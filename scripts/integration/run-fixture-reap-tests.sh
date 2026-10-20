#!/usr/bin/env bash
# Conditions are single-quoted for check()'s eval; the EXIT trap reads
# script_completed.
# shellcheck disable=SC2016,SC2034
# Host-free tests for the run-owned fixture cleanup in lib.sh
# (reap_run_mosh_servers, kill_run_tmux_sessions, end_run_processes). The
# remote halves are executed here, under macOS /bin/bash 3.2, against a fake
# /proc and stand-in `id`, `kill`, `sleep`, `runuser` and `tmux` functions
# that model what the fixture kernel and tmux do with each signal and command:
#
#   - a stopped server keeps TERM pending until CONT, so CONT must come first;
#   - a server that ignores TERM is escalated to KILL;
#   - every signal re-proves PID and start tick: a PID that names another
#     process by then gets nothing more, and the log says so;
#   - only a word of the command line equal to a run name, or beginning with
#     "<name>-", proves ownership: a longer name, a neighbouring run token,
#     another user's server, a non-mosh process and a zombie are never
#     signalled, and short, digit-free or dash-ended names are refused;
#   - a helper process is the run's only below a process naming it, never
#     through a tmux server, and tmux or mosh-server processes are never its
#     targets, even a tmux server whose command line names the run;
#   - the remote halves refuse to run as the fixture user itself;
#   - a survivor, a mosh-server comm whose executable is not mosh-server, or
#     a tmux listing that fails for any reason but "no server" fails the
#     cleanup instead of passing it.
#
#   /bin/bash scripts/integration/run-fixture-reap-tests.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/tessera-fixture-reap.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap 'fail_closed_trap cleanup' EXIT

failures=0
checks=0
fail() {
  printf 'FAIL %s\n' "$*" >&2
  failures=$((failures + 1))
}
check() {
  checks=$((checks + 1))
  if ! eval "$2"; then fail "$1"; fi
}

me="$(id -un)"
my_uid="$(id -u)"
foreign_uid=$((my_uid + 1))
run=tessera-scroll-20261006T120000Z-123
other_run=tessera-scroll-20261006T120000Z-1234
trigger=/tmp/tessera_scroll_20261006T120000Z_mosh.trigger

