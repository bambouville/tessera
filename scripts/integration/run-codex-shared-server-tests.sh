#!/bin/sh

# Credential-free live gate for Codex's shared app-server: two real Codex TUIs
# on one server, the scripted Responses API, the production hooks. All state
# and the tmux socket are disposable; the installed Codex is used read-only.
set -eu

if [ "${TESSERA_RUN_CODEX_SHARED_SERVER:-0}" != 1 ]; then
    printf '%s\n' 'set TESSERA_RUN_CODEX_SHARED_SERVER=1 to run the shared Codex server lane' >&2
    exit 64
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for command in swiftc python3 tmux codex; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'shared Codex server lane requires %s\n' "$command" >&2
        exit 1
    fi
done

# The tmux and Codex daemon sockets live in the run directory; a long macOS
# $TMPDIR would pass the 104-byte Unix socket path limit.
RUN=$(CDPATH= cd -- "$(mktemp -d /tmp/tessera-codex-shared.XXXXXX)" && pwd -P)
DESTINATION=${1:-.build/codex-shared-server/$(date +%Y%m%d-%H%M%S)}

cleanup() {
    status=$?
    if [ "$status" -eq 0 ] && [ "${script_completed:-0}" != 1 ]; then
        printf '%s\n' 'shared Codex server lane aborted before completion' >&2
        status=1
    fi
    trap - EXIT HUP INT TERM
    set +e
    tmux -S "$RUN/codex-shared.sock" kill-server >/dev/null 2>&1
    if [ -d "$RUN/evidence" ] && ! { mkdir -p "$DESTINATION" && cp -R "$RUN/evidence/." "$DESTINATION/"; }; then
        printf 'could not copy shared Codex server evidence to %s\n' "$DESTINATION" >&2
        status=1
    fi
    rm -rf "$RUN"
    printf 'shared Codex server evidence: %s\n' "$DESTINATION"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sh "$SCRIPT_DIR/build-agent-integration-dumper.sh" \
    "$RUN/dump-agent-integration" "$RUN/swift-module-cache"
# The driver stops the lane's detached processes itself, so a signal is
# passed on and the driver awaited before the run directory goes.
python3 "$SCRIPT_DIR/agent-prompt-tui/codex_shared_server.py" "$RUN" \
    "$RUN/dump-agent-integration" "$RUN/evidence" &
lane_pid=$!
forward() {
    kill -TERM "$lane_pid" 2>/dev/null
    wait "$lane_pid" 2>/dev/null
    exit "$1"
}
trap 'forward 129' HUP
trap 'forward 130' INT
trap 'forward 143' TERM
wait "$lane_pid"
script_completed=1
