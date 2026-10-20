# Shared platform branch contract

This file records the stable ownership boundary produced by Shared Platform
Enablement. Android and Mac adapters may depend on these contracts; they must
not copy or fork their protocol and policy behavior.

## Shared implementation owners

| Contract | Product / target | Implementation status |
|---|---|---|
| Public host profiles, routes, credential capabilities | `TesseraDomainCore` | shared Swift implementation |
| Continuation v1, bootstrap manifest v2, legacy nearby-bootstrap constants/version probe | `TesseraProtocolCore` | shared Swift implementation plus frozen vectors |
| Purpose-bound pairing v1 and encrypted envelopes | `TesseraPairingCore` | shared Swift implementation |
| Pairing v1 QR text, self-framed byte-stream records, one-peer handshake driver | `TesseraPairingCore` | shared portable Swift implementation; platform adapters render/scan QR and own raw sockets |
| Bootstrap transaction v1; released nearby-bootstrap v2 hello, commitment, transcript, SAS, frames, and ordered transfer | `TesseraBootstrapCore` | shared portable Swift wire/crypto implementation plus complete canonical v2 vector |
| Enrollment messages, peer binding, transaction state | `TesseraEnrollmentCore` | shared Swift implementation |
| Continuation resolution, admission, trust hints, receive state | `TesseraContinuityCore` | shared Swift implementation |
| Cross-device pairing plus continuation/bootstrap/enrollment orchestration | `TesseraCrossDeviceCore` | one-attempt shared actor; descriptor-first `setUpAndContinue`, durable receipt gates, cancellation, expiry, and policy invalidation |
| Apple Handoff activity publication and continuation-stream transport | `TesseraAppleContinuity` | Foundation-only iOS/iPadOS/macOS adapter; excluded from the portable umbrella and Android graph |
| Trust records, TOFU/change policy, OpenSSH codec | `TesseraTrustCore` | shared Swift implementation; platform persistence adapters |
| Modifier normalization, terminal key sequences, mouse encoding, mode-reset rules | `TesseraInputCore` | shared Swift implementation; platform event/IME adapters remain native |
| Session commands, events, policy generation, one-shot grants | `TesseraSessionCore` | shared Swift implementation; functional platform backend-operation ports |
| Coarse command/event bridge | `TesseraCoreABI` + `TesseraCoreABI.h` | versioned C-callable command/backend-event boundary with batched bytes; callbacks are serialized in accepted-operation order on ABI-owned executors with no fixed thread or UI affinity |
| Cross-device command/event bridge | `TesseraCoreABI` + `TesseraCoreABI.h` | separate versioned handle namespace over `TesseraCrossDeviceCore`; bounded canonical JSON commands/events and borrowed callback bytes |
| tmux parser, response framing, topology, routing, repaint, authority lifecycle, immutable snapshots | `TmuxControlCore` | one Observation-free runtime engine and one stateful authority reducer; Apple and Android controllers are side-effect/observation adapters |
| Mosh engine boundary | `MoshCABI` | versioned C ABI over the vendored C++ engine |

Platform code continues to own persistence, key stores and signing prompts,
discovery and sockets, lifecycle, terminal rendering, localization, billing,
and UI. A platform may replace a shared implementation only behind the same
public contract and conformance vectors when its toolchain cannot consume the
Swift implementation.

## Compatibility invariants

- Handoff continues to publish and receive the existing activity type,
  user-info key, and byte-identical continuation schema v1.
- Released Apple peers continue to use nearby-bootstrap v2 under
  `_tessera-bootstrap._tcp`; the one public owner is `TesseraBootstrapCore`,
  Apple exposes compatibility wrappers only, and pairing v1 never masquerades
  as that epoch.
- Enrollment v1 field names and request/install/record/complete ordering remain
  frozen.
- Continuation fingerprint data is a comparison hint and never an implicit
  trust pin.
- Credential and private-key material never crosses a shared Codable boundary.
- Locks, background security changes, host/credential/route edits, and policy
  generation changes invalidate active grants and attempts.
- Cross-device TCP carries concatenated canonical `TPR1` records directly. It
  must not add the released nearby-bootstrap length envelope or any second
  platform-specific framing layer.
- `setUpAndContinue` sends and retains the authenticated continuation
  descriptor first, completes every bootstrap durable receipt, and only then
  permits descriptor acceptance, connection, or authority handoff.

## Change control

Wire changes require a new explicit version, checked-in cross-language vectors,
downgrade/rejection tests, and shared-core owner review. Public API changes must
remain adapter-shaped so Android and Mac branches do not need to edit the Apple
application target or duplicate a state machine.

