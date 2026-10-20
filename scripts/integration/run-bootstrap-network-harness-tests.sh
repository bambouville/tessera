#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-bootstrap-network-harness-tests.sh RUN_DIR [--without-building]\n' >&2; exit 2; }
BUILD_APP=1
if [[ "${2:-}" == --without-building ]]; then
  BUILD_APP=0
elif [[ -n "${2:-}" ]]; then
  printf 'unknown option: %s\n' "$2" >&2
  exit 2
fi

require_command jq
require_command xcodebuild
require_command xcrun
[[ -x /usr/bin/perl ]] || die "required command is missing: /usr/bin/perl"

simctl_setup_timeout="${TESSERA_BOOTSTRAP_SIMCTL_SETUP_TIMEOUT:-90}"
simctl_bootstatus_timeout="${TESSERA_BOOTSTRAP_SIMCTL_BOOTSTATUS_TIMEOUT:-180}"
simctl_poll_timeout="${TESSERA_BOOTSTRAP_SIMCTL_POLL_TIMEOUT:-30}"
simctl_cleanup_timeout="${TESSERA_BOOTSTRAP_SIMCTL_CLEANUP_TIMEOUT:-15}"
harness_timeout="${TESSERA_BOOTSTRAP_HARNESS_TIMEOUT:-180}"
for timeout_value in \
  "$simctl_setup_timeout" \
  "$simctl_bootstatus_timeout" \
  "$simctl_poll_timeout" \
  "$simctl_cleanup_timeout" \
  "$harness_timeout"; do
  case "$timeout_value" in
    ''|0|*[!0-9]*) die "simctl timeouts must be positive integer seconds" ;;
  esac
done

