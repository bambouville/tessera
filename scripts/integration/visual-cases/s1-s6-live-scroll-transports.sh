#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || exit 2
load_fixture_config
ensure_fixture_credentials

VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/${TESSERA_SCROLL_CASE_ID:-S1-S6-live-scroll-transports}"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
APP_PATH="$(jq -r .app_path "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
PROJECT="$HERE/../../Tessera.xcodeproj"
RUN_TOKEN="$(basename "$RUN_DIR" | tr -cd 'A-Za-z0-9_-')"
# Cleanup proves this run's sessions, mosh-servers and scenario processes by
# their names alone (see capture_transport), so they must be run-unique: a
# timestamped run directory makes them so. The longest is the mosh+tmux
# scenario's Vim file.
run_owned_name_is_specific "/tmp/tessera_scroll_${RUN_TOKEN}_mosh_tmux.trigger.vim.txt" \
  || die "run directory name must be a short run token with digits: $RUN_DIR"
PASSWORD="$(fixture_password)"
mkdir -p "$CASE_DIR"

current_host=''
current_session=''
current_trigger=''
# Set while an XCUITest waits on this lane's acknowledgements; an interrupted
# lane releases it (see cleanup).
current_ack_dir=''

# Post-mortem evidence that the aggregate review must not see: every
# attempt's in-app diagnostics log, and the complete artifact set of any
# attempt that failed before its evidence sheet was accepted. Both live
# outside cases/ so finalize-visual-evidence.py never forwards them.
DIAGNOSTICS_ROOT="$VISUAL_ROOT/diagnostics/${TESSERA_SCROLL_CASE_ID:-S1-S6-live-scroll-transports}"
FAILED_ATTEMPTS_ROOT="$VISUAL_ROOT/failed-attempts/${TESSERA_SCROLL_CASE_ID:-S1-S6-live-scroll-transports}"

# The Mosh render ledger, painter handoff, and scroll placement only log when
# these two switches are on. The visual simulator is disposable, so the run
# turns them on once here; a frozen or rejected frame then leaves the full
# adapter state in the retained log instead of a bare screenshot.
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" Diagnostics.VerboseEnabled -bool YES
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" Diagnostics.ScrollEnabled -bool YES

preserve_app_diagnostics() {
  local slug="$1"
  local attempt="$2"
  local container
  container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  [[ -n "$container" ]] || return 0
  local log="$container/Library/Application Support/Diagnostics/tessera-diagnostics.log"
  [[ -f "$log" ]] || return 0
  mkdir -p "$DIAGNOSTICS_ROOT"
  cp "$log" "$DIAGNOSTICS_ROOT/$slug-attempt-$attempt.log"
}

# TESSERA_SCROLL_DROP_CLIENT_MOUSE (S12, mosh+tmux only): the app's DEBUG
# harness keeps every mouse mode off the mosh surface, so taps and pans can
# reach htop and Vim only through the tmux pane state. The attempt's gesture
# diagnostics must show that the surface never reported a mouse mode.
drops_client_mouse() {
  [[ "${TESSERA_SCROLL_DROP_CLIENT_MOUSE:-0}" == 1 && "$1" == mosh-tmux ]]
}

# The app's log outlives the process: a run's earlier lanes and transports,
# which report their own mouse modes, stay in it. Only lines stamped at or
# after the attempt's launch count (UTC ISO timestamps sort as text).
check_client_mouse_dropped() {
  local slug="$1" attempt="$2" started="$3"
  local log="$DIAGNOSTICS_ROOT/$slug-attempt-$attempt.log" modes
  [[ -f "$log" ]] || { printf '%s: no app diagnostics to check the client mouse mode\n' "$slug" >&2; return 1; }
  # A rotation keeps only the log's tail: the attempt's earlier modes are gone.
  if awk -v started="$started" '/^[0-9][0-9][0-9][0-9]-/ && substr($0, 1, 19) >= started \
      && /\[DiagnosticLog\] rotated/ { found = 1 } END { exit !found }' "$log"; then
    printf '%s: the app log rotated during the attempt, so its mouse modes are incomplete\n' "$slug" >&2
    return 1
  fi
  modes="$(awk -v started="$started" '/^[0-9][0-9][0-9][0-9]-/ && substr($0, 1, 19) >= started' "$log" \
    | grep -o '\[ScrollDiag\].* mouse=[A-Za-z0-9]*' | grep -o 'mouse=[A-Za-z0-9]*$' | sort | uniq -c || true)"
  printf '%s\n' "$modes" >"$CASE_DIR/$slug/client-mouse-modes.txt"
  if [[ -z "$modes" ]] || grep -qv ' mouse=off$' <<<"$modes"; then
    printf '%s: the mosh surface reported a mouse mode despite the harness (%s)\n' "$slug" "$(tr '\n' ' ' <<<"$modes")" >&2
    return 1
  fi
}

