#!/usr/bin/env bash
# Finger scrolling through primary-screen history (a shell, Claude Code's
# classic UI) under tmux's default `mouse off`. mosh relays only the visible
# screen, so on mosh+tmux every row above it must come from tmux; a trackpad
# fetched it while a finger drag only moved the empty local scroll view. The
# XCUITest reads the fixture rows on screen from the app's DEBUG harness and
# must reach the oldest row, return to the live tail with the heartbeat moving
# again, and reveal history a second time; screenshots must show each step.
# While the reader holds its first reveal, the pane prints
# TESSERA_SCROLL_STREAM_BURST_LINES new lines (default 8; Claude Code
# finishing messages in synchronized frames), and the reader must stay put.
# Variants: TESSERA_SCROLL_SPLIT=1 (an iPad split: history in the focused
# pane's overlay), TESSERA_SCROLL_TMUX_HISTORY_LIMIT with more fixture rows
# (deep tmux history, where SSH+tmux must deepen past its 2000-row attach
# capture; s13-touch-deep-history.sh runs it), TESSERA_SCROLL_PORTRAIT=1 and
# an iPhone device type.
# TESSERA_SCROLL_TOUCH_TRANSPORTS may select fewer transports to diagnose
# one; such a run never passes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TESSERA_SCROLL_CAPTURE_LIBRARY=1
export TESSERA_SCROLL_CASE_ID="${TESSERA_SCROLL_CASE_ID:-S13-touch-primary-history}"
export TESSERA_SCROLL_TMUX_MOUSE="${TESSERA_SCROLL_TMUX_MOUSE:-off}"
export TESSERA_SCROLL_INPUT=touch
# A hardware-keyboard iPad has no software keyboard over the rows.
export TESSERA_SCROLL_KEEP_KEYBOARD="${TESSERA_SCROLL_KEEP_KEYBOARD:-0}"
export TESSERA_SCROLL_PHYSICS=1
export TESSERA_SCROLL_EXPOSE_ROWS=1
# A split's fingers land on the left (fixture) pane, not the divider; the
# harness reads the terminal under that point of the window.
if [[ "${TESSERA_SCROLL_SPLIT:-0}" == 1 ]]; then
  export TESSERA_SCROLL_AIM_X=0.25
fi
# More than the first mosh+tmux history page, within tmux's default
# history-limit (at iPad widths) and the app's default local scrollback.
export TESSERA_SCROLL_FIXTURE_ROWS="${TESSERA_SCROLL_FIXTURE_ROWS:-1500}"
# A phone in portrait is narrower than a fixture row: tmux reflows each row
# onto two lines, past its default 2000-line history-limit, and trims the
# oldest at the next scroll. Portrait runs give the pane room for them, so
# SSH+tmux fingers must also deepen past the 2000-line attach capture.
if [[ "${TESSERA_SCROLL_PORTRAIT:-0}" == 1 ]]; then
  portrait_history_limit=$((TESSERA_SCROLL_FIXTURE_ROWS * 4))
  (( portrait_history_limit >= 10000 )) || portrait_history_limit=10000
  export TESSERA_SCROLL_TMUX_HISTORY_LIMIT="${TESSERA_SCROLL_TMUX_HISTORY_LIMIT:-$portrait_history_limit}"
fi
# A failed attempt keeps this case's own result bundle, and each variant
# keeps its own beside S13's in a shared run.
SCROLL_RESULT_PREFIX="touch-history${TESSERA_SCROLL_CASE_ID#S13-touch-primary-history}"
source "$HERE/visual-cases/s1-s6-live-scroll-transports.sh" "${1:?run directory}"
# Both reach a remote shell command. Fixture rows carry five digits, and a
# burst prints two lines a second within the milestone's capture hold.
[[ "$TESSERA_SCROLL_FIXTURE_ROWS" =~ ^[1-9][0-9]{0,4}$ ]] \
  || die 'TESSERA_SCROLL_FIXTURE_ROWS must be a row count below 100000'
# An XCUITest flick moves about 85 rows and takes about 7 s with its idle
# waits, so the oldest and tail milestones of 6000 rows arrive ~8 minutes
# after the one before. Allow twice the expected time.
LOG_EVENT_TIMEOUT_SECONDS=$((120 + TESSERA_SCROLL_FIXTURE_ROWS / 6))
TESSERA_SCROLL_STREAM_BURST_LINES="${TESSERA_SCROLL_STREAM_BURST_LINES:-8}"
[[ "$TESSERA_SCROLL_STREAM_BURST_LINES" =~ ^(0|[1-9][0-9]?)$ ]] \
  || die 'TESSERA_SCROLL_STREAM_BURST_LINES must be a line count below 100'

