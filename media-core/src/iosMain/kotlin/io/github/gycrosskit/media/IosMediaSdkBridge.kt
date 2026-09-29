package io.github.gycrosskit.media

import platform.Foundation.NSData

/** Swift 系统图片选择器逐张回传原始数据，Kotlin 侧统一组装为 [PickedImage]。 */
interface IosImagePickerSdkCallback {
    fun onImage(data: NSData, fileName: String, contentType: String)

    fun onCompleted()

    fun onCancelled()

    fun onPermissionDenied()

    fun onPermissionBlocked()

    fun onPermissionRestricted()

    fun onFailed(message: String)
}

/** Swift 相册写入结果回调；权限状态不得简化成普通失败。 */
interface IosImageSaveSdkCallback {
    fun onSaved()

    fun onPermissionDenied()

    fun onPermissionBlocked()

    fun onPermissionRestricted()

    fun onInvalidContent()

    fun onFailed(message: String)
}

/** PhotosUI、UIImagePickerController 和 Photos 的宿主 Swift 接线。 */
interface IosMediaSdkBridge {
    fun pickImages(
        source: Int,
        maxCount: Int,
        maxDimension: Int,
        jpegQuality: Int,
        callback: IosImagePickerSdkCallback,
    )

    fun cancelImagePicker()

    fun saveImage(data: NSData, fileNamePrefix: String, callback: IosImageSaveSdkCallback)


}

const val IOS_IMAGE_SOURCE_CAMERA = 0
const val IOS_IMAGE_SOURCE_GALLERY = 1