preserve_failed_attempt() {
  local slug="$1"
  local attempt="$2"
  local keep="$FAILED_ATTEMPTS_ROOT/$slug-attempt-$attempt"
  rm -rf "$keep"
  mkdir -p "$keep"
  [[ -d "$CASE_DIR/$slug" ]] && mv "$CASE_DIR/$slug" "$keep/case"
  # Cases that run another XCUITest name its result bundle with their prefix.
  local result="${SCROLL_RESULT_PREFIX:-live-scroll}-$slug.xcresult"
  [[ -d "$VISUAL_ROOT/$result" ]] && mv "$VISUAL_ROOT/$result" "$keep/$result"
  return 0
}

clear_app_environment() {
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_FLICK_INPUT >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_FLICK_DISTANCE >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_PHYSICS >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_HARNESS \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_INPUT \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_VISUAL_CAPTURE_ACK_DIR \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_KEEP_KEYBOARD \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_DROP_CLIENT_MOUSE \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_CONFIG_B64 \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_EXPOSE_ROWS \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_TOUCH_HISTORY_OLDEST_ROW \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_TOUCH_HISTORY_DRAG_X \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_PORTRAIT \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_AIM_X \
    >/dev/null 2>&1 || true
}

# S1/S6 turn tmux mouse reporting on; S12 pins tmux's default `mouse off`,
# where the visible client has only the modes htop/Vim asked for (and on
# mosh+tmux the harness drops those; see drops_client_mouse).
enable_fixture_tmux_mouse() {
  local slug="$1" host="$2" phase_dir="$3"
  local mouse="${TESSERA_SCROLL_TMUX_MOUSE:-on}"
  [[ "$slug" == *_tmux ]] || return 0
  local target="$current_session"
  [[ "$slug" == mosh_tmux ]] && target="$current_session-tessera-view"
  if [[ "${TESSERA_SCROLL_ASSERT_ATTACH_MOUSE:-0}" == 1 ]]; then
    # Check the production attach policy before this fixture applies its
    # scenario option. Programs can probe the owner behind a grouped view.
    fixture_ssh "$host" "tmux display-message -p -t '$current_session' '#{mouse}'; tmux display-message -p -t '$target' '#{mouse}'" \
      > "$phase_dir/tmux-attach-mouse.txt" || return 1
    [[ "$(cat "$phase_dir/tmux-attach-mouse.txt")" == $'1\n1' ]] || return 1
  fi
  # XCUITest can reattach the app. Set the exact task-owned view session after
  # ready, so destroy-unattached cannot silently discard this fixture option.
  fixture_ssh "$host" "tmux set-option -t '$target' mouse $mouse; tmux show-options -v -t '$target' mouse" \
    > "$phase_dir/tmux-mouse.txt" || return 1
  [[ "$(cat "$phase_dir/tmux-mouse.txt")" == "$mouse" ]]
}

# Prints "cursor_y pane_height" for the fixture's program pane.
fixture_pane_cursor() {
  local host="$1"
  fixture_ssh "$host" "tmux display-message -p -t '$current_session:0.0' '#{cursor_y} #{pane_height}'"
}

# S12 taps the middle of Vim's visible rows after wheel scrolling left its
# cursor on a window edge. The software keyboard stays up, so the grid is
# shifted above it; the XCUITest logs the tap's height as a fraction of the
# whole grid (TESSERA_VISUAL_TAP). On tmux transports, tmux's own pane cursor
# must move to within three rows of that point (the view can include tmux's
# status line).
check_vim_tap() {
  local slug="$1" host="$2" phase_dir="$3" log="$4" test_pid="$5"
  wait_for_log_event "$log" vim-tap-before "$test_pid" || return 1
  if [[ "$slug" != *_tmux ]]; then
    ack_event vim-tap-before
    capture_logged_frame "$log" vim-tapped "$test_pid" "$phase_dir/vim-tapped.png" || return 1
    ack_event vim-tapped
    return
  fi
  # The XCUITest taps only after this acknowledgement.
  fixture_pane_cursor "$host" >"$phase_dir/vim-cursor-before.txt" || return 1
  ack_event vim-tap-before
  capture_logged_frame "$log" vim-tapped "$test_pid" "$phase_dir/vim-tapped.png" || return 1
  fixture_pane_cursor "$host" >"$phase_dir/vim-cursor-after.txt" || return 1
  ack_event vim-tapped
  local before_y after_y height tap
  read -r before_y _ <"$phase_dir/vim-cursor-before.txt"
  read -r after_y height <"$phase_dir/vim-cursor-after.txt"
  tap="$(grep -o 'TESSERA_VISUAL_TAP vim-tapped .*' "$log" | tail -n 1)"
  [[ "$tap" =~ gridFraction=([0-9.]+) ]] || {
    printf '%s: the XCUITest did not log its Vim tap\n' "$slug" >&2
    return 1
  }
  jq -n --argjson before "$before_y" --argjson after "$after_y" --argjson height "$height" \
    --argjson fraction "${BASH_REMATCH[1]}" --arg tap "$tap" \
    '{before_cursor_y:$before, after_cursor_y:$after, pane_height:$height,
      tap_grid_fraction:$fraction, expected_row:($height * $fraction), tap_event:$tap,
      verdict:(if ($after != $before) and (($after - ($height * $fraction)) | fabs) <= 3
        then "pass" else "fail" end)}' \
    >"$phase_dir/vim-tap.json"
  if [[ "$(jq -r .verdict "$phase_dir/vim-tap.json")" != pass ]]; then
    printf '%s: Vim tap did not move the cursor to the tapped row (%s)\n' \
      "$slug" "$(jq -c . "$phase_dir/vim-tap.json")" >&2
    return 1
  fi
}

