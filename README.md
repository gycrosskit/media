# GYC Media

Android、iOS、HarmonyOS 的系统选图、拍照、可选 JPEG 压缩和保存相册组件。输出图片编码字节、文件名和 MIME；上传、业务大小限制和页面提示由宿主负责。

## 目录与平台

| 目录 | 职责 |
| --- | --- |
| `media-core/` | KMP 公共 API、Android 原生实现、iOS Swift 接口 |
| `media-kuikly/` | HarmonyOS 的 Kuikly 调用桥 |
| `iosApp/` | 独立 Swift Package 原生实现及 KMP 接线示例 |
| `ohos/` | HarmonyOS HAR 工程，`@gycrosskit/media` |
| `verification-consumer/` | 只用 Maven 坐标的独立三端消费工程 |

最低系统：Android API 24、iOS 14；当前 HAR 以 HarmonyOS API 22 构建。许可 Apache-2.0。基于接入项目 `codex/harmony-production-integration` 中已有媒体实现抽离，源码归属业务持有人；没有引入账号、上传接口或扫码识别。

## Gradle 接入

```kotlin
repositories {
    maven("https://jitpack.io") { content { includeGroup("com.github.gycrosskit.media") } }
    // Kotlin/OHOS 与 kotlinx.coroutines 的厂商适配版本。
    maven("https://maven.eazytec-cloud.com/nexus/repository/maven-public/")
    google()
    mavenCentral()
    maven("https://mirrors.tencent.com/nexus/repository/maven-public/")
}
commonMain.dependencies { implementation("com.github.gycrosskit.media:media-core:0.1.1") }
// Kuikly 的 OHOS 模块：
ohosArm64Main.dependencies { implementation("com.github.gycrosskit.media:media-kuikly:0.1.1") }
```

构建使用 Kotlin `2.2.21-1.0.0`、coroutines `1.10.2-1.0.0`，Kuikly `2.28.0-2.0.21-ohos`。使用 OHOS target 的宿主需要匹配的 Kotlin 工具链。

```kotlin
val result = picker.pick(ImagePickerRequest(
    source = ImagePickerSource.GALLERY,
    maxCount = 3,
    compression = ImageCompression(maxDimension = 2048, jpegQuality = 85),
))
// 原图：省略 compression。Selected.images 每项包含 bytes / fileName / contentType。
val saved = saver.save(ImageSaveRequest(bytes = imageBytes, fileNamePrefix = "photo"))
```

取消、拒绝权限、已阻止权限和设备限制分别表达。Android/iOS 的新 Picker 会替换旧请求；HarmonyOS 系统 Picker 正忙时返回失败。宿主销毁时调用 `picker.dispose()`（Kuikly Module 同样需 dispose），防止迟到回调进入业务。Android/iOS 入口和 dispose 在主线程调用。

## Android

```kotlin
val picker = AndroidImagePickerPlatform(activity, permission = ::requestMediaPermission)
val saver = AndroidImageSavePlatform(activity, permission = ::requestMediaPermission)
```

`requestMediaPermission: suspend (String) -> MediaPermissionState` 由宿主对接权限库，返回 `GRANTED / DENIED / BLOCKED / RESTRICTED`。声明 `android.permission.CAMERA`；API 28 及以下保存相册还需 `WRITE_EXTERNAL_STORAGE`（`maxSdkVersion="28"`）。相册选择使用系统 Photo Picker / ACTION_GET_CONTENT，不申请整库读取权限。

AAR 自动合并 FileProvider `${applicationId}.gycrosskit.media`，只暴露应用私有 Pictures 目录。压缩前采样解码并应用 EXIF 旋转/镜像；拍照临时文件在结束或取消时清理。保存使用 MediaStore，写入失败时清理未完成条目。

## iOS

Swift Package URL `https://github.com/gycrosskit/media`，版本 `0.1.1`，产品 `GycMedia`。直接原生接入使用 `MediaClient.shared` 和 `MediaPickerCallback / MediaSaveCallback`。

