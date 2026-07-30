#!/usr/bin/env bash
set -euo pipefail

APP_PATH=""
VERSION=""
OUTPUT_DIR=""

usage() {
    echo "Usage: $0 --app <Codex 工作台.app> --version <x.y.z> [--output-dir <dir>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_PATH="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        *) usage; exit 2 ;;
    esac
done

[[ -d "$APP_PATH" ]] || { echo "FAIL: 缺少 App：$APP_PATH" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "FAIL: version 必须是语义化版本号" >&2; exit 1; }
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DMG_PATH="$OUTPUT_DIR/Codex-Workbench-v$VERSION-arm64.dmg"
SHA_PATH="$DMG_PATH.sha256"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-workbench-dmg.XXXXXX")"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGING_DIR/Codex 工作台.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
    -volname "Codex 工作台 $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG_PATH")") > "$SHA_PATH"

echo "$DMG_PATH"
echo "$SHA_PATH"
