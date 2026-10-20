#!/usr/bin/env python3
"""Private finite-snapshot gate for Codex canonical-authority selection.

Exercises the production Catalog and prefix reader through the synthetic-test
driver, with no provider executable available. This is header/identity coverage,
not whole-history normalization or semantic equivalence. Outputs only ordinals,
counts, bounded error codes and I/O/timing; private source data stays outside Git.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

from native_first_page import clone

MAXIMUM_HEADER = 8 * 1024 * 1024


def header_expectation(path, session):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate_header_key')
            result[key] = value
        return result
    with path.open('rb') as source:
        prefix = source.readline(MAXIMUM_HEADER + 1)
    if not prefix:
        return False, 'empty', 0
    if len(prefix) > MAXIMUM_HEADER:
        raise ValueError('header_budget')
    if not prefix.endswith(b'\n'):
        raise ValueError('incomplete_header')
    header = json.loads(prefix, object_pairs_hook=unique)
    if not isinstance(header, dict):
        raise ValueError('invalid_header_shape')
    if header.get('type') != 'session_meta':
        return False, 'unmarked', len(prefix)
    payload = header.get('payload')
    if not isinstance(payload, dict) or payload.get('id') != session:
        raise ValueError('header_identity_mismatch')
    mode = payload.get('history_mode') or 'legacy'
    if mode not in ('legacy', 'paginated'):
        raise ValueError('unknown_history_mode')
    return True, mode, len(prefix)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]):
        parser.error('private output must be outside Git')
    manifest = args.manifest.read_bytes()
    candidates = json.loads(manifest)['candidates']
    if not candidates or any('original_path' not in row for row in candidates):
        parser.error('an existing finite-snapshot manifest is required')
    os.umask(0o077)
    output.mkdir(mode=0o700)
    driver = output / 'measured-driver'
    clone(args.driver.resolve(strict=True), driver); driver.chmod(0o700)
    codex = output / 'codex'
    sessions = codex / 'sessions'; sessions.mkdir(parents=True, mode=0o700)
    environment = dict(os.environ, CODEX_HOME=str(codex), CLAUDE_CONFIG_DIR=str(output / 'empty-claude'),
                       PATH=str(output / 'no-provider-executables'))
    rows = []; counts = collections.Counter()
    for ordinal, candidate in enumerate(candidates):
        if candidate['provider'] != 'codex':
            continue
        row = dict(ordinal=ordinal, file_bytes=candidate['bytes'])
        target = None
        try:
            original = Path(candidate['original_path'])
            session = original.stem[-36:]
            if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', session):
                raise ValueError('unsupported_filename_identity')
            target = sessions / original.name
            clone(candidate['path'], target)
            expected, mode, header_bytes = header_expectation(target, session)
            started = time.monotonic_ns()
            result = subprocess.run([str(driver), 'codex', str(target)],
                input=b'{"op":"authority"}\n', stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env=environment, timeout=5, check=True)
            if len(result.stdout) > 8192:
                raise ValueError('driver_output_budget')
            reply = json.loads(result.stdout)
            if reply.get('error'):
                code = reply['error']
                raise ValueError(code if re.fullmatch(r'[A-Za-z0-9_]{1,80}', code) else 'opaque_driver_error')
            if reply.get('canonical') is not expected:
                raise ValueError('authority_mismatch')
            if reply.get('path') != str(target):
                raise ValueError('source_path_mismatch')
            physical = reply.get('bytesRead')
            if type(physical) is not int or not 0 <= physical <= min(candidate['bytes'],
                    ((header_bytes + 65535) // 65536) * 65536):
                raise ValueError('prefix_io_budget')
            row.update(mode=mode, header_bytes=header_bytes, bytes_read=physical,
                       elapsed_ms=(time.monotonic_ns() - started) / 1e6)
            counts[mode] += 1
        except ValueError as error:
            code = str(error)
            row['error'] = code if re.fullmatch(r'[A-Za-z0-9_]{1,80}', code) else 'invalid_header_or_response'
        except Exception as error:
            row['error'] = type(error).__name__
        finally:
            if target is not None:
                target.unlink(missing_ok=True)  # Only this run's disposable clone.
        rows.append(row)
    failures = sum('error' in row for row in rows)
    report = dict(stage='canonical_header_authority_not_full_semantics', files=len(rows), failures=failures,
        modes=dict(counts), manifest_sha256=hashlib.sha256(manifest).hexdigest(),
        driver_sha256=hashlib.sha256(driver.read_bytes()).hexdigest(),
        script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), rows=rows)
    (output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(files=len(rows), failures=failures, modes=dict(counts))))
    raise SystemExit(1 if failures or not rows else 0)


if __name__ == '__main__':
    main()
