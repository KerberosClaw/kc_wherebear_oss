package com.kerberosclaw.wherebear.location

import com.kerberosclaw.wherebear.net.WBAuth
import org.json.JSONArray
import org.json.JSONObject

/**
 * 離線佇列（對應 iOS 的 outbox / visitOutbox）：斷線期間累積、回線一口氣補送。
 * 存 SharedPreferences 的 JSON 陣列字串；有上限、避免無限成長。
 */
class Outbox(private val key: String, private val cap: Int) {

    fun load(): MutableList<JSONObject> {
        val raw = WBAuth.prefs.getString(key, null) ?: return mutableListOf()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.toMutableList()
        }.getOrElse { mutableListOf() }
    }

    fun save(items: List<JSONObject>) {
        count = items.size
        if (items.isEmpty()) {
            WBAuth.prefs.edit().remove(key).apply()
            return
        }
        val arr = JSONArray()
        items.forEach { arr.put(it) }
        WBAuth.prefs.edit().putString(key, arr.toString()).apply()
    }

    fun enqueue(item: JSONObject, dedupKey: ((JSONObject) -> String)? = null) {
        val q = load()
        if (dedupKey != null) {
            val k = dedupKey(item)
            q.removeAll { dedupKey(it) == k }   // 同一 visit（到達+離開兩段）只留最新那版
        }
        q.add(item)
        while (q.size > cap) q.removeAt(0)
        save(q)
    }

    @Volatile var count: Int = 0
        private set

    fun refreshCount() { count = load().size }
}
