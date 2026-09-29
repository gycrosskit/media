@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)
package io.github.gycrosskit.media
import kotlinx.cinterop.*
import platform.Foundation.*
import platform.posix.memcpy
internal fun NSData.toByteArray(): ByteArray = ByteArray(length.toInt()).also { result ->
    if (result.isNotEmpty()) result.usePinned { memcpy(it.addressOf(0), bytes, length) }
}
internal fun ByteArray.toNSData(): NSData = if (isEmpty()) NSData() else usePinned {
    NSData.create(bytes = it.addressOf(0), length = size.toULong())
}
