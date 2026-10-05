plugins {
    kotlin("multiplatform") version "2.2.21-1.0.0"
    id("com.android.library") version "8.10.1"
}
val mediaVersion = providers.gradleProperty("mediaVersion").orElse("0.1.5").get()
kotlin {
    androidTarget()
    iosArm64()
    iosX64 { binaries.framework { baseName = "MediaConsumer" } }
    iosSimulatorArm64 { binaries.framework { baseName = "MediaConsumer" } }
    ohosArm64()
    sourceSets {
        commonMain.dependencies { implementation("com.github.gycrosskit.media:media-core:$mediaVersion") }
        val ohosArm64Main by getting {
            dependencies { implementation("com.github.gycrosskit.media:media-kuikly:$mediaVersion") }
        }
    }
}
android { namespace = "io.github.gycrosskit.media.consumer"; compileSdk = 36; defaultConfig { minSdk = 24 } }
