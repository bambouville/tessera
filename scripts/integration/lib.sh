#!/usr/bin/env bash

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$INTEGRATION_DIR/../.." && pwd)"
FIXTURE_CONFIG="${TESSERA_FIXTURE_CONFIG:-$INTEGRATION_DIR/fixture.env}"
FIXTURE_CONFIG_DIR="$(cd "$(dirname "$FIXTURE_CONFIG")" && pwd)"
# Private fixture credentials live beside the selected fixture.env.  This is
# normally the current checkout's integration directory, but durable feature
# worktrees intentionally reuse the primary checkout's gitignored config and
# must therefore reuse its matching password/key state as one atomic set.
FIXTURE_STATE="${TESSERA_INTEGRATION_FIXTURE_STATE_DIR:-$FIXTURE_CONFIG_DIR/.state}"
FIXTURE_OUT="${TESSERA_INTEGRATION_OUTPUT_DIR:-$INTEGRATION_DIR/out}"
SIMULATOR_STATE="${TESSERA_INTEGRATION_SIMULATOR_STATE_DIR:-$FIXTURE_STATE}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '[integration] %s\n' "$*"
}

# macOS /bin/bash 3.2 enters an EXIT trap with $? = 0 after a `set -u` abort
# (unbound variable, empty "${array[@]}", ${VAR:?}) under `set -e`, so a lane
# that crashed before its tests would report success. Scripts set
# script_completed=1 as their last statement and before any deliberate early
# exit. Handlers that capture $? run `fail_closed_status "$status" ||
# status=1`; other handlers are installed as `trap 'fail_closed_trap cleanup'
# EXIT`. run-fail-closed-script-tests.sh checks every EXIT trap for this.
fail_closed_status() {
  [[ "${1:-0}" -ne 0 || "${script_completed:-0}" == 1 ]] && return 0
  printf '%s: aborted before completion (bash set -u abort?)\n' "${0##*/}" >&2
  return 1
}

# Runs one cleanup command as the EXIT handler, then exits with the script's
# own status, failing closed as above.
fail_closed_trap() {
  local status=$?
  fail_closed_status "$status" || status=1
  "$@"
  exit "$status"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

# A freshly booted AVD keeps applying overlay changes (CONFIG_ASSETS_PATHS)
# for several seconds after sys.boot_completed, and each one relaunches every
# activity, including a test's, mid-case. Return once the global configuration
# sequence has held for ten seconds; fail after ninety.
wait_for_android_configuration_settled() {
  local adb="$1" serial="$2"
  local last='' current='' stable=0 waited=0
  while (( waited < 90 )); do
    current="$("$adb" -s "$serial" shell dumpsys window 2>/dev/null \
      | grep -m1 -o 'mGlobalConfiguration=.*' | grep -o ' s\.[0-9]*' | tail -n 1 || true)"
    if [[ -n "$current" && "$current" == "$last" ]]; then
      stable=$((stable + 1))
      (( stable >= 10 )) && return 0
    else
      stable=0
      last="$current"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf 'error: Android configuration did not settle within 90 s (last sequence:%s)\n' "${last:- none}" >&2
  return 1
}

# XcodeBuildMCP prepares a relocatable test product instead of retaining an
# .xctestrun in DerivedData. Allow affected lanes to exercise that exact build.
# Without this explicit opt-in, preserve the existing source-build workflow.
integration_xcodebuild() {
  if [[ -z "${TESSERA_INTEGRATION_TEST_PRODUCTS:-}" ]]; then
    xcodebuild "$@"
    return $?
  fi
  [[ -d "$TESSERA_INTEGRATION_TEST_PRODUCTS" && "$TESSERA_INTEGRATION_TEST_PRODUCTS" == *.xctestproducts ]] \
    || die 'TESSERA_INTEGRATION_TEST_PRODUCTS must name a prepared .xctestproducts directory'
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      test|test-without-building) shift ;;
      -project|-workspace|-scheme|-configuration|-derivedDataPath) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  xcodebuild test-without-building -testProductsPath "$TESSERA_INTEGRATION_TEST_PRODUCTS" ${args[@]+"${args[@]}"}
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is not set in $FIXTURE_CONFIG"
}