# The fixture's htop timeout is only a backstop: acknowledged captures can
# outlast any fixed budget. Advance to Vim once the last htop frame is taken.
# Only the htop this transport's scenario started ends (it descends from the
# process naming TRIGGER): another lane's htop on the shared account is not
# this case's to stop.
end_fixture_htop() {
  local host="$1" trigger="$2"
  end_run_processes "$host" "$TESSERA_FIXTURE_USER" htop "$trigger" >>"$CASE_DIR/fixture-reap.txt" 2>&1
}

# Ends what a transport's scenario runs: each of the fixture user's
# processes whose command line names TRIGGER (the scenario), or that descends
# from one that does (its htop), and the Vim stage the probe execs into,
# whose command line names only TRIGGER.vim.txt, its file. Never `pgrep -f
# TRIGGER | kill`: when the scenario's `tmux new-session` starts the user's
# tmux server, the server's command line keeps that scenario, trigger and
# all, and every concurrent lane's sessions live in that server.
end_scenario_processes() {
  local host="$1" trigger="$2"
  end_run_processes "$host" "$TESSERA_FIXTURE_USER" @any "$trigger" "$trigger.vim.txt" \
    >>"$CASE_DIR/fixture-reap.txt" 2>&1
}

# The files a scenario and this case create next to TRIGGER.
remove_trigger_files() {
  local host="$1" trigger="$2"
  control_ssh "$host" \
    "rm -f '$trigger' '$trigger.htop' '$trigger.htop.done' '$trigger.vim' '$trigger.vim.txt'"
}

capture_primary_tmux_mode() {
  local slug="$1" host="$2" phase_dir="$3" event="$4"
  [[ "$slug" == *_tmux ]] || return 0
  fixture_ssh "$host" "tmux display-message -p -t '$current_session:0.0' '#{pane_in_mode}|#{pane_mode}'" \
    > "$phase_dir/$event-tmux-mode.txt" || return 1
  [[ "$(cat "$phase_dir/$event-tmux-mode.txt")" == '0|' ]]
}

