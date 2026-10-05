package io.github.gycrosskit.media

/**
 * 保存到系统相册的图片内容。
 *
 * @property bytes 原始图片编码数据。
 * @property fileNamePrefix 不包含扩展名的文件名前缀。
 */
data class ImageSaveRequest(
    val bytes: ByteArray,
    val fileNamePrefix: String,
)

/** 系统相册写入结果；权限结果保持平台中立，由页面决定提示方式。 */
enum class ImageSaveResult {
    SAVED,
    /** 系统保存确认框被用户取消，不显示失败提示。 */
    CANCELLED,
    PERMISSION_DENIED,
    PERMISSION_BLOCKED,
    PERMISSION_RESTRICTED,
    INVALID_CONTENT,
    FAILED,
}

/** Android/iOS 写入系统相册的最小平台能力。 */
fun interface ImageSavePlatform {
    /** 等待系统保存结果；取消只结束本地等待，已开始的原生写入不保证可撤销。 */
    suspend fun save(request: ImageSaveRequest): ImageSaveResult
}
