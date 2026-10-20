#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUN_DIR="${1:?usage: run-agent-host-security-tests.sh RUN_DIR}"
mkdir -p "$RUN_DIR"
WORK="$(mktemp -d "$RUN_DIR/agent-host-security.XXXXXX")"
# Xcode's bundled clang can omit libFuzzer. Prefer the full Swift toolchain
# already required by the Android shared-core build, unless CC/CXX are set.
SWIFT_CLANG="$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin"
if [[ -z "${CC:-}" && -z "${CXX:-}" && -x "$SWIFT_CLANG/clang++" ]]; then
  export CC="$SWIFT_CLANG/clang" CXX="$SWIFT_CLANG/clang++"
fi
SQLITE="${TESSERA_SQLITE_AMALGAMATION:-$WORK/sqlite}"
python3 "$ROOT/Tools/AgentHost/fetch_sqlite.py" "$SQLITE"
cmake -S "$ROOT/Tools/AgentHost" -B "$WORK/build" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DTESSERA_SQLITE_AMALGAMATION="$SQLITE" -DTESSERA_SANITIZERS=ON -DTESSERA_FUZZING=ON
cmake --build "$WORK/build" --parallel 4
ctest --test-dir "$WORK/build" --output-on-failure --timeout 180 -R 'normalize|normalization|bounded_json|kimi_reader|jsonl_reader|page_window|integration_removal'
