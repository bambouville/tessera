#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || exit 2

VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/O1-onboarding-tour"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
mkdir -p "$CASE_DIR"

for step in {0..7}; do
  display_step=$((step + 1))
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  SIMCTL_CHILD_TESSERA_FORCE_TOUR_STEP="$step" \
    xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    >"$CASE_DIR/step-${display_step}-launch.txt"
  sleep 1
  xcrun simctl io "$UDID" screenshot \
    "$CASE_DIR/step-${display_step}.raw.png" >/dev/null
  sips -r 270 \
    "$CASE_DIR/step-${display_step}.raw.png" \
    --out "$CASE_DIR/step-${display_step}.png" >/dev/null
  rm "$CASE_DIR/step-${display_step}.raw.png"
done

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "O1-onboarding-tour",
  "title": "All eight onboarding tour states remain readable in landscape",
  "matrix_ids": ["O1"],
  "invariants": [
    "Exactly eight landscape captures are present and each displays the matching STEP N OF 8 state.",
    "Every callout is fully on-screen with readable title/body copy and an unbroken single-row footer; buttons and page dots do not overlap or clip.",
    "Spotlight rings in steps 1 and 2 align with the intended visible control when that control is present; a centered fallback is acceptable only when the target is absent from the seeded landing state.",
    "The six illustration steps render complete, coherent diagrams without missing layers, black rectangles, stale frames, or edge clipping."
  ],
  "capture_notes": "DEBUG forced-step hook on the dedicated integration simulator. No connection is initiated; screenshots are normalized to landscape pixels before review.",
  "deterministic_precheck": {"verdict": "not-run"}
}
JSON
