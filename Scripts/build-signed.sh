#!/bin/bash
# Build chuckit, then sign it with a stable local Apple Development identity so
# macOS privacy grants (Full Disk Access) survive rebuilds. Ad-hoc / unsigned
# builds get a new code identity every build and lose the grant.
# Usage: Scripts/build-signed.sh [derivedDataPath]   (override with CHUCKIT_SIGN_ID)
set -euo pipefail
cd "$(dirname "$0")/.."
dd="${1:-${TMPDIR:-/tmp}/chuckit-dd}"
xcodebuild -project chuckit.xcodeproj -scheme chuckit -configuration Debug ENABLE_DEBUG_DYLIB=NO \
  -derivedDataPath "$dd" build CODE_SIGNING_ALLOWED=NO -quiet
app="$dd/Build/Products/Debug/chuckit.app"
id="${CHUCKIT_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
if [ -z "$id" ]; then echo "No Apple Development identity found; app left unsigned." >&2; exit 1; fi
for ext in "$app"/Contents/PlugIns/*.appex; do
  [ -e "$ext" ] || continue
  codesign --force --options runtime --timestamp=none --entitlements ChuckitWidget/ChuckitWidget.entitlements -s "$id" "$ext" 2>/dev/null \
    || codesign --force --options runtime --timestamp=none -s "$id" "$ext"
done
codesign --force --options runtime --timestamp=none --entitlements Chuckit.entitlements -s "$id" "$app"
codesign --verify --strict "$app" && echo "Signed: $app with $id"
