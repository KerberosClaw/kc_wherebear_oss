package com.kerberosclaw.wherebear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.kerberosclaw.wherebear.core.Connectivity
import com.kerberosclaw.wherebear.core.PermissionState
import com.kerberosclaw.wherebear.core.relativeZh
import com.kerberosclaw.wherebear.location.LocationReporter
import com.kerberosclaw.wherebear.ui.components.EmptyStateBear
import com.kerberosclaw.wherebear.ui.components.StatusPill
import com.kerberosclaw.wherebear.ui.theme.BearTheme
import com.kerberosclaw.wherebear.vm.LandmarkViewModel
import com.kerberosclaw.wherebear.vm.LocationViewModel
import com.kerberosclaw.wherebear.vm.ProfileViewModel

@Composable
fun MapHomeScreen(
    vm: LocationViewModel,
    landmarkVm: LandmarkViewModel,
    profileVm: ProfileViewModel,
    onOpenAppSettings: () -> Unit,
    onRequestLocationPermission: () -> Unit,
) {
    val context = LocalContext.current
    val current by vm.current.collectAsState()
    val landmarks by landmarkVm.landmarks.collectAsState()
    val isReporting by LocationReporter.isReporting.collectAsState()
    val permission by LocationReporter.permissionState.collectAsState()
    val connectivity by LocationReporter.connectivity.collectAsState()
    val lastLocation by LocationReporter.lastLocation.collectAsState()
    val lastReportAt by LocationReporter.lastReportAt.collectAsState()
    val pendingLongStay by landmarkVm.pendingLongStay.collectAsState()

    var naming by remember { mutableStateOf<LatLng?>(null) }
    var following by remember { mutableStateOf(true) }

    val cameraState = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(LatLng(23.5, 121.0), 6f)
    }

    // 進地圖：開即時位置流（顯示用、不寫 DB）；離開就關
    DisposableEffect(Unit) {
        LocationReporter.startLiveUpdates(context)
        onDispose { LocationReporter.stopLiveUpdates() }
    }

    // 回報後刷新地名卡 / 新鮮度
    LaunchedEffect(lastReportAt) { vm.refreshCurrent() }

    // 跟隨模式：位置一動就把相機帶過去
    val userLatLng = lastLocation?.let { LatLng(it.latitude, it.longitude) } ?: current?.coordinate
    LaunchedEffect(userLatLng, following) {
        if (following && userLatLng != null) {
            cameraState.animate(CameraUpdateFactory.newLatLngZoom(userLatLng, maxOf(cameraState.position.zoom, 16f)))
        }
    }

    Box(Modifier.fillMaxSize().background(BearTheme.bg)) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = cameraState,
            properties = MapProperties(mapType = MapType.NORMAL, isMyLocationEnabled = false),
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false,
                myLocationButtonEnabled = false,
                mapToolbarEnabled = false,
            ),
            onMapClick = { following = false },
        ) {
            userLatLng?.let {
                Marker(state = MarkerState(position = it), title = current?.resolvedName ?: "現在位置")
            }
            landmarks.forEach { l ->
                Circle(
                    center = l.coordinate,
                    radius = l.radius.toDouble(),
                    strokeColor = BearTheme.honey.copy(alpha = 0.8f),
                    strokeWidth = 2f,
                    fillColor = BearTheme.honey.copy(alpha = 0.12f),
                )
            }
        }

        // 頂部：地名卡 + 狀態 pill
        Column(
            modifier = Modifier.align(Alignment.TopStart).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            val name = current?.resolvedName
            if (name != null) {
                Text(
                    name,
                    color = BearTheme.cream,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .background(BearTheme.surface.copy(alpha = 0.92f), RoundedCornerShape(12.dp))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
            when {
                permission == PermissionState.DENIED ->
                    StatusPill("定位權限不足 · 前往設定", BearTheme.salmon, onOpenAppSettings)
                permission == PermissionState.NOT_DETERMINED ->
                    StatusPill("需要定位權限", BearTheme.amber, onRequestLocationPermission)
                permission == PermissionState.WHEN_IN_USE && isReporting ->
                    StatusPill("僅前景可回報 · 開放「一律允許」", BearTheme.amber, onOpenAppSettings)
                isReporting && connectivity == Connectivity.OFFLINE ->
                    StatusPill("離線中 · 已排入佇列", BearTheme.offlineBlue)
                isReporting -> StatusPill("回報中", BearTheme.green)
                else -> StatusPill("未回報", BearTheme.cream.copy(alpha = 0.4f))
            }
            current?.takeIf { it.isStale && isReporting }?.let {
                StatusPill("座標於 ${relativeZh(it.capturedAt)}", BearTheme.amber)
            }
        }

        if (current == null && lastLocation == null) {
            Box(Modifier.align(Alignment.Center)) {
                EmptyStateBear("熊熊還不知道你在哪裡", "點右下角的熊掌開始回報，足跡就會出現在這裡。")
            }
        }

        // 長停留命名卡
        pendingLongStay?.let { c ->
            Column(
                modifier = Modifier.align(Alignment.BottomStart).padding(16.dp).fillMaxWidth(0.72f)
                    .background(BearTheme.surface, RoundedCornerShape(16.dp)).padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("你在這裡待了一陣子，要幫它取名嗎？", color = BearTheme.cream, fontSize = 14.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { landmarkVm.dismissLongStay(); naming = c }) {
                        Text("取名", color = BearTheme.honeyLight)
                    }
                    TextButton(onClick = { landmarkVm.dismissLongStay() }) {
                        Text("先不要", color = BearTheme.cream.copy(alpha = 0.6f))
                    }
                }
            }
        }

        // 右下：熊掌回報開關 + 跟隨鈕
        Column(
            modifier = Modifier.align(Alignment.BottomEnd).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            FloatingActionButton(
                onClick = {
                    if (isReporting) LocationReporter.stop(context)
                    else {
                        if (!LocationReporter.hasForegroundLocation(context)) onRequestLocationPermission()
                        else LocationReporter.start(context)
                    }
                },
                containerColor = if (isReporting) BearTheme.honey else BearTheme.surface,
                contentColor = if (isReporting) BearTheme.ink else BearTheme.cream,
                shape = CircleShape,
                modifier = Modifier.size(64.dp),
            ) { Text("🐾", fontSize = 26.sp) }

            FloatingActionButton(
                onClick = { following = true },
                containerColor = BearTheme.surface,
                contentColor = if (following) BearTheme.honeyLight else BearTheme.cream.copy(alpha = 0.65f),
                shape = CircleShape,
                modifier = Modifier.size(44.dp),
            ) { Text("◎", fontSize = 18.sp) }
        }

        // 長按地圖沒有原生 hook 在這層做，改由命名卡 / 地標頁進入；此對話框共用
        naming?.let { c ->
            var alias by remember { mutableStateOf("") }
            var radius by remember { mutableStateOf(100) }
            AlertDialog(
                onDismissRequest = { naming = null },
                containerColor = BearTheme.surfaceHi,
                title = { Text("幫這裡取個名字", color = BearTheme.cream) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(alias, { alias = it }, singleLine = true,
                            label = { Text("名稱", color = BearTheme.cream.copy(alpha = 0.6f)) })
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(50, 100, 200, 500).forEach { r ->
                                TextButton(onClick = { radius = r }) {
                                    Text(
                                        "${r}m",
                                        color = if (radius == r) BearTheme.honeyLight else BearTheme.cream.copy(alpha = 0.5f),
                                    )
                                }
                            }
                        }
                    }
                },
                confirmButton = {
                    TextButton(
                        enabled = alias.isNotBlank(),
                        onClick = { landmarkVm.create(alias.trim(), c, radius); naming = null },
                    ) { Text("存起來", color = BearTheme.honeyLight) }
                },
                dismissButton = {
                    TextButton(onClick = { naming = null }) { Text("取消", color = BearTheme.cream.copy(alpha = 0.6f)) }
                },
            )
        }
    }
}
