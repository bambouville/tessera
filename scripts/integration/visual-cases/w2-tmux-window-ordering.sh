#!/usr/bin/env bash
# Ordering gestures are part of aggregate visual acceptance, not an opt-in lane.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:?run directory required}"
CASE_DIR="$RUN_DIR/visual/cases/W2-tmux-window-ordering"
mkdir -p "$CASE_DIR"
for device in ipad phone; do
  device_dir="$RUN_DIR/visual/ordering/$device"
  if [[ "$device" == phone ]]; then
    "$HERE/run-tmux-window-ordering-ui-tests.sh" "$device_dir" --phone
  else
    "$HERE/run-tmux-window-ordering-ui-tests.sh" "$device_dir"
  fi
  if [[ "$device" == phone ]]; then
    python3 "$HERE/tmux-ordering-frame-sheets.py" "$device_dir" --phone
  else
    python3 "$HERE/tmux-ordering-frame-sheets.py" "$device_dir"
  fi
  mkdir -p "$CASE_DIR/$device"
  for screenshot in "$device_dir"/screenshots/*.png; do
    [[ "$screenshot" == *.raw.png ]] && continue
    cp "$screenshot" "$CASE_DIR/$device/"
  done
  cp "$device_dir/interaction.mp4" "$device_dir/xctest.log" "$device_dir/summary.json" "$device_dir/motion-summary.json" "$CASE_DIR/$device/"
done
cat > "$CASE_DIR/case.json" <<'JSON'
{
  "id": "W2-tmux-window-ordering",
  "title": "Tmux ordering on iPad and compact iPhone",
  "matrix_ids": ["W1", "W3", "W4"],
  "invariants": [
    "Dragging preserves all windows and leaves a legible gap without blanking the strip or list.",
    "The dragged row remains visible and the resulting order matches the gesture.",
    "Move menus remain readable and within the viewport on both devices."
  ],
  "capture_notes": "Host-free production controller and UI, disposable landscape iPad and compact iPhone. Each subdirectory includes simctl screenshots, video, XCTest evidence and pass/skip summary.",
  "deterministic_precheck": {"verdict": "pass", "details": "Both runners require nonzero passed tests and every expected screenshot milestone; skips are failures."}
}
JSON
