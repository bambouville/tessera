# Shared platform import smoke

This standalone macOS Swift package contains two deliberately separate import
surfaces. `SharedPlatformImportSmoke` proves that a portable downstream target
can compose `TesseraContinuityCore`, `TesseraEnrollmentCore`,
`TesseraInputCore`, `TmuxControlCore`, and `TesseraCoreABI` without depending on
Tessera's application target or Apple adapters. The macOS-only
`AppleContinuityImportSmoke` separately proves that a Mac bridge can import the
shared Foundation Handoff publisher and continuation-stream transport.

Run from the repository root:

```sh
swift test --package-path Packages/SharedPlatformImportSmoke
swift run --package-path Packages/SharedPlatformImportSmoke SharedPlatformCABILinkSmoke
```

The fixture uses deterministic public-key, tmux parser/query, Handoff binding,
enrollment binding, terminal key/mouse encoding, and 16 KiB coarse-ABI input
checks. Its Apple lane also instantiates the shared activity publisher and
stream transport, then drives the stream's peer binding through the public
enrollment frame codec and state machine. It is intentionally a separate
package so accidental app-target imports fail at compile time.
The executable imports the installed public C header and links every declared
runtime symbol against the Swift implementation. Through one live C handle it
drives connect ordering and a 720 KiB raw terminal batch (960 KiB after base64)
through one backend-event call, verifies exact callback bytes and order, and
holds JSON envelope overhead to 256 bytes without a wall-clock threshold. It
also proves stale handles are rejected after idempotent destruction. Callbacks
from one runtime are serialized on ABI-owned executors with no fixed thread or
UI affinity; downstream presentation adapters must marshal to their UI executor.

Only the portable `SharedPlatformImportSmoke` target is cross-compiled by the
Android release gate; `AppleContinuityImportSmoke` and
`TesseraAppleContinuity` are intentionally excluded:

```sh
SWIFT_ANDROID_SWIFT=/path/to/open-source/swift \
TESSERA_ANDROID_NDK_ROOT=/path/to/android-ndk-r27d \
TESSERA_ANDROID_OPENSSL_ARCHIVE=/path/to/openssl-3.5.7.tar.gz \
TESSERA_SWIFTPM_OFFLINE_CACHE_ROOT="$PWD/Packages/TesseraCore/.build" \
  scripts/check-shared-core-android.sh
```

The gate verifies the official OpenSSL 3.5.7 source archive against the
reviewed SHA256 recorded in the SBOM, then builds its Android-arm64 static
`libcrypto.a` with the selected NDK/API 28 in run-scoped scratch. It never
accepts a separately supplied prefix as release provenance. The gate links a
real `MoshCABILinkSmoke` Android executable through MoshCore, vendored mosh,
protobuf-lite, zlib, and that source-built crypto library; it does not treat
compilation of the wrapper object as sufficient evidence. The preceding macOS
package lane hydrates the exact locked swift-crypto and swift-asn1 bare
repositories; the Android lane validates their origin and revisions, copies
them into run-scoped scratch, and disables remote update and prefetching.
