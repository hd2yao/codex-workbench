#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT_DIR="${1:-$ROOT_DIR/Platform/LocalDataRuntime}"

for name in codex_profile.py codex_profile_dashboard.py; do
    [[ -f "$ACCOUNT_DIR/$name" ]] || {
        echo "missing account backend resource: $ACCOUNT_DIR/$name" >&2
        exit 1
    }
done

for name in codex_profile.py codex_profile_dashboard.py; do
    shasum -a 256 "$ACCOUNT_DIR/$name" | awk '{print $1}'
done | shasum -a 256 | awk '{print $1}'
