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
CASE_DIR="$VISUAL_ROOT/cases/S1-S6-live-scroll-transports"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
APP_PATH="$(jq -r .app_path "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
PROJECT="$HERE/../../Tessera.xcodeproj"
RUN_TOKEN="$(basename "$RUN_DIR" | tr -cd 'A-Za-z0-9_-')"
PASSWORD="$(fixture_password)"
mkdir -p "$CASE_DIR"

current_host=''
current_session=''
current_trigger=''

clear_app_environment() {
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_HARNESS \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_LIVE_SCROLL_CONFIG_B64 \
    >/dev/null 2>&1 || true
}

cleanup_remote() {
  [[ -n "$current_host" ]] || return 0
  if [[ -n "$current_session" ]]; then
    fixture_ssh "$current_host" tmux kill-session -t "$current_session" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "$current_trigger" ]]; then
    control_ssh "$current_host" \
      "pids=\$(pgrep -u '$TESSERA_FIXTURE_USER' -f '$current_trigger' || true); [[ -z \"\$pids\" ]] || kill \$pids; pkill -u '$TESSERA_FIXTURE_USER' -x htop >/dev/null 2>&1 || true; rm -f '$current_trigger' '$current_trigger.htop' '$current_trigger.htop.done' '$current_trigger.vim' '$current_trigger.vim.txt'" \
      >/dev/null 2>&1 || true
  fi
  current_host=''
  current_session=''
  current_trigger=''
}

cleanup() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  clear_app_environment
  cleanup_remote
}
trap cleanup EXIT

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

take_landscape_screenshot() {
  local output="$1"
  local best='' best_size=0 candidate size attempt
  for attempt in 1 2 3; do
    candidate="$output.$attempt.png"
    xcrun simctl io "$UDID" screenshot "$candidate.raw.png" >/dev/null 2>&1
    sips -r 270 "$candidate.raw.png" --out "$candidate" >/dev/null
    rm "$candidate.raw.png"
    size="$(stat -f %z "$candidate")"
    if ((size > best_size)); then
      best="$candidate"
      best_size="$size"
    fi
    sleep 0.1
  done
  cp "$best" "$output"
  rm "$output".1.png "$output".2.png "$output".3.png
}

wait_for_log_event() {
  local log="$1"
  local event="$2"
  local process_id="$3"
  for _ in {1..600}; do
    if [[ -f "$log" ]] && grep -Fq "TESSERA_VISUAL_EVENT $event " "$log"; then
      return 0
    fi
    kill -0 "$process_id" >/dev/null 2>&1 || return 1
    sleep 0.2
  done
  printf 'timed out waiting for XCUITest event %s\n' "$event" >&2
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
  take_landscape_screenshot "$output"
}

