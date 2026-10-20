#!/usr/bin/env python3
"""Synthetic before/after display equivalence, including controls and UTF-8.

No provider home, network, or real transcript is accessed. Binaries must be
already built; run this correctness lane separately from latency measurements.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def read(binary, provider, path, cursor):
    result = subprocess.run([str(binary), 'jsonl', '--provider', provider, '--path', str(path),
                             '--after', str(cursor)], capture_output=True, timeout=10)
    if result.returncode or result.stderr or len(result.stdout) >= 262144:
        raise ValueError('reader failed or exceeded its wire budget')
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', required=True, type=Path)
    parser.add_argument('--after', required=True, type=Path)
    args = parser.parse_args()
    binaries = [path.resolve(strict=True) for path in (args.before, args.after)]
    report = dict(binarySHA256=[hashlib.sha256(path.read_bytes()).hexdigest() for path in binaries], results=[])
    with tempfile.TemporaryDirectory(prefix='tessera-display-equivalence-') as directory:
        path = Path(directory) / 'synthetic.jsonl'
        for provider in ('claude', 'codex'):
            count = 0
            with path.open('w') as stream:
                for length in (0, 16380):
                    for position in range(8):
                        for character in [chr(value) for value in range(128)] + ['é', '界', '😀', '\u202e', '\u2066', '\u2069']:
                            body = 'a' * (length + position) + character + 'z' * 32 + ' café 😀 final text'
                            parts = [dict(type='text', text=body)]
                            source = (dict(type='user', uuid=f'fixture-{count}', message=dict(role='user', content=parts))
                                      if provider == 'claude' else dict(type='response_item', payload=dict(
                                          type='message', role='user', content=[dict(type='input_text', text=body)])))
                            stream.write(json.dumps(source, ensure_ascii=False) + '\n')
                            count += 1
            cursor = 0
            seen = 0
            digest = hashlib.sha256()
            while True:
                before, after = [read(binary, provider, path, cursor) for binary in binaries]
                if before['records'] != after['records']:
                    raise ValueError(f'{provider}: normalized record mismatch after record {seen}')
                if not before['records'] or before['livePosition'] <= cursor:
                    raise ValueError('incomplete forward traversal')
                if before['livePosition'] != after['livePosition'] or before['hasNewer'] != after['hasNewer']:
                    raise ValueError('page boundary mismatch')
                for record in before['records']:
                    digest.update(json.dumps(record['record'], sort_keys=True, ensure_ascii=False).encode())
                seen += len(before['records'])
                cursor = before['livePosition']
                if not before['hasNewer']:
                    break
            if seen != count or cursor != path.stat().st_size:
                raise ValueError('source coverage incomplete')
            report['results'].append(dict(provider=provider, records=seen, normalizedSHA256=digest.hexdigest()))
    report['status'] = 'exact_synthetic_equivalence'
    print(json.dumps(report))


if __name__ == '__main__':
    main()
