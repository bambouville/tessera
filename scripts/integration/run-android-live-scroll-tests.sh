#!/usr/bin/env bash
# Live terminal gesture gate; every AVD is run-owned and deleted.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { printf "%s\n" "$*" >&2; exit 1; }
device_profile="${2:-pixel_tablet}"
source "$repo_root/scripts/integration/lib.sh"
load_fixture_config
ensure_fixture_credentials
case "${TESSERA_SCROLL_FIXTURE:-stable}" in
    stable) scroll_fixture_host="$TESSERA_FIXTURE_STABLE_HOST" ;;
    chaos) scroll_fixture_host="$TESSERA_FIXTURE_CHAOS_HOST" ;;
    *) die 'TESSERA_SCROLL_FIXTURE must be stable or chaos' ;;
esac
[[ "${TESSERA_SCROLL_TCP_DELAY_MS:-0}" =~ ^[0-9]+$ ]] || die 'TESSERA_SCROLL_TCP_DELAY_MS must be a nonnegative integer'
# The lane owns one live-fixture AVD, so its focused cases are selected by
# method rather than by starting a second emulator. Every method in this class
# is a single JUnit case, which keeps the `OK (1 test)` gate below honest.
test_method="${TESSERA_LIVE_SCROLL_TEST_METHOD:-liveScrollingAcrossAllTransports}"
[[ "$test_method" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] \
    || die 'TESSERA_LIVE_SCROLL_TEST_METHOD must be a bare JUnit method name'
test_class=com.bambouville.tessera.feature.session.TmuxRenderLedgerIsolationInstrumentedTest
height_case=0
resize_keyboard="${TESSERA_HEIGHT_RESIZE_KEYBOARD:-false}"
height_only_peers="${TESSERA_CONTINUATION_HEIGHT_ONLY_PEERS:-false}"
[[ "$height_only_peers" == true || "$height_only_peers" == false ]] \
    || die 'TESSERA_CONTINUATION_HEIGHT_ONLY_PEERS must be true or false'
if [[ "$test_method" == liveProductionScreenRepairsVerticalWindowDrift ]]; then
    test_class=com.bambouville.tessera.feature.session.MoshTmuxHeightProductionUiInstrumentedTest
    height_case=1
    [[ "$resize_keyboard" == true || "$resize_keyboard" == false ]] \
        || die 'TESSERA_HEIGHT_RESIZE_KEYBOARD must be true or false'
fi
codex_fixture_root="${TESSERA_SCROLL_CODEX_FIXTURE_ROOT:-}"
if [[ "$test_method" == liveCodexMouseSurvivesLifecycleOnBothTransports ]]; then
    [[ "$codex_fixture_root" =~ ^/tmp/tessera-codex-[A-Za-z0-9_-]+$ ]] \
        || die 'supply a run-owned offline Codex fixture with TESSERA_SCROLL_CODEX_FIXTURE_ROOT'
fi
openssl_root="${TESSERA_ANDROID_MOSH_OPENSSL_ROOT:?set TESSERA_ANDROID_MOSH_OPENSSL_ROOT}"
run_token="$(fixture_run_token)"
fixture_session="tessera-scroll-$run_token"
if [[ "$height_case" == 1 ]]; then fixture_session="tessera-height-$run_token"; fi
sdk_root="${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
java_root="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
adb="$sdk_root/platform-tools/adb"
emulator="$sdk_root/emulator/emulator"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
out_dir="${1:-$repo_root/.build/android-live-scroll/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
umask 077
run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-live-scroll.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-live-scroll-$(date -u +%Y%m%dT%H%M%SZ)-$$"
serial=''
emulator_pid=''
record_pid=''
proxy_root=''
scroll_fixture_port="$TESSERA_FIXTURE_APP_PORT"

collect_height_evidence() {
    [[ "$height_case" == 1 && -n "$serial" ]] || return 0
    [[ "$("$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1)" == "$avd_name" ]] || return 0
    "$adb" -s "$serial" exec-out run-as com.bambouville.tessera.feature.session.test \
        tar -C files -cf - height-production-ui >"$out_dir/height-captures.tar" 2>/dev/null || return 0
    tar -xf "$out_dir/height-captures.tar" -C "$out_dir"
}

collect_tui_ownership() {
    [[ "$test_method" == liveTuiScrollingAcrossAllTransports && -n "$serial" ]] || return 0
    [[ "$("$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1)" == "$avd_name" ]] || return 0
    mkdir -p "$out_dir/live-scroll"
    local pending="$out_dir/live-scroll/tui-fixture-ownership.json.pending"
    if "$adb" -s "$serial" exec-out run-as com.bambouville.tessera.feature.session.test \
        cat files/live-scroll/tui-fixture-ownership.json >"$pending" 2>/dev/null && [[ -s "$pending" ]]; then
        mv "$pending" "$out_dir/live-scroll/tui-fixture-ownership.json"
    else
        rm -f "$pending"
    fi
}

cleanup_tui_resources() {
    [[ "$test_method" == liveTuiScrollingAcrossAllTransports ]] || return 0
    local ownership="$out_dir/live-scroll/tui-fixture-ownership.json"
    # No remote resource is created before this identity record. A missing
    # record cannot justify guessing another run's target or signalling it.
    [[ -f "$ownership" ]] || { printf '%s\n' 'TUI cleanup identity unavailable; no guessed remote cleanup' >&2; return 1; }
    local rows="$out_dir/tui-cleanup-targets.tsv"
    if ! python3 - "$ownership" "$fixture_session" "$run_token" >"$rows" <<'PYTUI'
import json, re, sys
with open(sys.argv[1]) as source:
    value = json.load(source)
assert value['schemaVersion'] == 1 and value['fixtureSession'] == sys.argv[2]
run_token = sys.argv[3]
token, owner = value['token'], value['ownerMarker']
assert re.fullmatch(r'[0-9a-f]{8}', token)
assert re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', owner)
resources = value['resources']
assert 1 <= len(resources) <= 4
seen = set()
for resource in resources:
    label = resource['transport']
    assert label in ('ssh', 'ssh-tmux', 'mosh', 'mosh-tmux') and label not in seen
    seen.add(label)
    target = 'tessera-tui-' + run_token + '-' + token + '-' + label
    directory = '/tmp/' + target
    assert resource['target'] == target and resource['viewTarget'] == target + '-view'
    assert resource['directory'] == directory and resource['workerFile'] == directory + '/workers'
    print('\t'.join((target, target + '-view', directory, owner, token)))
PYTUI
    then return 1; fi
    local target view directory owner token
    while IFS=$'\t' read -r target view directory owner token; do
        if ! control_ssh "$scroll_fixture_host" bash -s -- "$TESSERA_FIXTURE_USER" "$target" "$view" "$directory" "$owner" "$token" <<'REMOTE_TUI'
set -eu
user="$1"; target="$2"; view="$3"; root="$4"; owner="$5"; token="$6"
if [[ -d "$root" ]]; then
    [[ "$(stat -c %U "$root")" == "$user" && -f "$root/.owner" && "$(cat "$root/.owner")" == "$owner" ]] || exit 1
    if [[ -f "$root/workers" ]]; then
        while read -r pid start; do
            [[ "$pid" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || exit 1
            if [[ -r "/proc/$pid/stat" && "$(awk '{print $22}' "/proc/$pid/stat")" == "$start" && "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]]; then
                [[ "$(stat -c %U "/proc/$pid")" == "$user" && "$(readlink "/proc/$pid/exe")" == */sleep ]] || exit 1
                tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "S6-$token-" || exit 1
                kill -TERM "$pid"
                for _ in {1..40}; do
                    [[ ! -r "/proc/$pid/stat" || "$(awk '{print $22}' "/proc/$pid/stat")" != "$start" || "$(awk '{print $3}' "/proc/$pid/stat")" == Z ]] && break
                    sleep 0.05
                done
                [[ ! -r "/proc/$pid/stat" || "$(awk '{print $22}' "/proc/$pid/stat")" != "$start" || "$(awk '{print $3}' "/proc/$pid/stat")" == Z ]] || exit 1
            fi
            printf 'OWNED_TUI_WORKER_ABSENT pid=%s start=%s\n' "$pid" "$start"
        done <"$root/workers"
    fi
else
    # A test may have removed its directory before failing to close tmux.
    # Require its unique content marker before touching such a leftover.
    for session in "$view" "$target"; do
        if runuser -u "$user" -- tmux has-session -t "=$session" 2>/dev/null; then
            runuser -u "$user" -- tmux capture-pane -p -t "$session" -S - \
                | grep -Eq "(S1|VIM|S6)-$token-" || exit 1
        fi
    done
fi
for session in "$view" "$target"; do
    if runuser -u "$user" -- tmux has-session -t "=$session" 2>/dev/null; then
        runuser -u "$user" -- tmux kill-session -t "=$session"
    fi
    ! runuser -u "$user" -- tmux has-session -t "=$session" 2>/dev/null || exit 1
done
if [[ -d "$root" ]]; then rm -rf -- "$root"; fi
[[ ! -e "$root" ]] || exit 1
printf 'OWNED_TUI_RESOURCES_ABSENT target=%s view=%s directory=%s\n' "$target" "$view" "$root"
REMOTE_TUI
        then return 1; fi
    done <"$rows"
}

cleanup() {
    local result=$?
    fail_closed_status "$result" || result=1
    trap - EXIT
    collect_height_evidence || result=1
    collect_tui_ownership || result=1
    cleanup_tui_resources >"$out_dir/tui-exit-cleanup.txt" 2>&1 || result=1
    local mosh_pid='-' mosh_start='-' height_owner='-'
    if [[ "$height_case" == 1 && -f "$out_dir/height-production-ui/ownership.json" ]]; then
        if ! read -r mosh_pid mosh_start height_owner < <(python3 - "$out_dir/height-production-ui/ownership.json" "$fixture_session" <<'PYOWN'
import json, re, sys
with open(sys.argv[1]) as source:
    value = json.load(source)
target = sys.argv[2]
assert value['target'] == target and value['viewTarget'] == target + '-view'
assert value['directory'] == '/tmp/' + target
owner = value['ownerMarker']
assert re.fullmatch(r'[0-9a-f]{8}', owner)
pid, start = str(value.get('moshPid', '-')), str(value.get('moshStart', '-'))
assert (pid == start == '-') or (pid.isdigit() and start.isdigit())
print(pid, start, owner)
PYOWN
        ); then result=1; fi
    fi
    if ! control_ssh "$scroll_fixture_host" bash -s -- "$TESSERA_FIXTURE_USER" "$fixture_session" "$test_method" "$mosh_pid" "$mosh_start" "$height_owner" <<'REMOTE'
set -eu
targets=("$2" "$2-view")
if [[ "$3" == liveCodexMouseSurvivesLifecycleOnBothTransports ]]; then
    targets+=("$2-ssh" "$2-ssh-view" "$2-mosh" "$2-mosh-view")
fi
for session in "${targets[@]}"; do
    if runuser -u "$1" -- tmux has-session -t "=$session" 2>/dev/null; then
        runuser -u "$1" -- tmux kill-session -t "=$session"
    fi
done
if [[ "$3" == liveProductionScreenRepairsVerticalWindowDrift ]]; then
    root="/tmp/$2"
    case "$root" in /tmp/tessera-height-[A-Za-z0-9_.-]*) ;; *) exit 1;; esac
    if [[ -d "$root" ]]; then
        [[ "$6" =~ ^[0-9a-f]{8}$ && "$(cat "$root/.owner")" == "$6" ]] || exit 1
        if [[ -f "$root/pid" ]]; then
            read -r pid start <"$root/pid"
            [[ "$pid" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || exit 1
            if [[ -r "/proc/$pid/stat" && "$(awk '{print $22}' "/proc/$pid/stat")" == "$start" && "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]]; then
                [[ "$(stat -c %U "/proc/$pid")" == "$1" ]] || exit 1
                tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$root/tui.py" || exit 1
                kill -TERM "$pid"
            fi
        fi
        rm -rf -- "$root"
    fi
    [[ ! -e "$root" ]] || exit 1
    if [[ "$4" != - || "$5" != - ]]; then
        [[ "$4" =~ ^[0-9]+$ && "$5" =~ ^[0-9]+$ ]] || exit 1
        pid="$4"; start="$5"
        if [[ -r "/proc/$pid/stat" && "$(awk '{print $22}' "/proc/$pid/stat")" == "$start" && "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]]; then
            [[ "$(stat -c %U "/proc/$pid")" == "$1" ]] || exit 1
            [[ "$(readlink "/proc/$pid/exe")" == */mosh-server ]] || exit 1
            tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$2-view" || exit 1
            gone() {
                [[ ! -r "/proc/$pid/stat" || "$(awk '{print $22}' "/proc/$pid/stat")" != "$start" || "$(awk '{print $3}' "/proc/$pid/stat")" == Z ]]
            }
            # A case that died while this server was SIGSTOPped left TERM
            # pending on it forever: continue it first, and KILL what TERM
            # does not end within three seconds.
            signal=TERM
            kill -CONT "$pid" 2>/dev/null || true
            gone || kill -TERM "$pid" 2>/dev/null || true
            for _ in {1..30}; do
                gone && break
                sleep 0.1
            done
            if ! gone; then
                signal=KILL
                kill -KILL "$pid" 2>/dev/null || true
                for _ in {1..20}; do
                    gone && break
                    sleep 0.1
                done
            fi
            gone || exit 1
            printf 'OWNED_MOSH_TERMINATED pid=%s start=%s signal=%s\n' "$pid" "$start" "$signal"
        else
            printf 'OWNED_MOSH_ABSENT pid=%s start=%s\n' "$pid" "$start"
        fi
    fi
    printf 'OWNED_HEIGHT_RESOURCES_ABSENT target=%s directory=%s\n' "$2" "$root"
fi
REMOTE
    then result=1; fi
    # Every name this lane's cases use carries run_token. The cases' own
    # finally blocks cannot run when the instrumented process dies mid-case,
    # and a mosh-server it left (stopped, or with no client) never exits.
    local run_names=("$fixture_session" "tessera-inline-hist-$run_token" "tessera-inline-flick-$run_token"
        "tessera-cwd-$run_token" "tessera-tui-$run_token" "tessera-mouse-control-$run_token")
    if ! reap_run_fixture_sessions "$scroll_fixture_host" "$TESSERA_FIXTURE_USER" "${run_names[@]}" \
        >"$out_dir/fixture-reap.txt" 2>&1; then
        printf 'run-owned tmux sessions or mosh-servers survived cleanup; see %s\n' "$out_dir/fixture-reap.txt" >&2
        result=1
    fi
    if [[ -n "$proxy_root" ]]; then
        control_ssh "$scroll_fixture_host" bash -s -- "$proxy_root" <<'REMOTE' || result=1
set -eu
root="$1"
if [[ -f "$root/pid" ]]; then
    pid="$(cat "$root/pid")"
    if [[ -r "/proc/$pid/cmdline" ]] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$root/proxy.py"; then
        kill "$pid"
    fi
fi
rm -rf -- "$root"
REMOTE
    fi
    if [[ -n "$serial" ]]; then
        if [[ "$("$adb" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | head -n 1)" == "$avd_name" ]]; then
            # Every case keeps the crash buffer and a bounded log tail: a
            # native crash in the shared core or the Mosh bridge reaches
            # neither AndroidRuntime nor device.log, and the AVD is deleted
            # below, so "Process crashed." would otherwise leave no trace.
            "$adb" -s "$serial" logcat -b crash -d -v threadtime >"$out_dir/owned-crash-buffer.txt" 2>/dev/null || true
            "$adb" -s "$serial" logcat -b main,system,crash -d -v threadtime -t 5000 >"$out_dir/device-tail.txt" 2>/dev/null || true
            if [[ -n "$record_pid" ]]; then
                "$adb" -s "$serial" shell pkill -INT -x screenrecord >/dev/null 2>&1 || true
                wait "$record_pid" 2>/dev/null || true
                "$adb" -s "$serial" pull /data/local/tmp/live-scroll.mp4 "$out_dir/gestures.mp4" >/dev/null 2>&1 || true
            fi
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
    local disposal='Disposed owned AVD'
    if ! JAVA_HOME="$java_root" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1; then
        # A leftover AVD fails the run, even after its test passed.
        disposal='Could not delete owned AVD'
        printf '%s %s\n' "$disposal" "$avd_name" >&2
        [[ "$result" -ne 0 ]] || result=1
    fi
    [[ -f "$run_root/emulator.log" ]] && cp "$run_root/emulator.log" "$out_dir/emulator.log"
    rm -rf -- "$run_root"
    printf '%s %s (%s); result=%s\n' "$disposal" "$avd_name" "$serial" "$result" >"$out_dir/cleanup.txt"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

test_apk="${TESSERA_SCROLL_TEST_APK:-$repo_root/android/feature-session/build/outputs/apk/androidTest/debug/feature-session-debug-androidTest.apk}"
if [[ -z "${TESSERA_SCROLL_TEST_APK:-}" ]]; then
(
    cd "$repo_root/android"
    JAVA_HOME="$java_root" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew -Ptessera.enableMoshNative=true "-Ptessera.moshOpenSslRoot=$openssl_root" :feature-session:testDebugUnitTest :feature-session:assembleDebugAndroidTest
) >"$out_dir/build.log" 2>&1

fi
[[ -f "$test_apk" ]] || die 'test APK is missing'
shasum -a 256 "$test_apk" >"$out_dir/test-apk.sha256"

if [[ "${TESSERA_SCROLL_TCP_DELAY_MS:-0}" != 0 ]]; then
    proxy_root="/tmp/tessera-scroll-proxy-$run_token"
    control_ssh "$scroll_fixture_host" mkdir -m 700 "$proxy_root"
    control_scp "$repo_root/scripts/integration/tcp-delay-proxy.py" "$scroll_fixture_host" "$proxy_root/proxy.py"
    scroll_fixture_port="$(control_ssh "$scroll_fixture_host" bash -s -- "$proxy_root" "$TESSERA_FIXTURE_APP_PORT" "$TESSERA_SCROLL_TCP_DELAY_MS" <<'REMOTE'
set -eu
nohup python3 "$1/proxy.py" --state-dir "$1" --target-port "$2" --delay-ms "$3" >"$1/log" 2>&1 </dev/null &
for _ in {1..50}; do
    if [[ -s "$1/port" ]]; then cat "$1/port"; exit 0; fi
    sleep 0.1
done
cat "$1/log" >&2
exit 1
REMOTE
)"
    printf 'TCP delay per direction: %sms\n' "$TESSERA_SCROLL_TCP_DELAY_MS" >"$out_dir/network-delay.txt"
fi

password_base64="$(fixture_password | tr -d '\n' | base64 | tr -d '\n')"
printf 'stableHost=%s\nport=%s\nuser=%s\npasswordBase64=%s\ntoken=%s\nrenderLedgerSession=%s\nrenderLedgerToken=%s\n' \
    "$scroll_fixture_host" "$scroll_fixture_port" "$TESSERA_FIXTURE_USER" \
    "$password_base64" "$run_token" "$fixture_session" "$run_token" >"$run_root/fixture.properties"
password_base64=''
if [[ -n "$codex_fixture_root" ]]; then
    printf 'codexFixtureRoot=%s\n' "$codex_fixture_root" >>"$run_root/fixture.properties"
fi

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
"$adb" -s "$serial" shell settings put secure show_ime_with_hard_keyboard 1
if [[ "$device_profile" == *tablet* ]]; then
    "$adb" -s "$serial" shell settings put system accelerometer_rotation 0
    "$adb" -s "$serial" shell settings put system user_rotation 1
fi
"$adb" -s "$serial" push "$run_root/fixture.properties" /data/local/tmp/tessera-native-ssh-fixture.properties >"$out_dir/fixture-push.log"
"$adb" -s "$serial" shell chmod 0644 /data/local/tmp/tessera-native-ssh-fixture.properties
"$adb" -s "$serial" install -r "$test_apk" >"$out_dir/install.log"
wait_for_android_configuration_settled "$adb" "$serial" || die 'owned emulator configuration did not settle'
"$adb" -s "$serial" shell screenrecord --time-limit 180 /data/local/tmp/live-scroll.mp4 >"$out_dir/record.log" 2>&1 &
record_pid=$!
phases=(initial)
if [[ "$test_method" == liveCodexMouseSurvivesLifecycleOnBothTransports ]]; then phases+=(restore); fi
for phase in "${phases[@]}"; do
    "$adb" -s "$serial" shell am instrument -w -r \
        -e scrollTransport "${TESSERA_SCROLL_TRANSPORT:-all}" \
        -e codexPhase "$phase" \
        -e historyPresentationDelayMs "${TESSERA_SCROLL_PRESENTATION_DELAY_MS:-1500}" \
        -e resizeKeyboard "$resize_keyboard" \
        -e heightOnlyPeers "$height_only_peers" \
        -e class "$test_class#$test_method" \
        com.bambouville.tessera.feature.session.test/androidx.test.runner.AndroidJUnitRunner >"$out_dir/instrumentation-$phase.log" 2>&1
    cat "$out_dir/instrumentation-$phase.log" >>"$out_dir/instrumentation.log"
    if ! rg -q 'OK \(1 test\)' "$out_dir/instrumentation-$phase.log"; then break; fi
    if [[ "${#phases[@]}" == 2 && "$phase" == initial ]]; then
        "$adb" -s "$serial" shell am force-stop com.bambouville.tessera.feature.session.test
    fi
done
collect_height_evidence
# These live cases write screenshots and measurements to the evidence directory.
if [[ "$test_method" == liveScrollingAcrossAllTransports \
    || "$test_method" == liveTmuxMousePolicyEnablesFullScreenWheelOnBothTransports \
    || "$test_method" == liveCodexMouseSurvivesLifecycleOnBothTransports \
    || "$test_method" == liveMoshTmuxMouseOffTouchReachesFullScreenPane \
    || "$test_method" == liveMoshTmuxFrozenReaderFlicksToOldestRow \
    || "$test_method" == liveMoshTmuxContinuationAlternatesOwnersWithoutStalling \
    || "$test_method" == liveMoshTmuxShowRepairsOwnedDriftAndForegroundYieldsToPeer \
    || "$test_method" == liveSshTmuxWidthOnlyForegroundWaitsForNativeGrid \
    || "$test_method" == liveTuiScrollingAcrossAllTransports \
    || "$test_method" == liveInlineTmuxFingerFlicksDeepenToOldestRow ]]; then
    "$adb" -s "$serial" exec-out run-as com.bambouville.tessera.feature.session.test tar -C files -cf - live-scroll >"$out_dir/captures.tar"
    tar -xf "$out_dir/captures.tar" -C "$out_dir"
fi
for phase in "${phases[@]}"; do rg -q 'OK \(1 test\)' "$out_dir/instrumentation-$phase.log"; done
if [[ "$height_case" == 1 ]]; then
    ! rg -q 'INSTRUMENTATION_STATUS_CODE: -3' "$out_dir/instrumentation.log" \
        || die 'height acceptance was skipped'
    python3 - "$out_dir/height-production-ui" "$fixture_session" "$resize_keyboard" <<'PYHEIGHT'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
target = sys.argv[2]
resize = sys.argv[3] == 'true'
with (root / 'geometry.json').open() as source:
    geometry = json.load(source)
assert geometry['target'] == target and geometry['viewTarget'] == target + '-view'
assert geometry['ownedDirectory'] == '/tmp/' + target
assert geometry['resizeKeyboard'] is resize
assert re.fullmatch(r'[0-9a-f]{8}', geometry['token'])
required = ['01-before-drift', '02-remote-height-drift', '03-after-normal-reconciliation',
            '04-hidden-height45', '05-visible-recovered', '06-ime-visible', '07-ime-hidden']
records = {}
for phase in geometry['phases']:
    if phase['phase'] in required:
        assert phase['phase'] not in records
        records[phase['phase']] = phase
assert set(records) == set(required)
for label in required:
    phase = records[label]
    if label == '04-hidden-height45':
        continue  # A stopped Activity is measured but cannot supply a shown frame.
    assert phase['preDrawPostMatched'] is True and phase['remotePrePostMatched'] is True
    commits = phase['hardwareFrameCommitUptimeMs']
    assert len(commits) == 2 and 0 < commits[0] <= commits[1]
    assert commits[1] <= phase['afterCommitAnimationUptimeMs'] <= phase['screenshotUptimeMs']
    assert (root / (label + '.png')).read_bytes()[:8] == b'\x89PNG\r\n\x1a\n'
    assert (root / (label + '-rows.txt')).is_file()
    if label == '02-remote-height-drift':
        continue  # The fixed client may already have repaired this committed frame.
    local, remote = phase['local'], phase['remote']
    rows = local['physicalRows']
    assert local['physicalColumns'] == 56
    assert 4 <= rows < 48 if label == '06-ime-visible' and resize else rows == 48
    for prefix in ['requested', 'publishedClient', 'native', 'canvas']:
        assert local[prefix + 'Columns'] == 56 and local[prefix + 'Rows'] == rows
    assert remote['windowColumns'] == remote['paneColumns'] == 56
    assert remote['windowRows'] == remote['paneRows'] == rows
    assert ('BOTTOM-' + geometry['token'] + '-' + f'{rows:02}') in local['visibleText']
assert records['01-before-drift']['remote']['authorityStamp']
assert records['01-before-drift']['remote']['authorityStamp'] == records['03-after-normal-reconciliation']['remote']['authorityStamp']
with (root / 'drift-injection.json').open() as source:
    assert 'DRIFT|56|46|56|46' in json.load(source)['observed'].splitlines()
with (root / 'ownership.json').open() as source:
    ownership = json.load(source)
assert ownership['target'] == target and ownership['ownerMarker'] == geometry['token']
assert str(ownership['moshPid']).isdigit() and str(ownership['moshStart']).isdigit()
with (root / 'cleanup.json').open() as source:
    cleanup = json.load(source)
assert cleanup['verifiedAbsent'] is True and cleanup['target'] == target
assert cleanup['viewTarget'] == target + '-view' and cleanup['directory'] == '/tmp/' + target
stages = [json.loads(line)['stage'] for line in (root / 'cleanup-stages.jsonl').read_text().splitlines()]
assert stages[0] == 'entered' and stages[-1] == 'completed'
assert (root / 'diagnostics.txt').is_file()
print('Height acceptance proved seven phases, six committed frames, current ownership and cleanup; zero skips.')
PYHEIGHT
fi
if [[ "$test_method" == liveCodexMouseSurvivesLifecycleOnBothTransports ]]; then
    initial_pid="$(cat "$out_dir/live-scroll/codex-initial-process.txt")"
    restore_pid="$(cat "$out_dir/live-scroll/codex-restore-process.txt")"
    [[ "$initial_pid" =~ ^[0-9]+$ && "$restore_pid" =~ ^[0-9]+$ && "$initial_pid" != "$restore_pid" ]] \
        || die 'Codex restore must run in a different app process'
fi
printf 'Android live scroll gate passed (%s); evidence: %s\n' "$test_method" "$out_dir"
script_completed=1
