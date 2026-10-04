package com.tencent.kuikly.core.nvi.serialization.json

/** 仅构造返回值；不模拟 JSON 解析，避免把桥序列化当成已验证。 */
class JSONObject {
    private val values = mutableMapOf<String, Any>()
    fun put(key: String, value: Any) { values[key] = value }
    fun optString(key: String) = values[key] as? String ?: ""
    fun optJSONArray(key: String) = values[key] as? JSONArray
    override fun toString() = values.toString()
}
class JSONArray(private val items: List<JSONObject>) {
    var objectReads = 0
    fun length() = items.size
    fun optJSONObject(index: Int): JSONObject? { objectReads++; return items.getOrNull(index) }
}
