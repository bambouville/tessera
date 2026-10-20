plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.bambouville.tessera.feature.pairing"

    buildFeatures { compose = true }
}

dependencies {
    implementation(project(":core-bridge"))
    implementation(project(":data"))
    implementation(project(":security"))
    implementation(project(":networking"))
    implementation(project(":port-forwarding"))
    implementation(project(":design"))
    implementation(project(":feature-session"))
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.mlkit.barcode.scanning)
    implementation(libs.zxing.core)
    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)
    testImplementation(libs.junit4)
    testImplementation(libs.json) // JVM tests exercise the real coordinator event reader.
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
