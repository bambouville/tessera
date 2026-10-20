#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-continuity-harness-tests.sh RUN_DIR\n' >&2; exit 2; }
BUILD_ACTION=test
if [[ "${2:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ -n "${2:-}" ]]; then
  printf 'unknown option: %s\n' "$2" >&2
  exit 2
fi

ipad_udid=''
iphone_udid=''
capture_pid=''
derived_data="$(integration_derived_data)"
result_dir="$RUN_DIR/programmatic"
mkdir -p "$derived_data" "$result_dir"

cleanup() {
  local udid udid_file
  if [[ -n "$capture_pid" ]]; then
    kill -INT "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
  fi
  for udid in "$ipad_udid" "$iphone_udid"; do
    [[ -n "$udid" ]] || continue
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_CONTINUITY_CAPTURE \
      >/dev/null 2>&1 || true
  done
  # The iPhone is private to this lane and always goes; only the shared
  # iPad may outlive the lane when the parent runner keeps it booted.
  delete_owned_test_simulator "$SIMULATOR_STATE/continuity_iphone_simulator_udid" || true
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
  fi
}
trap 'fail_closed_trap cleanup' EXIT

ipad_udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"
iphone_udid="$(
  TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Continuity Integration iPhone" \
  TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/continuity_iphone_simulator_udid" \
    "$HERE/ensure-test-simulator.sh" | tail -n 1
)"

prime_simulator() {
  local udid="$1"
  # This lane owns dedicated integration simulators. Prime only the two local
  # first-open markers so bootstrap/onboarding cannot obscure descriptor UI;
  # no app data is erased and no connection/session preference is changed.
  xcrun simctl terminate "$udid" com.bambouville.TesseraApp >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" defaults write \
    com.bambouville.TesseraApp tessera.nearbyBootstrap.completed.v1 -bool YES
  xcrun simctl spawn "$udid" defaults write \
    com.bambouville.TesseraApp tessera.pref.hasSeenWelcome -bool YES
  xcrun simctl spawn "$udid" launchctl setenv TESSERA_CONTINUITY_CAPTURE 1
}

run_harness() {
  local idiom="$1"
  local udid="$2"
  local action="$3"
  local result_bundle="$result_dir/continuity-harness-$idiom.xcresult"
  rm -rf "$result_bundle"

  note "running Handoff receiver UI on $idiom simulator"
  local test_filters=(-only-testing:TesseraUITests/ContinuityHarnessTests)
  if [[ "${TESSERA_CONTINUITY_QR_ONLY:-0}" == 1 ]]; then
    test_filters=(
      -only-testing:TesseraUITests/ContinuityHarnessTests/testQRManualEntryRemainsUsableWithSoftwareKeyboard
      -only-testing:TesseraUITests/ContinuityHarnessTests/testQROfferKeepsGuidanceAndCancelReachable
    )
  fi
  if [[ "${TESSERA_CONTINUITY_RECORD_VIDEO:-0}" == 1 ]]; then
    mkdir -p "$RUN_DIR/visual"
    xcrun simctl io "$udid" recordVideo --codec=h264 \
      "$RUN_DIR/visual/continuity-$idiom.mp4" \
      >"$RUN_DIR/visual/continuity-$idiom-recording.log" 2>&1 &
    capture_pid=$!
  fi
  integration_xcodebuild "$action" \
    -project "$REPO_ROOT/Tessera.xcodeproj" \
    -scheme Tessera \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    -parallel-testing-enabled NO \
    "${test_filters[@]}"
  if [[ -n "$capture_pid" ]]; then
    kill -INT "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
    capture_pid=''
  fi
}

prime_simulator "$ipad_udid"
prime_simulator "$iphone_udid"
run_harness ipad "$ipad_udid" "$BUILD_ACTION"
run_harness iphone "$iphone_udid" test-without-building
script_completed=1
