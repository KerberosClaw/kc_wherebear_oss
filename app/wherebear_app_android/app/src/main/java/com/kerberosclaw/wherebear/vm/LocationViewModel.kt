package com.kerberosclaw.wherebear.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.android.gms.maps.model.LatLng
import com.kerberosclaw.wherebear.core.Config
import com.kerberosclaw.wherebear.core.CurrentLocation
import com.kerberosclaw.wherebear.core.Stay
import com.kerberosclaw.wherebear.core.WBTime
import com.kerberosclaw.wherebear.net.WBAuth
import com.kerberosclaw.wherebear.net.WBClient
import com.kerberosclaw.wherebear.net.asJsonArray
import com.kerberosclaw.wherebear.net.asJsonObject
import com.kerberosclaw.wherebear.net.asJsonScalarString
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

/** 對應 iOS 的 LocationVM */
class LocationViewModel : ViewModel() {

    private val _current = MutableStateFlow<CurrentLocation?>(null)
    val current: StateFlow<CurrentLocation?> = _current.asStateFlow()

    private val _stays = MutableStateFlow<List<Stay>>(emptyList())
    val stays: StateFlow<List<Stay>> = _stays.asStateFlow()

    /** 選定單日的 live 移動點（連成軌跡線；多日不畫） */
    private val _livePoints = MutableStateFlow<List<LatLng>>(emptyList())
    val livePoints: StateFlow<List<LatLng>> = _livePoints.asStateFlow()

    /** 空 ⇒ 今天；1 天 ⇒ 單日；>1 ⇒ 多日。狀態存 VM → 切 tab 再回來保留 */
    private val _selectedDays = MutableStateFlow<List<LocalDate>>(emptyList())
    val selectedDays: StateFlow<List<LocalDate>> = _selectedDays.asStateFlow()

    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    private var loadGeneration = 0   // 每次載入 +1 → geocode 回來前若又重載就放棄

    val isRange: Boolean get() = _selectedDays.value.size > 1

    fun setSelectedDays(days: List<LocalDate>) {
        _selectedDays.value = days.sorted()
        reloadStays()
    }

    fun selectRange(from: LocalDate, to: LocalDate) {
        val days = generateSequence(from) { d -> d.plusDays(1).takeIf { !it.isAfter(to) } }.toList()
        setSelectedDays(days)
    }

    fun refresh() = viewModelScope.launch { loadCurrent(); reloadStaysSuspend() }
    fun refreshCurrent() = viewModelScope.launch { loadCurrent() }
    fun reloadStays() = viewModelScope.launch { reloadStaysSuspend() }

    private suspend fun reloadStaysSuspend() {
        val days = _selectedDays.value
        _loading.value = true
        when {
            days.isEmpty() -> { loadStays(WBTime.today()); loadLivePoints(WBTime.today()) }
            days.size == 1 -> { loadStays(days[0]); loadLivePoints(days[0]) }
            else -> { loadDays(days); _livePoints.value = emptyList() }   // 多日不畫 live 線（避免糊）
        }
        _loading.value = false
    }

    // 行事曆標記用：某範圍內「有記錄」的當地日
    suspend fun recordedDayKeys(from: LocalDate, to: LocalDate): Set<String> {
        WBAuth.userId ?: return emptySet()
        return try {
            val data = WBClient.rpc(
                "my_recorded_days",
                mapOf("p_from" to from.toString(), "p_to" to to.toString(), "p_tz" to Config.TZ),
            )
            data.asJsonArray().mapNotNull { it.optString("day").takeIf { s -> s.isNotEmpty() } }.toSet()
        } catch (e: Exception) { emptySet() }
    }

    private suspend fun loadCurrent() {
        val uid = WBAuth.userId ?: return
        try {
            val data = WBClient.rest(
                "GET", "current_location",
                query = listOf("select" to "lat,lng,accuracy,captured_at", "user_id" to "eq.$uid"),
            )
            val row = data.asJsonArray().firstOrNull() ?: run { _current.value = null; return }
            val lat = row.optDouble("lat"); val lng = row.optDouble("lng")
            if (lat.isNaN() || lng.isNaN()) { _current.value = null; return }
            val captured = WBTime.parse(row.optString("captured_at")) ?: Instant.now()
            val stale = Instant.now().epochSecond - captured.epochSecond > Config.STALE_THRESHOLD_SECONDS
            val name = runCatching {
                WBClient.rpc("my_resolve_alias", mapOf("p_lat" to lat, "p_lng" to lng)).asJsonScalarString()
            }.getOrNull()
            _current.value = CurrentLocation(
                coordinate = LatLng(lat, lng),
                accuracy = row.optDouble("accuracy", 0.0),
                resolvedName = name,
                capturedAt = captured,
                isStale = stale,
            )
        } catch (e: Exception) { /* 保留上一次的值，不閃空 */ }
    }

