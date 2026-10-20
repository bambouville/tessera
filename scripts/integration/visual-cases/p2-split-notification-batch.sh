#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:?supply aggregate run directory}"
CASE_DIR="$RUN_DIR/visual/cases/P2-split-notification-batch"
RUNTIME="$RUN_DIR/visual/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
mkdir -p "$CASE_DIR"
recorder=''
test_pid=''
cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  [[ -z "$recorder" ]] || { kill -INT "$recorder" 2>/dev/null || true; wait "$recorder" || true; }
  [[ -z "$test_pid" ]] || { kill "$test_pid" 2>/dev/null || true; wait "$test_pid" || true; }
  exit "$status"
}
trap cleanup EXIT
xcrun simctl io "$UDID" recordVideo --codec=h264 "$CASE_DIR/sequence.mov" >"$CASE_DIR/record.log" 2>&1 &
recorder=$!
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" -scheme Tessera \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RUN_DIR/visual/split-notification-batch.xcresult" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testSplitBatchPresentation \
  >"$CASE_DIR/xctest.log" 2>&1 &
test_pid=$!
for stage in split returned; do
  captured=0
  for ((attempt=0; attempt<240; attempt++)); do
    if rg -q "TESSERA_SPLIT_CAPTURE $stage" "$CASE_DIR/xctest.log"; then
      # Model publication precedes the asynchronous capture replies and layer draw.
      sleep 1
      xcrun simctl io "$UDID" screenshot "$CASE_DIR/$stage.raw.png" >/dev/null
      "$HERE/normalize-landscape-screenshot.sh" "$CASE_DIR/$stage.raw.png" "$CASE_DIR/$stage.png" >/dev/null
      rm "$CASE_DIR/$stage.raw.png"
      captured=1
      break
    fi
    kill -0 "$test_pid" 2>/dev/null || break
    sleep 0.5
  done
  [[ "$captured" == 1 ]] || { cat "$CASE_DIR/xctest.log" >&2; exit 1; }
done
wait "$test_pid"
test_pid=''
kill -INT "$recorder"
wait "$recorder"
recorder=''
xcrun simctl spawn "$UDID" log show --last 3m --style compact \
  --predicate 'eventMessage CONTAINS "SplitBatchHarness"' >"$CASE_DIR/harness.log"
cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "P2-split-notification-batch",
  "title": "Split-pane notification ordering and window return",
  "matrix_ids": ["P2"],
  "invariants": [
    "split.png displays two distinct production terminal panes in landscape, with ORIGINAL PANE %5 on the left and NEW PANE %6 on the right.",
    "returned.png retains both panes after switching to another window and back, without reconnecting.",
    "The new right pane is focused, and the original pane's content remains visible. No blank, missing or full-width replacement surface is acceptable."
  ],
  "capture_notes": "Host-free production TmuxController, PaneGridView and terminal surfaces. Focus and layout notifications share one cooperative input read, reproducing the September 19 failure. XCUITest verifies layout and focus and emits capture milestones; simctl records actual terminal layers. Live VPS coverage separately exercises horizontal/vertical split, typing, window return, zoom and collapse on SSH+tmux and mosh+tmux; plain transport paths remain no-op.",
  "deterministic_precheck": {"verdict":"pass","details":"The native UI test requires panes=2 and focus=%6 immediately after split and after window return."}
}
JSON
script_completed=1