delete_owned_test_simulator() {
  local udid_file="$1"
  local owner_file="${udid_file}.owned"
  local udid owned_udid attempt deleted=0
  [[ -f "$udid_file" && -f "$owner_file" ]] || return 0
  IFS= read -r udid <"$udid_file"
  IFS= read -r owned_udid <"$owner_file"
  [[ -n "$udid" && "$udid" == "$owned_udid" ]] || {
    note "refusing to delete simulator with mismatched ownership files: $udid_file"
    return 1
  }
  for attempt in {1..30}; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    if xcrun simctl delete "$udid" >/dev/null 2>&1; then
      deleted=1
      break
    fi
    if ! xcrun simctl list devices -j \
      | jq -e --arg udid "$udid" \
        '[.devices[][] | select(.udid == $udid)] | length > 0' \
        >/dev/null 2>&1; then
      deleted=1
      break
    fi
    sleep 1
  done
  if [[ "$deleted" -eq 1 ]]; then
    if [[ -f "${udid_file}.software-keyboard" ]]; then
      # Use the preferences service: editing its plist directly lets cfprefsd
      # restore the deleted entry from cache. Preserve every other device.
      osascript -l JavaScript -e '
        function run(args) {
          ObjC.import("Foundation");
          const prefs = $.NSUserDefaults.alloc.initWithSuiteName("com.apple.iphonesimulator");
          const devices = ObjC.deepUnwrap(prefs.dictionaryForKey("DevicePreferences"));
          if (devices) {
            delete devices[args[0]];
            prefs.setObjectForKey($(devices), "DevicePreferences");
            prefs.synchronize;
          }
        }' "$udid" >/dev/null 2>&1 || true
      rm -f "${udid_file}.software-keyboard"
    fi
    rm -f "$udid_file" "$owner_file" "${udid_file}.run-id"
  else
    note "could not delete disposable simulator $udid; retaining ownership record for retry"
    return 1
  fi
}

# macOS does not ship GNU timeout. Perl's alarm survives exec, giving every
# CoreSimulator operation a hard wall-clock bound while remaining compatible
# with the system Bash 3.2 used by this suite. Returns 124 on timeout.
simctl_bounded() {
  local timeout_ms="$1"
  shift
  local status
  if /usr/bin/perl -MTime::HiRes=alarm -e \
      'alarm(shift(@ARGV) / 1000); exec @ARGV or die "exec failed: $!\n";' \
      "$timeout_ms" xcrun simctl "$@"; then
    return 0
  else
    status=$?
  fi
  if [[ "$status" -eq 142 ]]; then
    printf '[integration] timed out after %sms: xcrun simctl %s\n' \
      "$timeout_ms" "$*" >&2
    return 124
  fi
  return "$status"
}

# Every Xcode lane in one run - visual capture, unit lanes, UI harnesses,
# the two-device bootstrap harness - tests the same Debug simulator build.
# It is compiled once, up front, into this DerivedData; lanes then run
# `test-without-building`. Separate per-lane DerivedData trees used to cost
# up to four full app builds per run whenever a source file had changed.
integration_derived_data() {
  printf '%s' "${TESSERA_INTEGRATION_DERIVED_DATA:-$FIXTURE_STATE/DerivedData}"
}

integration_app_path() {
  printf '%s/Build/Products/Debug-iphonesimulator/Tessera.app' "$(integration_derived_data)"
}

# Build the app and both test bundles once. A parent that already built
# exports TESSERA_INTEGRATION_PREBUILT=1 so nested lane scripts only verify
# the product exists. Standalone lane invocations without that variable
# still build, so every entry point remains self-sufficient.
ensure_integration_build() {
  local log="${1:-/dev/null}"
  local derived_data
  derived_data="$(integration_derived_data)"
  if [[ "${TESSERA_INTEGRATION_PREBUILT:-0}" == 1 ]]; then
    [[ -d "$(integration_app_path)" ]] \
      || die "TESSERA_INTEGRATION_PREBUILT=1 but $(integration_app_path) is missing"
    return 0
  fi
  require_command xcodebuild
  mkdir -p "$derived_data" "$(dirname "$log")"
  note "building the app and test bundles once for every lane (log: $log)"
  if ! xcodebuild build-for-testing \
    -project "$REPO_ROOT/Tessera.xcodeproj" \
    -scheme Tessera \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data" \
    >"$log" 2>&1; then
    die "build-for-testing failed; see $log"
  fi
  [[ -d "$(integration_app_path)" ]] || die "build-for-testing did not produce $(integration_app_path)"
  export TESSERA_INTEGRATION_PREBUILT=1
  export TESSERA_INTEGRATION_DERIVED_DATA="$derived_data"
}

