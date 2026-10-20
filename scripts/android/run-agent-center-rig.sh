#!/usr/bin/env bash
# Live Agent Center rig for Android, aimed at a host that is really running agents.
#
# Boots a disposable AVD, runs AgentCenterLiveInstrumentedTest against a host
# with live `@tessera_agent_state` panes, and grades the rows the presenter
# actually produces. A good run reads:
#
#   TESSERA_AGENT_CENTER_RIG connected=yes threads=N candidates=M titled=K ...
#
# with K > 0 — a thread that carries a projected title and status, not
# "untitled / unavailable".
#
# The default target is this Mac over the emulator's host route (10.0.2.2), so
# the tmux session under test is the one the developer is sitting in. The test
# generates its own Android Keystore P256 key and logs the authorized_keys line;
# this script installs that line for the run and removes exactly that line on
# exit. No other credential is used and no host config is left behind.
#
# Usage: scripts/android/run-agent-center-rig.sh [out-dir]
# Env:   ANDROID_SDK_ROOT, JAVA_HOME, SWIFT_ANDROID_SWIFT
#        TESSERA_AGENT_RIG_HOST     (default 10.0.2.2 — the Mac, from the emulator)
#        TESSERA_AGENT_RIG_PORT     (default 22)
#        TESSERA_AGENT_RIG_USER     (default $USER)
#        TESSERA_AGENT_RIG_SESSION  (default: the only live tmux session here)
#        TESSERA_AGENT_RIG_AUTHORIZED_KEYS (default ~/.ssh/authorized_keys)
#        TESSERA_AGENT_RIG_EXPECT_CANDIDATES (comma-separated provider ids that
#            must appear as Tier-A candidate rows, e.g. "opencode,pi"; grading
#            switches from titled threads to those rows when set)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
[[ -n "$sdk_root" ]] || { echo "agent center rig: set ANDROID_SDK_ROOT" >&2; exit 1; }

java_home="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
emulator="$sdk_root/emulator/emulator"
adb="$sdk_root/platform-tools/adb"
system_image="system-images;android-36;default;arm64-v8a"

rig_host="${TESSERA_AGENT_RIG_HOST:-10.0.2.2}"
rig_port="${TESSERA_AGENT_RIG_PORT:-22}"
rig_user="${TESSERA_AGENT_RIG_USER:-$USER}"
rig_session="${TESSERA_AGENT_RIG_SESSION:-$(tmux ls -F '#{session_name}' 2>/dev/null | head -n 1)}"
authorized_keys="${TESSERA_AGENT_RIG_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
# Providers that reach the list only as Tier-A candidates (opencode, pi) never
# emit a lifecycle frame, so grading them means asking for them by name. When
# set, the run is graded on those candidate rows instead of on titled threads.
expect_candidates="${TESSERA_AGENT_RIG_EXPECT_CANDIDATES:-}"
expect_threads="${TESSERA_AGENT_RIG_EXPECT_THREADS:-claude,codex}"
# Sending is opt-in and independently fenced by a run-owned pane marker.
owned_pane="${TESSERA_AGENT_RIG_OWNED_PANE:-}"
owned_marker="${TESSERA_AGENT_RIG_OWNED_MARKER:-}"
other_window="${TESSERA_AGENT_RIG_OTHER_WINDOW:-}"
if [[ -n "$owned_pane" ]]; then
  [[ "$owned_pane" =~ ^%[0-9]+$ && -n "$owned_marker" ]] || exit 2
  [[ "$(tmux show-options -p -v -t "$owned_pane" @tessera_verify_owner)" == "$owned_marker" ]] || {
    echo "refusing send verification: pane is not owned by this rig" >&2; exit 2;
  }
fi
if [[ -n "$other_window" ]]; then
  [[ "$other_window" =~ ^@[0-9]+$ && -n "$owned_marker" ]] || exit 2
  while IFS= read -r owner; do
    [[ "$owner" == "$owned_marker" ]] || { echo "alternate window is not rig-owned" >&2; exit 2; }
  done < <(tmux list-panes -t "$other_window" -F '#{@tessera_verify_owner}')
  [[ "$(tmux display-message -p -t "$other_window" '#{session_name}')" == "$rig_session" ]] || exit 2
fi

[[ -x "$java_home/bin/java" ]] || { echo "missing JDK at $java_home" >&2; exit 1; }
[[ -x "$swift_bin" ]] || { echo "missing Swift toolchain at $swift_bin" >&2; exit 1; }
for command in "$avdmanager" "$emulator" "$adb"; do
  [[ -x "$command" ]] || { echo "missing Android tool: $command" >&2; exit 1; }
done
[[ -d "$sdk_root/system-images/android-36/default/arm64-v8a" ]] || {
  echo "missing installed system image: $system_image" >&2; exit 1; }
