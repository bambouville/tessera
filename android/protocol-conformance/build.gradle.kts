plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

sourceSets {
    main {
        kotlin.srcDir("../../KotlinConformance/src/main/kotlin")
    }
}

val checkProtocolVectors = tasks.register<JavaExec>("checkProtocolVectors") {
    group = "verification"
    description = "Runs the independent Kotlin consumer against ProtocolVectors"
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass = "tessera.conformance.MainKt"
    args(rootProject.projectDir.resolve("../ProtocolVectors").absolutePath)
}

tasks.named("check") {
    dependsOn(checkProtocolVectors)
}
