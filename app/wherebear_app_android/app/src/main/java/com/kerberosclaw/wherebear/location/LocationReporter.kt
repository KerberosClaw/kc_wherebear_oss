package com.kerberosclaw.wherebear.location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.kerberosclaw.wherebear.core.Config
import com.kerberosclaw.wherebear.core.Connectivity
import com.kerberosclaw.wherebear.core.PermissionState
import com.kerberosclaw.wherebear.core.ReportFrequency
import com.kerberosclaw.wherebear.core.WBTime
import com.kerberosclaw.wherebear.net.WBAuth
import com.kerberosclaw.wherebear.net.WBClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.time.Instant
import kotlin.math.abs

/**
 * LocationReporter — 對應 iOS Logic.swift 的 LocationReporter。
 *
 * 分工上跟 iOS 不同的地方：iOS 是一個 @Observable 物件直接抱著 CLLocationManager；
 * Android 的背景定位一定要跑在 foreground service 裡（見 ReportingService），
 * 所以這裡只當「大腦」——收點、去重、寫 DB、管佇列、管停留偵測；
 * 誰去要點、什麼時候要，交給 service。UI 讀這裡的 StateFlow。
 */
object LocationReporter {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var appContext: Context

    private val _isReporting = MutableStateFlow(false)
    val isReporting: StateFlow<Boolean> = _isReporting.asStateFlow()

    private val _lastReportAt = MutableStateFlow<Instant?>(null)
    val lastReportAt: StateFlow<Instant?> = _lastReportAt.asStateFlow()

    private val _permissionState = MutableStateFlow(PermissionState.NOT_DETERMINED)
    val permissionState: StateFlow<PermissionState> = _permissionState.asStateFlow()

    private val _connectivity = MutableStateFlow(Connectivity.ONLINE)
    val connectivity: StateFlow<Connectivity> = _connectivity.asStateFlow()

    private val _frequency = MutableStateFlow(ReportFrequency.SAVER)
    val frequency: StateFlow<ReportFrequency> = _frequency.asStateFlow()

    /** 即時位置（顯示用，不必等 DB round-trip） */
    private val _lastLocation = MutableStateFlow<Location?>(null)
    val lastLocation: StateFlow<Location?> = _lastLocation.asStateFlow()

    private val _outboxCount = MutableStateFlow(0)
    val outboxCount: StateFlow<Int> = _outboxCount.asStateFlow()
    private val _visitOutboxCount = MutableStateFlow(0)
    val visitOutboxCount: StateFlow<Int> = _visitOutboxCount.asStateFlow()

    private val outbox = Outbox(KEY_OUTBOX, 1000)
    private val visitOutbox = Outbox(KEY_VISIT_OUTBOX, 500)
    private val detector = StationaryDetector { body -> scope.launch { submitVisit(body) } }

    // 見 isRedundantFix：擋同一次定位被兩條觸發源各寫一列
    private var lastReportedFix: Fix? = null
    private val reportMutex = Mutex()

    data class Fix(val lat: Double, val lng: Double, val atMillis: Long, val accuracy: Double)

    // 地圖畫面用的即時位置流（前景限定、絕不寫 DB）
    private var liveClient: FusedLocationProviderClient? = null
    private var liveCallback: LocationCallback? = null

    fun init(context: Context) {
        appContext = context.applicationContext
        _frequency.value = if (WBAuth.prefs.getString(KEY_FREQUENCY, "saver") == "standard")
            ReportFrequency.STANDARD else ReportFrequency.SAVER
        outbox.refreshCount(); _outboxCount.value = outbox.count
        visitOutbox.refreshCount(); _visitOutboxCount.value = visitOutbox.count
        refreshPermissionState()
        // 🔴 冷啟動自動恢復回報（與 iOS 同一個坑，理由見原專案註解）：
        // 開關存 prefs，程序被殺／開機後照著恢復，否則那條路就斷了。
        _isReporting.value = WBAuth.prefs.getBoolean(KEY_REPORTING, false)
    }

    // ---------------- 開關 ----------------

    fun start(context: Context) {
        _isReporting.value = true
        WBAuth.prefs.edit().putBoolean(KEY_REPORTING, true).apply()
        ReportingService.start(context)
    }

    fun stop(context: Context) {
        _isReporting.value = false
        WBAuth.prefs.edit().putBoolean(KEY_REPORTING, false).apply()
        ReportingService.stop(context)
        // 停止＝最後一次能講話的機會：把還開著的停留收掉，
        // 否則讀取層看到 departed_at 是空的會當成「人還在那裡」，往後每天都畫一段。
        scope.launch {
            detector.closeOpen()
            closeOpenVisits()
        }
    }

