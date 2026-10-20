#!/usr/bin/env python3
"""Selected bounded Core items versus ACTUAL upstream conversion, no bodies logged.

This proves conversion on the native reader's bounded input, not unbounded
source equality, history lineage or legacy selection. The upstream binary and
its source/build provenance must come from build_codex_history_oracle.py.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import time
from codex_completed_projection_corpus import line, write_frame
from native_first_page import Guard, clone
from normalization_corpus import coverage, safe_type
from codex_private_materialization_probe import copy_database_snapshot


def rpc(process, value, maximum=8 * 1024 * 1024):
    raw = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    if len(raw) > 4 * 1024 * 1024: raise RuntimeError('oracle_request_budget')
    deadline = time.monotonic() + 30
    write_frame(process, [str(len(raw)).encode() + b'\n', raw], deadline)
    return line(process, maximum=maximum, deadline=deadline, allow_error=True)


def native_extension(item, database, public):
    """Exact same-revision reference for two installed-schema additions.

    No invented upstream conversion, stripping unknown fields or fuzzy body
    comparison: these rows must match the independently captured native store.
    """
    core = item['coreItem']
    extension = core.get('type') == 'SubAgentActivity' and core.get('kind') == 'completed' or (
        core.get('type') == 'AgentMessage' and isinstance(core.get('questions'), list) and bool(core['questions']))
    if not extension: return None
    row = database.execute('SELECT rowid, updated_at_ordinal, length(CAST(item_json AS BLOB)) FROM thread_items '
        'WHERE thread_id=? AND turn_id=? AND item_id=?', (item['owner'], item['turn'], item['itemID'])).fetchone()
    if row is None: return 'extension_missing_native_reference'
    rowid, updated, length = row
    if updated != item['ordinal']: return 'extension_reference_revision_mismatch'
    if not 0 < length < 4 * 1024 * 1024 - 1024: return 'extension_reference_budget'
    with database.blobopen('thread_items', 'item_json', rowid, readonly=True) as blob:
        if len(blob) != length: raise RuntimeError('extension_reference_changed')
        reference = json.loads(blob.read(length))
    converted = rpc(public, dict(turn=item['turn'], item=reference, sourceTruncated=item['sourceTruncated']), maximum=262144)
    if coverage(converted): return 'extension_reference_coverage_failure'
    return 'exact_native_schema_extension' if converted['record'] == item['projection'] else 'extension_projection_difference'


def audit(driver, source, oracle, public, database=None):
    counts = collections.Counter(); types = collections.defaultdict(collections.Counter)
    reported_peak = 0
    with subprocess.Popen([str(driver), '--selected-source', str(source)], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True) as selected:
        guard = Guard(selected)
        try:
            while True:
                row = line(selected, maximum=2 * 1024 * 1024)
                if row.get('complete'):
                    if selected.wait(timeout=5) or row['sourceEnd'] != source.stat().st_size: raise RuntimeError('source_completion')
                    reported_peak = row['peakRSSBytes']
                    if not isinstance(reported_peak, int) or not 0 < reported_peak <= 256 * 1024 * 1024:
                        raise RuntimeError('selected_memory_budget')
                    if not row['paginated']: counts['legacy_separate_oracle_required'] += 1
                    break
                item = row['record']; kind = safe_type(row['sourceType'])
                if coverage(dict(row, record=item['projection'])): outcome = 'source_coverage_failure'
                else:
                    upstream = rpc(oracle, dict(operation='core', item=item['coreItem']))
                    if 'error' in upstream: outcome = 'upstream_core_shape_failure'
                    else:
                        converted = rpc(public, dict(turn=item['turn'], item=upstream['item'], sourceTruncated=item['sourceTruncated']), maximum=262144)
                        if coverage(converted): outcome = 'reference_coverage_failure'
                        else: outcome = 'exact_bounded_projection' if item['projection'] == converted['record'] else 'projection_difference'
                    if database is not None and outcome in ('upstream_core_shape_failure', 'projection_difference'):
                        outcome = native_extension(item, database, public) or outcome
                counts[outcome] += 1; types[kind][outcome] += 1
        finally:
            guard.close()
            if selected.poll() is None: selected.kill(); selected.wait(timeout=5)
        # A tiny finite worker can exit between ps samples. Its own getrusage
        # still measures its lifetime peak; never excuse failed ps access.
        if guard.failure and not (guard.failure == 'rss_guard_incomplete' and reported_peak and not guard.thread.is_alive()):
            raise RuntimeError(guard.failure)
        return dict(counts=counts, types=types, worker_peak_bytes=max(guard.peak, reported_peak))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('driver', 'public-driver', 'oracle', 'oracle-evidence', 'manifest', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--native-db', type=Path, help='Finite native store for installed-schema additions only')
    parser.add_argument('--schema', type=Path, help='Installed App Server schema; required with native-db')
    args = parser.parse_args(); output = args.output.resolve()
    if bool(args.native_db) != bool(args.schema): parser.error('native-db and schema are required together')
    if any((parent / '.git').exists() for parent in [output, *output.parents]): parser.error('private output must be outside Git')
    os.umask(0o077); output.mkdir(mode=0o700, parents=True, exist_ok=False)
    binaries = {}
    for name, source in [('driver', args.driver), ('public', args.public_driver), ('oracle', args.oracle)]:
        binaries[name] = output / name; clone(source, binaries[name]); binaries[name].chmod(0o700)
    evidence = json.loads(args.oracle_evidence.read_text())
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()}
    if hashes['oracle'] != evidence['executable_sha256']: raise RuntimeError('oracle_provenance_mismatch')
    database = None
    if args.native_db:
        schema_bytes = args.schema.read_bytes(); schema = json.loads(schema_bytes)['definitions']['v2']
        if 'completed' not in schema['SubAgentActivityKind']['enum']: raise RuntimeError('schema_missing_completed_activity')
        agents = [row for row in schema['ThreadItem']['oneOf'] if row.get('properties', {}).get('type', {}).get('enum') == ['agentMessage']]
        if len(agents) != 1 or 'questions' not in agents[0]['properties']: raise RuntimeError('schema_missing_questions')
        clone(args.schema, output / 'installed-schema.json'); hashes['installed_schema'] = hashlib.sha256(schema_bytes).hexdigest()
        # A terminated private native reader may leave committed rows in WAL.
        # Include the stable complete snapshot and recover only the new copy.
        copy_database_snapshot(args.native_db, output / 'native.sqlite')
        digest = hashlib.sha256()
        with (output / 'native.sqlite').open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
        hashes['native_database'] = digest.hexdigest()
        database = sqlite3.connect('file:' + str(output / 'native.sqlite') + '?mode=ro', uri=True)
    manifest_bytes = args.manifest.read_bytes()
    candidates = json.loads(manifest_bytes)['candidates']
    expected = sum(row['provider'] == 'codex' for row in candidates)
    script_hashes = {}
    for name in ('upstream_core_corpus.py', 'codex_completed_projection_corpus.py', 'native_first_page.py',
                 'normalization_corpus.py', 'normalization_schema.py', 'transcript_layout.py',
                 'codex_private_materialization_probe.py'):
        source = Path(__file__).with_name(name); clone(source, output / name)
        script_hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    results = []; totals = collections.Counter(); resource_errors = []; peaks = []
    def checkpoint():
        report = dict(stage='primary_upstream_conversion_of_bounded_selected_input_not_legacy_or_full_source',
            hashes=hashes, scripts=script_hashes, manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
            upstream=evidence, expected_files=expected, files=len(results), processing_failures=sum('error' in row for row in results),
            counts=totals, results=results, resource_errors=resource_errors, oracle_and_public_worker_peak_bytes=peaks)
        report['status'] = 'failed' if len(results) != expected or report['processing_failures'] or resource_errors or not totals or any(
            count for key, count in totals.items() if key not in ('exact_bounded_projection', 'exact_native_schema_extension')) else 'passed_scoped_checks'
        pending = output / 'results.pending'; pending.write_text(json.dumps(report, indent=2) + '\n')
        os.replace(pending, output / 'content-free-results.json')
        return report
    with subprocess.Popen([str(binaries['oracle'])], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True) as oracle, \
         subprocess.Popen([str(binaries['public']), '--public-projected-items'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True) as public:
        guards = [Guard(oracle), Guard(public)]
        try:
            for ordinal, candidate in enumerate(candidates):
                if candidate['provider'] != 'codex': continue
                try: result = audit(binaries['driver'], Path(candidate['path']), oracle, public, database)
                except Exception as error: result = dict(error=str(error) if isinstance(error, RuntimeError) else type(error).__name__)
                results.append(dict(ordinal=ordinal, **result)); totals.update(result.get('counts', {})); checkpoint()
                if len(results) % 25 == 0: print(json.dumps(dict(files=len(results), counts=totals)), flush=True)
                if any(guard.failure for guard in guards): raise RuntimeError('oracle_memory_guard')
                if oracle.poll() is not None or public.poll() is not None: raise RuntimeError('oracle_worker_exit')
            for process in (oracle, public):
                process.stdin.close()
                if process.wait(timeout=5): raise RuntimeError('oracle_worker_exit')
        except Exception as error:
            resource_errors.append(str(error) if isinstance(error, RuntimeError) else type(error).__name__)
        finally:
            for guard in guards: guard.close()
            resource_errors.extend(guard.failure for guard in guards if guard.failure)
            peaks.extend(guard.peak for guard in guards)
            for process in (oracle, public):
                if process.poll() is None: process.kill(); process.wait(timeout=5)
            if database is not None: database.close()
    report = checkpoint()
    return int(report['status'] != 'passed_scoped_checks')


if __name__ == '__main__': raise SystemExit(main())
