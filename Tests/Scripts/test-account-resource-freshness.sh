#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
APP_DIR="$TEST_ROOT/Codex 工作台.app"
PLIST="$APP_DIR/Contents/Info.plist"
HELPER="$APP_DIR/Contents/Resources/CodexAccountBackend/account-backend-source-fingerprint.txt"
OUTPUT="$TEST_ROOT/verify.out"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

CODEX_WORKBENCH_INSTALL_ROOT="$TEST_ROOT" "$ROOT_DIR/install-app.sh" >/dev/null

if ! /usr/libexec/PlistBuddy -c "Print :WorkbenchAccountBackendFingerprint" "$PLIST" >/dev/null 2>&1; then
    echo "FAIL: 安装包缺少账号后端 fingerprint" >&2
    exit 1
fi

if ! CODEX_WORKBENCH_INSTALL_ROOT="$TEST_ROOT" "$ROOT_DIR/verify-install.sh" >"$OUTPUT" 2>&1; then
    echo "FAIL: 未篡改的账号后端没有通过 freshness 校验" >&2
    cat "$OUTPUT" >&2
    exit 1
fi

printf '\n# freshness-test-tamper\n' >> "$HELPER"
if CODEX_WORKBENCH_INSTALL_ROOT="$TEST_ROOT" "$ROOT_DIR/verify-install.sh" >"$OUTPUT" 2>&1; then
    echo "FAIL: verifier 接受了被篡改的账号后端" >&2
    exit 1
fi

if ! grep -Fq "FAIL: 打包的账号后端不是当前源码" "$OUTPUT"; then
    echo "FAIL: verifier 没有报告账号后端 freshness 错误" >&2
    cat "$OUTPUT" >&2
    exit 1
fi

echo "PASS: account backend freshness"
