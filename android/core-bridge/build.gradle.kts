plugins {
    alias(libs.plugins.android.library)
}

val generatedJniLibraries = layout.buildDirectory.dir("generated/swiftJniLibs")
val buildSwiftCore = tasks.register<Exec>("buildSwiftCore") {
    group = "build"
    description = "Builds and stages the shared Swift core for Android arm64"
    inputs.files(
        fileTree("../../Packages/TesseraCore/Sources"),
        fileTree("../../Packages/TmuxControl/Sources"),
    )
    inputs.file("../../Packages/TesseraCore/Package.swift")
    inputs.file("../../Packages/TesseraCore/Package.resolved")
    inputs.file("../../Packages/TmuxControl/Package.swift")
    inputs.file("../../scripts/android/build-swift-core.sh")
    outputs.dir(generatedJniLibraries)
    commandLine(
        "../../scripts/android/build-swift-core.sh",
        generatedJniLibraries.get().asFile.absolutePath,
    )
}

// JVM unit tests in every module load these (root build.gradle.kts).
val hostJniLibraries = layout.buildDirectory.dir("generated/hostJniLibs")
tasks.register<Exec>("buildHostCore") {
    group = "verification"
    description = "Builds the shared Swift core and JNI shim for JVM unit tests on this machine"
    inputs.files(
        fileTree("../../Packages/TesseraCore/Sources"),
        fileTree("../../Packages/TmuxControl/Sources"),
        fileTree("src/main/cpp"),
    )
    inputs.file("../../Packages/TesseraCore/Package.swift")
    inputs.file("../../Packages/TesseraCore/Package.resolved")
    inputs.file("../../Packages/TmuxControl/Package.swift")
    inputs.file("../../scripts/android/build-host-core.sh")
    outputs.dir(hostJniLibraries)
    commandLine(
        "../../scripts/android/build-host-core.sh",
        hostJniLibraries.get().asFile.absolutePath,
    )
}

android {
    namespace = "com.bambouville.tessera.core.bridge"

    // The protocol vectors are checked in once, at the repo root, and read by
    // the Swift tests as files. The instrumented side needs them inside the
    // test APK, so the same directory is staged as test assets rather than
    // copied — a copy is a second version to drift from.
    sourceSets {
        getByName("androidTest") {
            assets.srcDir("../../ProtocolVectors")
        }
    }

    ndkVersion = "28.2.13676358"

    defaultConfig {
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17")
            }
        }
        consumerProguardFiles("consumer-rules.pro")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.directories.add(generatedJniLibraries.get().asFile.absolutePath)
        }
        getByName("androidTest") {
            assets.directories.add("../../ProtocolVectors")
        }
    }

    lint {
        // Phase A's official Swift Android SDK target is arm64-only. ChromeOS
        // architecture coverage is part of the later backend/device decision.
        disable += "ChromeOsAbiSupport"
    }
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }
    .configureEach {
        dependsOn(buildSwiftCore)
    }

dependencies {
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit4)
    testImplementation(libs.json)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
