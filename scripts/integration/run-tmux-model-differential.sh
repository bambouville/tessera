#!/usr/bin/env bash
# Differential lane for the tmux semantics model
# (Packages/TmuxControl/Tests/Support/TmuxSemanticsModel): replays the scenario
# scripts on real tmux on the disposable VPS fixtures and diffs every control
# client's stream against the model's replay of the same timeline.
#
#   scripts/integration/run-tmux-model-differential.sh --dry-run [SCENARIO...]
#   scripts/integration/run-tmux-model-differential.sh [--host stable|chaos|both] [SCENARIO...]
#
# SCENARIO is a name or path; the default is every scenario. --dry-run is
# host-free: it validates the scripts, builds and checks the payload, runs the
# model self-test, exports the model's nominal transcripts, proves the replay
# and diff on synthetic runner output, and prints the command a live run
# would use. A live run connects only to the configured
# disposable fixtures (fixture.env), as the app-facing fixture user.
#
# Environment:
#   TESSERA_TMUX_MODEL_BUILD_VERSIONS  upstream releases to build on the fixture,
#                                      e.g. "3.2 3.3a 3.4 3.6a" (VERSION[:SHA256])
#   TESSERA_TMUX_MODEL_SYSTEM_TMUX=0   skip the fixture's own tmux
#   TESSERA_TMUX_MODEL_SETTLE          seconds read after each action (0.3)
#   TESSERA_TMUX_MODEL_SCRATCH_PATH    SwiftPM --scratch-path
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

SCENARIO_DIR="$REPO_ROOT/Packages/TmuxControl/Tests/TmuxSemanticsModelTests/Scenarios"
HELPER="$HERE/tmux-model-differential.py"
dry_run=0
hosts=both
scenarios=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --host)
      [[ $# -ge 2 ]] || die "--host needs stable, chaos or both"
      hosts="$2"
      shift
      ;;
    -h|--help)
      sed -n '2,21p' "$0"
      script_completed=1
      exit 0
      ;;
    -*) die "unknown option $1" ;;
    *)
      if [[ -f "$1" ]]; then
        scenarios+=("$1")
      else
        [[ -f "$SCENARIO_DIR/$1.scenario" ]] || die "no scenario $1 in $SCENARIO_DIR"
        scenarios+=("$SCENARIO_DIR/$1.scenario")
      fi
      ;;
  esac
  shift
