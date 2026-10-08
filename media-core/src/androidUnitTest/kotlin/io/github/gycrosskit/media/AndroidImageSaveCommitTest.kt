package io.github.gycrosskit.media

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.activity.ComponentActivity
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowContentResolver
import kotlin.test.assertEquals

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AndroidImageSaveCommitTest {
    @Test fun publishMustUpdateOneRowAndOtherwiseCleansItsPendingInsert() = runBlocking {
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val file = File.createTempFile("media-commit", ".png", controller.get().cacheDir)
        val provider = object : ContentProvider() {
            var updatedRows = 0
            var deletes = 0
            override fun onCreate() = true
            override fun insert(uri: Uri, values: ContentValues?) = Uri.parse("content://media/external/images/media/1")
            override fun openFile(uri: Uri, mode: String) = ParcelFileDescriptor.open(file,
                ParcelFileDescriptor.MODE_READ_WRITE or ParcelFileDescriptor.MODE_TRUNCATE)
            override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = updatedRows
            override fun delete(uri: Uri, selection: String?, args: Array<out String>?): Int { deletes++; return 1 }
            override fun getType(uri: Uri) = "image/png"
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, order: String?): Cursor? = null
        }
        provider.attachInfo(controller.get(), android.content.pm.ProviderInfo().apply {
            authority = "media"; exported = true
        })
        ShadowContentResolver.registerProviderInternal("media", provider)
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val encoded = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        try {
            val saver = AndroidImageSavePlatform(controller.get()) { error("API33 needs no legacy permission") }
            val request = ImageSaveRequest(encoded, "photo")
            assertEquals(ImageSaveResult.FAILED, saver.save(request))
            assertEquals(1, provider.deletes)
            provider.updatedRows = 1
            assertEquals(ImageSaveResult.SAVED, saver.save(request))
            assertEquals(1, provider.deletes, "successful publish must retain its row")
        } finally { controller.destroy(); file.delete() }
    }
}
