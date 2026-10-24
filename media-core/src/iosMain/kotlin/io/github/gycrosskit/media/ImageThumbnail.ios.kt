@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.gycrosskit.media

import kotlinx.cinterop.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import platform.CoreFoundation.CFDataCreate
import platform.CoreFoundation.CFDictionaryCreateMutable
import platform.CoreFoundation.CFDictionarySetValue
import platform.CoreFoundation.CFNumberCreate
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.kCFBooleanTrue
import platform.CoreFoundation.kCFNumberIntType
import platform.ImageIO.CGImageSourceCreateThumbnailAtIndex
import platform.ImageIO.CGImageSourceCreateWithData
import platform.ImageIO.kCGImageSourceCreateThumbnailFromImageAlways
import platform.ImageIO.kCGImageSourceCreateThumbnailWithTransform
import platform.ImageIO.kCGImageSourceShouldCacheImmediately
import platform.ImageIO.kCGImageSourceThumbnailMaxPixelSize
import platform.UIKit.UIImage
import platform.UIKit.UIImageJPEGRepresentation

internal actual suspend fun encodeImageThumbnail(bytes: ByteArray, maxBytes: Int): ByteArray? = withContext(Dispatchers.Default) {
    currentCoroutineContext().ensureActive()
    if (bytes.isEmpty()) return@withContext null
    val data = bytes.usePinned { CFDataCreate(null, it.addressOf(0).reinterpret(), bytes.size.toLong()) }
        ?: return@withContext null
    try {
        val source = CGImageSourceCreateWithData(data, null) ?: return@withContext null
        try {
            for (size in ImageThumbnailPolicy.edges) {
                currentCoroutineContext().ensureActive()
                val thumbnail = memScoped {
                    val options = CFDictionaryCreateMutable(null, 4, null, null) ?: return@memScoped null
                    val value = alloc<IntVar>().also { it.value = size }
                    val number = CFNumberCreate(null, kCFNumberIntType, value.ptr)
                    try {
                        CFDictionarySetValue(options, kCGImageSourceCreateThumbnailFromImageAlways, kCFBooleanTrue)
                        CFDictionarySetValue(options, kCGImageSourceCreateThumbnailWithTransform, kCFBooleanTrue)
                        CFDictionarySetValue(options, kCGImageSourceShouldCacheImmediately, kCFBooleanTrue)
                        CFDictionarySetValue(options, kCGImageSourceThumbnailMaxPixelSize, number)
                        CGImageSourceCreateThumbnailAtIndex(source, 0uL, options)
                    } finally { if (number != null) CFRelease(number); CFRelease(options) }
                } ?: continue
                try {
                    val preview = UIImage.imageWithCGImage(thumbnail)
                    for (quality in ImageThumbnailPolicy.qualities) {
                        currentCoroutineContext().ensureActive()
                        val encoded = UIImageJPEGRepresentation(preview, quality / 100.0) ?: continue
                        if (encoded.length <= maxBytes.toULong()) return@withContext encoded.bytes?.reinterpret<ByteVar>()?.readBytes(encoded.length.toInt())
                    }
                } finally { CFRelease(thumbnail) }
            }
            null
        } finally { CFRelease(source) }
    } finally { CFRelease(data) }
}
