#!/usr/bin/env bash
# Uses the aggregate-owned iPad plus one run-owned iPhone; no host connection.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/PERF2-hidden-terminal"
IPAD_UDID="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
DERIVED_DATA="$(jq -r .derived_data "$VISUAL_ROOT/runtime.json")"
PHONE_STATE="$VISUAL_ROOT/perf2-phone.udid"
mkdir -p "$CASE_DIR"
cleanup() { delete_owned_test_simulator "$PHONE_STATE"; }
trap 'fail_closed_trap cleanup' EXIT
for surface in ipad iphone; do
  UDID="$IPAD_UDID"
  if [[ "$surface" == iphone ]]; then
    UDID="$(xcrun simctl create "Tessera Hidden Draw iPhone $(date -u +%Y%m%dT%H%M%SZ)-$$" \
      com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-0)"
    printf '%s\n' "$UDID" >"$PHONE_STATE"
    printf '%s\n' "$UDID" >"$PHONE_STATE.owned"
    xcrun simctl boot "$UDID"
  fi
  RESULT="$VISUAL_ROOT/perf2-$surface.xcresult"
  xcodebuild test-without-building \
    -project "$HERE/../../Tessera.xcodeproj" -scheme Tessera -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
    -only-testing:TesseraTests/AppleSessionCommandFacadeTests/testHiddenTerminalKeepsBufferCurrentWithoutDrawingAndRepaintsOnUnhide \
    -only-testing:TesseraTests/AppleSessionCommandFacadeTests/testTerminalSurfaceBoundInitiallyHiddenStillReachesReadyGeometry \
    -only-testing:TesseraTests/AppleSessionCommandFacadeTests/testCoreGraphicsDrawHookPassesThroughWithoutVerboseDiagnostics \
    -resultBundlePath "$RESULT" >"$CASE_DIR/$surface-xctest.log" 2>&1
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$CASE_DIR/$surface"
done
python3 - "$CASE_DIR/case.json" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'id': 'PERF2-hidden-terminal',
    'title': 'Inactive terminal suppresses drawing and reveals its current buffer',
    'matrix_ids': ['PERF2'],
    'invariants': [
        'The opacity-zero baseline shows only the reference terminal, although native counters verify both terminals still draw.',
        'After the production drawing gate suppresses all inherited CoreGraphics drawing during hidden output, revealing the candidate shows the same complete text as the continuously visible reference.',
        'Initially hidden real TerminalSurfaceBound reaches ready geometry and preserves view identity as its environment toggles drawing; normal non-verbose rendering remains pixel-equivalent.'
    ],
    'capture_notes': 'Scene-bound native iPad/iPhone tests use the pinned production CoreGraphics renderer, not Metal. Images are native CoreGraphics window backing-store captures, with exact terminal pixel equality asserted separately. Counters measure forwarded inherited draw calls, not cheap guarded callback entries. Output/emulator updates continue while drawing is disabled. Images alone cannot prove CPU or keystroke latency; those claims require the native assertions and physical diagnostics. No remote connection is initiated.',
    'deterministic_precheck': {'verdict': 'pass', 'details': 'Three focused native tests pass on each device: opacity baseline, production no-forward gate/reveal pixel parity, real surface environment lifecycle, and non-verbose exact-once forwarding.'}
}, indent=2) + '\n')
PY
script_completed=1
