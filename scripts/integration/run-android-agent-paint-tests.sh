#!/usr/bin/env bash
# Reuse the integration suite's exact disposable-AVD ownership/cleanup path.
set -euo pipefail
[[ $# -ge 2 && $# -le 3 ]] || { echo 'usage: run-android-agent-paint-tests.sh PRIVATE_MANIFEST FRESH_OUTPUT [pixel_tablet|pixel_7]' >&2; exit 64; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$1"
output="$2"
[[ "$output" == /private/tmp/tessera-android-paint-* && ! -e "$output" ]] || exit 64
export TESSERA_ANDROID_AGENT_PAINT_MANIFEST="$manifest"
export TESSERA_ANDROID_AGENT_PAINT_OUTPUT="$output"
exec bash "$repo_root/scripts/integration/run-android-agent-window-tests.sh" "$output-runner" "${3:-pixel_tablet}"
