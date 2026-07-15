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

rm -rf "$VISUAL_ROOT/ag1-hook-disclosure.xcresult"
xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$VISUAL_ROOT/ag1-hook-disclosure.xcresult" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentHookHelpDisclosureExpands \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentCenterHarnessCoversLifecycleStatesAndIdentity \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentAttentionTopBarAndPopoverUseCurrentWindowVisibility \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentNotificationDeliversWhileBackgroundAssertionIsActive \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentCenterInstallPromptOpensHelpAndSource \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentIntegrationMissingAgentConfirmationDisclosesOneStepActivation \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentIntegrationWarningOpensHelpAndSource \
  >"$CASE_DIR/hook-disclosure-xctest.log" 2>&1

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_CENTER_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/agent-center.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/agent-center.raw.png" --out "$CASE_DIR/agent-center.png" >/dev/null
rm "$CASE_DIR/agent-center.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_ATTENTION_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/attention-bar-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/attention-bar.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/attention-bar.raw.png" --out "$CASE_DIR/attention-bar.png" >/dev/null
rm "$CASE_DIR/attention-bar.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_ATTENTION_HARNESS=1 \
SIMCTL_CHILD_TESSERA_AGENT_ATTENTION_AUTO_OPEN=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/attention-popover-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/attention-popover.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/attention-popover.raw.png" --out "$CASE_DIR/attention-popover.png" >/dev/null
rm "$CASE_DIR/attention-popover.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_HOOK_HELP_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/hook-help-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/hook-help.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/hook-help.raw.png" --out "$CASE_DIR/hook-help.png" >/dev/null
rm "$CASE_DIR/hook-help.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_HOOK_SOURCE_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/hook-source-launch.txt"
# The exact source is a width-constrained, vertically scrollable, selectable
# text view. Its first layout can outlive the generic two-second launch settle
# on a cold sim, leaving the app's launch progress veil in the screenshot.
# Capture the stable disclosure state that a person actually reads.
sleep 4
xcrun simctl io "$UDID" screenshot "$CASE_DIR/hook-source.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/hook-source.raw.png" --out "$CASE_DIR/hook-source.png" >/dev/null
rm "$CASE_DIR/hook-source.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_INTEGRATION_WARNING_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/integration-warning-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/integration-warning.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/integration-warning.raw.png" --out "$CASE_DIR/integration-warning.png" >/dev/null
rm "$CASE_DIR/integration-warning.raw.png"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_PALETTE_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/palette-launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/agent-palette.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/agent-palette.raw.png" --out "$CASE_DIR/agent-palette.png" >/dev/null
rm "$CASE_DIR/agent-palette.raw.png"

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "AG1-agent-center",
  "title": "Agent Center lifecycle states, session identity, and inline controls",
  "matrix_ids": ["AG1"],
  "invariants": [
    "A real Codex plan-approval menu, just-finished agent, working agent, idle agent, and unavailable agent appear in urgency order with distinct readable status treatment.",
    "Each card keeps its provider session reference, human task summary, host, transport, tmux window/pane address, duration, meaningful viewport excerpt, and open affordance legible without overlap or clipping.",
    "The working card's task remains the submitted Validate Agent Center request even while its viewport excerpt contains the live Improve documentation composer suggestion.",
    "The blocked plan card renders only its parsed valid answer buttons; working and idle cards render their correct message, queue, interrupt, and send controls.",
    "A just-finished group is visually distinct from idle, and idle duration reports time since the last provider lifecycle event.",
    "The Agent Center sidebar row keeps amber needs-input and neutral total counts while its green completion count represents only unread off-screen completions; viewing Agent Center clears that green count without erasing the just-finished card.",
    "The foreground terminal bar aggregates only unread off-screen needs-input and just-finished events; its popover identifies each exact tmux location and offers an open action.",
    "A user-initiated working turn owns a finite iPadOS background assertion; a synthetic Stop delivered after Home schedules an immediate local notification and is verified in the system delivered-notification store.",
    "Every pane in the currently visible tmux window is omitted from unread attention and the active tab has no green completion marker; inactive waiting and unread-finished windows are amber and green respectively.",
    "The unavailable card exposes an explicit install-status-hook action rather than implying that remote mutation is automatic.",
    "Hook help explains why lifecycle integration is necessary, enumerates every remote mutation and privacy boundary, and its show-more state exposes readable exact source without clipping the primary disclosure controls.",
    "The terminal top bar warning is visible at the far right only when Agent Center integration needs attention, and its popover gives a succinct reason plus a state-specific fix action.",
    "An inactive shell warning offers distinct immediate and automatic activation actions; automatic activation names the future-window startup behavior and remains behind explicit confirmation.",
    "The command palette lists sessions before urgency-ranked agents, shows location context, and remains navigation-only.",
    "The page is landscape, uses the Tessera flat frosted design language, and has no horizontal truncation of the primary actions at iPad width."
  ],
  "capture_notes": "DEBUG Agent Center, attention, and hook-disclosure harnesses with deterministic in-memory state; no host connection, mutation, or user data. The aggregate programmatic lane separately drives real installed Codex and Claude through idle, working, visible permission, approval, and idle. Screenshot pixels were rotated counter-clockwise to normalize simctl's fixed portrait framebuffer into landscape.",
  "deterministic_precheck": {"verdict": "pass", "details": "XCUITest proves current-window completion-marker suppression, unread tab clearing, top-bar/popover counts, and real local-notification delivery while backgrounded; it also expands direct Help and reaches exact source through both the Agent Center install and terminal-warning repair confirmations. Unit and real-provider lanes verify scene direction, background-assertion policy, plan, and permission classification."}
}
JSON
