#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUN_DIR="${1:?usage: run-agent-host-tests.sh RUN_DIR}"
WORK_DIR="$(mktemp -d "$RUN_DIR/agent-host.XXXXXX")"

# Native-only deterministic fixtures. CTest owns and cleans each private socket
# and service process; this lane neither opens SSH nor invokes a real provider.
SQLITE_SOURCE_DIR="${TESSERA_SQLITE_AMALGAMATION:-$WORK_DIR/sqlite}"
python3 "$REPO_ROOT/Tools/AgentHost/fetch_sqlite.py" "$SQLITE_SOURCE_DIR"
cmake -S "$REPO_ROOT/Tools/AgentHost" -B "$WORK_DIR/build" \
  -DCMAKE_BUILD_TYPE=Release -DTESSERA_SQLITE_AMALGAMATION="$SQLITE_SOURCE_DIR"
cmake --build "$WORK_DIR/build" --parallel 4
ctest --test-dir "$WORK_DIR/build" --output-on-failure
python3 "$REPO_ROOT/scripts/performance/agent-center/test_hook_probe.py"
