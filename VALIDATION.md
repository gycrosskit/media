# 0.1.1 Picker 修复验收

- `bash scripts/verify-ios-picker.sh`：独立 Swift 模块与消费 app 编译，并在 iPhone 17 / iOS 26.3 Simulator 实跑成功。覆盖未展示取消、真实展示/关闭转场、延迟 PHPicker 的即时连续替换、旧 delegate、终态回调重入、宿主页转场、Navigation/Tab/Split/presented/自定义 child 与无可见 presenter。
- `:media-core:publishAllPublicationsToReleaseRepository :media-kuikly:publishAllPublicationsToReleaseRepository :media-core:linkDebugFrameworkIosSimulatorArm64`：全部声明平台发布产物与 Simulator Framework 成功。
- 独立 Maven staging consumer：Android、iOS arm64/x64、OHOS 编译及 iOS Simulator Framework 链接成功。
- 8 个 Gradle Module Metadata / 20 个产物引用校验通过；使用共用 Python tarfile 发布脚本排除 AppleDouble，归档只包含 0.1.1。
- Swift / Maven 标签候选 0.1.1，OHPM 保持 0.1.0，因为此次原生改动仅影响 iOS。

远程发布/消费验证在版本发布后另行记录。未执行真机相机、权限、选图/保存相册、大图内存与生产业务验收。
