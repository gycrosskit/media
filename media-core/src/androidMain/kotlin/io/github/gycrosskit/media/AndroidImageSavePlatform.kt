package io.github.gycrosskit.media

import android.Manifest
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import java.io.File
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** Android 使用 MediaStore 写入公共图片目录；旧系统仅在用户主动保存时申请写入权限。 */
class AndroidImageSavePlatform(
    private val activity: ComponentActivity,
    private val permission: suspend (String) -> MediaPermissionState,
) : ImageSavePlatform {
    override suspend fun save(request: ImageSaveRequest): ImageSaveResult {
        if (request.bytes.isEmpty()) return ImageSaveResult.INVALID_CONTENT
        val format = request.bytes.detectImageFormat() ?: return ImageSaveResult.INVALID_CONTENT
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
                resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
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

private fun ByteArray.detectImageFormat(): AndroidImageFormat? = when {
    size >= 8 && this[0] == 0x89.toByte() && decodeToString(1, 4) == "PNG" -> {
        AndroidImageFormat(extension = "png", mimeType = "image/png")
    }
    size >= 3 && this[0] == 0xFF.toByte() && this[1] == 0xD8.toByte() && this[2] == 0xFF.toByte() -> {
        AndroidImageFormat(extension = "jpg", mimeType = "image/jpeg")
    }
    size >= 12 && decodeToString(0, 4) == "RIFF" && decodeToString(8, 12) == "WEBP" -> {
        AndroidImageFormat(extension = "webp", mimeType = "image/webp")
    }
    else -> null
}

private fun String.safeFileName(): String = replace(Regex("[^A-Za-z0-9._-]"), "_")
    .trim('_')
    .ifBlank { "image" }