done
case "$hosts" in stable|chaos|both) ;; *) die "--host needs stable, chaos or both" ;; esac
if [[ ${#scenarios[@]} -eq 0 ]]; then
  for path in "$SCENARIO_DIR"/*.scenario; do
    scenarios+=("$path")
  done
fi
[[ ${#scenarios[@]} -gt 0 ]] || die "no scenarios in $SCENARIO_DIR"
require_command python3
require_command swift

run_id="tm$(date -u +%Y%m%d%H%M%S)-$$"
run_dir="$FIXTURE_OUT/tmux-model-differential/$run_id"
mkdir -p "$run_dir"
cleanup() {
  # Partial remote output is never evidence.
  rm -f "$run_dir"/*.partial
  note "tmux model differential output: $run_dir"
}
trap 'fail_closed_trap cleanup' EXIT

names=()
for path in "${scenarios[@]}"; do
  name="$(basename "$path" .scenario)"
  names+=("$name")
done
selected="$(IFS=,; printf '%s' "${names[*]}")"

note "validating ${#scenarios[@]} scenarios"
python3 "$HELPER" validate "${scenarios[@]}" | tee "$run_dir/validate.txt"
python3 "$HELPER" prepare --out "$run_dir" --run-id "$run_id" \
  --settle "${TESSERA_TMUX_MODEL_SETTLE:-0.3}" "${scenarios[@]}"
python3 "$run_dir/payload.py" --check-plan | tee "$run_dir/payload-check.json"
grep -q '"check": "ok"' "$run_dir/payload-check.json" || die "payload plan check failed"

# The runner's process, pseudo-terminal, reader and cleanup paths, against a
# stand-in binary (it refuses anything whose -V is not tmux-model-stub).
note "exercising the runner against the stub tmux"
if ! python3 "$run_dir/payload.py" --stub-tmux "$HERE/tmux-model-stub-tmux.py" --settle 0.05 \
    >"$run_dir/stub-run.json" 2>"$run_dir/stub-run.log"; then
  tail -20 "$run_dir/stub-run.log" >&2
  die "the runner failed against the stub tmux"
fi
python3 - "$run_dir/plan.json" "$run_dir/stub-run.json" <<'PY'
import json
import sys

plan, result = (json.load(open(path)) for path in sys.argv[1:3])
(run,) = result["runs"]
planned = {scenario["name"]: scenario for scenario in plan["scenarios"]}
ran = {scenario["name"]: scenario for scenario in run["scenarios"]}
assert set(ran) == set(planned) and ran, (sorted(ran), sorted(planned))
for name, scenario in ran.items():
    assert scenario["status"] == "ok" and scenario["cleanup"] == "verified", (name, scenario["status"], scenario["cleanup"])
    actions = planned[name]["actions"]
    assert [step["index"] for step in scenario["steps"]] == [step["index"] for step in actions], name
    for action, step in zip(actions, scenario["steps"]):
        if action["kind"] == "send":
            echoed = [line for line in step["lines"][action["client"]] if line.startswith("stub: ")]
            leftover = [key for key in scenario["ids"] if "{" + key + "}" in "".join(echoed)]
            assert len(echoed) == 1 and not leftover, (name, action["index"], step["lines"])
            lines = [line for line in step["lines"][action["client"]] if not line.startswith("stub: ")]
            guards = [line.split()[0] for line in lines if line.startswith(("%begin ", "%end ", "%error "))]
            if action["command"] == "display -p a ; display -p b":
                assert guards == ["%begin", "%end", "%begin", "%end"], lines
                assert [line for line in lines if not line.startswith("%")] == ["a", "b"], lines
            elif action["command"] == "display -p a ; select-window -t @999999 ; display -p c":
                assert guards == ["%begin", "%end", "%begin", "%error"], lines
                assert [line for line in lines if not line.startswith("%")] == ["a", "can't find window: @999999"], lines
            elif action["command"] == "display -p a ; bogus-command ; display -p c":
                assert guards == ["%begin", "%error"], lines
                assert [line for line in lines if not line.startswith("%")] == ["parse error: unknown command: bogus-command"], lines
print("stub run: %d scenarios, %d steps" % (len(ran), sum(len(s["steps"]) for s in ran.values())))
PY

swift_args=(test --package-path "$REPO_ROOT/Packages/TmuxControl")
if [[ -n "${TESSERA_TMUX_MODEL_SCRATCH_PATH:-}" ]]; then
  swift_args+=(--scratch-path "$TESSERA_TMUX_MODEL_SCRATCH_PATH")
fi

# run_model_tests FILTER EXPECTED_TESTS LOG [ENV=VALUE...]
run_model_tests() {
  local filter="$1" expected="$2" log="$3"
  shift 3
  if ! env "$@" swift "${swift_args[@]}" --filter "$filter" >"$log" 2>&1; then
    tail -40 "$log" >&2
    die "model tests failed (see $log)"
  fi
  # A filter that matches nothing, or a skipped env-gated test, is a false green.
  grep -Eq "Executed $expected tests?, with 0 failures" "$log" \
    || die "expected $expected executed model tests without skips or failures (see $log)"
}

note "model self-test and nominal export"
run_model_tests 'ScenarioFileTests/(testEveryScenarioHoldsInTheModel|testExportNominalTranscripts)$' 2 \
  "$run_dir/swift-export.log" \
  "TESSERA_TMUX_MODEL_EXPORT_DIR=$run_dir/model-nominal" "TESSERA_TMUX_MODEL_SCENARIOS=$selected"
exported="$(find "$run_dir/model-nominal" -name '*.json' | wc -l | tr -d ' ')"
[[ "$exported" -gt 0 ]] || die "the model exported no transcripts"
note "exported $exported nominal model transcripts"

# The comparator itself, host-free: runner-shaped output synthesized from the
# nominal transcripts must replay and diff as identical; one changed line must
# fail; a line that crossed a step boundary must pass with a note.
note "checking replay and diff on synthetic runner output"
synthetic="$run_dir/synthetic"
mkdir -p "$synthetic"
for variant in same mutated shifted; do
  python3 "$HELPER" synthesize --plan "$run_dir/plan.json" --nominal "$run_dir/model-nominal" \
    --variant "$variant" --out "$synthetic/real-$variant.json"
done
run_model_tests 'ScenarioFileTests/testReplayRecordedRuns$' 1 "$run_dir/swift-synthetic-replay.log" \
  "TESSERA_TMUX_MODEL_REPLAY_DIR=$synthetic"
expected_results=$(( ${#scenarios[@]} * 4 ))
# check_synthetic VARIANT EXPECTED_EXIT SAME_COUNT [REQUIRED_TEXT]
check_synthetic() {
  local variant="$1" expected_exit="$2" same_count="$3" required="${4:-}" actual_exit=0 same
  python3 "$HELPER" diff --plan "$run_dir/plan.json" --real "$synthetic/real-$variant.json" \
    --model "$synthetic/model-$variant.json" --report "$synthetic/diff-$variant.txt" \
    --json "$synthetic/diff-$variant.json" >/dev/null || actual_exit=$?
  [[ "$actual_exit" == "$expected_exit" ]] \
    || die "synthetic $variant diff exited $actual_exit, expected $expected_exit (see $synthetic/diff-$variant.txt)"
  same="$(python3 -c 'import json,sys; print(sum(r["status"] == "same" for r in json.load(open(sys.argv[1]))["results"]))' \
    "$synthetic/diff-$variant.json")"
  [[ "$same" == "$same_count" ]] \
    || die "synthetic $variant diff: $same identical scenario runs, expected $same_count"
  if [[ -n "$required" ]]; then
    grep -q "$required" "$synthetic/diff-$variant.txt" || die "synthetic $variant diff lacks '$required'"
  fi
}
check_synthetic same 0 "$expected_results"
check_synthetic mutated 1 "$(( expected_results - 1 ))" 'control stream differs'
check_synthetic shifted 0 "$expected_results" 'crossed step boundaries'
note "comparator check passed on $expected_results synthetic scenario runs"

runner_args=(--disposable-fixture)
for spec in ${TESSERA_TMUX_MODEL_BUILD_VERSIONS:-}; do
  runner_args+=(--build "$spec")
done
if [[ "${TESSERA_TMUX_MODEL_SYSTEM_TMUX:-1}" == 0 ]]; then
  runner_args+=(--no-system)
fi

if [[ "$dry_run" == 1 ]]; then
  note "dry run: a live run would execute, per fixture host:"
  note "  fixture_ssh HOST python3 - ${runner_args[*]} < $run_dir/payload.py"
  script_completed=1
  exit 0
fi

load_fixture_config
targets=()
case "$hosts" in
  stable) targets=(stable) ;;
  chaos) targets=(chaos) ;;
  both) targets=(stable chaos) ;;
esac

status=0
for target in "${targets[@]}"; do
  if [[ "$target" == stable ]]; then host="$TESSERA_FIXTURE_STABLE_HOST"; else host="$TESSERA_FIXTURE_CHAOS_HOST"; fi
  note "running ${#scenarios[@]} scenarios on the $target fixture"
  if ! fixture_ssh "$host" python3 - "${runner_args[@]}" \
      <"$run_dir/payload.py" >"$run_dir/real-$target.json.partial" 2>"$run_dir/runner-$target.log"; then
    tail -20 "$run_dir/runner-$target.log" >&2
    # The runner prints its JSON before exiting 2 for failed scenarios; keep
    # that evidence, fail the lane below.
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$run_dir/real-$target.json.partial" 2>/dev/null \
      || die "the $target runner failed (see $run_dir/runner-$target.log)"
    status=1
  fi
  mv "$run_dir/real-$target.json.partial" "$run_dir/real-$target.json"
done

note "replaying the recorded timelines on the model"
run_model_tests 'ScenarioFileTests/testReplayRecordedRuns$' 1 "$run_dir/swift-replay.log" \
  "TESSERA_TMUX_MODEL_REPLAY_DIR=$run_dir"

for target in "${targets[@]}"; do
  [[ -f "$run_dir/model-$target.json" ]] || die "no model replay for $target"
  if ! python3 "$HELPER" diff --plan "$run_dir/plan.json" --real "$run_dir/real-$target.json" \
      --model "$run_dir/model-$target.json" --report "$run_dir/diff-$target.txt" --json "$run_dir/diff-$target.json"; then
    status=1
  fi
done
[[ "$status" == 0 ]] || die "differences or failed scenarios; see $run_dir/diff-*.txt"
note "model and real tmux agree"
script_completed=1
