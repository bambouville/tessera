#!/usr/bin/env python3
"""Private native-store pagination gate using the production window protocol.

Uses consistent, previously sanitized SQLite snapshots, not the live Codex
home. Compares every stored native item ID and type in both directions against
SQLite rollout order, commits bounded retention ACKs, and audits unchanged
revision sweeps. This is a pagination/identity gate, NOT full normalized-content
or app-rendering equivalence. Reports contain counts, timings and error codes;
no session IDs, prompts, paths, or normalized records are written to the report.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import time

from native_first_page import Guard, clone, receive, wire, connect_started_service, now_ns
from normalization_corpus import coverage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--snapshot', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]):
        parser.error('private output must be outside Git')
    os.umask(0o077); output.mkdir(mode=0o700)
    measured_binary = output / 'measured-helper'
    clone(args.binary.resolve(), measured_binary); measured_binary.chmod(0o700)
    home = output / 'codex'; home.mkdir(mode=0o700)
    for name in ('state_5.sqlite', 'thread_history_1.sqlite'):
        clone(args.snapshot / name, home / name)
    with sqlite3.connect(home / 'state_5.sqlite') as state:
        # Re-sanitize this new clone even when the input was already a private
        # probe: an upstream read server may have recreated local enrollment
        # metadata. Never copy authentication/configuration or start the child
        # while a copied enrollment remains.
        state.execute('DELETE FROM remote_control_enrollments'); state.commit()
        modes = dict(state.execute('SELECT id,history_mode FROM threads'))
    database = sqlite3.connect((home / 'thread_history_1.sqlite').as_uri() + '?mode=ro', uri=True)
    counts = list(database.execute('SELECT thread_id,count(*) FROM thread_items GROUP BY thread_id ORDER BY count(*) DESC'))
    runtime = output / 'r'; stream = None; guard = None
    launch_ns = now_ns()
    process = subprocess.Popen([str(measured_binary), 'serve', '--runtime', str(runtime), '--lease-ms', '30000'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        env=dict(os.environ, CODEX_HOME=str(home), CLAUDE_CONFIG_DIR=str(output / 'empty-claude')))
    results = []; started = time.monotonic(); request_number = 0; gate_errors = []
    discovery = dict(threads=0, fallback_reasons=[])

    def send(fields):
        nonlocal request_number
        request_number += 1
        fields = dict(fields, id=f'corpus_{request_number}')
        stream.sendall(wire(fields)); return fields['id']

    def one(fields):
        identifier = send(fields); value, _ = receive(stream)
        if value.get('id') != identifier: raise RuntimeError('responseIDMismatch')
        if value['kind'] == 'error': raise RuntimeError(value.get('code', 'unknown'))
        return value

    def page(thread, operation, version, cursor=None):
        identifier = send(dict(kind='window.read', thread=thread, operation=operation,
            windowVersion=version, **({'cursor': cursor} if cursor else {})))
        records = []; total = 0
        while True:
            value, raw = receive(stream); total += len(raw)
            if total > 262144 or value.get('id') != identifier: raise RuntimeError('pageEnvelopeInvalid')
            if value['kind'] == 'error': raise RuntimeError(value.get('code', 'unknown'))
            if value['kind'] == 'page.record': records.append(value)
            if value['kind'] == 'page.end': return records, value

    def checkpoint():
        evidence = dict(stage='native_window_identity_order_and_type_not_content_equivalence',
            binary_sha256=hashlib.sha256(measured_binary.read_bytes()).hexdigest(), stored_threads=len(counts),
            tested_threads=len(results), matched_threads=sum(row.get('matched', False) for row in results),
            failed_threads=sum('error' in row for row in results),
            coverage_failed_threads=sum(bool(row.get('coverage_issues')) for row in results),
            skipped_non_paginated=sum(row.get('skipped_non_paginated', False) for row in results),
            elapsed_seconds=round(time.monotonic() - started, 3), sampled_tree_peak_bytes=guard.peak if guard else 0,
            discovery=discovery, results=results, gate_errors=gate_errors)
        temporary = output / 'content-free-results.pending'
        temporary.write_text(json.dumps(evidence, indent=2)); os.replace(temporary, output / 'content-free-results.json')
        return evidence

    try:
        guard = Guard(process)
        stream = connect_started_service(process, str(runtime / 'client.sock'), launch_ns)
        one(dict(kind='hello', v=3))
        cursor = None; seen = set()
        while True:
            identifier = send(dict(kind='inventory', **({'cursor': cursor} if cursor else {})))
            while True:
                value, _ = receive(stream)
                if value.get('id') != identifier: raise RuntimeError('inventoryResponseIDMismatch')
                if value['kind'] == 'error': raise RuntimeError(value.get('code', 'inventoryFailed'))
                if value['kind'] == 'inventory.thread': discovery['threads'] += 1
                if value['kind'] == 'inventory.end': break
            if value.get('fallbackReason'): discovery['fallback_reasons'].append(value['fallbackReason'])
            if not value['hasMore']: break
            cursor = value['cursor']
            if cursor in seen or len(seen) >= 164: raise RuntimeError('inventoryCursorDidNotAdvance')
            seen.add(cursor)
        checkpoint()
        if discovery['threads'] < len(counts): raise RuntimeError('nativeInventoryIncomplete')
        for ordinal, (session, count) in enumerate(counts):
            row = dict(ordinal=ordinal, expected_items=count)
            if modes.get(session) != 'paginated':
                row['skipped_non_paginated'] = True; results.append(row); checkpoint(); continue
            thread = None; pending = None; began = time.monotonic()
            try:
                one(dict(kind='heartbeat'))
                resolved = one(dict(kind='resolve', provider='codex', nativeSessionID=session)); thread = resolved['thread']
                expected = list(database.execute('SELECT item_id,item_type FROM thread_items WHERE thread_id=? ORDER BY rollout_ordinal', (session,)))
                position = len(expected); viewport = []; retained = []; head = None; version = 0; cursor = None
                pages = 0; types = collections.Counter(); issues = collections.Counter()
                while True:
                    if time.monotonic() - began > 120: raise RuntimeError('threadDeadline')
                    one(dict(kind='heartbeat'))
                    records, end = page(thread, 'bootstrap' if not pages else 'before', version, cursor); pending = end['id']
                    for record in records: issues.update(coverage(record))
                    actual = [(record['recordID'], record.get('sourceType', '').removeprefix('app-server/')) for record in records]
                    if not actual or len(actual) > position or actual != expected[position-len(actual):position]:
                        raise RuntimeError('nativeOrderOrTypeMismatch')
                    for _, kind in actual: types[kind] += 1
                    position -= len(actual); pages += 1; descriptor = end['window']; version = descriptor['version']
                    cursor = descriptor['before']; viewport.insert(0, descriptor['segmentID']); viewport = viewport[:4]
                    retained.insert(0, (descriptor, position + len(actual))); retained = retained[:4]
                    if head is None: head = descriptor['segmentID']; live = end['liveCursor']
                    one(dict(kind='window.ack', thread=thread, transaction=pending, windowVersion=version, viewport=viewport, head=head)); pending = None
                    if not descriptor['hasOlder']: break
                if position: raise RuntimeError('nativeHistoryPrematureEnd')
                for sweep in range(32):
                    records, end = page(thread, 'head', version, live); pending = end['id']
                    if records: raise RuntimeError('finiteStoreUnexpectedRevision')
                    version = end['window']['version']
                    one(dict(kind='window.ack', thread=thread, transaction=pending, windowVersion=version, viewport=viewport, head=head)); pending = None
                    if not end['hasNewer']: break
                else: raise RuntimeError('revisionSweepDidNotFinish')
                # Walk back toward the live head from the current oldest
                # retained viewport, not a transcript-wide ID cache.
                forward_offset = retained[-1][1]; forward_pages = 0
                cursor = retained[-1][0]['after']
                while forward_offset < len(expected):
                    if time.monotonic() - began > 120: raise RuntimeError('threadDeadline')
                    one(dict(kind='heartbeat'))
                    records, end = page(thread, 'after', version, cursor); pending = end['id']
                    actual = [(record['recordID'], record.get('sourceType', '').removeprefix('app-server/')) for record in records]
                    if not actual or actual != expected[forward_offset:forward_offset+len(actual)]:
                        raise RuntimeError('nativeForwardOrderOrTypeMismatch')
                    forward_offset += len(actual); forward_pages += 1
                    descriptor = end['window']; version = descriptor['version']; cursor = descriptor['after']
                    viewport.append(descriptor['segmentID']); viewport = viewport[-4:]
                    one(dict(kind='window.ack', thread=thread, transaction=pending, windowVersion=version, viewport=viewport, head=head)); pending = None
                row.update(matched=not bool(issues), identity_matched=True, coverage_issues=dict(issues),
                    pages=pages, forward_pages=forward_pages, types=dict(types), unchanged_slices=sweep+1)
            except Exception as error:
                row['error'] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
            finally:
                if thread:
                    try:
                        if pending: one(dict(kind='window.cancel', thread=thread, transaction=pending))
                        one(dict(kind='window.release', thread=thread))
                    except Exception:
                        row['cleanup_error'] = True
                        row['error'] = row.get('error', 'windowCleanupFailed')
                        row['matched'] = False
                row['wall_ms'] = round((time.monotonic() - began) * 1000, 3)
                results.append(row); checkpoint()
            if ordinal % 25 == 0: print(json.dumps(dict(tested=len(results), failures=sum('error' in value for value in results))), flush=True)
            if process.poll() is not None or guard.failure: raise RuntimeError(guard.failure or 'serviceExited')
    except Exception as error:
        gate_errors.append(str(error) if isinstance(error, RuntimeError) else type(error).__name__)
    finally:
        if stream: stream.close()
        if guard: guard.signal_owned(signal.SIGTERM)
        if process.poll() is None: process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            if guard: guard.signal_owned(signal.SIGKILL)
            os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=3)
        if guard:
            guard.signal_owned(signal.SIGKILL)
            guard.close()
            if guard.failure: gate_errors.append(guard.failure)
        database.close()
        final = checkpoint()
    print(json.dumps({key: final[key] for key in ('tested_threads', 'matched_threads', 'failed_threads', 'skipped_non_paginated', 'sampled_tree_peak_bytes', 'gate_errors')}))
    if final['failed_threads'] or final['coverage_failed_threads'] or gate_errors or len(results) != len(counts): raise SystemExit(1)


if __name__ == '__main__': main()
