---
title: keys
nav: 5
description: Generate, import, protect, install, and recover SSH keys — all inside the iOS Keychain.
---

# Keys

The **keys** page (sidebar) manages your SSH keys. Private key bytes live only
in the iOS Keychain — Tessera stores just public metadata (names, fingerprints,
usage) in its own database.

## Generating a key

Tap **+ generate** and pick an algorithm:

- **Ed25519** — "fast, modern default". A software key stored in the Keychain;
  it can be exported to a recovery file and moved between devices.
- **P-256 Enclave** — "device-bound". Generated inside the Secure Enclave and
  **never leaves it**: the key cannot be exported or moved to another device.
  Lose the iPad and the key is gone — keep a second authorized key somewhere.

RSA generation is not supported; see
[troubleshooting](troubleshooting.md#rsa-keys-are-not-supported).

## Importing a key

Tap **import** and pick an OpenSSH private-key file (up to 1 MB). If the file
is passphrase-protected, the passphrase is used once to decrypt it and is not
retained.

- Only **Ed25519** imports are accepted. RSA import is disabled because the
  current SSH stack can only offer the deprecated RSA/SHA-1 signature — use
  Ed25519 instead.
- The import sheet hides itself ("private-key import hidden") whenever the
  screen is captured or the app is backgrounded.

## Biometric protection

Each key has a **require biometrics or passcode** toggle: Face ID / Touch ID or
the device passcode is then required whenever Tessera accesses that key,
enforced by iOS at the Keychain/Secure Enclave boundary.

### Authorization bursts

Under **settings → security → authorize key connection bursts**, a single
biometric grant may cover repeated connections using the same key to the same
endpoint for 30 seconds — so tmux tabs and file transfers don't each prompt.
Backgrounding the app always invalidates these grants, even when
[app lock](security.md) is off.

P-256 Enclave keys have their protection fixed at creation; to change it,
generate a new key and rotate.

## The key detail panel

Tap a key to see its type, **fingerprint (sha256)** (OpenSSH-compatible), and
public key. From here you can:

- **copy public key** — the `authorized_keys` line.
- **copy to host…** — install it on a server (below).
- **export private key…** — Ed25519 only; writes a passphrase-encrypted
  `openssh-key-v1` recovery file.
- **delete local private key…** — see [deletion](#deleting-a-key).

A **used by** section lists the hosts that reference the key.

## Installing a key on a host

**copy to host…** picks a host, shows the exact `authorized_keys` line, and
appends it to `~/.ssh/authorized_keys` over SSH, with verification markers.

- You must have [trusted the host key](host-keys.md) first: connect once to
  review it, then retry.
- Tessera refuses to install a key onto a host that already uses that key for
  authentication.
- Completed installations are tracked, and the deletion flow reports them
  ("Known remote installations: N").

## Export and recovery

The **recovery** section of a key tracks its backup state — whether a verified
recovery export exists (with date and fingerprint), and for Enclave keys a
standing reminder that Secure Enclave private material cannot leave the
device.

- **protect recovery key…** — export with a passphrase.
- **verify recovery file…** — check that a recovery file still matches the key.
- **restore from recovery file…** — fingerprint-verified repair of missing or
  mismatched Keychain material (e.g. after a restore from backup).

Back up software keys before installing them widely — an unrecoverable key
means locking yourself out as passwords get disabled.

## Deleting a key

**delete local private key…** removes the key from the Keychain after
confirmation. Deleting locally **does not revoke** any `authorized_keys` entry
on your servers — where a tracked host has an alternate credential available,
the deletion flow offers "revoke on N tracked hosts & delete" to remove them
for you; otherwise remove the corresponding lines on each server yourself if
the key should stop working.

Legacy RSA keys left over from older versions are shown disabled.

## Where the bytes are

- Software Ed25519 keys: iOS Keychain (non-synchronizing).
- P-256 keys: Secure Enclave, non-exportable by design.
- Tessera's own database: public keys, fingerprints, labels, usage — never
  private material.

For the full hardening story, see the public
[private-key security audit](https://github.com/bambouville/tessera/blob/main/docs/private-key-security-audit.md).
