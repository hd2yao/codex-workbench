import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo


class DashboardNormalizationTests(unittest.TestCase):
    def test_reset_credit_reminders_cover_workday_afternoon_expiry(self):
        from codex_profile_dashboard import build_reset_credit_reminder_schedule

        expiry = datetime(2026, 7, 21, 15, 0, tzinfo=ZoneInfo("Asia/Shanghai"))
        result = build_reset_credit_reminder_schedule(expiry.timestamp())

        self.assertEqual(
            [
                (
                    item["kind"],
                    datetime.fromtimestamp(item["at"], ZoneInfo("Asia/Shanghai")),
                )
                for item in result
            ],
            [
                (
                    "previous_workday",
                    datetime(2026, 7, 20, 16, 30, tzinfo=ZoneInfo("Asia/Shanghai")),
                ),
                (
                    "same_day_morning",
                    datetime(2026, 7, 21, 9, 30, tzinfo=ZoneInfo("Asia/Shanghai")),
                ),
                (
                    "last_chance",
                    datetime(2026, 7, 21, 14, 0, tzinfo=ZoneInfo("Asia/Shanghai")),
                ),
            ],
        )

    def test_reset_credit_reminders_skip_same_morning_for_early_expiry(self):
        from codex_profile_dashboard import build_reset_credit_reminder_schedule

        expiry = datetime(2026, 7, 21, 8, 36, tzinfo=ZoneInfo("Asia/Shanghai"))
        result = build_reset_credit_reminder_schedule(expiry.timestamp())

        self.assertEqual(
            [item["kind"] for item in result],
            ["previous_workday", "last_chance"],
        )

    def test_reset_credit_reminders_move_monday_notice_to_friday(self):
        from codex_profile_dashboard import build_reset_credit_reminder_schedule

        expiry = datetime(2026, 7, 20, 12, 0, tzinfo=ZoneInfo("Asia/Shanghai"))
        result = build_reset_credit_reminder_schedule(expiry.timestamp())

        previous = datetime.fromtimestamp(result[0]["at"], ZoneInfo("Asia/Shanghai"))
        self.assertEqual(
            previous,
            datetime(2026, 7, 17, 16, 30, tzinfo=ZoneInfo("Asia/Shanghai")),
        )

    def test_reset_credit_reminders_move_weekend_notice_to_friday(self):
        from codex_profile_dashboard import build_reset_credit_reminder_schedule

        expiry = datetime(2026, 7, 19, 12, 0, tzinfo=ZoneInfo("Asia/Shanghai"))
        result = build_reset_credit_reminder_schedule(expiry.timestamp())

        self.assertEqual(
            [item["kind"] for item in result],
            ["previous_workday", "last_chance"],
        )
        previous = datetime.fromtimestamp(result[0]["at"], ZoneInfo("Asia/Shanghai"))
        self.assertEqual(
            previous,
            datetime(2026, 7, 17, 16, 30, tzinfo=ZoneInfo("Asia/Shanghai")),
        )

    def test_summarize_account_usage_marks_today_missing_when_account_data_lags(self):
        from datetime import datetime, timezone

        from codex_profile_dashboard import summarize_account_usage

        result = summarize_account_usage(
            {
                "dailyUsageBuckets": [
                    {"startDate": "2026-07-06", "tokens": 10},
                    {"startDate": "2026-07-07", "tokens": 20},
                    {"startDate": "2026-07-08", "tokens": 30},
                ]
            },
            now=datetime(2026, 7, 9, 1, 0, tzinfo=timezone.utc),
        )

        self.assertIsNone(result["today_tokens"])
        self.assertFalse(result["today_available"])
        self.assertEqual(result["latest_date"], "2026-07-08")
        self.assertEqual(result["last_7_tokens"], 60)
        self.assertEqual(result["last_14_tokens"], 60)


