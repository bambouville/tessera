#!/usr/bin/env bash
# Host-free native setup parity and full-screen evidence on owned devices.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?usage: run-setup-flow-harness-tests.sh RUN_DIR [--without-building]}"
BUILD_ACTION=test
if [[ "${2:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ -n "${2:-}" ]]; then
  die "unknown argument: $2"
fi
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$RUN_DIR/simulators"
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="setup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
capture_pid=''
cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  trap - EXIT
  if [[ -n "$capture_pid" ]]; then
    kill -INT "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
  fi
  delete_owned_test_simulator "$RUN_DIR/simulators/ipad" || status=1
  delete_owned_test_simulator "$RUN_DIR/simulators/iphone" || status=1
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
for idiom in ipad iphone; do
  export TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Setup Flow $idiom"
  export TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$RUN_DIR/simulators/$idiom"
  export TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB
  if [[ "$idiom" == iphone ]]; then
    export TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
  fi
  [[ ! -e "$RUN_DIR/$idiom.xcresult" ]] || die 'use a fresh run directory'
  udid="$("$HERE/ensure-test-simulator.sh" | tail -n 1)"
  xcrun simctl io "$udid" recordVideo --codec=h264 "$RUN_DIR/$idiom.mp4" \
    >"$RUN_DIR/$idiom-recording.log" 2>&1 &
  capture_pid=$!
  filters=(
    -only-testing:TesseraUITests/SetupFlowPresentationHarnessTests
    -only-testing:TesseraUITests/ContinuityHarnessTests/testQROfferKeepsGuidanceAndCancelReachable
    -only-testing:TesseraUITests/ContinuityHarnessTests/testQRManualEntryRemainsUsableWithSoftwareKeyboard
  )
  if [[ "$idiom" == iphone ]]; then
    filters+=(
      -only-testing:TesseraUITests/ContinuityHarnessTests/testQROfferCompactPortrait
      -only-testing:TesseraUITests/ContinuityHarnessTests/testQRManualEntryCompactPortrait
    )
  fi
  integration_xcodebuild "$BUILD_ACTION" -project "$REPO_ROOT/Tessera.xcodeproj" \
    -scheme Tessera -configuration Debug -derivedDataPath "$(integration_derived_data)" \
    -destination "platform=iOS Simulator,id=$udid" -parallel-testing-enabled NO \
    -resultBundlePath "$RUN_DIR/$idiom.xcresult" "${filters[@]}"
  kill -INT "$capture_pid"
  wait "$capture_pid"
  capture_pid=''
  xcrun xcresulttool export attachments --path "$RUN_DIR/$idiom.xcresult" \
    --output-path "$RUN_DIR/$idiom-attachments"
  delete_owned_test_simulator "$RUN_DIR/simulators/$idiom"
  BUILD_ACTION=test-without-building
done
script_completed=1
