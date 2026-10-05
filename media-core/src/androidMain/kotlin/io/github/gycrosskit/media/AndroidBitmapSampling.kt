package io.github.gycrosskit.media

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri

/**
 * 先读取尺寸再解码接近目标大小的 Bitmap，避免选图和二维码识别先分配完整相册原图。
 *
 * [sampleAtMostTarget] 适用于二维码等分析场景，允许结果略低于目标值以换取确定的内存上限；上传压缩保持
 * `false`，先解码到不小于目标的最近采样级别，再做一次精确缩放以维持图片质量。
 * @param maxDimension 目标最长边像素；非正数不降采样。
 * @param preferredConfig 默认 null，沿用系统解码配置；无效图片返回 null。
 */
fun ContentResolver.decodeSampledBitmap(
    uri: Uri,
    maxDimension: Int,
    sampleAtMostTarget: Boolean = false,
    preferredConfig: Bitmap.Config? = null,
): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    openInputStream(uri)?.use { stream -> BitmapFactory.decodeStream(stream, null, bounds) }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    val options = sampledBitmapOptions(bounds, maxDimension, sampleAtMostTarget, preferredConfig)
    return openInputStream(uri)?.use { stream -> BitmapFactory.decodeStream(stream, null, options) }
}

/** ByteArray 版本供二维码解码使用，避免先创建完整 Bitmap 再缩放。 */
fun decodeSampledBitmap(
    bytes: ByteArray,
    maxDimension: Int,
    sampleAtMostTarget: Boolean = false,
    preferredConfig: Bitmap.Config? = null,
): Bitmap? {
    if (bytes.isEmpty()) return null
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    val options = sampledBitmapOptions(bounds, maxDimension, sampleAtMostTarget, preferredConfig)
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
}

private fun sampledBitmapOptions(
    bounds: BitmapFactory.Options,
    maxDimension: Int,
    sampleAtMostTarget: Boolean,
    preferredConfig: Bitmap.Config?,
): BitmapFactory.Options = BitmapFactory.Options().apply {
    inSampleSize = calculateBitmapInSampleSize(
        width = bounds.outWidth,
        height = bounds.outHeight,
        maxDimension = maxDimension,
        sampleAtMostTarget = sampleAtMostTarget,
    )
    if (preferredConfig != null) inPreferredConfig = preferredConfig
}

/** BitmapFactory 使用 2 的幂采样，避免不同 Android 版本对非幂值采用不同舍入行为。 */
internal fun calculateBitmapInSampleSize(
    width: Int,
    height: Int,
    maxDimension: Int,
    sampleAtMostTarget: Boolean,
): Int {
    if (width <= 0 || height <= 0 || maxDimension <= 0) return 1
    val sourceMaxDimension = maxOf(width, height)
    var sampleSize = 1
    if (sampleAtMostTarget) {
        while (sourceMaxDimension / sampleSize > maxDimension && sampleSize <= Int.MAX_VALUE / 2) {
            sampleSize *= 2
        }
    } else {
        while (sampleSize <= Int.MAX_VALUE / 2 &&
            sourceMaxDimension / (sampleSize * 2) >= maxDimension
        ) {
            sampleSize *= 2
        }
    }
    return sampleSize
}
