# GY CrossKit Media

新版 Maven 发布由 Jenkins 生成同版本归档、`source-receipt.json` 和 `SHA256SUMS`。JitPack 核对标签来源、归档尺寸和摘要后安装同一份制品。历史发布按原版本 Tag 复验。

> 版本 `1.1.0`：Maven、Swift Package `GycMedia`（`native-1.1.0`）与私有 OHPM（`1.1.0`）。各渠道发布与精确远程消费状态以对应 Release 为准，设备验收单独记录。

Kuikly 由宿主统一选择版本；组件构建基线、允许范围及消费验证边界见[功能与平台差异](docs/功能与平台差异.md#kuikly-版本与宿主选择)。

> 上一发行基线：Maven **1.0.2** 已发布：[Release](https://github.com/gycrosskit/media/releases/tag/1.0.2)。13 个 publications 的公开元数据与字节核验、公开 OHOS 编译消费已完成；真实 imageThumbnail cinterop 使用独立 `media-cinterop-ohosarm64` 模块，由 core 正常传递依赖，保留两个真实 KLIB。HarmonyOS HAR/OHPM 为 **1.0.3**（`har-1.0.3`），iOS Git Pod 为 `1.0.2`（`native-1.0.2`）；发布与精确消费状态见对应 Release，旧版本 Tag/归档保留，真机行为另验。

## 当前功能与平台边界

`media-core` 提供原始文件选择、选图、拍照、可选 JPEG 压缩和相册保存。`media-kuikly` 提供三端调用侧和 Android/iOS 原生接收端。宿主管理注入的原生能力、文件消费与释放、上传及页面提示。接线见[接入指南](docs/接入指南.md)，当前验证和未验收项见[功能与平台差异](docs/功能与平台差异.md#验证范围)。

历史版本的坐标与验收见[版本记录](CHANGELOG.md)及 [Release](https://github.com/gycrosskit/media/releases)。

## 平台与要求

| 平台 | 接入方式 | 系统要求 |
| --- | --- | --- |
| Android | KMP `media-core` 原生实现 | API 24+，`ComponentActivity` |
| iOS | KMP + Swift bridge，或 Swift Package `GycMedia` | iOS 14+，Swift tools 5.9 |
| HarmonyOS | `media-kuikly` + `@gycrosskit/media` HAR | 当前 HAR 的 target/compatible SDK 均为 API 22 |

KMP 使用 Kotlin `2.2.21-1.0.0`、coroutines `1.10.2-1.0.0`，Kuikly 使用 `2.29.1-2.0.21-ohos`；OHOS 宿主需匹配工具链。

## 架构与调用流程

iOS KMP 通过宿主的 Swift bridge 接到 `GycMedia`。HarmonyOS 的 Kotlin 和 ArkTS `MediaModule` 分别通过 Maven 和 HAR 交付，使用 `requestId` 隔离等待与取消。调用方取消后停止接收旧结果，系统 Picker 退出时由原生 owner 释放资源。源码入口见 [AOCI 索引](aoci.txt)。

## 安装

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        exclusiveContent {
            forRepository {
                maven("https://mirrors.tencent.com/nexus/repository/maven-tencent/")
            }
            filter { includeGroup("com.tencent.kuikly-open") }
        }
        maven("https://jitpack.io")
        maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
        google()
        mavenCentral()
    }
}
```

Kuikly group 固定从腾讯 Maven 读取 metadata 和实际产物，避免其他镜像先返回 metadata、随后产物缺失时 Gradle 无法切源。此规则只匹配 `com.tencent.kuikly-open`，其他 SDK 的仓库选择保持；该仓库路由的历史检查见 [0.1.4 远程发布验收](docs/0.1.4远程发布验收.md)。

```kotlin
commonMain.dependencies {
    implementation("com.github.gycrosskit.media:media-core:1.1.0")
}
ohosArm64Main.dependencies {
    implementation("com.github.gycrosskit.media:media-kuikly:1.1.0")
}
```

SPM 在 Xcode 的 Package Dependencies 使用 `https://github.com/gycrosskit/media.git`，产品 `GycMedia`，固定精确 tag `native-1.1.0`。KMP 不自动导入该 Swift Package，桥接步骤见接入指南。

HarmonyOS 原生包从私有 OHPM 安装精确版本 `1.1.0`：

```sh
ohpm install @gycrosskit/media@1.1.0
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

选图数量合同统一为 `1..500`，系统 Picker 可采用更低上限。Android Launcher 注册/启动异常都会清理 owner；相机临时文件按请求 suffix 隔离。保存保留原始字节：Android API28+ 严格拒绝 partial；API24–27、Swift 和 HAR 先核对 PNG/JPEG/WebP 结束边界再做小尺寸实际解码。兼容解码器对其他编码错误的限制见完整源码审查。HAR 保存的非字符串文件名前缀在任何原生读写前返回 `invalid_content`。

Android 声明 `CAMERA`；API 28 及以下保存相册还需 `WRITE_EXTERNAL_STORAGE`（`maxSdkVersion="28"`）。系统选图不申请整库读取权限。iOS 填写 `NSCameraUsageDescription`、`NSPhotoLibraryAddUsageDescription`，PHPicker 不读取整库授权，保存请求 `.addOnly`。

取消、拒绝权限、已阻止权限、设备策略限制和失败分开返回。Android/iOS 的新 Picker 替换旧请求；原生平台的 `pick()`、`save()` 和 `dispose()` 可从调用方线程进入，SDK、权限与 Picker 状态由组件切到主线程。`dispose()` 立即撤销已回调但尚未交付的结果，释放是终态，同实例后续 pick 返回 Failed，宿主须创建新实例。HarmonyOS 系统 Picker 忙时返回失败，Kotlin Module 销毁时 `dispose()`。
新版 Kotlin/HAR 使用 requestId 成对隔离，取消结束自有原生等待、移除回调并阻止后续读写；旧系统 Picker
返回前仍保持忙状态，不承诺强制关闭系统页面。文件、图像 source/pixels/packer 和相册 helper 在所属原生操作
退出时由 finally 释放；不可撤回的系统操作需等待它返回，不复用旧 ID，不让旧 cancel 或迟到结果影响新请求。

单次输入原图总量、输出结果总量分别不超过 32 MiB。HarmonyOS 的 JSON/Base64 桥在 decode 前检查限额，
原图文件在读取分配前检查输入剩余额度，显式 JPEG 压缩后检查独立的输出合计再编码。原图不重编码，三类权限结果保持。Android 保存支持 PNG/JPEG/WebP；
iOS/HarmonyOS 按系统图像解码能力识别格式。不提供视频、上传或扫码。真实设备权限、选择器、相册写入与大图内存仍需宿主验收。

## 文档与帮助

- [接入指南](docs/接入指南.md)：平台初始化、权限声明和生命周期。
- [开发与验证](docs/开发与验证.md)：源码构建、检查命令与验收范围。
- [版本与发行说明](https://github.com/gycrosskit/media/releases)、[问题反馈](https://github.com/gycrosskit/media/issues)。

组件源码使用 Apache-2.0，见 [LICENSE](LICENSE)。Kuikly 和平台 SDK 遵循各自许可。

## 历史发布记录

以下记录保留对应版本、渠道与验收时点，不替代顶部当前功能和安装基线。

- <a id="015-历史发布状态"></a>[0.1.5 发布验收](docs/0.1.5发布验收.md)。
- <a id="014-历史-prerelease"></a>[0.1.4 远程发布验收](docs/0.1.4远程发布验收.md)。
- [0.1.3 HAR 发布验收](docs/发布验收-0.1.3.md)、[历史渠道配对](CHANGELOG.md#har-013)。

## 自动回归

源码回归使用 `component-ci/verify`，见[统一远程验证（Jenkins）](https://github.com/gycrosskit/.github/blob/main/docs/统一远程验证.md)，按已推送源码 ref/SHA 选择对应组件；平台命令与参数以受信 Jenkins recipe 为准。实际执行范围、测试数量、结果与耗时以绑定源码/CI SHA 的构建回执为准，轻量检查或跳过不算平台测试通过。

新版本按[发布流程](https://github.com/gycrosskit/.github/blob/main/docs/发布流程.md)执行 `component-ci/release`。按渠道绑定准确的源码 SHA、版本和必要的 Tag，在同一次 Run 冻结候选并核对远端制品，保留发布和消费回执。

HAR 使用受管 HarmonyOS CLT 构建。KLIB 编译、Registry 安装及真机验收分别按实际回执记录。

阶段、缓存、有限网络重试、失败记录与证据边界见[共用 CI 规则](https://github.com/gycrosskit/.github/blob/main/docs/持续集成门禁.md)；本库实际平台命令以 Jenkins 的固定版本 recipe 为准。源码通过、远程消费、HAR/ohpm 与设备验收分别记录。
