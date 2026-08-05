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
BUNDLE_ID=com.bambouville.TesseraApp
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
}

cleanup() {
  if [[ -n "$phone_udid" ]]; then
    xcrun simctl terminate "$phone_udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    clear_app_environment "$phone_udid"
  fi
  xcrun simctl terminate "$IPAD_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  clear_app_environment "$IPAD_UDID"
  fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" tmux kill-session -t "$SESSION" \
    >/dev/null 2>&1 || true
  delete_owned_test_simulator "$SIMULATOR_STATE/iphone_keyboard_simulator_udid" || true
}
trap cleanup EXIT

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
          && window_rows >= 18 && window_rows <= 24
          && pane_cols >= 45 && pane_cols <= 55
          && pane_rows >= 18 && pane_rows <= 24
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
xcrun simctl spawn "$phone_udid" launchctl setenv TESSERA_LIVE_SCROLL_HARNESS 1
xcrun simctl spawn "$phone_udid" launchctl setenv \
  TESSERA_LIVE_SCROLL_CONFIG_B64 "$config_b64"
xcrun simctl launch --terminate-running-process \
  "$phone_udid" "$BUNDLE_ID" >"$CASE_DIR/phone-launch.txt"

phone_geometry="$(wait_for_phone_geometry)"
[[ "$phone_geometry" =~ ^([0-9]+)x([0-9]+)[[:space:]]([0-9]+)x([0-9]+)[[:space:]]2$ ]]
phone_pane_cols="${BASH_REMATCH[3]}"
phone_pane_rows="${BASH_REMATCH[4]}"
sleep 1
xcrun simctl io "$phone_udid" screenshot \
  "$CASE_DIR/phone-tmux-keyboard.png" >/dev/null

xcrun simctl install "$IPAD_UDID" "$APP_PATH"
clear_app_environment "$IPAD_UDID"
xcrun simctl spawn "$IPAD_UDID" launchctl setenv TESSERA_LIVE_SCROLL_HARNESS 1
xcrun simctl spawn "$IPAD_UDID" launchctl setenv \
  TESSERA_LIVE_SCROLL_CONFIG_B64 "$config_b64"
xcrun simctl launch --terminate-running-process \
  "$IPAD_UDID" "$BUNDLE_ID" >"$CASE_DIR/ipad-launch.txt"

ipad_geometry="$(wait_for_ipad_geometry "$phone_pane_cols" "$phone_pane_rows")"
sleep 1
xcrun simctl io "$IPAD_UDID" screenshot \
  "$CASE_DIR/ipad-tmux-resized.raw.png" >/dev/null
# simctl can return the landscape CAMetalLayer in a portrait-oriented pixel
# buffer on this runtime. Normalize the evidence without changing its pixels.
read -r ipad_pixel_width ipad_pixel_height < <(
  sips -g pixelWidth -g pixelHeight "$CASE_DIR/ipad-tmux-resized.raw.png" \
    | awk '/pixelWidth/{width=$2} /pixelHeight/{height=$2} END{print width, height}'
)
if ((ipad_pixel_height > ipad_pixel_width)); then
  sips -r 270 "$CASE_DIR/ipad-tmux-resized.raw.png" \
    --out "$CASE_DIR/ipad-tmux-resized.png" >/dev/null
else
  mv "$CASE_DIR/ipad-tmux-resized.raw.png" \
    "$CASE_DIR/ipad-tmux-resized.png"
fi
rm -f "$CASE_DIR/ipad-tmux-resized.raw.png"

jq -n \
  --arg initial "$initial_geometry" \
  --arg phone "$phone_geometry" \
  --arg ipad "$ipad_geometry" \
  '{
    id: "P1-iphone-keyboard",
    title: "iPhone presents one split tmux pane full-screen without flattening the shared layout",
    matrix_ids: [],
    invariants: [
      "The real 160x50 fixture keeps two side-by-side tmux panes, while the phone expands its client canvas so the focused pane itself matches the physical phone viewport.",
      "Only the focused pane is presented on iPhone and it occupies the full terminal width with clearly readable 13 pt text while the software keyboard and accessory bar are visible.",
      "A later iPad attachment expands the same two-pane layout beyond the phone dimensions instead of inheriting a flattened or phone-width split.",
      "The terminal, accessory controls, and keyboard remain complete and non-overlapping, with no clipping, stale pixels, or black rendering artifacts."
    ],
    capture_notes: "Production SSH+tmux session views connected programmatically to a disposable fixture. The same pre-existing 160x50 side-by-side htop/Vim window is captured first on a dedicated portrait iPhone with its real software keyboard, then on the integration iPad after that client expands the shared layout. simctl screenshots preserve CAMetalLayer pixels; the iPad PNG is losslessly orientation-normalized when this simulator runtime returns its landscape surface in a portrait pixel buffer. No user host or UI-driven connection is involved.",
    deterministic_precheck: {
      verdict: "pass",
      detail: ("Remote tmux window, focused-pane, and pane-count geometry changed " + $initial + " -> " + $phone + " -> " + $ipad + ".")
    }
  }' >"$CASE_DIR/case.json"

cleanup
trap - EXIT
