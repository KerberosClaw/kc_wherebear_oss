package com.kerberosclaw.wherebear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kerberosclaw.wherebear.core.Stay
import com.kerberosclaw.wherebear.core.WBTime
import com.kerberosclaw.wherebear.ui.components.EmptyStateBear
import com.kerberosclaw.wherebear.ui.theme.BearTheme
import com.kerberosclaw.wherebear.vm.LocationViewModel
import java.time.LocalDate

@Composable
fun TimelineScreen(vm: LocationViewModel) {
    val stays by vm.stays.collectAsState()
    val selectedDays by vm.selectedDays.collectAsState()
    val loading by vm.loading.collectAsState()

    LaunchedEffect(Unit) { vm.reloadStays() }

    Column(Modifier.fillMaxSize().background(BearTheme.bg)) {
        Text(
            "時間軸",
            color = BearTheme.cream,
            fontSize = 26.sp,
            fontWeight = FontWeight.ExtraBold,
            modifier = Modifier.padding(start = 20.dp, top = 18.dp, bottom = 10.dp),
        )

        // 日期快選（對應 iOS 的 DateChips；完整月曆多選見 README 的待辦）
        val today = WBTime.today()
        Row(
            modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            DayChip("今天", selectedDays.isEmpty()) { vm.setSelectedDays(emptyList()) }
            DayChip("昨天", selectedDays == listOf(today.minusDays(1))) {
                vm.setSelectedDays(listOf(today.minusDays(1)))
            }
            DayChip("近 7 天", selectedDays.size == 7) { vm.selectRange(today.minusDays(6), today) }
        }

        Box(Modifier.fillMaxSize()) {
            when {
                loading && stays.isEmpty() ->
                    CircularProgressIndicator(color = BearTheme.honey, modifier = Modifier.align(Alignment.Center))
                stays.isEmpty() ->
                    Box(Modifier.align(Alignment.Center)) {
                        EmptyStateBear("這天沒有足跡", "開著回報，停留段會自己長出來。")
                    }
                else -> LazyColumn(
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    itemsIndexed(stays) { i, stay -> StayRow(stay, i + 1) }
                }
            }
        }
    }
}

@Composable
private fun DayChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label,
        color = if (selected) BearTheme.ink else BearTheme.cream.copy(alpha = 0.7f),
        fontSize = 13.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier
            .background(if (selected) BearTheme.honey else BearTheme.surface, RoundedCornerShape(999.dp))
            .clickable { onClick() }
            .padding(horizontal = 14.dp, vertical = 7.dp),
    )
}

@Composable
private fun StayRow(stay: Stay, index: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(BearTheme.surface, RoundedCornerShape(14.dp))
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            Modifier.size(26.dp).background(BearTheme.honey, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (stay.source == Stay.Source.PHOTO_IMPORT) "📷" else "$index",
                color = BearTheme.ink, fontSize = 12.sp, fontWeight = FontWeight.Bold,
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(3.dp), modifier = Modifier.fillMaxWidth()) {
            Text(stay.name, color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            val range = buildString {
                append(WBTime.hhmm(stay.from))
                stay.to?.let { append(" – ${WBTime.hhmm(it)}") }
                if (stay.dwellSeconds > 0) append(" · ${stay.dwellText}")
            }
            Text(range, color = BearTheme.cream.copy(alpha = 0.6f), fontSize = 12.5.sp)
            if (stay.isLowConfidence) {
                Text("訊號稀疏、可能不準", color = BearTheme.amberText, fontSize = 11.5.sp)
            }
            stay.day?.let {
                Text(it, color = BearTheme.cream.copy(alpha = 0.35f), fontSize = 11.sp)
            }
        }
    }
}
