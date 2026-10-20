#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || {
  printf 'usage: run-app-transport-tests.sh RUN_DIR [TEST_FILTER] [--without-building]\n' >&2
  exit 2
}
shift
# Class selection includes the D2 plain-client-latest and mixed-pair lanes.
TEST_FILTER=TesseraTests/RealHostTransportIntegrationTests
BUILD_ACTION=test
for argument in "$@"; do
  case "$argument" in
    --without-building) BUILD_ACTION=test-without-building ;;
    --*) printf 'unknown option: %s\n' "$argument" >&2; exit 2 ;;
    *) TEST_FILTER="$argument" ;;
  esac
done
BUILD_CONFIGURATION="${TESSERA_INTEGRATION_BUILD_CONFIGURATION:-Debug}"
if [[ "$BUILD_CONFIGURATION" != Debug ]]; then
  # The shared prebuilt product is Debug; any other configuration compiles
  # its own optimized test artifact here.
  BUILD_ACTION=test
fi

load_fixture_config
ensure_fixture_credentials
require_command base64
require_command jq
require_command openssl
require_command xcodebuild
require_command xcrun

udid=''
derived_data="$(integration_derived_data)"
result_bundle="$RUN_DIR/programmatic/real-host-transports.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"

password="$(fixture_password)"
config_json="$(
  jq -cn \
    --arg stableHost "$TESSERA_FIXTURE_STABLE_HOST" \
    --arg chaosHost "$TESSERA_FIXTURE_CHAOS_HOST" \
    --argjson port "$TESSERA_FIXTURE_APP_PORT" \
    --arg user "$TESSERA_FIXTURE_USER" \
    --arg password "$password" \
    --argjson echoPort 18080 \
    --argjson localForwardPort 39081 \
    '{stableHost: $stableHost, chaosHost: $chaosHost, port: $port, user: $user, password: $password, echoPort: $echoPort, localForwardPort: $localForwardPort}'
)"
config_b64="$(printf '%s' "$config_json" | base64 | tr -d '\n')"
isolation_run_id="ios-$(fixture_run_token)"
# Marker text must remain contiguous inside both halves of the compact tmux
# split. The full run id still owns fixture/session cleanup; this independent
# 54-bit URL-safe token keeps the specified TESSERA-<owner>-<token> marker at
# 21 columns, including the longest P2b owner name.
isolation_token="$(openssl rand -base64 7 | tr '+/' '-_' | tr -d '=\n' | cut -c1-9)"
[[ "$isolation_token" =~ ^[A-Za-z0-9_-]{9}$ ]] || {
  printf 'run-app-transport-tests.sh: failed to generate a compact isolation token\n' >&2
  exit 1
}
inline_isolation_session="tessera-ios-inline-$isolation_run_id"
mosh_isolation_session="tessera-ios-mosh-$isolation_run_id"
codex_scroll_test='test_liveCodexMouseSurvivesLifecycleOnBothTransports'
codex_scroll_session="tessera-ios-codex-$isolation_run_id"
# The mosh tests that otherwise name their sessions randomly (server loss,
# side channel, mosh viewport, continuation, mixed pair) put this prefix first, so this
# lane can prove those sessions and their mosh-servers are its own and reap
# them when XCTest dies before a test's own cleanup.
run_session_prefix="tessera-$isolation_run_id"
codex_scroll_root="${TESSERA_SCROLL_CODEX_FIXTURE_ROOT:-}"
codex_scroll_selected=0
if [[ "$TEST_FILTER" == *"$codex_scroll_test"* ]]; then
  [[ "$codex_scroll_root" =~ ^/tmp/tessera-codex-[A-Za-z0-9_-]+$ ]] \
    || die 'supply a run-owned offline Codex fixture with TESSERA_SCROLL_CODEX_FIXTURE_ROOT'
  codex_scroll_selected=1
