import io.github.gycrosskit.media.*
suspend fun pickOriginal(picker: ImagePickerPlatform) = picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY))
suspend fun save(saver: ImageSavePlatform, bytes: ByteArray) = saver.save(ImageSaveRequest(bytes, "photo"))
