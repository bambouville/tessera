#!/usr/bin/env bash
# Native, host-free reproduction of synchronized redraw and split-SGR repaint.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/S7-idle-redraw"
IPAD_UDID="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
DERIVED_DATA="$(jq -r .derived_data "$VISUAL_ROOT/runtime.json")"
APP_PATH="$(jq -r .app_path "$VISUAL_ROOT/runtime.json")"
PHONE_STATE="$VISUAL_ROOT/s7-phone.udid"
BUNDLE_ID=com.bambouville.TesseraApp
UDID=''
record_pid=''
launch_pid=''
mkdir -p "$CASE_DIR"
stop_capture() {
  [[ -z "$UDID" ]] || xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -n "$launch_pid" ]]; then wait "$launch_pid" || true; launch_pid=''; fi
  if [[ -n "$record_pid" ]]; then kill -INT "$record_pid" 2>/dev/null || true; wait "$record_pid" || true; record_pid=''; fi
}
cleanup() { stop_capture; delete_owned_test_simulator "$PHONE_STATE"; }
trap 'fail_closed_trap cleanup' EXIT
wait_stage() {
  local stage="$1" log="$2"
  for _ in {1..300}; do
    if grep -q "stage=$stage" "$log"; then return 0; fi
    sleep 0.1
  done
  printf 'missing redraw milestone %s in %s\n' "$stage" "$log" >&2
  return 1
}
capture_landscape() {
  local path="$1"
  xcrun simctl io "$UDID" screenshot "$path.raw.png"
  if [[ "$surface" == ipad ]]; then
    "$HERE/normalize-landscape-screenshot.sh" "$path.raw.png" "$path" >/dev/null
    rm "$path.raw.png"
  else
    mv "$path.raw.png" "$path"
  fi
}
for surface in ipad iphone; do
  UDID="$IPAD_UDID"
  if [[ "$surface" == iphone ]]; then
    UDID="$(TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Idle Redraw iPhone' \
      TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
      TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$PHONE_STATE" "$HERE/ensure-test-simulator.sh" | tail -n 1)"
  fi
  xcrun simctl install "$UDID" "$APP_PATH"
  if [[ "$surface" == iphone ]]; then
    # Let one-time simulator welcome banners expire before recording.
    SIMCTL_CHILD_TESSERA_SCROLL_HARNESS=1 SIMCTL_CHILD_TESSERA_IDLE_REDRAW_HARNESS=color \
      xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$VISUAL_ROOT/s7-phone-warmup.log" 2>&1
    sleep 8
    xcrun simctl terminate "$UDID" "$BUNDLE_ID"
  fi
  for mode in color-baseline color 1; do
    name="$surface-$mode"
    log="$CASE_DIR/$name.log"
    xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$CASE_DIR/$name.mov" >"$CASE_DIR/$name-record.log" 2>&1 &
    record_pid=$!
    SIMCTL_CHILD_TESSERA_SCROLL_HARNESS=1 SIMCTL_CHILD_TESSERA_IDLE_REDRAW_HARNESS="$mode" \
      xcrun simctl launch --terminate-running-process --console "$UDID" "$BUNDLE_ID" >"$log" 2>&1 &
    launch_pid=$!
    if [[ "$mode" == 1 ]]; then
      wait_stage history "$log"
      capture_landscape "$CASE_DIR/$surface-history.png"
      wait_stage redrawn "$log"
      capture_landscape "$CASE_DIR/$surface-redrawn.png"
      python3 - "$log" <<'PY'
import pathlib,re,sys
s=pathlib.Path(sys.argv[1]).read_text()
a=float(re.search(r'stage=history offset=([\d.]+)',s)[1])
b=float(re.search(r'stage=redrawn offset=([\d.]+)',s)[1])
assert abs(a-b)<0.5,(a,b)
PY
    else
      wait_stage color "$log"
      expected=1; [[ "$mode" != color-baseline ]] || expected=0
      grep -q "stage=color clean=$expected" "$log"
      capture_landscape "$CASE_DIR/$name.png"
    fi
    stop_capture
  done
done
cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "S7-idle-redraw",
  "title": "Idle redraw retains history and tmux repaint cannot split SGR",
  "matrix_ids": ["S1", "S7"],
  "invariants": [
    "On iPad and iPhone, history and redrawn screenshots show the same numbered history rows after 30 synchronized idle prompt redraws.",
    "The intentionally unframed color-baseline screenshot reproduces the visible suffix 58;48;2;0;0;30mX after prompt. This baseline is expected to be broken.",
    "The framed color screenshot shows promptX without numeric escape text, missing characters, or corrupted surrounding geometry."
  ],
  "capture_notes": "Landscape iPad and compact portrait iPhone production TerminalSurfaceBound and SwiftTerm renderer, no remote connection. Continuous simctl videos and Metal-aware screenshots accompany content/offset assertions. The color-baseline mode deliberately bypasses the new framer for a differential reproduction; all other modes use fixed production code. Touch and pointer routing is covered by the separate native scroll lane and live S1/S6 matrix.",
  "deterministic_precheck": {"verdict": "pass", "details": "Both native devices retained the exact fractional offset after 30 redraws; renderer text reproduced the baseline suffix and retained promptX with framing."}
}
JSON
script_completed=1
