import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.dsl.LibraryExtension

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.ksp) apply false
}

subprojects {
    // JVM unit tests run the shared Swift core the app links, built for this
    // machine (scripts/android/build-host-core.sh), not a Kotlin stand-in.
    tasks.withType<Test>().configureEach {
        val hostCore = rootProject.layout.projectDirectory.dir("core-bridge/build/generated/hostJniLibs")
        dependsOn(":core-bridge:buildHostCore")
        // The library's content, not just its path, keys the test results:
        // otherwise a change to the shared core alone replays a cached result
        // measured against the previous core.
        inputs.dir(hostCore).withPropertyName("hostCore").withPathSensitivity(PathSensitivity.RELATIVE)
        systemProperty("java.library.path", hostCore.asFile.absolutePath)
    }

    pluginManager.withPlugin("com.android.application") {
        extensions.configure<ApplicationExtension> {
            compileSdk {
                version = release(37) {
                    minorApiLevel = 0
                }
            }

            defaultConfig {
                // Supported application floor: Android 13.
                minSdk = 33
            }

            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }

            lint {
                abortOnError = true
                warningsAsErrors = true
            }
        }
    }

    pluginManager.withPlugin("com.android.library") {
        extensions.configure<LibraryExtension> {
            compileSdk {
                version = release(37) {
                    minorApiLevel = 0
                }
            }

            defaultConfig {
                // Keep library API availability aligned with the app.
                minSdk = 33
            }

            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }

            lint {
                abortOnError = true
                warningsAsErrors = true
            }
        }
    }
}
