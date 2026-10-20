#!/usr/bin/env bash
# Real pointer release physics, separate from quiescent S1/S6 image capture.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TESSERA_SCROLL_CAPTURE_LIBRARY=1
export TESSERA_SCROLL_CASE_ID=S3-live-scroll-momentum
export TESSERA_SCROLL_PHYSICS=1
export TESSERA_SCROLL_FIXTURE_ROWS="${TESSERA_SCROLL_FIXTURE_ROWS:-3000}"
# A failed attempt keeps this case's own result bundle.
SCROLL_RESULT_PREFIX=flick
source "$HERE/visual-cases/s1-s6-live-scroll-transports.sh" "${1:?run directory}"

capture_sequence() {
  local slug="$1" host="$2" trigger="$3"
  local phase_dir="$CASE_DIR/$slug"
  local ack_dir="$phase_dir/acks"
  rm -rf "$ack_dir"
  mkdir -p "$phase_dir" "$ack_dir"
  # Initial SSH fixture output fills the diagnostic signature's 60s quota.
  # Wait for that window to expire before recording gesture measurements.
  sleep 65
  xcrun simctl spawn "$UDID" launchctl setenv TESSERA_FLICK_DISTANCE "${TESSERA_FLICK_DISTANCE:-900}"
  xcrun simctl spawn "$UDID" launchctl setenv TESSERA_FLICK_INPUT "${TESSERA_FLICK_INPUT:-pointer}"
  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$phase_dir/first-second.mov" >"$phase_dir/record.log" 2>&1 &
  local record_pid=$!
  # The XCUITest holds at each milestone until its capture is acknowledged.
  # Three screenshot candidates outlast the two-second settle, so without the
  # hold the second flick ran inside the "first settled" capture and the two
  # settled frames matched.
  if ! xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE_ACK_DIR "$ack_dir"; then
    stop_recording "$record_pid"
    printf 'could not pass the capture acknowledgement directory to the simulator\n' >&2
    return 1
  fi
  current_ack_dir="$ack_dir"
  run_ui_test testLiveFirstFlickMomentum "$phase_dir/xctest.log" "$VISUAL_ROOT/flick-$slug.xcresult" &
  local test_pid=$!
  local capture_status=0 event
  for event in flick-before flick-first-return flick-first-settled flick-second-return flick-second-settled; do
    if ! capture_logged_frame "$phase_dir/xctest.log" "$event" "$test_pid" "$phase_dir/$event.png" \
      || { [[ "$event" == flick-before ]] && ! enable_fixture_tmux_mouse "$slug" "$host" "$phase_dir"; } \
      || ! capture_primary_tmux_mode "$slug" "$host" "$phase_dir" "$event"; then
      capture_status=1
      break
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
  [[ "$capture_status" == 0 ]] || return 1
  local container
  container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
  cp "$container/Library/Application Support/Diagnostics/tessera-diagnostics.log" "$phase_dir/diagnostics.log"
  python3 - "$phase_dir" "$slug" "${TESSERA_SCROLL_SPLIT:-0}" "$TESSERA_SCROLL_FIXTURE_ROWS" "${TESSERA_FLICK_INPUT:-pointer}" <<'PY' || return 1
import datetime, json, pathlib, re, sys
root=pathlib.Path(sys.argv[1]); slug=sys.argv[2]; split=sys.argv[3]=='1'
xctest=(root/'xctest.log').read_text()
start=float(re.search(r'TESSERA_VISUAL_EVENT flick-before epoch=([\d.]+)',xctest)[1])
lines=[]
for line in (root/'diagnostics.log').read_text().splitlines():
    try: t=datetime.datetime.fromisoformat(line.split(' ')[0].replace('Z','+00:00')).timestamp()
    except ValueError: continue
    if t >= start: lines.append((t,line))
glides=[]; active=None
for t,line in lines:
    if 'inertia-start velocity=' in line: active={'start':t,'velocity':float(line.split('velocity=')[-1])}
    if active and 'inertia-stop reason=' in line:
        m=re.search(r'reason=(\S+) ticks=(\d+)',line)
        active.update(duration=t-active['start'],reason=m[1],ticks=int(m[2])); glides.append(active); active=None
# Each glide belongs to the flick released before it started: the second
# flick is sent once the first has settled.
second=float(re.search(r'TESSERA_VISUAL_EVENT flick-first-settled epoch=([\d.]+)',xctest)[1])
first_glides=[g for g in glides if g['start'] < second]
second_glides=[g for g in glides if g['start'] >= second]
if sys.argv[5] == 'pointer':
    assert first_glides, (slug,'the first flick had no release momentum',glides)
    assert split or second_glides, (slug,'the second flick had no release momentum',glides)
    assert first_glides[0]['ticks'] >= 15, (slug,'first flick stopped prematurely',glides)
    assert first_glides[0]['reason'] == 'decayed', (slug,'first flick must coast through the initial page boundary',glides)
if int(sys.argv[4]) >= 3000 and not split and sys.argv[5] == 'pointer':
    assert all(g['reason'] == 'decayed' for g in glides), (slug,'loaded history must not stop either flick',glides)
assert not any('history-presentation-failed' in l or 'history-ready-dropped' in l for _,l in lines), 'valid history was lost'
assert not any('live-returned-tail' in l for _,l in lines), 'upward gestures must not discard newly revealed history'
assert not any('reason=authority-reclaim' in l for _,l in lines), 'initial attach reservation survived into scroll'
summary={'verdict':'pass','input':sys.argv[5],'glides':glides,'firstFlickGlides':len(first_glides),'secondFlickGlides':len(second_glides),'splitPresentation':split,'historyLoads':sum('history-applied' in l for _,l in lines)}
(root/'primary-motion.json').write_text(json.dumps(summary,indent=2)+'\n')
PY
  if [[ "${TESSERA_SCROLL_SPLIT:-0}" == 1 || "${TESSERA_FLICK_INPUT:-pointer}" != pointer ]]; then
    local fraction
    fraction="$(motion_fraction "$phase_dir/flick-before.png" "$phase_dir/flick-first-settled.png")" || return 1
    awk -v f="$fraction" 'BEGIN { exit !(f >= 0.25) }' || return 1
    fraction="$(motion_fraction "$phase_dir/flick-first-settled.png" "$phase_dir/flick-second-settled.png")" || return 1
    awk -v f="$fraction" 'BEGIN { exit !(f >= 0.25) }' || return 1
  fi
  local rotate
  rotate="$("$HERE/landscape-video-filter.sh" "$phase_dir/first-second.mov")" || return 1
  ffmpeg -v error -i "$phase_dir/first-second.mov" -vf "${rotate}fps=1,scale=480:-1,tile=5x6" -frames:v 1 -y "$phase_dir/motion-sequence.jpg" || return 1
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_FLICK_DISTANCE
}

