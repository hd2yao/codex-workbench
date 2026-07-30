"""Codex-scoped project services and automation process controls."""

from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path


MANAGED_PROJECTS_FILE = "codex-workbench-projects.json"
PROJECT_SECRET_RE = re.compile(
    r"(?i)(?:--?(?:api[-_]?key|access[-_]?token|refresh[-_]?token|token|password|passwd|secret|cookie)(?:=|\s+)|(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie|authorization)\s*=)"
)
PROJECT_UNSAFE_COMMAND_RE = re.compile(r"(?i)(?:^|[;&|]\s*)kill\s+\d+")
RUNTIME_SECRET_RE = re.compile(
    r"(?i)(--?(?:api[-_]?key|access[-_]?token|refresh[-_]?token|token|password|passwd|secret|cookie)(?:=|\s+))([^\s]+)"
)
RUNTIME_ASSIGNMENT_SECRET_RE = re.compile(
    r"(?i)((?:authorization|cookie|api[_-]?key|access[-_]?token|refresh[-_]?token|password|secret)=)([^\s]+)"
)
PLAYWRIGHT_DAEMON = "playwright-core/lib/entry/cliDaemon.js"
STARTUP_FAILURE_GRACE_SECONDS = 0.35


def redact_command(command: str) -> str:
    value = RUNTIME_SECRET_RE.sub(r"\1[REDACTED]", command)
    return RUNTIME_ASSIGNMENT_SECRET_RE.sub(r"\1[REDACTED]", value)


def _normalize_project_command(command: str) -> str:
    """Restore shell quotes escaped by Codex task JSON before invoking zsh."""
    return command.strip().replace(r'\"', '"')


def _projects_path(shared_home: Path) -> Path:
    return shared_home / MANAGED_PROJECTS_FILE


