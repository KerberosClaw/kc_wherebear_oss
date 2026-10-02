package com.kerberosclaw.wherebear.location

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.kerberosclaw.wherebear.net.WBAuth

/**
 * 開機／更新後把回報接回來。
 * 對應 iOS「開關存 UserDefaults、啟動時照著恢復」那段 —— 原專案就是漏了這條路，
 * 才會出現數小時的空白。Android 這邊除了冷啟動還多一個開機事件要接。
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        WBAuth.init(context)
        LocationReporter.init(context)

        // 沒開回報、或沒權限就別硬起（Android 14 起前景服務啟動限制更嚴）
        if (!LocationReporter.isReporting.value) return
        if (!LocationReporter.hasForegroundLocation(context)) return
        ReportingService.start(context)
    }
}
