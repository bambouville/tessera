#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

AI_VISUAL=1
PROVISION=0

usage() {
  cat <<'EOF'
Usage: run-integration-tests.sh [--no-ai-visual] [--provision]

Execution order is fixed:
  1. build the app and test bundles once for every lane;
  2. capture every visual case;
  3. launch exactly one aggregate Codex review in the background;
  4. run deterministic suites while Codex evaluates;
  5. join both lanes into report.json.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ai-visual) AI_VISUAL=0; shift ;;
    --provision) PROVISION=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

load_fixture_config
ensure_fixture_credentials

# The visual cases name their fixture sessions and processes after this run
# directory, and their cleanup proves ownership by those names alone: mint it
# like every lane's run token.
run_id="$(fixture_run_token)"
run_dir="$FIXTURE_OUT/$run_id"
run_simulator_state="$run_dir/simulators"
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="$run_id"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$run_simulator_state"

cleanup_test_simulator() {
  local status=$?
  fail_closed_status "$status" || status=1
  local cleanup_status=0
  local udid_file
  for udid_file in \
    "$run_simulator_state/simulator_udid" \
    "$run_simulator_state/visual_simulator_udid" \
    "$run_simulator_state/iphone_keyboard_simulator_udid" \
    "$run_simulator_state/ipad_keyboard_simulator_udid" \
    "$run_simulator_state/continuity_iphone_simulator_udid" \
    "$run_simulator_state/touch_simulator_udid" \
    "$run_simulator_state/bootstrap_origin_simulator_udid" \
    "$run_simulator_state/bootstrap_recipient_simulator_udid"; do
    # Do not stop at the first teardown problem: each record identifies an
    # independently owned disposable device. Preserve a real suite failure,
    # but turn an otherwise-green run red when any owned device survives.
    if ! delete_owned_test_simulator "$udid_file"; then
      printf 'run-integration-tests.sh: failed to delete owned simulator recorded at %s\n' \
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
trap cleanup_test_simulator EXIT

if [[ $PROVISION -eq 1 ]]; then
  "$HERE/provision-fixtures.sh" || exit 1
fi

mkdir -p "$run_dir"
printf '%s\n' "$run_id" >"$run_dir/run-id.txt"
note "run directory: $run_dir"
ensure_integration_build "$run_dir/build-for-testing.log" || exit 1

ai_pid=''
ai_exit=''
if [[ $AI_VISUAL -eq 1 ]]; then
  note "capturing every visual case before starting the aggregate reviewer"
  "$HERE/capture-visual-evidence.sh" "$run_dir" || exit 1
  note "starting one aggregate Codex review in the background"
  "$HERE/run-visual-review.sh" "$run_dir" >"$run_dir/visual/reviewer.log" 2>&1 &
  ai_pid=$!
fi

note "running deterministic suites"
"$HERE/run-programmatic-tests.sh" "$run_dir"
programmatic_exit=$?

if [[ -n "$ai_pid" ]]; then
  note "waiting for the aggregate Codex review"
  wait "$ai_pid"
  ai_exit=$?
fi

aggregate_args=(
  "$run_dir"
  --programmatic-exit "$programmatic_exit"
)
if [[ $AI_VISUAL -eq 1 ]]; then
  aggregate_args+=(--ai-requested --ai-exit "${ai_exit:-1}")
fi

# No `set -e` here: the aggregator's verdict is this runner's exit status.
python3 "$HERE/aggregate-results.py" "${aggregate_args[@]}"
aggregate_exit=$?
script_completed=1
exit "$aggregate_exit"