Run `scripts/check-shared-core-portability.sh` in every shared-core CI lane.
Portable targets may not import SwiftUI, UIKit, AppKit, SwiftData, StoreKit,
Security, LocalAuthentication, Network, UserNotifications, or GameController,
and may not return localized prose as protocol errors.

## Reproducible release gates

Run these commands from the repository root before cutting an Android or Mac
branch:

```sh
swift test --package-path Packages/TesseraCore --disable-sandbox
swift test --package-path Packages/TmuxControl
swift test --package-path Packages/MoshBridge
swift test --package-path Packages/SharedPlatformImportSmoke # portable + separate macOS Apple import smoke
KOTLINC=/path/to/kotlinc-2.2.21/bin/kotlinc \
JAVA_HOME=/path/to/jdk-21 \
  scripts/check-kotlin-conformance.sh
scripts/check-shared-core-portability.sh
scripts/check-shared-core-dependencies.sh
SWIFT_ANDROID_SWIFT=/path/to/open-source/swift \
TESSERA_ANDROID_NDK_ROOT=/path/to/android-ndk-r27d \
TESSERA_ANDROID_OPENSSL_ARCHIVE=/path/to/openssl-3.5.7.tar.gz \
TESSERA_SWIFTPM_OFFLINE_CACHE_ROOT="$PWD/Packages/TesseraCore/.build" \
  scripts/check-shared-core-android.sh
```

The same lanes are wired in `.github/workflows/shared-platform.yml`. Hosted
macOS jobs run the portable/Mac/vector/ABI/SBOM gates and one run-scoped iPad
whose UDID is always shut down and deleted by an exit trap. Labeled self-hosted
runners provide the reviewed Swift Android 6.3.3 SDK/NDK environment and the
disposable two-fixture/four-transport integration environment. The workflow
never targets a developer's persistent simulator.

The Android runner supplies repository variables `SWIFT_ANDROID_SWIFT` and
`TESSERA_ANDROID_NDK_ROOT`; the gate still validates the installed toolchain,
SDK, NDK, archive, dependency mirrors, and output ELF rather than trusting the
runner label. The integration runner receives only the three fixture secrets
named in the workflow and materializes its ignored key/config under
`RUNNER_TEMP` for that job.

The Android gate currently selects the official Swift 6.3.3 SDK and
`aarch64-unknown-linux-android28`, configured with Android NDK r27d or newer.
It compiles `TesseraCore` (including `TesseraInputCore`), `TmuxControlCore`, and
the portable public-import smoke target. `TesseraAppleContinuity` and its
separate macOS import smoke stay outside that Android graph. The gate also links
an arm64 Android executable through the complete
`MoshCABI` → `MoshCore` → vendored mosh/protobuf graph using a reviewed static
OpenSSL Android build, then verifies every public Mosh C symbol and the ELF
dependencies. The gate pins the target triple, rejects NDKs older than r27d,
verifies the official 3.5.7 source archive SHA256, and builds the static
`libcrypto.a` in run-scoped scratch with that selected NDK and API 28. A
separately supplied prefix is never accepted as release provenance. It also
links a downstream executable against every public Tessera Core C runtime
symbol. Remote resolution is disabled: the gate validates exact locked
swift-crypto and swift-asn1 revisions in the supplied hydrated SwiftPM cache,
copies only those bare mirrors into run-scoped scratch, and uses
`--skip-update`, `--disable-prefetching`, and resolved-file-only mode. The
official Android SDK does not ship XCTest, so
the same sources' deterministic state-machine and vector suites execute in the
macOS package lanes while production targets and their public composition are
cross-compiled for Android.

`scripts/check-kotlin-conformance.sh` is the independent cross-language lane:
it pins the standalone JetBrains `kotlinc-jvm 2.2.21` interface, performs no
downloads, uses no Gradle or third-party JSON/runtime dependency, and parses the
checked-in protocol vectors with Kotlin-owned code. Its coverage and the
remaining Android application-specific integration obligations are recorded in
`KotlinConformance/README.md`.

`docs/refactor/shared-platform-sbom.spdx.json` records the remote and vendored
dependencies that enter the shared boundary. The dependency gate checks its
pins and required license texts so a dependency change cannot silently bypass
review. Android Mosh uses the reviewed OpenSSL 3.5.7 LTS source archive
(`SHA256 a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8`,
Apache-2.0) as Mosh's build/link dependency; an arbitrary system OpenSSL is not
a release input. Mosh is recorded as
`GPL-3.0-or-later WITH cryptsetup-OpenSSL-exception`; its upstream `COPYING.iOS`
commitment remains separate from Tessera's own App Store exception. The gate
requires the exact Swift lockfile set, submodule
gitlinks, SBOM package records, checksums, licenses, and dependency edges.
