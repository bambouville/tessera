#!/usr/bin/env bash
# Live mosh+tmux grid-authority rig for Android.
#
# Boots a disposable portrait-phone AVD, runs
# MoshTmuxAuthorityLiveInstrumentedTest against the stable VPS fixture with a
# plain `tmux attach` PC peer (160x48, fed through a fifo) and a stale
# `@tessera_authority` stamp on the app-derived private view, then collects:
#   logcat-rig.txt    the rig's own log (tag TesseraAuthorityRig) including the
#                     device diagnostics delta (`diag|` lines) and the
#                     `TESSERA_AUTHORITY_RIG` verdict line
#   logcat-full.txt   everything logcat had
#   tmux-server.log   the fixture's `tmux -vv` server log for the run
#   gradle.log        the connectedDebugAndroidTest output
#
# A good run follows the §6.9 show rule: A_attach_claims=0 (attach never
# claims) A_show=settled-in-<ms> B_takeback=not-needed
# C_after_peer_key_authority=peer(...) D_takeback=settled-on-attempt-1-in-<ms>
# D_layout=@<window>:<phone-grid> D_server includes window=<phone-grid>;
# the idle PC still holds its old latest when D starts.
# E_after_peer_left_claims=0 (a departure moves nothing) E_takeback=settled-on-attempt-1-in-<ms>
# or not-needed, F_switch=painted-in-<ms>(...) F_switch_back=painted-in-<ms>(...),
# with both switch legs well under a second (the mosh painter used to wait on
# a 4 s quiet watchdog).
#
# Usage: scripts/android/run-mosh-authority-rig.sh [out-dir]
#        (default out-dir: scripts/integration/out/mosh-authority-rig-<stamp>)
# Env:   TESSERA_ANDROID_MOSH_OPENSSL_ROOT (cached arm64 OpenSSL prefix, see
#        prepare-mosh-openssl.sh), ANDROID_SDK_ROOT, JAVA_HOME,
#        SWIFT_ANDROID_SWIFT, TESSERA_FIXTURE_CONFIG (defaults as in
#        run-native-ssh-gate.sh). The AVD and every fixture artifact are
#        deleted on exit, including on failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
[[ -n "$sdk_root" ]] || { echo "mosh authority rig: set ANDROID_SDK_ROOT" >&2; exit 1; }

java_home="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
openssl_root="${TESSERA_ANDROID_MOSH_OPENSSL_ROOT:-$repo_root/.build/android-deps/openssl-3.5.7-arm64-api28}"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
emulator="$sdk_root/emulator/emulator"
adb="$sdk_root/platform-tools/adb"
system_image="system-images;android-36;default;arm64-v8a"
fixture_config="${TESSERA_FIXTURE_CONFIG:-$repo_root/scripts/integration/fixture.env}"
if [[ ! -f "$fixture_config" ]]; then
  git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -n "$git_common_dir" && -f "$git_common_dir/../scripts/integration/fixture.env" ]]; then
    fixture_config="$(cd "$git_common_dir/../scripts/integration" && pwd)/fixture.env"
  fi
fi

[[ -x "$java_home/bin/java" ]] || { echo "missing JDK at $java_home" >&2; exit 1; }
[[ -x "$swift_bin" ]] || { echo "missing Swift toolchain at $swift_bin" >&2; exit 1; }
[[ -f "$fixture_config" ]] || { echo "missing fixture config: $fixture_config" >&2; exit 1; }
[[ -f "$openssl_root/include/openssl/evp.h" && -f "$openssl_root/lib/libcrypto.a" ]] || {
  echo "mosh authority rig needs the cached arm64 OpenSSL prefix at $openssl_root (prepare-mosh-openssl.sh)" >&2
  exit 1
}
for command in "$avdmanager" "$emulator" "$adb"; do
  [[ -x "$command" ]] || { echo "missing Android tool: $command" >&2; exit 1; }
done
[[ -d "$sdk_root/system-images/android-36/default/arm64-v8a" ]] || {
  echo "missing installed system image: $system_image" >&2
  exit 1
}

export TESSERA_FIXTURE_CONFIG="$fixture_config"
export TESSERA_INTEGRATION_FIXTURE_STATE_DIR="${TESSERA_INTEGRATION_FIXTURE_STATE_DIR:-$(dirname "$fixture_config")/.state}"
# shellcheck source=../integration/lib.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/integration/lib.sh"
load_fixture_config
ensure_fixture_credentials

host="$TESSERA_FIXTURE_STABLE_HOST"
token="$(fixture_run_token)"
session="tessera-authrig-$token"
device_fixture_path=/data/local/tmp/tessera-authority-rig-fixture.properties
out_dir="${1:-$FIXTURE_OUT/mosh-authority-rig-$token}"
mkdir -p "$out_dir"

run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-authority-rig.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-authrig-$token"
emulator_pid=''
serial=''

cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  echo "== cleanup (status $status)"
  # The test tears its own session down; repeat it here so an aborted run
  # leaves nothing attached on the fixture, then pull the server log. Killing
  # the session detaches its plain client, which ends that client's `script`.
  fixture_ssh "$host" \
    "tmux kill-session -t '=$session' 2>/dev/null; tmux kill-session -t '=$session-ssh' 2>/dev/null; rm -f /tmp/$session.fifo /tmp/$session.script.log; ls -t ~/tmux-server-*.log 2>/dev/null | head -1" \
    >"$run_root/server-log-name.txt" 2>/dev/null || true
  # Then exactly the processes naming this run: the FIFO keeper (started as
  # `<session>-fifo-keeper`) and the `script` client, never every `sleep
  # 3600` or `tmux attach` on the shared account (S13's split panes run one),
  # and its `-view` and mosh-servers, which an aborted test leaves running
  # forever, after which the native gate refuses the fixture account.
  if ! end_run_processes "$host" "$TESSERA_FIXTURE_USER" @any "$session" >"$out_dir/fixture-reap.txt" 2>&1; then
    echo "run-owned processes survived cleanup; see $out_dir/fixture-reap.txt" >&2
    status=1
  fi
  if ! reap_run_fixture_sessions "$host" "$TESSERA_FIXTURE_USER" "$session" >>"$out_dir/fixture-reap.txt" 2>&1; then
    echo "run-owned tmux sessions or mosh-servers survived cleanup; see $out_dir/fixture-reap.txt" >&2
    status=1
  fi
  local server_log
  server_log="$(tr -d '\r\n' <"$run_root/server-log-name.txt" 2>/dev/null || true)"
  if [[ -n "$server_log" ]]; then
    fixture_ssh "$host" "cat '$server_log'" >"$out_dir/tmux-server.log" 2>/dev/null || true
    fixture_ssh "$host" "rm -f ~/tmux-server-*.log" >/dev/null 2>&1 || true
  fi
  if [[ -n "$serial" ]]; then
    "$adb" -s "$serial" logcat -d >"$out_dir/logcat-full.txt" 2>/dev/null || true
    "$adb" -s "$serial" logcat -d -s TesseraAuthorityRig:I TestRunner:I AndroidRuntime:E '*:S' >"$out_dir/logcat-rig.txt" 2>/dev/null || true
    "$adb" -s "$serial" shell rm -f "$device_fixture_path" >/dev/null 2>&1 || true
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  fi
  [[ -n "$emulator_pid" ]] && wait "$emulator_pid" >/dev/null 2>&1 || true
  JAVA_HOME="$java_home" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || true
  rm -rf -- "$run_root"
  echo "== outputs in $out_dir"
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

umask 077
printf 'stableHost=%s\nport=%s\nuser=%s\npasswordBase64=%s\nauthoritySession=%s\n' \
  "$host" "$TESSERA_FIXTURE_APP_PORT" "$TESSERA_FIXTURE_USER" \
  "$(fixture_password | base64 | tr -d '\n')" "$session" >"$run_root/fixture.properties"

echo "== creating AVD $avd_name"
JAVA_HOME="$java_home" "$avdmanager" create avd --force --name "$avd_name" --package "$system_image" --device pixel_7 <<<"no" >/dev/null
cfg="$ANDROID_AVD_HOME/$avd_name.avd/config.ini"
# A portrait phone, like the reports.
sed -i '' '/^hw.lcd.width=/d;/^hw.lcd.height=/d;/^hw.lcd.density=/d' "$cfg"
printf 'hw.lcd.width=1080\nhw.lcd.height=2400\nhw.lcd.density=420\nhw.ramSize=3072\n' >>"$cfg"

for p in $(seq 5900 2 5980); do
  if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && ! lsof -nP -iTCP:"$((p+1))" -sTCP:LISTEN >/dev/null 2>&1 \
     && ! "$adb" devices | awk 'NR>1{print $1}' | grep -qx "emulator-$p"; then
    serial="emulator-$p"
    "$emulator" -avd "$avd_name" -port "$p" -no-window -no-audio -no-boot-anim -no-snapshot -wipe-data >"$run_root/emulator.log" 2>&1 &
    emulator_pid=$!
    break
  fi
done
[[ -n "$serial" ]] || { echo "no free emulator port" >&2; exit 1; }
echo "== booting $serial"
for _ in {1..240}; do
  kill -0 "$emulator_pid" 2>/dev/null || { echo "emulator died" >&2; tail -50 "$run_root/emulator.log" >&2; exit 1; }
  [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
  sleep 1
done
[[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] || { echo "boot timeout" >&2; exit 1; }
"$adb" -s "$serial" push "$run_root/fixture.properties" "$device_fixture_path" >/dev/null
"$adb" -s "$serial" shell chmod 0644 "$device_fixture_path"
"$adb" -s "$serial" logcat -c || true

echo "== running instrumented rig (session $session)"
gradle_status=0
(
  cd "$repo_root/android"
  ANDROID_SERIAL="$serial" ANDROID_SDK_ROOT="$sdk_root" JAVA_HOME="$java_home" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew --no-daemon --max-workers=1 \
    -Ptessera.enableMoshNative=true -Ptessera.moshOpenSslRoot="$openssl_root" \
    :feature-session:connectedDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.class=com.bambouville.tessera.feature.session.MoshTmuxAuthorityLiveInstrumentedTest
) >"$out_dir/gradle.log" 2>&1 || gradle_status=$?
[[ "$gradle_status" == 0 ]] || echo "== gradle exit $gradle_status (see $out_dir/gradle.log)"
"$adb" -s "$serial" logcat -d -s TesseraAuthorityRig:I '*:S' | grep -v "diag|" | tail -80
"$adb" -s "$serial" logcat -d -s TesseraAuthorityRig:I '*:S' | grep -q "TESSERA_AUTHORITY_RIG" || {
  echo "mosh authority rig: no verdict line; see $out_dir/gradle.log" >&2
  exit 1
}
script_completed=1
exit "$gradle_status"
