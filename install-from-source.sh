#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_ROOT="${CODEX_WORKBENCH_INSTALL_ROOT:-$HOME/Applications}"
BOOTSTRAP_HOME="${CODEX_WORKBENCH_BOOTSTRAP_HOME:-$HOME}"
ARCH="${CODEX_WORKBENCH_ARCH_OVERRIDE:-$(uname -m)}"
MACOS_VERSION="${CODEX_WORKBENCH_MACOS_VERSION_OVERRIDE:-$(sw_vers -productVersion)}"
DRY_RUN="${CODEX_WORKBENCH_BOOTSTRAP_DRY_RUN:-0}"
CHECK_ONLY=0
OPEN_APP=1

usage() {
    echo "Usage: $0 [--check] [--no-open]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=1
            ;;
        --no-open)
            OPEN_APP=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数：$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

[[ "$ARCH" == "arm64" ]] || {
    echo "环境不兼容：仅支持 Apple Silicon（M 系列），当前为 $ARCH。" >&2
    exit 1
}

macos_major="${MACOS_VERSION%%.*}"
[[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 13 ]] || {
    echo "环境不兼容：需要 macOS 13+，当前为 $MACOS_VERSION。" >&2
    exit 1
}

if [[ -n "${CODEX_WORKBENCH_SWIFT_BIN:-}" ]]; then
    SWIFT_BIN="$CODEX_WORKBENCH_SWIFT_BIN"
    [[ -x "$SWIFT_BIN" ]] || {
        echo "缺少 Swift 编译器：$SWIFT_BIN" >&2
        exit 1
    }
else
    command -v xcrun >/dev/null 2>&1 || {
        echo "缺少 Xcode Command Line Tools（xcrun）。" >&2
        exit 1
    }
    SWIFT_BIN="$(xcrun --find swift 2>/dev/null || true)"
    [[ -n "$SWIFT_BIN" && -x "$SWIFT_BIN" ]] || {
        echo "缺少可用 Swift 编译器，请先安装 Xcode Command Line Tools。" >&2
        exit 1
    }
fi

for required_command in git python3; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "缺少源码构建命令：$required_command" >&2
        exit 1
    }
done

[[ -f "$ROOT_DIR/Package.swift" \
    && -f "$ROOT_DIR/Platform/LocalDataRuntime/codex_profile.py" ]] || {
    echo "源码不完整：请克隆完整 codex-workbench 仓库。" >&2
    exit 1
}

swift_version="$("$SWIFT_BIN" --version 2>&1 | head -n 1)"
echo "PASS: 源码构建环境已就绪（${ARCH}，macOS ${MACOS_VERSION}，Swift ${swift_version}）"
if [[ "$CHECK_ONLY" == "1" ]]; then
    exit 0
fi

run_command() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'RUN'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

run_command "$ROOT_DIR/scripts/bootstrap-release-tools.sh"
run_command "$ROOT_DIR/scripts/build-account-backend.sh"
run_command /usr/bin/env "CODEX_WORKBENCH_INSTALL_ROOT=$INSTALL_ROOT" "$ROOT_DIR/install-app.sh"
run_command /usr/bin/env "CODEX_WORKBENCH_INSTALL_ROOT=$INSTALL_ROOT" "$ROOT_DIR/verify-install.sh"

if [[ "${CODEX_WORKBENCH_SKIP_ENHANCED_COLLECTION:-0}" != "1" ]]; then
    run_command python3 "$ROOT_DIR/scripts/configure-enhanced-collection.py" \
        --home "$BOOTSTRAP_HOME" --install
else
    echo "SKIP: 已按要求跳过增强生命周期日志。"
fi

if [[ "$OPEN_APP" == "1" ]]; then
    run_command open "$INSTALL_ROOT/Codex 工作台.app"
fi

echo "PASS: 源码构建、安装与验证流程完成。"
