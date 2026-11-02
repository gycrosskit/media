package io.github.gycrosskit.media

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.ActivityNotFoundException
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.ComponentActivity
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext
import java.io.File
import java.util.UUID

/** 原始文件供调用方流式读取，调用方释放返回的句柄后临时拍摄文件失效。 */
data class AndroidPickedFile(val uri: Uri, val name: String, val mimeType: String, val size: Long)
data class AndroidFilePickerRequest(val acceptTypes: List<String>, val maxCount: Int, val capture: Boolean)
sealed interface AndroidFilePickerResult {
    data class Selected(val files: List<AndroidPickedFile>, val release: () -> Unit) : AndroidFilePickerResult
    data object Cancelled : AndroidFilePickerResult
    data object PermissionDenied : AndroidFilePickerResult
    data object PermissionBlocked : AndroidFilePickerResult
    data object PermissionRestricted : AndroidFilePickerResult
    data class Failed(val message: String) : AndroidFilePickerResult
}

/** 相机权限由调用方取得；保留原文件，PNG-only 拍摄会转换并限制最长边 4096。 */
class AndroidFilePicker(private val activity: ComponentActivity, private val authority: String = "${activity.packageName}.gycrosskit.media") {
    private var active: (() -> Unit)? = null
    private var revision = 0L
    private var disposed = false
    private val lateLaunchers = mutableSetOf<ActivityResultLauncher<Intent>>()
    fun dispose() {
        disposed = true; revision++; val previous = active; active = null; previous?.invoke()
        lateLaunchers.forEach { it.unregister() }; lateLaunchers.clear()
    }

