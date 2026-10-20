#!/usr/bin/env python3
"""Private paginated history identity/order/revision differential; no bodies."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
from codex_completed_projection_corpus import line
from native_first_page import clone
from codex_private_materialization_probe import copy_database_snapshot


def validate_reference(database):
    # Fail before scanning the corpus when given the discovery/state database.
    try:
        database.execute('SELECT thread_id,turn_id,item_id,rollout_ordinal,updated_at_ordinal FROM thread_items LIMIT 0')
        database.execute('SELECT thread_id,next_rollout_ordinal FROM thread_history_projection_state LIMIT 0')
    except sqlite3.OperationalError as error:
        raise RuntimeError('expected_thread_history_database') from error


def validate_completion(row, emitted):
    if row.get('complete') is not True or type(row.get('paginated')) is not bool or type(row.get('records')) is not int or row['records'] < 0:
        raise RuntimeError('invalid_completion')
    if type(row.get('peakRSSBytes')) is not int or not 0 < row['peakRSSBytes'] <= 256 * 1024 * 1024:
        raise RuntimeError('history_worker_memory_evidence')
    if type(row.get('indexBytes')) is not int or not 0 <= row['indexBytes'] <= 8 * 1024 * 1024:
        raise RuntimeError('history_worker_index_budget')
    if type(row.get('bytesRead')) is not int or row['bytesRead'] < 0:
        raise RuntimeError('invalid_read_counter')
    # The default driver emits only paginated identities; legacy selection is
    # covered by separate content/replay lanes, never by this native-store lane.
    expected = row['records'] if row['paginated'] else 0
    if emitted != expected: raise RuntimeError('record_count_mismatch')


def audit(driver, path, database):
    counts = collections.Counter(); records = 0; last_order = None
    before = path.stat()
    with subprocess.Popen([str(driver), str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0) as worker:
        try:
            while True:
                row = line(worker)
                if row.get('complete'):
                    if worker.wait(timeout=5): raise RuntimeError('worker_exit')
                    validate_completion(row, records)
                    after = path.stat()
                    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) or type(row.get('sourceEnd')) is not int or row['sourceEnd'] != before.st_size:
                        raise RuntimeError('finite_source_boundary_changed')
                    if row['paginated']:
                        native_count = database.execute('SELECT count(*) FROM thread_items WHERE thread_id=?', (row['thread'],)).fetchone()[0]
                        if native_count != records:
                            counts['native_count_difference'] += 1
                            # The transcript and native-store backups have
                            # separate finite boundaries. Do not mislabel newer
                            # native identities as missing selected history.
                            newer = database.execute('SELECT count(*) FROM thread_items WHERE thread_id=? AND rollout_ordinal>?',
                                (row['thread'], last_order if last_order is not None else -1)).fetchone()[0]
                            counts['native_items_after_selected_tail'] += newer
                            if native_count - newer != records:
                                counts['native_count_within_selected_range_difference'] += 1
                    return dict(counts=counts, records=records, selected_records=row['records'], paginated=row['paginated'],
                                index_bytes=row['indexBytes'], peak_rss_bytes=row['peakRSSBytes'], bytes_read=row['bytesRead'])
                records += 1
                order = row['ordinal']
                if last_order is not None and order <= last_order: raise RuntimeError('index_order_invalid')
                last_order = order
                native = database.execute('SELECT rollout_ordinal,updated_at_ordinal FROM thread_items WHERE thread_id=? AND turn_id=? AND item_id=?',
                                          (row['thread'], row['turn'], row['id'])).fetchone()
                if native is None:
                    counts['missing_native_reference'] += 1
                    watermark = database.execute('SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id=?', (row['thread'],)).fetchone()
                    if watermark is not None and order >= watermark[0]: counts['missing_after_reference_watermark'] += 1
                else:
                    counts['matched_identity'] += 1
                    if native[0] != order: counts['creation_order_difference'] += 1
                    if native[1] != row['updatedOrdinal']: counts['revision_order_difference'] += 1
        finally:
            if worker.poll() is None: worker.kill(); worker.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ('driver', 'manifest', 'native-db', 'output'): parser.add_argument('--' + field, type=Path, required=True)
    args = parser.parse_args(); args.output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [args.output, *args.output.parents]): parser.error('private output must be outside Git')
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest_bytes = args.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)['candidates']; results = []; counts = collections.Counter()
    with tempfile.TemporaryDirectory(prefix='history-', dir=args.output) as temporary:
        private = Path(temporary); driver = private / 'driver'; clone(args.driver, driver); driver.chmod(0o700)
        digest = hashlib.sha256(driver.read_bytes()).hexdigest()
        copy_database_snapshot(args.native_db, private / 'reference.sqlite')
        with (private / 'reference.sqlite').open('rb') as source:
            reference_digest = hashlib.file_digest(source, 'sha256').hexdigest()
        database = sqlite3.connect('file:' + str(private / 'reference.sqlite') + '?mode=ro', uri=True)
        try:
            validate_reference(database)
            for ordinal, source in enumerate(manifest):
                if source['provider'] != 'codex': continue
                try: result = audit(driver, Path(source['path']), database)
                except Exception as error: result = dict(error=str(error) if isinstance(error, RuntimeError) else type(error).__name__)
                results.append(dict(ordinal=ordinal, **result)); counts.update(result.get('counts', {}))
                if len(results) % 25 == 0: print(json.dumps(dict(files=len(results), counts=counts)), flush=True)
        finally: database.close()
    failures = sum('error' in row for row in results)
    report = dict(stage='paginated_identity_order_revision_not_content', driver_sha256=digest,
                  reference_sha256=reference_digest, manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
                  audit_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  status='failed' if failures or any(value for key, value in counts.items() if key != 'matched_identity') or not counts else 'passed_scoped_checks',
                  files=len(results), processing_failures=failures, counts=counts,
                  resource_failures=sum(row.get('error', '').startswith('history_worker_') for row in results),
                  legacy_files_not_compared=sum(row.get('paginated') is False for row in results),
                  paginated_files_compared=sum(row.get('paginated') is True for row in results),
                  max_index_bytes=max((row.get('index_bytes', 0) for row in results), default=0),
                  max_worker_rss_bytes=max((row.get('peak_rss_bytes', 0) for row in results), default=0), results=results)
    (args.output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'results'}))
    return int(report['status'] == 'failed')


if __name__ == '__main__': raise SystemExit(main())