simctl_setup_timeout_ms=$((10#$simctl_setup_timeout * 1000))
simctl_bootstatus_timeout_ms=$((10#$simctl_bootstatus_timeout * 1000))
simctl_poll_timeout_ms=$((10#$simctl_poll_timeout * 1000))
simctl_cleanup_timeout_ms=$((10#$simctl_cleanup_timeout * 1000))
harness_timeout_ms=$((10#$harness_timeout * 1000))

runtime="${TESSERA_BOOTSTRAP_SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-0}"
origin_type="${TESSERA_BOOTSTRAP_ORIGIN_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB}"
recipient_type="${TESSERA_BOOTSTRAP_RECIPIENT_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
derived_data="$(integration_derived_data)"
app_path="$(integration_app_path)"
scenario="${TESSERA_BOOTSTRAP_HARNESS_SCENARIO:-transfer}"
case "$scenario" in
  transfer|rejection|rejection-reversed) ;;
  *) die "unknown nearby-bootstrap harness scenario: $scenario" ;;
esac
artifact_dir="$RUN_DIR/programmatic/bootstrap-network"
if [[ "$scenario" == rejection ]]; then
  artifact_dir="$RUN_DIR/programmatic/bootstrap-network-rejection"
elif [[ "$scenario" == rejection-reversed ]]; then
  artifact_dir="$RUN_DIR/programmatic/bootstrap-network-rejection-reversed"
fi
mkdir -p "$derived_data" "$artifact_dir"

origin_udid=''
recipient_udid=''
created_udid=''
origin_name=''
recipient_name=''
# The suite runner boots one origin/recipient pair and reuses it for every
# scenario: each scenario still starts from a fresh app install (uninstall +
# install below), and the harness keeps all of its state inside the app
# container, so a shared pair costs no isolation while saving two device
# creations and boots per scenario. In that mode this script never deletes
# a device; it only removes its app and launchd environment on exit.
provided_pair=0
if [[ -n "${TESSERA_BOOTSTRAP_ORIGIN_UDID:-}" || -n "${TESSERA_BOOTSTRAP_RECIPIENT_UDID:-}" ]]; then
  [[ -n "${TESSERA_BOOTSTRAP_ORIGIN_UDID:-}" && -n "${TESSERA_BOOTSTRAP_RECIPIENT_UDID:-}" ]] \
    || die "TESSERA_BOOTSTRAP_ORIGIN_UDID and TESSERA_BOOTSTRAP_RECIPIENT_UDID must be set together"
  for candidate in "$TESSERA_BOOTSTRAP_ORIGIN_UDID" "$TESSERA_BOOTSTRAP_RECIPIENT_UDID"; do
    case "$candidate" in
      ????????-????-????-????-????????????) ;;
      *) die "provided bootstrap simulator ID is not a UUID: $candidate" ;;
    esac
    case "$candidate" in
      *[!0-9A-Fa-f-]*) die "provided bootstrap simulator ID is not a UUID: $candidate" ;;
    esac
  done
  provided_pair=1
  origin_udid="$TESSERA_BOOTSTRAP_ORIGIN_UDID"
  recipient_udid="$TESSERA_BOOTSTRAP_RECIPIENT_UDID"
fi

simulator_udid_is_absent() {
  local udid="$1"
  local devices count
  devices="$(simctl_bounded "$simctl_cleanup_timeout_ms" list devices -j)" \
    || return 1
  count="$(printf '%s' "$devices" | jq -r --arg udid "$udid" \
    '[.devices[][]? | select(.udid == $udid)] | length')" \
    || return 1
  [[ "$count" == 0 ]]
}

cleanup_simulator() {
  local name="$1"
  local udid="$2"
  [[ -n "$name" && -n "$udid" ]] || return 0
  case "$udid" in
    ????????-????-????-????-????????????) ;;
    *) note "refusing to delete invalid disposable simulator ID: $udid"; return 1 ;;
  esac
  case "$udid" in
    *[!0-9A-Fa-f-]*) note "refusing to delete non-UUID simulator ID: $udid"; return 1 ;;
  esac
  # Deleting the disposable device terminates its app and removes its launchd
  # environment. This UDID was resolved by the exact generated name below;
  # never turn a create timeout or malformed create response into a broad
  # deletion. Every call is bounded so a sick CoreSimulator service cannot
  # wedge the EXIT trap.
  for _ in 1 2; do
    simctl_bounded "$simctl_cleanup_timeout_ms" shutdown "$udid" \
      >/dev/null 2>&1 || true
    if simctl_bounded "$simctl_cleanup_timeout_ms" delete "$udid" \
        >/dev/null 2>&1; then
      return 0
    fi
    simulator_udid_is_absent "$udid" && return 0
    sleep 1
  done
  note "failed to delete disposable simulator $udid"
  return 1
}

cleanup_simulator_target() {
  local name="$1"
  local expected_udid="$2"
  local devices resolved candidate known_name status=0
  [[ -n "$name" ]] || return 0
  # Resolve every deletion target from the exact run-scoped name, even after a
  # successful create. A bounded or malformed `simctl create` can leave a
  # device behind without yielding a trustworthy UDID; this deliberately
  # cannot match a user device by a broad type/runtime query.
  devices="$(simctl_bounded "$simctl_cleanup_timeout_ms" list devices -j)" \
    || { note "failed to resolve disposable simulator named $name"; return 1; }
  resolved="$(printf '%s' "$devices" | jq -r --arg name "$name" --arg udid "$expected_udid" \
    '.devices[][]? | select(.name == $name and ($udid == "" or .udid == $udid)) | .udid')" \
    || { note "failed to parse disposable simulator named $name"; return 1; }
  if [[ -n "$expected_udid" && -z "$resolved" ]]; then
    known_name="$(printf '%s' "$devices" | jq -r --arg udid "$expected_udid" \
      '[.devices[][]? | select(.udid == $udid) | .name][0] // empty')" \
      || { note "failed to inspect disposable simulator $expected_udid"; return 1; }
    # A device already absent is a successful cleanup. If the known UDID was
    # renamed, refuse it: the name+UDID pair is the ownership proof that keeps
    # this trap away from persistent user simulators.
    [[ -z "$known_name" ]] && return 0
    note "refusing to delete simulator $expected_udid because its name is $known_name, not $name"
    return 1
  fi
  [[ -n "$resolved" ]] || return 0
  while IFS= read -r candidate; do
    cleanup_simulator "$name" "$candidate" || status=1
  done <<<"$resolved"
  return "$status"
}

# Provided-pair mode: leave the devices to their owner, but remove this
# scenario's app (its container holds every harness default and marker) and
# launchd environment so the next scenario on the same pair starts clean.
release_provided_device() {
  local udid="$1"
  local status=0
  simctl_bounded "$simctl_cleanup_timeout_ms" terminate "$udid" com.bambouville.TesseraApp \
    >/dev/null 2>&1 || true
  simctl_bounded "$simctl_cleanup_timeout_ms" spawn "$udid" launchctl unsetenv \
    TESSERA_BOOTSTRAP_NETWORK_HARNESS >/dev/null 2>&1 || true
  simctl_bounded "$simctl_cleanup_timeout_ms" spawn "$udid" launchctl unsetenv \
    TESSERA_BOOTSTRAP_NETWORK_HARNESS_SCENARIO >/dev/null 2>&1 || true
  if ! simctl_bounded "$simctl_cleanup_timeout_ms" uninstall "$udid" com.bambouville.TesseraApp \
      >/dev/null 2>&1; then
    note "failed to uninstall the harness app from provided simulator $udid"
    status=1
  fi
  return "$status"
}

cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  local cleanup_status=0
  trap - EXIT HUP INT TERM
  if [[ "$provided_pair" -eq 1 ]]; then
    release_provided_device "$recipient_udid" || cleanup_status=1
    release_provided_device "$origin_udid" || cleanup_status=1
  else
    cleanup_simulator_target "$recipient_name" "$recipient_udid" || cleanup_status=1
    cleanup_simulator_target "$origin_name" "$origin_udid" || cleanup_status=1
  fi
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    status=$cleanup_status
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

create_simulator() {
  local name="$1"
  local device_type="$2"
  local candidate
  if ! candidate="$(simctl_bounded "$simctl_setup_timeout_ms" \
      create "$name" "$device_type" "$runtime")"; then
    die "failed to create disposable simulator $name"
  fi
  case "$candidate" in
    ????????-????-????-????-????????????) ;;
    *) die "simctl create returned an invalid disposable simulator ID" ;;
  esac
  case "$candidate" in
    *[!0-9A-Fa-f-]*) die "simctl create returned a non-UUID simulator ID" ;;
  esac
  created_udid="$candidate"
}

