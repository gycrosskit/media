package io.github.gycrosskit.media

import kotlinx.coroutines.test.runTest
import kotlin.io.encoding.Base64
import kotlin.test.*

abstract class ImageThumbnailTest {
    @Test fun pngProducesBoundedJpegWithoutChangingTheUploadBytes() = runTest {
        val bytes = Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=")
        val original = bytes.copyOf()
        val thumbnail = assertNotNull(createImageThumbnail(bytes, 4096))
        assertTrue(thumbnail.size in 1..4096)
        assertEquals(0xff.toByte(), thumbnail[0]); assertEquals(0xd8.toByte(), thumbnail[1])
        assertContentEquals(original, bytes)
        assertNull(createImageThumbnail(bytes, 8))
    }

    @Test fun emptyOrInvalidImageDoesNotProduceAPreview() = runTest {
        assertNull(createImageThumbnail(byteArrayOf(), 4096))
        assertNull(createImageThumbnail(byteArrayOf(1, 2, 3), 4096))
    }
    @Test fun invalidBudgetsAreRejectedBeforeDecoding() = runTest {
        assertFailsWith<IllegalArgumentException> { createImageThumbnail(byteArrayOf(), 0) }
        assertFailsWith<IllegalArgumentException> { createImageThumbnail(byteArrayOf(), ImageContentPolicy.maxBytes + 1) }
    }

}
