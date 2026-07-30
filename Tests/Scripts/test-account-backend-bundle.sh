#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND="${CODEX_ACCOUNT_BACKEND_DIR:-$ROOT_DIR/.build/account-backend/dist/CodexAccountBackend}"
EXECUTABLE="$BACKEND/CodexAccountBackend"

[[ -x "$EXECUTABLE" ]] || {
    echo "FAIL: missing bundled account backend: $EXECUTABLE" >&2
    exit 1
}

file "$EXECUTABLE" | grep -q 'arm64'
! file "$EXECUTABLE" | grep -q 'x86_64'
"$ROOT_DIR/scripts/verify-macos-deployment-target.sh" "$BACKEND" 13.0 >/dev/null

FIXTURE_HOME="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_HOME"' EXIT
mkdir -p "$FIXTURE_HOME/.codex"

env -i HOME="$FIXTURE_HOME" PATH=/usr/bin:/bin \
    "$EXECUTABLE" --help >/dev/null

echo "PASS: bundled account backend is self-contained arm64"
