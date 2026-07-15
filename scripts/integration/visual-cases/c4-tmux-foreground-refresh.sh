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
CASE_DIR="$VISUAL_ROOT/cases/C4-tmux-foreground-refresh"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
APP_PATH="$(jq -r .app_path "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
PROJECT="$HERE/../../Tessera.xcodeproj"
XCRESULT="$VISUAL_ROOT/c4-tmux-foreground-refresh.xcresult"
VIDEO="$CASE_DIR/foreground-refresh.mov"
PASSWORD="$(fixture_password)"
RUN_TOKEN="$(basename "$RUN_DIR" | tr -cd 'A-Za-z0-9_-')"
SESSION="tessera_foreground_${RUN_TOKEN}"
TRIGGER="/tmp/${SESSION}.trigger"
SCENARIO="/usr/local/bin/tessera-fixture-probe scroll-scenario --label FOREGROUND --trigger $TRIGGER --count 1000 --delay 0.001 --htop-seconds 45 --vim-seconds 45"
mkdir -p "$CASE_DIR"

record_pid=''
redraw_pid=''
cleanup() {
  local exit_status="${1:-0}"
  if [[ -n "$redraw_pid" ]] && kill -0 "$redraw_pid" >/dev/null 2>&1; then
    kill "$redraw_pid" >/dev/null 2>&1 || true
    wait "$redraw_pid" || true
  fi
  if [[ -n "$record_pid" ]] && kill -0 "$record_pid" >/dev/null 2>&1; then
    kill -INT "$record_pid" >/dev/null 2>&1 || true
    wait "$record_pid" || true
  fi
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_HARNESS \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_CONFIG_B64 \
    >/dev/null 2>&1 || true
  fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" tmux kill-session -t "$SESSION" \
    >/dev/null 2>&1 || true
  control_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
    "pids=\$(pgrep -u '$TESSERA_FIXTURE_USER' -f '$TRIGGER' || true); [[ -z \"\$pids\" ]] || kill \$pids; rm -f '$TRIGGER' '$TRIGGER.htop' '$TRIGGER.htop.done' '$TRIGGER.vim' '$TRIGGER.vim.txt'" \
    >/dev/null 2>&1 || true
  return "$exit_status"
}
trap 'exit_status=$?; cleanup "$exit_status"; exit "$exit_status"' EXIT

fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
  "tmux kill-session -t '$SESSION' >/dev/null 2>&1 || true; tmux new-session -d -s '$SESSION' -x 160 -y 50 '$SCENARIO'"

config_json="$(jq -cn \
  --arg address "$TESSERA_FIXTURE_STABLE_HOST" \
  --argjson port "$TESSERA_FIXTURE_APP_PORT" \
  --arg user "$TESSERA_FIXTURE_USER" \
  --arg password "$PASSWORD" \
  --arg tmuxSessionName "$SESSION" \
  '{mode:"ssh-tmux",address:$address,port:$port,user:$user,password:$password,launchCommand:"",tmuxSessionName:$tmuxSessionName}')"
config_b64="$(printf '%s' "$config_json" | base64 | tr -d '\n')"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_HARNESS 1
xcrun simctl spawn "$UDID" launchctl setenv \
  TESSERA_LIVE_SCROLL_CONFIG_B64 "$config_b64"

# Let the XCUITest's first app.activate() perform the cold launch. Starting the
# SSH handshake with simctl first would let runner activation background the
# app and correctly revoke that still-pending authentication policy.

xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$VIDEO" \
  >"$CASE_DIR/record-video.log" 2>&1 &
record_pid=$!
for _ in {1..50}; do
  grep -q 'Recording started' "$CASE_DIR/record-video.log" && break
  sleep 0.1
done
grep -q 'Recording started' "$CASE_DIR/record-video.log"
python3 -c 'import time; print(time.time())' >"$CASE_DIR/recording-start-epoch.txt"

rm -rf "$XCRESULT"
touch "$CASE_DIR/xctest.log"
(
  for _ in {1..1200}; do
    if grep -q 'TESSERA_VISUAL_EVENT foreground-backgrounded' "$CASE_DIR/xctest.log"; then
      fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
        timeout 8 /usr/local/bin/tessera-fixture-probe tmux-redraw-burst \
        --session "$SESSION" --start-delay 0.4 --frames 80 --rows 50 --frame-delay 0.005
      exit
    fi
    sleep 0.05
  done
  exit 1
) >"$CASE_DIR/redraw-burst.log" 2>&1 &
redraw_pid=$!
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$PROJECT" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$XCRESULT" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testLiveTmuxForegroundRefresh \
  >"$CASE_DIR/xctest.log" 2>&1
wait "$redraw_pid"
redraw_pid=''
grep -q 'TESSERA_TMUX_REDRAW_COMPLETE' "$CASE_DIR/redraw-burst.log"

python3 -c 'import time; print(time.time())' >"$CASE_DIR/recording-stop-epoch.txt"
kill -INT "$record_pid" >/dev/null 2>&1 || true
wait "$record_pid" || true
record_pid=''

