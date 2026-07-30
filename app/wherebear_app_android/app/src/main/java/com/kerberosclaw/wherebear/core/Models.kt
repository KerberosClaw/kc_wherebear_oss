package com.kerberosclaw.wherebear.core

import com.google.android.gms.maps.model.LatLng
import java.time.Instant

// 對齊 iOS Models.swift / API_CONTRACT

enum class AuthState { RESTORING, LOGGED_OUT, NEEDS_VERIFY, LOGGED_IN }

enum class ReportFrequency(val label: String) {
    SAVER("省電"), STANDARD("標準");

    val pollSeconds: Long
        get() = if (this == SAVER) Config.POLL_SAVER_SECONDS else Config.POLL_STANDARD_SECONDS
}

/** iOS 的 whenInUse/always 在 Android 對應 前景定位 / 背景定位 */
enum class PermissionState { NOT_DETERMINED, WHEN_IN_USE, ALWAYS, DENIED }

enum class Connectivity { ONLINE, OFFLINE }

data class CurrentLocation(
    val coordinate: LatLng,
    val accuracy: Double,
    /** 契約 §2.1：nullable（null → UI 顯示 raw 座標） */
    val resolvedName: String?,
    val capturedAt: Instant,
    val isStale: Boolean,
)

data class Stay(
    val id: String,
    val name: String,
    val from: Instant,
    /** 契約 §2.2：進行中／單點 import 可 null */
    val to: Instant?,
    val dwellSeconds: Int,
    val confidence: Double = 1.0,
    val source: Source = Source.LIVE,
    val coordinate: LatLng? = null,
    val day: String? = null,
) {
    enum class Source { LIVE, PHOTO_IMPORT, VISIT }

    val isLowConfidence: Boolean get() = confidence < LOW_CONFIDENCE_THRESHOLD

    val dwellText: String
        get() {
            val m = dwellSeconds / 60
            if (m < 60) return "$m 分"
            return if (m % 60 == 0) "${m / 60} 小時" else "${m / 60} 小時 ${m % 60} 分"
        }

    companion object { const val LOW_CONFIDENCE_THRESHOLD = 0.6 }
}

data class ApiKeyInfo(
    val id: String,
    val name: String,
    val keyLast4: String,
    val lastUsedAt: Instant?,
    val createdAt: Instant,
) {
    val masked: String get() = "wb_…$keyLast4"
    val lastUsedText: String
        get() = lastUsedAt?.let { "上次使用 ${relativeZh(it)}" } ?: "尚未使用"
}

data class Landmark(
    val id: String,
    val alias: String,
    val coordinate: LatLng,
    /** 契約 §1.3：int 公尺 */
    val radius: Int,
)
