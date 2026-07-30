#!/usr/bin/env python3
"""Local dashboard for Codex profile status and account limits."""

from __future__ import annotations

import json
import hashlib
import os
import re
import selectors
import shutil
import sqlite3
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, time as datetime_time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


DEFAULT_USAGE = {
    "input_tokens": 0,
    "cached_input_tokens": 0,
    "output_tokens": 0,
    "reasoning_output_tokens": 0,
    "total_tokens": 0,
}
PROFILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
RUNTIME_GREEN_ROLLOUT_MS = 90_000
RUNTIME_RECENT_ACTIVITY_MS = 15 * 60_000
REMOTE_STATUS_CACHE_SECONDS = 10 * 60
RESET_CREDIT_DETAILS_CACHE_SECONDS = 6 * 60 * 60
TASK_RATE_LIMIT_MAX_AGE_SECONDS = 30 * 60
TASK_RESET_TIME_TOLERANCE_SECONDS = 5
CHATGPT_APP_BINARY = Path("/Applications/ChatGPT.app/Contents/Resources/codex")
LEGACY_CODEX_APP_BINARY = Path("/Applications/Codex.app/Contents/Resources/codex")
CODEX_APP_BINARY = CHATGPT_APP_BINARY
RESET_CREDIT_GRANTED_KEYS = ("granted_at", "grantedAt", "created_at", "createdAt", "issued_at", "issuedAt")
RESET_CREDIT_EXPIRES_KEYS = (
    "expires_at",
    "expiresAt",
    "expiration_time",
    "expirationTime",
    "expired_at",
    "expiredAt",
)
RESET_CREDIT_USED_KEYS = (
    "used",
    "is_used",
    "isUsed",
    "consumed",
    "is_consumed",
    "isConsumed",
    "redeemed",
)
ATTRIBUTION_LEDGER_VERSION = 1
THREAD_ATTRIBUTION_SCHEMA_VERSION = 1
THREAD_CHILD_SHARE_WARNING_THRESHOLD = 0.80
THREAD_FORK_CACHED_INPUT_WARNING_THRESHOLD = 0.75
THREAD_USAGE_KEYS = (
    "input_tokens",
    "cached_input_tokens",
    "non_cached_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


def normalize_window(value: dict | None) -> dict | None:
    if not value:
        return None
    used = int(value.get("usedPercent") or 0)
    return {
        "used_percent": used,
        "remaining_percent": max(0, 100 - used),
        "window_minutes": value.get("windowDurationMins"),
        "resets_at": value.get("resetsAt"),
    }

def _first_present(value: dict, *keys: str) -> object | None:
    for key in keys:
        if key in value and value[key] is not None:
            return value[key]
    return None


def _optional_int(value: object | None) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _optional_number(value: object | None) -> int | float | None:
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return int(number) if number.is_integer() else number


def _optional_timestamp(value: object | None) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        timestamp = float(value)
        if timestamp > 10_000_000_000:
            timestamp = timestamp / 1000
        return int(timestamp) if timestamp.is_integer() else timestamp
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return _optional_timestamp(float(text))
        except ValueError:
            pass
        try:
            parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        timestamp = parsed.timestamp()
        return int(timestamp) if timestamp.is_integer() else timestamp
    return None


def _mask_identifier(value: object | None) -> str | None:
    if value is None:
        return None
    text = str(value)
    digest = hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()[:10]
    if len(text) <= 8:
        return f"hash:{digest}"
    return f"{text[:4]}...{text[-4:]} hash:{digest}"


def build_reset_credit_reminder_schedule(expires_at: object | None) -> list[dict]:
    """Build reset-credit reminder timestamps in the user's Beijing workday."""
    expiry_timestamp = _optional_timestamp(expires_at)
    if expiry_timestamp is None:
        return []

    timezone_beijing = ZoneInfo("Asia/Shanghai")
    expiry = datetime.fromtimestamp(expiry_timestamp, timezone_beijing)
    previous_workday = expiry.date() - timedelta(days=1)
    while previous_workday.weekday() >= 5:
        previous_workday -= timedelta(days=1)

    reminders = [
        {
            "kind": "previous_workday",
            "at": int(
                datetime.combine(
                    previous_workday,
                    datetime_time(hour=16, minute=30),
                    tzinfo=timezone_beijing,
                ).timestamp()
            ),
        }
    ]
    if expiry.weekday() < 5 and (expiry.hour, expiry.minute) >= (11, 0):
        reminders.append(
            {
                "kind": "same_day_morning",
                "at": int(
                    datetime.combine(
                        expiry.date(),
                        datetime_time(hour=9, minute=30),
                        tzinfo=timezone_beijing,
                    ).timestamp()
                ),
            }
        )
    reminders.append(
        {
            "kind": "last_chance",
            "at": int((expiry - timedelta(hours=1)).timestamp()),
        }
    )
    return sorted(reminders, key=lambda reminder: reminder["at"])


def normalize_reset_credits(payload: dict, limits: dict) -> dict:
    candidates = [
        payload.get("rateLimitResetCredits"),
        payload.get("resetCredits"),
        limits.get("rateLimitResetCredits"),
        limits.get("resetCredits"),
        limits.get("credits"),
    ]
    credits = next((item for item in candidates if isinstance(item, dict)), {})
    available = _optional_int(
        _first_present(credits, "availableCount", "available_count", "balance", "count")
    )
    return {
        "available": bool(credits),
        "available_count": available,
        "has_credits": credits.get("hasCredits"),
        "unlimited": credits.get("unlimited"),
        "expires_at": _optional_number(
            _first_present(
                credits,
                "expiresAt",
                "expires_at",
                "expirationTime",
                "expiration_time",
                "resetsAt",
            )
        ),
    }


def normalize_reset_credit_details(payload: dict | None) -> dict:
    value = payload or {}
    credits = value.get("credits") if isinstance(value.get("credits"), list) else []
    normalized_credits = []
    for item in credits:
        if not isinstance(item, dict):
            continue
        status = _first_present(item, "status", "state", "type") or "unknown"
        used = _first_present(item, *RESET_CREDIT_USED_KEYS)
        if used is None:
            used = str(status).lower() not in {"available", "active", "unused"}
        granted_at = _optional_timestamp(_first_present(item, *RESET_CREDIT_GRANTED_KEYS))
        expires_at = _optional_timestamp(_first_present(item, *RESET_CREDIT_EXPIRES_KEYS))
        card = {
            "id": _mask_identifier(
                _first_present(
                    item,
                    "id",
                    "uuid",
                    "credit_id",
                    "creditId",
                    "reset_credit_id",
                    "resetCreditId",
                )
            ),
            "status": status,
            "used": bool(used),
            "reset_type": _first_present(item, "reset_type", "resetType"),
            "title": _first_present(item, "title"),
            "description": _first_present(item, "description"),
            "granted_at": granted_at,
            "expires_at": expires_at,
            "reminders": build_reset_credit_reminder_schedule(expires_at),
        }
        normalized_credits.append(card)

    available_count = _optional_int(
        _first_present(value, "available_count", "availableCount", "count", "balance")
    )
    if available_count is None:
        available_count = sum(
            1
            for card in normalized_credits
            if not card["used"] and str(card["status"]).lower() in {"available", "active", "unused"}
        )
    total_earned_count = _optional_int(
        _first_present(value, "total_earned_count", "totalEarnedCount", "total")
    )
    available_expirations = [
        card["expires_at"]
        for card in normalized_credits
        if card["expires_at"] is not None and not card["used"]
    ]
    return {
        "available": bool(value),
        "available_count": available_count,
        "total_earned_count": total_earned_count,
        "credits": normalized_credits,
        "earliest_expires_at": min(available_expirations) if available_expirations else None,
    }


def normalize_individual_limit(value: dict | None) -> dict | None:
    if not value:
        return None
    return {
        "used": value.get("used"),
        "limit": value.get("limit"),
        "remaining_percent": _optional_int(value.get("remainingPercent")),
        "resets_at": _optional_timestamp(value.get("resetsAt")),
    }


def normalize_account(payload: dict | None) -> dict:
    value = payload or {}
    account = value.get("account") if isinstance(value.get("account"), dict) else {}
    return {
        "available": bool(account),
        "type": account.get("type"),
        "plan_type": account.get("planType"),
        "email_present": account.get("email") is not None,
        "requires_openai_auth": bool(value.get("requiresOpenaiAuth")),
    }


def normalize_rate_limits(payload: dict | None) -> dict:
    value = payload or {}
    buckets = value.get("rateLimitsByLimitId")
    limits = (
        buckets.get("codex")
        if isinstance(buckets, dict) and isinstance(buckets.get("codex"), dict)
        else value.get("rateLimits") or {}
    )
    reset_credits = normalize_reset_credits(value, limits)
    reset_credit_details = normalize_reset_credit_details(
        value.get("rateLimitResetCredits")
        if isinstance(value.get("rateLimitResetCredits"), dict)
        else None
    )
    return {
        "available": bool(limits),
        "limit_id": limits.get("limitId"),
        "limit_name": limits.get("limitName"),
        "plan_type": limits.get("planType"),
        "credits_available": reset_credits["available_count"],
        "reset_credits": reset_credits,
        "reset_credit_details": reset_credit_details,
        "primary": normalize_window(limits.get("primary")),
        "secondary": normalize_window(limits.get("secondary")),
        "individual_limit": normalize_individual_limit(limits.get("individualLimit")),
        "rate_limit_reached_type": limits.get("rateLimitReachedType"),
    }


def _usage_value(usage: dict, key: str) -> int:
    return int(usage.get(key) or 0)


def _empty_usage() -> dict:
    return dict(DEFAULT_USAGE)


def _add_usage(target: dict, usage: dict) -> None:
    for key in DEFAULT_USAGE:
        target[key] = _usage_value(target, key) + _usage_value(usage, key)


def _date_key(timestamp: str | None) -> str | None:
    if isinstance(timestamp, str) and len(timestamp) >= 10:
        return timestamp[:10]
    return None


def _beijing_day(value: datetime) -> str:
    return value.astimezone(ZoneInfo("Asia/Shanghai")).date().isoformat()


def _local_total_tokens(local_snapshot: dict | None) -> int | None:
    total = (local_snapshot or {}).get("total") or {}
    if not isinstance(total, dict):
        return None
    value = total.get("total_tokens")
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _attribution_ledger_path(shared_home: Path) -> Path:
    return shared_home / "cache" / "codex-profile-switcher" / "token-attribution" / "ledger.json"


def _empty_attribution_ledger() -> dict:
    return {
        "version": ATTRIBUTION_LEDGER_VERSION,
        "active_profile": None,
        "managed": False,
        "baseline": None,
        "daily_estimates": {},
    }


def read_attribution_ledger(shared_home: Path) -> dict:
    path = _attribution_ledger_path(shared_home)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return _empty_attribution_ledger()
    if not isinstance(value, dict):
        return _empty_attribution_ledger()
    ledger = _empty_attribution_ledger()
    ledger.update(value)
    if not isinstance(ledger.get("daily_estimates"), dict):
        ledger["daily_estimates"] = {}
    return ledger


def _write_attribution_ledger(shared_home: Path, ledger: dict) -> None:
    path = _attribution_ledger_path(shared_home)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(
            json.dumps(ledger, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        tmp.replace(path)
    except OSError:
        return


def _add_daily_profile_estimate(ledger: dict, day: str, profile_name: str, tokens: int) -> None:
    if tokens <= 0:
        return
    daily = ledger.setdefault("daily_estimates", {})
    day_bucket = daily.setdefault(day, {})
    current = day_bucket.get(profile_name)
    current_tokens = 0
    if isinstance(current, dict):
        current_tokens = int(current.get("estimated_tokens") or 0)
    elif isinstance(current, int):
        current_tokens = current
    day_bucket[profile_name] = {"estimated_tokens": current_tokens + tokens}


def _close_active_attribution_segment(
    ledger: dict,
    *,
    current_total_tokens: int | None,
    day: str,
) -> None:
    baseline = ledger.get("baseline")
    active = ledger.get("active_profile")
    if not ledger.get("managed") or not isinstance(baseline, dict) or not isinstance(active, str):
        return
    baseline_total = baseline.get("total_tokens")
    if current_total_tokens is None or not isinstance(baseline_total, int):
        return
    _add_daily_profile_estimate(
        ledger,
        day,
        active,
        max(0, current_total_tokens - baseline_total),
    )


def record_attribution_baseline(
    shared_home: Path,
    profile_name: str,
    local_snapshot: dict | None,
    *,
    managed: bool,
    now_seconds: float | None = None,
) -> None:
    now_value = datetime.fromtimestamp(
        time.time() if now_seconds is None else now_seconds,
        timezone.utc,
    )
    day = _beijing_day(now_value)
    current_total = _local_total_tokens(local_snapshot)
    ledger = read_attribution_ledger(shared_home)
    _close_active_attribution_segment(
        ledger,
        current_total_tokens=current_total,
        day=day,
    )
    ledger.update(
        {
            "version": ATTRIBUTION_LEDGER_VERSION,
            "active_profile": profile_name,
            "managed": bool(managed),
            "baseline": {
                "profile": profile_name,
                "recorded_at": int(now_value.timestamp()),
                "day": day,
                "total_tokens": current_total,
                "latest_timestamp": (local_snapshot or {}).get("latest_timestamp"),
            },
        }
    )
    _write_attribution_ledger(shared_home, ledger)


def _official_bucket_tokens(usage: dict | None, day: str) -> int | None:
    for item in (usage or {}).get("dailyUsageBuckets") or []:
        if not isinstance(item, dict):
            continue
        if item.get("startDate") == day:
            try:
                return int(item.get("tokens") or 0)
            except (TypeError, ValueError):
                return None
    return None


def _stored_estimate_tokens(ledger: dict, day: str, profile_name: str) -> int | None:
    profile_estimate = ((ledger.get("daily_estimates") or {}).get(day) or {}).get(profile_name)
    if isinstance(profile_estimate, dict):
        try:
            return int(profile_estimate.get("estimated_tokens") or 0)
        except (TypeError, ValueError):
            return None
    if isinstance(profile_estimate, int):
        return profile_estimate
    return None


def summarize_profile_attribution(
    shared_home: Path,
    profile_name: str,
    local_snapshot: dict | None,
    account_usage: dict | None,
    *,
    now: datetime | None = None,
) -> dict:
    now_value = now or datetime.now(timezone.utc)
    today = _beijing_day(now_value)
    previous_day_key = (
        now_value.astimezone(ZoneInfo("Asia/Shanghai")).date() - timedelta(days=1)
    ).isoformat()
    ledger = read_attribution_ledger(shared_home)
    active_profile = ledger.get("active_profile")
    current_total = _local_total_tokens(local_snapshot)

    stored_today = _stored_estimate_tokens(ledger, today, profile_name) or 0
    active_delta = None
    if active_profile == profile_name and ledger.get("managed"):
        baseline = ledger.get("baseline")
        baseline_total = baseline.get("total_tokens") if isinstance(baseline, dict) else None
        if current_total is not None and isinstance(baseline_total, int):
            active_delta = max(0, current_total - baseline_total)

    estimated_today = stored_today + (active_delta or 0)
    estimate_available = estimated_today > 0 or active_delta is not None
    official_today = _official_bucket_tokens(account_usage, today)
    if official_today is not None:
        display_tokens = official_today
        source = "official"
    elif estimate_available:
        display_tokens = estimated_today
        source = "attribution_estimate"
    else:
        display_tokens = None
        source = "unavailable"

    official_previous = _official_bucket_tokens(account_usage, previous_day_key)
    estimated_previous = _stored_estimate_tokens(ledger, previous_day_key, profile_name)
    accuracy = None
    if estimated_previous is not None and official_previous is not None:
        delta = estimated_previous - official_previous
        accuracy = {
            "date": previous_day_key,
            "estimated_tokens": estimated_previous,
            "official_tokens": official_previous,
            "delta_tokens": delta,
            "delta_percent": (delta / official_previous * 100) if official_previous else None,
        }

    return {
        "active_profile": active_profile,
        "managed": bool(ledger.get("managed")),
        "estimate_available": estimate_available,
        "today_estimated_tokens": estimated_today if estimate_available else None,
        "today_official_tokens": official_today,
        "today_display_tokens": display_tokens,
        "today_source": source,
        "previous_day_accuracy": accuracy,
    }


def summarize_account_usage(usage: dict | None, now: datetime | None = None) -> dict:
    now_value = now or datetime.now(timezone.utc)
    today_key = now_value.astimezone(ZoneInfo("Asia/Shanghai")).date().isoformat()
    raw_buckets = (usage or {}).get("dailyUsageBuckets") or []
    buckets = []
    for item in raw_buckets:
        if not isinstance(item, dict):
            continue
        date = item.get("startDate")
        if not isinstance(date, str):
            continue
        buckets.append({"date": date, "tokens": int(item.get("tokens") or 0)})
    buckets.sort(key=lambda item: item["date"])

    latest_date = buckets[-1]["date"] if buckets else None
    today_bucket = next((item for item in reversed(buckets) if item["date"] == today_key), None)
    last_7 = buckets[-7:]
    last_14 = buckets[-14:]
    return {
        "today_tokens": today_bucket["tokens"] if today_bucket else None,
        "today_available": today_bucket is not None,
        "last_7_tokens": sum(item["tokens"] for item in last_7) if last_7 else None,
        "last_14_tokens": sum(item["tokens"] for item in last_14) if last_14 else None,
        "latest_date": latest_date,
        "source": "account_usage",
    }


def _extract_token_count(row: dict) -> tuple[dict, dict | None] | None:
    payload = row.get("payload") or {}
    if not isinstance(payload, dict):
        return None
    message = payload.get("message") or {}
    if not isinstance(message, dict):
        return None
    if payload.get("type") == "token_count":
        message = payload
    if row.get("type") == "token_count":
        message = row
    if message.get("type") != "token_count":
        return None
    info = message.get("info") or {}
    usage = info.get("total_token_usage") or {}
    rate_limits = (
        info.get("rate_limits")
        or info.get("rateLimits")
        or message.get("rate_limits")
        or message.get("rateLimits")
    )
    normalized_usage = {key: _usage_value(usage, key) for key in DEFAULT_USAGE}
    return normalized_usage, rate_limits


def _safe_thread_id(value: object | None) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def _thread_usage(usage: dict | None = None) -> dict:
    value = usage if isinstance(usage, dict) else {}
    normalized = {
        key: max(0, _usage_value(value, key))
        for key in DEFAULT_USAGE
    }
    normalized["non_cached_input_tokens"] = max(
        0,
        normalized["input_tokens"] - normalized["cached_input_tokens"],
    )
    return normalized


def _add_thread_usage(target: dict, usage: dict | None) -> None:
    normalized = _thread_usage(usage)
    for key in THREAD_USAGE_KEYS:
        target[key] = int(target.get(key) or 0) + normalized[key]


def _thread_rollout_key(path: Path) -> str:
    try:
        value = str(path.expanduser().resolve(strict=False))
    except OSError:
        value = str(path)
    return value


def _thread_ids_by_rollout(shared_home: Path) -> dict[str, str]:
    """Read only the SQLite rollout mapping for metadata compatibility fallback."""
    state_path = _sqlite_state_path(shared_home)
    if state_path is None:
        return {}
    try:
        conn = sqlite3.connect(f"file:{state_path}?mode=ro", uri=True, timeout=5)
        try:
            columns = {row[1] for row in conn.execute("pragma table_info(threads)")}
            if "id" not in columns or "rollout_path" not in columns:
                return {}
            rows = conn.execute(
                "select id, rollout_path from threads "
                "where id is not null and rollout_path is not null"
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return {}
    result = {}
    for thread_id, rollout_path in rows:
        safe_id = _safe_thread_id(thread_id)
        if safe_id and isinstance(rollout_path, str) and rollout_path.strip():
            path = Path(rollout_path).expanduser()
            if not path.is_absolute():
                path = shared_home / path
            result[_thread_rollout_key(path)] = safe_id
    return result


def _read_thread_rollout(path: Path, fallback_thread_id: str | None = None) -> dict:
    """Read session metadata and the last valid token count without returning rollout text."""
    metadata_seen = False
    metadata_invalid = False
    metadata: dict | None = None
    latest_usage: dict | None = None
    latest_timestamp: str | None = None
    bad_line_count = 0
    try:
        handle = path.open(encoding="utf-8")
    except OSError:
        return {
            "thread_id": fallback_thread_id,
            "parent_thread_id": None,
            "forked_from_id": None,
            "metadata_status": "unreadable",
            "usage": None,
            "latest_timestamp": None,
            "bad_line_count": 0,
        }

    with handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                bad_line_count += 1
                continue
            if not isinstance(row, dict):
                continue
            if row.get("type") == "session_meta":
                metadata_seen = True
                payload = row.get("payload")
                if not isinstance(payload, dict):
                    metadata_invalid = True
                else:
                    thread_id = _safe_thread_id(payload.get("id"))
                    source = payload.get("source")
                    subagent = source.get("subagent") if isinstance(source, dict) else None
                    spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
                    parent_thread_id = None
                    parent_source = None
                    if isinstance(spawn, dict):
                        parent_thread_id = _safe_thread_id(spawn.get("parent_thread_id"))
                        if parent_thread_id:
                            parent_source = "source.subagent.thread_spawn"
                    if parent_thread_id is None:
                        parent_thread_id = _safe_thread_id(payload.get("parent_thread_id"))
                        if parent_thread_id:
                            parent_source = "session_meta.parent_thread_id"
                    if thread_id:
                        metadata = {
                            "thread_id": thread_id,
                            "parent_thread_id": parent_thread_id,
                            "parent_source": parent_source,
                            "forked_from_id": _safe_thread_id(payload.get("forked_from_id")),
                        }
                    else:
                        metadata_invalid = True

            extracted = _extract_token_count(row)
            if extracted is None:
                continue
            usage, _ = extracted
            timestamp = row.get("timestamp")
            if latest_timestamp is None or (timestamp or "") >= latest_timestamp:
                latest_timestamp = timestamp
                latest_usage = usage

    thread_id = (metadata or {}).get("thread_id") or fallback_thread_id
    if metadata is not None:
        metadata_status = "valid"
        if metadata.get("parent_source") == "session_meta.parent_thread_id":
            metadata_status = "legacy_parent_field"
    elif fallback_thread_id:
        metadata_status = "sqlite_fallback"
    elif metadata_seen or metadata_invalid:
        metadata_status = "malformed"
    else:
        metadata_status = "missing"
    return {
        "thread_id": thread_id,
        "parent_thread_id": (metadata or {}).get("parent_thread_id"),
        "forked_from_id": (metadata or {}).get("forked_from_id"),
        "metadata_status": metadata_status,
        "usage": latest_usage,
        "latest_timestamp": latest_timestamp,
        "bad_line_count": bad_line_count,
    }


def _unresolved_thread_id(path: Path) -> str:
    digest = hashlib.sha256(_thread_rollout_key(path).encode("utf-8")).hexdigest()[:16]
    return f"unresolved:{digest}"


def _thread_root(
    thread_id: str,
    nodes: dict[str, dict],
) -> tuple[str, str]:
    seen: list[str] = []
    current = thread_id
    while True:
        if current in seen:
            cycle = seen[seen.index(current):]
            return min(cycle), "cycle"
        seen.append(current)
        parent = nodes.get(current, {}).get("parent_thread_id")
        if not parent:
            node = nodes.get(current, {})
            if node.get("metadata_status") in {"missing", "malformed", "unreadable"}:
                return current, "missing_metadata"
            return current, "top_level"
        if parent not in nodes:
            return current, "missing_parent"
        current = parent


def _thread_depth(thread_id: str, root_id: str, nodes: dict[str, dict]) -> int:
    depth = 0
    current = thread_id
    seen = set()
    while current != root_id and current not in seen:
        seen.add(current)
        parent = nodes.get(current, {}).get("parent_thread_id")
        if not parent:
            break
        depth += 1
        current = parent
    return max(1, depth)


def _thread_task_status_label(status: str) -> str:
    return {
        "top_level": "顶层任务",
        "missing_parent": "父任务缺失",
        "missing_metadata": "未识别 rollout",
        "cycle": "关系环异常",
    }.get(status, "归因异常")


def read_thread_attribution(shared_home: Path) -> dict:
    """Summarize local rollout tokens by top-level task without reading chat content."""
    search_roots = (shared_home / "sessions", shared_home / "archived_sessions")
    rollout_paths = [
        path
        for root in search_roots
        if root.exists()
        for path in sorted(root.rglob("rollout-*.jsonl"))
    ]
    sqlite_thread_ids = _thread_ids_by_rollout(shared_home)
    nodes: dict[str, dict] = {}
    bad_line_count = 0
    metadata_missing_count = 0
    metadata_malformed_count = 0
    rollout_count = 0

    for path in rollout_paths:
        record = _read_thread_rollout(
            path,
            sqlite_thread_ids.get(_thread_rollout_key(path)),
        )
        if record["usage"] is None and record["thread_id"] is None:
            continue
        thread_id = record["thread_id"] or _unresolved_thread_id(path)
        if record["thread_id"] is None:
            record["metadata_status"] = "missing"
        node = nodes.setdefault(
            thread_id,
            {
                "thread_id": thread_id,
                "parent_thread_id": None,
                "is_fork": False,
                "metadata_status": record["metadata_status"],
                "usage": _thread_usage(),
                "rollout_count": 0,
            },
        )
        parent = record.get("parent_thread_id")
        if parent and node["parent_thread_id"] and parent != node["parent_thread_id"]:
            node["metadata_status"] = "conflict"
            node["parent_thread_id"] = None
        elif parent:
            node["parent_thread_id"] = parent
        node["is_fork"] = node["is_fork"] or bool(record.get("forked_from_id"))
        if node["metadata_status"] == "valid" and record["metadata_status"] != "valid":
            node["metadata_status"] = record["metadata_status"]
        _add_thread_usage(node["usage"], record["usage"])
        if record["usage"] is not None:
            node["rollout_count"] += 1
            rollout_count += 1
        bad_line_count += record["bad_line_count"]
        metadata_missing_count += record["metadata_status"] in {"missing", "sqlite_fallback"}
        metadata_malformed_count += record["metadata_status"] in {"malformed", "unreadable", "conflict"}

    roots: dict[str, list[str]] = {}
    statuses: dict[str, str] = {}
    for thread_id in nodes:
        root_id, status = _thread_root(thread_id, nodes)
        roots.setdefault(root_id, []).append(thread_id)
        statuses[root_id] = "cycle" if status == "cycle" else statuses.get(root_id, status)

    tasks = []
    risk_counts = {"child_share": 0, "full_context_fork": 0, "data_quality": 0}
    for root_id, member_ids in roots.items():
        root_node = nodes[root_id]
        member_ids = sorted(member_ids)
        child_ids = [thread_id for thread_id in member_ids if thread_id != root_id]
        own_usage = _thread_usage(root_node["usage"])
        child_usage = _thread_usage()
        child_rows = []
        for child_id in child_ids:
            child = nodes[child_id]
            _add_thread_usage(child_usage, child["usage"])
            child_rows.append(
                {
                    "thread_id": child_id,
                    "relation": "fork" if child["is_fork"] else "subtask",
                    "depth": _thread_depth(child_id, root_id, nodes),
                    "metadata_status": child["metadata_status"],
                    "tokens": _thread_usage(child["usage"]),
                    "rollout_count": child["rollout_count"],
                }
            )
        merged_usage = _thread_usage(own_usage)
        _add_thread_usage(merged_usage, child_usage)
        merged_total = merged_usage["total_tokens"]
        child_share = (
            child_usage["total_tokens"] / merged_total
            if merged_total > 0
            else 0.0
        )
        full_context_fork = any(
            row["relation"] == "fork"
            and row["tokens"]["cached_input_tokens"]
            / max(row["tokens"]["input_tokens"], 1)
            >= THREAD_FORK_CACHED_INPUT_WARNING_THRESHOLD
            for row in child_rows
        )
        status = statuses.get(root_id, "top_level")
        messages = []
        if child_share >= THREAD_CHILD_SHARE_WARNING_THRESHOLD and child_ids:
            risk_counts["child_share"] += 1
            messages.append(
                f"子任务占合并统计 {child_share * 100:.1f}%，请展开查看；这只是本机 rollout 统计。"
            )
        if full_context_fork:
            risk_counts["full_context_fork"] += 1
            messages.append(
                "检测到 fork 子任务的缓存输入占比较高，可能复制了较完整上下文；"
                "本机数据不能证明官方计费。"
            )
        if status != "top_level" or any(
            node_id != root_id and nodes[node_id]["metadata_status"] != "valid"
            for node_id in member_ids
        ):
            risk_counts["data_quality"] += 1
            messages.append("线程元数据不完整，工作台未把它强行合并到其他任务。")
        tasks.append(
            {
                "thread_id": root_id,
                "status": status,
                "status_label": _thread_task_status_label(status),
                "own_tokens": own_usage,
                "child_tokens": child_usage,
                "merged_tokens": merged_usage,
                "child_task_count": len(child_ids),
                "fork_child_count": sum(1 for child_id in child_ids if nodes[child_id]["is_fork"]),
                "child_share": child_share,
                "child_share_abnormal": child_share >= THREAD_CHILD_SHARE_WARNING_THRESHOLD
                and bool(child_ids),
                "full_context_fork_risk": full_context_fork,
                "risk_messages": messages,
                "children": sorted(
                    child_rows,
                    key=lambda row: (-row["tokens"]["total_tokens"], row["thread_id"]),
                ),
                "rollout_count": sum(nodes[node_id]["rollout_count"] for node_id in member_ids),
            }
        )

    tasks.sort(key=lambda item: (-item["merged_tokens"]["total_tokens"], item["thread_id"]))
    return {
        "schema_version": THREAD_ATTRIBUTION_SCHEMA_VERSION,
        "source": "local_rollouts",
        "scope_label": "本机 rollout 统计",
        "disclaimer": "不是官方账单，也不是实时配额；仅表示本机 rollout 文件的最后 token_count 汇总。",
        "is_official_billing": False,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "rollout_count": rollout_count,
        "top_level_task_count": len(tasks),
        "metadata_missing_count": metadata_missing_count,
        "metadata_malformed_count": metadata_malformed_count,
        "bad_line_count": bad_line_count,
        "risk_counts": risk_counts,
        "tasks": tasks,
    }


def _rate_limit_fingerprint(value: dict | None) -> dict | None:
    if not isinstance(value, dict):
        return None

    def window(name: str) -> dict | None:
        raw = value.get(name)
        if not isinstance(raw, dict):
            return None
        minutes = _optional_int(
            _first_present(raw, "window_minutes", "windowDurationMins", "window_duration_mins")
        )
        resets_at = _optional_timestamp(_first_present(raw, "resets_at", "resetsAt"))
        if minutes is None or resets_at is None:
            return None
        return {"window_minutes": minutes, "resets_at": int(resets_at)}

    windows = [item for item in (window("primary"), window("secondary")) if item is not None]
    windows.sort(key=lambda item: (item["window_minutes"], item["resets_at"]))
    if not windows:
        return None
    return {"windows": windows}


def _latest_visible_thread_rollout(shared_home: Path) -> tuple[str | None, Path] | None:
    state_path = _sqlite_state_path(shared_home)
    if state_path is None:
        return None
    try:
        conn = sqlite3.connect(f"file:{state_path}?mode=ro", uri=True, timeout=5)
        try:
            columns = {row[1] for row in conn.execute("pragma table_info(threads)")}
            if "rollout_path" not in columns:
                return None
            filters = []
            if "archived" in columns:
                filters.append("archived = 0")
            if "preview" in columns:
                filters.append("preview != ''")
            order_column = next(
                (
                    name
                    for name in ("recency_at_ms", "updated_at_ms", "updated_at", "created_at")
                    if name in columns
                ),
                None,
            )
            where = f" where {' and '.join(filters)}" if filters else ""
            order = f" order by {order_column} desc" if order_column else ""
            selection = "id, rollout_path" if "id" in columns else "null, rollout_path"
            row = conn.execute(f"select {selection} from threads{where}{order} limit 1").fetchone()
        finally:
            conn.close()
    except sqlite3.Error:
        return None
    if not row or not isinstance(row[1], str):
        return None
    path = Path(row[1]).expanduser()
    return (str(row[0]) if row[0] is not None else None, path) if path.is_file() else None


def _latest_rollout_rate_limit_event(path: Path) -> tuple[dict, float] | None:
    latest: tuple[dict, float] | None = None
    try:
        handle = path.open(encoding="utf-8")
    except OSError:
        return None
    with handle:
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            payload = row.get("payload")
            if not isinstance(payload, dict):
                continue
            message = payload.get("message")
            message = message if isinstance(message, dict) else {}
            event = payload if payload.get("type") == "token_count" else message
            info = event.get("info")
            info = info if isinstance(info, dict) else {}
            raw_limits = (
                info.get("rate_limits")
                or info.get("rateLimits")
                or event.get("rate_limits")
                or event.get("rateLimits")
            )
            fingerprint = _rate_limit_fingerprint(raw_limits)
            timestamp = _optional_timestamp(row.get("timestamp"))
            if fingerprint is None or timestamp is None:
                continue
            if latest is None or float(timestamp) >= latest[1]:
                latest = (fingerprint, float(timestamp))
    return latest


def infer_task_profile(
    shared_home: Path,
    profile_rate_limits: dict[str, dict],
    *,
    now_seconds: float | None = None,
    max_age_seconds: int = TASK_RATE_LIMIT_MAX_AGE_SECONDS,
    reset_tolerance_seconds: int = TASK_RESET_TIME_TOLERANCE_SECONDS,
) -> dict:
    thread_rollout = _latest_visible_thread_rollout(shared_home)
    if thread_rollout is None:
        return {"profile": None, "source": "no_recent_thread", "confidence": "unknown"}
    thread_id, rollout = thread_rollout
    event = _latest_rollout_rate_limit_event(rollout)
    if event is None:
        return {
            "profile": None,
            "source": "missing_thread_rate_limits",
            "confidence": "unknown",
            "thread_id": thread_id,
        }
    task_fingerprint, observed_at = event
    now = time.time() if now_seconds is None else now_seconds
    if now - observed_at > max_age_seconds or observed_at - now > reset_tolerance_seconds:
        return {
            "profile": None,
            "source": "stale_thread_rate_limits",
            "confidence": "unknown",
            "observed_at": int(observed_at),
            "thread_id": thread_id,
        }

    def matches(candidate: dict | None) -> bool:
        fingerprint = _rate_limit_fingerprint(candidate)
        if fingerprint is None:
            return False
        task_windows = task_fingerprint["windows"]
        candidate_windows = fingerprint["windows"]
        if len(candidate_windows) != len(task_windows):
            return False
        for task_window, candidate_window in zip(task_windows, candidate_windows):
            if candidate_window["window_minutes"] != task_window["window_minutes"]:
                return False
            if abs(candidate_window["resets_at"] - task_window["resets_at"]) > reset_tolerance_seconds:
                return False
        return True

    matched = sorted(name for name, limits in profile_rate_limits.items() if matches(limits))
    if len(matched) == 1:
        return {
            "profile": matched[0],
            "source": "recent_active_thread_rate_limit_match",
            "confidence": "inferred",
            "observed_at": int(observed_at),
            "thread_id": thread_id,
        }
    if len(matched) > 1:
        return {
            "profile": None,
            "source": "ambiguous_rate_limit_match",
            "confidence": "unknown",
            "observed_at": int(observed_at),
            "thread_id": thread_id,
        }
    return {
        "profile": None,
        "source": "no_rate_limit_match",
        "confidence": "unknown",
        "observed_at": int(observed_at),
        "thread_id": thread_id,
    }


def read_local_token_snapshot(shared_home: Path) -> dict:
    event_count = 0
    bad_line_count = 0
    latest_timestamp = None
    latest_usage = _empty_usage()
    latest_rate_limits = None
    daily_usage: dict[str, dict] = {}
    model_usage: dict[str, dict] = {}
    search_roots = (shared_home / "sessions", shared_home / "archived_sessions")

    for root in search_roots:
        if not root.exists():
            continue
        for path in sorted(root.rglob("rollout-*.jsonl")):
            file_latest_timestamp = None
            file_latest_usage = None
            file_model = "unknown"
            try:
                handle = path.open(encoding="utf-8")
            except OSError:
                continue
            with handle:
                for line in handle:
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        bad_line_count += 1
                        continue
                    payload = row.get("payload") or {}
                    if (
                        isinstance(payload, dict)
                        and row.get("type") == "turn_context"
                        and isinstance(payload.get("model"), str)
                    ):
                        file_model = payload["model"]
                    extracted = _extract_token_count(row)
                    if extracted is None:
                        continue
                    usage, rate_limits = extracted
                    timestamp = row.get("timestamp")
                    if latest_timestamp is None or (timestamp or "") >= latest_timestamp:
                        latest_timestamp = timestamp
                        latest_usage = usage
                        latest_rate_limits = rate_limits
                    if file_latest_timestamp is None or (timestamp or "") >= file_latest_timestamp:
                        file_latest_timestamp = timestamp
                        file_latest_usage = usage
                    event_count += 1
            if file_latest_usage is None:
                continue
            day = _date_key(file_latest_timestamp)
            if day is not None:
                daily_usage.setdefault(day, {"date": day, **_empty_usage()})
                _add_usage(daily_usage[day], file_latest_usage)
            model_usage.setdefault(file_model, {"model": file_model, **_empty_usage()})
            _add_usage(model_usage[file_model], file_latest_usage)

    return {
        "event_count": event_count,
        "bad_line_count": bad_line_count,
        "latest_timestamp": latest_timestamp,
        "total": latest_usage,
        "daily": [daily_usage[key] for key in sorted(daily_usage)[-30:]],
        "by_model": sorted(
            model_usage.values(),
            key=lambda item: item["total_tokens"],
            reverse=True,
        )[:8],
        "rate_limits": normalize_rate_limits({"rateLimits": latest_rate_limits})
        if latest_rate_limits
        else normalize_rate_limits(None),
    }


def read_sqlite_history_summary(shared_home: Path) -> dict:
    path = _sqlite_state_path(shared_home)
    if path is None:
        return {"available": False, "thread_count": 0, "tokens_used": 0, "error": None}
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            row = conn.execute(
                "select count(*), coalesce(sum(tokens_used), 0) from threads"
            ).fetchone()
        finally:
            conn.close()
    except sqlite3.Error:
        return {
            "available": False,
            "thread_count": 0,
            "tokens_used": 0,
            "error": "sqlite unavailable",
        }
    return {
        "available": True,
        "thread_count": int(row[0] or 0),
        "tokens_used": int(row[1] or 0),
        "error": None,
    }


def _sqlite_state_path(shared_home: Path) -> Path | None:
    for path in (shared_home / "state_5.sqlite", shared_home / "sqlite" / "state_5.sqlite"):
        if path.exists():
            return path
    return None


def read_project_rankings(shared_home: Path, limit: int = 8) -> dict:
    path = _sqlite_state_path(shared_home)
    if path is None:
        return {"available": False, "projects": [], "error": None}
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            rows = conn.execute(
                """
                select cwd,
                       count(*),
                       coalesce(sum(tokens_used), 0),
                       coalesce(max(updated_at), 0)
                from threads
                where cwd is not null and cwd != ''
                group by cwd
                order by coalesce(sum(tokens_used), 0) desc,
                         coalesce(max(updated_at), 0) desc
                limit ?
                """,
                (limit,),
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return {"available": False, "projects": [], "error": "sqlite unavailable"}

    projects = []
    for cwd, thread_count, tokens_used, latest_updated_at in rows:
        path_value = str(cwd)
        projects.append(
            {
                "name": Path(path_value).name or path_value,
                "path": path_value,
                "thread_count": int(thread_count or 0),
                "tokens_used": int(tokens_used or 0),
                "latest_updated_at": int(latest_updated_at or 0),
            }
        )
    return {"available": True, "projects": projects, "error": None}


def read_tool_rankings(shared_home: Path, limit: int = 12) -> dict:
    path = _sqlite_state_path(shared_home)
    if path is None:
        return {"available": False, "tools": [], "error": None}
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            rows = conn.execute(
                """
                select coalesce(thread_dynamic_tools.namespace, ''),
                       thread_dynamic_tools.name,
                       count(*),
                       coalesce(max(threads.updated_at), 0),
                       coalesce(sum(threads.tokens_used), 0)
                from thread_dynamic_tools
                join threads on threads.id = thread_dynamic_tools.thread_id
                where thread_dynamic_tools.name is not null
                  and thread_dynamic_tools.name != ''
                group by coalesce(thread_dynamic_tools.namespace, ''),
                         thread_dynamic_tools.name
                order by count(*) desc, coalesce(max(threads.updated_at), 0) desc
                limit ?
                """,
                (limit,),
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return {"available": False, "tools": [], "error": "sqlite unavailable"}

    tools = []
    for namespace, name, call_count, latest_updated_at, thread_tokens in rows:
        namespace_value = str(namespace or "")
        name_value = str(name)
        tools.append(
            {
                "id": f"{namespace_value}.{name_value}" if namespace_value else name_value,
                "namespace": namespace_value,
                "name": name_value,
                "call_count": int(call_count or 0),
                "latest_updated_at": int(latest_updated_at or 0),
                "thread_tokens": int(thread_tokens or 0),
            }
        )
    return {"available": True, "tools": tools, "error": None}


def _skill_name_from_path(path_value: str) -> str | None:
    path = Path(path_value)
    if path.name != "SKILL.md" or path.parent.name in ("", "."):
        return None
    return path.parent.name


def _skill_names_from_row(row: dict) -> set[str]:
    payload = row.get("payload") or {}
    if not isinstance(payload, dict):
        return set()
    names: set[str] = set()
    parsed = payload.get("parsed_cmd") or row.get("parsed_cmd") or []
    if isinstance(parsed, list):
        for item in parsed:
            if not isinstance(item, dict):
                continue
            path_value = item.get("path")
            if not isinstance(path_value, str):
                continue
            name = _skill_name_from_path(path_value)
            if name:
                names.add(name)
    return names


def read_skill_rankings(shared_home: Path, limit: int = 12) -> dict:
    skills: dict[str, dict] = {}
    bad_line_count = 0
    search_roots = (shared_home / "sessions", shared_home / "archived_sessions")
    for root in search_roots:
        if not root.exists():
            continue
        for path in sorted(root.rglob("rollout-*.jsonl")):
            try:
                handle = path.open(encoding="utf-8")
            except OSError:
                continue
            with handle:
                for line in handle:
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        bad_line_count += 1
                        continue
                    timestamp = row.get("timestamp")
                    for name in _skill_names_from_row(row):
                        item = skills.setdefault(
                            name,
                            {"name": name, "use_count": 0, "latest_timestamp": None},
                        )
                        item["use_count"] += 1
                        if (
                            isinstance(timestamp, str)
                            and (
                                item["latest_timestamp"] is None
                                or timestamp > item["latest_timestamp"]
                            )
                        ):
                            item["latest_timestamp"] = timestamp
    ranked = sorted(
        skills.values(),
        key=lambda item: (item["use_count"], item.get("latest_timestamp") or ""),
        reverse=True,
    )[:limit]
    return {
        "available": bool(ranked),
        "skills": ranked,
        "bad_line_count": bad_line_count,
        "error": None,
    }


def _default_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _chat_process_files(shared_home: Path, profile_root: Path) -> list[Path]:
    paths = [shared_home / "process_manager" / "chat_processes.json"]
    if profile_root.exists():
        paths.extend(
            profile / "process_manager" / "chat_processes.json"
            for profile in sorted(path for path in profile_root.iterdir() if path.is_dir())
        )
    return paths


def _read_chat_processes(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


def _latest_rollout_mtime_ms(shared_home: Path) -> int | None:
    latest = None
    for root in (shared_home / "sessions", shared_home / "archived_sessions"):
        if not root.exists():
            continue
        for path in root.rglob("rollout-*.jsonl"):
            try:
                mtime = int(path.stat().st_mtime * 1000)
            except OSError:
                continue
            latest = mtime if latest is None else max(latest, mtime)
    return latest


def read_runtime_status(
    shared_home: Path,
    profile_root: Path,
    *,
    now_ms: int | None = None,
    pid_alive: Callable[[int], bool] = _default_pid_alive,
) -> dict:
    now = now_ms if now_ms is not None else int(time.time() * 1000)
    active_process_count = 0
    recent_process_count = 0
    latest_activity_at_ms = None
    sources_checked = 0

    for path in _chat_process_files(shared_home, profile_root):
        sources_checked += 1
        for item in _read_chat_processes(path):
            updated = item.get("updatedAtMs") or item.get("startedAtMs")
            if isinstance(updated, int):
                latest_activity_at_ms = (
                    updated
                    if latest_activity_at_ms is None
                    else max(latest_activity_at_ms, updated)
                )
                if now - updated <= RUNTIME_RECENT_ACTIVITY_MS:
                    recent_process_count += 1
            pid = item.get("osPid")
            if isinstance(pid, int) and pid_alive(pid):
                active_process_count += 1

    latest_rollout_at_ms = _latest_rollout_mtime_ms(shared_home)
    if latest_rollout_at_ms is not None:
        latest_activity_at_ms = (
            latest_rollout_at_ms
            if latest_activity_at_ms is None
            else max(latest_activity_at_ms, latest_rollout_at_ms)
        )

    latest_age_ms = None if latest_activity_at_ms is None else max(0, now - latest_activity_at_ms)
    if active_process_count > 0 or (
        latest_rollout_at_ms is not None and now - latest_rollout_at_ms <= RUNTIME_GREEN_ROLLOUT_MS
    ):
        state = "running"
        light = "green"
        label = "运行中"
    elif latest_age_ms is not None and latest_age_ms <= RUNTIME_RECENT_ACTIVITY_MS:
        state = "waiting"
        light = "yellow"
        label = "待接手"
    else:
        state = "idle"
        light = "red"
        label = "空闲"

    return {
        "state": state,
        "light": light,
        "label": label,
        "active_process_count": active_process_count,
        "recent_process_count": recent_process_count,
        "latest_activity_at_ms": latest_activity_at_ms,
        "latest_activity_age_ms": latest_age_ms,
        "latest_rollout_at_ms": latest_rollout_at_ms,
        "sources_checked": sources_checked,
    }


def build_rpc_request(request_id: int, method: str, params: dict | None = None) -> dict:
    request = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        request["params"] = params
    return request


def select_reset_credit_for_consumption(
    rate_limits: dict | None,
    *,
    now_seconds: float | None = None,
) -> dict | None:
    value = rate_limits or {}
    reset_credits = value.get("rateLimitResetCredits")
    if not isinstance(reset_credits, dict):
        return None
    now = time.time() if now_seconds is None else now_seconds
    credits = reset_credits.get("credits")
    available = []
    if isinstance(credits, list):
        for item in credits:
            if not isinstance(item, dict):
                continue
            status = str(item.get("status") or "available").lower()
            if status not in {"available", "active", "unused"}:
                continue
            credit_id = item.get("id")
            if credit_id is not None and (not isinstance(credit_id, str) or not credit_id):
                continue
            expires_at = _optional_timestamp(item.get("expiresAt"))
            if expires_at is not None and expires_at <= now:
                continue
            available.append(
                {
                    "credit_id": credit_id,
                    "expires_at": expires_at,
                }
            )
    if available:
        return min(
            available,
            key=lambda item: item["expires_at"]
            if item["expires_at"] is not None
            else float("inf"),
        )
    if (_optional_int(reset_credits.get("availableCount")) or 0) > 0:
        return {"credit_id": None, "expires_at": None}
    return None


def normalize_reset_credit_consume_response(response: dict | None) -> dict:
    value = response or {}
    if "error" in value:
        return {
            "ok": False,
            "outcome": None,
            "error": "reset credit consume failed",
        }
    result = value.get("result")
    outcome = result.get("outcome") if isinstance(result, dict) else None
    if not isinstance(outcome, str) or not outcome:
        return {
            "ok": False,
            "outcome": None,
            "error": "reset credit consume unavailable",
        }
    return {"ok": True, "outcome": outcome, "error": None}


def resolve_codex_binary(
    *,
    app_binary: Path = CODEX_APP_BINARY,
    legacy_app_binary: Path = LEGACY_CODEX_APP_BINARY,
    path_lookup: Callable[[str], str | None] = shutil.which,
) -> str | None:
    override = os.environ.get("CODEX_PROFILE_SWITCHER_CODEX")
    if override:
        return override
    for candidate in (app_binary, legacy_app_binary):
        if candidate.is_file():
            return str(candidate)
    return path_lookup("codex")


def _app_server_read_command(
    codex: str,
    profile_home: Path,
    *,
    sandbox_binary: Path = Path("/usr/bin/sandbox-exec"),
) -> list[str] | None:
    auth_link = profile_home / "auth.json"
    if not auth_link.is_symlink():
        return [codex, "app-server"]
    try:
        linked_auth = auth_link.readlink()
        if not linked_auth.is_absolute():
            linked_auth = auth_link.parent / linked_auth
        isolated_root = profile_home.resolve(strict=True)
        protected_roots = sorted(
            {
                str(linked_auth.parent.resolve(strict=True)),
                str(linked_auth.resolve(strict=True).parent),
            }
        )
    except OSError:
        return None
    if not sandbox_binary.is_file() or not os.access(sandbox_binary, os.X_OK):
        return None

    # Keep the root read-only so auth refresh cannot stage a credential copy.
    sqlite_names = (
        "goals_1.sqlite",
        "logs_2.sqlite",
        "memories_1.sqlite",
        "state_5.sqlite",
    )
    writable_files = [isolated_root / "installation_id"] + [
        isolated_root / suffix
        for name in sqlite_names
        for suffix in (
            name,
            f"{name}-journal",
            f"{name}-shm",
            f"{name}-wal",
        )
    ]
    profile = "(version 1)(allow default)" + "".join(
        f'(deny file-write* (subpath (param "CODEX_PROTECTED_{index}")))'
        for index in range(len(protected_roots))
    )
    profile += '(deny file-write* (subpath (param "CODEX_ISOLATED_HOME")))'
    profile += "".join(
        f'(allow file-write* (literal (param "CODEX_SCRATCH_{index}")))'
        for index in range(len(writable_files))
    )
    command = [str(sandbox_binary)]
    for index, root in enumerate(protected_roots):
        command += ["-D", f"CODEX_PROTECTED_{index}={root}"]
    command += ["-D", f"CODEX_ISOLATED_HOME={isolated_root}"]
    for index, path in enumerate(writable_files):
        command += ["-D", f"CODEX_SCRATCH_{index}={path}"]
    return command + ["-p", profile, codex, "app-server"]


def _stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def _consume_reset_credit_rpc(
    profile_home: Path,
    idempotency_key: str,
    credit_id: str | None,
    timeout_seconds: float,
) -> dict:
    if not idempotency_key.strip():
        raise ValueError("idempotency key must not be empty")
    codex = resolve_codex_binary()
    if not codex:
        return {"ok": False, "outcome": None, "error": "codex not found"}

    env = dict(os.environ)
    env["CODEX_HOME"] = str(profile_home)
    try:
        process = subprocess.Popen(
            [codex, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=env,
        )
    except OSError:
        return {"ok": False, "outcome": None, "error": "spawn failed"}

    response = None
    try:
        if process.stdin is None or process.stdout is None:
            return {
                "ok": False,
                "outcome": None,
                "error": "app-server pipe unavailable",
            }
        params = {"idempotencyKey": idempotency_key}
        if credit_id is not None:
            params["creditId"] = credit_id
        requests = [
            build_rpc_request(
                1,
                "initialize",
                {
                    "clientInfo": {"name": "codex-profile-switcher", "version": "0"},
                    "capabilities": {"experimentalApi": True},
                },
            ),
            {"jsonrpc": "2.0", "method": "initialized", "params": {}},
            build_rpc_request(2, "account/rateLimitResetCredit/consume", params),
        ]
        for request in requests:
            process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            wait = max(0.0, deadline - time.monotonic())
            events = selector.select(timeout=min(0.25, wait))
            if not events:
                if process.poll() is not None:
                    break
                continue
            line = process.stdout.readline()
            if not line:
                break
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("id") == 2:
                response = row
                break
        selector.close()
    finally:
        _stop_process(process)
        for stream in (process.stdin, process.stdout):
            if stream is not None:
                stream.close()
    return normalize_reset_credit_consume_response(response)


def consume_next_expiring_reset_credit(
    profile_home: Path,
    idempotency_key: str,
    *,
    timeout_seconds: float = 8.0,
    snapshot_reader: Callable[..., dict] | None = None,
    consumer: Callable[..., dict] | None = None,
    now_seconds: float | None = None,
) -> dict:
    reader = snapshot_reader or read_app_server_account_snapshot
    snapshot = reader(profile_home, timeout_seconds=timeout_seconds)
    if not snapshot.get("ok"):
        return {
            "ok": False,
            "outcome": None,
            "expires_at": None,
            "error": snapshot.get("error") or "rate limits unavailable",
        }
    selected = select_reset_credit_for_consumption(
        snapshot.get("rate_limits"),
        now_seconds=now_seconds,
    )
    if selected is None:
        return {
            "ok": True,
            "outcome": "noCredit",
            "expires_at": None,
            "error": None,
        }
    consume = consumer or _consume_reset_credit_rpc
    result = consume(
        profile_home,
        idempotency_key,
        selected["credit_id"],
        timeout_seconds,
    )
    return {
        "ok": bool(result.get("ok")),
        "outcome": result.get("outcome"),
        "expires_at": selected["expires_at"],
        "error": result.get("error"),
    }
def read_app_server_account_snapshot(
    profile_home: Path,
    timeout_seconds: float = 8.0,
) -> dict:
    if not (profile_home / "auth.json").is_file():
        return {
            "ok": False,
            "account": None,
            "rate_limits": None,
            "usage": None,
            "error": "authentication unavailable",
        }
    codex = resolve_codex_binary()
    if not codex:
        return {"ok": False, "account": None, "rate_limits": None, "usage": None, "error": "codex not found"}

    env = dict(os.environ)
    env["CODEX_HOME"] = str(profile_home)
    command = _app_server_read_command(codex, profile_home)
    if command is None:
        return {
            "ok": False,
            "account": None,
            "rate_limits": None,
            "usage": None,
            "error": "read-only sandbox unavailable",
        }
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=env,
        )
    except OSError:
        return {"ok": False, "account": None, "rate_limits": None, "usage": None, "error": "spawn failed"}

    responses: dict[int, dict] = {}
    try:
        requests = [
            build_rpc_request(
                1,
                "initialize",
                {
                    "clientInfo": {"name": "codex-profile-switcher", "version": "0"},
                    "capabilities": {"experimentalApi": True},
                },
            ),
            {"jsonrpc": "2.0", "method": "initialized", "params": {}},
            build_rpc_request(2, "account/read", {"refreshToken": False}),
            build_rpc_request(3, "account/rateLimits/read"),
            build_rpc_request(4, "account/usage/read"),
        ]
        if process.stdin is None or process.stdout is None:
            return {
                "ok": False,
                "account": None,
                "rate_limits": None,
                "usage": None,
                "error": "app-server pipe unavailable",
            }
        for request in requests:
            process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline and not {2, 3, 4}.issubset(responses):
            wait = max(0.0, deadline - time.monotonic())
            events = selector.select(timeout=min(0.25, wait))
            if not events:
                if process.poll() is not None:
                    break
                continue
            line = process.stdout.readline()
            if not line:
                break
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row.get("id"), int):
                responses[row["id"]] = row
        selector.close()
    finally:
        _stop_process(process)
        for stream in (process.stdin, process.stdout):
            if stream is not None:
                stream.close()

    account = responses.get(2) or {}
    rate_limits = responses.get(3) or {}
    usage = responses.get(4) or {}
    error = None
    if "error" in rate_limits:
        error = "rate limits unavailable"
    elif "result" not in rate_limits:
        error = "app-server timeout"
    return {
        "ok": error is None,
        "account": account.get("result"),
        "rate_limits": rate_limits.get("result"),
        "usage": usage.get("result"),
        "error": error,
    }


def read_reset_credit_details(
    profile_home: Path,
    timeout_seconds: float = 8.0,
) -> dict:
    snapshot = read_app_server_account_snapshot(profile_home, timeout_seconds=timeout_seconds)
    if not snapshot.get("ok"):
        return {"ok": False, "details": None, "error": snapshot.get("error")}
    details = normalize_rate_limits(snapshot.get("rate_limits"))["reset_credit_details"]
    return {
        "ok": bool(details.get("available")),
        "details": details,
        "error": None if details.get("available") else "reset credit details unavailable",
    }


def _remote_status_cache_path(shared_home: Path, profile_name: str) -> Path:
    safe_name = re.sub(r"[^A-Za-z0-9_.-]", "_", profile_name)
    return shared_home / "cache" / "codex-profile-switcher" / "remote-status" / f"{safe_name}.json"


def _reset_credit_details_cache_path(shared_home: Path, profile_name: str) -> Path:
    safe_name = re.sub(r"[^A-Za-z0-9_.-]", "_", profile_name)
    return (
        shared_home
        / "cache"
        / "codex-profile-switcher"
        / "reset-credit-details"
        / f"{safe_name}.json"
    )


def _write_remote_status_cache(
    shared_home: Path,
    profile_name: str,
    remote: dict,
    now_seconds: float,
) -> None:
    if not remote.get("ok") or not remote.get("rate_limits"):
        return
    path = _remote_status_cache_path(shared_home, profile_name)
    payload = {
        "cached_at": now_seconds,
        "account": remote.get("account"),
        "rate_limits": remote.get("rate_limits"),
        "usage": remote.get("usage"),
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path)
    except OSError:
        return


def _read_remote_status_cache(
    shared_home: Path,
    profile_name: str,
    now_seconds: float,
    max_age_seconds: int = REMOTE_STATUS_CACHE_SECONDS,
) -> dict | None:
    path = _remote_status_cache_path(shared_home, profile_name)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    cached_at = payload.get("cached_at")
    if not isinstance(cached_at, (int, float)):
        return None
    if now_seconds - cached_at > max_age_seconds:
        return None
    return {
        "ok": True,
        "account": payload.get("account"),
        "rate_limits": payload.get("rate_limits"),
        "usage": payload.get("usage"),
        "error": None,
        "stale": True,
        "cached_at": cached_at,
    }


def _read_remote_status_with_cache(
    profile: Path,
    shared_home: Path,
    remote_reader: Callable[[Path], dict],
    now_seconds: float,
    *,
    profile_name: str | None = None,
    cache_enabled: bool = True,
) -> dict:
    logical_name = profile_name or profile.name
    try:
        remote = remote_reader(profile)
    except Exception:
        remote = {
            "ok": False,
            "account": None,
            "rate_limits": None,
            "usage": None,
            "error": "status reader failed",
        }
    if remote.get("ok") and remote.get("rate_limits"):
        if cache_enabled:
            _write_remote_status_cache(shared_home, logical_name, remote, now_seconds)
        return {**remote, "stale": False, "cached_at": None}

    cached = (
        _read_remote_status_cache(shared_home, logical_name, now_seconds)
        if cache_enabled
        else None
    )
    if cached is not None:
        cached["error"] = remote.get("error")
        return cached
    return {**remote, "stale": False, "cached_at": None}


def _read_local_default_status_in_isolated_home(
    profile_home: Path,
    reader: Callable[[Path], dict],
) -> dict:
    source_auth = profile_home / "auth.json"
    if not source_auth.is_file():
        return {
            "ok": False,
            "account": None,
            "rate_limits": None,
            "usage": None,
            "error": "authentication unavailable",
        }

    with tempfile.TemporaryDirectory(prefix="codex-workbench-account-read-") as tmp:
        isolated_home = Path(tmp)
        isolated_home.chmod(0o700)
        destination_auth = isolated_home / "auth.json"
        destination_auth.symlink_to(source_auth.absolute())
        return reader(isolated_home)


def _write_reset_credit_details_cache(
    shared_home: Path,
    profile_name: str,
    details: dict,
    now_seconds: float,
) -> None:
    if not details.get("available"):
        return
    path = _reset_credit_details_cache_path(shared_home, profile_name)
    payload = {
        "cached_at": now_seconds,
        "details": details,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        tmp.replace(path)
    except OSError:
        return


def _read_reset_credit_details_cache(
    shared_home: Path,
    profile_name: str,
    now_seconds: float,
    *,
    expected_count: int | None = None,
    max_age_seconds: int | None = RESET_CREDIT_DETAILS_CACHE_SECONDS,
) -> dict | None:
    path = _reset_credit_details_cache_path(shared_home, profile_name)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    cached_at = payload.get("cached_at")
    details = payload.get("details")
    if not isinstance(cached_at, (int, float)) or not isinstance(details, dict):
        return None
    if max_age_seconds is not None and now_seconds - cached_at > max_age_seconds:
        return None
    if expected_count is not None and details.get("available_count") != expected_count:
        return None
    return {
        "ok": True,
        "details": details,
        "error": None,
        "stale": True,
        "cached_at": cached_at,
    }


def _read_reset_credit_details_with_cache(
    profile: Path,
    shared_home: Path,
    reset_credit_reader: Callable[[Path], dict],
    now_seconds: float,
    *,
    profile_name: str | None = None,
    cache_enabled: bool = True,
    expected_count: int | None = None,
    force_refresh: bool = False,
) -> dict:
    logical_name = profile_name or profile.name
    if cache_enabled and not force_refresh:
        cached = _read_reset_credit_details_cache(
            shared_home,
            logical_name,
            now_seconds,
            expected_count=expected_count,
        )
        if cached is not None:
            return cached
    try:
        remote = reset_credit_reader(profile)
    except Exception:
        remote = {"ok": False, "details": None, "error": "reset credit reader failed"}
    if remote.get("ok") and remote.get("details"):
        details = remote["details"]
        if cache_enabled:
            _write_reset_credit_details_cache(shared_home, logical_name, details, now_seconds)
        return {**remote, "stale": False, "cached_at": None}

    cached = (
        _read_reset_credit_details_cache(
            shared_home,
            logical_name,
            now_seconds,
            expected_count=None,
            max_age_seconds=None,
        )
        if cache_enabled
        else None
    )
    if cached is not None:
        cached["error"] = remote.get("error")
        return cached
    return {**remote, "stale": False, "cached_at": None}


def build_profiles_payload(
    profile_root: Path,
    shared_home: Path,
    read_remote: bool = True,
    remote_reader: Callable[[Path], dict] | None = None,
    reset_credit_reader: Callable[[Path], dict] | None = None,
    force_reset_credit_refresh: bool = False,
    active_profile: str | None = None,
    now_seconds: float | None = None,
) -> dict:
    from account_vault import AccountVault

    now = time.time() if now_seconds is None else now_seconds
    local_snapshot = read_local_token_snapshot(shared_home)
    thread_attribution = read_thread_attribution(shared_home)
    managed_paths = (
        sorted(path for path in profile_root.iterdir() if path.is_dir())
        if profile_root.exists()
        else []
    )
    legacy_profile_count = len(managed_paths)
    vault_snapshot = AccountVault(codex_home=shared_home).storage_snapshot()
    unified_accounts = (
        vault_snapshot.get("accounts", [])
        if vault_snapshot is not None
        else []
    )
    if unified_accounts:
        account_mode = "managed_profiles"
        account_sources = [
            (item["id"], item["path"])
            for item in unified_accounts
        ]
        effective_active_profile = vault_snapshot.get("active_account_id")
        storage_mode = "unified_vault"
        root_auth_kind = vault_snapshot.get("root_auth_kind", "unknown")
    elif managed_paths:
        account_mode = "managed_profiles"
        account_sources = [(path.name, path) for path in managed_paths]
        effective_active_profile = active_profile
        storage_mode = "legacy_profiles"
        root_auth_kind = (
            "symlink"
            if (shared_home / "auth.json").is_symlink()
            else "plain_file"
            if (shared_home / "auth.json").is_file()
            else "missing"
        )
    elif (shared_home / "auth.json").is_file():
        account_mode = "local_default"
        account_sources = [("local-default", shared_home)]
        effective_active_profile = "local-default"
        storage_mode = "local_default"
        root_auth_kind = "plain_file"
    else:
        account_mode = "unavailable"
        account_sources = []
        effective_active_profile = None
        storage_mode = "unavailable"
        root_auth_kind = (
            "symlink"
            if (shared_home / "auth.json").is_symlink()
            else "missing"
        )
    cache_enabled = account_mode == "managed_profiles"
    remote_by_name: dict[str, dict | None] = {}
    if read_remote and account_sources:
        base_reader = remote_reader or read_app_server_account_snapshot
        if account_mode == "local_default" or storage_mode == "unified_vault":
            reader = lambda home: _read_local_default_status_in_isolated_home(
                home,
                base_reader,
            )
        else:
            reader = base_reader
        with ThreadPoolExecutor(max_workers=min(4, len(account_sources))) as executor:
            futures = {
                executor.submit(
                    _read_remote_status_with_cache,
                    account_home,
                    shared_home,
                    reader,
                    now,
                    profile_name=account_name,
                    cache_enabled=cache_enabled,
                ): account_name
                for account_name, account_home in account_sources
            }
            for future in as_completed(futures):
                account_name = futures[future]
                remote_by_name[account_name] = future.result()

    reset_details_by_name: dict[str, dict | None] = {}
    fallback_accounts: list[tuple[str, Path]] = []
    for account_name, account_home in account_sources:
        remote = remote_by_name.get(account_name) or {}
        normalized_limits = normalize_rate_limits(remote.get("rate_limits") or {})
        embedded = normalized_limits["reset_credit_details"]
        if embedded.get("available"):
            reset_details_by_name[account_name] = {
                "ok": True,
                "details": embedded,
                "error": None,
                "stale": bool(remote.get("stale")),
                "cached_at": remote.get("cached_at"),
            }
        elif reset_credit_reader is not None:
            fallback_accounts.append((account_name, account_home))

    if read_remote and fallback_accounts and reset_credit_reader is not None:
        reader = reset_credit_reader
        with ThreadPoolExecutor(max_workers=min(4, len(fallback_accounts))) as executor:
            futures = {}
            for account_name, account_home in fallback_accounts:
                remote = remote_by_name.get(account_name)
                expected_count = normalize_rate_limits(
                    (remote or {}).get("rate_limits") or {}
                )["reset_credits"]["available_count"]
                futures[
                    executor.submit(
                        _read_reset_credit_details_with_cache,
                        account_home,
                        shared_home,
                        reader,
                        now,
                        profile_name=account_name,
                        cache_enabled=cache_enabled,
                        expected_count=expected_count,
                        force_refresh=force_reset_credit_refresh,
                    )
                ] = account_name
            for future in as_completed(futures):
                account_name = futures[future]
                reset_details_by_name[account_name] = future.result()

    profiles = []
    attribution_ledger = read_attribution_ledger(shared_home)
    if (
        effective_active_profile
        and not attribution_ledger.get("active_profile")
        and account_mode == "managed_profiles"
        and any(
            account_name == effective_active_profile
            for account_name, _ in account_sources
        )
    ):
        record_attribution_baseline(
            shared_home,
            effective_active_profile,
            local_snapshot,
            managed=True,
            now_seconds=now,
        )
        attribution_ledger = read_attribution_ledger(shared_home)
    for account_name, account_home in account_sources:
        remote = remote_by_name.get(account_name)
        reset_details = reset_details_by_name.get(account_name) or {}
        usage = (remote or {}).get("usage")
        normalized_limits = normalize_rate_limits(
            (remote or {}).get("rate_limits") or {}
        )
        profiles.append(
            {
                "name": account_name,
                "path": str(account_home),
                "auth": "present" if (account_home / "auth.json").is_file() else "missing",
                "config": "present" if (account_home / "config.toml").is_file() else "missing",
                "account": normalize_account((remote or {}).get("account")),
                "rate_limits": normalized_limits,
                "usage": usage,
                "usage_metrics": summarize_account_usage(
                    usage,
                    now=datetime.fromtimestamp(now, timezone.utc),
                ),
                "token_attribution": summarize_profile_attribution(
                    shared_home,
                    account_name,
                    local_snapshot,
                    usage,
                    now=datetime.fromtimestamp(now, timezone.utc),
                ),
                "reset_credit_details": reset_details.get("details"),
                "reset_credit_error": reset_details.get("error") if reset_details else None,
                "reset_credit_stale": bool(reset_details.get("stale")) if reset_details else False,
                "reset_credit_cached_at": reset_details.get("cached_at") if reset_details else None,
                "remote_error": (remote or {}).get("error") if remote else None,
                "remote_stale": bool((remote or {}).get("stale")),
                "remote_cached_at": (remote or {}).get("cached_at") if remote else None,
            }
        )
    task_role = infer_task_profile(
        shared_home,
        {profile["name"]: profile["rate_limits"] for profile in profiles},
        now_seconds=now,
    )
    if account_mode == "local_default":
        desktop_role = {
            "profile": "local-default",
            "source": "local_default",
            "confidence": "confirmed",
        }
    elif storage_mode == "unified_vault":
        desktop_role = {
            "profile": effective_active_profile,
            "source": "vault_state_expected"
            if effective_active_profile
            else "unavailable",
            "confidence": "inferred" if effective_active_profile else "unknown",
        }
    else:
        desktop_role = {
            "profile": effective_active_profile,
            "source": "desktop_bridge_expected"
            if effective_active_profile
            else "unavailable",
            "confidence": "inferred"
            if effective_active_profile
            else "unknown",
        }
    attribution_profile = attribution_ledger.get("active_profile")
    attribution_role = {
        "profile": attribution_profile,
        "source": "attribution_ledger" if attribution_profile else "unavailable",
        "confidence": "confirmed" if attribution_profile else "unknown",
    }
    roles_consistent = (
        task_role["profile"] == desktop_role["profile"]
        if task_role.get("profile") and desktop_role.get("profile")
        else None
    )
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "account_mode": account_mode,
        "active_profile": effective_active_profile,
        "profile_root": str(profile_root),
        "shared_home": str(shared_home),
        "account_storage": {
            "mode": storage_mode,
            "active_account_id": effective_active_profile,
            "account_count": len(account_sources),
            "root_auth_kind": root_auth_kind,
        },
        "legacy_migration": {
            "available": legacy_profile_count > 0,
            "profile_count": legacy_profile_count,
            "status": "completed"
            if storage_mode == "unified_vault"
            else "not_started"
            if legacy_profile_count > 0
            else "not_applicable",
            "requires_confirmation": legacy_profile_count > 0
            and storage_mode != "unavailable",
        },
        "local_snapshot": local_snapshot,
        "thread_attribution": thread_attribution,
        "history": read_sqlite_history_summary(shared_home),
        "project_rankings": read_project_rankings(shared_home),
        "tool_rankings": read_tool_rankings(shared_home),
        "skill_rankings": read_skill_rankings(shared_home),
        "attribution_summary": {
            "active_profile": attribution_ledger.get("active_profile"),
            "managed": bool(attribution_ledger.get("managed")),
        },
        "profile_roles": {
            "task": task_role,
            "desktop": desktop_role,
            "attribution": attribution_role,
            "task_matches_desktop": roles_consistent,
        },
        "profiles": profiles,
    }
