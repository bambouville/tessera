#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || exit 2

VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/AG1-agent-center"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
mkdir -p "$CASE_DIR"

rm -rf "$VISUAL_ROOT/ag1-agent-center-v2.xcresult"
xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$VISUAL_ROOT/ag1-agent-center-v2.xcresult" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentCenterV2HarnessCoversThreadHierarchyAndActions \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentCenterV2HarnessCoversLoadingAndCompactUrgentFallback \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentCenterV2HarnessCoversErrorTraitsAndKeyboardFocus \
  >"$CASE_DIR/agent-center-v2-xctest.log" 2>&1

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_CENTER_V2_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/agent-center.raw.png" >/dev/null
"$HERE/normalize-landscape-screenshot.sh" "$CASE_DIR/agent-center.raw.png" "$CASE_DIR/agent-center.png" >/dev/null
rm "$CASE_DIR/agent-center.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_SWIPEPAD_FAN_HARNESS=1 \
SIMCTL_CHILD_TESSERA_SWIPEPAD_FAN_OPTIONS=3 \
SIMCTL_CHILD_TESSERA_SWIPEPAD_FAN_CORNER=bottomRight \
SIMCTL_CHILD_TESSERA_SWIPEPAD_FORCE_RADIAL_OPEN=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/swipepad-partial-fan-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/swipepad-partial-fan.raw.png" >/dev/null
"$HERE/normalize-landscape-screenshot.sh" "$CASE_DIR/swipepad-partial-fan.raw.png" "$CASE_DIR/swipepad-partial-fan.png" >/dev/null
rm "$CASE_DIR/swipepad-partial-fan.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_SWIPEPAD_FAN_HARNESS=1 \
SIMCTL_CHILD_TESSERA_SWIPEPAD_FAN_OPTIONS=idle \
SIMCTL_CHILD_TESSERA_SWIPEPAD_FAN_CORNER=bottomRight \
SIMCTL_CHILD_TESSERA_SWIPEPAD_FORCE_RADIAL_OPEN=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/swipepad-idle-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/swipepad-idle.raw.png" >/dev/null
"$HERE/normalize-landscape-screenshot.sh" "$CASE_DIR/swipepad-idle.raw.png" "$CASE_DIR/swipepad-idle.png" >/dev/null
rm "$CASE_DIR/swipepad-idle.raw.png"


cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "AG1-agent-center",
  "title": "Agent Center v2 host-free visual fixture",
  "matrix_ids": ["AG1"],
  "invariants": [
    "The primary iPad fixture shows the mockup's existing navigation, grouped thread list, and selected structured thread without a browser-tab row.",
    "The fixture includes needs-input, working, unread-finished, recent, and identity-unproven live-terminal rows; their grouped labels and selected-thread provider/project/branch/host/context/cost metadata are asserted by XCUITest.",
    "The selected thread exposes Live, Activity, and Changes plus text, collapsed thinking, tool, edit, workflow, subagent, and permission-prompt blocks; the deterministic test enters Activity and Changes.",
    "The host-free fixture renders New and Fork sheets, the selected thread's prompt actions, Open Terminal, dictation, Send/Queue, and Interrupt controls without a host connection or remote mutation.",
    "The loading, error, and degraded scenes assert searching, a source-changed safe error, and the no-proven-transcript live-terminal fallback; the compact scene asserts list-to-detail navigation and Open terminal to answer when the prompt lacks a prompt-answer capability.",
    "Deterministic fixture runs force dark/accessibility Dynamic Type and light/standard Dynamic Type, then verify action, list, and composer keyboard-focus ownership through the fixture's DEBUG accessibility state.",
    "The retained SwipePad screenshots cover only a three-option fan and an idle fan, including their compact radial packing."
  ],
  "capture_notes": "DEBUG Agent Center v2 and SwipePad fixtures use deterministic shared-domain snapshots only; no host connection, remote mutation, notification delivery, lifecycle-install UI, command-palette route, or background assertion is represented here. Frames are normalized to upright landscape whichever shape simctl returns.",
  "deterministic_precheck": {"verdict": "pass", "details": "XCUITest checks the V2 fixture's grouped list, structured thread hierarchy and block kinds, prompt choices, all three projections, New and Fork sheet entry, loading search state, source-changed error, degraded live-terminal fallback, dark/light and Dynamic Type trait injection, keyboard-focus ownership, and compact list-detail navigation with its Open terminal to answer fallback. Separate retained captures show only the stated SwipePad fan variants."}
}
JSON
