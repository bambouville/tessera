#!/bin/sh
# Snapshot/restore only the disposable fixture account's shell files before the
# production Agent installer changes them. Invoked by run-native-ssh-gate.sh.
set -eu

mode=$1
state_dir=$2

case "$mode:$state_dir" in
  snapshot:/*/.tessera-native-agent-*/rc-state|restore:/*/.tessera-native-agent-*/rc-state) ;;
  *) exit 64 ;;
esac

for rc in .bashrc .bash_profile .bash_login .profile .zshrc; do
  saved="$state_dir/$rc"
  absent="$state_dir/$rc.absent"
  case "$mode" in
    snapshot)
      mkdir -p "$state_dir"
      if [ -e "$HOME/$rc" ]; then
        cp -p "$HOME/$rc" "$saved"
      else
        : > "$absent"
      fi
      ;;
    restore)
      if [ -e "$absent" ]; then
        rm -f "$HOME/$rc"
      elif [ -f "$saved" ]; then
        cp -p "$saved" "$HOME/$rc"
      else
        echo "missing rc-state entry for $rc" >&2
        exit 65
      fi
      ;;
  esac
done
