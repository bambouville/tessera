#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
[[ -n "$sdk_root" ]] || { echo "Android native SSH gate failed: set ANDROID_SDK_ROOT" >&2; exit 1; }

java_home="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
agent_mosh_runtime="${TESSERA_ANDROID_AGENT_CENTER_MOSH:-0}"
ordering_only="${TESSERA_ANDROID_NATIVE_ORDERING_ONLY:-0}"
program_status_only="${TESSERA_ANDROID_NATIVE_PROGRAM_STATUS_ONLY:-0}"
[[ "$ordering_only" == 0 || "$ordering_only" == 1 ]] || {
  echo "TESSERA_ANDROID_NATIVE_ORDERING_ONLY must be 0 or 1" >&2
  exit 1
}
[[ "$program_status_only" == 0 || "$program_status_only" == 1 ]] || {
  echo "TESSERA_ANDROID_NATIVE_PROGRAM_STATUS_ONLY must be 0 or 1" >&2
  exit 1
}
[[ "$ordering_only" == 0 || "$program_status_only" == 0 ]] || {
  echo "TESSERA_ANDROID_NATIVE_ORDERING_ONLY and TESSERA_ANDROID_NATIVE_PROGRAM_STATUS_ONLY are mutually exclusive" >&2
  exit 1
}
emulator_window="${TESSERA_ANDROID_NATIVE_EMULATOR_WINDOW:-0}"
[[ "$emulator_window" == 0 || "$emulator_window" == 1 ]] || {
  echo "TESSERA_ANDROID_NATIVE_EMULATOR_WINDOW must be 0 or 1" >&2
  exit 1
}
agent_mosh_openssl_root="${TESSERA_ANDROID_MOSH_OPENSSL_ROOT:-}"
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

[[ -x "$java_home/bin/java" ]] || { echo "missing JDK 17 at $java_home" >&2; exit 1; }
[[ -x "$swift_bin" ]] || { echo "missing Swift 6.3.3 at $swift_bin" >&2; exit 1; }
[[ -f "$fixture_config" ]] || { echo "missing fixture config: $fixture_config" >&2; exit 1; }
[[ "$agent_mosh_runtime" == 0 || "$agent_mosh_runtime" == 1 ]] || {
  echo "TESSERA_ANDROID_AGENT_CENTER_MOSH must be 0 or 1" >&2
  exit 1
}
if [[ "$agent_mosh_runtime" == 1 ]]; then
  [[ -f "$agent_mosh_openssl_root/include/openssl/evp.h" && -f "$agent_mosh_openssl_root/lib/libcrypto.a" ]] || {
    echo "Mosh Agent Center gate requires TESSERA_ANDROID_MOSH_OPENSSL_ROOT with reviewed arm64 OpenSSL" >&2
    exit 1
  }
elif [[ "$program_status_only" == 0 ]]; then
  # The render-ledger isolation proof deliberately includes mosh+tmux: a
  # green SSH-only run cannot establish that the side-channel owner survives
  # a control reconnect while the UDP painter remains live.
  echo "Android native SSH gate requires TESSERA_ANDROID_AGENT_CENTER_MOSH=1 for the tmux render isolation proof" >&2
  exit 1
fi
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
require_command openssl
fixture_secret="$(fixture_password)"

for host in "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_CHAOS_HOST"; do
  [[ "$host" =~ ^[A-Za-z0-9.:_-]+$ ]] || { echo "fixture host contains unsupported characters" >&2; exit 1; }
done
[[ "$TESSERA_FIXTURE_APP_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || { echo "invalid fixture port" >&2; exit 1; }
(( TESSERA_FIXTURE_APP_PORT <= 65535 )) || { echo "fixture port is out of range" >&2; exit 1; }
[[ "$TESSERA_FIXTURE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "invalid fixture user" >&2; exit 1; }

run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-android-native-ssh.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-native-ssh-$(date -u +%Y%m%dT%H%M%SZ)-$$"
token="$(fixture_run_token)"
marker="tessera-phase-a-$token"
render_ledger_fixture_session="tessera-ledger-$token"
# Keep each render marker contiguous in a compact horizontal split. The full
# run token remains responsible for globally unique fixture/session cleanup.
render_ledger_token="$(openssl rand -base64 7 | tr '+/' '-_' | tr -d '=\n' | cut -c1-9)"
[[ "$render_ledger_token" =~ ^[A-Za-z0-9_-]{9}$ ]] || {
  echo "failed to generate a compact render-ledger token" >&2
  exit 1
}
[[ "$render_ledger_fixture_session" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || {
  echo "generated render-ledger fixture session is not cleanup-safe" >&2
  exit 1
}
fixture_path="/data/local/tmp/tessera-native-ssh-fixture.properties"
agent_setup_path="/tmp/tessera-native-agent-setup-$token.sh"
agent_rc_state_path="/tmp/tessera-native-agent-rc-state-$token.sh"
agent_tmux_session="tessera-native-agent-$token"
agent_fixture_root=""
agent_fixture_home=""
agent_rc_snapshot=""
agent_rc_snapshot_taken=0
agent_fixture_owned=0
agent_tmux_started=0
emulator_pid=''
serial=''

cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  local cleanup_status=0
  fixture_secret=''
  # The run directory must still be deleted on failure, but retain the
  # emulator's own diagnosis in the caller's log before removing it.
  if [[ "$status" -ne 0 && -f "$run_root/emulator.log" ]]; then
    echo "Native gate failed; final emulator diagnostics follow:" >&2
    tail -80 "$run_root/emulator.log" >&2 || true
  fi
  # An emulator crash prevents Kotlin finally blocks from running. These
  # exact names mirror SshjAndroidInstrumentedTest and include this run's
  # unique token; never kill the account-wide tmux server.
  if ! control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$token" <<'REMOTE'
set -eu
for session in "tessera-$2" "tessera-authority-$2" "tessera-geometry-$2" "tessera-cwd-$2"; do
  if runuser -u "$1" -- tmux has-session -t "=$session" 2>/dev/null; then
    runuser -u "$1" -- tmux kill-session -t "=$session"
  fi
done
REMOTE
  then
    echo "failed to clean exact Android networking fixture sessions" >&2
    cleanup_status=1
  fi
  if ! control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
    "su -s /bin/sh '$TESSERA_FIXTURE_USER' -c '/usr/local/bin/tessera-fixture-probe tmux-isolation-cleanup --session $render_ledger_fixture_session'" \
    >/dev/null 2>&1; then
    echo "failed to remove exact Android render-ledger fixture $render_ledger_fixture_session" >&2
    cleanup_status=1
  fi
  # Every tmux session these instrumented tests create carries this run's
  # token, and so does every mosh-server that attaches to one of them (its
  # visible-client command names the session and its `-view`). A test process
  # that dies mid-case cannot run its finally block: the servers it started
  # never exit, and one it held with SIGSTOP holds TERM until continued.
  # Reap exactly those before the account-wide check below, which stays the
  # refusal for servers whose ownership cannot be proven (raw mosh carries no
  # session name in its command line).
  if ! reap_run_fixture_sessions "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_USER" \
    "tessera-$token" "tessera-authority-$token" "tessera-geometry-$token" "tessera-cwd-$token" \
    "$render_ledger_fixture_session" "tessera-inline-hist-$token" "tessera-inline-flick-$token" \
    "tessera-ps-ssh-$token" "tessera-ps-mosh-$token" \
    "tessera-tui-$token" "tessera-rgb-$token" "tessera-mouse-control-$token" "$agent_tmux_session" >&2; then
    echo "native-SSH gate's run-owned tmux sessions or mosh-servers survived cleanup" >&2
    cleanup_status=1
  fi
  for host in "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_CHAOS_HOST"; do
    if ! control_ssh "$host" \
      "if [ -f '/home/$TESSERA_FIXTURE_USER/.ssh/authorized_keys' ]; then sed -i '/ $marker\$/d' '/home/$TESSERA_FIXTURE_USER/.ssh/authorized_keys'; fi" \
      >/dev/null 2>&1; then
      echo "failed to verify temporary native-SSH key cleanup on $host" >&2
      cleanup_status=1
    fi
  done
  # The Agent fixture uses only a run-token path and a private tmux session.
  # Do not erase a fixture home/config wholesale: cleanup targets exactly the
  # files this gate installed after its clean-state preflight, including the
  # Agent Host deployment the product installs (its runtime base, staging,
  # digest-named versions, install lock, launcher link and remover). Even the
  # product's remover keeps those directories, so leaving them would make
  # the next run's preflight refuse the account.
  if [[ "$agent_fixture_owned" == 1 && -n "$agent_fixture_home" && -n "$agent_fixture_root" ]]; then
    # Mosh transports reap the exact PID parsed from their own bootstrap
    # banner. Never use account-wide `pkill`: even a fixture account can be
    # shared by another in-flight gate between our preflight and teardown.
    # Report a stray server as a cleanup failure instead of guessing ownership
    # and terminating another run's process.
    if ! control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
      "! pgrep -u '$TESSERA_FIXTURE_USER' -x mosh-server >/dev/null 2>&1" \
      >/dev/null 2>&1; then
      echo "native-SSH gate left a mosh-server whose ownership cannot be proven; refusing broad cleanup" >&2
      describe_fixture_mosh_servers "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_USER" >&2 || true
      cleanup_status=1
    fi
    if [[ "$agent_tmux_started" -eq 1 ]]; then
      # tmux sockets are per-UID. Running this as the control user would look
      # only at root's socket and leak the fixture provider process. The run
      # reap above normally removed this session already (and verified it).
      control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
        "su -s /bin/sh '$TESSERA_FIXTURE_USER' -c 'if tmux has-session -t =$agent_tmux_session 2>/dev/null; then tmux kill-session -t =$agent_tmux_session; fi'" \
        >/dev/null 2>&1 || cleanup_status=1
    fi
    if [[ "$agent_rc_snapshot_taken" -eq 1 ]]; then
      control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
        "su -s /bin/sh '$TESSERA_FIXTURE_USER' -c '/bin/sh $agent_rc_state_path restore $agent_rc_snapshot'" \
        >/dev/null 2>&1 || cleanup_status=1
    fi
    control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
      "rm -f '$agent_fixture_home/.config/tessera/agent-codex-recover.sh'" \
      >/dev/null 2>&1 || cleanup_status=1
    control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
      "rm -f '$agent_setup_path' '$agent_rc_state_path'; rm -rf '$agent_fixture_root' '$agent_fixture_home/.claude/projects/tessera-native-$token' '$agent_fixture_home/.config/tessera/active-shells' '$agent_fixture_home/.config/tessera/active-subagents' '$agent_fixture_home/.config/tessera/agent-host' '$agent_fixture_home/.config/tessera/agent-host-staging' '$agent_fixture_home/.config/tessera/agent-host-versions'; rm -f '$agent_fixture_home/.config/tessera/agent-host-install.lock' '$agent_fixture_home/.config/tessera/tessera-agent-host' '$agent_fixture_home/.config/tessera/agent-uninstall.sh' '$agent_fixture_home/.config/tessera/agent-lifecycle-hook.sh' '$agent_fixture_home/.config/tessera/agent-launch.sh' '$agent_fixture_home/.config/tessera/tessera-agent-project' '$agent_fixture_home/.config/tessera/tessera-agent-launch' '$agent_fixture_home/.config/tessera/tessera-agent-prove' '$agent_fixture_home/.config/tessera/agent-codex-readiness.sh' '$agent_fixture_home/.config/tessera/agent-lifecycle.sh' '$agent_fixture_home/.config/tessera/claude-agent-hooks.json' '$agent_fixture_home/.config/tessera/agent-lifecycle-diagnostics.log' '$agent_fixture_home/.config/tessera/codex-readiness-diagnostics.log' '$agent_fixture_home/.config/tessera/bin/claude' '$agent_fixture_home/.config/tessera/bin/codex' '$agent_fixture_home/.claude/settings.json' '$agent_fixture_home/.codex/hooks.json' '$agent_fixture_home/.kimi-code/config.toml'; rmdir '$agent_fixture_home/.config/tessera/bin' '$agent_fixture_home/.config/tessera' '$agent_fixture_home/.config' '$agent_fixture_home/.claude/projects' '$agent_fixture_home/.claude' '$agent_fixture_home/.codex' '$agent_fixture_home/.kimi-code' 2>/dev/null || true" \
      >/dev/null 2>&1 || cleanup_status=1
  fi
  if [[ -n "$serial" ]]; then
    "$adb" -s "$serial" shell rm -f "$fixture_path" >/dev/null 2>&1 || true
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  fi
  if [[ -n "$emulator_pid" ]]; then
    # Boot can fail before ADB discovers the emulator. Bound cleanup to the
    # child process this script owns instead of waiting forever after emu kill.
    if kill -0 "$emulator_pid" 2>/dev/null; then
      kill -TERM "$emulator_pid" 2>/dev/null || true
      for _ in {1..10}; do
        kill -0 "$emulator_pid" 2>/dev/null || break
        sleep 1
      done
      kill -0 "$emulator_pid" 2>/dev/null && kill -KILL "$emulator_pid" 2>/dev/null || true
    fi
    wait "$emulator_pid" >/dev/null 2>&1 || true
  fi
  JAVA_HOME="$java_home" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || cleanup_status=1
  case "$run_root" in
    "${TMPDIR:-/tmp}"/tessera-android-native-ssh.*) rm -rf -- "$run_root" ;;
    *) echo "refusing to remove unexpected native-SSH directory: $run_root" >&2; cleanup_status=1 ;;
  esac
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then status=$cleanup_status; fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

password_base64="$(printf '%s' "$fixture_secret" | base64 | tr -d '\n')"
umask 077
printf 'stableHost=%s\nchaosHost=%s\nport=%s\nuser=%s\nnotmuxUser=%s\npasswordBase64=%s\ntoken=%s\nrenderLedgerSession=%s\nrenderLedgerToken=%s\n' \
  "$TESSERA_FIXTURE_STABLE_HOST" \
  "$TESSERA_FIXTURE_CHAOS_HOST" \
  "$TESSERA_FIXTURE_APP_PORT" \
  "$TESSERA_FIXTURE_USER" \
  "$TESSERA_FIXTURE_NOTMUX_USER" \
  "$password_base64" \
  "$token" \
  "$render_ledger_fixture_session" \
  "$render_ledger_token" \
  >"$run_root/fixture.properties"
password_base64=''
fixture_secret=''

# The ordering and program-status lanes own only uniquely named tmux sessions.
# They do not install Agent Center helpers or edit shell/provider configuration.
if [[ "$ordering_only" == 0 && "$program_status_only" == 0 ]]; then
# The fixture must begin without any Tessera integration. The instrumented
# Android product path owns probe, install, verification, and update; preparing
# helpers here would let a missing product installer pass this gate again.
agent_fixture_home="$(control_ssh "$TESSERA_FIXTURE_STABLE_HOST" "getent passwd '$TESSERA_FIXTURE_USER' | cut -d: -f6")"
[[ "$agent_fixture_home" =~ ^/[-A-Za-z0-9_./]+$ ]] || { echo "invalid disposable fixture home" >&2; exit 1; }
agent_fixture_root="$agent_fixture_home/.tessera-native-agent-$token"
agent_rc_snapshot="$agent_fixture_root/rc-state"
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
  "test ! -e '$agent_fixture_home/.config/tessera' && test ! -e '$agent_fixture_home/.claude/settings.json' && test ! -e '$agent_fixture_home/.codex/hooks.json' && test ! -e '$agent_fixture_home/.kimi-code/config.toml' && test ! -e '$agent_fixture_root' && ! pgrep -u '$TESSERA_FIXTURE_USER' -x mosh-server >/dev/null 2>&1" \
  || {
    echo "Agent fixture account is not clean; refusing to modify it" >&2
    # A stray mosh-server is the usual cause; name what is there (read-only)
    # so the run that leaked it can be found. Ownership cannot be proven here:
    # no earlier run's token is known to this one.
    describe_fixture_mosh_servers "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_USER" >&2 || true
    exit 1
  }
agent_fixture_owned=1
control_scp "$repo_root/scripts/android/native-agent-fixture-rc-state.sh" "$TESSERA_FIXTURE_STABLE_HOST" "$agent_rc_state_path"
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
  "chown '$TESSERA_FIXTURE_USER' '$agent_rc_state_path'; chmod 700 '$agent_rc_state_path'; su -s /bin/sh '$TESSERA_FIXTURE_USER' -c '$agent_rc_state_path snapshot $agent_rc_snapshot'" \
  || { echo "failed to snapshot disposable fixture shell state" >&2; exit 1; }
agent_rc_snapshot_taken=1
agent_transcript="$agent_fixture_home/.claude/projects/tessera-native-$token/session.jsonl"
agent_transcript_ref="$(printf '%s' "$agent_transcript" | base64 | tr -d '\n=' | tr '+/' '-_')"
control_scp "$repo_root/scripts/android/native-agent-fixture-setup.sh" "$TESSERA_FIXTURE_STABLE_HOST" "$agent_setup_path"
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
  "chown '$TESSERA_FIXTURE_USER' '$agent_setup_path'; chmod 700 '$agent_setup_path'; su -s /bin/sh '$TESSERA_FIXTURE_USER' -c '$agent_setup_path $agent_fixture_root $agent_transcript $agent_tmux_session'" \
  || { echo "failed to create owned Agent fixture files" >&2; exit 1; }
agent_tmux_started=1
printf 'agentTranscriptRef=%s\nagentDirectory=%s\nagentTmuxSession=%s\n' \
  "$agent_transcript_ref" "$agent_fixture_root" "$agent_tmux_session" >>"$run_root/fixture.properties"
fi

JAVA_HOME="$java_home" "$avdmanager" create avd \
  --force --name "$avd_name" --package "$system_image" --device pixel_tablet \
  <<<"no" >/dev/null

emulator_window_args=(-no-audio -no-window)
# Some macOS emulator builds abort inside the headless gRPC callback loop.
# A visible, equally disposable emulator provides the same instrumentation
# lane without weakening any assertions or changing the application.
[[ "$emulator_window" == 0 ]] || emulator_window_args=(-no-audio)
# Stay inside Android's recommended emulator console/ADB discovery range.
for port in $(seq 5554 2 5584); do
  console_port_busy=0
  adb_port_busy=0
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && console_port_busy=1
    lsof -nP -iTCP:"$((port + 1))" -sTCP:LISTEN >/dev/null 2>&1 && adb_port_busy=1
  fi
  if [[ "$console_port_busy" -eq 0 && "$adb_port_busy" -eq 0 ]] \
      && ! "$adb" devices | awk 'NR > 1 {print $1}' | grep -qx "emulator-$port"; then
    serial="emulator-$port"
    "$emulator" -avd "$avd_name" -port "$port" "${emulator_window_args[@]}" \
      -no-boot-anim -no-snapshot -wipe-data -crash-report-mode never \
      >"$run_root/emulator.log" 2>&1 &
    emulator_pid=$!
    break
  fi
done
[[ -n "$serial" ]] || { echo "no free Android emulator port" >&2; exit 1; }

booted=0
for _ in {1..240}; do
  if ! kill -0 "$emulator_pid" >/dev/null 2>&1; then
    echo "Android emulator exited during boot" >&2
    tail -80 "$run_root/emulator.log" >&2 || true
    exit 1
  fi
  if [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
    booted=1
    break
  fi
  sleep 1
done
[[ "$booted" -eq 1 ]] || { echo "Android emulator did not finish booting" >&2; exit 1; }

"$adb" -s "$serial" push "$run_root/fixture.properties" "$fixture_path" >/dev/null
# Instrumentation executes as the target app UID, not adb's shell UID. This
# emulator is uniquely named and deleted by the EXIT trap, so expose the
# run-scoped fixture read-only for the duration of this disposable gate.
"$adb" -s "$serial" shell chmod 0644 "$fixture_path"

(
  cd "$repo_root/android"
  # Every connected lane shares the one run-scoped fixture account. Keep
  # Gradle from overlapping module instrumentation tasks: tmux sockets and
  # Mosh ownership are serialized resources even though their test names are
  # otherwise unique.
  gradle_args=(--no-daemon --max-workers=1)
  if [[ "$agent_mosh_runtime" == 1 ]]; then
    gradle_args+=("-Ptessera.enableMoshNative=true" "-Ptessera.moshOpenSslRoot=$agent_mosh_openssl_root")
  fi
  if [[ "$ordering_only" == 1 ]]; then
    ANDROID_SERIAL="$serial" JAVA_HOME="$java_home" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew "${gradle_args[@]}" \
      -Pandroid.testInstrumentationRunnerArguments.class=com.bambouville.tessera.core.bridge.SharedTmuxWindowOrderInstrumentedTest \
      :core-bridge:connectedDebugAndroidTest
    ANDROID_SERIAL="$serial" JAVA_HOME="$java_home" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew "${gradle_args[@]}" \
      -Pandroid.testInstrumentationRunnerArguments.class=com.bambouville.tessera.feature.session.TmuxRenderLedgerIsolationInstrumentedTest#liveTmuxRenderLedgerKeepsOwnersIsolatedAcrossSwitchReconnectAndMosh \
      :feature-session:connectedDebugAndroidTest
  elif [[ "$program_status_only" == 1 ]]; then
    ANDROID_SERIAL="$serial" JAVA_HOME="$java_home" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew "${gradle_args[@]}" \
      -Pandroid.testInstrumentationRunnerArguments.class=com.bambouville.tessera.feature.session.ProgramStatusLiveInstrumentedTest \
      :feature-session:connectedDebugAndroidTest
    ANDROID_SERIAL="$serial" JAVA_HOME="$java_home" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew "${gradle_args[@]}" \
      -Pandroid.testInstrumentationRunnerArguments.class=com.bambouville.tessera.feature.session.ChallengeRenewalLiveInstrumentedTest \
      :feature-session:connectedDebugAndroidTest
  else
    ANDROID_SERIAL="$serial" JAVA_HOME="$java_home" SWIFT_ANDROID_SWIFT="$swift_bin" ./gradlew "${gradle_args[@]}" \
    :core-bridge:connectedDebugAndroidTest \
    :networking:connectedDebugAndroidTest \
    :terminal:connectedDebugAndroidTest \
    :feature-session:connectedDebugAndroidTest
  fi
)

log_output="$("$adb" -s "$serial" logcat -d -s TesseraNativeSsh:I '*:S')"
if [[ "$ordering_only" == 1 ]]; then
  [[ "$(printf '%s\n' "$log_output" | grep -c 'TESSERA_WINDOW_ORDER_OK append=1 move=1 external=1 panes=1')" -eq 2 ]] || {
    echo "Window ordering did not pass on both tmux transports" >&2
    echo "$log_output" >&2
    exit 1
  }
  [[ "$log_output" == *"TESSERA_ANDROID_TMUX_ISOLATION_TRANSPORTS ssh=1 sshTmux=1 mosh=1 moshTmux=1"* ]] || {
    echo "Ordering lane did not prove all four transport boundaries" >&2
    exit 1
  }
  echo "$log_output"
  echo "Android window ordering JNI/live gate passed on $serial; exact fixture cleanup follows"
  script_completed=1
  exit 0
fi
if [[ "$log_output" != *"TESSERA_ANDROID_PROGRAM_STATUS_OK raw=1 query=1 sshTmux=1 moshTmux="[01]* ]]; then
  echo "Android program-status live proof missing" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$agent_mosh_runtime" == 1 && "$log_output" != *"TESSERA_ANDROID_PROGRAM_STATUS_OK raw=1 query=1 sshTmux=1 moshTmux=1"* ]]; then
  echo "Android program-status proof missing for native Mosh+tmux" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$program_status_only" == 1 ]]; then
  echo "$log_output"
  echo "Android program-status live gate passed on $serial; exact fixture cleanup follows"
  script_completed=1
  exit 0
fi
for transport in ssh ssh+tmux mosh mosh+tmux; do
  if [[ "$log_output" != *"TESSERA_ANDROID_FILES_FOLLOW_OK transport=$transport cd=1 reopen=1 manual=1"* ]]; then
    echo "Android Files cwd-follow proof missing for $transport" >&2
    exit 1
  fi
done
if [[ "$log_output" != *"TESSERA_SSHJ_ANDROID_OK"* ]]; then
  echo "SSHJ Android proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_HOST_KEYS_OK ed25519=1 ecdsa=1 rsa=1 direct=1 jump=1"* ]]; then
  echo "Android host-key algorithm matrix did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_SSH_BACKEND_OK password=1 passwordWiped=1 pty=1 resize=1 hostKey=1"* ]]; then
  echo "production Android SSH backend did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_FILES_OK browse=1 upload=1 download=1 mutate=1"* ]]; then
  echo "Android Remote Files side-channel proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_TMUX_OK attach=1 create=1 split=1 sharedCore=1"* ]]; then
  echo "Android shared-core tmux proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_TMUX_DEGRADE_OK notEngaged=1 classified=unavailable sharedCore=1"* ]]; then
  echo "native-ssh gate: tmux launch-failure classification did not report success" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_TMUX_AUTHORITY_OK stampReplayInert=1 restampDetected=1 paneTitleLabel=1 sharedCore=1"* ]]; then
  echo "Android tmux take-back / window-label proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi

