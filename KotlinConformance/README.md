# Kotlin protocol conformance

This directory is the independent Kotlin/JVM consumer required by sections
22.2 and 22.3 of the shared-platform architecture. It reads the checked-in
`ProtocolVectors` directly and does not import, call, or duplicate-test through
the Swift implementation. It has no Gradle build and no runtime dependency
beyond the Kotlin standard library embedded by `kotlinc` and the JDK.

The gate pins the official standalone JetBrains compiler to
`kotlinc-jvm 2.2.21`, compiles for JVM 17, treats warnings as errors, builds in a
run-scoped temporary directory, and removes that directory on success or
failure. It performs no network access. `KOTLINC` must name the pinned compiler
executable; `JAVA_HOME` may name any JDK 17 or newer. The release lane was
verified with Temurin 21.0.8+9.

Run from the repository root:

```sh
KOTLINC=/path/to/kotlinc-2.2.21/bin/kotlinc \
JAVA_HOME=/path/to/jdk-21 \
  scripts/check-kotlin-conformance.sh
```

The reviewed standalone compiler archive is published by JetBrains at:

```text
https://github.com/JetBrains/kotlin/releases/download/v2.2.21/kotlin-compiler-2.2.21.zip
SHA256 a623871f1cd9c938946948b70ef9170879f0758043885bbd30c32f024e511714
```

The conformance executable contains a small strict JSON parser rather than a
Swift bridge or third-party serializer. Its test groups independently
verify:

- Continuation v1's exact public field spellings, required schema, released
  unknown-field tolerance, canonical descriptor, version/port/tmux/connection
  key rejection, byte budget, and route limit.
- Bootstrap-manifest v2's recursive field allowlists, unknown-root rejection,
  frozen version, encoded-byte budget, and collection limits.
- Public-key descriptor v1/v2 field spellings, canonical SSH blob structure,
  display-safety rules, protection claims, and SHA-256 fingerprints.
- Enrollment-v1 canonical bytes, four-byte stream framing, version rejection,
  and the requester/origin durable receipt order through completion.
- Released nearby-bootstrap v2 cleartext limits, commitment/transcript bytes,
  X25519 and HKDF material, SAS, complete transfer ordering, manifest/receipt
  hashes, both shipped envelope orderings, every encrypted frame, and frame cap.
- Pairing v1's closed offer schema, canonical component JSON, exact framed
  transcript, SHA-256, optical HMAC proof, X25519 agreement, HKDF keys/nonces,
  six-digit SAS, and frame nonce/sequence relationship.
- Pairing expiry boundaries, highest-common-version downgrade detection, and
  authenticated post-completion rejection.
- Continuation and bootstrap transaction envelope spellings, role-accurate
  receipt order, abort validation, aborted-state rejection, and completed-state
  rejection.
- Bootstrap authorization-scope, manifest-set, grant-receipt, and optional
  transfer rejection names frozen by the vectors.
- Session challenge lifetime and display-metadata limits, identity and policy
  binding, and one-shot response consumption.
- Tmux control-mode topology and repaint vectors, including authority state,
  active window/pane mapping, frozen rendered-state fields, terminal mode, and
  final cursor placement.

This is the language-neutral contract gate, not an Android application test
suite. The Android branch must still test Swift/C ABI loading and callback
ownership from Kotlin, Android Keystore/biometric signing, NSD and socket
adapters, process/background lifecycle, foreground-service policy, Compose/UI
behavior, packaging/R8, and physical-device transport behavior.