# A screen of terminal rows: frames only differing from each other could be
# black or blank. Real milestone frames score >= 0.90, a black terminal under
# the app's chrome 0.03.
FRAME_TEXT_MIN_FRACTION=0.75

# Prints the fraction of 64 horizontal bands of a PNG in which at least one
# of 32 cells holds edges (glyphs), whatever the theme's colours.
text_fraction() {
  local yavg
  yavg="$(ffmpeg -hide_banner -loglevel error -i "$1" \
    -lavfi "format=gray,edgedetect=low=0.1:high=0.3,scale=32:64:flags=area,lutyuv=y='if(gt(val,6),255,0)',scale=1:64:flags=area,lutyuv=y='if(gt(val,4),255,0)',signalstats,metadata=print:file=-" \
    -frames:v 1 -f null - 2>/dev/null | sed -n 's/^lavfi.signalstats.YAVG=//p' | head -1)"
  [[ -n "$yavg" ]] || return 1
  awk -v y="$yavg" 'BEGIN { printf "%.4f\n", y / 255 }'
}

remote_scenario="/tmp/tessera_primary_history_${RUN_TOKEN}.py"

scroll_scenario_command() {
  local label="$1" trigger="$2"
  printf '%s' "python3 $remote_scenario --label $label --count $TESSERA_SCROLL_FIXTURE_ROWS --trigger $trigger --burst-lines $TESSERA_SCROLL_STREAM_BURST_LINES"
}

# Makes the scenario print its burst while the reader holds the first reveal,
# and waits until every line is out. The deeper history the flicks fetch next
# then holds rows newer than the reader's page.
stream_burst() {
  local host="$1" trigger="$2"
  (( TESSERA_SCROLL_STREAM_BURST_LINES > 0 )) || return 0
  fixture_ssh "$host" "touch '$trigger.burst'; for _ in \$(seq 1 $((TESSERA_SCROLL_STREAM_BURST_LINES * 2 + 20))); do [ -e '$trigger.burst.done' ] && exit 0; sleep 0.5; done; exit 1" \
    || { printf 'the fixture never finished its %s-line burst\n' "$TESSERA_SCROLL_STREAM_BURST_LINES" >&2; return 1; }
}

upload_scenario() {
  fixture_ssh "$1" "cat > '$remote_scenario'" <"$HERE/remote/primary-history-scenario.py"
}

remove_scenarios() {
  local host status=0
  for host in "$TESSERA_FIXTURE_STABLE_HOST" "$TESSERA_FIXTURE_CHAOS_HOST"; do
    fixture_ssh "$host" "rm -f '$remote_scenario' /tmp/tessera_scroll_${RUN_TOKEN}_*.trigger.burst /tmp/tessera_scroll_${RUN_TOKEN}_*.trigger.burst.done" \
      >/dev/null 2>&1 || { printf 'could not remove the scenario files from %s\n' "$host" >&2; status=1; }
  done
  return "$status"
}

# A fixture left with this run's files fails the run, even after a pass.
touch_history_cleanup() {
  cleanup
  remove_scenarios || exit 1
}
trap 'fail_closed_trap touch_history_cleanup' EXIT

TOUCH_HISTORY_EVENTS=(
  touch-history-before
  touch-history-revealed
  touch-history-oldest
  touch-history-tail
  touch-history-reentered
  touch-history-final
)

