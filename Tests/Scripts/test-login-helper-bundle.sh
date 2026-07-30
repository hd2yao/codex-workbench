#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
APP_DIR="$TEST_ROOT/Codex 工作台.app"
HELPER_APP="$APP_DIR/Contents/Library/LoginItems/Codex Workbench Login Helper.app"
HELPER_PLIST="$HELPER_APP/Contents/Info.plist"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

CODEX_WORKBENCH_INSTALL_ROOT="$TEST_ROOT" "$ROOT_DIR/install-app.sh" >/dev/null
CODEX_WORKBENCH_INSTALL_ROOT="$TEST_ROOT" "$ROOT_DIR/verify-install.sh" >/dev/null

[[ "$(defaults read "$HELPER_PLIST" CFBundleIdentifier)" == "com.hd2yao.codex-workbench.login-helper" ]] \
    || { echo "FAIL: helper identifier 不匹配" >&2; exit 1; }
[[ "$(defaults read "$HELPER_PLIST" CFBundleExecutable)" == "CodexWorkbenchLoginHelper" ]] \
    || { echo "FAIL: helper executable 不匹配" >&2; exit 1; }
codesign --verify --strict "$HELPER_APP"

echo "PASS: login helper bundle"