for selected_transport in ${TESSERA_SCROLL_TRANSPORTS:-ssh ssh-tmux mosh mosh-tmux}; do
  capture_selected_transport "$selected_transport"
done
cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id":"S3-live-scroll-momentum",
  "title":"First and second scroll gestures with production momentum enabled",
  "matrix_ids":["S1","S3","S4","S10"],
  "invariants":[
    "The first flick continues moving after release instead of requiring another gesture to acquire momentum.",
    "Both flicks preserve coherent numbered history; no blank capture frame, stale page or duplicated rows appears.",
    "Mosh history loading preserves the glide and does not replay an already-completed attach claim.",
    "With tmux mouse reporting enabled, primary history stays local: pane_in_mode remains zero after both gestures, with no copy-mode indicator.",
    "Direct finger and diagonal variants each reveal history on the first gesture and continue moving on the second."
  ],
  "capture_notes":"One continuous simulator recording per transport, actual XCUITest pointer scroll events or direct touch/diagonal gestures as labeled, production physics enabled. Images sample the recordings; diagnostics bracket each release and report glide duration/tick count. This is simulator input evidence; physical trackpad and finger feel remain human checks. Plain-mosh received history can contain gaps already present before this optimization; compare baseline evidence when diagnosing a regression. Mosh+tmux capture-pane history remains graded for contiguous rows.",
  "deterministic_precheck":{"verdict":"pass","details":"Pointer first flicks decayed normally after at least 15 display ticks; touch/diagonal gestures changed history after both gestures; tmux primary pane_in_mode stayed zero; no history rejection or stale authority-claim request occurred during scrolling."}
}
JSON
script_completed=1
