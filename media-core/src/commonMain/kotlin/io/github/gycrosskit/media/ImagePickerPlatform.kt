package io.github.gycrosskit.media

/** 系统图片来源；平台实现负责权限、原生选择器和临时文件生命周期。 */
enum class ImagePickerSource {
    CAMERA,
    GALLERY,
}

/** 可选图片压缩策略；为空时必须保留原始字节，适用于二维码等需要原图分析的场景。 */
data class ImageCompression(
    val maxDimension: Int,
    val jpegQuality: Int,
) {
    init {
        require(maxDimension > 0) { "图片最大边长必须大于 0" }
        require(jpegQuality in 1..100) { "JPEG 质量必须在 1..100 之间" }
    }
}

/** 与 Uri、UIImage 等平台类型无关的系统选图请求。 */
data class ImagePickerRequest(
    val source: ImagePickerSource,
    val maxCount: Int = 1,
    val compression: ImageCompression? = null,
) {
    init {
        require(maxCount > 0) { "图片选择数量必须大于 0" }
    }
}

/** 已读取的图片快照，可直接交给 shared 解码、预览或上传。 */
data class PickedImage(
    val bytes: ByteArray,
    val fileName: String,
    val contentType: String,
) {
    override fun equals(other: Any?): Boolean = other is PickedImage &&
        fileName == other.fileName &&
        contentType == other.contentType &&
        bytes.contentEquals(other.bytes)

    override fun hashCode(): Int = 31 * (31 * bytes.contentHashCode() + fileName.hashCode()) +
        contentType.hashCode()
}

/**
 * 系统选图结果。
 *
 * 取消、权限拒绝和平台失败必须分开表达，避免业务把权限拒绝误当成用户取消，失去设置页恢复入口。
 */
sealed interface ImagePickerResult {
    data class Selected(val images: List<PickedImage>) : ImagePickerResult {
        init {
            require(images.isNotEmpty()) { "选图成功结果不能为空" }
        }
    }

    data object Cancelled : ImagePickerResult

    /** 用户刚刚拒绝了相机系统权限；业务只结束本次拍摄，不立即展示设置页。 */
    data object PermissionDenied : ImagePickerResult

    /** 用户再次主动拍摄时确认系统已阻止申请，可以引导到应用设置手动开启。 */
    data object PermissionBlocked : ImagePickerResult

    /** 权限受家长控制或设备策略限制，应用设置无法恢复。 */
    data object PermissionRestricted : ImagePickerResult

    data class Failed(val message: String) : ImagePickerResult
}

/**
 * 系统选图平台能力。
 *
 * 平台边界内完成 Activity Result、Uri/URL 读取和可选压缩，宿主
 * 不得重复维护原生 Launcher。
 */
interface ImagePickerPlatform {
    suspend fun pick(request: ImagePickerRequest): ImagePickerResult

    /** 平台宿主销毁时取消待处理请求并注销临时回调。 */
    fun dispose()
}
