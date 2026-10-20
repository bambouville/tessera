#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-programmatic-tests.sh RUN_DIR\n' >&2; exit 2; }
if [[ -z "${TESSERA_INTEGRATION_SIMULATOR_RUN_ID:-}" ]]; then
  export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="programmatic-$(basename "$RUN_DIR")-$$"
fi

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

# One Debug build serves every Xcode lane below (a no-op when the suite
# runner already built and exported TESSERA_INTEGRATION_PREBUILT=1).
ensure_integration_build "$RESULT_DIR/build-for-testing.log"

# Simulator budget: at most two run-scoped devices are booted at any time
# (the user's persistent iPad and iPhone stay booted beside them). Creating
# and booting a device costs roughly a minute, so lanes are grouped around
# a shared iPad instead of each lane creating its own:
#   - XCTest-hosted unit lanes share one iPad (they already coexist in the
#     ordinary full unit-test run);
#   - UI harness lanes share a second, fresh iPad; their private secondary
#     phones are always deleted inside the lane;
#   - the three Nearby-bootstrap scenarios share one origin/recipient pair
#     and reinstall the app between scenarios.
# TESSERA_KEEP_TEST_SIM_BOOTED=1 tells a lane to leave `simulator_udid` in
# place for the next lane; release_shared_simulator ends a group. The parent
# trap remains the final cleanup backstop for interrupted children.
export TESSERA_KEEP_TEST_SIM_BOOTED=0
release_shared_simulator() {
  if ! delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid"; then
    printf 'run-programmatic-tests.sh: shared simulator survived its group; the exit trap will retry\n' >&2
  fi
}
cleanup_programmatic_simulator() {
  local status=$?
  fail_closed_status "$status" || status=1
  local cleanup_status=0
  local udid_file
  for udid_file in \
    "$SIMULATOR_STATE/simulator_udid" \
    "$SIMULATOR_STATE/iphone_keyboard_simulator_udid" \
    "$SIMULATOR_STATE/ipad_keyboard_simulator_udid" \
    "$SIMULATOR_STATE/continuity_iphone_simulator_udid" \
    "$SIMULATOR_STATE/touch_simulator_udid" \
    "$SIMULATOR_STATE/bootstrap_origin_simulator_udid" \
    "$SIMULATOR_STATE/bootstrap_recipient_simulator_udid"; do
    # Attempt every tracked device. A successful lane must not conceal one
    # orphaned simulator, while a primary test failure remains the reported
    # exit status even if teardown also fails.
    if ! delete_owned_test_simulator "$udid_file"; then
      printf 'run-programmatic-tests.sh: failed to delete owned simulator recorded at %s\n' \
        "$udid_file" >&2
      cleanup_status=1
    fi
  done
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    status=$cleanup_status
  fi
  trap - EXIT
  exit "$status"
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

# macOS /bin/bash is 3.2, which exits 0 from a `set -u` unbound-variable or
# syntax fault whenever the script has an EXIT trap installed (every lane
# script does, for simulator cleanup). The exit status therefore cannot tell
# a lane that never reached its tests from one that passed - the live
# transports lane recorded PASS for three weeks that way - so the log is
# checked for the shell's own fault signature as well.
lane_log_shows_shell_fault() {
  grep -Eq ': line [0-9]+: .*(unbound variable|syntax error)' "$1"
}

run_case() {
  local id="$1"
  shift
  local log_path="$LOG_DIR/$id.log"
  local started ended verdict
  started="$(date +%s)"
  printf '[programmatic] %-36s' "$id"
  if "$@" >"$log_path" 2>&1 && ! lane_log_shows_shell_fault "$log_path"; then
    verdict=pass
    printf ' PASS\n'
  else
    verdict=fail
    failed=1
    if lane_log_shows_shell_fault "$log_path"; then
      printf ' FAIL (shell fault, see %s)\n' "${log_path#$RUN_DIR/}"
    else
      printf ' FAIL (%s)\n' "${log_path#$RUN_DIR/}"
    fi
  fi
  ended="$(date +%s)"
  record_result "$id" "$verdict" "$((ended - started))" "$log_path"
}

# The native Android isolation case uses a disposable AVD and writes a temporary
# key plus an exact tmux fixture to the disposable VPS account. Do not infer
# consent from the normal fixture configuration: all three settings below must
# be explicit before this runner invokes that gate. A full integration result
# without the Android proof is deliberately non-green, but it is *unverified*,
# not a failed Android product run, when the required opt-in is absent.
record_android_native_isolation_unverified() {
  local id="android_native_tmux_render_isolation"
  local log_path="$LOG_DIR/$id.log"
  local reason="$1"

  printf '%s\n' "$reason" >"$log_path"
  record_result "$id" unverified 0 "$log_path"
  failed=1
  printf '[programmatic] %-36s UNVERIFIED (%s)\n' "$id" "${log_path#"$RUN_DIR"/}"
}

run_android_native_isolation_gate() {
  if [[ "${TESSERA_RUN_ANDROID_NATIVE_SSH_GATE:-0}" != 1 ]]; then
    record_android_native_isolation_unverified \
      'Android native tmux render-isolation gate was not enabled; set TESSERA_RUN_ANDROID_NATIVE_SSH_GATE=1, TESSERA_ANDROID_AGENT_CENTER_MOSH=1, and TESSERA_ANDROID_MOSH_OPENSSL_ROOT to a reviewed arm64 OpenSSL prefix.'
    return
  fi

  if [[ "${TESSERA_ANDROID_AGENT_CENTER_MOSH:-0}" != 1 ]]; then
    record_android_native_isolation_unverified \
      'Android native tmux render-isolation gate requires TESSERA_ANDROID_AGENT_CENTER_MOSH=1; the proof must cover mosh+tmux as well as SSH transports.'
    return
  fi

  if [[ -z "${TESSERA_ANDROID_MOSH_OPENSSL_ROOT:-}" ]]; then
    record_android_native_isolation_unverified \
      'Android native tmux render-isolation gate requires TESSERA_ANDROID_MOSH_OPENSSL_ROOT pointing to a reviewed arm64 OpenSSL prefix.'
    return
  fi

  run_case android_native_tmux_render_isolation \
    "$HERE/../android/run-native-ssh-gate.sh"
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

# One origin iPad + recipient iPhone pair for all three Nearby-bootstrap
# scenarios. Each scenario reinstalls the app on both devices, so scenario
# state never leaks; only the device creation and boot are shared. A pair
# that fails to come up is its own reported case, and the scenarios then
# fail fast rather than each spending a boot timeout.
bootstrap_origin_udid=''
bootstrap_recipient_udid=''
prepare_bootstrap_pair() {
  bootstrap_origin_udid="$(
    TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Bootstrap Origin" \
    TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="${TESSERA_BOOTSTRAP_ORIGIN_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB}" \
    TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/bootstrap_origin_simulator_udid" \
      "$HERE/ensure-test-simulator.sh" | tail -n 1
  )" || return 1
  bootstrap_recipient_udid="$(
    TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Bootstrap Recipient" \
    TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="${TESSERA_BOOTSTRAP_RECIPIENT_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}" \
    TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/bootstrap_recipient_simulator_udid" \
      "$HERE/ensure-test-simulator.sh" | tail -n 1
  )" || return 1
  [[ -n "$bootstrap_origin_udid" && -n "$bootstrap_recipient_udid" ]]
}