if [[ $BUILD_APP -eq 1 ]]; then
  xcodebuild build \
    -project "$REPO_ROOT/Tessera.xcodeproj" \
    -scheme Tessera \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data"
fi
[[ -d "$app_path" ]] || die "bootstrap harness build did not produce $app_path"

if [[ "$provided_pair" -eq 1 ]]; then
  # The owner booted both devices; confirm they are usable within the same
  # bound a fresh boot gets, then start from no installed app at all.
  simctl_bounded "$simctl_bootstatus_timeout_ms" bootstatus "$origin_udid" -b
  simctl_bounded "$simctl_bootstatus_timeout_ms" bootstatus "$recipient_udid" -b
  for udid in "$origin_udid" "$recipient_udid"; do
    simctl_bounded "$simctl_cleanup_timeout_ms" terminate "$udid" com.bambouville.TesseraApp \
      >/dev/null 2>&1 || true
    simctl_bounded "$simctl_setup_timeout_ms" uninstall "$udid" com.bambouville.TesseraApp \
      >/dev/null 2>&1 || true
  done
else
  token="$(basename "$RUN_DIR")-$scenario-$$"
  origin_name="Tessera Bootstrap Origin $token"
  recipient_name="Tessera Bootstrap Recipient $token"
  create_simulator "$origin_name" "$origin_type"
  origin_udid="$created_udid"
  created_udid=''
  create_simulator "$recipient_name" "$recipient_type"
  recipient_udid="$created_udid"

  for udid in "$origin_udid" "$recipient_udid"; do
    simctl_bounded "$simctl_setup_timeout_ms" boot "$udid" >/dev/null
  done
  simctl_bounded "$simctl_bootstatus_timeout_ms" bootstatus "$origin_udid" -b
  simctl_bounded "$simctl_bootstatus_timeout_ms" bootstatus "$recipient_udid" -b
