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
CASE_DIR="$VISUAL_ROOT/cases/P1-iphone-keyboard"
RUNTIME="$VISUAL_ROOT/runtime.json"
APP_PATH="$(jq -r .app_path "$RUNTIME")"
IPAD_UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
PROJECT="$HERE/../../Tessera.xcodeproj"
PASSWORD="$(fixture_password)"
SESSION="tessera-phone-viewport-$(basename "$RUN_DIR" | tr -cd 'A-Za-z0-9' | tail -c 17)"
rm -rf "$CASE_DIR"
mkdir -p "$CASE_DIR"

phone_udid=''

clear_app_environment() {
  local udid="$1"
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_LIVE_SCROLL_HARNESS \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_LIVE_SCROLL_CONFIG_B64 \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_LIVE_SCROLL_SHOW_EDGES \
    >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$phone_udid" ]]; then
    xcrun simctl terminate "$phone_udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl spawn "$phone_udid" launchctl unsetenv TESSERA_VISUAL_CAPTURE \
      >/dev/null 2>&1 || true
    clear_app_environment "$phone_udid"
  fi
  xcrun simctl terminate "$IPAD_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  clear_app_environment "$IPAD_UDID"
  fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" tmux kill-session -t "$SESSION" \
    >/dev/null 2>&1 || true
  delete_owned_test_simulator "$SIMULATOR_STATE/iphone_keyboard_simulator_udid" || true
}
trap 'fail_closed_trap cleanup' EXIT

phone_udid="$(
  TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera Integration iPhone Keyboard" \
  TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/iphone_keyboard_simulator_udid" \
    "$HERE/ensure-test-simulator.sh" | tail -n 1
)"

tmux_geometry_snapshot() {
  fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
    "tmux display-message -p -t '$SESSION:0' '#{window_width}x#{window_height} #{pane_width}x#{pane_height} #{window_panes}'" \
    | tr -d '\r\n'
}

wait_for_phone_geometry() {
  local snapshot window_cols window_rows pane_cols pane_rows pane_count stable=0
  for _ in {1..300}; do
    snapshot="$(tmux_geometry_snapshot 2>/dev/null || true)"
    if [[ "$snapshot" =~ ^([0-9]+)x([0-9]+)[[:space:]]([0-9]+)x([0-9]+)[[:space:]]([0-9]+)$ ]]; then
      window_cols="${BASH_REMATCH[1]}"
      window_rows="${BASH_REMATCH[2]}"
      pane_cols="${BASH_REMATCH[3]}"
      pane_rows="${BASH_REMATCH[4]}"
      pane_count="${BASH_REMATCH[5]}"
      if ((window_cols >= 90 && window_cols <= 115
          && window_rows >= 34 && window_rows <= 42
          && pane_cols >= 45 && pane_cols <= 55
          && pane_rows >= 34 && pane_rows <= 42
          && pane_count == 2)); then
        ((stable += 1))
        if ((stable >= 5)); then
          printf '%s' "$snapshot"
          return 0
        fi
      else
        stable=0
      fi
    fi
    sleep 0.1
  done
  printf 'phone never projected the active split pane to its viewport; last=%s\n' \
    "$(tmux_geometry_snapshot 2>/dev/null || true)" >&2
  return 1
}

wait_for_ipad_geometry() {
  local phone_pane_cols="$1"
  local phone_pane_rows="$2"
  local snapshot window_cols window_rows pane_cols pane_rows pane_count stable=0
  for _ in {1..300}; do
    snapshot="$(tmux_geometry_snapshot 2>/dev/null || true)"
    if [[ "$snapshot" =~ ^([0-9]+)x([0-9]+)[[:space:]]([0-9]+)x([0-9]+)[[:space:]]([0-9]+)$ ]]; then
      window_cols="${BASH_REMATCH[1]}"
      window_rows="${BASH_REMATCH[2]}"
      pane_cols="${BASH_REMATCH[3]}"
      pane_rows="${BASH_REMATCH[4]}"
      pane_count="${BASH_REMATCH[5]}"
      if ((window_cols >= 140 && window_rows >= 42
          && pane_cols > phone_pane_cols && pane_rows > phone_pane_rows
          && pane_count == 2)); then
        ((stable += 1))
        if ((stable >= 5)); then
          printf '%s' "$snapshot"
          return 0
        fi
      else
        stable=0
      fi
    fi
    sleep 0.1
  done
  printf 'iPad never expanded the phone split layout; last=%s\n' \
    "$(tmux_geometry_snapshot 2>/dev/null || true)" >&2
  return 1
}

