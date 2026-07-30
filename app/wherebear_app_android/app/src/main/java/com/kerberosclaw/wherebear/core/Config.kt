package com.kerberosclaw.wherebear.core

import com.kerberosclaw.wherebear.BuildConfig

/**
 * Config — dev / prod 端點切換（對應 iOS Config.swift）。
 * iOS 用 `DEV` 編譯旗標切；Android 直接用 build type：debug = dev backend、release = prod。
 * 值全部來自 gitignored 的 local.properties（見 local.properties.example）。
 */
object Config {
    val supabaseUrl: String = BuildConfig.SUPABASE_URL.trimEnd('/')
    val anonKey: String = BuildConfig.SUPABASE_ANON_KEY
    val envName: String = BuildConfig.ENV_NAME

    /** today-stays / 停留段的使用者時區（走 config、勿硬編在別處） */
    const val TZ = "Asia/Taipei"

    /** 座標過時門檻（秒）— 超過視為 isStale */
    const val STALE_THRESHOLD_SECONDS = 15L * 60

    /** 啟動 splash 停留秒數；設 0 直接跳過 */
    const val SPLASH_SECONDS = 4.0

    /** 回報間隔（秒）：省電 / 標準。對應 iOS 的 180 / 60。 */
    const val POLL_SAVER_SECONDS = 180L
    const val POLL_STANDARD_SECONDS = 60L

    /** 同一次定位重複投遞的判定窗（秒），見 LocationReporter.isRedundantFix */
    const val FIX_DEDUP_WINDOW_SECONDS = 2.0

    /**
     * 靜止停留偵測（CLVisit 的 Android 替代品，見 StationaryDetector）。
     * Android 沒有 CLVisit，這幾個值是我們自己的判準。
     */
    const val VISIT_RADIUS_METERS = 120.0        // 落在此半徑內視為「還在同一個地方」
    const val VISIT_MIN_DWELL_SECONDS = 300L     // 待滿這麼久才算一次停留（開 visit）
    const val VISIT_DEPART_METERS = 250.0        // 離開此距離視為離開（關 visit）
}
