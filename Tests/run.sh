#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/kliersky-checks.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
swiftc -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/Weather.swift" "$project_dir/Tests/CoreChecks.swift" -o "$check_dir/checks"
"$check_dir/checks" "$project_dir/Tests/Fixtures/forecast.json" "$project_dir/Tests/Fixtures/radar.json"

swiftc -parse-as-library -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/Weather.swift" "$project_dir/KlierSky/AdaptiveCore.swift" "$project_dir/Tests/AdaptiveChecks.swift" -o "$check_dir/adaptive-checks"
"$check_dir/adaptive-checks" "$project_dir/Tests/Fixtures/nws-observations.json"
swiftc -parse-as-library -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/GatewayAccessCore.swift" "$project_dir/Tests/AccessChecks.swift" -o "$check_dir/access-checks"
"$check_dir/access-checks"
swiftc -parse-as-library -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/Weather.swift" "$project_dir/KlierSky/RadarCore.swift" "$project_dir/KlierSky/AlertsCore.swift" "$project_dir/Tests/FeatureChecks.swift" -o "$check_dir/feature-checks"
"$check_dir/feature-checks" "$project_dir/Tests/Fixtures/nws-alerts.json"
python3 -m unittest discover -s "$project_dir/Gateway" -p "test_*.py"
