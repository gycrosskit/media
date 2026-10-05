package io.github.gycrosskit.media

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/** iOS 通过宿主 Photos Bridge 写入系统相册，shared 不直接持有 UIKit 或授权状态。 */
class IosImageSavePlatform(
    private val bridge: IosMediaSdkBridge,
) : ImageSavePlatform {
    override suspend fun save(request: ImageSaveRequest): ImageSaveResult {
        if (request.bytes.isEmpty()) return ImageSaveResult.INVALID_CONTENT
        return withContext(Dispatchers.Main.immediate) {
            suspendCancellableCoroutine { continuation ->
                if (!continuation.isActive) return@suspendCancellableCoroutine
                val callback = object : IosImageSaveSdkCallback {
                    override fun onSaved() = finish(ImageSaveResult.SAVED)

                    override fun onPermissionDenied() = finish(ImageSaveResult.PERMISSION_DENIED)

                    override fun onPermissionBlocked() = finish(ImageSaveResult.PERMISSION_BLOCKED)

                    override fun onPermissionRestricted() = finish(ImageSaveResult.PERMISSION_RESTRICTED)

                    override fun onInvalidContent() = finish(ImageSaveResult.INVALID_CONTENT)

                    override fun onFailed(message: String) = finish(ImageSaveResult.FAILED)

                    private fun finish(result: ImageSaveResult) {
                        if (continuation.isActive) continuation.resume(result)
                    }
                }
                runCatching {
                    bridge.saveImage(
                        data = request.bytes.toNSData(),
                        fileNamePrefix = request.fileNamePrefix,
                        callback = callback,
                    )
                }.onFailure {
                    if (continuation.isActive) continuation.resume(ImageSaveResult.FAILED)
                }
            }
        }
    }
}
