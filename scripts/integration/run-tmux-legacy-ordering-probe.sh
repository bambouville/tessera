#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
load_fixture_config
fixture_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s <<'REMOTE'
set -euo pipefail
work=$(mktemp -d /tmp/tessera-legacy-order.XXXXXX)
sock="tessera-legacy-$$"
cleanup() { "$work/tmux-3.1c/tmux" -L "$sock" kill-server >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
curl --fail --location --silent --show-error https://github.com/tmux/tmux/releases/download/3.1c/tmux-3.1c.tar.gz -o "$work/tmux.tar.gz"
tar -xzf "$work/tmux.tar.gz" -C "$work"
cd "$work/tmux-3.1c"
./configure > "$work/configure.log" 2>&1 || { tail -20 "$work/configure.log"; exit 1; }
make -j2 > "$work/make.log" 2>&1 || { tail -20 "$work/make.log"; exit 1; }
python3 - "$work/tmux-3.1c/tmux" "$sock" <<'PY'
import subprocess,sys,json
base=[sys.argv[1],'-L',sys.argv[2],'-f','/dev/null']
def t(*args):return subprocess.check_output(base+list(args),text=True).strip()
def order():return t('list-windows','-t','fixture','-F','#{window_id}').splitlines()
t('new-session','-d','-s','fixture')
for _ in range(3):t('new-window','-d','-t','fixture')
ids=order(); count=0
for active in ids:
 for source in ids:
  for destination in range(4):
   original=order();start=original.index(source)
   t('select-window','-t','fixture:'+active)
   expected=[i for i in original if i!=source];expected.insert(destination,source)
   if start!=destination:
    step=1 if start<destination else -1
    for idx in range(start+step,destination+step,step):t('swap-window','-d','-s','fixture:'+source,'-t','fixture:'+original[idx])
    t('select-window','-t','fixture:'+active)
   assert order()==expected,(original,source,destination,order(),expected)
   assert t('display-message','-p','-t','fixture','#{window_id}')==active
   count+=1
print(json.dumps({'version':t('-V'),'permutationsAndSelections':count,'passed':True}))
PY
REMOTE
