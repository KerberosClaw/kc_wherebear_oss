package com.kerberosclaw.wherebear.net

import com.kerberosclaw.wherebear.core.Config
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

sealed class WBError(message: String? = null) : Exception(message) {
    class Http(val code: Int, val body: String) : WBError("HTTP $code: $body")
    object EmailNotConfirmed : WBError("email not confirmed")
    object BadCredentials : WBError("bad credentials")
    object Decode : WBError("decode")
    class Network(cause: Throwable) : WBError(cause.message)
}

data class SignInResult(
    val token: String,
    val refreshToken: String,
    val userId: String,
    val email: String?,
    val confirmed: Boolean,
)

/**
 * 精簡 Supabase client（OkHttp，不用 Supabase SDK → 行為可控、依賴少）。
 * A 平面（owner）：GoTrue auth + PostgREST（anon apikey + Bearer JWT）+ RPC + Storage。
 * 逐條對應 iOS 的 WBClient.swift。
 */
object WBClient {
    private val JSON = "application/json".toMediaType()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // 短 timeout：離線 / 連不到 dev 時 12s 內快速失敗，不卡預設 60s
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(12, TimeUnit.SECONDS)
        .callTimeout(20, TimeUnit.SECONDS)
        .retryOnConnectionFailure(false)
        .build()

    /** test seam：測試可注入自己的 client */
    @Volatile var clientOverride: OkHttpClient? = null
    private val active: OkHttpClient get() = clientOverride ?: client

    private fun url(path: String, query: List<Pair<String, String>> = emptyList()): okhttp3.HttpUrl {
        val b = (Config.supabaseUrl + path).toHttpUrl().newBuilder()
        query.forEach { (k, v) -> b.addQueryParameter(k, v) }
        return b.build()
    }

    private fun Request.Builder.commonHeaders(json: Boolean = true): Request.Builder {
        header("apikey", Config.anonKey)
        WBAuth.accessToken?.let { header("Authorization", "Bearer $it") }
        if (json) header("Content-Type", "application/json")
        return this
    }

