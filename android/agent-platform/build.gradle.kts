plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.bambouville.tessera.agent.platform"
}

dependencies {
    implementation(project(":core-bridge"))
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit4)
    // Route-authority unit tests exercise canonical JSONObject bindings on the JVM.
    testImplementation(libs.json)
}