fi

simctl_bounded "$simctl_setup_timeout_ms" install "$origin_udid" "$app_path"
simctl_bounded "$simctl_setup_timeout_ms" install "$recipient_udid" "$app_path"
simctl_bounded "$simctl_setup_timeout_ms" spawn "$origin_udid" launchctl setenv \
  TESSERA_BOOTSTRAP_NETWORK_HARNESS origin
simctl_bounded "$simctl_setup_timeout_ms" spawn "$recipient_udid" launchctl setenv \
  TESSERA_BOOTSTRAP_NETWORK_HARNESS recipient
for udid in "$origin_udid" "$recipient_udid"; do
  simctl_bounded "$simctl_setup_timeout_ms" spawn "$udid" launchctl setenv \
    TESSERA_BOOTSTRAP_NETWORK_HARNESS_SCENARIO "$scenario"
done

harness_log_start="$(date '+%Y-%m-%d %H:%M:%S')"
simctl_bounded "$simctl_setup_timeout_ms" launch \
  "$origin_udid" com.bambouville.TesseraApp >/dev/null
sleep 1
simctl_bounded "$simctl_setup_timeout_ms" launch \
  "$recipient_udid" com.bambouville.TesseraApp >/dev/null

read_harness_log() {
  local udid="$1"
  local timeout="$2"
  simctl_bounded "$timeout" spawn "$udid" log show \
    --style compact \
    --start "$harness_log_start" \
    --predicate 'eventMessage CONTAINS "[Tessera][BootstrapNetworkHarness]"'
}

refresh_harness_log() {
  local role="$1"
  local udid="$2"
  local timeout="$3"
  local destination="$artifact_dir/$role.log"
  local candidate="$destination.next"
  local status
  if read_harness_log "$udid" "$timeout" >"$candidate"; then
    mv "$candidate" "$destination"
    return 0
  else
    status=$?
  fi
  rm -f "$candidate"
  return "$status"
}

monotonic_milliseconds() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%d\n", int(clock_gettime(CLOCK_MONOTONIC) * 1000)'
}

sleep_milliseconds() {
  /usr/bin/perl -MTime::HiRes=sleep -e 'sleep(shift(@ARGV) / 1000)' "$1"
}

