#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/kliersky-checks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
swiftc -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/Weather.swift" "$project_dir/Tests/CoreChecks.swift" -o "$check_dir/checks"
"$check_dir/checks" "$project_dir/Tests/Fixtures/forecast.json" "$project_dir/Tests/Fixtures/radar.json"

swiftc -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/Weather.swift" "$project_dir/KlierSky/AdaptiveCore.swift" "$project_dir/Tests/AdaptiveChecks.swift" -o "$check_dir/adaptive-checks"
"$check_dir/adaptive-checks"
python3 -m unittest discover -s "$project_dir/Gateway" -p "test_*.py"
