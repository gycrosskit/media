package io.github.gycrosskit.media

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** 有界 JPEG 预览，不修改原图；maxBytes 为 1..32 MiB，无效/超限输入或预算不足返回 null。 */
suspend fun createImageThumbnail(bytes: ByteArray, maxBytes: Int): ByteArray? {
    require(maxBytes in 1..ImageContentPolicy.maxBytes)
    currentCoroutineContext().ensureActive()
    if (bytes.isEmpty() || bytes.size > ImageContentPolicy.maxBytes) return null
    return try { encodeImageThumbnail(bytes, maxBytes) }
    catch (cancelled: CancellationException) { throw cancelled }
    catch (_: Exception) { null }
}

internal expect suspend fun encodeImageThumbnail(bytes: ByteArray, maxBytes: Int): ByteArray?

/** 三端按同一顺序降尺寸、降质量，不放大小图；平台仅负责编解码及资源释放。 */
internal object ImageThumbnailPolicy {
    val edges = listOf(320, 256, 192, 128)
    val qualities = listOf(85, 65, 45)
}
