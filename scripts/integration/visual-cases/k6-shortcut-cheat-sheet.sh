#!/usr/bin/env bash
# Hold-⌘ shortcut cheat sheet over real simulator HID, in every surface
# material, plus the ⌘⇧A Agent Center arrival with the sidebar collapsed.
#
# The oracle is the DEBUG `[cheat-sheet] show/hide` log, not the pixels: a
# screenshot taken mid-hold proves what the sheet looks like, the log proves it
# came from a real ⌘ hold (and that a short tap or a chord never produced one).
# AXe drives HID because XCUITest's typeKey cannot hold a bare modifier.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
source "$HERE/lib.sh"
RUN_DIR="${1:?supply the aggregate run directory}"
VISUAL_ROOT="$RUN_DIR/visual"
CASE_DIR="$VISUAL_ROOT/cases/K6-shortcut-cheat-sheet"
RUNTIME="$VISUAL_ROOT/runtime.json"
UDID="$(jq -r .udid "$RUNTIME")"
DERIVED_DATA="$(jq -r .derived_data "$RUNTIME")"
APP_PATH="$(jq -r .app_path "$RUNTIME")"
BUNDLE_ID=com.bambouville.TesseraApp
mkdir -p "$CASE_DIR"

axe="${AXE:-$(command -v axe || true)}"
if [[ -z "$axe" ]]; then
  for candidate in /opt/homebrew/Cellar/xcodebuildmcp/*/libexec/bundled/axe; do
    [[ -x "$candidate" ]] && axe="$candidate"
  done
fi
[[ -x "$axe" ]] || die "AXe not found; install XcodeBuildMCP or set AXE"

IPHONE_UDID_FILE="$SIMULATOR_STATE/k6_iphone_simulator_udid"
exit_cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  delete_owned_test_simulator "$IPHONE_UDID_FILE" || status=1
  exit "$status"
}
trap exit_cleanup EXIT

step() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$CASE_DIR/steps.txt"; }

shot() {
  local udid="$1" name="$2"
  xcrun simctl io "$udid" screenshot "$CASE_DIR/$name.raw.png" >/dev/null
  "$HERE/normalize-landscape-screenshot.sh" "$CASE_DIR/$name.raw.png" "$CASE_DIR/$name.png" >/dev/null
  rm "$CASE_DIR/$name.raw.png"
}

# Cheat-sheet log lines from the current launch since the wall-clock mark $2.
# Both fences matter: a relaunch would otherwise inherit the previous
# material's show/hide pair and pass a hold that produced nothing.
APP_PID=''
mark() { date '+%Y-%m-%d %H:%M:%S'; }
sheet_log() {
  xcrun simctl spawn "$1" log show --start "$2" --style compact \
    --predicate "processIdentifier == $APP_PID AND eventMessage CONTAINS \"[cheat-sheet]\"" \
    2>/dev/null | grep -F '[cheat-sheet]' || true
}

# Launches straight to the hosts landing: no first-open Nearby Setup, no
# welcome tour, Agent Center on, the requested material and mode.
# Argument-domain defaults, not `defaults write`: a booted simulator's cfprefsd
# caches the latter. PREVIEW=1 pins the sheet open (DEBUG hook) for a
# steady-state capture that no hold timing can catch mid-fade.
PREVIEW=0
launch() {
  local udid="$1" material="$2" mode="${3:-dark}" out
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  out="$(SIMCTL_CHILD_TESSERA_SHORTCUT_CHEAT_SHEET_PREVIEW="$PREVIEW" \
    xcrun simctl launch "$udid" "$BUNDLE_ID" \
    -tessera.nearbyBootstrap.completed.v1 YES \
    -tessera.pref.hasSeenWelcome YES \
    -tessera.pref.agentCenterEnabled YES \
    -tessera.pref.chromeMaterial "$material" \
    -tessera.pref.mode "$mode")"
  printf '%s %s/%s\n' "$out" "$material" "$mode" >>"$CASE_DIR/launch.txt"
  APP_PID="${out##*: }"
  [[ "$APP_PID" =~ ^[0-9]+$ ]] || die "no pid in launch output: $out"
  sleep 4
}

# Holds ⌘ for $3 seconds and captures $2-held mid-hold, then $2-released.
# Leaves the hold's start in HOLD_MARK for the assertion that follows.
# AXe takes up to ~1 s to put ⌘ down and a simctl capture up to ~1 s to land,
# so the mid-hold capture needs margin on both sides of the 0.8 s reveal and
# the release fade.
HOLD_MARK=''
hold_command() {
  local udid="$1" name="$2" seconds="${3:-5}"
  HOLD_MARK="$(mark)"
  "$axe" key 227 --duration "$seconds" --udid "$udid" >>"$CASE_DIR/axe.log" 2>&1 &
  local hold_pid=$!
  sleep 2.6
  shot "$udid" "$name-held"
  wait "$hold_pid"
  sleep 0.7
  shot "$udid" "$name-released"
}

# The hold's own pair, in order, and released by ⌘ rather than the watchdog.
expect_show_then_hide() {
  local udid="$1" label="$2" lines first_show first_hide
  lines="$(sheet_log "$udid" "$HOLD_MARK")"
  printf '== %s (pid %s since %s)\n%s\n' "$label" "$APP_PID" "$HOLD_MARK" "$lines" >>"$CASE_DIR/sheet-log.txt"
  first_show="$(grep -n '\[cheat-sheet\] show' <<<"$lines" | head -n 1 | cut -d: -f1)"
  first_hide="$(grep -n '\[cheat-sheet\] hide' <<<"$lines" | head -n 1 | cut -d: -f1)"
  [[ -n "$first_show" ]] || die "$label: no show logged"
  [[ -n "$first_hide" ]] || die "$label: no hide logged"
  (( first_show < first_hide )) || die "$label: hide logged before show"
  grep -q '\[cheat-sheet\] hide: command released' <<<"$lines" \
    || die "$label: hidden by something other than releasing ⌘"
}

expect_no_show() {
  local udid="$1" label="$2" since="$3" lines
  lines="$(sheet_log "$udid" "$since")"
  printf '== %s (pid %s since %s)\n%s\n' "$label" "$APP_PID" "$since" "$lines" >>"$CASE_DIR/sheet-log.txt"
  if grep -q '\[cheat-sheet\] show' <<<"$lines"; then die "$label: sheet appeared"; fi
}

# The first HID key on a fresh simulator posts AppleKeyboardsSettingsChanged,
# and keys sent over the next ~70 s are dropped outright. Hold ⌘ until a show
# lands rather than sleeping a guessed interval.
warm_keyboard() {
  local udid="$1" started=$SECONDS attempt
  while :; do
    [[ $((SECONDS - started)) -lt 180 ]] || die "simulator keyboard never settled"
    attempt="$(mark)"
    "$axe" key 227 --duration 1.6 --udid "$udid" >>"$CASE_DIR/axe.log" 2>&1
    sleep 0.5
    if sheet_log "$udid" "$attempt" | grep -q '\[cheat-sheet\] show'; then break; fi
    sleep 3
  done
  step "keyboard settled after $((SECONDS - started))s"
}

run_surface() {
  local udid="$1" surface="$2"
  PREVIEW=1
  for material in liquidGlass frosted solid; do
    launch "$udid" "$material"
    sleep 1
    shot "$udid" "$surface-$material-pinned"
  done
  launch "$udid" liquidGlass light
  sleep 1
  shot "$udid" "$surface-liquidGlass-light-pinned"
  PREVIEW=0
  step "$surface: pinned captures for every material"

  launch "$udid" liquidGlass
  shot "$udid" "$surface-landing"
  warm_keyboard "$udid"

  for material in liquidGlass frosted solid; do
    launch "$udid" "$material"
    hold_command "$udid" "$surface-$material"
    expect_show_then_hide "$udid" "$surface $material hold"
    step "$surface $material: shown while held, hidden on release"
  done
  launch "$udid" liquidGlass light
  hold_command "$udid" "$surface-liquidGlass-light"
  expect_show_then_hide "$udid" "$surface light hold"

  # A short tap is a brush of ⌘, not a request.
  launch "$udid" liquidGlass
  local since
  since="$(mark)"
  "$axe" key 227 --duration 0.3 --udid "$udid" >>"$CASE_DIR/axe.log" 2>&1
  sleep 1.5
  expect_no_show "$udid" "$surface short tap" "$since"
  step "$surface: 0.3 s tap shows nothing"

  # Holding ⌘ through a chord never reveals: ⇧ lands while ⌘ is down.
  since="$(mark)"
  "$axe" key 227 --duration 2.4 --udid "$udid" >>"$CASE_DIR/axe.log" 2>&1 &
  local hold_pid=$!
  sleep 0.3
  "$axe" key 225 --duration 0.2 --udid "$udid" >>"$CASE_DIR/axe.log" 2>&1
  wait "$hold_pid"
  sleep 0.5
  expect_no_show "$udid" "$surface chord hold" "$since"
  step "$surface: ⌘ held through ⇧ shows nothing"

  # The negatives above only mean something if a hold still works afterwards
  # in this same launch.
  hold_command "$udid" "$surface-after-negatives"
  expect_show_then_hide "$udid" "$surface hold after negatives"
}

# iPad: the shared landscape visual simulator, plus the Agent Center arrival.
run_surface "$UDID" ipad
launch "$UDID" liquidGlass
shot "$UDID" ipad-agents-before
"$axe" key-combo --modifiers 227,225 --key 4 --udid "$UDID" >>"$CASE_DIR/axe.log" 2>&1
sleep 1.5
shot "$UDID" ipad-agents-open
"$axe" key-combo --modifiers 227,225 --key 4 --udid "$UDID" >>"$CASE_DIR/axe.log" 2>&1
sleep 1.5
shot "$UDID" ipad-agents-closed
step "ipad: ⌘⇧A open/close captured"

# iPhone: an owned disposable device, primed to landscape with the app active
# (SpringBoard on iPhone does not keep a landscape orientation by itself).
iphone_udid="$(
  TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera K6 Cheat Sheet iPhone' \
  TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$IPHONE_UDID_FILE" \
    "$HERE/ensure-test-simulator.sh" | tail -n 1
)"
xcrun simctl install "$iphone_udid" "$APP_PATH"
xcrun simctl spawn "$iphone_udid" launchctl setenv TESSERA_VISUAL_CAPTURE 1
rm -rf "$VISUAL_ROOT/k6-iphone-landscape-prime.xcresult"
TESSERA_VISUAL_CAPTURE=1 xcodebuild test-without-building \
  -project "$HERE/../../Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$iphone_udid" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$VISUAL_ROOT/k6-iphone-landscape-prime.xcresult" \
  -only-testing:TesseraUITests/VisualCaptureProbe/testSetLandscapeWithActiveApp \
  >"$CASE_DIR/iphone-landscape-prime.log" 2>&1
run_surface "$iphone_udid" iphone

cp "$HERE/visual-cases/k6-shortcut-cheat-sheet.json" "$CASE_DIR/case.json"
script_completed=1