run_bootstrap_scenario() {
  local scenario="$1"
  [[ -n "$bootstrap_origin_udid" && -n "$bootstrap_recipient_udid" ]] || {
    printf 'nearby-bootstrap simulator pair is unavailable; see app_nearby_bootstrap_simulator_pair\n' >&2
    return 1
  }
  env \
    TESSERA_BOOTSTRAP_HARNESS_SCENARIO="$scenario" \
    TESSERA_BOOTSTRAP_ORIGIN_UDID="$bootstrap_origin_udid" \
    TESSERA_BOOTSTRAP_RECIPIENT_UDID="$bootstrap_recipient_udid" \
    "$HERE/run-bootstrap-network-harness-tests.sh" "$RUN_DIR" --without-building
}

release_bootstrap_pair() {
  local udid_file
  for udid_file in \
    "$SIMULATOR_STATE/bootstrap_recipient_simulator_udid" \
    "$SIMULATOR_STATE/bootstrap_origin_simulator_udid"; do
    if ! delete_owned_test_simulator "$udid_file"; then
      printf 'run-programmatic-tests.sh: bootstrap simulator survived; the exit trap will retry\n' >&2
    fi
  done
  bootstrap_origin_udid=''
  bootstrap_recipient_udid=''
}

run_case fixture_contract "$HERE/verify-fixtures.sh"
run_case ssh_pty_stable test_probe_lines "$TESSERA_FIXTURE_STABLE_HOST"
run_case ssh_pty_chaos test_probe_lines "$TESSERA_FIXTURE_CHAOS_HOST"
run_case tmux_capture_3_4 test_tmux_capture "$TESSERA_FIXTURE_STABLE_HOST"
run_case tmux_capture_3_6a test_tmux_capture "$TESSERA_FIXTURE_CHAOS_HOST"
run_case tmux_isolation_3_4 test_tmux_session_isolation "$TESSERA_FIXTURE_STABLE_HOST"
run_case tmux_isolation_3_6a test_tmux_session_isolation "$TESSERA_FIXTURE_CHAOS_HOST"
run_case tmux_window_ordering "$HERE/run-tmux-window-ordering-probe.sh"
run_case tmux_window_ordering_legacy "$HERE/run-tmux-legacy-ordering-probe.sh"
run_case tmux_missing_stable test_no_tmux_contract "$TESSERA_FIXTURE_STABLE_HOST"
run_case tmux_missing_chaos test_no_tmux_contract "$TESSERA_FIXTURE_CHAOS_HOST"
run_case forwarding_target_stable test_fixture_echo_target "$TESSERA_FIXTURE_STABLE_HOST"
run_case forwarding_target_chaos test_fixture_echo_target "$TESSERA_FIXTURE_CHAOS_HOST"
run_case sftp_stable test_sftp_listing "$TESSERA_FIXTURE_STABLE_HOST" stable
run_case sftp_chaos test_sftp_listing "$TESSERA_FIXTURE_CHAOS_HOST" chaos
run_case agent_integration_scripts \
  "$HERE/run-agent-integration-script-tests.sh" "$RUN_DIR"
