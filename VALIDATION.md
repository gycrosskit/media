# Media 验收记录

## 0.1.2 构建与远程验收（2026-10-04）

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
- 最终归档独立 staging consumer 使用 --refresh-dependencies --rerun-tasks --info，Android、iOS arm64/x64/OHOS 编译与 Simulator Framework 链接通过：SUCCESS 1m2s、13 tasks 全执行。通过 mediaMavenRepo 参数只将本组件 group 指向候选 staging，没有源码 project/includeBuild/mavenLocal 替换；它不代表远程仓库消费。
- 归档前修复 metadata/checksum，staging 和归档解包目录完整检查均通过：8 个 metadata 模块、9 个文件引用和 7 个 available-at 引用；size/hash、内部坐标/版本和所有 checksum sidecar 一致；8 个 POM 均包含与本仓库 LICENSE 一致的 Apache 2.0 标签；19 个归档 ZIP CRC 与 Native sources 的最终修复内容检查通过。JitPack 安装只校验并解包同一字节，不运行 Python 或修改 metadata。
- API 22 HAR 构建与 `ohpm prepublish` 通过；包版本与应用版本字段均 0.1.2，未执行 publish。本轮不重复构建未变 HAR，实际解包核 public MediaModule 导出、GycMedia 名称、cancel/requestId 契约，包内源码与当前原生源码字节一致。
- Swift Package 实现保持原有 UUID/controller 所有权；本轮 exact0.1.2 独立 native SDK consumer 编译/最终链接通过，但没有重跑 UIKit 交互行为验收。

不可变 Release 归档（仓库根相对路径）：

| 产物 | SHA-256 |
| --- | --- |
| `build/release/0.1.2/media-maven.tar.gz` | `ec7e23a07e078e809f83f60fa9fe3d42dae618704abccdf97e19a6f1393d1899` |
| `build/release/0.1.2/media.har` | `89a08ae2acaf77e55eb1b4cc5a1cb60bfe9b5a5390fd04a46ee87be199c9dc65` |

最终日志在 `build/remote-dependency-closure/verification-final-source.log`、`kuikly-jvm-lifecycle-final.log`、`consumer-final-source.log`、
`har-build-final.log` 和 `har-prepublish-final.log`；SHA256SUMS 在候选目录，解包检查目录 archive-check-final。
pack-final-validation.json / har-public-api.json 记录产物检查。
发布与真实 Maven/SPM 消费的追加结果见下节；OHPM 仍在审核，真机选图/保存/权限/内存未验。
这些检查不证明系统 Picker 能撤回；取消已开始的系统操作只能隔离后续业务，句柄在所属 await 退出后释放。


### 0.1.2 远程结果

- [PR #5](https://github.com/gycrosskit/media/pull/5) 精确 HEAD 合并；不可变 tag0.1.2 指向 dd85d2cc7f114b639492b7fff76b02a40e3f41b2；[prerelease](https://github.com/gycrosskit/media/releases/tag/0.1.2) Maven/HAR/SHA256SUMS 重新下载 hash 匹配。没有覆盖旧 tag/附件。
- JitPack 最终 status=ok、isTag=true、同 commit 与 8 modules。真实远程 8.module/16variants 的 9 file refs（8 unique JAR/AAR/KLIB）和 7 available-at 均 HTTP200；每种声明 hash/size、ZIP CRC、内部版本及 8 个 Apache POM 通过。没有 metadataSources 或空资源 ZIP 引用。
- 6 个 top component.url 被 JitPack 改写为额外 media 子目录，真实404，原始报告保留。Gradle8.11.1 consumeComponent 只读 attributes，其他 component 字段跳过，见 [Gradle parser](https://github.com/gradle/gradle/blob/v8.11.1/platforms/software/dependency-management/src/main/java/org/gradle/api/internal/artifacts/ivyservice/ivyresolve/parser/GradleModuleMetadataParser.java)。不新增伪root坐标；真实 consumer 也已通过。
- 默认真实 JitPack consumer 无 mediaMavenRepo/init/mavenLocal/project/includeBuild 替换，--refresh-dependencies --rerun-tasks --info：Android、OHOS、iOS arm64/x64/Simulator Framework SUCCESS1m，13 tasks 全执行。日志包含22行本组件JitPack下载，8模块POM/module与6个实际选中AAR/KLIB；6个binary的Gradle cache字节/hash与远程声明一致。2个root metadata JAR已通过HTTP审计，但本次平台编译没有选用，未混称实际输入。
- 独立 SPM native consumer 仅依赖 remote exact0.1.2、产品GycMedia；Package.resolved和真实checkout都为同tag commit。Swift6.2.4以arm64-apple-ios14.0-simulator/iPhoneSimulator26.2 SDK编译，并最终link NativeConsumer动态库成功4.84s。vtool确认IOSSIMULATOR/minos14/sdk26.2，otool确认UIKit/Photos/PhotosUI等链接。clang有sysroot分类warning，真实Mach-O平台已单独核验；没有模拟器/设备UI执行，不以KMP Framework代替SPM结果。
- OHPM --tag next 提交exit0、under review；registry仍仅0.1.0/latest，没有宣称0.1.2已上架或已安装验收。

远程日志及精确身份记录在 build/remote-dependency-closure/{consumer-default-jitpack.log,consumer-default-identity.json,spm-native-resolve.log,spm-native-build.log,spm-native-identity.json}；全引用raw报告在media-remote-audit/report.json，classification.json单列topcomponent.url已知404。

## 0.1.1 Picker 修复验收

- `bash scripts/verify-ios-picker.sh`：独立 Swift 模块与消费 app 编译，并在 iPhone 17 / iOS 26.3 Simulator 实跑成功。覆盖未展示取消、真实展示/关闭转场、延迟 PHPicker 的即时连续替换、旧 delegate、终态回调重入、宿主页转场、Navigation/Tab/Split/presented/自定义 child 与无可见 presenter。
- `:media-core:publishAllPublicationsToReleaseRepository :media-kuikly:publishAllPublicationsToReleaseRepository :media-core:linkDebugFrameworkIosSimulatorArm64`：全部声明平台发布产物与 Simulator Framework 成功。
- 独立 Maven staging consumer：Android、iOS arm64/x64、OHOS 编译及 iOS Simulator Framework 链接成功。
- 8 个 Gradle Module Metadata / 20 个产物引用校验通过；使用共用 Python tarfile 发布脚本排除 AppleDouble，归档只包含 0.1.1。
- Swift / Maven 标签候选 0.1.1，OHPM 保持 0.1.0，因为此次原生改动仅影响 iOS。

远程发布/消费结果已记录在 [0.1.1 Release](https://github.com/gycrosskit/media/releases/tag/0.1.1)，当前接入版本与核对范围见 [开发与验证](docs/开发与验证.md)。未执行真机相机、权限、选图/保存相册、大图内存与生产业务验收。
