plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.bambouville.tessera.feature.agentcenter"

    buildFeatures { compose = true }

    defaultConfig { testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
}

dependencies {
    implementation(project(":core-bridge"))
    implementation(project(":agent-platform"))
    implementation(project(":design"))
    implementation(project(":markdown"))
    implementation(project(":data"))
    implementation(project(":lifecycle"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.kotlinx.coroutines.android)
    // Gemini Nano through ML Kit, for the on-device tier of the title
    // waterfall. Every transitive Play/datatransport artifact it brings is
    // already in the app through the pairing scanner, so this adds a model
    // client and nothing else. Absent hardware simply falls through to the
    // clipped opening prompt.
    implementation(libs.mlkit.genai.prompt)

    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit4)
    // Android's framework JSONObject is a throwing stub in local JVM tests.
    // Use the matching standalone implementation so binding/lease wire tests
    // exercise real serialization instead of silently accepting defaults.
    testImplementation(libs.json)
    androidTestImplementation(composeBom)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