capture_sequence() {
  local slug="$1" host="$2" trigger="$3"
  local phase_dir="$CASE_DIR/$slug"
  local log="$phase_dir/xctest.log"
  local ack_dir="$phase_dir/acks"
  rm -rf "$phase_dir"
  mkdir -p "$phase_dir" "$ack_dir"

  # Plain mosh keeps only the frames it happened to paint; its oldest loaded
  # row is enough there.
  local oldest=1
  [[ "$slug" == mosh ]] && oldest=0
  # The app's diagnostics from this attempt on: mosh+tmux logs each deepen
  # of a page frozen by output, with the rows it dropped.
  local attempt_started
  attempt_started="$(date -u +%Y-%m-%dT%H:%M:%S)"
  xcrun simctl spawn "$UDID" launchctl setenv TESSERA_TOUCH_HISTORY_OLDEST_ROW "$oldest" || return 1
  xcrun simctl spawn "$UDID" launchctl setenv TESSERA_TOUCH_HISTORY_BURST_LINES "$TESSERA_SCROLL_STREAM_BURST_LINES" \
    || return 1
  # A split's fingers land on the left (fixture) pane, not the divider: a
  # quarter across the mosh surface, which spans both panes, or across the
  # SSH+tmux pane the harness exposes.
  if [[ "${TESSERA_SCROLL_SPLIT:-0}" == 1 ]]; then
    xcrun simctl spawn "$UDID" launchctl setenv TESSERA_TOUCH_HISTORY_DRAG_X 0.25 || return 1
  fi

  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$phase_dir/touch-history.mov" \
    >"$phase_dir/record-video.log" 2>&1 &
  local record_pid=$!
  for _ in {1..50}; do
    grep -q 'Recording started' "$phase_dir/record-video.log" && break
    sleep 0.1
  done
  if ! xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE_ACK_DIR "$ack_dir"; then
    stop_recording "$record_pid"
    printf 'could not pass the capture acknowledgement directory to the simulator\n' >&2
    return 1
  fi
  current_ack_dir="$ack_dir"
  run_ui_test testLiveTouchPrimaryHistory "$log" "$VISUAL_ROOT/$SCROLL_RESULT_PREFIX-$slug.xcresult" &
  local test_pid=$!
  local capture_status=0 event
  for event in "${TOUCH_HISTORY_EVENTS[@]}"; do
    if ! capture_logged_frame "$log" "$event" "$test_pid" "$phase_dir/$event.png" \
      || { [[ "$event" == touch-history-before ]] && ! record_pane_history "$slug" "$host" "$phase_dir"; } \
      || { [[ "$event" == touch-history-before ]] && ! enable_fixture_tmux_mouse "$slug" "$host" "$phase_dir"; } \
      || { [[ "$event" == touch-history-revealed ]] && ! stream_burst "$host" "$trigger"; } \
      || ! capture_primary_tmux_mode "$slug" "$host" "$phase_dir" "$event" \
      || ! record_split_focus "$slug" "$host" "$phase_dir" "$event"; then
      capture_status=1
      break
    fi
    # At the live tail a second frame must show the heartbeat painted again.
    if [[ "$event" == touch-history-before || "$event" == touch-history-tail \
      || "$event" == touch-history-final ]]; then
      sleep 1.5
      take_landscape_screenshot "$phase_dir/$event-later.png" "$event-later" || { capture_status=1; break; }
    fi
    ack_event "$event"
  done
  if [[ "$capture_status" != 0 ]]; then
    touch "$ack_dir/abort"
  fi
  wait "$test_pid" || capture_status=1
  current_ack_dir=''
  stop_recording "$record_pid"
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_VISUAL_CAPTURE_ACK_DIR >/dev/null 2>&1 || true
  grep -o 'TESSERA_TOUCH_ROWS .*' "$log" >"$phase_dir/touch-rows.log" || true
  [[ "$capture_status" == 0 ]] || return 1

  xcrun xcresulttool get test-results summary --path "$VISUAL_ROOT/$SCROLL_RESULT_PREFIX-$slug.xcresult" \
    >"$phase_dir/xctest-summary.json" || return 1
  jq -e '.result == "Passed" and .passedTests > 0' "$phase_dir/xctest-summary.json" >/dev/null \
    || { printf 'the XCTest result summary does not show the passed test\n' >&2; return 1; }
  # Pixel changes between milestone frames: what the XCUITest read from the
  # terminal buffer must also have reached the screen.
  local pair first second fraction
  : >"$phase_dir/frame-motion.txt"
  for pair in before:revealed before:oldest oldest:tail tail:reentered reentered:final \
    before:tail before:before-later tail:tail-later final:final-later; do
    first="${pair%%:*}" second="${pair#*:}"
    fraction="$(motion_fraction "$phase_dir/touch-history-$first.png" "$phase_dir/touch-history-$second.png")" \
      || fraction=''
    printf '%s %s\n' "$pair" "${fraction:--}" >>"$phase_dir/frame-motion.txt"
  done
  : >"$phase_dir/frame-text.txt"
  for event in "${TOUCH_HISTORY_EVENTS[@]}"; do
    fraction="$(text_fraction "$phase_dir/$event.png")" || fraction=''
    printf '%s %s\n' "${event#touch-history-}" "${fraction:--}" >>"$phase_dir/frame-text.txt"
  done
  local app_log
  app_log="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Library/Application Support/Diagnostics/tessera-diagnostics.log" \
    || return 1
  # The command a plain shell echoes above the fixture's first row.
  local scenario_command
  scenario_command="$(scroll_scenario_command "$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')" "$trigger")"
  python3 - "$phase_dir" "$slug" "$oldest" "$TESSERA_SCROLL_FIXTURE_ROWS" \
    "$PRIMARY_MOTION_MIN_FRACTION" "${TESSERA_SCROLL_TMUX_HISTORY_LIMIT:-}" \
    "$TESSERA_SCROLL_STREAM_BURST_LINES" "$app_log" "$attempt_started" "$FRAME_TEXT_MIN_FRACTION" \
    "${#scenario_command}" <<'PY' || return 1
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1]); slug = sys.argv[2]
oldest = int(sys.argv[3]); count = int(sys.argv[4]); minimum = float(sys.argv[5])
history_limit = int(sys.argv[6]) if sys.argv[6] else None
burst = int(sys.argv[7]); app_log = pathlib.Path(sys.argv[8]); started = sys.argv[9]
text_minimum = float(sys.argv[10]); command_length = int(sys.argv[11])
# RenderLedger's first SSH+tmux capture (`deepHistoryDepth`).
INLINE_ATTACH_DEPTH = 2000
text = {}
for line in (root / "frame-text.txt").read_text().splitlines():
    frame, value = line.split(" ")
    text[frame] = float(value) if value != "-" else None
