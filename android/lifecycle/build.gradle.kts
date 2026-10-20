plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.bambouville.tessera.lifecycle"
}

dependencies {
    implementation(project(":core-bridge"))
    implementation(project(":networking"))
}
