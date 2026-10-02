package com.kerberosclaw.wherebear

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import com.kerberosclaw.wherebear.location.LocationReporter
import com.kerberosclaw.wherebear.photo.PhotoImporter
import com.kerberosclaw.wherebear.ui.RootScreen
import com.kerberosclaw.wherebear.ui.theme.WhereBearTheme
import com.kerberosclaw.wherebear.vm.ApiKeyViewModel
import com.kerberosclaw.wherebear.vm.LandmarkViewModel
import com.kerberosclaw.wherebear.vm.LocationViewModel
import com.kerberosclaw.wherebear.vm.ProfileViewModel
import com.kerberosclaw.wherebear.vm.SessionViewModel

class MainActivity : ComponentActivity() {

    private val session: SessionViewModel by viewModels()
    private val locationVm: LocationViewModel by viewModels()
    private val landmarkVm: LandmarkViewModel by viewModels()
    private val apiKeyVm: ApiKeyViewModel by viewModels()
    private val profileVm: ProfileViewModel by viewModels()
    private val photoImporter: PhotoImporter by viewModels()

    /**
     * 權限流程與 iOS 不同的重點：
     * Android 10 起「背景定位」不能跟前景定位一起要 —— 必須先拿到前景，
     * 之後才能單獨要背景，而且 Android 11 起系統直接不給彈窗、只能把人帶去設定頁。
     * 所以這裡拆成兩段，第二段落在設定頁的按鈕上。
     */
    private val locationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
            LocationReporter.markLocationAsked()
            LocationReporter.refreshPermissionState()
            if (granted[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                granted[Manifest.permission.ACCESS_COARSE_LOCATION] == true
            ) {
                // 有前景權限了 → 順手要通知權限（Android 13+ 前景服務通知需要它）
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
        }

    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    private val backgroundPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            LocationReporter.refreshPermissionState()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            WhereBearTheme {
                RootScreen(
                    session = session,
                    locationVm = locationVm,
                    landmarkVm = landmarkVm,
                    apiKeyVm = apiKeyVm,
                    profileVm = profileVm,
                    photoImporter = photoImporter,
                    onRequestLocationPermission = ::requestLocationPermission,
                    onRequestBackgroundPermission = ::requestBackgroundPermission,
                    onOpenAppSettings = ::openAppSettings,
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // 回前景：補位置權限狀態 + 把離線佇列送出去（對應 iOS 的 scenePhase → active）
        LocationReporter.onEnterForeground()
    }

    private fun requestLocationPermission() {
        locationPermissionLauncher.launch(
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        )
    }

    private fun requestBackgroundPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+：系統不再給第二次彈窗，只能帶去設定頁選「一律允許」
            openAppSettings()
        } else {
            backgroundPermissionLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        }
    }

    private fun openAppSettings() {
        startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        )
    }
}
