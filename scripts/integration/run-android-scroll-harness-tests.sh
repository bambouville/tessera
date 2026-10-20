#!/usr/bin/env bash
# Host-free continuous-pixel terminal scrolling gate; every AVD is run-owned and deleted.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/integration/lib.sh"
die() { printf "%s\n" "$*" >&2; exit 1; }
device_profile="${2:-pixel_7}"
sdk_root="${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
java_root="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
adb="$sdk_root/platform-tools/adb"
emulator="$sdk_root/emulator/emulator"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
out_dir="${1:-$repo_root/.build/android-scroll/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
test_class="${TESSERA_TERMINAL_TEST_CLASS:-com.termux.view.TerminalPixelScrollInstrumentedTest,com.bambouville.tessera.terminal.TermuxTerminalSurfaceInstrumentedTest}"
expected_tests=43
if [[ -n "${TESSERA_TERMINAL_TEST_CLASS:-}" ]]; then
    [[ "$test_class" =~ ^[A-Za-z0-9_.]+#[A-Za-z0-9_]+$ ]] || die 'TESSERA_TERMINAL_TEST_CLASS must name one class#method'
    expected_tests=1
fi
umask 077
run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-scroll.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-scroll-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
            "$adb" -s "$serial" logcat -d -s TerminalView:I '*:S' >"$out_dir/device.log" 2>/dev/null || true
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
    JAVA_HOME="$java_root" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew :terminal:testDebugUnitTest :terminal:assembleDebugAndroidTest
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
"$adb" -s "$serial" install -r "$repo_root/android/terminal/build/outputs/apk/androidTest/debug/terminal-debug-androidTest.apk" >"$out_dir/install.log"
wait_for_android_configuration_settled "$adb" "$serial" || die 'owned emulator configuration did not settle'
"$adb" -s "$serial" shell am instrument -w -r \
    -e class "$test_class" \
    com.bambouville.tessera.terminal.test/androidx.test.runner.AndroidJUnitRunner >"$out_dir/instrumentation.log" 2>&1
"$adb" -s "$serial" exec-out run-as com.bambouville.tessera.terminal.test cat files/scroll-frames.csv >"$out_dir/scroll-frames.csv" || true
"$adb" -s "$serial" exec-out run-as com.bambouville.tessera.terminal.test tar -C files -cf - mouse-mode-recovery >"$out_dir/mouse-mode-recovery.tar" || true
rg -q "OK \\($expected_tests tests?\\)" "$out_dir/instrumentation.log"
printf 'Android pixel scrolling gate passed; evidence: %s\n' "$out_dir"
script_completed=1
