package com.kerberosclaw.wherebear.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kerberosclaw.wherebear.core.AuthState
import com.kerberosclaw.wherebear.ui.components.PrimaryButton
import com.kerberosclaw.wherebear.ui.theme.BearTheme
import com.kerberosclaw.wherebear.vm.SessionViewModel

@Composable
fun AuthScreen(session: SessionViewModel) {
    val state by session.state.collectAsState()
    val lastError by session.lastError.collectAsState()
    val info by session.infoMessage.collectAsState()

    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var isSignUp by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BearTheme.bg)
            .padding(horizontal = 28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("熊熊在哪裡", color = BearTheme.cream, fontSize = 34.sp, fontWeight = FontWeight.ExtraBold)
        Text(
            "位置只會送到你自己的後端。",
            color = BearTheme.cream.copy(alpha = 0.6f),
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 6.dp, bottom = 28.dp),
        )

        if (state == AuthState.NEEDS_VERIFY) {
            Text(
                info ?: "請先驗證 email 再登入。",
                color = BearTheme.amberText,
                fontSize = 14.sp,
                modifier = Modifier.padding(bottom = 16.dp),
            )
            PrimaryButton("重寄驗證信") { session.resendVerification() }
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = { session.backToLogin() }) {
                Text("回登入", color = BearTheme.honeyLight)
            }
            return@Column
        }

        AuthField(email, { email = it }, "Email", KeyboardType.Email)
        Spacer(Modifier.height(12.dp))
        AuthField(password, { password = it }, "密碼", KeyboardType.Password, isPassword = true)

        lastError?.let {
            Text(it, color = BearTheme.salmonText, fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp))
        }
        info?.let {
            Text(it, color = BearTheme.greenText, fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp))
        }

        Spacer(Modifier.height(20.dp))
        PrimaryButton(if (isSignUp) "註冊" else "登入", enabled = email.isNotBlank() && password.length >= 6) {
            if (isSignUp) session.signUp(email.trim(), password) else session.signIn(email.trim(), password)
        }

        TextButton(onClick = { isSignUp = !isSignUp; session.clearMessages() }) {
            Text(if (isSignUp) "已經有帳號了，去登入" else "還沒有帳號，去註冊", color = BearTheme.honeyLight, fontSize = 13.sp)
        }
        if (!isSignUp) {
            TextButton(onClick = { if (email.isNotBlank()) session.resetPassword(email.trim()) }) {
                Text("忘記密碼", color = BearTheme.cream.copy(alpha = 0.55f), fontSize = 12.5.sp)
            }
        }
    }
}

@Composable
private fun AuthField(
    value: String,
    onChange: (String) -> Unit,
    label: String,
    keyboard: KeyboardType,
    isPassword: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label, color = BearTheme.cream.copy(alpha = 0.55f)) },
        singleLine = true,
        shape = RoundedCornerShape(12.dp),
        visualTransformation = if (isPassword) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard, imeAction = ImeAction.Next),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = BearTheme.cream,
            unfocusedTextColor = BearTheme.cream,
            focusedBorderColor = BearTheme.honey,
            unfocusedBorderColor = BearTheme.cream.copy(alpha = 0.22f),
            cursorColor = BearTheme.honeyLight,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}
