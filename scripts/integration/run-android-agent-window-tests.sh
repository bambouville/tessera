#!/usr/bin/env bash
# Real shared Core/JNI + Compose bounded-history gate. No host connections.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
java_root="${JAVA_HOME:?set JAVA_HOME}"
swift_bin="${SWIFT_ANDROID_SWIFT:?set SWIFT_ANDROID_SWIFT}"
profile="${2:-pixel_tablet}"
case "$profile" in pixel_tablet|pixel_7) ;; *) exit 64 ;; esac
adb="$sdk_root/platform-tools/adb"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
umask 077
out="${1:-$repo_root/.build/agent-window-android/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
run_root="$(mktemp -d /private/tmp/tessera-agent-window-android.XXXXXXXX)"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-agent-window-$(date -u +%Y%m%dT%H%M%SZ)-$$"
serial=''
emulator_pid=''
recorder_pid=''
cleanup() {
    local result=$?
    # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
    # `set -e`; only a run that reached script_completed=1 may exit 0.
    if [[ "$result" -eq 0 && "${script_completed:-0}" != 1 ]]; then
        echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
        result=1
    fi
    trap - EXIT
    if [[ -n "$serial" && "$("$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -1)" == "$avd_name" ]]; then
        if [[ -n "$recorder_pid" ]]; then
            remote_recorder="$("$adb" -s "$serial" shell cat /data/local/tmp/tessera-agent-window-record.pid 2>/dev/null | tr -d '\r')"
            if [[ "$remote_recorder" =~ ^[0-9]+$ ]] &&
               [[ "$("$adb" -s "$serial" shell cat "/proc/$remote_recorder/comm" 2>/dev/null | tr -d '\r')" == screenrecord ]]; then
                "$adb" -s "$serial" shell kill -INT "$remote_recorder" >/dev/null 2>&1 || true
            fi
            wait "$recorder_pid" 2>/dev/null || true
            "$adb" -s "$serial" pull /data/local/tmp/tessera-agent-window.mp4 "$out/window.mp4" >"$out/video-pull.log" 2>&1 || true
        fi
        "$adb" -s "$serial" logcat -d >"$out/logcat.txt" 2>/dev/null || true
        "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
    fi
    if [[ -n "$emulator_pid" ]]; then
        for _ in {1..20}; do kill -0 "$emulator_pid" 2>/dev/null || break; sleep 1; done
        if kill -0 "$emulator_pid" 2>/dev/null; then kill "$emulator_pid" 2>/dev/null || true; fi
        for _ in {1..5}; do kill -0 "$emulator_pid" 2>/dev/null || break; sleep 1; done
        if kill -0 "$emulator_pid" 2>/dev/null; then kill -KILL "$emulator_pid" 2>/dev/null || true; fi
        wait "$emulator_pid" 2>/dev/null || true
    fi
    JAVA_HOME="$java_root" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || true
    if [[ -f "$run_root/emulator.log" ]]; then cp "$run_root/emulator.log" "$out/emulator.log" || true; fi
    # mktemp path owned by this invocation, never the user's global AVD home.
    rm -rf -- "$run_root"
    printf 'Disposed owned AVD %s (%s); result=%s\n' "$avd_name" "$serial" "$result" >"$out/cleanup.txt"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [[ "${TESSERA_AGENT_COMPOSE_TESTS:-0}" == 1 ]]; then
    TESSERA_AGENT_TRANSCRIPT_FIXTURE_OUTPUT="$out/core-transcript.json" \
        swift test --package-path "$repo_root/Packages/TesseraCore" \
        --filter AgentCodexTranscriptContentTests/testSharedSnapshotForBothNativeRenderers \
        >"$out/core-fixture.log" 2>&1
fi
(
    cd "$repo_root/android"
    JAVA_HOME="$java_root" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew :feature-agent-center:assembleDebugAndroidTest
) >"$out/build.log" 2>&1
JAVA_HOME="$java_root" "$avdmanager" create avd --name "$avd_name" \
    --package 'system-images;android-36;default;arm64-v8a' --device "$profile" <<<"no" >"$out/avd.log" 2>&1
for port in $(seq 5882 2 5980); do
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && ! lsof -nP -iTCP:"$((port+1))" -sTCP:LISTEN >/dev/null 2>&1; then
        serial="emulator-$port"
        "$sdk_root/emulator/emulator" -avd "$avd_name" -port "$port" -no-window -no-audio -no-boot-anim -no-snapshot \
            >"$run_root/emulator.log" 2>&1 &
        emulator_pid=$!
        break
    fi
done
[[ -n "$serial" ]] || exit 1
printf '%s\n%s\n' "$avd_name" "$serial" >"$out/owned-device.txt"
booted=0
for _ in {1..180}; do
    kill -0 "$emulator_pid" 2>/dev/null || exit 1
    if [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then booted=1; break; fi
    sleep 1
done
[[ "$booted" == 1 && "$("$adb" -s "$serial" emu avd name | tr -d '\r' | head -1)" == "$avd_name" ]] || exit 1
# Tablet acceptance is landscape. This is a fresh, run-owned emulator only.
if [[ "$profile" == pixel_tablet ]]; then
    "$adb" -s "$serial" shell settings put system accelerometer_rotation 0
    "$adb" -s "$serial" shell settings put system user_rotation 1
fi
"$adb" -s "$serial" install -r "$repo_root/android/feature-agent-center/build/outputs/apk/androidTest/debug/feature-agent-center-debug-androidTest.apk" >"$out/install.log"
if [[ "${TESSERA_AGENT_COMPOSE_TESTS:-0}" == 1 ]]; then
    "$adb" -s "$serial" push "$out/core-transcript.json" /data/local/tmp/tessera-agent-transcript-fixture.json >"$out/fixture-push.log"
    "$adb" -s "$serial" shell chmod 0644 /data/local/tmp/tessera-agent-transcript-fixture.json
fi
if [[ -n "${TESSERA_ANDROID_AGENT_PAINT_MANIFEST:-}" ]]; then
    paint_options=()
    if [[ "${TESSERA_NATIVE_PAINT_SSH:-0}" == 1 ]]; then paint_options+=(--ssh); fi
    if [[ "${TESSERA_NATIVE_PAINT_LAUNCH:-0}" == 1 ]]; then paint_options+=(--launch-inclusive); fi
    python3 "$repo_root/scripts/performance/agent-center/android_native_paint.py" ${paint_options[@]+"${paint_options[@]}"} \
        --binary "$repo_root/SharedAssets/agent-host/tessera-agent-host-darwin-arm64" \
        --apk "$repo_root/android/feature-agent-center/build/outputs/apk/androidTest/debug/feature-agent-center-debug-androidTest.apk" \
        --manifest "$TESSERA_ANDROID_AGENT_PAINT_MANIFEST" \
        --output "${TESSERA_ANDROID_AGENT_PAINT_OUTPUT:?fresh private paint output required}" \
        --owned-device-file "$out/owned-device.txt" --adb "$adb" \
        --device-profile "$profile" \
        --trials "${TESSERA_NATIVE_PAINT_TRIALS:-20}" --rtt-ms "${TESSERA_NATIVE_PAINT_RTT_MS:-50}" \
        --discovery-order "${TESSERA_NATIVE_PAINT_DISCOVERY_ORDER:-inventory-first}"
    script_completed=1
    exit 0
fi
"$adb" -s "$serial" shell 'screenrecord --time-limit 180 /data/local/tmp/tessera-agent-window.mp4 & echo $! > /data/local/tmp/tessera-agent-window-record.pid; wait' >"$out/video.log" 2>&1 &
recorder_pid=$!
test_classes=com.bambouville.tessera.feature.agentcenter.AgentIngestionWindowInstrumentedTest,com.bambouville.tessera.feature.agentcenter.AgentContextPoolInstrumentedTest,com.bambouville.tessera.feature.agentcenter.AgentDetectedConversationInstrumentedTest,com.bambouville.tessera.feature.agentcenter.AgentIntegrationRecoveryInstrumentedTest
scenes='deep-history history-with-live-head history-with-resegmentation forward-history latest chat-initial-bottom chat-same-record-growth chat-detached-before chat-detached-growth chat-returned-to-latest chat-coalesced-tools short-transcript-filled'
# Window 8 + context pool 8 + detected 3 + integration recovery 4.
expected_tests=23
if [[ "${TESSERA_AGENT_DETECTED_TEST:-0}" == 1 ]]; then
    test_classes=com.bambouville.tessera.feature.agentcenter.AgentDetectedConversationInstrumentedTest
    scenes=''
    expected_tests=3
fi
if [[ "${TESSERA_AGENT_CHAT_FOLLOW_TEST:-0}" == 1 ]]; then
    window_test=com.bambouville.tessera.feature.agentcenter.AgentIngestionWindowInstrumentedTest
    test_classes="$window_test#chatFollowsSameRecordGrowth,$window_test#followedAppendLandsInTheFrameThatDrawsIt,$window_test#followedTranscriptKeepsItsEndInTheFrameThatResizesIt,$window_test#shortTranscriptSitsAtTheEndAndFillsFromHistory,$window_test#followerKeepsTheNewestRowsWhenARevisionSplitsItsRolledHead"
    scenes='chat-initial-bottom chat-same-record-growth chat-detached-before chat-detached-growth chat-returned-to-latest chat-coalesced-tools short-transcript-filled'
    expected_tests=5
fi
if [[ "${TESSERA_AGENT_COMPOSE_TESTS:-0}" == 1 ]]; then
    test_classes=com.bambouville.tessera.feature.agentcenter.AgentCenterComposeTest,com.bambouville.tessera.feature.agentcenter.AgentTranscriptSiblingUpdateInstrumentedTest
    scenes='read-preparing read-verifying read-failed'
    expected_tests=36
fi
"$adb" -s "$serial" shell am instrument -w -r \
    -e class "$test_classes" \
    com.bambouville.tessera.feature.agentcenter.test/androidx.test.runner.AndroidJUnitRunner >"$out/instrumentation.log" 2>&1
for scene in $scenes; do
    "$adb" -s "$serial" exec-out run-as com.bambouville.tessera.feature.agentcenter.test \
        cat "files/agent-window-$scene.png" >"$out/$scene.png"
    "$adb" -s "$serial" exec-out run-as com.bambouville.tessera.feature.agentcenter.test \
        cat "files/agent-window-immediate-$scene.png" >"$out/immediate-$scene.png"
done
if [[ "${TESSERA_AGENT_COMPOSE_TESTS:-0}" == 1 ]]; then
    "$adb" -s "$serial" pull /sdcard/Download "$out/compose-captures" >"$out/capture-pull.log" 2>&1
fi
"$adb" -s "$serial" logcat -d -s TesseraAgentWindow:I '*:S' >"$out/device.log"
rg -q "OK \\($expected_tests tests?\\)" "$out/instrumentation.log"
if [[ "${TESSERA_AGENT_CHAT_FOLLOW_TEST:-0}" != 1 && "${TESSERA_AGENT_COMPOSE_TESTS:-0}" != 1 ]]; then
    if [[ "${TESSERA_AGENT_DETECTED_TEST:-0}" != 1 ]]; then rg -q 'TESSERA_AGENT_WINDOW_OK' "$out/device.log"; fi
    [[ "$(rg -c 'TESSERA_AGENT_DETECTED_OK' "$out/device.log")" == 8 ]]
    for provider in codex claude; do
        for transport in SSH SSH_TMUX MOSH MOSH_TMUX; do
            "$adb" -s "$serial" exec-out run-as com.bambouville.tessera.feature.agentcenter.test \
                cat "files/agent-detected-$provider-$transport.png" >"$out/detected-$provider-$transport.png"
        done
    done
fi
printf 'Android native ingestion window gate passed; evidence: %s\n' "$out"
script_completed=1