class TaskProfileInferenceTests(unittest.TestCase):
    def _write_state(self, shared: Path, rollout: Path, *, updated_at: int) -> None:
        import sqlite3

        conn = sqlite3.connect(shared / "state_5.sqlite")
        try:
            conn.execute(
                "create table threads (id text, rollout_path text, updated_at integer, archived integer, preview text)"
            )
            conn.execute(
                "insert into threads values (?, ?, ?, 0, 'visible task')",
                ("task-1", str(rollout), updated_at),
            )
            conn.commit()
        finally:
            conn.close()

    def _write_rollout(
        self,
        rollout: Path,
        *,
        timestamp: str,
        primary_reset: int,
        secondary_reset: int = 1784200000,
    ) -> None:
        rollout.parent.mkdir(parents=True, exist_ok=True)
        rollout.write_text(
            json.dumps(
                {
                    "timestamp": timestamp,
                    "payload": {
                        "type": "token_count",
                        "info": {
                            "total_token_usage": {"total_tokens": 1},
                            "rate_limits": {
                                "primary": {
                                    "window_minutes": 300,
                                    "resets_at": primary_reset,
                                    "used_percent": 12,
                                },
                                "secondary": {
                                    "window_minutes": 10080,
                                    "resets_at": secondary_reset,
                                    "used_percent": 34,
                                },
                            },
                        },
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def _profile_limits(primary_reset: int, secondary_reset: int = 1784200000) -> dict:
        return {
            "primary": {
                "window_minutes": 300,
                "resets_at": primary_reset,
                "remaining_percent": 88,
            },
            "secondary": {
                "window_minutes": 10080,
                "resets_at": secondary_reset,
                "remaining_percent": 66,
            },
        }

    def test_unique_exact_fingerprint_infers_task_profile(self):
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "rollout-task.jsonl"
            self._write_rollout(
                rollout,
                timestamp="2026-07-11T08:00:00Z",
                primary_reset=1783781285,
            )
            self._write_state(shared, rollout, updated_at=1783756800)

            result = infer_task_profile(
                shared,
                {
                    "hd-master": self._profile_limits(1783781285),
                    "hd-sarah-blackwell": self._profile_limits(1783782219),
                },
                now_seconds=1783757100,
            )

            self.assertEqual(result["profile"], "hd-master")
            self.assertEqual(result["source"], "recent_active_thread_rate_limit_match")
            self.assertEqual(result["confidence"], "inferred")
            self.assertEqual(result["thread_id"], "task-1")

    def test_small_reset_time_tolerance_still_matches(self):
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "rollout-task.jsonl"
            self._write_rollout(
                rollout,
                timestamp="2026-07-11T08:00:00Z",
                primary_reset=1783781285,
            )
            self._write_state(shared, rollout, updated_at=1783756800)

            result = infer_task_profile(
                shared,
                {"hd-master": self._profile_limits(1783781288)},
                now_seconds=1783757100,
            )

            self.assertEqual(result["profile"], "hd-master")

    def test_unique_single_weekly_window_infers_task_profile(self):
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "rollout-task.jsonl"
            rollout.parent.mkdir(parents=True, exist_ok=True)
            rollout.write_text(
                json.dumps(
                    {
                        "timestamp": "2026-07-13T08:00:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {"total_tokens": 1},
                                "rate_limits": {
                                    "primary": {
                                        "window_minutes": 10080,
                                        "resets_at": 1784513608,
                                        "used_percent": 4,
                                    },
                                    "secondary": None,
                                },
                            },
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            self._write_state(shared, rollout, updated_at=1783930000)

            result = infer_task_profile(
                shared,
                {
                    "hd-master": {
                        "primary": {
                            "window_minutes": 10080,
                            "resets_at": 1784513608,
                            "remaining_percent": 100,
                        },
                        "secondary": None,
                    },
                    "legacy-two-window": self._profile_limits(1784513608),
                },
                now_seconds=1783929900,
            )

            self.assertEqual(result["profile"], "hd-master")
            self.assertEqual(result["source"], "recent_active_thread_rate_limit_match")

    def test_single_window_fingerprint_does_not_match_two_window_profile(self):
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "rollout-task.jsonl"
            rollout.parent.mkdir(parents=True, exist_ok=True)
            rollout.write_text(
                json.dumps(
                    {
                        "timestamp": "2026-07-13T08:00:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {"total_tokens": 1},
                                "rate_limits": {
                                    "primary": {
                                        "window_minutes": 10080,
                                        "resets_at": 1784513608,
                                    }
                                },
                            },
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            self._write_state(shared, rollout, updated_at=1783930000)

            result = infer_task_profile(
                shared,
                {"legacy-two-window": self._profile_limits(1784513608)},
                now_seconds=1783929900,
            )

            self.assertIsNone(result["profile"])
            self.assertEqual(result["source"], "no_rate_limit_match")

    def test_no_matching_fingerprint_returns_unknown(self):
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "rollout-task.jsonl"
            self._write_rollout(
                rollout,
                timestamp="2026-07-11T08:00:00Z",
                primary_reset=1783781285,
            )
            self._write_state(shared, rollout, updated_at=1783756800)

            result = infer_task_profile(
                shared,
                {"other": self._profile_limits(1783790000)},
                now_seconds=1783757100,
            )

            self.assertIsNone(result["profile"])
            self.assertEqual(result["source"], "no_rate_limit_match")

    def test_multiple_matching_fingerprints_return_ambiguous(self):
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "rollout-task.jsonl"
            self._write_rollout(
                rollout,
                timestamp="2026-07-11T08:00:00Z",
                primary_reset=1783781285,
            )
            self._write_state(shared, rollout, updated_at=1783756800)

            result = infer_task_profile(
                shared,
                {
                    "account-a": self._profile_limits(1783781285),
                    "account-b": self._profile_limits(1783781285),
                },
                now_seconds=1783757100,
            )

            self.assertIsNone(result["profile"])
            self.assertEqual(result["source"], "ambiguous_rate_limit_match")

    def test_stale_rollout_returns_unknown_without_matching(self):
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "rollout-task.jsonl"
            self._write_rollout(
                rollout,
                timestamp="2026-07-11T06:00:00Z",
                primary_reset=1783781285,
            )
            self._write_state(shared, rollout, updated_at=1783749600)

            result = infer_task_profile(
                shared,
                {"hd-master": self._profile_limits(1783781285)},
                now_seconds=1783757100,
            )

            self.assertIsNone(result["profile"])
            self.assertEqual(result["source"], "stale_thread_rate_limits")

    def test_multiple_threads_use_most_recent_activity_and_report_thread_id(self):
        import sqlite3
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            older = shared / "sessions" / "rollout-older.jsonl"
            newer = shared / "sessions" / "rollout-newer.jsonl"
            self._write_rollout(older, timestamp="2026-07-11T07:58:00Z", primary_reset=1783781285)
            self._write_rollout(newer, timestamp="2026-07-11T08:00:00Z", primary_reset=1783782219)
            conn = sqlite3.connect(shared / "state_5.sqlite")
            try:
                conn.execute(
                    "create table threads (id text, rollout_path text, updated_at integer, archived integer, preview text)"
                )
                conn.execute("insert into threads values ('older', ?, 100, 0, 'visible')", (str(older),))
                conn.execute("insert into threads values ('newer-background', ?, 200, 0, 'visible')", (str(newer),))
                conn.commit()
            finally:
                conn.close()

            result = infer_task_profile(
                shared,
                {
                    "hd-master": self._profile_limits(1783781285),
                    "hd-sarah-blackwell": self._profile_limits(1783782219),
                },
                now_seconds=1783757100,
            )

            self.assertEqual(result["profile"], "hd-sarah-blackwell")
            self.assertEqual(result["thread_id"], "newer-background")
            self.assertEqual(result["source"], "recent_active_thread_rate_limit_match")

    def test_stale_newest_thread_does_not_fall_back_to_older_thread(self):
        import sqlite3
        from codex_profile_dashboard import infer_task_profile

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            older = shared / "sessions" / "rollout-older.jsonl"
            stale_newer = shared / "sessions" / "rollout-stale-newer.jsonl"
            self._write_rollout(older, timestamp="2026-07-11T08:00:00Z", primary_reset=1783781285)
            self._write_rollout(stale_newer, timestamp="2026-07-11T06:00:00Z", primary_reset=1783782219)
            conn = sqlite3.connect(shared / "state_5.sqlite")
            try:
                conn.execute(
                    "create table threads (id text, rollout_path text, updated_at integer, archived integer, preview text)"
                )
                conn.execute("insert into threads values ('older', ?, 100, 0, 'visible')", (str(older),))
                conn.execute("insert into threads values ('stale-background', ?, 200, 0, 'visible')", (str(stale_newer),))
                conn.commit()
            finally:
                conn.close()

            result = infer_task_profile(
                shared,
                {
                    "hd-master": self._profile_limits(1783781285),
                    "hd-sarah-blackwell": self._profile_limits(1783782219),
                },
                now_seconds=1783757100,
            )

            self.assertIsNone(result["profile"])
            self.assertEqual(result["thread_id"], "stale-background")
            self.assertEqual(result["source"], "stale_thread_rate_limits")

    def test_summarize_account_usage_uses_today_when_present(self):
        from datetime import datetime, timezone

        from codex_profile_dashboard import summarize_account_usage

        result = summarize_account_usage(
            {
                "dailyUsageBuckets": [
                    {"startDate": "2026-07-08", "tokens": 30},
                    {"startDate": "2026-07-09", "tokens": 45},
                ]
            },
            now=datetime(2026, 7, 9, 1, 0, tzinfo=timezone.utc),
        )

        self.assertEqual(result["today_tokens"], 45)
        self.assertTrue(result["today_available"])
        self.assertEqual(result["latest_date"], "2026-07-09")
        self.assertEqual(result["last_7_tokens"], 75)

    def test_normalize_reset_credit_details_masks_ids_and_parses_times(self):
        from codex_profile_dashboard import normalize_reset_credit_details

        result = normalize_reset_credit_details(
            {
                "available_count": 2,
                "total_earned_count": 4,
                "credits": [
                    {
                        "id": "RateLimitResetCredit-abcdef123456",
                        "status": "available",
                        "granted_at": "2026-06-18T00:36:51Z",
                        "expires_at": "2026-07-18T00:36:51Z",
                    },
                    {
                        "id": "RateLimitResetCredit-fedcba654321",
                        "status": "used",
                        "created_at": 1783000000,
                        "expiration_time": 1785600000000,
                        "used": True,
                    },
                ],
            }
        )

        self.assertTrue(result["available"])
        self.assertEqual(result["available_count"], 2)
        self.assertEqual(result["total_earned_count"], 4)
        self.assertEqual(result["earliest_expires_at"], 1784335011)
        self.assertEqual(result["credits"][0]["status"], "available")
        self.assertEqual(result["credits"][0]["granted_at"], 1781743011)
        self.assertEqual(result["credits"][0]["expires_at"], 1784335011)
        self.assertEqual(result["credits"][0]["used"], False)
        self.assertRegex(result["credits"][0]["id"], r"^Rate\.\.\.3456 hash:[0-9a-f]{10}$")
        self.assertNotIn("abcdef123456", result["credits"][0]["id"])
        self.assertEqual(result["credits"][1]["used"], True)

    def test_normalize_rate_limits_adds_remaining_percent(self):
        from codex_profile_dashboard import normalize_rate_limits

        payload = {
            "rateLimits": {
                "limitId": "codex",
                "limitName": "Codex",
                "planType": "plus",
                "primary": {
                    "usedPercent": 25,
                    "windowDurationMins": 300,
                    "resetsAt": 1782700000,
                },
                "secondary": None,
                "credits": {"availableCount": 2, "expiresAt": 1783000000},
            }
        }

        result = normalize_rate_limits(payload)

        self.assertEqual(result["limit_id"], "codex")
        self.assertEqual(result["limit_name"], "Codex")
        self.assertEqual(result["plan_type"], "plus")
        self.assertEqual(result["credits_available"], 2)
        self.assertEqual(result["reset_credits"]["available_count"], 2)
        self.assertEqual(result["reset_credits"]["expires_at"], 1783000000)
        self.assertEqual(result["primary"]["used_percent"], 25)
        self.assertEqual(result["primary"]["remaining_percent"], 75)
        self.assertEqual(result["primary"]["window_minutes"], 300)
        self.assertEqual(result["primary"]["resets_at"], 1782700000)
        self.assertIsNone(result["secondary"])

    def test_normalize_rate_limits_supports_current_credit_balance_shape(self):
        from codex_profile_dashboard import normalize_rate_limits

        payload = {
            "rateLimits": {
                "limitId": "codex",
                "planType": "plus",
                "credits": {"balance": 1, "hasCredits": True, "unlimited": False},
            }
        }

        result = normalize_rate_limits(payload)

        self.assertEqual(result["credits_available"], 1)
        self.assertEqual(result["reset_credits"]["available_count"], 1)
        self.assertTrue(result["reset_credits"]["has_credits"])
        self.assertFalse(result["reset_credits"]["unlimited"])

    def test_normalize_rate_limits_supports_top_level_reset_credits(self):
        from codex_profile_dashboard import normalize_rate_limits

        payload = {
            "rateLimits": {"limitId": "codex"},
            "rateLimitResetCredits": {
                "availableCount": 3,
                "expiresAt": 1783100000,
            },
        }

        result = normalize_rate_limits(payload)

        self.assertEqual(result["credits_available"], 3)
        self.assertEqual(result["reset_credits"]["available_count"], 3)
        self.assertEqual(result["reset_credits"]["expires_at"], 1783100000)

    def test_normalize_rate_limits_prefers_codex_bucket_and_embeds_credit_details(self):
        from codex_profile_dashboard import normalize_rate_limits

        payload = {
            "rateLimits": {"limitId": "legacy", "primary": {"usedPercent": 99}},
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "planType": "plus",
                    "primary": {"usedPercent": 20, "resetsAt": 1783700000},
                    "secondary": {"usedPercent": 30, "resetsAt": 1784200000},
                    "individualLimit": {
                        "used": "12.5",
                        "limit": "100",
                        "remainingPercent": 87,
                        "resetsAt": 1784300000,
                    },
                }
            },
            "rateLimitResetCredits": {
                "availableCount": 2,
                "credits": [
                    {
                        "id": "RateLimitResetCredit-abcdef123456",
                        "status": "available",
                        "resetType": "codexRateLimits",
                        "title": "Rate limit reset",
                        "description": "Available for 30 days",
                        "grantedAt": 1781743011,
                        "expiresAt": 1784335011,
                    }
                ],
            },
        }

        result = normalize_rate_limits(payload)

        self.assertEqual(result["limit_id"], "codex")
        self.assertEqual(result["primary"]["remaining_percent"], 80)
        self.assertEqual(result["secondary"]["remaining_percent"], 70)
        self.assertEqual(result["individual_limit"]["remaining_percent"], 87)
        self.assertEqual(result["individual_limit"]["resets_at"], 1784300000)
        self.assertEqual(result["reset_credits"]["available_count"], 2)
        details = result["reset_credit_details"]
        self.assertEqual(details["available_count"], 2)
        self.assertEqual(details["earliest_expires_at"], 1784335011)
        self.assertEqual(details["credits"][0]["reset_type"], "codexRateLimits")
        self.assertEqual(details["credits"][0]["title"], "Rate limit reset")
        self.assertEqual(details["credits"][0]["description"], "Available for 30 days")
        self.assertNotIn("abcdef123456", details["credits"][0]["id"])

    def test_normalize_account_exposes_status_without_email_value(self):
        from codex_profile_dashboard import normalize_account

        result = normalize_account(
            {
                "account": {
                    "type": "chatgpt",
                    "planType": "plus",
                    "email": "private@example.com",
                },
                "requiresOpenaiAuth": True,
            }
        )

        self.assertEqual(result["type"], "chatgpt")
        self.assertEqual(result["plan_type"], "plus")
        self.assertTrue(result["email_present"])
        self.assertTrue(result["requires_openai_auth"])
        self.assertNotIn("email", result)


class LocalTokenSnapshotTests(unittest.TestCase):
    def test_token_snapshot_keeps_thirty_daily_records_for_usage_trends(self):
        from codex_profile_dashboard import read_local_token_snapshot

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first_day = datetime(2026, 6, 25, 1, 0, 0)
            for offset in range(31):
                timestamp = first_day + timedelta(days=offset)
                rollout = (
                    root
                    / "sessions"
                    / timestamp.strftime("%Y")
                    / timestamp.strftime("%m")
                    / timestamp.strftime("%d")
                    / f"rollout-{offset:02d}.jsonl"
                )
                rollout.parent.mkdir(parents=True, exist_ok=True)
                rollout.write_text(
                    json.dumps(
                        {
                            "timestamp": timestamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
                            "payload": {
                                "type": "token_count",
                                "info": {
                                    "total_token_usage": {
                                        "total_tokens": offset + 1,
                                    }
                                },
                            },
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )

            result = read_local_token_snapshot(root)

            self.assertEqual(len(result["daily"]), 30)
            self.assertEqual(result["daily"][0]["date"], "2026-06-26")
            self.assertEqual(result["daily"][-1]["date"], "2026-07-25")

    def test_read_latest_token_count_snapshot(self):
        from codex_profile_dashboard import read_local_token_snapshot

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rollout = root / "sessions" / "2026" / "06" / "29" / "rollout-test.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.write_text(
                json.dumps(
                    {
                        "timestamp": "2026-06-29T01:00:00Z",
                        "payload": {
                            "type": "event_msg",
                            "message": {
                                "type": "token_count",
                                "info": {
                                    "total_token_usage": {
                                        "input_tokens": 10,
                                        "cached_input_tokens": 4,
                                        "output_tokens": 3,
                                        "reasoning_output_tokens": 2,
                                        "total_tokens": 15,
                                    },
                                    "rate_limits": {
                                        "limitId": "codex",
                                        "primary": {"usedPercent": 8},
                                    },
                                },
                            },
                        },
                    }
                )
                + "\n"
                + "{bad-json\n",
                encoding="utf-8",
            )

            result = read_local_token_snapshot(root)

            self.assertEqual(result["event_count"], 1)
            self.assertEqual(result["bad_line_count"], 1)
            self.assertEqual(result["total"]["input_tokens"], 10)
            self.assertEqual(result["total"]["cached_input_tokens"], 4)
            self.assertEqual(result["latest_timestamp"], "2026-06-29T01:00:00Z")
            self.assertEqual(result["rate_limits"]["primary"]["used_percent"], 8)
            self.assertEqual(result["daily"][0]["date"], "2026-06-29")
            self.assertEqual(result["daily"][0]["total_tokens"], 15)

    def test_token_snapshot_counts_only_latest_token_count_per_rollout(self):
        from codex_profile_dashboard import read_local_token_snapshot

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rollout = root / "sessions" / "2026" / "06" / "29" / "rollout-test.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.write_text(
                json.dumps(
                    {
                        "timestamp": "2026-06-29T01:00:00Z",
                        "type": "turn_context",
                        "payload": {"model": "gpt-5.5"},
                    }
                )
                + "\n"
                + json.dumps(
                    {
                        "timestamp": "2026-06-29T01:01:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {
                                    "input_tokens": 10,
                                    "cached_input_tokens": 4,
                                    "output_tokens": 3,
                                    "reasoning_output_tokens": 2,
                                    "total_tokens": 15,
                                }
                            },
                        },
                    }
                )
                + "\n"
                + json.dumps(
                    {
                        "timestamp": "2026-06-29T01:02:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {
                                    "input_tokens": 20,
                                    "cached_input_tokens": 8,
                                    "output_tokens": 6,
                                    "reasoning_output_tokens": 4,
                                    "total_tokens": 30,
                                }
                            },
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = read_local_token_snapshot(root)

            self.assertEqual(result["event_count"], 2)
            self.assertEqual(result["daily"], [{"date": "2026-06-29", **result["total"]}])
            self.assertEqual(result["by_model"][0]["model"], "gpt-5.5")
            self.assertEqual(result["by_model"][0]["total_tokens"], 30)

    def test_token_snapshot_skips_non_dict_messages(self):
        from codex_profile_dashboard import read_local_token_snapshot

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rollout = root / "sessions" / "2026" / "06" / "29" / "rollout-test.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.write_text(
                json.dumps({"payload": {"type": "event_msg", "message": "plain text"}})
                + "\n",
                encoding="utf-8",
            )

            result = read_local_token_snapshot(root)

            self.assertEqual(result["event_count"], 0)
            self.assertEqual(result["bad_line_count"], 0)

    def test_token_snapshot_skips_rollout_files_that_disappear_during_scan(self):
        from codex_profile_dashboard import read_local_token_snapshot

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rollout = root / "sessions" / "2026" / "07" / "06" / "rollout-vanished.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.symlink_to(root / "missing-rollout.jsonl")

            result = read_local_token_snapshot(root)

            self.assertEqual(result["event_count"], 0)
            self.assertEqual(result["bad_line_count"], 0)


class ThreadAttributionTests(unittest.TestCase):
    @staticmethod
    def _write_rollout(
        root: Path,
        filename: str,
        *,
        thread_id: str | None,
        parent_thread_id: str | None = None,
        legacy_parent_thread_id: str | None = None,
        forked_from_id: str | None = None,
        usage: dict | None,
        bad_line: bool = False,
    ) -> None:
        rollout = root / "sessions" / "2026" / "07" / filename
        rollout.parent.mkdir(parents=True, exist_ok=True)
        rows = []
        if thread_id is not None:
            source = {}
            if parent_thread_id is not None:
                source = {
                    "subagent": {
                        "thread_spawn": {
                            "parent_thread_id": parent_thread_id,
                            "depth": 1,
                        }
                    }
                }
            session_meta = {
                "id": thread_id,
                "source": source,
            }
            if legacy_parent_thread_id is not None:
                session_meta["parent_thread_id"] = legacy_parent_thread_id
            if forked_from_id is not None:
                session_meta["forked_from_id"] = forked_from_id
            rows.append({"type": "session_meta", "payload": session_meta})
        if usage is not None:
            rows.append(
                {
                    "timestamp": "2026-07-30T01:00:00Z",
                    "payload": {
                        "type": "token_count",
                        "info": {"total_token_usage": usage},
                    },
                }
            )
        text = "\n".join(json.dumps(row) for row in rows) + ("\n" if rows else "")
        if bad_line:
            text += "{broken-json\n"
        rollout.write_text(text, encoding="utf-8")

    def test_parent_direct_and_indirect_children_are_grouped_with_breakdowns(self):
        from codex_profile_dashboard import read_thread_attribution

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_rollout(
                root,
                "rollout-parent.jsonl",
                thread_id="parent",
                usage={
                    "input_tokens": 100,
                    "cached_input_tokens": 40,
                    "output_tokens": 10,
                    "reasoning_output_tokens": 5,
                    "total_tokens": 115,
                },
            )
            self._write_rollout(
                root,
                "rollout-child.jsonl",
                thread_id="child",
                parent_thread_id="parent",
                forked_from_id="parent",
                usage={
                    "input_tokens": 200,
                    "cached_input_tokens": 160,
                    "output_tokens": 20,
                    "reasoning_output_tokens": 10,
                    "total_tokens": 230,
                },
            )
            self._write_rollout(
                root,
                "rollout-grandchild.jsonl",
                thread_id="grandchild",
                parent_thread_id="child",
                usage={
                    "input_tokens": 50,
                    "cached_input_tokens": 0,
                    "output_tokens": 10,
                    "reasoning_output_tokens": 5,
                    "total_tokens": 65,
                },
            )

            result = read_thread_attribution(root)

        self.assertEqual(result["top_level_task_count"], 1)
        task = result["tasks"][0]
        self.assertEqual(task["thread_id"], "parent")
        self.assertEqual(task["child_task_count"], 2)
        self.assertEqual(task["fork_child_count"], 1)
        self.assertEqual(task["own_tokens"]["total_tokens"], 115)
        self.assertEqual(task["child_tokens"]["total_tokens"], 295)
        self.assertEqual(task["merged_tokens"]["total_tokens"], 410)
        self.assertEqual(task["own_tokens"]["non_cached_input_tokens"], 60)
        self.assertEqual(task["child_tokens"]["non_cached_input_tokens"], 90)
        self.assertEqual(task["children"][1]["depth"], 2)

    def test_missing_parent_and_missing_metadata_are_kept_separate(self):
        from codex_profile_dashboard import read_thread_attribution

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_rollout(
                root,
                "rollout-orphan.jsonl",
                thread_id="orphan",
                parent_thread_id="does-not-exist",
                usage={"total_tokens": 12},
            )
            self._write_rollout(
                root,
                "rollout-no-meta.jsonl",
                thread_id=None,
                usage={"total_tokens": 8},
                bad_line=True,
            )

            result = read_thread_attribution(root)

        self.assertEqual(result["top_level_task_count"], 2)
        statuses = {task["status"] for task in result["tasks"]}
        self.assertIn("missing_parent", statuses)
        self.assertIn("missing_metadata", statuses)
        self.assertGreaterEqual(result["bad_line_count"], 1)
        self.assertGreaterEqual(result["risk_counts"]["data_quality"], 2)

    def test_cached_input_is_clamped_and_risk_thresholds_are_explicit(self):
        from codex_profile_dashboard import (
            THREAD_CHILD_SHARE_WARNING_THRESHOLD,
            THREAD_FORK_CACHED_INPUT_WARNING_THRESHOLD,
            read_thread_attribution,
        )

        self.assertEqual(THREAD_CHILD_SHARE_WARNING_THRESHOLD, 0.80)
        self.assertEqual(THREAD_FORK_CACHED_INPUT_WARNING_THRESHOLD, 0.75)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_rollout(
                root,
                "rollout-small-parent.jsonl",
                thread_id="small-parent",
                usage={"input_tokens": 10, "cached_input_tokens": 20, "total_tokens": 10},
            )
            self._write_rollout(
                root,
                "rollout-small-child.jsonl",
                thread_id="small-child",
                parent_thread_id="small-parent",
                forked_from_id="small-parent",
                usage={"input_tokens": 90, "cached_input_tokens": 80, "total_tokens": 90},
            )

            result = read_thread_attribution(root)

        task = result["tasks"][0]
        self.assertEqual(task["own_tokens"]["non_cached_input_tokens"], 0)
        self.assertTrue(task["child_share_abnormal"])
        self.assertTrue(task["full_context_fork_risk"])
        self.assertEqual(result["risk_counts"]["child_share"], 1)
        self.assertEqual(result["risk_counts"]["full_context_fork"], 1)

    def test_relationship_cycle_is_grouped_once_with_data_quality_warning(self):
        from codex_profile_dashboard import read_thread_attribution

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_rollout(
                root,
                "rollout-cycle-a.jsonl",
                thread_id="cycle-a",
                parent_thread_id="cycle-b",
                usage={"total_tokens": 10},
            )
            self._write_rollout(
                root,
                "rollout-cycle-b.jsonl",
                thread_id="cycle-b",
                parent_thread_id="cycle-a",
                usage={"total_tokens": 20},
            )

            result = read_thread_attribution(root)

        self.assertEqual(result["top_level_task_count"], 1)
        self.assertEqual(result["tasks"][0]["status"], "cycle")
        self.assertEqual(result["tasks"][0]["merged_tokens"]["total_tokens"], 30)
        self.assertEqual(result["risk_counts"]["data_quality"], 1)

    def test_legacy_parent_field_is_supported_and_marked(self):
        from codex_profile_dashboard import read_thread_attribution

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_rollout(
                root,
                "rollout-legacy-parent.jsonl",
                thread_id="legacy-child",
                legacy_parent_thread_id="legacy-parent",
                usage={"total_tokens": 7},
            )
            self._write_rollout(
                root,
                "rollout-legacy-root.jsonl",
                thread_id="legacy-parent",
                usage={"total_tokens": 3},
            )

            result = read_thread_attribution(root)

        self.assertEqual(result["tasks"][0]["child_task_count"], 1)
        self.assertEqual(result["tasks"][0]["children"][0]["metadata_status"], "legacy_parent_field")


class TokenAttributionTests(unittest.TestCase):
    def test_record_attribution_baseline_writes_active_profile_snapshot(self):
        from codex_profile_dashboard import (
            read_attribution_ledger,
            record_attribution_baseline,
        )

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            record_attribution_baseline(
                shared,
                "account-a",
                {"total": {"total_tokens": 100}, "latest_timestamp": "2026-07-09T01:00:00Z"},
                managed=True,
                now_seconds=1000,
            )

            ledger = read_attribution_ledger(shared)

            self.assertEqual(ledger["active_profile"], "account-a")
            self.assertEqual(ledger["baseline"]["total_tokens"], 100)
            self.assertEqual(ledger["baseline"]["latest_timestamp"], "2026-07-09T01:00:00Z")
            self.assertTrue(ledger["managed"])

    def test_summarize_profile_attribution_estimates_today_from_switch_delta(self):
        from datetime import datetime, timezone

        from codex_profile_dashboard import (
            record_attribution_baseline,
            summarize_profile_attribution,
        )

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            record_attribution_baseline(
                shared,
                "account-a",
                {"total": {"total_tokens": 100}},
                managed=True,
                now_seconds=1783584000,
            )

            result = summarize_profile_attribution(
                shared,
                "account-a",
                {"total": {"total_tokens": 165}},
                {"dailyUsageBuckets": [{"startDate": "2026-07-08", "tokens": 40}]},
                now=datetime(2026, 7, 9, 4, 0, tzinfo=timezone.utc),
            )

            self.assertEqual(result["today_estimated_tokens"], 65)
            self.assertEqual(result["today_display_tokens"], 65)
            self.assertEqual(result["today_source"], "attribution_estimate")
            self.assertTrue(result["estimate_available"])
            self.assertEqual(result["active_profile"], "account-a")

    def test_summarize_profile_attribution_uses_official_today_when_available(self):
        from datetime import datetime, timezone

        from codex_profile_dashboard import (
            record_attribution_baseline,
            summarize_profile_attribution,
        )

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            record_attribution_baseline(
                shared,
                "account-a",
                {"total": {"total_tokens": 100}},
                managed=True,
                now_seconds=1783584000,
            )

            result = summarize_profile_attribution(
                shared,
                "account-a",
                {"total": {"total_tokens": 165}},
                {"dailyUsageBuckets": [{"startDate": "2026-07-09", "tokens": 72}]},
                now=datetime(2026, 7, 9, 4, 0, tzinfo=timezone.utc),
            )

            self.assertEqual(result["today_display_tokens"], 72)
            self.assertEqual(result["today_source"], "official")
            self.assertEqual(result["today_estimated_tokens"], 65)

    def test_summarize_profile_attribution_compares_previous_official_day(self):
        from datetime import datetime, timezone

        from codex_profile_dashboard import (
            record_attribution_baseline,
            summarize_profile_attribution,
        )

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            record_attribution_baseline(
                shared,
                "account-a",
                {"total": {"total_tokens": 100}},
                managed=True,
                now_seconds=1783497600,
            )
            record_attribution_baseline(
                shared,
                "account-b",
                {"total": {"total_tokens": 165}},
                managed=True,
                now_seconds=1783501200,
            )

            result = summarize_profile_attribution(
                shared,
                "account-a",
                {"total": {"total_tokens": 165}},
                {
                    "dailyUsageBuckets": [
                        {"startDate": "2026-07-08", "tokens": 60},
                    ]
                },
                now=datetime(2026, 7, 9, 4, 0, tzinfo=timezone.utc),
            )

            accuracy = result["previous_day_accuracy"]
            self.assertEqual(accuracy["date"], "2026-07-08")
            self.assertEqual(accuracy["estimated_tokens"], 65)
            self.assertEqual(accuracy["official_tokens"], 60)
            self.assertEqual(accuracy["delta_tokens"], 5)
            self.assertAlmostEqual(accuracy["delta_percent"], 8.333333333333332)

    def test_summarize_profile_attribution_does_not_attribute_unmanaged_usage(self):
        from datetime import datetime, timezone

        from codex_profile_dashboard import (
            record_attribution_baseline,
            summarize_profile_attribution,
        )

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            record_attribution_baseline(
                shared,
                "account-a",
                {"total": {"total_tokens": 100}},
                managed=False,
                now_seconds=1000,
            )

            result = summarize_profile_attribution(
                shared,
                "account-a",
                {"total": {"total_tokens": 165}},
                None,
                now=datetime(2026, 7, 9, 4, 0, tzinfo=timezone.utc),
            )

            self.assertIsNone(result["today_estimated_tokens"])
            self.assertFalse(result["estimate_available"])
            self.assertEqual(result["today_source"], "unavailable")


class AppServerClientTests(unittest.TestCase):
    def test_build_rpc_request(self):
        from codex_profile_dashboard import build_rpc_request

        self.assertEqual(
            build_rpc_request(3, "account/rateLimits/read"),
            {"jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read"},
        )

    def test_read_only_app_server_command_protects_auth_source_roots(self):
        from codex_profile_dashboard import _app_server_read_command

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            default_home = root / "default" / ".codex"
            managed_home = root / "profiles" / "account-a"
            isolated_home = root / "isolated"
            sandbox = root / "sandbox-exec"
            codex = root / "codex"
            default_home.mkdir(parents=True)
            managed_home.mkdir(parents=True)
            isolated_home.mkdir()
            sandbox.write_text("", encoding="utf-8")
            sandbox.chmod(0o700)
            codex.write_text("", encoding="utf-8")
            managed_auth = managed_home / "auth.json"
            managed_auth.write_text("secret-token", encoding="utf-8")
            default_auth = default_home / "auth.json"
            default_auth.symlink_to(managed_auth)
            (isolated_home / "auth.json").symlink_to(default_auth)

            command = _app_server_read_command(
                str(codex),
                isolated_home,
                sandbox_binary=sandbox,
            )

            self.assertIsNotNone(command)
            self.assertEqual(command[0], str(sandbox))
            self.assertEqual(command[-2:], [str(codex), "app-server"])
            protected = {
                item.split("=", 1)[1]
                for item in command
                if item.startswith("CODEX_PROTECTED_")
            }
            self.assertEqual(
                protected,
                {str(default_home.resolve()), str(managed_home.resolve())},
            )
            self.assertIn("deny file-write*", command[command.index("-p") + 1])
            self.assertNotIn("secret-token", " ".join(command))

    def test_read_only_app_server_command_fails_closed_without_sandbox(self):
        from codex_profile_dashboard import _app_server_read_command

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_home = root / "source"
            isolated_home = root / "isolated"
            source_home.mkdir()
            isolated_home.mkdir()
            source_auth = source_home / "auth.json"
            source_auth.write_text("{}", encoding="utf-8")
            (isolated_home / "auth.json").symlink_to(source_auth)

            command = _app_server_read_command(
                "/usr/bin/codex",
                isolated_home,
                sandbox_binary=root / "missing-sandbox",
            )

            self.assertIsNone(command)

    def test_read_only_app_server_sandbox_blocks_source_home_writes(self):
        import subprocess

        from codex_profile_dashboard import _app_server_read_command

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_home = root / "source"
            isolated_home = root / "isolated"
            source_home.mkdir()
            isolated_home.mkdir()
            source_auth = source_home / "auth.json"
            source_auth.write_text("{}", encoding="utf-8")
            (isolated_home / "auth.json").symlink_to(source_auth)
            blocked = source_home / "blocked"
            command = _app_server_read_command("/usr/bin/true", isolated_home)

            self.assertIsNotNone(command)
            result = subprocess.run(
                command[:-2] + ["/usr/bin/touch", str(blocked)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(blocked.exists())

    def test_read_only_app_server_sandbox_blocks_atomic_auth_replacement(self):
        import subprocess

        from codex_profile_dashboard import _app_server_read_command

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_home = root / "source"
            isolated_home = root / "isolated"
            source_home.mkdir()
            isolated_home.mkdir()
            source_auth = source_home / "auth.json"
            source_auth.write_text("original-secret", encoding="utf-8")
            isolated_auth = isolated_home / "auth.json"
            isolated_auth.symlink_to(source_auth)
            replacement = isolated_home / "auth.json.new"
            command = _app_server_read_command("/usr/bin/true", isolated_home)

            self.assertIsNotNone(command)
            result = subprocess.run(
                command[:-2]
                + [
                    "/bin/sh",
                    "-c",
                    'printf %s "$1" > "$2" && /bin/mv "$2" "$3"',
                    "sandbox-auth-replacement",
                    "credential-copy",
                    str(replacement),
                    str(isolated_auth),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(isolated_auth.is_symlink())
            self.assertFalse(replacement.exists())
            self.assertEqual(source_auth.read_text(encoding="utf-8"), "original-secret")

    def test_read_only_app_server_sandbox_only_allows_known_scratch_files(self):
        import subprocess

        from codex_profile_dashboard import _app_server_read_command

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_home = root / "source"
            isolated_home = root / "isolated"
            source_home.mkdir()
            isolated_home.mkdir()
            source_auth = source_home / "auth.json"
            source_auth.write_text("{}", encoding="utf-8")
            (isolated_home / "auth.json").symlink_to(source_auth)
            allowed = isolated_home / "state_5.sqlite"
            blocked = isolated_home / "unexpected-credential-stage"
            command = _app_server_read_command("/usr/bin/true", isolated_home)

            self.assertIsNotNone(command)
            allowed_result = subprocess.run(
                command[:-2] + ["/usr/bin/touch", str(allowed)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            blocked_result = subprocess.run(
                command[:-2] + ["/usr/bin/touch", str(blocked)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            self.assertEqual(allowed_result.returncode, 0)
            self.assertTrue(allowed.exists())
            self.assertNotEqual(blocked_result.returncode, 0)
            self.assertFalse(blocked.exists())

    def test_app_server_command_keeps_managed_profile_behavior(self):
        from codex_profile_dashboard import _app_server_read_command

        with tempfile.TemporaryDirectory() as tmp:
            profile = Path(tmp)
            (profile / "auth.json").write_text("{}", encoding="utf-8")

            self.assertEqual(
                _app_server_read_command("/usr/bin/codex", profile),
                ["/usr/bin/codex", "app-server"],
            )

    def test_select_reset_credit_prefers_earliest_available_expiry(self):
        from codex_profile_dashboard import select_reset_credit_for_consumption

        selected = select_reset_credit_for_consumption(
            {
                "rateLimitResetCredits": {
                    "availableCount": 3,
                    "credits": [
                        {
                            "id": "credit-later",
                            "status": "available",
                            "expiresAt": 1785110610,
                        },
                        {
                            "id": "credit-used",
                            "status": "used",
                            "expiresAt": 1784000000,
                        },
                        {
                            "id": "credit-earlier",
                            "status": "available",
                            "expiresAt": 1784335011,
                        },
                    ],
                }
            },
            now_seconds=1783000000,
        )

        self.assertEqual(selected["credit_id"], "credit-earlier")
        self.assertEqual(selected["expires_at"], 1784335011)

    def test_consume_next_expiring_credit_keeps_opaque_id_inside_adapter(self):
        from codex_profile_dashboard import consume_next_expiring_reset_credit

        calls = []

        def snapshot_reader(_profile, timeout_seconds):
            self.assertEqual(timeout_seconds, 4.0)
            return {
                "ok": True,
                "rate_limits": {
                    "rateLimitResetCredits": {
                        "availableCount": 2,
                        "credits": [
                            {
                                "id": "private-later-id",
                                "status": "available",
                                "expiresAt": 1785110610,
                            },
                            {
                                "id": "private-earlier-id",
                                "status": "available",
                                "expiresAt": 1784335011,
                            },
                        ],
                    }
                },
            }

        def consumer(profile, idempotency_key, credit_id, timeout_seconds):
            calls.append((profile, idempotency_key, credit_id, timeout_seconds))
            return {"ok": True, "outcome": "reset", "error": None}

        result = consume_next_expiring_reset_credit(
            Path("/tmp/profile-a"),
            "stable-idempotency-key",
            timeout_seconds=4.0,
            snapshot_reader=snapshot_reader,
            consumer=consumer,
            now_seconds=1783000000,
        )

        self.assertEqual(
            calls,
            [
                (
                    Path("/tmp/profile-a"),
                    "stable-idempotency-key",
                    "private-earlier-id",
                    4.0,
                )
            ],
        )
        self.assertEqual(
            result,
            {
                "ok": True,
                "outcome": "reset",
                "expires_at": 1784335011,
                "error": None,
            },
        )
        self.assertNotIn("private-earlier-id", json.dumps(result))

    def test_normalize_consume_outcome_preserves_official_states(self):
        from codex_profile_dashboard import normalize_reset_credit_consume_response

        for outcome in ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"]:
            with self.subTest(outcome=outcome):
                self.assertEqual(
                    normalize_reset_credit_consume_response(
                        {"result": {"outcome": outcome}}
                    ),
                    {"ok": True, "outcome": outcome, "error": None},
                )

    def test_resolve_codex_binary_prefers_app_bundle_binary(self):
        from codex_profile_dashboard import resolve_codex_binary

        with tempfile.TemporaryDirectory() as tmp:
            bundled = Path(tmp) / "Codex.app" / "Contents" / "Resources" / "codex"
            bundled.parent.mkdir(parents=True)
            bundled.write_text("#!/bin/sh\n", encoding="utf-8")

            result = resolve_codex_binary(
                app_binary=bundled,
                path_lookup=lambda _: "/opt/homebrew/bin/codex",
            )

            self.assertEqual(result, str(bundled))

    def test_resolve_codex_binary_prefers_chatgpt_bundle_over_legacy_codex(self):
        from codex_profile_dashboard import resolve_codex_binary

        with tempfile.TemporaryDirectory() as tmp:
            chatgpt = Path(tmp) / "ChatGPT.app" / "Contents" / "Resources" / "codex"
            legacy = Path(tmp) / "Codex.app" / "Contents" / "Resources" / "codex"
            chatgpt.parent.mkdir(parents=True)
            legacy.parent.mkdir(parents=True)
            chatgpt.write_text("#!/bin/sh\n", encoding="utf-8")
            legacy.write_text("#!/bin/sh\n", encoding="utf-8")

            result = resolve_codex_binary(
                app_binary=chatgpt,
                legacy_app_binary=legacy,
                path_lookup=lambda _: "/opt/homebrew/bin/codex",
            )

            self.assertEqual(result, str(chatgpt))

    def test_resolve_codex_binary_falls_back_to_legacy_codex_bundle(self):
        from codex_profile_dashboard import resolve_codex_binary

        with tempfile.TemporaryDirectory() as tmp:
            chatgpt = Path(tmp) / "ChatGPT.app" / "Contents" / "Resources" / "codex"
            legacy = Path(tmp) / "Codex.app" / "Contents" / "Resources" / "codex"
            legacy.parent.mkdir(parents=True)
            legacy.write_text("#!/bin/sh\n", encoding="utf-8")

            result = resolve_codex_binary(
                app_binary=chatgpt,
                legacy_app_binary=legacy,
                path_lookup=lambda _: "/opt/homebrew/bin/codex",
            )

            self.assertEqual(result, str(legacy))


class ProfileApiTests(unittest.TestCase):
    @staticmethod
    def remote_snapshot(remaining=43):
        return {
            "ok": True,
            "account": {
                "account": {"type": "chatgpt", "planType": "plus", "email": None},
                "requiresOpenaiAuth": True,
            },
            "rate_limits": {
                "rateLimits": {
                    "limitId": "codex",
                    "planType": "plus",
                    "primary": {"usedPercent": 100 - remaining},
                }
            },
            "usage": None,
            "error": None,
        }

    def test_default_home_becomes_read_only_local_account_when_profiles_are_absent(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_root = root / ".codex-profiles"
            shared_home = root / ".codex"
            shared_home.mkdir()
            auth = shared_home / "auth.json"
            auth.write_text("{}", encoding="utf-8")
            before = sorted(path.relative_to(shared_home) for path in shared_home.rglob("*"))
            remote_homes = []

            def read_isolated_remote(home):
                remote_homes.append(home)
                self.assertNotEqual(home, shared_home)
                self.assertTrue((home / "auth.json").is_symlink())
                self.assertEqual((home / "auth.json").readlink(), auth)
                self.assertEqual((home / "auth.json").resolve(), auth.resolve())
                (home / "state_5.sqlite").write_text("isolated", encoding="utf-8")
                return self.remote_snapshot(remaining=43)

            payload = build_profiles_payload(
                profile_root,
                shared_home,
                remote_reader=read_isolated_remote,
            )

            self.assertEqual(payload["account_mode"], "local_default")
            self.assertEqual(payload["active_profile"], "local-default")
            self.assertEqual([row["name"] for row in payload["profiles"]], ["local-default"])
            self.assertEqual(payload["profiles"][0]["path"], str(shared_home))
            self.assertEqual(
                payload["profiles"][0]["rate_limits"]["primary"]["remaining_percent"],
                43,
            )
            self.assertEqual(len(remote_homes), 1)
            self.assertFalse(remote_homes[0].exists())
            self.assertEqual(
                before,
                sorted(path.relative_to(shared_home) for path in shared_home.rglob("*")),
            )
            self.assertFalse(auth.is_symlink())
            self.assertEqual(auth.read_text(encoding="utf-8"), "{}")
            self.assertFalse(profile_root.exists())
            self.assertEqual(payload["account_storage"]["mode"], "local_default")
            self.assertFalse(payload["legacy_migration"]["available"])

    def test_app_server_snapshot_does_not_spawn_without_local_auth(self):
        from codex_profile_dashboard import read_app_server_account_snapshot

        with tempfile.TemporaryDirectory() as tmp:
            shared_home = Path(tmp) / ".codex"
            shared_home.mkdir()
            with (
                mock.patch(
                    "codex_profile_dashboard.resolve_codex_binary",
                    return_value="/usr/bin/codex",
                ),
                mock.patch(
                    "codex_profile_dashboard.subprocess.Popen",
                    side_effect=AssertionError("app-server must not start without auth"),
                ) as popen,
            ):
                result = read_app_server_account_snapshot(shared_home)

            self.assertFalse(result["ok"])
            self.assertEqual(result["error"], "authentication unavailable")
            popen.assert_not_called()

    def test_empty_profile_root_without_auth_is_unavailable(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_root = root / ".codex-profiles"
            shared_home = root / ".codex"
            profile_root.mkdir()
            shared_home.mkdir()

            payload = build_profiles_payload(profile_root, shared_home, read_remote=False)

            self.assertEqual(payload["account_mode"], "unavailable")
            self.assertIsNone(payload["active_profile"])
            self.assertEqual(payload["profiles"], [])

    def test_existing_profiles_keep_managed_mode_and_physical_paths(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_root = root / ".codex-profiles"
            shared_home = root / ".codex"
            profile = profile_root / "account-a"
            profile.mkdir(parents=True)
            shared_home.mkdir()

            payload = build_profiles_payload(
                profile_root,
                shared_home,
                read_remote=False,
                active_profile="account-a",
            )

            self.assertEqual(payload["account_mode"], "managed_profiles")
            self.assertEqual(payload["active_profile"], "account-a")
            self.assertEqual([row["name"] for row in payload["profiles"]], ["account-a"])
            self.assertEqual(payload["profiles"][0]["path"], str(profile))
            self.assertEqual(payload["account_storage"]["mode"], "legacy_profiles")
            self.assertTrue(payload["legacy_migration"]["available"])
            self.assertEqual(payload["legacy_migration"]["profile_count"], 1)

    def test_unified_vault_wins_over_legacy_profiles_and_reads_snapshots_in_isolation(self):
        from account_vault import AccountVault
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile_root = root / ".codex-profiles"
            legacy = profile_root / "legacy-account"
            legacy.mkdir(parents=True)
            (legacy / "auth.json").write_text("{}", encoding="utf-8")
            shared_home = root / ".codex"
            vault = AccountVault(codex_home=shared_home)
            vault.import_account(
                "A",
                {"tokens": {"account_id": "account-a", "access_token": "private-a"}},
            )
            vault.import_account(
                "B",
                {"tokens": {"account_id": "account-b", "access_token": "private-b"}},
            )
            vault.activate("A")
            remote_sources = []

            def read_isolated_remote(home):
                source = (home / "auth.json")
                self.assertTrue(source.is_symlink())
                resolved = source.resolve()
                self.assertIn(resolved.parent.name, {"A", "B"})
                self.assertEqual(
                    resolved.parent.parent.resolve(),
                    vault.accounts_root.resolve(),
                )
                remote_sources.append(resolved.parent.name)
                return self.remote_snapshot()

            payload = build_profiles_payload(
                profile_root,
                shared_home,
                remote_reader=read_isolated_remote,
            )

            self.assertEqual(payload["account_mode"], "managed_profiles")
            self.assertEqual(payload["active_profile"], "A")
            self.assertEqual(payload["account_storage"]["mode"], "unified_vault")
            self.assertEqual(payload["account_storage"]["account_count"], 2)
            self.assertEqual(payload["account_storage"]["root_auth_kind"], "plain_file")
            self.assertEqual([row["name"] for row in payload["profiles"]], ["A", "B"])
            self.assertEqual(sorted(remote_sources), ["A", "B"])
            self.assertTrue(payload["legacy_migration"]["available"])
            self.assertEqual(payload["legacy_migration"]["profile_count"], 1)
            self.assertTrue((legacy / "auth.json").exists())

    def test_missing_profiles_and_default_home_are_unavailable(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)

            payload = build_profiles_payload(
                root / ".codex-profiles",
                root / ".codex",
                read_remote=False,
            )

            self.assertEqual(payload["account_mode"], "unavailable")
            self.assertIsNone(payload["active_profile"])
            self.assertEqual(payload["profiles"], [])
            self.assertEqual(payload["account_storage"]["mode"], "unavailable")

    def test_build_profiles_payload_does_not_include_secret_contents(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "profiles"
            shared = Path(tmp) / "shared"
            profile = root / "account-a"
            profile.mkdir(parents=True)
            shared.mkdir()
            (profile / "auth.json").write_text("secret-token", encoding="utf-8")

            result = build_profiles_payload(root, shared, read_remote=False)

            text = json.dumps(result)
            self.assertIn("account-a", text)
            self.assertNotIn("secret-token", text)
            self.assertEqual(result["profiles"][0]["auth"], "present")

    def test_build_profiles_payload_uses_cached_remote_status_on_transient_failure(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "profiles"
            shared = Path(tmp) / "shared"
            profile = root / "account-a"
            profile.mkdir(parents=True)
            shared.mkdir()

            successful_remote = {
                "ok": True,
                "rate_limits": {
                    "rateLimits": {
                        "limitId": "codex",
                        "planType": "plus",
                        "primary": {"usedPercent": 25, "resetsAt": 1782700000},
                        "credits": {"balance": 1},
                    }
                },
                "usage": {"dailyUsageBuckets": [{"startDate": "2026-07-01", "tokens": 42}]},
                "error": None,
            }

            first = build_profiles_payload(
                root,
                shared,
                read_remote=True,
                remote_reader=lambda _: successful_remote,
                now_seconds=1000,
            )

            self.assertEqual(first["profiles"][0]["rate_limits"]["plan_type"], "plus")
            self.assertFalse(first["profiles"][0]["remote_stale"])

            second = build_profiles_payload(
                root,
                shared,
                read_remote=True,
                remote_reader=lambda _: {
                    "ok": False,
                    "rate_limits": None,
                    "usage": None,
                    "error": "app-server timeout",
                },
                now_seconds=1060,
            )

            profile_payload = second["profiles"][0]
            self.assertEqual(profile_payload["rate_limits"]["plan_type"], "plus")
            self.assertEqual(
                profile_payload["rate_limits"]["primary"]["remaining_percent"],
                75,
            )
            self.assertEqual(profile_payload["usage"]["dailyUsageBuckets"][0]["tokens"], 42)
            self.assertEqual(profile_payload["usage_metrics"]["last_7_tokens"], 42)
            self.assertTrue(profile_payload["remote_stale"])
            self.assertEqual(profile_payload["remote_error"], "app-server timeout")

    def test_build_profiles_payload_includes_reset_credit_details(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "profiles"
            shared = Path(tmp) / "shared"
            profile = root / "account-a"
            profile.mkdir(parents=True)
            shared.mkdir()
            (profile / "auth.json").write_text("{}", encoding="utf-8")

            def remote_reader(_profile):
                return {
                    "ok": True,
                    "rate_limits": {
                        "rateLimits": {
                            "limitId": "codex",
                            "credits": {"balance": 1},
                        }
                    },
                    "usage": None,
                    "error": None,
                }

            def reset_credit_reader(_profile):
                return {
                    "ok": True,
                    "details": {
                        "available": True,
                        "available_count": 1,
                        "credits": [
                            {
                                "status": "available",
                                "expires_at": 1784344611,
                            }
                        ],
                        "earliest_expires_at": 1784344611,
                    },
                    "error": None,
                }

            result = build_profiles_payload(
                root,
                shared,
                remote_reader=remote_reader,
                reset_credit_reader=reset_credit_reader,
            )

            details = result["profiles"][0]["reset_credit_details"]
            self.assertEqual(details["available_count"], 1)
            self.assertEqual(details["earliest_expires_at"], 1784344611)
            self.assertEqual(details["credits"][0]["status"], "available")

    def test_build_profiles_payload_prefers_app_server_credit_details(self):
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "profiles"
            shared = Path(tmp) / "shared"
            profile = root / "account-a"
            profile.mkdir(parents=True)
            shared.mkdir()
            fallback_calls = []

            result = build_profiles_payload(
                root,
                shared,
                remote_reader=lambda _: {
                    "ok": True,
                    "account": {
                        "account": {"type": "chatgpt", "planType": "plus", "email": None},
                        "requiresOpenaiAuth": True,
                    },
                    "rate_limits": {
                        "rateLimitsByLimitId": {
                            "codex": {"limitId": "codex", "planType": "plus"}
                        },
                        "rateLimitResetCredits": {
                            "availableCount": 1,
                            "credits": [
                                {
                                    "id": "private-reset-credit-id",
                                    "status": "available",
                                    "grantedAt": 1781743011,
                                    "expiresAt": 1784335011,
                                }
                            ],
                        },
                    },
                    "usage": None,
                    "error": None,
                },
                reset_credit_reader=lambda _: fallback_calls.append(True),
            )

            profile_payload = result["profiles"][0]
            self.assertEqual(fallback_calls, [])
            self.assertEqual(profile_payload["account"]["type"], "chatgpt")
            self.assertEqual(profile_payload["reset_credit_details"]["available_count"], 1)
            self.assertEqual(
                profile_payload["reset_credit_details"]["earliest_expires_at"],
                1784335011,
            )
            self.assertFalse(profile_payload["reset_credit_stale"])
            self.assertNotIn(
                "private-reset-credit-id",
                json.dumps(profile_payload["reset_credit_details"]),
            )

    def test_build_profiles_payload_includes_token_attribution(self):
        from codex_profile_dashboard import build_profiles_payload, record_attribution_baseline

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "profiles"
            shared = Path(tmp) / "shared"
            profile = root / "account-a"
            profile.mkdir(parents=True)
            shared.mkdir()
            record_attribution_baseline(
                shared,
                "account-a",
                {"total": {"total_tokens": 100}},
                managed=True,
                now_seconds=1783584000,
            )
            rollout = shared / "sessions" / "2026" / "07" / "09" / "rollout-test.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.write_text(
                json.dumps(
                    {
                        "timestamp": "2026-07-09T04:10:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {
                                    "input_tokens": 120,
                                    "cached_input_tokens": 50,
                                    "output_tokens": 20,
                                    "reasoning_output_tokens": 10,
                                    "total_tokens": 165,
                                }
                            },
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = build_profiles_payload(root, shared, read_remote=False, now_seconds=1783587600)

            attribution = result["profiles"][0]["token_attribution"]
            self.assertEqual(attribution["today_display_tokens"], 65)
            self.assertEqual(attribution["today_source"], "attribution_estimate")
            self.assertEqual(result["attribution_summary"]["active_profile"], "account-a")
            self.assertEqual(result["thread_attribution"]["rollout_count"], 1)
            self.assertEqual(result["thread_attribution"]["scope_label"], "本机 rollout 统计")
            self.assertFalse(result["thread_attribution"]["is_official_billing"])

    def test_build_profiles_payload_seeds_attribution_baseline_for_active_profile(self):
        from codex_profile_dashboard import build_profiles_payload, read_attribution_ledger

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "profiles"
            shared = Path(tmp) / "shared"
            (root / "account-a").mkdir(parents=True)
            shared.mkdir()
            rollout = shared / "sessions" / "2026" / "07" / "09" / "rollout-test.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.write_text(
                json.dumps(
                    {
                        "timestamp": "2026-07-09T04:10:00Z",
                        "payload": {
                            "type": "token_count",
                            "info": {
                                "total_token_usage": {
                                    "input_tokens": 80,
                                    "cached_input_tokens": 20,
                                    "output_tokens": 10,
                                    "reasoning_output_tokens": 0,
                                    "total_tokens": 90,
                                }
                            },
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            result = build_profiles_payload(
                root,
                shared,
                read_remote=False,
                active_profile="account-a",
                now_seconds=1783587600,
            )

            self.assertEqual(result["attribution_summary"]["active_profile"], "account-a")
            self.assertEqual(result["profiles"][0]["token_attribution"]["today_display_tokens"], 0)
            self.assertEqual(read_attribution_ledger(shared)["baseline"]["total_tokens"], 90)

    def test_read_sqlite_history_summary(self):
        import sqlite3
        from codex_profile_dashboard import read_sqlite_history_summary

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            conn = sqlite3.connect(shared / "state_5.sqlite")
            try:
                conn.execute("create table threads (tokens_used integer)")
                conn.execute("insert into threads values (10)")
                conn.execute("insert into threads values (15)")
                conn.commit()
            finally:
                conn.close()

            result = read_sqlite_history_summary(shared)

            self.assertTrue(result["available"])
            self.assertEqual(result["thread_count"], 2)
            self.assertEqual(result["tokens_used"], 25)

    def test_read_project_rankings_groups_threads_by_workspace(self):
        import sqlite3
        from codex_profile_dashboard import read_project_rankings

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            conn = sqlite3.connect(shared / "state_5.sqlite")
            try:
                conn.execute(
                    "create table threads (id text, cwd text, tokens_used integer, updated_at integer)"
                )
                conn.execute("insert into threads values ('t1', '/work/alpha', 40, 100)")
                conn.execute("insert into threads values ('t2', '/work/alpha', 60, 200)")
                conn.execute("insert into threads values ('t3', '/work/beta', 20, 300)")
                conn.commit()
            finally:
                conn.close()

            result = read_project_rankings(shared, limit=2)

            self.assertTrue(result["available"])
            self.assertEqual(result["projects"][0]["name"], "alpha")
            self.assertEqual(result["projects"][0]["path"], "/work/alpha")
            self.assertEqual(result["projects"][0]["tokens_used"], 100)
            self.assertEqual(result["projects"][0]["thread_count"], 2)
            self.assertEqual(result["projects"][0]["latest_updated_at"], 200)
            self.assertEqual(result["projects"][1]["name"], "beta")

    def test_read_tool_rankings_groups_dynamic_tools(self):
        import sqlite3
        from codex_profile_dashboard import read_tool_rankings

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            conn = sqlite3.connect(shared / "state_5.sqlite")
            try:
                conn.execute(
                    "create table threads (id text, tokens_used integer, updated_at integer)"
                )
                conn.execute(
                    "create table thread_dynamic_tools (thread_id text, name text, namespace text)"
                )
                conn.execute("insert into threads values ('t1', 40, 100)")
                conn.execute("insert into threads values ('t2', 80, 300)")
                conn.execute("insert into thread_dynamic_tools values ('t1', 'exec_command', 'tools')")
                conn.execute("insert into thread_dynamic_tools values ('t2', 'exec_command', 'tools')")
                conn.execute("insert into thread_dynamic_tools values ('t2', 'apply_patch', 'tools')")
                conn.commit()
            finally:
                conn.close()

            result = read_tool_rankings(shared, limit=2)

            self.assertTrue(result["available"])
            self.assertEqual(result["tools"][0]["name"], "exec_command")
            self.assertEqual(result["tools"][0]["namespace"], "tools")
            self.assertEqual(result["tools"][0]["call_count"], 2)
            self.assertEqual(result["tools"][0]["latest_updated_at"], 300)
            self.assertEqual(result["tools"][1]["name"], "apply_patch")

    def test_read_skill_rankings_counts_skill_file_reads(self):
        from codex_profile_dashboard import read_skill_rankings

        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            rollout = shared / "sessions" / "2026" / "07" / "09" / "rollout-test.jsonl"
            rollout.parent.mkdir(parents=True)
            rollout.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "timestamp": "2026-07-09T01:00:00Z",
                                "type": "event_msg",
                                "payload": {
                                    "type": "exec_command_end",
                                    "parsed_cmd": [
                                        {
                                            "type": "read",
                                            "path": "/Users/me/.codex/skills/frontend-ui-guardrail/SKILL.md",
                                        }
                                    ],
                                },
                            }
                        ),
                        json.dumps(
                            {
                                "timestamp": "2026-07-09T02:00:00Z",
                                "type": "event_msg",
                                "payload": {
                                    "type": "exec_command_end",
                                    "parsed_cmd": [
                                        {
                                            "type": "read",
                                            "path": "/Users/me/.codex/skills/frontend-ui-guardrail/SKILL.md",
                                        }
                                    ],
                                },
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            result = read_skill_rankings(shared)

            self.assertTrue(result["available"])
            self.assertEqual(result["skills"][0]["name"], "frontend-ui-guardrail")
            self.assertEqual(result["skills"][0]["use_count"], 2)
            self.assertEqual(result["skills"][0]["latest_timestamp"], "2026-07-09T02:00:00Z")

    def test_build_profiles_payload_includes_local_rankings(self):
        import sqlite3
        from codex_profile_dashboard import build_profiles_payload

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "profiles"
            shared = Path(tmp) / "shared"
            (root / "account-a").mkdir(parents=True)
            shared.mkdir()
            conn = sqlite3.connect(shared / "state_5.sqlite")
            try:
                conn.execute(
                    "create table threads (id text, cwd text, tokens_used integer, updated_at integer)"
                )
                conn.execute(
                    "create table thread_dynamic_tools (thread_id text, name text, namespace text)"
                )
                conn.execute("insert into threads values ('t1', '/work/alpha', 100, 200)")
                conn.execute("insert into thread_dynamic_tools values ('t1', 'exec_command', 'tools')")
                conn.commit()
            finally:
                conn.close()

            result = build_profiles_payload(root, shared, read_remote=False)

            self.assertEqual(result["project_rankings"]["projects"][0]["name"], "alpha")
            self.assertEqual(result["tool_rankings"]["tools"][0]["name"], "exec_command")
            self.assertIn("skill_rankings", result)


class RuntimeStatusTests(unittest.TestCase):
    def test_runtime_status_is_green_with_live_process(self):
        from codex_profile_dashboard import read_runtime_status

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shared = root / "shared"
            profiles = root / "profiles"
            path = shared / "process_manager" / "chat_processes.json"
            path.parent.mkdir(parents=True)
            path.write_text(
                json.dumps([{"osPid": 123, "updatedAtMs": 1000}]),
                encoding="utf-8",
            )

            result = read_runtime_status(
                shared,
                profiles,
                now_ms=10_000,
                pid_alive=lambda pid: pid == 123,
            )

            self.assertEqual(result["state"], "running")
            self.assertEqual(result["light"], "green")
            self.assertEqual(result["active_process_count"], 1)

    def test_runtime_status_is_yellow_with_recent_activity(self):
        from codex_profile_dashboard import read_runtime_status

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shared = root / "shared"
            profiles = root / "profiles"
            path = shared / "process_manager" / "chat_processes.json"
            path.parent.mkdir(parents=True)
            path.write_text(
                json.dumps([{"osPid": 123, "updatedAtMs": 1000}]),
                encoding="utf-8",
            )

            result = read_runtime_status(
                shared,
                profiles,
                now_ms=61_000,
                pid_alive=lambda pid: False,
            )

            self.assertEqual(result["state"], "waiting")
            self.assertEqual(result["light"], "yellow")
            self.assertEqual(result["recent_process_count"], 1)

    def test_runtime_status_is_red_without_recent_activity(self):
        from codex_profile_dashboard import read_runtime_status

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shared = root / "shared"
            profiles = root / "profiles"
            path = shared / "process_manager" / "chat_processes.json"
            path.parent.mkdir(parents=True)
            path.write_text(
                json.dumps([{"osPid": 123, "updatedAtMs": 1000}]),
                encoding="utf-8",
            )

            result = read_runtime_status(
                shared,
                profiles,
                now_ms=1_000_000,
                pid_alive=lambda pid: False,
            )

            self.assertEqual(result["state"], "idle")
            self.assertEqual(result["light"], "red")


if __name__ == "__main__":
    unittest.main()
