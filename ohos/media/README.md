# @gycrosskit/media

适用版本：此版 Maven `0.1.7` 复用已发布 HAR `0.1.6` 的原字节。完整功能与五入口限制见[功能与平台差异](https://github.com/gycrosskit/media/blob/0.1.7/docs/功能与平台差异.md)；本版发布记录见[Release](https://github.com/gycrosskit/media/releases/tag/0.1.7)。此源码 README 的文档更新不重新发布或修改既有 HAR。

HAR `0.1.6` 已发布；Registry 精确安装与固定 Release HAR 消费分别验收，不以一个渠道代替另一个。

系统选图、拍照、可选 JPEG 压缩和相册保存的 Kuikly Module。当前 HAR target/compatible SDK 为 HarmonyOS API 22。

```sh
ohpm install @gycrosskit/media@0.1.6
```

```typescript
import { MediaModule } from '@gycrosskit/media';
modules.set(MediaModule.MODULE_NAME, () => new MediaModule());
```

旧 HAR0.1.3 的发布及审核记录仅代表当时查询。此版 Maven media-kuikly:0.1.7 配套已发布 HAR0.1.6，模块名称 GycMedia，桥接契约兼容。
临时文件使用实例 UUID 加请求序号，避免跨页面同毫秒碰撞；目录与本次请求清理归属保持。
宿主提供相机权限声明，页面销毁调用 Kotlin MediaModule.dispose()。pick/save 附加 requestId，cancel 只结束
匹配请求等待，阻止后续读写并在收尾时释放原生资源；系统 Picker 返回前仍保持 busy，旧 ID 不影响新请求。
单次输入原图总量、输出结果总量分别不超过 32 MiB；Base64 解码、单文件读取和输出亦有前置检查。无独立 ArkTS picker facade、视频或上传能力。

[完整接入指南](https://github.com/gycrosskit/media/blob/main/docs/接入指南.md) · [开发与验证](https://github.com/gycrosskit/media/blob/main/docs/开发与验证.md) · [版本](https://github.com/gycrosskit/media/releases) · [问题反馈](https://github.com/gycrosskit/media/issues)。

Apache-2.0，见 [LICENSE](LICENSE)。
