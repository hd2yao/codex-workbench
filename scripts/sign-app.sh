#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH=""
SIGN_IDENTITY=""

usage() {
    echo "Usage: $0 --app <Codex 工作台.app> --identity <Developer ID Application>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="${2:-}"; shift 2 ;;
        --identity) SIGN_IDENTITY="${2:-}"; shift 2 ;;
        *) usage; exit 2 ;;
    esac
done

[[ -d "$APP_PATH" ]] || { echo "FAIL: 缺少待签名 App：$APP_PATH" >&2; exit 1; }
[[ -n "$SIGN_IDENTITY" ]] || { echo "FAIL: 缺少 Developer ID identity" >&2; exit 1; }
security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY" \
    || { echo "FAIL: Keychain 中没有 Developer ID identity：$SIGN_IDENTITY" >&2; exit 1; }

ACCOUNT_PAYLOAD="$APP_PATH/Contents/Resources/CodexAccountBackend"
ACCOUNT_BINARY="$ACCOUNT_PAYLOAD/CodexAccountBackend"
LOGIN_HELPER_APP="$APP_PATH/Contents/Library/LoginItems/Codex Workbench Login Helper.app"
ACCOUNT_ENTITLEMENTS="$ROOT_DIR/Resources/AccountBackend.entitlements"
APP_ENTITLEMENTS="$ROOT_DIR/Resources/CodexWorkbench.entitlements"

[[ -d "$ACCOUNT_PAYLOAD" && -x "$ACCOUNT_BINARY" ]] \
    || { echo "FAIL: App 内缺少账号后端" >&2; exit 1; }
[[ -d "$LOGIN_HELPER_APP" ]] || { echo "FAIL: App 内缺少登录 helper" >&2; exit 1; }
plutil -lint "$ACCOUNT_ENTITLEMENTS" "$APP_ENTITLEMENTS" >/dev/null

while IFS= read -r -d '' candidate; do
    description="$(file "$candidate")"
    [[ "$description" == *"Mach-O"* ]] || continue
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$candidate"
done < <(find "$ACCOUNT_PAYLOAD" -type f -print0)

while IFS= read -r -d '' framework; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$framework"
done < <(find "$ACCOUNT_PAYLOAD" -type d -name '*.framework' -print0)

codesign --force --options runtime --timestamp \
    --entitlements "$ACCOUNT_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$ACCOUNT_BINARY"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$LOGIN_HELPER_APP"
codesign --force --options runtime --timestamp \
    --entitlements "$APP_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_PATH"

codesign --verify --strict "$ACCOUNT_BINARY"
codesign --verify --strict "$LOGIN_HELPER_APP"
codesign --verify --deep --strict "$APP_PATH"

echo "PASS: Developer ID signed $APP_PATH"
