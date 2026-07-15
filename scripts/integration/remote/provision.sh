#!/usr/bin/env bash
set -euo pipefail

ROLE="${1:-}"
FIXTURE_USER="${2:-}"
NOTMUX_USER="${3:-}"
APP_PORT="${4:-}"
PASSWORD_HASH_B64="${5:-}"
PUBLIC_KEY_B64="${6:-}"

[[ "$ROLE" == stable || "$ROLE" == chaos ]] || { printf 'invalid role\n' >&2; exit 2; }
[[ "$FIXTURE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'invalid fixture user\n' >&2; exit 2; }
[[ "$NOTMUX_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'invalid no-tmux user\n' >&2; exit 2; }
[[ "$APP_PORT" =~ ^[0-9]+$ ]] || { printf 'invalid app port\n' >&2; exit 2; }

PASSWORD_HASH="$(printf '%s' "$PASSWORD_HASH_B64" | base64 -d)"
PUBLIC_KEY="$(printf '%s' "$PUBLIC_KEY_B64" | base64 -d)"
[[ "$PASSWORD_HASH" == \$6\$* ]] || { printf 'invalid password hash\n' >&2; exit 2; }
[[ "$PUBLIC_KEY" == ssh-ed25519\ * ]] || { printf 'invalid public key\n' >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  bash bison build-essential ca-certificates curl htop iptables jq \
  libevent-dev libncurses-dev mosh netcat-openbsd openssh-server \
  pkg-config python3 socat sudo tmux vim-nox

ROOT=/opt/tessera-fixture
STATE=/var/lib/tessera-fixture
mkdir -p "$ROOT/bin" "$ROOT/ssh" "$ROOT/notmux-bin" "$STATE/runs"

if [[ "$ROLE" == chaos ]]; then
  TMUX_PREFIX="$ROOT/tmux-3.6a"
  if [[ ! -x "$TMUX_PREFIX/bin/tmux" ]] \
    || [[ "$($TMUX_PREFIX/bin/tmux -V)" != 'tmux 3.6a' ]]; then
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL \
      https://github.com/tmux/tmux/releases/download/3.6a/tmux-3.6a.tar.gz \
      -o "$work/tmux-3.6a.tar.gz"
    tar -xzf "$work/tmux-3.6a.tar.gz" -C "$work"
    (
      cd "$work/tmux-3.6a"
      ./configure --prefix="$TMUX_PREFIX"
      make -j"$(nproc)"
      make install
    )
    rm -rf "$work"
    trap - EXIT
  fi
fi

install -m 0755 /tmp/tessera-fixture-probe.py /usr/local/bin/tessera-fixture-probe
install -m 0755 /tmp/tessera-fixture-admin /usr/local/sbin/tessera-fixture-admin

FIXTURE_SHELL=/bin/bash
if [[ "$ROLE" == chaos ]]; then
  FIXTURE_SHELL="$ROOT/bin/tessera-chaos-shell"
  cat >"$FIXTURE_SHELL" <<EOF
#!/usr/bin/env bash
export PATH="$ROOT/tmux-3.6a/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
exec /bin/bash "\$@"
EOF
  chmod 0755 "$FIXTURE_SHELL"
fi

NOTMUX_SHELL="$ROOT/bin/tessera-notmux-shell"
cat >"$NOTMUX_SHELL" <<EOF
#!/usr/bin/env bash
export PATH="$ROOT/notmux-bin"
exec /bin/bash "\$@"
EOF
chmod 0755 "$NOTMUX_SHELL"

for shell in "$FIXTURE_SHELL" "$NOTMUX_SHELL"; do
  grep -Fxq "$shell" /etc/shells || printf '%s\n' "$shell" >>/etc/shells
done

for command_path in \
  /bin/bash /bin/cat /bin/chmod /bin/cp /bin/date /bin/grep /bin/hostname \
  /bin/ln /bin/ls /bin/mkdir /bin/mv /bin/pwd /bin/rm /bin/sed /bin/sh \
  /bin/sleep /bin/stty /bin/touch /usr/bin/awk /usr/bin/base64 /usr/bin/cut \
  /usr/bin/env /usr/bin/find /usr/bin/head /usr/bin/id /usr/bin/mosh-server \
  /usr/bin/pgrep /usr/bin/pkill /usr/bin/printf /usr/bin/ps /usr/bin/python3 \
  /usr/bin/readlink /usr/bin/realpath /usr/bin/seq /usr/bin/tail \
  /usr/local/bin/tessera-fixture-probe; do
  [[ -x "$command_path" ]] || continue
  ln -sfn "$command_path" "$ROOT/notmux-bin/$(basename "$command_path")"
done

getent group tessera-fixture >/dev/null || groupadd --system tessera-fixture

ensure_user() {
  local user="$1"
  local shell="$2"
  if id "$user" >/dev/null 2>&1; then
    usermod --shell "$shell" "$user"
  else
    useradd --create-home --shell "$shell" "$user"
  fi
  usermod --append --groups tessera-fixture "$user"
  usermod --password "$PASSWORD_HASH" "$user"
  install -d -m 0700 -o "$user" -g "$user" "/home/$user/.ssh"
  printf '%s\n' "$PUBLIC_KEY" >"/home/$user/.ssh/authorized_keys"
  chown "$user:$user" "/home/$user/.ssh/authorized_keys"
  chmod 0600 "/home/$user/.ssh/authorized_keys"
}

ensure_user "$FIXTURE_USER" "$FIXTURE_SHELL"
ensure_user "$NOTMUX_USER" "$NOTMUX_SHELL"

install -d -m 2770 -o root -g tessera-fixture "$STATE" "$STATE/runs"

for user in "$FIXTURE_USER" "$NOTMUX_USER"; do
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

cat >"$ROOT/sshd_config" <<EOF
Port $APP_PORT
ListenAddress 0.0.0.0
AddressFamily inet
HostKey $ROOT/ssh/ssh_host_ed25519_key
PidFile /run/tessera-fixture-sshd.pid
AuthorizedKeysFile .ssh/authorized_keys
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
AllowUsers $FIXTURE_USER $NOTMUX_USER
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
EOF

/usr/sbin/sshd -t -f "$ROOT/sshd_config"

cat >/etc/systemd/system/tessera-fixture-sshd.service <<EOF
[Unit]
Description=Tessera disposable integration-test SSH endpoint
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sshd -D -e -f $ROOT/sshd_config
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

cat >"$ROOT/role.env" <<EOF
role=$ROLE
fixture_user=$FIXTURE_USER
notmux_user=$NOTMUX_USER
app_port=$APP_PORT
EOF

systemctl daemon-reload
systemctl enable --now tessera-fixture-sshd.service >/dev/null
systemctl restart tessera-fixture-sshd.service

cat >/etc/systemd/system/tessera-fixture-echo.service <<EOF
[Unit]
Description=Tessera disposable integration-test HTTP echo endpoint
After=network.target

[Service]
Type=simple
User=$FIXTURE_USER
ExecStart=/usr/local/bin/tessera-fixture-probe echo-server --host 127.0.0.1 --port 18080
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tessera-fixture-echo.service >/dev/null
systemctl restart tessera-fixture-echo.service

/usr/local/sbin/tessera-fixture-admin restore-udp
/usr/local/sbin/tessera-fixture-admin restore-app-ssh

printf 'role=%s\n' "$ROLE"
printf 'app_port=%s\n' "$APP_PORT"
if [[ "$ROLE" == chaos ]]; then
  printf 'tmux=%s\n' "$("$ROOT/tmux-3.6a/bin/tmux" -V)"
else
  printf 'tmux=%s\n' "$(/usr/bin/tmux -V)"
fi
printf 'mosh=%s\n' "$(mosh-server --help 2>&1 | sed -n '1p')"
printf 'host_key='; ssh-keygen -lf "$ROOT/ssh/ssh_host_ed25519_key.pub"
