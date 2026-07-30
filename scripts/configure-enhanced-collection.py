#!/usr/bin/env python3
"""Idempotently configure optional Codex workbench lifecycle collection."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any


EVENT_MATCHERS = {
    "SessionStart": "*",
    "Stop": "*",
    "PreCompact": "manual|auto",
}
COLLECTOR_NAME = "codex-workbench-lifecycle.py"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--status", action="store_true")
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--install", action="store_true")
    mode.add_argument("--uninstall", action="store_true")
    parser.add_argument("--home", type=Path, default=Path.home())
    return parser.parse_args()


def source_collector() -> Path:
    return Path(__file__).resolve().parent / "hooks" / COLLECTOR_NAME


def target_collector(home: Path) -> Path:
    return home.absolute() / ".codex" / "operation-ledger" / "hooks" / COLLECTOR_NAME


def legacy_target_collector(home: Path) -> Path:
    return home.absolute() / ".codex" / "codex-workbench" / "hooks" / COLLECTOR_NAME


def config_path(home: Path) -> Path:
    return home.absolute() / ".codex" / "hooks.json"


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"hooks": {}}
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"配置路径不是普通文件：{path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"无法读取有效 hooks.json：{error}") from error
    if not isinstance(value, dict):
        raise ValueError("hooks.json 根节点必须是对象")
    hooks = value.get("hooks")
    if hooks is None:
        value["hooks"] = {}
    elif not isinstance(hooks, dict):
        raise ValueError("hooks.json 的 hooks 字段必须是对象")
    return value


def own_hook(command: str) -> dict[str, Any]:
    return {
        "type": "command",
        "command": command,
        "timeout": 10,
    }


def merge_config(config: dict[str, Any], command: str) -> bool:
    hooks = config["hooks"]
    changed = False
    for event_name, matcher in EVENT_MATCHERS.items():
        groups = hooks.get(event_name)
        if groups is None:
            groups = []
            hooks[event_name] = groups
            changed = True
        if not isinstance(groups, list):
            raise ValueError(f"{event_name} Hook 组必须是数组")
        found = False
        for group in groups:
            if not isinstance(group, dict):
                raise ValueError(f"{event_name} Hook 组成员必须是对象")
            commands = group.get("hooks")
            if not isinstance(commands, list):
                raise ValueError(f"{event_name} Hook 组的 hooks 必须是数组")
            for hook in commands:
                if (
                    isinstance(hook, dict)
                    and hook.get("type") == "command"
                    and hook.get("command") == command
                ):
                    found = True
        if not found:
            groups.append({"matcher": matcher, "hooks": [own_hook(command)]})
            changed = True
    return changed


def remove_own_hooks(config: dict[str, Any], command: str) -> bool:
    hooks = config["hooks"]
    changed = False
    for event_name in list(hooks):
        groups = hooks[event_name]
        if not isinstance(groups, list):
            raise ValueError(f"{event_name} Hook 组必须是数组")
        retained_groups: list[Any] = []
        for group in groups:
            if not isinstance(group, dict):
                raise ValueError(f"{event_name} Hook 组成员必须是对象")
            commands = group.get("hooks")
            if not isinstance(commands, list):
                raise ValueError(f"{event_name} Hook 组的 hooks 必须是数组")
            retained_commands = [
                hook
                for hook in commands
                if not (
                    isinstance(hook, dict)
                    and hook.get("type") == "command"
                    and hook.get("command") == command
                )
            ]
            if len(retained_commands) != len(commands):
                changed = True
            if retained_commands:
                if retained_commands != commands:
                    group = dict(group)
                    group["hooks"] = retained_commands
                retained_groups.append(group)
        if retained_groups:
            hooks[event_name] = retained_groups
        elif groups:
            del hooks[event_name]
    return changed


def is_enabled(config: dict[str, Any], command: str, collector: Path) -> bool:
    if not collector.is_file() or collector.is_symlink():
        return False
    hooks = config["hooks"]
    for event_name in EVENT_MATCHERS:
        groups = hooks.get(event_name)
        if not isinstance(groups, list):
            return False
        if not any(
            isinstance(group, dict)
            and isinstance(group.get("hooks"), list)
            and any(
                isinstance(hook, dict)
                and hook.get("type") == "command"
                and hook.get("command") == command
                for hook in group["hooks"]
            )
            for group in groups
        ):
            return False
    return True


def serialized(config: dict[str, Any]) -> bytes:
    return (json.dumps(config, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def backup_config(path: Path) -> None:
    if not path.exists():
        return
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    shutil.copy2(path, path.with_name(f"{path.name}.bak.{stamp}"))


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
        os.chmod(path, mode)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def same_contents(first: Path, second: Path) -> bool:
    def digest(path: Path) -> bytes:
        result = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(65_536), b""):
                result.update(block)
        return result.digest()

    return first.is_file() and second.is_file() and digest(first) == digest(second)


def validate_target(path: Path) -> None:
    if path.exists() and (path.is_dir() or path.is_symlink() or not path.is_file()):
        raise ValueError(f"collector 目标路径冲突：{path}")


def migrate_legacy_collector(home: Path, source: Path) -> bool:
    legacy = legacy_target_collector(home)
    if not legacy.exists() and not legacy.is_symlink():
        return False
    if legacy.is_symlink() or not legacy.is_file() or not same_contents(legacy, source):
        raise ValueError(f"旧 collector 不是可安全迁移的工作台文件：{legacy}")
    legacy.unlink()
    prune_empty_legacy_directories(home)
    return True


def prune_empty_legacy_directories(home: Path) -> None:
    legacy = legacy_target_collector(home)
    for directory in (legacy.parent, legacy.parent.parent):
        if directory.is_symlink() or not directory.is_dir():
            continue
        try:
            directory.rmdir()
        except OSError:
            pass


def install(home: Path, dry_run: bool) -> None:
    source = source_collector()
    if not source.is_file():
        raise ValueError(f"collector 源文件不存在：{source}")
    target = target_collector(home)
    validate_target(target)
    path = config_path(home)
    config = load_config(path)
    legacy = legacy_target_collector(home)
    legacy_is_managed = legacy.exists() or legacy.is_symlink()
    if legacy_is_managed and (
        legacy.is_symlink() or not legacy.is_file() or not same_contents(legacy, source)
    ):
        raise ValueError(f"旧 collector 不是可安全迁移的工作台文件：{legacy}")
    changed = remove_own_hooks(config, str(legacy))
    changed = merge_config(config, str(target)) or changed
    if dry_run:
        print("将启用 SessionStart / Stop / PreCompact 增强日志；不会覆盖其他 Hook。")
        return
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    atomic_write(target, source.read_bytes(), 0o700)
    if changed:
        backup_config(path)
        atomic_write(path, serialized(config), 0o600)
    if legacy_is_managed:
        migrate_legacy_collector(home, source)
    else:
        prune_empty_legacy_directories(home)
    print("增强日志已启用。")


def uninstall(home: Path) -> None:
    target = target_collector(home)
    path = config_path(home)
    config = load_config(path)
    changed = remove_own_hooks(config, str(target))
    if changed:
        backup_config(path)
        atomic_write(path, serialized(config), 0o600)
    source = source_collector()
    if target.exists() and not target.is_symlink() and same_contents(target, source):
        target.unlink()
    print("增强日志已停用；其他 Hook 保持不变。")


def main() -> int:
    args = parse_args()
    try:
        home = args.home.expanduser()
        if args.status:
            target = target_collector(home)
            config = load_config(config_path(home))
            print("增强日志已启用" if is_enabled(config, str(target), target) else "增强日志未启用")
        elif args.dry_run:
            install(home, dry_run=True)
        elif args.install:
            install(home, dry_run=False)
        else:
            uninstall(home)
    except ValueError as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
