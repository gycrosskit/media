pluginManagement { repositories {
    maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
    maven("https://maven.aliyun.com/repository/public")
    gradlePluginPortal()
} }
dependencyResolutionManagement { repositories {
    maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
    maven("https://maven.aliyun.com/repository/public")
    mavenCentral()
} }
rootProject.name = "media-kuikly-lifecycle-tests"
