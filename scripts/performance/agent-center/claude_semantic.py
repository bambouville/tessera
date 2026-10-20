#!/usr/bin/env python3
"""All-private-Claude branch differential against a pinned official SDK reader.

Reference parsing runs in one disposable subprocess per file, not in the app.
No provider code is launched, no provider configuration is loaded, and only
content-free counts/timing/hash evidence is written outside Git.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time
from native_first_page import Guard, clone

REFERENCE_SHA256 = 'c885b89b741d190fc081a2a8e793e2c6e2affd0bc4bbf3e75facf20091e06551'
REFERENCE_URL = 'https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/sessions.py'


def reference(source, path):
    raw = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != REFERENCE_SHA256:
        raise ValueError('official reference digest changed; review before updating')
    selected = {'_parse_transcript_entries', '_build_conversation_chain', '_is_visible_message'}
    tree = ast.parse(raw)
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in selected]
    if len(functions) != 3: raise ValueError('reference function boundary changed')
    # Execute only the reviewed pure parsing/chain functions, never SDK imports,
    # provider discovery, network clients, hooks, or filesystem mutation helpers.
    module = ast.Module(body=[ast.ImportFrom(module='__future__', names=[ast.alias(name='annotations')], level=0), *functions], type_ignores=[])
    namespace = {'json': json, '_TRANSCRIPT_ENTRY_TYPES': frozenset({'user', 'assistant', 'progress', 'system', 'attachment'})}
    exec(compile(ast.fix_missing_locations(module), str(source), 'exec'), namespace)
    entries = namespace['_parse_transcript_entries'](path.read_text())
    offsets = {}; ordinal = 0; position = 0
    with path.open('rb') as transcript:
        for line in transcript:
            try: entry = json.loads(line)
            except (ValueError, UnicodeError): position += len(line); continue
            if isinstance(entry, dict) and entry.get('type') in namespace['_TRANSCRIPT_ENTRY_TYPES'] and isinstance(entry.get('uuid'), str):
                offsets[id(entries[ordinal])] = position; ordinal += 1
            position += len(line)
    def selection(values):
        chain = namespace['_build_conversation_chain'](values)
        visible = [entry for entry in chain if namespace['_is_visible_message'](entry)]
        return {'ids': [entry['uuid'] for entry in visible], 'sourceOffsets': [offsets[id(entry)] for entry in visible]}
    parents = {entry.get('parentUuid') for entry in entries if entry.get('parentUuid')}
    latest = {entry['uuid']: id(entry) for entry in entries}
    corrected = [entry for entry in entries if entry['uuid'] in parents or latest[entry['uuid']] == id(entry)]
    return {'sdk': selection(entries), 'latest_terminal_policy': selection(corrected)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--reference-file', type=Path)
    parser.add_argument('--driver', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.reference_file:
        # The reference is intentionally a full-file implementation. Bound its
        # address space and duration separately from native-service acceptance.
        if sys.platform != 'darwin':
            resource.setrlimit(resource.RLIMIT_AS, (768 * 1024 * 1024, 768 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CPU, (20, 20))
        selections = reference(args.reference, args.reference_file)
        peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == 'darwin' else 1024)
        print(json.dumps(dict(selections, peakRSSBytes=peak)))
        return
    if not all((args.driver, args.manifest, args.output)): parser.error('driver, manifest and output required')
    output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]):
        parser.error('private evidence must be outside Git')
    output.mkdir(mode=0o700)
    # Every file in one audit must use the same executable, even if a separate
    # native build finishes while the guarded reference subprocesses run.
    pinned_driver = output / 'native-driver'
    clone(args.driver, pinned_driver)
    pinned_driver.chmod(0o700)
    driver_digest = hashlib.sha256(pinned_driver.read_bytes()).hexdigest()
    manifest = json.loads(args.manifest.read_text())
    candidates = manifest['candidates'] if isinstance(manifest, dict) else manifest
    rows = []
    def checkpoint():
        summary = {'reference_url': REFERENCE_URL, 'reference_sha256': REFERENCE_SHA256,
                   'driver_sha256': driver_digest, 'files': len(rows),
                   'sdk_matches': sum(row.get('sdk_matches', False) for row in rows),
                   'matches': sum(row.get('matches', False) for row in rows),
                   'failures': sum(not row.get('matches', False) for row in rows), 'results': rows}
        temporary = output / 'content-free-results.pending'
        temporary.write_text(json.dumps(summary, indent=2)); temporary.chmod(0o600)
        os.replace(temporary, output / 'content-free-results.json')
        return summary
    for ordinal, candidate in enumerate(candidates):
        if candidate['provider'] != 'claude': continue
        path = Path(candidate['path']); started = time.monotonic()
        row = {'ordinal': ordinal, 'file_bytes': candidate['bytes']}
        try:
            result = subprocess.run([str(pinned_driver), str(path)], capture_output=True, timeout=30)
            native = json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError) as error:
            row['native_error'] = type(error).__name__; rows.append(row); checkpoint(); continue
        elapsed = (time.monotonic() - started) * 1000
        row.update({'native_ms': elapsed,
               'native_error': native.get('error'), 'index_bytes': native.get('indexBytes'),
               'peak_rss_bytes': native.get('peakRSSBytes'), 'bytes_read': native.get('bytesRead')})
        try:
            reference_child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--reference', str(args.reference),
                '--reference-file', str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        except OSError as error:
            row['reference_error'] = type(error).__name__; rows.append(row); checkpoint(); continue
        guard = Guard(reference_child)
        try:
            reference_output, _ = reference_child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            reference_child.kill(); reference_child.communicate(); reference_output = b''
        finally: guard.close()
        if reference_child.returncode or (guard.failure and guard.failure != 'rss_guard_incomplete'):
            row['reference_error'] = guard.failure or 'reference_child_failed'
            row['reference_exit_code'] = reference_child.returncode
        else:
            try: reference_result = json.loads(reference_output)
            except ValueError:
                row['reference_error'] = 'malformedReferenceOutput'; rows.append(row); checkpoint(); continue
            expected = reference_result['latest_terminal_policy']['ids']
            row['reference_peak_rss_bytes'] = reference_result['peakRSSBytes']
            actual = native.get('ids', [])
            selection = {'ids': actual, 'sourceOffsets': native.get('sourceOffsets', [])}
            row.update(reference_messages=len(expected), native_messages=len(actual),
                       sdk_matches=not result.returncode and selection == reference_result['sdk'],
                       matches=not result.returncode and selection == reference_result['latest_terminal_policy'],
                       reference_ids_sha256=hashlib.sha256(json.dumps(expected).encode()).hexdigest(),
                       native_ids_sha256=hashlib.sha256(json.dumps(actual).encode()).hexdigest())
        rows.append(row)
        checkpoint()
    summary = checkpoint()
    print(json.dumps({key: summary[key] for key in ('files', 'matches', 'failures')}))
    if summary['failures']: raise SystemExit(1)


if __name__ == '__main__': main()
