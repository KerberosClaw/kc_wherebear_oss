package com.kerberosclaw.wherebear.vm

import android.app.Application
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.kerberosclaw.wherebear.net.WBAuth
import com.kerberosclaw.wherebear.net.WBClient
import com.kerberosclaw.wherebear.net.asJsonArray
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.Instant

/**
 * 對應 iOS 的 ProfileManager。
 * 頭貼本地快取：app 一開先吃檔案 → 即時顯示、離線也在、不閃預設熊。
 * 跨裝置新鮮度靠 profile.updated_at 版本，無 TTL。
 */
class ProfileViewModel(app: Application) : AndroidViewModel(app) {

    private val _avatar = MutableStateFlow<Bitmap?>(null)
    val avatar: StateFlow<Bitmap?> = _avatar.asStateFlow()

    private val _displayName = MutableStateFlow<String?>(null)
    val displayName: StateFlow<String?> = _displayName.asStateFlow()

    private val localFile: File get() = File(getApplication<Application>().filesDir, "avatar.jpg")

    init {
        // 同步吃本地快取
        runCatching {
            if (localFile.exists()) _avatar.value = BitmapFactory.decodeFile(localFile.absolutePath)
        }
    }

    fun load() = viewModelScope.launch {
        val uid = WBAuth.userId ?: return@launch
        val row = runCatching {
            WBClient.rest(
                "GET", "profile",
                query = listOf("select" to "display_name,avatar_path,updated_at", "user_id" to "eq.$uid"),
            ).asJsonArray().firstOrNull()
        }.getOrNull() ?: return@launch

        _displayName.value = row.optString("display_name").takeIf { it.isNotEmpty() && it != "null" }
        if (row.isNull("avatar_path")) return@launch   // 沒頭貼就到此為止（暱稱已讀）

        val version = "$uid|${row.optString("updated_at")}"
        if (WBAuth.prefs.getString(VERSION_KEY, null) == version && _avatar.value != null) return@launch

        runCatching { WBClient.bytes(WBClient.publicAvatarUrl(uid)) }.onSuccess { bytes ->
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@onSuccess
            _avatar.value = bmp
            withContext(Dispatchers.IO) { localFile.writeBytes(bytes) }
            WBAuth.prefs.edit().putString(VERSION_KEY, version).apply()
        }
    }

    fun setAvatar(bitmap: Bitmap) = viewModelScope.launch {
        val uid = WBAuth.userId ?: return@launch
        _avatar.value = bitmap                            // 立刻反映到 UI
        val jpeg = withContext(Dispatchers.IO) {
            ByteArrayOutputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                out.toByteArray()
            }
        }
        withContext(Dispatchers.IO) { runCatching { localFile.writeBytes(jpeg) } }
        runCatching {
            WBClient.uploadAvatar(jpeg, uid)
            val now = com.kerberosclaw.wherebear.core.WBTime.isoMillis(Instant.now())
            WBClient.rest(
                "POST", "profile",
                body = JSONObject(mapOf("user_id" to uid, "avatar_path" to "$uid/avatar.jpg", "updated_at" to now)),
                prefer = "resolution=merge-duplicates",
            )
            WBAuth.prefs.edit().putString(VERSION_KEY, "$uid|$now").apply()
        }
    }

    /** 留空＝清除暱稱（存空字串，UI 依 displayName 為 null fallback email） */
    fun setDisplayName(name: String) = viewModelScope.launch {
        val uid = WBAuth.userId ?: return@launch
        val trimmed = name.trim()
        _displayName.value = trimmed.takeIf { it.isNotEmpty() }
        runCatching {
            WBClient.rest(
                "POST", "profile",
                body = JSONObject(mapOf("user_id" to uid, "display_name" to trimmed)),
                prefer = "resolution=merge-duplicates",
            )
        }
    }

    companion object { private const val VERSION_KEY = "wb_avatar_version" }
}
