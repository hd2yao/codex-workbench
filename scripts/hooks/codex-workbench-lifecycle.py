#!/usr/bin/env python3
"""Append sanitized Codex lifecycle facts to the local workbench ledger."""

from __future__ import annotations

import datetime as dt
import fcntl
import json
import os
import re
import sys
import uuid
from pathlib import Path
from typing import Any


MAX_INPUT_BYTES = 1_048_576
SAFE_SESSION_ID = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
EVENTS = {
    "sessionstart": (
        "session_start",
        "Codex 会话已开始",
        "本机 Codex 生命周期 Hook 确认会话开始。",
    ),
    "stop": (
        "stop",
        "Codex 本轮已停止",
        "本机 Codex 生命周期 Hook 确认本轮执行停止。",
    ),
    "precompact": (
        "pre_compact",
        "Codex 准备压缩上下文",
        "本机 Codex 生命周期 Hook 确认上下文压缩即将发生。",
    ),
}


def utc_timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def event_from(payload: dict[str, Any]) -> dict[str, Any] | None:
    raw_name = payload.get("hook_event_name") or payload.get("event_name") or payload.get("event")
    if not isinstance(raw_name, str):
        return None
    normalized = raw_name.replace("_", "").replace("-", "").lower()
    definition = EVENTS.get(normalized)
    if definition is None:
        return None

    action_suffix, title, summary = definition
    session_id = payload.get("session_id")
    safe_session_id = (
        session_id
        if isinstance(session_id, str) and SAFE_SESSION_ID.fullmatch(session_id)
        else None
    )
    timestamp = utc_timestamp()
    event: dict[str, Any] = {
        "schema_version": 1,
        "id": f"lifecycle-{uuid.uuid4()}",
        "occurred_at": timestamp,
        "recorded_at": timestamp,
        "category": "hook",
        "action": f"codex_lifecycle_{action_suffix}",
        "title": title,
        "summary": summary,
        "status": "success",
        "importance": "routine",
        "certainty": "confirmed",
        "actor": {
            "type": "hook",
            "id": "codex-workbench-lifecycle",
            "label": "工作台生命周期采集",
        },
        "scope": "thread" if safe_session_id else "device",
        "source_chain": [],
        "evidence": [],
    }
    if safe_session_id:
        event["thread"] = {
            "id": safe_session_id,
            "title": None,
            "relation": "source",
        }
    return event


def append_event(event: dict[str, Any], home: Path) -> None:
    ledger_directory = home / ".codex" / "operation-ledger"
    ledger_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(ledger_directory, 0o700)
    except OSError:
        pass
    ledger = ledger_directory / "events.jsonl"
    encoded = (
        json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    descriptor = os.open(ledger, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.chmod(ledger, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.write(descriptor, encoded)
        os.fsync(descriptor)
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        if len(raw) > MAX_INPUT_BYTES:
            return 0
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            return 0
        event = event_from(payload)
        if event is not None:
            append_event(event, Path.home())
    except Exception:
        # Hook collection is best effort and must never block the Codex lifecycle.
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
