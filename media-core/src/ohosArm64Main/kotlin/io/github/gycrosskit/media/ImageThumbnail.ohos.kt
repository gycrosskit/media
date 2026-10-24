@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.gycrosskit.media

import cnames.structs.*
import kotlinx.cinterop.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import io.github.gycrosskit.media.image.*

internal actual suspend fun encodeImageThumbnail(bytes: ByteArray, maxBytes: Int): ByteArray? = withContext(Dispatchers.Default) {
    val context = currentCoroutineContext()
    context.ensureActive()
    if (bytes.isEmpty()) return@withContext null
    bytes.usePinned { input -> memScoped {
        val source = alloc<CPointerVar<OH_ImageSourceNative>>().apply { value = null }
        val info = alloc<CPointerVar<OH_ImageSource_Info>>().apply { value = null }
        val decoding = alloc<CPointerVar<OH_DecodingOptions>>().apply { value = null }
        val packing = alloc<CPointerVar<OH_PackingOptions>>().apply { value = null }
        val packer = alloc<CPointerVar<OH_ImagePackerNative>>().apply { value = null }
        try {
            if (OH_ImageSourceNative_CreateFromData(input.addressOf(0).reinterpret(), bytes.size.toULong(), source.ptr) != IMAGE_SUCCESS ||
                OH_ImageSourceInfo_Create(info.ptr) != IMAGE_SUCCESS ||
                OH_DecodingOptions_Create(decoding.ptr) != IMAGE_SUCCESS ||
                OH_PackingOptions_Create(packing.ptr) != IMAGE_SUCCESS ||
                OH_ImagePackerNative_Create(packer.ptr) != IMAGE_SUCCESS) return@memScoped null
            val width = alloc<UIntVar>()
            val height = alloc<UIntVar>()
            if (OH_ImageSourceNative_GetImageInfo(source.value, 0, info.value) != IMAGE_SUCCESS ||
                OH_ImageSourceInfo_GetWidth(info.value, width.ptr) != IMAGE_SUCCESS ||
                OH_ImageSourceInfo_GetHeight(info.value, height.ptr) != IMAGE_SUCCESS ||
                width.value == 0u || height.value == 0u) return@memScoped null
            val mime = alloc<Image_MimeType>().apply { data = "image/jpeg".cstr.ptr; size = 10uL }
            if (OH_PackingOptions_SetMimeType(packing.value, mime.ptr) != IMAGE_SUCCESS) return@memScoped null
            // 直接按预览尺寸解码，不能先解码整张相册大图再缩放。
            for (edge in ImageThumbnailPolicy.edges) {
                context.ensureActive()
                val scale = minOf(1.0, edge.toDouble() / maxOf(width.value, height.value).toDouble())
                val size = alloc<Image_Size>().apply {
                    this.width = maxOf(1, (width.value.toDouble() * scale).toInt()).toUInt()
                    this.height = maxOf(1, (height.value.toDouble() * scale).toInt()).toUInt()
                }
                if (OH_DecodingOptions_SetDesiredSize(decoding.value, size.ptr) != IMAGE_SUCCESS) continue
                val pixels = alloc<CPointerVar<OH_PixelmapNative>>().apply { value = null }
                try {
                    if (OH_ImageSourceNative_CreatePixelmap(source.value, decoding.value, pixels.ptr) != IMAGE_SUCCESS) continue
                    for (quality in ImageThumbnailPolicy.qualities) {
                        context.ensureActive()
                        if (OH_PackingOptions_SetQuality(packing.value, quality.toUInt()) != IMAGE_SUCCESS) continue
                        val output = ByteArray(maxBytes)
                        val length = alloc<ULongVar>().apply { value = maxBytes.toULong() }
                        val status = output.usePinned {
                            OH_ImagePackerNative_PackToDataFromPixelmap(packer.value, packing.value, pixels.value,
                                it.addressOf(0).reinterpret(), length.ptr)
                        }
                        if (status == IMAGE_SUCCESS && length.value in 1uL..maxBytes.toULong()) {
                            return@memScoped output.copyOf(length.value.toInt())
                        }
                    }
                } finally { pixels.value?.let { OH_PixelmapNative_Release(it) } }
            }
            null
        } finally {
            packer.value?.let { OH_ImagePackerNative_Release(it) }
            packing.value?.let { OH_PackingOptions_Release(it) }
            decoding.value?.let { OH_DecodingOptions_Release(it) }
            info.value?.let { OH_ImageSourceInfo_Release(it) }
            source.value?.let { OH_ImageSourceNative_Release(it) }
        }
    } }
}
