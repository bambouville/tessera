#!/usr/bin/env bash
# Proves the jump topology from this Mac before any app-level testing:
#   1. bastion app endpoint reachable directly (key auth)
#   2. target app endpoint NOT reachable directly (firewall)
#   3. target reachable via ProxyJump; SSH_CONNECTION shows the bastion as source
#   4. per-hop key isolation (bastion key rejected at target and vice versa)
#   5. password lane works bastion->target (distinct per-hop password)
#   6. multi-hop chain to the loopback-only inner sshd
#   7. SFTP through the jump
#   8. mosh UDP blocked by default; tmux present on target
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-jump.sh
source "$HERE/lib-jump.sh"

load_jump_config
ensure_jump_credentials
write_jump_ssh_config

SSH="ssh -F $JUMP_STATE/ssh_config"
pass=0
fail=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    jump_note "PASS $label"
    pass=$((pass + 1))
  else
    jump_note "FAIL $label"
    fail=$((fail + 1))
  fi
}

check_not() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    jump_note "FAIL $label (unexpectedly succeeded)"
    fail=$((fail + 1))
  else
    jump_note "PASS $label"
    pass=$((pass + 1))
  fi
}

# 1. Bastion app endpoint, key auth.
check "bastion:$TESSERA_JUMP_APP_PORT key auth" \
  $SSH jump-bastion hostname

# 2. Target app endpoint must be unreachable directly (5s TCP timeout).
check_not "target:$TESSERA_JUMP_APP_PORT direct connect blocked" \
  nc -z -G 5 "$TESSERA_JUMP_TARGET_HOST" "$TESSERA_JUMP_APP_PORT"

# Control plane on the target must still be open (sanity that the firewall
# isolated only the app port).
check "target:22 control plane still open" \
  jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" true

# 3. Jump works and genuinely routes through the bastion.
conn="$($SSH jump-target 'printf "%s" "$SSH_CONNECTION"' 2>/dev/null || true)"
src="${conn%% *}"
if [[ "$src" == "$TESSERA_JUMP_BASTION_HOST" || "$src" == "$TESSERA_JUMP_BASTION_PRIVATE" ]]; then
  jump_note "PASS jump routes via bastion (source $src)"
  pass=$((pass + 1))
else
  jump_note "FAIL jump source is '$src', expected a bastion address"
  fail=$((fail + 1))
fi

# 4. Per-hop key isolation: the bastion client key must NOT work at the
# target, and the target client key must NOT work at the bastion.
check_not "target rejects bastion client key" \
  $SSH jump-target-wrongkey true
check_not "bastion rejects target client key" \
  $SSH jump-bastion-wrongkey true

# 5. Password lane, bastion -> target over the VPC private network (sshpass
# lives on the droplets, not the Mac).
check "password auth bastion->target ($TESSERA_JUMP_PW_USER)" \
  jump_control_ssh "$TESSERA_JUMP_BASTION_HOST" \
  "sshpass -p '$(jump_password target)' \
     ssh -p $TESSERA_JUMP_APP_PORT -o StrictHostKeyChecking=no \
     -o PreferredAuthentications=password -o PubkeyAuthentication=no \
     $TESSERA_JUMP_PW_USER@$TESSERA_JUMP_TARGET_PRIVATE hostname"

# 6. Multi-hop: Mac -> bastion -> target -> loopback-only inner sshd.
check "multi-hop chain to inner sshd" \
  $SSH jump-inner hostname

# 7. SFTP subsystem through the jump (file panel's transport).
check "sftp through jump" \
  bash -c "printf 'ls fixture-files\nbye\n' | sftp -q -F $JUMP_STATE/ssh_config -b - jump-target"

# 8. Environment details.
check "tmux present on target" \
  $SSH jump-target tmux -V
check "loopback http endpoint (port-forward target)" \
  $SSH jump-target "curl -s -o /dev/null http://127.0.0.1:18080/"
mosh_state="$(jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" /usr/local/sbin/tessera-jump-mosh status 2>/dev/null || echo unknown)"
if [[ "$mosh_state" == blocked ]]; then
  jump_note "PASS mosh udp blocked by default"
  pass=$((pass + 1))
else
  jump_note "FAIL mosh udp state is '$mosh_state', expected blocked"
  fail=$((fail + 1))
fi

jump_note "verification: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || jump_die "jump fixture verification failed"
