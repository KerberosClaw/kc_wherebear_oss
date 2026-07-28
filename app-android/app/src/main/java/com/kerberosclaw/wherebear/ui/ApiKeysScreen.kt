package com.kerberosclaw.wherebear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.platform.ClipboardManager
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kerberosclaw.wherebear.ui.components.SectionCard
import com.kerberosclaw.wherebear.ui.theme.BearTheme
import com.kerberosclaw.wherebear.vm.ApiKeyViewModel

/**
 * B 平面讀取金鑰的生命週期 UI（契約 §1.4）。
 * 🔴 明文只顯示一次：離開這個 modal 就再也拿不回來，DB 裡只有 hash。
 */
@Composable
fun ApiKeysSection(vm: ApiKeyViewModel) {
    val keys by vm.keys.collectAsState()
    val plaintext by vm.newPlaintext.collectAsState()
    val clipboard: ClipboardManager = LocalClipboardManager.current
    var creating by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }

    SectionCard {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("讀取金鑰", color = BearTheme.cream, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold)
            TextButton(onClick = { creating = true }) { Text("＋ 新增", color = BearTheme.honeyLight) }
        }
        Text(
            "給 bridge / 下游消費者用的唯讀金鑰。明文只會出現一次。",
            color = BearTheme.cream.copy(alpha = 0.55f), fontSize = 12.sp,
        )
        if (keys.isEmpty()) {
            Text("還沒有金鑰。", color = BearTheme.cream.copy(alpha = 0.4f), fontSize = 13.sp)
        }
        keys.forEach { k ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text(k.name, color = BearTheme.cream, fontSize = 14.sp)
                    Text(
                        "${k.masked} · ${k.lastUsedText}",
                        color = BearTheme.cream.copy(alpha = 0.5f), fontSize = 11.5.sp,
                        fontFamily = FontFamily.Monospace,
                    )
                }
                TextButton(onClick = { vm.revoke(k.id) }) { Text("撤銷", color = BearTheme.salmonText) }
            }
        }
    }

    if (creating) {
        AlertDialog(
            onDismissRequest = { creating = false; newName = "" },
            containerColor = BearTheme.surfaceHi,
            title = { Text("新增讀取金鑰", color = BearTheme.cream) },
            text = {
                OutlinedTextField(
                    newName, { newName = it }, singleLine = true,
                    label = { Text("用途名（如 home-bridge）", color = BearTheme.cream.copy(alpha = 0.6f)) },
                )
            },
            confirmButton = {
                TextButton(enabled = newName.isNotBlank(), onClick = {
                    vm.create(newName.trim()); newName = ""; creating = false
                }) { Text("產生", color = BearTheme.honeyLight) }
            },
            dismissButton = {
                TextButton(onClick = { creating = false; newName = "" }) {
                    Text("取消", color = BearTheme.cream.copy(alpha = 0.6f))
                }
            },
        )
    }

    plaintext?.let { p ->
        AlertDialog(
            onDismissRequest = { vm.consumePlaintext() },
            containerColor = BearTheme.surfaceHi,
            title = { Text("這是你的金鑰", color = BearTheme.cream) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        p,
                        color = BearTheme.honeyLight, fontSize = 13.sp, fontFamily = FontFamily.Monospace,
                        modifier = Modifier
                            .background(BearTheme.bg, RoundedCornerShape(8.dp))
                            .padding(10.dp),
                    )
                    Text(
                        "離開這個視窗就再也看不到了——現在複製起來。",
                        color = BearTheme.amberText, fontSize = 12.sp,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    clipboard.setText(AnnotatedString(p)); vm.consumePlaintext()
                }) { Text("複製並關閉", color = BearTheme.honeyLight) }
            },
        )
    }
}
