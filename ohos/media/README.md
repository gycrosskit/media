# @gycrosskit/media

系统选图、拍照、可选 JPEG 压缩和相册保存的 Kuikly Module。当前 HAR target/compatible SDK 为 HarmonyOS API 22。

```sh
ohpm install @gycrosskit/media@0.1.0
```

```typescript
import { MediaModule } from '@gycrosskit/media';
modules.set(MediaModule.MODULE_NAME, () => new MediaModule());
```

模块名称 GycMedia；Kotlin 侧使用 media-kuikly:0.1.1（HAR 仍为 0.1.0）。宿主提供相机权限声明，页面销毁调用 Kotlin MediaModule.dispose()。JSON/Base64 原始数据单次合计上限 32 MiB，取消不承诺关闭系统 Picker。无独立 ArkTS picker facade、视频或上传能力。

[完整接入指南](https://github.com/gycrosskit/media/blob/main/docs/接入指南.md) · [开发与验证](https://github.com/gycrosskit/media/blob/main/docs/开发与验证.md) · [版本](https://github.com/gycrosskit/media/releases) · [问题反馈](https://github.com/gycrosskit/media/issues)。

Apache-2.0，见 [LICENSE](LICENSE)。
