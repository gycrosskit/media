package io.github.gycrosskit.media

import android.Manifest
import android.app.Activity
import android.os.Looper
import androidx.activity.ComponentActivity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class AndroidMediaThreadTest {
    @Test fun legacySavePermissionUsesMainBeforeReturningToCaller() = runTest {
        val main = MainQueueDispatcher()
        Dispatchers.setMain(main)
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        var permissionCalls = 0
        val saver = AndroidImageSavePlatform(controller.get()) { permission ->
            assertEquals(Manifest.permission.WRITE_EXTERNAL_STORAGE, permission)
            permissionCalls++
            MediaPermissionState.DENIED
        }
        try {
            val result = async { saver.save(ImageSaveRequest(byteArrayOf(-1, -40, -1), "photo")) }
            runCurrent()
            assertEquals(0, permissionCalls)
            main.runCurrent()
            runCurrent()
            assertEquals(1, permissionCalls)
            assertEquals(ImageSaveResult.PERMISSION_DENIED, result.await())
        } finally {
            controller.destroy()
            Dispatchers.resetMain()
        }
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
