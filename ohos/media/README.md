# @gycrosskit/media

2026-10-08 当前源码与三端/五入口边界见[功能与平台差异](../../docs/功能与平台差异.md)；本包只承担上文所述原生能力，以下版本和渠道记录按各自日期阅读。

本轮 HAR 候选为 `0.1.5`，尚未发布；下面精确安装命令用于发布并确认可见后，历史验收不代表本候选已验收。

系统选图、拍照、可选 JPEG 压缩和相册保存的 Kuikly Module。当前 HAR target/compatible SDK 为 HarmonyOS API 22。

```sh
ohpm install @gycrosskit/media@0.1.5
```

```typescript
import { MediaModule } from '@gycrosskit/media';
modules.set(MediaModule.MODULE_NAME, () => new MediaModule());
```

HAR 0.1.3 已提供不可变 Release 并通过 API22 独立消费，OHPM next 仍在审核，精确 Registry 安装尚不可用；历史版本保持。模块名称 GycMedia；Kotlin 侧使用已验 media-kuikly:0.1.2，桥接契约兼容。
临时文件使用实例 UUID 加请求序号，避免跨页面同毫秒碰撞；目录与本次请求清理归属保持。
宿主提供相机权限声明，页面销毁调用 Kotlin MediaModule.dispose()。pick/save 附加 requestId，cancel 只结束
匹配请求等待，阻止后续读写并在收尾时释放原生资源；系统 Picker 返回前仍保持 busy，旧 ID 不影响新请求。
所有 Base64 decode、原图读取和压缩输出均前置检查单次合计 32 MiB。无独立 ArkTS picker facade、视频或上传能力。

[完整接入指南](https://github.com/gycrosskit/media/blob/main/docs/接入指南.md) · [开发与验证](https://github.com/gycrosskit/media/blob/main/docs/开发与验证.md) · [版本](https://github.com/gycrosskit/media/releases) · [问题反馈](https://github.com/gycrosskit/media/issues)。

Apache-2.0，见 [LICENSE](LICENSE)。
