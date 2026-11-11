#!/bin/sh
# Optional: live smoke test of the public data sources through the app's own code, then the
# daily-forecast checks against the forecast just fetched. Needs network access. Not run by run.sh.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/kliersky-live.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/Weather.swift" "$project_dir/KlierSky/RadarCore.swift" "$project_dir/KlierSky/AlertsCore.swift" "$project_dir/Tests/LiveChecks.swift" -o "$check_dir/live-checks"
status=0
"$check_dir/live-checks" "$check_dir/forecast.json" || status=$?
[ -s "$check_dir/forecast.json" ] || { echo "No live forecast was fetched; daily checks skipped."; exit 1; }
swiftc -parse-as-library -module-cache-path "$check_dir/cache" "$project_dir/KlierSky/Weather.swift" "$project_dir/Tests/DailyChecks.swift" -o "$check_dir/daily-checks"
"$check_dir/daily-checks" "$check_dir/forecast.json"
exit "$status"
