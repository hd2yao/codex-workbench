#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
NOTES_FILE=""
DIST_DIR="$ROOT_DIR/dist"
PUBLISH=0

usage() {
    echo "Usage: $0 --version <x.y.z> --notes-file <file> [--dist-dir <dir>] --publish" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
        --dist-dir) DIST_DIR="${2:-}"; shift 2 ;;
        --publish) PUBLISH=1; shift ;;
        *) usage; exit 2 ;;
    esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "FAIL: 缺少有效 version" >&2; exit 1; }
[[ -f "$NOTES_FILE" ]] || { echo "FAIL: 缺少 release notes" >&2; exit 1; }
DMG_PATH="$DIST_DIR/Codex-Workbench-v$VERSION-arm64.dmg"
SHA_PATH="$DMG_PATH.sha256"
[[ -f "$DMG_PATH" ]] || { echo "FAIL: 缺少 DMG：$DMG_PATH" >&2; exit 1; }
[[ -f "$SHA_PATH" ]] || { echo "FAIL: 缺少 SHA256：$SHA_PATH" >&2; exit 1; }
(cd "$DIST_DIR" && shasum -a 256 -c "$(basename "$SHA_PATH")") >/dev/null \
    || { echo "FAIL: DMG 与 SHA256 不匹配" >&2; exit 1; }
hdiutil verify "$DMG_PATH" >/dev/null \
    || { echo "FAIL: DMG 结构校验失败" >&2; exit 1; }
xcrun stapler validate "$DMG_PATH" >/dev/null \
    || { echo "FAIL: DMG 没有有效的 Apple 公证票据" >&2; exit 1; }
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH" >/dev/null 2>&1 \
    || { echo "FAIL: DMG 未通过 Gatekeeper" >&2; exit 1; }

TAG="codex-workbench-v$VERSION"
echo "tag=$TAG"
echo "asset=$DMG_PATH"
echo "asset=$SHA_PATH"
if [[ "$PUBLISH" != "1" ]]; then
    echo "GATE: 未传 --publish；未创建 GitHub Release。" >&2
    exit 2
fi

command -v gh >/dev/null || { echo "FAIL: 缺少 gh" >&2; exit 1; }
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || {
    echo "FAIL: 发布仓库有未提交改动" >&2
    exit 1
}
HEAD_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "FAIL: 本地 tag 已存在：$TAG" >&2
    exit 1
fi
REMOTE_TAG="$(git -C "$ROOT_DIR" ls-remote --tags origin "refs/tags/$TAG")" || {
    echo "FAIL: 无法检查远端 tag" >&2
    exit 1
}
[[ -z "$REMOTE_TAG" ]] || {
    echo "FAIL: 远端 tag 已存在：$TAG" >&2
    exit 1
}
REMOTE_HEADS="$(git -C "$ROOT_DIR" ls-remote --heads origin)" || {
    echo "FAIL: 无法检查远端分支" >&2
    exit 1
}
/usr/bin/awk -v expected="$HEAD_SHA" '$1 == expected { found = 1 } END { exit !found }' \
    <<<"$REMOTE_HEADS" || {
        echo "FAIL: 当前 HEAD 尚未作为远端分支 tip 推送：$HEAD_SHA" >&2
        exit 1
    }
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "FAIL: GitHub Release 已存在：$TAG" >&2
    exit 1
fi

gh release create "$TAG" "$DMG_PATH" "$SHA_PATH" \
    --title "Codex 工作台 v$VERSION" \
    --notes-file "$NOTES_FILE" \
    --target "$HEAD_SHA"

echo "PASS: published $TAG"
