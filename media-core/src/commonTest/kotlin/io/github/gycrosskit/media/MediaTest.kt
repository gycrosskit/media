package io.github.gycrosskit.media
import kotlin.test.*
class MediaTest {
    @Test fun rejectsInvalidRequests() {
        assertFailsWith<IllegalArgumentException> { ImageCompression(0, 80) }
        assertFailsWith<IllegalArgumentException> { ImageCompression(1024, 101) }
        assertFailsWith<IllegalArgumentException> { ImagePickerRequest(ImagePickerSource.GALLERY, 0) }
        assertFailsWith<IllegalArgumentException> { ImagePickerRequest(ImagePickerSource.GALLERY, 501) }
        assertEquals(500, ImagePickerRequest(ImagePickerSource.GALLERY, 500).maxCount)
        assertFailsWith<IllegalArgumentException> { ImagePickerResult.Selected(emptyList()) }
    }
    @Test fun imageSnapshotUsesByteContentEquality() {
        assertEquals(PickedImage(byteArrayOf(1, 2), "a.png", "image/png"),
            PickedImage(byteArrayOf(1, 2), "a.png", "image/png"))
    }
}
