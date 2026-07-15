#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || exit 2

VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/F12-files-context-menu"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
VIDEO="$CASE_DIR/context-menu.mov"
XCRESULT="$VISUAL_ROOT/f12-files-context-menu.xcresult"
mkdir -p "$CASE_DIR"

# XCUITest runners start in portrait. Prime the dedicated simulator before the
# baseline capture so both stills describe the same landscape geometry.
rm -rf "$VISUAL_ROOT/f12-landscape-prime.xcresult"
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$VISUAL_ROOT/f12-landscape-prime.xcresult" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testSetLandscapeOnly \
  >"$CASE_DIR/landscape-prime.log" 2>&1

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_FILES_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >"$CASE_DIR/launch.txt"
sleep 2
xcrun simctl io "$UDID" screenshot "$CASE_DIR/initial-launch.raw.png" >/dev/null
sips -r 270 "$CASE_DIR/initial-launch.raw.png" \
  --out "$CASE_DIR/initial-launch.png" >/dev/null
rm "$CASE_DIR/initial-launch.raw.png"

xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$VIDEO" \
  >"$CASE_DIR/record-video.log" 2>&1 &
record_pid=$!
cleanup_recording() {
  if kill -0 "$record_pid" >/dev/null 2>&1; then
    kill -INT "$record_pid" >/dev/null 2>&1 || true
    wait "$record_pid" || true
  fi
}
trap cleanup_recording EXIT

for _ in {1..50}; do
  grep -q 'Recording started' "$CASE_DIR/record-video.log" && break
  sleep 0.1
done
grep -q 'Recording started' "$CASE_DIR/record-video.log"
python3 -c 'import time; print(time.time())' >"$CASE_DIR/recording-start-epoch.txt"

rm -rf "$XCRESULT"
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$XCRESULT" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testFilesContextMenuLifecycle \
  >"$CASE_DIR/xctest.log" 2>&1

cleanup_recording
trap - EXIT

python3 "$HERE/visual-event-timeline.py" \
  "$CASE_DIR/recording-start-epoch.txt" \
  "$CASE_DIR/xctest.log" \
  "$CASE_DIR/event-offsets.json"
before_offset="$(jq -r '."before-long-press"' "$CASE_DIR/event-offsets.json")"

# Both comparison frames come from the same uninterrupted recording, after
# XCUITest has established its window geometry. An external pre-test still is
# not a valid geometry baseline because activating the runner can update the
# app's safe area before the marked interaction begins. simctl's movie PTS can
# lag wall-clock event timestamps, so the settled frame is the last decoded
# frame: recording stops only after the post-dismiss-settled marker and test
# teardown complete.
ffmpeg -hide_banner -loglevel error -ss "$before_offset" -i "$VIDEO" \
  -vf 'transpose=cclock' -frames:v 1 "$CASE_DIR/before-event-frame.png"
ffmpeg -hide_banner -loglevel error -i "$VIDEO" \
  -vf 'transpose=cclock' -fps_mode passthrough -update 1 -y \
  "$CASE_DIR/post-dismiss-settled-frame.png"
test -s "$CASE_DIR/before-event-frame.png"
test -s "$CASE_DIR/post-dismiss-settled-frame.png"

xcrun xcresulttool get test-results summary --path "$XCRESULT" \
  >"$CASE_DIR/xctest-summary.json"
ffprobe -v error -show_entries format=duration,size -of json "$VIDEO" \
  >"$CASE_DIR/video-info.json"
ffmpeg -hide_banner -loglevel error -i "$VIDEO" \
  -vf "setpts=N/30/TB,transpose=cclock,signalstats,metadata=print:file=$CASE_DIR/signalstats.txt" \
  -f null -
python3 "$HERE/summarize-signalstats.py" \
  "$CASE_DIR/signalstats.txt" "$CASE_DIR/signalstats-summary.json"
ffmpeg -hide_banner -loglevel error -i "$VIDEO" \
  -vf 'setpts=N/30/TB,transpose=cclock,fps=3,scale=320:-1,tile=6x8:padding=2:margin=2' \
  -frames:v 1 "$CASE_DIR/timeline-contact-sheet.png"

cat >"$CASE_DIR/case.json" <<'JSON'
{
  "id": "F12-files-context-menu",
  "title": "Files glass stays backed through context-menu suppression",
  "matrix_ids": ["F1", "F12"],
  "invariants": [
    "At the before-long-press event, the Files panel is a fully visible normal frosted-glass card with readable fixture rows, breadcrumb, controls, and no terminal reflow or black hole around it. The normal glass intentionally transmits softened/tinted HARNESS stripes.",
    "At touch-down, the normal translucent glass must switch to a backed stand-in before system context-menu suppression could expose an unbacked hole. Colorful stripes showing through during the suppression interval are a failure; stripes visible through the normal before/settled frosted glass are expected.",
    "The card remains backed while the context menu and lifted preview are visible. A near-black opaque stand-in is intentional over this dark terminal and is a PASS, provided the card shape and readable row content remain present.",
    "The card remains backed for the post-dismiss suppression interval and returns without a transparency flash or delayed geometry shift. Normal system whole-screen dimming is not a failure.",
    "The pre-interaction and settled post-interaction card return to the same intended translucent frosted tone and geometry; neither normal endpoint is expected to remain opaque."
  ],
  "capture_notes": "Use before-event-frame.png and post-dismiss-settled-frame.png for normal frosted tone and geometry comparison: both come from one uninterrupted recording after XCUITest established its window geometry, and both should visibly transmit softened/tinted HARNESS stripes. The baseline is selected from the before-long-press event offset. Because simctl movie PTS can lag wall-clock event timestamps, the settled image is the recording's last decoded frame; recording stops only after the post-dismiss-settled marker and test teardown complete. initial-launch.png is only a content/layout reference and must not be used as the pre-interaction geometry baseline. The contact sheet samples the entire recording at 3 fps after physically normalizing the fixed simulator framebuffer to landscape. Ignore XCUITest's initial orientation transition before the before-long-press marker. Only the suppression interval must use the deliberately near-black opaque regression backstop; it is not a hole. A failure exposes colorful HARNESS stripes through the card during that interval, loses the card/rows, or flashes transparent during recovery. signalstats-summary.json contains the complete compact per-frame metric series. Event timestamps and derived offsets are in xctest.log and event-offsets.json.",
  "deterministic_precheck": {"verdict": "not-run"}
}
JSON
