plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
    `maven-publish`
}

kotlin {
    androidTarget {
        publishLibraryVariants("release")
        compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11) }
    }
    listOf(iosX64(), iosArm64(), iosSimulatorArm64()).forEach {
        it.binaries.framework { baseName = "MediaCore"; isStatic = true }
    }
    ohosArm64()
    sourceSets {
        commonMain.dependencies { implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2-1.0.0") }
        androidMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2-1.0.0")
            api("androidx.activity:activity:1.13.0")
            implementation("androidx.lifecycle:lifecycle-runtime:2.10.0")
        }
        commonTest.dependencies { implementation(kotlin("test")) }
    }
}

android {
    namespace = "io.github.gycrosskit.media"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

publishing { repositories { maven {
    name = "Release"
    url = uri(providers.gradleProperty("releaseMavenRepo").orElse(rootProject.layout.buildDirectory.dir("release-maven").map { it.asFile.absolutePath }))
} } }
