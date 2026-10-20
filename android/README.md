# Tessera Android development

This directory is the native Kotlin/Compose app described by
`docs/refactor/tessera-android-architecture-after-shared-refactor.md`. Phase A
established the reproducible build, module boundaries, shared Swift/C ABI, and
Android backend decisions. The current baseline contains SSH, SSH+tmux, Mosh,
Mosh+tmux, Remote Files, compact geometry-neutral tmux, recovery, and Android
share flows for phone and tablet software keyboards.
Persisted direct and ordered-jump hosts authenticate with ephemeral passwords or
non-exportable Android Keystore P-256 identities. The shared runtime owns typed
session challenges and tmux topology; Android owns Compose presentation, the
pinned terminal View, SAF/content-URI file flows, lifecycle restore, app lock,
and redacted local diagnostics. Passwords are not persisted, and every mutable
password copy is wiped at the authentication boundary.

## Pinned toolchain

| Component | Version | Reason |
|---|---:|---|
| JDK | 21 | Matches the repository's Kotlin conformance CI runtime |
| Gradle wrapper | 9.7.1 | Current stable Gradle, compatible with AGP 9.3 and checksum-pinned |
| Android Gradle Plugin | 9.3.2 | Current stable AGP patch with built-in Kotlin support |
| Kotlin/Compose compiler plugin | 2.3.21 | Matches AGP's built-in Kotlin line |
| Compile SDK | 37.0 | Current stable Android SDK surface for compatibility testing |
| Target SDK | 37.0 | Starts new work on current Android behavior rather than compatibility mode |
| Minimum SDK | 33 (Android 13) | Supported application floor; native libraries may target an older ABI |
| Android NDK | 28.2.13676358 | AGP 9.x default and sufficient for the existing shared-core gate |
| Compose BOM | 2026.08.00 | Stable, mutually tested Compose dependency set |

The Gradle project uses AGP 9's built-in Kotlin support. Do not add the
`org.jetbrains.kotlin.android` plugin. The Compose compiler plugin remains
explicit because Compose compiler releases follow Kotlin.

Tessera requires Android 13 (API 33) or newer.

## One-time setup

1. Install the current stable Android Studio with a JDK 21 runtime, or install a
   standalone JDK 21 and export `JAVA_HOME`.
2. In Android Studio's SDK Manager, install Android SDK Platform 37.0, SDK Build
   Tools 36.0.0, Platform-Tools, SDK Command-line Tools, and NDK
   28.2.13676358.
3. Accept the Android SDK licenses. If Command-line Tools are already installed,
   `scripts/android/setup-sdk.sh` installs the pinned packages.
4. Set `ANDROID_SDK_ROOT`, or let Android Studio write the gitignored
   `android/local.properties` file.
5. Verify the machine from the repository root:

   ```sh
   scripts/android/check-environment.sh
   ```
6. Install Swift 6.3.3 and its matching official Android SDK bundle, then run
   the bundle's `setup-android-sdk.sh` against NDK 28.2.13676358. The native
   build accepts `SWIFT_ANDROID_SWIFT` and
   `SWIFT_ANDROID_STATIC_RESOURCE_DIR` when those installations are outside
   SwiftPM's standard locations.

## Build

Run Gradle from the Android project root:

```sh
cd android
./gradlew build lint
```

For the installable development shell:

```sh
./gradlew :app:assembleDebug
```

After enabling USB debugging and accepting this Mac on an unlocked physical
device, build, update-install, and launch the debug app from the repository
root with:

```sh
scripts/install-android.sh
```

The installer also prepares the checksum-pinned OpenSSL 3.5.7 arm64 prefix and
enables the native Mosh library. Direct Gradle builds that need Mosh must pass
the two properties documented in `networking/MOSH_NATIVE.md`; builds without
them fail a Mosh connection with a clear capability error instead of attempting
to load a missing JNI library.

Use `scripts/install-android.sh --find-only` to inspect adb visibility without
building, or pass an adb serial when more than one physical device is attached.
The installer rejects emulators and unsupported API/ABI combinations, preserves
existing app data during updates, and never uninstalls a conflicting package.

