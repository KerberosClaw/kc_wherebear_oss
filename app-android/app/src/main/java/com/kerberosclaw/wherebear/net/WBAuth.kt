package com.kerberosclaw.wherebear.net

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * 目前登入 session（token / user）——各邏輯物件共用。對應 iOS 的 WBAuth。
 *
 * iOS 把 refresh token 放 UserDefaults；Android 這裡放 EncryptedSharedPreferences
 * （檔案落地就加密，root/備份撈不到明文）。取不到 keystore 時退回一般 prefs，
 * 不讓「加密失敗」變成「登不進去」。
 */
object WBAuth {
    private const val PREFS_NAME = "wb_secure"
    private const val PLAIN_PREFS = "wb_prefs"
    const val REFRESH_TOKEN_KEY = "wb_refresh_token"

    @Volatile var accessToken: String? = null
    @Volatile var userId: String? = null
    @Volatile var email: String? = null

    private lateinit var securePrefs: SharedPreferences
    lateinit var prefs: SharedPreferences   // 非機密設定（回報開關、頻率、outbox）

    fun init(context: Context) {
        val app = context.applicationContext
        prefs = app.getSharedPreferences(PLAIN_PREFS, Context.MODE_PRIVATE)
        securePrefs = try {
            val key = MasterKey.Builder(app).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            EncryptedSharedPreferences.create(
                app, PREFS_NAME, key,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        } catch (e: Exception) {
            app.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    var refreshToken: String?
        get() = securePrefs.getString(REFRESH_TOKEN_KEY, null)?.takeIf { it.isNotEmpty() }
        set(value) {
            securePrefs.edit().apply {
                if (value.isNullOrEmpty()) remove(REFRESH_TOKEN_KEY) else putString(REFRESH_TOKEN_KEY, value)
            }.apply()
        }

    fun clear() {
        accessToken = null; userId = null; email = null
        refreshToken = null
    }
}
