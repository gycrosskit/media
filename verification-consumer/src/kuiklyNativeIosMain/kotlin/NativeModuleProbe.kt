import io.github.gycrosskit.media.ImagePickerPlatform
import io.github.gycrosskit.media.ImageSavePlatform

fun iosKuiklyMediaHandler(picker: ImagePickerPlatform, saver: ImageSavePlatform) =
    io.github.gycrosskit.media.kuikly.IosMediaModuleHandler(picker, saver)
