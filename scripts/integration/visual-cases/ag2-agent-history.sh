#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/AG2-agent-history"
UDID="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
DERIVED_DATA="$(jq -r .derived_data "$VISUAL_ROOT/runtime.json")"
RESULT="$VISUAL_ROOT/ag2-agent-history.xcresult"
mkdir -p "$CASE_DIR"
PHONE_STATE="$VISUAL_ROOT/ag2-phone.udid"
trap 'fail_closed_trap delete_owned_test_simulator "$PHONE_STATE"' EXIT

xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" -scheme Tessera -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentHistoryLoadsWhileScrollingAndPreservesPosition \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentShortHistoryRetriesAndFillsWithoutAButton \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentDiscoveryKeepsRowsStationaryWhilePolling \
  >"$CASE_DIR/ipad-xctest.log" 2>&1

PHONE_UDID="$(xcrun simctl create "Tessera Agent History iPhone $(date -u +%Y%m%dT%H%M%SZ)-$$" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-0)"
printf '%s\n' "$PHONE_UDID" >"$PHONE_STATE"
printf '%s\n' "$PHONE_UDID" >"$PHONE_STATE.owned"
xcrun simctl boot "$PHONE_UDID"
xcrun simctl spawn "$PHONE_UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" -scheme Tessera -configuration Debug \
  -destination "platform=iOS Simulator,id=$PHONE_UDID" -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$VISUAL_ROOT/ag2-agent-history-iphone.xcresult" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentHistoryLoadsWhileScrollingAndPreservesPosition \
  -only-testing:TesseraUITests/VisualCaptureProbe/testAgentShortHistoryRetriesAndFillsWithoutAButton \
  >"$CASE_DIR/iphone-xctest.log" 2>&1
delete_owned_test_simulator "$PHONE_STATE"

# The fixture is entirely native SwiftUI; these captures contain no Metal
# terminal. Export only named acceptance images, not incidental test UI shots.
for surface in ipad iphone; do
  if [[ "$surface" == iphone ]]; then RESULT="$VISUAL_ROOT/ag2-agent-history-iphone.xcresult"; fi
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$VISUAL_ROOT/ag2-attachments-$surface" \
    >"$CASE_DIR/$surface-attachment-export.log" 2>&1
  python3 - "$VISUAL_ROOT/ag2-attachments-$surface" "$CASE_DIR" "$surface" <<'PY'
import json, pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:3])
count = 0
for test in json.loads((source / 'manifest.json').read_text()):
    for item in test.get('attachments', []):
        name = item.get('suggestedHumanReadableName', '')
        if name.startswith(('history-', 'discovery-')):
            shutil.copy2(source / item['exportedFileName'], target / (sys.argv[3] + '-' + name))
            count += 1
expected = 5 if sys.argv[3] == 'ipad' else 3
if count != expected:
    raise SystemExit(f'Expected {expected} named history/discovery screenshots, got {count}')
PY
done

if [[ "${TESSERA_RUN_ANDROID_NATIVE_SSH_GATE:-0}" == 1 ]]; then
  "$HERE/../android/run-agent-history-gate.sh" "$VISUAL_ROOT/ag2-android" >"$CASE_DIR/android-run.log" 2>&1
  cp "$VISUAL_ROOT/ag2-android/instrumentation.log" "$CASE_DIR/android-tablet-tests.log"
  cp "$VISUAL_ROOT/ag2-android/phone-instrumentation.log" "$CASE_DIR/android-phone-tests.log"
  cp "$VISUAL_ROOT/ag2-android/cleanup.txt" "$CASE_DIR/android-cleanup.txt"
  for surface in tablet phone; do
    for stage in before after retried; do
      cp "$VISUAL_ROOT/ag2-android/$surface/agent-transcript-history-$stage.png" "$CASE_DIR/android-$surface-$stage.png"
    done
  done
fi

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "AG2-agent-history",
  "title": "Agent Center automatic history loading",
  "matrix_ids": ["AG2"],
  "invariants": [
    "No load-older button is present. Approaching the start of loaded history automatically requests the next page.",
    "The before/after captures preserve the visible message and its vertical reading offset when an older page is prepended.",
    "A short transcript automatically fills; a simulated failed read retries without requiring a button or another scroll.",
    "Repeated alternating discovery completions keep Claude and Codex live-terminal rows at identical vertical positions.",
    "When Android evidence is present, both tablet and compact phone use the same pagination; the tests also verify exhaustion and a collapsed tool group merging across a page boundary."
  ],
  "capture_notes": "Host-free fixtures exercise native production transcript views. iPad and iPhone screenshots are native SwiftUI XCUIScreen captures with no Metal terminal. Android screenshots are captured on a disposable AVD; Android evidence is included with the aggregate Android opt-in.",
  "deterministic_precheck": {"verdict":"pass","details":"iPad and iPhone XCUITest assert automatic loading, retry and visible-message offset within four points. Included Android tests assert message and tool-header offsets within two pixels, automatic retry and stopping at exhaustion."}
}
JSON
script_completed=1
