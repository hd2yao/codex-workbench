#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

swift run --quiet CodexWorkbenchCoreTests
"$ROOT_DIR/scripts/test-app-model.sh"
"$ROOT_DIR/scripts/test-ui-source-contracts.sh"
PYTHONPATH="$ROOT_DIR/Platform/LocalDataRuntime" \
  python3 -m unittest discover -s "$ROOT_DIR/Tests/LocalDataRuntimeTests" -v
"$ROOT_DIR/Tests/Scripts/test-enhanced-collection.sh"
"$ROOT_DIR/Tests/Scripts/test-source-bootstrap.sh"
