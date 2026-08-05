#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: prepare-visual-simulator.sh RUN_DIR\n' >&2; exit 2; }

require_command jq
require_command xcodebuild
require_command xcrun

VISUAL_ROOT="$RUN_DIR/visual"
BUILD_LOG="$VISUAL_ROOT/build-for-testing.log"
DERIVED_DATA="$FIXTURE_STATE/VisualDerivedData"
mkdir -p "$VISUAL_ROOT" "$DERIVED_DATA"

# Visual capture must not share a simulator with unit/UI tests from another
# development session. Reinstalling the same bundle ID during a recording can
# otherwise terminate Tessera and turn a valid milestone into SpringBoard.
udid=''
handoff_complete=0
cleanup_failed_prepare() {
  if [[ "$handoff_complete" -eq 0 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/visual_simulator_udid" || true
  fi
}
trap cleanup_failed_prepare EXIT

udid="$(
  TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Visual Integration Tests" \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/visual_simulator_udid" \
    "$HERE/ensure-test-simulator.sh" | tail -n 1
)"

xcodebuild build-for-testing \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$DERIVED_DATA" \
  >"$BUILD_LOG" 2>&1

app_path="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Tessera.app"
[[ -d "$app_path" ]] || die "visual build did not produce $app_path"
xcrun simctl install "$udid" "$app_path"
xcrun simctl spawn "$udid" launchctl setenv TESSERA_VISUAL_CAPTURE 1

# A freshly booted simulator starts in portrait even though Tessera supports
# landscape only. Set the dedicated device orientation before any app capture;
# simctl has no public orientation command, so use the smallest UI-test probe.
orientation_result="$VISUAL_ROOT/orientation-prime.xcresult"
rm -rf "$orientation_result"
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$orientation_result" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testSetLandscapeOnly \
  >"$VISUAL_ROOT/orientation-prime.log" 2>&1

jq -n \
  --arg udid "$udid" \
  --arg appPath "$app_path" \
  --arg derivedData "$DERIVED_DATA" \
  '{udid: $udid, app_path: $appPath, derived_data: $derivedData}' \
  >"$VISUAL_ROOT/runtime.json"

handoff_complete=1
trap - EXIT
