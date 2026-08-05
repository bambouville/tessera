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

export TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Integration iPhone Keyboard"
export TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
export TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/iphone_keyboard_simulator_udid"

udid=''
derived_data="$FIXTURE_STATE/iPhoneKeyboardDerivedData"
result_dir="$RUN_DIR/programmatic"
result_bundle="$result_dir/iphone-keyboard-harness.xcresult"
mkdir -p "$derived_data" "$result_dir"
rm -rf "$result_bundle"

cleanup() {
  if [[ -n "$udid" ]]; then
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_IPHONE_KEYBOARD_HARNESS \
      >/dev/null 2>&1 || true
  fi
  delete_owned_test_simulator "$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE" || true
}
trap cleanup EXIT

udid="$("$HERE/ensure-test-simulator.sh" | tail -n 1)"

xcodebuild test \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -only-testing:TesseraUITests/IPhoneKeyboardHarnessTests/testHideKeyboardDismissesUntilTerminalIsTappedAgain \
  -only-testing:TesseraTests/PaneLayoutMathTests/test_compactTmuxClientSizingProjectsFocusedPaneToPhoneViewport
