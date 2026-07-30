import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import codex_runtime_services


class CodexRuntimeServicesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.shared_home = self.root / "shared"
        self.project_dir = self.root / "project"
        self.project_dir.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_add_project_persists_safe_definition_without_secret(self):
        project = codex_runtime_services.add_project(
            self.shared_home,
            "Demo",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
        )

        self.assertEqual(project["name"], "Demo")
        self.assertEqual(project["port"], 5173)
        stored = json.loads(
            (self.shared_home / codex_runtime_services.MANAGED_PROJECTS_FILE).read_text()
        )
        self.assertEqual(stored["projects"][0]["command"], "python3 -m http.server 5173")
        self.assertEqual((self.shared_home / codex_runtime_services.MANAGED_PROJECTS_FILE).stat().st_mode & 0o777, 0o600)

    def test_add_project_rejects_inline_credentials(self):
        with self.assertRaises(ValueError):
            codex_runtime_services.add_project(
                self.shared_home,
                "Unsafe",
                str(self.project_dir),
                "npm run dev -- --api-key=do-not-store",
                None,
            )

    def test_add_project_is_idempotent_for_the_same_definition(self):
        first = codex_runtime_services.add_project(
            self.shared_home,
            "Demo",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
        )
        second = codex_runtime_services.add_project(
            self.shared_home,
            "Demo again",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
        )

        self.assertEqual(second["id"], first["id"])
        self.assertEqual(len(codex_runtime_services._read_projects(self.shared_home)), 1)

    def test_add_project_normalizes_shell_quotes_copied_from_task_json(self):
        project = codex_runtime_services.add_project(
            self.shared_home,
            "Frontend",
            str(self.project_dir),
            r'node --input-type=module -e \"const config = { port: 5174 };\"',
            5174,
        )

        self.assertEqual(
            project["command"],
            'node --input-type=module -e "const config = { port: 5174 };"',
        )

    def test_start_project_reports_an_immediate_shell_failure_from_its_log(self):
        project = codex_runtime_services.add_project(
            self.shared_home,
            "Broken frontend",
            str(self.project_dir),
            "node --input-type=module -e 'broken'",
            5174,
        )

        class FailedProcess:
            pid = 4242

            @staticmethod
            def poll():
                return 1

        log_dir = self.shared_home / "logs" / "codex-workbench-projects"
        log_dir.mkdir(parents=True)
        log_path = log_dir / f"{project['id']}.log"
        log_path.write_text("zsh:1: parse error near `}'\n", encoding="utf-8")
        with (
            patch.object(codex_runtime_services, "_run", return_value=("", None)),
            patch.object(codex_runtime_services.subprocess, "Popen", return_value=FailedProcess()),
        ):
            with self.assertRaisesRegex(RuntimeError, "parse error near `}'"):
                codex_runtime_services.start_project(self.shared_home, project["id"])

        stored = codex_runtime_services._read_projects(self.shared_home)[0]
        self.assertIsNone(stored["pid"])
        self.assertIn("parse error near `}'", stored["last_error"])

    def test_start_project_waits_briefly_for_a_real_shell_parse_failure(self):
        project = codex_runtime_services.add_project(
            self.shared_home,
            "Invalid frontend",
            str(self.project_dir),
            'node -e "const config = {;"',
            None,
        )

        with self.assertRaisesRegex(RuntimeError, "启动命令立即退出"):
            codex_runtime_services.start_project(self.shared_home, project["id"])

        stored = codex_runtime_services._read_projects(self.shared_home)[0]
        self.assertIsNone(stored["pid"])
        self.assertIn("SyntaxError", stored["last_error"])

    def test_prune_duplicate_projects_keeps_one_exact_definition_only(self):
        first = codex_runtime_services.add_project(
            self.shared_home,
            "Demo",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
        )
        duplicate = dict(first, id="duplicate")
        different = dict(first, id="different", command="python3 -m http.server 5174", port=5174)
        codex_runtime_services._write_projects(self.shared_home, [first, duplicate, different])

        result = codex_runtime_services.prune_duplicate_projects(self.shared_home)

        self.assertEqual(result["removed_count"], 1)
        self.assertEqual([item["id"] for item in codex_runtime_services._read_projects(self.shared_home)], [first["id"], "different"])

    def test_remove_project_only_removes_its_registration(self):
        project = codex_runtime_services.add_project(
            self.shared_home,
            "Demo",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
        )

        result = codex_runtime_services.remove_project(self.shared_home, project["id"])

        self.assertEqual(result["state"], "removed")
        self.assertEqual(codex_runtime_services._read_projects(self.shared_home), [])

    def test_process_parser_redacts_command_and_fingerprints_identity(self):
        output = "123 1 me S 00:01 /bin/zsh -lc npm run dev --token=secret\n"
        process = codex_runtime_services._processes(output)[0]

        self.assertEqual(process["pid"], 123)
        self.assertEqual(process["command"], "/bin/zsh -lc npm run dev --token=[REDACTED]")
        self.assertRegex(process["fingerprint"], r"^[a-f0-9]{16}$")

    def test_stop_process_refuses_non_playwright_process(self):
        process_output = "123 1 me S 00:01 /bin/zsh -lc npm run dev\n"
        fingerprint = codex_runtime_services._processes(process_output)[0]["fingerprint"]
        with patch.object(codex_runtime_services, "_run", return_value=(process_output, None)):
            result = codex_runtime_services.stop_process(123, fingerprint)

        self.assertEqual(result, {"ok": False, "error": "process is not a safe Codex automation daemon"})

    def test_discovery_keeps_codex_port_evidence_and_deduplicates_tasks(self):
        tasks = [
            {
                "id": "task-1",
                "conversationId": "conversation-1",
                "cwd": str(self.project_dir),
                "command": "npm run dev -- --port 5173",
                "updatedAtMs": 2,
            },
            {
                "id": "task-2",
                "conversationId": "conversation-2",
                "cwd": str(self.project_dir),
                "command": "npm run dev -- --port 5173",
                "updatedAtMs": 1,
            },
        ]
        ports = [{"pid": 321, "port": 5173, "process": "node"}]
        processes = [{"pid": 321, "command": "node dev-server", "_raw_command": "node dev-server"}]

        services = codex_runtime_services._discovered_services(tasks, ports, processes, [])

        self.assertEqual(len(services), 1)
        self.assertEqual(services[0]["source_task_ids"], ["conversation-1", "conversation-2"])
        self.assertTrue(services[0]["port_listening"])
        self.assertTrue(services[0]["can_register"])

    def test_discovery_does_not_register_a_historical_command_that_kills_a_pid(self):
        tasks = [{
            "id": "task-1",
            "cwd": str(self.project_dir),
            "command": "kill 69978 && python3 -m demo.server --port 5173",
        }]

        services = codex_runtime_services._discovered_services(tasks, [], [], [])

        self.assertFalse(services[0]["can_register"])
        self.assertIn("结束进程", services[0]["reason"])
        self.assertIn("移除", services[0]["action_hint"])

    def test_start_project_refuses_an_already_occupied_port(self):
        project = codex_runtime_services.add_project(
            self.shared_home,
            "Demo",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
        )
        lsof_output = "p321\ncnode\nPTCP\nn127.0.0.1:5173\n"
        with (
            patch.object(codex_runtime_services, "_pid_alive", return_value=False),
            patch.object(codex_runtime_services, "_run", return_value=(lsof_output, None)),
        ):
            with self.assertRaisesRegex(RuntimeError, "already in use"):
                codex_runtime_services.start_project(self.shared_home, project["id"])

    def test_adopted_stop_refuses_a_replaced_process(self):
        project = codex_runtime_services.add_project(
            self.shared_home,
            "Demo",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
            adopted_from_codex=True,
        )
        projects = codex_runtime_services._read_projects(self.shared_home)
        projects[0].update(
            {
                "pid": 321,
                "pgid": 321,
                "owner_fingerprint": "0000000000000000",
            }
        )
        codex_runtime_services._write_projects(self.shared_home, projects)
        lsof_output = "p321\ncnode\nPTCP\nn127.0.0.1:5173\n"
        ps_output = "321 1 me S 00:01 node replacement-server\n"
        with (
            patch.object(codex_runtime_services, "_pid_alive", return_value=False),
            patch.object(
                codex_runtime_services,
                "_run",
                side_effect=[(lsof_output, None), (ps_output, None)],
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "process changed"):
                codex_runtime_services.stop_project(self.shared_home, project["id"])

    def test_shared_registered_port_disables_start_and_stop(self):
        first = codex_runtime_services.add_project(
            self.shared_home,
            "First",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
            adopted_from_codex=True,
        )
        second = codex_runtime_services.add_project(
            self.shared_home,
            "Second",
            str(self.project_dir),
            "python3 -m http.server 5173 --bind 127.0.0.1",
            5173,
            adopted_from_codex=True,
        )
        projects = codex_runtime_services._read_projects(self.shared_home)
        for project in projects:
            project.update({"pid": 321, "pgid": 321})
        codex_runtime_services._write_projects(self.shared_home, projects)
        process_output = "321 1 me S 00:01 node server\n"
        trusted_fingerprint = codex_runtime_services._processes(process_output)[0]["fingerprint"]
        for project in projects:
            project["owner_fingerprint"] = trusted_fingerprint
        codex_runtime_services._write_projects(self.shared_home, projects)
        lsof_output = "p321\ncnode\nPTCP\nn127.0.0.1:5173\n"
        with (
            patch.object(codex_runtime_services, "_pid_alive", return_value=True),
            patch.object(
                codex_runtime_services,
                "_run",
                side_effect=[(process_output, None), (lsof_output, None)],
            ),
            patch("codex_profile_dashboard._chat_process_files", return_value=[]),
        ):
            payload = codex_runtime_services.build_payload(self.shared_home, self.root / "profiles")

        self.assertEqual({project["id"] for project in payload["projects"]}, {first["id"], second["id"]})
        self.assertTrue(all(not project["can_start"] for project in payload["projects"]))
        self.assertTrue(all(not project["can_stop"] for project in payload["projects"]))
        self.assertTrue(all(project["can_switch"] for project in payload["projects"]))
        self.assertTrue(all(project["state"] == "registration_conflict" for project in payload["projects"]))
        self.assertTrue(all("端口" in project["reason"] for project in payload["projects"]))
        self.assertTrue(all("切换启动" in project["action_hint"] for project in payload["projects"]))

    def test_switch_project_stops_a_verified_shared_listener_then_starts_the_target(self):
        first = codex_runtime_services.add_project(
            self.shared_home,
            "First",
            str(self.project_dir),
            "python3 -m http.server 5173",
            5173,
            adopted_from_codex=True,
        )
        second = codex_runtime_services.add_project(
            self.shared_home,
            "Second",
            str(self.project_dir),
            "python3 -m http.server 5173 --bind 127.0.0.1",
            5173,
            adopted_from_codex=True,
        )
        projects = codex_runtime_services._read_projects(self.shared_home)
        for project in projects:
            project.update({"pid": 321, "pgid": 321, "owner_fingerprint": "trusted"})
        codex_runtime_services._write_projects(self.shared_home, projects)

        with (
            patch.object(
                codex_runtime_services,
                "_current_port_owner",
                side_effect=[{"pid": 321}, None],
            ),
            patch.object(
                codex_runtime_services,
                "_process_for_pid",
                return_value={"fingerprint": "trusted"},
            ),
            patch.object(codex_runtime_services, "stop_project", return_value={"ok": True}) as stop,
            patch.object(
                codex_runtime_services,
                "start_project",
                return_value={"ok": True, "state": "started", "project": second},
            ) as start,
        ):
            result = codex_runtime_services.switch_project(self.shared_home, second["id"])

        self.assertTrue(result["ok"])
        stop.assert_called_once_with(self.shared_home, first["id"])
        start.assert_called_once_with(self.shared_home, second["id"])


if __name__ == "__main__":
    unittest.main()
