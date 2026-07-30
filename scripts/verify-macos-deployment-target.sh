#!/usr/bin/env bash
set -euo pipefail

ROOT_PATH="${1:-}"
MAX_VERSION="${2:-13.0}"

[[ -n "$ROOT_PATH" && -e "$ROOT_PATH" ]] || {
    echo "FAIL: missing Mach-O path for deployment target verification" >&2
    exit 1
}

version_at_most() {
    /usr/bin/awk -v actual="$1" -v maximum="$2" '
        function component(value, part_index, parts, count) {
            count = split(value, parts, ".")
            return part_index <= count ? parts[part_index] + 0 : 0
        }
        BEGIN {
            for (part_index = 1; part_index <= 3; part_index++) {
                actual_part = component(actual, part_index)
                maximum_part = component(maximum, part_index)
                if (actual_part < maximum_part) exit 0
                if (actual_part > maximum_part) exit 1
            }
            exit 0
        }
    '
}

mach_o_count=0
while IFS= read -r -d '' candidate; do
    description="$(file "$candidate")"
    [[ "$description" == *"Mach-O"* ]] || continue
    mach_o_count=$((mach_o_count + 1))
    build_info="$(xcrun vtool -show-build "$candidate" 2>/dev/null)" || {
        echo "FAIL: cannot read Mach-O deployment target: $candidate" >&2
        exit 1
    }
    min_versions="$(/usr/bin/awk '$1 == "minos" { print $2 }' <<<"$build_info")"
    [[ -n "$min_versions" ]] || {
        echo "FAIL: Mach-O has no macOS minimum version: $candidate" >&2
        exit 1
    }
    while IFS= read -r min_version; do
        version_at_most "$min_version" "$MAX_VERSION" || {
            echo "FAIL: Mach-O requires macOS $min_version (> $MAX_VERSION): $candidate" >&2
            exit 1
        }
    done <<<"$min_versions"
done < <(find "$ROOT_PATH" -type f -print0)

[[ "$mach_o_count" -gt 0 ]] || {
    echo "FAIL: no Mach-O files found under $ROOT_PATH" >&2
    exit 1
}

echo "PASS: $mach_o_count Mach-O files require macOS $MAX_VERSION or earlier"
