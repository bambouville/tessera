#!/usr/bin/env python3
"""A stand-in for tmux, used only by the differential lane's dry run to
exercise remote/tmux-model-runner.py's process, pseudo-terminal, reader and
cleanup paths without tmux or any host. It implements nothing of tmux beyond
the command shapes the runner issues:

  -V                                   prints tmux-model-stub
  new-session/new-window ... -F FMT    prints FMT with fresh $N/@N/%N ids
  -C attach-session ...                %begin/%end for the attach, then one
                                       `stub: LINE` echo per input line; compound
                                       lines have per-command/error guards
  attach-session ...                   reads the terminal until killed
  list-panes -a -F '#{pid} #{pane_pid}' stand-in server and pane processes
  has-session / kill-server            against a state file beside -S SOCKET;
                                       kill-server ends the stand-in processes
"""
import json
import os
import signal
import shlex
import subprocess
import sys
import tty

args = sys.argv[1:]
socket_path = None
while args and args[0] in ("-S", "-f", "-L"):
    if args[0] == "-S":
        socket_path = args[1]
    args = args[2:]
if args[:1] == ["-V"]:
    print("tmux-model-stub")
    sys.exit(0)
if socket_path is None:
    sys.exit("stub: -S SOCKET is required")
state_path = socket_path + ".stub.json"
control = args[:1] == ["-C"]
if control:
    args = args[1:]
command = args[0] if args else ""


def load():
    try:
        with open(state_path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None


def save(state):
    with open(state_path, "w") as handle:
        json.dump(state, handle)


def option(flag):
    return args[args.index(flag) + 1] if flag in args else None


def stand_in():
    """A real process the runner's cleanup must see end."""
    return subprocess.Popen(["sleep", "600"], start_new_session=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid


if command in ("new-session", "new-window"):
    state = load() or {"session": 0, "window": 0, "pane": 0, "server": stand_in(), "panes": []}
    state["panes"].append(stand_in())
    values = {"#{session_id}": f"${state['session']}", "#{window_id}": f"@{state['window']}",
              "#{pane_id}": f"%{state['pane']}"}
    if command == "new-session":
        state["session"] += 1
    state["window"] += 1
    state["pane"] += 1
    save(state)
    text = option("-F") or ""
    for key, value in values.items():
        text = text.replace(key, value)
    print(text)
elif command == "has-session":
    sys.exit(0 if load() is not None else 1)
elif command == "list-panes":
    state = load()
    if state is None:
        sys.exit(1)
    for pane in state["panes"]:
        print(f"{state['server']} {pane}")
elif command == "kill-server":
    state = load()
    if state is None:
        sys.exit(1)
    for pid in [state["server"]] + state["panes"]:
        os.kill(pid, signal.SIGTERM)
    os.remove(state_path)
elif command == "attach-session" and control:
    number = 0

    def block(*lines, success=True):
        global number
        number += 1
        print(f"%begin 1700000000 {number} {0 if number == 1 else 1}")
        for line in lines:
            print(line)
        print(f"%{'end' if success else 'error'} 1700000000 {number} {0 if number == 1 else 1}", flush=True)

    block()
    for line in sys.stdin:
        text = line.rstrip()
        if ";" not in text:
            block(f"stub: {text}")
            continue
        # Keep one echo per input line for the runner's substitution check.
        print(f"stub: {text}")
        lexer = shlex.shlex(text, posix=True, punctuation_chars=";")
        lexer.whitespace_split = True
        commands = [[]]
        for word in lexer:
            if word == ";":
                commands.append([])
            else:
                commands[-1].append(word)
        known = {"display", "display-message", "select-window", "set-option", "refresh-client", "resize-window"}
        unknown = next((words[0] for words in commands if words and words[0] not in known), None)
        # control_error rejects the entire parsed line with one error frame.
        if unknown:
            block(f"parse error: unknown command: {unknown}", success=False)
            continue
        for words in commands:
            if not words:
                continue
            if words[0] in ("display", "display-message"):
                block(words[-1])
            elif words[0] == "select-window" and "-t" in words:
                target = words[words.index("-t") + 1]
                if target.startswith("@") and int(target[1:]) >= load()["window"]:
                    # cmdq_next / cmdq_remove_group drop the tail with no guards.
                    block(f"can't find window: {target}", success=False)
                    break
                block()
            else:
                block()
elif command == "attach-session":
    tty.setraw(0)
    signal.signal(signal.SIGWINCH, lambda number, frame: os.write(1, b"stub: resized\r\n"))
    os.write(1, b"stub: attached\r\n")
    while os.read(0, 1024):
        os.write(1, b"stub: key\r\n")
else:
    sys.exit(f"stub: unsupported {command}")
