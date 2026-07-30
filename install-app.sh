#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Codex 工作台"
SOURCE_APP="${CODEX_WORKBENCH_SOURCE_APP:-$ROOT_DIR/build/$APP_NAME.app}"
INSTALL_ROOT="${CODEX_WORKBENCH_INSTALL_ROOT:-$HOME/Applications}"
DEST_APP="$INSTALL_ROOT/$APP_NAME.app"
mkdir -p "$INSTALL_ROOT"
STAGE_DIR="$(mktemp -d "$INSTALL_ROOT/.codex-workbench-install.XXXXXX")"
INSTALL_COMMITTED=0
RESTORE_PATHS=()
RESTORE_STAGED=()

rollback() {
    [[ "$INSTALL_COMMITTED" == "0" ]] || return 0
    local index
    for ((index=${#RESTORE_PATHS[@]} - 1; index >= 0; index--)); do
        if [[ -e "${RESTORE_STAGED[$index]}" ]]; then
            mv "${RESTORE_STAGED[$index]}" "${RESTORE_PATHS[$index]}" || true
        fi
    done
}

cleanup() {
    rollback
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

if [[ "${CODEX_WORKBENCH_SKIP_BUILD:-0}" != "1" ]]; then
    "$ROOT_DIR/build-app.sh"
fi
[[ -d "$SOURCE_APP" ]] || { echo "安装失败：缺少 $SOURCE_APP" >&2; exit 1; }
ditto "$SOURCE_APP" "$STAGE_DIR/$APP_NAME.app"

PREVIOUS_NAMES=("Codex 工作台" "Codex 观测站" "Codex 工具台")
for previous_name in "${PREVIOUS_NAMES[@]}"; do
    previous_path="$INSTALL_ROOT/$previous_name.app"
    if [[ -e "$previous_path" ]]; then
        staged_path="$STAGE_DIR/previous-${#RESTORE_PATHS[@]}.app"
        if ! mv "$previous_path" "$staged_path"; then
            echo "安装失败：无法暂存原有 $previous_name，已恢复原有 App。" >&2
            exit 1
        fi
        RESTORE_PATHS+=("$previous_path")
        RESTORE_STAGED+=("$staged_path")
    fi
done

if [[ "${CODEX_WORKBENCH_TEST_FAIL_FINAL_MOVE:-0}" == "1" ]] \
    || ! mv "$STAGE_DIR/$APP_NAME.app" "$DEST_APP"; then
    echo "安装失败，已恢复原有 App。" >&2
    exit 1
fi
INSTALL_COMMITTED=1

echo "已安装：$DEST_APP"
echo "可直接从 Finder、Spotlight 或菜单栏打开；旧版观测站/工具台已完成冷备迁移。"