def _read_projects(shared_home: Path) -> list[dict]:
    try:
        value = json.loads(_projects_path(shared_home).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    projects = value.get("projects") if isinstance(value, dict) else value
    return [item for item in projects if isinstance(item, dict)] if isinstance(projects, list) else []


def _write_projects(shared_home: Path, projects: list[dict]) -> None:
    path = _projects_path(shared_home)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps({"version": 1, "projects": projects}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    temporary.replace(path)


def _registration_key(project: dict) -> tuple[str, str, int | None]:
    """Return the stable identity for an executable project registration."""
    cwd = Path(str(project.get("cwd") or "")).expanduser().resolve()
    command = str(project.get("command") or "").strip()
    port = project.get("port")
    return str(cwd), command, port if isinstance(port, int) else None


def prune_duplicate_projects(shared_home: Path) -> dict:
    """Remove only byte-for-byte equivalent registrations, never processes."""
    projects = _read_projects(shared_home)
    seen: set[tuple[str, str, int | None]] = set()
    kept, removed = [], []
    for project in projects:
        key = _registration_key(project)
        if key in seen:
            removed.append(project)
            continue
        seen.add(key)
        kept.append(project)
    if removed:
        _write_projects(shared_home, kept)
    return {
        "ok": True,
        "removed_count": len(removed),
        "removed_project_ids": [str(project.get("id") or "") for project in removed],
    }


def remove_project(shared_home: Path, project_id: str) -> dict:
    """Forget a registry entry without signalling its process group."""
    projects, project = _find_project(shared_home, project_id)
    _write_projects(
        shared_home,
        [item for item in projects if item.get("id") != project_id],
    )
    return {"ok": True, "state": "removed", "project": project}


def add_project(
    shared_home: Path,
    name: str,
    cwd: str,
    command: str,
    port: int | None,
    adopted_from_codex: bool = False,
) -> dict:
    project_name = name.strip()
    project_cwd = Path(cwd).expanduser().resolve()
    project_command = _normalize_project_command(command)
    if not project_name or len(project_name) > 100:
        raise ValueError("project name must be 1-100 characters")
    if not project_cwd.is_dir():
        raise FileNotFoundError(f"project directory does not exist: {project_cwd}")
    if not project_command:
        raise ValueError("project command cannot be empty")
    if PROJECT_SECRET_RE.search(project_command):
        raise ValueError("project command appears to contain a credential; use environment configuration instead")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("project port must be between 1 and 65535")
    project = {
        "id": uuid.uuid4().hex,
        "name": project_name,
        "cwd": str(project_cwd),
        "command": project_command,
        "port": port,
        "pid": None,
        "pgid": None,
        "started_at_ms": None,
        "stop_requested_at_ms": None,
        "last_error": None,
        "adopted_from_codex": adopted_from_codex,
    }
    projects = _read_projects(shared_home)
    project_key = _registration_key(project)
    existing = next(
        (item for item in projects if _registration_key(item) == project_key),
        None,
    )
    if existing is not None:
        return existing
    projects.append(project)
    _write_projects(shared_home, projects)
    return project


def _find_project(shared_home: Path, project_id: str) -> tuple[list[dict], dict]:
    projects = _read_projects(shared_home)
    for project in projects:
        if project.get("id") == project_id:
            return projects, project
    raise ValueError("managed project not found")


def _pid_alive(pid: object) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def start_project(shared_home: Path, project_id: str) -> dict:
    projects, project = _find_project(shared_home, project_id)
    cwd = Path(str(project.get("cwd") or "")).expanduser()
    if not cwd.is_dir():
        raise FileNotFoundError(f"project directory does not exist: {cwd}")
    if _pid_alive(project.get("pid")):
        return {"ok": True, "state": "already_running", "project": project}
    command = _normalize_project_command(str(project.get("command") or ""))
    if not command:
        raise ValueError("project command cannot be empty")
    project["command"] = command
    if project.get("port"):
        port_output, port_error = _run(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"]
        )
        if port_error is None:
            owner = _port_owner(int(project["port"]), _ports(port_output))
            if owner:
                raise RuntimeError(
                    f"port {project['port']} is already in use by PID {owner.get('pid')}"
                )
    log_dir = shared_home / "logs" / "codex-workbench-projects"
    log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    log_path = log_dir / f"{project_id}.log"
    with log_path.open("ab") as log_file:
        process = subprocess.Popen(
            ["/bin/zsh", "-lc", command],
            cwd=str(cwd),
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    project.update(
        {
            "pid": process.pid,
            "pgid": process.pid,
            "started_at_ms": int(time.time() * 1000),
            "stop_requested_at_ms": None,
            "last_error": None,
        }
    )
    deadline = time.monotonic() + STARTUP_FAILURE_GRACE_SECONDS
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.025)
    if process.poll() is not None:
        project.update(
            {
                "pid": None,
                "pgid": None,
                "last_error": _startup_failure_message(log_path),
            }
        )
        _write_projects(shared_home, projects)
        raise RuntimeError(str(project["last_error"]))
    _write_projects(shared_home, projects)
    return {"ok": True, "state": "started", "project": project}


def _current_port_owner(port: int) -> dict | None:
    output, error = _run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"])
    return _port_owner(port, _ports(output)) if error is None else None


def switch_project(shared_home: Path, project_id: str) -> dict:
    """Replace a verified shared-port Codex service with the chosen registration."""
    projects, target = _find_project(shared_home, project_id)
    port = target.get("port")
    if not isinstance(port, int):
        raise ValueError("project must have a port before it can switch services")
    conflicts = [item for item in projects if item.get("port") == port]
    if len(conflicts) < 2:
        raise RuntimeError("project has no shared registered port to switch")
    owner = _current_port_owner(port)
    if not owner or not isinstance(owner.get("pid"), int):
        return start_project(shared_home, project_id)
    process = _process_for_pid(owner["pid"])
    fingerprints = {str(item.get("owner_fingerprint") or "") for item in conflicts}
    if (
        process is None
        or len(fingerprints) != 1
        or not next(iter(fingerprints))
        or process["fingerprint"] not in fingerprints
    ):
        raise RuntimeError("shared port owner cannot be verified; refusing to switch")
    active = next(
        (
            item
            for item in conflicts
            if item.get("id") != project_id and item.get("pid") == owner["pid"]
        ),
        None,
    )
    if active is None:
        raise RuntimeError("shared port registration does not match the verified listener")
    stop_project(shared_home, str(active["id"]))
    deadline = time.monotonic() + 3.0
    owner = _current_port_owner(port)
    while owner is not None and time.monotonic() < deadline:
        time.sleep(0.05)
        owner = _current_port_owner(port)
    if owner is not None:
        raise RuntimeError(f"port {port} did not stop within 3 seconds")
    return start_project(shared_home, project_id)


def _startup_failure_message(log_path: Path) -> str:
    try:
        detail = log_path.read_text(encoding="utf-8", errors="replace")[-1200:].strip()
    except OSError:
        detail = ""
    if detail:
        return f"启动命令立即退出：{redact_command(detail)}"
    return "启动命令立即退出；请检查启动命令和项目依赖。"


def stop_project(shared_home: Path, project_id: str) -> dict:
    projects, project = _find_project(shared_home, project_id)
    pid = project.get("pid")
    pgid = project.get("pgid")
    if not _pid_alive(pid):
        owner = None
        if project.get("adopted_from_codex") and project.get("port"):
            port_output, port_error = _run(
                ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"]
            )
            if port_error is None:
                owner = _port_owner(int(project["port"]), _ports(port_output))
        if owner and isinstance(owner.get("pid"), int):
            pid = owner["pid"]
            process = _process_for_pid(pid)
            expected_fingerprint = project.get("owner_fingerprint")
            if process is None or not expected_fingerprint or process["fingerprint"] != expected_fingerprint:
                raise RuntimeError("claimed project process changed; refusing to stop")
            pgid = os.getpgid(pid)
            if pgid <= 1 or pgid == os.getpgrp():
                raise RuntimeError("claimed project process group is unsafe; refusing to stop")
            os.killpg(pgid, signal.SIGTERM)
            project.update({"pid": pid, "pgid": pgid, "stop_requested_at_ms": int(time.time() * 1000)})
            _write_projects(shared_home, projects)
            return {"ok": True, "state": "stop_requested", "project": project}
        project.update({"pid": None, "pgid": None, "stop_requested_at_ms": None})
        _write_projects(shared_home, projects)
        return {"ok": True, "state": "already_stopped", "project": project}
    if not isinstance(pgid, int) or pgid <= 1 or os.getpgid(pid) != pgid:
        raise RuntimeError("managed project process group changed; refusing to stop")
    os.killpg(pgid, signal.SIGTERM)
    project["stop_requested_at_ms"] = int(time.time() * 1000)
    _write_projects(shared_home, projects)
    return {"ok": True, "state": "stop_requested", "project": project}


def _run(args: list[str]) -> tuple[str, str | None]:
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=False)
    except OSError as exc:
        return "", str(exc)
    return result.stdout or "", None if result.returncode == 0 else (result.stderr or "command failed").strip()


def _fingerprint(pid: int, ppid: int, user: str, command: str) -> str:
    raw = f"{pid}\0{ppid}\0{user}\0{command}".encode("utf-8", errors="ignore")
    return hashlib.sha256(raw).hexdigest()[:16]


def _processes(output: str) -> list[dict]:
    result = []
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=5)
        if len(fields) != 6:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        user, status, elapsed, command = fields[2:]
        result.append(
            {
                "pid": pid,
                "ppid": ppid,
                "user": user,
                "status": "运行中" if "Z" not in status else "已退出等待清理",
                "command": redact_command(command),
                "_raw_command": command,
                "fingerprint": _fingerprint(pid, ppid, user, command),
            }
        )
    return result


