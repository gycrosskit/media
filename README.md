# GY CrossKit Media

系统选图、拍照、可选 JPEG 压缩和保存相册。返回图片编码字节、文件名与 MIME；上传、业务大小限制和页面提示由宿主负责。

Maven/Swift Package 0.1.2 已提供为预发行；默认 JitPack 全平台消费与 exact SPM iOS SDK 独立编译/链接通过。
HAR 0.1.2 已以 next 提交审核，registry 正式 latest 仍为 0.1.0。历史 Maven/Swift 0.1.1 和 HAR 0.1.0 保留。

## HAR 0.1.3 prerelease

拍照/保存临时路径改用实例 UUID 加请求序号，防止同毫秒跨页面覆盖或清理另一请求文件。目录、finally 释放和桥接契约保持。

| 渠道 | 本轮消费版本 | 状态 |
| --- | --- | --- |
| HarmonyOS HAR | 0.1.3 | 已发布且下载 SHA/API22 独立编译通过；Registry 审核中 |
| Maven core/Kuikly | 0.1.2 | 生产 Kotlin 未变，沿用已验精确远程版本 |
| Swift Package GycMedia | 0.1.2 | 原生 Swift 未变，沿用已验精确消费版本 |

0.1.3 标签只发布更新后的 HAR，不提供 Maven 0.1.3；JitPack 使用 Maven 0.1.2。


## 平台与要求

| 平台 | 接入方式 | 系统要求 |
| --- | --- | --- |
| Android | KMP `media-core` 原生实现 | API 24+，`ComponentActivity` |
| iOS | KMP + Swift bridge，或 Swift Package `GycMedia` | iOS 14+，Swift tools 5.9 |
| HarmonyOS | `media-kuikly` + `@gycrosskit/media` HAR | 当前 HAR 的 target/compatible SDK 均为 API 22 |

KMP 使用 Kotlin `2.2.21-1.0.0`、coroutines `1.10.2-1.0.0`，Kuikly 使用 `2.28.0-2.0.21-ohos`；OHOS 宿主需匹配工具链。

## 架构与调用流程

`media-core` 定义选图与保存契约，平台实现负责系统 UI、编码读取及资源收尾。iOS KMP 需要宿主接线 Swift bridge；HarmonyOS Kotlin Module 与 ArkTS Module 同名，分属不同产物。

```mermaid
flowchart TB
    Host[宿主] --> Core[media-core<br/>ImagePickerPlatform<br/>ImageSavePlatform]
    Core --> Android[Android<br/>Picker / Saver]
    Android --> AndroidSystem[ActivityResult<br/>MediaStore]
    Core --> IOS[iOS Picker / Saver<br/>IosMediaSdkBridge]
    IOS --> Bridge[宿主<br/>KmpMediaBridge]
    Bridge --> Swift[GycMedia<br/>MediaClient]
    Swift --> Apple[PhotosUI<br/>UIImagePickerController<br/>Photos]
    Core --> Module[media-kuikly<br/>MediaModule]
    Module --> Native[HAR<br/>ArkTS MediaModule]
    Native --> Harmony[cameraPicker<br/>photoAccessHelper<br/>ImageKit]
```

HarmonyOS 选图使用 requestId 隔离等待与取消；正常结果返回编码字节，宿主决定下一步保存或上传。取消不能强制关闭系统 Picker，原生操作仍需在退出时释放自己的资源。

```mermaid
sequenceDiagram
    participant Host as Kuikly 页面
    participant Module as Kotlin MediaModule
    participant Native as ArkTS MediaModule
    participant System as 系统 Picker
    Host->>Module: pick(request)
    Module->>Native: pick(requestId, source, compression)
    Native->>System: 打开相机或图库
    alt 系统完成且请求仍有效
        System-->>Native: 图片 URI
        Native->>Native: 读取；按需压缩；检查大小；编码 Base64
        Native-->>Module: selected / 权限结果 / cancelled / failed
        Module->>Module: 校验数量与 32 MiB 限额，解码
        Module-->>Host: ImagePickerResult
    else 协程取消或页面 dispose
        Module->>Native: cancel(requestId)
        Native->>Native: 结算本次等待，阻止后续读写
        Module->>Module: 移除回调，阻止迟交付
        Note over Native,System: 系统页面仍可能返回；所属操作退出时 finally 释放资源
    end
```

类图聚焦两种公共能力及选图实现；iOS saver 同样使用 `IosMediaSdkBridge`，Android saver 直接调用 MediaStore。

```mermaid
classDiagram
    class ImagePickerPlatform {
        <<interface>>
        +pick(request) ImagePickerResult
        +dispose()
    }
    class ImageSavePlatform {
        <<interface>>
        +save(request) ImageSaveResult
    }
    class AndroidImagePickerPlatform
    class IosImagePickerPlatform
    class IosMediaSdkBridge {
        <<interface>>
        +pickImages(source, maxCount, maxDimension, jpegQuality, callback)
        +cancelImagePicker()
        +saveImage(data, fileNamePrefix, callback)
    }
    class MediaModule
    ImagePickerPlatform <|.. AndroidImagePickerPlatform
    ImagePickerPlatform <|.. IosImagePickerPlatform
    ImagePickerPlatform <|.. MediaModule
    ImageSavePlatform <|.. MediaModule
    IosImagePickerPlatform --> IosMediaSdkBridge : 持有
```

源码：[选图契约](media-core/src/commonMain/kotlin/io/github/gycrosskit/media/ImagePickerPlatform.kt)、[保存契约](media-core/src/commonMain/kotlin/io/github/gycrosskit/media/ImageSavePlatform.kt)、[Android Picker](media-core/src/androidMain/kotlin/io/github/gycrosskit/media/AndroidImagePickerPlatform.kt)、[Android Saver](media-core/src/androidMain/kotlin/io/github/gycrosskit/media/AndroidImageSavePlatform.kt)、[iOS Picker](media-core/src/iosMain/kotlin/io/github/gycrosskit/media/IosImagePickerPlatform.kt)、[iOS Saver](media-core/src/iosMain/kotlin/io/github/gycrosskit/media/IosImageSavePlatform.kt)、[iOS bridge 契约](media-core/src/iosMain/kotlin/io/github/gycrosskit/media/IosMediaSdkBridge.kt)、[宿主 bridge 示例](iosApp/KmpMediaBridge.swift)、[Swift MediaClient](iosApp/Sources/GycMedia/MediaClient.swift)、[Kotlin MediaModule](media-kuikly/src/commonMain/kotlin/io/github/gycrosskit/media/kuikly/MediaModule.kt)、[ArkTS MediaModule](ohos/media/src/main/ets/MediaModule.ets)。

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

HarmonyOS 原生包独立安装；本轮使用已验 Maven 0.1.2 配合 HAR 0.1.3，桥接契约兼容。以下 registry 命令需等待审核可见；
审核期间可使用既有 Maven/HAR 0.1.2 配对，或从对应 Release 下载并校验 HAR 后本地安装：

```sh
ohpm install @gycrosskit/media@0.1.3
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

本轮制品校验与远程状态见 [0.1.3 发布验收](docs/发布验收-0.1.3.md)。
