#!/usr/bin/env python3
"""Release-side compilation only; never run on a user's connected host.

Build on macOS with Xcode clang and Zig 0.15.2. Outputs all four executable
resources and a SHA-256 manifest; no provider data or host credentials used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from validate_artifacts import source_digest, validate

ROOT = Path(__file__).resolve().parent
SOURCE_HASH = '826660ed60cf467641ab2f93a0e1a2dacf603c444f76d835358c814bc2caba3a'
HEADER_HASH = 'fec0cb4559e25456789efb153b7e5eaa27b50ce2bc2c9d3b531ea2000928380a'
SQLITE_SOURCE_HASH = 'b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189'
SQLITE_HEADER_HASH = '919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d'
TARGETS = ('darwin-arm64', 'darwin-x86_64', 'linux-aarch64', 'linux-x86_64')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', required=True)
    parser.add_argument('--simdjson-source', type=Path, required=True)
    parser.add_argument('--simdjson-header', type=Path, required=True)
    parser.add_argument('--sqlite-source', type=Path, required=True)
    parser.add_argument('--sqlite-header', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--simdjson-license', type=Path, required=True)
    parser.add_argument('--notices-only', action='store_true')
    parser.add_argument('--target', choices=TARGETS, action='append')
    args = parser.parse_args()
    if hashlib.sha256(args.simdjson_source.read_bytes()).hexdigest() != SOURCE_HASH:
        raise SystemExit('simdjson 4.6.4 source checksum mismatch')
    if hashlib.sha256(args.simdjson_header.read_bytes()).hexdigest() != HEADER_HASH:
        raise SystemExit('simdjson 4.6.4 header checksum mismatch')
    if hashlib.sha256(args.sqlite_source.read_bytes()).hexdigest() != SQLITE_SOURCE_HASH or hashlib.sha256(args.sqlite_header.read_bytes()).hexdigest() != SQLITE_HEADER_HASH:
        raise SystemExit('SQLite 3.53.4 source/header checksum mismatch')
    if subprocess.check_output([args.zig, 'version'], text=True).strip() != '0.15.2':
        raise SystemExit('Zig 0.15.2 is required')
    args.output.mkdir(parents=True, exist_ok=True)
    zig_root = Path(args.zig).resolve().parent
    licenses = [('shlex 1.3.0 display-quoting port (MIT option)', ROOT / 'licenses/shlex-MIT.txt'),
                ('SQLite 3.53.4 (public domain)', ROOT / 'licenses/sqlite-public-domain.txt'),
                ('simdjson 4.6.4 (MIT option)', args.simdjson_license),
                ('musl libc', zig_root / 'lib/libc/musl/COPYRIGHT'),
                ('LLVM libc++', zig_root / 'lib/libcxx/LICENSE.TXT'),
                ('LLVM libc++abi', zig_root / 'lib/libcxxabi/LICENSE.TXT'),
                ('LLVM libunwind', zig_root / 'lib/libunwind/LICENSE.TXT'),
                ('Zig compiler runtime', zig_root / 'LICENSE')]
    (args.output / 'THIRD-PARTY-NOTICES.txt').write_text('\n\n'.join(title + '\n\n' + path.read_text() for title, path in licenses))
    if args.notices_only: return
    entries = []
    initial_source = source_digest()
    with tempfile.TemporaryDirectory(prefix='tessera-artifact-build-') as temporary:
        directory = Path(temporary)
        shutil.copyfile(args.simdjson_header, directory / 'simdjson.h')
        shutil.copyfile(args.simdjson_source, directory / 'simdjson.cpp')
        shutil.copyfile(args.sqlite_header, directory / 'sqlite3.h')
        sources = [str(path) for path in sorted((ROOT / 'src').glob('*.cpp'))] + [str(directory / 'simdjson.cpp')]
        for target in args.target or TARGETS:
            output = args.output / ('tessera-agent-host-' + target)
            if target.startswith('darwin-'):
                arch = target.split('-')[1]
                command = ['xcrun', 'clang++', '-arch', arch, '-mmacosx-version-min=12.0']
                sqlite_command = ['xcrun', 'clang', '-arch', arch, '-mmacosx-version-min=12.0']
                platform = {'minimumOS': 'macOS 12', 'libc': 'system', 'cpu': arch}
            else:
                arch = target.split('-')[1]
                command = [args.zig, 'c++', '-target', arch + '-linux-musl', '-mcpu=baseline', '-static', '-fPIE', '-pie', '-Wl,-z,relro,-z,now,-z,noexecstack', '-s']
                sqlite_command = [args.zig, 'cc', '-target', arch + '-linux-musl', '-mcpu=baseline']
                platform = {'minimumOS': 'Linux 4.19', 'libc': 'static musl (glibc and musl hosts)', 'cpu': arch + ' baseline'}
            # Zig's LLVM20 AVX512 feature spelling differs from this simdjson
            # release. Keep Westmere/Haswell runtime dispatch and the baseline
            # fallback; never enable AVX512 globally to bypass that mismatch.
            hardening = ['-fstack-protector-strong', '-D_FORTIFY_SOURCE=2']
            command += hardening
            sqlite_command += hardening + ['-fPIE']
            command += ['-DSIMDJSON_IMPLEMENTATION_ICELAKE=0', '-std=c++17', '-O2', '-DNDEBUG', '-pthread', '-I', str(directory), '-I', str(ROOT / 'src')]
            sqlite_object = directory / ('sqlite-' + target + '.o')
            sqlite_command += ['-std=c11', '-O2', '-DNDEBUG', '-D_GNU_SOURCE', '-DSQLITE_THREADSAFE=1',
                '-DSQLITE_OMIT_LOAD_EXTENSION=1', '-DSQLITE_DQS=0', '-DSQLITE_DEFAULT_MEMSTATUS=1',
                '-DSQLITE_TEMP_STORE=3', '-DSQLITE_MAX_MMAP_SIZE=0', '-c', str(args.sqlite_source), '-o', str(sqlite_object)]
            command += sources + [str(sqlite_object), '-o', str(output)]
            print('Building ' + target, flush=True)
            subprocess.run(sqlite_command, check=True)
            subprocess.run(command, check=True)
            if target.startswith('darwin-'):
                subprocess.run(['xcrun', 'strip', '-S', str(output)], check=True)
                subprocess.run(['codesign', '--force', '--sign', '-', str(output)], check=True)
            contents = output.read_bytes()
            if not 0 < len(contents) <= 16 * 1024 * 1024: raise SystemExit('artifact exceeds installation budget')
            entries.append(dict(target=target, file=output.name, bytes=len(contents),
                                sha256=hashlib.sha256(contents).hexdigest(), **platform))
    if source_digest() != initial_source: raise SystemExit('native sources changed during compilation; rebuild required')
    manifest = {'schema': 1, 'version': '0.1.0', 'protocol': 3, 'simdjson': '4.6.4',
                'sqlite': '3.53.4', 'sourceSHA256': initial_source, 'artifacts': entries}
    # A developer's partial build is never a publishable release manifest.
    complete = len(entries) == 4 and {entry['target'] for entry in entries} == set(TARGETS)
    (args.output / ('manifest.json' if complete else 'partial-manifest.json')).write_text(json.dumps(manifest, indent=2) + '\n')
    if complete: validate(args.output, initial_source)
    if complete and args.output.resolve() == (ROOT.parent.parent / 'SharedAssets/agent-host').resolve():
        revision = ROOT.parent.parent / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentHostBuildRevision.swift'
        revision.write_text('// Generated by Tools/AgentHost/build_artifacts.py for the complete bundled matrix.\n'
            '// Include in lifecycle installation checksums so a native-only app update is\n'
            '// not mistaken for an already-current host installation.\n'
            'enum AgentHostBuildRevision {\n'
            f'    static let sourceSHA256 = "{initial_source}"\n'
            '    static let artifacts = [\n' + ''.join(
                f'        "{entry["target"]}": "{entry["sha256"]}",\n' for entry in entries) +
            '    ]\n}\n')


if __name__ == '__main__':
    main()