: >"$artifact_dir/origin.log"
: >"$artifact_dir/recipient.log"
completed=0
poll_deadline_ms=$(( $(monotonic_milliseconds) + harness_timeout_ms ))
while :; do
  remaining_ms=$(( poll_deadline_ms - $(monotonic_milliseconds) ))
  (( remaining_ms > 0 )) || break
  call_timeout_ms="$simctl_poll_timeout_ms"
  (( call_timeout_ms > remaining_ms )) && call_timeout_ms="$remaining_ms"
  refresh_status=0
  refresh_harness_log origin "$origin_udid" "$call_timeout_ms" || refresh_status=$?
  [[ "$refresh_status" -eq 0 || "$refresh_status" -eq 124 ]] \
    || die "failed to read origin nearby-bootstrap harness log"

  remaining_ms=$(( poll_deadline_ms - $(monotonic_milliseconds) ))
  (( remaining_ms > 0 )) || break
  call_timeout_ms="$simctl_poll_timeout_ms"
  (( call_timeout_ms > remaining_ms )) && call_timeout_ms="$remaining_ms"
  refresh_status=0
  refresh_harness_log recipient "$recipient_udid" "$call_timeout_ms" || refresh_status=$?
  [[ "$refresh_status" -eq 0 || "$refresh_status" -eq 124 ]] \
    || die "failed to read recipient nearby-bootstrap harness log"
  if [[ "$scenario" != transfer && ! -f "$artifact_dir/peer-rejection-alert.png" ]]; then
    notice_udid="$origin_udid"
    notice_log="$artifact_dir/origin.log"
    notice_role=origin
    if [[ "$scenario" == rejection-reversed ]]; then
      notice_udid="$recipient_udid"
      notice_log="$artifact_dir/recipient.log"
      notice_role=recipient
    fi
    if grep -Eq "role=$notice_role event=peer-rejection-notice visible=true" "$notice_log"; then
      remaining_ms=$(( poll_deadline_ms - $(monotonic_milliseconds) ))
      if (( remaining_ms > 0 )); then
        capture_pause_ms=1000
        (( capture_pause_ms > remaining_ms )) && capture_pause_ms="$remaining_ms"
        sleep_milliseconds "$capture_pause_ms"
      fi
      remaining_ms=$(( poll_deadline_ms - $(monotonic_milliseconds) ))
      if (( remaining_ms > 0 )); then
        call_timeout_ms="$simctl_poll_timeout_ms"
        (( call_timeout_ms > remaining_ms )) && call_timeout_ms="$remaining_ms"
        if ! simctl_bounded "$call_timeout_ms" io "$notice_udid" screenshot \
            "$artifact_dir/peer-rejection-alert.png"; then
          note "could not capture peer-rejection alert before harness deadline"
        fi
      fi
    fi
  fi
  if [[ "$scenario" != transfer && ! -f "$artifact_dir/peer-rejection-retry.png" ]]; then
    notice_udid="$origin_udid"
    notice_log="$artifact_dir/origin.log"
    notice_role=origin
    if [[ "$scenario" == rejection-reversed ]]; then
      notice_udid="$recipient_udid"
      notice_log="$artifact_dir/recipient.log"
      notice_role=recipient
    fi
    if grep -Eq "role=$notice_role event=peer-rejection-notice acknowledged=true" "$notice_log"; then
      remaining_ms=$(( poll_deadline_ms - $(monotonic_milliseconds) ))
      if (( remaining_ms > 0 )); then
        call_timeout_ms="$simctl_poll_timeout_ms"
        (( call_timeout_ms > remaining_ms )) && call_timeout_ms="$remaining_ms"
        if ! simctl_bounded "$call_timeout_ms" io "$notice_udid" screenshot \
            "$artifact_dir/peer-rejection-retry.png"; then
          note "could not capture peer-rejection retry screen before harness deadline"
        fi
      fi
    fi
  fi
  if grep -Eq 'role=origin result=failed' "$artifact_dir/origin.log" \
      || grep -Eq 'role=recipient result=failed' "$artifact_dir/recipient.log"; then
    break
  fi
  if grep -Eq 'role=origin result=completed installed=1' "$artifact_dir/origin.log" \
      && grep -Eq 'role=recipient result=completed installed=1 trusted=0' "$artifact_dir/recipient.log"; then
    completed=1
    break
  fi
  remaining_ms=$(( poll_deadline_ms - $(monotonic_milliseconds) ))
  (( remaining_ms > 0 )) || break
  poll_pause_ms=1000
  (( poll_pause_ms > remaining_ms )) && poll_pause_ms="$remaining_ms"
  sleep_milliseconds "$poll_pause_ms"
done

if grep -Eq 'result=failed' "$artifact_dir/origin.log" "$artifact_dir/recipient.log"; then
  grep -E 'result=failed' "$artifact_dir/origin.log" "$artifact_dir/recipient.log" >&2 || true
  die "the production nearby-bootstrap harness reported failure"
