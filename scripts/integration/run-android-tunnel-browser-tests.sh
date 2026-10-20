#!/usr/bin/env bash
# Host-free gate for opening a forwarded port in the in-app browser on Android.
#
# The instrumented test stands a real loopback HTTP server beside the panel and
# asserts that only a live, browsable tunnel offers a page and that opening it
# actually fetches one — so the run covers the cleartext network-security
# config and the WebView wiring, not a fixture. No SSH session is opened.
#
# The same run checks each listening row's service line ("serving · 0 active",
# "listening · nothing serving on remote port N", "listening · checking…",
# and "listening · 0 active" for a rule that is not probed) against the real
# shared-core web policy, which decides the rules that are probed at all.
#
# Every AVD is run-owned and deleted on exit, including on failure. The
# emulator runs windowed-off but still renders, so the screencap loop records
# what the browser actually drew.
#
# Run it on its own: with a second emulator alive on the same machine, the
# test activity has twice failed to come up at all and the Compose rule
# reported "No compose hierarchies found" — a contention flake, not a defect
# in what is under test.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { printf "%s\n" "$*" >&2; exit 1; }
device_profile="${2:-pixel_7}"
sdk_root="${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
java_root="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
adb="$sdk_root/platform-tools/adb"
emulator="$sdk_root/emulator/emulator"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
out_dir="${1:-$repo_root/build/android-tunnel-browser/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$out_dir/frames"
out_dir="$(cd "$out_dir" && pwd)"
umask 077
run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-tunnel-browser.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-tunnel-browser-$(date -u +%Y%m%dT%H%M%SZ)-$$"
serial=''
emulator_pid=''
shot_pid=''

cleanup() {
    local result=$?
    # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
    # `set -e`; only a run that reached script_completed=1 may exit 0.
    if [[ "$result" -eq 0 && "${script_completed:-0}" != 1 ]]; then
        echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
        result=1
    fi
    trap - EXIT
    [[ -n "$shot_pid" ]] && kill "$shot_pid" 2>/dev/null
    if [[ -n "$serial" ]]; then
        # Only ever touch the device this run created.
        if [[ "$("$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1)" == "$avd_name" ]]; then
            # `-s X '*:S'` silences X as well, which is why this file used to
            # come back empty on a failed run. Dump the whole buffer and the
            # crash buffer; the reader greps.
            "$adb" -s "$serial" logcat -d >"$out_dir/device.log" 2>/dev/null || true
            "$adb" -s "$serial" logcat -d -b crash >"$out_dir/crash.log" 2>/dev/null || true
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
    JAVA_HOME="$java_root" SWIFT_ANDROID_SWIFT="$swift_bin" \
        ./gradlew :port-forwarding:testDebugUnitTest :port-forwarding:assembleDebugAndroidTest
) >"$out_dir/build.log" 2>&1

JAVA_HOME="$java_root" "$avdmanager" create avd --name "$avd_name" \
    --package 'system-images;android-36;default;arm64-v8a' --device "$device_profile" <<<"no" >"$out_dir/avd.log" 2>&1
for port in $(seq 5902 2 5980); do
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
"$adb" -s "$serial" shell input keyevent KEYCODE_WAKEUP
"$adb" -s "$serial" shell wm dismiss-keyguard

# `sys.boot_completed` is not the same as a quiet device: the system is still
# fanning BOOT_COMPLETED out to dozens of processes, and an activity that takes
# longer to resume than the Compose test framework's own grace reads back as
# "No compose hierarchies found in the app" — this gate's failure mode whenever
# the Mac was busy. Wait for the broadcast queue to drain, bounded so a wedged
# wait cannot hang the run (macOS has no `timeout`).
"$adb" -s "$serial" shell am wait-for-broadcast-idle >"$out_dir/broadcast-idle.log" 2>&1 &
idle_pid=$!
for _ in {1..90}; do
    kill -0 "$idle_pid" 2>/dev/null || break
    sleep 1
done
kill "$idle_pid" 2>/dev/null || true
wait "$idle_pid" 2>/dev/null || true

"$adb" -s "$serial" install -r \
    "$repo_root/android/port-forwarding/build/outputs/apk/androidTest/debug/port-forwarding-debug-androidTest.apk" \
    >"$out_dir/install.log"

# Visual evidence: the test holds the browser open long enough for several of
# these to land on the page. Screencap only — `uiautomator dump` takes the
# UiAutomation connection the Compose rule needs and fails the run with "No
# compose hierarchies found"; the geometry that would have come from a dump is
# asserted inside the test instead.
(
    i=0
    while [[ $i -lt 90 ]]; do
        printf -v n '%03d' "$i"
        "$adb" -s "$serial" exec-out screencap -p >"$out_dir/frames/$n.png" 2>/dev/null
        i=$((i + 1))
        sleep 1
    done
) &
shot_pid=$!

"$adb" -s "$serial" logcat -c >/dev/null 2>&1 || true
set +e
"$adb" -s "$serial" shell am instrument -w -r \
    -e class com.bambouville.tessera.forwarding.TunnelWebBrowserInstrumentedTest,com.bambouville.tessera.forwarding.PortForwardingServiceStatusInstrumentedTest \
    com.bambouville.tessera.forwarding.test/androidx.test.runner.AndroidJUnitRunner \
    >"$out_dir/instrumentation.log" 2>&1
status=$?
set -e

kill "$shot_pid" 2>/dev/null
shot_pid=''
# Drop the empty frames a screencap can produce while the screen is off.
find "$out_dir/frames" -name '*.png' -size -1k -delete 2>/dev/null || true

grep -E "INSTRUMENTATION_STATUS: stream|OK \(|FAILURES" "$out_dir/instrumentation.log" | tail -20
grep -q 'OK (3 tests)' "$out_dir/instrumentation.log" \
    || die "Android tunnel-browser gate failed; evidence: $out_dir"
[[ "$status" -eq 0 ]] || die "instrumentation exited $status; evidence: $out_dir"
printf 'Android tunnel-browser gate passed; evidence: %s\n' "$out_dir"
script_completed=1
