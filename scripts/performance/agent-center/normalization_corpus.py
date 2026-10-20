#!/usr/bin/env python3
"""Streaming private-corpus visible-payload differential, not a full semantic gate.

Compares every physical JSONL record against the existing independent Python
projector. Independently fails on unknown/unsupported/malformed native records
and blocks, even when the old parser has the same defect. SDK chain selection,
tool relationships, live replay and
native UI remain separate required gates. No transcript contents are reported.
Unexplained differences and old-reference limitations are not green results.
"""
import argparse
import ast
import collections
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import select
import signal
import subprocess
import sys
import time
from native_first_page import Guard, clone
from normalization_schema import CLAUDE_BOOKKEEPING, output_issues, source_shape_issues


def projector(source):
    raw = source.read_text()
    marker = 'exec "$tessera_python" -c \'\n'
    start = raw.index(marker) + len(marker)
    end = raw.index('\ntry:\n    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)', start)
    program = raw[start:end]
    tree = ast.parse(program)
    # Same extraction boundary as the existing hermetic projector tests. Do
    # not execute its stdin dispatcher, discovery, provider or transport paths.
    if any(not isinstance(node, (ast.Import, ast.ImportFrom, ast.Assign, ast.FunctionDef, ast.ClassDef)) for node in tree.body):
        raise ValueError('reference module boundary changed')
    namespace = {'__name__': 'tessera_private_reference'}
    exec(compile(tree, str(source), 'exec'), namespace)
    # Same legacy semantics with an already decoded source: the independent
    # shape inventory and legacy projector share ONE immutable input DOM,
    # rather than parsing a giant line twice and retaining allocator high-water.
    original = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'normalized')
    parse_statement = ast.parse('try:\n source = json.loads(raw.decode("utf-8"))\nexcept Exception:\n pass').body[0]
    if not isinstance(original.body[0], ast.Try) or ast.dump(original.body[0].body[0]) != ast.dump(parse_statement.body[0]):
        raise ValueError('reference JSON decode boundary changed')
    decoded = copy.deepcopy(original); decoded.name = 'normalized_source'
    if [arg.arg for arg in decoded.args.args] != ['provider', 'raw', 'truncated']:
        raise ValueError('reference normalizer signature changed')
    decoded.args.args[1].arg = 'decoded_source'
    decoded.body[0] = ast.parse('source = decoded_source').body[0]
    exec(compile(ast.fix_missing_locations(ast.Module(body=[decoded], type_ignores=[])), str(source), 'exec'), namespace)
    # Titles are outside this payload comparison. The legacy normalizer's
    # session_meta path would otherwise query the user's real Codex database.
    namespace['codex_title'] = lambda _: None
    return namespace, hashlib.sha256(program.encode()).hexdigest()


def compare(reference, native):
    if reference.get('malformed') and not native.get('malformed'): return 'reference_incomplete'
    if reference.get('type') != 'message' and native.get('type') != 'message': return 'metadata_not_compared'
    if reference.get('type') != native.get('type'): return 'message_classification_mismatch'
    if reference.get('role') != native.get('role'): return 'role_mismatch'
    old, new = reference.get('blocks', []), native.get('blocks', [])
    if len(old) != len(new): return 'block_count_mismatch'
    shortened = False
    for left, right in zip(old, new):
        # Relationship identifiers are a new field and have a separate gate.
        a = {k: v for k, v in left.items() if k not in ('truncated', 'toolCallID')}
        b = {k: v for k, v in right.items() if k not in ('truncated', 'toolCallID')}
        if a == b: continue
        if a.keys() != b.keys(): return 'block_fields_mismatch'
        for key in a:
            if a[key] == b[key]: continue
            if key in ('text', 'preview', 'diff') and isinstance(a[key], str) and isinstance(b[key], str) and a[key].startswith(b[key]) and right.get('truncated') is True:
                shortened = True
            else: return 'block_content_mismatch'
    return 'bounded_prefix' if shortened else 'exact_visible_payload'


def safe_type(value):
    return value if re.fullmatch(r'[A-Za-z0-9_./-]{1,128}', value) else 'opaque-type-' + hashlib.sha256(value.encode()).hexdigest()[:16]