def _process_for_pid(pid: int) -> dict | None:
    output, error = _run(["ps", "-p", str(pid), "-o", "pid=,ppid=,user=,stat=,etime=,command="])
    if error is not None:
        return None
    return next((item for item in _processes(output) if item["pid"] == pid), None)


def _ports(output: str) -> list[dict]:
    result, current, protocol = [], None, "TCP"
    for line in output.splitlines():
        if not line:
            continue
        field, value = line[0], line[1:]
        if field == "p":
            current = {"pid": int(value) if value.isdigit() else None}
            protocol = "TCP"
        elif field == "c" and current is not None:
            current["process"] = value
        elif field == "P":
            protocol = value or "TCP"
        elif field == "n" and current is not None:
            match = re.search(r":(\d+)$", value)
            if match:
                result.append(
                    {
                        "pid": current.get("pid"),
                        "process": current.get("process") or "未知",
                        "protocol": protocol,
                        "port": int(match.group(1)),
                        "endpoint": value,
                    }
                )
    return result


def _port_owner(port: int | None, ports: list[dict]) -> dict | None:
    if port is None:
        return None
    return next((item for item in ports if item.get("port") == port), None)


def _task_port_hints(command: str) -> list[int]:
    values = []
    for value in re.findall(r"(?:--port|port)\s*[=:]?\s*(\d{2,5})", command):
        port = int(value)
        if 1 <= port <= 65535 and port not in values:
            values.append(port)
    return values


