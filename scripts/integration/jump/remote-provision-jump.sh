#!/usr/bin/env bash
# Runs ON a disposable jump-test droplet (fed via `ssh bash -s`). Idempotent.
set -euo pipefail

ROLE="${1:-}"                 # bastion | target
KEY_USER="${2:-}"             # pubkey-only login
PW_USER="${3:-}"              # password-only login
APP_PORT="${4:-}"             # app-facing sshd port
INNER_PORT="${5:-}"           # loopback-only sshd port (target only)
PASSWORD_HASH_B64="${6:-}"
PUBLIC_KEY_B64="${7:-}"
ALLOWED_SOURCES="${8:-}"      # target only: comma-separated IPs allowed to reach APP_PORT

[[ "$ROLE" == bastion || "$ROLE" == target ]] || { printf 'invalid role\n' >&2; exit 2; }
[[ "$KEY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'invalid key user\n' >&2; exit 2; }
[[ "$PW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'invalid pw user\n' >&2; exit 2; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { printf 'invalid app port\n' >&2; exit 2; }
[[ "$INNER_PORT" =~ ^[0-9]+$ ]] || { printf 'invalid inner port\n' >&2; exit 2; }
if [[ "$ROLE" == target ]]; then
  [[ "$ALLOWED_SOURCES" =~ ^[0-9.,]+$ ]] || { printf 'invalid allowed sources\n' >&2; exit 2; }
fi

PASSWORD_HASH="$(printf '%s' "$PASSWORD_HASH_B64" | base64 -d)"
PUBLIC_KEY="$(printf '%s' "$PUBLIC_KEY_B64" | base64 -d)"
[[ "$PASSWORD_HASH" == \$6\$* ]] || { printf 'invalid password hash\n' >&2; exit 2; }
[[ "$PUBLIC_KEY" == ssh-ed25519\ * ]] || { printf 'invalid public key\n' >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  bash ca-certificates curl htop mosh netcat-openbsd nftables openssh-server \
  python3 sshpass sudo tmux vim-nox

ROOT=/opt/tessera-jump
mkdir -p "$ROOT/ssh"

ensure_user() {
  local user="$1"
  if ! id "$user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$user"
  fi
  usermod --password "$PASSWORD_HASH" "$user"
  install -d -m 0700 -o "$user" -g "$user" "/home/$user/.ssh"
  printf '%s\n' "$PUBLIC_KEY" >"/home/$user/.ssh/authorized_keys"
  chown "$user:$user" "/home/$user/.ssh/authorized_keys"
  chmod 0600 "/home/$user/.ssh/authorized_keys"
}

ensure_user "$KEY_USER"
ensure_user "$PW_USER"
# PW_USER must not be able to use the shared pubkey — password lane only.
rm -f "/home/$PW_USER/.ssh/authorized_keys"

# Deterministic file-panel fixtures (mirrors the main integration fixtures).
for user in "$KEY_USER" "$PW_USER"; do
  home="/home/$user"
  install -d -m 0755 -o "$user" -g "$user" "$home/fixture-files/subdirectory"
  printf 'visible fixture file\n' >"$home/fixture-files/visible.txt"
  printf 'hidden fixture file\n' >"$home/fixture-files/.hidden"
  printf 'extensionless fixture file\n' >"$home/fixture-files/testfile"
  printf 'nested fixture file\n' >"$home/fixture-files/subdirectory/nested.txt"
  chown -R "$user:$user" "$home/fixture-files"
done

if [[ ! -f "$ROOT/ssh/ssh_host_ed25519_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -f "$ROOT/ssh/ssh_host_ed25519_key"
fi
chmod 0600 "$ROOT/ssh/ssh_host_ed25519_key"

write_sshd_config() {
  local path="$1" port="$2" listen="$3" pidfile="$4"
  cat >"$path" <<EOF
Port $port
ListenAddress $listen
AddressFamily inet
HostKey $ROOT/ssh/ssh_host_ed25519_key
PidFile $pidfile
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AllowUsers $KEY_USER $PW_USER
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
PrintMotd no
UseDNS no
MaxSessions 64
ClientAliveInterval 30
ClientAliveCountMax 4
Subsystem sftp internal-sftp
Match User $PW_USER
  PasswordAuthentication yes
  PubkeyAuthentication no
EOF
}

install_sshd_unit() {
  local name="$1" config="$2"
  cat >"/etc/systemd/system/$name.service" <<EOF
[Unit]
Description=Tessera jump-test SSH endpoint ($name)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sshd -D -e -f $config
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
}

write_sshd_config "$ROOT/sshd_config" "$APP_PORT" 0.0.0.0 /run/tessera-jump-sshd.pid
/usr/sbin/sshd -t -f "$ROOT/sshd_config"
install_sshd_unit tessera-jump-sshd "$ROOT/sshd_config"

if [[ "$ROLE" == target ]]; then
  # Loopback-only inner endpoint: reachable ONLY by jumping through this host.
  write_sshd_config "$ROOT/sshd_config_inner" "$INNER_PORT" 127.0.0.1 /run/tessera-jump-inner-sshd.pid
  /usr/sbin/sshd -t -f "$ROOT/sshd_config_inner"
  install_sshd_unit tessera-jump-inner-sshd "$ROOT/sshd_config_inner"

  # Loopback-only HTTP endpoint for port-forwarding-through-jump tests.
  cat >/etc/systemd/system/tessera-jump-http.service <<EOF
[Unit]
Description=Tessera jump-test loopback HTTP endpoint
After=network.target

[Service]
Type=simple
User=$KEY_USER
WorkingDirectory=/home/$KEY_USER/fixture-files
ExecStart=/usr/bin/python3 -m http.server 18080 --bind 127.0.0.1
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

  # Firewall: app port only from the bastion; mosh UDP dropped by default
  # (the realistic corporate case). Control port 22 is untouched.
  allowed_set="{ ${ALLOWED_SOURCES//,/, } }"
  cat >/usr/local/sbin/tessera-jump-firewall <<EOF
#!/usr/bin/env bash
set -euo pipefail
nft -f - <<'RULES'
destroy table inet tessera_jump
table inet tessera_jump {
  chain input {
    type filter hook input priority -10; policy accept;
    tcp dport $APP_PORT ip saddr $allowed_set accept
    tcp dport $APP_PORT drop
  }
}
RULES
/usr/local/sbin/tessera-jump-mosh block
EOF
  chmod 0755 /usr/local/sbin/tessera-jump-firewall

  cat >/usr/local/sbin/tessera-jump-mosh <<'EOF'
#!/usr/bin/env bash
# tessera-jump-mosh block|allow|status — toggle mosh UDP reachability.
set -euo pipefail
case "${1:-status}" in
  block)
    nft -f - <<'RULES'
destroy table inet tessera_jump_mosh
table inet tessera_jump_mosh {
  chain input {
    type filter hook input priority -5; policy accept;
    udp dport 60000-61000 drop
  }
}
RULES
    ;;
  allow)
    nft destroy table inet tessera_jump_mosh 2>/dev/null || true
    ;;
  status)
    if nft list table inet tessera_jump_mosh >/dev/null 2>&1; then
      echo blocked
    else
      echo allowed
    fi
    ;;
  *)
    echo 'usage: tessera-jump-mosh block|allow|status' >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 /usr/local/sbin/tessera-jump-mosh

  cat >/etc/systemd/system/tessera-jump-firewall.service <<EOF
[Unit]
Description=Tessera jump-test firewall (target isolation)
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tessera-jump-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
fi

cat >"$ROOT/role.env" <<EOF
role=$ROLE
key_user=$KEY_USER
pw_user=$PW_USER
app_port=$APP_PORT
inner_port=$INNER_PORT
EOF

systemctl daemon-reload
systemctl enable --now tessera-jump-sshd.service >/dev/null
systemctl restart tessera-jump-sshd.service
if [[ "$ROLE" == target ]]; then
  systemctl enable --now tessera-jump-inner-sshd.service >/dev/null
  systemctl restart tessera-jump-inner-sshd.service
  systemctl enable --now tessera-jump-http.service >/dev/null
  systemctl restart tessera-jump-http.service
  systemctl enable --now tessera-jump-firewall.service >/dev/null
  /usr/local/sbin/tessera-jump-firewall
fi

printf 'role=%s\n' "$ROLE"
printf 'app_port=%s\n' "$APP_PORT"
printf 'tmux=%s\n' "$(tmux -V)"
printf 'mosh=%s\n' "$(mosh-server --version 2>&1 | sed -n '1p')"
if [[ "$ROLE" == target ]]; then
  printf 'mosh_udp=%s\n' "$(/usr/local/sbin/tessera-jump-mosh status)"
fi
printf 'host_key='
ssh-keygen -lf "$ROOT/ssh/ssh_host_ed25519_key.pub"
