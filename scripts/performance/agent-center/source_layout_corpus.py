#!/usr/bin/env python3
"""Compare native Claude discovery grammar with the pinned SDK on private paths.

All discovered JSONL files remain accounted for, including non-session sidecar
logs. This does not claim excluded logs are understood transcript messages.
"""
import argparse
import ast
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from claude_semantic import REFERENCE_SHA256, REFERENCE_URL
from native_first_page import clone
from transcript_layout import claude_relative, claude_layout, default_claude_projects_root


def reference_functions(reference):
    raw = reference.read_bytes()
    if hashlib.sha256(raw).hexdigest() != REFERENCE_SHA256:
        raise ValueError('official SDK digest changed')
    selected = []
    for node in ast.parse(raw).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == '_UUID_RE' for t in node.targets):
            selected.append(node)
        elif isinstance(node, ast.FunctionDef) and node.name in ('_validate_uuid', '_read_sessions_from_dir', '_collect_agent_files'):
            selected.append(node)
    if len(selected) != 4:
        raise ValueError('reference discovery boundary changed')
    # Discovery grammar only: do not read user messages or conflate title /
    # visibility heuristics with which paths are session files. The real SDK
    # directory walking, UUID and leaf-name predicates run without changes.
    namespace = {'re': re, 'Path': Path, '_read_session_lite': lambda _: True,
                 '_parse_session_info_from_lite': lambda session, *_: session}
    future = ast.ImportFrom(module='__future__', names=[ast.alias(name='annotations')], level=0)
    exec(compile(ast.fix_missing_locations(ast.Module(body=[future, *selected], type_ignores=[])), str(reference), 'exec'), namespace)
    return namespace


def sdk_discovery(functions, relative_paths, tree):
    for relative in relative_paths:
        target = tree / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.touch(mode=0o600, exist_ok=False)  # Names only, never transcripts.
    selected = {}
    orphan_roots = 0
    for project in tree.iterdir():
        if not project.is_dir():
            continue
        main = functions['_read_sessions_from_dir'](project)
        for session in main:
            selected[(project / (session + '.jsonl')).relative_to(tree)] = 'main_session'
        for session_dir in project.iterdir():
            if not session_dir.is_dir() or not functions['_validate_uuid'](session_dir.name):
                continue
            agents = functions['_collect_agent_files'](session_dir / 'subagents')
            if agents and session_dir.name not in main:
                orphan_roots += 1
            for _, path in agents:
                selected[path.relative_to(tree)] = 'subagent_session'
    return selected, orphan_roots


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--claude-projects-root', type=Path, default=default_claude_projects_root())
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if any((parent / '.git').exists() for parent in (output, *output.parents)):
        parser.error('private output must be outside Git')
    os.umask(0o077)
    output.mkdir(mode=0o700)
    pinned_reference = output / 'sdk-sessions.py'
    clone(args.reference, pinned_reference)
    functions = reference_functions(pinned_reference)
    driver = output / 'measured-driver'
    clone(args.driver.resolve(), driver)
    driver.chmod(0o700)
    rows = []
    inputs = []
    relatives = []
    manifest_bytes = args.manifest.read_bytes()
    for ordinal, entry in enumerate(json.loads(manifest_bytes)['candidates']):
        if entry['provider'] != 'claude':
            continue
        path = Path(entry.get('original_path', entry['path']))
        # Frozen original paths retain the configured provider projects root;
        # numbered private snapshot leaves are not the discovery input.
        relative = claude_relative(path, entry.get('source_root', args.claude_projects_root))
        relatives.append(relative)
        rows.append({'ordinal': ordinal})
        inputs.append(json.dumps(str(relative)))
    with tempfile.TemporaryDirectory(prefix='sdk-shape-tree-', dir=output) as directory:
        selected, orphan_roots = sdk_discovery(functions, relatives, Path(directory))
    fixture_mismatches = 0
    for relative, row in zip(relatives, rows):
        row['classification'] = selected.get(relative, 'non_session_jsonl')
        fixture_mismatches += claude_layout(relative) != row['classification']
    session = '00000000-0000-0000-0000-000000000001'
    fixtures = [Path('fixture/' + suffix) for suffix in (
        session + '.jsonl', session + '/subagents/agent-fixture.jsonl',
        session + '/subagents/workflows/projects/run/agent-nested.jsonl',
        session + '/subagents/agent-.jsonl', 'results.jsonl',
        session + '/subagents/workflows/projects/run/results.jsonl',
        'not-uuid/subagents/agent-invalid.jsonl', session + '/elsewhere/agent-invalid.jsonl')]
    with tempfile.TemporaryDirectory(prefix='sdk-fixtures-', dir=output) as directory:
        fixture_selected, _ = sdk_discovery(functions, fixtures, Path(directory))
    fixture_rows = [{'classification': fixture_selected.get(path, 'non_session_jsonl')} for path in fixtures]
    for path, row in zip(fixtures, fixture_rows):
        fixture_mismatches += claude_layout(path) != row['classification']
        inputs.append(json.dumps(str(path)))
    process = subprocess.run([str(driver), '--layout'], input='\n'.join(inputs) + '\n',
                             text=True, capture_output=True, timeout=30)
    actual = process.stdout.splitlines()
    complete = process.returncode == 0 and not process.stderr and len(actual) == len(rows) + len(fixtures)
    mismatches = sum(value != ('0' if row['classification'] == 'non_session_jsonl' else '1')
                     for value, row in zip(actual, rows + fixture_rows))
    report = {'status': 'passed_scoped_checks' if complete and rows and not mismatches and not fixture_mismatches else 'failed',
              'files': len(rows), 'synthetic_fixtures': len(fixtures),
              'counts': dict(collections.Counter(row['classification'] for row in rows)),
              'complete': complete, 'mismatches': mismatches, 'fixture_layout_mismatches': fixture_mismatches,
              'orphan_subagent_roots': orphan_roots,
              'scope': 'SDK file-collection grammar; excludes title visibility filtering; includes orphan subagent roots',
              'reference_sha256': REFERENCE_SHA256,
              'manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
              'reference_url': REFERENCE_URL, 'driver_sha256': hashlib.sha256(driver.read_bytes()).hexdigest(),
              'results': rows}
    (output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'results'}))
    return 0 if report['status'] == 'passed_scoped_checks' else 1


if __name__ == '__main__':
    raise SystemExit(main())
