#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply a fresh evidence directory}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$RUN_DIR/simulator"
export TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$RUN_DIR/simulator/simulator_udid"
udid=''
video_pid=''
test_pid=''
cleanup() {
  if [[ -n "$test_pid" ]]; then
    # integration_xcodebuild runs in a background subshell; stop its exact
    # child as well before deleting the simulator on an interrupted capture.
    pkill -TERM -P "$test_pid" 2>/dev/null || true
    kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" || true
  fi
  if [[ -n "$video_pid" ]]; then kill -INT "$video_pid" 2>/dev/null || true; wait "$video_pid" || true; fi
  delete_owned_test_simulator "$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE"
}
trap 'fail_closed_trap cleanup' EXIT
derived="${TESSERA_KEYBOARD_DERIVED_DATA:-$(integration_derived_data)}"
if [[ "${TESSERA_INTEGRATION_PREBUILT:-0}" != 1 ]]; then
  xcodebuild build-for-testing -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" ARCHS=arm64 \
    >"$RUN_DIR/build.log" 2>&1
fi
udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"
xcrun simctl io "$udid" recordVideo "$RUN_DIR/keyboard.mov" >"$RUN_DIR/video.log" 2>&1 &
video_pid=$!
integration_xcodebuild test-without-building -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
  -parallel-testing-enabled NO \
  -only-testing:TesseraUITests/HardwareKeyChordHarnessTests \
  -only-testing:TesseraTests/AppleSessionCommandFacadeTests/testBackgroundTerminalCleanupDoesNotResignAnotherViewsFirstResponder \
  -resultBundlePath "$RUN_DIR/tests.xcresult" >"$RUN_DIR/test.log" 2>&1 &
test_pid=$!
while kill -0 "$test_pid" 2>/dev/null; do
  for milestone in background-cleanup mouse-focus foreground; do
    if [[ ! -f "$RUN_DIR/$milestone.png" ]] && grep -q "TESSERA_KEYBOARD_CAPTURE $milestone" "$RUN_DIR/test.log"; then
      xcrun simctl io "$udid" screenshot "$RUN_DIR/$milestone.raw.png" >/dev/null
      "$HERE/normalize-landscape-screenshot.sh" "$RUN_DIR/$milestone.raw.png" "$RUN_DIR/$milestone.png" >/dev/null
    fi
  done
  sleep 0.2
done
status=0
wait "$test_pid" || status=$?
test_pid=''
xcrun simctl spawn "$udid" log show --last 2m --style compact \
  --predicate 'eventMessage CONTAINS "KeyboardDiag"' >"$RUN_DIR/keyboard.log" 2>&1 || true
script_completed=1
exit "$status"
