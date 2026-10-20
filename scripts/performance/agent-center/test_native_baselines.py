#!/usr/bin/env python3
"""Validate native framing against Python JSONL parsing on private fixtures.

Usage: test_native_baselines.py /path/to/getline-binary /path/to/chunked-binary
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARIES = [str(Path(value).resolve()) for value in sys.argv[1:]]
if len(BINARIES) != 2:
    raise SystemExit(__doc__)
sys.argv[1:] = []


class NativeReaderTests(unittest.TestCase):
    def test_complete_partial_empty_unicode_and_chunk_boundaries(self):
        fixtures = [
            b"", b"{}", b"{}\n", b"\n", b"{}\n\n[]\n",
            b'{"bad":}\n{}\n', b'{"text":"nul\x00byte"}\n',
            '{"text":"café 😀"}\n{"text":"escaped \\" quote"}\n'.encode(),
        ]
        fixtures += [b'{"text":"' + b"a" * size + b'"}\n{}\n'
                     for size in (65525, 65526, 65527, 65535, 65536, 65537, 2 * 1024 * 1024)]
        for index, data in enumerate(fixtures):
            valid = invalid = 0
            for line in data.splitlines(keepends=True):
                try:
                    json.loads(line)
                    valid += 1
                except (ValueError, UnicodeDecodeError):
                    invalid += 1
            with tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "fixture.jsonl"
                path.write_bytes(data)
                for binary in BINARIES:
                    with self.subTest(fixture=index, binary=Path(binary).name):
                        output = subprocess.check_output([binary, str(path)], timeout=10)
                        row = json.loads(output)[0]
                        self.assertEqual(row["bytes_scanned"], len(data))
                        self.assertEqual(row["valid_records"], valid)
                        self.assertEqual(row["invalid_records"], invalid)


if __name__ == "__main__":
    unittest.main()
