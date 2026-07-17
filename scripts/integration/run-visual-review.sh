#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-visual-review.sh RUN_DIR\n' >&2; exit 2; }

VISUAL_ROOT="$RUN_DIR/visual"
MANIFEST="$VISUAL_ROOT/aggregate-manifest.json"
IMAGE_LIST="$VISUAL_ROOT/image-list.txt"
RESULT="$VISUAL_ROOT/codex-review.json"
EVENTS="$VISUAL_ROOT/codex-events.jsonl"

[[ -f "$MANIFEST" ]] || { printf 'missing %s\n' "$MANIFEST" >&2; exit 1; }
[[ -s "$IMAGE_LIST" ]] || { printf 'missing or empty %s\n' "$IMAGE_LIST" >&2; exit 1; }
command -v codex >/dev/null 2>&1 || { printf 'codex CLI is unavailable\n' >&2; exit 1; }

image_args=()
while IFS= read -r path; do
  [[ -f "$path" ]] || { printf 'missing visual artifact: %s\n' "$path" >&2; exit 1; }
  image_args+=(--image "$path")
done <"$IMAGE_LIST"

{
  sed -n '1,260p' "$HERE/visual-review-prompt.md"
  printf '\n# Aggregate evidence manifest\n\n```json\n'
  sed -n '1,20000p' "$MANIFEST"
  printf '\n```\n'
} | codex --ask-for-approval never exec \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --skip-git-repo-check \
  --sandbox read-only \
  --json \
  --output-schema "$HERE/visual-review.schema.json" \
  --output-last-message "$RESULT" \
  --cd "$RUN_DIR" \
  "${image_args[@]}" \
  - >"$EVENTS"

python3 - "$MANIFEST" "$RESULT" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
result = json.loads(pathlib.Path(sys.argv[2]).read_text())
expected = {case["id"] for case in manifest["cases"]}
actual = [case["id"] for case in result["cases"]]
if len(actual) != len(set(actual)):
    raise SystemExit("Codex review returned duplicate case IDs")
missing = sorted(expected - set(actual))
extra = sorted(set(actual) - expected)
if missing or extra:
    raise SystemExit(f"Codex review coverage mismatch missing={missing} extra={extra}")
PY

printf '%s\n' "$RESULT"