run_case script_exit_traps_fail_closed /bin/bash "$HERE/run-fail-closed-script-tests.sh"
run_case fixture_run_ownership_reap /bin/bash "$HERE/run-fixture-reap-tests.sh"
run_case agent_host_native \
  bash "$HERE/run-agent-host-tests.sh" "$RUN_DIR"
run_case agent_host_security \
  bash "$HERE/run-agent-host-security-tests.sh" "$RUN_DIR"
run_case ssh_dependency_and_citadel_adapters \
  swift test --package-path "$HERE/../../Packages/Citadel"
run_case tmux_control_pane_commands \
  swift test --package-path "$HERE/../../Packages/TmuxControl" --filter PaneCommandTests
run_case tmux_control_compact_client_role \
  swift test --package-path "$HERE/../../Packages/TmuxControl" \
    --filter TmuxControllerTests/test_compact
run_case tmux_control_grid_authority \
  swift test --package-path "$HERE/../../Packages/TmuxControl" \
    --filter 'TmuxControlCoreTests|GridAuthorityTests'

# ---- XCTest-hosted unit lanes: one shared iPad ----
export TESSERA_KEEP_TEST_SIM_BOOTED=1
run_case app_offline_oracles \
  "$HERE/run-offline-oracle-tests.sh" "$RUN_DIR" --without-building
