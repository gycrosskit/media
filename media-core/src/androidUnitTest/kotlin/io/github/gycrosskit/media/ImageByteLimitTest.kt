package io.github.gycrosskit.media

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ImageByteLimitTest {
    @Test fun unknownLengthStreamStopsAfterOneByteBeyondBudget() {
        var readBytes = 0
        val endless = object : InputStream() {
            override fun read(): Int { readBytes++; return 1 }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                readBytes += length
                buffer.fill(1, offset, offset + length)
                return length
            }
        }
        assertFailsWith<Exception> { endless.readImageBytes(10) }
        assertEquals(11, readBytes, "unbounded provider streams cannot allocate or read past the limit probe")
        assertContentEquals(byteArrayOf(1, 2), ByteArrayInputStream(byteArrayOf(1, 2)).readImageBytes(2))
        assertContentEquals(ByteArray(0), ByteArrayInputStream(ByteArray(0)).readImageBytes(0))
    }
}
