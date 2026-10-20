# Android Mosh transport foundation

Android Mosh uses the same vendored Mosh core and stable C ABI as iOS. The
normal Android installer prepares the pinned native dependency and enables it
for the APK build:

- `AndroidSshMoshBootstrapper` runs `mosh-server new` through the existing
  `SshRouteRequest`, host-key policy, password provider, and Keystore
  authorization provider.
- `AndroidMoshTransport` owns native input, resize, output, tick scheduling,
  full repaint, and connectivity state.
- `AndroidMoshTmuxControlChannelFactory` opens an independent SSH `tmux -CC`
  channel for a Mosh+tmux session. It never shares terminal bytes with UDP
  Mosh.

The native implementation is `src/main/cpp/tessera_mosh_jni.cpp`. It calls the
same stable C ABI in `Packages/MoshBridge/Sources/MoshCABI/MoshCABI.h` used by
iOS; the bootstrap key is passed as a mutable byte array and wiped on both
sides of the JNI handoff.

## Build integration

1. `scripts/android/prepare-mosh-openssl.sh` downloads the reviewed OpenSSL
   3.5.7 archive once, verifies its SHA-256 digest, and builds the arm64 Android
   prefix under the ignored `.build/android-deps` directory. Later runs reuse
   the verified prefix.
2. `scripts/install-android.sh` invokes that preparation step and passes the
   native properties automatically. For a direct Gradle build, pass them with:

   ```sh
   ./gradlew -Ptessera.enableMoshNative=true \
     -Ptessera.moshOpenSslRoot=/absolute/path/to/reviewed/arm64-prefix :app:assembleDebug
   ```

   The networking AAR then contributes `libtessera_mosh_jni.so` for arm64-v8a.
3. The shared session controller adapts plain Mosh and Mosh+tmux launch modes,
   preserving the same password, host-key, Keystore authorization, recovery,
   and diagnostics contracts as SSH. Mosh+tmux retains an independent SSH
   control channel for metadata, history, authority, and window operations.
4. Release packaging must provide the same two Gradle properties; the checked
   installer is the reference local build path.

The focused JVM tests validate parsing, credential lifetime at the Kotlin/JNI
boundary, native start/resize delegation, and the transport-neutral contract.
