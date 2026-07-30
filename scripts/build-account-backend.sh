#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT_SOURCE_DIR="$ROOT_DIR/Platform/LocalDataRuntime"
VENV_PYTHON="$ROOT_DIR/.build/release-tools/venv/bin/python"
BUILD_ROOT="$ROOT_DIR/.build/account-backend"
DIST_DIR="$BUILD_ROOT/dist"
WORK_DIR="$BUILD_ROOT/work"
SPEC_DIR="$BUILD_ROOT/spec"
BACKEND_DIR="$DIST_DIR/CodexAccountBackend"
EXECUTABLE="$BACKEND_DIR/CodexAccountBackend"
FINGERPRINT_FILE="$BACKEND_DIR/account-backend-source-fingerprint.txt"

[[ "$(uname -m)" == "arm64" ]] || {
    echo "FAIL: account backend must be built on Apple Silicon" >&2
    exit 1
}
[[ -x "$VENV_PYTHON" ]] || {
    echo "FAIL: release tools are missing; run ./scripts/bootstrap-release-tools.sh" >&2
    exit 1
}

mkdir -p "$DIST_DIR" "$WORK_DIR" "$SPEC_DIR"
PYTHONHASHSEED=0 "$VENV_PYTHON" -m PyInstaller \
    --clean \
    --noconfirm \
    --onedir \
    --target-arch arm64 \
    --noupx \
    --name CodexAccountBackend \
    --paths "$ACCOUNT_SOURCE_DIR" \
    --hidden-import codex_profile_dashboard \
    --hidden-import codex_runtime_services \
    --distpath "$DIST_DIR" \
    --workpath "$WORK_DIR" \
    --specpath "$SPEC_DIR" \
    "$ACCOUNT_SOURCE_DIR/codex_profile.py"

[[ -x "$EXECUTABLE" ]] || {
    echo "FAIL: PyInstaller did not create $EXECUTABLE" >&2
    exit 1
}
bash "$ROOT_DIR/scripts/account-resource-fingerprint.sh" "$ACCOUNT_SOURCE_DIR" \
    > "$FINGERPRINT_FILE"

while IFS= read -r -d '' candidate; do
    description="$(file "$candidate")"
    [[ "$description" == *"Mach-O"* ]] || continue
    [[ "$description" == *"arm64"* && "$description" != *"x86_64"* ]] || {
        echo "FAIL: non-arm64 Mach-O in account backend: $candidate" >&2
        exit 1
    }
done < <(find "$BACKEND_DIR" -type f -print0)

"$ROOT_DIR/scripts/verify-macos-deployment-target.sh" "$BACKEND_DIR" 13.0

echo "PASS: $BACKEND_DIR"
