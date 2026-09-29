plugins {
    alias(libs.plugins.kotlin.multiplatform)
    `maven-publish`
}

kotlin {
    ohosArm64()
    sourceSets {
        commonMain.dependencies {
            api(project(":media-core"))
            api(libs.kuikly.core)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2-1.0.0")
        }
    }
}

publishing { repositories { maven {
    name = "Release"
    url = uri(providers.gradleProperty("releaseMavenRepo").orElse(rootProject.layout.buildDirectory.dir("release-maven").map { it.asFile.absolutePath }))
} } }
