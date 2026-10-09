import io.github.gycrosskit.media.kuikly.registerMediaModule

fun registerKuiklyMedia(exports: com.tencent.kuikly.core.render.android.IKuiklyRenderExport, picker: io.github.gycrosskit.media.ImagePickerPlatform, saver: io.github.gycrosskit.media.ImageSavePlatform) = exports.registerMediaModule(picker, saver)