def _service_kind(command: str) -> str:
    lowered = command.lower()
    if re.search(r"\b(uvicorn|gunicorn|flask|fastapi|django|python(?:3)?\s+-m)\b", lowered):
        return "backend"
    if re.search(
        r"\b(vite|next|nuxt|webpack|astro|react-scripts|hyperframes)\b|\b(?:npm|pnpm|yarn)\s+(?:run\s+)?(?:dev|start)\b",
        lowered,
    ):
        return "web"
    return "unknown"


def _project_state_details(
    project: dict,
    *,
    alive: bool,
    owner: dict | None,
    shared_port_count: int,
    duplicate_count: int,
) -> tuple[str, str, str, str, bool, bool]:
    """Return state, label, reason, next step, startability and stopability."""
    port = project.get("port")
    if duplicate_count > 1:
        return (
            "duplicate_registration",
            "重复登记",
            f"相同目录、命令和端口已登记 {duplicate_count} 次；为避免误停，当前不执行启动或停止。",
            "保留一条后点击“清理重复登记”；该操作只删除登记，不会结束进程。",
            False,
            False,
        )
    if shared_port_count > 1:
        return (
            "registration_conflict",
            "登记端口冲突",
            f"端口 {port} 同时登记给 {shared_port_count} 个项目，当前归属不明确。",
            "删除无关登记后再启动；删除登记不会释放正在监听的端口。",
            False,
            False,
        )
    if alive:
        return (
            "running",
            "运行中",
            f"受管进程 PID {project.get('pid')} 正在运行。",
            "可打开服务，或停止后释放端口。",
            False,
            True,
        )
    if owner:
        return (
            "port_in_use",
            "端口被外部占用",
            f"端口 {port} 正由 PID {owner.get('pid')} 监听，但不是可验证的受管进程。",
            "请先确认占用进程归属；不要从此行强制停止。端口释放后可启动本项目。",
            False,
            bool(project.get("adopted_from_codex")),
        )
    return (
        "stopped",
        "已停止",
        "未检测到受管进程，端口当前未监听。",
        "可点击“启动”按登记命令启动此项目。",
        True,
        False,
    )


def _can_switch_registered_port(
    project: dict,
    registered_projects: list[dict],
    owner: dict | None,
    processes: list[dict],
) -> bool:
    port = project.get("port")
    if not isinstance(port, int) or not owner or not isinstance(owner.get("pid"), int):
        return False
    conflicts = [item for item in registered_projects if item.get("port") == port]
    expected_fingerprints = {str(item.get("owner_fingerprint") or "") for item in conflicts}
    process = next((item for item in processes if item.get("pid") == owner["pid"]), None)
    return (
        len(conflicts) > 1
        and all(item.get("adopted_from_codex") is True for item in conflicts)
        and len(expected_fingerprints) == 1
        and bool(next(iter(expected_fingerprints)))
        and process is not None
        and process.get("fingerprint") in expected_fingerprints
    )