# Rotation keeps the log's tail; its UTC timestamps sort as text.
diagnostics = [line for line in (app_log.read_text(errors="replace").splitlines() if app_log.exists() else [])
    if line[:19] >= started]
# Each anchored deepen as (dropped, expected, anchor), and whether output
# had frozen the page before it. Only verbose diagnostics (the lane's) log
# the freeze and a lost or ambiguous anchor.
anchored = []
frozen_before = False
for line in diagnostics:
    if re.search(r"render-ledger side-channel-frozen(-after-presentation)? surface=", line):
        frozen_before = True
    m = re.search(r"side-channel-anchored-deepen surface=\S+ dropped=(\d+) expected=(-?\d+|-) anchor=(\w+)(?:\s|$)", line)
    if m:
        anchored.append({"dropped": int(m.group(1)), "expected": m.group(2), "anchor": m.group(3),
                         "after_freeze": frozen_before})
anchor_lost = sum(re.search(r"reason=frozen-anchor-(lost|ambiguous)", line) is not None for line in diagnostics)
# SSH+tmux: the gate's requests, and the depth of each settle that answered one.
inline_requests = sum(re.search(r"render-ledger inline-history-request surface=", line) is not None
    for line in diagnostics)
inline_deepened = [int(m.group(1)) for m in (re.search(
    r"render-ledger inline-history-settled surface=\S+ depth=(\d+) .*requested=true(?:\s|$)", line)
    for line in diagnostics) if m]
motion = {}
for line in (root / "frame-motion.txt").read_text().splitlines():
    pair, value = line.split(" ")
    motion[pair] = float(value) if value != "-" else None
def moved(pair):
    return motion.get(pair) is not None and motion[pair] >= minimum
def still_but_ticking(pair):
    # Only the heartbeat line (and at most a cursor) changed.
    return motion.get(pair) is not None and 0 < motion[pair] <= 0.1
pane = None
pane_file = root / "pane-history.txt"
if pane_file.exists():
    limit, size = (int(n) for n in pane_file.read_text().split()[:2])
    pane = {"history_limit": limit, "history_size": size}
stages = {}
readouts = []
flicks = {"up": 0, "down": 0}
for line in (root / "touch-rows.log").read_text().splitlines():
    _, stage, *rest = line.split(" ")
    fields = dict(f.split("=", 1) for f in rest if "=" in f)
    stages[stage] = fields
    readouts.append((stage, fields))
    for direction in flicks:
        if stage.startswith(direction + "-"):
            flicks[direction] += 1
def rows(stage):
    value = stages.get(stage, {}).get("rows", "-")
    return tuple(int(n) for n in value.split("-")) if value != "-" else None
def number(stage, field):
    value = stages.get(stage, {}).get(field, "")
    return int(value) if value.isdigit() else None
start, revealed, held, tail, again, final = (rows(s) for s in ("start", "revealed", "held", "tail", "reentered", "final"))
# How many rows the burst added to the terminal behind the reader.
burst_arrived = (number("held", "lines") - number("revealed", "lines")
    if number("held", "lines") is not None and number("revealed", "lines") is not None else None)
