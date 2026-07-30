package com.kerberosclaw.wherebear.location

import android.location.Location
import com.kerberosclaw.wherebear.core.Config
import com.kerberosclaw.wherebear.net.WBAuth
import org.json.JSONObject
import java.time.Instant

/**
 * CLVisit 的 Android 替代品。
 *
 * 🔴 這是整個移植裡唯一「沒有等價 API」的地方。iOS 的 CLVisit 由系統低耗電地判斷
 * 「這個人在某處靜止了一段時間」，Android 沒有對應品（Geofencing 的 DWELL 只在
 * 你事先註冊的圈內有效 → 只能覆蓋已知地標，覆蓋不了「今天第一次去的咖啡店」）。
 * 所以自己判：用回報流本來就會產生的定位點，維持一個 anchor，
 *   - 新點落在 anchor 的 VISIT_RADIUS 內 → 還在同一個地方，延長 lastSeen
 *   - 待滿 VISIT_MIN_DWELL → 開一段 visit（送 arrived_at、departed_at 留 null）
 *   - 新點離開 VISIT_DEPART → 關掉那段（送同一個 arrived_at ＋ departed_at）
 *
 * 之所以能這樣做：後端 visits 的去重鍵是 (user_id, arrived_at)，第二次投遞
 * 帶 departed_at 走 merge-duplicates 就是更新同一列 —— 跟 iOS 端一模一樣的形狀，
 * 後端完全不必改。
 *
 * 狀態存 prefs：程序被系統回收再拉起來時，還沒關的那段停留不能憑空消失。
 */
class StationaryDetector(
    private val onVisit: (JSONObject) -> Unit,
) {
    private val prefs get() = WBAuth.prefs

    // 🔴 存 raw long bits 而非 Float：Float 只有 ~7 位有效數字，緯度存進去回來會差到公尺級，
    // 而 VISIT_RADIUS 的判斷正好吃這個精度。
    private var anchorLat: Double
        get() = java.lang.Double.longBitsToDouble(prefs.getLong(K_LAT, NAN_BITS))
        set(v) = prefs.edit().putLong(K_LAT, java.lang.Double.doubleToRawLongBits(v)).apply()
    private var anchorLng: Double
        get() = java.lang.Double.longBitsToDouble(prefs.getLong(K_LNG, NAN_BITS))
        set(v) = prefs.edit().putLong(K_LNG, java.lang.Double.doubleToRawLongBits(v)).apply()
    private var firstSeen: Long
        get() = prefs.getLong(K_FIRST, 0)
        set(v) = prefs.edit().putLong(K_FIRST, v).apply()
    private var lastSeen: Long
        get() = prefs.getLong(K_LAST, 0)
        set(v) = prefs.edit().putLong(K_LAST, v).apply()
    private var accuracy: Double
        get() = prefs.getFloat(K_ACC, 0f).toDouble()   // accuracy 是公尺誤差，Float 綽綽有餘
        set(v) = prefs.edit().putFloat(K_ACC, v.toFloat()).apply()
    private var opened: Boolean
        get() = prefs.getBoolean(K_OPENED, false)
        set(v) = prefs.edit().putBoolean(K_OPENED, v).apply()

    fun feed(loc: Location) {
        val now = loc.time.takeIf { it > 0 } ?: System.currentTimeMillis()
        if (anchorLat.isNaN() || firstSeen == 0L) { reset(loc, now); return }

        val d = distanceMeters(anchorLat, anchorLng, loc.latitude, loc.longitude)

        if (d <= Config.VISIT_RADIUS_METERS) {
            lastSeen = now
            if (accuracy <= 0 || loc.accuracy > 0) accuracy = maxOf(accuracy, loc.accuracy.toDouble())
            val dwell = (lastSeen - firstSeen) / 1000
            if (!opened && dwell >= Config.VISIT_MIN_DWELL_SECONDS) {
                opened = true
                onVisit(visitBody(departedAt = null))   // 到達：departed_at 留 null
            }
            return
        }

        if (d >= Config.VISIT_DEPART_METERS) {
            if (opened) {
                // 離開：用 lastSeen 當離開時刻（最後一次還在圈內的時間），比「現在」準
                onVisit(visitBody(departedAt = Instant.ofEpochMilli(lastSeen)))
            }
            reset(loc, now)
        }
        // VISIT_RADIUS < d < VISIT_DEPART 的灰帶：不動作。
        // 有意留白 —— GPS 在室內漂 150m 很常見，這段不該既不算「還在」也不該算「走了」。
    }

    /** 停止回報時呼叫：把還開著的那段收掉（對應 iOS 的 closeOpenVisits 精神） */
    fun closeOpen() {
        if (opened) onVisit(visitBody(departedAt = Instant.now()))
        clear()
    }

    private fun visitBody(departedAt: Instant?): JSONObject = JSONObject().apply {
        put("user_id", WBAuth.userId)
        put("lat", anchorLat)
        put("lng", anchorLng)
        put("accuracy", maxOf(accuracy, 0.0))
        put("arrived_at", com.kerberosclaw.wherebear.core.WBTime.isoSeconds(Instant.ofEpochMilli(firstSeen)))
        departedAt?.let { put("departed_at", com.kerberosclaw.wherebear.core.WBTime.isoSeconds(it)) }
    }

    private fun reset(loc: Location, now: Long) {
        anchorLat = loc.latitude; anchorLng = loc.longitude
        firstSeen = now; lastSeen = now
        accuracy = loc.accuracy.toDouble()
        opened = false
    }

    private fun clear() {
        prefs.edit().remove(K_LAT).remove(K_LNG).remove(K_FIRST)
            .remove(K_LAST).remove(K_ACC).remove(K_OPENED).apply()
    }

    companion object {
        private const val K_LAT = "wb_visit_anchor_lat"
        private const val K_LNG = "wb_visit_anchor_lng"
        private const val K_FIRST = "wb_visit_first_seen"
        private const val K_LAST = "wb_visit_last_seen"
        private const val K_ACC = "wb_visit_accuracy"
        private const val K_OPENED = "wb_visit_opened"
        private val NAN_BITS = java.lang.Double.doubleToRawLongBits(Double.NaN)

        fun distanceMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
            val r = FloatArray(1)
            Location.distanceBetween(lat1, lng1, lat2, lng2, r)
            return r[0].toDouble()
        }
    }
}