def _discovered_services(
    task_records: list[dict],
    ports: list[dict],
    processes: list[dict],
    registered_projects: list[dict],
) -> list[dict]:
    registered_keys = {
        (str(item.get("cwd") or ""), item.get("port"))
        for item in registered_projects
    }
    candidates: dict[tuple[str, int], dict] = {}
    for item in task_records:
        cwd = str(item.get("cwd") or "")
        command = str(item.get("command") or "")
        if not cwd or not command:
            continue
        for port in _task_port_hints(command):
            key = (cwd, port)
            if key in registered_keys:
                continue
            owner = _port_owner(port, ports)
            safe_to_register = (
                Path(cwd).expanduser().is_dir()
                and not PROJECT_SECRET_RE.search(command)
                and not PROJECT_UNSAFE_COMMAND_RE.search(command)
            )
            candidate = candidates.get(key)
            if candidate is None:
                state = "listening" if owner else "recorded"
                reason = (
                    "来自 Codex 任务记录，可登记为项目服务"
                    if safe_to_register
                    else "目录不存在，无法登记"
                    if not Path(cwd).expanduser().is_dir()
                    else "启动命令包含凭据，需改用项目环境配置"
                )
                if PROJECT_UNSAFE_COMMAND_RE.search(command):
                    reason = "历史命令包含结束进程的操作，不能直接登记执行"
                action_hint = (
                    "登记后可一键启动、停止和打开服务。"
                    if safe_to_register and owner
                    else "登记后可一键启动和停止。"
                    if safe_to_register
                    else "恢复项目目录后再登记。"
                    if not Path(cwd).expanduser().is_dir()
                    else "请移除历史命令中的结束进程操作，再填写安全的启动命令。"
                    if PROJECT_UNSAFE_COMMAND_RE.search(command)
                    else "请将凭据移到项目环境配置后再登记。"
                )
                candidate = {
                    "id": "discovered-" + hashlib.sha256(f"{cwd}\0{port}".encode()).hexdigest()[:16],
                    "name": Path(cwd).name or f"端口 {port}",
                    "source": "codex_task",
                    "source_task_ids": [],
                    "cwd": cwd,
                    "command": redact_command(command),
                    "port": port,
                    "state": state,
                    "state_label": "当前监听" if owner else "历史记录",
                    "port_listening": owner is not None,
                    "port_owner_pid": owner.get("pid") if owner else None,
                    "port_owner_command": next(
                        (process["command"] for process in processes if owner and process["pid"] == owner.get("pid")),
                        None,
                    ),
                    "can_register": safe_to_register,
                    "reason": reason,
                    "action_hint": action_hint,
                    "can_open": owner is not None,
                    "service_url": f"http://127.0.0.1:{port}" if owner else None,
                    "service_kind": _service_kind(command),
                    "last_seen_at_ms": item.get("updatedAtMs") or item.get("startedAtMs"),
                }
                candidates[key] = candidate
            task_id = str(item.get("conversationId") or item.get("id") or "")
            if task_id and task_id not in candidate["source_task_ids"]:
                candidate["source_task_ids"].append(task_id)
            if owner and not candidate["port_listening"]:
                candidate.update(
                    {
                        "state": "listening",
                        "state_label": "当前监听",
                        "port_listening": True,
                        "port_owner_pid": owner.get("pid"),
                        "port_owner_command": next(
                            (
                                process["command"]
                                for process in processes
                                if process["pid"] == owner.get("pid")
                            ),
                            None,
                        ),
                        "can_open": True,
                        "service_url": f"http://127.0.0.1:{port}",
                    }
                )
    return sorted(
        candidates.values(),
        key=lambda item: (not item["port_listening"], item["port"], item["cwd"]),
    )


