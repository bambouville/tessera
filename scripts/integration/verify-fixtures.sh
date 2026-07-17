#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

load_fixture_config
ensure_fixture_credentials

verify_one() {
  local role="$1"
  local host="$2"
  local expected_tmux="$3"
  local identity tmux_version no_tmux_path echo_response

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