[[ -n "$rig_session" ]] || {
  echo "no tmux session to attach; set TESSERA_AGENT_RIG_SESSION" >&2; exit 1; }
# The whole point is a host with live agents. Refuse to grade a green run that
# only proves an empty session stays empty.
if [[ -n "$expect_candidates" ]]; then
  # A candidate provider has no lifecycle hook and so never writes
  # `@tessera_agent_state`; its only evidence before the run is a live process
  # inside the target session.
  panes="$(tmux list-panes -t "$rig_session" -F '#{pane_id} #{pane_current_command}' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$panes" -gt 0 ]] || {
    echo "tmux session $rig_session has no panes; the rig would prove nothing" >&2
    exit 1
  }
  echo "== grading candidates ($expect_candidates) in $rig_session:"
  tmux list-panes -t "$rig_session" -F '   %  #{pane_id} #{pane_current_command}' 2>/dev/null
else
  panes="$(tmux list-panes -a -F '#{@tessera_agent_state}' 2>/dev/null | grep -c '"provider"' || true)"
  [[ "$panes" -gt 0 ]] || {
    echo "no pane on this host carries @tessera_agent_state; the rig would prove nothing" >&2
    exit 1
  }
fi
echo "== $panes agent pane(s) in reach; attaching to $rig_session as $rig_user@$rig_host:$rig_port"

token="$(date -u +%Y%m%dT%H%M%SZ)-$$"
device_fixture_path=/data/local/tmp/tessera-agent-center-rig-fixture.properties
device_go_path=/data/local/tmp/tessera-agent-center-rig-go
out_dir="${1:-$repo_root/.build/agent-center-rig/$token}"
mkdir -p "$out_dir"

run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-agent-center-rig.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-agentcenter-$token"
key_marker="tessera-agent-center-rig-$token"
emulator_pid=''
serial=''
logcat_pid=''

cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  echo "== cleanup (status $status)"
  [[ -n "$logcat_pid" ]] && kill "$logcat_pid" 2>/dev/null || true
  # Remove exactly the lines this run added. The marker carries the run token,
  # so this can never touch a key the developer authorized themselves, and it is
  # safe to run even when the rig never got as far as installing one.
  if [[ -f "$authorized_keys" ]] && grep -q -F "$key_marker" "$authorized_keys" 2>/dev/null; then
    grep -v -F "$key_marker" "$authorized_keys" >"$run_root/authorized_keys.trimmed" || true
    cat "$run_root/authorized_keys.trimmed" >"$authorized_keys"
    echo "== removed the rig key from $authorized_keys"
  fi
  if [[ -n "$serial" ]]; then
    "$adb" -s "$serial" logcat -d >"$out_dir/logcat-full.txt" 2>/dev/null || true
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
printf 'stableHost=%s\nport=%s\nuser=%s\nrigSession=%s\nexpectCandidateProviders=%s\n' \
  "$rig_host" "$rig_port" "$rig_user" "$rig_session" "$expect_candidates" >"$run_root/fixture.properties"
printf 'expectedThreadProviders=%s\nownedPane=%s\nownedMarker=%s\n' \
  "$expect_threads" "$owned_pane" "$owned_marker" >>"$run_root/fixture.properties"
printf 'verifyWorkingQueue=%s\n' "${TESSERA_AGENT_RIG_WORKING_QUEUE:-false}" >>"$run_root/fixture.properties"
printf 'ownedOtherWindow=%s\n' "$other_window" >>"$run_root/fixture.properties"
printf 'readOnlyThread=%s\n' "${TESSERA_AGENT_RIG_READ_ONLY_THREAD:-}" >>"$run_root/fixture.properties"
printf 'verifyComposerMargins=%s\n' "${TESSERA_AGENT_RIG_COMPOSER_MARGINS:-false}" >>"$run_root/fixture.properties"
printf 'verifyMultiline=%s\n' "${TESSERA_AGENT_RIG_MULTILINE:-false}" >>"$run_root/fixture.properties"

echo "== creating AVD $avd_name"
JAVA_HOME="$java_home" "$avdmanager" create avd --force --name "$avd_name" \
  --package "$system_image" --device pixel_7 <<<"no" >/dev/null
cfg="$ANDROID_AVD_HOME/$avd_name.avd/config.ini"
sed -i '' '/^hw.lcd.width=/d;/^hw.lcd.height=/d;/^hw.lcd.density=/d' "$cfg"
printf 'hw.lcd.width=1080\nhw.lcd.height=2400\nhw.lcd.density=420\nhw.ramSize=3072\n' >>"$cfg"