def build_payload(shared_home: Path, profile_root: Path) -> dict:
    from codex_profile_dashboard import _chat_process_files

    process_output, process_error = _run(["ps", "-axo", "pid=,ppid=,user=,stat=,etime=,command="])
    processes = _processes(process_output)
    port_output, port_error = _run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"])
    ports = _ports(port_output)
    registered_projects = _read_projects(shared_home)
    registered_port_counts: dict[int, int] = {}
    registered_definition_counts: dict[tuple[str, str, int | None], int] = {}
    for registered_project in registered_projects:
        port = registered_project.get("port")
        if isinstance(port, int):
            registered_port_counts[port] = registered_port_counts.get(port, 0) + 1
        key = _registration_key(registered_project)
        registered_definition_counts[key] = registered_definition_counts.get(key, 0) + 1

    projects = []
    for project in registered_projects:
        value = dict(project)
        alive = _pid_alive(value.get("pid"))
        port = value.get("port")
        owner = next((item for item in ports if item.get("port") == port), None) if port else None
        shared_port_count = registered_port_counts.get(port, 0) if isinstance(port, int) else 0
        duplicate_count = registered_definition_counts.get(_registration_key(value), 0)
        state, state_label, reason, action_hint, can_start, can_stop = _project_state_details(
            value,
            alive=alive,
            owner=owner,
            shared_port_count=shared_port_count,
            duplicate_count=duplicate_count,
        )
        can_switch = state == "registration_conflict" and _can_switch_registered_port(
            value,
            registered_projects,
            owner,
            processes,
        )
        if can_switch:
            action_hint = "可点击“切换启动”：安全停止当前同端口受管服务后启动此项目。"
        value.update(
            {
                "state": state,
                "state_label": state_label,
                "reason": reason,
                "action_hint": action_hint,
                "can_start": can_start,
                "can_stop": can_stop,
                "can_switch": can_switch,
                "can_remove": True,
                "can_open": owner is not None,
                "service_url": f"http://127.0.0.1:{port}" if owner and port else None,
                "service_kind": _service_kind(str(value.get("command") or "")),
                "duplicate_registration_count": duplicate_count,
                "conflicting_registration_count": shared_port_count,
                "port_listening": owner is not None,
                "port_owner_pid": owner.get("pid") if owner else None,
                "port_owner_command": next(
                    (item["command"] for item in processes if item["pid"] == owner.get("pid")),
                    None,
                )
                if owner
                else None,
                "command": redact_command(str(value.get("command") or "")),
            }
        )
        projects.append(value)

    task_records = {}
    for path in _chat_process_files(shared_home, profile_root):
        try:
            rows = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            rows = []
        for item in rows if isinstance(rows, list) else []:
            if isinstance(item, dict) and item.get("id"):
                task_records[str(item["id"])] = item

    codex_tasks = []
    listening = {item["port"] for item in ports}
    for item in sorted(
        task_records.values(),
        key=lambda row: row.get("updatedAtMs") or row.get("startedAtMs") or 0,
        reverse=True,
    )[:80]:
        command = str(item.get("command") or "")
        pid = item.get("osPid") if isinstance(item.get("osPid"), int) else None
        related = _task_port_hints(command)
        listening_related = [port for port in related if port in listening]
        alive = _pid_alive(pid)
        codex_tasks.append(
            {
                "id": str(item["id"]),
                "task_id": str(item.get("conversationId") or item["id"]),
                "cwd": item.get("cwd"),
                "command": redact_command(command),
                "pid": pid,
                "state": "running" if alive else ("running_by_port" if listening_related else "recorded"),
                "state_label": "运行中" if alive else ("端口仍在监听" if listening_related else "历史记录"),
                "kind": "browser_automation" if re.search(r"(?i)(playwright|browser|chrome)", command) else "task_process",
                "related_ports": related,
                "port_owner_pid": next((item["pid"] for item in ports if item["port"] in listening_related), None),
                "updated_at_ms": item.get("updatedAtMs") or item.get("startedAtMs"),
                "can_stop": False,
            }
        )

    discovered_services = _discovered_services(
        list(task_records.values()),
        ports,
        processes,
        projects,
    )

    browser_processes = []
    for process in processes:
        command = process["_raw_command"]
        if PLAYWRIGHT_DAEMON not in command:
            continue
        label_match = re.search(r"cliDaemon\.js\s+(\S+)", command)
        browser_processes.append(
            {
                "id": f"process:{process['pid']}",
                "task_label": label_match.group(1) if label_match else None,
                "pid": process["pid"],
                "state": "running",
                "state_label": "运行中",
                "kind": "browser_automation",
                "command": process["command"],
                "can_stop": True,
                "fingerprint": process["fingerprint"],
            }
        )
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "projects": projects,
        "discovered_services": discovered_services,
        "codex_tasks": codex_tasks,
        "browser_processes": browser_processes,
        "errors": {"processes": process_error, "ports": port_error},
    }


def claim_project(shared_home: Path, project_id: str) -> dict:
    projects, project = _find_project(shared_home, project_id)
    port = project.get("port")
    if not isinstance(port, int):
        raise ValueError("project must have a port before it can claim an active service")
    port_output, port_error = _run(
        ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnP"]
    )
    if port_error is not None:
        raise RuntimeError(f"cannot inspect port {port}: {port_error}")
    owner = _port_owner(port, _ports(port_output))
    if not owner or not isinstance(owner.get("pid"), int):
        raise RuntimeError(f"port {port} is not currently listening")
    pgid = os.getpgid(owner["pid"])
    if pgid <= 1 or pgid == os.getpgrp():
        raise RuntimeError("claimed project process group is unsafe; refusing to claim")
    process = _process_for_pid(owner["pid"])
    if process is None:
        raise RuntimeError("claimed project process disappeared; refusing to claim")
    project.update(
        {
            "adopted_from_codex": True,
            "pid": owner["pid"],
            "pgid": pgid,
            "owner_fingerprint": process["fingerprint"],
            "last_error": None,
        }
    )
    _write_projects(shared_home, projects)
    return {"ok": True, "state": "claimed", "project": project}


def stop_process(pid: int, fingerprint: str) -> dict:
    process_output, _ = _run(["ps", "-p", str(pid), "-o", "pid=,ppid=,user=,stat=,etime=,command="])
    process = next((item for item in _processes(process_output) if item["pid"] == pid), None)
    if process is None or process["fingerprint"] != fingerprint:
        return {"ok": False, "error": "process changed or not found"}
    if PLAYWRIGHT_DAEMON not in process["_raw_command"]:
        return {"ok": False, "error": "process is not a safe Codex automation daemon"}
    os.kill(pid, signal.SIGTERM)
    return {"ok": True, "pid": pid, "sent": "SIGTERM"}
