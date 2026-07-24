---
title: host key verification
nav: 6
description: Trust-on-first-use verification, changed-key warnings, and the known hosts page.
---

# host key verification

Tessera uses trust-on-first-use (TOFU): the first connection to a server pins
its host key, and every later connection is checked against that pin.

## first connection

The first time you connect to a server, Tessera blocks with an **Unknown
Host** sheet showing:

- the endpoint (address and port),
- the **server fingerprint** (SHA-256, OpenSSH-compatible),
- the **key type**.

Verify the fingerprint against a source you trust — your provider's dashboard,
or on the server itself:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Then tap **Accept New Key** to pin it, or **Reject** to abort. Until a host's
key is trusted, Tessera won't install keys on it, and the
[files](files.md) panel will ask you to open a terminal session first.

## a changed host key

If a server's key ever differs from the pinned one, Tessera shows **HOST KEY
CHANGED** with the classic "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!"
notice, the old and new fingerprints, and **Trust** / **Reject** buttons.

Treat this as a possible man-in-the-middle attack unless you know why it
changed — legitimate reasons include reinstalling the server, replacing it, or
rotating its host keys deliberately.

## the known hosts page

The sidebar's **known hosts** page lists every pinned key: host, algorithm,
date added, and status. Filter chips narrow the list:

- **verified** — pinned and matching,
- **stale** — not seen in 90 days,
- **changed** — a different key was seen; a red banner marks the mismatch.

Expand a row to see its fingerprints, **copy fingerprint**, **accept new key**
(after a legitimate change), or **remove** the pin. Removing a pin means the
next connection is treated as a first connection again.

Pins are stored in `known_hosts.json` in the app's Application Support
directory, keyed by `address:port`, with OpenSSH-compatible SHA-256
fingerprints.

> The page header shows **export** / **import** buttons; they aren't wired up
> yet and currently do nothing.
