plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.bambouville.tessera.core.nativefallback"
}

dependencies {
    implementation(project(":core-bridge"))
}