xcrun xcresulttool get test-results summary --path "$XCRESULT" \
  >"$CASE_DIR/xctest-summary.json"
ffprobe -v error -show_entries format=duration,size -of json "$VIDEO" \
  >"$CASE_DIR/video-info.json"

# `simctl io recordVideo` acknowledges the request before its encoder begins
# emitting frames. Calibrate from the stop edge instead: the test leaves a
# settled tail, so stop wall time minus encoded duration is the reliable PTS-0
# wall clock for lifecycle markers.
python3 - \
  "$CASE_DIR/recording-stop-epoch.txt" \
  "$CASE_DIR/video-info.json" \
  "$CASE_DIR/video-start-epoch.txt" <<'PY'
import json
import pathlib
import sys

stopped = float(pathlib.Path(sys.argv[1]).read_text())
info = json.loads(pathlib.Path(sys.argv[2]).read_text())
duration = float(info["format"]["duration"])
pathlib.Path(sys.argv[3]).write_text(f"{stopped - duration}\n")
PY

python3 "$HERE/visual-event-timeline.py" \
  "$CASE_DIR/video-start-epoch.txt" \
  "$CASE_DIR/xctest.log" \
  "$CASE_DIR/event-offsets.json" \
  --required foreground-before-background \
  --required foreground-backgrounded \
  --required foreground-activated \
  --required foreground-settled
activation_offset="$(jq -r '."foreground-activated"' "$CASE_DIR/event-offsets.json")"
settled_offset="$(jq -r '."foreground-settled"' "$CASE_DIR/event-offsets.json")"

python3 - "$activation_offset" "$settled_offset" "$CASE_DIR/video-info.json" <<'PY'
import json
import pathlib
import sys

activated = float(sys.argv[1])
settled = float(sys.argv[2])
info = json.loads(pathlib.Path(sys.argv[3]).read_text())
duration = float(info["format"]["duration"])
if settled - activated < 20:
    raise SystemExit("foreground lifecycle probe did not cover the 20-second recovery window")
# Allow a small encoder-finalization skew around the calibrated stop edge.
if duration + 1 < settled:
    raise SystemExit(f"recording ended before settled marker: duration={duration} settled={settled}")
PY

# `simctl io recordVideo` may duplicate or omit frames while SpringBoard owns
# the transition, so movie PTS is not reliably affine to the wall clock. Find
# the actual foreground cut in the movie: the terminal is dark, SpringBoard is
# bright, and the terminal becomes dark again when Tessera fills the screen.
ffmpeg -hide_banner -loglevel error -i "$VIDEO" \
  -vf "signalstats,metadata=print:file=$CASE_DIR/frame-signalstats.txt" \
  -f null - >"$CASE_DIR/signalstats-ffmpeg.log" 2>&1
python3 - \
  "$CASE_DIR/frame-signalstats.txt" \
  "$CASE_DIR/video-event-offsets.json" <<'PY'
import json
import pathlib
import re
import sys

stats_path = pathlib.Path(sys.argv[1])
samples = []
frame_number = None
pts = None
yavg = None
for line in stats_path.read_text().splitlines():
    match = re.search(r"frame:(\d+).*pts_time:([0-9.]+)", line)
    if match:
        frame_number = int(match.group(1))
        pts = float(match.group(2))
        yavg = None
        continue
    match = re.search(r"lavfi\.signalstats\.YAVG=([0-9.]+)", line)
    if match and pts is not None:
        yavg = float(match.group(1))
        continue
    match = re.search(r"lavfi\.signalstats\.YMAX=([0-9.]+)", line)
    if match and frame_number is not None and pts is not None and yavg is not None:
        samples.append((frame_number, pts, yavg, float(match.group(1))))

bright_times = [pts for _, pts, yavg, _ in samples if yavg >= 80]
segments = []
for pts in bright_times:
    # simctl can omit long runs of duplicate SpringBoard frames entirely.
    if not segments or pts - segments[-1][1] > 3.5:
        segments.append([pts, pts])
    else:
        segments[-1][1] = pts
candidates = [segment for segment in segments if segment[0] > 2 and segment[1] - segment[0] >= 1]
if not candidates:
    raise SystemExit("movie does not contain a sustained SpringBoard interval")
springboard_start, springboard_end = candidates[-1]

returned = None
for index, (_, pts, yavg, _) in enumerate(samples):
    if pts < springboard_end or yavg >= 50:
        continue
    following = [sample[2] for sample in samples[index:index + 10]]
    if len(following) == 10 and all(value < 50 for value in following):
        returned = pts
        break
if returned is None:
    raise SystemExit("movie does not show Tessera returning after SpringBoard")
last_frame = samples[-1][1]
last_terminal_index, last_terminal_frame, _, _ = max(
    (sample for sample in samples
     if sample[1] >= returned and sample[2] < 50 and sample[3] >= 100),
    key=lambda sample: sample[1],
)
if last_terminal_frame - returned < 4:
    raise SystemExit("movie ends before the four-second post-return evidence window")

pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "last-frame": last_frame,
    "last-terminal-frame": last_terminal_frame,
    "last-terminal-frame-index": last_terminal_index,
    "springboard-start": springboard_start,
    "tessera-returned": returned,
}, indent=2, sort_keys=True) + "\n")
PY
springboard_offset="$(jq -r '."springboard-start"' "$CASE_DIR/video-event-offsets.json")"
return_offset="$(jq -r '."tessera-returned"' "$CASE_DIR/video-event-offsets.json")"
last_terminal_index="$(jq -r '."last-terminal-frame-index"' "$CASE_DIR/video-event-offsets.json")"

# Normalize the simulator's fixed framebuffer to landscape. Four native-rate
# one-second sheets surround the visually measured return; at 30 fps, the
# attached log's 120 ms deep replay spans several full-size tiles instead of
# disappearing between sparse samples.
before_video_offset="$(python3 - "$springboard_offset" <<'PY'
import sys
print(max(0.0, float(sys.argv[1]) - 0.5))
PY
)"
ffmpeg -hide_banner -loglevel error -ss "$before_video_offset" -i "$VIDEO" \
  -vf 'transpose=cclock' -frames:v 1 -y "$CASE_DIR/before-background.png"
sheet_start="$(python3 - "$return_offset" <<'PY'
import sys
print(max(0.0, float(sys.argv[1]) - 1.0))
PY
)"
for sheet in 0 1 2 3; do
  offset="$(python3 - "$sheet_start" "$sheet" <<'PY'
import sys
print(float(sys.argv[1]) + int(sys.argv[2]))
PY
)"
  ffmpeg -hide_banner -loglevel error -ss "$offset" -t 1 -i "$VIDEO" \
    -vf 'transpose=cclock,fps=30,scale=480:-1,tile=5x6:padding=2:margin=2' \
    -frames:v 1 -y "$CASE_DIR/foreground-activation-$((sheet + 1)).png"
done
# Decode sequentially to the exact contentful terminal frame. Timestamp seeks
# can land inside simctl's long omitted-frame gap and synthesize a black frame.
ffmpeg -hide_banner -loglevel error -i "$VIDEO" \
  -vf "select='eq(n,$last_terminal_index)',transpose=cclock" -fps_mode vfr \
  -frames:v 1 -y "$CASE_DIR/foreground-settled.png"
test -s "$CASE_DIR/before-background.png"
test -s "$CASE_DIR/foreground-activation-1.png"
test -s "$CASE_DIR/foreground-activation-2.png"
test -s "$CASE_DIR/foreground-activation-3.png"
test -s "$CASE_DIR/foreground-activation-4.png"
test -s "$CASE_DIR/foreground-settled.png"

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "C4-tmux-foreground-refresh",
  "title": "Inline tmux foreground restore does not replay deep history",
  "matrix_ids": ["C4"],
  "invariants": [
    "Before backgrounding, the SSH+tmux fixture is stably showing the final numbered tail produced by the 1000-row scenario.",
    "After Tessera is activated again, the terminal returns directly to the authoritative visible tmux viewport. A single TESSERA_FOREGROUND_LIVE_PROBE input echo may appear at the bottom to prove post-activation transport liveness; frames must not animate older scrollback rows rapidly toward the bottom.",
    "Foreground recovery must not introduce a black terminal, half-width background ghost, geometry jump, or multi-second visibly frozen intermediate screen.",
    "SpringBoard frames between the explicit Home press and app activation are expected and are not graded as Tessera output."
  ],
  "capture_notes": "foreground-refresh.mov is one uninterrupted simctl recording across the explicit Home press and Tessera reactivation. before-background.png and foreground-settled.png are terminal endpoint frames; the settled image uses the last video-measured terminal frame before UI-test teardown returns to SpringBoard. foreground-activation-1.png through -4.png cover four consecutive one-second windows at 30 fps, beginning one second before the video-measured SpringBoard-to-Tessera return in video-event-offsets.json. The first tiles may show SpringBoard; once Tessera appears, the numbered viewport must not race through history. Each tile is 480 pixels wide so row changes remain legible. event-offsets.json, xctest.log, and redraw-burst.log carry the lifecycle markers, probe result, and the 80-frame PTY redraw burst injected while Tessera is backgrounded. The remote fixture has 1000 primary-screen history rows before the redraw burst, matching the user-reported high-history Codex pane exposure.",
  "deterministic_precheck": {"verdict": "pass", "detail": "XCUITest proved Home moved Tessera out of foreground, reactivation returned it to runningForeground within four seconds, a unique post-activation probe traversed inline tmux into the rendered terminal, at most four terminal-feed presentation steps carried at least 250000 bytes across the injected 80-frame background redraw burst, and the test plus recording covered the full 20-second recovery window. A large coalesced batch is expected because preserving scrollback requires retaining every background byte below the bounded safety cap."}
}
JSON

cleanup 0
trap - EXIT
