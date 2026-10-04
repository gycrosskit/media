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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.random.Random
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** 页面拥有媒体回调；原图不经过重编码，只有显式 compression 请求才输出 JPEG。 */
@OptIn(ExperimentalEncodingApi::class)
class MediaModule : Module(), ImagePickerPlatform, ImageSavePlatform {
    private var disposed = false
    private val pending = mutableMapOf<String, CancellableContinuation<JSONObject?>>()
    private val requestPrefix = Random.nextLong().toString()
    private var sequence = 0L

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
                    val count = images.length()
                    require(count in 1..request.maxCount)
                    val items = (0 until count).map { requireNotNull(images.optJSONObject(it)) }
                    // 原生返回也属于输入边界；在分配解码 ByteArray 前检查单张及总量。
                    var estimatedBytes = 0L
                    items.forEach { item ->
                        val data = item.optString("data")
                        require(data.isNotEmpty() && data.length <= MAX_ENCODED_LENGTH)
                        estimatedBytes += data.length.toLong() * 3 / 4 - when {
                            data.endsWith("==") -> 2
                            data.endsWith("=") -> 1
                            else -> 0
                        }
                        require(estimatedBytes <= MAX_BYTES)
                    }
                    var decodedBytes = 0L
                    val decoded = items.map { item ->
                        val bytes = Base64.decode(item.optString("data"))
                        decodedBytes += bytes.size
                        require(bytes.isNotEmpty() && decodedBytes <= MAX_BYTES)
                        PickedImage(bytes, item.optString("fileName"), item.optString("contentType"))
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
            "busy" -> ImagePickerResult.Failed("系统图片选择器尚未关闭")
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
        val requestId = "${requestPrefix}_${++sequence}"
        args.put("requestId", requestId)
        var callbackRef: CallbackRef? = null
        var completed = false
        try {
            val response = suspendCancellableCoroutine<JSONObject?> { continuation ->
                pending[requestId] = continuation
                if (!continuation.isActive) return@suspendCancellableCoroutine
                callbackRef = toNative(false, method, args.toString(), { response ->
                    completed = true
                    if (continuation.isActive) continuation.resume(response)
                }, false).callbackRef
            }
            // 回调 resume 后仍可能排队恢复；页面此时销毁不能再交付旧结果。
            if (disposed) throw CancellationException("媒体模块已销毁")
            return response
        } finally {
            pending.remove(requestId)
            if (!completed) cancelNative(requestId)
            callbackRef?.let(::removeCallback)
        }
    }

    private fun cancelNative(requestId: String) {
        asyncToNativeMethod("cancel", JSONObject().apply { put("requestId", requestId) }, null)
    }

    override fun dispose() {
        disposed = true
        pending.toList().forEach { (requestId, continuation) ->
            cancelNative(requestId)
            continuation.cancel()
        }
        pending.clear()
    }

    companion object {
        const val NAME = "GycMedia"
        // ponytail: JSON Base64 增加临时内存；单次媒体限 32 MiB，大文件需求改用分块二进制桥。
        private const val MAX_BYTES = 32 * 1024 * 1024
        private const val MAX_ENCODED_LENGTH = ((MAX_BYTES + 2) / 3) * 4
    }
}