capture_sequence() {
  local slug="$1"
  local host="$2"
  local trigger="$3"
  local phase_dir="$CASE_DIR/$slug"
  local video="$phase_dir/scroll-sequence.mov"
  local result="$VISUAL_ROOT/live-scroll-$slug.xcresult"
  local log="$phase_dir/xctest.log"
  rm -rf "$phase_dir"
  mkdir -p "$phase_dir"

  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$video" \
    >"$phase_dir/record-video.log" 2>&1 &
  local record_pid=$!
  for _ in {1..50}; do
    grep -q 'Recording started' "$phase_dir/record-video.log" && break
    sleep 0.1
  done
  grep -q 'Recording started' "$phase_dir/record-video.log"

  run_ui_test testLiveScrollVisualSequence "$log" "$result" &
  local test_pid=$!
  if ! capture_logged_frame "$log" primary-before "$test_pid" "$phase_dir/primary-before.png" \
    || ! capture_logged_frame "$log" primary-moved "$test_pid" "$phase_dir/primary-moved.png" \
    || ! capture_logged_frame "$log" primary-restored "$test_pid" "$phase_dir/primary-restored.png"; then
    stop_recording "$record_pid"
    wait "$test_pid" || true
    return 1
  fi
  fixture_ssh "$host" touch "$trigger"
  wait_remote_file "$host" "$trigger.htop"
  if ! capture_logged_frame "$log" htop-before "$test_pid" "$phase_dir/htop-before.png" \
    || ! capture_logged_frame "$log" htop-moved "$test_pid" "$phase_dir/htop-moved.png" \
    || ! capture_logged_frame "$log" htop-restored "$test_pid" "$phase_dir/htop-restored.png"; then
    stop_recording "$record_pid"
    wait "$test_pid" || true
    return 1
  fi
  if [[ "$slug" != mosh ]]; then
    wait_remote_file "$host" "$trigger.vim"
  fi
  if ! capture_logged_frame "$log" vim-before "$test_pid" "$phase_dir/vim-before.png" \
    || ! capture_logged_frame "$log" vim-moved "$test_pid" "$phase_dir/vim-moved.png" \
    || ! capture_logged_frame "$log" vim-restored "$test_pid" "$phase_dir/vim-restored.png"; then
    stop_recording "$record_pid"
    wait "$test_pid" || true
    return 1
  fi
  if ! wait "$test_pid"; then
    stop_recording "$record_pid"
    return 1
  fi
  stop_recording "$record_pid"

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
      -y 2>>"$phase_dir/evidence-sheet.log"
    ffmpeg -hide_banner -loglevel error \
      -i "$phase_dir/$phase-before.png" \
      -i "$phase_dir/$phase-moved.png" \
      -i "$phase_dir/$phase-restored.png" \
      -filter_complex '[0:v][1:v][2:v]vstack=inputs=3' \
      -frames:v 1 "$phase_dir/$phase-evidence.png" \
      -y 2>>"$phase_dir/evidence-sheet.log"
  done
  ffmpeg -hide_banner -loglevel error \
    -i "$phase_dir/primary-row.png" \
    -i "$phase_dir/htop-row.png" \
    -i "$phase_dir/vim-row.png" \
    -filter_complex '[0:v][1:v][2:v]vstack=inputs=3' \
    -frames:v 1 "$phase_dir/scroll-evidence.png" \
    -y 2>>"$phase_dir/evidence-sheet.log"
  rm "$phase_dir"/*-before.png "$phase_dir"/*-moved.png \
    "$phase_dir"/*-restored.png "$phase_dir"/*-row.png
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
  local scenario="/usr/local/bin/tessera-fixture-probe scroll-scenario --label $label --trigger $trigger --count 600 --delay 0.001 --htop-seconds 30 --vim-seconds 300"
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

  local capture_status=1 attempt
  for attempt in 1 2; do
    current_host="$host"
    current_session=''
    current_trigger="$trigger"
    if ! control_ssh "$host" \
      "pids=\$(pgrep -u '$TESSERA_FIXTURE_USER' -f '$trigger' || true); [[ -z \"\$pids\" ]] || kill \$pids; pkill -u '$TESSERA_FIXTURE_USER' -x htop >/dev/null 2>&1 || true; rm -f '$trigger' '$trigger.htop' '$trigger.htop.done' '$trigger.vim' '$trigger.vim.txt'" \
      >/dev/null; then
      note "scroll fixture setup $slug attempt $attempt failed; retrying"
      cleanup_remote
      sleep 1
      continue
    fi

    if [[ $uses_tmux -eq 1 ]]; then
      current_session="$session"
      if ! fixture_ssh "$host" \
        "tmux kill-session -t '$session' >/dev/null 2>&1 || true; tmux new-session -d -s '$session' -x 160 -y 50 '$scenario'"; then
        note "scroll tmux setup $slug attempt $attempt failed; retrying"
        cleanup_remote
        sleep 1
        continue
      fi
    fi

    # Reinstall before every transport. Other development sessions may build
    # the same bundle ID onto the booted simulator; a mid-capture replacement
    # is retried once below, while this guarantees the next attempt uses the
    # isolated integration DerivedData product.
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$APP_PATH"
    clear_app_environment
    xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
    xcrun simctl spawn "$UDID" launchctl setenv TESSERA_LIVE_SCROLL_HARNESS 1
    xcrun simctl spawn "$UDID" launchctl setenv \
      TESSERA_LIVE_SCROLL_CONFIG_B64 "$config_b64"
    xcrun simctl launch "$UDID" "$BUNDLE_ID" \
      >"$CASE_DIR/$slug-launch-attempt-$attempt.txt"

    set +e
    capture_sequence "$slug" "$host" "$trigger"
    capture_status=$?
    set -e
    [[ $capture_status -eq 0 ]] && break

    note "scroll capture $slug attempt $attempt failed; reinstalling and retrying"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    clear_app_environment
    cleanup_remote
  done
  [[ $capture_status -eq 0 ]] || return "$capture_status"

  jq -n \
    --arg mode "$mode" \
    --arg fixtureRole "$role" \
    --arg tmuxVersion "$(fixture_ssh "$host" tmux -V)" \
    '{mode:$mode,fixture_role:$fixtureRole,tmux_version:$tmuxVersion,phases:["primary","htop","vim"],vim_graded:($mode != "mosh")}' \
    >"$CASE_DIR/$slug/transport.json"

  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  clear_app_environment
  cleanup_remote
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
    "The four transport results are behaviorally consistent even though SSH uses local scrollback and mosh+tmux may reveal a capture-pane overlay."
  ],
  "capture_notes": "Each transport has a 3x3 summary assembled from external simctl screenshots captured at timestamped XCUITest milestones while one continuous simctl recording runs. Rows are primary, htop, and vim; columns are before, after the first gesture, and after the reverse gesture. Full-resolution primary/htop/vim companion images stack those same states top-to-bottom so character ranges and selections remain legible. Plain-mosh Vim is retained as diagnostic evidence but is not graded; primary and htop are graded on all four transports and Vim is graded on the other three. Raw .mov files, XCUITest event logs, result summaries, and video metadata accompany the images. Connections are created programmatically from an ignored ephemeral fixture configuration; UI automation never opens a host.",
  "deterministic_precheck": {"verdict": "pass", "detail": "The four continuous XCUITest drivers completed all primary, htop, and vim stages before this manifest was finalized."}
}
JSON