    fun setFrequency(context: Context, f: ReportFrequency) {
        _frequency.value = f
        WBAuth.prefs.edit().putString(KEY_FREQUENCY, if (f == ReportFrequency.SAVER) "saver" else "standard").apply()
        if (_isReporting.value) ReportingService.restart(context)   // 換取樣間隔要重下 request
    }

    /** 回前景：立刻補送離線佇列（對應 iOS onEnterForeground） */
    fun onEnterForeground() {
        refreshPermissionState()
        val uid = WBAuth.userId ?: return
        scope.launch { flushOutbox(uid); flushVisitOutbox() }
    }

    // ---------------- 收點 ----------------

    /** ReportingService 收到定位就丟進來 */
    fun onLocation(loc: Location) {
        _lastLocation.value = loc
        if (!_isReporting.value) return
        scope.launch {
            report(loc)
            detector.feed(loc)   // 停留偵測吃同一串點，不另外耗電
        }
    }

    /**
     * 同一次定位被寫成兩列的判準（純函式、可單測）——直接沿用 iOS 的規則。
     * 用「座標完全相等」而非距離門檻：距離門檻會連真的小幅移動一起吃掉。
     * accuracy 只准「不比留下那筆好」才丟：座標相同不代表誤差相同，而 accuracy 有下游在吃。
     */
    fun isRedundantFix(lat: Double, lng: Double, atMillis: Long, accuracy: Double, previous: Fix?, windowSeconds: Double): Boolean {
        val p = previous ?: return false
        if (lat != p.lat || lng != p.lng) return false
        if (accuracy < p.accuracy) return false          // 這筆更準 → 它帶了新資訊，放行
        return abs(atMillis - p.atMillis) / 1000.0 < windowSeconds
    }

    private suspend fun report(loc: Location) {
      reportMutex.withLock {
        val uid = WBAuth.userId ?: return@withLock
        val acc = maxOf(loc.accuracy.toDouble(), 0.0)
        val at = loc.time.takeIf { it > 0 } ?: System.currentTimeMillis()
        if (isRedundantFix(loc.latitude, loc.longitude, at, acc, lastReportedFix, Config.FIX_DEDUP_WINDOW_SECONDS)) return@withLock
        // 寫在送出「之前」：送失敗會進 outbox，重複的第二次不該再補一份
        lastReportedFix = Fix(loc.latitude, loc.longitude, at, acc)

        flushOutbox(uid)
        flushVisitOutbox()

        val point = JSONObject().apply {
            put("lat", loc.latitude)
            put("lng", loc.longitude)
            put("accuracy", acc)
            put("captured_at", WBTime.isoMillis(Instant.ofEpochMilli(at)))
        }
        try {
            val cur = JSONObject(point.toString()).put("user_id", uid)
            WBClient.rest("POST", "current_location", body = cur, prefer = "resolution=merge-duplicates")

            val hist = JSONObject(point.toString()).put("user_id", uid).put("source", "live")
            WBClient.rest(
                "POST", "location_history",
                query = listOf("on_conflict" to "user_id,source,captured_at,lat,lng"),
                body = hist, prefer = "resolution=ignore-duplicates",
            )
            _lastReportAt.value = Instant.now()
            _connectivity.value = Connectivity.ONLINE
        } catch (e: Exception) {
            outbox.enqueue(point)                       // 失敗 → 存 raw 點（current 下次成功時自然更新）
            _outboxCount.value = outbox.count
            _connectivity.value = Connectivity.OFFLINE
        }
      }
    }

    // ---------------- visits ----------------

    suspend fun submitVisit(body: JSONObject) {
        try {
            postVisit(body)
            flushVisitOutbox()
        } catch (e: Exception) {
            visitOutbox.enqueue(body) { it.optString("arrived_at") }  // 去重鍵＝到達時刻，與 DB 唯一鍵一致
            _visitOutboxCount.value = visitOutbox.count
        }
    }

    private suspend fun postVisit(body: JSONObject) {
        WBClient.rest(
            "POST", "visits",
            query = listOf("on_conflict" to "user_id,arrived_at"),
            body = body, prefer = "resolution=merge-duplicates",
        )
    }

