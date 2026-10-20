#!/usr/bin/env bash
# Finger drags and taps into full-screen programs under tmux's default
# `mouse off`. mosh never relays the alternate screen, and a pane's mouse mode
# can be missing from the visible tmux client (it was on a user's host while
# Claude Code's pane asked for the mouse), so mosh+tmux routes by the tmux
# pane state (Claude Code fullscreen, htop, Vim). The fixture's tmux and mosh
# do hand the mode over, so the app's DEBUG harness keeps it off the mosh
# surface here and the lane checks that it stayed off. SSH+tmux is the
# control that sees those modes directly.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TESSERA_SCROLL_CAPTURE_LIBRARY=1
export TESSERA_SCROLL_CASE_ID=S12-mouse-off-touch
export TESSERA_SCROLL_TMUX_MOUSE=off
export TESSERA_SCROLL_INPUT=touch
export TESSERA_SCROLL_DROP_CLIENT_MOUSE=1
source "$HERE/visual-cases/s1-s6-live-scroll-transports.sh" "${1:?run directory}"

# Only the tmux transports have a mouse option to pin off. A narrower run is
# for diagnosis and says so in its manifest.
transports="${TESSERA_SCROLL_TOUCH_TRANSPORTS:-mosh-tmux ssh-tmux}"
read -r -a selected <<<"$transports"
(( ${#selected[@]} > 0 )) || die 'TESSERA_SCROLL_TOUCH_TRANSPORTS selects no transport'
for selected_transport in "${selected[@]}"; do
  case "$selected_transport" in
    mosh-tmux|ssh-tmux) ;;
    *) die "S12 runs only on tmux transports, not: $selected_transport" ;;
  esac
done
for selected_transport in "${selected[@]}"; do
  capture_selected_transport "$selected_transport"
done

jq -n --arg transports "${selected[*]}" '$transports | split(" ")' >"$CASE_DIR/transports.json"
cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "S12-mouse-off-touch",
  "title": "Finger scrolling and taps in full-screen programs with tmux mouse off",
  "matrix_ids": ["S6", "S12"],
  "invariants": [
    "With tmux `mouse off` (tmux's default), a pointer scroll on the primary screen still reveals earlier numbered history and the reverse scroll returns to the live tail.",
    "In htop, finger drags visibly change the selection or process-list position in both directions; a single tap then selects the process row under the finger. Literal escape bytes, a history overlay over htop, or a frozen screen fail.",
    "In Vim with mouse=a, finger drags visibly change the numbered file range in both directions, and a tap in the middle of the rows visible above the keyboard moves Vim's cursor to that row (the lane also checks tmux's pane cursor row).",
    "Primary milestones keep pane_in_mode=0: no gesture puts the pane into tmux copy mode.",
    "The software keyboard stays up throughout (the terminal keeps focus so a tap clicks); gestures and taps stay above it.",
    "On mosh+tmux the mosh surface never shows a mouse mode (client-mouse-modes.txt), so the taps and drags reach htop and Vim through the tmux pane state alone."
  ],
  "capture_notes": "Same fixture, recording and 3x3 sheet layout as S1/S6 (rows primary, htop, vim; columns before, after the first gesture, after the reverse gesture), but the htop and Vim gestures are XCUITest finger drags (the primary row keeps the pointer scroll) and tmux's mouse option is pinned off on the attached session. Each transport adds htop-tap-evidence.png and vim-tap-evidence.png: the restored state on the left and the state one tap later on the right. Connections are created programmatically from an ignored ephemeral fixture configuration; UI automation never opens a host. Physical finger feel remains a manual check.",
  "deterministic_precheck": {"verdict": "pass", "detail": "Every finger-driven XCUITest driver listed in transports.json (mosh+tmux and SSH+tmux unless narrowed for diagnosis) completed every stage, each first primary scroll changed at least a quarter of the screen's horizontal bands, tmux reported mouse=off, each Vim tap moved tmux's pane cursor from the window edge to within three rows of the tapped row (see vim-tap.json), and on mosh+tmux every gesture diagnostic showed the surface's mouse mode off (client-mouse-modes.txt)."}
}
JSON
script_completed=1
