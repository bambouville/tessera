plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.bambouville.tessera.feature.session"
    sourceSets { getByName("main") { assets.srcDir("../../SharedAssets/agent-host") } }

    defaultConfig { testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(project(":core-bridge"))
    implementation(project(":agent-platform"))
    implementation(project(":terminal"))
    implementation(project(":networking"))
    implementation(project(":lifecycle"))
    implementation(project(":data"))
    implementation(project(":files"))
    implementation(project(":port-forwarding"))
    implementation(project(":security"))
    implementation(project(":design"))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.kotlinx.coroutines.android)

    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(libs.junit4)
    testImplementation(libs.kotlinx.coroutines.test)
    // The core-bridge JSON envelopes run on the JVM here; android.jar's
    // org.json is a stub that throws, so the tests need the real one.
    testImplementation(libs.json)
    testImplementation(libs.sshj) { exclude(group = "org.bouncycastle") }

    // Test-only: the Agent Center rig drives the production presenter over a
    // real controller. Production direction stays feature-session -> nothing.
    androidTestImplementation(project(":feature-agent-center"))
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    androidTestImplementation(libs.junit4)
    androidTestImplementation(libs.sshj) { exclude(group = "org.bouncycastle") }
}
