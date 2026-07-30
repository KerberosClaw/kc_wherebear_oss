package com.kerberosclaw.wherebear.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kerberosclaw.wherebear.ui.theme.BearTheme

@Composable
fun SectionCard(
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(BearTheme.surface, RoundedCornerShape(16.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        content = content,
    )
}

@Composable
fun PrimaryButton(text: String, enabled: Boolean = true, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = BearTheme.honey,
            contentColor = BearTheme.ink,
            disabledContainerColor = BearTheme.honey.copy(alpha = 0.35f),
        ),
    ) { Text(text, fontWeight = FontWeight.Bold) }
}

/** 狀態 pill：回報中 / 離線 / 權限不足 / 座標過時 */
@Composable
fun StatusPill(text: String, tint: Color, onClick: (() -> Unit)? = null) {
    Row(
        modifier = Modifier
            .background(BearTheme.surface.copy(alpha = 0.92f), RoundedCornerShape(999.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.10f), RoundedCornerShape(999.dp))
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(8.dp).background(tint, CircleShape))
        Text(text, color = BearTheme.cream, fontSize = 12.5.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun EmptyStateBear(title: String, message: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(32.dp),
    ) {
        Text("🐻", fontSize = 44.sp)
        Text(title, color = BearTheme.cream, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Text(
            message,
            color = BearTheme.cream.copy(alpha = 0.65f),
            fontSize = 13.5.sp,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}
