# GY CrossKit Media

系统选图、拍照、可选 JPEG 压缩和保存相册。返回图片编码字节、文件名与 MIME；上传、业务大小限制和页面提示由宿主负责。

Maven/Swift Package 0.1.2 已提供为预发行；默认 JitPack 全平台消费与 exact SPM iOS SDK 独立编译/链接通过。
HAR 0.1.2 已以 next 提交审核，registry 正式 latest 仍为 0.1.0。历史 Maven/Swift 0.1.1 和 HAR 0.1.0 保留。

## 平台与要求

| 平台 | 接入方式 | 系统要求 |
| --- | --- | --- |
| Android | KMP `media-core` 原生实现 | API 24+，`ComponentActivity` |
| iOS | KMP + Swift bridge，或 Swift Package `GycMedia` | iOS 14+，Swift tools 5.9 |
| HarmonyOS | `media-kuikly` + `@gycrosskit/media` HAR | 当前 HAR 的 target/compatible SDK 均为 API 22 |

KMP 使用 Kotlin `2.2.21-1.0.0`、coroutines `1.10.2-1.0.0`，Kuikly 使用 `2.28.0-2.0.21-ohos`；OHOS 宿主需匹配工具链。

## 安装

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        maven("https://jitpack.io")
        maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
        google()
        mavenCentral()
    }
}
```

```kotlin
commonMain.dependencies {
    implementation("com.github.gycrosskit.media:media-core:0.1.2")
}
ohosArm64Main.dependencies {
    implementation("com.github.gycrosskit.media:media-kuikly:0.1.2")
}
```

iOS 在 Xcode 的 Package Dependencies 添加 `https://github.com/gycrosskit/media.git`，选择精确版本 `0.1.2`，产品 `GycMedia`。KMP 不自动导入该 Swift Package，桥接步骤见接入指南。

HarmonyOS 原生包独立安装；Kotlin Module 与 HAR 0.1.2 需成对更新。以下 registry 命令需等待审核可见；
审核期间保留旧配对 Maven 0.1.1/HAR 0.1.0，或从 0.1.2 Release 下载并校验 HAR 后本地安装：

```sh
ohpm install @gycrosskit/media@0.1.2
```

## 最小使用

```kotlin
import io.github.gycrosskit.media.*

// permission 是宿主的 suspend (String) -> MediaPermissionState 权限入口。
val picker = AndroidImagePickerPlatform(activity, permission)
val saver = AndroidImageSavePlatform(activity, permission)
// 绑定页面生命周期的协程内调用：
val result = picker.pick(ImagePickerRequest(
    source = ImagePickerSource.GALLERY,
    maxCount = 3,
    compression = ImageCompression(maxDimension = 2048, jpegQuality = 85),
))
if (result is ImagePickerResult.Selected) {
    val image = result.images.first()
    val saved = saver.save(ImageSaveRequest(image.bytes, fileNamePrefix = "photo"))
}
// 宿主销毁时：
picker.dispose()
```

不传 `compression` 保留原始编码；系统相机只提供 UIImage 时会编码为 JPEG。iOS 构建 `IosImagePickerPlatform(bridge)` / `IosImageSavePlatform(bridge)`；HarmonyOS 注册 `MediaModule`。

## 权限与边界

Android 声明 `CAMERA`；API 28 及以下保存相册还需 `WRITE_EXTERNAL_STORAGE`（`maxSdkVersion="28"`）。系统选图不申请整库读取权限。iOS 填写 `NSCameraUsageDescription`、`NSPhotoLibraryAddUsageDescription`，PHPicker 不读取整库授权，保存请求 `.addOnly`。

取消、拒绝权限、已阻止权限、设备策略限制和失败分开返回。Android/iOS 的新 Picker 替换旧请求；入口和 `dispose()` 在主线程调用。HarmonyOS 系统 Picker 忙时返回失败，Kotlin Module 销毁时 `dispose()`。
新版 Kotlin/HAR 使用 requestId 成对隔离，取消结束自有原生等待、移除回调并阻止后续读写；旧系统 Picker
返回前仍保持忙状态，不承诺强制关闭系统页面。文件、图像 source/pixels/packer 和相册 helper 在所属原生操作
退出时由 finally 释放；不可撤回的系统操作需等待它返回，不复用旧 ID，不让旧 cancel 或迟到结果影响新请求。

HarmonyOS 的 JSON/Base64 桥在 decode 前检查单张和合计 32 MiB，原图文件在读取分配前检查剩余额度，
显式 JPEG 压缩后也检查输出合计再编码。原图不重编码，三类权限结果保持。Android 保存支持 PNG/JPEG/WebP；
iOS/HarmonyOS 按系统图像解码能力识别格式。不提供视频、上传或扫码。真实设备权限、选择器、相册写入与大图内存仍需宿主验收。

## 文档与帮助

- [接入指南](docs/接入指南.md)：平台初始化、权限声明和生命周期。
- [开发与验证](docs/开发与验证.md)：源码构建、检查命令与验收范围。
- [版本与发行说明](https://github.com/gycrosskit/media/releases)、[问题反馈](https://github.com/gycrosskit/media/issues)。

组件源码使用 Apache-2.0，见 [LICENSE](LICENSE)。Kuikly 和平台 SDK 遵循各自许可。
