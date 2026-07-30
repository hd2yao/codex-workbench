#!/usr/bin/env bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ROOT="${CODEX_WORKBENCH_CAPTURE_APP:-$HOME/Applications/Codex 工作台.app}"
APP_BINARY="$APP_ROOT/Contents/MacOS/CodexWorkbenchApp"
APP_PLIST="$APP_ROOT/Contents/Info.plist"
OUTPUT_ROOT="${CODEX_WORKBENCH_CAPTURE_OUTPUT:-$TASK_ROOT/screenshots/theme-usage-workflow-assets}"
WINDOW_HELPER="$TASK_ROOT/scripts/window-info.swift"
MANIFEST="$OUTPUT_ROOT/manifest.tsv"

[[ -x "$APP_BINARY" ]] || {
    echo "FAIL: capture target is not executable: $APP_BINARY" >&2
    exit 1
}

mkdir -p "$OUTPUT_ROOT"
printf '%s\n' \
    $'file\tcommit\tfingerprint\tbinary_sha256\tpid\tstarted_at\tfixture\tmodule\tappearance\tbounds' \
    > "$MANIFEST"

stop_workbench() {
    local process_id
    while IFS= read -r process_id; do
        [[ -n "$process_id" ]] || continue
        kill -TERM "$process_id"
    done < <(pgrep -x CodexWorkbenchApp || true)

    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x CodexWorkbenchApp >/dev/null || return 0
        sleep 0.2
    done
    echo "FAIL: prior workbench process did not exit" >&2
    return 1
}

front_window_id() {
    local process_id="$1"
    local line
    line="$(
        xcrun swift "$WINDOW_HELPER" "Codex 工作台" "$process_id" \
            | awk '/layer=0/ {print; exit}'
    )"
    if [[ -z "$line" ]]; then
        line="$(
            xcrun swift "$WINDOW_HELPER" CodexWorkbenchApp "$process_id" \
                | awk '/layer=0/ {print; exit}'
        )"
    fi
    sed -n 's/^id=\([0-9][0-9]*\).*/\1/p' <<< "$line"
}

set_window_geometry() {
    local width="$1"
    local height="$2"
    local process_id="$3"
    osascript - "$width" "$height" "$process_id" <<'APPLESCRIPT'
on run argv
    set targetWidth to item 1 of argv as integer
    set targetHeight to item 2 of argv as integer
    set targetProcessID to item 3 of argv as integer
    tell application "System Events"
        tell first process whose unix id is targetProcessID
            set frontmost to true
            set position of front window to {72, 72}
            set size of front window to {targetWidth, targetHeight}
        end tell
    end tell
end run
APPLESCRIPT
}

scroll_window_to_bottom() {
    local process_id="$1"
    xcrun swift "$TASK_ROOT/scripts/scroll-content.swift" "$process_id"
}

capture_case() {
    local fixture="$1"
    local module="$2"
    local appearance="$3"
    local width="$4"
    local height="$5"
    local file_name="$6"
    local surface="${7:-}"
    local scroll_position="${8:-top}"
    local process_id
    local window_id=""
    local attempt

    stop_workbench
    open -n -F \
        --env "CODEX_WORKBENCH_VISUAL_FIXTURE=$fixture" \
        --env "CODEX_WORKBENCH_VISUAL_MODULE=$module" \
        --env "CODEX_WORKBENCH_VISUAL_APPEARANCE=$appearance" \
        --env "CODEX_WORKBENCH_VISUAL_SURFACE=$surface" \
        "$APP_ROOT"

    process_id=""
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        process_id="$(pgrep -x CodexWorkbenchApp | head -n 1 || true)"
        [[ -n "$process_id" ]] && break
        sleep 0.2
    done
    if [[ -z "$process_id" ]]; then
        echo "FAIL: workbench process did not launch for fixture $fixture" >&2
        return 1
    fi

    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        window_id="$(front_window_id "$process_id")"
        [[ -n "$window_id" ]] && break
        sleep 0.3
    done
    if [[ -z "$window_id" ]]; then
        echo "FAIL: no workbench window for fixture $fixture" >&2
        kill -TERM "$process_id" 2>/dev/null || true
        return 1
    fi

    set_window_geometry "$width" "$height" "$process_id"
    # NavigationSplitView and toolbar can briefly expose an incomplete layout
    # immediately after a scripted resize. Capture only the settled frame.
    sleep 1.5
    if [[ "$scroll_position" == "bottom" ]]; then
        scroll_window_to_bottom "$process_id"
        sleep 0.5
    fi
    window_id="$(front_window_id "$process_id")"
    [[ -n "$window_id" ]] || {
        echo "FAIL: workbench window disappeared for fixture $fixture" >&2
        return 1
    }

    screencapture -x -l "$window_id" "$OUTPUT_ROOT/$file_name"
    local commit
    local fingerprint
    local binary_sha
    local started_at
    local bounds
    commit="$(defaults read "$APP_PLIST" WorkbenchSourceCommit)"
    fingerprint="$(defaults read "$APP_PLIST" WorkbenchSourceFingerprint)"
    binary_sha="$(shasum -a 256 "$APP_BINARY" | awk '{print $1}')"
    started_at="$(ps -p "$process_id" -o lstart= | sed 's/^ *//')"
    bounds="$(
        xcrun swift "$WINDOW_HELPER" "Codex 工作台" "$process_id" \
            | awk -v id="$window_id" '$1 == "id=" id {print substr($0, index($0, "bounds=") + 7); exit}'
    )"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$file_name" "$commit" "$fingerprint" "$binary_sha" \
        "$process_id" "$started_at" "$fixture" "$module" \
        "$appearance" "$bounds" >> "$MANIFEST"
    echo "CAPTURED: $file_name"
}

capture_case ready accounts light 900 900 usage-900-light.png
capture_case ready accounts dark 900 900 usage-900-dark.png
capture_case ready accounts light 1160 900 usage-1160-light.png
capture_case ready accounts dark 1160 900 usage-1160-dark.png
capture_case ready accounts light 1440 900 usage-1440-light.png
capture_case ready accounts dark 1440 900 usage-1440-dark.png
capture_case local accounts light 1160 900 usage-local-fallback-1160-light.png
capture_case local accounts dark 1160 900 usage-local-fallback-1160-dark.png

capture_case ready toolsAndSkills light 900 900 assets-900-light.png
capture_case ready toolsAndSkills dark 900 900 assets-900-dark.png
capture_case ready toolsAndSkills light 1160 900 assets-1160-light.png
capture_case ready toolsAndSkills dark 1160 900 assets-1160-dark.png
capture_case ready toolsAndSkills light 1440 900 assets-1440-light.png
capture_case ready toolsAndSkills dark 1440 900 assets-1440-dark.png

stop_workbench
echo "PASS: screenshots and identity manifest written to $OUTPUT_ROOT"