cleanup_remote() {
  [[ -n "$current_host" ]] || return 0
  local status=0
  # The scenario's processes first, while the scenario naming the trigger is
  # still its helpers' ancestor: a killed session would orphan them.
  if [[ -n "$current_trigger" ]]; then
    end_scenario_processes "$current_host" "$current_trigger" || status=1
  fi
  if [[ -n "$current_session" ]]; then
    fixture_ssh "$current_host" "tmux kill-session -t '=$current_session-tessera-view'" \
      >/dev/null 2>&1 || true
    fixture_ssh "$current_host" "tmux kill-session -t '=$current_session'" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$current_trigger" ]]; then
    remove_trigger_files "$current_host" "$current_trigger" >/dev/null 2>&1 || true
  fi
  # A mosh-server names this transport's session (mosh+tmux) or its trigger
  # path (plain mosh, whose launch command carries it). One whose client is
  # gone never exits, and killing its session does not end a stopped one:
  # reap exactly these, and fail the transport if any survives.
  local reap_names=()
  [[ -z "$current_session" ]] || reap_names+=("$current_session")
  [[ -z "$current_trigger" ]] || reap_names+=("$current_trigger")
  if [[ ${#reap_names[@]} -gt 0 ]] \
    && ! reap_run_fixture_sessions "$current_host" "$TESSERA_FIXTURE_USER" "${reap_names[@]}" \
      >>"$CASE_DIR/fixture-reap.txt" 2>&1; then
    note "run-owned tmux sessions or mosh-servers survived cleanup; see $CASE_DIR/fixture-reap.txt"
    status=1
  fi
  current_host=''
  current_session=''
  current_trigger=''
  return "$status"
}

cleanup() {
  [[ -z "$current_ack_dir" ]] || touch "$current_ack_dir/abort" 2>/dev/null || true
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  clear_app_environment
  cleanup_remote
}
trap 'fail_closed_trap cleanup' EXIT

run_ui_test() {
  local method="$1"
  local log="$2"
  local result="$3"
  rm -rf "$result"
  TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
    -project "$PROJECT" \
    -scheme Tessera \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$result" \
    -only-testing:"TesseraUITests/VisualCaptureProbe/$method" \
    >"$log" 2>&1
}

stop_recording() {
  local pid="$1"
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill -INT "$pid" >/dev/null 2>&1 || true
    wait "$pid" || true
  fi
}

# Sub-second wall-clock time; macOS date has no %N.
now_epoch() {
  perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
}

# Takes three candidates and keeps the largest (a Metal frame that is still
# painting compresses smaller). Each candidate's timing goes to
# capture-timing.log beside the frame.
take_landscape_screenshot() {
  local output="$1" label="${2:-${1##*/}}"
  local best='' best_size=0 candidate size attempt started
  local timing="${output%/*}/capture-timing.log"
  for attempt in 1 2 3; do
    started="$(now_epoch)"
    candidate="$output.$attempt.png"
    xcrun simctl io "$UDID" screenshot "$candidate.raw.png" >/dev/null 2>&1 || return 1
    if [[ "${TESSERA_SCROLL_PORTRAIT:-0}" != 1 ]]; then
      "$HERE/normalize-landscape-screenshot.sh" "$candidate.raw.png" "$candidate" >/dev/null || return 1
      rm "$candidate.raw.png"
    else
      mv "$candidate.raw.png" "$candidate"
    fi
    size="$(stat -f %z "$candidate")" || return 1
    printf '%s candidate=%s start=%s end=%s bytes=%s\n' "$label" "$attempt" "$started" "$(now_epoch)" "$size" >>"$timing"
    if ((size > best_size)); then
      best="$candidate"
      best_size="$size"
    fi
    sleep 0.1
  done
  cp "$best" "$output" || return 1
  rm -f "$output".1.png "$output".2.png "$output".3.png
}

# How long each XCUITest milestone may take to arrive. A case whose gestures
# legitimately run longer (S13 flicking through thousands of rows) raises it;
# a test that exits is noticed at once either way.
LOG_EVENT_TIMEOUT_SECONDS="${LOG_EVENT_TIMEOUT_SECONDS:-120}"

wait_for_log_event() {
  local log="$1"
  local event="$2"
  local process_id="$3"
  local polls=$((LOG_EVENT_TIMEOUT_SECONDS * 5)) poll
  for ((poll = 0; poll < polls; poll++)); do
    if [[ -f "$log" ]] && grep -Fq "TESSERA_VISUAL_EVENT $event " "$log"; then
      return 0
    fi
    kill -0 "$process_id" >/dev/null 2>&1 || return 1
    sleep 0.2
  done
  printf 'timed out waiting %ss for XCUITest event %s\n' "$LOG_EVENT_TIMEOUT_SECONDS" "$event" >&2
  return 1
}

wait_remote_file() {
  local host="$1"
  local path="$2"
  for _ in {1..100}; do
    fixture_ssh "$host" test -f "$path" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  printf 'timed out waiting for remote stage marker %s\n' "$path" >&2
  return 1
}

capture_logged_frame() {
  local log="$1"
  local event="$2"
  local process_id="$3"
  local output="$4"
  wait_for_log_event "$log" "$event" "$process_id" || return 1
  printf '%s marker-seen=%s\n' "$event" "$(now_epoch)" >>"${output%/*}/capture-timing.log"
  take_landscape_screenshot "$output" "$event"
}

# capture_sequence's XCUITest waits in each holdForExternalCapture until the
# lane acknowledges that milestone (TESSERA_VISUAL_CAPTURE_ACK_DIR). A fixed
# hold let slow screenshots or SSH stage waits (htop's timeout before Vim) run
# into the next gesture: a "before" frame showed the moved state and
# read as a frozen reveal, or a "Vim" scroll landed in htop. `ack_dir` is
# capture_sequence's local.
ack_event() {
  touch "$ack_dir/$1.ack"
}

# Deterministic frozen-reveal gate. A primary-screen reveal that presents no
# history leaves the first-gesture capture pixel-identical to the before
# capture (mosh+tmux painter wedge, 2026-09-05). The metric is the fraction of
# 64 horizontal bands in which some 1/32-width cell changed: a raw changed-
# pixel fraction misreads a reveal that lands exactly on a row boundary (only
# the row numbers differ, under 1% of pixels) as frozen. Calibrated on every
# retained capture: real reveals score >= 0.906 (row-aligned ones included),
# true freezes score 0.000. The review would still grade a frozen sheet, but
# it must never reach the review as a candidate pass.
PRIMARY_MOTION_MIN_FRACTION=0.25

# Prints the fraction of 64 horizontal bands of two same-size PNGs in which
# at least one of 32 cells contains luma changes above 40/255 (more than ~1%
# of the cell).
motion_fraction() {
  local yavg
  yavg="$(ffmpeg -hide_banner -loglevel error -i "$1" -i "$2" \
    -lavfi "[0:v]format=gray[a];[1:v]format=gray[b];[a][b]blend=all_mode=difference,lutyuv=y='if(gt(val,40),255,0)',scale=32:64:flags=area,lutyuv=y='if(gt(val,2),255,0)',scale=1:64:flags=area,lutyuv=y='if(gt(val,4),255,0)',signalstats,metadata=print:file=-" \
    -frames:v 1 -f null - 2>/dev/null | sed -n 's/^lavfi.signalstats.YAVG=//p' | head -1)"
  [[ -n "$yavg" ]] || return 1
  awk -v y="$yavg" 'BEGIN { printf "%.4f\n", y / 255 }'
}

# Writes $phase_dir/primary-motion.json and fails when the first primary
# gesture did not visibly move the screen.
check_primary_motion() {
  local phase_dir="$1"
  local fraction verdict
  fraction="$(motion_fraction "$phase_dir/primary-before.png" "$phase_dir/primary-moved.png")" \
    || fraction=''
  if [[ -n "$fraction" ]] \
    && awk -v f="$fraction" -v min="$PRIMARY_MOTION_MIN_FRACTION" 'BEGIN { exit !(f >= min) }'; then
    verdict=pass
  else
    verdict=fail
  fi
  jq -n \
    --arg fraction "${fraction:-}" \
    --arg threshold "$PRIMARY_MOTION_MIN_FRACTION" \
    --arg verdict "$verdict" \
    '{metric:"fraction of 64 horizontal bands with a changed cell between primary-before and primary-moved",
      moved_fraction:(if $fraction == "" then null else ($fraction | tonumber) end),
      min_fraction:($threshold | tonumber), verdict:$verdict}' \
    >"$phase_dir/primary-motion.json"
  if [[ "$verdict" != pass ]]; then
    printf 'primary reveal did not move the screen (changed fraction %s < %s)\n' \
      "${fraction:-unmeasurable}" "$PRIMARY_MOTION_MIN_FRACTION" >&2
    return 1
  fi
}

capture_sequence() {
  local slug="$1"
  local host="$2"
  local trigger="$3"
  local phase_dir="$CASE_DIR/$slug"
  local video="$phase_dir/scroll-sequence.mov"
  local result="$VISUAL_ROOT/live-scroll-$slug.xcresult"
  local log="$phase_dir/xctest.log"
  local input="${TESSERA_SCROLL_INPUT:-pointer}"
  local ack_dir="$phase_dir/acks"
  rm -rf "$phase_dir"
  mkdir -p "$phase_dir" "$ack_dir"

  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$video" \
    >"$phase_dir/record-video.log" 2>&1 &
  local record_pid=$!
  for _ in {1..50}; do
    grep -q 'Recording started' "$phase_dir/record-video.log" && break
    sleep 0.1
  done
  grep -q 'Recording started' "$phase_dir/record-video.log"

  if ! xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE_ACK_DIR "$ack_dir"; then
    stop_recording "$record_pid"
    printf 'could not pass the capture acknowledgement directory to the simulator\n' >&2
    return 1
  fi
  current_ack_dir="$ack_dir"
  run_ui_test testLiveScrollVisualSequence "$log" "$result" &
  local test_pid=$!
  # Every milestone is acknowledged only once its capture and any remote stage
  # it gates are done: primary-restored after htop has started, vim-before
  # after Vim has (plain mosh cannot observe that stage; see case.json).
  if ! capture_logged_frame "$log" primary-before "$test_pid" "$phase_dir/primary-before.png" \
    || ! enable_fixture_tmux_mouse "$slug" "$host" "$phase_dir" \
    || ! capture_primary_tmux_mode "$slug" "$host" "$phase_dir" primary-before \
    || ! ack_event primary-before \
    || ! capture_logged_frame "$log" primary-moved "$test_pid" "$phase_dir/primary-moved.png" \
    || ! capture_primary_tmux_mode "$slug" "$host" "$phase_dir" primary-moved \
    || ! ack_event primary-moved \
    || ! capture_logged_frame "$log" primary-restored "$test_pid" "$phase_dir/primary-restored.png" \
    || ! capture_primary_tmux_mode "$slug" "$host" "$phase_dir" primary-restored \
    || ! check_primary_motion "$phase_dir" \
    || ! fixture_ssh "$host" touch "$trigger" \
    || ! wait_remote_file "$host" "$trigger.htop" \
    || ! ack_event primary-restored \
    || ! capture_logged_frame "$log" htop-before "$test_pid" "$phase_dir/htop-before.png" \
    || ! ack_event htop-before \
    || ! capture_logged_frame "$log" htop-moved "$test_pid" "$phase_dir/htop-moved.png" \
    || ! ack_event htop-moved \
    || ! capture_logged_frame "$log" htop-restored "$test_pid" "$phase_dir/htop-restored.png" \
    || { [[ "$input" != touch ]] && ! end_fixture_htop "$host" "$trigger"; } \
    || ! ack_event htop-restored \
    || { [[ "$input" == touch ]] \
      && { ! capture_logged_frame "$log" htop-tapped "$test_pid" "$phase_dir/htop-tapped.png" \
        || ! end_fixture_htop "$host" "$trigger" \
        || ! ack_event htop-tapped; }; } \
    || { [[ "$slug" != mosh ]] && ! wait_remote_file "$host" "$trigger.vim"; } \
    || ! capture_logged_frame "$log" vim-before "$test_pid" "$phase_dir/vim-before.png" \
    || ! ack_event vim-before \
    || ! capture_logged_frame "$log" vim-moved "$test_pid" "$phase_dir/vim-moved.png" \
    || ! ack_event vim-moved \
    || ! capture_logged_frame "$log" vim-restored "$test_pid" "$phase_dir/vim-restored.png" \
    || ! ack_event vim-restored \
    || { [[ "$input" == touch ]] \
      && ! check_vim_tap "$slug" "$host" "$phase_dir" "$log" "$test_pid"; }; then
    # Release the XCUITest at once instead of leaving it in a hold.
    touch "$ack_dir/abort"
    stop_recording "$record_pid"
    wait "$test_pid" || true
    current_ack_dir=''
    xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_VISUAL_CAPTURE_ACK_DIR >/dev/null 2>&1 || true
    return 1
  fi
  if ! wait "$test_pid"; then
    current_ack_dir=''
    stop_recording "$record_pid"
    xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_VISUAL_CAPTURE_ACK_DIR >/dev/null 2>&1 || true
    return 1
  fi
  current_ack_dir=''
  stop_recording "$record_pid"
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_VISUAL_CAPTURE_ACK_DIR >/dev/null 2>&1 || true

  xcrun xcresulttool get test-results summary --path "$result" \
    >"$phase_dir/xctest-summary.json"
  ffprobe -v error -show_entries format=duration,size -of json "$video" \
    >"$phase_dir/video-info.json"

  local phase
  for phase in primary htop vim; do
    ffmpeg -hide_banner -loglevel error \
      -i "$phase_dir/$phase-before.png" \
      -i "$phase_dir/$phase-moved.png" \
      -i "$phase_dir/$phase-restored.png" \
      -filter_complex \
        '[0:v]scale=640:-1[before];[1:v]scale=640:-1[moved];[2:v]scale=640:-1[restored];[before][moved][restored]hstack=inputs=3' \
      -frames:v 1 "$phase_dir/$phase-row.png" \
      -y 2>>"$phase_dir/evidence-sheet.log" || return 1
    ffmpeg -hide_banner -loglevel error \
      -i "$phase_dir/$phase-before.png" \
      -i "$phase_dir/$phase-moved.png" \
      -i "$phase_dir/$phase-restored.png" \
      -filter_complex '[0:v][1:v][2:v]vstack=inputs=3' \
      -frames:v 1 "$phase_dir/$phase-evidence.png" \
      -y 2>>"$phase_dir/evidence-sheet.log" || return 1
  done
  ffmpeg -hide_banner -loglevel error \
    -i "$phase_dir/primary-row.png" \
    -i "$phase_dir/htop-row.png" \
    -i "$phase_dir/vim-row.png" \
    -filter_complex '[0:v][1:v][2:v]vstack=inputs=3' \
    -frames:v 1 "$phase_dir/scroll-evidence.png" \
    -y 2>>"$phase_dir/evidence-sheet.log" || return 1
  if [[ "$input" == touch ]]; then
    # Restored state beside the state after one tap.
    for phase in htop vim; do
      ffmpeg -hide_banner -loglevel error \
        -i "$phase_dir/$phase-restored.png" \
        -i "$phase_dir/$phase-tapped.png" \
        -filter_complex '[0:v]scale=960:-1[restored];[1:v]scale=960:-1[tapped];[restored][tapped]hstack=inputs=2' \
        -frames:v 1 "$phase_dir/$phase-tap-evidence.png" \
        -y 2>>"$phase_dir/evidence-sheet.log" || return 1
    done
    rm "$phase_dir"/*-tapped.png
  fi
  rm "$phase_dir"/*-before.png "$phase_dir"/*-moved.png \
    "$phase_dir"/*-restored.png "$phase_dir"/*-row.png
}

# The program each transport runs. A case may redefine this after sourcing
# the library; the command must carry the trigger path as a word of its own,
# by which cleanup proves and ends it (end_scenario_processes).
scroll_scenario_command() {
  local label="$1" trigger="$2"
  printf '%s' "/usr/local/bin/tessera-fixture-probe scroll-scenario --label $label --trigger $trigger --count ${TESSERA_SCROLL_FIXTURE_ROWS:-600} --delay 0.001 --trigger-timeout 600 --htop-seconds 180 --vim-seconds 300"
}

capture_transport() {
  local mode="$1"
  local host="$2"
  local role="$3"
  local slug="${mode//-/_}"
  local label
  label="$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')"
  local session="tessera_scroll_${RUN_TOKEN}_${slug}"
  local trigger="/tmp/${session}.trigger"
  local scenario
  scenario="$(scroll_scenario_command "$label" "$trigger")"
  local uses_tmux=0
  [[ "$mode" == *-tmux ]] && uses_tmux=1

  local config_json config_b64
  config_json="$(jq -cn \
    --arg mode "$mode" \
    --arg address "$host" \
    --argjson port "$TESSERA_FIXTURE_APP_PORT" \
    --arg user "$TESSERA_FIXTURE_USER" \
    --arg password "$PASSWORD" \
    --arg launchCommand "$scenario" \
    --arg tmuxSessionName "$session" \
    '{mode:$mode,address:$address,port:$port,user:$user,password:$password,launchCommand:$launchCommand,tmuxSessionName:$tmuxSessionName}')"
  config_b64="$(printf '%s' "$config_json" | base64 | tr -d '\n')"

  # Every attempt uses the same session and trigger names, so the final
  # cleanup's reap also proves an earlier attempt's leftovers gone. A retry
  # path only records its own cleanup failure: the transient SSH failure a
  # retry exists for fails that reap too, and must not end the case before
  # the next attempt.
  local capture_status=1 attempt reap_failed=0
  for attempt in 1 2; do
    current_host="$host"
    current_session=''
    current_trigger="$trigger"
    if ! end_scenario_processes "$host" "$trigger" \
      || ! remove_trigger_files "$host" "$trigger" >/dev/null; then
      note "scroll fixture setup $slug attempt $attempt failed; retrying"
      cleanup_remote || reap_failed=1
      sleep 1
      continue
    fi

    if [[ $uses_tmux -eq 1 ]]; then
      current_session="$session"
      local create_session="tmux new-session -d -s '$session' -x 160 -y 50 '$scenario'"
      if [[ -n "${TESSERA_SCROLL_TMUX_HISTORY_LIMIT:-}" ]]; then
        # history-limit sizes a pane when it is created, so the scenario
        # replaces a placeholder window after the session-scoped option is
        # set; the fixture's global option stays untouched.
        [[ "$TESSERA_SCROLL_TMUX_HISTORY_LIMIT" =~ ^[1-9][0-9]*$ ]] \
          || die "TESSERA_SCROLL_TMUX_HISTORY_LIMIT must be a positive row count"
        create_session="tmux new-session -d -s '$session' -x 160 -y 50 'sleep 600' \\; set-option -t '$session' history-limit $TESSERA_SCROLL_TMUX_HISTORY_LIMIT \\; new-window -k -t '$session:0' '$scenario'"
      fi
      if ! fixture_ssh "$host" \
        "tmux kill-session -t '=$session' >/dev/null 2>&1 || true; $create_session"; then
        note "scroll tmux setup $slug attempt $attempt failed; retrying"
        cleanup_remote || reap_failed=1
        sleep 1
        continue
      fi
      if [[ "${TESSERA_SCROLL_SPLIT:-0}" == 1 ]]; then
        # Outlives the longest case (S13 at depth runs ~20 minutes); cleanup
        # kills the session.
        fixture_ssh "$host" "tmux split-window -h -d -t '$session:0' 'sleep 3600'" || return 1
      fi
      if [[ "${TESSERA_SCROLL_ASSERT_ATTACH_MOUSE:-0}" == 1 ]]; then
        fixture_ssh "$host" "tmux set-option -t '$session' mouse off; tmux display-message -p -t '$session' '#{mouse}'" \
          > "$CASE_DIR/$slug-mouse-before-attach.txt" || return 1
        [[ "$(cat "$CASE_DIR/$slug-mouse-before-attach.txt")" == 0 ]] || return 1
      fi
    fi

    # Reinstall before every transport. Other development sessions may build
    # the same bundle ID onto the booted simulator; a mid-capture replacement
    # is retried once below, while this guarantees the next attempt uses the
    # isolated integration DerivedData product.
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$APP_PATH"
    # The log stamps whole seconds first: start a second the terminated
    # process wrote nothing in.
    sleep 1
    local attempt_started
    attempt_started="$(date -u +%Y-%m-%dT%H:%M:%S)"
    clear_app_environment
    xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
    xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_HARNESS 1
    xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_PHYSICS "${TESSERA_SCROLL_PHYSICS:-0}"
    xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_INPUT "${TESSERA_SCROLL_INPUT:-pointer}"
    # Touch input keeps the terminal first responder by default: an
    # unfocused terminal's first tap only focuses it (handleMouseTap), so it
    # would never click. TESSERA_SCROLL_KEEP_KEYBOARD overrides either way.
    local keep_keyboard=0
    [[ "${TESSERA_SCROLL_INPUT:-pointer}" == touch ]] && keep_keyboard=1
    if [[ "${TESSERA_SCROLL_KEEP_KEYBOARD:-$keep_keyboard}" == 1 ]]; then
      xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_KEEP_KEYBOARD 1
    fi
    if [[ "${TESSERA_SCROLL_EXPOSE_ROWS:-0}" == 1 ]]; then
      xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_EXPOSE_ROWS 1
    fi
    if [[ "${TESSERA_SCROLL_PORTRAIT:-0}" == 1 ]]; then
      xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_PORTRAIT 1
    fi
    # The fraction of the window's width a case's fingers aim at (an S13
    # split's fixture pane): the harness exposes the terminal under it.
    if [[ -n "${TESSERA_SCROLL_AIM_X:-}" ]]; then
      xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_AIM_X "$TESSERA_SCROLL_AIM_X"
    fi
    if drops_client_mouse "$mode"; then
      xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_DROP_CLIENT_MOUSE 1
    fi
    xcrun simctl spawn "$UDID" launchctl setenv \
      TESSERA_LIVE_SCROLL_CONFIG_B64 "$config_b64"
    xcrun simctl launch "$UDID" "$BUNDLE_ID" \
      >"$CASE_DIR/$slug-launch-attempt-$attempt.txt"

    set +e
    capture_sequence "$slug" "$host" "$trigger"
    capture_status=$?
    set -e
    preserve_app_diagnostics "$slug" "$attempt"
    if [[ $capture_status -eq 0 ]] && drops_client_mouse "$mode" \
      && ! check_client_mouse_dropped "$slug" "$attempt" "$attempt_started"; then
      capture_status=1
    fi
    [[ $capture_status -eq 0 ]] && break

    note "scroll capture $slug attempt $attempt failed; reinstalling and retrying"
    preserve_failed_attempt "$slug" "$attempt"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    clear_app_environment
    cleanup_remote || reap_failed=1
  done
  if [[ $capture_status -ne 0 ]]; then
    [[ $reap_failed -eq 0 ]] || note "scroll $slug cleanup also failed; see $CASE_DIR/fixture-reap.txt"
    return "$capture_status"
  fi

  jq -n \
    --arg mode "$mode" \
    --argjson physics "${TESSERA_SCROLL_PHYSICS:-0}" \
    --arg fixtureRole "$role" \
    --arg tmuxVersion "$(fixture_ssh "$host" tmux -V)" \
    --arg input "${TESSERA_SCROLL_INPUT:-pointer}" \
    --arg tmuxMouse "${TESSERA_SCROLL_TMUX_MOUSE:-on}" \
    --argjson clientMouseDropped "$(drops_client_mouse "$mode" && echo true || echo false)" \
    --slurpfile primaryMotion "$CASE_DIR/$slug/primary-motion.json" \
    '{mode:$mode,fixture_role:$fixtureRole,tmux_version:$tmuxVersion,input:$input,tmux_mouse:$tmuxMouse,client_mouse_dropped:$clientMouseDropped,phases:(if $physics == 1 then ["first-flick","second-flick"] else ["primary","htop","vim"] end),vim_graded:($physics != 1 and $mode != "mosh"),primary_motion_precheck:$primaryMotion[0]}' \
    >"$CASE_DIR/$slug/transport.json"

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  clear_app_environment
  # The hard check. Its reap covers every attempt's names, so it alone
  # decides whether an earlier attempt's failed cleanup left anything.
  cleanup_remote || return 1
  [[ $reap_failed -eq 0 ]] || note "scroll $slug: the final reap proved an earlier attempt's failed cleanup left nothing"
}

capture_selected_transport() {
  case "$1" in
    ssh) capture_transport ssh "$TESSERA_FIXTURE_STABLE_HOST" stable ;;
    ssh-tmux) capture_transport ssh-tmux "$TESSERA_FIXTURE_STABLE_HOST" stable ;;
    mosh) capture_transport mosh "$TESSERA_FIXTURE_CHAOS_HOST" chaos ;;
    mosh-tmux) capture_transport mosh-tmux "$TESSERA_FIXTURE_CHAOS_HOST" chaos ;;
    *) die "unknown scroll transport: $1" ;;
  esac
}

# The momentum case shares the exact fixture lifecycle and ownership cleanup.
if [[ "${TESSERA_SCROLL_CAPTURE_LIBRARY:-0}" == 1 ]]; then return 0; fi

for selected_transport in ${TESSERA_SCROLL_TRANSPORTS:-ssh ssh-tmux mosh mosh-tmux}; do
  capture_selected_transport "$selected_transport"
done

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "S1-S6-live-scroll-transports",
  "title": "Real primary and alternate-screen scrolling across all four transports",
  "matrix_ids": ["S1", "S6"],
  "invariants": [
    "SSH, SSH+tmux, mosh, and mosh+tmux each render their deterministic numbered primary-screen tail before interaction.",
    "A real XCUITest indirect-pointer scroll reveals earlier numbered primary history on every transport, then the reverse scroll returns to the live tail. A frozen/no-op scroll is a failure.",
    "No primary-scroll phase shows black panes, stale transport content, half-width/colored tails, garbled lines, or a geometry jump.",
    "In htop on every transport, scrolling visibly changes the selection or process-list position while remaining a coherent htop screen; reversing remains responsive. Literal escape bytes or a frozen screen fail.",
    "In vim with mouse=a on SSH, SSH+tmux, and mosh+tmux, scrolling visibly changes the numbered file range through mouse-wheel forwarding and reversing remains coherent. Literal escape bytes, black frames, or no motion fail. Plain-mosh Vim is diagnostic-only because the remote htop-to-Vim fixture transition cannot be controlled reliably while htop owns the mosh PTY.",
    "With mouse reporting enabled on the active tmux view, all primary milestones retain pane_in_mode=0 with no remote copy-mode indicator.",
    "The four transport results are behaviorally consistent even though SSH uses local scrollback and mosh+tmux may reveal a capture-pane overlay."
  ],
  "capture_notes": "Each transport has a 3x3 summary assembled from external simctl screenshots captured at timestamped XCUITest milestones while one continuous simctl recording runs. Rows are primary, htop, and vim; columns are before, after the first gesture, and after the reverse gesture. Full-resolution primary/htop/vim companion images stack those same states top-to-bottom so character ranges and selections remain legible. Plain-mosh Vim is retained as diagnostic evidence but is not graded; primary and htop are graded on all four transports and Vim is graded on the other three. Raw .mov files, XCUITest event logs, result summaries, and video metadata accompany the images. Connections are created programmatically from an ignored ephemeral fixture configuration; UI automation never opens a host. Plain-mosh received history can contain gaps already present before this optimization; compare baseline evidence when diagnosing a regression. Mosh+tmux capture-pane history remains graded for contiguous rows.",
  "deterministic_precheck": {"verdict": "pass", "detail": "The four continuous XCUITest drivers completed all primary, htop, and vim stages before this manifest was finalized, and every transport's first primary gesture visibly changed at least a quarter of the screen's horizontal bands between primary-before and primary-moved (a frozen reveal fails the capture before review; see each transport.json primary_motion_precheck)."}
}
JSON
script_completed=1