The debug application ID is `com.bambouville.tessera.debug`; release uses
`com.bambouville.tessera`. Release code and resource shrinking are enabled from
the first milestone so native bridge keep rules cannot become a late surprise.

## Module boundaries

The module names mirror section 7 of the architecture specification. Feature
modules depend on repository/platform contracts and `core-bridge`, never on
JNI, Swift, or C++ types directly. `core-native-fallback` is present but is not
selected by the application; the Phase A backend gate decides whether and how
it becomes active.

JVM unit tests (`testDebugUnitTest`) run the same shared core. Every module's
`Test` task depends on `:core-bridge:buildHostCore`. That task runs
`scripts/android/build-host-core.sh`, which builds `TesseraCoreAndroid` and
the JNI shim for the build machine and puts them on `java.library.path`. On
macOS this uses Xcode's `swift` and `clang++`; on Linux, the `swift` on `PATH`.
`TESSERA_HOST_SWIFT_SCRATCH` moves its SwiftPM scratch directory. Kotlin tests
can therefore call the real core instead of a stand-in.

`core-bridge` loads the shared library before its JNI adapter and validates ABI
version 1 plus the 1 MiB payload ceiling. `CoreRuntime` owns explicit native
handles, accepts batched direct buffers, copies borrowed callback data before it
leaves JNI, and supports deterministic or callback-reentrant destruction.
Features depend only on the Kotlin facade; Swift, C ABI, and JNI types remain
private to the bridge module.

The independent `protocol-conformance` JVM module runs the checked-in protocol
and tmux vectors during Gradle `check`. The device gate creates a uniquely named
Android 16 arm64 tablet AVD and deletes it on every exit:

```sh
./scripts/android/run-runtime-gate.sh
```

Focused reruns can set `TESSERA_ANDROID_RUNTIME_FOCUS`, select a phone or tablet
definition with `TESSERA_ANDROID_RUNTIME_DEVICE`, and pass a JUnit class or
`Class#method` through `TESSERA_ANDROID_RUNTIME_TEST_FILTER`. Every variant uses
the same run-scoped cleanup trap.

The Mosh gate builds the vendored C++/protobuf core with checksum-verified
OpenSSL 3.5.7, verifies the Android ELF and every stable C ABI symbol, then
executes a full local lifecycle probe on another run-scoped arm64 AVD. Supply
the reviewed source archive explicitly; the script never substitutes a system
`libcrypto`:

```sh
TESSERA_ANDROID_OPENSSL_ARCHIVE=/path/to/openssl-3.5.7.tar.gz \
  ./scripts/android/run-mosh-runtime-gate.sh
```

The Citadel gate cross-compiles the resolved SwiftNIO/NIOSSH graph as a static
Swift Android executable, verifies its AArch64 ELF runtime contract, and drives
password authentication, an exec channel, a PTY, and a PTY resize against the
designated disposable stable VPS fixture from a run-scoped AVD:

```sh
TESSERA_FIXTURE_CONFIG=/path/to/fixture.env \
  ./scripts/android/run-citadel-ssh-gate.sh
```

The checked-in `Packages/Citadel/Package.resolved` is the standalone Android
gate lock. The Xcode workspace keeps its own application dependency lock.

The first Android product baseline is deliberately software-keyboard-first.
Advanced hardware-keyboard behavior and shortcuts remain follow-up work; see
`../docs/android-product-gaps.md`.
The implementation and disposable-device gates are complete. The native SSH
gate proves the exact product adapter with password and Keystore auth, direct
and jump routes, Ed25519/ECDSA/RSA host keys, SFTP Remote Files, and shared-core
tmux attach/create/split. Its geometry case also starts from a 160x50 split,
projects one pane onto a compact viewport through the shared Apple/Android
sizing core, and proves a later 160x50 reattach retains the same pane IDs and
split tree. The runtime gate covers the shared ABI/JNI, Room,
Keystore stale-policy rejection, terminal IME/selection/paste, activity
recreation, installation, and normal launch. The physical-device software-IME,
security, and lifecycle matrix remains an explicit external acceptance gate;
emulator results must not be reported as physical-device evidence.