# The fake kernel. Each process directory carries stat/comm/status/cmdline/
# exe like Linux's, plus `ppid`, `behaviour` (normal, two-term, ignore-term,
# unkillable, recycled: CONT finds the PID already reused by an unrelated
# process) and a `pending-term` flag for a TERM sent while stopped.
# shellcheck disable=SC2016
fake_kernel='
fake_stat() {
  local dir="$1"
  printf "%s (%s) %s %s %s %s 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 %s 1000 10\n" \
    "${dir##*/}" "$(cat "$dir/comm")" "$(cat "$dir/state")" "$(cat "$dir/ppid")" "${dir##*/}" "${dir##*/}" \
    "$(cat "$dir/start")" >"$dir/stat"
}
fake_term() {
  local dir="$1"
  case "$(cat "$dir/behaviour")" in
    normal) rm -rf "$dir" ;;
    two-term) if [[ -f "$dir/shutting" ]]; then rm -rf "$dir"; else : >"$dir/shutting"; fi ;;
  esac
}
kill() {
  local signal="${1#-}" dir="$TESSERA_REAP_PROC_ROOT/$2"
  printf "%s %s\n" "$2" "$signal" >>"$FAKE_SIGNAL_LOG"
  [[ -d "$dir" && "$(cat "$dir/state")" != Z ]] || return 1
  case "$signal" in
    CONT)
      if [[ "$(cat "$dir/behaviour")" == recycled ]]; then
        printf "%s" "$(($(cat "$dir/start") + 1))" >"$dir/start"
        printf "bash\n" >"$dir/comm"
        printf "bash\0" >"$dir/cmdline"
        printf S >"$dir/state"
        printf normal >"$dir/behaviour"
        fake_stat "$dir"
        return 0
      fi
      if [[ "$(cat "$dir/state")" == T ]]; then printf S >"$dir/state"; fake_stat "$dir"; fi
      if [[ -f "$dir/pending-term" ]]; then rm -f "$dir/pending-term"; fake_term "$dir"; fi ;;
    TERM)
      if [[ "$(cat "$dir/state")" == T ]]; then : >"$dir/pending-term"; else fake_term "$dir"; fi ;;
    KILL)
      [[ "$(cat "$dir/behaviour")" == unkillable ]] || rm -rf "$dir" ;;
  esac
  return 0
}
sleep() { :; }
# The control user is root unless a test says otherwise.
id() {
  if [[ $# -eq 1 && "$1" == -u ]]; then printf "%s\n" "${FAKE_CALLER_UID:-0}"; return 0; fi
  command id "$@"
}
'

# make_process ROOT PID COMM UID STATE BEHAVIOUR EXE ARGV...
make_process() {
  local root="$1" pid="$2" comm="$3" uid="$4" state="$5" behaviour="$6" exe="$7"
  shift 7
  local dir="$root/$pid"
  mkdir -p "$dir"
  printf '%s\n' "$comm" >"$dir/comm"
  printf '%s' "$state" >"$dir/state"
  printf '%s' "$((pid * 100 + 7))" >"$dir/start"
  printf '%s' "$behaviour" >"$dir/behaviour"
  printf '%s' "${make_ppid:-1}" >"$dir/ppid"
  printf 'Name:\t%s\nState:\t%s\nUid:\t%s\t%s\t%s\t%s\n' "$comm" "$state" "$uid" "$uid" "$uid" "$uid" >"$dir/status"
  printf '%s\0' "$@" >"$dir/cmdline"
  ln -s "$exe" "$dir/exe"
  /bin/bash -c "TESSERA_REAP_PROC_ROOT='$root'; $fake_kernel"' fake_stat "$1"' _ "$dir"
}

# The app's own bootstrap argv for a mosh+tmux view of SESSION.
tmux_argv() {
  printf '%s\n' mosh-server new -c 256 -- sh -lc \
    "if tmux -u has-session -t '$1-view' 2>/dev/null; then set -- attach-session -t '$1-view'; else tmux -u has-session -t '$1' 2>/dev/null || tmux -u new-session -d -s '$1'; set -- new-session -s '$1-view' -t '$1'; fi; exec tmux -u \"\$@\""
}

# run_remote SCRIPT_FUNCTION ROOT LOG ARGS...: one remote invocation.
run_remote() {
  local script="$1" root="$2" log="$3"
  shift 3
  { printf 'export TESSERA_REAP_PROC_ROOT=%q FAKE_SIGNAL_LOG=%q\n' "$root" "$log"
    printf '%s\n' "$fake_kernel"
    "$script"
  } | /bin/bash -s -- "$@"
}

signals_of() { grep -E "^$2 " "$1" | cut -d' ' -f2 | tr '\n' ' ' || true; }

# ---- Scenario A: a mixed account; only this run's servers go -------------
root="$work/proc-a"
log="$work/signals-a.log"
: >"$log"
argv=()
while IFS= read -r word; do argv+=("$word"); done < <(tmux_argv "$run")
make_process "$root" 101 mosh-server "$my_uid" T normal /usr/bin/mosh-server "${argv[@]}"
argv=()
while IFS= read -r word; do argv+=("$word"); done < <(tmux_argv "$other_run")
make_process "$root" 102 mosh-server "$my_uid" T normal /usr/bin/mosh-server "${argv[@]}"
make_process "$root" 103 mosh-server "$foreign_uid" S normal /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run'"
make_process "$root" 104 sleep "$my_uid" S normal /usr/bin/sleep sleep 900 "'$run'"
make_process "$root" 105 mosh-server "$my_uid" S normal /usr/bin/mosh-server mosh-server new -c 256 -- sh -lc \
  "/usr/local/bin/tessera-fixture-probe scroll-scenario --label MOSH --trigger $trigger --count 600"
make_process "$root" 106 mosh-server "$my_uid" S ignore-term /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run-mosh-view'"
make_process "$root" 107 mosh-server "$my_uid" Z normal /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run'"
make_process "$root" 108 mosh-server "$my_uid" S normal "/usr/bin/mosh-server (deleted)" mosh-server new -- sh -lc "exec tmux attach -t '$run'"
make_process "$root" 111 mosh-server "$my_uid" S two-term /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run'"
# A user's own server that merely mentions the name inside a path is not it.
make_process "$root" 112 mosh-server "$my_uid" S normal /usr/bin/mosh-server mosh-server new -- sh -lc "cat /tmp/$run.log"
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$run" "$trigger")" || status=$?
check "A exits 0 ($status): $out" '[[ $status -eq 0 ]]'
check "A stopped view server is continued before TERM" '[[ "$(signals_of "$log" 101)" == "CONT TERM " ]]'
check "A stopped view server reaped" '[[ "$out" == *"RUN_MOSH_SERVER_REAPED pid=101 start=10107 state=T signal=TERM"* && ! -e "$root/101" ]]'
check "A custom-command server named by its trigger reaped" '[[ "$out" == *"RUN_MOSH_SERVER_REAPED pid=105 "*"signal=TERM"* && ! -e "$root/105" ]]'
check "A TERM-ignoring server escalated to KILL" '[[ "$(signals_of "$log" 106)" == "CONT TERM TERM KILL " && "$out" == *"pid=106 "*"signal=KILL"* ]]'
check "A deleted-executable server reaped" '[[ "$out" == *"RUN_MOSH_SERVER_REAPED pid=108 "* && ! -e "$root/108" ]]'
check "A handshake server ends on its second TERM" '[[ "$(signals_of "$log" 111)" == "CONT TERM TERM " && "$out" == *"pid=111 "*"signal=TERM"* ]]'
check "A longer run name untouched" '[[ -z "$(signals_of "$log" 102)" && -e "$root/102" ]]'
check "A foreign user untouched" '[[ -z "$(signals_of "$log" 103)" && -e "$root/103" ]]'
check "A non-mosh process untouched" '[[ -z "$(signals_of "$log" 104)" && -e "$root/104" ]]'
check "A zombie never signalled" '[[ -z "$(signals_of "$log" 107)" ]]'
check "A path that only contains the name untouched" '[[ -z "$(signals_of "$log" 112)" && -e "$root/112" ]]'
check "A reports absence" '[[ "$out" == *"RUN_MOSH_SERVERS_ABSENT reaped=5 "* ]]'
check "A one line per server" '[[ "$(grep -c "^RUN_MOSH_SERVER_REAPED" <<<"$out")" == 5 ]]'

# ---- Scenario B: a survivor fails the cleanup -------------------------------
root="$work/proc-b"
log="$work/signals-b.log"
: >"$log"
make_process "$root" 109 mosh-server "$my_uid" T unkillable /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run'"
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$run")" || status=$?
check "B exits non-zero" '[[ $status -ne 0 ]]'
check "B escalates fully" '[[ "$(signals_of "$log" 109)" == "CONT TERM TERM KILL " ]]'
check "B reports the survivor and the failed assertion" '[[ "$out" == *"RUN_MOSH_SERVER_SURVIVED pid=109"* && "$out" == *"RUN_MOSH_SERVER_REMAINS pid=109"* && "$out" != *RUN_MOSH_SERVERS_ABSENT* ]]'

# ---- Scenario C: an unproven executable is refused, not signalled ------------
root="$work/proc-c"
log="$work/signals-c.log"
: >"$log"
make_process "$root" 110 mosh-server "$my_uid" S normal /usr/bin/python3 mosh-server new -- sh -lc "exec tmux attach -t '$run'"
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$run")" || status=$?
check "C exits non-zero" '[[ $status -ne 0 ]]'
check "C never signals" '[[ ! -s "$log" ]]'
check "C reports refusal" '[[ "$out" == *"RUN_MOSH_SERVER_REFUSED pid=110"*"reason=executable"* && "$out" == *"RUN_MOSH_SERVER_REMAINS pid=110"* ]]'

# ---- Scenario D: nothing to do is a pass; a generic name is refused ----------
root="$work/proc-d"
mkdir -p "$root"
log="$work/signals-d.log"
: >"$log"
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$run")" || status=$?
check "D empty account passes ($status)" '[[ $status -eq 0 && "$out" == *"RUN_MOSH_SERVERS_ABSENT reaped=0"* ]]'
# Too short (even with a digit), digit-free, dash-ended (an empty token
# part) and over-long names each fail one rule; 200 characters is the limit.
long_name="tessera-$(printf '%0193d' 1)"
limit_name="tessera-$(printf '%0192d' 1)"
refused_names=(tessera tessera-1 tessera-scroll- tessera-scroll-abcdefghijk tessera-ios-2026-1- "$long_name")
for name in "${refused_names[@]}"; do
  status=0
  run_remote mosh_server_reap_script "$root" "$log" "$me" "$name" >/dev/null 2>&1 || status=$?
  check "D mosh remote refuses ${name:0:24}" '[[ $status -eq 2 ]]'
  status=0
  run_remote tmux_session_reap_script "$root" "$log" "$me" "$name" >/dev/null 2>&1 || status=$?
  check "D tmux remote refuses ${name:0:24}" '[[ $status -eq 2 ]]'
  status=0
  run_remote run_process_reap_script "$root" "$log" "$me" htop "$name" >/dev/null 2>&1 || status=$?
  check "D process remote refuses ${name:0:24}" '[[ $status -eq 2 ]]'
done
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$limit_name")" || status=$?
check "D a 200-character name is accepted ($status)" '[[ $status -eq 0 && "$out" == *RUN_MOSH_SERVERS_ABSENT* ]]'
check "D refusals never signal" '[[ ! -s "$log" ]]'

# ---- Scenario R: a PID reused before TERM gets no TERM, and the log says so --
root="$work/proc-r"
log="$work/signals-r.log"
: >"$log"
make_process "$root" 401 mosh-server "$my_uid" T recycled /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run'"
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$run")" || status=$?
check "R exits 0 ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_MOSH_SERVERS_ABSENT reaped=0 "* ]]'
check "R the reused PID is never sent TERM or KILL" '[[ "$(signals_of "$log" 401)" == "CONT " ]]'
check "R reports what it sent, not a reap" '[[ "$out" == *"RUN_MOSH_SERVER_GONE pid=401 start=40107 state=T sent=CONT"* && "$out" != *RUN_MOSH_SERVER_REAPED* ]]'