load_fixture_config() {
  [[ -f "$FIXTURE_CONFIG" ]] || die "missing $FIXTURE_CONFIG (copy fixture.env.example)"
  local harness_integration_dir="$INTEGRATION_DIR"
  INTEGRATION_DIR="$(cd "$(dirname "$FIXTURE_CONFIG")" && pwd)"
  # shellcheck disable=SC1090
  source "$FIXTURE_CONFIG"
  INTEGRATION_DIR="$harness_integration_dir"

  : "${TESSERA_FIXTURE_CONTROL_USER:=root}"
  : "${TESSERA_FIXTURE_CONTROL_PORT:=22}"
  : "${TESSERA_FIXTURE_APP_PORT:=2222}"
  : "${TESSERA_FIXTURE_USER:=tessera}"
  : "${TESSERA_FIXTURE_NOTMUX_USER:=tessera-notmux}"

  require_value TESSERA_FIXTURE_STABLE_HOST
  require_value TESSERA_FIXTURE_CHAOS_HOST
  require_value TESSERA_FIXTURE_CONTROL_KEY

  [[ -r "$TESSERA_FIXTURE_CONTROL_KEY" ]] \
    || die "control key is not readable: $TESSERA_FIXTURE_CONTROL_KEY"

  mkdir -p "$FIXTURE_STATE" "$FIXTURE_OUT"
  chmod 700 "$FIXTURE_STATE"
  TESSERA_FIXTURE_CONTROL_KNOWN_HOSTS="$FIXTURE_STATE/control_known_hosts"
  TESSERA_FIXTURE_APP_KNOWN_HOSTS="$FIXTURE_STATE/app_known_hosts"
}

control_ssh() {
  local host="$1"
  shift
  ssh \
    -i "$TESSERA_FIXTURE_CONTROL_KEY" \
    -p "$TESSERA_FIXTURE_CONTROL_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_CONTROL_KNOWN_HOSTS" \
    "$TESSERA_FIXTURE_CONTROL_USER@$host" "$@"
}

control_scp() {
  local source_path="$1"
  local host="$2"
  local destination_path="$3"
  scp \
    -i "$TESSERA_FIXTURE_CONTROL_KEY" \
    -P "$TESSERA_FIXTURE_CONTROL_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_CONTROL_KNOWN_HOSTS" \
    "$source_path" "$TESSERA_FIXTURE_CONTROL_USER@$host:$destination_path"
}

fixture_ssh() {
  local host="$1"
  shift
  ssh \
    -i "$FIXTURE_STATE/client_ed25519" \
    -p "$TESSERA_FIXTURE_APP_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_APP_KNOWN_HOSTS" \
    "$TESSERA_FIXTURE_USER@$host" "$@"
}

ensure_fixture_credentials() {
  require_command ssh-keygen
  require_command openssl

  if [[ ! -f "$FIXTURE_STATE/client_ed25519" ]]; then
    note "generating an app-facing Ed25519 fixture key"
    ssh-keygen \
      -q -t ed25519 -a 64 -N '' \
      -C 'tessera-integration-fixture' \
      -f "$FIXTURE_STATE/client_ed25519"
  fi
  chmod 600 "$FIXTURE_STATE/client_ed25519"

  if [[ ! -f "$FIXTURE_STATE/password" ]]; then
    openssl rand -hex 24 >"$FIXTURE_STATE/password"
  fi
  chmod 600 "$FIXTURE_STATE/password"
}

fixture_password() {
  [[ -f "$FIXTURE_STATE/password" ]] || die "fixture password has not been generated"
  IFS= read -r REPLY <"$FIXTURE_STATE/password"
  printf '%s' "$REPLY"
}

fixture_public_key() {
  [[ -f "$FIXTURE_STATE/client_ed25519.pub" ]] || die "fixture public key has not been generated"
  IFS= read -r REPLY <"$FIXTURE_STATE/client_ed25519.pub"
  printf '%s' "$REPLY"
}

