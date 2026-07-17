#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: capture-visual-evidence.sh RUN_DIR\n' >&2; exit 2; }

VISUAL_ROOT="$RUN_DIR/visual"
CASE_ROOT="$VISUAL_ROOT/cases"
mkdir -p "$CASE_ROOT"

"$HERE/prepare-visual-simulator.sh" "$RUN_DIR"
UDID="$(jq -r .udid "$VISUAL_ROOT/runtime.json")"
cleanup_visual_environment() {
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_VISUAL_CAPTURE \
    >/dev/null 2>&1 || true
}
trap cleanup_visual_environment EXIT

shopt -s nullglob
case_scripts=("$HERE"/visual-cases/*.sh)
(( ${#case_scripts[@]} > 0 )) || {
  printf 'no visual capture cases are installed\n' >&2
  exit 1
}

# This loop must finish before run-integration-tests.sh launches Codex. The
# single aggregate reviewer must see the complete evidence set in one turn.
for case_script in "${case_scripts[@]}"; do
  printf '[visual-capture] %s\n' "$(basename "$case_script")"
  "$case_script" "$RUN_DIR"
done

python3 "$HERE/finalize-visual-evidence.py" "$VISUAL_ROOT"
cleanup_visual_environment
trap - EXIT
