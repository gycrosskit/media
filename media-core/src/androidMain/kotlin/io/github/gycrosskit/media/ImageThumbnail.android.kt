package io.github.gycrosskit.media

import android.graphics.Bitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

internal actual suspend fun encodeImageThumbnail(bytes: ByteArray, maxBytes: Int): ByteArray? = withContext(Dispatchers.Default) {
    currentCoroutineContext().ensureActive()
    if (bytes.isEmpty()) return@withContext null
    val source = decodeSampledBitmap(bytes, 640, sampleAtMostTarget = true, preferredConfig = Bitmap.Config.RGB_565)
        ?: return@withContext null
    try {
        for (size in ImageThumbnailPolicy.edges) {
            currentCoroutineContext().ensureActive()
            val scale = minOf(1.0, size.toDouble() / maxOf(source.width, source.height))
            val thumbnail = Bitmap.createScaledBitmap(source, maxOf(1, (source.width * scale).toInt()), maxOf(1, (source.height * scale).toInt()), true)
            try {
                for (quality in ImageThumbnailPolicy.qualities) {
                    currentCoroutineContext().ensureActive()
                    val output = ByteArrayOutputStream()
                    if (thumbnail.compress(Bitmap.CompressFormat.JPEG, quality, output)) {
                        val bytes = output.toByteArray()
                        if (bytes.size <= maxBytes) return@withContext bytes
                    }
                }
            } finally { if (thumbnail !== source) thumbnail.recycle() }
        }
        null
    } finally { source.recycle() }
}
