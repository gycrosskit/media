package io.github.gycrosskit.media

import android.Manifest
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.app.ActivityOptionsCompat
import org.robolectric.util.ReflectionHelpers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class AndroidMediaThreadTest {
    @Test @Config(sdk = [27])
    fun legacySavePermissionUsesMainBeforeReturningToCaller() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val ownerThread = Thread.currentThread()
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        var permissionCalls = 0
        val saver = AndroidImageSavePlatform(controller.get()) { permission ->
            assertEquals(ownerThread, Thread.currentThread())
            assertEquals(Manifest.permission.WRITE_EXTERNAL_STORAGE, permission)
            permissionCalls++
            MediaPermissionState.DENIED
        }
        try {
            val result = async { saver.save(ImageSaveRequest(validImage(), "photo")) }
            assertEquals(0, permissionCalls)
            assertEquals(ImageSaveResult.PERMISSION_DENIED, result.await())
            assertEquals(1, permissionCalls)
        } finally {
            controller.destroy()
            Dispatchers.resetMain()
        }
    }

    @Test @Config(sdk = [33])
    fun modernPickerLaunchFailureCleansOwnerAndAllowsNextPick() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val registry = FailingRegistry()
        ReflectionHelpers.setField(activity, "activityResultRegistry", registry)
        val picker = AndroidImagePickerPlatform(activity, { MediaPermissionState.GRANTED })
        try {
            val failed = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY, 3)) }
            runCurrent(); main.runCurrent(); runCurrent()
            assertTrue(failed.await() is ImagePickerResult.Failed)
            registry.fail = false
            val next = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent(); main.runCurrent()
            assertTrue(!next.isCompleted)
            registry.dispatchResult(registry.code, null as android.net.Uri?)
            main.runCurrent(); runCurrent()
            assertEquals(ImagePickerResult.Cancelled, next.await())
        } finally {
            picker.dispose(); controller.destroy(); Dispatchers.resetMain()
        }
    }

    @Test fun cameraInstancesDoNotReuseOrDeleteEachOthersTemporaryFile() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val registry = FailingRegistry().apply { fail = false }
        ReflectionHelpers.setField(activity, "activityResultRegistry", registry)
        val providers = activity.packageManager.getPackageInfo(activity.packageName, android.content.pm.PackageManager.GET_PROVIDERS).providers
        val authority = requireNotNull(providers).first().authority
        val first = AndroidImagePickerPlatform(activity, { MediaPermissionState.GRANTED }, authority)
        val second = AndroidImagePickerPlatform(activity, { MediaPermissionState.GRANTED }, authority)
        try {
            val old = async { first.pick(ImagePickerRequest(ImagePickerSource.CAMERA)) }
            runCurrent(); main.runCurrent()
            val firstUri = registry.input as android.net.Uri
            val directory = requireNotNull(activity.getExternalFilesDir(android.os.Environment.DIRECTORY_PICTURES))
            val firstFile = java.io.File(directory, requireNotNull(firstUri.lastPathSegment)).apply { writeBytes(byteArrayOf(1)) }
            val next = async { second.pick(ImagePickerRequest(ImagePickerSource.CAMERA)) }
            runCurrent(); main.runCurrent()
            val secondUri = registry.input as android.net.Uri
            val secondFile = java.io.File(directory, requireNotNull(secondUri.lastPathSegment)).apply { writeBytes(byteArrayOf(2)) }
            assertTrue(firstUri != secondUri)
            first.dispose(); main.runCurrent(); runCurrent()
            assertTrue(!firstFile.exists())
            assertTrue(secondFile.exists())
            assertTrue(old.isCancelled && !next.isCompleted)
            second.dispose(); main.runCurrent(); runCurrent()
            assertTrue(!secondFile.exists())
        } finally {
            first.dispose(); second.dispose(); controller.destroy(); Dispatchers.resetMain()
        }
    }

    private class FailingRegistry : ActivityResultRegistry() {
        var fail = true
        var code = 0
        var input: Any? = null
        override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
            code = requestCode
            this.input = input
            if (fail) throw android.content.ActivityNotFoundException("Picker missing")
        }
    }

    @Test @Config(sdk = [27, 28])
    fun corruptHeadersDoNotRequestPermissionOrWrite() = runTest {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        var permissionCalls = 0
        val saver = AndroidImageSavePlatform(controller.get()) { permissionCalls++; MediaPermissionState.GRANTED }
        try {
            for (bytes in listOf(byteArrayOf(-1, -40, -1), byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10))) {
                assertEquals(ImageSaveResult.INVALID_CONTENT, saver.save(ImageSaveRequest(bytes, "bad")))
            }
            assertEquals(0, permissionCalls)
        } finally { controller.destroy() }
    }

    @Test @Config(sdk = [27, 28]) @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun pngWithReadableDimensionsButMissingPixelsIsInvalid() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        var permissionCalls = 0
        val saver = AndroidImageSavePlatform(controller.get()) { permissionCalls++; MediaPermissionState.DENIED }
        // 保留完整 IHDR 与 IDAT 头，让标准解码器读出尺寸；截去压缩像素数据和 IEND。
        val encoded = validImage()
        val idat = (8 until encoded.size - 4).first { encoded.decodeToString(it, it + 4) == "IDAT" }
        val truncated = encoded.copyOf(idat + 4)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(truncated, 0, truncated.size, bounds)
        assertEquals(2, bounds.outWidth)
        assertEquals(2, bounds.outHeight)
        try {
            assertEquals(ImageSaveResult.INVALID_CONTENT, saver.save(ImageSaveRequest(truncated, "truncated")))
            assertEquals(0, permissionCalls)
            // 完整图片与合法尾随数据均仍能进入权限阶段，校验不会误拒正常内容。
            assertEquals(ImageSaveResult.PERMISSION_DENIED, saver.save(ImageSaveRequest(encoded, "valid")))
            assertEquals(ImageSaveResult.PERMISSION_DENIED, saver.save(ImageSaveRequest(encoded + byteArrayOf(0, 32), "tail")))
            assertEquals(2, permissionCalls)
            val jpeg = validImage(Bitmap.CompressFormat.JPEG)
            val embeddedEnd = jpeg.copyOfRange(0, 2) + byteArrayOf(-1, -31, 0, 4, -1, -39) + jpeg.copyOfRange(2, jpeg.size - 2)
            assertEquals(ImageSaveResult.INVALID_CONTENT, saver.save(ImageSaveRequest(embeddedEnd, "metadata-eoi")))
            assertEquals(ImageSaveResult.PERMISSION_DENIED, saver.save(ImageSaveRequest(jpeg + byteArrayOf(0, 32), "jpeg-tail")))
            assertEquals(3, permissionCalls)
        } finally { controller.destroy(); Dispatchers.resetMain() }
    }

    private fun validImage(format: Bitmap.CompressFormat = Bitmap.CompressFormat.PNG): ByteArray = ByteArrayOutputStream().use { output ->
        Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888).apply {
            compress(format, 100, output)
            recycle()
        }
        output.toByteArray()
    }

    @Test fun disposeAfterNativeCompletionCancelsQueuedConsumerDelivery() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val picker = AndroidImagePickerPlatform(activity, { MediaPermissionState.GRANTED })
        try {
            val result = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            main.runCurrent()
            val code = shadowOf(activity).nextStartedActivityForResult.requestCode
            assertTrue(activity.activityResultRegistry.dispatchResult(code, Activity.RESULT_CANCELED, null))
            main.runCurrent()
            picker.dispose()
            runCurrent()
            assertFailsWith<CancellationException> { result.await() }
        } finally {
            picker.dispose()
            controller.destroy()
            Dispatchers.resetMain()
        }
    }

    @Test fun backgroundDisposeCancelsLauncherAndDoesNotPreventNextPick() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        val picker = AndroidImagePickerPlatform(activity, { MediaPermissionState.GRANTED })
        try {
            val old = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            main.runCurrent()
            val oldCode = shadowOf(activity).nextStartedActivityForResult.requestCode
            Thread { picker.dispose() }.also { it.start(); it.join() }
            shadowOf(Looper.getMainLooper()).idle()
            main.runCurrent()
            runCurrent()
            assertTrue(old.isCancelled)
            val next = async { picker.pick(ImagePickerRequest(ImagePickerSource.GALLERY)) }
            runCurrent()
            main.runCurrent()
            val nextCode = shadowOf(activity).nextStartedActivityForResult.requestCode
            // 第一条已取消的系统请求仍可迟到，不得结束第二条。
            activity.activityResultRegistry.dispatchResult(oldCode, Activity.RESULT_CANCELED, null)
            main.runCurrent()
            runCurrent()
            assertTrue(!next.isCompleted)
            activity.activityResultRegistry.dispatchResult(nextCode, Activity.RESULT_CANCELED, null)
            main.runCurrent()
            runCurrent()
            assertEquals(ImagePickerResult.Cancelled, next.await())
        } finally {
            picker.dispose()
            controller.destroy()
            Dispatchers.resetMain()
        }
    }
}