    private suspend fun send(request: Request): Pair<String, Int> = withContext(Dispatchers.IO) {
        try {
            active.newCall(request).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                body to resp.code
            }
        } catch (e: IOException) {
            throw WBError.Network(e)
        }
    }

    // access token 過期自動續期（jwt_exp=3600）。多筆請求同時撞 401 時 coalesce 成單一 refresh，
    // 避免並發 refresh 撞 rotation reuse 而整個 session 被撤（與 iOS 同一個坑）。
    private val refreshMutex = Mutex()
    private var refreshJob: Deferred<Boolean>? = null

    suspend fun tryRefresh(): Boolean {
        val existing = refreshMutex.withLock { refreshJob }
        if (existing != null) return existing.await()
        val job = refreshMutex.withLock {
            refreshJob ?: scope.async {
                val rt = WBAuth.refreshToken ?: return@async false
                try {
                    val r = refresh(rt)
                    WBAuth.accessToken = r.token
                    WBAuth.userId = r.userId
                    if (WBAuth.email == null) WBAuth.email = r.email
                    if (r.refreshToken.isNotEmpty()) WBAuth.refreshToken = r.refreshToken
                    true
                } catch (e: Exception) {
                    false
                }
            }.also { refreshJob = it }
        }
        val ok = job.await()
        refreshMutex.withLock { if (refreshJob === job) refreshJob = null }
        return ok
    }

    /** 送出帶 JWT 的請求；遇 401 → 續期後用最新 token 重建請求、重試一次 */
    private suspend fun sendAuthed(make: () -> Request): Pair<String, Int> {
        var (body, code) = send(make())
        if (code == 401 && tryRefresh()) {
            val retry = send(make())
            body = retry.first; code = retry.second
        }
        return body to code
    }

    // ---------------- Auth ----------------

    suspend fun signUp(email: String, password: String) {
        val req = Request.Builder().url(url("/auth/v1/signup")).commonHeaders()
            .post(JSONObject(mapOf("email" to email, "password" to password)).toString().toRequestBody(JSON))
            .build()
        val (body, code) = send(req)
        if (code >= 400) throw WBError.Http(code, body)
    }

    suspend fun signIn(email: String, password: String): SignInResult {
        val req = Request.Builder()
            .url(url("/auth/v1/token", listOf("grant_type" to "password")))
            .commonHeaders()
            .post(JSONObject(mapOf("email" to email, "password" to password)).toString().toRequestBody(JSON))
            .build()
        val (body, code) = send(req)
        val j = body.asJsonObject()
        if (code >= 400) {
            val errCode = j.optString("error_code", j.optString("error", ""))
            val msg = j.optString("msg", j.optString("error_description", ""))
            if (errCode.contains("not_confirmed") || msg.lowercase().contains("not confirmed")) {
                throw WBError.EmailNotConfirmed
            }
            throw WBError.BadCredentials
        }
        return parseToken(j)
    }

    suspend fun refresh(refreshToken: String): SignInResult {
        val req = Request.Builder()
            .url(url("/auth/v1/token", listOf("grant_type" to "refresh_token")))
            .commonHeaders()
            .post(JSONObject(mapOf("refresh_token" to refreshToken)).toString().toRequestBody(JSON))
            .build()
        val (body, code) = send(req)
        if (code >= 400) throw WBError.BadCredentials
        return parseToken(body.asJsonObject())
    }

    private fun parseToken(j: JSONObject): SignInResult {
        val token = j.optString("access_token").takeIf { it.isNotEmpty() } ?: throw WBError.Decode
        val user = j.optJSONObject("user") ?: throw WBError.Decode
        val uid = user.optString("id").takeIf { it.isNotEmpty() } ?: throw WBError.Decode
        val confirmed = !user.isNull("email_confirmed_at") || !user.isNull("confirmed_at")
        return SignInResult(
            token = token,
            refreshToken = j.optString("refresh_token", ""),
            userId = uid,
            email = user.optString("email").takeIf { it.isNotEmpty() },
            confirmed = confirmed,
        )
    }

    suspend fun signOut() {
        if (WBAuth.accessToken == null) return
        runCatching {
            send(Request.Builder().url(url("/auth/v1/logout")).commonHeaders()
                .post(ByteArray(0).toRequestBody(JSON)).build())
        }
    }

    suspend fun recover(email: String) {
        runCatching {
            send(Request.Builder().url(url("/auth/v1/recover")).commonHeaders()
                .post(JSONObject(mapOf("email" to email)).toString().toRequestBody(JSON)).build())
        }.getOrThrow()
    }

    suspend fun resend(email: String) {
        runCatching {
            send(Request.Builder().url(url("/auth/v1/resend")).commonHeaders()
                .post(JSONObject(mapOf("email" to email, "type" to "signup")).toString().toRequestBody(JSON)).build())
        }.getOrThrow()
    }

    // ---------------- PostgREST ----------------

    suspend fun rest(
        method: String,
        table: String,
        query: List<Pair<String, String>> = emptyList(),
        body: Any? = null,
        prefer: String? = null,
    ): String {
        val payload: RequestBody? = when (body) {
            null -> if (method == "GET" || method == "DELETE") null else "{}".toRequestBody(JSON)
            is JSONObject, is JSONArray -> body.toString().toRequestBody(JSON)
            is Map<*, *> -> JSONObject(body as Map<*, *>).toString().toRequestBody(JSON)
            else -> body.toString().toRequestBody(JSON)
        }
        val (respBody, code) = sendAuthed {
            Request.Builder().url(url("/rest/v1/$table", query)).commonHeaders()
                .apply { prefer?.let { header("Prefer", it) } }
                .method(method, payload)
                .build()
        }
        if (code >= 400) throw WBError.Http(code, respBody)
        return respBody
    }

    suspend fun rpc(fn: String, params: Map<String, Any?> = emptyMap()): String {
        val (body, code) = sendAuthed {
            Request.Builder().url(url("/rest/v1/rpc/$fn")).commonHeaders()
                .post(JSONObject(params).toString().toRequestBody(JSON)).build()
        }
        if (code >= 400) throw WBError.Http(code, body)
        return body
    }

    /** Edge Function（owner 平面）：apikey + Bearer JWT 由 commonHeaders 帶上 */
    suspend fun function(name: String, body: Map<String, Any?>): String {
        val (resp, code) = sendAuthed {
            Request.Builder().url(url("/functions/v1/$name")).commonHeaders()
                .post(JSONObject(body).toString().toRequestBody(JSON)).build()
        }
        if (code >= 400) throw WBError.Http(code, resp)
        return resp
    }

    // ---------------- Storage（avatars public bucket） ----------------

    suspend fun uploadAvatar(jpeg: ByteArray, uid: String) {
        val (body, code) = sendAuthed {
            Request.Builder().url(url("/storage/v1/object/avatars/$uid/avatar.jpg"))
                .commonHeaders(json = false)
                .header("Content-Type", "image/jpeg")
                .header("x-upsert", "true")
                .post(jpeg.toRequestBody("image/jpeg".toMediaType()))
                .build()
        }
        if (code >= 400) throw WBError.Http(code, body)
    }

    fun publicAvatarUrl(uid: String): String =
        "${Config.supabaseUrl}/storage/v1/object/public/avatars/$uid/avatar.jpg"

    suspend fun bytes(rawUrl: String): ByteArray = withContext(Dispatchers.IO) {
        try {
            active.newCall(Request.Builder().url(rawUrl).build()).execute().use { resp ->
                if (resp.code >= 400) throw WBError.Http(resp.code, "")
                resp.body?.bytes() ?: ByteArray(0)
            }
        } catch (e: IOException) {
            throw WBError.Network(e)
        }
    }
}

// ---------------- JSON helpers（對應 iOS 的 Data extension） ----------------

fun String.asJsonObject(): JSONObject = runCatching { JSONObject(this) }.getOrElse { JSONObject() }

fun String.asJsonArray(): List<JSONObject> = runCatching {
    val arr = JSONArray(this)
    (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
}.getOrElse { emptyList() }

/** RPC 回傳純量字串（如 my_resolve_alias 回 "家"），非 JSON 物件 */
fun String.asJsonScalarString(): String? = runCatching {
    val trimmed = trim()
    if (trimmed.startsWith("\"") && trimmed.endsWith("\"")) {
        JSONArray("[$trimmed]").optString(0).takeIf { it.isNotEmpty() }
    } else null
}.getOrNull()

fun JSONObject.optDoubleOrNull(key: String): Double? = if (isNull(key)) null else optDouble(key)
fun JSONObject.optStringOrNull(key: String): String? =
    if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }
