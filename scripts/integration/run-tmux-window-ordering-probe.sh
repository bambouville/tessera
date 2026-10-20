#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
load_fixture_config
for host in "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_CHAOS_HOST"; do
  for base_index in 0 1; do
    fixture_ssh "$host" python3 - --disposable-fixture --base-index "$base_index" < "$HERE/tmux-window-ordering-probe.py"
  done
done
