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
require_command rg
require_command xcodebuild
require_command xcrun

runtime="${TESSERA_BOOTSTRAP_SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-0}"
origin_type="${TESSERA_BOOTSTRAP_ORIGIN_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB}"
recipient_type="${TESSERA_BOOTSTRAP_RECIPIENT_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
derived_data="${TESSERA_INTEGRATION_DERIVED_DATA:-$FIXTURE_STATE/DerivedData}"
app_path="$derived_data/Build/Products/Debug-iphonesimulator/Tessera.app"
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
cleanup_simulator() {
  local udid="$1"
  [[ -n "$udid" ]] || return 0
  xcrun simctl terminate "$udid" com.bambouville.TesseraApp >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_BOOTSTRAP_NETWORK_HARNESS \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_BOOTSTRAP_NETWORK_HARNESS_SCENARIO \
    >/dev/null 2>&1 || true
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  # Both IDs come directly from run-scoped `simctl create` calls below. Never
  # resolve a user simulator by name and never broaden this delete target.
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}
cleanup() {
  cleanup_simulator "$recipient_udid"
  cleanup_simulator "$origin_udid"
}
trap cleanup EXIT

if [[ $BUILD_APP -eq 1 ]]; then
  xcodebuild build \
    -project "$REPO_ROOT/Tessera.xcodeproj" \
    -scheme Tessera \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data"
fi
[[ -d "$app_path" ]] || die "bootstrap harness build did not produce $app_path"

token="$(basename "$RUN_DIR")-$scenario-$$"
origin_udid="$(xcrun simctl create "Tessera Bootstrap Origin $token" "$origin_type" "$runtime")"
recipient_udid="$(xcrun simctl create "Tessera Bootstrap Recipient $token" "$recipient_type" "$runtime")"

for udid in "$origin_udid" "$recipient_udid"; do
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
done
xcrun simctl bootstatus "$origin_udid" -b
xcrun simctl bootstatus "$recipient_udid" -b

xcrun simctl install "$origin_udid" "$app_path"
xcrun simctl install "$recipient_udid" "$app_path"
xcrun simctl spawn "$origin_udid" launchctl setenv \
  TESSERA_BOOTSTRAP_NETWORK_HARNESS origin
xcrun simctl spawn "$recipient_udid" launchctl setenv \
  TESSERA_BOOTSTRAP_NETWORK_HARNESS recipient
for udid in "$origin_udid" "$recipient_udid"; do
  xcrun simctl spawn "$udid" launchctl setenv \
    TESSERA_BOOTSTRAP_NETWORK_HARNESS_SCENARIO "$scenario"
done

xcrun simctl launch "$origin_udid" com.bambouville.TesseraApp >/dev/null
sleep 1
xcrun simctl launch "$recipient_udid" com.bambouville.TesseraApp >/dev/null

read_harness_log() {
  local udid="$1"
  xcrun simctl spawn "$udid" log show \
    --style compact \
    --last 3m \
    --predicate 'eventMessage CONTAINS "[Tessera][BootstrapNetworkHarness]"' \
    2>/dev/null || true
}

completed=0
for _ in {1..180}; do
  read_harness_log "$origin_udid" >"$artifact_dir/origin.log"
  read_harness_log "$recipient_udid" >"$artifact_dir/recipient.log"
  if [[ "$scenario" != transfer && ! -f "$artifact_dir/peer-rejection-alert.png" ]]; then
    notice_udid="$origin_udid"
    notice_log="$artifact_dir/origin.log"
    notice_role=origin
    if [[ "$scenario" == rejection-reversed ]]; then
      notice_udid="$recipient_udid"
      notice_log="$artifact_dir/recipient.log"
      notice_role=recipient
    fi
    if rg -q "role=$notice_role event=peer-rejection-notice visible=true" "$notice_log"; then
      sleep 1
      xcrun simctl io "$notice_udid" screenshot \
        "$artifact_dir/peer-rejection-alert.png"
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
    if rg -q "role=$notice_role event=peer-rejection-notice acknowledged=true" "$notice_log"; then
      xcrun simctl io "$notice_udid" screenshot \
        "$artifact_dir/peer-rejection-retry.png"
    fi
  fi
  if rg -q 'role=origin result=failed' "$artifact_dir/origin.log" \
      || rg -q 'role=recipient result=failed' "$artifact_dir/recipient.log"; then
    break
  fi
  if rg -q 'role=origin result=completed installed=1' "$artifact_dir/origin.log" \
      && rg -q 'role=recipient result=completed installed=1 trusted=0' "$artifact_dir/recipient.log"; then
    completed=1
    break
  fi
  sleep 1
done

# Capture final logs even if the terminal state arrived between polls.
read_harness_log "$origin_udid" >"$artifact_dir/origin.log"
read_harness_log "$recipient_udid" >"$artifact_dir/recipient.log"

if rg -q 'result=failed' "$artifact_dir/origin.log" "$artifact_dir/recipient.log"; then
  rg 'result=failed' "$artifact_dir/origin.log" "$artifact_dir/recipient.log" >&2 || true
  die "the production nearby-bootstrap harness reported failure"
fi
[[ $completed -eq 1 ]] || die "the two-simulator nearby-bootstrap harness timed out"

origin_sas="$(sed -n 's/.*role=origin event=sas attempt=1 code=\([0-9][0-9][0-9] [0-9][0-9][0-9]\).*/\1/p' "$artifact_dir/origin.log" | tail -n 1)"
recipient_sas="$(sed -n 's/.*role=recipient event=sas attempt=1 code=\([0-9][0-9][0-9] [0-9][0-9][0-9]\).*/\1/p' "$artifact_dir/recipient.log" | tail -n 1)"
[[ -n "$origin_sas" && -n "$recipient_sas" ]] \
  || die "one or both harness roles did not emit an SAS"
[[ "$origin_sas" == "$recipient_sas" ]] \
  || die "nearby-bootstrap SAS mismatch: origin=$origin_sas recipient=$recipient_sas"
rg -q 'role=origin event=sas attempt=1 .*peer="Tessera Bootstrap Harness Recipient"' \
  "$artifact_dir/origin.log" \
  || die "origin did not receive the recipient device label"
rg -q 'role=recipient event=sas attempt=1 .*peer="Tessera Bootstrap Harness Origin"' \
  "$artifact_dir/recipient.log" \
  || die "recipient did not receive the origin device label"

if [[ "$scenario" != transfer ]]; then
  rejecting_role=recipient
  untouched_role=origin
  if [[ "$scenario" == rejection-reversed ]]; then
    rejecting_role=origin
    untouched_role=recipient
  fi
  rg -q "role=$rejecting_role event=sas-rejected-local" \
    "$artifact_dir/$rejecting_role.log" \
    || die "$rejecting_role did not reject the SAS"
  rg -q "role=$untouched_role event=peer-rejection-notice acknowledged=true" \
    "$artifact_dir/$untouched_role.log" \
    || die "untouched $untouched_role did not acknowledge the peer-rejection notice"
  for role in origin recipient; do
    rg -q "role=$role event=retry-started" "$artifact_dir/$role.log" \
      || die "$role did not retry after rejection"
    rg -q "role=$role event=retry-sas fresh=true" "$artifact_dir/$role.log" \
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
