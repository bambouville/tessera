pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "TesseraAndroid"

include(
    ":app",
    ":feature-hosts",
    ":feature-session",
    ":feature-pairing",
    ":design",
    ":markdown",
    ":terminal",
    ":data",
    ":security",
    ":networking",
    ":lifecycle",
    ":billing",
    ":files",
    ":port-forwarding",
    ":core-bridge",
    ":core-native-fallback",
    ":protocol-conformance",
    ":agent-platform",
    ":feature-agent-center",
)