# ---- Run-owned fixture sessions and mosh-servers ---------------------------
#
# A lane proves which tmux sessions, mosh-servers and processes on the shared
# fixture account are its own by name alone: it passes the run-unique tmux
# session names (or paths) its tests use, and a session or process is this
# run's only when one word of its name or command line is exactly one of
# those names or begins with "<name>-" (tmux views, `<name>-view`, and
# per-transport variants, `<name>-mosh`, derive their names that way). A word
# is a maximal run of [A-Za-z0-9_./-]. The mosh bootstrap hands mosh-server
# its tmux session single-quoted inside an `sh -lc` body ('tessera-x',
# 'tessera-x-view') and a custom launch command as bare arguments (--trigger
# /tmp/x.trigger); both spellings split into the same word, and neither can
# be confused with a longer name (`tessera-x1` is not `tessera-x`). Nothing
# account-wide is ever signalled: another lane may share the account at the
# same moment.
#
# Every lane's names carry fixture_run_token's three parts,
# TIMESTAMP-PID-RANDOM, and so do the visual cases', whose RUN_TOKEN is the
# basename of run-integration-tests.sh's run directory. One shape everywhere
# keeps any run's token from being another's "<token>-" prefix, as a two-part
# TIMESTAMP-PID was of a three-part token from the same second and PID on
# another machine.
#
# A mosh-server whose client is gone never exits on its own, and one left
# SIGSTOPped by a test process that died mid-case (TmuxRenderLedgerIsolation-
# InstrumentedTest, RealHostTransportIntegrationTests) holds every signal but
# SIGKILL and SIGCONT. Killing its tmux session does not end it either: it
# cannot even reap the tmux client that exits.

# fixture_run_token: a lane's run token (see above).
fixture_run_token() {
  printf '%s-%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$RANDOM"
}

# run_owned_name_is_specific NAME: whether NAME can prove ownership. Every
# lane's names carry a timestamped run token, so a name without a digit, a
# short one or one ending in "-" (an empty token) is a bug that would match
# other runs' sessions.
run_owned_name_is_specific() {
  [[ "$1" =~ ^[A-Za-z0-9_./-]{16,200}$ && "$1" == *[0-9]* && "$1" != *- ]]
}