if [[ "$log_output" != *"TESSERA_ANDROID_TMUX_GEOMETRY_OK geometryNeutral=1 splitPreserved=1 largerReattach=1 sharedCore=1"* ]]; then
  echo "Android compact tmux geometry proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_TMUX_ISOLATION_DIAGNOSTICS dropped_foreign=0"* ]]; then
  echo "Android tmux render isolation did not prove dropped_foreign=0" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_TMUX_ISOLATION_TRANSPORTS ssh=1 sshTmux=1 mosh=1 moshTmux=1 history=1 freshGrid=1 p2bSurface=1 postDropPainter=1 dropped_foreign=0"* ]]; then
  echo "Android tmux render isolation did not prove all four transports, detached P2b surface history, and post-drop Mosh painting" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_MOSH_OVERLAY_HOST_OK mounted=1 history=1 tail=1 windowPrune=1 freshSurface=1"* ]]; then
  echo "Android production Mosh overlay host did not prove mount, history reveal, tail return, and window pruning" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_TMUX_ISOLATION_OK windows=1 panes=1 reconnect=1 mosh=1 sharedCore=1"* ]]; then
  echo "Android tmux render isolation proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$log_output" != *"TESSERA_ANDROID_AGENT_CENTER_SSH_OK install=1 update=1 projection=1 rawAction=1 tmuxFocus=1 spawn=1 transports=2"* ]]; then
  echo "Android Agent Center SSH + SSH-tmux proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$agent_mosh_runtime" == 1 && "$log_output" != *"TESSERA_ANDROID_AGENT_CENTER_MOSH_OK rawUdp=1 bootstrapRoot=1 tmuxUdp=1 tmuxSideChannel=1 tmuxVisiblePaneFocus=1 transports=2"* ]]; then
  echo "Android Agent Center Mosh + Mosh-tmux proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$agent_mosh_runtime" == 1 && "$log_output" != *"TESSERA_ANDROID_AGENT_MOSH_RECOVERY_OK sameCarrier=1 udpProgress=1 foreground=1 renewedRoute=1 integration=1 processInventory=1"* ]]; then
  echo "Android raw-Mosh Agent recovery did not preserve UDP output and recover reads after its auxiliary SSH route failed" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$agent_mosh_runtime" == 1 && "$log_output" != *"TESSERA_ANDROID_MOSH_TARGET_OK resolvedName=1 unresolvableRejected=1 sharedCore=1"* ]]; then
  echo "Android native Mosh host-name resolution proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$agent_mosh_runtime" == 1 && "$log_output" != *"TESSERA_ANDROID_MOSH_BOOTSTRAP_OK loginShellFallback=1 dnsTarget="* ]]; then
  echo "Android Mosh login-only-PATH bootstrap proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$agent_mosh_runtime" == 1 && "$log_output" != *"TESSERA_ANDROID_MOSH_TERM_OK term=xterm-256color tmuxClientRGB=1 sharedCore=1"* ]]; then
  echo "Android Mosh TERM / truecolor visible-client proof did not report its success marker" >&2
  echo "$log_output" >&2
  exit 1
fi
if [[ "$agent_mosh_runtime" == 1 && "$log_output" == *"TESSERA_ANDROID_MOSH_BOOTSTRAP_OK loginShellFallback=1 dnsTarget=0"* ]]; then
  echo "note: the wildcard DNS resolver was unreachable from the emulator, so the live Mosh dial used the fixture address" >&2
fi
echo "$log_output"
echo "Android native SSH gate passed on $serial; fixture-key and disposable-AVD cleanup follows"
script_completed=1
