package com.kerberosclaw.wherebear.vm

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.kerberosclaw.wherebear.core.ApiKeyInfo
import com.kerberosclaw.wherebear.core.WBTime
import com.kerberosclaw.wherebear.net.WBAuth
import com.kerberosclaw.wherebear.net.WBClient
import com.kerberosclaw.wherebear.net.asJsonArray
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant

/**
 * 對應 iOS 的 ApiKeyManager。
 * 🔴 明文只在記憶體、顯示一次；DB 只存 sha256 + 尾 4 碼（契約 §1.4）。
 */
class ApiKeyViewModel : ViewModel() {

    private val _keys = MutableStateFlow<List<ApiKeyInfo>>(emptyList())
    val keys: StateFlow<List<ApiKeyInfo>> = _keys.asStateFlow()

    /** 剛產生的明文（顯示一次後由 UI 清掉） */
    private val _newPlaintext = MutableStateFlow<String?>(null)
    val newPlaintext: StateFlow<String?> = _newPlaintext.asStateFlow()

    fun load() = viewModelScope.launch {
        val uid = WBAuth.userId ?: return@launch
        runCatching {
            WBClient.rest(
                "GET", "api_keys",
                query = listOf(
                    "select" to "id,name,key_last4,last_used_at,created_at",
                    "user_id" to "eq.$uid",
                    "revoked_at" to "is.null",
                    "order" to "created_at.desc",
                ),
            )
        }.onSuccess { data ->
            _keys.value = data.asJsonArray().map { r ->
                ApiKeyInfo(
                    id = r.opt("id").toString(),
                    name = r.optString("name"),
                    keyLast4 = r.optString("key_last4"),
                    lastUsedAt = if (r.isNull("last_used_at")) null else WBTime.parse(r.optString("last_used_at")),
                    createdAt = WBTime.parse(r.optString("created_at")) ?: Instant.now(),
                )
            }
        }
    }

    fun create(name: String) = viewModelScope.launch {
        val uid = WBAuth.userId ?: return@launch
        val plaintext = "wb_" + randomToken(32)
        val hash = sha256Hex(plaintext)
        val last4 = plaintext.takeLast(4)
        _newPlaintext.value = plaintext          // 顯示一次
        _keys.value = listOf(
            ApiKeyInfo("temp-$last4", name, last4, null, Instant.now())
        ) + _keys.value
        runCatching {
            WBClient.rest(
                "POST", "api_keys",
                body = JSONObject(
                    mapOf("user_id" to uid, "name" to name, "key_hash" to hash, "key_last4" to last4)
                ),
            )
        }
        load()
    }

    fun consumePlaintext() { _newPlaintext.value = null }

    fun revoke(id: String) = viewModelScope.launch {
        _keys.value = _keys.value.filterNot { it.id == id }
        runCatching {
            WBClient.rest(
                "PATCH", "api_keys",
                query = listOf("id" to "eq.$id"),
                body = JSONObject(mapOf("revoked_at" to WBTime.isoMillis(Instant.now()))),
            )
        }
    }

    companion object {
        private const val CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

        fun randomToken(n: Int): String {
            val rnd = SecureRandom()
            val bytes = ByteArray(n).also { rnd.nextBytes(it) }
            return bytes.map { CHARS[(it.toInt() and 0xFF) % CHARS.length] }.joinToString("")
        }

        fun sha256Hex(s: String): String =
            MessageDigest.getInstance("SHA-256").digest(s.toByteArray())
                .joinToString("") { "%02x".format(it) }
    }
}
