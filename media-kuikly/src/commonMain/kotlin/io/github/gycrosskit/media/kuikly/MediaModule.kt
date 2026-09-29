package io.github.gycrosskit.media.kuikly

import io.github.gycrosskit.media.ImagePickerPlatform
import io.github.gycrosskit.media.ImagePickerRequest
import io.github.gycrosskit.media.ImagePickerResult
import io.github.gycrosskit.media.ImageSavePlatform
import io.github.gycrosskit.media.ImageSaveRequest
import io.github.gycrosskit.media.ImageSaveResult
import io.github.gycrosskit.media.PickedImage
import com.tencent.kuikly.core.module.CallbackRef
import com.tencent.kuikly.core.module.Module
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** 页面拥有媒体回调；原图不经过重编码，只有显式 compression 请求才输出 JPEG。 */
@OptIn(ExperimentalEncodingApi::class)
class MediaModule : Module(), ImagePickerPlatform, ImageSavePlatform {
    private var disposed = false
    private val pending = mutableSetOf<CancellableContinuation<JSONObject?>>()

    override fun moduleName(): String = NAME

    override suspend fun pick(request: ImagePickerRequest): ImagePickerResult {
        val result = await("pick", JSONObject().apply {
            put("source", request.source.name)
            put("maxCount", request.maxCount)
            put("maxDimension", request.compression?.maxDimension ?: 0)
            put("jpegQuality", request.compression?.jpegQuality ?: 0)
        }) ?: return ImagePickerResult.Failed("媒体宿主不可用")
        return when (result.optString("status")) {
            "selected" -> {
                val images = result.optJSONArray("images")
                    ?: return ImagePickerResult.Failed("系统未返回图片")
                try {
                    val decoded = (0 until images.length()).map { index ->
                        val item = requireNotNull(images.optJSONObject(index))
                        PickedImage(Base64.decode(item.optString("data")), item.optString("fileName"),
                            item.optString("contentType"))
                    }
                    if (decoded.isEmpty()) ImagePickerResult.Failed("系统未返回图片")
                    else ImagePickerResult.Selected(decoded)
                } catch (_: IllegalArgumentException) {
                    ImagePickerResult.Failed("图片数据无效")
                }
            }
            "cancelled" -> ImagePickerResult.Cancelled
            "permission_denied" -> ImagePickerResult.PermissionDenied
            "permission_blocked" -> ImagePickerResult.PermissionBlocked
            "permission_restricted" -> ImagePickerResult.PermissionRestricted
            else -> ImagePickerResult.Failed("无法读取图片，请重试")
        }
    }

    override suspend fun save(request: ImageSaveRequest): ImageSaveResult {
        if (request.bytes.isEmpty() || request.bytes.size > MAX_BYTES) return ImageSaveResult.INVALID_CONTENT
        val result = await("save", JSONObject().apply {
            put("data", Base64.encode(request.bytes))
            put("fileNamePrefix", request.fileNamePrefix)
        })
        return when (result?.optString("status")) {
            "saved" -> ImageSaveResult.SAVED
            "invalid_content" -> ImageSaveResult.INVALID_CONTENT
            "permission_denied" -> ImageSaveResult.PERMISSION_DENIED
            "permission_blocked" -> ImageSaveResult.PERMISSION_BLOCKED
            "permission_restricted" -> ImageSaveResult.PERMISSION_RESTRICTED
            "cancelled" -> ImageSaveResult.CANCELLED
            else -> ImageSaveResult.FAILED
        }
    }

    private suspend fun await(method: String, args: JSONObject): JSONObject? {
        if (disposed) return null
        return suspendCancellableCoroutine { continuation ->
            pending.add(continuation)
            var callbackRef: CallbackRef? = null
            continuation.invokeOnCancellation {
                pending.remove(continuation)
                callbackRef?.let(::removeCallback)
            }
            callbackRef = toNative(false, method, args.toString(), { response ->
                pending.remove(continuation)
                if (continuation.isActive) continuation.resume(response)
            }, false).callbackRef
            if (!continuation.isActive) callbackRef?.let(::removeCallback)
        }
    }

    override fun dispose() {
        disposed = true
        pending.toList().forEach { it.cancel() }
        pending.clear()
    }

    companion object {
        const val NAME = "GycMedia"
        // ponytail: JSON Base64 增加临时内存；单次媒体限 32 MiB，大文件需求改用分块二进制桥。
        private const val MAX_BYTES = 32 * 1024 * 1024
    }
}
