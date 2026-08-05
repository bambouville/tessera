#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-scroll-harness-tests.sh RUN_DIR\n' >&2; exit 2; }
BUILD_ACTION=test
if [[ "${2:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ -n "${2:-}" ]]; then
  printf 'unknown option: %s\n' "$2" >&2
  exit 2
fi

udid=''
touch_udid=''
derived_data="$FIXTURE_STATE/DerivedData"
result_bundle="$RUN_DIR/programmatic/terminal-scroll-harness.xcresult"
touch_result_bundle="$RUN_DIR/programmatic/terminal-touch-scroll-harness.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"
rm -rf "$touch_result_bundle"

cleanup() {
  if [[ -n "$udid" ]]; then
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_SCROLL_CAPTURE \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_SCROLL_HARNESS \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_TOUCH_SCROLL_CAPTURE \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_TOUCH_SCROLL_HARNESS \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$touch_udid" ]]; then
    xcrun simctl spawn "$touch_udid" launchctl unsetenv TESSERA_TOUCH_SCROLL_CAPTURE \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$touch_udid" launchctl unsetenv TESSERA_TOUCH_SCROLL_HARNESS \
      >/dev/null 2>&1 || true
  fi
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
    if [[ -n "$touch_udid" ]]; then
      delete_owned_test_simulator "$SIMULATOR_STATE/touch_simulator_udid" || true
    fi
  fi
}
trap cleanup EXIT

udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"

xcrun simctl spawn "$udid" launchctl setenv TESSERA_SCROLL_CAPTURE 1
xcrun simctl spawn "$udid" launchctl setenv TESSERA_SCROLL_HARNESS 1

TESSERA_SCROLL_CAPTURE=1 xcodebuild "$BUILD_ACTION" \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:TesseraUITests/TerminalScrollHarnessTests/testPrimaryScrollMovesIntoHistoryAndBackToBottom \
  -only-testing:TesseraUITests/TerminalScrollHarnessTests/testHookProvenWorkingAgentConsumesPointerScrollAndShowsNotice

xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_SCROLL_CAPTURE
xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_SCROLL_HARNESS
touch_udid="$({
  TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Integration Touch Tests' \
  TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE='com.apple.CoreSimulator.SimDeviceType.iPhone-17' \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/touch_simulator_udid" \
    "$HERE/ensure-test-simulator.sh"
} | tail -n 1)"
xcrun simctl spawn "$touch_udid" launchctl setenv TESSERA_TOUCH_SCROLL_CAPTURE 1
xcrun simctl spawn "$touch_udid" launchctl setenv TESSERA_TOUCH_SCROLL_HARNESS 1

TESSERA_TOUCH_SCROLL_CAPTURE=1 xcodebuild test-without-building \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$touch_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$touch_result_bundle" \
  -only-testing:TesseraUITests/TerminalTouchScrollHarnessTests/testTouchSwipeForwardsMouseWheelInAlternateScreen \
  -only-testing:TesseraUITests/TerminalTouchScrollHarnessTests/testHookProvenWorkingAgentConsumesTouchScrollAndShowsNotice
