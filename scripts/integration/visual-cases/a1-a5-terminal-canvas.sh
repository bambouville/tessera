#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || exit 2

VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/A1-A5-terminal-canvas"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
mkdir -p "$CASE_DIR"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_TERMINAL_CANVAS_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/full-canvas.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/full-canvas.raw.png" --out "$CASE_DIR/full-canvas.png" >/dev/null
rm "$CASE_DIR/full-canvas.raw.png"

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "A1-A5-terminal-canvas",
  "title": "Full-bleed terminal background and top-level chrome canvas",
  "matrix_ids": ["A1", "A5", "G3"],
  "invariants": [
    "The striped terminal background reaches every screen edge with no black letterbox strips.",
    "The top reserved chrome area does not introduce an opaque black slab.",
    "The canvas is landscape, full-screen, unclipped, and free of stale-width seams."
  ],
  "capture_notes": "DEBUG terminal-canvas harness; no host connection and no user data. Screenshot pixels were rotated counter-clockwise to normalize simctl's fixed portrait framebuffer into landscape.",
  "deterministic_precheck": {"verdict": "not-run"}
}
JSON
