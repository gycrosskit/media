plugins {
    kotlin("multiplatform") version "2.2.21-1.0.0"
    id("com.android.library") version "8.10.1"
}
kotlin {
    androidTarget()
    iosArm64()
    iosX64()
    iosSimulatorArm64 { binaries.framework { baseName = "MediaConsumer" } }
    ohosArm64()
    sourceSets {
        commonMain.dependencies { implementation("com.github.gycrosskit.media:media-core:0.1.1") }
        val ohosArm64Main by getting {
            dependencies { implementation("com.github.gycrosskit.media:media-kuikly:0.1.1") }
        }
    }
}
android { namespace = "io.github.gycrosskit.media.consumer"; compileSdk = 36; defaultConfig { minSdk = 24 } }