# ---- Scenario G: neighbouring run tokens never match ---------------------------
# Every lane's token is TIMESTAMP-PID-RANDOM (fixture_run_token): a token
# whose RANDOM or PID extends this one's, a shorter one, and the two-part
# shape lanes used to mint from the same second and PID are all other runs.
token="$(fixture_run_token)"
check "G fixture_run_token is three-part ($token)" '[[ "$token" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]]'
root="$work/proc-g"
log="$work/signals-g.log"
: >"$log"
mine=tessera-cwd-20261006T120000Z-777-123
neighbours=(tessera-cwd-20261006T120000Z-777-1234 tessera-cwd-20261006T120000Z-777-12
  tessera-cwd-20261006T120000Z-7777-123 tessera-cwd-20261006T120000Z-777)
pid=450
for session in "$mine" "${neighbours[@]}"; do
  argv=()
  while IFS= read -r word; do argv+=("$word"); done < <(tmux_argv "$session")
  make_process "$root" "$pid" mosh-server "$my_uid" S normal /usr/bin/mosh-server "${argv[@]}"
  pid=$((pid + 1))
done
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$mine")" || status=$?
check "G only this run's server is reaped ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_MOSH_SERVERS_ABSENT reaped=1 "* && ! -e "$root/450" ]]'
check "G neighbouring tokens untouched" '[[ "$(cut -d" " -f1 "$log" | sort -u | tr "\n" " ")" == "450 " && -e "$root/451" && -e "$root/452" && -e "$root/453" && -e "$root/454" ]]'
# Every lane mints its token with fixture_run_token, never the old two-part
# TIMESTAMP-PID that was a dash-prefix of the three-part tokens.
for lane in run-android-live-scroll-tests.sh run-android-files-follow-tests.sh run-app-transport-tests.sh \
  run-integration-tests.sh ../android/run-native-ssh-gate.sh ../android/run-mosh-authority-rig.sh \
  ../android/run-new-window-rig.sh; do
  check "G $lane mints its run token with fixture_run_token" \
    'grep -q "\$(fixture_run_token)" "$HERE/$lane" && ! grep -Eq "^[a-z_]*(token|run_id)=\"[^\"]*%SZ\)-\\\$\\\$\"" "$HERE/$lane"'
done

# ---- Scenario F: the run prefixes lanes pass reach their tests' servers ------
# run-app-transport-tests.sh passes a run prefix its mosh tests put first;
# the S1/S6 case's sessions are not `tessera-` names, so their views are
# `<name>-tessera-view`.
root="$work/proc-f"
log="$work/signals-f.log"
: >"$log"
ios_prefix=tessera-ios-20261006T120000Z-123-456
scroll_session=tessera_scroll_20261006T120000Z-123_mosh_tmux
argv=()
while IFS= read -r word; do argv+=("$word"); done < <(tmux_argv "$ios_prefix-continuation-ab12cd34")
make_process "$root" 301 mosh-server "$my_uid" T normal /usr/bin/mosh-server "${argv[@]}"
argv=()
while IFS= read -r word; do argv+=("$word"); done < <(tmux_argv "${ios_prefix}7-continuation-ab12cd34")
make_process "$root" 302 mosh-server "$my_uid" T normal /usr/bin/mosh-server "${argv[@]}"
make_process "$root" 303 mosh-server "$my_uid" S normal /usr/bin/mosh-server mosh-server new -c 256 -- sh -lc \
  "exec tmux -u new-session -s '$scroll_session-tessera-view' -t '$scroll_session'"
status=0
out="$(run_remote mosh_server_reap_script "$root" "$log" "$me" "$ios_prefix" "$scroll_session")" || status=$?
check "F exits 0 ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_MOSH_SERVERS_ABSENT reaped=2 "* ]]'
check "F run-prefixed stopped view server continued and reaped" '[[ "$(signals_of "$log" 301)" == "CONT TERM " && ! -e "$root/301" ]]'
check "F non-tessera session view server reaped" '[[ "$out" == *"RUN_MOSH_SERVER_REAPED pid=303 "* && ! -e "$root/303" ]]'
check "F another run whose prefix extends this one untouched" '[[ -z "$(signals_of "$log" 302)" && -e "$root/302" ]]'

# ---- Scenario P: helper processes below the run's scenario, and only those ----
# end_run_processes ends htop under the S1/S6 scenario that names the
# trigger; the walk up never passes a tmux server, whose command line can
# repeat the new-session (and the run's names) that started it.
root="$work/proc-p"
log="$work/signals-p.log"
: >"$log"
other_trigger=/tmp/tessera_scroll_20261006T120000Z_mosh_tmux.trigger
make_process "$root" 501 python3 "$my_uid" S normal /usr/bin/python3 python3 /usr/local/bin/tessera-fixture-probe \
  scroll-scenario --label MOSH --trigger "$trigger" --count 600
