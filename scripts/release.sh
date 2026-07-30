#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
SIGN_IDENTITY=""
NOTARY_PROFILE=""
DRY_RUN=0

usage() {
    echo "Usage: $0 --version <x.y.z> --sign-identity <identity> --notary-profile <profile> [--dry-run]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --sign-identity) SIGN_IDENTITY="${2:-}"; shift 2 ;;
        --notary-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) usage; exit 2 ;;
    esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "FAIL: 缺少有效 version" >&2; exit 1; }

missing=0
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "GATE: 缺少 Developer ID identity" >&2
    missing=1
elif ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    echo "GATE: Keychain 中没有 Developer ID identity：$SIGN_IDENTITY" >&2
    missing=1
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "GATE: 缺少 notary profile" >&2
    missing=1
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "GATE: notary profile 不可用：$NOTARY_PROFILE" >&2
    missing=1
fi
[[ "$missing" == "0" ]] || exit 2

if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY RUN: Developer ID 与 notary profile 可用；不会构建、签名、公证或发布。"
    echo "planned_asset=Codex-Workbench-v$VERSION-arm64.dmg"
    exit 0
fi

cd "$ROOT_DIR"
if [[ "${CODEX_WORKBENCH_SKIP_BUILD:-0}" != "1" ]]; then
    ./scripts/bootstrap-release-tools.sh
    ./scripts/build-account-backend.sh
    ./build-app.sh
fi

APP_PATH="${CODEX_WORKBENCH_RELEASE_APP:-$ROOT_DIR/build/Codex 工作台.app}"
DIST_DIR="${CODEX_WORKBENCH_DIST_DIR:-$ROOT_DIR/dist}"
PLIST="$APP_PATH/Contents/Info.plist"
[[ -d "$APP_PATH" && -f "$PLIST" ]] || { echo "FAIL: 缺少 release App" >&2; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"

while IFS= read -r -d '' candidate; do
    description="$(file "$candidate")"
    [[ "$description" == *"Mach-O"* ]] || continue
    [[ "$description" == *"arm64"* && "$description" != *"x86_64"* ]] \
        || { echo "FAIL: Release 包含非 arm64 Mach-O：$candidate" >&2; exit 1; }
done < <(find "$APP_PATH" -type f -print0)

./scripts/verify-macos-deployment-target.sh "$APP_PATH" 13.0

./scripts/sign-app.sh --app "$APP_PATH" --identity "$SIGN_IDENTITY"
./scripts/create-dmg.sh --app "$APP_PATH" --version "$VERSION" --output-dir "$DIST_DIR"

DMG_PATH="$DIST_DIR/Codex-Workbench-v$VERSION-arm64.dmg"
SHA_PATH="$DMG_PATH.sha256"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vv --type execute "$APP_PATH"
hdiutil verify "$DMG_PATH"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")") > "$SHA_PATH"
[[ -s "$SHA_PATH" ]] || { echo "FAIL: SHA256 文件缺失" >&2; exit 1; }

echo "PASS: notarized release assets"
echo "dmg=$DMG_PATH"
echo "sha256=$SHA_PATH"
