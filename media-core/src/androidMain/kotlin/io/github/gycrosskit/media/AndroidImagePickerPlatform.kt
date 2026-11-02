package io.github.gycrosskit.media

import android.Manifest
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/**
 * Android 系统选图统一实现。
 *
 * 原始文件选择交给 filePicker；本层只读取、处理图片并释放本次文件结果。
 * @param permission 宿主权限能力，在 Main 调用；业务负责申请时机与提示。
 * @param fileProviderAuthority 默认 packageName.gycrosskit.media，须与宿主 Manifest 配置一致。
 */
class AndroidImagePickerPlatform(
    private val activity: ComponentActivity,
    private val permission: suspend (String) -> MediaPermissionState,
    private val fileProviderAuthority: String = "${activity.packageName}.gycrosskit.media",
) : ImagePickerPlatform {
    private var activeRequest: (() -> Unit)? = null
    private var sequence = 0L
    private val disposed = AtomicBoolean()

    override suspend fun pick(request: ImagePickerRequest): ImagePickerResult {
        if (disposed.get()) return ImagePickerResult.Failed("媒体宿主已释放")
        val result = withContext(Dispatchers.Main.immediate) {
            if (disposed.get()) throw CancellationException("图片选择宿主已释放")
            val ticket = ++sequence
            activeRequest?.invoke()
            if (request.source == ImagePickerSource.CAMERA) {
                when (permission(Manifest.permission.CAMERA)) {
                    MediaPermissionState.GRANTED -> Unit
                    MediaPermissionState.DENIED -> return@withContext ImagePickerResult.PermissionDenied
                    MediaPermissionState.BLOCKED -> return@withContext ImagePickerResult.PermissionBlocked
                    MediaPermissionState.RESTRICTED -> return@withContext ImagePickerResult.PermissionRestricted
                }
            }
            if (ticket != sequence || disposed.get()) ImagePickerResult.Cancelled else pickAuthorized(request)
        }
        // 原生回调完成后仍可能排队恢复到 Renderer；释放必须同时撤销这段交付窗口。
        if (disposed.get()) throw CancellationException("图片选择宿主已释放")
        return result
    }

    val filePicker = AndroidFilePicker(activity, fileProviderAuthority)

    private suspend fun pickAuthorized(request: ImagePickerRequest): ImagePickerResult =
        suspendCancellableCoroutine { continuation ->
            activeRequest?.invoke()
            var cancelPicker: (() -> Unit)? = null
            var imageReadJob: Job? = null
            var releaseFiles: (() -> Unit)? = null
            lateinit var requestOwner: () -> Unit
            fun cleanup() {
                imageReadJob?.cancel(); imageReadJob = null
                cancelPicker?.invoke(); cancelPicker = null
                releaseFiles?.invoke(); releaseFiles = null
                if (activeRequest === requestOwner) activeRequest = null
            }
            fun finish(result: ImagePickerResult) {
                cleanup()
                if (continuation.isActive) continuation.resume(result)
            }
            requestOwner = { cleanup(); continuation.cancel() }
            activeRequest = requestOwner
            continuation.invokeOnCancellation { activity.runOnUiThread { cleanup() } }
            if (!continuation.isActive) return@suspendCancellableCoroutine
            cancelPicker = filePicker.pick(AndroidFilePickerRequest(
                acceptTypes = listOf("image/*"), maxCount = request.maxCount,
                capture = request.source == ImagePickerSource.CAMERA,
            )) { result ->
                when (result) {
                    AndroidFilePickerResult.Cancelled -> finish(ImagePickerResult.Cancelled)
                    AndroidFilePickerResult.PermissionDenied -> finish(ImagePickerResult.PermissionDenied)
                    AndroidFilePickerResult.PermissionBlocked -> finish(ImagePickerResult.PermissionBlocked)
                    AndroidFilePickerResult.PermissionRestricted -> finish(ImagePickerResult.PermissionRestricted)
                    is AndroidFilePickerResult.Failed -> finish(ImagePickerResult.Failed(result.message))
                    is AndroidFilePickerResult.Selected -> {
                        releaseFiles = result.release
                        imageReadJob = activity.lifecycleScope.launch {
                            val images = try {
                                withContext(Dispatchers.IO) {
                                    var remainingOriginal = ImageContentPolicy.maxBytes
                                    var remainingOutput = ImageContentPolicy.maxBytes
                                    result.files.distinctBy { it.uri.toString() }.take(request.maxCount).mapIndexedNotNull { index, file ->
                                        val original = try {
                                            activity.contentResolver.openInputStream(file.uri)?.use { it.readImageBytes(remainingOriginal) }
                                        } catch (error: Exception) {
                                            if (error is ImageSizeExceeded || error is CancellationException) throw error
                                            null
                                        } ?: return@mapIndexedNotNull null
                                        if (original.isEmpty()) return@mapIndexedNotNull null
                                        remainingOriginal -= original.size
                                        readImage(index, file.uri, request, original)?.also { image ->
                                            remainingOutput -= image.bytes.size
                                            if (remainingOutput < 0) throw ImageSizeExceeded()
                                        }
                                    }
                                }
                            } catch (_: ImageSizeExceeded) {
                                imageReadJob = null; finish(ImagePickerResult.Failed(ImageContentPolicy.limitExceededMessage)); return@launch
                            }
                            imageReadJob = null
                            finish(images.takeIf(List<PickedImage>::isNotEmpty)?.let(ImagePickerResult::Selected)
                                ?: ImagePickerResult.Failed("无法读取所选图片"))
                        }
                    }
                }
            }
        }

    override fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        activity.runOnUiThread {
            sequence++
            activeRequest?.invoke()
            activeRequest = null
            filePicker.dispose()
        }
    }

    private fun readImage(
        index: Int,
        uri: Uri,
        request: ImagePickerRequest,
        originalBytes: ByteArray,
    ): PickedImage? = runCatching {
        val compression = request.compression
        var encodedAsJpeg = false
        val bytes = if (compression == null) {
            originalBytes
        } else {
            val original = decodeSampledBitmap(
                bytes = originalBytes,
                maxDimension = compression.maxDimension,
            )
            if (original == null) {
                null
            } else {
                encodedAsJpeg = true
                val oriented = orientBitmap(original, uri)
                if (oriented !== original) original.recycle()
                val scaled = scaleBitmap(oriented, compression.maxDimension)
                if (scaled !== oriented) oriented.recycle()
                ByteArrayOutputStream().use { output ->
                    scaled.compress(Bitmap.CompressFormat.JPEG, compression.jpegQuality, output)
                    if (!scaled.isRecycled) scaled.recycle()
                    output.toByteArray()
                }
            }
        } ?: return@runCatching null
        val contentType = if (encodedAsJpeg) {
            "image/jpeg"
        } else {
            activity.contentResolver.getType(uri) ?: "application/octet-stream"
        }
        val extension = if (encodedAsJpeg) {
            "jpg"
        } else {
            contentType.substringAfter('/', "bin")
        }
        PickedImage(
            bytes = bytes,
            fileName = "picked_${index}_${uri.toString().hashCode()}.$extension",
            contentType = contentType,
        )
    }.onFailure { android.util.Log.w("GycMedia", "系统图片读取失败，uri=$uri", it) }.getOrNull()

    private fun orientBitmap(bitmap: Bitmap, uri: Uri): Bitmap {
        val orientation = runCatching {
            activity.contentResolver.openInputStream(uri)?.use { stream ->
                ExifInterface(stream).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            }
        }.onFailure { android.util.Log.w("GycMedia", "读取图片方向失败，保留原始方向", it) }.getOrNull()
        // BitmapFactory 不应用 EXIF；重新编码 JPEG 会丢掉元数据，必须先把旋转和镜像落到像素上。
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun scaleBitmap(original: Bitmap, maxDimension: Int): Bitmap {
        if (original.width <= maxDimension && original.height <= maxDimension) return original
        val ratio = minOf(
            maxDimension.toFloat() / original.width,
            maxDimension.toFloat() / original.height,
        )
        return Bitmap.createScaledBitmap(
            original,
            (original.width * ratio).toInt().coerceAtLeast(1),
            (original.height * ratio).toInt().coerceAtLeast(1),
            true,
        )
    }

}

private class ImageSizeExceeded : Exception()

/** 先限制原始编码内存，再解码/压缩；未知长度的系统流也不能绕过单次总量。 */
internal fun InputStream.readImageBytes(limit: Int): ByteArray = ByteArrayOutputStream().use { output ->
    val buffer = ByteArray(8192)
    while (true) {
        val count = read(buffer, 0, minOf(buffer.size, limit - output.size() + 1))
        if (count < 0) break
        if (count == 0) continue
        if (count > limit - output.size()) throw ImageSizeExceeded()
        output.write(buffer, 0, count)
    }
    output.toByteArray()
}
