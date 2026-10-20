#!/usr/bin/env bash
# Reproduce the measured modal layout pulse while an idle TUI patches its prompt.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/S9-preview-resize"
IPAD_UDID="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
APP_PATH="$(jq -r .app_path "$VISUAL_ROOT/runtime.json")"
PHONE_STATE="$VISUAL_ROOT/s9-phone.udid"
BUNDLE_ID=com.bambouville.TesseraApp
UDID=''; record_pid=''; launch_pid=''
mkdir -p "$CASE_DIR"
stop_capture() {
  [[ -z "$UDID" ]] || xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -n "$launch_pid" ]]; then wait "$launch_pid" || true; launch_pid=''; fi
  if [[ -n "$record_pid" ]]; then kill -INT "$record_pid" 2>/dev/null || true; wait "$record_pid" || true; record_pid=''; fi
}
cleanup() { stop_capture; delete_owned_test_simulator "$PHONE_STATE"; }
trap 'fail_closed_trap cleanup' EXIT
wait_stage() {
  for _ in {1..400}; do
    if grep -q "stage=$1" "$2"; then return 0; fi
    sleep 0.1
  done
  printf 'missing preview milestone %s in %s\n' "$1" "$2" >&2
  return 1
}
capture() {
  xcrun simctl io "$UDID" screenshot "$1.raw.png"
  if [[ "$surface" == ipad ]]; then
    "$HERE/normalize-landscape-screenshot.sh" "$1.raw.png" "$1" >/dev/null
    rm "$1.raw.png"
  else
    mv "$1.raw.png" "$1"
  fi
}
for surface in ipad iphone; do
  UDID="$IPAD_UDID"
  if [[ "$surface" == iphone ]]; then
    UDID="$(TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Preview Resize iPhone' \
      TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
      TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$PHONE_STATE" "$HERE/ensure-test-simulator.sh" | tail -n 1)"
  fi
  xcrun simctl install "$UDID" "$APP_PATH"
  for mode in popup fullScreen; do
    name="$surface-$mode"
    log="$CASE_DIR/$name.log"
    xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$CASE_DIR/$name.mov" >"$CASE_DIR/$name-record.log" 2>&1 &
    record_pid=$!
    SIMCTL_CHILD_TESSERA_SCROLL_HARNESS=1 SIMCTL_CHILD_TESSERA_IDLE_REDRAW_HARNESS=preview \
      SIMCTL_CHILD_TESSERA_PREVIEW_RESIZE_PULSE=1 SIMCTL_CHILD_TESSERA_PREVIEW_MODE="$mode" \
      xcrun simctl launch --terminate-running-process --console "$UDID" "$BUNDLE_ID" >"$log" 2>&1 &
    launch_pid=$!
    for stage in before dismiss after; do
      wait_stage "$stage" "$log"
      capture "$CASE_DIR/$name-$stage.png"
    done
    grep -q 'stage=after clean=1 defects=0' "$log"
    python3 - "$log" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
ticks = re.findall(r'tick=\d+ local=(\d+x\d+) remote=(\d+x\d+)', text)
assert ticks and all(local == remote for local, remote in ticks), ticks
assert len(set(local for local, _ in ticks)) == 1, ticks
PY
    stop_capture
  done
done
cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "S9-preview-resize",
  "title": "Markdown dismissal preserves the terminal prompt during transient layout",
  "matrix_ids": ["S9"],
  "invariants": [
    "After popup and fullscreen Markdown dismissal on iPad and iPhone, the bottom gray prompt contains exactly one Ask Codex to do anything line and has no black holes or stale duplicate text.",
    "The numbered terminal rows remain aligned and the final local grid equals the remote grid.",
    "The dismiss screenshot may capture the modal animation in flight; grade final terminal integrity from after screenshots."
  ],
  "capture_notes": "Production TerminalSurfaceBound and SwiftTerm renderer with actual QuickLookPreview, no remote host. A DEBUG-only 32pt two-frame layout pulse at dismissal makes the measured 976->944->976 modal geometry race deterministic; this is injected timing, not a claim that the bare simulator modal naturally emits the pulse. Continuous simctl videos and Metal-aware screenshots accompany cell-background and grid assertions. iPad landscape and iPhone portrait cover both layouts. Pre-fix bug-present recordings are archived separately in qa/prompt-artifacts-20260911/pulse-before.mov.",
  "deterministic_precheck": {"verdict": "pass", "details": "All four native presentations retained the committed grid and zero gray-background defects after the pulse."}
}
JSON
script_completed=1
