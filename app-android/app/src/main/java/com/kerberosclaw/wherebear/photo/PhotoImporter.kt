package com.kerberosclaw.wherebear.photo

import android.app.Application
import android.content.ContentUris
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.kerberosclaw.wherebear.core.WBTime
import com.kerberosclaw.wherebear.net.WBAuth
import com.kerberosclaw.wherebear.net.WBClient
import com.kerberosclaw.wherebear.net.WBError
import com.kerberosclaw.wherebear.net.asJsonArray
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate

/**
 * 相簿匯入（對應 iOS 的 PhotoImporter）。
 * 只讀 EXIF 的座標與時間、不讀像素本身。
 *
 * Android 特有的坑：Android 10 起 MediaStore 預設把照片的位置資訊「洗掉」再給你，
 * 要拿到真的座標必須 (1) 宣告並取得 ACCESS_MEDIA_LOCATION、
 * (2) 用 MediaStore.setRequireOriginal(uri) 取原始檔。少任何一步就是全部沒座標、
 * 而且不會報錯——只會安靜地掃出 0 張，很難查。
 */
class PhotoImporter(app: Application) : AndroidViewModel(app) {

    private val _progress = MutableStateFlow(0.0)
    val progress: StateFlow<Double> = _progress.asStateFlow()

    private val _scannedCount = MutableStateFlow<Int?>(null)
    val scannedCount: StateFlow<Int?> = _scannedCount.asStateFlow()

    private val _result = MutableStateFlow<ImportResult?>(null)
    val result: StateFlow<ImportResult?> = _result.asStateFlow()

    private var pending: List<Point> = emptyList()

    data class Point(val lat: Double, val lng: Double, val takenAt: Instant)

    /** inserted＝真的寫入；total-inserted＝重複略過；failed＝連不到伺服器、中途中止 */
    data class ImportResult(val inserted: Int, val total: Int, val failed: Boolean = false)

    fun scan(from: LocalDate, to: LocalDate) = viewModelScope.launch {
        _progress.value = 0.0
        _scannedCount.value = null
        val found = withContext(Dispatchers.IO) { scanBlocking(from, to) }
        pending = found
        _scannedCount.value = found.size
    }

    private fun scanBlocking(from: LocalDate, to: LocalDate): List<Point> {
        val resolver = getApplication<Application>().contentResolver
        val (startI, _) = WBTime.dayBounds(from)
        val (_, endI) = WBTime.dayBounds(to)

        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DATE_TAKEN)
        val selection = "${MediaStore.Images.Media.DATE_TAKEN} >= ? AND ${MediaStore.Images.Media.DATE_TAKEN} <= ?"
        val args = arrayOf(startI.toEpochMilli().toString(), endI.toEpochMilli().toString())

        val out = mutableListOf<Point>()
        resolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, selection, args,
            "${MediaStore.Images.Media.DATE_TAKEN} ASC",
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val dateCol = c.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)
            while (c.moveToNext()) {
                val id = c.getLong(idCol)
                val taken = c.getLong(dateCol)
                var uri: Uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    uri = MediaStore.setRequireOriginal(uri)   // 🔴 沒這行就拿不到座標
                }
                val latLng = runCatching {
                    resolver.openInputStream(uri)?.use { stream ->
                        ExifInterface(stream).latLong   // FloatArray? = [lat, lng]
                    }
                }.getOrNull() ?: continue
                out.add(Point(latLng[0].toDouble(), latLng[1].toDouble(), Instant.ofEpochMilli(taken)))
            }
        }
        return out
    }

    fun importPoints() = viewModelScope.launch {
        val items = pending
        _progress.value = 0.0
        val uid = WBAuth.userId
        if (uid == null || items.isEmpty()) {
            pending = emptyList()
            _result.value = ImportResult(0, 0)
            return@launch
        }
        var inserted = 0
        var done = 0
        for (p in items) {
            val body = JSONObject(
                mapOf(
                    "user_id" to uid, "lat" to p.lat, "lng" to p.lng,
                    "accuracy" to 0.0,
                    "captured_at" to WBTime.isoSeconds(p.takenAt),
                    "source" to "photo_import",
                )
            )
            try {
                // ignore-duplicates → 重複略過；return=representation → 有回 body 代表真的寫入
                val data = WBClient.rest(
                    "POST", "location_history",
                    query = listOf("on_conflict" to "user_id,source,captured_at,lat,lng"),
                    body = body, prefer = "resolution=ignore-duplicates,return=representation",
                )
                if (data.asJsonArray().isNotEmpty()) inserted += 1
            } catch (e: WBError.Network) {
                // 連不到伺服器 → 立刻中止，別讓每點各 12s timeout 累加卡爆；已寫入的保留
                pending = emptyList()
                _result.value = ImportResult(inserted, items.size, failed = true)
                return@launch
            } catch (e: Exception) {
                // 其他錯（單點被拒等）→ 跳過該點續跑
            }
            done += 1
            _progress.value = done.toDouble() / items.size
        }
        pending = emptyList()
        _result.value = ImportResult(inserted, items.size)
    }

    fun clearResult() { _result.value = null; _scannedCount.value = null }
}
