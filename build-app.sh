#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Codex 工作台"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
LOGIN_ITEMS_DIR="$CONTENTS_DIR/Library/LoginItems"
LOGIN_HELPER_APP="$LOGIN_ITEMS_DIR/Codex Workbench Login Helper.app"
LOGIN_HELPER_MACOS_DIR="$LOGIN_HELPER_APP/Contents/MacOS"
ACCOUNT_SOURCE_DIR="$ROOT_DIR/Platform/LocalDataRuntime"
ACCOUNT_BACKEND_SOURCE_DIR="$ROOT_DIR/.build/account-backend/dist/CodexAccountBackend"
ACCOUNT_BACKEND_PAYLOAD_DIR="$RESOURCES_DIR/CodexAccountBackend"
ACCOUNT_BACKEND_ENTRY_DIR="$HELPERS_DIR/CodexAccountBackend"
ICON_SOURCE="$ROOT_DIR/Resources/AppIcon-1024.png"
ICONSET_DIR="$ROOT_DIR/.build/CodexWorkbench.iconset"

source_fingerprint() {
    find Sources Resources scripts -type f \
        ! -name 'AppIcon-1024.png' \
        ! -name 'AppIcon.icns' \
        -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
}

cd "$ROOT_DIR"
[[ -x "$ACCOUNT_BACKEND_SOURCE_DIR/CodexAccountBackend" ]] || {
    echo "FAIL: 缺少自包含账号后端；先运行 ./scripts/bootstrap-release-tools.sh 和 ./scripts/build-account-backend.sh" >&2
    exit 1
}
mkdir -p "$ROOT_DIR/Resources"
xcrun swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$ICON_SOURCE"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$ROOT_DIR/Resources/AppIcon.icns"
swift build -c release --product CodexWorkbenchApp
swift build -c release --product CodexWorkbenchLoginHelper
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR" "$LOGIN_HELPER_MACOS_DIR"
cp "$BIN_DIR/CodexWorkbenchApp" "$MACOS_DIR/CodexWorkbenchApp"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp -R "$ACCOUNT_BACKEND_SOURCE_DIR" "$ACCOUNT_BACKEND_PAYLOAD_DIR"
ln -s ../Resources/CodexAccountBackend "$ACCOUNT_BACKEND_ENTRY_DIR"
cp "$BIN_DIR/CodexWorkbenchLoginHelper" "$LOGIN_HELPER_MACOS_DIR/CodexWorkbenchLoginHelper"
cp "$ROOT_DIR/Resources/LoginHelper-Info.plist" "$LOGIN_HELPER_APP/Contents/Info.plist"
chmod +x "$MACOS_DIR/CodexWorkbenchApp"
chmod +x "$ACCOUNT_BACKEND_PAYLOAD_DIR/CodexAccountBackend"
chmod +x "$LOGIN_HELPER_MACOS_DIR/CodexWorkbenchLoginHelper"
/usr/libexec/PlistBuddy -c "Add :WorkbenchSourceCommit string $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :WorkbenchSourceFingerprint string $(source_fingerprint)" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :WorkbenchAccountBackendFingerprint string $(bash "$ROOT_DIR/scripts/account-resource-fingerprint.sh" "$ACCOUNT_SOURCE_DIR")" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :WorkbenchBuildTimestamp string $(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CONTENTS_DIR/Info.plist"
"$ROOT_DIR/scripts/verify-macos-deployment-target.sh" "$APP_DIR" 13.0
codesign --force --sign - "$LOGIN_HELPER_APP"
codesign --force --deep --sign - "$APP_DIR"
touch "$APP_DIR"

echo "$APP_DIR"
