package com.tencent.kuikly.core.module

import com.tencent.kuikly.core.nvi.serialization.json.JSONObject

class CallbackRef
class NativeResult(val callbackRef: CallbackRef)

/** 仅截获桥调用，调度和媒体结果处理均来自生产 MediaModule。 */
open class Module {
    lateinit var response: (JSONObject?) -> Unit
    val cancelled = mutableListOf<JSONObject>()
    var removedCallbacks = 0
    open fun moduleName() = ""
    fun toNative(sync: Boolean, method: String, args: String,
                 callback: (JSONObject?) -> Unit, keepAlive: Boolean): NativeResult {
        response = callback
        return NativeResult(CallbackRef())
    }
    fun asyncToNativeMethod(method: String, args: JSONObject, callback: Any?) {
        check(method == "cancel")
        cancelled += args
    }
    fun removeCallback(ref: CallbackRef) { removedCallbacks++ }
}
