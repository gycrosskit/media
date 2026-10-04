package io.github.gycrosskit.media.kuikly

import com.tencent.kuikly.core.nvi.serialization.json.JSONArray
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import io.github.gycrosskit.media.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class MediaModuleLifecycleTest {
    private fun selected(images: JSONArray) = JSONObject().apply {
        put("status", "selected")
        put("images", images)
    }
    private fun image() = JSONObject().apply {
        put("data", "AQ==")
        put("fileName", "original.png")
        put("contentType", "image/png")
    }

    @Test fun `dispose after picker callback before dispatch cancels delivery`() = runTest {
        val module = MediaModule()
        val result = async { module.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
        runCurrent()
        module.response(selected(JSONArray(listOf(image()))))
        module.dispose()
        runCurrent()
        assertFailsWith<CancellationException> { result.await() }
        assertEquals(1, module.removedCallbacks)
    }

    @Test fun `dispose after save callback before dispatch cancels delivery`() = runTest {
        val module = MediaModule()
        val result = async { module.save(ImageSaveRequest(byteArrayOf(1), "photo")) }
        runCurrent()
        module.response(JSONObject().apply { put("status", "saved") })
        module.dispose()
        runCurrent()
        assertFailsWith<CancellationException> { result.await() }
        assertEquals(1, module.removedCallbacks)
    }

    @Test fun `oversized image count is rejected before accessing items`() = runTest {
        val module = MediaModule()
        val result = async { module.pick(ImagePickerRequest(ImagePickerSource.GALLERY, maxCount = 1)) }
        runCurrent()
        val images = JSONArray(listOf(image(), image()))
        module.response(selected(images))
        runCurrent()
        assertIs<ImagePickerResult.Failed>(result.await())
        assertEquals(0, images.objectReads)
    }

    @Test fun `valid image retains original bytes and metadata`() = runTest {
        val module = MediaModule()
        val result = async { module.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
        runCurrent()
        module.response(selected(JSONArray(listOf(image()))))
        runCurrent()
        val picked = assertIs<ImagePickerResult.Selected>(result.await()).images.single()
        assertContentEquals(byteArrayOf(1), picked.bytes)
        assertEquals("original.png", picked.fileName)
        assertEquals("image/png", picked.contentType)
    }
}
