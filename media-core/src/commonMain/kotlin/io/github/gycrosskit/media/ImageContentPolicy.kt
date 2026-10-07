package io.github.gycrosskit.media

/**
 * 一次选图的原始编码与输出编码分别合计最多 32 MiB；单次保存同限额。
 * PNG/JPEG 是跨端共同格式，其他格式交给系统解码器，保留可用的平台扩展。
 * 空数据、超限和系统不支持/无法解码的保存数据返回 INVALID_CONTENT，不申请权限或写入相册。
 */
object ImageContentPolicy {
    const val maxBytes: Int = 32 * 1024 * 1024
    const val limitExceededMessage: String = "图片数据超过 32 MiB 限额"
}
