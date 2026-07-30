#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_HOME="$TEST_ROOT/home"
CONFIG="$TEST_HOME/.codex/hooks.json"
CONFIGURATOR="$ROOT_DIR/scripts/configure-enhanced-collection.py"
COLLECTOR="$TEST_HOME/.codex/operation-ledger/hooks/codex-workbench-lifecycle.py"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$(dirname "$CONFIG")"
printf '%s\n' \
    '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"/existing/start.py"}]}]}}' \
    > "$CONFIG"

python3 "$CONFIGURATOR" --home "$TEST_HOME" --status \
    | grep -q "增强日志未启用"

before_dry_run="$(shasum -a 256 "$CONFIG" | awk '{print $1}')"
python3 "$CONFIGURATOR" --home "$TEST_HOME" --dry-run >/dev/null
after_dry_run="$(shasum -a 256 "$CONFIG" | awk '{print $1}')"
[[ "$before_dry_run" == "$after_dry_run" ]] \
    || { echo "FAIL: dry-run 修改了 hooks.json" >&2; exit 1; }
[[ ! -e "$COLLECTOR" ]] \
    || { echo "FAIL: dry-run 安装了 collector" >&2; exit 1; }

python3 "$CONFIGURATOR" --home "$TEST_HOME" --install >/dev/null

collector="$COLLECTOR"
[[ -x "$collector" ]] \
    || { echo "FAIL: collector 未安装为可执行文件" >&2; exit 1; }
compgen -G "$CONFIG.bak.*" >/dev/null \
    || { echo "FAIL: install 没有创建 hooks.json 备份" >&2; exit 1; }
jq -e '.hooks.SessionStart[0].hooks[] | select(.command == "/existing/start.py")' "$CONFIG" >/dev/null \
    || { echo "FAIL: install 覆盖了现有 Hook" >&2; exit 1; }

for event_name in SessionStart Stop PreCompact; do
    own_count="$(
        jq --arg event "$event_name" --arg command "$collector" \
            '[.hooks[$event][]?.hooks[]? | select(.type == "command" and .command == $command)] | length' \
            "$CONFIG"
    )"
    [[ "$own_count" == "1" ]] \
        || { echo "FAIL: $event_name 没有且仅有一个自有 Hook" >&2; exit 1; }
done

installed_hash="$(shasum -a 256 "$CONFIG" | awk '{print $1}')"
backup_count="$(find "$(dirname "$CONFIG")" -maxdepth 1 -name 'hooks.json.bak.*' | wc -l | tr -d ' ')"
python3 "$CONFIGURATOR" --home "$TEST_HOME" --install >/dev/null
reinstalled_hash="$(shasum -a 256 "$CONFIG" | awk '{print $1}')"
reinstalled_backup_count="$(find "$(dirname "$CONFIG")" -maxdepth 1 -name 'hooks.json.bak.*' | wc -l | tr -d ' ')"
[[ "$installed_hash" == "$reinstalled_hash" && "$backup_count" == "$reinstalled_backup_count" ]] \
    || { echo "FAIL: 重复 install 不幂等" >&2; exit 1; }

event_payload='{"hook_event_name":"SessionStart","session_id":"safe-session-123","cwd":"/tmp/demo","prompt":"DO_NOT_RECORD_PROMPT","token":"DO_NOT_RECORD_TOKEN","auth":"DO_NOT_RECORD_AUTH"}'
HOME="$TEST_HOME" python3 "$collector" <<<"$event_payload"
ledger="$TEST_HOME/.codex/operation-ledger/events.jsonl"
[[ -s "$ledger" ]] \
    || { echo "FAIL: collector 没有写入事件" >&2; exit 1; }
if rg -q 'DO_NOT_RECORD_(PROMPT|TOKEN|AUTH)' "$ledger"; then
    echo "FAIL: collector 泄漏了敏感输入" >&2
    exit 1
fi
jq -e '
    .schema_version == 1
    and .category == "hook"
    and .action == "codex_lifecycle_session_start"
    and .status == "success"
    and .certainty == "confirmed"
    and .actor.type == "hook"
    and .thread.id == "safe-session-123"
    and (.source_chain | type == "array")
    and (.evidence | type == "array")
' "$ledger" >/dev/null \
    || { echo "FAIL: collector 事件不兼容 OperationEvent schema" >&2; exit 1; }

python3 "$CONFIGURATOR" --home "$TEST_HOME" --uninstall >/dev/null
jq -e '.hooks.SessionStart[0].hooks[] | select(.command == "/existing/start.py")' "$CONFIG" >/dev/null \
    || { echo "FAIL: uninstall 删除了现有 Hook" >&2; exit 1; }
