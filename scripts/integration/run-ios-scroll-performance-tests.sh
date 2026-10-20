#!/usr/bin/env bash
# Host-free painter comparison. Live S1/S6 remains the transport acceptance gate.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?usage: run-ios-scroll-performance-tests.sh RUN_DIR}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
STATE="$RUN_DIR/simulator.udid"
udid=''; record_pid=''; launch_pid=''
stop_capture() {
  [[ -z "$udid" ]] || xcrun simctl terminate "$udid" com.bambouville.TesseraApp >/dev/null 2>&1 || true
  if [[ -n "$record_pid" ]]; then kill -INT "$record_pid" 2>/dev/null || true; wait "$record_pid" || true; record_pid=''; fi
  if [[ -n "$launch_pid" ]]; then wait "$launch_pid" || true; launch_pid=''; fi
}
cleanup() { stop_capture; delete_owned_test_simulator "$STATE"; }
trap 'fail_closed_trap cleanup' EXIT
ensure_integration_build "$RUN_DIR/build.log"
udid="$(TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Scroll Performance' TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$STATE" "$HERE/ensure-test-simulator.sh" | tail -n 1)"
xcrun simctl spawn "$udid" launchctl setenv TESSERA_VISUAL_CAPTURE 1
xcodebuild test-without-building -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$(integration_derived_data)" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testSetLandscapeOnly \
  -only-testing:TesseraTests/TerminalScrollbackOracleTests/testCoreGraphicsRowCacheMatchesUncachedPixelsAcrossMutations \
  -resultBundlePath "$RUN_DIR/painter.xcresult" >"$RUN_DIR/painter.log" 2>&1
xcrun simctl install "$udid" "$(integration_app_path)"
for variant in before after; do
  uncached=0; [[ "$variant" != before ]] || uncached=1
  xcrun simctl io "$udid" recordVideo --codec=h264 "$RUN_DIR/$variant.mov" >"$RUN_DIR/$variant-record.log" 2>&1 &
  record_pid=$!
  SIMCTL_CHILD_TESSERA_SCROLL_HARNESS=1 SIMCTL_CHILD_TESSERA_IDLE_REDRAW_HARNESS=benchmark \
  SIMCTL_CHILD_TESSERA_SCROLL_BENCHMARK=1 SIMCTL_CHILD_TESSERA_SCROLL_BENCHMARK_UNCACHED="$uncached" \
  xcrun simctl launch --terminate-running-process --console "$udid" com.bambouville.TesseraApp >"$RUN_DIR/$variant.log" 2>&1 &
  launch_pid=$!
  complete=0
  for _ in {1..120}; do
    if rg -q 'ScrollBenchmark.*stage=done' "$RUN_DIR/$variant.log"; then complete=1; break; fi
    sleep 0.5
  done
  [[ "$complete" == 1 ]] || die "scroll benchmark did not finish: $variant"
  container="$(xcrun simctl get_app_container "$udid" com.bambouville.TesseraApp data)"
  cp "$container/Documents/scroll-benchmark.json" "$RUN_DIR/$variant.json"
  xcrun simctl io "$udid" screenshot "$RUN_DIR/$variant.png"
  stop_capture
done
python3 - "$RUN_DIR" <<'PY'
import json, pathlib, statistics, sys
root = pathlib.Path(sys.argv[1])
summary = {}
for variant in ('before', 'after'):
    data = json.loads((root / (variant + '.json')).read_text())
    costs = data['drawMilliseconds']
    assert len(costs) > 100, (variant, 'insufficient painter samples')
    assert len(data['samples']) > 100, (variant, 'insufficient display callbacks')
    assert not data['metal'], 'this gate measures the production CoreGraphics painter'
    summary[variant] = {'medianDrawMs': statistics.median(costs),
                        'p95DrawMs': sorted(costs)[int(len(costs) * .95)],
                        'drawCount': len(costs)}
(root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
assert summary['after']['medianDrawMs'] < summary['before']['medianDrawMs'] * .75, summary
print(json.dumps(summary, indent=2))
PY
script_completed=1
