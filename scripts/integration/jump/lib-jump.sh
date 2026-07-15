#!/usr/bin/env bash
# Shared helpers for the jump-host test bed (disposable DO droplets).

JUMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRATION_DIR="$(cd "$JUMP_DIR/.." && pwd)"
JUMP_CONFIG="${TESSERA_JUMP_CONFIG:-$JUMP_DIR/jump.env}"
JUMP_STATE="$INTEGRATION_DIR/.state/jump"

jump_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

jump_note() {
  printf '[jump] %s\n' "$*"
}

jump_require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || jump_die "$name is not set in $JUMP_CONFIG"
}

load_jump_config() {
  [[ -f "$JUMP_CONFIG" ]] || jump_die "missing $JUMP_CONFIG (copy jump.env.example)"
  # shellcheck disable=SC1090
  source "$JUMP_CONFIG"

  : "${TESSERA_JUMP_CONTROL_USER:=root}"
  : "${TESSERA_JUMP_CONTROL_PORT:=22}"
  : "${TESSERA_JUMP_APP_PORT:=2222}"
  : "${TESSERA_JUMP_INNER_PORT:=2223}"
  : "${TESSERA_JUMP_KEY_USER:=tessera}"
  : "${TESSERA_JUMP_PW_USER:=tessera-pw}"

  jump_require_value TESSERA_JUMP_BASTION_HOST
  jump_require_value TESSERA_JUMP_TARGET_HOST
  jump_require_value TESSERA_JUMP_BASTION_PRIVATE
  jump_require_value TESSERA_JUMP_TARGET_PRIVATE
  jump_require_value TESSERA_JUMP_CONTROL_KEY

  [[ -r "$TESSERA_JUMP_CONTROL_KEY" ]] \
    || jump_die "control key is not readable: $TESSERA_JUMP_CONTROL_KEY"

  mkdir -p "$JUMP_STATE"
  chmod 700 "$JUMP_STATE"
  TESSERA_JUMP_CONTROL_KNOWN_HOSTS="$JUMP_STATE/control_known_hosts"
  TESSERA_JUMP_APP_KNOWN_HOSTS="$JUMP_STATE/app_known_hosts"
}

jump_control_ssh() {
  local host="$1"
  shift
  ssh \
    -i "$TESSERA_JUMP_CONTROL_KEY" \
    -p "$TESSERA_JUMP_CONTROL_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$TESSERA_JUMP_CONTROL_KNOWN_HOSTS" \
    "$TESSERA_JUMP_CONTROL_USER@$host" "$@"
}

# Distinct client credentials per hop so per-hop auth is genuinely exercised.
ensure_jump_credentials() {
  local role
  for role in bastion target; do
    if [[ ! -f "$JUMP_STATE/client_${role}_ed25519" ]]; then
      ssh-keygen -q -t ed25519 -N '' \
        -C "tessera-jump-${role}-client" \
        -f "$JUMP_STATE/client_${role}_ed25519"
      jump_note "generated $role client key"
    fi
    if [[ ! -f "$JUMP_STATE/password_${role}" ]]; then
      openssl rand -base64 24 | tr -d '/+=' | cut -c1-20 \
        >"$JUMP_STATE/password_${role}"
      chmod 600 "$JUMP_STATE/password_${role}"
      jump_note "generated $role password"
    fi
  done
}

jump_password() {
  cat "$JUMP_STATE/password_$1"
}

jump_public_key() {
  cat "$JUMP_STATE/client_$1_ed25519.pub"
}

# ssh_config with per-hop identities; mirrors how Tessera must chain hops.
# ProxyCommand with an explicit -F (rather than ProxyJump) so the sub-ssh
# resolving the alias is guaranteed to read this config file.
write_jump_ssh_config() {
  local cfg="$JUMP_STATE/ssh_config"
  cat >"$cfg" <<EOF
Host jump-bastion
  HostName $TESSERA_JUMP_BASTION_HOST
  IdentityFile $JUMP_STATE/client_bastion_ed25519

Host jump-target
  HostName $TESSERA_JUMP_TARGET_HOST
  IdentityFile $JUMP_STATE/client_target_ed25519
  ProxyCommand ssh -F $cfg -W %h:%p jump-bastion

# Wrong-key variants prove per-hop key isolation (IdentityFile accumulates
# across matching blocks, so these need their own Host entries).
Host jump-target-wrongkey
  HostName $TESSERA_JUMP_TARGET_HOST
  IdentityFile $JUMP_STATE/client_bastion_ed25519
  ProxyCommand ssh -F $cfg -W %h:%p jump-bastion

Host jump-bastion-wrongkey
  HostName $TESSERA_JUMP_BASTION_HOST
  IdentityFile $JUMP_STATE/client_target_ed25519

Host jump-inner
  HostName 127.0.0.1
  Port $TESSERA_JUMP_INNER_PORT
  IdentityFile $JUMP_STATE/client_target_ed25519
  ProxyCommand ssh -F $cfg -W %h:%p jump-target

Host jump-*
  Port $TESSERA_JUMP_APP_PORT
  User $TESSERA_JUMP_KEY_USER
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 15
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $JUMP_STATE/app_known_hosts
EOF
}