make_ppid=501 make_process "$root" 502 timeout "$my_uid" S normal /usr/bin/timeout timeout --foreground 180 htop -d 100
make_ppid=502 make_process "$root" 503 htop "$my_uid" S normal /usr/bin/htop htop -d 100
make_ppid=502 make_process "$root" 512 htop "$my_uid" S ignore-term /usr/bin/htop htop -d 100
make_ppid=502 make_process "$root" 513 htop "$my_uid" Z normal /usr/bin/htop htop -d 100
make_ppid=502 make_process "$root" 514 htop "$my_uid" S recycled /usr/bin/htop htop -d 100
make_ppid=501 make_process "$root" 508 htop "$foreign_uid" S normal /usr/bin/htop htop -d 100
make_process "$root" 510 python3 "$my_uid" S normal /usr/bin/python3 python3 /usr/local/bin/tessera-fixture-probe \
  scroll-scenario --label MOSH_TMUX --trigger "$other_trigger" --count 600
make_ppid=510 make_process "$root" 504 htop "$my_uid" S normal /usr/bin/htop htop -d 100
make_process "$root" 505 "tmux: server" "$my_uid" S normal /usr/bin/tmux tmux new-session -d -s "$run" \
  /usr/local/bin/tessera-fixture-probe scroll-scenario --trigger "$trigger"
make_ppid=505 make_process "$root" 506 bash "$my_uid" S normal /usr/bin/bash -bash
make_ppid=506 make_process "$root" 507 htop "$my_uid" S normal /usr/bin/htop htop
make_process "$root" 509 mosh-server "$my_uid" S normal /usr/bin/mosh-server mosh-server new -c 256 -- sh -lc \
  "/usr/local/bin/tessera-fixture-probe scroll-scenario --label MOSH --trigger $trigger"
make_process "$root" 511 "tmux: client" "$my_uid" S normal /usr/bin/tmux tmux attach -t "$run"
# Only the user's own processes anchor: root's `su ... --trigger` naming the
# run proves nothing about the user's processes below it.
make_process "$root" 520 su "$foreign_uid" S normal /usr/bin/su su -s /bin/sh "$me" -c \
  "/usr/local/bin/tessera-fixture-probe scroll-scenario --trigger $trigger"
make_ppid=520 make_process "$root" 521 htop "$my_uid" S normal /usr/bin/htop htop
status=0
out="$(run_remote run_process_reap_script "$root" "$log" "$me" htop "$trigger")" || status=$?
check "P exits 0 ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_PROCESSES_ABSENT comm=htop ended=2 "* ]]'
check "P htop under the run's scenario ended by TERM" '[[ "$(signals_of "$log" 503)" == "CONT TERM " && "$out" == *"RUN_PROCESS_ENDED pid=503 "*"signal=TERM"* ]]'
check "P TERM-ignoring htop escalated to KILL" '[[ "$(signals_of "$log" 512)" == "CONT TERM KILL " && "$out" == *"pid=512 "*"signal=KILL"* ]]'
check "P reused PID gets no TERM and is reported as gone" '[[ "$(signals_of "$log" 514)" == "CONT " && "$out" == *"RUN_PROCESS_GONE pid=514 "*"sent=CONT"* ]]'
check "P zombie never signalled" '[[ -z "$(signals_of "$log" 513)" ]]'
check "P another user's htop untouched" '[[ -z "$(signals_of "$log" 508)" ]]'
check "P htop below another user's process naming the run untouched" '[[ -z "$(signals_of "$log" 521)" && -e "$root/521" ]]'
check "P another run's htop untouched" '[[ -z "$(signals_of "$log" 504)" && -e "$root/504" ]]'
check "P a pane under a tmux server naming the run untouched" '[[ -z "$(signals_of "$log" 507)" && -e "$root/507" ]]'
check "P the scenario, timeout, tmux and mosh-server untouched" '[[ -z "$(signals_of "$log" 501)$(signals_of "$log" 502)$(signals_of "$log" 505)$(signals_of "$log" 509)$(signals_of "$log" 511)" ]]'

# ---- Scenario Q: any command the run named, for the authority rig ------------
# Its FIFO keeper is started as `exec -a <session>-fifo-keeper sleep 3600`
# and its `script` client names the session; S13's split panes run a bare
# `sleep 3600` and must survive, as must tmux and mosh-server processes.
root="$work/proc-q"
log="$work/signals-q.log"
: >"$log"
rig=tessera-authrig-20261006T120000Z-777-123
make_process "$root" 601 sleep "$my_uid" S normal /usr/bin/sleep "$rig-fifo-keeper" 3600
make_process "$root" 602 script "$my_uid" S normal /usr/bin/script script -qfc \
  "stty cols 160 rows 48; exec tmux attach -t $rig" /dev/null
make_ppid=602 make_process "$root" 603 sh "$my_uid" S normal /bin/sh sh -c "stty cols 160 rows 48; exec tmux attach -t $rig"
make_process "$root" 604 "tmux: server" "$my_uid" S normal /usr/bin/tmux tmux -vv new-session -d -s "$rig" -x 100 -y 30
make_ppid=604 make_process "$root" 605 sleep "$my_uid" S normal /usr/bin/sleep sleep 3600
make_process "$root" 606 sleep "$my_uid" S normal /usr/bin/sleep "${rig}4-fifo-keeper" 3600
make_process "$root" 607 sleep "$my_uid" S normal /usr/bin/sleep sleep 3600
make_ppid=602 make_process "$root" 608 "tmux: client" "$my_uid" S normal /usr/bin/tmux tmux attach -t "$rig"
make_process "$root" 609 mosh-server "$my_uid" S normal /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$rig-view'"
status=0
out="$(run_remote run_process_reap_script "$root" "$log" "$me" @any "$rig")" || status=$?
check "Q exits 0 ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_PROCESSES_ABSENT comm=@any ended=3 "* ]]'
check "Q keeper, script and its shell ended" '[[ ! -e "$root/601" && ! -e "$root/602" && ! -e "$root/603" ]]'
check "Q bare sleeps, other runs, tmux and mosh-server untouched" '[[ -z "$(signals_of "$log" 604)$(signals_of "$log" 605)$(signals_of "$log" 606)$(signals_of "$log" 607)$(signals_of "$log" 608)$(signals_of "$log" 609)" ]]'
for bad_comm in mosh-server tmux "tmux: server" "bad comm" "*" ""; do
  status=0
  run_remote run_process_reap_script "$root" "$log" "$me" "$bad_comm" "$rig" >/dev/null 2>&1 || status=$?
  check "Q remote refuses command name '$bad_comm'" '[[ $status -eq 2 ]]'
