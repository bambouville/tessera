#!/usr/bin/env bash
# Local-image previews on both size classes; never connects to a host.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/F14-markdown-images"
PHONE_STATE="$CASE_DIR/phone.udid"
mkdir -p "$CASE_DIR"
test_pid=''
cleanup() {
  [[ -z "$test_pid" ]] || { kill "$test_pid" 2>/dev/null || true; wait "$test_pid" || true; }
  delete_owned_test_simulator "$PHONE_STATE"
}
trap 'fail_closed_trap cleanup' EXIT
for surface in ipad iphone; do
  udid="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
  if [[ "$surface" == iphone ]]; then
    udid="$(TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Markdown iPhone' \
      TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
      TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$PHONE_STATE" "$HERE/ensure-test-simulator.sh" | tail -n 1)"
  fi
  log="$CASE_DIR/$surface.log"
  xcodebuild test-without-building -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$(integration_derived_data)" \
    -resultBundlePath "$CASE_DIR/$surface.xcresult" \
    -only-testing:TesseraUITests/MarkdownScrollProbe/testLocalImages >"$log" 2>&1 &
  test_pid=$!
  ready=0
  for _ in {1..600}; do
    if rg -q 'markdown-images-ready' "$log"; then ready=1; break; fi
    kill -0 "$test_pid" 2>/dev/null || break
    sleep 0.2
  done
  if [[ "$ready" != 1 ]]; then
    xcrun simctl io "$udid" screenshot "$CASE_DIR/$surface-failed.png" || true
    cat "$log"
    exit 1
  fi
  xcrun simctl io "$udid" screenshot "$CASE_DIR/$surface.png"
  if [[ "$surface" == ipad ]]; then "$HERE/normalize-landscape-screenshot.sh" "$CASE_DIR/$surface.png" "$CASE_DIR/$surface.png" >/dev/null; fi
  wait "$test_pid"; test_pid=''
done
cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "F14-markdown-images",
  "title": "Remote Markdown local images on iPad and iPhone",
  "matrix_ids": ["F14"],
  "invariants": [
    "Both screenshots show a blue RELATIVE IMAGE, red ABSOLUTE IMAGE, and green TABLE IMAGE in rendered Markdown.",
    "Images fit the preview width without cropping or covering surrounding prose. The green image stays inside its table cell.",
    "The missing image keeps its readable Missing image alt text and the rest of the document remains readable."
  ],
  "capture_notes": "Host-free fixture passes encoded relative, absolute, reference-style, and literal-space table destinations through real image staging using a mock bridge. iPad is landscape; iPhone is portrait.",
  "deterministic_precheck": {"verdict": "pass"}
}
JSON
script_completed=1
