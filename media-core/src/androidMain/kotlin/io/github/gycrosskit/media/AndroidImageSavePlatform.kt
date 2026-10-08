package io.github.gycrosskit.media

import android.Manifest
import android.content.ContentValues
import android.graphics.ImageDecoder
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import java.io.File
import java.nio.ByteBuffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Android 使用 MediaStore 写入公共图片目录；旧系统主动保存时在 Main 调用宿主 permission，数据在 IO 写入。 */
class AndroidImageSavePlatform(
    private val activity: ComponentActivity,
    private val permission: suspend (String) -> MediaPermissionState,
) : ImageSavePlatform {
    override suspend fun save(request: ImageSaveRequest): ImageSaveResult {
        if (request.bytes.isEmpty() || request.bytes.size > ImageContentPolicy.maxBytes) return ImageSaveResult.INVALID_CONTENT
        val format = withContext(Dispatchers.IO) { request.bytes.detectImageFormat() }
            ?: return ImageSaveResult.INVALID_CONTENT
        ensureLegacyWritePermission()?.let { return it }
        return withContext(Dispatchers.IO) {
            writeToMediaStore(request, format)
        }
    }

    private suspend fun ensureLegacyWritePermission(): ImageSaveResult? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return null
        return when (withContext(Dispatchers.Main.immediate) {
            permission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        }) {
            MediaPermissionState.GRANTED -> null
            MediaPermissionState.DENIED -> ImageSaveResult.PERMISSION_DENIED
            MediaPermissionState.BLOCKED -> ImageSaveResult.PERMISSION_BLOCKED
            MediaPermissionState.RESTRICTED -> ImageSaveResult.PERMISSION_RESTRICTED
        }
    }

    private fun writeToMediaStore(
        request: ImageSaveRequest,
        format: AndroidImageFormat,
    ): ImageSaveResult {
        val displayName = "${request.fileNamePrefix.safeFileName()}_${System.currentTimeMillis()}.${format.extension}"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, format.mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES)
                put(MediaStore.Images.Media.IS_PENDING, 1)
            } else {
                @Suppress("DEPRECATION")
                val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                if (!directory.exists() && !directory.mkdirs()) return ImageSaveResult.FAILED
                put(MediaStore.Images.Media.DATA, File(directory, displayName).absolutePath)
            }
        }
        val resolver = activity.contentResolver
        val uri = try {
            resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: return ImageSaveResult.FAILED
        } catch (_: SecurityException) { return ImageSaveResult.PERMISSION_DENIED }
          catch (_: Exception) { return ImageSaveResult.FAILED }
        var saved = false
        return try {
            resolver.openOutputStream(uri)?.use { output -> output.write(request.bytes) }
                ?: return ImageSaveResult.FAILED
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val published = resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
                if (published != 1) return ImageSaveResult.FAILED
            }
            saved = true
            ImageSaveResult.SAVED
        } catch (error: SecurityException) {
            android.util.Log.e("GycMedia", "保存图片到系统相册缺少权限", error)
            ImageSaveResult.PERMISSION_DENIED
        } catch (error: Exception) {
            android.util.Log.e("GycMedia", "保存图片到系统相册失败", error)
            ImageSaveResult.FAILED
        } finally {
            if (!saved) {
                runCatching { resolver.delete(uri, null, null) }
            }
        }
    }
}

private data class AndroidImageFormat(val extension: String, val mimeType: String)

private fun ByteArray.detectImageFormat(): AndroidImageFormat? {
    val format = when {
        size >= 8 && this[0] == 0x89.toByte() && decodeToString(1, 4) == "PNG" -> {
            AndroidImageFormat(extension = "png", mimeType = "image/png")
        }
        size >= 3 && this[0] == 0xFF.toByte() && this[1] == 0xD8.toByte() && this[2] == 0xFF.toByte() -> {
            AndroidImageFormat(extension = "jpg", mimeType = "image/jpeg")
        }
        size >= 12 && decodeToString(0, 4) == "RIFF" && decodeToString(8, 12) == "WEBP" -> {
            AndroidImageFormat(extension = "webp", mimeType = "image/webp")
        }
        else -> {
            // 不限制为手写的三种签名；系统支持的 GIF/BMP/HEIF 等仍保存原始编码。
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(this, 0, size, bounds)
            val mime = bounds.outMimeType ?: return null
            val extension = when (mime) {
                "image/gif" -> "gif"
                "image/bmp", "image/x-ms-bmp" -> "bmp"
                "image/heif" -> "heif"
                "image/heic" -> "heic"
                "image/tiff" -> "tiff"
                "image/avif" -> "avif"
                else -> return null
            }
            AndroidImageFormat(extension, mime)
        }
    }
    return try {
        // BitmapFactory 接受部分图像；API28+ 用系统 ImageDecoder 拒绝 partial，仍限制验证内存。
        val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(this))) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetSampleSize(calculateBitmapInSampleSize(
                    info.size.width, info.size.height, maxDimension = 256, sampleAtMostTarget = true,
                ))
                decoder.setOnPartialImageListener { false }
            }
        } else {
            // 旧 BitmapFactory 可接受截断像素，先核对标准结束边界，再采样解码。
            if (!hasCompleteLegacyContainer(format.extension)) return null
            decodeSampledBitmap(this, maxDimension = 256, sampleAtMostTarget = true) ?: return null
        }
        bitmap.recycle()
        format
    } catch (_: Exception) {
        // 解码拒绝属于内容错误，不请求权限或进入 MediaStore；原始 bytes 不重新编码。
        null
    }
}

private fun String.safeFileName(): String = replace(Regex("[^A-Za-z0-9._-]"), "_")
    .trim('_')
    .ifBlank { "image" }

// 只核对容器结束边界，不重复实现图片解码器；允许结束标记后的附加数据。
private fun ByteArray.hasCompleteLegacyContainer(extension: String): Boolean = when (extension) {
    "png" -> {
        var offset = 8
        var complete = false
        while (offset <= size - 12) {
            val length = (0..3).fold(0L) { value, index -> (value shl 8) or (this[offset + index].toLong() and 255) }
            if (length > size - offset - 12) break
            if (decodeToString(offset + 4, offset + 8) == "IEND") {
                complete = length == 0L
                break
            }
            offset += length.toInt() + 12
        }
        complete
    }
    "jpg" -> hasJpegEndMarker()
    "webp" -> {
        val declared = (0..3).fold(0L) { value, index -> value or ((this[4 + index].toLong() and 255) shl (8 * index)) }
        declared >= 4 && declared + 8 <= size
    }
    else -> true // 平台扩展格式由系统实际像素解码校验。
}

// 跳过 APP/其他带长度的 metadata 段，内嵌缩略图的 EOI 不是主图的结束。
private fun ByteArray.hasJpegEndMarker(): Boolean {
    var offset = 2
    while (offset < size - 1) {
        if ((this[offset++].toInt() and 255) != 255) continue
        while (offset < size && (this[offset].toInt() and 255) == 255) offset++
        if (offset >= size) return false
        val marker = this[offset++].toInt() and 255
        if (marker == 0xD9) return true
        if (marker == 0 || marker == 1 || marker == 0xD8 || marker in 0xD0..0xD7) continue
        if (offset > size - 2) return false
        val length = ((this[offset].toInt() and 255) shl 8) or (this[offset + 1].toInt() and 255)
        if (length < 2 || length > size - offset) return false
        offset += length
    }
    return false
}
