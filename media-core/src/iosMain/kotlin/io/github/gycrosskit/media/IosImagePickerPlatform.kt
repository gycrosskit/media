package io.github.gycrosskit.media

import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.NSData
import kotlin.coroutines.resume

/** iOS 系统相机与相册适配；同一宿主只允许存在一个待完成的原生选择请求。 */
class IosImagePickerPlatform(
    private val bridge: IosMediaSdkBridge,
) : ImagePickerPlatform {
    private var activeRequest: CancellableContinuation<ImagePickerResult>? = null

    override suspend fun pick(request: ImagePickerRequest): ImagePickerResult =
        suspendCancellableCoroutine { continuation ->
            val previous = activeRequest
            activeRequest = continuation
            // Swift pickImages 负责替换原生 Picker；先交接所有权，旧协程取消时才不会关闭新请求。
            previous?.cancel()
            val images = mutableListOf<PickedImage>()
            val callback = object : IosImagePickerSdkCallback {
                override fun onImage(data: NSData, fileName: String, contentType: String) {
                    if (activeRequest !== continuation || !continuation.isActive) return
                    images += PickedImage(
                        bytes = data.toByteArray(),
                        fileName = fileName,
                        contentType = contentType,
                    )
                }

                override fun onCompleted() {
                    finish(continuation) {
                        continuation.resume(
                            images.takeIf(List<PickedImage>::isNotEmpty)
                                ?.let(ImagePickerResult::Selected)
                                ?: ImagePickerResult.Cancelled,
                        )
                    }
                }

                override fun onCancelled() {
                    finish(continuation) { continuation.resume(ImagePickerResult.Cancelled) }
                }

                override fun onPermissionDenied() {
                    finish(continuation) { continuation.resume(ImagePickerResult.PermissionDenied) }
                }

                override fun onPermissionBlocked() {
                    finish(continuation) { continuation.resume(ImagePickerResult.PermissionBlocked) }
                }

                override fun onPermissionRestricted() {
                    finish(continuation) { continuation.resume(ImagePickerResult.PermissionRestricted) }
                }

                override fun onFailed(message: String) {
                    finish(continuation) { continuation.resume(ImagePickerResult.Failed(message)) }
                }
            }
            continuation.invokeOnCancellation {
                if (activeRequest === continuation) {
                    activeRequest = null
                    bridge.cancelImagePicker()
                }
            }
            if (activeRequest !== continuation || !continuation.isActive) return@suspendCancellableCoroutine
            val compression = request.compression
            try {
                bridge.pickImages(
                    source = when (request.source) {
                        ImagePickerSource.CAMERA -> IOS_IMAGE_SOURCE_CAMERA
                        ImagePickerSource.GALLERY -> IOS_IMAGE_SOURCE_GALLERY
                    },
                    maxCount = request.maxCount,
                    maxDimension = compression?.maxDimension ?: 0,
                    jpegQuality = compression?.jpegQuality ?: 0,
                    callback = callback,
                )
            } catch (cancelled: CancellationException) {
                continuation.cancel(cancelled)
            } catch (error: Exception) {
                finish(continuation) {
                    continuation.resume(ImagePickerResult.Failed(error.message ?: "无法打开图片选择器"))
                }
            }
        }

    override fun dispose() {
        val request = activeRequest ?: return
        activeRequest = null
        try {
            bridge.cancelImagePicker()
        } finally {
            request.cancel()
        }
    }

    private inline fun finish(
        request: CancellableContinuation<ImagePickerResult>,
        complete: () -> Unit,
    ) {
        if (activeRequest !== request || !request.isActive) return
        activeRequest = null
        complete()
    }
}