KMP 宿主将 `media-core` 导出到自己的 Framework，然后加入 `iosApp/KmpMediaBridge.swift`，把 `import MediaCore` 改成宿主 Framework 名。将 `KmpMediaBridge` 实例传给 `IosImagePickerPlatform` / `IosImageSavePlatform`。

Info.plist 配置 `NSCameraUsageDescription` 和 `NSPhotoLibraryAddUsageDescription`；说明文案由宿主提供。PHPicker 无需读取整库权限；保存仅请求 `.addOnly`。默认从 foregroundActive 场景的 key window 递归查找 presented、Navigation、Tab、Split 和可见自定义 child。多个前台窗口或无法按可见 child 判定活动页的自定义容器，在主线程设置 `MediaClient.shared.presenterResolver = { [weak page] in page }`，返回 nil 时本次选择失败；仍共用同一 Picker 请求所有权。

未展示的 UIViewController 关闭回调立即完成；PHPicker 已交给 UIKit 排队展示时，组件等它完成展示再关闭，期间保留最新待展示请求。Picker 或宿主页处于展示/关闭转场时，在转场结束后的下一轮主队列重新解析并检查；隐藏或不在 window 内的展示页面直接失败。连续替换只展示最新请求，旧页面关闭和迟到回调不会关闭新 Picker。无压缩选图保留原始编码；系统相机只提供 UIImage 时会编码为质量 1 的 JPEG。

## HarmonyOS

```shell
ohpm install @gycrosskit/media@0.1.0
```

ArkTS 导入 `MediaModule`，按宿主 Kuikly 初始化流程注册 `MediaModule.MODULE_NAME`（`GycMedia`）；Kotlin 注册 `io.github.gycrosskit.media.kuikly.MediaModule` 并用作 picker/saver。宿主保留系统相机调用需要的权限声明。相册使用系统 PhotoViewPicker；保存使用逐次授权对话框。

JSON/Base64 桥每次原图合计上限 32 MiB（压缩前检查），超限返回失败；大量照片或更大原图需要单独的二进制传输方案。系统 Picker 关闭由用户操作；协程取消会移除 Kotlin 回调，不承诺强制关闭系统页面。

## 验证与发布

执行 `scripts/verify.sh` 编译 Android/iOS/OHOS，跑公共 API 单测，检查 Swift 原生和 KMP 接线。HAR：`ohos/` 执行 `ohpm install --all` 后 `hvigorw --mode module -p module=MediaNative@default -p product=default assembleHar --no-daemon`。

iOS Picker 最小回归检查：启动一个 iOS Simulator 后执行 `bash scripts/verify-ios-picker.sh`（多台启动时用 `MEDIA_SIMULATOR=<设备 ID>` 指定）。脚本独立编译 Swift module 和消费应用，在 Simulator 检查未展示取消、Picker/宿主页的真实 UIKit 展示/关闭转场、连续替换、迟到 delegate、回调重入、容器查找及无可见 presenter 的失败；无需 Gradle，不代替真机相机/权限/相册验收。

Maven 由 macOS 执行 `publishAllPublicationsToReleaseRepository`，默认产物位于 `build/release-maven`。使用 `python3 release-pack.py build/release-maven build/release/media-maven.tar.gz 0.1.1` 只打包当前版本并排除 macOS AppleDouble，写入 `release-checksums.txt` 后上传 GitHub Release 的 `media-maven.tar.gz`，`jitpack-install.sh` 校验 SHA-256 再安装。标签不可变，不在仓库提交 Maven 二进制目录。

本地已验证 Android 编译与单测、iOS Simulator Framework 链接及 Swift typecheck、OHOS KLIB 编译和 HAR 构建。尚未做 Android/iOS/HarmonyOS 真机的授权、系统选择器、相册写入和大图内存验收。各远程渠道状态见 Release 说明，ohpm 审核提交不等于上架。
