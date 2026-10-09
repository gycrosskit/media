package io.github.gycrosskit.media.kuikly

import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import io.github.gycrosskit.media.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Before
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class MediaModuleHandlerTest {
    @Before fun setup() { Dispatchers.setMain(StandardTestDispatcher()) }
    @After fun cleanup() { Dispatchers.resetMain() }
    private class Picker : ImagePickerPlatform {
        val waits = mutableListOf<CompletableDeferred<ImagePickerResult>>()
        var disposed = false
        override suspend fun pick(request: ImagePickerRequest): ImagePickerResult {
            val wait = CompletableDeferred<ImagePickerResult>()
            waits += wait
            return wait.await()
        }
        override fun dispose() { disposed = true }
    }
    private fun args(id: String) = "{\"requestId\":\"$id\",\"source\":\"GALLERY\",\"maxCount\":1,\"maxDimension\":0,\"jpegQuality\":0}"

    @Test fun `handler disposal suppresses late terminal without disposing shared picker owner`() = runTest {
        val picker = Picker()
        val saver = ImageSavePlatform { ImageSaveResult.SAVED }
        val old = MediaModuleHandler(picker, saver)
        val fresh = MediaModuleHandler(picker, saver)
        val replies = mutableListOf<String>()
        old.call("pick", args("id"), replies::add)
        runCurrent()
        old.dispose()
        fresh.call("pick", args("id"), replies::add)
        runCurrent()
        picker.waits[0].complete(ImagePickerResult.PermissionDenied)
        picker.waits[1].complete(ImagePickerResult.Selected(listOf(PickedImage(byteArrayOf(1), "original.png", "image/png"))))
        runCurrent()
        val response = JSONObject(replies.single())
        assertEquals("selected", response.optString("status"))
        val image = assertNotNull(response.optJSONArray("images")?.optJSONObject(0))
        assertEquals("AQ==", image.optString("data"))
        assertEquals("original.png", image.optString("fileName"))
        assertFalse(picker.disposed)
        fresh.dispose()
    }

    @Test fun `save waits for real terminal and preserves content and permission classification`() = runTest {
        val picker = Picker()
        val terminal = CompletableDeferred<ImageSaveResult>()
        var content: ImageSaveRequest? = null
        val handler = MediaModuleHandler(picker, ImageSavePlatform { content = it; terminal.await() })
        val replies = mutableListOf<String>()
        handler.call("save", "{\"requestId\":\"save\",\"data\":\"AQ==\",\"fileNamePrefix\":\"photo\"}", replies::add)
        runCurrent()
        assertTrue(replies.isEmpty())
        assertContentEquals(byteArrayOf(1), content?.bytes)
        terminal.complete(ImageSaveResult.PERMISSION_BLOCKED)
        runCurrent()
        assertEquals("permission_blocked", JSONObject(replies.single()).optString("status"))
        handler.dispose()
    }

    @Test fun `invalid base64 and selection count are rejected before native calls`() = runTest {
        val picker = Picker()
        var writes = 0
        val handler = MediaModuleHandler(picker, ImageSavePlatform { writes++; ImageSaveResult.SAVED })
        val replies = mutableListOf<String>()
        handler.call("save", "{\"requestId\":\"save\",\"data\":\"not-base64!\",\"fileNamePrefix\":\"photo\"}", replies::add)
        handler.call("pick", args("pick").replace("\"maxCount\":1", "\"maxCount\":501"), replies::add)
        runCurrent()
        assertEquals(listOf("invalid_content", "failed"), replies.map { JSONObject(it).optString("status") })
        assertEquals(0, writes)
        assertTrue(picker.waits.isEmpty())
        handler.dispose()
    }

    @Test fun `old ID cancellation cannot cancel concurrent successor`() = runTest {
        val picker = Picker()
        val handler = MediaModuleHandler(picker, ImageSavePlatform { ImageSaveResult.SAVED })
        val replies = mutableListOf<String>()
        handler.call("pick", args("old"), replies::add)
        handler.call("pick", args("next"), replies::add)
        runCurrent()
        handler.call("cancel", "{\"requestId\":\"old\"}", replies::add)
        runCurrent()
        picker.waits[0].complete(ImagePickerResult.PermissionRestricted)
        picker.waits[1].complete(ImagePickerResult.Cancelled)
        runCurrent()
        assertEquals(listOf("cancelled"), replies.map { JSONObject(it).optString("status") })
        handler.dispose()
    }
}
