pluginManagement {
    // 独立 JVM 验证复用 Android 阶段的同版 fork KGP，免除额外 marker 请求。
    resolutionStrategy {
        eachPlugin {
            if (requested.id.id == "org.jetbrains.kotlin.jvm") {
                useModule("org.jetbrains.kotlin:kotlin-gradle-plugin:${requested.version}")
            }
        }
    }
    repositories {
        maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
        maven("https://maven.aliyun.com/repository/public")
        gradlePluginPortal()
    }
}
dependencyResolutionManagement { repositories {
    maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
    maven("https://maven.aliyun.com/repository/public")
    mavenCentral()
} }
rootProject.name = "media-kuikly-lifecycle-tests"