    /**
     * 用 PATCH ＋ filter 而非 POST upsert：POST 的去重鍵是 arrived_at，
     * app 手上不一定有那個值（到達可能發生在上一次冷啟動之前）。
     * PATCH 讓 PostgREST 一次把「這個人的、還沒關的」孤兒列收掉。
     */
    private suspend fun closeOpenVisits() {
        val uid = WBAuth.userId ?: return
        runCatching {
            WBClient.rest(
                "PATCH", "visits",
                query = listOf("user_id" to "eq.$uid", "departed_at" to "is.null"),
                body = JSONObject().put("departed_at", WBTime.isoMillis(Instant.now())),
            )
        }
    }

    // ---------------- 佇列補送 ----------------

    private suspend fun flushOutbox(uid: String) {
        val q = outbox.load()
        if (q.isEmpty()) return
        val remaining = mutableListOf<JSONObject>()
        for (point in q) {
            val hist = JSONObject(point.toString()).put("user_id", uid).put("source", "live")
            try {
                WBClient.rest(
                    "POST", "location_history",
                    query = listOf("on_conflict" to "user_id,source,captured_at,lat,lng"),
                    body = hist, prefer = "resolution=ignore-duplicates",
                )
            } catch (e: Exception) {
                remaining.add(point)
            }
        }
        outbox.save(remaining)
        _outboxCount.value = outbox.count
    }

    private suspend fun flushVisitOutbox() {
        val q = visitOutbox.load()
        if (q.isEmpty()) return
        val remaining = mutableListOf<JSONObject>()
        for (body in q) {
            try { postVisit(body) } catch (e: Exception) { remaining.add(body) }
        }
        visitOutbox.save(remaining)
        _visitOutboxCount.value = visitOutbox.count
    }

    fun outboxPeek(): List<Triple<Double, Double, String>> =
        outbox.load().mapNotNull {
            val la = it.optDouble("lat"); val lo = it.optDouble("lng")
            if (la.isNaN() || lo.isNaN()) null else Triple(la, lo, it.optString("captured_at"))
        }

    fun visitOutboxPeek(): List<Pair<String, String?>> =
        visitOutbox.load().map {
            it.optString("arrived_at") to (if (it.isNull("departed_at")) null else it.optString("departed_at"))
        }

    // ---------------- 權限 ----------------

    fun refreshPermissionState() {
        if (!::appContext.isInitialized) return
        _permissionState.value = currentPermissionState(appContext)
    }

    fun currentPermissionState(context: Context): PermissionState {
        val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            val asked = WBAuth.prefs.getBoolean(KEY_ASKED_LOCATION, false)
            return if (asked) PermissionState.DENIED else PermissionState.NOT_DETERMINED
        }
        val background = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
        } else true   // Android 9 以下沒有背景定位這個概念，前景權限即可
        return if (background) PermissionState.ALWAYS else PermissionState.WHEN_IN_USE
    }

    fun markLocationAsked() { WBAuth.prefs.edit().putBoolean(KEY_ASKED_LOCATION, true).apply() }

    fun hasForegroundLocation(context: Context): Boolean =
        currentPermissionState(context).let { it == PermissionState.WHEN_IN_USE || it == PermissionState.ALWAYS }

    // ---------------- 地圖用即時位置流 ----------------

    /**
     * 只刷新 lastLocation（座標卡／跟隨相機），絕不寫 DB、不碰回報密度。
     * 前景限定（離開地圖即停）。對應 iOS 的 liveManager。
     */
    @SuppressLint("MissingPermission")
    fun startLiveUpdates(context: Context) {
        if (!hasForegroundLocation(context)) return
        if (liveCallback != null) return
        val client = LocationServices.getFusedLocationProviderClient(context)
        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let { _lastLocation.value = it }
            }
        }
        val req = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 5_000L)
            .setMinUpdateDistanceMeters(10f)   // 濾掉 <10m 的 GPS 抖動：站著不動時不亂跳
            .setWaitForAccurateLocation(false)
            .build()
        client.requestLocationUpdates(req, cb, context.mainLooper)
        liveClient = client; liveCallback = cb
        // 進地圖先 seed 一次（對應 primeLocation）
        runCatching { client.lastLocation.addOnSuccessListener { it?.let { l -> _lastLocation.value = l } } }
    }

    fun stopLiveUpdates() {
        liveCallback?.let { liveClient?.removeLocationUpdates(it) }
        liveCallback = null; liveClient = null
    }

    private const val KEY_OUTBOX = "wb_outbox"
    private const val KEY_VISIT_OUTBOX = "wb_visit_outbox"
    private const val KEY_REPORTING = "wb_reporting"
    private const val KEY_FREQUENCY = "wb_frequency"
    private const val KEY_ASKED_LOCATION = "wb_asked_location"
}
