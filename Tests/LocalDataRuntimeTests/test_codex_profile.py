import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch


class ImportTests(unittest.TestCase):
    def test_module_imports(self):
        import codex_profile  # noqa: F401


class ProfileHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.old_shared_home = os.environ.get("CODEX_SHARED_HOME")
        os.environ["CODEX_SHARED_HOME"] = str(self.root / "shared-codex")

    def tearDown(self):
        if self.old_shared_home is None:
            os.environ.pop("CODEX_SHARED_HOME", None)
        else:
            os.environ["CODEX_SHARED_HOME"] = self.old_shared_home
        self.tmp.cleanup()

    def test_validate_profile_name_accepts_safe_names(self):
        from codex_profile import validate_profile_name

        self.assertEqual(validate_profile_name("account-a"), "account-a")
        self.assertEqual(validate_profile_name("work_2"), "work_2")
        self.assertEqual(validate_profile_name("personal.2026"), "personal.2026")

    def test_validate_profile_name_rejects_unsafe_names(self):
        from codex_profile import validate_profile_name

        bad_names = ["", ".", "..", "../work", "a/b", "a b", "a;b", "$HOME"]
        for name in bad_names:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    validate_profile_name(name)

    def test_consume_reset_credit_command_outputs_sanitized_result(self):
        import codex_profile

        profile = self.root / "profiles" / "account-a"
        profile.mkdir(parents=True)
        output = io.StringIO()
        with (
            patch("codex_profile.get_profile_root", return_value=profile.parent),
            patch(
                "codex_profile_dashboard.consume_next_expiring_reset_credit",
                return_value={
                    "ok": True,
                    "outcome": "alreadyRedeemed",
                    "expires_at": 1784335011,
                    "error": None,
                },
            ) as consume,
            redirect_stdout(output),
        ):
            result = codex_profile.main(
                [
                    "consume-reset-credit",
                    "account-a",
                    "--idempotency-key",
                    "stable-key",
                ]
            )

        self.assertEqual(result, 0)
        self.assertEqual(
            json.loads(output.getvalue()),
            {
                "ok": True,
                "outcome": "alreadyRedeemed",
                "expires_at": 1784335011,
                "error": None,
            },
        )
        consume.assert_called_once_with(profile, "stable-key")

    def test_profile_path_stays_under_root(self):
        from codex_profile import profile_path

        self.assertEqual(profile_path(self.root, "account-a"), self.root / "account-a")

    def test_ensure_profile_creates_user_only_directory(self):
        from codex_profile import ensure_profile

        path = ensure_profile(self.root, "account-a")

        self.assertTrue(path.is_dir())
        mode = path.stat().st_mode & 0o777
        self.assertEqual(mode, 0o700)

    def test_profile_status_checks_files_without_reading_contents(self):
        from codex_profile import profile_status

        profile = self.root / "account-a"
        profile.mkdir()
        (profile / "auth.json").write_text("secret-token-placeholder", encoding="utf-8")

        status = profile_status(profile)

        self.assertEqual(
            status,
            {"exists": True, "has_auth": True, "has_config": False},
        )

    def test_record_active_profile_records_token_attribution_baseline(self):
        import codex_profile
        import codex_profile_dashboard

        profile = self.root / "account-a"
        profile.mkdir()
        calls = []
        old_snapshot = codex_profile_dashboard.read_local_token_snapshot
        old_record = codex_profile_dashboard.record_attribution_baseline
        try:
            codex_profile_dashboard.read_local_token_snapshot = lambda shared_home: {
                "total": {"total_tokens": 123}
            }
            codex_profile_dashboard.record_attribution_baseline = (
                lambda shared_home, profile_name, local_snapshot, **kwargs: calls.append(
                    (shared_home, profile_name, local_snapshot, kwargs)
                )
            )

            codex_profile.record_active_profile("account-a", profile_home=profile, codex_pid=24680)
        finally:
            codex_profile_dashboard.read_local_token_snapshot = old_snapshot
            codex_profile_dashboard.record_attribution_baseline = old_record

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], self.root / "shared-codex")
        self.assertEqual(calls[0][1], "account-a")
        self.assertEqual(calls[0][2]["total"]["total_tokens"], 123)
        self.assertTrue(calls[0][3]["managed"])

    def test_build_codex_env_sets_codex_home(self):
        from codex_profile import build_codex_env

        env = build_codex_env({"PATH": "/bin", "CODEX_HOME": "/old"}, self.root)

        self.assertEqual(env["PATH"], "/bin")
        self.assertEqual(env["CODEX_HOME"], str(self.root))

    def test_require_codex_uses_desktop_compatible_resolver(self):
        from codex_profile import require_codex

        bundled = "/Applications/ChatGPT.app/Contents/Resources/codex"
        with patch(
            "codex_profile_dashboard.resolve_codex_binary",
            return_value=bundled,
        ) as resolve:
            result = require_codex()

        self.assertEqual(result, bundled)
        resolve.assert_called_once_with()

    def test_desktop_pid_returns_the_only_exact_running_target(self):
        from codex_profile import DesktopAppTarget, codex_desktop_pid

        target = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=24680,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        with patch("codex_profile.probe_running_desktop_apps", return_value=[target]):
            result = codex_desktop_pid()

        self.assertEqual(result, 24680)

    def test_quit_desktop_terminates_the_resolved_exact_target(self):
        from codex_profile import DesktopAppTarget, quit_codex_desktop

        target = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=24680,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        with patch(
            "codex_profile.terminate_desktop_app_target",
            return_value=True,
        ) as terminate:
            result = quit_codex_desktop(target)

        self.assertTrue(result)
        terminate.assert_called_once_with(target)

    def test_desktop_target_selector_prefers_the_running_chatgpt_path(self):
        from codex_profile import DesktopAppTarget, select_desktop_app_target

        chatgpt = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=410,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        codex = DesktopAppTarget(
            bundle_path=Path("/Applications/Codex.app"),
            pid=None,
            display_name="Codex",
            selection_reason="installed_fallback",
        )

        selected = select_desktop_app_target(
            running=[chatgpt],
            installed=[chatgpt, codex],
        )

        self.assertEqual(selected.bundle_path, chatgpt.bundle_path)
        self.assertEqual(selected.pid, 410)
        self.assertEqual(selected.display_name, "ChatGPT")
        self.assertEqual(selected.selection_reason, "running_instance")

    def test_desktop_target_selector_prefers_the_running_codex_path(self):
        from codex_profile import DesktopAppTarget, select_desktop_app_target

        codex = DesktopAppTarget(
            bundle_path=Path("/Applications/Codex.app"),
            pid=411,
            display_name="Codex",
            selection_reason="running_instance",
        )
        chatgpt = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=None,
            display_name="ChatGPT",
            selection_reason="installed_fallback",
        )

        selected = select_desktop_app_target(
            running=[codex],
            installed=[chatgpt, codex],
        )

        self.assertEqual(selected.bundle_path, codex.bundle_path)
        self.assertEqual(selected.pid, 411)
        self.assertEqual(selected.display_name, "Codex")

    def test_desktop_target_selector_is_chatgpt_first_when_nothing_runs(self):
        from codex_profile import DesktopAppTarget, select_desktop_app_target

        codex = DesktopAppTarget(
            bundle_path=Path("/Applications/Codex.app"),
            pid=None,
            display_name="Codex",
            selection_reason="installed_fallback",
        )
        chatgpt = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=None,
            display_name="ChatGPT",
            selection_reason="installed_fallback",
        )

        selected = select_desktop_app_target(
            running=[],
            installed=[codex, chatgpt],
            selected_path=codex.bundle_path,
        )

        self.assertEqual(selected.bundle_path, chatgpt.bundle_path)
        self.assertEqual(selected.selection_reason, "chatgpt_preferred")

    def test_desktop_target_selector_rejects_multiple_running_main_apps(self):
        from codex_profile import (
            DesktopAppAmbiguousError,
            DesktopAppTarget,
            select_desktop_app_target,
        )

        running = [
            DesktopAppTarget(
                bundle_path=Path("/Applications/ChatGPT.app"),
                pid=410,
                display_name="ChatGPT",
                selection_reason="running_instance",
            ),
            DesktopAppTarget(
                bundle_path=Path("/Applications/Codex.app"),
                pid=411,
                display_name="Codex",
                selection_reason="running_instance",
            ),
        ]

        with self.assertRaises(DesktopAppAmbiguousError):
            select_desktop_app_target(running=running, installed=running)

    def test_explicit_desktop_target_rejects_a_second_pid_from_the_same_path(self):
        from codex_profile import (
            DesktopAppAmbiguousError,
            DesktopAppTarget,
            resolve_desktop_app_target,
        )

        chatgpt_path = Path("/Applications/ChatGPT.app")
        running = [
            DesktopAppTarget(
                bundle_path=chatgpt_path,
                pid=410,
                display_name="ChatGPT",
                selection_reason="running_instance",
            ),
            DesktopAppTarget(
                bundle_path=chatgpt_path,
                pid=411,
                display_name="ChatGPT",
                selection_reason="running_instance",
            ),
        ]

        with self.assertRaises(DesktopAppAmbiguousError):
            resolve_desktop_app_target(
                bundle_path=chatgpt_path,
                expected_pid=410,
                running_probe=lambda: running,
                installed_probe=lambda: [],
            )

    def test_explicit_unstarted_target_rejects_another_running_main_app(self):
        from codex_profile import (
            DesktopAppError,
            DesktopAppTarget,
            resolve_desktop_app_target,
        )

        chatgpt_path = Path("/Applications/ChatGPT.app")
        codex = DesktopAppTarget(
            bundle_path=Path("/Applications/Codex.app"),
            pid=411,
            display_name="Codex",
            selection_reason="running_instance",
        )
        installed_chatgpt = DesktopAppTarget(
            bundle_path=chatgpt_path,
            pid=None,
            display_name="ChatGPT",
            selection_reason="installed_fallback",
        )

        with self.assertRaises(DesktopAppError):
            resolve_desktop_app_target(
                bundle_path=chatgpt_path,
                expected_pid=None,
                running_probe=lambda: [codex],
                installed_probe=lambda: [installed_chatgpt],
            )

    def test_authentication_writer_probe_detects_legacy_switcher_processes(self):
        from codex_profile import probe_authentication_writer_processes

        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=(
                "8123 /usr/bin/env python3 /tmp/codex_profile.py app A\n"
                "8124 /Users/example/Applications/Codex Profile Switcher.app/"
                "Contents/MacOS/Codex Profile Switcher\n"
                "8125 /Applications/ChatGPT.app/Contents/Resources/codex app-server\n"
                "8126 /Users/example/Applications/Codex 工作台.app/"
                "Contents/MacOS/CodexWorkbenchApp\n"
                "8127 /Users/example/Applications/Agent Tools.app/Contents/"
                "Resources/CodexAccountBackend/CodexAccountBackend "
                "migrate-profiles\n"
            ),
            stderr="",
        )

        with patch("codex_profile.subprocess.run", return_value=completed):
            writers = probe_authentication_writer_processes()

        self.assertEqual(
            writers,
            [
                (8123, "codex-profile-switcher"),
                (8124, "codex-profile-switcher"),
                (8125, "codex"),
                (8127, "codex-workbench-backend"),
            ],
        )

    def test_terminate_desktop_target_binds_pid_and_bundle_path(self):
        from codex_profile import DesktopAppTarget, terminate_desktop_app_target

        target = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=410,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout='{"terminated":true}\n',
            stderr="",
        )

        with patch("codex_profile.subprocess.run", return_value=completed) as run:
            terminated = terminate_desktop_app_target(target)

        self.assertTrue(terminated)
        command = run.call_args.args[0]
        self.assertIn("410", command[-1])
        self.assertIn("/Applications/ChatGPT.app", command[-1])
        self.assertNotIn("tell application id", command[-1])

    def test_running_desktop_probe_fails_closed_when_osascript_fails(self):
        from codex_profile import DesktopAppProbeError, probe_running_desktop_apps

        completed = subprocess.CompletedProcess(
            args=[],
            returncode=1,
            stdout="",
            stderr="unavailable",
        )
        with (
            patch("codex_profile.subprocess.run", return_value=completed),
            self.assertRaises(DesktopAppProbeError),
        ):
            probe_running_desktop_apps()

    def test_wait_for_desktop_launch_rejects_old_pid_and_wrong_path(self):
        from codex_profile import DesktopAppTarget, wait_for_desktop_app_launch

        expected = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=410,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        observed = [
            DesktopAppTarget(
                bundle_path=Path("/Applications/ChatGPT.app"),
                pid=410,
                display_name="ChatGPT",
                selection_reason="running_instance",
            ),
            DesktopAppTarget(
                bundle_path=Path("/Applications/Codex.app"),
                pid=510,
                display_name="Codex",
                selection_reason="running_instance",
            ),
        ]

        result = wait_for_desktop_app_launch(
            expected,
            previous_pids={410},
            timeout_seconds=0,
            running_probe=lambda: observed,
        )

        self.assertIsNone(result)

    def test_wait_for_desktop_launch_accepts_same_path_new_pid(self):
        from codex_profile import DesktopAppTarget, wait_for_desktop_app_launch

        expected = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=410,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        relaunched = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=510,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )

        result = wait_for_desktop_app_launch(
            expected,
            previous_pids={410},
            timeout_seconds=0,
            running_probe=lambda: [relaunched],
        )

        self.assertEqual(result, relaunched)

    def test_wait_for_desktop_exit_rejects_a_replacement_writer(self):
        from codex_profile import DesktopAppTarget, wait_for_desktop_app_exit

        expected = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=410,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        replacement = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=411,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )

        self.assertFalse(
            wait_for_desktop_app_exit(
                expected,
                timeout_seconds=0,
                running_probe=lambda: [replacement],
            )
        )

    def test_wait_for_desktop_launch_rejects_a_preexisting_pid(self):
        from codex_profile import DesktopAppTarget, wait_for_desktop_app_launch

        expected = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=410,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )
        preexisting = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=411,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )

        result = wait_for_desktop_app_launch(
            expected,
            previous_pids={410, 411},
            timeout_seconds=0,
            running_probe=lambda: [preexisting],
        )

        self.assertIsNone(result)

    def test_launch_desktop_target_uses_exact_path_without_codex_home(self):
        from codex_profile import DesktopAppTarget, launch_desktop_app_target

        target = DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=None,
            display_name="ChatGPT",
            selection_reason="chatgpt_preferred",
        )
        completed = subprocess.CompletedProcess(args=[], returncode=0)

        with patch("codex_profile.subprocess.run", return_value=completed) as run:
            code = launch_desktop_app_target(
                target,
                base_env={"PATH": "/usr/bin:/bin", "CODEX_HOME": "/old"},
            )

        self.assertEqual(code, 0)
        self.assertEqual(
            run.call_args.args[0],
            ["/usr/bin/open", str(target.bundle_path)],
        )
        self.assertNotIn("CODEX_HOME", run.call_args.kwargs["env"])

    def test_prepare_profile_links_history_to_shared_home(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        (shared_home).mkdir()
        (shared_home / "state_5.sqlite").write_bytes(b"sqlite-placeholder")

        prepare_profile_home(profile, shared_home)

        for name in ("sessions", "archived_sessions", "history.jsonl", "state_5.sqlite"):
            with self.subTest(name=name):
                link = profile / name
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), (shared_home / name).resolve())

        sqlite_link = profile / "sqlite" / "state_5.sqlite"
        self.assertTrue(sqlite_link.is_symlink())
        self.assertEqual(sqlite_link.resolve(), (shared_home / "state_5.sqlite").resolve())

    def test_prepare_profile_links_skills_to_shared_home(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        (profile / "skills" / "profile-skill").mkdir(parents=True)
        (profile / "skills" / "profile-skill" / "SKILL.md").write_text("profile", encoding="utf-8")
        (shared_home / "skills" / "shared-skill").mkdir(parents=True)
        (shared_home / "skills" / "shared-skill" / "SKILL.md").write_text("shared", encoding="utf-8")

        prepare_profile_home(profile, shared_home)

        skills_link = profile / "skills"
        self.assertTrue(skills_link.is_symlink())
        self.assertEqual(skills_link.resolve(), (shared_home / "skills").resolve())
        self.assertTrue((shared_home / "skills" / "profile-skill" / "SKILL.md").is_file())
        self.assertTrue((shared_home / "skills" / "shared-skill" / "SKILL.md").is_file())

    def test_prepare_profile_links_local_workspace_entries_to_shared_home(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        directory_entries = (
            "pets",
            "plugins",
            "vendor_imports",
            "computer-use",
            "attachments",
            "generated_images",
            "shell_snapshots",
            "ambient-suggestions",
            "browser",
            "automations",
            "rules",
            "superpowers",
            "worktrees",
            "cache",
        )
        file_entries = ("session_index.jsonl", "AGENTS.md")
        json_entries = ("models_cache.json",)
        for name in directory_entries:
            (profile / name / "from-profile.txt").mkdir(parents=True)
            (shared_home / name / "from-shared.txt").mkdir(parents=True)
        for name in file_entries:
            (profile / name).write_text("from-profile\n", encoding="utf-8")
            (shared_home / name).write_text("from-shared\n", encoding="utf-8")
        for name in json_entries:
            (profile / name).write_text('{"profile":["one"]}\n', encoding="utf-8")
            (shared_home / name).write_text('{"shared":["one"]}\n', encoding="utf-8")

        prepare_profile_home(profile, shared_home)

        for name in directory_entries:
            with self.subTest(name=name):
                link = profile / name
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), (shared_home / name).resolve())
                self.assertTrue((shared_home / name / "from-profile.txt").is_dir())
                self.assertTrue((shared_home / name / "from-shared.txt").is_dir())
        for name in file_entries:
            with self.subTest(name=name):
                link = profile / name
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), (shared_home / name).resolve())
                self.assertEqual(
                    (shared_home / name).read_text(encoding="utf-8"),
                    "from-shared\nfrom-profile\n",
                )
        for name in json_entries:
            with self.subTest(name=name):
                link = profile / name
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), (shared_home / name).resolve())
                self.assertEqual(
                    (shared_home / name).read_text(encoding="utf-8"),
                    '{"shared":["one"],"profile":["one"]}\n',
                )

    def test_prepare_profile_links_new_shared_entries_from_shared_home(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        (shared_home / "hooks").mkdir()
        (shared_home / "hooks" / "notify.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        (shared_home / "hooks.json").write_text('{"enabled":true}\n', encoding="utf-8")

        prepare_profile_home(profile, shared_home)

        hooks_link = profile / "hooks"
        self.assertTrue(hooks_link.is_symlink())
        self.assertEqual(hooks_link.resolve(), (shared_home / "hooks").resolve())

        hooks_json_link = profile / "hooks.json"
        self.assertTrue(hooks_json_link.is_symlink())
        self.assertEqual(hooks_json_link.resolve(), (shared_home / "hooks.json").resolve())

    def test_prepare_profile_merges_and_links_config_to_shared_home(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        (profile / "config.toml").write_text(
            '\n'.join(
                [
                    'model = "gpt-5.5"',
                    '',
                    '[projects."/work/from-profile"]',
                    'trust_level = "trusted"',
                    '',
                    '[hooks.state."/shared/hooks.json:pre_compact:0:0"]',
                    'trusted_hash = "profile-hash"',
                    '',
                ]
            ),
            encoding="utf-8",
        )
        (shared_home / "config.toml").write_text(
            '\n'.join(
                [
                    'approval_policy = "on-request"',
                    '',
                    '[projects."/work/from-shared"]',
                    'trust_level = "trusted"',
                    '',
                ]
            ),
            encoding="utf-8",
        )

        prepare_profile_home(profile, shared_home)

        config_link = profile / "config.toml"
        self.assertTrue(config_link.is_symlink())
        self.assertEqual(config_link.resolve(), (shared_home / "config.toml").resolve())
        shared_config = (shared_home / "config.toml").read_text(encoding="utf-8")
        self.assertIn('approval_policy = "on-request"', shared_config)
        self.assertIn('model = "gpt-5.5"', shared_config)
        self.assertIn('[projects."/work/from-profile"]', shared_config)
        self.assertIn('[projects."/work/from-shared"]', shared_config)
        self.assertIn('[hooks.state."/shared/hooks.json:pre_compact:0:0"]', shared_config)

    def test_prepare_profile_converts_old_default_config_symlink_to_shared_file(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        (profile / "config.toml").write_text(
            '[hooks.state."/shared/hooks.json:pre_compact:0:0"]\ntrusted_hash = "hash"\n',
            encoding="utf-8",
        )
        (shared_home / "config.toml").symlink_to(profile / "config.toml")

        prepare_profile_home(profile, shared_home)

        self.assertFalse((shared_home / "config.toml").is_symlink())
        self.assertTrue((profile / "config.toml").is_symlink())
        self.assertEqual((profile / "config.toml").resolve(), (shared_home / "config.toml").resolve())
        self.assertIn(
            'trusted_hash = "hash"',
            (shared_home / "config.toml").read_text(encoding="utf-8"),
        )

    def test_prepare_profile_adds_hook_trust_alias_for_profile_path(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        (shared_home / "config.toml").write_text(
            f'[hooks.state."{shared_home}/hooks.json:pre_compact:0:0"]\n'
            'trusted_hash = "hash"\n',
            encoding="utf-8",
        )

        prepare_profile_home(profile, shared_home)

        shared_config = (shared_home / "config.toml").read_text(encoding="utf-8")
        self.assertIn(
            f'[hooks.state."{shared_home}/hooks.json:pre_compact:0:0"]',
            shared_config,
        )
        self.assertIn(
            f'[hooks.state."{profile}/hooks.json:pre_compact:0:0"]',
            shared_config,
        )

    def test_prepare_profile_does_not_share_new_private_or_runtime_entries(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        for name in (
            ".codex-profile-switcher-active.json",
            "auth.json",
            "tmp",
            "process_manager",
            "logs_2.sqlite-wal",
        ):
            path = shared_home / name
            if "." not in name and name != "config.toml":
                path.mkdir()
            else:
                path.write_text("private\n", encoding="utf-8")

        prepare_profile_home(profile, shared_home)

        for name in (
            ".codex-profile-switcher-active.json",
            "auth.json",
            "tmp",
            "process_manager",
            "logs_2.sqlite-wal",
        ):
            with self.subTest(name=name):
                self.assertFalse((profile / name).is_symlink())

    def test_prepare_profile_merges_and_links_global_state(self):
        from codex_profile import prepare_profile_home

        profile = self.root / "account-a"
        shared_home = self.root / "shared-codex"
        profile.mkdir()
        shared_home.mkdir()
        (profile / ".codex-global-state.json").write_text(
            '{"project-order":["/work/current"],"thread-workspace-root-hints":{"t1":"/work/current"}}',
            encoding="utf-8",
        )
        (shared_home / ".codex-global-state.json").write_text(
            '{"project-order":["/work/old"],"thread-workspace-root-hints":{"t0":"/work/old"}}',
            encoding="utf-8",
        )

        prepare_profile_home(profile, shared_home)

        state_link = profile / ".codex-global-state.json"
        self.assertTrue(state_link.is_symlink())
        self.assertEqual(state_link.resolve(), (shared_home / ".codex-global-state.json").resolve())
        self.assertEqual(
            (shared_home / ".codex-global-state.json").read_text(encoding="utf-8"),
            '{"project-order":["/work/old","/work/current"],"thread-workspace-root-hints":{"t0":"/work/old","t1":"/work/current"}}\n',
        )


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.old_root = os.environ.get("CODEX_PROFILE_ROOT")
        self.old_shared_home = os.environ.get("CODEX_SHARED_HOME")
        os.environ["CODEX_PROFILE_ROOT"] = str(self.root)
        os.environ["CODEX_SHARED_HOME"] = str(self.root / "shared-codex")

    def tearDown(self):
        if self.old_root is None:
            os.environ.pop("CODEX_PROFILE_ROOT", None)
        else:
            os.environ["CODEX_PROFILE_ROOT"] = self.old_root
        if self.old_shared_home is None:
            os.environ.pop("CODEX_SHARED_HOME", None)
        else:
            os.environ["CODEX_SHARED_HOME"] = self.old_shared_home
        self.tmp.cleanup()

    def desktop_target(self, pid=24000):
        from codex_profile import DesktopAppTarget

        return DesktopAppTarget(
            bundle_path=Path("/Applications/ChatGPT.app"),
            pid=pid,
            display_name="ChatGPT",
            selection_reason="running_instance",
        )

    @staticmethod
    def synthetic_auth(account_id, marker):
        return {
            "tokens": {
                "account_id": account_id,
                "access_token": f"access-{marker}",
                "refresh_token": f"refresh-{marker}",
            }
        }

    def test_init_command_creates_profile(self):
        from codex_profile import main

        out = io.StringIO()
        with redirect_stdout(out):
            code = main(["init", "account-a"])

        self.assertEqual(code, 0)
        self.assertTrue((self.root / "account-a").is_dir())

    def test_list_command_does_not_print_auth_contents(self):
        from codex_profile import main

        profile = self.root / "account-a"
        profile.mkdir()
        (profile / "auth.json").write_text("do-not-print-this", encoding="utf-8")

        out = io.StringIO()
        with redirect_stdout(out):
            code = main(["list"])

        self.assertEqual(code, 0)
        output = out.getvalue()
        self.assertIn("account-a", output)
        self.assertIn("auth: yes", output)
        self.assertNotIn("do-not-print-this", output)

    def test_use_requires_existing_profile(self):
        from codex_profile import main

        err = io.StringIO()
        with redirect_stderr(err):
            code = main(["use", "missing", "--", "--version"])

        self.assertEqual(code, 2)
        self.assertIn("profile not found", err.getvalue())

    def test_restart_command_reuses_managed_profile_app_path(self):
        import codex_profile

        with patch("codex_profile.cmd_app", return_value=0) as app:
            code = codex_profile.main(["restart", "--profile", "account-a"])

        self.assertEqual(code, 0)
        app.assert_called_once()
        args = app.call_args.args[0]
        self.assertEqual(args.name, "account-a")
        self.assertTrue(args.restart)

    def test_migrate_profiles_dry_run_is_read_only(self):
        import codex_profile

        profile = self.root / "A"
        profile.mkdir(mode=0o700)
        auth = profile / "auth.json"
        auth.write_text(
            json.dumps(self.synthetic_auth("account-a", "A")),
            encoding="utf-8",
        )
        auth.chmod(0o600)
        out = io.StringIO()

        with redirect_stdout(out):
            code = codex_profile.main(["migrate-profiles", "--dry-run"])

        self.assertEqual(code, 0)
        report = json.loads(out.getvalue())
        self.assertTrue(report["dry_run"])
        self.assertEqual(report["planned_import_count"], 1)
        self.assertFalse((self.root / "shared-codex").exists())

    def test_migrate_profiles_requires_the_desktop_client_to_be_closed(self):
        import codex_profile

        profile = self.root / "A"
        profile.mkdir(mode=0o700)
        auth = profile / "auth.json"
        auth.write_text(
            json.dumps(self.synthetic_auth("account-a", "A")),
            encoding="utf-8",
        )
        auth.chmod(0o600)
        err = io.StringIO()

        with (
            patch(
                "codex_profile.probe_running_desktop_apps",
                return_value=[self.desktop_target()],
            ),
            redirect_stderr(err),
        ):
            code = codex_profile.main(["migrate-profiles"])

        self.assertEqual(code, 3)
        self.assertIn("must be closed", err.getvalue())
        self.assertFalse((self.root / "shared-codex").exists())

    def test_migrate_profiles_fails_closed_when_the_desktop_probe_fails(self):
        import codex_profile

        profile = self.root / "A"
        profile.mkdir(mode=0o700)
        auth = profile / "auth.json"
        auth.write_text(
            json.dumps(self.synthetic_auth("account-a", "A")),
            encoding="utf-8",
        )
        auth.chmod(0o600)
        err = io.StringIO()

        with (
            patch(
                "codex_profile.probe_running_desktop_apps",
                side_effect=codex_profile.DesktopAppProbeError(
                    "desktop process probe failed"
                ),
            ),
            redirect_stderr(err),
        ):
            code = codex_profile.main(["migrate-profiles"])

        self.assertEqual(code, 2)
        self.assertIn("probe failed", err.getvalue())
        self.assertFalse((self.root / "shared-codex").exists())

    def test_migrate_profiles_replaces_the_legacy_root_symlink_explicitly(self):
        import codex_profile

        profile = self.root / "A"
        profile.mkdir(mode=0o700)
        auth = profile / "auth.json"
        auth.write_text(
            json.dumps(self.synthetic_auth("account-a", "A")),
            encoding="utf-8",
        )
        auth.chmod(0o600)
        shared = self.root / "shared-codex"
        shared.mkdir(mode=0o700)
        (shared / "auth.json").symlink_to(auth)
        (shared / codex_profile.ACTIVE_PROFILE_FILE).write_text(
            '{"active_profile":"A"}\n',
            encoding="utf-8",
        )
        (shared / codex_profile.ACTIVE_PROFILE_FILE).chmod(0o600)
        out = io.StringIO()

        with (
            patch("codex_profile.probe_running_desktop_apps", return_value=[]),
            patch(
                "codex_profile.probe_authentication_writer_processes",
                return_value=[],
            ),
            redirect_stdout(out),
        ):
            code = codex_profile.main(["migrate-profiles"])

        self.assertEqual(code, 0)
        self.assertFalse((shared / "auth.json").is_symlink())
        self.assertEqual(
            json.loads((shared / "auth.json").read_text())["tokens"]["account_id"],
            "account-a",
        )
        self.assertTrue(profile.exists())

    def test_migrate_profiles_requires_codex_authentication_writers_to_exit(self):
        import codex_profile

        profile = self.root / "A"
        profile.mkdir(mode=0o700)
        auth = profile / "auth.json"
        auth.write_text(
            json.dumps(self.synthetic_auth("account-a", "A")),
            encoding="utf-8",
        )
        auth.chmod(0o600)
        err = io.StringIO()

        with (
            patch("codex_profile.probe_running_desktop_apps", return_value=[]),
            patch(
                "codex_profile.probe_authentication_writer_processes",
                return_value=[(8123, "codex")],
            ),
            redirect_stderr(err),
        ):
            code = codex_profile.main(["migrate-profiles"])

        self.assertEqual(code, 3)
        self.assertIn("authentication writers", err.getvalue())
        self.assertFalse((self.root / "shared-codex").exists())

    def test_recover_vault_is_an_explicit_guarded_product_command(self):
        import codex_profile
        from account_vault import AccountVault

        shared = self.root / "shared-codex"
        vault = AccountVault(codex_home=shared)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.import_account("B", self.synthetic_auth("account-b", "B"))
        vault.activate("A")
        vault.prepare_switch("B")
        out = io.StringIO()

        with (
            patch("codex_profile.authentication_writers_closed", return_value=True),
            redirect_stdout(out),
        ):
            code = codex_profile.main(["recover-vault"])

        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["outcome"], "rolled_back")
        self.assertEqual(vault.active_account_id(), "A")
        self.assertFalse(vault.transaction_path.exists())

    def test_unified_vault_app_switch_commits_only_after_exact_launch(self):
        import codex_profile
        from account_vault import AccountVault

        shared = self.root / "shared-codex"
        vault = AccountVault(codex_home=shared)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.import_account("B", self.synthetic_auth("account-b", "B"))
        vault.activate("A")
        target = self.desktop_target()
        relaunched = self.desktop_target(pid=24680)

        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch("codex_profile.terminate_desktop_app_target", return_value=True),
            patch("codex_profile.wait_for_desktop_app_exit", return_value=True),
            patch("codex_profile.launch_desktop_app_target", return_value=0),
            patch(
                "codex_profile.wait_for_desktop_app_launch",
                return_value=relaunched,
            ),
            patch("codex_profile.record_active_profile"),
        ):
            code = codex_profile.main(["app", "B"])

        self.assertEqual(code, 0)
        self.assertEqual(vault.active_account_id(), "B")
        self.assertEqual(
            json.loads((shared / "auth.json").read_text())["tokens"]["account_id"],
            "account-b",
        )
        self.assertFalse((shared / "auth.json").is_symlink())

    def test_unified_vault_never_falls_back_to_a_preserved_legacy_profile(self):
        import codex_profile
        from account_vault import AccountVault

        shared = self.root / "shared-codex"
        vault = AccountVault(codex_home=shared)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.activate("A")
        legacy = self.root / "legacy-only"
        legacy.mkdir(mode=0o700)
        legacy_auth = legacy / "auth.json"
        legacy_auth.write_text(
            json.dumps(self.synthetic_auth("legacy-account", "legacy")),
            encoding="utf-8",
        )
        legacy_auth.chmod(0o600)
        err = io.StringIO()

        with (
            patch("codex_profile.terminate_desktop_app_target") as terminate,
            redirect_stderr(err),
        ):
            code = codex_profile.main(["app", "legacy-only"])

        self.assertEqual(code, 2)
        self.assertIn("not found in the unified vault", err.getvalue())
        terminate.assert_not_called()
        self.assertEqual(vault.active_account_id(), "A")

    def test_unified_root_conflict_is_detected_before_terminating_the_app(self):
        import codex_profile
        from account_vault import AccountVault

        shared = self.root / "shared-codex"
        vault = AccountVault(codex_home=shared)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.import_account("B", self.synthetic_auth("account-b", "B"))
        vault.activate("A")
        root_auth = shared / "auth.json"
        root_auth.write_text(
            json.dumps(self.synthetic_auth("external-account", "external")),
            encoding="utf-8",
        )
        root_auth.chmod(0o600)
        err = io.StringIO()

        with (
            patch("codex_profile._desktop_target_from_args", return_value=self.desktop_target()),
            patch("codex_profile.terminate_desktop_app_target") as terminate,
            redirect_stderr(err),
        ):
            code = codex_profile.main(["app", "B"])

        self.assertEqual(code, 1)
        self.assertIn("changed outside", err.getvalue())
        terminate.assert_not_called()
        self.assertEqual(vault.active_account_id(), "A")

    def test_desktop_status_recognizes_a_unified_vault_working_copy(self):
        import codex_profile
        from account_vault import AccountVault

        shared = self.root / "shared-codex"
        vault = AccountVault(codex_home=shared)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.activate("A")

        with patch(
            "codex_profile.probe_running_desktop_apps",
            return_value=[self.desktop_target()],
        ):
            status = codex_profile.build_desktop_status()

        self.assertTrue(status["running"])
        self.assertTrue(status["managed"])
        self.assertEqual(status["state"], "managed_vault")
        self.assertEqual(status["active_profile"], "A")
        self.assertIn("统一账号库", status["message"])

    def test_desktop_status_fails_closed_when_root_identity_changes(self):
        import codex_profile
        from account_vault import AccountVault

        shared = self.root / "shared-codex"
        vault = AccountVault(codex_home=shared)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.activate("A")
        root_auth = shared / "auth.json"
        root_auth.write_text(
            json.dumps(self.synthetic_auth("external-account", "external")),
            encoding="utf-8",
        )
        root_auth.chmod(0o600)

        with patch(
            "codex_profile.probe_running_desktop_apps",
            return_value=[self.desktop_target()],
        ):
            status = codex_profile.build_desktop_status()

        self.assertFalse(status["managed"])
        self.assertEqual(status["state"], "vault_identity_conflict")

    def test_consume_reset_credit_never_uses_a_unified_vault_snapshot(self):
        import codex_profile
        from account_vault import AccountVault

        shared = self.root / "shared-codex"
        vault = AccountVault(codex_home=shared)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        calls = []
        err = io.StringIO()

        with (
            patch(
                "codex_profile_dashboard.consume_next_expiring_reset_credit",
                side_effect=lambda home, key: calls.append((home, key))
                or {"ok": True, "outcome": "noCredit"},
            ),
            redirect_stderr(err),
        ):
            code = codex_profile.main(
                ["consume-reset-credit", "A", "--idempotency-key", "stable-key"]
            )

        self.assertEqual(code, 2)
        self.assertEqual(calls, [])
        self.assertIn("unified vault", err.getvalue().lower())

    def test_restart_command_restarts_local_default_without_profile_bridge(self):
        import codex_profile

        calls = []
        target = self.desktop_target()
        relaunched = self.desktop_target(pid=24680)
        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch(
                "codex_profile.terminate_desktop_app_target",
                side_effect=lambda value: calls.append(("terminate", value)) or True,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_exit",
                side_effect=lambda value: calls.append(("wait-exit", value)) or True,
            ),
            patch(
                "codex_profile.launch_desktop_app_target",
                side_effect=lambda value: calls.append(("open", value)) or 0,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_launch",
                side_effect=lambda value, previous_pids: calls.append(
                    ("wait-launch", value, previous_pids)
                )
                or relaunched,
            ),
            patch("codex_profile.activate_default_home_profile") as bridge,
            patch("codex_profile.record_active_profile") as record,
            patch("codex_profile.reconcile_default_home_auth_for_active_profile") as reconcile,
        ):
            code = codex_profile.main(["restart"])

        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [
                ("terminate", target),
                ("wait-exit", target),
                ("open", target),
                ("wait-launch", target, {24000}),
            ],
        )
        bridge.assert_not_called()
        record.assert_not_called()
        reconcile.assert_not_called()

    def test_restart_command_requires_confirmation_when_runtime_is_running(self):
        import codex_profile

        err = io.StringIO()
        with (
            patch("codex_profile.current_restart_runtime_state", return_value="running"),
            patch("codex_profile._desktop_target_from_args") as resolve_target,
            redirect_stderr(err),
        ):
            code = codex_profile.main(["restart"])

        self.assertEqual(code, 3)
        self.assertIn("restart confirmation required: running", err.getvalue())
        resolve_target.assert_not_called()

    def test_restart_command_allows_explicitly_confirmed_active_runtime(self):
        import codex_profile

        calls = []
        target = self.desktop_target()
        relaunched = self.desktop_target(pid=24680)
        with (
            patch("codex_profile.current_restart_runtime_state", return_value="running"),
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch(
                "codex_profile.terminate_desktop_app_target",
                side_effect=lambda value: calls.append(("terminate", value)) or True,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_exit",
                side_effect=lambda value: calls.append(("wait-exit", value)) or True,
            ),
            patch(
                "codex_profile.launch_desktop_app_target",
                side_effect=lambda value: calls.append(("open", value)) or 0,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_launch",
                side_effect=lambda value, previous_pids: calls.append(
                    ("wait-launch", value, previous_pids)
                )
                or relaunched,
            ),
        ):
            code = codex_profile.main(["restart", "--allow-active"])

        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [
                ("terminate", target),
                ("wait-exit", target),
                ("open", target),
                ("wait-launch", target, {24000}),
            ],
        )

    def test_restart_command_reports_local_default_quit_timeout(self):
        import codex_profile

        err = io.StringIO()
        target = self.desktop_target()
        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch("codex_profile.terminate_desktop_app_target", return_value=True),
            patch("codex_profile.wait_for_desktop_app_exit", return_value=False),
            patch("codex_profile.launch_desktop_app_target") as launch,
            redirect_stderr(err),
        ):
            code = codex_profile.main(["restart"])

        self.assertEqual(code, 1)
        self.assertIn("did not quit within 12 seconds", err.getvalue())
        launch.assert_not_called()

    def test_restart_command_reports_local_default_launch_timeout(self):
        import codex_profile

        err = io.StringIO()
        target = self.desktop_target()
        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch("codex_profile.terminate_desktop_app_target", return_value=True),
            patch("codex_profile.wait_for_desktop_app_exit", return_value=True),
            patch("codex_profile.launch_desktop_app_target", return_value=0),
            patch("codex_profile.wait_for_desktop_app_launch", return_value=None),
            redirect_stderr(err),
        ):
            code = codex_profile.main(["restart"])

        self.assertEqual(code, 1)
        self.assertIn("did not launch within 12 seconds", err.getvalue())

    def test_app_command_restarts_desktop_and_launches_app(self):
        from codex_profile import main

        profile = self.root / "account-a"
        profile.mkdir()
        calls = []
        target = self.desktop_target()
        relaunched = self.desktop_target(pid=24680)
        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch(
                "codex_profile.terminate_desktop_app_target",
                side_effect=lambda value: calls.append(("terminate", value)) or True,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_exit",
                side_effect=lambda value: calls.append(("wait-exit", value)) or True,
            ),
            patch(
                "codex_profile.reconcile_default_home_auth_for_active_profile",
                side_effect=lambda: calls.append(("reconcile", None)) or {"state": "linked"},
            ),
            patch(
                "codex_profile.activate_default_home_profile",
                side_effect=lambda profile_home, profile_name, shared_home=None: calls.append(
                    ("bridge", profile_home, profile_name, shared_home)
                ),
            ),
            patch(
                "codex_profile.record_active_profile",
                side_effect=lambda name, **kwargs: calls.append(("active", name, kwargs)),
            ),
            patch(
                "codex_profile.launch_desktop_app_target",
                side_effect=lambda value: calls.append(("open", value)) or 0,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_launch",
                side_effect=lambda value, previous_pids: calls.append(
                    ("wait-launch", value, previous_pids)
                )
                or relaunched,
            ),
        ):
            code = main(["app", "account-a"])

        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [
                ("terminate", target),
                ("wait-exit", target),
                ("reconcile", None),
                ("bridge", profile, "account-a", self.root / "shared-codex"),
                ("active", "account-a", {"profile_home": profile}),
                ("open", target),
                ("wait-launch", target, {24000}),
                ("active", "account-a", {"profile_home": profile, "codex_pid": 24680}),
            ],
        )

    def test_app_command_aborts_when_desktop_does_not_quit(self):
        from codex_profile import main

        profile = self.root / "account-a"
        profile.mkdir()
        calls = []
        target = self.desktop_target()
        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch(
                "codex_profile.terminate_desktop_app_target",
                side_effect=lambda value: calls.append(("terminate", value)) or True,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_exit",
                side_effect=lambda value: calls.append(("wait-exit", value)) or False,
            ),
            patch("codex_profile.activate_default_home_profile") as bridge,
            patch("codex_profile.launch_desktop_app_target") as launch,
            patch("codex_profile.record_active_profile") as record,
        ):
            err = io.StringIO()
            with redirect_stderr(err):
                code = main(["app", "account-a"])

        self.assertEqual(code, 1)
        self.assertEqual(
            calls,
            [("terminate", target), ("wait-exit", target)],
        )
        bridge.assert_not_called()
        launch.assert_not_called()
        record.assert_not_called()
        self.assertIn("did not quit", err.getvalue())

    def test_app_command_aborts_when_desktop_does_not_launch(self):
        from codex_profile import main

        profile = self.root / "account-a"
        profile.mkdir()
        calls = []
        target = self.desktop_target()
        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch(
                "codex_profile.terminate_desktop_app_target",
                side_effect=lambda value: calls.append(("terminate", value)) or True,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_exit",
                side_effect=lambda value: calls.append(("wait-exit", value)) or True,
            ),
            patch(
                "codex_profile.reconcile_default_home_auth_for_active_profile",
                return_value={"state": "linked"},
            ),
            patch(
                "codex_profile.activate_default_home_profile",
                side_effect=lambda profile_home, profile_name, shared_home=None: calls.append(
                    ("bridge", profile_home, profile_name, shared_home)
                ),
            ),
            patch(
                "codex_profile.record_active_profile",
                side_effect=lambda name, **kwargs: calls.append(("active", name, kwargs)),
            ),
            patch(
                "codex_profile.launch_desktop_app_target",
                side_effect=lambda value: calls.append(("open", value)) or 0,
            ),
            patch(
                "codex_profile.wait_for_desktop_app_launch",
                side_effect=lambda value, previous_pids: calls.append(
                    ("wait-launch", value, previous_pids)
                )
                or None,
            ),
        ):
            err = io.StringIO()
            with redirect_stderr(err):
                code = main(["app", "account-a"])

        self.assertEqual(code, 1)
        self.assertEqual(
            calls,
            [
                ("terminate", target),
                ("wait-exit", target),
                ("bridge", profile, "account-a", self.root / "shared-codex"),
                ("active", "account-a", {"profile_home": profile}),
                ("open", target),
                ("wait-launch", target, {24000}),
            ],
        )
        self.assertIn("did not launch", err.getvalue())

    def test_app_command_can_skip_restart(self):
        from codex_profile import main

        profile = self.root / "account-a"
        profile.mkdir()
        calls = []
        target = self.desktop_target()
        with (
            patch("codex_profile._desktop_target_from_args", return_value=target),
            patch(
                "codex_profile.activate_default_home_profile",
                side_effect=lambda profile_home, profile_name, shared_home=None: calls.append(
                    ("bridge", profile_home, profile_name, shared_home)
                ),
            ),
            patch(
                "codex_profile.record_active_profile",
                side_effect=lambda name, **kwargs: calls.append(("active", name, kwargs)),
            ),
            patch(
                "codex_profile.launch_desktop_app_target",
                side_effect=lambda value: calls.append(("open", value)) or 0,
            ),
            patch("codex_profile.terminate_desktop_app_target") as terminate,
            patch("codex_profile.wait_for_desktop_app_exit") as wait_exit,
            patch("codex_profile.wait_for_desktop_app_launch") as wait_launch,
        ):
            code = main(["app", "account-a", "--no-restart"])

        self.assertEqual(code, 0)
        self.assertEqual(
            calls,
            [
                ("bridge", profile, "account-a", self.root / "shared-codex"),
                ("active", "account-a", {"profile_home": profile}),
                ("open", target),
                ("active", "account-a", {"profile_home": profile, "codex_pid": 24000}),
            ],
        )
        terminate.assert_not_called()
        wait_exit.assert_not_called()
        wait_launch.assert_not_called()

    def test_default_home_bridge_moves_missing_profile_files_then_links(self):
        from codex_profile import activate_default_home_profile

        shared_home = self.root / "shared-codex"
        profile = self.root / "account-a"
        shared_home.mkdir()
        profile.mkdir()
        (shared_home / "auth.json").write_text("default-auth", encoding="utf-8")

        result = activate_default_home_profile(profile, "account-a", shared_home=shared_home)

        self.assertTrue((profile / "auth.json").is_file())
        self.assertEqual((profile / "auth.json").read_text(encoding="utf-8"), "default-auth")
        self.assertTrue((shared_home / "auth.json").is_symlink())
        self.assertEqual((shared_home / "auth.json").resolve(), (profile / "auth.json").resolve())
        self.assertNotIn("config.toml", result["files"])

    def test_default_home_bridge_backs_up_default_files_when_profile_has_files(self):
        from codex_profile import activate_default_home_profile

        shared_home = self.root / "shared-codex"
        profile = self.root / "account-a"
        shared_home.mkdir()
        profile.mkdir()
        (profile / "auth.json").write_text("profile-auth", encoding="utf-8")
        (shared_home / "auth.json").write_text("default-auth", encoding="utf-8")

        activate_default_home_profile(profile, "account-a", shared_home=shared_home)

        self.assertTrue((shared_home / "auth.json").is_symlink())
        self.assertEqual((shared_home / "auth.json").resolve(), (profile / "auth.json").resolve())
        self.assertEqual((profile / "auth.json").read_text(encoding="utf-8"), "profile-auth")
        backups = list((shared_home / ".codex-profile-switcher-backups").glob("account-files-*"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "auth.json").is_file())
        self.assertEqual((backups[0] / "auth.json").read_text(encoding="utf-8"), "default-auth")

    def test_reconcile_default_auth_persists_atomic_replacement_for_same_account(self):
        from codex_profile import reconcile_default_home_auth

        shared_home = self.root / "shared-codex"
        profile = self.root / "account-a"
        shared_home.mkdir()
        profile.mkdir()
        old_auth = {
            "tokens": {"account_id": "account-1", "refresh_token": "old-refresh"},
            "last_refresh": "old",
        }
        refreshed_auth = {
            "tokens": {"account_id": "account-1", "refresh_token": "new-refresh"},
            "last_refresh": "new",
        }
        (profile / "auth.json").write_text(json.dumps(old_auth), encoding="utf-8")
        (shared_home / "auth.json").write_text(json.dumps(refreshed_auth), encoding="utf-8")

        result = reconcile_default_home_auth(shared_home, profile)

        self.assertEqual(result["state"], "synced")
        self.assertTrue((shared_home / "auth.json").is_symlink())
        self.assertEqual((shared_home / "auth.json").resolve(), (profile / "auth.json").resolve())
        self.assertEqual(json.loads((profile / "auth.json").read_text()), refreshed_auth)

    def test_reconcile_default_auth_preserves_different_account_files(self):
        from codex_profile import reconcile_default_home_auth

        shared_home = self.root / "shared-codex"
        profile = self.root / "account-a"
        shared_home.mkdir()
        profile.mkdir()
        profile_auth = {"tokens": {"account_id": "account-1", "refresh_token": "profile-refresh"}}
        default_auth = {"tokens": {"account_id": "account-2", "refresh_token": "default-refresh"}}
        (profile / "auth.json").write_text(json.dumps(profile_auth), encoding="utf-8")
        (shared_home / "auth.json").write_text(json.dumps(default_auth), encoding="utf-8")

        result = reconcile_default_home_auth(shared_home, profile)

        self.assertEqual(result["state"], "account_conflict")
        self.assertFalse((shared_home / "auth.json").is_symlink())
        self.assertEqual(json.loads((shared_home / "auth.json").read_text()), default_auth)
        self.assertEqual(json.loads((profile / "auth.json").read_text()), profile_auth)

    def test_default_home_bridge_status_reports_active_profile_links(self):
        from codex_profile import activate_default_home_profile, default_home_bridge_status

        shared_home = self.root / "shared-codex"
        profile = self.root / "account-a"
        shared_home.mkdir()
        profile.mkdir()
        (profile / "auth.json").write_text("profile-auth", encoding="utf-8")

        activate_default_home_profile(profile, "account-a", shared_home=shared_home)
        status = default_home_bridge_status(shared_home, self.root, "account-a")

        self.assertTrue(status["managed"])
        self.assertEqual(status["active_profile"], "account-a")
        self.assertEqual(status["files"]["auth.json"], "linked")

    def test_desktop_status_treats_manual_launch_as_managed_when_default_bridge_matches(self):
        import codex_profile
        from codex_profile import activate_default_home_profile, build_desktop_status, record_active_profile

        profile_home = self.root / "account-a"
        profile_home.mkdir()
        (profile_home / "auth.json").write_text("profile-auth", encoding="utf-8")
        activate_default_home_profile(profile_home, "account-a", shared_home=self.root / "shared-codex")
        record_active_profile("account-a", profile_home=profile_home, codex_pid=12345)

        old_pid = codex_profile.codex_desktop_pid
        try:
            codex_profile.codex_desktop_pid = lambda: 99999

            status = build_desktop_status()
        finally:
            codex_profile.codex_desktop_pid = old_pid

        self.assertTrue(status["running"])
        self.assertTrue(status["managed"])
        self.assertEqual(status["state"], "managed_default_home")

    def test_active_profile_roundtrip(self):
        from codex_profile import read_active_profile, record_active_profile

        record_active_profile("account-a")

        self.assertEqual(read_active_profile(), "account-a")

    def test_active_profile_record_includes_managed_launch_metadata(self):
        from codex_profile import read_active_profile_record, record_active_profile

        profile_home = self.root / "account-a"
        record_active_profile("account-a", profile_home=profile_home, codex_pid=12345)

        record = read_active_profile_record()

        self.assertEqual(record["active_profile"], "account-a")
        self.assertEqual(record["profile_home"], str(profile_home))
        self.assertEqual(record["codex_pid"], 12345)
        self.assertEqual(record["shared_home"], str(self.root / "shared-codex"))
        self.assertIn("managed_launch_at", record)

    def test_desktop_status_marks_managed_launch_when_pid_matches(self):
        import codex_profile
        from codex_profile import build_desktop_status, record_active_profile

        profile_home = self.root / "account-a"
        record_active_profile("account-a", profile_home=profile_home, codex_pid=12345)

        old_pid = codex_profile.codex_desktop_pid
        try:
            codex_profile.codex_desktop_pid = lambda: 12345

            status = build_desktop_status()
        finally:
            codex_profile.codex_desktop_pid = old_pid

        self.assertTrue(status["running"])
        self.assertTrue(status["managed"])
        self.assertEqual(status["state"], "managed_legacy")
        self.assertEqual(status["active_profile"], "account-a")
        self.assertEqual(status["codex_pid"], 12345)

    def test_desktop_status_marks_manual_launch_when_pid_differs(self):
        import codex_profile
        from codex_profile import build_desktop_status, record_active_profile

        profile_home = self.root / "account-a"
        record_active_profile("account-a", profile_home=profile_home, codex_pid=12345)

        old_pid = codex_profile.codex_desktop_pid
        try:
            codex_profile.codex_desktop_pid = lambda: 99999

            status = build_desktop_status()
        finally:
            codex_profile.codex_desktop_pid = old_pid

        self.assertTrue(status["running"])
        self.assertFalse(status["managed"])
        self.assertIn("manual", status["state"])

    def test_status_payload_includes_active_profile(self):
        from codex_profile import build_status_payload, record_active_profile

        record_active_profile("account-a")

        self.assertEqual(build_status_payload()["active_profile"], "account-a")

    def test_status_payload_uses_local_default_without_managed_profile_repairs(self):
        from codex_profile import build_status_payload

        profile_root = self.root / ".codex-profiles"
        shared_home = self.root / ".codex"
        shared_home.mkdir()
        local_payload = {
            "account_mode": "local_default",
            "active_profile": "local-default",
            "profiles": [{"name": "local-default", "path": str(shared_home)}],
        }
        with (
            patch("codex_profile.get_profile_root", return_value=profile_root),
            patch("codex_profile.get_shared_home", return_value=shared_home),
            patch("codex_profile.sync_profile_homes") as sync_profiles,
            patch("codex_profile.repair_default_home_bridge_for_active_profile") as repair_bridge,
            patch("codex_profile.read_active_profile", return_value="stale-profile") as read_active,
            patch(
                "codex_profile_dashboard.build_profiles_payload",
                return_value=local_payload,
            ),
            patch(
                "codex_profile_dashboard.read_runtime_status",
                return_value={"state": "idle"},
            ),
            patch(
                "codex_profile.build_desktop_status",
                return_value={
                    "running": False,
                    "managed": False,
                    "active_profile": None,
                    "state": "not_running",
                    "message": "Codex 未运行",
                    "default_home_bridge": {"state": "no_active_profile"},
                },
            ),
        ):
            payload = build_status_payload()

        sync_profiles.assert_not_called()
        repair_bridge.assert_not_called()
        read_active.assert_not_called()
        self.assertEqual(payload["account_mode"], "local_default")
        self.assertEqual(payload["active_profile"], "local-default")
        self.assertFalse(payload["desktop_status"]["managed"])
        self.assertEqual(payload["desktop_status"]["active_profile"], "local-default")
        self.assertEqual(payload["desktop_status"]["state"], "local_default")
        self.assertEqual(payload["desktop_status"]["message"], "使用本机默认 Codex 账号")

    def test_status_payload_is_read_only_for_managed_legacy_profiles(self):
        from codex_profile import build_status_payload

        profile_root = self.root / ".codex-profiles"
        shared_home = self.root / ".codex"
        (profile_root / "account-a").mkdir(parents=True)
        shared_home.mkdir()
        with (
            patch("codex_profile.get_profile_root", return_value=profile_root),
            patch("codex_profile.get_shared_home", return_value=shared_home),
            patch("codex_profile.sync_profile_homes") as sync_profiles,
            patch("codex_profile.repair_default_home_bridge_for_active_profile") as repair_bridge,
            patch("codex_profile.read_active_profile", return_value="account-a"),
            patch(
                "codex_profile_dashboard.build_profiles_payload",
                return_value={
                    "account_mode": "managed_profiles",
                    "active_profile": "account-a",
                    "profiles": [{"name": "account-a", "path": str(profile_root / "account-a")}],
                },
            ),
            patch(
                "codex_profile_dashboard.read_runtime_status",
                return_value={"state": "idle"},
            ),
            patch(
                "codex_profile.build_desktop_status",
                return_value={"active_profile": "account-a", "default_home_bridge": {}},
            ),
        ):
            payload = build_status_payload()

        sync_profiles.assert_not_called()
        repair_bridge.assert_not_called()
        self.assertEqual(payload["account_mode"], "managed_profiles")
        self.assertEqual(payload["active_profile"], "account-a")

    def test_status_payload_never_falls_back_when_an_existing_vault_is_corrupt(self):
        from account_vault import AccountVault, VaultError
        from codex_profile import build_status_payload

        profile_root = self.root / ".codex-profiles"
        legacy = profile_root / "account-a"
        legacy.mkdir(parents=True)
        shared_home = self.root / ".codex"
        vault = AccountVault(codex_home=shared_home)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.registry_path.write_text("{", encoding="utf-8")
        vault.registry_path.chmod(0o600)

        with (
            patch("codex_profile.get_profile_root", return_value=profile_root),
            patch("codex_profile.get_shared_home", return_value=shared_home),
            patch("codex_profile.sync_profile_homes") as sync_profiles,
            patch("codex_profile.repair_default_home_bridge_for_active_profile") as repair_bridge,
            self.assertRaises(VaultError),
        ):
            build_status_payload()

        sync_profiles.assert_not_called()
        repair_bridge.assert_not_called()

    def test_desktop_status_reports_an_existing_corrupt_vault_without_legacy_fallback(self):
        import codex_profile
        from account_vault import AccountVault

        shared_home = self.root / ".codex"
        vault = AccountVault(codex_home=shared_home)
        vault.import_account("A", self.synthetic_auth("account-a", "A"))
        vault.registry_path.write_text("{", encoding="utf-8")
        vault.registry_path.chmod(0o600)
        codex_profile.record_active_profile("legacy-account", codex_pid=123)

        with (
            patch("codex_profile.get_shared_home", return_value=shared_home),
            patch(
                "codex_profile.probe_running_desktop_apps",
                return_value=[self.desktop_target(pid=123)],
            ),
        ):
            status = codex_profile.build_desktop_status()

        self.assertEqual(status["state"], "vault_unavailable")
        self.assertFalse(status["managed"])
        self.assertIsNone(status["active_profile"])

    def test_sync_profile_homes_links_new_shared_entries_for_all_profiles(self):
        from codex_profile import sync_profile_homes

        profile_root = self.root / "profiles"
        shared_home = self.root / "shared-codex"
        profile_root.mkdir()
        shared_home.mkdir()
        (shared_home / "hooks").mkdir()
        (shared_home / "hooks" / "notify.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        for name in ("account-a", "account-b"):
            (profile_root / name).mkdir()

        synced = sync_profile_homes(profile_root, shared_home)

        self.assertEqual(synced, ["account-a", "account-b"])
        for name in synced:
            link = profile_root / name / "hooks"
            self.assertTrue(link.is_symlink())
            self.assertEqual(link.resolve(), (shared_home / "hooks").resolve())

    def test_sync_profile_homes_skips_shared_home_inside_profile_root(self):
        from codex_profile import sync_profile_homes

        shared_home = self.root / "shared-codex"
        shared_home.mkdir()
        (self.root / "account-a").mkdir()

        synced = sync_profile_homes(self.root, shared_home)

        self.assertEqual(synced, ["account-a"])

    def test_status_payload_never_syncs_profile_homes_while_reading(self):
        import codex_profile
        from codex_profile import build_status_payload

        profile_root = self.root / "profiles"
        (profile_root / "account-a").mkdir(parents=True)
        calls = []
        with (
            patch("codex_profile.get_profile_root", return_value=profile_root),
            patch("codex_profile.sync_profile_homes", side_effect=lambda: calls.append("sync") or []),
        ):
            payload = build_status_payload()

        self.assertEqual(calls, [])
        self.assertIn("profiles", payload)

    def test_sync_command_runs_profile_sync(self):
        import codex_profile
        from codex_profile import main

        calls = []
        old_sync = codex_profile.sync_profile_homes
        try:
            codex_profile.sync_profile_homes = lambda: calls.append("sync") or ["account-a"]
            out = io.StringIO()
            with redirect_stdout(out):
                code = main(["sync"])
        finally:
            codex_profile.sync_profile_homes = old_sync

        self.assertEqual(code, 0)
        self.assertEqual(calls, ["sync"])
        self.assertIn("account-a", out.getvalue())

    def test_ui_command_is_not_available_in_workbench_backend(self):
        import codex_profile

        with self.assertRaises(SystemExit) as error:
            codex_profile.build_parser().parse_args(["ui"])

        self.assertEqual(error.exception.code, 2)

    def test_status_command_prints_json(self):
        import codex_profile
        from codex_profile import main

        old_build = codex_profile.build_status_payload
        try:
            codex_profile.build_status_payload = lambda: {
                "profiles": [{"name": "account-a", "auth": "present"}]
            }
            out = io.StringIO()
            with redirect_stdout(out):
                code = main(["status", "--json"])
        finally:
            codex_profile.build_status_payload = old_build

        self.assertEqual(code, 0)
        self.assertEqual(
            json.loads(out.getvalue()),
            {"profiles": [{"name": "account-a", "auth": "present"}]},
        )


if __name__ == "__main__":
    unittest.main()
