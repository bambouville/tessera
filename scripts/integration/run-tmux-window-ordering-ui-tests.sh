#!/usr/bin/env bash
# Host-free tmux ordering UI on one owned disposable simulator.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?usage: run-tmux-window-ordering-ui-tests.sh RUN_DIR [--phone|--strip]}"
TEST_FILTER=TesseraUITests/VisualCaptureProbe/testTmuxWindowOrderingDragAndMenu
expected_milestones=(before-drag after-drag menu strip-before strip-after)
if [[ "${2:-}" == --phone ]]; then
  export TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
  TEST_FILTER=TesseraUITests/VisualCaptureProbe/testTmuxWindowOrderingCompact
  expected_milestones=(compact-before compact-after compact-menu compact-keyboard compact-scrolled)
fi
if [[ "${2:-}" == --strip ]]; then
  TEST_FILTER=TesseraUITests/VisualCaptureProbe/testTmuxWindowOrderingStrip
  expected_milestones=(strip-before strip-after)
fi
test_args=(-only-testing:"$TEST_FILTER")
expected_passes=1
if [[ -z "${2:-}" ]]; then
  test_args+=(-only-testing:TesseraUITests/VisualCaptureProbe/testTmuxWindowOrderingStrip)
  expected_passes=2
fi
mkdir -p "$RUN_DIR"
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="tmux-order-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$RUN_DIR/simulator"
export TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$RUN_DIR/simulator/simulator_udid"
record_pid=''
test_pid=''
cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  trap - EXIT
  if [[ -n "$test_pid" ]]; then
    pkill -TERM -P "$test_pid" 2>/dev/null || true
    kill "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
  fi
  if [[ -n "$record_pid" ]]; then
    kill -INT "$record_pid" 2>/dev/null || true
    wait "$record_pid" 2>/dev/null || true
  fi
  if [[ -d "$RUN_DIR/ordering.xcresult" ]]; then
    xcrun xcresulttool export attachments --path "$RUN_DIR/ordering.xcresult" \
      --output-path "$RUN_DIR/attachments" >/dev/null 2>&1 || true
  fi
  if [[ -n "${udid:-}" ]]; then
    xcrun simctl spawn "$udid" log show --last 2m --style compact \
      --predicate 'eventMessage CONTAINS "tmux-window-reorder"' \
      > "$RUN_DIR/reorder-events.log" 2>&1 || true
  fi
  delete_owned_test_simulator "$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE" || status=1
  exit "$status"
}
trap cleanup EXIT
"$HERE/ensure-test-simulator.sh" > "$RUN_DIR/simulator.log" 2>&1
IFS= read -r udid < "$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE"
xcrun simctl spawn "$udid" launchctl setenv TESSERA_VISUAL_CAPTURE 1
if [[ "${2:-}" != --phone ]]; then
  TESSERA_VISUAL_CAPTURE=1 integration_xcodebuild test-without-building \
    -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$(integration_derived_data)" \
    -parallel-testing-enabled NO -resultBundlePath "$RUN_DIR/orientation.xcresult" \
    -only-testing:TesseraUITests/VisualCaptureProbe/testSetLandscapeOnly \
    > "$RUN_DIR/orientation.log" 2>&1
fi
xcrun simctl io "$udid" recordVideo --codec=h264 "$RUN_DIR/interaction.mp4" > "$RUN_DIR/video.log" 2>&1 &
record_pid=$!
TESSERA_VISUAL_CAPTURE=1 integration_xcodebuild test-without-building \
  -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$(integration_derived_data)" \
  -parallel-testing-enabled NO -resultBundlePath "$RUN_DIR/ordering.xcresult" \
  "${test_args[@]}" > "$RUN_DIR/xctest.log" 2>&1 &
test_pid=$!
mkdir -p "$RUN_DIR/screenshots"
while kill -0 "$test_pid" 2>/dev/null; do
  for milestone in before-drag after-drag menu strip-before strip-after compact-before compact-after compact-menu compact-keyboard compact-scrolled; do
    if [[ ! -f "$RUN_DIR/screenshots/$milestone.png" ]] && rg -q "TESSERA_WINDOW_ORDER_CAPTURE $milestone" "$RUN_DIR/xctest.log"; then
      xcrun simctl io "$udid" screenshot "$RUN_DIR/screenshots/$milestone.raw.png" >/dev/null
      if [[ "${2:-}" == --phone ]]; then
        cp "$RUN_DIR/screenshots/$milestone.raw.png" "$RUN_DIR/screenshots/$milestone.png"
      else
        "$HERE/normalize-landscape-screenshot.sh" "$RUN_DIR/screenshots/$milestone.raw.png" "$RUN_DIR/screenshots/$milestone.png" >/dev/null
      fi
    fi
  done
  sleep 0.2
done
status=0
wait "$test_pid" || status=$?
test_pid=''
[[ "$status" -eq 0 ]] || exit "$status"
for milestone in "${expected_milestones[@]}"; do
  if [[ ! -s "$RUN_DIR/screenshots/$milestone.png" ]]; then
    echo "Missing required ordering capture: $milestone" >&2
    exit 1
  fi
done
xcrun simctl io "$udid" screenshot "$RUN_DIR/final.png" >/dev/null
xcrun xcresulttool get test-results summary --path "$RUN_DIR/ordering.xcresult" > "$RUN_DIR/summary.json"
python3 - "$RUN_DIR/summary.json" "$expected_passes" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary.get("passedTests", 0) == int(sys.argv[2]) and summary.get("skippedTests", 0) == 0 and summary.get("failedTests", 0) == 0, summary
PY
xcrun xcresulttool export attachments --path "$RUN_DIR/ordering.xcresult" --output-path "$RUN_DIR/attachments" >/dev/null
script_completed=1