    private suspend fun loadStays(date: LocalDate) {
        WBAuth.userId ?: return
        runCatching {
            WBClient.rpc("my_today_stays", mapOf("p_day" to date.toString(), "p_tz" to Config.TZ))
        }.onSuccess { setStays(it) }
    }

    private suspend fun loadDays(days: List<LocalDate>) {
        WBAuth.userId ?: return
        if (days.isEmpty()) { _stays.value = emptyList(); return }
        runCatching {
            WBClient.rpc("my_stays_days", mapOf("p_days" to days.map { it.toString() }, "p_tz" to Config.TZ))
        }.onSuccess { setStays(it) }
    }

    /** live 軌跡線：撈某本地日的原始 live 點（依 captured_at 升冪）→ 直接連 */
    private suspend fun loadLivePoints(day: LocalDate) {
        val uid = WBAuth.userId ?: run { _livePoints.value = emptyList(); return }
        val (start, end) = WBTime.dayBounds(day)
        try {
            val data = WBClient.rest(
                "GET", "location_history",
                query = listOf(
                    "select" to "lat,lng,captured_at",
                    "user_id" to "eq.$uid",
                    "source" to "eq.live",
                    "captured_at" to "gte.${WBTime.isoSeconds(start)}",
                    "captured_at" to "lt.${WBTime.isoSeconds(end)}",
                    "order" to "captured_at.asc",
                    "limit" to "2000",
                ),
            )
            _livePoints.value = data.asJsonArray().mapNotNull {
                val la = it.optDouble("lat"); val lo = it.optDouble("lng")
                if (la.isNaN() || lo.isNaN()) null else LatLng(la, lo)
            }
        } catch (e: Exception) { _livePoints.value = emptyList() }
    }

    private fun setStays(json: String) {
        loadGeneration += 1
        val gen = loadGeneration
        _stays.value = json.asJsonArray().map(::makeStay)
        viewModelScope.launch { geocodeUnnamed(gen) }
    }

    /**
     * 把「未命名地點」補成地名：走我們自己後端的 geocode function（Nominatim），
     * 與下游讀取層同一來源 —— 刻意不走裝置端 Geocoder（Android 的 Geocoder 是 Google 的），
     * 否則 app 看到的地名會跟 bridge / 下游不一致（契約 §3）。
     */
    private suspend fun geocodeUnnamed(gen: Int) {
        val targets = _stays.value.filter { it.name == UNNAMED && it.coordinate != null }.take(60)
        for (stay in targets) {
            if (gen != loadGeneration) return
            val c = stay.coordinate ?: continue
            val name = runCatching {
                WBClient.function("geocode", mapOf("lat" to c.latitude, "lng" to c.longitude))
                    .asJsonObject().optString("name").takeIf { it.isNotEmpty() }
            }.getOrNull()
            if (name == null) { delay(300); continue }
            if (gen != loadGeneration) return
            _stays.value = _stays.value.map { if (it.id == stay.id) it.copy(name = name) else it }
            delay(300)   // 對 Nominatim 客氣點（別連發）
        }
    }

    private fun makeStay(r: JSONObject): Stay {
        val lat = r.optDouble("centroid_lat"); val lng = r.optDouble("centroid_lng")
        return Stay(
            id = UUID.randomUUID().toString(),
            name = r.optString("name").takeIf { it.isNotEmpty() && it != "null" } ?: UNNAMED,
            from = WBTime.parse(r.optString("from_ts")) ?: Instant.now(),
            to = if (r.isNull("to_ts")) null else WBTime.parse(r.optString("to_ts")),
            dwellSeconds = r.optInt("dwell_seconds", 0),
            confidence = r.optDouble("confidence", 1.0),
            source = when (r.optString("source")) {
                "photo_import" -> Stay.Source.PHOTO_IMPORT
                "visit" -> Stay.Source.VISIT
                else -> Stay.Source.LIVE
            },
            coordinate = if (lat.isNaN() || lng.isNaN()) null else LatLng(lat, lng),
            day = r.optString("day").takeIf { it.isNotEmpty() },
        )
    }

    companion object { const val UNNAMED = "未命名地點" }
}
