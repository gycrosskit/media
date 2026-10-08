# 更新日志

## 0.1.7（2026-10-08）

- 精简Android Picker单实现层；补正常完成后的重复回执隔离测试；明确dispose为终态。
- 更新功能、测试覆盖与平台差异文档；设备业务验收范围保持明确。

## 未发布：Maven/HAR 0.1.5，Swift native-0.1.3

修复现代 Android Picker 启动清理、相机跨实例文件隔离和 maxCount 1..500 合同。保存继续写原字节：Android API28+ 严格拒绝 ImageDecoder partial，API24–27 与 Swift 对 PNG/JPEG/WebP 检查标准结束边界后小尺寸实际解码；HAR 实际解码并释放小 PixelMap。修复可读尺寸但缺少像素的截断输入误入授权/保存。Swift 采用独立不可变 tag/revision `native-0.1.3`，不重用仅提供 HAR 的历史 `0.1.3` tag；此仓库不提供 CocoaPods podspec。候选均未发布，远程消费及设备验收另行记录。

## HAR 0.1.3

拍照/保存临时路径改用实例 UUID 加请求序号，防止同毫秒跨页面覆盖或清理另一请求文件。目录、finally 释放和桥接契约保持。

| 渠道 | 本轮消费版本 | 状态 |
| --- | --- | --- |
| HarmonyOS HAR | 0.1.3 | 已发布且下载 SHA/API22 独立编译通过；Registry 审核中 |
| Maven core/Kuikly | 0.1.2 | 生产 Kotlin 未变，沿用已验精确远程版本 |
| Swift Package GycMedia | 0.1.2 | 原生 Swift 未变，沿用已验精确消费版本 |

0.1.3 标签只发布更新后的 HAR，不提供 Maven 0.1.3；JitPack 使用 Maven 0.1.2。


历史版本与验证范围见 [Releases](https://github.com/gycrosskit/media/releases)；真实消费与 Registry 状态见本轮发布验收。