    fun pick(request: AndroidFilePickerRequest, complete: (AndroidFilePickerResult) -> Unit): () -> Unit {
        require(request.maxCount in 1..500)
        if (disposed) { complete(AndroidFilePickerResult.Failed("媒体宿主已释放")); return {} }
        val ticket = ++revision
        val previous = active; active = null; previous?.invoke()
        if (ticket != revision || disposed) { complete(AndroidFilePickerResult.Cancelled); return {} }
        if (lateLaunchers.isNotEmpty()) { complete(AndroidFilePickerResult.Cancelled); return {} }
        var done = false
        var output: File? = null
        var outputUri: Uri? = null
        val types = request.acceptTypes.flatMap { it.split(',') }.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
            .map { if (it.startsWith('.')) MimeTypeMap.getSingleton().getMimeTypeFromExtension(it.drop(1)) ?: it else it }
            .map(::canonicalFileMime)
        val visual = types.isNotEmpty() && types.all { it.startsWith("image/") || it.startsWith("video/") }
        val hasImage = types.any { it.startsWith("image/") }
        val hasVideo = types.any { it.startsWith("video/") }
        val photoPickerAvailable = !request.capture && visual && PickVisualMedia.isPhotoPickerAvailable(activity)
        val needsPng = request.capture && hasImage && types.none { it == "*/*" || it == "image/*" || it == "image/jpeg" } && types.contains("image/png")
        lateinit var launcher: ActivityResultLauncher<Intent>
        lateinit var cancel: () -> Unit
        var processing: Job? = null
        var systemPickerInFlight = false
        var mediaChoice: AlertDialog? = null
        launcher = activity.activityResultRegistry.register("gy_file_${UUID.randomUUID()}", ActivityResultContracts.StartActivityForResult()) { result ->
            systemPickerInFlight = false
            if (done) { lateLaunchers.remove(launcher); launcher.unregister(); output?.delete(); return@register }
            if (!done) {
                launcher.unregister()
                val uris = if (result.resultCode != Activity.RESULT_OK) emptyList() else outputUri?.takeIf { (output?.length() ?: 0L) > 0L }?.let(::listOf)
                    ?: result.data?.clipData?.let { clip -> (0 until clip.itemCount).map { clip.getItemAt(it).uri } }
                    ?: listOfNotNull(result.data?.data)
                if (uris.isEmpty() || uris.size > request.maxCount) {
                    done = true; if (active === cancel) active = null; output?.delete()
                    complete(if (uris.isEmpty()) AndroidFilePickerResult.Cancelled else AndroidFilePickerResult.Failed("所选文件数量超限"))
                } else processing = activity.lifecycleScope.launch {
                    var converted: File? = null
                    var transferred = false
                    try {
                        val (files, captured) = withContext(Dispatchers.IO) {
                            var selected = uris
                            var capture = output
                            var captureUri = outputUri
                            if (needsPng && selected.size == 1) {
                                val original = requireNotNull(capture)
                                if (selected.single() == captureUri) check(original.length() in 1L..50L * 1024L * 1024L)
                                val bitmap = activity.contentResolver.decodeSampledBitmap(selected.single(), 4096) ?: error("invalid image")
                                val target = File(original.parentFile, "gy_media_${UUID.randomUUID()}.png")
                                converted = target
                                try { target.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
                                finally { bitmap.recycle() }
                                check(target.length() in 1L..50L * 1024L * 1024L)
                                coroutineContext.ensureActive()
                                original.delete(); capture = target; captureUri = FileProvider.getUriForFile(activity, authority, target)
                                selected = listOf(requireNotNull(captureUri))
                            }
                            val files = selected.map { uri ->
                                coroutineContext.ensureActive()
                                check(uri.scheme == "content" && !uri.authority.isNullOrBlank())
                                var name: String? = null
                                var size = if (uri == captureUri) capture?.length() ?: 0L else -1L
                                if (uri != captureUri) runCatching { activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                                    if (cursor.moveToFirst()) {
                                        val n = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME); if (n >= 0 && !cursor.isNull(n)) name = cursor.getString(n)
                                    }
                                } }
                                val resolvedName = name ?: uri.lastPathSegment.orEmpty()
                                val mime = canonicalFileMime((if (uri == captureUri) if (hasVideo && !hasImage) "video/mp4" else if (needsPng) "image/png" else "image/jpeg"
                                    else runCatching { activity.contentResolver.getType(uri) }.getOrNull() ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(resolvedName.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream").lowercase())
                                if (size < 0) size = runCatching { activity.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } }.getOrNull() ?: -1
                                if (size < 0) {
                                    size = 0
                                    activity.contentResolver.openInputStream(uri)?.use { stream ->
                                        val buffer = ByteArray(8192)
                                        while (true) {
                                            coroutineContext.ensureActive()
                                            val read = stream.read(buffer)
                                            if (read < 0) break
                                            size += read
                                            check(size <= 50L * 1024L * 1024L)
                                        }
                                    } ?: error("unreadable file")
                                }
                                check(size in 1L..50L * 1024L * 1024L)
                                check(types.isEmpty() || types.any { it == "*/*" || it == mime ||
                                    (it.endsWith("/*") && mime.startsWith(it.dropLast(1))) ||
                                    (it.startsWith('.') && resolvedName.lowercase().endsWith(it)) })
                                if (request.capture) {
                                    val header = activity.contentResolver.openInputStream(uri)?.use { stream -> ByteArray(12).also { stream.read(it) } } ?: error("missing capture")
                                    val valid = when (mime) {
                                        "image/jpeg" -> header[0] == 0xff.toByte() && header[1] == 0xd8.toByte() && header[2] == 0xff.toByte()
                                        "image/png" -> header.take(8) == listOf(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a).map(Int::toByte)
                                        else -> String(header, 4, 4, Charsets.US_ASCII) == "ftyp"
                                    }
                                    check(valid)
                                }
                                AndroidPickedFile(uri, resolvedName, mime, size)
                            }
                            files to capture?.takeIf { captureUri in selected }
                        }
                        if (!done) {
                            done = true; if (active === cancel) active = null
                            if (captured !== output) output?.delete()
                            complete(AndroidFilePickerResult.Selected(files) { captured?.delete() })
                            transferred = true
                        }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) {
                        if (!done) { done = true; if (active === cancel) active = null; output?.delete(); complete(AndroidFilePickerResult.Failed("无法读取所选文件")) }
                    } finally { if (!transferred) { converted?.delete(); output?.delete() } }
                }
            }
        }
        cancel = {
            if (!done) {
                done = true; processing?.cancel(); output?.delete()
                mediaChoice?.dismiss(); mediaChoice = null
                if (systemPickerInFlight) lateLaunchers.add(launcher) else launcher.unregister()
                if (active === cancel) active = null
                complete(AndroidFilePickerResult.Cancelled)
            }
        }
        active = cancel
        fun fallback(): Intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, request.maxCount > 1)
            type = if (types.size == 1 && '/' in types[0]) types[0] else "*/*"
            if (types.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, types.filter { '/' in it }.toTypedArray())
        }
        fun launch(intent: Intent, allowFallback: Boolean) {
            try {
                systemPickerInFlight = true
                launcher.launch(intent)
            } catch (error: ActivityNotFoundException) {
                systemPickerInFlight = false
                if (!allowFallback) throw error
                android.util.Log.d("GycMedia", "file-picker gallery-fallback")
                systemPickerInFlight = true
                launcher.launch(fallback())
            }
        }
        fun gallery(video: Boolean): Intent = Intent(Intent.ACTION_PICK)
            .setDataAndType(if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                if (video) "video/*" else "image/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, request.maxCount > 1)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            if (!request.capture && visual && !photoPickerAvailable && hasImage && hasVideo) {
                mediaChoice = AlertDialog.Builder(activity).setItems(arrayOf(activity.getString(R.string.media_choose_photos), activity.getString(R.string.media_choose_videos))) { _, which ->
                    mediaChoice = null
                    if (!done) {
                        try { launch(gallery(which == 1), true) }
                        catch (_: SecurityException) { if (!done) { done = true; launcher.unregister(); if (active === cancel) active = null; complete(AndroidFilePickerResult.PermissionDenied) } }
                        catch (_: Exception) { if (!done) { done = true; launcher.unregister(); if (active === cancel) active = null; complete(AndroidFilePickerResult.Failed("无法打开系统选择器")) } }
                    }
                }.setOnCancelListener { cancel() }.create().also { it.show() }
                return cancel
            }
            val intent = if (request.capture) {
                val video = hasVideo && !hasImage
                val file = File(activity.getExternalFilesDir(if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES), "gy_media_${UUID.randomUUID()}${if (video) ".mp4" else ".jpg"}")
                file.parentFile?.mkdirs(); check(file.createNewFile()); output = file; outputUri = FileProvider.getUriForFile(activity, authority, file)
                Intent(if (video) MediaStore.ACTION_VIDEO_CAPTURE else MediaStore.ACTION_IMAGE_CAPTURE).putExtra(MediaStore.EXTRA_OUTPUT, outputUri)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            } else if (photoPickerAvailable) {
                val type = if (hasImage && hasVideo) PickVisualMedia.ImageAndVideo else if (hasImage) PickVisualMedia.ImageOnly else PickVisualMedia.VideoOnly
                if (request.maxCount > 1) ActivityResultContracts.PickMultipleVisualMedia(
                    if (Build.VERSION.SDK_INT >= 33) minOf(request.maxCount, MediaStore.getPickImagesMaxLimit()) else request.maxCount,
                ).createIntent(activity, PickVisualMediaRequest(type))
                else ActivityResultContracts.PickVisualMedia().createIntent(activity, PickVisualMediaRequest(type))
            } else if (visual) {
                gallery(hasVideo)
            } else fallback()
            launch(intent, !request.capture && visual)
        } catch (error: SecurityException) {
            if (!done) { done = true; output?.delete(); launcher.unregister(); if (active === cancel) active = null; complete(AndroidFilePickerResult.PermissionDenied) }
        } catch (error: Exception) {
            if (!done) { done = true; output?.delete(); launcher.unregister(); if (active === cancel) active = null; complete(AndroidFilePickerResult.Failed("无法打开系统选择器")) }
        }
        return cancel
    }
}

internal fun canonicalFileMime(value: String): String = when (value) {
    "image/jpg" -> "image/jpeg"
    "video/mov" -> "video/quicktime"
    "*" -> "*/*"
    else -> value
}
