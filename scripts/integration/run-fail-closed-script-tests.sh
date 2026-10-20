#!/usr/bin/env bash
# Host-free guard for a macOS /bin/bash 3.2 hole: a `set -u` abort (unbound
# variable, empty "${array[@]}", ${VAR:?}) under `set -e` reaches the EXIT trap
# with $? = 0, so a lane that crashed before its tests reported success.
#
# 1. Runs the lib.sh helpers and the inline pattern under /bin/bash (and the
#    POSIX form under /bin/sh) against real aborts, failures and exits.
# 2. Statically checks every EXIT trap under scripts/: its handler must fail
#    closed, and its script must end with script_completed=1 (and set it
#    before any deliberate `exit 0` while the trap is armed).
#
#   /bin/bash scripts/integration/run-fail-closed-script-tests.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/tessera-fail-closed.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap 'fail_closed_trap cleanup' EXIT

failures=0
checks=0
fail() {
  printf 'FAIL %s\n' "$*" >&2
  failures=$((failures + 1))
}

# Handler shapes. Each touches $CASE_OUT.cleaned so a skipped cleanup shows.
# The inline and POSIX bodies must match what the static check accepts.
cat >"$work/capturing.sh" <<'SH'
cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  touch "$CASE_OUT.cleaned"
  exit "$status"
}
trap cleanup EXIT
SH
cat >"$work/wrapped.sh" <<'SH'
cleanup() { touch "$CASE_OUT.cleaned"; }
trap 'fail_closed_trap cleanup' EXIT
SH
cat >"$work/inline.sh" <<'SH'
cleanup() {
  local status=$?
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  touch "$CASE_OUT.cleaned"
  exit "$status"
}
trap cleanup EXIT
SH
cat >"$work/posix.sh" <<'SH'
cleanup() {
  status=$?
  if [ "$status" -eq 0 ] && [ "${script_completed:-0}" != 1 ]; then
    printf '%s\n' "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  touch "$CASE_OUT.cleaned"
  exit "$status"
}
trap cleanup EXIT
SH
cat >"$work/unguarded.sh" <<'SH'
cleanup() {
  local status=$?
  trap - EXIT
  touch "$CASE_OUT.cleaned"
  exit "$status"
}
trap cleanup EXIT
SH

# write_case SHAPE NAME TRIGGER: prints the path of a script that installs
# SHAPE's handler and then runs TRIGGER.
write_case() {
  local shape="$1" name="$2" trigger="$3" script="$work/$1-$2.sh"
  {
    if [[ "$shape" == posix ]]; then
      printf 'set -eu\n'
    else
      printf 'set -euo pipefail\n'
    fi
    printf "CASE_OUT='%s'\n" "$work/$shape-$name"
    case "$shape" in
      capturing|wrapped) printf ". '%s'\n" "$HERE/lib.sh" ;;
    esac
    printf ". '%s'\n" "$work/$shape.sh"
    printf '%s\n' "$trigger"
  } >"$script"
  printf '%s\n' "$script"
}

# expect SHAPE NAME EXPECTED_STATUS ABORT_MESSAGE(yes|no) TRIGGER
expect() {
  local shape="$1" name="$2" expected="$3" message="$4" trigger="$5"
  local shell=/bin/bash script out actual
  [[ "$shape" != posix ]] || shell=/bin/sh
  script="$(write_case "$shape" "$name" "$trigger")"
  out="$work/$shape-$name"
  if env -u script_completed "$shell" "$script" >"$out.log" 2>&1; then actual=0; else actual=$?; fi
  checks=$((checks + 1))
  if [[ "$actual" != "$expected" ]]; then
    fail "$shape/$name: exited $actual, expected $expected ($(tr '\n' ' ' <"$out.log"))"
  elif [[ ! -f "$out.cleaned" ]]; then
    fail "$shape/$name: cleanup handler did not run"
  elif [[ "$message" == yes ]] && ! grep -q 'aborted before completion' "$out.log"; then
    fail "$shape/$name: no 'aborted before completion' diagnostic"
  elif [[ "$message" == no ]] && grep -q 'aborted before completion' "$out.log"; then
    fail "$shape/$name: unexpected 'aborted before completion' diagnostic"
  fi
}