# validate_run_owned_names CALLER USER NAME...
validate_run_owned_names() {
  local caller="$1" user="$2" name
  shift 2
  if [[ $# -eq 0 ]]; then
    printf '%s: no run-owned session names\n' "$caller" >&2
    return 1
  fi
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    printf '%s: invalid fixture user\n' "$caller" >&2
    return 1
  fi
  for name in "$@"; do
    if ! run_owned_name_is_specific "$name"; then
      printf '%s: refusing a name that cannot prove run ownership: %s\n' "$caller" "$name" >&2
      return 1
    fi
  done
}

# The start of every remote script below, which runs as the control user
# (root: only root may read another user's /proc/PID/exe) by `bash -s --
# USER ...`: the name rule again, since the host never trusts its caller,
# and /proc readers that use only builtins, so a scan of every process stays
# fast. They stay bash 3.2-clean so run-fixture-reap-tests.sh can drive them
# on macOS against a fake /proc (TESSERA_REAP_PROC_ROOT) with stand-ins for
# `id`, `kill`, `sleep`, `runuser` and `tmux`.
run_owned_remote_prelude() {
  cat <<'REMOTE_RUN_OWNED_PRELUDE'
set -euo pipefail
export LC_ALL=C
proc="${TESSERA_REAP_PROC_ROOT:-/proc}"

# require_run_names NAME...: never widen to a name that is not run-unique.
require_run_names() {
  local name
  [[ $# -gt 0 ]] || exit 2
  for name in "$@"; do
    [[ "$name" =~ ^[A-Za-z0-9_./-]{16,200}$ && "$name" == *[0-9]* && "$name" != *- ]] || exit 2
  done
}

# require_fixture_user USER: sets uid, USER's. The caller must be the control
# user, never USER itself: as USER, this script's own shell (and the SSH
# session's shell running it) would carry the run's names on its command
# line and be among its own targets.
require_fixture_user() {
  uid="$(id -u "$1")"
  [[ "$uid" =~ ^[0-9]+$ ]] || exit 2
  [[ "$(id -u)" != "$uid" ]] || exit 2
}

# read_comm PID: sets comm.
read_comm() {
  comm=''
  IFS= read -r comm 2>/dev/null <"$proc/$1/comm" || [[ -n "$comm" ]]
}

# read_stat PID: sets state, ppid and start (fields 3, 4 and 22), read after
# the comm's closing parenthesis so no process name can shift them.
read_stat() {
  local line='' rest
  local -a fields
  state='' ppid='' start=''
  IFS= read -r line 2>/dev/null <"$proc/$1/stat" || [[ -n "$line" ]] || return 1
  rest="${line##*) }"
  read -r -a fields <<<"$rest"
  [[ ${#fields[@]} -ge 20 ]] || return 1
  state="${fields[0]}" ppid="${fields[1]}" start="${fields[19]}"
}

# read_euid PID: sets euid.
read_euid() {
  local key real rest
  while read -r key real euid rest; do
    [[ "$key" != Uid: ]] || return 0
  done 2>/dev/null <"$proc/$1/status"
  euid=''
  return 1
}

# alive PID START: the same process (PID and start tick) has not exited. A
# zombie has: init reaps an orphan's corpse on its own.
alive() {
  local state ppid start
  read_stat "$1" || return 1
  [[ "$start" == "$2" && "$state" != Z && "$state" != X ]]
}

# names_this_run PID: a word of its command line is a name or "<name>-...".
names_this_run() {
  local word name
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    for name in "${names[@]}"; do
      if [[ "$word" == "$name" || "$word" == "$name"-* ]]; then
        return 0
      fi
    done
  done < <(tr -c 'A-Za-z0-9_./-' '\n' <"$proc/$1/cmdline" 2>/dev/null)
  return 1
}
REMOTE_RUN_OWNED_PRELUDE
}

# The remote half of reap_run_mosh_servers: `bash -s -- USER NAME...`. Prints
# one line per run-owned server and exits non-zero if any survives or cannot
# be proven to be mosh-server.
mosh_server_reap_script() {
  run_owned_remote_prelude
  cat <<'REMOTE_MOSH_REAP'
user="$1"
shift
require_fixture_user "$user"
require_run_names "$@"
names=("$@")
name_list="$*"

# Prints "PID START STATE" for each live mosh-server of USER naming this run.
run_owned_servers() {
  local dir pid comm euid state ppid start
  for dir in "$proc"/[0-9]*; do
    pid="${dir##*/}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    read_comm "$pid" && [[ "$comm" == mosh-server ]] || continue
    read_euid "$pid" && [[ "$euid" == "$uid" ]] || continue
    read_stat "$pid" || continue
    [[ "$state" != Z && "$state" != X ]] || continue
    names_this_run "$pid" || continue
    printf '%s %s %s\n' "$pid" "$start" "$state"
  done
}

# send PID START SIGNAL: signals only that same process, and records it in
# the caller's `sent`.
send() {
  if alive "$1" "$2"; then
    kill -"$3" "$1" 2>/dev/null || true
    sent="${sent:+$sent,}$3"
  fi
}

reap() {
  local pid="$1" start="$2" state="$3" sent='' waited=0 exe signal
  exe="$(readlink "$proc/$pid/exe" 2>/dev/null)" || exe=''
  if [[ "$exe" != */mosh-server && "$exe" != */"mosh-server (deleted)" ]]; then
    if ! alive "$pid" "$start"; then
      printf 'RUN_MOSH_SERVER_GONE pid=%s start=%s state=%s sent=none\n' "$pid" "$start" "$state"
      return 0
    fi
    printf 'RUN_MOSH_SERVER_REFUSED pid=%s start=%s state=%s reason=executable\n' "$pid" "$start" "$state"
    return 1
  fi
  # A stopped process keeps TERM pending until it is continued.
  send "$pid" "$start" CONT
  send "$pid" "$start" TERM
  while alive "$pid" "$start" && [[ "$waited" -lt 30 ]]; do
    # mosh-server spends its first TERM on a shutdown handshake with the
    # client address it remembers, which nobody acknowledges; a second
    # TERM during that handshake ends it at once.
    if [[ "$waited" -eq 10 ]]; then send "$pid" "$start" TERM; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if alive "$pid" "$start"; then
    send "$pid" "$start" KILL
    waited=0
    while alive "$pid" "$start" && [[ "$waited" -lt 20 ]]; do
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
  if alive "$pid" "$start"; then
    printf 'RUN_MOSH_SERVER_SURVIVED pid=%s start=%s state=%s sent=%s\n' "$pid" "$start" "$state" "${sent:-none}"
    return 1
  fi
  case ",$sent," in
    *,KILL,*) signal=KILL ;;
    *,TERM,*) signal=TERM ;;
    *)
      # It exited, or its PID now names another process, before any TERM.
      printf 'RUN_MOSH_SERVER_GONE pid=%s start=%s state=%s sent=%s\n' "$pid" "$start" "$state" "${sent:-none}"
      return 0 ;;
  esac
  reaped=$((reaped + 1))
  printf 'RUN_MOSH_SERVER_REAPED pid=%s start=%s state=%s signal=%s\n' "$pid" "$start" "$state" "$signal"
}

status=0
found=()
reaped=0
while IFS= read -r line; do found+=("$line"); done < <(run_owned_servers)
for line in ${found[@]+"${found[@]}"}; do
  read -r pid start state <<<"$line"
  reap "$pid" "$start" "$state" || status=1
done
# The assertion: nothing that names this run may outlive its cleanup.
while IFS= read -r line; do
  read -r pid start state <<<"$line"
  printf 'RUN_MOSH_SERVER_REMAINS pid=%s start=%s state=%s\n' "$pid" "$start" "$state"
  status=1
done < <(run_owned_servers)
if [[ "$status" -eq 0 ]]; then
  printf 'RUN_MOSH_SERVERS_ABSENT reaped=%s names=%s\n' "$reaped" "$name_list"
fi
exit "$status"
REMOTE_MOSH_REAP
}

# reap_run_mosh_servers HOST USER NAME...: ends every mosh-server of USER on
# HOST whose command line names one of this run's tmux sessions (see above):
# SIGCONT, SIGTERM, about three seconds, then SIGKILL, each signal only after
# re-proving the PID's start tick. Returns non-zero if any survives, which a
# lane reports as a cleanup failure. Run it after the run's tmux sessions are
# gone, so a running server has already been asked to exit by its client.
reap_run_mosh_servers() {
  local host="$1" user="$2"
  shift 2
  validate_run_owned_names reap_run_mosh_servers "$user" "$@" || return 1
  mosh_server_reap_script | control_ssh "$host" bash -s -- "$user" "$@"
}

# The remote half of kill_run_tmux_sessions: `bash -s -- USER NAME...`.
tmux_session_reap_script() {
  run_owned_remote_prelude
  cat <<'REMOTE_TMUX_REAP'
user="$1"
shift
require_fixture_user "$user"
require_run_names "$@"
names=("$@")
# The tmux USER's login shell runs, so the listing reaches the server the
# run's sessions live on. The chaos fixture's shell puts its own tmux 3.6a
# first on PATH (remote/provision.sh); the system tmux 3.4 cannot talk to that
# server and answers "server exited unexpectedly" every time, so a live
# session there could never be listed or reaped.
fixture_root="${TESSERA_REAP_FIXTURE_ROOT:-/opt/tessera-fixture}"
tmux_bin=tmux
if [[ "$(getent passwd "$user" 2>/dev/null | cut -d: -f7)" == "$fixture_root/bin/tessera-chaos-shell" ]]; then
  tmux_bin="$fixture_root/tmux-3.6a/bin/tmux"
fi
owned() {
  local name
  for name in "${names[@]}"; do
    if [[ "$1" == "$name" || "$1" == "$name"-* ]]; then
      return 0
    fi
  done
  return 1
}
# list_sessions: sets `listing` to USER's session names. A user with no tmux
# server (no socket, or a stale one) has none; any other failure is reported
# and fails the cleanup, or a broken runuser or tmux would read as done. A
# server exiting after its last session went can refuse a moment: retry.
list_sessions() {
  local attempt=0 status
  while :; do
    status=0
    listing="$(runuser -u "$user" -- "$tmux_bin" list-sessions -F '#{session_name}' 2>&1)" || status=$?
    [[ "$status" -ne 0 ]] || return 0
    case "$listing" in
      "no server running on "*|"error connecting to "*"(No such file or directory)"*)
        listing=''
        return 0 ;;
    esac
    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 3 ]]; then
      printf 'RUN_TMUX_LIST_FAILED status=%s output=%s\n' "$status" "$(printf '%s' "$listing" | tr '\n' ' ' | cut -c1-200)"
      return 1
    fi
    sleep 0.2
  done
}
status=0
killed=0
list_sessions || exit 1
while IFS= read -r session; do
  [[ -n "$session" ]] || continue
  owned "$session" || continue
  # A view in a group can vanish with its owner; the listing below decides.
  runuser -u "$user" -- "$tmux_bin" kill-session -t "=$session" 2>/dev/null || true
  printf 'RUN_TMUX_SESSION_KILLED name=%s\n' "$session"
  killed=$((killed + 1))
done <<<"$listing"
list_sessions || exit 1
while IFS= read -r session; do
  [[ -n "$session" ]] || continue
  owned "$session" || continue
  printf 'RUN_TMUX_SESSION_REMAINS name=%s\n' "$session"
  status=1
done <<<"$listing"
if [[ "$status" -eq 0 ]]; then
  printf 'RUN_TMUX_SESSIONS_ABSENT killed=%s\n' "$killed"
fi
exit "$status"
REMOTE_TMUX_REAP
}

# kill_run_tmux_sessions HOST USER NAME...: kills every tmux session of USER
# on HOST named NAME or NAME-*, so the `-view` session a mosh visible client
# groups with each owner goes too, then verifies none remains.
kill_run_tmux_sessions() {
  local host="$1" user="$2"
  shift 2
  validate_run_owned_names kill_run_tmux_sessions "$user" "$@" || return 1
  tmux_session_reap_script | control_ssh "$host" bash -s -- "$user" "$@"
}

# reap_run_fixture_sessions HOST USER NAME...: the run's tmux sessions, then
# its mosh-servers. Non-zero if either survives.
reap_run_fixture_sessions() {
  local status=0
  kill_run_tmux_sessions "$@" || status=1
  reap_run_mosh_servers "$@" || status=1
  return "$status"
}

# The remote half of end_run_processes: `bash -s -- USER COMM NAME...`.
run_process_reap_script() {
  run_owned_remote_prelude
  cat <<'REMOTE_PROCESS_REAP'
user="$1"
want="$2"
shift 2
require_fixture_user "$user"
[[ "$want" == @any || "$want" =~ ^[A-Za-z0-9_.+-]{1,15}$ ]] || exit 2
[[ "$want" != mosh-server && "$want" != tmux* ]] || exit 2
require_run_names "$@"
names=("$@")
name_list="$*"

# owned_by_run PID: USER's process itself, or an ancestor below the nearest
# tmux process, names this run. The walk never passes a tmux process: a tmux
# server's command line can repeat the new-session that started it, a run's
# names included, and every other run's panes descend from it too.
owned_by_run() {
  local pid="$1" steps=0 comm euid state ppid start
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$steps" -lt 64 ]]; do
    read_comm "$pid" || return 1
    [[ "$comm" != tmux* ]] || return 1
    if read_euid "$pid" && [[ "$euid" == "$uid" ]] && names_this_run "$pid"; then
      return 0
    fi
    read_stat "$pid" || return 1
    pid="$ppid"
    steps=$((steps + 1))
  done
  return 1
}

# Prints "PID START STATE COMM" for each matching process of USER. tmux
# processes are never signalled (a session's own kill detaches its clients),
# nor mosh-servers (reap_run_mosh_servers proves and ends those).
run_owned_processes() {
  local dir pid comm euid state ppid start
  for dir in "$proc"/[0-9]*; do
    pid="${dir##*/}"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] || continue
    read_comm "$pid" || continue
    [[ "$comm" != tmux* && "$comm" != mosh-server ]] || continue
    [[ "$want" == @any || "$comm" == "$want" ]] || continue
    read_euid "$pid" && [[ "$euid" == "$uid" ]] || continue
    read_stat "$pid" || continue
    [[ "$state" != Z && "$state" != X ]] || continue
    owned_by_run "$pid" || continue
    printf '%s %s %s %s\n' "$pid" "$start" "$state" "$comm"
  done
}

pids=()
starts=()
states=()
comms=()
sents=()
while IFS= read -r line; do
  read -r pid start state comm <<<"$line"
  pids+=("$pid")
  starts+=("$start")
  states+=("$state")
  comms+=("$comm")
  sents+=("")
done < <(run_owned_processes)
count=${#pids[@]}

# signal_all SIGNAL: each process still the same one gets SIGNAL, recorded.
signal_all() {
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    if alive "${pids[$i]}" "${starts[$i]}"; then
      kill -"$1" "${pids[$i]}" 2>/dev/null || true
      sents[$i]="${sents[$i]:+${sents[$i]},}$1"
    fi
    i=$((i + 1))
  done
}
any_alive() {
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    if alive "${pids[$i]}" "${starts[$i]}"; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

# Continue first (a stopped process keeps TERM pending), then TERM all of
# them, wait about three seconds together, and KILL what remains.
signal_all CONT
signal_all TERM
waited=0
while any_alive && [[ "$waited" -lt 30 ]]; do
  sleep 0.1
  waited=$((waited + 1))
done
if any_alive; then
  signal_all KILL
  waited=0
  while any_alive && [[ "$waited" -lt 20 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
fi
status=0
ended=0
i=0
while [[ "$i" -lt "$count" ]]; do
  sent="${sents[$i]}"
  if alive "${pids[$i]}" "${starts[$i]}"; then
    printf 'RUN_PROCESS_SURVIVED pid=%s start=%s comm=%s sent=%s\n' "${pids[$i]}" "${starts[$i]}" "${comms[$i]}" "${sent:-none}"
    status=1
  else
    case ",$sent," in
      *,KILL,*) signal=KILL ;;
      *,TERM,*) signal=TERM ;;
      *) signal='' ;;
    esac
    if [[ -n "$signal" ]]; then
      printf 'RUN_PROCESS_ENDED pid=%s start=%s comm=%s state=%s signal=%s\n' "${pids[$i]}" "${starts[$i]}" "${comms[$i]}" "${states[$i]}" "$signal"
      ended=$((ended + 1))
    else
      printf 'RUN_PROCESS_GONE pid=%s start=%s comm=%s sent=%s\n' "${pids[$i]}" "${starts[$i]}" "${comms[$i]}" "${sent:-none}"
    fi
  fi
  i=$((i + 1))
done
while IFS= read -r line; do
  read -r pid start state comm <<<"$line"
  printf 'RUN_PROCESS_REMAINS pid=%s start=%s comm=%s state=%s\n' "$pid" "$start" "$comm" "$state"
  status=1
done < <(run_owned_processes)
if [[ "$status" -eq 0 ]]; then
  printf 'RUN_PROCESSES_ABSENT comm=%s ended=%s names=%s\n' "$want" "$ended" "$name_list"
fi
exit "$status"
REMOTE_PROCESS_REAP
}

# end_run_processes HOST USER COMM NAME...: ends USER's processes on HOST
# named COMM (or any command, for @any) that are, or descend from, a process
# whose command line names this run by the rule above; the walk up stops at
# any tmux process. Each is continued, terminated, and killed after about
# three seconds, every signal after re-proving its PID's start tick; a
# survivor makes it return non-zero. tmux processes and mosh-servers are
# never signalled here. This is how a lane ends a helper that carries no
# name of its own (htop under a run's scenario) or one it named (a FIFO
# keeper started with `exec -a <name>-...`), without pkill's account-wide
# reach.
end_run_processes() {
  local host="$1" user="$2" comm="$3"
  shift 3
  validate_run_owned_names end_run_processes "$user" "$@" || return 1
  if [[ "$comm" != @any && ! "$comm" =~ ^[A-Za-z0-9_.+-]{1,15}$ ]] \
    || [[ "$comm" == mosh-server || "$comm" == tmux* ]]; then
    printf 'end_run_processes: refusing command name %s\n' "$comm" >&2
    return 1
  fi
  run_process_reap_script | control_ssh "$host" bash -s -- "$user" "$comm" "$@"
}

# describe_fixture_mosh_servers HOST USER: a read-only inventory of USER's
# mosh-servers on HOST (state, age, and the tessera names their command lines
# carry) for a refusal message. It never signals anything.
describe_fixture_mosh_servers() {
  control_ssh "$1" bash -s -- "$2" <<'REMOTE_MOSH_INVENTORY'
for pid in $(pgrep -u "$1" -x mosh-server 2>/dev/null); do
  state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
  age="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  words="$(tr -c 'A-Za-z0-9_./-' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -E '^(/tmp/)?tessera[-_]' | sort -u | tr '\n' ' ' || true)"
  printf 'fixture mosh-server pid=%s state=%s age=%ss names=%s\n' "$pid" "${state:-?}" "${age:-?}" "${words:-none}"
done
REMOTE_MOSH_INVENTORY
}
