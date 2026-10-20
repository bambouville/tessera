#!/usr/bin/env python3
"""Revoke one fingerprint without rewriting an account's authorized_keys.

The production installer appends without a lock. A rename/truncate cleanup can
lose an unrelated concurrent append. Blank only the owned record in place,
preserving its byte length and every other record/offset. Blank lines are
intentional: they contain no key material and grant no access.
"""
import base64
import fcntl
import hashlib
import os
import pwd
import sys


def fingerprint(line):
    fields = line.strip().split()
    if len(fields) < 2 or fields[0].startswith(b"#"):
        return None
    # This fixture installs bare public keys, never authorized_keys options.
    if fields[0] not in (b"ssh-ed25519", b"ecdsa-sha2-nistp256"):
        return None
    try:
        blob = base64.b64decode(fields[1], validate=True)
    except ValueError:
        return None
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def revoke(path, expected, before_write=lambda: None):
    # Serialize our removals. Appending writers need not participate: we never
    # truncate, replace, or write beyond the exact owned record's byte range.
    with open(path, "r+b", buffering=0) as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        offset = 0
        removed = 0
        for line in stream:
            if fingerprint(line) == expected:
                before_write()
                if os.pread(stream.fileno(), len(line), offset) != line:
                    raise RuntimeError("authorized_keys changed in place; refusing stale offsets")
                if os.stat(path).st_ino != os.fstat(stream.fileno()).st_ino:
                    raise RuntimeError("authorized_keys was replaced; retry cleanup on current file")
                replacement = b" " * (len(line) - int(line.endswith(b"\n")))
                if line.endswith(b"\n"):
                    replacement += b"\n"
                if os.pwrite(stream.fileno(), replacement, offset) != len(replacement):
                    raise RuntimeError("short key revocation write")
                removed += 1
            offset += len(line)
        os.fsync(stream.fileno())
        if os.stat(path).st_ino != os.fstat(stream.fileno()).st_ino:
            raise RuntimeError("authorized_keys was replaced; cleanup must be retried")
    with open(path, "rb") as check:
        if any(fingerprint(line) == expected for line in check):
            raise RuntimeError("owned key remains after revocation")
    return removed


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--user":
        path = os.path.join(pwd.getpwnam(sys.argv[2]).pw_dir, ".ssh/authorized_keys")
        expected = sys.argv[3]
    elif len(sys.argv) == 3:
        path, expected = sys.argv[1:]
    else:
        raise SystemExit("usage: revoke-qr-fixture-key.py AUTHORIZED_KEYS SHA256_FINGERPRINT")
    print(f"revoked={revoke(path, expected)} fingerprint={expected}")
