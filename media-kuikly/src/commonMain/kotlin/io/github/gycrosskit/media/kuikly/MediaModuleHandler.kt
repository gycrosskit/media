package io.github.gycrosskit.media.kuikly

import com.tencent.kuikly.core.nvi.serialization.json.JSONArray
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import io.github.gycrosskit.media.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.io.encoding.Base64

/** 每个 Renderer 独占回执；picker/saver 复用同一原生 bridge 的 owner，由宿主负责最终释放。 */
class MediaModuleHandler(
    private val picker: ImagePickerPlatform,
    private val saver: ImageSavePlatform,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val requests = mutableMapOf<String, Job>()

    fun call(method: String, params: String, callback: (String) -> Unit) {
        scope.launch {
            val invalid = if (method == "save") "invalid_content" else "failed"
            val args = try { JSONObject(params) } catch (_: Exception) {
                callback(status(invalid).toString())
                return@launch
            }
            val id = (args.opt("requestId") as? String)?.takeIf { it.isNotBlank() }
            if (method == "cancel") {
                id?.let { requests.remove(it)?.cancel() }
                return@launch
            }
            if (id == null || requests.containsKey(id) || method !in listOf("pick", "save")) {
                callback(status(invalid).toString())
                return@launch
            }
            val job = scope.launch(start = CoroutineStart.LAZY) {
                val response = try {
                    if (method == "pick") pick(args) else save(args)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: IllegalArgumentException) {
                    status(invalid)
                } catch (_: Exception) {
                    status("failed")
                } finally {
                    if (requests[id] === coroutineContext[Job]) requests.remove(id)
                }
                if (isActive) callback(response.toString())
            }
            requests[id] = job
            job.start()
        }
    }

    private suspend fun pick(args: JSONObject): JSONObject {
        val source = ImagePickerSource.entries.firstOrNull { it.name == args.opt("source") }
        require(source != null)
        val count = args.opt("maxCount") as? Number
        val dimension = args.opt("maxDimension") as? Number
        val quality = args.opt("jpegQuality") as? Number
        require(count != null && count.toDouble() == count.toInt().toDouble())
        require(dimension != null && dimension.toDouble() == dimension.toInt().toDouble() && dimension.toInt() >= 0)
        require(quality != null && quality.toDouble() == quality.toInt().toDouble())
        val request = ImagePickerRequest(source, count.toInt(), if (dimension.toInt() == 0) null
            else ImageCompression(dimension.toInt(), quality.toInt()))
        return when (val result = picker.pick(request)) {
            is ImagePickerResult.Selected -> {
                if (result.images.size !in 1..request.maxCount) return status("failed")
                if (result.images.sumOf { it.bytes.size.toLong() } > ImageContentPolicy.maxBytes) return status("too_large")
                val images = JSONArray()
                result.images.forEach { image ->
                    require(image.bytes.isNotEmpty())
                    images.put(JSONObject().apply {
                        put("data", Base64.encode(image.bytes))
                        put("fileName", image.fileName)
                        put("contentType", image.contentType)
                    })
                }
                status("selected").apply { put("images", images) }
            }
            ImagePickerResult.Cancelled -> status("cancelled")
            ImagePickerResult.PermissionDenied -> status("permission_denied")
            ImagePickerResult.PermissionBlocked -> status("permission_blocked")
            ImagePickerResult.PermissionRestricted -> status("permission_restricted")
            is ImagePickerResult.Failed -> status(if (result.message == ImageContentPolicy.limitExceededMessage) "too_large" else "failed")
        }
    }

    private suspend fun save(args: JSONObject): JSONObject {
        val encoded = args.opt("data") as? String
        val prefix = args.opt("fileNamePrefix") as? String
        require(encoded != null && prefix != null && encoded.isNotEmpty())
        // JSON 是外部输入：先限 Base64 长度和估算大小，再分配解码数组。
        require(encoded.length <= ((ImageContentPolicy.maxBytes + 2) / 3) * 4)
        val padding = if (encoded.endsWith("==")) 2 else if (encoded.endsWith("=")) 1 else 0
        require(encoded.length.toLong() * 3 / 4 - padding <= ImageContentPolicy.maxBytes)
        val bytes = Base64.decode(encoded)
        require(bytes.isNotEmpty() && bytes.size <= ImageContentPolicy.maxBytes)
        return status(when (saver.save(ImageSaveRequest(bytes, prefix))) {
            ImageSaveResult.SAVED -> "saved"
            ImageSaveResult.CANCELLED -> "cancelled"
            ImageSaveResult.PERMISSION_DENIED -> "permission_denied"
            ImageSaveResult.PERMISSION_BLOCKED -> "permission_blocked"
            ImageSaveResult.PERMISSION_RESTRICTED -> "permission_restricted"
            ImageSaveResult.INVALID_CONTENT -> "invalid_content"
            ImageSaveResult.FAILED -> "failed"
        })
    }

    private fun status(value: String) = JSONObject().apply { put("status", value) }

    /** 不释放共享 picker：新 Renderer 可能已经接管原生选择器。 */
    fun dispose() { scope.cancel() }
}
