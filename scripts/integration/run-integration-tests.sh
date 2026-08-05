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
  1. capture every visual case;
  2. launch exactly one aggregate Codex review in the background;
  3. run deterministic suites while Codex evaluates;
  4. join both lanes into report.json.
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

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_dir="$FIXTURE_OUT/$run_id"
run_simulator_state="$run_dir/simulators"
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="$run_id"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$run_simulator_state"

cleanup_test_simulator() {
  local udid_file
  for udid_file in \
    "$run_simulator_state/simulator_udid" \
    "$run_simulator_state/visual_simulator_udid" \
    "$run_simulator_state/iphone_keyboard_simulator_udid" \
    "$run_simulator_state/continuity_iphone_simulator_udid" \
    "$run_simulator_state/touch_simulator_udid"; do
    delete_owned_test_simulator "$udid_file" || true
  done
}
trap cleanup_test_simulator EXIT

if [[ $PROVISION -eq 1 ]]; then
  "$HERE/provision-fixtures.sh" || exit 1
fi

mkdir -p "$run_dir"
printf '%s\n' "$run_id" >"$run_dir/run-id.txt"
note "run directory: $run_dir"

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

python3 "$HERE/aggregate-results.py" "${aggregate_args[@]}"
