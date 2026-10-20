#!/usr/bin/env python3
"""Legacy selection versus actual upstream authored messages, not full replay parity.

Reasoning, tool displays, metadata, receipts and relationships require their
separate gates. Only content-free counts/hashes are written to this report.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import subprocess
from codex_completed_projection_corpus import line
from native_first_page import Guard, clone
from normalization_corpus import coverage, safe_type
from normalization_schema import source_shape_issues
from upstream_core_corpus import rpc


def signature(record):
    view = {key: record.get(key, False) for key in ('isMeta', 'isSidechain', 'isCompactSummary')}
    view.update(role=record['role'], blocks=record['blocks'])
    return hashlib.sha256(json.dumps(view, sort_keys=True, ensure_ascii=False).encode()).digest()


def stop(process):
    if process.poll() is None: process.kill(); process.wait(timeout=5)


def audit(path, binaries):
    actual = []; expected = collections.OrderedDict(); issues = collections.Counter()
    shape_errors = collections.Counter(); metadata_gaps = collections.Counter(); resources = []; peaks = []
    with subprocess.Popen([str(binaries['history']), '--legacy-items', str(path)], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True) as selected:
        guard = Guard(selected); summary = None
        try:
            while True:
                row = line(selected)
                if row.get('complete'):
                    summary = row
                    if row['sourceEnd'] != path.stat().st_size or row['paginated'] or selected.wait(timeout=5):
                        raise RuntimeError('legacy_selection_completion')
                    break
                record = row['record']['projection']; issues.update(coverage(dict(row, record=record)))
                if row['sourceType'] in ('response_item/message', 'event_msg/user_message', 'event_msg/agent_message') and record.get('role') in ('user', 'assistant') and row['visible']:
                    actual.append(signature(record))
                    if len(actual) > 20000: raise RuntimeError('authored_reference_capacity')
        finally:
            guard.close(); stop(selected)
        peak = summary['peakRSSBytes']
        if not isinstance(peak, int) or not 0 < peak <= 256 * 1024 * 1024: raise RuntimeError('selected_memory_budget')
        if guard.failure and not (guard.failure == 'rss_guard_incomplete' and not guard.thread.is_alive()): resources.append(guard.failure)
        peaks.append(max(peak, guard.peak))
    with subprocess.Popen([str(binaries['oracle'])], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True) as oracle, \
         subprocess.Popen([str(binaries['driver']), '--bounded-codex-source', str(path)], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True) as source, \
         subprocess.Popen([str(binaries['driver']), '--public-projected-items'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True) as public:
        guards = [Guard(process) for process in (oracle, source, public)]
        try:
            while True:
                row = line(source, maximum=2 * 1024 * 1024)
                if row.get('complete'):
                    if row['sourceEnd'] != path.stat().st_size: raise RuntimeError('legacy_source_completion')
                    break
                envelope = row['record']; item = envelope['source']
                changes = rpc(oracle, dict(operation='legacy', item=item))
                if 'error' in changes:
                    kind = safe_type(row['sourceType'])
                    # Pinned current metadata is outside the older upstream
                    # RolloutItem union. Validate it; do not blanket-ignore
                    # unknown message/content types to green this gate.
                    if kind == 'token_usage_record' and not source_shape_issues(item, 'codex'):
                        metadata_gaps[kind] += 1
                    else: shape_errors[kind] += 1
                    continue
                for turn in changes['removedTurns']:
                    for key in list(expected):
                        if key[0] == turn: del expected[key]
                for change in changes['items']:
                    if change['item']['type'] not in ('userMessage', 'agentMessage'): continue
                    key = (change['turn'], change['item']['id'])
                    if any(not isinstance(value, str) or not 0 < len(value.encode()) <= 256 for value in key):
                        raise RuntimeError('reference_identity_budget')
                    converted = rpc(public, dict(turn=change['turn'], item=change['item'], sourceTruncated=envelope['sourceTruncated']), maximum=262144)
                    issues.update(coverage(converted)); expected[key] = signature(converted['record'])
                    if len(expected) > 20000: raise RuntimeError('authored_reference_capacity')
            oracle.stdin.close(); public.stdin.close()
            for process in (oracle, source, public):
                if process.wait(timeout=5): raise RuntimeError('reference_worker_exit')
        finally:
            for guard in guards: guard.close()
            for process in (oracle, source, public): stop(process)
        resources.extend(guard.failure for guard in guards if guard.failure); peaks.extend(guard.peak for guard in guards)
    return dict(selected_records=summary['records'], mirrored_records=summary['mirroredRecords'], index_bytes=summary['indexBytes'],
        authored_selected=len(actual), authored_upstream=len(expected), exact_authored_order_and_blocks=actual == list(expected.values()),
        coverage=issues, upstream_shape_errors=shape_errors, validated_metadata_outside_upstream_union=metadata_gaps,
        worker_peak_bytes=peaks, resource_errors=resources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('manifest', 'selection-report', 'history-driver', 'driver', 'oracle', 'oracle-evidence', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args(); output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]): parser.error('private output must be outside Git')
    manifest_bytes = args.manifest.read_bytes(); manifest_hash = hashlib.sha256(manifest_bytes).hexdigest()
    manifest = json.loads(manifest_bytes)['candidates']; selection = json.loads(args.selection_report.read_text())
    if selection['manifest_sha256'] != manifest_hash or selection['files'] != selection['expected_files']:
        parser.error('complete selection report for this exact manifest required')
    ordinals = [row['ordinal'] for row in selection['results'] if row.get('counts', {}).get('legacy_separate_oracle_required') == 1]
    if not ordinals or len(ordinals) != len(set(ordinals)) or any(manifest[i]['provider'] != 'codex' for i in ordinals):
        parser.error('invalid legacy selection')
    os.umask(0o077); output.mkdir(mode=0o700, parents=True, exist_ok=False)
    binaries = {}; hashes = {}
    for name, source in [('history', args.history_driver), ('driver', args.driver), ('oracle', args.oracle)]:
        binaries[name] = output / name; clone(source, binaries[name]); binaries[name].chmod(0o700)
        hashes[name] = hashlib.sha256(binaries[name].read_bytes()).hexdigest()
    evidence = json.loads(args.oracle_evidence.read_text())
    if hashes['oracle'] != evidence['executable_sha256']: raise RuntimeError('oracle_provenance_mismatch')
    scripts = {}
    for name in ('legacy_authored_corpus.py', 'upstream_core_corpus.py', 'codex_completed_projection_corpus.py',
                 'native_first_page.py', 'normalization_corpus.py', 'normalization_schema.py', 'transcript_layout.py',
                 'codex_private_materialization_probe.py'):
        source = Path(__file__).with_name(name); clone(source, output / name); scripts[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    results = []
    for ordinal in ordinals:
        try: result = audit(Path(manifest[ordinal]['path']), binaries)
        except Exception as error: result = dict(error=str(error) if isinstance(error, RuntimeError) else type(error).__name__)
        results.append(dict(ordinal=ordinal, **result))
        report = dict(stage='legacy_authored_selection_not_full_replay_parity', manifest_sha256=manifest_hash,
            selection_sha256=hashlib.sha256(args.selection_report.read_bytes()).hexdigest(), hashes=hashes, scripts=scripts,
            upstream=evidence, files=len(results), expected_files=len(ordinals), results=results)
        report['status'] = 'passed_scoped_checks' if len(results) == len(ordinals) and all(
            row.get('exact_authored_order_and_blocks') and not any(row.get(key) for key in
                ('error', 'coverage', 'upstream_shape_errors', 'resource_errors')) for row in results) else 'failed'
        pending = output / 'results.pending'; pending.write_text(json.dumps(report, indent=2) + '\n')
        os.replace(pending, output / 'content-free-results.json')
        print(json.dumps(dict(files=len(results), status=report['status'])), flush=True)
    return int(report['status'] != 'passed_scoped_checks')


if __name__ == '__main__': raise SystemExit(main())
