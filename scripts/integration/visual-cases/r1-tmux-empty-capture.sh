#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || exit 2

VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/R1-tmux-empty-capture"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
run_token="$(date +%s)-$$-$RANDOM"
mkdir -p "$CASE_DIR"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
launch_output="$(
  SIMCTL_CHILD_TESSERA_TMUX_EMPTY_CAPTURE_HARNESS=1 \
  SIMCTL_CHILD_TESSERA_TMUX_EMPTY_CAPTURE_RUN_TOKEN="$run_token" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID"
)"
printf '%s\n' "$launch_output" >"$CASE_DIR/launch.txt"
launch_pid="${launch_output##*: }"
[[ "$launch_pid" =~ ^[0-9]+$ ]]

# The harness holds the invalid-capture interval for five seconds. During that
# interval the established first-window pixels must remain visible.
sleep 3
xcrun simctl io "$UDID" screenshot "$CASE_DIR/preserved.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/preserved.raw.png" --out "$CASE_DIR/preserved.png" >/dev/null
rm "$CASE_DIR/preserved.raw.png"

# The harness then satisfies the production controller's scheduled retry with
# a recognizable second-window viewport. SwiftTerm's CAMetalLayer can present
# a few frames after the controller's synchronous feed, so leave a full render
# interval before asking simctl for the Metal-aware frame.
sleep 6
xcrun simctl io "$UDID" screenshot "$CASE_DIR/recovered.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/recovered.raw.png" --out "$CASE_DIR/recovered.png" >/dev/null
rm "$CASE_DIR/recovered.raw.png"
if cmp -s "$CASE_DIR/preserved.png" "$CASE_DIR/recovered.png"; then
  echo "R1 recovery frame never advanced from the preserved viewport" >&2
  exit 1
fi

xcrun simctl spawn "$UDID" log show --last 30s --style compact \
  --predicate "processIdentifier == $launch_pid AND eventMessage CONTAINS \"TmuxEmptyCaptureHarness\"" \
  >"$CASE_DIR/harness.log"
preserved_verdict="$(grep 'phase=preserved' "$CASE_DIR/harness.log" | tail -1)"
latest_verdict="$(grep 'verdict=' "$CASE_DIR/harness.log" | tail -1)"
[[ "$preserved_verdict" == *"token=$run_token ok=true"* ]]
[[ "$latest_verdict" == *"verdict=recovered token=$run_token"* ]]

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "R1-tmux-empty-capture",
  "title": "Inline tmux empty-capture preservation and recovery",
  "matrix_ids": ["R1"],
  "invariants": [
    "preserved.png retains a complete blue WINDOW ONE viewport while an impossible zero-row capture is rejected; it must not be black, cursor-only, partial, or cleared.",
    "recovered.png shows the complete green RECOVERED WINDOW TWO viewport after the authoritative retry, without stale blue rows, black regions, half-width tails, or geometry drift.",
    "Both frames fill the landscape terminal canvas edge-to-edge and keep every numbered row coherent at the surface's measured runtime geometry."
  ],
  "capture_notes": "DEBUG host-free harness using the production inline TmuxController and production SwiftTerm terminal surface. It measures the live terminal geometry, seeds one rendered window, switches to a second window, injects the July 19 impossible successful zero-row capture, and later satisfies the controller retry with a full recognizable grid. No host connection or user data. preserved.png is captured during the rejected-capture interval; recovered.png is captured after retry. Screenshot pixels were rotated counter-clockwise to normalize simctl's fixed portrait framebuffer into landscape.",
  "deterministic_precheck": {"verdict": "pass", "details": "The launch-PID- and run-token-scoped host-free production controller logged phase=preserved with no swap/feed caused by the invalid response, then verdict=recovered only after the requested window and pane became authoritative with exactly one swap and one replacement feed. Package tests separately cover the shared terminal, split-pane grid, mosh+tmux side channel, optional alternate history and saved-primary captures, and bounded FIFO recovery."}
}
JSON
