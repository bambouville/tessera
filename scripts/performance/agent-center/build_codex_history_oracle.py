#!/usr/bin/env python3
"""Build the primary upstream history oracle in a private, explicit directory.

No upstream source is edited and no provider process/session is started.
Requires an externally selected compiler matching upstream rust-toolchain.toml.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Codex repository root')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cargo', type=Path, required=True)
    parser.add_argument('--target-dir', type=Path, help='Optional private build cache for subsequent oracle builds')
    args = parser.parse_args()
    source = args.source.resolve(strict=True); output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]): parser.error('oracle output must be outside Git')
    if output.exists(): parser.error('output must not already exist')
    target = (args.target_dir or output / 'target').resolve()
    if any((parent / '.git').exists() for parent in [target, *target.parents]): parser.error('build cache must be outside Git')
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=no']):
        parser.error('primary source must have no tracked modifications')
    os.umask(0o077); output.mkdir(mode=0o700, parents=True)
    code = Path(__file__).with_name('CodexHistoryOracle.rs')
    shutil.copy2(code, output / 'main.rs')
    manifest = '\n'.join(['[package]', 'name = "tessera-codex-history-oracle"', 'version = "0.0.0"',
        'edition = "2024"', '[workspace]', '[[bin]]', 'name = "tessera-codex-history-oracle"', 'path = "main.rs"',
        '[dependencies]', 'serde_json = "1"',
        'codex-app-server-protocol = { path = ' + json.dumps(str(source / 'codex-rs/app-server-protocol')) + ' }',
        'codex-protocol = { path = ' + json.dumps(str(source / 'codex-rs/protocol')) + ' }',
        '[profile.dev]', 'debug = 0', 'incremental = false', ''])
    (output / 'Cargo.toml').write_text(manifest)
    shutil.copy2(source / 'codex-rs/Cargo.lock', output / 'Cargo.lock')
    # Bound parallel compilation. All build/dependency output paths are chosen
    # by the invoking test environment, never by a transcript or provider.
    subprocess.run([str(args.cargo.resolve()), 'build', '--manifest-path', str(output / 'Cargo.toml'),
                    '--target-dir', str(target), '-j', '2'],
                   cwd=output, check=True)
    executable = target / 'debug/tessera-codex-history-oracle'
    evidence = dict(upstream_revision=revision,
        bridge_sha256=hashlib.sha256((output / 'main.rs').read_bytes()).hexdigest(),
        lock_sha256=hashlib.sha256((output / 'Cargo.lock').read_bytes()).hexdigest(),
        executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest())
    (output / 'build-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence))


if __name__ == '__main__': main()
