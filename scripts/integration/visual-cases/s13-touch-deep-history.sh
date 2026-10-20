#!/usr/bin/env bash
# S13 at depth: 6000 fixture rows under a 10000-row tmux history-limit, so
# finger flicks alone must take SSH+tmux past its 2000-row attach capture and
# mosh+tmux past its 512-row first page to the oldest row. The shallow S13
# fits inside both first captures and never asks for more. Plain SSH and
# plain mosh hold no remote history to deepen; S13 itself covers them.
set -euo pipefail
export TESSERA_SCROLL_CASE_ID="${TESSERA_SCROLL_CASE_ID:-S13-touch-primary-history-deep}"
export TESSERA_SCROLL_TMUX_HISTORY_LIMIT="${TESSERA_SCROLL_TMUX_HISTORY_LIMIT:-10000}"
export TESSERA_SCROLL_FIXTURE_ROWS="${TESSERA_SCROLL_FIXTURE_ROWS:-6000}"
export TESSERA_SCROLL_TOUCH_TRANSPORTS="${TESSERA_SCROLL_TOUCH_TRANSPORTS:-ssh-tmux mosh-tmux}"
exec "$(dirname "${BASH_SOURCE[0]}")/s13-touch-primary-history.sh" "$@"
