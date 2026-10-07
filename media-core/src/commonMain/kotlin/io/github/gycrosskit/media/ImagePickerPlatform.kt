package io.github.gycrosskit.media

/** 系统图片来源；平台实现负责权限、原生选择器和临时文件生命周期。 */
enum class ImagePickerSource {
    CAMERA,
    GALLERY,
}

/**
 * 可选图片压缩策略；为空时保留原始字节，适用于二维码等原图分析。
 * @property maxDimension 最长边像素上限，必须大于 0；不会放大小图。
 * @property jpegQuality JPEG 质量百分比，范围 1..100。
 */
data class ImageCompression(
    val maxDimension: Int,
    val jpegQuality: Int,
) {
    init {
        require(maxDimension > 0) { "图片最大边长必须大于 0" }
        require(jpegQuality in 1..100) { "JPEG 质量必须在 1..100 之间" }
    }
}

/**
 * 与 Uri、UIImage 等平台类型无关的系统选图请求。
 * @property source 相机或相册；相机权限由宿主提供。
 * @property maxCount 相册选择数量上限，默认 1，范围 1..500；系统可限制更低数量，相机只产生一张。
 * @property compression 默认 null 保留原始编码；指定后输出 JPEG 并同步 MIME/扩展名。
 */
data class ImagePickerRequest(
    val source: ImagePickerSource,
    val maxCount: Int = 1,
    val compression: ImageCompression? = null,
) {
    init {
        require(maxCount in 1..500) { "图片选择数量必须在 1..500 之间" }
    }
}

/**
 * 已读取的图片快照，可交给 shared 解码、预览或上传；bytes 是可变数组，调用方不要修改已交付内容。
 * @property bytes 原始或按请求压缩的图片编码，按内容参与相等性比较。
 * @property fileName 建议文件名，包含扩展名；不是本地路径。
 * @property contentType MIME 类型，未知来源可为 application/octet-stream。
 */
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
    /** 至少一张已读取图片；顺序沿用系统选择顺序，部分无法读取的图片可能被跳过。 */
    data class Selected(val images: List<PickedImage>) : ImagePickerResult {
        init {
            require(images.isNotEmpty()) { "选图成功结果不能为空" }
        }
    }

    /** 用户结束系统选择，不是权限错误。 */
    data object Cancelled : ImagePickerResult

    /** 用户刚刚拒绝了相机系统权限；业务只结束本次拍摄，不立即展示设置页。 */
    data object PermissionDenied : ImagePickerResult

    /** 用户再次主动拍摄时确认系统已阻止申请，可以引导到应用设置手动开启。 */
    data object PermissionBlocked : ImagePickerResult

    /** 权限受家长控制或设备策略限制，应用设置无法恢复。 */
    data object PermissionRestricted : ImagePickerResult

    /** 本次选择失败的可展示说明；宿主负责最终文案和本地化。 */
    data class Failed(val message: String) : ImagePickerResult
}

/**
 * 系统选图平台能力。
 *
 * 平台边界内完成 Activity Result、Uri/URL 读取和可选压缩，宿主
 * 不得重复维护原生 Launcher。
 */
interface ImagePickerPlatform {
    /**
     * 等待一次选择；取消撤销结果交付，原生操作未结束时资源清理可能延后到系统回调。
     * Android/iOS 切到 Main 并替换旧等待；Kuikly 入口及恢复由宿主保持在页面线程，
     * OHOS 选择器仍打开时，新请求返回 [ImagePickerResult.Failed]。
     */
    suspend fun pick(request: ImagePickerRequest): ImagePickerResult

    /** 宿主销毁时幂等取消待处理请求并注销回调；终态，后续 pick 返回 Failed，重用须新建实例。 */
    fun dispose()
}
