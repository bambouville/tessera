#!/usr/bin/env python3
"""Probe bounded native App Server reads against private SQLite snapshots.

The live provider home is read-only. No auth, hooks, or configuration is copied.
Evidence is content-free; snapshot databases stay private and outside Git.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--source', type=Path, default=Path.home() / '.codex')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]):
        parser.error('private snapshots must be outside every Git worktree')
    output.mkdir(mode=0o700)
    os.umask(0o077)
    evidence = {'stage': 'native_store_capability_probe', 'databases': {}}
    for name in ['state_5.sqlite', 'thread_history_1.sqlite']:
        source = (args.source / name).resolve(strict=True)
        target = output / name
        deadline = time.monotonic() + 60
        def progress(status, remaining, total):
            if time.monotonic() > deadline: raise TimeoutError('snapshot deadline')
        with sqlite3.connect(source.as_uri() + '?mode=ro', uri=True) as reader, sqlite3.connect(target) as writer:
            reader.backup(writer, pages=256, progress=progress)
            if writer.execute('PRAGMA quick_check').fetchone() != ('ok',): raise RuntimeError('snapshot integrity')
            if name == 'state_5.sqlite':
                # An isolated read probe must not reconnect a copied remote-
                # control enrollment. Modify only this new private snapshot.
                writer.execute('DELETE FROM remote_control_enrollments')
                writer.commit()
        digest = hashlib.sha256()
        with target.open('rb') as stream:
            while chunk := stream.read(1048576): digest.update(chunk)
        evidence['databases'][name] = {'bytes': target.stat().st_size, 'sha256': digest.hexdigest()}
    with sqlite3.connect((output / 'state_5.sqlite').as_uri() + '?mode=ro', uri=True) as state:
        evidence['history_modes'] = dict(state.execute('SELECT history_mode, count(*) FROM threads GROUP BY history_mode'))
        selected = state.execute("SELECT id FROM threads WHERE history_mode='paginated' ORDER BY updated_at DESC LIMIT 1").fetchone()
        evidence['stored_threads'] = state.execute('SELECT count(*) FROM threads').fetchone()[0]
    with sqlite3.connect((output / 'thread_history_1.sqlite').as_uri() + '?mode=ro', uri=True) as history:
        evidence['native_threads'] = history.execute('SELECT count(DISTINCT thread_id) FROM thread_turns').fetchone()[0]
        evidence['native_items'] = history.execute('SELECT count(*) FROM thread_items').fetchone()[0]
        evidence['native_item_types'] = dict(history.execute('SELECT item_type, count(*) FROM thread_items GROUP BY item_type'))
    if not selected: raise RuntimeError('no paginated thread to probe')
    process = subprocess.run([str(args.binary.resolve()), 'codex-probe', '--thread', selected[0]],
        capture_output=True, timeout=20, env=dict(os.environ, CODEX_HOME=str(output)))
    if process.stderr or len(process.stdout) > 65536: raise RuntimeError('unexpected probe diagnostics')
    evidence['probe'] = json.loads(process.stdout)
    evidence['probe_exit'] = process.returncode
    with (output / 'content-free-evidence.json').open('x') as stream: json.dump(evidence, stream, indent=2)
    print(json.dumps(evidence))
    raise SystemExit(process.returncode)


if __name__ == '__main__': main()
