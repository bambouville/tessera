#!/usr/bin/env bash
# Live Remote Files directory-follow gate; every AVD is run-owned and deleted.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { printf "%s\n" "$*" >&2; exit 1; }
device_profile="${2:-pixel_tablet}"
source "$repo_root/scripts/integration/lib.sh"
load_fixture_config
ensure_fixture_credentials
case "${TESSERA_FILES_FOLLOW_FIXTURE:-stable}" in
    stable) files_fixture_host="$TESSERA_FIXTURE_STABLE_HOST" ;;
    chaos) files_fixture_host="$TESSERA_FIXTURE_CHAOS_HOST" ;;
    *) die 'TESSERA_FILES_FOLLOW_FIXTURE must be stable or chaos' ;;
esac
openssl_root="${TESSERA_ANDROID_MOSH_OPENSSL_ROOT:?set TESSERA_ANDROID_MOSH_OPENSSL_ROOT}"
run_token="$(fixture_run_token)"
fixture_session="tessera-cwd-$run_token"
sdk_root="${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
java_root="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
adb="$sdk_root/platform-tools/adb"
emulator="$sdk_root/emulator/emulator"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
out_dir="${1:-$repo_root/.build/android-files-follow/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
umask 077
run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-files-follow.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-files-follow-$(date -u +%Y%m%dT%H%M%SZ)-$$"
serial=''
emulator_pid=''

cleanup() {
    local result=$?
    fail_closed_status "$result" || result=1
    trap - EXIT
    if ! control_ssh "$files_fixture_host" bash -s -- "$TESSERA_FIXTURE_USER" "$fixture_session" <<'REMOTE'
set -eu
for session in "$2" "$2-view"; do
    if runuser -u "$1" -- tmux has-session -t "=$session" 2>/dev/null; then
        runuser -u "$1" -- tmux kill-session -t "=$session"
    fi
done
REMOTE
    then result=1; fi
    # The case's mosh transports name this session (and its `-view`). A case
    # killed mid-flight leaves their servers running with no client forever,
    # and the next native gate refuses the whole fixture account.
    if ! reap_run_fixture_sessions "$files_fixture_host" "$TESSERA_FIXTURE_USER" "$fixture_session" \
        >"$out_dir/fixture-reap.txt" 2>&1; then
        printf 'run-owned tmux sessions or mosh-servers survived cleanup; see %s\n' "$out_dir/fixture-reap.txt" >&2
        result=1
    fi
    if [[ -n "$serial" ]]; then
        if [[ "$("$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1)" == "$avd_name" ]]; then
            "$adb" -s "$serial" logcat -d -s TesseraNativeSsh:I AndroidRuntime:E '*:S' >"$out_dir/device.log" 2>/dev/null || true
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
    JAVA_HOME="$java_root" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew -Ptessera.enableMoshNative=true "-Ptessera.moshOpenSslRoot=$openssl_root" :feature-session:testDebugUnitTest :files:testDebugUnitTest :feature-session:assembleDebugAndroidTest :app:assembleDebug
) >"$out_dir/build.log" 2>&1

password_base64="$(fixture_password | tr -d '\n' | base64 | tr -d '\n')"
printf 'stableHost=%s\nport=%s\nuser=%s\npasswordBase64=%s\ntoken=%s\nrenderLedgerSession=%s\nrenderLedgerToken=%s\n' \
    "$files_fixture_host" "$TESSERA_FIXTURE_APP_PORT" "$TESSERA_FIXTURE_USER" \
    "$password_base64" "$run_token" "$fixture_session" "$run_token" >"$run_root/fixture.properties"
password_base64=''

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
if [[ "$device_profile" == *tablet* ]]; then
    "$adb" -s "$serial" shell settings put system accelerometer_rotation 0
    "$adb" -s "$serial" shell settings put system user_rotation 1
fi
"$adb" -s "$serial" push "$run_root/fixture.properties" /data/local/tmp/tessera-native-ssh-fixture.properties >"$out_dir/fixture-push.log"
"$adb" -s "$serial" shell chmod 0644 /data/local/tmp/tessera-native-ssh-fixture.properties
"$adb" -s "$serial" install -r "$repo_root/android/feature-session/build/outputs/apk/androidTest/debug/feature-session-debug-androidTest.apk" >"$out_dir/install.log"
"$adb" -s "$serial" shell am instrument -w -r \
    -e class com.bambouville.tessera.feature.session.TmuxRenderLedgerIsolationInstrumentedTest#liveFilesFollowDirectoryAcrossAllTransports \
    com.bambouville.tessera.feature.session.test/androidx.test.runner.AndroidJUnitRunner >"$out_dir/instrumentation.log" 2>&1
rg -q 'OK \(1 test\)' "$out_dir/instrumentation.log"
printf 'Android Files follow gate passed; evidence: %s\n' "$out_dir"
script_completed=1
