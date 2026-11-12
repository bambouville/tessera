#!/usr/bin/env bash
# Fails when the app uses an API or conformance newer than its deployment
# target without an availability check. Swift 5 mode only warns, and the
# binary then weak-links a symbol the oldest supported iOS lacks (iOS 18's
# CGRect: Hashable shipped to iOS 17 this way). Simulators run the newest iOS
# and never show it, so this reads the warnings.
#
# Usage: scripts/check-ios-availability.sh [BUILD_LOG]
# Without BUILD_LOG it runs a clean device build (an incremental build does
# not repeat warnings for unchanged files). A BUILD_LOG must come from a clean
# build or archive too.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log=${1:-}

if [[ -z "$log" ]]; then
  work=$(mktemp -d "${TMPDIR:-/tmp}/tessera-availability.XXXXXX")
  cleanup() {
    local status=$?
    if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
      echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
      status=1
    fi
    rm -rf "$work"
    exit "$status"
  }
  trap cleanup EXIT
  log="$work/build.log"
  if ! xcodebuild -project "$repo_root/Tessera.xcodeproj" -scheme Tessera \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath "$work/dd" CODE_SIGNING_ALLOWED=NO build >"$log" 2>&1; then
    grep -E "error:" "$log" | head -20 >&2
    echo "build failed" >&2
    exit 1
  fi
fi

[[ -f "$log" ]] || { echo "missing build log: $log" >&2; exit 1; }
if ! grep -q -E "^SwiftCompile |^CompileSwift " "$log"; then
  echo "no Swift compilation in $log; was it an incremental build?" >&2
  exit 1
fi

sites=$(grep -E "warning: .* is only available in iOS [0-9.]+ or newer" "$log" \
  | sed -E "s#^$repo_root/##; s#^.*/(Tessera|TesseraShareExtension|Packages)/#\\1/#" \
  | sort -u || true)
if [[ -n "$sites" ]]; then
  echo "unguarded uses of APIs newer than the deployment target:" >&2
  echo "$sites" >&2
  exit 1
fi
echo "availability: clean"
script_completed=1