fi
[[ $completed -eq 1 ]] || die "the two-simulator nearby-bootstrap harness timed out"

origin_sas="$(sed -n 's/.*role=origin event=sas attempt=1 code=\([0-9][0-9][0-9] [0-9][0-9][0-9]\).*/\1/p' "$artifact_dir/origin.log" | tail -n 1)"
recipient_sas="$(sed -n 's/.*role=recipient event=sas attempt=1 code=\([0-9][0-9][0-9] [0-9][0-9][0-9]\).*/\1/p' "$artifact_dir/recipient.log" | tail -n 1)"
[[ -n "$origin_sas" && -n "$recipient_sas" ]] \
  || die "one or both harness roles did not emit an SAS"
[[ "$origin_sas" == "$recipient_sas" ]] \
  || die "nearby-bootstrap SAS mismatch: origin=$origin_sas recipient=$recipient_sas"
grep -Eq 'role=origin event=sas attempt=1 .*peer="Tessera Bootstrap Harness Recipient"' \
  "$artifact_dir/origin.log" \
  || die "origin did not receive the recipient device label"
grep -Eq 'role=recipient event=sas attempt=1 .*peer="Tessera Bootstrap Harness Origin"' \
  "$artifact_dir/recipient.log" \
  || die "recipient did not receive the origin device label"

if [[ "$scenario" != transfer ]]; then
  rejecting_role=recipient
  untouched_role=origin
  if [[ "$scenario" == rejection-reversed ]]; then
    rejecting_role=origin
    untouched_role=recipient
  fi
  grep -Eq "role=$rejecting_role event=sas-rejected-local" \
    "$artifact_dir/$rejecting_role.log" \
    || die "$rejecting_role did not reject the SAS"
  grep -Eq "role=$untouched_role event=peer-rejection-notice acknowledged=true" \
    "$artifact_dir/$untouched_role.log" \
    || die "untouched $untouched_role did not acknowledge the peer-rejection notice"
  for role in origin recipient; do
    grep -Eq "role=$role event=retry-started" "$artifact_dir/$role.log" \
      || die "$role did not retry after rejection"
    grep -Eq "role=$role event=retry-sas fresh=true" "$artifact_dir/$role.log" \
      || die "$role did not establish a fresh retry handshake"
  done
  origin_retry_sas="$(sed -n 's/.*role=origin event=sas attempt=2 code=\([0-9][0-9][0-9] [0-9][0-9][0-9]\).*/\1/p' "$artifact_dir/origin.log" | tail -n 1)"
  recipient_retry_sas="$(sed -n 's/.*role=recipient event=sas attempt=2 code=\([0-9][0-9][0-9] [0-9][0-9][0-9]\).*/\1/p' "$artifact_dir/recipient.log" | tail -n 1)"
  [[ -n "$origin_retry_sas" && "$origin_retry_sas" == "$recipient_retry_sas" ]] \
    || die "retry SAS mismatch: origin=$origin_retry_sas recipient=$recipient_retry_sas"
  [[ "$origin_retry_sas" != "$origin_sas" ]] \
    || die "retry did not produce a new comparison code"
  [[ -f "$artifact_dir/peer-rejection-alert.png" ]] \
    || die "the untouched $untouched_role rejection alert was not captured"
  [[ -f "$artifact_dir/peer-rejection-retry.png" ]] \
    || die "the untouched $untouched_role retry page was not captured"
  printf 'nearby bootstrap rejection: real Bonjour + encrypted decision passed; first SAS=%s; untouched %s acknowledged; fresh retry SAS=%s; transfer completed\n' \
    "$origin_sas" "$untouched_role" "$origin_retry_sas"
else
  printf 'nearby bootstrap: real Bonjour + encrypted channel passed; SAS=%s; peer labels matched; both roles installed=1; default trusted keys imported=0\n' \
    "$origin_sas"
fi
script_completed=1