if jq --arg command "$collector" \
    '[.hooks[]?[]?.hooks[]? | select(.command == $command)] | length > 0' \
    "$CONFIG" | grep -q true; then
    echo "FAIL: uninstall 没有移除自有 Hook" >&2
    exit 1
fi

INVALID_HOME="$TEST_ROOT/invalid-home"
mkdir -p "$INVALID_HOME/.codex"
printf '{invalid-json\n' > "$INVALID_HOME/.codex/hooks.json"
invalid_before="$(shasum -a 256 "$INVALID_HOME/.codex/hooks.json" | awk '{print $1}')"
if python3 "$CONFIGURATOR" --home "$INVALID_HOME" --install >/dev/null 2>&1; then
    echo "FAIL: 非法 JSON 时 install 仍成功" >&2
    exit 1
fi
invalid_after="$(shasum -a 256 "$INVALID_HOME/.codex/hooks.json" | awk '{print $1}')"
[[ "$invalid_before" == "$invalid_after" ]] \
    || { echo "FAIL: 非法 JSON 时仍修改了配置" >&2; exit 1; }

CONFLICT_HOME="$TEST_ROOT/conflict-home"
mkdir -p "$CONFLICT_HOME/.codex/operation-ledger/hooks/codex-workbench-lifecycle.py"
if python3 "$CONFIGURATOR" --home "$CONFLICT_HOME" --install >/dev/null 2>&1; then
    echo "FAIL: collector 目标路径冲突时 install 仍成功" >&2
    exit 1
fi

MIGRATION_HOME="$TEST_ROOT/migration-home"
MIGRATION_CONFIG="$MIGRATION_HOME/.codex/hooks.json"
MIGRATION_COLLECTOR="$MIGRATION_HOME/.codex/operation-ledger/hooks/codex-workbench-lifecycle.py"
MIGRATION_LEGACY_COLLECTOR="$MIGRATION_HOME/.codex/codex-workbench/hooks/codex-workbench-lifecycle.py"
mkdir -p "$(dirname "$MIGRATION_LEGACY_COLLECTOR")"
cp "$ROOT_DIR/scripts/hooks/codex-workbench-lifecycle.py" "$MIGRATION_LEGACY_COLLECTOR"
chmod 700 "$MIGRATION_LEGACY_COLLECTOR"
mkdir -p "$(dirname "$MIGRATION_CONFIG")"
printf '{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}] }],"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"%s"}] }],"PreCompact":[{"matcher":"manual|auto","hooks":[{"type":"command","command":"%s"}] }]}}\n' \
    "$MIGRATION_LEGACY_COLLECTOR" \
    "$MIGRATION_LEGACY_COLLECTOR" \
    "$MIGRATION_LEGACY_COLLECTOR" > "$MIGRATION_CONFIG"

python3 "$CONFIGURATOR" --home "$MIGRATION_HOME" --install >/dev/null
[[ -x "$MIGRATION_COLLECTOR" ]] \
    || { echo "FAIL: install 没有迁移旧 collector" >&2; exit 1; }
[[ ! -e "$MIGRATION_LEGACY_COLLECTOR" ]] \
    || { echo "FAIL: install 遗留了旧 collector" >&2; exit 1; }
[[ ! -e "$MIGRATION_HOME/.codex/codex-workbench" ]] \
    || { echo "FAIL: install 遗留了与账号库冲突的空目录" >&2; exit 1; }
for event_name in SessionStart Stop PreCompact; do
    new_count="$(
        jq --arg event "$event_name" --arg command "$MIGRATION_COLLECTOR" \
            '[.hooks[$event][]?.hooks[]? | select(.type == "command" and .command == $command)] | length' \
            "$MIGRATION_CONFIG"
    )"
    old_count="$(
        jq --arg event "$event_name" --arg command "$MIGRATION_LEGACY_COLLECTOR" \
            '[.hooks[$event][]?.hooks[]? | select(.type == "command" and .command == $command)] | length' \
            "$MIGRATION_CONFIG"
    )"
    [[ "$new_count" == "1" && "$old_count" == "0" ]] \
        || { echo "FAIL: $event_name 没有完成旧 Hook 配置迁移" >&2; exit 1; }
done

STALE_HOME="$TEST_ROOT/stale-home"
mkdir -p "$STALE_HOME/.codex/codex-workbench/hooks"
python3 "$CONFIGURATOR" --home "$STALE_HOME" --install >/dev/null
[[ ! -e "$STALE_HOME/.codex/codex-workbench" ]] \
    || { echo "FAIL: install 没有清理旧 Hook 遗留的空目录" >&2; exit 1; }

echo "PASS: enhanced lifecycle collection"