done

# ---- Scenario U: a process that will not end fails the cleanup ---------------
root="$work/proc-u"
log="$work/signals-u.log"
: >"$log"
make_process "$root" 701 sleep "$my_uid" S unkillable /usr/bin/sleep "$rig-fifo-keeper" 3600
status=0
out="$(run_remote run_process_reap_script "$root" "$log" "$me" @any "$rig")" || status=$?
check "U exits non-zero" '[[ $status -ne 0 ]]'
check "U escalates and reports the survivor" '[[ "$(signals_of "$log" 701)" == "CONT TERM KILL " && "$out" == *"RUN_PROCESS_SURVIVED pid=701"* && "$out" == *"RUN_PROCESS_REMAINS pid=701"* && "$out" != *RUN_PROCESSES_ABSENT* ]]'
root="$work/proc-u2"
mkdir -p "$root"
status=0
out="$(run_remote run_process_reap_script "$root" "$log" "$me" htop "$trigger")" || status=$?
check "U nothing to end is a pass ($status)" '[[ $status -eq 0 && "$out" == *"RUN_PROCESSES_ABSENT comm=htop ended=0"* ]]'

# ---- Scenario T: the user's tmux server can name the trigger; it survives ----
# When a tmux transport's `tmux new-session ... '<scenario --trigger T>'`
# starts the user's server, the server's command line keeps that scenario,
# and every concurrent lane's sessions live in it. The S1/S6 and C4 cleanups
# end their scenario's processes by T and by T.vim.txt, the one name the
# probe's Vim stage (exec'd `timeout ... vim ... T.vim.txt`) still carries;
# the server and another lane's pane under it are never signalled.
root="$work/proc-t"
log="$work/signals-t.log"
: >"$log"
scroll_trigger=/tmp/tessera_scroll_20261006T120000Z-123-456_ssh_tmux.trigger
neighbour_trigger=/tmp/tessera_scroll_20261006T120000Z-123-4567_ssh_tmux.trigger
make_process "$root" 801 "tmux: server" "$my_uid" S normal /usr/bin/tmux tmux new-session -d \
  -s tessera_scroll_20261006T120000Z-123-456_ssh_tmux -x 160 -y 50 \
  "/usr/local/bin/tessera-fixture-probe scroll-scenario --label SSH_TMUX --trigger $scroll_trigger --count 600"
make_ppid=801 make_process "$root" 802 python3 "$my_uid" S normal /usr/bin/python3 python3 \
  /usr/local/bin/tessera-fixture-probe scroll-scenario --label SSH_TMUX --trigger "$scroll_trigger" --count 600
make_ppid=802 make_process "$root" 804 timeout "$my_uid" S normal /usr/bin/timeout timeout --foreground 180 htop -d 100
make_ppid=804 make_process "$root" 803 htop "$my_uid" S normal /usr/bin/htop htop -d 100
make_ppid=801 make_process "$root" 805 timeout "$my_uid" S normal /usr/bin/timeout timeout 300 vim -Nu NONE -n +300 \
  -c "set mouse=a" -c "silent call writefile(['ready'], '$scroll_trigger.vim')" "$scroll_trigger.vim.txt"
make_ppid=805 make_process "$root" 806 vim "$my_uid" S normal /usr/bin/vim vim -Nu NONE -n +300 \
  -c "set mouse=a" -c "silent call writefile(['ready'], '$scroll_trigger.vim')" "$scroll_trigger.vim.txt"
make_ppid=801 make_process "$root" 807 bash "$my_uid" S normal /usr/bin/bash -bash
make_ppid=807 make_process "$root" 808 sleep "$my_uid" S normal /usr/bin/sleep sleep 3600
make_ppid=801 make_process "$root" 810 timeout "$my_uid" S normal /usr/bin/timeout timeout 300 vim -Nu NONE \
  "$neighbour_trigger.vim.txt"
# A tmux built with libbsd's setproctitle keeps the comm `tmux`.
make_process "$root" 809 tmux "$my_uid" S normal /usr/bin/tmux tmux new-session -d -s other \
  "/usr/local/bin/tessera-fixture-probe scroll-scenario --trigger $scroll_trigger"
status=0
out="$(run_remote run_process_reap_script "$root" "$log" "$me" @any "$scroll_trigger" "$scroll_trigger.vim.txt")" || status=$?
check "T exits 0 ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_PROCESSES_ABSENT comm=@any ended=5 "* ]]'
check "T the tmux server naming the trigger is never signalled" '[[ -z "$(signals_of "$log" 801)$(signals_of "$log" 809)" && -e "$root/801" && -e "$root/809" ]]'
check "T the scenario and its htop ended" '[[ ! -e "$root/802" && ! -e "$root/803" && ! -e "$root/804" ]]'
check "T the exec'd Vim stage ended by its file's name" '[[ ! -e "$root/805" && ! -e "$root/806" ]]'
check "T another lane's pane under the same server untouched" '[[ -z "$(signals_of "$log" 807)$(signals_of "$log" 808)" && -e "$root/808" ]]'
check "T a neighbouring token's Vim stage untouched" '[[ -z "$(signals_of "$log" 810)" && -e "$root/810" ]]'

# ---- Scenario Y: never as the fixture user itself ------------------------------
# Run as the fixture user, the script's own shell and the SSH session's
# shell running it would name the run and be among its targets.
root="$work/proc-y"
log="$work/signals-y.log"
: >"$log"
make_process "$root" 901 mosh-server "$my_uid" S normal /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run'"
make_process "$root" 902 sleep "$my_uid" S normal /usr/bin/sleep "$run-fifo-keeper" 3600
for script in mosh_server_reap_script tmux_session_reap_script run_process_reap_script; do
  args=("$me")
  [[ "$script" != run_process_reap_script ]] || args+=(@any)
  status=0
  FAKE_CALLER_UID="$my_uid" run_remote "$script" "$root" "$log" "${args[@]}" "$run" >/dev/null 2>&1 || status=$?
  check "Y $script refuses the fixture user as its caller ($status)" '[[ $status -eq 2 ]]'
