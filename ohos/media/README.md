# @gycrosskit/media

HarmonyOS 图片选择、系统拍照、可选 JPEG 压缩与保存相册的 Kuikly Module。

```typescript
import { MediaModule } from '@gycrosskit/media';
```

注册模块名 `GycMedia`，Kotlin 侧使用 `com.github.gycrosskit.media:media-kuikly:0.1.0`。系统 Picker 逐次授权；JSON/Base64 单次图片原始数据合计上限 32 MiB。宿主销毁时调用 Kotlin Module.dispose。

完整接入说明：https://github.com/gycrosskit/media
