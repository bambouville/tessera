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
        versionCode = 1
        versionName = "0.1.0-dev"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }

        release {
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

dependencies {
    implementation(project(":core-bridge"))
    implementation(project(":agent-platform"))
    implementation(project(":feature-agent-center"))
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
