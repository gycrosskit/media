package io.github.gycrosskit.media

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Environment
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.atomic.AtomicLong
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
 * 每次请求独立注册 Launcher，完成、取消或宿主销毁后立即注销。
 */
class AndroidImagePickerPlatform(
    private val activity: ComponentActivity,
    private val permission: suspend (String) -> MediaPermissionState,
    private val fileProviderAuthority: String = "${activity.packageName}.gycrosskit.media",
) : ImagePickerPlatform {
    private var activeRequest: ActiveImagePickerRequest? = null
    private var sequence = 0L
    private var activeGeneration = 0L
    private val generation = AtomicLong()

    override suspend fun pick(request: ImagePickerRequest): ImagePickerResult {
        val epoch = generation.get()
        val result = withContext(Dispatchers.Main.immediate) {
            if (epoch != generation.get()) throw CancellationException("图片选择宿主已释放")
            activeGeneration = epoch
            val ticket = ++sequence
            activeRequest?.cancel()
            if (request.source == ImagePickerSource.CAMERA) {
                when (permission(Manifest.permission.CAMERA)) {
                    MediaPermissionState.GRANTED -> Unit
                    MediaPermissionState.DENIED -> return@withContext ImagePickerResult.PermissionDenied
                    MediaPermissionState.BLOCKED -> return@withContext ImagePickerResult.PermissionBlocked
                    MediaPermissionState.RESTRICTED -> return@withContext ImagePickerResult.PermissionRestricted
                }
            }
            if (ticket != sequence || epoch != generation.get()) ImagePickerResult.Cancelled else pickAuthorized(request)
        }
        // 原生回调完成后仍可能排队恢复到 Renderer；释放必须同时撤销这段交付窗口。
        if (epoch != generation.get()) throw CancellationException("图片选择宿主已释放")
        return result
    }

    private suspend fun pickAuthorized(request: ImagePickerRequest): ImagePickerResult =
        suspendCancellableCoroutine { continuation ->
            activeRequest?.cancel()
            val registry = activity.activityResultRegistry
            val suffix = "${System.identityHashCode(this)}_${System.nanoTime()}"
            var cameraOutputUri: Uri? = null
            var cameraOutputFile: File? = null
            var imageReadJob: Job? = null
            val launchers = mutableListOf<ActivityResultLauncher<*>>()
            lateinit var requestOwner: ActiveImagePickerRequest

            fun cleanup() {
                imageReadJob?.cancel()
                imageReadJob = null
                launchers.forEach { it.unregister() }
                launchers.clear()
                cameraOutputUri = null
                cameraOutputFile?.delete()
                cameraOutputFile = null
                if (activeRequest === requestOwner) activeRequest = null
            }

            fun finish(result: ImagePickerResult) {
                cleanup()
                if (continuation.isActive) continuation.resume(result)
            }

            fun finishSelection(uris: List<Uri>) {
                if (!continuation.isActive) {
                    cleanup()
                    return
                }
                if (uris.isEmpty()) {
                    finish(ImagePickerResult.Cancelled)
                    return
                }
                imageReadJob = activity.lifecycleScope.launch {
                    val images = withContext(Dispatchers.IO) {
                        uris.distinctBy(Uri::toString)
                            .take(request.maxCount)
                            .mapIndexedNotNull { index, uri -> readImage(index, uri, request) }
                    }
                    imageReadJob = null
                    finish(
                        images.takeIf(List<PickedImage>::isNotEmpty)
                            ?.let(ImagePickerResult::Selected)
                            ?: ImagePickerResult.Failed("无法读取所选图片"),
                    )
                }
            }

            requestOwner = ActiveImagePickerRequest {
                cleanup()
                continuation.cancel()
            }
            activeRequest = requestOwner

            continuation.invokeOnCancellation { activity.runOnUiThread { cleanup() } }
            if (!continuation.isActive) return@suspendCancellableCoroutine

            when (request.source) {
                ImagePickerSource.CAMERA -> {
                    val cameraLauncher = registry.register(
                        "image_picker_camera_$suffix",
                        ActivityResultContracts.TakePicture(),
                    ) { success ->
                        if (success) finishSelection(listOfNotNull(cameraOutputUri))
                        else finish(ImagePickerResult.Cancelled)
                    }
                    launchers += cameraLauncher

                    fun launchCamera() {
                        runCatching {
                            val imageFile = File(
                                activity.getExternalFilesDir(Environment.DIRECTORY_PICTURES),
                                "picked_${System.currentTimeMillis()}.jpg",
                            ).apply { parentFile?.mkdirs() }
                            cameraOutputFile = imageFile
                            val uri = FileProvider.getUriForFile(
                                activity,
                                fileProviderAuthority,
                                imageFile,
                            )
                            cameraOutputUri = uri
                            cameraLauncher.launch(uri)
                        }.onFailure {
                            android.util.Log.e("GycMedia", "打开系统相机失败", it)
                            finish(ImagePickerResult.Failed("无法打开系统相机"))
                        }
                    }

                    launchCamera()
                }
                ImagePickerSource.GALLERY -> launchGallery(
                    suffix = suffix,
                    maxCount = request.maxCount,
                    launchers = launchers,
                    finishSelection = ::finishSelection,
                    finish = ::finish,
                )
            }
        }

    override fun dispose() {
        val releasedGeneration = generation.incrementAndGet()
        activity.runOnUiThread {
            // 延迟释放只取消旧代次；dispose 后合法发起的新请求拥有自己的生命周期。
            if (activeGeneration < releasedGeneration) {
                sequence++
                activeRequest?.cancel()
                activeRequest = null
            }
        }
    }

    private fun launchGallery(
        suffix: String,
        maxCount: Int,
        launchers: MutableList<ActivityResultLauncher<*>>,
        finishSelection: (List<Uri>) -> Unit,
        finish: (ImagePickerResult) -> Unit,
    ) {
        val registry = activity.activityResultRegistry
        if (PickVisualMedia.isPhotoPickerAvailable(activity)) {
            if (maxCount == 1) {
                val picker = registry.register(
                    "image_picker_photo_$suffix",
                    ActivityResultContracts.PickVisualMedia(),
                ) { uri -> finishSelection(listOfNotNull(uri)) }
                launchers += picker
                picker.launch(PickVisualMediaRequest(PickVisualMedia.ImageOnly))
            } else {
                val picker = registry.register(
                    "image_picker_photos_$suffix",
                    ActivityResultContracts.PickMultipleVisualMedia(maxCount),
                ) { finishSelection(it) }
                launchers += picker
                picker.launch(PickVisualMediaRequest(PickVisualMedia.ImageOnly))
            }
            return
        }

        val picker = registry.register(
            "image_picker_legacy_$suffix",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            if (result.resultCode != Activity.RESULT_OK) {
                finish(ImagePickerResult.Cancelled)
            } else {
                val uris = mutableListOf<Uri>()
                result.data?.clipData?.let { clip ->
                    repeat(clip.itemCount) { index -> clip.getItemAt(index).uri?.let(uris::add) }
                } ?: result.data?.data?.let(uris::add)
                finishSelection(uris)
            }
        }
        launchers += picker
        runCatching {
            picker.launch(
                Intent(Intent.ACTION_GET_CONTENT).apply {
                    type = "image/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, maxCount > 1)
                    addCategory(Intent.CATEGORY_OPENABLE)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
        }.onFailure {
            android.util.Log.e("GycMedia", "打开系统相册失败", it)
            finish(ImagePickerResult.Failed("无法打开系统相册"))
        }
    }

    private fun readImage(
        index: Int,
        uri: Uri,
        request: ImagePickerRequest,
    ): PickedImage? = runCatching {
        val compression = request.compression
        var encodedAsJpeg = false
        val bytes = if (compression == null) {
            activity.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } else {
            val original = activity.contentResolver.decodeSampledBitmap(
                uri = uri,
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

    private fun interface ActiveImagePickerRequest {
        fun cancel()
    }
}
