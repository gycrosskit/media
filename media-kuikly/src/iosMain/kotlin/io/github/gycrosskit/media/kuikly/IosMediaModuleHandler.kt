package io.github.gycrosskit.media.kuikly

import io.github.gycrosskit.media.*

/** 从宿主既有 Shared framework 导出，供原生 Kuikly receiver 调用；不创建额外 runtime。 */
class IosMediaModuleHandler(picker: ImagePickerPlatform, saver: ImageSavePlatform) {
    private val handler = MediaModuleHandler(picker, saver)
    fun call(method: String, params: String, callback: (String) -> Unit) = handler.call(method, params, callback)
    fun dispose() = handler.dispose()
}
