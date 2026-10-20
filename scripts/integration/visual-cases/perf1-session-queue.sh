#!/usr/bin/env bash
# Native, host-free end-to-end scheduler-pressure regression. The aggregate
# caller owns its iPad; this case owns and always deletes its compact device.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/PERF1-session-queue"
IPAD_UDID="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
DERIVED_DATA="$(jq -r .derived_data "$VISUAL_ROOT/runtime.json")"
PHONE_STATE="$VISUAL_ROOT/perf1-phone.udid"
RECORD_PID=''
mkdir -p "$CASE_DIR"
cleanup() {
  if [[ -n "$RECORD_PID" ]]; then
    kill -INT "$RECORD_PID" 2>/dev/null || true
    wait "$RECORD_PID" || true
    RECORD_PID=''
  fi
  delete_owned_test_simulator "$PHONE_STATE"
}
trap 'fail_closed_trap cleanup' EXIT
for surface in ipad iphone; do
  UDID="$IPAD_UDID"
  if [[ "$surface" == iphone ]]; then
    UDID="$(xcrun simctl create "Tessera Queue iPhone $(date -u +%Y%m%dT%H%M%SZ)-$$" \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-0)"
    printf '%s\n' "$UDID" >"$PHONE_STATE"
    printf '%s\n' "$UDID" >"$PHONE_STATE.owned"
    xcrun simctl boot "$UDID"
  fi
  xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
  xcrun simctl spawn "$UDID" launchctl setenv TESSERA_QUEUE_ROUNDS "${TESSERA_QUEUE_ROUNDS:-900}"
  xcrun simctl io "$UDID" recordVideo "$CASE_DIR/$surface.mp4" >"$CASE_DIR/$surface-record.log" 2>&1 &
  RECORD_PID=$!
  TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
    -project "$HERE/../../Tessera.xcodeproj" -scheme Tessera -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
    -only-testing:TesseraUITests/VisualCaptureProbe/testSessionQueueKeepsUpWithTwoSustainedOutputStreams \
    -only-testing:TesseraUITests/VisualCaptureProbe/testSessionQueueKeepsUpWithTwoTmuxControlStreams \
    -resultBundlePath "$VISUAL_ROOT/perf1-$surface.xcresult" >"$CASE_DIR/$surface-xctest.log" 2>&1
  kill -INT "$RECORD_PID"
  wait "$RECORD_PID" || true
  RECORD_PID=''
  xcrun simctl spawn "$UDID" log show --last 3m --style compact \
    --predicate 'eventMessage CONTAINS "SessionQueueHarness"' >"$CASE_DIR/$surface-metrics.log" 2>&1
  # Native terminal pixels come from the continuous simctl video.
  filter=transpose=2
  if [[ "$surface" == ipad ]]; then
    rotate="$("$HERE/landscape-video-filter.sh" "$CASE_DIR/$surface.mp4")"
    filter="${rotate%,}"
  fi
  for seconds in 14 6; do
    ffmpeg -nostdin -loglevel error -sseof "-$seconds" -i "$CASE_DIR/$surface.mp4" \
      -vf "${filter:-null}" -frames:v 1 "$CASE_DIR/$surface-last-${seconds}s.png"
  done
done
python3 - "$CASE_DIR/case.json" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'id': 'PERF1-session-queue',
    'title': 'Two sustained session streams under native UI scheduling pressure',
    'matrix_ids': ['PERF1'],
    'invariants': [
        'The native terminal continues rendering ordered row output under sustained UI contention, without an expanding output delay.',
        'All generated packets reach the UI in order and half are actually painted; worst end-to-end output age is below 1000ms and input admission-to-backend age below 250ms.',
        'The same acceptance runs on landscape iPad and compact iPhone, with both raw output and real cooperative tmux control parsing. No user host is connected.'
    ],
    'capture_notes': 'Real SSHSession publication seam, Apple facade, shared SessionEngine, native stream delivery and CoreGraphics terminal. Two independent synthetic network FIFOs emit16packets every16ms (900rounds by default, configurable for soak). Their detached readers use the production SSH publication method without making a connection. A controlled2ms cooperative UI task creates scheduler contention. Only the first stream paints; completion requires its renderer count. Tmux uses real parsing and send-keys; synthetic remote command guards enter the same network FIFO. This is a scheduler-pressure oracle, not a physical CPU profile or proof of a historical introducing commit. Images come from continuous simctl recordings, with iPad frames normalized to landscape; logs carry exact timing and completion.',
    'deterministic_precheck': {'verdict': 'pass', 'details': 'Both native XCUITests require full ordered drain and enforce output/input latency bounds.'}
}, indent=2) + '\n')
PY
script_completed=1
