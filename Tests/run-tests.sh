#!/bin/bash
# RFO2 — compile the same canonical service files that the Xcode app builds.
# Stop on errors; let callers put fixture output outside the source repository.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_dir/chuckit"
output_dir="${1:-$project_dir/TestResults}"
mkdir -p "$output_dir"
xcrun swiftc -module-cache-path "$output_dir/module-cache" \
  "$source_dir/Models.swift" "$source_dir/RemovalPolicy.swift" \
  "$source_dir/MatchEngine.swift" "$source_dir/ScanLocations.swift" \
  "$source_dir/RelatedFileScanner.swift" "$source_dir/DeletionService.swift" \
  "$project_dir/Tests/RegressionTests.swift" -o "$output_dir/regression-tests"
"$output_dir/regression-tests" "$output_dir"
