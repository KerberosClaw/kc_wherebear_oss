package com.kerberosclaw.wherebear.ui

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kerberosclaw.wherebear.core.AuthState
import com.kerberosclaw.wherebear.core.Config
import com.kerberosclaw.wherebear.ui.theme.BearTheme
import com.kerberosclaw.wherebear.vm.ApiKeyViewModel
import com.kerberosclaw.wherebear.vm.LandmarkViewModel
import com.kerberosclaw.wherebear.vm.LocationViewModel
import com.kerberosclaw.wherebear.vm.ProfileViewModel
import com.kerberosclaw.wherebear.vm.SessionViewModel
import com.kerberosclaw.wherebear.photo.PhotoImporter
import kotlinx.coroutines.delay

enum class AppTab { MAP, TIMELINE, SETTINGS }

@Composable
fun RootScreen(
    session: SessionViewModel,
    locationVm: LocationViewModel,
    landmarkVm: LandmarkViewModel,
    apiKeyVm: ApiKeyViewModel,
    profileVm: ProfileViewModel,
    photoImporter: PhotoImporter,
    onRequestLocationPermission: () -> Unit,
    onRequestBackgroundPermission: () -> Unit,
    onOpenAppSettings: () -> Unit,
) {
    val authState by session.state.collectAsState()
    var splashDone by remember { mutableStateOf(Config.SPLASH_SECONDS <= 0) }

    LaunchedEffect(Unit) {
        if (Config.SPLASH_SECONDS > 0) {
            delay((Config.SPLASH_SECONDS * 1000).toLong())
            splashDone = true
        }
    }

    Crossfade(
        targetState = when {
            authState == AuthState.RESTORING || !splashDone -> "splash"
            authState == AuthState.LOGGED_IN -> "main"
            else -> "auth"
        },
        label = "root",
    ) { screen ->
        when (screen) {
            "splash" -> SplashScreen()
            "auth" -> AuthScreen(session)
            else -> MainTabs(
                session, locationVm, landmarkVm, apiKeyVm, profileVm, photoImporter,
                onRequestLocationPermission, onRequestBackgroundPermission, onOpenAppSettings,
            )
        }
    }
}

@Composable
private fun SplashScreen() {
    var progress by remember { mutableStateOf(0f) }
    LaunchedEffect(Unit) {
        val steps = 40
        repeat(steps) {
            delay(((Config.SPLASH_SECONDS * 1000) / steps).toLong())
            progress = (it + 1f) / steps
        }
    }
    Box(Modifier.fillMaxSize().background(BearTheme.bg), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Text("🐻", fontSize = 64.sp)
            Text("熊熊在哪裡", color = BearTheme.cream, fontSize = 34.sp, fontWeight = FontWeight.ExtraBold)
            LinearProgressIndicator(
                progress = { progress },
                color = BearTheme.honey,
                trackColor = BearTheme.cream.copy(alpha = 0.2f),
                modifier = Modifier.fillMaxWidth(0.55f),
            )
            Text("正在登入……", color = BearTheme.cream.copy(alpha = 0.7f), fontSize = 13.sp)
        }
    }
}

@Composable
private fun MainTabs(
    session: SessionViewModel,
    locationVm: LocationViewModel,
    landmarkVm: LandmarkViewModel,
    apiKeyVm: ApiKeyViewModel,
    profileVm: ProfileViewModel,
    photoImporter: PhotoImporter,
    onRequestLocationPermission: () -> Unit,
    onRequestBackgroundPermission: () -> Unit,
    onOpenAppSettings: () -> Unit,
) {
    var tab by remember { mutableStateOf(AppTab.MAP) }
    val snackbar = remember { SnackbarHostState() }
    val landmarkError by landmarkVm.lastError.collectAsState()

    // 登入後集中重載（各 VM 建立時還沒 token）
    LaunchedEffect(Unit) {
        profileVm.load(); landmarkVm.load(); apiKeyVm.load(); locationVm.refresh()
    }
    LaunchedEffect(landmarkError) {
        landmarkError?.let { snackbar.showSnackbar(it); landmarkVm.clearError() }
    }

    Scaffold(
        containerColor = BearTheme.bg,
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar(containerColor = BearTheme.surface) {
                TabItem(tab == AppTab.MAP, Icons.Filled.Map, "地圖") { tab = AppTab.MAP }
                TabItem(tab == AppTab.TIMELINE, Icons.Filled.Schedule, "時間軸") { tab = AppTab.TIMELINE }
                TabItem(tab == AppTab.SETTINGS, Icons.Filled.Settings, "設定") { tab = AppTab.SETTINGS }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            when (tab) {
                AppTab.MAP -> MapHomeScreen(locationVm, landmarkVm, profileVm, onOpenAppSettings, onRequestLocationPermission)
                AppTab.TIMELINE -> TimelineScreen(locationVm)
                AppTab.SETTINGS -> SettingsScreen(
                    session, landmarkVm, apiKeyVm, profileVm, photoImporter,
                    onRequestLocationPermission, onRequestBackgroundPermission, onOpenAppSettings,
                )
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TabItem(
    selected: Boolean,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
) {
    NavigationBarItem(
        selected = selected,
        onClick = onClick,
        icon = { Icon(icon, contentDescription = label) },
        label = { Text(label, fontSize = 11.sp) },
        colors = NavigationBarItemDefaults.colors(
            selectedIconColor = BearTheme.honeyLight,
            selectedTextColor = BearTheme.honeyLight,
            unselectedIconColor = BearTheme.cream.copy(alpha = 0.55f),
            unselectedTextColor = BearTheme.cream.copy(alpha = 0.55f),
            indicatorColor = BearTheme.surfaceHi,
        ),
    )
}
