#!/usr/bin/env python3
"""Private Pi persisted-branch differential and all-record taxonomy audit.

Uses finite copies only: the SDK may migrate old files when opened. Never
opens original sessions in the SDK, launches an agent, or loads extensions.
The reference lane admits <=8 MiB / 3200 entries per file; larger references
fail explicitly, not as a native-reader performance result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REFERENCE_SHA256 = 'f0912a8b585263cc9793b38d97f01d19b0617c67b56d7f790bbb81a27d916a3c'
REFERENCE_URL = 'https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/session-manager.ts'
REFERENCE_SCRIPT = '''
const {SessionManager} = await import(process.argv[1]);
const manager = SessionManager.open(process.argv[2]);
const entries = manager.getEntries();
const branch = manager.getBranch();
process.stdout.write(JSON.stringify({ids: branch.map(e => e.id),
  indices: branch.map(e => entries.indexOf(e)), peakRSSBytes: process.resourceUsage().maxRSS * 1024}));
'''


def run(command, **kwargs):
    with tempfile.TemporaryFile() as output:
        value = subprocess.run(command, stdout=output, stderr=subprocess.DEVNULL, timeout=30, **kwargs)
        if value.returncode: raise RuntimeError('subprocess-failed')
        if output.tell() > 64 * 1024 * 1024: raise RuntimeError('reference-output-budget')
        output.seek(0)
        return output.read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]): parser.error('evidence must be outside Git')
    if hashlib.sha256(args.reference.read_bytes()).hexdigest() != REFERENCE_SHA256: parser.error('reference changed; review and pin first')
    os.umask(0o077)
    output.mkdir(mode=0o700)
    bins = output / 'bin'; bins.mkdir()
    for name in ('agent-window-reader-driver', 'agent-normalization-driver'):
        shutil.copy2(args.build / name, bins / name)
    rows = []
    for ordinal, original in enumerate(sorted(args.root.rglob('*.jsonl'))):
        row = {'fileOrdinal': ordinal, 'status': 'failed'}
        try:
            before = original.stat()
            if original.is_symlink() or before.st_size > 8 * 1024 * 1024: raise RuntimeError('reference-input-budget')
            with original.open('rb') as source: data = source.read(8 * 1024 * 1024 + 1)
            if len(data) > 8 * 1024 * 1024: raise RuntimeError('reference-input-budget')
            after = original.stat()
            witness = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if witness(before) != witness(after): raise RuntimeError('snapshot-changed')
            complete = data.rfind(b'\n') + 1
            row.update(bytes=complete, excludedPartialBytes=len(data)-complete)
            data = data[:complete]
            entries = [json.loads(line) for line in data.splitlines() if line.strip()]
            offsets = []; position = 0
            for line in data.splitlines(keepends=True):
                if line.strip(): offsets.append(position)
                position += len(line)
            if not entries or entries[0].get('type') != 'session': raise RuntimeError('invalid-header')
            if len(entries) > 3200: raise RuntimeError('reference-entry-budget')
            private = output / str(ordinal); private.mkdir()
            root = private / 'pi'; session = root / 'sessions/fixture/session.jsonl'
            session.parent.mkdir(parents=True); session.write_bytes(data)
            sdk_copy = private / 'sdk-session.jsonl'; sdk_copy.write_bytes(data)
            started = time.monotonic()
            reference = json.loads(run(['node', '--max-old-space-size=128', '--input-type=module', '-e', REFERENCE_SCRIPT,
                                        args.reference.resolve().as_uri(), str(sdk_copy)]))
            commands = [dict(op='read')]+[dict(op='read', direction='before', page=n-1) for n in range(1, 32)]
            output_bytes = run([str(bins / 'agent-window-reader-driver'), 'pi', str(session)],
                input=('\n'.join(json.dumps(value) for value in commands)+'\n').encode(),
                env={**os.environ, 'PI_CODING_AGENT_DIR': str(root)})
            selected = []
            for line in output_bytes.splitlines():
                page = json.loads(line)
                if 'error' in page: raise RuntimeError('native-branch-read-failed')
                selected = page['records'] + selected
                if not page['hasOlder']: break
            else: raise RuntimeError('native-reference-page-budget')
            native_ids = [entry['id'] for entry in selected][1:]
            if entries[0].get('version', 1) == 1:
                expected = ['v1:' + str(offsets[index+1]) for index in reference['indices']]
            else: expected = reference['ids']
            if native_ids != expected: raise RuntimeError('branch-id-mismatch')
            normalized = [json.loads(line) for line in run([str(bins / 'agent-normalization-driver'), 'pi', str(session)]).splitlines()]
            end = normalized.pop()
            if end.get('complete') is not True or end.get('sourceEnd') != len(data): raise RuntimeError('incomplete-taxonomy')
            if [value['start'] for value in normalized] != offsets: raise RuntimeError('incomplete-record-coverage')
            if any(value.get('disposition') not in {'message', 'system', 'metadata', 'status', 'ignored', 'unclassified'}
                   for value in normalized): raise RuntimeError('invalid-disposition')
            unknown = sum(value['disposition'] == 'unclassified' for value in normalized)
            unparsed = sum(value['record'].get('unparsedContentCount', 0) for value in normalized)
            row.update(status='passed' if unknown == unparsed == 0 else 'unknown-content',
                physicalRecords=len(normalized), selectedRecords=len(selected), unknownRecords=unknown,
                unparsedBlocks=unparsed, nativeNormalizerPeakRSSBytes=end['peakRSSBytes'], referencePeakRSSBytes=reference['peakRSSBytes'],
                auditWallMS=round((time.monotonic()-started)*1000, 3))
        except Exception as error:
            row['failure'] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        rows.append(row)
    report = dict(reference_url=REFERENCE_URL, reference_sha256=REFERENCE_SHA256,
                  files=len(rows), failures=sum(row['status'] != 'passed' for row in rows), rows=rows)
    (output / 'content-free-results.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({key: report[key] for key in ('files', 'failures')}))
    return 0 if rows and report['failures'] == 0 else 1


if __name__ == '__main__': raise SystemExit(main())
