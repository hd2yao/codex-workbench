#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
SOURCE_APP="$TEST_ROOT/source/Codex 工作台.app"
DATA_ROOT="$TEST_ROOT/home/.codex"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$SOURCE_APP" "$DATA_ROOT"
printf 'new-app\n' > "$SOURCE_APP/marker.txt"
printf 'keep-user-data\n' > "$DATA_ROOT/user-data-marker.txt"

SUCCESS_ROOT="$TEST_ROOT/success-applications"
mkdir -p "$SUCCESS_ROOT/Codex 观测站.app" "$SUCCESS_ROOT/Codex 工具台.app"
printf 'old-observatory\n' > "$SUCCESS_ROOT/Codex 观测站.app/marker.txt"
printf 'old-toolbox\n' > "$SUCCESS_ROOT/Codex 工具台.app/marker.txt"

CODEX_WORKBENCH_INSTALL_ROOT="$SUCCESS_ROOT" \
CODEX_WORKBENCH_SOURCE_APP="$SOURCE_APP" \
CODEX_WORKBENCH_SKIP_BUILD=1 \
    "$ROOT_DIR/install-app.sh" >/dev/null

[[ -f "$SUCCESS_ROOT/Codex 工作台.app/marker.txt" ]] \
    || { echo "FAIL: 新 Codex 工作台没有安装" >&2; exit 1; }
[[ ! -e "$SUCCESS_ROOT/Codex 观测站.app" && ! -e "$SUCCESS_ROOT/Codex 工具台.app" ]] \
    || { echo "FAIL: 成功迁移后仍保留旧日常 App" >&2; exit 1; }
[[ "$(cat "$SUCCESS_ROOT/Codex 工作台.app/marker.txt")" == "new-app" ]] \
    || { echo "FAIL: 安装目标不是新的工作台" >&2; exit 1; }
[[ "$(cat "$DATA_ROOT/user-data-marker.txt")" == "keep-user-data" ]] \
    || { echo "FAIL: 安装迁移修改了用户数据根" >&2; exit 1; }

FAILURE_ROOT="$TEST_ROOT/failure-applications"
mkdir -p "$FAILURE_ROOT/Codex 观测站.app" "$FAILURE_ROOT/Codex 工具台.app"
printf 'restore-observatory\n' > "$FAILURE_ROOT/Codex 观测站.app/marker.txt"
printf 'restore-toolbox\n' > "$FAILURE_ROOT/Codex 工具台.app/marker.txt"

if CODEX_WORKBENCH_INSTALL_ROOT="$FAILURE_ROOT" \
    CODEX_WORKBENCH_SOURCE_APP="$SOURCE_APP" \
    CODEX_WORKBENCH_SKIP_BUILD=1 \
    CODEX_WORKBENCH_TEST_FAIL_FINAL_MOVE=1 \
        "$ROOT_DIR/install-app.sh" >/dev/null 2>&1; then
    echo "FAIL: 模拟最终 move 失败时安装脚本仍返回成功" >&2
    exit 1
fi

[[ ! -e "$FAILURE_ROOT/Codex 工作台.app" ]] \
    || { echo "FAIL: 失败安装留下了半成品工作台" >&2; exit 1; }
[[ "$(cat "$FAILURE_ROOT/Codex 观测站.app/marker.txt")" == "restore-observatory" ]] \
    || { echo "FAIL: 失败安装没有恢复旧观测站" >&2; exit 1; }
[[ "$(cat "$FAILURE_ROOT/Codex 工具台.app/marker.txt")" == "restore-toolbox" ]] \
    || { echo "FAIL: 失败安装没有恢复旧工具台" >&2; exit 1; }
[[ "$(cat "$DATA_ROOT/user-data-marker.txt")" == "keep-user-data" ]] \
    || { echo "FAIL: 回滚路径修改了用户数据根" >&2; exit 1; }

echo "PASS: atomic install migration"
