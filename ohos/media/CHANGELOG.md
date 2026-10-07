# 更新日志

## 0.1.6（待发布候选）

选图原始/输出总量维持 32 MiB，超限返回 too_large，配套 Maven 映射为 Failed(limitExceededMessage)；取消、权限和保存 INVALID_CONTENT 协议保持。

## 0.1.5

保存先核对 PNG/JPEG/WebP 结束边界并实际解码/释放小 PixelMap，再写原字节；取消/销毁不进入授权或文件写入。非法文件名前缀类型前置返回 invalid_content。maxCount合同为1..500。

## 0.1.3（prerelease）

- 拍照/保存的临时文件使用实例 UUID 加请求序号，避免同毫秒跨实例覆盖或清理另一请求。
- Kuikly requestId、32 MiB 与生命周期契约不变，配套 Maven/Swift 使用已验 0.1.2。

## 0.1.2（候选）

- pick/save 使用 requestId 隔离；cancel 结束自有等待并阻止后续读写，旧系统 Picker 返回前保持忙状态。
- 销毁取消全部自有请求，文件与图像对象在收尾时释放。
- Base64 decode、原图合计和压缩输出合计均在前置边界限制 32 MiB。

## 0.1.0

- 系统选图、拍照、按需 JPEG 压缩和保存相册。
