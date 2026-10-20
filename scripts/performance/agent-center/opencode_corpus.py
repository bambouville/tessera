#!/usr/bin/env python3
"""Finite OpenCode store: all-session ordered identity and output taxonomy gate.

Input must be a completed private SQLite backup, never the live provider DB.
No body or session identity appears in the content-free result. This is not
independent full-payload equivalence or live SSE/provider-control testing.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
from codex_completed_projection_corpus import line, write_frame
from codex_private_materialization_probe import copy_database_snapshot
from native_first_page import clone
from native_paint import SamplingOnlyGuard
from normalization_corpus import coverage, worker_memory
import time


def file_sha256(path):
    with path.open('rb') as source: return hashlib.file_digest(source, 'sha256').hexdigest()


def expected_keys(database, session):
    modern = database.execute("SELECT 1 FROM sqlite_schema WHERE type='table' AND name='session_message'").fetchone()
    if modern and database.execute('SELECT 1 FROM session_message WHERE session_id=? LIMIT 1', (session,)).fetchone():
        yield from database.execute("SELECT seq,'',id FROM session_message WHERE session_id=? ORDER BY seq,id", (session,))
        return
    for message, created in database.execute('SELECT id,time_created FROM message WHERE session_id=? ORDER BY time_created,id', (session,)):
        yield created, message, message
        for part, in database.execute('SELECT id FROM part WHERE session_id=? AND message_id=? ORDER BY id', (session, message)):
            yield created, message, part


def audit_session(worker, database, session):
    expected = iter(expected_keys(database, session))
    boundary = {}; total = 0; issues = collections.Counter(); types = collections.Counter()
    identity = None; peak = 0
    for _ in range(100000):
        request = dict(operation='page', session=session, forward=True, **boundary)
        deadline = time.monotonic() + 30
        write_frame(worker, [(json.dumps(request) + '\n').encode()], deadline)
        response = line(worker, maximum=4 * 1024 * 1024, deadline=deadline)
        memory = response.get('peakRSSBytes')
        if type(memory) is not int or not 0 < memory <= 256 * 1024 * 1024:
            raise RuntimeError('worker_peak_invalid_or_over_budget')
        peak = max(peak, memory)
        if identity is not None and response.get('identity') != identity: raise RuntimeError('source_identity_changed')
        identity = response['identity']
        rows = response['rows']
        if not isinstance(rows, list) or len(rows) > 10: raise RuntimeError('page_budget')
        for row in rows:
            actual = row['created'], row['message'], row['id']
            if next(expected, None) != actual: raise RuntimeError('selected_identity_order_mismatch')
            record = row['record']; total += 1
            issues.update(coverage(dict(record=record, disposition=row['disposition'])))
            kind = record.get('type')
            types[kind if kind in ('message', 'metadata', 'usage', 'state', 'unknown') else '<other>'] += 1
        if not rows:
            if next(expected, None) is not None: raise RuntimeError('selected_history_incomplete')
            return dict(records=total, coverage_issues=dict(issues), output_types=dict(types), worker_lifetime_peak_bytes=peak)
        last = rows[-1]
        boundary = dict(created=last['created'], message=last['message'], id=last['id'])
    raise RuntimeError('reference_record_budget')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('snapshot', 'driver', 'output'): parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args(); args.output = args.output.resolve(); source = args.snapshot.resolve(strict=True)
    if not str(source).startswith('/private/tmp/tessera-'): parser.error('use a finite owned private backup')
    if any((parent / '.git').exists() for parent in (args.output, *args.output.parents)): parser.error('private output must be outside Git')
    os.umask(0o077); args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    snapshot = args.output / 'measured.sqlite'; copy_database_snapshot(source, snapshot)
    driver = args.output / 'measured-driver'; clone(args.driver.resolve(strict=True), driver); driver.chmod(0o700)
    results = []; issues = collections.Counter()
    with sqlite3.connect(snapshot.as_uri() + '?mode=ro', uri=True) as database:
        database.execute('PRAGMA cache_size=-2048')
        sessions = database.execute('SELECT id FROM session ORDER BY id LIMIT 16385').fetchall()
        if not 0 < len(sessions) <= 16384: raise RuntimeError('reference_session_budget')
        with subprocess.Popen([str(driver), str(snapshot)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, bufsize=0) as worker:
            guard = SamplingOnlyGuard(worker)
            try:
                for ordinal, (session,) in enumerate(sessions):
                    try: row = audit_session(worker, database, session)
                    except Exception as error:
                        row = dict(error=str(error) if isinstance(error, RuntimeError) else type(error).__name__)
                    results.append(dict(ordinal=ordinal, **row)); issues.update(row.get('coverage_issues', {}))
                    if 'error' in row: break # Worker stream is no longer correlated.
            finally:
                worker.stdin.close()
                try: worker.wait(timeout=5)
                except subprocess.TimeoutExpired: worker.kill(); worker.wait(timeout=5)
                guard.close()
    failed = sum('error' in row for row in results)
    try:
        measured_peak = worker_memory(max((row.get('worker_lifetime_peak_bytes', 0) for row in results), default=0), guard)
        resource_error = None
    except RuntimeError as error:
        measured_peak = None; resource_error = str(error)
    report = dict(stage='all_session_ordered_identity_and_normalized_taxonomy_not_full_payload',
        sessions=len(sessions), processed_sessions=len(results), failed_sessions=failed,
        records=sum(row.get('records', 0) for row in results), coverage_issues=dict(issues),
        worker_peak_sampled_bytes=guard.peak, worker_peak_bytes=measured_peak,
        worker_samples=guard.samples, worker_resource_error=resource_error,
        driver_sha256=file_sha256(driver), snapshot_sha256=file_sha256(snapshot), results=results)
    report['status'] = 'passed_scoped_checks' if not failed and len(results) == len(sessions) and not issues and resource_error is None and worker.returncode == 0 else 'failed'
    (args.output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'results'}))
    return int(report['status'] != 'passed_scoped_checks')


if __name__ == '__main__': raise SystemExit(main())
