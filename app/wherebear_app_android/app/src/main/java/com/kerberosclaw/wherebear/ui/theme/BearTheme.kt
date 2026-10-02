package com.kerberosclaw.wherebear.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/** 設計 tokens（深色底＋暖熊 accent）— 與 iOS BearTheme.swift 同一組色票 */
object BearTheme {
    val bg = Color(0xFF17130F)          // 主背景（暖近黑）
    val surface = Color(0xFF221B13)     // 卡片
    val surfaceHi = Color(0xFF262019)   // modal
    val sheet = Color(0xFF201913)       // bottom sheet
    val cream = Color(0xFFF4E3C8)       // 主文字
    val honey = Color(0xFFC98A4B)       // accent
    val honeyLight = Color(0xFFE8B878)  // accent 亮
    val ink = Color(0xFF2A1D10)         // accent 上的深字
    val pawInk = Color(0xFF3A2A18)      // 掌印
    val green = Color(0xFF7FAE63)       // 回報中
    val greenText = Color(0xFFCFE3BD)
    val amber = Color(0xFFD9A13A)       // 警示
    val amberText = Color(0xFFECC57E)
    val salmon = Color(0xFFD98A6A)      // 破壞性
    val salmonText = Color(0xFFEAB29A)
    val offlineBlue = Color(0xFFB8C6DD) // 離線

    val honeyGradient = Brush.linearGradient(listOf(honeyLight, honey))
}

private val WhereBearColors = darkColorScheme(
    primary = BearTheme.honeyLight,
    onPrimary = BearTheme.ink,
    secondary = BearTheme.honey,
    background = BearTheme.bg,
    onBackground = BearTheme.cream,
    surface = BearTheme.surface,
    onSurface = BearTheme.cream,
    surfaceVariant = BearTheme.surfaceHi,
    onSurfaceVariant = BearTheme.cream,
    error = BearTheme.salmon,
)

/** app 一律深色（對應 iOS 的 .preferredColorScheme(.dark)） */
@Composable
fun WhereBearTheme(content: @Composable () -> Unit) {
    @Suppress("UNUSED_EXPRESSION") isSystemInDarkTheme()
    MaterialTheme(colorScheme = WhereBearColors, content = content)
}
