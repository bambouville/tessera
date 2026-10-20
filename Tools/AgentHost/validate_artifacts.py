#!/usr/bin/env python3
"""Fail-closed release gate for the complete bundled native host matrix.

Inspects foreign binaries without executing them. Checksums provide integrity
inside the signed app distribution, not independent publisher authentication.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parent
TARGETS = ('darwin-arm64', 'darwin-x86_64', 'linux-aarch64', 'linux-x86_64')


def source_digest(root=ROOT):
    digest = hashlib.sha256()
    paths = [root / 'build_artifacts.py', root / 'validate_artifacts.py', *sorted((root / 'src').glob('*')),
             *sorted((root / 'licenses').glob('*'))]
    for path in paths:
        if path.is_file(): digest.update(str(path.relative_to(root)).encode() + b'\0' + path.read_bytes())
    return digest.hexdigest()


def validate_binary(data, target):
    if target.startswith('darwin-'):
        expected = 0x0100000C if target == 'darwin-arm64' else 0x01000007
        if len(data) < 32 or struct.unpack_from('<III', data)[:2] != (0xFEEDFACF, expected):
            raise ValueError('Mach-O architecture mismatch')
        if struct.unpack_from('<I', data, 12)[0] != 2: raise ValueError('Mach-O is not executable')
        count, size = struct.unpack_from('<II', data, 16)
        if not 0 < count < 1024 or 32 + size > len(data): raise ValueError('Mach-O load commands invalid')
        position = 32; entry = None; deployment = False; executable = []
        for _ in range(count):
            if position + 8 > 32 + size: raise ValueError('Mach-O load commands invalid')
            command, length = struct.unpack_from('<II', data, position)
            if length < 8 or length % 8 or position + length > 32 + size: raise ValueError('Mach-O load commands invalid')
            if command == 0x19:  # LC_SEGMENT_64
                if length < 72: raise ValueError('Mach-O segment invalid')
                _, memory, offset, length_file = struct.unpack_from('<QQQQ', data, position + 24)
                protection = struct.unpack_from('<I', data, position + 60)[0]
                if length_file > memory or offset + length_file > len(data): raise ValueError('Mach-O segment invalid')
                if protection & 4: executable.append((offset, offset + length_file))
            elif command == 0x80000028:  # LC_MAIN
                if length != 24 or entry is not None: raise ValueError('Mach-O entry invalid')
                entry = struct.unpack_from('<Q', data, position + 8)[0]
            elif command == 0x32:  # LC_BUILD_VERSION
                if length < 24: raise ValueError('Mach-O deployment invalid')
                platform, minimum = struct.unpack_from('<II', data, position + 8)
                if platform != 1 or minimum > 12 << 16: raise ValueError('Mach-O deployment invalid')
                deployment = True
            elif command in (0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023, 0xE):
                if length < 16: raise ValueError('Mach-O dependency invalid')
                offset = struct.unpack_from('<I', data, position + 8)[0]
                if offset < 12 or offset >= length: raise ValueError('Mach-O dependency invalid')
                name = data[position + offset:position + length].split(b'\0', 1)[0]
                if name not in (b'/usr/lib/libc++.1.dylib', b'/usr/lib/libSystem.B.dylib', b'/usr/lib/dyld'):
                    raise ValueError('Mach-O non-system dependency')
            elif command == 0x8000001C: raise ValueError('Mach-O runtime search path forbidden')
            position += length
        if position != 32 + size or not deployment or entry is None or not any(start <= entry < end for start, end in executable):
            raise ValueError('Mach-O executable entry or deployment missing')
    else:
        expected = 183 if target == 'linux-aarch64' else 62
        if len(data) < 64 or data[:7] != b'\x7fELF\x02\x01\x01': raise ValueError('ELF format mismatch')
        kind, machine = struct.unpack_from('<HH', data, 16)
        if machine != expected: raise ValueError('ELF architecture mismatch')
        if kind != 3: raise ValueError('Linux artifact must be a static PIE ET_DYN executable')
        offset = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
        if size != 56 or not 0 < count < 1024 or offset + size * count > len(data):
            raise ValueError('ELF program headers invalid')
        entry = struct.unpack_from('<Q', data, 24)[0]; executable = []
        relro = False; nonexec_stack = False
        for n in range(count):
            segment, flags, start, address, _, files, memory, _ = struct.unpack_from('<IIQQQQQQ', data, offset + size * n)
            if files > memory or start + files > len(data): raise ValueError('ELF load segment invalid')
            if segment == 3: raise ValueError('Linux artifact requires a dynamic interpreter')
            if segment == 2:
                if files % 16: raise ValueError('ELF dynamic segment invalid')
                for at in range(start, start + files, 16):
                    tag, value = struct.unpack_from('<QQ', data, at)
                    if tag == 0: break
                    if tag == 1: raise ValueError('Linux artifact has a shared-library dependency')
            if segment == 0x6474e552: relro = True
            if segment == 0x6474e551: nonexec_stack = not (flags & 1)
            if files > memory or start + files > len(data): raise ValueError('ELF load segment invalid')
            if segment == 1 and flags & 1: executable.append((address, address + files))
        if not entry or not any(start <= entry < end for start, end in executable): raise ValueError('ELF executable entry missing')
        if not relro or not nonexec_stack: raise ValueError('ELF hardening missing')


def validate(directory, expected_source=None):
    manifest = json.loads((directory / 'manifest.json').read_text())
    if not isinstance(manifest, dict) or (manifest.get('schema'), manifest.get('protocol'), manifest.get('simdjson')) != (1, 3, '4.6.4'):
        raise ValueError('unsupported manifest')
    if manifest.get('sqlite') != '3.53.4': raise ValueError('unsupported SQLite build')
    if expected_source is not None and manifest.get('sourceSHA256') != expected_source:
        raise ValueError('bundled binaries are stale relative to native sources')
    entries = manifest.get('artifacts')
    if not isinstance(entries, list) or len(entries) != 4 or {row.get('target') for row in entries} != set(TARGETS):
        raise ValueError('release must contain exactly all four targets')
    for row in entries:
        name = 'tessera-agent-host-' + row['target']
        if row.get('file') != name: raise ValueError('artifact filename mismatch')
        path = directory / name
        if path.is_symlink() or not path.is_file(): raise ValueError('artifact must be a regular bundled file')
        if not 0 < path.stat().st_size <= 16 * 1024 * 1024: raise ValueError('artifact size budget')
        data = path.read_bytes()
        if len(data) != row.get('bytes') or hashlib.sha256(data).hexdigest() != row.get('sha256'):
            raise ValueError('artifact integrity mismatch')
        validate_binary(data, row['target'])
    notices = directory / 'THIRD-PARTY-NOTICES.txt'
    if notices.is_symlink() or not notices.is_file() or not 0 < notices.stat().st_size <= 262144:
        raise ValueError('missing or invalid license notices')
    text = notices.read_text()
    if any(name not in text for name in ('SQLite 3.53.4', 'shlex 1.3.0', 'simdjson 4.6.4', 'musl libc', 'LLVM libc++', 'LLVM libunwind', 'Zig compiler runtime')):
        raise ValueError('incomplete license notices')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    validate(args.directory, source_digest())
    print('All four native artifacts match their source, architecture, integrity and license matrix.')
