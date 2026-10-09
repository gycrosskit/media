package com.tencent.kuikly.core.nvi.serialization.json

/** JSON 解析替身基于 org.json；行为断言执行生产 handler，不声明 SDK 序列化验收。 */
class JSONObject {
    private val values = mutableMapOf<String, Any>()
    constructor()
    constructor(json: String) {
        val parsed = org.json.JSONObject(json)
        parsed.keys().forEach { key -> values[key] = wrap(parsed.get(key)) }
    }
    fun put(key: String, value: Any) { values[key] = value }
    fun opt(key: String): Any? = values[key]
    fun optString(key: String) = values[key] as? String ?: ""
    fun optDouble(key: String, fallback: Double) = (values[key] as? Number)?.toDouble() ?: fallback
    fun optLong(key: String, fallback: Long) = (values[key] as? Number)?.toLong() ?: fallback
    fun optJSONArray(key: String) = values[key] as? JSONArray
    override fun toString() = org.json.JSONObject(values.mapValues { unwrap(it.value) }).toString()
}
class JSONArray(items: List<JSONObject> = emptyList()) {
    private val items = items.toMutableList()
    var objectReads = 0
    fun length() = items.size
    fun put(value: JSONObject) { items += value }
    fun optJSONObject(index: Int): JSONObject? { objectReads++; return items.getOrNull(index) }
    override fun toString() = org.json.JSONArray(items.map { org.json.JSONObject(it.toString()) }).toString()
}
private fun wrap(value: Any): Any = when (value) {
    is org.json.JSONObject -> JSONObject(value.toString())
    is org.json.JSONArray -> JSONArray((0 until value.length()).map { JSONObject(value.getJSONObject(it).toString()) })
    else -> value
}
private fun unwrap(value: Any): Any = when (value) {
    is JSONObject -> org.json.JSONObject(value.toString())
    is JSONArray -> org.json.JSONArray(value.toString())
    else -> value
}
