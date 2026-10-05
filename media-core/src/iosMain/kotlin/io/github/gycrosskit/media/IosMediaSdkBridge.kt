package io.github.gycrosskit.media

import platform.Foundation.NSData

/** Swift 系统图片选择器逐张回传原始数据，Kotlin 侧统一组装为 [PickedImage]。 */
interface IosImagePickerSdkCallback {
    /** 每张图片先交付编码数据与文件名/MIME；在 onCompleted 之前顺序调用。 */
    fun onImage(data: NSData, fileName: String, contentType: String)

    /** 本次图片已全部交付；无图片时按取消处理。 */
    fun onCompleted()

    /** 用户取消本次系统 Picker，唯一终态。 */
    fun onCancelled()

    /** 本次刚拒绝权限；不可立即再次弹权限框。 */
    fun onPermissionDenied()

    /** 此前已拒绝权限，需要宿主引导设置恢复。 */
    fun onPermissionBlocked()

    /** 设备或家长策略限制，设置页无法恢复。 */
    fun onPermissionRestricted()

    /** 读取/保存失败的说明；不得携带原图内容或敏感路径。 */
    fun onFailed(message: String)
}

/** Swift 相册写入结果回调；权限状态不得简化成普通失败。 */
interface IosImageSaveSdkCallback {
    /** 原生写入已成功完成，唯一终态。 */
    fun onSaved()

    /** 本次刚拒绝权限；不可立即再次弹权限框。 */
    fun onPermissionDenied()

    /** 此前已拒绝权限，需要宿主引导设置恢复。 */
    fun onPermissionBlocked()

    /** 设备或家长策略限制，设置页无法恢复。 */
    fun onPermissionRestricted()

    /** 图片内容无法解码，不调用系统保存。 */
    fun onInvalidContent()

    /** 读取/保存失败的说明；不得携带原图内容或敏感路径。 */
    fun onFailed(message: String)
}

/** PhotosUI、UIImagePickerController 和 Photos 的宿主 Swift 接线。 */
interface IosMediaSdkBridge {
    /** 在 Main 拉起系统 Picker；source 用下列常量，尺寸为像素，质量为 1..100，尺寸 0 表示保留原图。 */
    fun pickImages(
        source: Int,
        maxCount: Int,
        maxDimension: Int,
        jpegQuality: Int,
        callback: IosImagePickerSdkCallback,
    )

    /** 幂等取消当前 Picker；只关闭该桥拥有的页面并释放回调。 */
    fun cancelImagePicker()

    /** 在 Main 写入相册；唯一终态回调也在 Main，取消等待不保证撤销原生写入。 */
    fun saveImage(data: NSData, fileNamePrefix: String, callback: IosImageSaveSdkCallback)

}

/** Swift Bridge 的相机来源码。 */
const val IOS_IMAGE_SOURCE_CAMERA = 0
/** Swift Bridge 的系统相册来源码。 */
const val IOS_IMAGE_SOURCE_GALLERY = 1
