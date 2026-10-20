#!/usr/bin/env python3
"""Private completed CoreTurnItem versus native ThreadItem display differential.

This checks conversion, not history selection. Native rows can be newer than a
completed event, and absent native rows remain missing reference, never passes.
Only counters, file ordinals and implementation hashes leave the worker pipes.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import resource
import select
import signal
import shlex
import sqlite3
import subprocess
import tempfile
import time
from normalization_corpus import coverage, safe_type
from native_first_page import clone


def line(process, maximum=262144, deadline=None, allow_error=False):
    # Reading a raw FileIO one byte at a time is catastrophically expensive;
    # buffered readline + select can instead overlook already-buffered rows.
    buffer = getattr(process, '_projection_buffer', None)
    if buffer is None: buffer = process._projection_buffer = bytearray()
    if deadline is None: deadline = time.monotonic() + 30
    while True:
        end = buffer.find(b'\n')
        if end >= 0:
            if end + 1 > maximum: raise RuntimeError('worker_frame_budget')
            raw = bytes(buffer[:end + 1]); del buffer[:end + 1]
            break
        if len(buffer) >= maximum: raise RuntimeError('worker_frame_budget')
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]: raise RuntimeError('worker_timeout')
        chunk = os.read(process.stdout.fileno(), min(65536, maximum - len(buffer)))
        if not chunk: raise RuntimeError('worker_frame_budget')
        buffer.extend(chunk)
    value = json.loads(raw)
    if not isinstance(value, dict) or 'error' in value and not allow_error: raise RuntimeError('worker_error')
    return value


def write_frame(process, chunks, deadline):
    """Bound pipe backpressure as well as the response, with one deadline."""
    descriptor = process.stdin.fileno()
    os.set_blocking(descriptor, False)
    for chunk in chunks:
        pending = memoryview(chunk)
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [descriptor], [], remaining)[1]:
                raise RuntimeError('public_worker_write_timeout')
            try: count = os.write(descriptor, pending)
            except BlockingIOError: continue
            if not count: raise RuntimeError('public_worker_write')
            pending = pending[count:]


def command_argv(command):
    # shlex.split alone loses the distinction between shell operators and
    # quoted literals. Admit only one literal argv expression: no expansion,
    # redirects, pipelines, comments, substitutions, or command separators.
    if not isinstance(command, str): return None
    quote = None; escaped = False
    for character in command:
        if escaped:
            escaped = False
            continue
        if quote == "'":
            if character == "'": quote = None
        elif character == '\\': escaped = True
        elif quote == '"':
            if character == '"': quote = None
            elif character in '$`': return None
        elif character in "'\"": quote = character
        elif character not in ' abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-': return None
    if quote is not None or escaped: return None
    try: return shlex.split(command)
    except ValueError: return None


def equivalent_projection(left, right):
    if left == right: return 'exact_projection'
    # Envelope-level budget marks can differ after upstream drops non-display
    # metadata. Do not excuse ANY block/body/truncation difference with this.
    a = {key: value for key, value in left.items() if key != 'truncated'}
    b = {key: value for key, value in right.items() if key != 'truncated'}
    if a == b: return 'same_projection_different_envelope_budget'
    if left.get('role') != 'tool' or right.get('role') != 'tool': return None
    first, second = a.get('blocks', []), b.get('blocks', [])
    if not first or len(first) != len(second) or first[1:] != second[1:]: return None
    x, y = first[0], second[0]
    if any(block.get('type') != 'tool_call' or block.get('name') != 'Command' or block.get('truncated') for block in (x, y)): return None
    if {key: value for key, value in x.items() if key != 'preview'} != {key: value for key, value in y.items() if key != 'preview'}: return None
    if {key: value for key, value in a.items() if key != 'blocks'} != {key: value for key, value in b.items() if key != 'blocks'}: return None
    first_argv, second_argv = command_argv(x.get('preview')), command_argv(y.get('preview'))
    if first_argv is not None and first_argv == second_argv: return 'equivalent_command_argv'
    return None


def compare_item(row, database, public, differences=None):
    envelope = row['record']; projected = envelope['projection']
    issues = coverage(dict(row, record=projected))
    if issues: return 'source_conversion_coverage_failure'
    identity = (envelope['owner'], envelope['turn'], envelope['itemID'])
    if not all(isinstance(value, str) and 0 < len(value) <= 256 for value in identity):
        return 'source_identity_failure'
    result = database.execute('SELECT rowid, updated_at_ordinal, length(CAST(item_json AS BLOB)) FROM thread_items '
        'WHERE thread_id=? AND turn_id=? AND item_id=?', identity).fetchone()
    if result is None: return 'missing_native_reference'
    rowid, updated, length = result
    prefix = ('{"turn":' + json.dumps(envelope['turn']) + ',"item":').encode()
    if not isinstance(length, int) or length + len(prefix) + 1 > 32 * 1024 * 1024: return 'native_reference_budget'
    # Stream raw UTF-8 out of SQLite's incremental BLOB API (also valid for
    # TEXT storage). No giant Python Unicode string or decoded input DOM.
    def chunks():
        yield str(length + len(prefix) + 1).encode() + b'\n' + prefix
        with database.blobopen('thread_items', 'item_json', rowid, readonly=True) as blob:
            if len(blob) != length: raise RuntimeError('native_reference_changed')
            for _ in range(0, length, 65536): yield blob.read(65536)
        yield b'}'
    deadline = time.monotonic() + 30
    write_frame(public, chunks(), deadline)
    native = line(public, deadline=deadline)
    if coverage(native): return 'native_projection_coverage_failure'
    equivalent = equivalent_projection(projected, native['record'])
    if equivalent: return equivalent
    if differences is not None and updated <= envelope['ordinal']:
        for key in ('type', 'role', 'turnID', 'providerItemID', 'toolStatus', 'truncated', 'isSidechain', 'isCompactSummary'):
            if projected.get(key) != native['record'].get(key): differences[key] += 1
        left, right = projected.get('blocks', []), native['record'].get('blocks', [])
        if len(left) != len(right): differences['block_count'] += 1
        for a, b in zip(left, right):
            for key in ('type', 'name', 'text', 'preview', 'diff', 'path', 'mediaType', 'toolCallID', 'truncated'):
                if a.get(key) != b.get(key): differences['block/' + key] += 1
    return 'different_native_newer' if updated > envelope['ordinal'] else 'different_native_not_newer'


def audit(driver, path, database, public, selected=False):
    counts = collections.Counter(); types = collections.defaultdict(collections.Counter)
    differences = collections.defaultdict(collections.Counter)
    with subprocess.Popen([str(driver), '--selected-items' if selected else '--core-items', str(path)], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0) as process:
        try:
            while True:
                row = line(process)
                if row.get('complete'):
                    if row.get('sourceEnd') != path.stat().st_size: raise RuntimeError('source_completion_mismatch')
                    if process.wait(timeout=5): raise RuntimeError('worker_exit')
                    if selected and not row.get('paginated'): counts['legacy_canonical_reference_required'] += 1
                    return dict(counts=counts, types=types, differences=differences, bytes_read=row['bytesRead'])
                kind = safe_type(row['sourceType'])
                outcome = compare_item(row, database, public, differences[kind])
                counts[outcome] += 1; types[kind][outcome] += 1
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=5)


def main():
    def interrupt(_signal, _frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupt)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', required=True, type=Path)
    parser.add_argument('--history-driver', type=Path,
        help='compare selected latest paginated snapshots using agent-codex-history-driver; legacy remains unproven')
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--native-db', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [args.output, *args.output.parents]):
        parser.error('private output must be outside Git')
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    candidates = json.loads(args.manifest.read_text())['candidates']
    totals = collections.Counter(); results = []
    with tempfile.TemporaryDirectory(prefix='completed-projection-', dir=args.output) as temporary:
        private = Path(temporary); driver = private / 'driver'
        clone(args.driver, driver); driver.chmod(0o700)
        driver_hash = hashlib.sha256(driver.read_bytes()).hexdigest()
        history_driver = None; history_hash = None
        if args.history_driver:
            history_driver = private / 'history-driver'
            clone(args.history_driver, history_driver); history_driver.chmod(0o700)
            history_hash = hashlib.sha256(history_driver.read_bytes()).hexdigest()
        # Input must be the previously captured finite snapshot, not live WAL.
        clone(args.native_db, private / 'native.sqlite')
        database = sqlite3.connect('file:' + str(private / 'native.sqlite') + '?mode=ro', uri=True)
        with subprocess.Popen([str(driver), '--public-items'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, bufsize=0) as public:
            try:
                for ordinal, candidate in enumerate(candidates):
                    if candidate['provider'] != 'codex': continue
                    try: result = audit(history_driver or driver, Path(candidate['path']), database, public, selected=history_driver is not None)
                    except Exception as error:
                        result = dict(error=str(error) if isinstance(error, RuntimeError) else type(error).__name__)
                    results.append(dict(ordinal=ordinal, **result)); totals.update(result.get('counts', {}))
                    if len(results) % 25 == 0: print(json.dumps(dict(files=len(results), counts=totals)), flush=True)
                    if public.poll() is not None: raise RuntimeError('public_worker_exit')
                public.stdin.close()
                if public.wait(timeout=5): raise RuntimeError('public_worker_exit')
            finally:
                if public.poll() is None: public.kill(); public.wait(timeout=5)
                database.close()
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if os.uname().sysname != 'Darwin': peak *= 1024
    failures = sum('error' in row for row in results)
    unproven = sum(value for key, value in totals.items() if key != 'exact_projection')
    report = dict(stage='selected_paginated_item_projection' if history_driver else 'completed_item_projection_not_canonical_history',
        status='failed' if failures or unproven or not results or not totals or peak > 256 * 1024 * 1024 else 'passed',
        driver_sha256=driver_hash, history_driver_sha256=history_hash, files=len(results), processing_failures=failures,
        counts=totals, results=results, coordinator_peak_bytes=peak)
    (args.output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'results'}))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__': raise SystemExit(main())
