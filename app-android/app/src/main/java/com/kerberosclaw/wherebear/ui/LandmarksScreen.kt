package com.kerberosclaw.wherebear.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.LatLng
import com.kerberosclaw.wherebear.core.Landmark
import com.kerberosclaw.wherebear.location.LocationReporter
import com.kerberosclaw.wherebear.ui.components.SectionCard
import com.kerberosclaw.wherebear.ui.theme.BearTheme
import com.kerberosclaw.wherebear.vm.LandmarkViewModel

/**
 * 地標（使用者自訂 alias，契約 §1.3）。
 * 🔴 語意標籤座標比匿名座標敏感 —— 只在 runtime 寫入、絕不進 migration seed。
 */
@Composable
fun LandmarksSection(vm: LandmarkViewModel) {
    val context = LocalContext.current
    val landmarks by vm.landmarks.collectAsState()
    val lastLocation by LocationReporter.lastLocation.collectAsState()
    var editing by remember { mutableStateOf<Landmark?>(null) }
    var creatingHere by remember { mutableStateOf(false) }

    SectionCard {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("我的地標", color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            TextButton(
                enabled = lastLocation != null,
                onClick = { creatingHere = true },
            ) { Text("＋ 用現在位置", color = BearTheme.honeyLight) }
        }
        Text(
            "座標落在半徑內時，app 與下游都會顯示你取的名字。",
            color = BearTheme.cream.copy(alpha = 0.55f), fontSize = 12.sp,
        )
        if (landmarks.isEmpty()) {
            Text("還沒有地標。", color = BearTheme.cream.copy(alpha = 0.4f), fontSize = 13.sp)
        }
        landmarks.forEach { l ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text(l.alias, color = BearTheme.cream, fontSize = 14.sp)
                    Text("半徑 ${l.radius} m", color = BearTheme.cream.copy(alpha = 0.5f), fontSize = 11.5.sp)
                }
                Row {
                    TextButton(onClick = { editing = l }) { Text("編輯", color = BearTheme.honeyLight) }
                    TextButton(onClick = { vm.delete(l.id) }) { Text("刪除", color = BearTheme.salmonText) }
                }
            }
        }
    }

    if (creatingHere) {
        val loc = lastLocation
        LandmarkDialog(
            title = "把現在位置存成地標",
            initialAlias = "",
            initialRadius = 100,
            onDismiss = { creatingHere = false },
            onConfirm = { alias, radius ->
                if (loc != null) vm.create(alias, LatLng(loc.latitude, loc.longitude), radius)
                creatingHere = false
            },
        )
    }

    editing?.let { l ->
        LandmarkDialog(
            title = "編輯地標",
            initialAlias = l.alias,
            initialRadius = l.radius,
            onDismiss = { editing = null },
            onConfirm = { alias, radius ->
                vm.update(l.copy(alias = alias, radius = radius))
                editing = null
            },
        )
    }
}

@Composable
private fun LandmarkDialog(
    title: String,
    initialAlias: String,
    initialRadius: Int,
    onDismiss: () -> Unit,
    onConfirm: (String, Int) -> Unit,
) {
    var alias by remember { mutableStateOf(initialAlias) }
    var radius by remember { mutableStateOf(initialRadius) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = BearTheme.surfaceHi,
        title = { Text(title, color = BearTheme.cream) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    alias, { alias = it }, singleLine = true,
                    label = { Text("名稱", color = BearTheme.cream.copy(alpha = 0.6f)) },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
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
            TextButton(enabled = alias.isNotBlank(), onClick = { onConfirm(alias.trim(), radius) }) {
                Text("存起來", color = BearTheme.honeyLight)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消", color = BearTheme.cream.copy(alpha = 0.6f)) }
        },
    )
}
