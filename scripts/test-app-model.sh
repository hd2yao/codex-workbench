#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/.build/app-model-tests"
TEST_EXECUTABLE="$OUTPUT_DIR/CodexWorkbenchAppModelTests"
CORE_LIBRARY="$OUTPUT_DIR/libCodexWorkbenchCore.dylib"
CORE_SOURCES=()
while IFS= read -r source_file; do
  CORE_SOURCES+=("$source_file")
done < <(find "$ROOT_DIR/Sources/Core" -type f -name '*.swift' | sort)

mkdir -p "$OUTPUT_DIR"

xcrun swiftc \
  -parse-as-library \
  -emit-library \
  -emit-module \
  -module-name CodexWorkbenchCore \
  "${CORE_SOURCES[@]}" \
  -o "$CORE_LIBRARY"

xcrun swiftc \
  -parse-as-library \
  -module-name CodexWorkbenchAppModelTests \
  -I "$OUTPUT_DIR" \
  -L "$OUTPUT_DIR" \
  -lCodexWorkbenchCore \
  "$ROOT_DIR/Sources/App/Platform/DesktopClientRuntime/AccountRuntimeServices.swift" \
  "$ROOT_DIR/Sources/App/Modules/Accounts/AutomaticResetCoordinator.swift" \
  "$ROOT_DIR/Sources/App/Shell/AppModel.swift" \
  "$ROOT_DIR/Sources/App/Modules/Accounts/OfficialRateLimitObserver.swift" \
  "$ROOT_DIR/Sources/App/Modules/Accounts/ResetCreditNotificationService.swift" \
  "$ROOT_DIR/Tests/CodexWorkbenchAppTests/WorkbenchAppModelRestartTests.swift" \
  -Xlinker -rpath \
  -Xlinker "$OUTPUT_DIR" \
  -o "$TEST_EXECUTABLE"

"$TEST_EXECUTABLE"
