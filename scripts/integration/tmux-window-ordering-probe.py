#!/usr/bin/env python3
"""Server oracle. Run via SSH on a disposable VPS, never on a user test host."""
import argparse
import json
import os
import pty
import fcntl
import termios
import struct
import selectors
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--disposable-fixture', action='store_true', required=True)
parser.add_argument("--base-index", type=int, choices=[0, 1], default=0)
args = parser.parse_args()
socket = 'tessera-order-' + uuid.uuid4().hex
base = ['tmux', '-L', socket, '-f', '/dev/null']
client = None
transcript = []

def tmux(*args):
    return subprocess.check_output(base + list(args), text=True).strip()

def order(session):
    return tmux('list-windows', '-t', session, '-F', '#{window_id}').splitlines()

def selection(session):
    return tmux('display-message', '-p', '-t', session, '#{window_id}')

def capture(seconds):
    end = time.monotonic() + seconds
    result = b''
    with selectors.DefaultSelector() as selector:
        selector.register(client.stdout, selectors.EVENT_READ)
        while time.monotonic() < end:
            for key, _ in selector.select(max(0, end - time.monotonic())):
                data = os.read(key.fd, 65536)
                if not data:
                    return result.decode()
                result += data
    text = result.decode()
    transcript.extend(text.splitlines())
    return text

