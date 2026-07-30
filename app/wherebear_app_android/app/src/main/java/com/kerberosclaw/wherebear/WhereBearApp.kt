package com.kerberosclaw.wherebear

import android.app.Application
import com.kerberosclaw.wherebear.location.LocationReporter
import com.kerberosclaw.wherebear.location.ReportingService
import com.kerberosclaw.wherebear.net.WBAuth

class WhereBearApp : Application() {
    override fun onCreate() {
        super.onCreate()
        WBAuth.init(this)
        LocationReporter.init(this)
        ReportingService.ensureChannel(this)

        // 冷啟動自動恢復回報：開關記在 prefs（見 LocationReporter.init）。
        // 有權限才起 —— 沒權限硬起前景服務在 Android 14 會直接被系統擋掉。
        if (LocationReporter.isReporting.value && LocationReporter.hasForegroundLocation(this)) {
            ReportingService.start(this)
        }
    }
}
