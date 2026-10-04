# Media 验收记录

## 0.1.2 候选验收（2026-10-04）

后续 review 的迟恢复 dispose 和 selected 数量前置检查已纳入最终源码与归档。
旧 Maven hash 458018… 已废弃，以本节 ec7e23… 为准；HAR 源码未变，既有 HAR hash 有效。

M16 的 Kuikly `MediaModule` 维持 ImagePickerPlatform/ImageSavePlatform API，用实例唯一前缀和 requestId
隔离取消与 dispose；HAR 结束所属 Promise 等待并拦截后续读写。系统 Picker 不可物理撤回时保持 busy，
直到系统操作退出才允许新 pick；finally 在当前原生等待返回后释放所属文件/图片/相册 helper 和拍照临时文件。
Kotlin 接收与 HAR 保存均在 Base64 decode 前检查 32 MiB，原图读取分配与压缩输出均检查合计。

- ArkTS 生产模块 mock 契约：`node --test ohos/media/test/media.test.cjs`，11 tests 全通过，覆盖原图字节/句柄释放、取消与旧 Picker busy、并行请求隔离、destroy、读写取消、相机临时文件、decode 前上限、原图合计与 JPEG 超限/失败释放。
- 独立 JVM harness 直接编译生产 MediaModule，仅替换 Kuikly 传输/JSON：4 tests，0 failures、0 skipped，覆盖 pick/save 回调已 resume 但 dispatch 前 dispose、超量图片数组在访问前拒绝和有效原图兼容。此 harness 不模拟真实 Kuikly 序列化或系统 Picker。首次因本机只有 JDK21、没有 JDK17 toolchain 失败；使用现有JDK21生成 JVM17 字节码后通过。
- 既有 Android 定向单测：2 tests，0 failures、0 skipped。
- 最终源码显式 GROUP=com.github.gycrosskit.media、VERSION=0.1.2 全部 Maven publication 成功（SUCCESS 21s）：Android Release AAR、iOS arm64/x64/Simulator arm64 和 OHOS core/Kuikly KLIB。
- 最终归档独立 staging consumer 使用 --refresh-dependencies --rerun-tasks --info，Android、iOS arm64/x64/OHOS 编译与 Simulator Framework 链接通过：SUCCESS 1m2s、13 tasks 全执行。临时 Gradle init 只将本组件 group 指向候选 staging，没有源码 project/includeBuild/mavenLocal 替换；它不代表远程仓库消费。
- 归档前修复 metadata/checksum，staging 和归档解包目录完整检查均通过：8 个 metadata 模块、9 个文件引用和 7 个 available-at 引用；size/hash、内部坐标/版本和所有 checksum sidecar 一致；8 个 POM 均包含与本仓库 LICENSE 一致的 Apache 2.0 标签；19 个归档 ZIP CRC 与 Native sources 的最终修复内容检查通过。JitPack 安装只校验并解包同一字节，不运行 Python 或修改 metadata。
- API 22 HAR 构建与 `ohpm prepublish` 通过；包版本与应用版本字段均 0.1.2，未执行 publish。本轮不重复构建未变 HAR，实际解包核 public MediaModule 导出、GycMedia 名称、cancel/requestId 契约，包内源码与当前原生源码字节一致。
- Swift Package 实现保持原有 UUID/controller 所有权；0.1.2 仅为后续标签候选，本轮未重跑独立 Swift/UIKit 行为验收。

候选归档（仓库根相对路径）：

| 产物 | SHA-256 |
| --- | --- |
| `build/release/0.1.2/media-maven.tar.gz` | `ec7e23a07e078e809f83f60fa9fe3d42dae618704abccdf97e19a6f1393d1899` |
| `build/release/0.1.2/media.har` | `89a08ae2acaf77e55eb1b4cc5a1cb60bfe9b5a5390fd04a46ee87be199c9dc65` |

最终日志在 `build/remote-dependency-closure/verification-final-source.log`、`kuikly-jvm-lifecycle-final.log`、`consumer-final-source.log`、
`har-build-final.log` 和 `har-prepublish-final.log`；SHA256SUMS 在候选目录，解包检查目录 archive-check-final。
pack-final-validation.json / har-public-api.json 记录产物检查。
未发布、未打 tag、未执行候选远程 Maven/Swift/OHPM 消费和真机选图/保存/权限/内存验收。
这些检查不证明系统 Picker 能撤回；取消已开始的系统操作只能隔离后续业务，句柄在所属 await 退出后释放。

## 0.1.1 Picker 修复验收

- `bash scripts/verify-ios-picker.sh`：独立 Swift 模块与消费 app 编译，并在 iPhone 17 / iOS 26.3 Simulator 实跑成功。覆盖未展示取消、真实展示/关闭转场、延迟 PHPicker 的即时连续替换、旧 delegate、终态回调重入、宿主页转场、Navigation/Tab/Split/presented/自定义 child 与无可见 presenter。
- `:media-core:publishAllPublicationsToReleaseRepository :media-kuikly:publishAllPublicationsToReleaseRepository :media-core:linkDebugFrameworkIosSimulatorArm64`：全部声明平台发布产物与 Simulator Framework 成功。
- 独立 Maven staging consumer：Android、iOS arm64/x64、OHOS 编译及 iOS Simulator Framework 链接成功。
- 8 个 Gradle Module Metadata / 20 个产物引用校验通过；使用共用 Python tarfile 发布脚本排除 AppleDouble，归档只包含 0.1.1。
- Swift / Maven 标签候选 0.1.1，OHPM 保持 0.1.0，因为此次原生改动仅影响 iOS。

远程发布/消费结果已记录在 [0.1.1 Release](https://github.com/gycrosskit/media/releases/tag/0.1.1)，当前接入版本与核对范围见 [开发与验证](docs/开发与验证.md)。未执行真机相机、权限、选图/保存相册、大图内存与生产业务验收。
