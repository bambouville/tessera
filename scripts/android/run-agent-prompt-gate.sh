#!/usr/bin/env bash
# Host-free Agent Center live prompt card gate on a disposable tablet and phone surface.
# Also runs the instrumented suites the prompt and lifecycle-warning changes touch.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { printf "%s\n" "$*" >&2; exit 1; }
sdk_root="${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
java_root="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
adb="$sdk_root/platform-tools/adb"
emulator="$sdk_root/emulator/emulator"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
out_dir="${1:-$repo_root/.build/agent-prompts/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
umask 077
run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-agent-prompts.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-agent-prompts-$(date -u +%Y%m%dT%H%M%SZ)-$$"
serial=''
emulator_pid=''

cleanup() {
    local result=$?
    # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
    # `set -e`; only a run that reached script_completed=1 may exit 0.
    if [[ "$result" -eq 0 && "${script_completed:-0}" != 1 ]]; then
        echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
        result=1
    fi
    trap - EXIT
    if [[ -n "$serial" ]]; then
        if [[ "$("$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1)" == "$avd_name" ]]; then
            "$adb" -s "$serial" logcat -d -s TesseraHistory:I '*:S' >"$out_dir/device.log" 2>/dev/null || true
            "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
        fi
    fi
    if [[ -n "$emulator_pid" ]]; then
        for _ in {1..20}; do
            kill -0 "$emulator_pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$emulator_pid" 2>/dev/null; then kill "$emulator_pid" 2>/dev/null || true; fi
        wait "$emulator_pid" 2>/dev/null || true
    fi
    JAVA_HOME="$java_root" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || true
    [[ -f "$run_root/emulator.log" ]] && cp "$run_root/emulator.log" "$out_dir/emulator.log"
    rm -rf -- "$run_root"
    printf 'Disposed owned AVD %s (%s); result=%s\n' "$avd_name" "$serial" "$result" >"$out_dir/cleanup.txt"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

(
    cd "$repo_root/android"
    JAVA_HOME="$java_root" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew :feature-agent-center:assembleDebugAndroidTest
) >"$out_dir/build.log" 2>&1

JAVA_HOME="$java_root" "$avdmanager" create avd --name "$avd_name" \
    --package 'system-images;android-36;default;arm64-v8a' --device pixel_tablet <<<"no" >"$out_dir/avd.log" 2>&1
for port in $(seq 5882 2 5980); do
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
        && ! lsof -nP -iTCP:"$((port + 1))" -sTCP:LISTEN >/dev/null 2>&1; then
        serial="emulator-$port"
        "$emulator" -avd "$avd_name" -port "$port" -no-window -no-audio -no-boot-anim -no-snapshot \
            >"$run_root/emulator.log" 2>&1 &
        emulator_pid=$!
        break
    fi
done
[[ -n "$serial" ]] || die 'no free emulator port'
printf '%s\n%s\n' "$avd_name" "$serial" >"$out_dir/owned-device.txt"
booted=0
for _ in {1..180}; do
    kill -0 "$emulator_pid" 2>/dev/null || die 'owned emulator exited during boot'
    if [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
        booted=1
        break
    fi
    sleep 1
done
[[ "$booted" == 1 ]] || die 'owned emulator did not boot'
[[ "$("$adb" -s "$serial" emu avd name | tr -d '\r' | head -n 1)" == "$avd_name" ]] \
    || die 'emulator serial does not belong to this run'
"$adb" -s "$serial" install -r "$repo_root/android/feature-agent-center/build/outputs/apk/androidTest/debug/feature-agent-center-debug-androidTest.apk" >"$out_dir/install.log"
pkg=com.bambouville.tessera.feature.agentcenter
runner=$pkg.test/androidx.test.runner.AndroidJUnitRunner
"$adb" -s "$serial" shell am instrument -w -r \
    -e class "$pkg.AgentPromptCardComposeTest,$pkg.AgentIntegrationRecoveryInstrumentedTest,$pkg.AgentCenterComposeTest,$pkg.AgentTranscriptSiblingUpdateInstrumentedTest" \
    "$runner" >"$out_dir/instrumentation.log" 2>&1
"$adb" -s "$serial" logcat -d -s TesseraHistory:I '*:S' >"$out_dir/device.log"
grep -Eq 'OK \([0-9]+ tests\)' "$out_dir/instrumentation.log"
mkdir -p "$out_dir/tablet" "$out_dir/phone"
"$adb" -s "$serial" pull /sdcard/Download/. "$out_dir/tablet" >"$out_dir/tablet-captures.log" 2>&1
"$adb" -s "$serial" shell rm -f '/sdcard/Download/agent-*.png'
# The same cards at compact phone size on this owned AVD.
"$adb" -s "$serial" shell wm size 1080x2400
"$adb" -s "$serial" shell wm density 420
"$adb" -s "$serial" shell am instrument -w -r -e class "$pkg.AgentPromptCardComposeTest" \
    "$runner" >"$out_dir/phone-instrumentation.log" 2>&1
grep -Eq 'OK \(3 tests\)' "$out_dir/phone-instrumentation.log"
"$adb" -s "$serial" pull /sdcard/Download/. "$out_dir/phone" >"$out_dir/phone-captures.log" 2>&1
for surface in tablet phone; do
    count=$(find "$out_dir/$surface" -name 'agent-prompt-*.png' | wc -l | tr -d ' ')
    [[ "$count" == 8 ]] || die "expected 8 $surface prompt captures, got $count"
done

printf 'Host-free Android Agent Center prompt gate passed; evidence: %s\n' "$out_dir"
script_completed=1
