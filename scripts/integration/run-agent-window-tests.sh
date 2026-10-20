#!/usr/bin/env bash
# Connection-free native window/transport adapter gate. Creates and deletes
# only its own simulator; never launches a saved user-host connection.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
WINDOW_UI_TEST=testBoundedIngestionWindowKeepsHistoryWhileHeadAdvances
case "${1:-}" in
    --phone)
        export TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
        export TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Window iPhone'
        WINDOW_UI_TEST=testBoundedIngestionWindowOnPhone
        ;;
    '') ;;
    *) die 'usage: run-agent-window-tests.sh [--phone]' ;;
esac
if [[ "${TESSERA_AGENT_CHAT_FOLLOW_TEST:-0}" == 1 ]]; then
    WINDOW_UI_TEST=testChatFollowsSameRecordGrowth
    if [[ "${1:-}" == --phone ]]; then WINDOW_UI_TEST=testChatFollowsSameRecordGrowthOnPhone; fi
fi
CHAT_UI_TEST=testChatFollowsSameRecordGrowth
DETACHED_UI_TEST=testInitiallyDetachedWindowCanPage
PROGRESS_UI_TEST=testReadProgressNeverShiftsAShownTranscript
SHORT_UI_TEST=testShortTranscriptSitsAtTheEndAndFillsFromHistory
SPLIT_UI_TEST=testFollowerKeepsTheNewestRowsWhenARevisionSplitsItsRolledHead
if [[ "${1:-}" == --phone ]]; then
    CHAT_UI_TEST=testChatFollowsSameRecordGrowthOnPhone
    DETACHED_UI_TEST=testInitiallyDetachedWindowCanPageOnPhone
    PROGRESS_UI_TEST=testReadProgressNeverShiftsAShownTranscriptOnPhone
    SHORT_UI_TEST=testShortTranscriptSitsAtTheEndAndFillsFromHistoryOnPhone
    SPLIT_UI_TEST=testFollowerKeepsTheNewestRowsWhenARevisionSplitsItsRolledHeadOnPhone
fi
RUN_DIR="$(mktemp -d /private/tmp/tessera-window-ui.XXXXXXXX)"
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="window-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$RUN_DIR/simulator"
export TESSERA_INTEGRATION_FIXTURE_STATE_DIR="$RUN_DIR/state"
export TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$RUN_DIR/simulator/simulator_udid"
WINDOW_RECORD_PID=""
WINDOW_RESOURCE_PID=""
cleanup() {
    local status=$?
    fail_closed_status "$status" || status=1
    trap - EXIT
    if [[ -n "$WINDOW_RESOURCE_PID" ]]; then
        kill -TERM "$WINDOW_RESOURCE_PID" 2>/dev/null || true
        wait "$WINDOW_RESOURCE_PID" || status=1
    fi
    if [[ -n "$WINDOW_RECORD_PID" ]]; then
        kill -INT "$WINDOW_RECORD_PID" 2>/dev/null || true
        wait "$WINDOW_RECORD_PID" 2>/dev/null || true
    fi
    delete_owned_test_simulator "$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE" || status=1
    printf 'Window test evidence: %s\n' "$RUN_DIR"
    exit "$status"
}
trap cleanup EXIT
"$HERE/ensure-test-simulator.sh" >"$RUN_DIR/simulator.log" 2>&1
IFS= read -r WINDOW_TEST_UDID <"$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE"
xcrun simctl spawn "$WINDOW_TEST_UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
xcrun simctl io "$WINDOW_TEST_UDID" recordVideo --codec=h264 "$RUN_DIR/window.mp4" >"$RUN_DIR/video.log" 2>&1 &
WINDOW_RECORD_PID=$!
python3 "$REPO_ROOT/scripts/performance/agent-center/native_ui_resources.py" \
    --device "$WINDOW_TEST_UDID" --output "$RUN_DIR/app-resources.json" --seconds 600 \
    >"$RUN_DIR/app-resources.log" 2>&1 &
WINDOW_RESOURCE_PID=$!
TESSERA_VISUAL_CAPTURE=1 integration_xcodebuild test \
    -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
    -destination "platform=iOS Simulator,id=$WINDOW_TEST_UDID" \
    -derivedDataPath /private/tmp/tessera-ingestion-derived \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES -maximum-test-execution-time-allowance 240 \
    -resultBundlePath "$RUN_DIR/window.xcresult" \
    -only-testing:TesseraTests/AgentCenterV2CoordinatorTests \
    -only-testing:TesseraTests/AppleAgentServicesTests \
    -only-testing:TesseraTests/MoshBootstrapTests \
    "-only-testing:TesseraUITests/VisualCaptureProbe/$DETACHED_UI_TEST" \
    "-only-testing:TesseraUITests/VisualCaptureProbe/$CHAT_UI_TEST" \
    "-only-testing:TesseraUITests/VisualCaptureProbe/$WINDOW_UI_TEST" \
    "-only-testing:TesseraUITests/VisualCaptureProbe/$PROGRESS_UI_TEST" \
    "-only-testing:TesseraUITests/VisualCaptureProbe/$SHORT_UI_TEST" \
    "-only-testing:TesseraUITests/VisualCaptureProbe/$SPLIT_UI_TEST" \
    -only-testing:TesseraUITests/VisualCaptureProbe/testAgentComposerSendShortcutHint \
    >"$RUN_DIR/test.log" 2>&1
xcrun simctl io "$WINDOW_TEST_UDID" screenshot "$RUN_DIR/final.png" >/dev/null
script_completed=1