done
check "Y a refused caller signals nothing" '[[ ! -s "$log" && -e "$root/901" && -e "$root/902" ]]'

# ---- No lane or test signals by pattern across the account --------------------
# `pgrep -f`/`pkill -f` patterns, bare `sleep 3600` and `tmux attach`
# substrings, and every htop: each has hit other lanes' processes.
for file in "$HERE"/visual-cases/*.sh "$HERE"/../android/run-mosh-authority-rig.sh \
  "$HERE"/../android/run-new-window-rig.sh \
  "$HERE"/../../android/feature-session/src/androidTest/kotlin/com/bambouville/tessera/feature/session/MoshTmuxAuthorityLiveInstrumentedTest.kt \
  "$HERE"/../../android/feature-session/src/androidTest/kotlin/com/bambouville/tessera/feature/session/TmuxNewWindowLiveInstrumentedTest.kt; do
  check "no account-wide pattern signal in ${file##*/}" \
    '[[ -f "$file" ]] && ! grep -Eq "pgrep -u [^;]* -f |pkill -f |slee\[p\]|attac\[h\]|-x htop" "$file"'
done

# ---- Local wrappers: validation before any SSH, then the exact remote call ---
ssh_calls="$work/ssh-calls.log"
: >"$ssh_calls"
control_ssh() {
  local host="$1"
  shift
  printf '%s %s\n' "$host" "$*" >>"$ssh_calls"
  [[ "$1 $2 $3" == "bash -s --" ]] || return 97
  shift 3
  { printf 'export TESSERA_REAP_PROC_ROOT=%q FAKE_SIGNAL_LOG=%q\n' "$wrapper_root" "$wrapper_log"
    printf '%s\n' "$fake_kernel"
    printf '%s\n' "$wrapper_prelude"
    cat
  } | /bin/bash -s -- "$@"
}
wrapper_root="$work/proc-e"
wrapper_log="$work/signals-e.log"
wrapper_prelude=''
: >"$wrapper_log"
make_process "$wrapper_root" 201 mosh-server "$my_uid" T normal /usr/bin/mosh-server mosh-server new -- sh -lc "exec tmux attach -t '$run-view'"
for bad in "" "tessera" "tessera-1" "tessera-scroll-" "tessera-scroll-abcdefghijk" "tessera-ios-2026-1-" "$long_name" "$run bad-user"; do
  status=0
  if [[ "$bad" == "$run bad-user" ]]; then
    reap_run_mosh_servers stable 'bad user' "$run" >/dev/null 2>&1 || status=$?
  elif [[ -z "$bad" ]]; then
    reap_run_mosh_servers stable "$me" >/dev/null 2>&1 || status=$?
  else
    reap_run_mosh_servers stable "$me" "$bad" >/dev/null 2>&1 || status=$?
  fi
  check "wrapper refuses '${bad:0:24}'" '[[ $status -ne 0 ]]'
  if [[ -n "$bad" && "$bad" != "$run bad-user" ]]; then
    status=0
    kill_run_tmux_sessions stable "$me" "$bad" >/dev/null 2>&1 || status=$?
    check "tmux wrapper refuses '${bad:0:24}'" '[[ $status -ne 0 ]]'
    status=0
    end_run_processes stable "$me" htop "$bad" >/dev/null 2>&1 || status=$?
    check "process wrapper refuses '${bad:0:24}'" '[[ $status -ne 0 ]]'
  fi
done
for bad_comm in mosh-server tmux "bad comm" "*"; do
  status=0
  end_run_processes stable "$me" "$bad_comm" "$run" >/dev/null 2>&1 || status=$?
  check "process wrapper refuses command name '$bad_comm'" '[[ $status -ne 0 ]]'
done
check "wrapper refusals never reach SSH" '[[ ! -s "$ssh_calls" ]]'
status=0
out="$(reap_run_mosh_servers stable "$me" "$run")" || status=$?
check "wrapper reaps end to end ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_MOSH_SERVER_REAPED pid=201 "* && ! -e "$wrapper_root/201" ]]'
check "wrapper passes user and names to bash -s" '[[ "$(cat "$ssh_calls")" == "stable bash -s -- $me $run" ]]'

# ---- tmux: the run's sessions and their views, exactly, nothing else ---------
sessions="$work/sessions"
kills="$work/tmux-kills.log"
# shellcheck disable=SC2016
wrapper_prelude='
runuser() { [[ "$1" == -u && "$3" == -- ]] || return 2; shift 3; "$@"; }
tmux() {
  case "$1" in
    list-sessions)
      if [[ -n "${FAKE_TMUX_ERROR:-}" ]]; then printf "%s\n" "$FAKE_TMUX_ERROR" >&2; return 1; fi
      [[ -s "$FAKE_SESSIONS" ]] || { printf "no server running on /tmp/tmux-501/default\n" >&2; return 1; }
      cat "$FAKE_SESSIONS" ;;
    kill-session)
      [[ "$2" == -t && "$3" == =* ]] || return 2
      printf "%s\n" "${3#=}" >>"$FAKE_TMUX_KILLS"
      [[ "${3#=}" != "${FAKE_STICKY:-}" ]] || return 1
      grep -Fxv -- "${3#=}" "$FAKE_SESSIONS" >"$FAKE_SESSIONS.new" || true
      mv "$FAKE_SESSIONS.new" "$FAKE_SESSIONS" ;;
    *) return 2 ;;
  esac
}
'
wrapper_prelude="export FAKE_SESSIONS='$sessions' FAKE_TMUX_KILLS='$kills'; $wrapper_prelude"
printf '%s\n' "$run" "$run-view" "$run-mosh-view" "$other_run" "$other_run-view" main >"$sessions"
: >"$kills"
: >"$ssh_calls"
status=0
out="$(kill_run_tmux_sessions chaos "$me" "$run")" || status=$?
check "tmux exits 0 ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_TMUX_SESSIONS_ABSENT killed=3"* ]]'
check "tmux kills exactly the run and its derived views" '[[ "$(sort "$kills" | tr "\n" " ")" == "$run $run-mosh-view $run-view " ]]'
check "tmux leaves other runs and the user alone" '[[ "$(tr "\n" " " <"$sessions")" == "$other_run $other_run-view main " ]]'
printf '%s\n' "$run" "$run-view" main >"$sessions"
: >"$kills"
status=0
out="$(FAKE_STICKY="$run-view" kill_run_tmux_sessions chaos "$me" "$run")" || status=$?
check "tmux survivor fails the cleanup" '[[ $status -ne 0 && "$out" == *"RUN_TMUX_SESSION_REMAINS name=$run-view"* ]]'
: >"$sessions"
status=0
out="$(kill_run_tmux_sessions chaos "$me" "$run")" || status=$?
check "tmux with no server passes" '[[ $status -eq 0 && "$out" == *"RUN_TMUX_SESSIONS_ABSENT killed=0"* ]]'
status=0
out="$(FAKE_TMUX_ERROR="error connecting to /tmp/tmux-501/default (No such file or directory)" \
  kill_run_tmux_sessions chaos "$me" "$run")" || status=$?
