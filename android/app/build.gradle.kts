plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.bambouville.tessera"

    defaultConfig {
        applicationId = "com.bambouville.tessera"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        targetSdk {
            version = release(37)
        }
        versionCode = 8
        versionName = "0.4.1"
        // The shared core and Mosh are built for arm64 only. Without this,
        // dependency .so files for other ABIs make Play serve the app to
        // x86/32-bit devices, where loading the core throws at launch.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // Per-app language (Android 13+): the system language picker lists the
    // locales the merged resources ship; res/resources.properties names the
    // default (unqualified) one.
    androidResources {
        generateLocaleConfig = true
    }

    signingConfigs {
        // The Play upload key. scripts/android/bundle-release.sh passes it in
        // from the Keychain; any other release build stays unsigned.
        providers.environmentVariable("TESSERA_UPLOAD_STORE_FILE").orNull?.let { store ->
            create("upload") {
                storeFile = file(store)
                storePassword = providers.environmentVariable("TESSERA_UPLOAD_STORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("TESSERA_UPLOAD_KEY_ALIAS").orNull ?: "upload"
                keyPassword = storePassword
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }

        release {
            signingConfig = signingConfigs.findByName("upload")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        resources.excludes += setOf(
            "/META-INF/{AL2.0,LGPL2.1}",
        )
    }

    lint {
        // arm64-only on purpose (see abiFilters above), as in :core-bridge.
        disable += "ChromeOsAbiSupport"
    }
}

// The bundled terminal typefaces carry licences (OFL 1.1, the Ubuntu Font
// Licence, MIT + Bitstream Vera) that require the licence text to travel with
// the font in any distribution — an APK included. iOS ships the same
// obligation inside `ThirdPartyNotices.txt`; here the licence files are packed
// as assets straight out of the shared directory, so adding a family cannot
// leave its licence behind. Typed AGP 9 DSL for the same reason as the res
// roots in `:design` and `:terminal`.
extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
    sourceSets.getByName("main").assets.directories.add(
        rootProject.file("../SharedAssets/font-licenses").path,
    )
}

// GPLv3 §6 requires the licence text to travel with the object code, so About
// shows the repository's own LICENSE and COPYING.iOS (its §7 terms) from
// assets. Copied at build time rather than duplicated in the tree, so the two
// can never disagree.
abstract class CopyLegalAssets : DefaultTask() {
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.NAME_ONLY)
    abstract val documents: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:Inject
    abstract val files: FileSystemOperations

    @TaskAction
    fun copy() {
        files.sync {
            from(documents)
            into(outputDir.dir("legal"))
        }
    }
}

val legalAssets = tasks.register<CopyLegalAssets>("copyLegalAssets") {
    documents.from(rootProject.file("../LICENSE"), rootProject.file("../COPYING.iOS"))
}

extensions.configure<com.android.build.api.variant.ApplicationAndroidComponentsExtension>("androidComponents") {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(legalAssets, CopyLegalAssets::outputDir)
    }
}

dependencies {
    implementation(project(":core-bridge"))
    implementation(project(":agent-platform"))
    implementation(project(":feature-agent-center"))
    implementation(project(":feature-artifacts"))
    implementation(project(":feature-hosts"))
    implementation(project(":feature-session"))
    implementation(project(":feature-pairing"))
    implementation(project(":data"))
    implementation(project(":security"))
    implementation(project(":design"))
    implementation(project(":lifecycle"))
    implementation(project(":terminal"))
    // MainActivity owns shared-URI ingress in production, while the visual
    // harness also renders the real Remote Files screen against a mock presenter.
    implementation(project(":files"))
    // MainActivity hands a live session's tunnels to the host list's forwarding page.
    implementation(project(":port-forwarding"))

    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)

    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    androidTestImplementation(composeBom)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)

    testImplementation(libs.junit4)
}
