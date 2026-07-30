#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${CODEX_WORKBENCH_BUILD_PYTHON:-python3}"
VENV_DIR="$ROOT_DIR/.build/release-tools/venv"

[[ "$(uname -m)" == "arm64" ]] || {
    echo "FAIL: release tools must be bootstrapped on Apple Silicon" >&2
    exit 1
}
command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
    echo "FAIL: build Python not found: $PYTHON_BIN" >&2
    exit 1
}

PYTHON_RUNTIME="$("$PYTHON_BIN" -c 'import pathlib, sys; print(pathlib.Path(sys.executable).resolve())')"
"$ROOT_DIR/scripts/verify-macos-deployment-target.sh" "$PYTHON_RUNTIME" 13.0 >/dev/null || {
    echo "FAIL: build Python cannot produce a macOS 13-compatible backend: $PYTHON_RUNTIME" >&2
    echo "Set CODEX_WORKBENCH_BUILD_PYTHON to a compatible arm64 Python runtime." >&2
    exit 1
}

"$PYTHON_BIN" -m venv --clear "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --requirement "$ROOT_DIR/requirements-build.txt"

echo "PASS: release tools installed in $VENV_DIR"
