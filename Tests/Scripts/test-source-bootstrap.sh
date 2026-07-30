#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BOOTSTRAP="$ROOT_DIR/install-from-source.sh"
TEST_ROOT="$(mktemp -d)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

if CODEX_WORKBENCH_ARCH_OVERRIDE="x86_64" \
    CODEX_WORKBENCH_MACOS_VERSION_OVERRIDE="14.0" \
    CODEX_WORKBENCH_BOOTSTRAP_DRY_RUN=1 \
        "$BOOTSTRAP" --no-open >/dev/null 2>&1; then
    echo "FAIL: 非 arm64 仍进入构建" >&2
    exit 1
fi

if CODEX_WORKBENCH_ARCH_OVERRIDE="arm64" \
    CODEX_WORKBENCH_MACOS_VERSION_OVERRIDE="12.6" \
    CODEX_WORKBENCH_BOOTSTRAP_DRY_RUN=1 \
        "$BOOTSTRAP" --no-open >/dev/null 2>&1; then
    echo "FAIL: macOS 12 仍进入构建" >&2
    exit 1
fi

if CODEX_WORKBENCH_ARCH_OVERRIDE="arm64" \
    CODEX_WORKBENCH_MACOS_VERSION_OVERRIDE="14.0" \
    CODEX_WORKBENCH_SWIFT_BIN="$TEST_ROOT/missing-swift" \
    CODEX_WORKBENCH_BOOTSTRAP_DRY_RUN=1 \
        "$BOOTSTRAP" --no-open >/dev/null 2>&1; then
    echo "FAIL: 缺 Swift 仍进入构建" >&2
    exit 1
fi

check_root="$TEST_ROOT/check-install"
CODEX_WORKBENCH_ARCH_OVERRIDE="arm64" \
CODEX_WORKBENCH_MACOS_VERSION_OVERRIDE="14.0" \
CODEX_WORKBENCH_INSTALL_ROOT="$check_root" \
    "$BOOTSTRAP" --check | grep -q "源码构建环境已就绪"
[[ ! -e "$check_root" ]] \
    || { echo "FAIL: --check 产生了安装写入" >&2; exit 1; }

install_root="$TEST_ROOT/applications"
bootstrap_home="$TEST_ROOT/home"
log="$TEST_ROOT/bootstrap.log"
CODEX_WORKBENCH_ARCH_OVERRIDE="arm64" \
CODEX_WORKBENCH_MACOS_VERSION_OVERRIDE="14.0" \
CODEX_WORKBENCH_INSTALL_ROOT="$install_root" \
CODEX_WORKBENCH_BOOTSTRAP_HOME="$bootstrap_home" \
CODEX_WORKBENCH_BOOTSTRAP_DRY_RUN=1 \
    "$BOOTSTRAP" --no-open >"$log"

line_tools="$(rg -n 'bootstrap-release-tools.sh' "$log" | cut -d: -f1)"
line_backend="$(rg -n 'build-account-backend.sh' "$log" | cut -d: -f1)"
line_install="$(rg -n 'install-app.sh' "$log" | cut -d: -f1)"
line_verify="$(rg -n 'verify-install.sh' "$log" | cut -d: -f1)"
line_collection="$(rg -n 'configure-enhanced-collection.py.*--install' "$log" | cut -d: -f1)"
[[ "$line_tools" -lt "$line_backend" \
    && "$line_backend" -lt "$line_install" \
    && "$line_install" -lt "$line_verify" \
    && "$line_verify" -lt "$line_collection" ]] \
    || { echo "FAIL: 自举步骤顺序错误" >&2; exit 1; }
rg -Fq "CODEX_WORKBENCH_INSTALL_ROOT=$install_root" "$log" \
    || { echo "FAIL: 没有传递显式 install root" >&2; exit 1; }
if rg -q '^RUN .* open ' "$log"; then
    echo "FAIL: --no-open 仍计划打开 App" >&2
    exit 1
fi

skip_log="$TEST_ROOT/skip.log"
CODEX_WORKBENCH_ARCH_OVERRIDE="arm64" \
CODEX_WORKBENCH_MACOS_VERSION_OVERRIDE="14.0" \
CODEX_WORKBENCH_INSTALL_ROOT="$install_root" \
CODEX_WORKBENCH_BOOTSTRAP_HOME="$bootstrap_home" \
CODEX_WORKBENCH_BOOTSTRAP_DRY_RUN=1 \
CODEX_WORKBENCH_SKIP_ENHANCED_COLLECTION=1 \
    "$BOOTSTRAP" --no-open >"$skip_log"
if rg -q 'configure-enhanced-collection.py.*--install' "$skip_log"; then
    echo "FAIL: skip enhanced collection 仍计划写 Hook" >&2
    exit 1
fi
[[ ! -e "$bootstrap_home/.codex/hooks.json" ]] \
    || { echo "FAIL: dry-run/skip 写入了 hooks.json" >&2; exit 1; }

if rg -n 'rm[[:space:]].*(\\.codex|codex-profiles|operation-ledger)' "$BOOTSTRAP"; then
    echo "FAIL: 源码安装器包含用户数据删除命令" >&2
    exit 1
fi
rg -q '从源码安装' "$ROOT_DIR/README.md" \
    || { echo "FAIL: README 没有源码安装路径" >&2; exit 1; }
rg -q '预构建 DMG' "$ROOT_DIR/README.md" \
    || { echo "FAIL: README 没有区分预构建 DMG" >&2; exit 1; }

echo "PASS: one-command source bootstrap"
