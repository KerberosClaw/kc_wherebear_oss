package com.kerberosclaw.wherebear.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.kerberosclaw.wherebear.core.AuthState
import com.kerberosclaw.wherebear.net.SignInResult
import com.kerberosclaw.wherebear.net.WBAuth
import com.kerberosclaw.wherebear.net.WBClient
import com.kerberosclaw.wherebear.net.WBError
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** 對應 iOS 的 SupabaseSession */
class SessionViewModel : ViewModel() {

    private val _state = MutableStateFlow(AuthState.RESTORING)   // 啟動先判斷續登，別閃登入頁
    val state: StateFlow<AuthState> = _state.asStateFlow()

    private val _userEmail = MutableStateFlow<String?>(null)
    val userEmail: StateFlow<String?> = _userEmail.asStateFlow()

    private val _emailVerified = MutableStateFlow(false)
    val emailVerified: StateFlow<Boolean> = _emailVerified.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    private val _infoMessage = MutableStateFlow<String?>(null)
    val infoMessage: StateFlow<String?> = _infoMessage.asStateFlow()

    private var pendingEmail: String? = null

    init { viewModelScope.launch { restore() } }

    suspend fun restore() {
        val rt = WBAuth.refreshToken
        if (rt.isNullOrEmpty()) { _state.value = AuthState.LOGGED_OUT; return }
        try {
            apply(WBClient.refresh(rt))
        } catch (e: Exception) {
            WBAuth.refreshToken = null
            _state.value = AuthState.LOGGED_OUT
        }
    }

    private fun apply(r: SignInResult) {
        WBAuth.accessToken = r.token
        WBAuth.userId = r.userId
        WBAuth.email = r.email
        _userEmail.value = r.email
        _emailVerified.value = r.confirmed
        if (r.refreshToken.isNotEmpty()) WBAuth.refreshToken = r.refreshToken
        _state.value = AuthState.LOGGED_IN
    }

    fun signUp(email: String, password: String) = viewModelScope.launch {
        _lastError.value = null; _infoMessage.value = null
        try {
            WBClient.signUp(email, password)
            pendingEmail = email
            _infoMessage.value = "驗證信已寄出，去收信點連結後回來登入。"
            _state.value = AuthState.NEEDS_VERIFY
        } catch (e: Exception) {
            _lastError.value = "註冊失敗，請確認 email／密碼。"
        }
    }

    fun signIn(email: String, password: String) = viewModelScope.launch {
        _lastError.value = null; _infoMessage.value = null
        try {
            apply(WBClient.signIn(email, password))
        } catch (e: WBError.EmailNotConfirmed) {
            pendingEmail = email
            _state.value = AuthState.NEEDS_VERIFY
            _infoMessage.value = "請先驗證 email 再登入。"
        } catch (e: WBError.BadCredentials) {
            _lastError.value = "帳號或密碼錯誤。"
        } catch (e: Exception) {
            _lastError.value = "連不到伺服器，檢查網路或 dev 連線。"   // 離線/timeout → 不誤報帳密錯
        }
    }

    fun resendVerification() = viewModelScope.launch {
        val e = pendingEmail ?: _userEmail.value ?: return@launch
        runCatching { WBClient.resend(e) }
        _infoMessage.value = "驗證信已重寄。"
    }

    fun resetPassword(email: String) = viewModelScope.launch {
        try {
            WBClient.recover(email)
            _infoMessage.value = "重設信已寄出，去收信改密碼。"
        } catch (e: Exception) {
            _lastError.value = "寄送失敗。"
        }
    }

    fun changePassword() = viewModelScope.launch {
        val e = _userEmail.value ?: return@launch
        runCatching { WBClient.recover(e) }
        _infoMessage.value = "已寄出改密碼信。"
    }

    fun backToLogin() { _state.value = AuthState.LOGGED_OUT }

    fun signOut() = viewModelScope.launch {
        runCatching { WBClient.signOut() }
        WBAuth.clear()
        _userEmail.value = null
        _emailVerified.value = false
        _state.value = AuthState.LOGGED_OUT
    }

    fun clearMessages() { _lastError.value = null; _infoMessage.value = null }
}
