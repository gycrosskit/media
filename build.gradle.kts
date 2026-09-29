plugins {
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.android.library) apply false
}
allprojects {
    group = providers.environmentVariable("GROUP").orElse("com.github.gycrosskit.media").get()
    version = providers.environmentVariable("VERSION").orElse("0.1.0").get()
}
