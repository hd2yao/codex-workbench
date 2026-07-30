#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

required_directories=(
    "Sources/App/Modules/Accounts"
    "Sources/App/Modules/ActivityLedger"
    "Sources/App/Modules/Overview"
    "Sources/App/Modules/ProjectsAndTasks"
    "Sources/App/Modules/ProjectServices"
    "Sources/App/Modules/ToolsAndAutomation"
    "Sources/App/Modules/Appearance"
    "Sources/App/Platform/DesktopClientRuntime"
    "Sources/Core/Modules/Accounts"
    "Sources/Core/Modules/ActivityLedger"
    "Sources/Core/Modules/ProjectsAndTasks"
    "Sources/Core/Platform/DesktopClientRuntime"
    "Platform/LocalDataRuntime"
    "Tests/LocalDataRuntimeTests"
)

for relative_path in "${required_directories[@]}"; do
    [[ -d "$ROOT_DIR/$relative_path" ]] || {
        echo "FAIL: missing module directory: $relative_path" >&2
        exit 1
    }
done

for legacy_path in \
    "codex-profile-switcher" \
    "Sources/CodexWorkbenchApp" \
    "Sources/CodexWorkbenchCore" \
    "Sources/CodexWorkbenchLoginHelper"; do
    [[ ! -e "$ROOT_DIR/$legacy_path" ]] || {
        echo "FAIL: legacy source layout remains: $legacy_path" >&2
        exit 1
    }
done

for forbidden_path in \
    "macos/CodexProfileMenuBar.swift" \
    "web/index.html" \
    "web/app.js" \
    "build-menubar-app.sh" \
    "install-menubar-app.sh"; do
    [[ ! -e "$ROOT_DIR/$forbidden_path" ]] || {
        echo "FAIL: standalone Profile Switcher UI remains: $forbidden_path" >&2
        exit 1
    }
done

rg -Fq 'path: "Sources/App"' "$ROOT_DIR/Package.swift" \
    || { echo "FAIL: App target does not use modular source path" >&2; exit 1; }
rg -Fq 'path: "Sources/Core"' "$ROOT_DIR/Package.swift" \
    || { echo "FAIL: Core target does not use modular source path" >&2; exit 1; }
rg -Fq 'Platform/LocalDataRuntime' "$ROOT_DIR/scripts/build-account-backend.sh" \
    || { echo "FAIL: backend build does not use local runtime" >&2; exit 1; }
if rg -F --glob '!docs/**' --glob '!specs/**' --glob '!screenshots/**' \
    --glob '!Tests/Scripts/test-module-layout.sh' \
    '../codex-profile-switcher' "$ROOT_DIR"; then
    echo "FAIL: source still depends on an adjacent Profile Switcher repository" >&2
    exit 1
fi

if rg -n 'serve_dashboard|make_handler|open the local profile dashboard' \
    "$ROOT_DIR/Platform/LocalDataRuntime"; then
    echo "FAIL: standalone Profile Switcher dashboard code remains in the runtime" >&2
    exit 1
fi

echo "PASS: modular product source layout"
