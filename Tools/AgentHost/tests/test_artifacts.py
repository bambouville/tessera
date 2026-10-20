#!/usr/bin/env python3
import hashlib
import json
import re
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_artifacts import TARGETS, validate


class ArtifactTests(unittest.TestCase):
    def test_bundled_simdjson_notice_matches_selected_mit_option(self):
        root = Path(__file__).resolve().parents[3]
        notices = (root / 'SharedAssets/agent-host/THIRD-PARTY-NOTICES.txt').read_text()
        selected = notices.split('simdjson 4.6.4 (MIT option)', 1)[1].split('musl libc', 1)[0]
        self.assertIn('Permission is hereby granted, free of charge', selected)
        self.assertNotIn('Apache License', selected)

    def test_bundled_reader_revision_invalidates_old_host_installations(self):
        root = Path(__file__).resolve().parents[3]
        manifest = json.loads((root / 'SharedAssets/agent-host/manifest.json').read_text())
        revision = (root / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentHostBuildRevision.swift').read_text()
        self.assertIn('"' + manifest['sourceSHA256'] + '"', revision)
        for entry in manifest['artifacts']:
            self.assertIn('"' + entry['target'] + '": "' + entry['sha256'] + '"', revision)
        installer = (root / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift').read_text()
        self.assertIn('Native reader bundle: \\#(AgentHostBuildRevision.sourceSHA256)', installer)

    def test_bundled_reader_ships_under_its_own_integration_version(self):
        # Apps order host installations by integration version alone. A rebuilt
        # reader under a released version gives two builds one version, and
        # each replaces the other's installation on every connection.
        root = Path(__file__).resolve().parents[3]
        manifest = json.loads((root / 'SharedAssets/agent-host/manifest.json').read_text())
        installer = (root / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift').read_text()
        version = int(re.search(r'public static let integrationVersion = (\d+)\n', installer).group(1))
        releases = {int(number): revision for number, revision in re.findall(
            r'^        (\d+): \.init\(fingerprint: "[0-9a-f]{64}", eventVersion: \d+, nativeRevision: "([0-9a-f]{64})"\),$',
            installer, re.M)}
        self.assertIn(10, releases, 'integrationReleases no longer parses')
        self.assertEqual(max(releases), version, f'Record {version} in integrationReleases; '
                         'AgentIntegrationVersioningTests prints the entry.')
        self.assertEqual(releases[version], manifest['sourceSHA256'],
                         f'The bundled native host was rebuilt: set integrationVersion to {version + 1} and record it '
                         'in integrationReleases; AgentIntegrationVersioningTests prints the entry.')

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tessera-artifact-test-')
        self.root = Path(self.temporary.name)
        self.manifest = dict(schema=1, protocol=3, simdjson='4.6.4', sqlite='3.53.4', sourceSHA256='synthetic', artifacts=[])
        for target in TARGETS:
            data = bytearray(512)
            if target.startswith('darwin-'):
                struct.pack_into('<IIII', data, 0, 0xFEEDFACF, 0x0100000C if target.endswith('arm64') else 0x01000007, 0, 2)
                struct.pack_into('<II', data, 16, 3, 120)
                struct.pack_into('<II', data, 32, 0x19, 72)
                struct.pack_into('<QQQQII', data, 56, 0x100000000, 256, 0, 256, 5, 5)
                struct.pack_into('<IIQ', data, 104, 0x80000028, 24, 200)
                struct.pack_into('<IIII', data, 128, 0x32, 24, 1, 12 << 16)
            else:
                data[:7] = b'\x7fELF\x02\x01\x01'
                struct.pack_into('<HH', data, 16, 3, 183 if target.endswith('aarch64') else 62)
                struct.pack_into('<Q', data, 32, 64)
                struct.pack_into('<HH', data, 54, 56, 3)
                struct.pack_into('<Q', data, 24, 0x4000C0)
                struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0x400000, 0x400000, 256, 256, 4096)
                struct.pack_into('<IIQQQQQQ', data, 120, 0x6474e552, 4, 0, 0, 0, 0, 0, 1)
                struct.pack_into('<IIQQQQQQ', data, 176, 0x6474e551, 6, 0, 0, 0, 0, 0, 1)
            name = 'tessera-agent-host-' + target
            (self.root / name).write_bytes(data)
            self.manifest['artifacts'].append(dict(target=target, file=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
        (self.root / 'THIRD-PARTY-NOTICES.txt').write_text('SQLite 3.53.4 shlex 1.3.0 simdjson 4.6.4 musl libc LLVM libc++ LLVM libunwind Zig compiler runtime')
        self.save()

    def tearDown(self): self.temporary.cleanup()
    def save(self): (self.root / 'manifest.json').write_text(json.dumps(self.manifest))
    def check(self): validate(self.root, 'synthetic')

    def test_complete_matrix(self): self.check()

    def test_partial_matrix(self):
        self.manifest['artifacts'].pop(); self.save()
        with self.assertRaisesRegex(ValueError, 'four targets'): self.check()

    def test_duplicate_target(self):
        self.manifest['artifacts'][-1] = self.manifest['artifacts'][0]; self.save()
        with self.assertRaisesRegex(ValueError, 'four targets'): self.check()

    def test_stale_sources(self):
        with self.assertRaisesRegex(ValueError, 'stale'): validate(self.root, 'changed')

    def test_tampered_binary(self):
        (self.root / self.manifest['artifacts'][0]['file']).write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'integrity'): self.check()

    def test_path_escape(self):
        self.manifest['artifacts'][0]['file'] = '../untrusted'; self.save()
        with self.assertRaisesRegex(ValueError, 'filename'): self.check()

    def test_symlink(self):
        path = self.root / self.manifest['artifacts'][0]['file']
        path.rename(self.root / 'old'); path.symlink_to(self.root / 'old')
        with self.assertRaisesRegex(ValueError, 'regular'): self.check()

    def test_foreign_architecture_and_dynamic_interpreter(self):
        row = self.manifest['artifacts'][-1]; path = self.root / row['file']
        for offset, value, message in ((18, 183, 'architecture'), (64, 3, 'interpreter')):
            original = path.read_bytes(); data = bytearray(original)
            struct.pack_into('<H' if offset == 18 else '<I', data, offset, value)
            path.write_bytes(data); row['sha256'] = hashlib.sha256(data).hexdigest(); self.save()
            with self.assertRaisesRegex(ValueError, message): self.check()
            path.write_bytes(original)

    def test_missing_licenses(self):
        (self.root / 'THIRD-PARTY-NOTICES.txt').write_text('incomplete')
        with self.assertRaisesRegex(ValueError, 'license'): self.check()

    def test_missing_display_quoting_port_license(self):
        notices = self.root / 'THIRD-PARTY-NOTICES.txt'
        notices.write_text(notices.read_text().replace('shlex 1.3.0', ''))
        with self.assertRaisesRegex(ValueError, 'license'): self.check()

    def test_non_executable_elf_and_dynamic_shared_object(self):
        row = self.manifest['artifacts'][-1]; path = self.root / row['file']
        for offset, fmt, value, message in ((16, '<H', 2, 'ET_DYN'), (24, '<Q', 0, 'entry'),
                                           (64, '<I', 2, 'entry'), (96, '<Q', 1000, 'segment')):
            original = path.read_bytes(); data = bytearray(original)
            struct.pack_into(fmt, data, offset, value)
            path.write_bytes(data); row['sha256'] = hashlib.sha256(data).hexdigest(); self.save()
            with self.assertRaisesRegex(ValueError, message): self.check()
            path.write_bytes(original)

    def test_macho_load_bounds_and_deployment(self):
        row = self.manifest['artifacts'][0]; path = self.root / row['file']
        for offset, value in ((20, 10000), (36, 7), (140, 14 << 16)):
            original = path.read_bytes(); data = bytearray(original); struct.pack_into('<I', data, offset, value)
            path.write_bytes(data); row['sha256'] = hashlib.sha256(data).hexdigest(); self.save()
            with self.assertRaisesRegex(ValueError, 'Mach-O'): self.check()
            path.write_bytes(original)


if __name__ == '__main__': unittest.main()
