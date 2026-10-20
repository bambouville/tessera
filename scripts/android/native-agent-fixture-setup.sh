#!/bin/sh
# Invoked only by run-native-ssh-gate.sh on its disposable fixture account.
set -eu

fixture_root=$1
transcript=$2
tmux_session=$3

case "$fixture_root:$transcript:$tmux_session" in
  /*:/*:tessera-native-agent-[0-9TZ-]*) ;;
  *) exit 64 ;;
esac

mkdir -p "$fixture_root/bin" "${transcript%/*}"
cat >"$fixture_root/bin/claude" <<'EOF'
#!/bin/sh
printf '%s\n' TESSERA_AGENT_DUMMY_STARTED
sleep 60
EOF
chmod 700 "$fixture_root/bin/claude"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"native projection"}}' >"$transcript"
chmod 600 "$transcript"

# The Android test must attach to the default tmux server.  Refuse to borrow a
# pre-existing server: it could select a real provider through its inherited
# PATH, and cleanup could no longer be limited to this fixture's session.
if tmux list-sessions >/dev/null 2>&1; then
  echo "refusing to use a pre-existing tmux server" >&2
  exit 65
fi

# This command starts the account's tmux server, so its environment becomes
# the server's for every later test session: `su -s /bin/sh` would make
# /bin/sh their default-shell, and a PATH prefix would put the dummy provider
# in all of them. Start it with the account's login shell and keep the dummy
# PATH to this session (its first pane gets it through env; `-e` covers the
# windows a launch adds).
login_shell=$(getent passwd "$(id -u)" | cut -d: -f7)
[ -x "$login_shell" ] || login_shell=/bin/sh
agent_path="$fixture_root/bin:$PATH"
SHELL=$login_shell tmux new-session -d -s "$tmux_session" -c "$fixture_root" -e "PATH=$agent_path" \
  /usr/bin/env "PATH=$agent_path" /bin/sh
# Preserve a failed launch pane long enough for the native gate to capture the
# semantic helper's bounded error. Scoped to this session's windows: a global
# remain-on-exit would keep every later test's exited panes open as dead panes.
tmux set-option -w -t "=$tmux_session:" remain-on-exit on
tmux set-hook -t "=$tmux_session:" after-new-window 'set-option -w remain-on-exit on'
