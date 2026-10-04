# 更新日志

## HAR 0.1.3

拍照/保存临时路径改用实例 UUID 加请求序号，防止同毫秒跨页面覆盖或清理另一请求文件。目录、finally 释放和桥接契约保持。

| 渠道 | 本轮消费版本 | 状态 |
| --- | --- | --- |
| HarmonyOS HAR | 0.1.3 | 已发布且下载 SHA/API22 独立编译通过；Registry 审核中 |
| Maven core/Kuikly | 0.1.2 | 生产 Kotlin 未变，沿用已验精确远程版本 |
| Swift Package GycMedia | 0.1.2 | 原生 Swift 未变，沿用已验精确消费版本 |

0.1.3 标签只发布更新后的 HAR，不提供 Maven 0.1.3；JitPack 使用 Maven 0.1.2。


历史版本与验证范围见 [Releases](https://github.com/gycrosskit/media/releases)；真实消费与 Registry 状态见本轮发布验收。