run_case app_sync_security_and_lifecycle_units \
  "$HERE/run-sync-unit-tests.sh" "$RUN_DIR" --without-building
run_case app_live_transports_tmux_files_forwarding \
  "$HERE/run-app-transport-tests.sh" "$RUN_DIR" --without-building
# Jump-host (ProxyJump) lane — opt-in: runs only when the disposable
# two-droplet jump test bed is configured (see jump/README section in
# scripts/integration/README.md). Verifies chained SSH, per-hop TOFU and
# auth attribution, multi-hop, SFTP + port forwarding through the chain,
# and the mosh-UDP-blocked SSH fallback.
if [[ -n "${TESSERA_JUMP_CONFIG:-}" || -f "$HERE/jump/jump.env" ]]; then
  run_case app_jump_host_transports \
    "$HERE/jump/run-jump-transport-tests.sh" --without-building
else
  note "skipping jump-host lane (no scripts/integration/jump/jump.env)"
fi
release_shared_simulator

# ---- UI harness lanes: a fresh shared iPad plus lane-private phones ----
run_case app_terminal_scroll_wiring \
  "$HERE/run-scroll-harness-tests.sh" "$RUN_DIR" --without-building
run_case app_compact_navigation_transition \
  "$HERE/run-compact-navigation-transition-tests.sh" "$RUN_DIR" --without-building
run_case app_continuity_descriptor_routes \
  "$HERE/run-continuity-harness-tests.sh" "$RUN_DIR" --without-building
release_shared_simulator
export TESSERA_KEEP_TEST_SIM_BOOTED=0

# ---- Lanes that own their own devices ----
run_case app_hardware_keyboard_focus \
  bash "$HERE/run-hardware-keyboard-tests.sh" "$RUN_DIR/programmatic/hardware-keyboard"
run_case app_keyboard_dismissal \
  bash "$HERE/run-keyboard-dismissal-tests.sh" "$RUN_DIR/programmatic/keyboard-dismissal"
run_case app_iphone_keyboard_and_tmux_viewport \
  "$HERE/run-iphone-keyboard-harness-tests.sh" "$RUN_DIR" --without-building
run_android_native_isolation_gate
# Credentialed, local-provider gate. It is deliberately opt-in because CI and
# the disposable VPS fixtures do not carry Claude/Codex credentials. When
# enabled it uses a private tmux socket and does not touch normal shell config.
if [[ "${TESSERA_RUN_REAL_AGENT_E2E:-0}" == 1 ]]; then
  run_case real_agent_center_state_transitions \
    "$HERE/run-real-agent-e2e.sh"
  run_case installed_tier_c_agent_adapters \
    "$HERE/run-installed-tier-c-agent-e2e.sh"
else
  note "skipping real Agent Center lane (set TESSERA_RUN_REAL_AGENT_E2E=1)"
fi
run_case mosh_orphan_budget_stable test_mosh_orphan_budget "$TESSERA_FIXTURE_STABLE_HOST"
run_case mosh_orphan_budget_chaos test_mosh_orphan_budget "$TESSERA_FIXTURE_CHAOS_HOST"

# ---- Nearby bootstrap: one device pair, three scenarios ----
run_case app_nearby_bootstrap_simulator_pair prepare_bootstrap_pair
run_case app_nearby_bootstrap_two_sim run_bootstrap_scenario transfer
run_case app_nearby_bootstrap_rejection_two_sim run_bootstrap_scenario rejection
run_case app_nearby_bootstrap_rejection_reversed_two_sim \
  run_bootstrap_scenario rejection-reversed
release_bootstrap_pair

script_completed=1
exit "$failed"
