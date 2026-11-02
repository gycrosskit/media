package io.github.gycrosskit.media

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 33])
class AndroidFilePickerTest {
    @Test fun cancelledInFlightPickerCannotDeliverToNewRequest() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val picker = AndroidFilePicker(activity)
        val old = mutableListOf<AndroidFilePickerResult>()
        val input = AndroidFilePickerRequest(listOf("image/*"), 1, false)
        val cancel = picker.pick(input, old::add)
        val launch = shadowOf(activity).nextStartedActivityForResult
        cancel()
        val blocked = mutableListOf<AndroidFilePickerResult>()
        picker.pick(input, blocked::add)
        assertEquals(listOf(AndroidFilePickerResult.Cancelled), old)
        assertEquals(listOf(AndroidFilePickerResult.Cancelled), blocked)
        activity.activityResultRegistry.dispatchResult(launch.requestCode, Activity.RESULT_CANCELED, null)
        val fresh = mutableListOf<AndroidFilePickerResult>()
        val stop = picker.pick(input, fresh::add)
        assertNotNull(shadowOf(activity).nextStartedActivityForResult)
        stop()
        assertEquals(listOf(AndroidFilePickerResult.Cancelled), fresh)
        picker.dispose()
    }
    @Test fun mediaAndDocumentsUseExpectedPickerAndCancellationSettlesOnce() {
        for ((types, media) in listOf(listOf("image/png") to true, listOf("video/mp4") to true,
            listOf("image/*", "video/*") to true,
            listOf("image/gif,image/jpeg,image/jpg,image/png,image/bmp,image/webp,video/mov,video/mp4") to true,
            listOf("image/*") to true, listOf("video/*") to true, listOf("*") to false,
            listOf("application/pdf") to false, emptyList<String>() to false)) {
            val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
            val picker = AndroidFilePicker(activity)
            val replies = mutableListOf<AndroidFilePickerResult>()
            val cancel = picker.pick(AndroidFilePickerRequest(types, maxCount = 1, capture = false), replies::add)
            val mixed = types.joinToString(",").contains("image/") && types.joinToString(",").contains("video/")
            if (mixed && Build.VERSION.SDK_INT < 33) {
                val dialog = org.robolectric.shadows.ShadowAlertDialog.getLatestAlertDialog()
                dialog.listView.performItemClick(dialog.listView.getChildAt(0), 0, 0)
            }
            val launch = shadowOf(activity).nextStartedActivityForResult
            assertNotNull(launch)
            assertEquals(if (!media) Intent.ACTION_GET_CONTENT else if (Build.VERSION.SDK_INT >= 33) MediaStore.ACTION_PICK_IMAGES else Intent.ACTION_PICK, launch.intent.action)
            activity.activityResultRegistry.dispatchResult(launch.requestCode, Activity.RESULT_CANCELED, null)
            assertEquals(listOf(AndroidFilePickerResult.Cancelled), replies)
            cancel(); assertEquals(1, replies.size)
            picker.dispose()
        }
    }
    @Test @Config(sdk = [31]) fun legacyGalleryUsesMultipleAndMixedSelectionOffersBothTypes() {
        for (chosenVideo in listOf(false, true)) {
            val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
            val picker = AndroidFilePicker(activity)
            val replies = mutableListOf<AndroidFilePickerResult>()
            val cancel = picker.pick(AndroidFilePickerRequest(listOf("image/*", "video/*"), 3, false), replies::add)
            val dialog = org.robolectric.shadows.ShadowAlertDialog.getLatestAlertDialog()
            val index = if (chosenVideo) 1 else 0
            dialog.listView.performItemClick(dialog.listView.getChildAt(index), index, index.toLong())
            val launch = shadowOf(activity).nextStartedActivityForResult
            assertEquals(Intent.ACTION_PICK, launch.intent.action)
            assertEquals(if (chosenVideo) "video/*" else "image/*", launch.intent.type)
            assertTrue(launch.intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
            activity.activityResultRegistry.dispatchResult(launch.requestCode, Activity.RESULT_CANCELED, null)
            assertEquals(listOf(AndroidFilePickerResult.Cancelled), replies)
            cancel(); picker.dispose()
        }
    }
    @Test @Config(sdk = [31]) fun systemBackportPickerIsPreferredToGallery() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val action = androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ACTION_SYSTEM_FALLBACK_PICK_IMAGES
        val info = android.content.pm.ActivityInfo().apply {
            packageName = "fixture.system.picker"; name = "fixture.system.picker.Activity"; exported = true
            applicationInfo = android.content.pm.ApplicationInfo().apply {
                packageName = "fixture.system.picker"; flags = android.content.pm.ApplicationInfo.FLAG_SYSTEM
            }
        }
        val resolve = android.content.pm.ResolveInfo().apply { activityInfo = info }
        shadowOf(activity.packageManager).addResolveInfoForIntent(Intent(action), resolve)
        assertTrue(androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(activity))
        for (count in listOf(1, 3)) {
            val picker = AndroidFilePicker(activity)
            val replies = mutableListOf<AndroidFilePickerResult>()
            val cancel = picker.pick(AndroidFilePickerRequest(listOf("image/*", "video/*"), count, false), replies::add)
            val launch = shadowOf(activity).nextStartedActivityForResult
            assertNotNull(launch)
            assertEquals(action, launch.intent.action)
            assertEquals("fixture.system.picker", launch.intent.component?.packageName)
            activity.activityResultRegistry.dispatchResult(launch.requestCode, Activity.RESULT_CANCELED, null)
            assertEquals(listOf(AndroidFilePickerResult.Cancelled), replies)
            cancel(); picker.dispose()
        }
    }
    @Test @Config(sdk = [31]) fun missingGalleryFallsBackToFilesWithoutRequestingPermissions() {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val actions = mutableListOf<String?>()
        val registry = object : androidx.activity.result.ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: androidx.activity.result.contract.ActivityResultContract<I, O>, input: I, options: androidx.core.app.ActivityOptionsCompat?) {
                val intent = input as Intent
                actions += intent.action
                if (intent.action == Intent.ACTION_PICK) throw android.content.ActivityNotFoundException()
            }
        }
        org.robolectric.util.ReflectionHelpers.setField(activity, "activityResultRegistry", registry)
        val picker = AndroidFilePicker(activity)
        val replies = mutableListOf<AndroidFilePickerResult>()
        val cancel = picker.pick(AndroidFilePickerRequest(listOf("image/*"), 3, false), replies::add)
        assertEquals(listOf(Intent.ACTION_PICK, Intent.ACTION_GET_CONTENT), actions)
        assertTrue(replies.isEmpty())
        cancel(); assertEquals(listOf(AndroidFilePickerResult.Cancelled), replies)
        picker.dispose()
    }
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test @Config(sdk = [31])
    fun providerWithoutMimeUsesNameAndReturnsOriginalUri() = kotlinx.coroutines.runBlocking {
        kotlinx.coroutines.Dispatchers.setMain(kotlinx.coroutines.Dispatchers.Unconfined)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val file = java.io.File(activity.cacheDir, "unknown-file").apply { writeText("test data") }
        val provider = AndroidUnknownMimeProvider(file)
        provider.attachInfo(activity, android.content.pm.ProviderInfo().apply { authority = "fixture.unknown"; exported = false })
        org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("fixture.unknown", provider)
        val uri = android.net.Uri.parse("content://fixture.unknown/record.foo")
        val picker = AndroidFilePicker(activity)
        try {
            for (accept in listOf(listOf("*/*"), listOf("*"), listOf(".foo", "image/*"))) {
                val completion = kotlinx.coroutines.CompletableDeferred<AndroidFilePickerResult>()
                picker.pick(AndroidFilePickerRequest(accept, 1, false)) { completion.complete(it) }
                val launch = shadowOf(activity).nextStartedActivityForResult
                activity.activityResultRegistry.dispatchResult(launch.requestCode, Activity.RESULT_OK, Intent().setData(uri))
                val selected = kotlinx.coroutines.withTimeout(10_000) { completion.await() } as AndroidFilePickerResult.Selected
                assertEquals(uri, selected.files.single().uri)
                assertEquals("application/octet-stream", selected.files.single().mimeType)
                assertEquals(file.length(), selected.files.single().size)
                selected.release()
            }
        } finally { picker.dispose(); file.delete(); kotlinx.coroutines.Dispatchers.resetMain() }
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test @Config(sdk = [31])
    fun galleryMultipleClipDataReturnsAllFilesWithinLimit() = kotlinx.coroutines.runBlocking {
        kotlinx.coroutines.Dispatchers.setMain(kotlinx.coroutines.Dispatchers.Unconfined)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val file = java.io.File(activity.cacheDir, "gallery-file").apply { writeText("image fixture") }
        val provider = AndroidUnknownMimeProvider(file, "image/jpeg", "photo.jpg")
        provider.attachInfo(activity, android.content.pm.ProviderInfo().apply { authority = "fixture.gallery"; exported = false })
        org.robolectric.shadows.ShadowContentResolver.registerProviderInternal("fixture.gallery", provider)
        val first = android.net.Uri.parse("content://fixture.gallery/1")
        val second = android.net.Uri.parse("content://fixture.gallery/2")
        val picker = AndroidFilePicker(activity)
        try {
            val completion = kotlinx.coroutines.CompletableDeferred<AndroidFilePickerResult>()
            picker.pick(AndroidFilePickerRequest(listOf("image/*"), 3, false)) { completion.complete(it) }
            val launch = shadowOf(activity).nextStartedActivityForResult
            assertEquals(Intent.ACTION_PICK, launch.intent.action)
            assertTrue(launch.intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
            val clip = android.content.ClipData.newRawUri("", first).apply { addItem(android.content.ClipData.Item(second)) }
            activity.activityResultRegistry.dispatchResult(launch.requestCode, Activity.RESULT_OK, Intent().apply { clipData = clip })
            val selected = kotlinx.coroutines.withTimeout(10_000) { completion.await() } as AndroidFilePickerResult.Selected
            assertEquals(listOf(first, second), selected.files.map { it.uri })
            selected.release()
        } finally { picker.dispose(); file.delete(); kotlinx.coroutines.Dispatchers.resetMain() }
    }

    @Test fun commonMimeAliasesAreNormalized() {
        assertEquals("image/jpeg", canonicalFileMime("image/jpg"))
        assertEquals("video/quicktime", canonicalFileMime("video/mov"))
        assertEquals("*/*", canonicalFileMime("*"))
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test @Config(sdk = [31]) @org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
    fun capturePngAndReturnedVideoAreRealFilesAndReleaseTheirOwnOutput() = kotlinx.coroutines.runBlocking {
        kotlinx.coroutines.Dispatchers.setMain(kotlinx.coroutines.Dispatchers.Unconfined)
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val authority = requireNotNull(activity.packageManager.getPackageInfo(activity.packageName, android.content.pm.PackageManager.GET_PROVIDERS).providers).first().authority
        val picker = AndroidFilePicker(activity, authority)
        try {
            for (video in listOf(false, true)) {
                val completion = kotlinx.coroutines.CompletableDeferred<AndroidFilePickerResult>()
                picker.pick(AndroidFilePickerRequest(listOf(if (video) "video/mp4" else "image/png"), 1, true)) { completion.complete(it) }
                val launched = shadowOf(activity).nextStartedActivityForResult
                val uri = launched.intent.getParcelableExtra<android.net.Uri>(MediaStore.EXTRA_OUTPUT)!!
                val resultIntent = if (video) {
                    val file = java.io.File(activity.getExternalFilesDir(android.os.Environment.DIRECTORY_MOVIES), "returned.mp4")
                    file.writeBytes(byteArrayOf(0, 0, 0, 12, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0))
                    Intent().setData(androidx.core.content.FileProvider.getUriForFile(activity, authority, file))
                } else {
                    activity.contentResolver.openOutputStream(uri)!!.use { stream ->
                        val bitmap = android.graphics.Bitmap.createBitmap(2, 2, android.graphics.Bitmap.Config.ARGB_8888)
                        try { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, stream)) } finally { bitmap.recycle() }
                    }
                    null
                }
                activity.activityResultRegistry.dispatchResult(launched.requestCode, Activity.RESULT_OK, resultIntent)
                val selected = kotlinx.coroutines.withTimeout(10_000) { completion.await() } as AndroidFilePickerResult.Selected
                val item = selected.files.single()
                assertEquals(if (video) "video/mp4" else "image/png", item.mimeType)
                val bytes = activity.contentResolver.openInputStream(item.uri)!!.use { it.readBytes() }
                if (video) assertEquals("ftyp", String(bytes, 4, 4, Charsets.US_ASCII))
                else assertEquals(listOf(0x89, 0x50, 0x4e, 0x47), bytes.take(4).map { it.toInt() and 255 })
                selected.release()
                if (!video) assertTrue(runCatching { activity.contentResolver.openFileDescriptor(item.uri, "r") }.getOrNull() == null)
            }
        } finally { picker.dispose(); kotlinx.coroutines.Dispatchers.resetMain() }
    }

}

private class AndroidUnknownMimeProvider(private val file: java.io.File, private val mime: String? = null,
    private val name: String = "record.foo") : android.content.ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: android.net.Uri): String? = mime
    override fun query(uri: android.net.Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): android.database.Cursor =
        android.database.MatrixCursor(arrayOf(android.provider.OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf(name)) }
    override fun openFile(uri: android.net.Uri, mode: String): android.os.ParcelFileDescriptor = android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
    override fun insert(uri: android.net.Uri, values: android.content.ContentValues?): android.net.Uri? = null
    override fun delete(uri: android.net.Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: android.net.Uri, values: android.content.ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
