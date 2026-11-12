# Linux build machine for the Android app, pinned to the toolchain in
# android/README.md so a remote x86_64 host runs the same Gradle tasks as a
# Mac. scripts/android/remote-build.sh builds and runs it; nothing in it signs,
# uploads or runs an emulator.
FROM swift:6.3.3-noble

ARG BUILDER_UID=1000
ARG BUILDER_GID=1000

# perl and make build the reviewed OpenSSL prefix (prepare-mosh-openssl.sh).
RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-21-jdk-headless curl ca-certificates unzip perl make \
 && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk

# Command-line Tools 22.0, as on the Mac. The SHA-1 matched Google's
# repository2-3.xml; the SHA-256 pins that download.
ARG CMDLINE_TOOLS=commandlinetools-linux-15859902_latest.zip
ARG CMDLINE_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
RUN curl -fsSL --proto '=https' -o /tmp/cmdline-tools.zip \
      "https://dl.google.com/android/repository/$CMDLINE_TOOLS" \
 && echo "$CMDLINE_TOOLS_SHA256  /tmp/cmdline-tools.zip" | sha256sum -c - \
 && unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools \
 && mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools" \
 && mv /tmp/cmdline-tools/cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/latest" \
 && rm -rf /tmp/cmdline-tools /tmp/cmdline-tools.zip \
 && yes | "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null \
 && "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" \
      "platform-tools" "platforms;android-37.0" "build-tools;36.0.0" \
      "ndk;28.2.13676358" "cmake;3.22.1" >/dev/null

# The host's own user, so the bind-mounted checkout and caches stay its files.
# Ubuntu images ship an "ubuntu" user on 1000.
RUN if id ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
 && groupadd --gid "$BUILDER_GID" builder \
 && useradd --create-home --uid "$BUILDER_UID" --gid "$BUILDER_GID" builder
USER builder
WORKDIR /home/builder

# The SHA-256 pins a download that passed its swift.org signature
# (Swift 6.x Release Signing Key, EF80A866B47A981F).
RUN swift sdk install \
      https://download.swift.org/swift-6.3.3-release/android-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_android.artifactbundle.tar.gz \
      --checksum d160cc3206dd1886dae3fef2337af5e25ec034692cd0ec225721c56cc69da7f5 \
 && bundle="$(find "$HOME" -type d -name swift-6.3.3-RELEASE_android.artifactbundle -print -quit)" \
 && ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/28.2.13676358" \
      "$bundle/swift-android/scripts/setup-android-sdk.sh" \
 && swift sdk list | grep -qx swift-6.3.3-RELEASE_android
