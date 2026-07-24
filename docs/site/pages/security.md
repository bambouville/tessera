---
title: security & app lock
nav: 13
description: App lock, biometric key protection, host-key verification, and diagnostics.
---

# security & app lock

## app lock

Under **settings → security**, **require device owner authentication to
unlock** gates the whole app behind Face ID (with device-passcode fallback).
You choose when it engages:

- on launch, when enabled at all,
- **lock when backgrounded**,
- **auto-lock after idle** — never, 1, 5, or 15 minutes, or 1 hour.

The lock screen shows "— locked —"; tap to unlock with Face ID or the device
passcode.

Locking is not cosmetic: it revokes every cached key-use authorization and
cancels in-flight SSH handshakes. Even with app lock off, backgrounding the
app always invalidates the 30-second
[key authorization bursts](keys.md#authorization-bursts).

## keys

Private keys live in the iOS Keychain; P-256 Enclave keys never leave the
Secure Enclave and can require biometrics per use. See [keys](keys.md), and
for the full detail the public
[private-key security audit](https://github.com/bambouville/tessera/blob/main/docs/private-key-security-audit.md).

## host keys

Every server is pinned on first contact and re-verified on every connection;
changed keys raise a loud warning. See [host key verification](host-keys.md).

## privacy

Tessera has no backend, no account, no analytics — connections go directly
from your iPad to your machines. The [privacy policy](privacy.md) has the
details.

## diagnostics

**settings → diagnostics** can write a local log (`tessera-diagnostics.log`,
capped at 20 MB, redacted) to help with troubleshooting, with **verbose
diagnostics** and **scroll diagnostics** toggles for deeper captures.

- **export log** — sends it through the iOS share sheet, to a destination you
  choose. It never leaves the device automatically.
- **upload log** — sends it to one of your own servers through the
  Upload-to-host sheet. It is never sent to the developers.
- **refresh** / **clear**.

Bug reports go to [GitHub Issues](https://github.com/bambouville/tessera/issues).
