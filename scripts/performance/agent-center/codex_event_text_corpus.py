#!/usr/bin/env python3
"""Private, scoped legacy user-event -> raw response -> native text oracle.

Unlike the legacy projector differential, this independently uses the original
user event as the text oracle. No transcript text, paths, IDs or text hashes are
reported. This does not prove event-only handling or completed-item semantics.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from native_first_page import clone


def display(value):
    return ''.join(c for c in value if (ord(c) >= 32 or c in '\n\t')
                   and not 0x202a <= ord(c) <= 0x202e and not 0x2066 <= ord(c) <= 0x2069)


def candidate(source, native):
    payload = source.get('payload', {})
    if not isinstance(payload, dict):
        return None
    if source.get('type') != 'response_item' or payload.get('role') != 'user':
        return None
    content = payload.get('content')
    if not isinstance(content, list):
        return None
    raw = ''.join(p['text'] for p in content if isinstance(p, dict) and isinstance(p.get('text'), str))
    expected = display(raw)
    actual = ''.join(p.get('text', '') for p in native.get('blocks', []) if p.get('type') == 'text')
    if native.get('type') != 'message' or native.get('role') != 'user' or native.get('unparsedContentCount'):
        outcome = 'native_classification_failure'
    elif expected == actual:
        outcome = 'exact_native_text'
    elif actual and expected.startswith(actual) and native.get('truncated') is True and any(
            p.get('truncated') is True for p in native.get('blocks', []) if p.get('type') == 'text'):
        outcome = 'explicit_bounded_prefix'
    else:
        outcome = 'native_text_failure'
    return hashlib.sha256(raw.encode()).digest(), outcome


def audit(driver, path):
    counts = collections.Counter()
    recent = collections.deque(maxlen=8)
    pending = None
    def finish():
        if pending is not None:
            counts[pending[1] or 'unmatched_user_event'] += 1
    with path.open('rb') as source, subprocess.Popen(
            [str(driver), 'codex', str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        complete = False
        try:
            for line in process.stdout:
                row = json.loads(line)
                if row.get('complete'):
                    complete = row.get('sourceEnd') == path.stat().st_size
                    continue
                if 'error' in row:
                    raise RuntimeError('native_worker_failure')
                source.seek(row['start'])
                value = json.loads(source.read(row['end'] - row['start']))
                payload = value.get('payload', {})
                payload = payload if isinstance(payload, dict) else {}
                if value.get('type') == 'event_msg' and payload.get('type') == 'user_message':
                    finish()
                    if not isinstance(payload.get('message'), str):
                        counts['invalid_user_event'] += 1
                        pending = None
                    else:
                        digest = hashlib.sha256(payload['message'].encode()).digest()
                        pending = [digest, next((outcome for key, outcome in reversed(recent) if key == digest), None)]
                match = candidate(value, row['record'])
                if match:
                    recent.append(match)
                    if pending is not None and pending[0] == match[0]:
                        pending[1] = match[1]
            finish()
            if process.wait(timeout=10) or not complete:
                raise RuntimeError('incomplete_native_worker')
        finally:
            if process.poll() is None:
                process.kill()
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--coverage', type=Path, required=True,
                        help='Prior full audit selecting files containing legacy user events')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    if any((parent / '.git').exists() for parent in (args.output, *args.output.parents)):
        parser.error('private output must be outside Git')
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = json.loads(args.manifest.read_text())['candidates']
    coverage = json.loads(args.coverage.read_text())
    selected = [row['ordinal'] for row in coverage['results'] if 'event_msg/user_message' in row['types']]
    totals = collections.Counter()
    results = []
    with tempfile.TemporaryDirectory(prefix='event-text-', dir=args.output) as temporary:
        private = Path(temporary)
        driver = private / 'driver'
        clone(args.driver, driver)
        driver.chmod(0o700)
        digest = hashlib.sha256(driver.read_bytes()).hexdigest()
        for ordinal in selected:
            entry = manifest[ordinal]
            if entry['provider'] != 'codex':
                raise ValueError('invalid_provider_scope')
            snapshot = private / 'source.jsonl'
            clone(Path(entry['path']), snapshot)
            try:
                counts = audit(driver, snapshot)
                results.append({'ordinal': ordinal, 'counts': dict(counts)})
                totals.update(counts)
            except Exception:
                totals['processing_failure'] += 1
                results.append({'ordinal': ordinal, 'error': 'processing_failure'})
            snapshot.unlink()
    failures = sum(n for key, n in totals.items() if key not in ('exact_native_text', 'explicit_bounded_prefix'))
    passed = bool(selected and totals) and not failures
    report = {'gate_status': 'passed_scoped_checks' if passed else 'failed', 'files': len(selected),
              'scope': 'legacy user-event text only; no event-only or completed-item claim',
              'driver_sha256': digest, 'counts': dict(totals), 'results': results}
    (args.output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'results'}))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