unset TESSERA_FAIL_CLOSED_UNSET_VALUE
for shape in capturing wrapped inline posix; do
  expect "$shape" unbound_variable 1 yes 'echo "$undefined_variable"'
  if [[ "$shape" != posix ]]; then
    expect "$shape" empty_array 1 yes 'empty=(); printf "%s\n" "${empty[@]}"'
  fi
  expect "$shape" required_value 1 yes ': "${TESSERA_FAIL_CLOSED_UNSET_VALUE:?required}"'
  expect "$shape" errexit_failure 1 no 'false'
  expect "$shape" explicit_exit_3 3 no 'exit 3'
  expect "$shape" marked_early_exit_0 0 no 'script_completed=1; exit 0; echo unreachable'
  # The contract: a deliberate exit 0 that forgot the marker fails closed.
  expect "$shape" unmarked_exit_0 1 yes 'exit 0'
  expect "$shape" completed 0 no 'true; script_completed=1'
done

# The guard used for arrays that may be empty expands to nothing when empty
# and keeps every element intact otherwise.
checks=$((checks + 1))
# shellcheck disable=SC2016
if ! /bin/bash -c 'set -euo pipefail
empty=(); two=("a b" c)
set -- ${empty[@]+"${empty[@]}"}; [[ $# -eq 0 ]]
set -- ${two[@]+"${two[@]}"}; [[ $# -eq 2 && "$1" == "a b" && "$2" == c ]]' >"$work/array-guard.log" 2>&1; then
  fail "empty-array guard: $(tr '\n' ' ' <"$work/array-guard.log")"
fi

# Control, informational only: what this bash does without the guard.
control="$(write_case unguarded unbound_variable 'echo "$undefined_variable"')"
if env -u script_completed /bin/bash "$control" >/dev/null 2>&1; then control_status=0; else control_status=$?; fi
printf 'control: an unguarded EXIT trap exits %s after a set -u abort under /bin/bash %s\n' \
  "$control_status" "$(/bin/bash -c 'printf %s "$BASH_VERSION"')"
printf 'dynamic: %d checks\n' "$checks"

static_status=0
python3 - "$REPO_ROOT" <<'PY' || static_status=$?
import os
import re
import shlex
import sys

root = sys.argv[1]
# Scripts that install an EXIT trap but never run under macOS bash.
EXEMPT = {
    "scripts/integration/remote/provision.sh":
        "runs on the Linux fixture host through `ssh bash -s`",
}
SKIP_DIRS = {"out", ".state", "__pycache__", "secrets"}
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
FUNCTION = re.compile(r"^(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{(.*)$")
TRAP = re.compile(r"(?:^|[;&|{(]|\bthen\b|\bdo\b|\belse\b)\s*trap\s+")
SOURCE = re.compile(r"^(?:source|\.)\s+(\S+)")
CAPTURE = re.compile(r"^(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)=\$\?(?:\s|;|$)")
EXIT_ZERO = re.compile(r"(?:^|[;{]\s*|\bthen\s+|\belse\s+|\|\|\s*|&&\s*)exit(?:\s+0)?\s*(?:$|;|\}|\bfi\b)")
MARKER = "script_completed=1"
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")


def shell_files():
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, "scripts")):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if name.endswith(".tmp"):
                continue
            if not name.endswith(".sh"):
                try:
                    with open(path, "rb") as handle:
                        first = handle.readline()
                except OSError:
                    continue
                if not (first.startswith(b"#!") and re.search(rb"\b(ba)?sh\b", first)):
                    continue
            yield os.path.relpath(path, root)


def logical_lines(text):
    """(line, indent, code): heredoc bodies, comments and continuations removed."""
    lines, pending, buffer, start = [], [], "", None
    for number, raw in enumerate(text.splitlines(), 1):
        if pending:
            strip_tabs, word = pending[0]
            if (raw.lstrip("\t") if strip_tabs else raw) == word:
                pending.pop(0)
            continue
        if start is None:
            start = number
        if raw.endswith("\\"):
            buffer += raw[:-1] + " "
            continue
        line, buffer = buffer + raw, ""
        for match in HEREDOC.finditer(line):
            if line[max(0, match.start() - 1):match.start()] != "<":
                pending.append((match.group(1) == "-", match.group(3)))
        code = line.strip()
        if code and not code.startswith("#"):
            lines.append((start, len(line) - len(line.lstrip()), code))
        start = None
    return lines


def functions(lines):
    found = {}
    for index, (number, indent, code) in enumerate(lines):
        match = FUNCTION.match(code)
        if not match:
            continue
        name, rest = match.groups()
        if rest.strip().endswith("}"):
            found[name] = (number, number, [rest.strip()[:-1].strip()])
            continue
        body = []
        for other_number, other_indent, other_code in lines[index + 1:]:
            if other_code.startswith("}") and other_indent <= indent:
                found[name] = (number, other_number, body)
                break
            body.append(other_code)
    return found


def exit_traps(lines):
    for number, _, code in lines:
        for match in TRAP.finditer(code):
            lexer = shlex.shlex(code[match.end():], posix=True, punctuation_chars=";&|()")
            lexer.whitespace_split = True
            words = []
            try:
                for token in lexer:
                    if token and set(token) <= set(";&|()"):
                        break
                    words.append(token)
            except ValueError:
                continue
            if len(words) >= 2 and words[0] != "-" and ({"EXIT", "0"} & set(words[1:])):
                yield number, words[0]


def fails_closed(statements):
    """The first statement captures $?; a fail-closed check follows on that variable."""
    if not statements:
        return False
    capture = CAPTURE.match(statements[0].split(";")[0].strip())
    if not capture:
        return False
    var = re.escape(capture.group(1))
    joined = "\n".join(statements)
    helper = re.search(r'fail_closed_status "\$%s" \|\| %s=1' % (var, var), joined)
    inline = re.search(
        r'"\$%s" -eq 0 (?:&&|\] &&) (?:\[ )?"\$\{script_completed:-0\}" != 1' % var, joined
    ) and re.search(r"(?:^|\s)%s=1(?:$|\s|;)" % var, joined)
    return bool(helper or inline)


def handler_ok(action, found):
    if re.match(r"fail_closed_trap\s+\S", action):
        return True
    if CAPTURE.match(action.strip()):
        return fails_closed([action])
    name = action.split()[0] if action.split() else ""
    return name in found and fails_closed(found[name][2])


def ends_with_marker(lines):
    codes = [code for _, _, code in lines]
    if codes and codes[-1] == MARKER:
        return True
    return len(codes) >= 2 and re.match(r"exit\b", codes[-1]) and codes[-2] == MARKER


files = {}
for rel in shell_files():
    with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as handle:
        lines = logical_lines(handle.read())
    files[rel] = (lines, functions(lines), list(exit_traps(lines)))
trap_scripts = {rel for rel, (_, _, traps) in files.items() if traps}
by_name = {}
for rel in trap_scripts:
    by_name.setdefault(os.path.basename(rel), []).append(rel)

problems, checked, wrapped = [], 0, 0
for rel, (lines, found, traps) in sorted(files.items()):
    sourced = []
    for number, _, code in lines:
        match = SOURCE.match(code)
        if match:
            target = os.path.basename(match.group(1).strip("\"'"))
            if by_name.get(target):
                sourced.append((number, target))
    if not traps and not sourced:
        continue
    if rel in EXEMPT:
        print("exempt: %s (%s)" % (rel, EXEMPT[rel]))
        continue
    checked += 1
    for number, action in traps:
        if action.startswith("fail_closed_trap"):
            wrapped += 1
        if not handler_ok(action, found):
            problems.append("%s:%d: EXIT handler %r does not fail closed" % (rel, number, action))
    if not ends_with_marker(lines):
        problems.append("%s: last statement is not %s (or %s; exit ...)" % (rel, MARKER, MARKER))
    armed_from = min([n for n, _ in traps] + [n for n, _ in sourced])
    handler_spans = []
    for _, action in traps:
        name = action.split()[0] if action.split() else ""
        if name in found:
            handler_spans.append(found[name][:2])
    depth, previous = 0, ""
    for number, _, code in lines:
        in_handler = any(start <= number <= end for start, end in handler_spans)
        if code.startswith(")"):
            depth = max(0, depth - 1)
        if (number > armed_from and depth == 0 and not in_handler
                and EXIT_ZERO.search(QUOTED.sub("''", code)) and previous != MARKER
                and MARKER + ";" not in code.split("exit")[0]):
            problems.append("%s:%d: deliberate exit without %s first: %s" % (rel, number, MARKER, code))
        if code.endswith("("):
            depth += 1
        previous = code

for problem in problems:
    print("FAIL " + problem, file=sys.stderr)
print("static: %d scripts with EXIT traps checked (%d traps through fail_closed_trap)" % (checked, wrapped))
if checked == 0:
    print("FAIL static: no EXIT traps found; the scan is broken", file=sys.stderr)
    sys.exit(1)
sys.exit(1 if problems else 0)
PY
if [[ "$static_status" -ne 0 ]]; then
  fail "static EXIT-trap check (see above)"
fi

if [[ "$failures" -ne 0 ]]; then
  printf 'fail-closed script tests: %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'fail-closed script tests passed\n'
script_completed=1
