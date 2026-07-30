package com.kerberosclaw.wherebear.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.google.android.gms.maps.model.LatLng
import com.kerberosclaw.wherebear.core.Landmark
import com.kerberosclaw.wherebear.location.StationaryDetector
import com.kerberosclaw.wherebear.net.WBAuth
import com.kerberosclaw.wherebear.net.WBClient
import com.kerberosclaw.wherebear.net.asJsonArray
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.UUID

/** 對應 iOS 的 LandmarkManager。CRUD 樂觀更新 → 失敗還原 + lastError（不靜默吞錯） */
class LandmarkViewModel : ViewModel() {

    private val _landmarks = MutableStateFlow<List<Landmark>>(emptyList())
    val landmarks: StateFlow<List<Landmark>> = _landmarks.asStateFlow()

    private val _pendingLongStay = MutableStateFlow<LatLng?>(null)
    val pendingLongStay: StateFlow<LatLng?> = _pendingLongStay.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    fun load() = viewModelScope.launch {
        val uid = WBAuth.userId ?: return@launch
        runCatching {
            WBClient.rest(
                "GET", "landmarks",
                query = listOf("select" to "id,alias,lat,lng,radius", "user_id" to "eq.$uid"),
            )
        }.onSuccess { data ->
            _landmarks.value = data.asJsonArray().mapNotNull { r ->
                val la = r.optDouble("lat"); val lo = r.optDouble("lng")
                if (la.isNaN() || lo.isNaN()) null
                else Landmark(
                    id = r.optString("id"),
                    alias = r.optString("alias"),
                    coordinate = LatLng(la, lo),
                    radius = r.optInt("radius", 100),
                )
            }
        }
    }

    fun create(alias: String, coordinate: LatLng, radius: Int) = viewModelScope.launch {
        val uid = WBAuth.userId ?: return@launch
        val temp = Landmark(UUID.randomUUID().toString(), alias, coordinate, radius)
        _landmarks.value = _landmarks.value + temp
        try {
            WBClient.rest(
                "POST", "landmarks",
                body = JSONObject(
                    mapOf(
                        "user_id" to uid, "alias" to alias,
                        "lat" to coordinate.latitude, "lng" to coordinate.longitude, "radius" to radius,
                    )
                ),
            )
            load()   // 成功才重載同步（拿 server id）
        } catch (e: Exception) {
            _landmarks.value = _landmarks.value.filterNot { it.id == temp.id }
            _lastError.value = "地標沒建立成功——沒網路或連不到伺服器。"
        }
    }

    fun update(landmark: Landmark) = viewModelScope.launch {
        val old = _landmarks.value.firstOrNull { it.id == landmark.id } ?: return@launch
        _landmarks.value = _landmarks.value.map { if (it.id == landmark.id) landmark else it }
        try {
            WBClient.rest(
                "PATCH", "landmarks",
                query = listOf("id" to "eq.${landmark.id}"),
                body = JSONObject(
                    mapOf(
                        "alias" to landmark.alias,
                        "lat" to landmark.coordinate.latitude,
                        "lng" to landmark.coordinate.longitude,
                        "radius" to landmark.radius,
                    )
                ),
            )
        } catch (e: Exception) {
            _landmarks.value = _landmarks.value.map { if (it.id == landmark.id) old else it }
            _lastError.value = "地標沒更新成功——沒網路或連不到伺服器。"
        }
    }

    fun delete(id: String) = viewModelScope.launch {
        val idx = _landmarks.value.indexOfFirst { it.id == id }
        if (idx < 0) return@launch
        val removed = _landmarks.value[idx]
        _landmarks.value = _landmarks.value.filterNot { it.id == id }
        try {
            WBClient.rest("DELETE", "landmarks", query = listOf("id" to "eq.$id"))
        } catch (e: Exception) {
            _landmarks.value = _landmarks.value.toMutableList().also {
                it.add(minOf(idx, it.size), removed)
            }
            _lastError.value = "地標沒刪成功——沒網路或連不到伺服器，地標還在。"
        }
    }

    /** 本地預覽用：座標落在哪個地標半徑內（正式名稱解析仍以後端 resolve_name 為準） */
    fun resolvePreview(c: LatLng): Landmark? = _landmarks.value.firstOrNull { l ->
        StationaryDetector.distanceMeters(
            l.coordinate.latitude, l.coordinate.longitude, c.latitude, c.longitude
        ) <= l.radius
    }

    fun promptLongStay(c: LatLng) { _pendingLongStay.value = c }
    fun dismissLongStay() { _pendingLongStay.value = null }
    fun clearError() { _lastError.value = null }
}
