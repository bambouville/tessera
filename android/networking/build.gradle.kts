plugins {
    alias(libs.plugins.android.library)
}

// Native Mosh ships by default: the reviewed OpenSSL 3.5.7 prefix is built
// once from source by scripts/android/prepare-mosh-openssl.sh and cached under
// .build/android-deps, so an ordinary `./gradlew :app:assembleDebug` produces
// the same Mosh-capable APK that scripts/install-android.sh does. Environments
// without the pinned NDK opt out with -Ptessera.enableMoshNative=false.
val enableMoshNative = providers.gradleProperty("tessera.enableMoshNative")
    .map(String::toBoolean)
    .getOrElse(true)

/** Env or local.properties SDK root, so the prep script runs without a login shell. */
val resolvedSdkRoot: String? = providers.environmentVariable("ANDROID_SDK_ROOT").orNull
    ?: providers.environmentVariable("ANDROID_HOME").orNull
    ?: rootProject.file("local.properties").takeIf { it.isFile }
        ?.readLines()
        ?.firstNotNullOfOrNull { line -> line.trim().removePrefix("sdk.dir=").takeIf { it != line.trim() } }

fun prepareMoshOpenSslRoot(): String {
    val script = rootProject.file("../scripts/android/prepare-mosh-openssl.sh")
    require(script.isFile) { "missing $script" }
    // The cached prefix returns in milliseconds, but the first build on a
    // machine compiles OpenSSL from source. Say so rather than stalling mute.
    logger.lifecycle("Preparing the reviewed Android OpenSSL prefix for native Mosh (one-time build if uncached)...")
    val output = providers.exec {
        commandLine(script.absolutePath)
        resolvedSdkRoot?.let { environment("ANDROID_SDK_ROOT", it) }
        isIgnoreExitValue = true
    }
    val exitValue = output.result.get().exitValue
    check(exitValue == 0) {
        "Could not prepare the reviewed Android OpenSSL prefix for native Mosh " +
            "(prepare-mosh-openssl.sh exited $exitValue): " +
            output.standardError.asText.get().trim().takeLast(500) +
            "\nInstall the pinned NDK from android/README.md, or build without Mosh " +
            "using -Ptessera.enableMoshNative=false."
    }
    return output.standardOutput.asText.get().trim().lines().last().trim()
}

val moshOpenSslRoot = if (enableMoshNative) {
    providers.gradleProperty("tessera.moshOpenSslRoot").orNull?.takeUnless(String::isBlank)
        ?: prepareMoshOpenSslRoot()
} else null

android {
    namespace = "com.bambouville.tessera.networking"

    ndkVersion = "28.2.13676358"

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("boolean", "TESSERA_MOSH_NATIVE_ENABLED", enableMoshNative.toString())
        if (enableMoshNative) {
            ndk {
                abiFilters += "arm64-v8a"
            }
            externalNativeBuild {
                cmake {
                    arguments += "-DTESSERA_ANDROID_OPENSSL_ROOT=$moshOpenSslRoot"
                    cppFlags += "-std=c++17"
                }
            }
        }
    }

    if (enableMoshNative) {
        externalNativeBuild {
            cmake {
                path = file("src/main/cpp/CMakeLists.txt")
                version = "3.22.1"
            }
        }
    }

    packaging {
        resources.excludes += setOf(
            "/META-INF/{AL2.0,LGPL2.1}",
        )
    }

    lint {
        // The reviewed native mosh/OpenSSL toolchain is arm64-only, matching
        // the shared Swift bridge. ChromeOS/x86_64 is not a supported target.
        disable += "ChromeOsAbiSupport"
    }
}

dependencies {
    implementation(project(":core-bridge"))
    implementation(project(":security"))
    implementation(project(":port-forwarding"))
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.sshj) {
        exclude(group = "org.bouncycastle")
    }
    implementation(libs.conscrypt.android)
    testImplementation(libs.junit4)
    testImplementation(project(":agent-platform"))
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
