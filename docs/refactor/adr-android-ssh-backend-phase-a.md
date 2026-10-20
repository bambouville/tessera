# ADR: Android SSH backend after the shared refactor

**Status:** Accepted for implementation; physical-device acceptance gates remain open
**Date:** August 24, 2026
**Decision owner:** Phase A Android portability/backend gate

## Decision

Use an `AndroidNativeSSHBackend` backed by a narrowly maintained SSHJ adapter
for Android. Keep Citadel/NIOSSH as the Apple SSH implementation and behind the
same session, trust, signer, and route contracts. Do not put SSH policy, tmux,
pairing, or enrollment behavior into the Android backend.

Pin the starting Android dependency to SSHJ `0.40.0`, official tag commit
`1398b190ec26eaec6bde49592170d293494bd851`. Exclude the unused transitive
`org.bouncycastle` artifacts and use Android platform JCA providers.

This chooses the backend split, not release readiness. Phase B must replace the
current RSA-host-key experiment guard with a maintained upstream/fork fix for
stock-Android Ed25519 and ECDSA host-key decoding, then run the same direct and
jump scenarios with Ed25519, ECDSA P-256, and RSA host keys. A backend that only
connects to RSA-host-key servers must not ship.

## Evidence

### Shared Swift candidate

- Toolchain: Swift `6.3.3`, Android Swift SDK
  `aarch64-unknown-linux-android28`, NDK `28.2.13676358`.
- Citadel and the resolved SwiftNIO, NIOSSH, Swift Crypto, BigInt, and Swift Log
  graph compile for Android arm64.
- A stripped, static-Swift executable was `60.5 MiB` and completed password
  authentication, exec, PTY open/output, and resize `80x24 -> 132x43` against
  the stable fixture on an Android 16 arm64 emulator.
- The standard NIOSSH P-256 path requires a Swift Crypto private key. Its custom
  key protocol requires a unique, nonstandard algorithm prefix, and its external
  Secure Enclave P-256 implementation is Darwin-only. Standard
  `ecdsa-sha2-nistp256` authentication with Android Keystore therefore needs a
  maintained NIOSSH change plus a synchronous Swift-to-JVM signing bridge.

The shared candidate proves portability, but it fails the stock signer boundary
and carries a large static runtime. It is not the Android product backend.

### Native Android candidate

- Toolchain: AGP `9.3.2`, Kotlin `2.3.21`, JDK `17`, min API `28`, Android 16
  arm64 emulator.
- SSHJ `0.40.0` accepts a normal JCA `KeyPair`. On Android, the private half was
  a non-exportable `AndroidKeyStore` P-256 key (`PrivateKey.encoded == null`).
- A real-fixture instrumentation gate proved:
  - password bootstrap on both dedicated fixtures;
  - temporary P-256 authorized-key installation and verified cleanup;
  - host-key observation;
  - P-256 public-key authentication through Android Keystore;
  - exec;
  - PTY and resize `80x24 -> 132x43`;
  - ordered stable-to-chaos jump using `direct-tcpip` and a second SSH client;
  - deterministic connection close.
- Marker:
  `TESSERA_SSHJ_ANDROID_OK direct=1 exec=1 pty=1 resize=1 jump=1 hostKeys=4 exportable=false`.
- The disposable AVD was deleted, and the gate's host-side cleanup independently
  removed any run marker from both fixtures.
- Strict Android lint and minified R8 release assembly pass after excluding the
  unused Bouncy Castle artifacts.
- The current unsigned release APK changed from `61,668,796` to `61,668,925`
  bytes. This `129`-byte result only proves R8 can remove the currently unused
  backend; it is not a retained-backend size or cold-start measurement.

### Native compatibility findings

Stock SSHJ `0.40.0` is not yet a shippable Android backend:

1. Ed25519 server host-key parsing selects Android's `AndroidKeyStore`
   `KeyFactory`, which advertises the algorithm but rejects imported X.509
   public keys. This reproduces upstream issue `#1032`.
2. NIST ECDSA host-key parsing requests `KeyFactory("ECDSA")`; Android exposes
   the standard `EC` name, so parsing fails before trust evaluation.
3. Preferring RSA host keys while retaining the ECDSA P-256 client-key
   algorithm isolates and passes the Keystore signer and transport proof.

These are narrow JCA adaptation defects, but they require maintained upstream
or fork work. The experimental factory documents and fails around the current
boundary; it is not evidence that RSA-only host support is acceptable.

### Apache MINA sshd comparison

Apache MINA sshd is the secondary native candidate. It is Apache-2.0, pure Java,
and has built-in proxy-jump and forwarding features. Its official Android notes,
however, state that Android compatibility/usability has not been checked, is not
a project goal, and that the available I/O/provider hooks are largely
user-feedback driven. Starting with SSHJ therefore has the smaller Phase B proof
surface despite SSHJ's known key-decoding adapter work.

## Contract and maintenance rules

The Android backend must expose the contract in the architecture plan:
direct/ordered-jump routes, host-key challenge, password and signer auth, PTY,
streams, resize, exec, direct-tcpip, cancellation, policy-generation
revalidation, and redacted diagnostics.

- Trust decisions stay above SSHJ; the experiment's accept-all callback is test
  code only.
- The production signer adapter must revalidate attempt ID and policy generation
  immediately before and after every Keystore signature.
- Do not add Bouncy Castle merely to route around Android provider selection.
- Keep the SSHJ patch minimal, source-pinned, documented, and covered by
  Ed25519/ECDSA/RSA host-key conformance tests.
- Retain Citadel as a build-tested portability fallback, not a runtime fallback
  selected per connection.

## Fallback triggers

Reopen the backend choice if any of these occurs:

- the host-key fixes cannot be upstreamed or maintained as a small auditable
  patch;
- physical-device Keystore authentication fails with hardware-backed keys or
  owner authorization;
- SSHJ cannot satisfy cancellation, IPv6, jump ordering, Mosh bootstrap, or
  host-key policy conformance;
- retained R8 size, memory, or cold-start measurements exceed the Phase A/Phase
  B device budgets;
- SSHJ maintenance or security response becomes unacceptable.

The next candidates are Apache MINA sshd after an equivalent Android proof, then
Citadel/NIOSSH only if a standard-algorithm Android Keystore signer bridge and
runtime-size budget are solved.

## Open physical-device acceptance gates

No physical Android device was attached during this gate. The following remain
blocked rather than inferred from the emulator:

- arm64 physical-device cold start, retained size, memory, and callback cost;
- hardware-backed/StrongBox Keystore reporting and owner-authentication flow;
- direct and ordered-jump SSH with the hardware-backed key;
- DNS, IPv4, IPv6, cancellation, network-change, and error behavior;
- phone/tablet IME, hardware keyboard, mouse/trackpad, selection, and
  accessibility baselines for the terminal surface.