wait_for_phone_clients_to_detach() {
  local snapshot=''
  local query_failed=0
  for _ in {1..100}; do
    if ! snapshot="$(
        fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
          "tmux list-clients -t '$SESSION' -F '#{client_name}'" \
          2>/dev/null
      )"; then
      query_failed=1
      sleep 0.1
      continue
    fi
    query_failed=0
    if [[ -z "$snapshot" ]]; then
      return 0
    fi

    # This tmux session is uniquely run-owned. A terminated simulator can
    # leave its SSH/control client visible for a short interval, so drain the
    # remaining clients one at a time instead of racing the iPad attach against
    # the production authority check (which must stay fail-closed).
    fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
      "tmux detach-client -s '$SESSION'" >/dev/null 2>&1 || true
    sleep 0.1
  done

  if ((query_failed)); then
    printf 'failed to verify phone tmux clients detached before iPad handoff\n' >&2
  else
    printf 'phone tmux clients did not detach before iPad handoff; clients=%s\n' \
      "$snapshot" >&2
  fi
  return 1
}

wait_for_terminal_presentation() {
  local udid="$1"
  local label="$2"
  local test_name="testWaitForLiveScrollTerminalPresentation"
  local xcresult="$VISUAL_ROOT/p1-iphone-keyboard-${label}-ready.xcresult"
  local log="$CASE_DIR/${label}-ready.log"
  local summary="$CASE_DIR/${label}-ready-summary.json"

  if [[ "$label" == phone ]]; then
    test_name="testWaitForLiveScrollPhoneKeyboardPresentation"
  fi

  # SpringBoard can refuse the runner ("Busy", "Application failed preflight
  # checks") while it is still launching the app just started above; the
  # refused attempt runs no test, so retry it after a pause.
  local attempt passed=0
  for attempt in 1 2 3; do
    rm -rf "$xcresult"
    if TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
        -project "$PROJECT" \
        -scheme Tessera \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$xcresult" \
        -only-testing:"TesseraUITests/VisualCaptureProbe/$test_name" \
        >"$log" 2>&1; then
      passed=1
      break
    fi
    grep -q "Application failed preflight checks" "$log" || break
    cp "$log" "$CASE_DIR/${label}-ready-refused-$attempt.log"
    sleep 5
  done
  if ((passed == 0)); then
    local data_container
    data_container="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null || true)"
    if [[ -n "$data_container" ]]; then
      cp "$data_container/Library/Application Support/Diagnostics/tessera-diagnostics.log" \
        "$CASE_DIR/${label}-failure-diagnostics.log" 2>/dev/null || true
    fi
    fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
      "tmux show-options -qv -t '$SESSION' @tessera_authority; \
tmux list-clients -t '$SESSION' -F '#{client_name}|#{client_pid}|#{client_created}|#{client_flags}'" \
      >"$CASE_DIR/${label}-failure-tmux-state.log" 2>&1 || true
    return 1
  fi
  xcrun xcresulttool get test-results summary --path "$xcresult" >"$summary"
  jq -e \
    '.totalTestCount == 1 and .passedTests == 1 and .skippedTests == 0 and .failedTests == 0' \
    "$summary" >/dev/null
}

fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
  "tmux kill-session -t '$SESSION' >/dev/null 2>&1 || true; \
tmux new-session -d -x 160 -y 50 -s '$SESSION' htop; \
tmux split-window -h -t '$SESSION:0' 'vim /etc/services'; \
tmux select-pane -t '$SESSION:0.0'; \
tmux set-option -t '$SESSION' status off"
initial_geometry="$(tmux_geometry_snapshot)"
[[ "$initial_geometry" =~ ^160x50[[:space:]][0-9]+x50[[:space:]]2$ ]]

config_json="$(jq -cn \
  --arg mode ssh-tmux \
  --arg address "$TESSERA_FIXTURE_STABLE_HOST" \
  --argjson port "$TESSERA_FIXTURE_APP_PORT" \
  --arg user "$TESSERA_FIXTURE_USER" \
  --arg password "$PASSWORD" \
  --arg launchCommand "" \
  --arg tmuxSessionName "$SESSION" \
  '{mode:$mode,address:$address,port:$port,user:$user,password:$password,launchCommand:$launchCommand,tmuxSessionName:$tmuxSessionName}')"
config_b64="$(printf '%s' "$config_json" | base64 | tr -d '\n')"

xcrun simctl install "$phone_udid" "$APP_PATH"
clear_app_environment "$phone_udid"
xcrun simctl spawn "$phone_udid" launchctl setenv TESSERA_VISUAL_CAPTURE 1
xcrun simctl spawn "$phone_udid" launchctl setenv TESSERA_LIVE_SCROLL_HARNESS 1
# Shown as ContentView shows a selected session: a hidden session sizes
# nothing (aa619a2dd), so without show edges neither device claims the grid.
xcrun simctl spawn "$phone_udid" launchctl setenv TESSERA_LIVE_SCROLL_SHOW_EDGES 1
xcrun simctl spawn "$phone_udid" launchctl setenv \
  TESSERA_LIVE_SCROLL_CONFIG_B64 "$config_b64"
