#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_LOG="$TEST_ROOT/mock.log"
FIXTURE_APP="$TEST_ROOT/Codex 工作台.app"
DIST_DIR="$TEST_ROOT/dist"
NOTES_FILE="$TEST_ROOT/notes.md"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p \
    "$MOCK_BIN" \
    "$FIXTURE_APP/Contents/MacOS" \
    "$FIXTURE_APP/Contents/Resources/CodexAccountBackend" \
    "$FIXTURE_APP/Contents/Library/LoginItems/Codex Workbench Login Helper.app/Contents/MacOS" \
    "$DIST_DIR"
printf '#!/bin/sh\nexit 0\n' > "$FIXTURE_APP/Contents/MacOS/CodexWorkbenchApp"
chmod +x "$FIXTURE_APP/Contents/MacOS/CodexWorkbenchApp"
cp "$FIXTURE_APP/Contents/MacOS/CodexWorkbenchApp" \
    "$FIXTURE_APP/Contents/Resources/CodexAccountBackend/CodexAccountBackend"
cp "$FIXTURE_APP/Contents/MacOS/CodexWorkbenchApp" \
    "$FIXTURE_APP/Contents/Library/LoginItems/Codex Workbench Login Helper.app/Contents/MacOS/CodexWorkbenchLoginHelper"
cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hd2yao.codex-workbench</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>0</string>
</dict></plist>
PLIST
printf '# Release fixture\n' > "$NOTES_FILE"

for required_script in release.sh sign-app.sh create-dmg.sh publish-github-release.sh; do
    [[ -x "$ROOT_DIR/scripts/$required_script" ]] \
        || { echo "FAIL: 缺少发布脚本 scripts/$required_script" >&2; exit 1; }
done
if /usr/bin/grep -E -n 'codesign .*--(force )?--deep.*--sign|codesign .*--sign.*--deep' \
    "$ROOT_DIR/scripts/sign-app.sh" >/dev/null; then
    echo "FAIL: sign-app.sh 不得用 --deep 执行签名" >&2
    exit 1
fi

cat > "$MOCK_BIN/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "${MOCK_LOG:?}"
case "$name" in
    security)
        [[ "${MOCK_IDENTITY:-0}" == "1" ]] || exit 0
        printf '  1) ABCDEF "Developer ID Application: Test (TEAMID)"\n'
        ;;
    xcrun)
        if [[ "$*" == "notarytool history"* ]]; then
            [[ "${MOCK_NOTARY:-0}" == "1" ]] || exit 1
        elif [[ "$*" == "vtool -show-build"* ]]; then
            printf 'platform MACOS\n    minos %s\n      sdk 26.0\n' "${MOCK_MINOS:-13.0}"
        elif [[ "$*" == "stapler validate"* ]]; then
            [[ "${MOCK_STAPLER_VALIDATE_FAIL:-0}" != "1" ]] || exit 1
        elif [[ "$*" == "stapler staple"* ]]; then
            [[ "${MOCK_STAPLER_FAIL:-0}" != "1" ]] || exit 1
        fi
        ;;
    file)
        if [[ "${MOCK_ARCH:-arm64}" == "x86_64" ]]; then
            printf '%s: Mach-O 64-bit executable x86_64\n' "$1"
        else
            printf '%s: Mach-O 64-bit executable arm64\n' "$1"
        fi
        ;;
    codesign)
        [[ "${MOCK_CODESIGN_FAIL:-0}" != "1" ]] || exit 1
        ;;
    hdiutil)
        if [[ "${1:-}" == "create" ]]; then
            last="${@: -1}"
            mkdir -p "$(dirname "$last")"
            printf 'fixture-dmg\n' > "$last"
        fi
        ;;
    spctl)
        ;;
    gh)
        if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
            exit 1
        fi
        ;;
    git)
        case "$*" in
            *"status --porcelain"*) ;;
            *"rev-parse HEAD"*) printf '%s\n' "${MOCK_HEAD_SHA:-1111111111111111111111111111111111111111}" ;;
            *"rev-parse -q --verify refs/tags/"*) exit 1 ;;
            *"ls-remote --tags origin refs/tags/"*)
                if [[ "${MOCK_REMOTE_TAG:-0}" == "1" ]]; then
                    printf '%s\trefs/tags/codex-workbench-v9.9.8\n' "${MOCK_HEAD_SHA:-1111111111111111111111111111111111111111}"
                fi
                ;;
            *"ls-remote --heads origin"*)
                if [[ "${MOCK_HEAD_PUSHED:-1}" == "1" ]]; then
                    printf '%s\trefs/heads/main\n' "${MOCK_HEAD_SHA:-1111111111111111111111111111111111111111}"
                else
                    printf '%040d\trefs/heads/main\n' 2
                fi
                ;;
        esac
        ;;
