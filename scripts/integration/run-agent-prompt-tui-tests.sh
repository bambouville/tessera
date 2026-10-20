#!/bin/sh

# Credential-free live provider prompt gate. All provider state and tmux
# sockets are disposable; the installed CLIs are used read-only.
set -eu

if [ "${TESSERA_RUN_AGENT_PROMPT_TUI:-0}" != 1 ]; then
    printf '%s\n' 'set TESSERA_RUN_AGENT_PROMPT_TUI=1 to run the mock-backed TUI prompt lane' >&2
    exit 64
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
HELPER_DIR="$SCRIPT_DIR/agent-prompt-tui"
for command in swiftc python3 tmux; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'agent prompt TUI lane requires %s\n' "$command" >&2
        exit 1
    fi
done

# tmux sockets live in the run directory; a long macOS $TMPDIR would pass
# the 104-byte Unix socket path limit.
# Resolved: providers key project trust by the real path (/tmp is a link on macOS).
RUN=$(CDPATH= cd -- "$(mktemp -d /tmp/tessera-agent-prompt-tui.XXXXXX)" && pwd -P)
STAMP=$(date +%Y%m%d-%H%M%S)
DESTINATION=${1:-.build/agent-prompt-tui/$STAMP}
SOCKET_PREFIX="tessera-prompt-tui-$$"
# Every scenario runs in a desktop pane and in a phone's: the apps size the
# tmux window to the device, and a narrow pane wraps the dialogs' rows.
SIZES=${TESSERA_AGENT_PROMPT_TUI_SIZES:-110x40 56x48}

cleanup() {
    status=$?
    if [ "$status" -eq 0 ] && [ "${script_completed:-0}" != 1 ]; then
        printf '%s\n' 'agent prompt TUI aborted before completion' >&2
        status=1
    fi
    trap - EXIT HUP INT TERM
    set +e
    if ! mkdir -p "$DESTINATION"; then
        printf 'could not create prompt TUI evidence destination: %s\n' "$DESTINATION" >&2
        status=1
    fi
    for size_run in "$RUN"/size-*; do
        [ -d "$size_run" ] || continue
        for provider in claude codex kimi; do
            tmux -S "$size_run/$SOCKET_PREFIX-$provider.sock" kill-server >/dev/null 2>&1
        done
        if [ -f "$size_run/mock-pids" ]; then
            while IFS= read -r pid; do
                kill "$pid" >/dev/null 2>&1
            done < "$size_run/mock-pids"
            attempts=0
            while [ "$attempts" -lt 20 ]; do
                live=0
                while IFS= read -r pid; do
                    if kill -0 "$pid" >/dev/null 2>&1; then live=1; fi
                done < "$size_run/mock-pids"
                [ "$live" -eq 0 ] && break
                attempts=$((attempts + 1))
                sleep 0.1
            done
        fi
        if [ -r "$size_run/home/.config/tessera/agent-lifecycle-diagnostics.log" ]; then
            mkdir -p "$size_run/evidence"
            cp "$size_run/home/.config/tessera/agent-lifecycle-diagnostics.log" \
                "$size_run/evidence/agent-lifecycle-diagnostics.log"
        fi
        size_name=${size_run##*/size-}
        if [ -d "$size_run/evidence" ] && ! { mkdir -p "$DESTINATION/$size_name" &&
            cp -R "$size_run/evidence/." "$DESTINATION/$size_name/"; }; then
            printf 'could not copy prompt TUI evidence to %s\n' "$DESTINATION/$size_name" >&2
            status=1
        fi
    done
    rm -rf "$RUN"
    printf 'agent prompt TUI evidence: %s\n' "$DESTINATION"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sh "$SCRIPT_DIR/build-agent-integration-dumper.sh" \
    "$RUN/dump-agent-integration" "$RUN/swift-module-cache"

# Reuse the production dumper's Core source list without changing its builder.
python3 - "$SCRIPT_DIR/build-agent-integration-dumper.sh" > "$RUN/core-sources.txt" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
for source in re.findall(r'"\$REPO_ROOT/([^"\n]+\.swift)"', text):
    print(source)
PY
if [ "$(wc -l < "$RUN/core-sources.txt" | tr -d '[:space:]')" -lt 20 ]; then
    printf '%s\n' 'could not extract Core source list from dumper builder' >&2
    exit 1
fi
set --
while IFS= read -r source; do
    set -- "$@" "$REPO_ROOT/$source"
done < "$RUN/core-sources.txt"
swiftc -O -module-cache-path "$RUN/swift-module-cache" "$@" \
    "$SCRIPT_DIR/AgentMarkdownDumperStub.swift" \
    "$HELPER_DIR/PromptDriver.swift" -o "$RUN/prompt-driver"

sizes_run=0
for size in $SIZES; do
    case "$size" in
        *[!0-9x]*|x*|*x|*x*x*) size_valid=0 ;;
        *x*) size_valid=1 ;;
        *) size_valid=0 ;;
    esac
    if [ "$size_valid" != 1 ]; then
        printf 'invalid prompt TUI size: %s\n' "$size" >&2
        exit 64
    fi
    mkdir "$RUN/size-$size"
    printf 'agent prompt TUI pane %s\n' "$size"
    TESSERA_AGENT_PROMPT_TUI_SIZE=$size python3 "$HELPER_DIR/lane.py" "$RUN/size-$size" "$REPO_ROOT" \
        "$RUN/dump-agent-integration" "$RUN/prompt-driver" "$SOCKET_PREFIX"
    sizes_run=$((sizes_run + 1))
done
# An empty size list runs no scenario; that is no pass.
if [ "$sizes_run" -eq 0 ]; then
    printf '%s\n' 'no prompt TUI size to run' >&2
    exit 64
fi
script_completed=1
