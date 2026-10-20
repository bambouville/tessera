#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/AG4-agent-prompts"
UDID="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
DERIVED_DATA="$(jq -r .derived_data "$VISUAL_ROOT/runtime.json")"
TEST=TesseraUITests/VisualCaptureProbe/testAgentLivePromptCardsAnswerInPlace
mkdir -p "$CASE_DIR"
PHONE_STATE="$VISUAL_ROOT/ag4-phone.udid"
trap 'fail_closed_trap delete_owned_test_simulator "$PHONE_STATE"' EXIT

xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" -scheme Tessera -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$VISUAL_ROOT/ag4-agent-prompts.xcresult" -only-testing:"$TEST" \
  >"$CASE_DIR/ipad-xctest.log" 2>&1

PHONE_UDID="$(xcrun simctl create "Tessera Agent Prompts iPhone $(date -u +%Y%m%dT%H%M%SZ)-$$" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-0)"
printf '%s\n' "$PHONE_UDID" >"$PHONE_STATE"
printf '%s\n' "$PHONE_UDID" >"$PHONE_STATE.owned"
xcrun simctl boot "$PHONE_UDID"
xcrun simctl spawn "$PHONE_UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" -scheme Tessera -configuration Debug \
  -destination "platform=iOS Simulator,id=$PHONE_UDID" -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$VISUAL_ROOT/ag4-agent-prompts-iphone.xcresult" -only-testing:"$TEST" \
  >"$CASE_DIR/iphone-xctest.log" 2>&1
delete_owned_test_simulator "$PHONE_STATE"

# The fixture is native SwiftUI only; these captures contain no Metal terminal.
for surface in ipad iphone; do
  result="$VISUAL_ROOT/ag4-agent-prompts.xcresult"
  if [[ "$surface" == iphone ]]; then result="$VISUAL_ROOT/ag4-agent-prompts-iphone.xcresult"; fi
  xcrun xcresulttool export attachments --path "$result" --output-path "$VISUAL_ROOT/ag4-attachments-$surface" \
    >"$CASE_DIR/$surface-attachment-export.log" 2>&1
  python3 - "$VISUAL_ROOT/ag4-attachments-$surface" "$CASE_DIR" "$surface" <<'PY'
import json, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:3])
count = 0
for test in json.loads((source / 'manifest.json').read_text()):
    for item in test.get('attachments', []):
        name = item.get('suggestedHumanReadableName', '')
        if name.startswith('prompt-'):
            shutil.copy2(source / item['exportedFileName'], target / (sys.argv[3] + '-' + name))
            count += 1
if count != 8:
    raise SystemExit(f'Expected 8 named prompt screenshots, got {count}')
PY
done

if [[ "${TESSERA_RUN_ANDROID_NATIVE_SSH_GATE:-0}" == 1 ]]; then
  "$HERE/../android/run-agent-prompt-gate.sh" "$VISUAL_ROOT/ag4-android" >"$CASE_DIR/android-run.log" 2>&1
  cp "$VISUAL_ROOT/ag4-android/instrumentation.log" "$CASE_DIR/android-tablet-tests.log"
  cp "$VISUAL_ROOT/ag4-android/phone-instrumentation.log" "$CASE_DIR/android-phone-tests.log"
  cp "$VISUAL_ROOT/ag4-android/cleanup.txt" "$CASE_DIR/android-cleanup.txt"
  for surface in tablet phone; do
    for shot in "$VISUAL_ROOT/ag4-android/$surface"/agent-prompt-*.png; do
      cp "$shot" "$CASE_DIR/android-$surface-${shot##*/agent-}"
    done
  done
fi

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "AG4-agent-prompts",
  "title": "Agent Center live prompt cards",
  "matrix_ids": ["AG4"],
  "invariants": [
    "Each card shows its question in full with vertical option rows. Option details sit below their labels, and the terminal's current selection is highlighted.",
    "The freeform row opens an inline text field with Send. On iPhone, the field and Send stay above the software keyboard.",
    "Text already typed in the terminal is shown as 'In the terminal: ...'.",
    "Multi-select rows lead with monochrome checkbox glyphs matching the terminal's state, followed by a Next control.",
    "The review card shows the collected answers and a Submit option. The text-only card shows its field directly, with Skip.",
    "The deferred Codex card reads '2 questions waiting' with a primary Answer control and says the agent keeps working.",
    "The permission card lists its four options with the command shown in the detail block.",
    "Surfaces are flat and frosted with hairline borders and monochrome glyphs, with no gradients, and nothing is clipped or overlapping."
  ],
  "capture_notes": "Host-free DEBUG fixture (scene prompt) built from the same card fields Core derives from real Claude Code, Codex and Kimi TUI captures. Answers are logged by the fixture instead of written to a terminal. iPad is landscape; iPhone is portrait on a disposable simulator. When Android evidence is present, the same eight cards come from a Compose test on a disposable AVD at tablet and compact phone sizes.",
  "deterministic_precheck": {"verdict":"pass","details":"XCUITest asserts every option, control and text-field identifier per variant, the terminal-entry echo, and the answer field's position above the software keyboard. The included Android tests assert the same tags and the exact answer each option, text and control produces, and that controls disable while an answer is in flight."}
}
JSON
script_completed=1