xcrun simctl launch --terminate-running-process \
  "$phone_udid" "$BUNDLE_ID" >"$CASE_DIR/phone-launch.txt"

# The remote resize arrives as soon as tmux attaches, which precedes local
# pane hydration. Wait for the production harness to prove its launch shield
# has dropped and the focused TerminalView is hittable at viewport size.
wait_for_terminal_presentation "$phone_udid" phone
phone_geometry="$(wait_for_phone_geometry)"
[[ "$phone_geometry" =~ ^([0-9]+)x([0-9]+)[[:space:]]([0-9]+)x([0-9]+)[[:space:]]2$ ]]
phone_pane_cols="${BASH_REMATCH[3]}"
phone_pane_rows="${BASH_REMATCH[4]}"
xcrun simctl io "$phone_udid" screenshot \
  "$CASE_DIR/phone-tmux-keyboard.png" >/dev/null

# P1 validates the same session sequentially on compact and regular width.
# End the phone transport after preserving its evidence so the production
# authority handoff can release that visible client before the iPad attaches.
# Leaving both apps live makes the iPad correctly show the peer-control veil,
# which is not the viewport-resize state this case is meant to grade.
xcrun simctl terminate "$phone_udid" "$BUNDLE_ID"
fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" \
  "tmux detach-client -s '$SESSION' >/dev/null 2>&1 || true"
wait_for_phone_clients_to_detach

xcrun simctl install "$IPAD_UDID" "$APP_PATH"
clear_app_environment "$IPAD_UDID"
xcrun simctl spawn "$IPAD_UDID" launchctl setenv TESSERA_LIVE_SCROLL_HARNESS 1
xcrun simctl spawn "$IPAD_UDID" launchctl setenv TESSERA_LIVE_SCROLL_SHOW_EDGES 1
xcrun simctl spawn "$IPAD_UDID" launchctl setenv \
  TESSERA_LIVE_SCROLL_CONFIG_B64 "$config_b64"
xcrun simctl launch --terminate-running-process \
  "$IPAD_UDID" "$BUNDLE_ID" >"$CASE_DIR/ipad-launch.txt"

wait_for_terminal_presentation "$IPAD_UDID" ipad
ipad_geometry="$(wait_for_ipad_geometry "$phone_pane_cols" "$phone_pane_rows")"
xcrun simctl io "$IPAD_UDID" screenshot \
  "$CASE_DIR/ipad-tmux-resized.raw.png" >/dev/null
"$HERE/normalize-landscape-screenshot.sh" "$CASE_DIR/ipad-tmux-resized.raw.png" \
  "$CASE_DIR/ipad-tmux-resized.png" >/dev/null
rm -f "$CASE_DIR/ipad-tmux-resized.raw.png"

jq -n \
  --arg initial "$initial_geometry" \
  --arg phone "$phone_geometry" \
  --arg ipad "$ipad_geometry" \
  '{
    id: "P1-iphone-keyboard",
    title: "iPhone keeps a stable full-height tmux grid while presenting one split pane",
    matrix_ids: [],
    invariants: [
      "The real 160x50 fixture keeps two side-by-side tmux panes, while the phone expands its client canvas so the focused pane keeps the physical phone viewport geometry instead of reflowing around the keyboard.",
      "Only the focused pane is presented on iPhone; it keeps a full-width, full-height terminal grid with clearly readable 13 pt text while the composed surface is intentionally pushed behind the software keyboard and accessory bar.",
      "A later iPad attachment expands the same two-pane layout beyond the phone dimensions instead of inheriting a flattened or phone-width split.",
      "Every accessory chip and the keyboard-toggle button is fully visible and entirely above the top edge of the software keyboard; no part of the 52 pt bar is covered. The visible terminal region and keyboard have no unintended clipping, stale pixels, or black rendering artifacts."
    ],
    capture_notes: "Production SSH+tmux session views connected programmatically to a disposable fixture. The same pre-existing 160x50 side-by-side htop/Vim window is captured first on a dedicated portrait iPhone with its real software keyboard. The run-owned phone app and tmux client are then ended without killing the session, and the integration iPad attaches and expands that shared layout. simctl screenshots preserve CAMetalLayer pixels; the iPad PNG is normalized to upright landscape whichever shape simctl returns. No user host or UI-driven connection is involved.",
    deterministic_precheck: {
      verdict: "pass",
      detail: ("Remote tmux window, focused-pane, and pane-count geometry changed " + $initial + " -> " + $phone + " -> " + $ipad + ".")
    },
    presentation_precheck: {
      verdict: "pass",
      detail: "Before each screenshot, XCUITest observed the production harness render-ready state and a hittable, viewport-sized live-scroll terminal surface; the phone probe also dismissed the one-time QuickPath tutorial if present and required the real software keyboard. This excludes the attaching-pane launch shield and keyboard onboarding sheet."
    }
  }' >"$CASE_DIR/case.json"

cleanup
trap - EXIT
script_completed=1