esac
MOCK
chmod +x "$MOCK_BIN/mock-command"
for command_name in security xcrun file codesign hdiutil spctl gh git; do
    ln -s mock-command "$MOCK_BIN/$command_name"
done

run_release() {
    env \
        PATH="$MOCK_BIN:$PATH" \
        MOCK_LOG="$MOCK_LOG" \
        MOCK_IDENTITY="${MOCK_IDENTITY:-0}" \
        MOCK_NOTARY="${MOCK_NOTARY:-0}" \
        MOCK_ARCH="${MOCK_ARCH:-arm64}" \
        MOCK_MINOS="${MOCK_MINOS:-13.0}" \
        MOCK_CODESIGN_FAIL="${MOCK_CODESIGN_FAIL:-0}" \
        MOCK_STAPLER_FAIL="${MOCK_STAPLER_FAIL:-0}" \
        CODEX_WORKBENCH_SKIP_BUILD=1 \
        CODEX_WORKBENCH_RELEASE_APP="$FIXTURE_APP" \
        CODEX_WORKBENCH_DIST_DIR="$DIST_DIR" \
        "$ROOT_DIR/scripts/release.sh" "$@"
}

expect_failure() {
    local label="$1"
    shift
    if "$@" >"$TEST_ROOT/output.log" 2>&1; then
        echo "FAIL: $label 没有 fail closed" >&2
        exit 1
    fi
}

expect_failure "缺少 version" run_release --dry-run

MOCK_IDENTITY=0 MOCK_NOTARY=1 \
    expect_failure "缺少 Developer ID" run_release \
        --version 9.9.1 --sign-identity "Developer ID Application: Test (TEAMID)" \
        --notary-profile test-profile

MOCK_IDENTITY=1 MOCK_NOTARY=0 \
    expect_failure "缺少 notary profile" run_release \
        --version 9.9.2 --sign-identity "Developer ID Application: Test (TEAMID)" \
        --notary-profile missing-profile

MOCK_IDENTITY=1 MOCK_NOTARY=1 MOCK_ARCH=x86_64 \
    expect_failure "x86_64 binary" run_release \
        --version 9.9.3 --sign-identity "Developer ID Application: Test (TEAMID)" \
        --notary-profile test-profile

MOCK_IDENTITY=1 MOCK_NOTARY=1 MOCK_ARCH=arm64 MOCK_MINOS=14.0 \
    expect_failure "macOS 14 minimum deployment" run_release \
        --version 9.9.4 --sign-identity "Developer ID Application: Test (TEAMID)" \
        --notary-profile test-profile

MOCK_IDENTITY=1 MOCK_NOTARY=1 MOCK_ARCH=arm64 MOCK_MINOS=13.0 MOCK_CODESIGN_FAIL=1 \
    expect_failure "codesign failure" run_release \
        --version 9.9.5 --sign-identity "Developer ID Application: Test (TEAMID)" \
        --notary-profile test-profile

MOCK_IDENTITY=1 MOCK_NOTARY=1 MOCK_ARCH=arm64 MOCK_MINOS=13.0 MOCK_CODESIGN_FAIL=0 MOCK_STAPLER_FAIL=1 \
    expect_failure "stapler failure" run_release \
        --version 9.9.6 --sign-identity "Developer ID Application: Test (TEAMID)" \
        --notary-profile test-profile

