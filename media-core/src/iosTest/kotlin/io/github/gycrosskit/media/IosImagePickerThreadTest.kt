package io.github.gycrosskit.media

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import platform.Foundation.NSData
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class IosImagePickerThreadTest {
    @Test fun entryAndCallbacksUseMainQueue() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val bridge = PickerBridge()
        val picker = IosImagePickerPlatform(bridge)
        try {
            val result = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            assertTrue(bridge.callbacks.isEmpty())
            main.runCurrent()
            withContext(Dispatchers.Default) {
                bridge.callbacks.single().onImage(byteArrayOf(1).toNSData(), "photo.png", "image/png")
                bridge.callbacks.single().onCompleted()
            }
            runCurrent()
            assertTrue(!result.isCompleted)
            main.runCurrent()
            runCurrent()
            assertEquals("photo.png", assertIs<ImagePickerResult.Selected>(result.await()).images.single().fileName)
        } finally {
            picker.dispose()
            main.runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test fun queuedOldCancellationAndCallbackCannotCloseReplacement() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val bridge = PickerBridge()
        val picker = IosImagePickerPlatform(bridge)
        try {
            val old = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            main.runCurrent()
            val replacement = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            // 新入口已排在 Main；从消费队列取消旧请求，清理必须在 Main 内重新判断 owner。
            withContext(Dispatchers.Default) {
                old.cancel()
                bridge.callbacks.first().onFailed("late failure")
            }
            assertEquals(0, bridge.cancelCount)
            main.runCurrent()
            runCurrent()
            assertEquals(0, bridge.cancelCount)
            assertTrue(old.isCancelled)
            assertTrue(!replacement.isCompleted)
            bridge.callbacks.last().onCancelled()
            main.runCurrent()
            runCurrent()
            assertEquals(ImagePickerResult.Cancelled, replacement.await())
        } finally {
            picker.dispose()
            main.runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test fun disposeAfterNativeCompletionCancelsQueuedDeliveryAndAllowsNewRequest() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val bridge = PickerBridge()
        val picker = IosImagePickerPlatform(bridge)
        try {
            val result = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            main.runCurrent()
            bridge.callbacks.single().onCancelled()
            main.runCurrent()
            picker.dispose()
            runCurrent()
            assertFailsWith<CancellationException> { result.await() }
            val next = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            main.runCurrent()
            bridge.callbacks.last().onCancelled()
            main.runCurrent()
            runCurrent()
            assertEquals(ImagePickerResult.Cancelled, next.await())
        } finally {
            picker.dispose()
            main.runCurrent()
            Dispatchers.resetMain()
        }
    }

    @Test fun saveBridgeUsesMainQueue() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        var saveCalls = 0
        val bridge = object : IosMediaSdkBridge {
            override fun pickImages(source: Int, maxCount: Int, maxDimension: Int, jpegQuality: Int,
                                    callback: IosImagePickerSdkCallback) = Unit
            override fun cancelImagePicker() = Unit
            override fun saveImage(data: NSData, fileNamePrefix: String, callback: IosImageSaveSdkCallback) {
                saveCalls++
                callback.onSaved()
            }
        }
        try {
            val result = async { IosImageSavePlatform(bridge).save(ImageSaveRequest(byteArrayOf(1), "photo")) }
            runCurrent()
            assertEquals(0, saveCalls)
            main.runCurrent()
            runCurrent()
            assertEquals(1, saveCalls)
            assertEquals(ImageSaveResult.SAVED, result.await())
        } finally {
            Dispatchers.resetMain()
        }
    }

    private class PickerBridge : IosMediaSdkBridge {
        val callbacks = mutableListOf<IosImagePickerSdkCallback>()
        var cancelCount = 0
        override fun pickImages(source: Int, maxCount: Int, maxDimension: Int, jpegQuality: Int,
                                callback: IosImagePickerSdkCallback) { callbacks += callback }
        override fun cancelImagePicker() { cancelCount++ }
        override fun saveImage(data: NSData, fileNamePrefix: String, callback: IosImageSaveSdkCallback) = Unit
    }
}