for p in $(seq 5600 2 5680); do
  if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 \
     && ! lsof -nP -iTCP:"$((p+1))" -sTCP:LISTEN >/dev/null 2>&1 \
     && ! "$adb" devices | awk 'NR>1{print $1}' | grep -qx "emulator-$p"; then
    serial="emulator-$p"
    "$emulator" -avd "$avd_name" -port "$p" -no-window -no-audio -no-boot-anim \
      -no-snapshot -wipe-data >"$run_root/emulator.log" 2>&1 &
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
[[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] || {
  echo "boot timeout" >&2; exit 1; }
"$adb" -s "$serial" push "$run_root/fixture.properties" "$device_fixture_path" >/dev/null
"$adb" -s "$serial" shell chmod 0644 "$device_fixture_path"
"$adb" -s "$serial" shell rm -f "$device_go_path" >/dev/null 2>&1 || true
"$adb" -s "$serial" logcat -c || true

# The test publishes the public half of a keystore key it just generated; the
# private half never leaves the emulator's keystore. Authorize it, then let the
# test proceed.
authorize() {
  local line=''
  for _ in $(seq 1 240); do
    line="$("$adb" -s "$serial" logcat -d -s TesseraAgentCenterRig:I 2>/dev/null \
      | sed -n 's/.*TESSERA_AGENT_RIG_PUBKEY //p' | tail -n 1)"
    [[ -n "$line" ]] && break
    sleep 1
  done
  [[ -n "$line" ]] || { echo "the rig never published a public key" >&2; return 1; }
  mkdir -p "$(dirname "$authorized_keys")"
  touch "$authorized_keys"
  cp "$authorized_keys" "$run_root/authorized_keys.bak"
  printf '%s %s\n' "$line" "$key_marker" >>"$authorized_keys"
  chmod 600 "$authorized_keys"
  echo "== authorized the rig key ($key_marker)"
  "$adb" -s "$serial" shell "touch $device_go_path"
}
authorize &
logcat_pid=$!

echo "== running instrumented rig (session $rig_session)"
gradle_status=0
(
  cd "$repo_root/android"
  JAVA_HOME="$java_home" ANDROID_SERIAL="$serial" SWIFT_ANDROID_SWIFT="$swift_bin" \
    ./gradlew --console=plain :feature-session:connectedDebugAndroidTest \
      -Pandroid.testInstrumentationRunnerArguments.class=com.bambouville.tessera.feature.session.AgentCenterLiveInstrumentedTest
) >"$out_dir/gradle.log" 2>&1 || gradle_status=$?

if [[ "${TESSERA_AGENT_RIG_COMPOSE_TESTS:-false}" == "true" && "$gradle_status" == 0 ]]; then
  if [[ -n "${TESSERA_AGENT_RIG_TRANSCRIPT_FIXTURE:-}" ]]; then
    "$adb" -s "$serial" push "$TESSERA_AGENT_RIG_TRANSCRIPT_FIXTURE" /data/local/tmp/tessera-agent-transcript-fixture.json >/dev/null
    "$adb" -s "$serial" shell chmod 0644 /data/local/tmp/tessera-agent-transcript-fixture.json
  fi
  (
    cd "$repo_root/android"
    JAVA_HOME="$java_home" ANDROID_SERIAL="$serial" SWIFT_ANDROID_SWIFT="$swift_bin" \
      ./gradlew --console=plain :feature-agent-center:connectedDebugAndroidTest \
        -Pandroid.testInstrumentationRunnerArguments.class=com.bambouville.tessera.feature.agentcenter.AgentCenterComposeTest
  ) >"$out_dir/compose.log" 2>&1 || gradle_status=$?
fi

wait "$logcat_pid" 2>/dev/null || true
logcat_pid=''
"$adb" -s "$serial" logcat -d -s TesseraAgentCenterRig:I TestRunner:I AndroidRuntime:E '*:S' \
  >"$out_dir/logcat-rig.txt" 2>/dev/null || true

echo "== verdict"
for image in collapsed expanded pending pending-settled reply failure terminal; do
  "$adb" -s "$serial" pull "/sdcard/Download/agent-center-rig-$image.png" "$out_dir/$image.png" >/dev/null 2>&1 || true
done
for image in pending-layout-0 pending-layout-1 pending-layout-2 pending-layout-3; do
  "$adb" -s "$serial" pull "/sdcard/Download/agent-transcript-$image.png" "$out_dir/$image.png" >/dev/null 2>&1 || true
done
"$adb" -s "$serial" pull /sdcard/Download/agent-center-rig-failure.json "$out_dir/failure.json" >/dev/null 2>&1 || true
grep -E "TESSERA_AGENT_CENTER_RIG|^.*row provider=" "$out_dir/logcat-rig.txt" | sed 's/^.*TesseraAgentCenterRig: //' || true
script_completed=1
exit "$gradle_status"