check "tmux with no socket yet passes" '[[ $status -eq 0 && "$out" == *"RUN_TMUX_SESSIONS_ABSENT killed=0"* ]]'
status=0
out="$(FAKE_TMUX_ERROR="error connecting to /tmp/tmux-501/default (Permission denied)" \
  kill_run_tmux_sessions chaos "$me" "$run")" || status=$?
check "tmux listing failure fails the cleanup" '[[ $status -ne 0 && "$out" == *"RUN_TMUX_LIST_FAILED status=1"*"Permission denied"* && "$out" != *RUN_TMUX_SESSIONS_ABSENT* ]]'
# Neighbouring tokens' sessions stay, as their servers did in scenario G.
printf '%s\n' "$mine" "$mine-view" "${neighbours[@]}" >"$sessions"
: >"$kills"
status=0
out="$(kill_run_tmux_sessions chaos "$me" "$mine")" || status=$?
check "tmux kills only this token's sessions ($status)" '[[ $status -eq 0 && "$(sort "$kills" | tr "\n" " ")" == "$mine $mine-view " ]]'
check "tmux leaves neighbouring tokens' sessions" '[[ "$(sort "$sessions" | tr "\n" " ")" == "$(printf "%s\n" "${neighbours[@]}" | sort | tr "\n" " ")" ]]'
# The chaos fixture's login shell runs its own tmux 3.6a; the system tmux
# cannot talk to that server ("server exited unexpectedly"), so the reap must
# list and kill through the login shell's binary.
fixture_root="$work/fixture-root"
mkdir -p "$fixture_root/tmux-3.6a/bin"
fixture_tmux_log="$work/fixture-tmux.log"
cat >"$fixture_root/tmux-3.6a/bin/tmux" <<'FIXTURE_TMUX'
#!/bin/bash
printf '%s\n' "$1" >>"$FAKE_FIXTURE_TMUX_LOG"
case "$1" in
  list-sessions)
    [[ -s "$FAKE_SESSIONS" ]] || { printf "no server running on /tmp/tmux-501/default\n" >&2; exit 1; }
    cat "$FAKE_SESSIONS" ;;
  kill-session)
    [[ "$2" == -t && "$3" == =* ]] || exit 2
    printf "%s\n" "${3#=}" >>"$FAKE_TMUX_KILLS"
    grep -Fxv -- "${3#=}" "$FAKE_SESSIONS" >"$FAKE_SESSIONS.new" || true
    mv "$FAKE_SESSIONS.new" "$FAKE_SESSIONS" ;;
  *) exit 2 ;;