def foreign_create(target, observed_session):
    global client
    if client is not None:
        client.terminate()
        client.wait(timeout=3)
    before_ids = order(target)
    gap_id = before_ids[1]
    gap_index = int(tmux('display-message', '-p', '-t', target + ':' + gap_id, '#{window_index}'))
    tmux('kill-window', '-t', target + ':' + gap_id)
    before_ids = order(target)
    observed_active = selection(observed_session)
    client = subprocess.Popen(base + ['-C', 'attach-session', '-t', observed_session],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    capture(.2)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    peer = subprocess.Popen(base + ['attach-session', '-t', target], stdin=slave,
                            stdout=slave, stderr=slave, env={**os.environ, 'TERM': 'xterm-256color'})
    os.close(slave)
    try:
        time.sleep(.3)
        capture(.2)
        os.write(master, b'\x02c')
        deadline = time.monotonic() + 5
        while len(order(target)) == len(before_ids) and time.monotonic() < deadline:
            time.sleep(.05)
        created = set(order(target)) - set(before_ids)
        assert len(created) == 1, ('foreign Ctrl-b c did not create', created)
        created = created.pop()
        assert int(tmux('display-message', '-p', '-t', target + ':' + created, '#{window_index}')) == gap_index
        assert selection(target) == created
        if target != observed_session:
            assert selection(observed_session) == observed_active
        events = capture(.3)
        assert '%window-add ' + created in events
        return {'created': created, 'index': gap_index, 'events': events.splitlines()}
    finally:
        peer.terminate()
        try:
            peer.wait(timeout=3)
        except subprocess.TimeoutExpired:
            peer.kill()
            peer.wait()
        os.close(master)


try:
    version = tmux('-V')
    owner = tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'owner', '-n', 'one')
    tmux('set-option', '-g', 'base-index', str(args.base_index))
    tmux('move-window', '-r', '-t', owner)
    ids = [order(owner)[0]]
    for name in ['two', 'three', 'four']:
        ids.append(tmux('new-window', '-d', '-a', '-t', owner + ':{end}', '-P', '-F', '#{window_id}', '-n', name))
    # Independent permutation oracle for the conservative swap-only strategy.
    for source in ids:
        for destination in range(len(ids)):
            current = order(owner)
            position = current.index(source)
            expected = [value for value in current if value != source]
            expected.insert(destination, source)
            if position != destination:
                step = 1 if position < destination else -1
                for index in range(position + step, destination + step, step):
                    tmux('swap-window', '-d', '-s', owner + ':' + source, '-t', owner + ':' + current[index])
            assert order(owner) == expected, (current, source, destination, order(owner), expected)
    # Restore the baseline before the existing gaps/group/subscription cases.
    for index, target in enumerate(ids):
        current = order(owner)
        if current[index] != target:
            tmux('swap-window', '-d', '-s', owner + ':' + target, '-t', owner + ':' + current[index])
    tmux('kill-window', '-t', owner + ':' + ids[1])
    before = list(map(int, tmux('list-windows', '-t', owner, '-F', '#{window_index}').splitlines()))
    appended = tmux('new-window', '-d', '-a', '-t', owner + ':{end}', '-e', 'COLORTERM=truecolor', '-P', '-F', '#{window_id}')
    assert int(tmux('display-message', '-p', '-t', appended, '#{window_index}')) > max(before)
    view = tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'owner-tessera-view', '-t', owner)
    third = tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'third-member', '-t', owner)
    members = [owner, view, third]
    for session, window in zip(members, [ids[0], ids[2], ids[3]]):
        tmux('select-window', '-t', session + ':' + window)
    selected = {session: selection(session) for session in members}
    panes = tmux('list-panes', '-s', '-t', view, '-F', '#{window_id}:#{pane_id}:#{pane_width}:#{pane_height}')
    client = subprocess.Popen(base + ['-C', 'attach-session', '-t', view], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    capture(.2)
    # One pane, never the session (`name::`), `%*` or `@*`: tmux <= 3.6a
    # crashes when a client holding those outlives its session.
    anchor = panes.splitlines()[0].split(':')[1]
    client.stdin.write(f"refresh-client -B 'tessera-window-order:{anchor}:#{{W:#{{window_index}}=#{{window_id}} ,#{{window_index}}=#{{window_id}}* }}'\n".encode())
    client.stdin.flush()
    capture(1.2)
    tmux('move-window', '-d', '-b', '-s', view + ':' + appended, '-t', view + ':' + ids[0])
    after_move_selection = {session: selection(session) for session in members}
    group_selection_changed = selected != after_move_selection
    for session, window in selected.items():
        tmux('select-window', '-t', session + ':' + window)
    moved_events = capture(1.3)
    assert order(view)[0] == appended
    assert all(order(session) == order(view) for session in members)
    assert {session: selection(session) for session in members} == selected
    assert '%window-close ' + appended in moved_events
    assert 'tessera-window-order' in moved_events
    assert sorted(panes.splitlines()) == sorted(tmux('list-panes', '-s', '-t', view, '-F', '#{window_id}:#{pane_id}:#{pane_width}:#{pane_height}').splitlines())
    before_swap = order(view)
    tmux('swap-window', '-s', view + ':' + before_swap[1], '-t', view + ':' + before_swap[2])
    swap_events = capture(1.3)
    expected = before_swap[:]
    expected[1], expected[2] = expected[2], expected[1]
    assert order(view) == expected
    assert 'tessera-window-order' in swap_events
    for session in members:
        tmux('move-window', '-r', '-t', session)
    assert all(order(session) == expected for session in members)
    indexes = [tmux('list-windows', '-t', session, '-F', '#{window_index}') for session in members]
    assert len(set(indexes)) == 1
    assert int(indexes[0].splitlines()[0]) == args.base_index
    grouped_create = foreign_create(owner, view)
    ungrouped = tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'ungrouped')
    for _ in range(2):
        tmux('new-window', '-d', '-a', '-t', ungrouped + ':{end}')
    ungrouped_create = foreign_create(ungrouped, ungrouped)
    print(json.dumps({'version': version, 'passed': True, 'baseIndex': args.base_index, 'groupMoveChangedSelection': group_selection_changed,
                      'foreignCreateGrouped': grouped_create, 'foreignCreateUngrouped': ungrouped_create,
                      'members': len(members), 'append': appended, 'expectedOrder': expected,
                      'moveEvents': moved_events.splitlines(), 'swapEvents': swap_events.splitlines()}, indent=2))
finally:
    if client is not None:
        client.terminate()
        try:
            client.wait(timeout=3)
        except subprocess.TimeoutExpired:
            client.kill()
            client.wait()
    subprocess.run(base + ['kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