def coverage(row):
    """Never use agreement with the legacy parser as proof of understanding."""
    record = row['record']
    issues = collections.Counter(output_issues(record))
    disposition = row.get('disposition', '')
    if disposition not in ('message', 'system', 'metadata', 'status', 'ignored'):
        issues['disposition/' + safe_type(disposition)] += 1
    if disposition == 'ignored':
        reason = record.get('ignoreReason')
        if not reason:
            issues['ignored_without_reason'] += 1
        source_type = row.get('sourceType')
        if (not isinstance(reason, str) or not isinstance(source_type, str) or
                source_type not in CLAUDE_BOOKKEEPING or reason != 'claude-sdk-non-message/' + source_type):
            issues['ignored_invalid_reason'] += 1
        if record.get('provider') != 'claude' or record.get('type') != 'system' or row.get('visible', False) is not False:
            issues['ignored_invalid_scope'] += 1
    if record.get('malformed'):
        issues['malformed_record'] += 1
    if record.get('unparsedContentCount', 0):
        issues['unparsed_content_including_evicted_blocks'] += record['unparsedContentCount']
    if record.get('type') in (None, '', 'unknown', 'unsupported'):
        issues['unknown_record_type'] += 1
    if record.get('type') == 'message' and record.get('role') not in ('user', 'assistant', 'tool', 'system', 'developer'):
        issues['unknown_message_role'] += 1
    for block in record.get('blocks', []):
        kind = block.get('type') if isinstance(block, dict) else None
        if kind not in ('text', 'compact-summary', 'thinking', 'tool_call', 'tool_result', 'edit', 'attachment', 'system-event'):
            issues['unknown_block/' + safe_type(str(block.get('sourceType', kind)) if isinstance(block, dict) else 'invalid-shape')] += 1
    return dict(issues)


UNPARSED = object()


def input_coverage(raw, provider, source=UNPARSED):
    """Inspect semantic content containers, never arbitrary tool arguments.

    This deliberately checks inside tool results before contentText flattening
    can erase their discriminators. Recognizing the outer record is not enough.
    Values and arbitrary keys never enter the report.
    """
    shapes = collections.Counter(); issues = collections.Counter()
    if source is UNPARSED:
        try:
            source = json.loads(raw.decode('utf-8') if isinstance(raw, bytes) else raw)
        except (ValueError, UnicodeError):
            return {}, {'input_malformed_json': 1}
    if not isinstance(source, dict): return {}, {'input_non_object': 1}
    issues.update(source_shape_issues(source, provider))

    def first(value, *keys):
        return next((value[key] for key in keys if value.get(key) is not None), None)

    def content(value, location, flattened=False, depth=0):
        if depth > 16:
            issues['input_content_depth'] += 1; return
        if value is None or isinstance(value, str): return
        if isinstance(value, list):
            for part in value: content(part, location, flattened, depth + 1)
            return
        if not isinstance(value, dict):
            issues['input_invalid_content_shape'] += 1; return
        kind = value.get('type', '<missing>')
        kind = kind if isinstance(kind, str) else '<invalid>'
        shapes[location + '/' + safe_type(kind)] += 1
        if flattened and kind not in ('text', 'input_text', 'output_text', 'thinking', 'summary_text', 'reasoning_text',
                                      'image', 'input_image', 'tool_reference', 'encrypted_content'):
            issues['flattened_content/' + safe_type(kind)] += 1
        if kind in ('tool_result', 'function_call_output', 'custom_tool_call_output'):
            content(first(value, 'content', 'output'), 'tool-result', True, depth + 1)

    if provider == 'claude' and source.get('type') in ('user', 'assistant', 'system'):
        message = source.get('message')
        message = message if isinstance(message, dict) else {}
        value = first(message, 'content')
        content(value if value is not None else first(source, 'content', 'text'), 'message')
    elif provider == 'codex' and source.get('type') == 'response_item':
        payload = source.get('payload')
        if not isinstance(payload, dict):
            content = None  # Break the recursive closure's self-cycle.
            return dict(shapes), {'input_invalid_payload': 1}
        kind = payload.get('type')
        if kind in ('message', 'agent_message', 'user_message'):
            content(first(payload, 'content', 'message', 'text'), 'message')
        elif kind == 'reasoning':
            content(first(payload, 'thinking', 'text', 'summary'), 'reasoning-primary', True)
            content(payload.get('summary'), 'reasoning-summary', True)
            content(payload.get('content'), 'reasoning-content', True)
        elif kind in ('function_call_output', 'custom_tool_call_output'):
            content(first(payload, 'content', 'output'), 'tool-result', True)
    content = None  # Do not retain one recursive closure cycle per record.
    return dict(shapes), dict(issues)