MOCK_IDENTITY=1 MOCK_NOTARY=1 MOCK_ARCH=arm64 MOCK_MINOS=13.0 MOCK_CODESIGN_FAIL=0 MOCK_STAPLER_FAIL=0 \
    run_release --version 9.9.7 \
        --sign-identity "Developer ID Application: Test (TEAMID)" \
        --notary-profile test-profile >/dev/null
[[ -s "$DIST_DIR/Codex-Workbench-v9.9.7-arm64.dmg.sha256" ]] \
    || { echo "FAIL: 完整 mock 发布链路没有生成 SHA256" >&2; exit 1; }

PUBLISH_VERSION="9.9.8"
PUBLISH_DMG="$DIST_DIR/Codex-Workbench-v$PUBLISH_VERSION-arm64.dmg"
PUBLISH_SHA="$PUBLISH_DMG.sha256"
printf 'fixture-dmg\n' > "$PUBLISH_DMG"
expect_failure "缺少 SHA" env PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" \
    "$ROOT_DIR/scripts/publish-github-release.sh" \
        --version "$PUBLISH_VERSION" --notes-file "$NOTES_FILE" --dist-dir "$DIST_DIR" --publish

(cd "$DIST_DIR" && shasum -a 256 "$(basename "$PUBLISH_DMG")") > "$PUBLISH_SHA"
expect_failure "未公证 DMG" env PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" \
    MOCK_STAPLER_VALIDATE_FAIL=1 "$ROOT_DIR/scripts/publish-github-release.sh" \
        --version "$PUBLISH_VERSION" --notes-file "$NOTES_FILE" \
        --dist-dir "$DIST_DIR" --publish
expect_failure "未传 --publish" env PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" \
    MOCK_STAPLER_VALIDATE_FAIL=0 "$ROOT_DIR/scripts/publish-github-release.sh" \
        --version "$PUBLISH_VERSION" --notes-file "$NOTES_FILE" --dist-dir "$DIST_DIR"
grep -Fq "tag=codex-workbench-v$PUBLISH_VERSION" "$TEST_ROOT/output.log" \
    || { echo "FAIL: 工作台 Release tag 没有使用独立命名空间" >&2; exit 1; }

if [[ -f "$MOCK_LOG" ]] && grep -Fq "gh release create" "$MOCK_LOG"; then
    echo "FAIL: 任一失败门禁仍调用了 gh release create" >&2
    exit 1
fi

expect_failure "远端 tag 已存在" env PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" \
    MOCK_REMOTE_TAG=1 MOCK_HEAD_PUSHED=1 "$ROOT_DIR/scripts/publish-github-release.sh" \
        --version "$PUBLISH_VERSION" --notes-file "$NOTES_FILE" \
        --dist-dir "$DIST_DIR" --publish
expect_failure "当前 HEAD 未推送" env PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" \
    MOCK_REMOTE_TAG=0 MOCK_HEAD_PUSHED=0 "$ROOT_DIR/scripts/publish-github-release.sh" \
        --version "$PUBLISH_VERSION" --notes-file "$NOTES_FILE" \
        --dist-dir "$DIST_DIR" --publish

env PATH="$MOCK_BIN:$PATH" MOCK_LOG="$MOCK_LOG" \
    MOCK_REMOTE_TAG=0 MOCK_HEAD_PUSHED=1 \
    "$ROOT_DIR/scripts/publish-github-release.sh" \
        --version "$PUBLISH_VERSION" --notes-file "$NOTES_FILE" \
        --dist-dir "$DIST_DIR" --publish >/dev/null
grep -Fq "gh release view codex-workbench-v$PUBLISH_VERSION" "$MOCK_LOG" \
    || { echo "FAIL: 发布前没有检查工作台命名空间中的 Release" >&2; exit 1; }
grep -Fq "gh release create codex-workbench-v$PUBLISH_VERSION" "$MOCK_LOG" \
    || { echo "FAIL: GitHub Release 没有使用工作台独立 tag" >&2; exit 1; }
grep -Fq -- "--target 1111111111111111111111111111111111111111" "$MOCK_LOG" \
    || { echo "FAIL: GitHub Release tag 没有绑定已推送的当前 HEAD" >&2; exit 1; }

echo "PASS: release guardrails"
