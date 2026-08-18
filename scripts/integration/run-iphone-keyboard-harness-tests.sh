#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || {
  printf 'usage: run-iphone-keyboard-harness-tests.sh RUN_DIR\n' >&2
  exit 2
}

phone_udid_file="$SIMULATOR_STATE/iphone_keyboard_simulator_udid"
ipad_udid_file="$SIMULATOR_STATE/ipad_keyboard_simulator_udid"
phone_udid=''
ipad_udid=''
derived_data="$FIXTURE_STATE/iPhoneKeyboardDerivedData"
result_dir="$RUN_DIR/programmatic"
phone_result_bundle="$result_dir/iphone-keyboard-harness.xcresult"
ipad_result_bundle="$result_dir/ipad-keyboard-occlusion.xcresult"
mkdir -p "$derived_data" "$result_dir"
rm -rf "$phone_result_bundle" "$ipad_result_bundle"

cleanup() {
  if [[ -n "$phone_udid" ]]; then
    xcrun simctl spawn "$phone_udid" launchctl unsetenv TESSERA_IPHONE_KEYBOARD_HARNESS \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$ipad_udid" ]]; then
    xcrun simctl spawn "$ipad_udid" launchctl unsetenv TESSERA_IPHONE_KEYBOARD_HARNESS \
      >/dev/null 2>&1 || true
  fi
  delete_owned_test_simulator "$phone_udid_file" || true
  delete_owned_test_simulator "$ipad_udid_file" || true
}
trap cleanup EXIT

phone_udid="$(
  TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Integration iPhone Keyboard" \
  TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$phone_udid_file" \
    "$HERE/ensure-test-simulator.sh" | tail -n 1
)"

xcodebuild test \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$phone_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$phone_result_bundle" \
  -parallel-testing-enabled NO \
  -only-testing:TesseraUITests/IPhoneKeyboardHarnessTests \
  -only-testing:TesseraUITests/IPhoneFindBarKeyboardHarnessTests \
  -only-testing:TesseraUITests/KeyboardAccessoryOcclusionHarnessTests \
  -only-testing:TesseraUITests/IPhoneCollapsedAccessorySafeAreaHarnessTests \
  -only-testing:TesseraTests/AccessoryChipEncoderTests/testKeyboardCurveCannotBeRebuiltAsACubicBezier \
  -only-testing:TesseraTests/PaneLayoutMathTests/test_compactTmuxClientSizingProjectsFocusedPaneToPhoneViewport

delete_owned_test_simulator "$phone_udid_file"
phone_udid=''

ipad_udid="$(
  TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Integration iPad Keyboard" \
  TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro" \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$ipad_udid_file" \
    "$HERE/ensure-test-simulator.sh" | tail -n 1
)"

xcodebuild test-without-building \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$ipad_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$ipad_result_bundle" \
  -parallel-testing-enabled NO \
  -only-testing:TesseraUITests/KeyboardAccessoryOcclusionHarnessTests