METADATA_FIELDS = frozenset(('model', 'branch', 'project', 'permissionMode', 'timestamp',
    'sessionID', 'turnID', 'isMeta', 'isCompactSummary', 'title', 'mode', 'value', 'pending',
    'count', 'totalCostUSD', 'totalDuration', 'totalLinesAdded', 'totalLinesRemoved',
    'used_tokens', 'max_tokens', 'context_percent'))
ROOT_METADATA_FIELDS = METADATA_FIELDS - {'timestamp', 'sessionID', 'turnID', 'isMeta', 'isCompactSummary'}


def compare_metadata(expected, actual):
    results = {}
    for field in METADATA_FIELDS:
        left, right = expected.get(field), actual.get(field)
        if left is None and right is None:
            continue
        if left == right:
            results[field] = 'exact'
        elif actual.get('isSidechain') is True and field in ROOT_METADATA_FIELDS and right is None:
            results[field] = 'child_scope_filtered'
        elif isinstance(left, str) and isinstance(right, str) and actual.get('truncated') is True and left.startswith(right):
            results[field] = 'bounded_prefix'
        else:
            results[field] = 'missing' if right is None else 'added' if left is None else 'mismatch'
    return results


def reference_records(path, provider, reference, limit=32 * 1024 * 1024, include_metadata=False):
    """Full single-record oracle; never inherit the old 49KB prefix scanner."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        end = os.fstat(stream.fileno()).st_size
        position = 0
        while position < end:
            raw = stream.readline(min(limit + 1, end - position))
            if len(raw) > limit: raise RuntimeError('referenceRecordBudget')
            if not raw.endswith(b'\n'): break  # Uncommitted tail, same physical contract.
            allowed_ignore_reason = None
            try:
                source = json.loads(raw.decode('utf-8'))
            except (ValueError, UnicodeError):
                shapes, issues = {}, {'input_malformed_json': 1}
                expected = reference['normalized'](provider, raw, False)
            else:
                shapes, issues = input_coverage(raw, provider, source)
                source_type = source.get('type') if isinstance(source, dict) else None
                if (provider == 'claude' and isinstance(source_type, str) and
                        source_type in CLAUDE_BOOKKEEPING and not issues):
                    allowed_ignore_reason = 'claude-sdk-non-message/' + source_type
                expected = reference['normalized_source'](provider, source, False) if 'normalized_source' in reference else reference['normalized'](provider, raw, False)
                del source
            # Metadata values are outside this gate; do not copy arbitrary
            # legacy metadata blobs across the subprocess boundary.
            fields = {'type', 'role', 'blocks', 'malformed'} | (METADATA_FIELDS if include_metadata else set())
            expected = {key: expected[key] for key in fields if key in expected}
            yield dict(start=position, end=position + len(raw), record=expected, input_shapes=shapes,
                       input_issues=issues, allowed_ignore_reason=allowed_ignore_reason)
            position += len(raw)
            del raw, expected
        yield dict(complete=True, sourceEnd=position)


def reference_worker(source, path, provider, include_metadata=False):
    try:
        reference, _ = projector(source)
        for row in reference_records(path, provider, reference, include_metadata=include_metadata):
            if row.get('complete'):
                row['peakRSSBytes'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == 'darwin' else 1024)
            raw = json.dumps(row, separators=(',', ':'))
            if len(raw.encode()) > 8 * 1024 * 1024: raise RuntimeError('referenceOutputBudget')
            print(raw, flush=True)
    except Exception as error:
        print(json.dumps({'error': str(error) if isinstance(error, RuntimeError) else type(error).__name__}), flush=True)
        raise SystemExit(1)


def worker_memory(lifetime_peak, monitor):
    """A finite worker's lifetime peak closes the first-sampler-tick gap.

    It never excuses a live/failed monitor or a sampled process-tree overrun.
    Both values measure the same worker; take the maximum, never their sum.
    """
    if type(lifetime_peak) is not int or lifetime_peak <= 0:
        raise RuntimeError('workerLifetimeMemoryEvidenceInvalid')
    if monitor.thread.is_alive(): raise RuntimeError('workerMemoryMonitorStillRunning')
    if monitor.failure and monitor.failure != 'rss_guard_incomplete': raise RuntimeError(monitor.failure)
    peak = max(lifetime_peak, monitor.peak)
    if peak > 256 * 1024 * 1024: raise RuntimeError('workerLifetimeMemoryBudgetExceeded')
    return peak


def audit(driver, path, provider, reference, include_metadata=False, worker_script=None):
    process = subprocess.Popen([str(driver), provider, str(path)], stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, start_new_session=True)
    oracle = subprocess.Popen([sys.executable, str(worker_script or Path(__file__).resolve()), '--reference-worker',
        str(reference), str(path), provider, 'metadata' if include_metadata else 'payload'], stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, start_new_session=True)
    guard = Guard(process); oracle_guard = Guard(oracle)
    buffers = {process: bytearray(), oracle: bytearray()}; began = time.monotonic()
    counts = collections.Counter(); types = collections.defaultdict(collections.Counter)
    metadata_counts = collections.defaultdict(collections.Counter)
    metadata_differences = []
    coverage_counts = collections.Counter(); coverage_types = collections.defaultdict(collections.Counter)
    input_shapes = collections.Counter()
    coverage_examples = []
    differences = []; position = 0; records = 0; result = {}
    native_lifetime = reference_lifetime = None
    native_peak = reference_peak = 0

    def line(child=process):
        buffered = buffers[child]
        budget = 300000 if child is process else 8 * 1024 * 1024
        while b'\n' not in buffered:
            if len(buffered) > budget: raise RuntimeError('workerLineBudget')
            if time.monotonic() - began > 120: raise RuntimeError('fileDeadline')
            if not select.select([child.stdout], [], [], 5)[0]: raise RuntimeError('workerOutputDeadline')
            data = os.read(child.stdout.fileno(), 65536)
            if not data: raise RuntimeError('workerPrematureEOF')
            buffered.extend(data)
        raw, _, rest = buffered.partition(b'\n'); buffered[:] = rest
        value = json.loads(raw)
        if 'error' in value: raise RuntimeError(value['error'])
        return value

    try:
        while True:
                expected_row = line(oracle)
                if expected_row.get('complete'):
                    if expected_row['sourceEnd'] != position: raise RuntimeError('referenceCompletionMismatch')
                    reference_lifetime = expected_row.get('peakRSSBytes')
                    break
                end = expected_row['end']
                native = line()
                if expected_row['start'] != position or native.get('start') != position or native.get('end') != end: raise RuntimeError('physicalRecordBoundaryMismatch')
                expected = expected_row['record']
                issues = collections.Counter(coverage(native))
                if (native.get('disposition') == 'ignored' and
                        native['record'].get('ignoreReason') != expected_row.get('allowed_ignore_reason')):
                    issues['ignored_source_disagreement'] += 1
                issues.update(expected_row.get('input_issues', {}))
                input_shapes.update(expected_row.get('input_shapes', {}))
                kind = safe_type(native['sourceType'])
                coverage_counts.update(issues)
                coverage_types[kind].update(issues or {'classified': 1})
                if issues and len(coverage_examples) < 32:
                    coverage_examples.append(dict(record_ordinal=records, source_type=kind, issues=issues))
                if include_metadata:
                    for field, outcome in compare_metadata(expected, native['record']).items():
                        metadata_counts[field][outcome] += 1
                        if outcome in ('missing', 'added', 'mismatch') and len(metadata_differences) < 32:
                            metadata_differences.append(dict(record_ordinal=records, source_type=safe_type(native['sourceType']),
                                field=field, status=outcome,
                                reference_sha256=hashlib.sha256(json.dumps(expected.get(field), sort_keys=True).encode()).hexdigest(),
                                native_sha256=hashlib.sha256(json.dumps(native['record'].get(field), sort_keys=True).encode()).hexdigest()))
                status = compare(expected, native['record'])
                kind = safe_type(native['sourceType']); counts[status] += 1; types[kind][status] += 1
                if status.endswith('mismatch') or status == 'reference_incomplete':
                    if len(differences) < 32:
                        differences.append(dict(record_ordinal=records, source_type=kind, status=status,
                            reference_sha256=hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest(),
                            native_sha256=hashlib.sha256(json.dumps(native['record'], sort_keys=True).encode()).hexdigest()))
                position = end; records += 1
                if guard.failure: raise RuntimeError(guard.failure)
                if oracle_guard.failure: raise RuntimeError('reference_' + oracle_guard.failure)
        end = line()
        if not end.get('complete') or end.get('sourceEnd') != position: raise RuntimeError('nativeCompletionMismatch')
        native_lifetime = end.get('peakRSSBytes')
        if process.wait(timeout=3) or oracle.wait(timeout=3): raise RuntimeError('workerExitFailed')
        result['bytes_read'] = end['bytesRead']
    except Exception as error:
        result['error'] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
    finally:
        for child, monitor in ((process, guard), (oracle, oracle_guard)):
            monitor.signal_owned(signal.SIGTERM)
            if child.poll() is None: child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: monitor.signal_owned(signal.SIGKILL); child.kill(); child.wait(timeout=3)
            monitor.signal_owned(signal.SIGKILL); monitor.close(); child.stdout.close()
        for label, lifetime, monitor in (('native', native_lifetime, guard), ('reference', reference_lifetime, oracle_guard)):
            try:
                peak = worker_memory(lifetime, monitor)
                if label == 'native': native_peak = peak
                else: reference_peak = peak
            except RuntimeError as error:
                code = label + '_' + str(error)
                result.setdefault('resource_errors', []).append(code)
                result.setdefault('error', code)
    result.update(records=records, counts=dict(counts), types={k: dict(v) for k, v in types.items()}, differences=differences,
        native_sampled_peak_bytes=guard.peak, native_lifetime_peak_bytes=native_lifetime, native_peak_bytes=native_peak,
        memory_measured=native_peak > 0,
        reference_sampled_peak_bytes=oracle_guard.peak, reference_lifetime_peak_bytes=reference_lifetime, reference_peak_bytes=reference_peak,
        reference_memory_measured=reference_peak > 0,
        wall_ms=round((time.monotonic() - began)*1000, 3),
        coverage_issues=dict(coverage_counts), coverage_types={key: dict(value) for key, value in coverage_types.items()},
        coverage_examples=coverage_examples, input_shapes=dict(input_shapes))
    if include_metadata:
        result.update(metadata_counts={key: dict(value) for key, value in metadata_counts.items()},
                      metadata_differences=metadata_differences)
    return result


def gate_status(report):
    if not report['expected_files']: return 'empty_corpus'
    if report['files'] != report['expected_files']: return 'incomplete'
    if report['failed_files']: return 'failed_processing'
    if report.get('resource_failed_files') != 0 or report.get('memory_measured_files') != report['expected_files']:
        return 'failed_resources'
    if report['coverage_failed_files']: return 'failed_coverage'
    if any(count and (key.endswith('mismatch') or key == 'reference_incomplete') for key, count in report['counts'].items()):
        return 'failed_payload_comparison'
    if any(values.get(key, 0) for values in report.get('metadata_counts', {}).values() for key in ('missing', 'added', 'mismatch')):
        return 'failed_metadata_comparison'
    return 'passed_scoped_checks'


def scope_summary(candidates, rows):
    # This is a layout breakdown, NOT permission to hide failed comparisons.
    # Every physical file still runs through the parser and the strict gate.
    from transcript_layout import candidate_is_session, default_claude_projects_root
    scopes = collections.defaultdict(lambda: dict(files=0, processing_failures=0, coverage_failed_files=0, coverage_issues=collections.Counter()))
    seen = set()
    for row in rows:
        ordinal = row['ordinal']
        if type(ordinal) is not int or not 0 <= ordinal < len(candidates) or ordinal in seen:
            raise RuntimeError('invalid_scope_ordinal')
        seen.add(ordinal); candidate = candidates[ordinal]
        if row['provider'] != candidate['provider'] or row['file_bytes'] != candidate['bytes']:
            raise RuntimeError('scope_manifest_mismatch')
        scope = 'session_layout' if candidate_is_session(candidate, default_claude_projects_root()) else 'non_session_jsonl_layout'
        result = scopes[scope]; result['files'] += 1; result['processing_failures'] += 'error' in row
        result['coverage_failed_files'] += bool(row.get('coverage_issues'))
        result['coverage_issues'].update(row.get('coverage_issues', {}))
    return dict(scopes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--metadata', action='store_true', help='Also compare bounded metadata fields; relationships/replay remain separate')
    args = parser.parse_args(); output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]): parser.error('private output must be outside Git')
    os.umask(0o077); output.mkdir(mode=0o700)
    driver = output / 'measured-driver'; clone(args.driver.resolve(), driver); driver.chmod(0o700)
    reference = output / 'measured-reference.swift'; clone(args.reference.resolve(), reference)
    worker_script = output / 'normalization_corpus.py'
    for name in ('normalization_corpus.py', 'normalization_schema.py', 'native_first_page.py', 'transcript_layout.py'):
        clone(Path(__file__).resolve().parent / name, output / name)
    _, digest = projector(reference)
    manifest_bytes = args.manifest.read_bytes()
    candidates = json.loads(manifest_bytes)['candidates']; rows = []
    def checkpoint():
        totals = collections.Counter()
        for row in rows: totals.update(row.get('counts', {}))
        coverage_totals = collections.Counter()
        for row in rows: coverage_totals.update(row.get('coverage_issues', {}))
        report = dict(stage='physical_visible_payload_differential_not_full_semantic_equivalence',
            manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(), layout_scopes=scope_summary(candidates, rows),
            reference_sha256=digest, driver_sha256=hashlib.sha256(driver.read_bytes()).hexdigest(),
            audit_sha256=hashlib.sha256(worker_script.read_bytes()).hexdigest(),
            schema_sha256=hashlib.sha256((output / 'normalization_schema.py').read_bytes()).hexdigest(),
            files=len(rows), expected_files=len(candidates), failed_files=sum('error' in row for row in rows), counts=dict(totals),
            resource_failed_files=sum(bool(row.get('resource_errors')) for row in rows),
            memory_measured_files=sum(row.get('memory_measured') is True and row.get('reference_memory_measured') is True for row in rows),
            coverage_issues=dict(coverage_totals), coverage_failed_files=sum(bool(row.get('coverage_issues')) for row in rows), results=rows)
        if args.metadata:
            metadata_totals = collections.defaultdict(collections.Counter)
            for row in rows:
                for field, values in row.get('metadata_counts', {}).items(): metadata_totals[field].update(values)
            report['metadata_counts'] = {key: dict(value) for key, value in metadata_totals.items()}
        report['status'] = gate_status(report)
        pending = output / 'content-free-results.pending'; pending.write_text(json.dumps(report, indent=2))
        os.replace(pending, output / 'content-free-results.json'); return report
    for ordinal, candidate in enumerate(candidates):
        if candidate['provider'] not in ('claude', 'codex'): raise RuntimeError('unexpectedProvider')
        result = audit(driver, Path(candidate['path']), candidate['provider'], reference, args.metadata, worker_script)
        rows.append(dict(ordinal=ordinal, provider=candidate['provider'], file_bytes=candidate['bytes'], **result)); checkpoint()
        if ordinal % 25 == 0:
            print(json.dumps(dict(tested=len(rows), processing_failures=sum('error' in row for row in rows),
                coverage_failed_files=sum(bool(row.get('coverage_issues')) for row in rows))), flush=True)
    report = checkpoint(); print(json.dumps({k: report[k] for k in ('status', 'files', 'failed_files', 'resource_failed_files', 'memory_measured_files', 'coverage_failed_files', 'coverage_issues', 'counts')}))
    if report['status'] != 'passed_scoped_checks': raise SystemExit(1)


if __name__ == '__main__':
    if len(sys.argv) in (5, 6) and sys.argv[1] == '--reference-worker':
        reference_worker(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], len(sys.argv) == 6 and sys.argv[5] == 'metadata')
    else: main()