fi
for session_name in "$inline_isolation_session" "$mosh_isolation_session" "$run_session_prefix"; do
  [[ "$session_name" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || {
    printf 'run-app-transport-tests.sh: generated isolation session is not cleanup-safe\n' >&2
    exit 1
  }
done

cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  local cleanup_status=0
  if ! control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
    "su -s /bin/sh '$TESSERA_FIXTURE_USER' -c '/usr/local/bin/tessera-fixture-probe tmux-isolation-cleanup --session $inline_isolation_session'" \
    >/dev/null 2>&1; then
    printf 'run-app-transport-tests.sh: failed to remove exact inline isolation fixture %s\n' \
      "$inline_isolation_session" >&2
    cleanup_status=1
  fi
  if ! control_ssh "$TESSERA_FIXTURE_CHAOS_HOST" \
    "su -s /bin/sh '$TESSERA_FIXTURE_USER' -c '/usr/local/bin/tessera-fixture-probe tmux-isolation-cleanup --session $mosh_isolation_session'" \
    >/dev/null 2>&1; then
    printf 'run-app-transport-tests.sh: failed to remove exact mosh isolation fixture %s\n' \
      "$mosh_isolation_session" >&2
    cleanup_status=1
  fi
  if [[ "$codex_scroll_selected" == 1 ]]; then
    if ! control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$codex_scroll_session" <<'REMOTE'
set -eu
for target in "$2-ssh" "$2-mosh"; do
  for session in "$target" "$target-view"; do
    if runuser -u "$1" -- tmux has-session -t "=$session" 2>/dev/null; then
      runuser -u "$1" -- tmux kill-session -t "=$session"
    fi
  done
done
REMOTE
    then cleanup_status=1; fi
  fi
  # The probe's cleanup above kills only each exact session, never the
  # `-view` a mosh visible client groups with it, and a crashed test leaves
  # its mosh-servers running with no client (or SIGSTOPped) forever. Reap
  # everything naming this run on both fixtures, and fail on any survivor.
  local reap_host reap_label
  for reap_label in stable chaos; do
    reap_host="$TESSERA_FIXTURE_STABLE_HOST"
    [[ "$reap_label" == stable ]] || reap_host="$TESSERA_FIXTURE_CHAOS_HOST"
    if ! reap_run_fixture_sessions "$reap_host" "$TESSERA_FIXTURE_USER" \
      "$inline_isolation_session" "$mosh_isolation_session" "$codex_scroll_session" "$run_session_prefix" \
      >"$RUN_DIR/programmatic/fixture-reap-$reap_label.txt" 2>&1; then
      printf 'run-app-transport-tests.sh: run-owned tmux sessions or mosh-servers survived on %s; see %s\n' \
        "$reap_label" "$RUN_DIR/programmatic/fixture-reap-$reap_label.txt" >&2
      cleanup_status=1
    fi
  done
  # The D2 plain peer's script and FIFO keeper name this run. Reap them
  # after the owned sessions detach, including when XCTest crashed.
  if ! end_run_processes "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_USER" @any "$run_session_prefix" \
    >"$RUN_DIR/programmatic/fixture-reap-plain-latest.txt" 2>&1; then
    cleanup_status=1
  fi
  if ! fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
    "find /tmp -maxdepth 1 \( -name '$run_session_prefix-latest-*.fifo' -o -name '$run_session_prefix-latest-*.script.log' \) -delete" \
    >/dev/null 2>&1; then cleanup_status=1; fi
  if [[ -n "$udid" ]]; then
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_REAL_HOST_CONFIG_B64 \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_RUN_PERFORMANCE_AUDIT \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_REAL_HOST_TMUX_ISOLATION_GATE \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_REAL_HOST_TMUX_ISOLATION_TOKEN \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_REAL_HOST_TMUX_INLINE_SESSION \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_REAL_HOST_TMUX_MOSH_SESSION \
      >/dev/null 2>&1 || true
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_REAL_HOST_RUN_SESSION_PREFIX \
      >/dev/null 2>&1 || true
    for key in TESSERA_CODEX_SCROLL_FIXTURE_ROOT TESSERA_CODEX_SCROLL_SESSION TESSERA_CODEX_SCROLL_PHASE; do
      xcrun simctl spawn "$udid" launchctl unsetenv "$key" >/dev/null 2>&1 || true
    done
  fi
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    if ! delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid"; then
      printf 'run-app-transport-tests.sh: failed to delete its owned simulator\n' >&2
      cleanup_status=1
    fi
  fi
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then status=$cleanup_status; fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"

xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_REAL_HOST_CONFIG_B64 "$config_b64"
# This programmatic lane is the canonical iOS owner-isolation acceptance
# harness. Keep the expensive live fixture case unavailable to incidental
# XCTest invocations that happen to provide connection credentials.
xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_REAL_HOST_TMUX_ISOLATION_GATE 1
xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_REAL_HOST_TMUX_ISOLATION_TOKEN "$isolation_token"
xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_REAL_HOST_TMUX_INLINE_SESSION "$inline_isolation_session"
xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_REAL_HOST_TMUX_MOSH_SESSION "$mosh_isolation_session"
xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_REAL_HOST_RUN_SESSION_PREFIX "$run_session_prefix"
if [[ "${TESSERA_RUN_PERFORMANCE_AUDIT:-0}" == 1 ]]; then
  xcrun simctl spawn "$udid" launchctl setenv TESSERA_RUN_PERFORMANCE_AUDIT 1
fi
if [[ "$codex_scroll_selected" == 1 ]]; then
  xcrun simctl spawn "$udid" launchctl setenv TESSERA_CODEX_SCROLL_FIXTURE_ROOT "$codex_scroll_root"
  xcrun simctl spawn "$udid" launchctl setenv TESSERA_CODEX_SCROLL_SESSION "$codex_scroll_session"
fi

xcode_settings=()
if [[ "$codex_scroll_selected" == 1 ]]; then
  # The lane retains its own native frames and state. Avoid a long sysdiagnose
  # after a failed fixture assertion before the owned-device cleanup can run.
  xcode_settings+=(-collect-test-diagnostics never)
fi
if [[ "$BUILD_CONFIGURATION" == Release ]]; then
  # Integration tests are DEBUG-gated. This retains Release optimization but
  # is an optimized test artifact, not a bit-for-bit App Store binary.
  xcode_settings+=(
    ONLY_ACTIVE_ARCH=YES
    ENABLE_TESTABILITY=YES
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'
  )
fi

phases=(initial)
if [[ "$codex_scroll_selected" == 1 ]]; then phases+=(restore); fi
for phase in "${phases[@]}"; do
  if [[ "$codex_scroll_selected" == 1 ]]; then
    xcrun simctl spawn "$udid" launchctl setenv TESSERA_CODEX_SCROLL_PHASE "$phase"
    result_bundle="$RUN_DIR/programmatic/real-host-transports-$phase.xcresult"
    rm -rf "$result_bundle"
  fi
integration_xcodebuild "$BUILD_ACTION" \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration "$BUILD_CONFIGURATION" \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$result_bundle" \
  -only-testing:"$TEST_FILTER" \
  ${xcode_settings[@]+"${xcode_settings[@]}"}
  if [[ "$codex_scroll_selected" == 1 ]]; then
    phase_tests="$RUN_DIR/programmatic/codex-$phase-tests.json"
    xcrun xcresulttool get test-results tests --path "$result_bundle" >"$phase_tests"
    jq -e --arg test "$codex_scroll_test" '
      [.. | objects | select(.nodeType? == "Test Case" and ((.name? // "") | contains($test)))]
      | length == 1 and .[0].result == "Passed"
    ' "$phase_tests" >/dev/null || die "Codex $phase must pass without skipping"
    if [[ "$phase" == initial ]]; then
      xcrun simctl terminate "$udid" com.bambouville.TesseraApp >/dev/null 2>&1 || true
      BUILD_ACTION=test-without-building
    fi
  fi
done

# XCTest treats a skipped test as a successful xcodebuild invocation. The
# render-ledger proof is a release gate, so require its individual result and
# the in-result success activity rather than accepting an incidental skip.
isolation_test='test_liveTmuxRenderSurfaceIsolationAcrossFourTransportsAndReconnects'
isolation_marker='TESSERA_IOS_TMUX_ISOLATION_OK ssh=1 sshTmux=1 mosh=1 moshTmux=1 reconnect=1 sideChannelDrop=1 dropped_foreign=0'
summary_json="$RUN_DIR/programmatic/real-host-transports-summary.json"
tests_json="$RUN_DIR/programmatic/real-host-transports-tests.json"
activities_json="$RUN_DIR/programmatic/real-host-transports-isolation-activities.json"
xcrun xcresulttool get test-results summary --path "$result_bundle" >"$summary_json"
xcrun xcresulttool get test-results tests --path "$result_bundle" >"$tests_json"

mixed_test='test_liveMixedSSHAndMoshTmuxTakeBacksWinLatestEachWay'
mixed_selected=0
if [[ "$TEST_FILTER" == TesseraTests ||
      "$TEST_FILTER" == TesseraTests/RealHostTransportIntegrationTests ||
      "$TEST_FILTER" == *"$mixed_test"* ]]; then
  mixed_selected=1
fi
if ! jq -e '.totalTestCount > 0 and .result == "Passed"' "$summary_json" >/dev/null; then
  printf 'run-app-transport-tests.sh: xcresult summary is not a passing test run\n' >&2
  cat "$summary_json" >&2
  exit 1
fi

# Require the D2 lane itself to pass when the class or that case is selected;
# an incidental XCTSkip or zero-test filter cannot prove the latest transfer.
latest_test='test_liveMoshTmuxTakeBackWinsLatestFromPlainClient'
if [[ "$TEST_FILTER" == TesseraTests ||
      "$TEST_FILTER" == TesseraTests/RealHostTransportIntegrationTests ||
      "$TEST_FILTER" == *"$latest_test"* ]]; then
  jq -e --arg test "$latest_test" '
    [.. | objects | select(.nodeType? == "Test Case" and ((.name? // "") | contains($test)))]
    | length == 1 and .[0].result == "Passed"
  ' "$tests_json" >/dev/null || die 'plain-client-latest XCTest must pass without skipping'
fi

# The mixed SSH+tmux / Mosh+tmux pair must also pass as an individual case.
if [[ "$mixed_selected" == 1 ]]; then
  jq -e --arg test "$mixed_test" '
    [.. | objects | select(.nodeType? == "Test Case" and ((.name? // "") | contains($test)))]
    | length == 1 and .[0].result == "Passed"
  ' "$tests_json" >/dev/null || die 'mixed-pair XCTest must pass without skipping'
fi

# Explicit focused filters are supported by this runner too. Require the
# isolation proof only when that case was selected; otherwise a successful
# diagnostics/unit smoke test incorrectly fails for omitting an unrelated case.
if [[ "$TEST_FILTER" != TesseraTests &&
      "$TEST_FILTER" != TesseraTests/RealHostTransportIntegrationTests &&
      "$TEST_FILTER" != *"$isolation_test"* ]]; then
  script_completed=1
  exit 0
fi

isolation_node_count="$(jq --arg test "$isolation_test" '
  [.. | objects | select(
    .nodeType? == "Test Case" and ((.name? // "") | contains($test))
  )] | length
' "$tests_json")"
if [[ "$isolation_node_count" != 1 ]]; then
  printf 'run-app-transport-tests.sh: expected one render-isolation XCTest case, found %s\n' \
    "$isolation_node_count" >&2
  cat "$tests_json" >&2
  exit 1
fi

isolation_result="$(jq -r --arg test "$isolation_test" '
  [.. | objects | select(
    .nodeType? == "Test Case" and ((.name? // "") | contains($test))
  )][0].result // "unknown"
' "$tests_json")"
if [[ "$isolation_result" != Passed ]]; then
  printf 'run-app-transport-tests.sh: render-isolation XCTest must pass, got %s\n' \
    "$isolation_result" >&2
  cat "$tests_json" >&2
  exit 1
fi

isolation_test_id="$(jq -er --arg test "$isolation_test" '
  [.. | objects | select(
    .nodeType? == "Test Case" and ((.name? // "") | contains($test))
  )][0].nodeIdentifier
' "$tests_json")"
xcrun xcresulttool get test-results activities \
  --path "$result_bundle" \
  --test-id "$isolation_test_id" >"$activities_json"
if ! jq -e --arg marker "$isolation_marker" '
  [.. | strings | select(. == $marker)] | length > 0
' "$activities_json" >/dev/null; then
  printf 'run-app-transport-tests.sh: render-isolation XCTest omitted its success marker activity\n' >&2
  cat "$activities_json" >&2
  exit 1
fi
# The guarded expansion matters: macOS /bin/bash is 3.2, where an empty
# array under `set -u` is an unbound-variable fault, and with the EXIT trap
# above installed that fault exits 0 - so every Debug run of this lane
# from 4ab2a7e until this fix crashed before xcodebuild and still passed.
script_completed=1
