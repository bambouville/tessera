#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || exit 2

VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/W1-tmux-window-close"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
XCRESULT="$VISUAL_ROOT/w1-tmux-window-close.xcresult"
mkdir -p "$CASE_DIR"

rm -rf "$XCRESULT"
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$XCRESULT" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testTmuxWindowCloseControls \
  >"$CASE_DIR/xctest.log" 2>&1
xcrun xcresulttool get test-results summary --path "$XCRESULT" \
  >"$CASE_DIR/xctest-summary.json"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_TMUX_WINDOW_CLOSE_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/tabs-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/tabs.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/tabs.raw.png" --out "$CASE_DIR/tabs.png" >/dev/null
rm "$CASE_DIR/tabs.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_TMUX_WINDOW_CLOSE_HARNESS=1 \
SIMCTL_CHILD_TESSERA_TMUX_WINDOW_CLOSE_AUTO_CONFIRM=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/confirmation-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/confirmation.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/confirmation.raw.png" --out "$CASE_DIR/confirmation.png" >/dev/null
rm "$CASE_DIR/confirmation.raw.png"

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "W1-tmux-window-close",
  "title": "Per-tab tmux window close controls and split-pane confirmation",
  "matrix_ids": ["W1"],
  "invariants": [
    "Every tmux tab has a distinct, legible X inside the tab capsule without obscuring its name or keyboard shortcut.",
    "The single-pane, split-pane, and zoomed split-pane fixture tabs all remain readable in the landscape top bar without clipping or overlap.",
    "Closing a window whose full layout contains multiple panes presents a destructive confirmation naming the pane count and clearly states that every pane in the window will close.",
    "The confirmation offers an unambiguous cancel action and follows Tessera's flat frosted visual language."
  ],
  "capture_notes": "DEBUG host-free SessionTopBar harness with authoritative tmux window/layout hydration; no host connection, remote command, or user data. tabs.png shows the three per-tab close controls. confirmation.png shows the split-window destructive prompt. Screenshot pixels were rotated counter-clockwise to normalize simctl's fixed portrait framebuffer into landscape.",
  "deterministic_precheck": {"verdict": "pass", "details": "XCUITest proved all three X controls exist, single-pane close is immediate, split close can be cancelled or confirmed, confirmation removes the targeted window, and a zoomed two-pane window still requires the two-pane confirmation."}
}
JSON