esac
FIXTURE_TMUX
chmod +x "$fixture_root/tmux-3.6a/bin/tmux"
system_wrapper_prelude="$wrapper_prelude"
wrapper_prelude="export TESSERA_REAP_FIXTURE_ROOT='$fixture_root' FAKE_FIXTURE_TMUX_LOG='$fixture_tmux_log'
getent() { [[ \"\$1\" == passwd ]] || return 2; printf '%s:x:1:1::/home/%s:%s\\n' \"\$2\" \"\$2\" '$fixture_root/bin/tessera-chaos-shell'; }
$system_wrapper_prelude
tmux() { printf 'server exited unexpectedly\\n' >&2; return 1; }"
printf '%s\n' "$run" "$run-view" main >"$sessions"
: >"$kills"
: >"$fixture_tmux_log"
status=0
out="$(kill_run_tmux_sessions chaos "$me" "$run")" || status=$?
check "chaos login shell reaps through its tmux ($status): $out" '[[ $status -eq 0 && "$out" == *"RUN_TMUX_SESSIONS_ABSENT killed=2"* ]]'
check "chaos reap kills exactly the run and its view" '[[ "$(sort "$kills" | tr "\n" " ")" == "$run $run-view " && "$(tr "\n" " " <"$sessions")" == "main " ]]'
check "chaos reap never asks the system tmux" '[[ "$(sort -u "$fixture_tmux_log" | tr "\n" " ")" == "kill-session list-sessions " ]]'
wrapper_prelude="$system_wrapper_prelude"

# ---- S1/S6: a retry's failed cleanup never ends the case early ---------------
# The visual case's own capture_transport and cleanup_remote run here under
# set -e with SSH stand-ins: a transient outage fails the first attempt's
# setup and its cleanup reap, and the case must still reach attempt 2; only
# the final cleanup, whose reap covers every attempt's names, decides. Every
# setup and cleanup ends the scenario's processes by the trigger's names,
# before the session goes, and nothing is signalled by a pattern.
visual="$HERE/visual-cases/s1-s6-live-scroll-transports.sh"
retry_harness="$work/retry-harness.sh"
{
  printf 'set -euo pipefail\n'
  cat <<'STUBS'
CASE_DIR="$1"
mkdir -p "$CASE_DIR/ssh" "$CASE_DIR/ssh_tmux"
TESSERA_FIXTURE_USER=fixture TESSERA_FIXTURE_APP_PORT=22 PASSWORD=x UDID=u BUNDLE_ID=b APP_PATH=a
RUN_TOKEN=20261006T120000Z-1-2
current_host='' current_session='' current_trigger=''
calls="$CASE_DIR/calls"
note() { printf 'NOTE %s\n' "$*" >>"$calls"; }
die() { exit 9; }
sleep() { :; }
xcrun() { :; }
jq() { :; }
clear_app_environment() { :; }
preserve_app_diagnostics() { :; }
preserve_failed_attempt() { :; }
drops_client_mouse() { return 1; }
check_client_mouse_dropped() { return 0; }
scroll_scenario_command() { printf 'scenario --trigger %s' "$2"; }
fixture_ssh() { shift; printf 'fixture_ssh %s\n' "$*" >>"$calls"; }
# The first $(cat down) SSH round trips fail.
ssh_down() {
  local n
  n="$(cat "$CASE_DIR/down")"
  [[ "$n" -gt 0 ]] || return 1
  printf '%s' "$((n - 1))" >"$CASE_DIR/down"
}
control_ssh() { shift; printf 'control_ssh %s\n' "$*" >>"$calls"; ! ssh_down; }
end_run_processes() { shift 2; printf 'end %s\n' "$*" >>"$calls"; ! ssh_down; }
reap_run_fixture_sessions() {
  printf 'reap\n' >>"$calls"
  [[ -z "${FINAL_REAP_FAILS:-}" ]] || return 1
  ! ssh_down
}
# The real sequence ends htop (end_fixture_htop) between its frames.
capture_sequence() {
  printf 'capture\n' >>"$calls"
  end_fixture_htop "$2" "$3"
  return "${CAPTURE_STATUS:-0}"
}
STUBS
  for function in end_fixture_htop end_scenario_processes remove_trigger_files cleanup_remote capture_transport; do
    awk "/^$function\\(\\) \\{/,/^}/" "$visual"
  done
  printf 'capture_transport "${2:-ssh}" stable-host stable\n'
} >"$retry_harness"
check "S1/S6 harness has the case's functions" '[[ "$(grep -cE "^(end_fixture_htop|end_scenario_processes|remove_trigger_files|cleanup_remote|capture_transport)\(\) \{" "$retry_harness")" == 5 ]]'
# 1. Setup, its htop end, and the retry's reap all fail; attempt 2 succeeds.
case_dir="$work/visual-retry"
mkdir -p "$case_dir"
printf 4 >"$case_dir/down"
status=0
/bin/bash "$retry_harness" "$case_dir" >/dev/null 2>&1 || status=$?
check "S1/S6 a transient outage still reaches attempt 2 ($status)" '[[ $status -eq 0 && "$(grep -c "^capture$" "$case_dir/calls")" == 1 ]]'
check "S1/S6 the retry reap failed and the final reap superseded it" '[[ "$(grep -c "^reap$" "$case_dir/calls")" == 2 ]] && grep -q "superseded\|proved an earlier" "$case_dir/calls"'
# 2. Capture passes but the final reap finds a survivor: the case fails.
case_dir="$work/visual-final"
mkdir -p "$case_dir"
printf 0 >"$case_dir/down"
status=0
FINAL_REAP_FAILS=1 /bin/bash "$retry_harness" "$case_dir" >/dev/null 2>&1 || status=$?
check "S1/S6 a failed final reap fails the case ($status)" '[[ $status -ne 0 && "$(grep -c "^capture$" "$case_dir/calls")" == 1 ]]'
# 3. Both attempts fail to capture: both are tried, and the case fails.
case_dir="$work/visual-capture"
mkdir -p "$case_dir"
printf 0 >"$case_dir/down"
status=0
CAPTURE_STATUS=1 /bin/bash "$retry_harness" "$case_dir" >/dev/null 2>&1 || status=$?
check "S1/S6 two failed captures fail the case ($status)" '[[ $status -ne 0 && "$(grep -c "^capture$" "$case_dir/calls")" == 2 ]]'
# 4. SSH+tmux: each cleanup ends the scenario's processes while the session
# still holds them, then kills the session by its exact name.
case_dir="$work/visual-tmux"
mkdir -p "$case_dir"
printf 0 >"$case_dir/down"
status=0
/bin/bash "$retry_harness" "$case_dir" ssh-tmux >/dev/null 2>&1 || status=$?
tmux_trigger=/tmp/tessera_scroll_20261006T120000Z-1-2_ssh_tmux.trigger
view_kill="fixture_ssh tmux kill-session -t '=tessera_scroll_20261006T120000Z-1-2_ssh_tmux-tessera-view'"
session_kill="fixture_ssh tmux kill-session -t '=tessera_scroll_20261006T120000Z-1-2_ssh_tmux'"
last_end="$(awk '/^end @any / { n = NR } END { print n }' "$case_dir/calls")"
last_kill="$(awk -v line="$view_kill" '$0 == line { n = NR } END { print n }' "$case_dir/calls")"
check "S1/S6 ssh-tmux passes ($status)" '[[ $status -eq 0 && "$(grep -c "^capture$" "$case_dir/calls")" == 1 ]]'
check "S1/S6 cleanup ends the scenario before it kills the session (${last_end:-none} < ${last_kill:-none})" \
  '[[ -n "$last_end" && -n "$last_kill" && "$last_end" -lt "$last_kill" ]] && grep -qxF "$session_kill" "$case_dir/calls"'
# Only the trigger's processes (and its Vim stage's file) or its htop are
# ended, and nothing is ever signalled by a command-line pattern: a tmux
# server started by the scenario's new-session carries the trigger too.
allowed_ends="$(printf '%s\n' "end htop /tmp/tessera_scroll_20261006T120000Z-1-2_ssh.trigger" \
  "end @any /tmp/tessera_scroll_20261006T120000Z-1-2_ssh.trigger /tmp/tessera_scroll_20261006T120000Z-1-2_ssh.trigger.vim.txt" \
  "end htop $tmux_trigger" "end @any $tmux_trigger $tmux_trigger.vim.txt")"
check "S1/S6 only the trigger's processes and its htop are ended" '[[ -z "$(grep -h "^end " "$work"/visual-*/calls | sort -u | grep -vxF "$allowed_ends")" ]]'
# Two setups and two cleanups in the retried run; one of each with tmux.
check "S1/S6 every setup and cleanup ends the scenario's processes" '[[ "$(grep -c "^end @any " "$work/visual-retry/calls")" == 4 && "$(grep -c "^end @any " "$work/visual-tmux/calls")" == 2 ]]'
check "S1/S6 no SSH command signals by pattern" '! grep -qhE "pgrep|pkill" "$work"/visual-*/calls'

printf 'fixture reap: %d checks, %d failures\n' "$checks" "$failures"
# An explicit exit: macOS bash 3.2 does not stop at a failing [[ ]].
if [[ "$checks" -eq 0 || "$failures" -ne 0 ]]; then exit 1; fi
script_completed=1
