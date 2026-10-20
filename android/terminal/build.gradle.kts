plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.bambouville.tessera.terminal"

    defaultConfig {
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
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
    implementation(project(":core-bridge"))
    implementation(libs.androidx.annotation)
    implementation(libs.androidx.core.ktx)
    testImplementation(libs.junit4)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
