#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

load_fixture_config
ensure_fixture_credentials
require_command openssl

verify_isolation_cleanup() {
  local output
  [[ "${VERIFY_ISOLATION_ACTIVE:-0}" == 1 ]] || return 0
  if ! output="$(fixture_ssh "$VERIFY_ISOLATION_HOST" \
      /usr/local/bin/tessera-fixture-probe tmux-isolation-cleanup \
      --session "$VERIFY_ISOLATION_SESSION")"; then
    note "failed to remove exact fixture verification session $VERIFY_ISOLATION_SESSION"
    return 1
  fi
  VERIFY_ISOLATION_CLEANUP_OUTPUT="$output"
  VERIFY_ISOLATION_ACTIVE=0
}

verify_one_exit_cleanup() {
  local status=$?
  # Armed only inside the background verify_one subshells, which never exit 0
  # on purpose while it is set; status 0 here is always an abort.
  fail_closed_status "$status" || status=1
  local cleanup_status=0
  trap - EXIT HUP INT TERM
  verify_isolation_cleanup || cleanup_status=1
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    status=$cleanup_status
  fi
  exit "$status"
}

verify_one() {
  local role="$1"
  local host="$2"
  local expected_tmux="$3"
  local identity tmux_version no_tmux_path echo_response
  local isolation_token isolation_session isolation_output cleanup_output

  note "verifying $role fixture at $host"
  control_ssh "$host" /usr/local/sbin/tessera-fixture-admin status

  identity="$(fixture_ssh "$host" /usr/local/bin/tessera-fixture-probe identity)"
  [[ "$identity" == *TESSERA_FIXTURE_IDENTITY_V1* ]] \
    || die "$role fixture PTY probe is unavailable"

  tmux_version="$(fixture_ssh "$host" tmux -V)"
  [[ "$tmux_version" == "$expected_tmux" ]] \
    || die "$role fixture expected '$expected_tmux', got '$tmux_version'"

  no_tmux_path="$(ssh \
    -i "$FIXTURE_STATE/client_ed25519" \
    -p "$TESSERA_FIXTURE_APP_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_APP_KNOWN_HOSTS" \
    "$TESSERA_FIXTURE_NOTMUX_USER@$host" \
    'command -v tmux || true')"
  [[ -z "$no_tmux_path" ]] || die "$role no-tmux user unexpectedly resolves $no_tmux_path"

  echo_response="$(fixture_ssh "$host" curl -fsS http://127.0.0.1:18080/)"
  [[ "$echo_response" == TESSERA_FORWARD_OK ]] \
    || die "$role forwarding target returned '$echo_response'"

  # Exercise the topology helper itself during fixture verification so a
  # probe/tmux formatting mismatch fails before the much slower app gate.
  # Nine URL-safe base64 characters retain 54 bits of the 56 random bits,
  # while keeping each P2b marker and the generated tmux session comfortably
  # inside the fixture's compact marker/session limits.
  isolation_token="$(openssl rand -base64 7 | tr '+/' '-_' | tr -d '=\n' | cut -c1-9)"
  [[ "$isolation_token" =~ ^[A-Za-z0-9_-]{9}$ ]] \
    || die "$role failed to generate a compact isolation token"
  isolation_session="tessera-fixture-$role-$isolation_token"
  VERIFY_ISOLATION_HOST="$host"
  VERIFY_ISOLATION_SESSION="$isolation_session"
  VERIFY_ISOLATION_CLEANUP_OUTPUT=''
  VERIFY_ISOLATION_ACTIVE=1
  trap verify_one_exit_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! isolation_output="$(fixture_ssh "$host" \
      /usr/local/bin/tessera-fixture-probe tmux-isolation-session \
      --session "$isolation_session" --token="$isolation_token" \
      --count 2 --hold-seconds 10 --heartbeat-seconds 0 \
      --columns 80 --rows 24)"; then
    die "$role tmux isolation topology probe failed"
  fi
  verify_isolation_cleanup || die "$role tmux isolation cleanup failed"
  cleanup_output="$VERIFY_ISOLATION_CLEANUP_OUTPUT"
  trap - EXIT HUP INT TERM
  [[ "$isolation_output" == *TESSERA_TMUX_ISOLATION_FIXTURE_V1* \
      && "$isolation_output" == *"\"session\": \"$isolation_session\""* \
      && "$cleanup_output" == *TESSERA_TMUX_ISOLATION_CLEANUP_V1* ]] \
    || die "$role tmux isolation topology contract is invalid"
}

verify_one stable "$TESSERA_FIXTURE_STABLE_HOST" 'tmux 3.4' &
stable_pid=$!
verify_one chaos "$TESSERA_FIXTURE_CHAOS_HOST" 'tmux 3.6a' &
chaos_pid=$!

status=0
wait "$stable_pid" || status=1
wait "$chaos_pid" || status=1
[[ $status -eq 0 ]] || die "fixture verification failed"

note "both fixtures passed SSH, tmux-version, no-tmux, forwarding-target, and probe checks"
script_completed=1
