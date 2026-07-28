package com.kerberosclaw.wherebear.ui

import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kerberosclaw.wherebear.core.Config
import com.kerberosclaw.wherebear.core.PermissionState
import com.kerberosclaw.wherebear.core.ReportFrequency
import com.kerberosclaw.wherebear.core.WBTime
import com.kerberosclaw.wherebear.location.LocationReporter
import com.kerberosclaw.wherebear.photo.PhotoImporter
import com.kerberosclaw.wherebear.ui.components.SectionCard
import com.kerberosclaw.wherebear.ui.theme.BearTheme
import com.kerberosclaw.wherebear.vm.ApiKeyViewModel
import com.kerberosclaw.wherebear.vm.LandmarkViewModel
import com.kerberosclaw.wherebear.vm.ProfileViewModel
import com.kerberosclaw.wherebear.vm.SessionViewModel

@Composable
fun SettingsScreen(
    session: SessionViewModel,
    landmarkVm: LandmarkViewModel,
    apiKeyVm: ApiKeyViewModel,
    profileVm: ProfileViewModel,
    photoImporter: PhotoImporter,
    onRequestLocationPermission: () -> Unit,
    onRequestBackgroundPermission: () -> Unit,
    onOpenAppSettings: () -> Unit,
) {
    val context = LocalContext.current
    val email by session.userEmail.collectAsState()
    val frequency by LocationReporter.frequency.collectAsState()
    val permission by LocationReporter.permissionState.collectAsState()
    val outboxCount by LocationReporter.outboxCount.collectAsState()
    val visitOutboxCount by LocationReporter.visitOutboxCount.collectAsState()
    val avatar by profileVm.avatar.collectAsState()
    val displayName by profileVm.displayName.collectAsState()

    Column(
        Modifier.fillMaxSize().background(BearTheme.bg).verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text(
            "設定",
            color = BearTheme.cream, fontSize = 26.sp, fontWeight = FontWeight.ExtraBold,
            modifier = Modifier.padding(start = 4.dp, top = 18.dp),
        )

        // --- 個人 ---
        ProfileSection(profileVm, email, displayName, avatar)

        // --- 回報頻率 ---
        SectionCard {
            Text("回報頻率", color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ReportFrequency.entries.forEach { f ->
                    TextButton(onClick = { LocationReporter.setFrequency(context, f) }) {
                        Text(
                            "${f.label}（${f.pollSeconds} 秒）",
                            color = if (frequency == f) BearTheme.honeyLight else BearTheme.cream.copy(alpha = 0.5f),
                        )
                    }
                }
            }
            Text(
                "省電＝約 100m 精度、間隔長；標準＝較準、較耗電。",
                color = BearTheme.cream.copy(alpha = 0.5f), fontSize = 12.sp,
            )
        }

        // --- 定位權限 ---
        SectionCard {
            Text("定位權限", color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            when (permission) {
                PermissionState.ALWAYS ->
                    Text("一律允許 ✓", color = BearTheme.green, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                PermissionState.WHEN_IN_USE -> {
                    Text("只在使用 app 時允許", color = BearTheme.amberText, fontSize = 14.sp)
                    Text(
                        "背景回報需要「一律允許」。Android 規定這一項只能由你到系統設定裡自己改。",
                        color = BearTheme.cream.copy(alpha = 0.55f), fontSize = 12.sp,
                    )
                    TextButton(onClick = onRequestBackgroundPermission) {
                        Text("前往開放背景定位", color = BearTheme.honeyLight)
                    }
                }
                PermissionState.NOT_DETERMINED ->
                    TextButton(onClick = onRequestLocationPermission) {
                        Text("要求定位權限", color = BearTheme.honeyLight)
                    }
                PermissionState.DENIED -> {
                    Text("已拒絕", color = BearTheme.salmonText, fontSize = 14.sp)
                    TextButton(onClick = onOpenAppSettings) { Text("前往系統設定", color = BearTheme.honeyLight) }
                }
            }
        }

        // --- 離線佇列 ---
        SectionCard {
            Text("離線佇列", color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            Text("位置點：$outboxCount 筆", color = BearTheme.cream.copy(alpha = 0.75f), fontSize = 13.sp)
            Text("停留：$visitOutboxCount 筆", color = BearTheme.cream.copy(alpha = 0.75f), fontSize = 13.sp)
            if (outboxCount == 0 && visitOutboxCount == 0) {
                Text("佇列是空的 — 都送出去了。", color = BearTheme.cream.copy(alpha = 0.45f), fontSize = 12.sp)
            }
        }

        LandmarksSection(landmarkVm)
        ApiKeysSection(apiKeyVm)
        PhotoImportSection(photoImporter)

        // --- 帳號 ---
        SectionCard {
            Text("帳號", color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            Text(email ?: "—", color = BearTheme.cream.copy(alpha = 0.7f), fontSize = 13.sp)
            Text(
                "後端：${Config.envName} · ${Config.supabaseUrl}",
                color = BearTheme.cream.copy(alpha = 0.4f), fontSize = 11.sp,
            )
            Row {
                TextButton(onClick = { session.changePassword() }) {
                    Text("寄改密碼信", color = BearTheme.honeyLight)
                }
                TextButton(onClick = {
                    LocationReporter.stop(context)
                    session.signOut()
                }) { Text("登出", color = BearTheme.salmonText) }
            }
        }

        Text(
            "你的位置資料只會送到你自己設定的後端，不經過任何第三方服務。頭貼是公開展示照、與位置資料分開存放。",
            color = BearTheme.cream.copy(alpha = 0.45f), fontSize = 11.5.sp,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun ProfileSection(
    profileVm: ProfileViewModel,
    email: String?,
    displayName: String?,
    avatar: Bitmap?,
) {
    val context = LocalContext.current
    var editingName by remember { mutableStateOf(false) }
    var nameDraft by remember { mutableStateOf(displayName.orEmpty()) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        val bmp = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { d, _, _ ->
                    d.setTargetSampleSize(2)
                    d.isMutableRequired = false
                }
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Images.Media.getBitmap(context.contentResolver, uri)
            }
        }.getOrNull()
        bmp?.let { profileVm.setAvatar(centerSquare(it)) }
    }

    SectionCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            androidx.compose.foundation.Image(
                bitmap = (avatar ?: defaultAvatar()).asImageBitmap(),
                contentDescription = "頭貼",
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(56.dp).background(BearTheme.surfaceHi, CircleShape),
            )
            Column(Modifier.weight(1f)) {
                Text(displayName ?: email ?: "—", color = BearTheme.cream, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    if (displayName != null) email.orEmpty() else "還沒設暱稱",
                    color = BearTheme.cream.copy(alpha = 0.5f), fontSize = 12.sp,
                )
            }
        }
        Row {
            TextButton(onClick = { picker.launch("image/*") }) { Text("更換頭貼", color = BearTheme.honeyLight) }
            TextButton(onClick = { nameDraft = displayName.orEmpty(); editingName = true }) {
                Text("改暱稱", color = BearTheme.honeyLight)
            }
        }
        if (editingName) {
            OutlinedTextField(
                nameDraft, { nameDraft = it }, singleLine = true,
                label = { Text("顯示名稱（留空＝顯示 email）", color = BearTheme.cream.copy(alpha = 0.6f)) },
                modifier = Modifier.fillMaxWidth(),
            )
            Row {
                TextButton(onClick = { profileVm.setDisplayName(nameDraft); editingName = false }) {
                    Text("存起來", color = BearTheme.honeyLight)
                }
                TextButton(onClick = { editingName = false }) {
                    Text("取消", color = BearTheme.cream.copy(alpha = 0.6f))
                }
            }
        }
    }
}

@Composable
private fun PhotoImportSection(importer: PhotoImporter) {
    val scanned by importer.scannedCount.collectAsState()
    val progress by importer.progress.collectAsState()
    val result by importer.result.collectAsState()
    var days by remember { mutableStateOf(7L) }

    SectionCard {
        Text("相簿匯入", color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "只讀照片的座標與時間，不讀照片內容本身。Android 需要「照片位置」權限才拿得到座標。",
            color = BearTheme.cream.copy(alpha = 0.55f), fontSize = 12.sp,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(1L, 7L, 30L).forEach { d ->
                TextButton(onClick = { days = d }) {
                    Text(
                        "近 $d 天",
                        color = if (days == d) BearTheme.honeyLight else BearTheme.cream.copy(alpha = 0.5f),
                    )
                }
            }
        }
        Row {
            TextButton(onClick = {
                val today = WBTime.today()
                importer.scan(today.minusDays(days - 1), today)
            }) { Text("掃描", color = BearTheme.honeyLight) }
            scanned?.let { n ->
                TextButton(enabled = n > 0, onClick = { importer.importPoints() }) {
                    Text("匯入 $n 個點", color = BearTheme.honeyLight)
                }
            }
        }
        if (progress > 0.0 && progress < 1.0) {
            LinearProgressIndicator(
                progress = { progress.toFloat() },
                color = BearTheme.honey,
                trackColor = BearTheme.cream.copy(alpha = 0.2f),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        result?.let { r ->
            val text = when {
                r.failed -> "連不到伺服器，已匯入 ${r.inserted} 個點就中止了。"
                r.total == 0 -> "這個範圍沒有帶座標的照片。"
                else -> "匯入 ${r.inserted} 個新點（${r.total - r.inserted} 個重複略過）。"
            }
            Text(text, color = BearTheme.greenText, fontSize = 12.5.sp)
            TextButton(onClick = { importer.clearResult() }) {
                Text("知道了", color = BearTheme.cream.copy(alpha = 0.6f))
            }
        }
    }
}

private fun centerSquare(src: Bitmap): Bitmap {
    val side = minOf(src.width, src.height)
    val x = (src.width - side) / 2
    val y = (src.height - side) / 2
    val cropped = Bitmap.createBitmap(src, x, y, side, side)
    return Bitmap.createScaledBitmap(cropped, 512, 512, true)
}

private fun defaultAvatar(): Bitmap =
    Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).apply { eraseColor(0xFF3A2A18.toInt()) }
