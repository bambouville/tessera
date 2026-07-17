#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-programmatic-tests.sh RUN_DIR\n' >&2; exit 2; }

load_fixture_config
ensure_fixture_credentials
require_command jq
require_command sftp

RESULT_DIR="$RUN_DIR/programmatic"
LOG_DIR="$RESULT_DIR/logs"
RESULTS="$RESULT_DIR/results.json"
mkdir -p "$LOG_DIR"
printf '[]\n' >"$RESULTS"

failed=0

# The child Xcode lanes share one purpose-built simulator and DerivedData.
# Avoid three shutdown/boot cycles; this parent owns the final cleanup.
export TESSERA_KEEP_TEST_SIM_BOOTED=1
cleanup_programmatic_simulator() {
  if [[ -f "$FIXTURE_STATE/simulator_udid" ]]; then
    local udid
    IFS= read -r udid <"$FIXTURE_STATE/simulator_udid"
    [[ -n "$udid" ]] && xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup_programmatic_simulator EXIT

record_result() {
  local id="$1"
  local verdict="$2"
  local duration="$3"
  local log_path="$4"
  local temporary="$RESULTS.tmp"
  jq \
    --arg id "$id" \
    --arg verdict "$verdict" \
    --argjson duration "$duration" \
    --arg log "${log_path#$RUN_DIR/}" \
    '. + [{id: $id, verdict: $verdict, duration_seconds: $duration, log: $log}]' \
    "$RESULTS" >"$temporary" && mv "$temporary" "$RESULTS"
}

run_case() {
  local id="$1"
  shift
  local log_path="$LOG_DIR/$id.log"
  local started ended verdict
  started="$(date +%s)"
  printf '[programmatic] %-36s' "$id"
  if "$@" >"$log_path" 2>&1; then
    verdict=pass
    printf ' PASS\n'
  else
    verdict=fail
    failed=1
    printf ' FAIL (%s)\n' "${log_path#$RUN_DIR/}"
  fi
  ended="$(date +%s)"
  record_result "$id" "$verdict" "$((ended - started))" "$log_path"
}

test_probe_lines() {
  local host="$1"
  local output count
  output="$(fixture_ssh "$host" /usr/local/bin/tessera-fixture-probe lines --count 25)" || return
  count="$(printf '%s\n' "$output" | grep -c '^TESSERA_ROW_')"
  [[ "$count" == 25 ]]
  [[ "$output" == *TESSERA_ROW_00001* ]]
  [[ "$output" == *TESSERA_ROW_00025* ]]
}

test_sftp_listing() {
  local host="$1"
  local tag="$2"
  local batch="$RESULT_DIR/sftp-$tag.batch"
  local output="$RESULT_DIR/sftp-$tag.txt"
  printf 'ls -la fixture-files\nquit\n' >"$batch"
  sftp \
    -q -b "$batch" \
    -i "$FIXTURE_STATE/client_ed25519" \
    -P "$TESSERA_FIXTURE_APP_PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_APP_KNOWN_HOSTS" \
    "$TESSERA_FIXTURE_USER@$host" >"$output"
  grep -q 'visible.txt' "$output"
  grep -q 'testfile' "$output"
  grep -q '.hidden' "$output"
}

test_tmux_capture() {
  local host="$1"
  local session="tessera-it-$$-$RANDOM"
  local output status=0
  fixture_ssh "$host" tmux new-session -d -s "$session" || return
  fixture_ssh "$host" tmux set-option -t "$session" remain-on-exit on || status=1
  fixture_ssh "$host" tmux respawn-pane -k -t "$session:0.0" \
    /usr/local/bin/tessera-fixture-probe lines --count 40 || status=1
  sleep 0.5
  output="$(fixture_ssh "$host" tmux capture-pane -p -t "$session:0.0")" || status=1
  [[ "$output" == *TESSERA_ROW_00040* ]] || status=1
  fixture_ssh "$host" tmux kill-session -t "$session" >/dev/null 2>&1 || true
  return "$status"
}

test_tmux_session_isolation() {
  local host="$1"
  local prefix="tessera-isolation-$$-$RANDOM"
  local session_a="${prefix}-a"
  local session_b="${prefix}-b"
  local before after_b after_a status=0

  fixture_ssh "$host" tmux new-session -d -s "$session_a" -c /home/"$TESSERA_FIXTURE_USER"/fixture-files || return
  fixture_ssh "$host" tmux new-window -d -t "$session_a" -n alpha -c /home/"$TESSERA_FIXTURE_USER"/fixture-files/subdirectory || status=1
  fixture_ssh "$host" tmux new-session -d -s "$session_b" -c /home/"$TESSERA_FIXTURE_USER" || status=1
  fixture_ssh "$host" tmux new-window -d -t "$session_b" -n beta -c /tmp || status=1

  before="$(fixture_ssh "$host" \
    "tmux list-windows -t $session_a -F '#S:#W:#{pane_current_path}'")" || status=1
  fixture_ssh "$host" tmux select-window -t "$session_b:beta" || status=1
  fixture_ssh "$host" tmux rename-window -t "$session_b:beta" beta-renamed || status=1
  after_b="$(fixture_ssh "$host" \
    "tmux list-windows -t $session_b -F '#S:#W:#{pane_current_path}:#{window_active}'")" || status=1
  after_a="$(fixture_ssh "$host" \
    "tmux list-windows -t $session_a -F '#S:#W:#{pane_current_path}'")" || status=1

  [[ "$before" == "$after_a" ]] || status=1
  [[ "$after_a" == *"$session_a:alpha:/home/$TESSERA_FIXTURE_USER/fixture-files/subdirectory"* ]] || status=1
  [[ "$after_b" == *"$session_b:beta-renamed:/tmp:1"* ]] || status=1

  fixture_ssh "$host" tmux kill-session -t "$session_a" >/dev/null 2>&1 || true
  fixture_ssh "$host" tmux kill-session -t "$session_b" >/dev/null 2>&1 || true
  return "$status"
}

test_no_tmux_contract() {
  local host="$1"
  local output
  if output="$(ssh \
    -i "$FIXTURE_STATE/client_ed25519" \
    -p "$TESSERA_FIXTURE_APP_PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_APP_KNOWN_HOSTS" \
    "$TESSERA_FIXTURE_NOTMUX_USER@$host" \
    'command -v tmux')"; then
    return 1
  fi
  [[ -z "$output" ]]
}

test_fixture_echo_target() {
  local host="$1"
  [[ "$(fixture_ssh "$host" curl -fsS http://127.0.0.1:18080/probe)" == TESSERA_FORWARD_OK ]]
}

test_mosh_orphan_budget() {
  local host="$1"
  local count
  sleep 1
  count="$(control_ssh "$host" pgrep -u "$TESSERA_FIXTURE_USER" -c mosh-server 2>/dev/null || true)"
  count="${count:-0}"
  [[ "$count" =~ ^[0-9]+$ ]]
  (( count <= 1 ))
}

run_case fixture_contract "$HERE/verify-fixtures.sh"
run_case ssh_pty_stable test_probe_lines "$TESSERA_FIXTURE_STABLE_HOST"
run_case ssh_pty_chaos test_probe_lines "$TESSERA_FIXTURE_CHAOS_HOST"
run_case tmux_capture_3_4 test_tmux_capture "$TESSERA_FIXTURE_STABLE_HOST"
run_case tmux_capture_3_6a test_tmux_capture "$TESSERA_FIXTURE_CHAOS_HOST"
run_case tmux_isolation_3_4 test_tmux_session_isolation "$TESSERA_FIXTURE_STABLE_HOST"
run_case tmux_isolation_3_6a test_tmux_session_isolation "$TESSERA_FIXTURE_CHAOS_HOST"
run_case tmux_missing_stable test_no_tmux_contract "$TESSERA_FIXTURE_STABLE_HOST"
run_case tmux_missing_chaos test_no_tmux_contract "$TESSERA_FIXTURE_CHAOS_HOST"
run_case forwarding_target_stable test_fixture_echo_target "$TESSERA_FIXTURE_STABLE_HOST"
run_case forwarding_target_chaos test_fixture_echo_target "$TESSERA_FIXTURE_CHAOS_HOST"
run_case sftp_stable test_sftp_listing "$TESSERA_FIXTURE_STABLE_HOST" stable
run_case sftp_chaos test_sftp_listing "$TESSERA_FIXTURE_CHAOS_HOST" chaos
run_case agent_integration_scripts \
  "$HERE/run-agent-integration-script-tests.sh" "$RUN_DIR"
run_case app_offline_oracles "$HERE/run-offline-oracle-tests.sh" "$RUN_DIR"
run_case tmux_control_pane_commands \
  swift test --package-path "$HERE/../../Packages/TmuxControl" --filter PaneCommandTests
run_case app_live_transports_tmux_files_forwarding \
  "$HERE/run-app-transport-tests.sh" "$RUN_DIR"
# Credentialed, local-provider gate. It is deliberately opt-in because CI and
# the disposable VPS fixtures do not carry Claude/Codex credentials. When
# enabled it uses a private tmux socket and does not touch normal shell config.
if [[ "${TESSERA_RUN_REAL_AGENT_E2E:-0}" == 1 ]]; then
  run_case real_agent_center_state_transitions \
    "$HERE/run-real-agent-e2e.sh"
else
  note "skipping real Agent Center lane (set TESSERA_RUN_REAL_AGENT_E2E=1)"
fi
# Jump-host (ProxyJump) lane — opt-in: runs only when the disposable
# two-droplet jump test bed is configured (see jump/README section in
# scripts/integration/README.md). Verifies chained SSH, per-hop TOFU and
# auth attribution, multi-hop, SFTP + port forwarding through the chain,
# and the mosh-UDP-blocked SSH fallback.
if [[ -n "${TESSERA_JUMP_CONFIG:-}" || -f "$HERE/jump/jump.env" ]]; then
  run_case app_jump_host_transports \
    "$HERE/jump/run-jump-transport-tests.sh"
else
  note "skipping jump-host lane (no scripts/integration/jump/jump.env)"
fi
run_case app_terminal_scroll_wiring \
  "$HERE/run-scroll-harness-tests.sh" "$RUN_DIR" --without-building
run_case mosh_orphan_budget_stable test_mosh_orphan_budget "$TESSERA_FIXTURE_STABLE_HOST"
run_case mosh_orphan_budget_chaos test_mosh_orphan_budget "$TESSERA_FIXTURE_CHAOS_HOST"

exit "$failed"