up = [s for s in stages if s.startswith("up-")]
reached = rows(up[-1]) if up else revealed
# Plain mosh keeps only the frames it painted, so its local rows skip.
contiguous = [s for s, f in readouts if f.get("rows", "-") != "-" and f.get("order") != "1"]
# Every readout's screen is at least 80% fixture rows: no blank or stale
# partial page. Below the fixture's last row come only the ready line, the
# burst's lines and the heartbeat's (plus a row of slack). A terminal
# narrower than a fixture row (an iPhone in portrait) wraps each one onto
# several screen lines, which the readout's width (cols) tells. Above the
# fixture's first row come only the shell's prompt and the scenario's
# command, which a plain shell echoes twice (typed ahead, then after the
# prompt): at the head of the history no more than those lines may show.
row_width = len(f"TESSERA_SCROLL_{slug.upper()}_00001 | 0123456789abcdef0123456789abcdef")
def sparse_readout(fields):
    n, screen, shown = fields.get("n", ""), fields.get("screen", ""), fields.get("rows", "-")
    cols = fields.get("cols", "")
    if not (n.isdigit() and screen.isdigit() and cols.isdigit()) or int(screen) < 10 \
            or int(cols) < 10 or shown == "-":
        return True
    cols = int(cols)
    n = int(n) * -(-row_width // cols)
    screen = int(screen)
    if int(shown.split("-")[0]) == 1:
        # tmux runs the scenario as the pane's command: above row 1 at most
        # a partly shown line.
        preamble = 1 if slug.endswith("tmux") else 2 * -(-(command_length + 2) // cols) + 2
        return screen - n > preamble
    if int(shown.split("-")[1]) == count:
        return n < screen - (burst + 4) or n * 2 < screen
    return n * 5 < screen * 4
sparse = [s for s, f in readouts if sparse_readout(f)]
checks = {
    "start_at_tail": stages.get("start", {}).get("tail") == "1" and start is not None and start[1] == count,
    "first_drag_revealed": revealed is not None and start is not None and revealed[1] < start[1],
    "reached_oldest": (reached is not None and reached[0] == oldest) if oldest else
        stages.get(up[-1] if up else "revealed", {}).get("top") == "1",
    "returned_to_tail": stages.get("tail", {}).get("tail") == "1" and tail is not None and tail[1] == count,
    "second_drag_revealed": again is not None and tail is not None and again[1] < tail[1],
    "final_at_tail": stages.get("final", {}).get("tail") == "1" and final is not None and final[1] == count,
    "rows_contiguous": slug == "mosh" or not contiguous,
    "rows_fill_screen": bool(readouts) and not sparse,
    "frames_show_text": len(text) == 6 and all(v is not None and v >= text_minimum for v in text.values()),
    "first_drag_moved_pixels": moved("before:revealed"),
    "oldest_painted": moved("before:oldest"),
    # Not compared with "before": the terminal places its live rows from the
    # top, while a scroll back comes to rest at the scroll view's end, up to
    # a row lower until output scrolls (before:tail stays informational).
    "tail_painted": moved("oldest:tail"),
    "second_drag_painted": moved("tail:reentered") and moved("reentered:final"),
    "heartbeat_painted": all(still_but_ticking(p) for p in
        ("before:before-later", "tail:tail-later", "final:final-later")),
}
if slug.endswith("tmux"):
    checks["pane_holds_fixture"] = pane is not None and pane["history_size"] >= count - 60 and (
        history_limit is None or pane["history_limit"] == history_limit)
active_file = root / "pane-active.txt"
if active_file.exists():
    # At every milestone the split stood and its fixture pane was tmux's
    # active pane ("<milestone> <pane_active> <window_panes>").
    samples = dict(line.split(" ", 1) for line in active_file.read_text().splitlines() if " " in line)
    checks["split_focus_kept"] = set(samples) >= {"before", "revealed", "oldest", "tail", "reentered", "final"} \
        and all(value.split() == ["1", "2"] for value in samples.values())
# Output while reading history (the heartbeat, the burst) leaves the reader
# on its rows. Plain mosh relays only screens, without the burst's
# synchronized frames, and its terminal follows scrolling output to the tail
# as it does under a trackpad: there this is informational.
held_still = held is not None and held == revealed
if slug != "mosh" or burst == 0:
    checks["reader_held_during_output"] = held_still
if burst > 0 and slug in ("ssh", "ssh_tmux"):
    # The held readout came after the burst reached this terminal's
    # scrollback (plain mosh keeps only the frames it paints; mosh+tmux
    # proves the burst through its anchored deepen).
    checks["burst_reached_terminal"] = burst_arrived is not None and burst_arrived >= burst
if slug in ("ssh_tmux", "mosh_tmux"):
    # A rotation keeps only the log's tail, and these checks read the
    # attempt's diagnostics, some for lines that must be absent.
    checks["diagnostics_complete"] = app_log.exists() and not any(
        "[DiagnosticLog] rotated" in line for line in diagnostics)
if slug == "ssh_tmux" and pane is not None and pane["history_size"] > INLINE_ATTACH_DEPTH:
    # The attach capture holds only the newest rows; finger flicks (not a
    # trackpad's underflow) asked the ledger for the rest.
    checks["inline_history_deepened"] = inline_requests > 0 and any(
        depth >= count - 60 for depth in inline_deepened)
if slug == "mosh_tmux":
    # The heartbeat froze the first page, so the flicks' deeper history was
    # aligned to the whole page: exactly the burst's rows were newer.
    checks["frozen_page_deepened"] = not anchor_lost and any(
        a["after_freeze"] and a["anchor"] == "page" and a["dropped"] == burst and a["expected"] == str(burst)
        for a in anchored)
verdict = "pass" if all(checks.values()) else "fail"
summary = {
    "verdict": verdict, "checks": checks, "oldest_row_required": oldest or "oldest loaded",
    "fixture_rows": count, "flicks": flicks, "tmux_pane": pane,
    "changed_band_fraction": motion, "rows_out_of_order_at": contiguous,
    "text_band_fraction": text, "sparse_readouts": sparse,
    "stream_burst_lines": burst, "burst_rows_reached_terminal": burst_arrived,
    "reader_held": held_still, "anchored_deepens": anchored, "anchor_lost_or_ambiguous": anchor_lost,
    "inline_history_requests": inline_requests, "inline_history_deepened_to": inline_deepened,
    "stages": {k: stages[k] for k in ("start", "revealed", "held", "tail", "reentered", "final") if k in stages},
    "oldest_stage": stages.get(up[-1]) if up else None,
}
(root / "primary-motion.json").write_text(json.dumps(summary, indent=2) + "\n")
if verdict != "pass":
    sys.exit(f"{slug}: finger history checks failed: {[k for k, v in checks.items() if not v]}")
PY
  ffmpeg -hide_banner -loglevel error \
    -i "$phase_dir/touch-history-before.png" -i "$phase_dir/touch-history-revealed.png" \
    -i "$phase_dir/touch-history-oldest.png" -i "$phase_dir/touch-history-tail.png" \
    -i "$phase_dir/touch-history-reentered.png" -i "$phase_dir/touch-history-final.png" \
    -filter_complex '[0:v]scale=640:-1[a];[1:v]scale=640:-1[b];[2:v]scale=640:-1[c];[3:v]scale=640:-1[d];[4:v]scale=640:-1[e];[5:v]scale=640:-1[f];[a][b][c]hstack=inputs=3[top];[d][e][f]hstack=inputs=3[bottom];[top][bottom]vstack=inputs=2' \
    -frames:v 1 "$phase_dir/touch-history-evidence.png" -y 2>>"$phase_dir/evidence-sheet.log" || return 1
  for event in "${TOUCH_HISTORY_EVENTS[@]}"; do rm -f "$phase_dir/$event.png"; done
  rm -f "$phase_dir"/touch-history-*-later.png
  # Thirty frames across the whole recording; ffmpeg applies its rotation.
  local duration
  duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$phase_dir/touch-history.mov")" \
    || return 1
  ffmpeg -hide_banner -loglevel error -i "$phase_dir/touch-history.mov" \
    -vf "fps=30/$duration,scale=480:-1,tile=6x5" -frames:v 1 -y "$phase_dir/motion-sequence.jpg" || return 1
}

# The pane's scrollback size and depth when the reader starts: the fixture
# rows must all be in tmux history (and deep variants get their limit).
record_pane_history() {
  local slug="$1" host="$2" phase_dir="$3" limit size width height row
  [[ "$slug" == *tmux ]] || return 0
  fixture_ssh "$host" "tmux display-message -p -t '$current_session:0.0' '#{history_limit} #{history_size} #{pane_width} #{pane_height}'" \
    >"$phase_dir/pane-history.txt"
  read -r limit size width height <"$phase_dir/pane-history.txt" || return 1
  [[ "$limit $size $width $height" =~ ^[0-9]+\ [0-9]+\ [1-9][0-9]*\ [0-9]+$ ]] || {
    printf '%s: unreadable pane history: %s\n' "$slug" "$(cat "$phase_dir/pane-history.txt")" >&2
    return 1
  }
  # Over its limit (rows reflowed for a narrow client), tmux drops the
  # oldest rows at the next scroll, before the reader gets there; under
  # the fixture's rows at the pane's width, it already has.
  row="TESSERA_SCROLL_$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')_00001 | 0123456789abcdef0123456789abcdef"
  if (( size > limit \
      || size + height < TESSERA_SCROLL_FIXTURE_ROWS * ((${#row} + width - 1) / width) - 60 )); then
    printf '%s: the pane holds %s history lines (limit %s, %sx%s) for %s fixture rows; raise TESSERA_SCROLL_TMUX_HISTORY_LIMIT\n' \
      "$slug" "$size" "$limit" "$width" "$height" "$TESSERA_SCROLL_FIXTURE_ROWS" >&2
    return 1
  fi
}

# The split was made without selecting its new pane. On tmux 3.4 the app's
# colour fallback (`select-pane -P`) used to select whichever pane it styled
# last, seconds after attach as each pane became ready, and so moved the
# user's typing. At every milestone the split must still stand, with its
# fixture pane active.
record_split_focus() {
  local slug="$1" host="$2" phase_dir="$3" event="$4" state
  [[ "${TESSERA_SCROLL_SPLIT:-0}" == 1 && "$slug" == *tmux ]] || return 0
  state="$(fixture_ssh "$host" "tmux display-message -p -t '$current_session:0.0' '#{pane_active} #{window_panes}'")" \
    || return 1
  printf '%s %s\n' "${event#touch-history-}" "$state" >>"$phase_dir/pane-active.txt"
}

transports="${TESSERA_SCROLL_TOUCH_TRANSPORTS:-ssh ssh-tmux mosh mosh-tmux}"
read -r -a selected <<<"$transports"
(( ${#selected[@]} > 0 )) || die 'TESSERA_SCROLL_TOUCH_TRANSPORTS selects no transport'
upload_scenario "$TESSERA_FIXTURE_STABLE_HOST"
upload_scenario "$TESSERA_FIXTURE_CHAOS_HOST"
for selected_transport in "${selected[@]}"; do
  capture_selected_transport "$selected_transport"
  transport_json="$CASE_DIR/${selected_transport//-/_}/transport.json"
  jq '.phases = ["before", "revealed", "oldest", "tail", "reentered", "final"] | del(.vim_graded)' \
    "$transport_json" >"$transport_json.tmp"
  mv "$transport_json.tmp" "$transport_json"
done

jq -n --arg transports "${selected[*]}" --arg mouse "$TESSERA_SCROLL_TMUX_MOUSE" \
  --arg split "${TESSERA_SCROLL_SPLIT:-0}" --arg limit "${TESSERA_SCROLL_TMUX_HISTORY_LIMIT:-}" \
  --arg portrait "${TESSERA_SCROLL_PORTRAIT:-0}" --argjson rows "$TESSERA_SCROLL_FIXTURE_ROWS" \
  --arg keyboard "$TESSERA_SCROLL_KEEP_KEYBOARD" --argjson burst "$TESSERA_SCROLL_STREAM_BURST_LINES" \
  '{transports:($transports | split(" ")), tmux_mouse:$mouse, split:($split == "1"),
    tmux_history_limit:(if $limit == "" then null else ($limit | tonumber) end),
    portrait:($portrait == "1"), software_keyboard:($keyboard == "1"), fixture_rows:$rows,
    stream_burst_lines:$burst}' \
  >"$CASE_DIR/transports.json"
cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "S13-touch-primary-history",
  "title": "Finger scrolling through primary-screen history",
  "matrix_ids": ["S1", "S3", "S13"],
  "invariants": [
    "A slow finger drag down on a primary screen (numbered fixture rows, like a shell or Claude Code's classic UI) reveals earlier rows, with tmux's `mouse` option as transports.json records (off by default).",
    "Finger flicks keep going through history to the oldest row: TESSERA_SCROLL_*_00001 on SSH, SSH+tmux and mosh+tmux (tmux history beyond the first fetched page), and the oldest loaded row on plain mosh, which keeps only the frames it painted.",
    "Finger flicks back down return to the live tail, where the fixture heartbeat (TESSERA_TICK_nnnnn redrawn on the cursor's line, like Claude Code's status line) moves again on screen: output is not frozen after reading history.",
    "A second slow drag after the return reveals history again, and the view returns to the live tail once more.",
    "The reader stays on the rows it revealed while the pane keeps ticking and prints transports.json's stream_burst_lines new lines in synchronized frames (Claude Code finishing messages), on SSH and SSH+tmux after those rows reached the terminal. Plain mosh relays only screens, and its terminal follows scrolling output to the tail as under a trackpad, so there the held rows are only recorded. Flicks still reach the oldest row afterwards, and on mosh+tmux the deeper history is aligned to the reader's whole page after output froze it: the app logs an anchored deepen with dropped and expected both equal to the burst.",
    "When the SSH+tmux pane holds more history than the app's 2000-row attach capture (a deeper TESSERA_SCROLL_TMUX_HISTORY_LIMIT variant), the finger flicks themselves ask for the rest: the app logs an inline history request and a settle answering it that covers the fixture.",
    "In a split (transports.json split=true) the fixture pane, made active before the app attached, is still tmux's active pane at every milestone, and the split still stands.",
    "No gesture puts a tmux pane into copy mode (pane_in_mode=0 at every milestone), and history rows appear in order without blank, duplicated or stale pages (every readout on SSH, SSH+tmux and mosh+tmux is one contiguous run of rows)."
  ],
  "capture_notes": "One continuous recording per transport (touch-history.mov, sampled in motion-sequence.jpg). touch-history-evidence.png shows, left to right and top to bottom: before, after the first slow drag, at the oldest row, back at the tail, after the second drag, and back at the tail again. The XCUITest reads the fixture row numbers on screen from the app's DEBUG harness (the Metal surface is black to XCUITest) and logs every flick in touch-rows.log; primary-motion.json grades them together with the changed-band fractions between milestone frames (frame-motion.txt), a second frame 1.5 s after each live-tail milestone (the heartbeat must repaint and nothing else may change), the share of each milestone frame's bands that hold text (frame-text.txt; black or blank frames fail), on tmux transports the pane's history_limit and history_size at the start, and on mosh+tmux the app's anchored-deepen diagnostics. A scroll back comes to rest at the scroll view's end, which can sit up to a row below the terminal's own live placement until output scrolls, so the tail frame is not compared with the starting one. Production momentum is on; the iPad has no software keyboard up unless TESSERA_SCROLL_KEEP_KEYBOARD=1. Connections are created programmatically from an ignored ephemeral fixture configuration; UI automation never opens a host. Physical finger feel remains a manual check.",
  "deterministic_precheck": {"verdict": "pass", "detail": "For every transport in transports.json, primary-motion.json passed: the first drag lowered the highest visible row and changed at least a quarter of the screen's horizontal bands, flicks reached the required oldest row and the frame changed accordingly, the view returned to the tail where the heartbeat repainted and nothing else changed, a second drag revealed history again and returned, both returns showed the fixture's last row, every readout's screen was at least 80% fixture rows, contiguous outside plain mosh, every milestone frame showed text, tmux panes held the fixture rows and stayed out of copy mode, the reader held still through the burst outside plain mosh, mosh+tmux deepened its frozen page by exactly the streamed rows, and SSH+tmux with more history than its attach capture deepened on the flicks' request."}
}
JSON
# A variant run (another TESSERA_SCROLL_CASE_ID) names itself and the
# transports it covers. S13 itself needs all four: with fewer it is a
# diagnostic run that records its evidence but never passes.
complete=1
for transport in ssh ssh-tmux mosh mosh-tmux; do
  [[ " ${selected[*]} " == *" $transport "* ]] || complete=0
done
jq --arg id "$TESSERA_SCROLL_CASE_ID" --arg transports "${selected[*]}" --argjson complete "$complete" \
  '.id = $id
   | if $complete == 1 then . else .title += " (\($transports) only)" end
   | if $complete == 0 and $id == "S13-touch-primary-history"
     then .deterministic_precheck.verdict = "incomplete" else . end' \
  "$CASE_DIR/case.json" >"$CASE_DIR/case.json.tmp"
mv "$CASE_DIR/case.json.tmp" "$CASE_DIR/case.json"
if (( ! complete )) && [[ "$TESSERA_SCROLL_CASE_ID" == S13-touch-primary-history ]]; then
  die "only ${selected[*]} ran: S13 needs all four transports; a variant names its own case id"
fi
script_completed=1
