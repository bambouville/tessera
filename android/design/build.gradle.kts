plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.bambouville.tessera.design"

    buildFeatures { compose = true }
}

// Terminal typefaces are shared byte-for-byte with iOS; see
// SharedAssets/README.md. The directory is a resource root, so every file under
// its `font/` becomes `R.font.<filename>`. Configured through the typed AGP 9
// DSL rather than `android { sourceSets[...] }`, whose generated Kotlin
// accessor still casts to the removed legacy source-set type.
extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
    sourceSets.getByName("main").res.directories.add(
        rootProject.file("../SharedAssets/fonts").path,
    )
}

dependencies {
    // BackHandler: TesseraSubPageHeader binds the system back gesture to the
    // same callback as its chevron, so every sub-page gets one for free.
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.annotation)
    implementation(libs.androidx.core.ktx)

    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)

    testImplementation(libs.junit4)
}
