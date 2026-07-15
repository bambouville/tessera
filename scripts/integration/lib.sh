#!/usr/bin/env bash

INTEGRATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$INTEGRATION_DIR/../.." && pwd)"
FIXTURE_CONFIG="${TESSERA_FIXTURE_CONFIG:-$INTEGRATION_DIR/fixture.env}"
FIXTURE_STATE="$INTEGRATION_DIR/.state"
FIXTURE_OUT="$INTEGRATION_DIR/out"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '[integration] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is not set in $FIXTURE_CONFIG"
}

load_fixture_config() {
  [[ -f "$FIXTURE_CONFIG" ]] || die "missing $FIXTURE_CONFIG (copy fixture.env.example)"
  # shellcheck disable=SC1090
  source "$FIXTURE_CONFIG"

  : "${TESSERA_FIXTURE_CONTROL_USER:=root}"
  : "${TESSERA_FIXTURE_CONTROL_PORT:=22}"
  : "${TESSERA_FIXTURE_APP_PORT:=2222}"
  : "${TESSERA_FIXTURE_USER:=tessera}"
  : "${TESSERA_FIXTURE_NOTMUX_USER:=tessera-notmux}"

  require_value TESSERA_FIXTURE_STABLE_HOST
  require_value TESSERA_FIXTURE_CHAOS_HOST
  require_value TESSERA_FIXTURE_CONTROL_KEY

  [[ -r "$TESSERA_FIXTURE_CONTROL_KEY" ]] \
    || die "control key is not readable: $TESSERA_FIXTURE_CONTROL_KEY"

  mkdir -p "$FIXTURE_STATE" "$FIXTURE_OUT"
  chmod 700 "$FIXTURE_STATE"
  TESSERA_FIXTURE_CONTROL_KNOWN_HOSTS="$FIXTURE_STATE/control_known_hosts"
  TESSERA_FIXTURE_APP_KNOWN_HOSTS="$FIXTURE_STATE/app_known_hosts"
}

control_ssh() {
  local host="$1"
  shift
  ssh \
    -i "$TESSERA_FIXTURE_CONTROL_KEY" \
    -p "$TESSERA_FIXTURE_CONTROL_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_CONTROL_KNOWN_HOSTS" \
    "$TESSERA_FIXTURE_CONTROL_USER@$host" "$@"
}

control_scp() {
  local source_path="$1"
  local host="$2"
  local destination_path="$3"
  scp \
    -i "$TESSERA_FIXTURE_CONTROL_KEY" \
    -P "$TESSERA_FIXTURE_CONTROL_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_CONTROL_KNOWN_HOSTS" \
    "$source_path" "$TESSERA_FIXTURE_CONTROL_USER@$host:$destination_path"
}

fixture_ssh() {
  local host="$1"
  shift
  ssh \
    -i "$FIXTURE_STATE/client_ed25519" \
    -p "$TESSERA_FIXTURE_APP_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_APP_KNOWN_HOSTS" \
    "$TESSERA_FIXTURE_USER@$host" "$@"
}

ensure_fixture_credentials() {
  require_command ssh-keygen
  require_command openssl

  if [[ ! -f "$FIXTURE_STATE/client_ed25519" ]]; then
    note "generating an app-facing Ed25519 fixture key"
    ssh-keygen \
      -q -t ed25519 -a 64 -N '' \
      -C 'tessera-integration-fixture' \
      -f "$FIXTURE_STATE/client_ed25519"
  fi
  chmod 600 "$FIXTURE_STATE/client_ed25519"

  if [[ ! -f "$FIXTURE_STATE/password" ]]; then
    openssl rand -hex 24 >"$FIXTURE_STATE/password"
  fi
  chmod 600 "$FIXTURE_STATE/password"
}

fixture_password() {
  [[ -f "$FIXTURE_STATE/password" ]] || die "fixture password has not been generated"
  IFS= read -r REPLY <"$FIXTURE_STATE/password"
  printf '%s' "$REPLY"
}

fixture_public_key() {
  [[ -f "$FIXTURE_STATE/client_ed25519.pub" ]] || die "fixture public key has not been generated"
  IFS= read -r REPLY <"$FIXTURE_STATE/client_ed25519.pub"
  printf '%s' "$REPLY"
}
