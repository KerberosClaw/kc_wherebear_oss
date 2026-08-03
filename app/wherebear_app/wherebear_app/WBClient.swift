// WBClient.swift — 精簡 Supabase client（URLSession，無外部依賴 → build 穩）。
// A 平面（owner）：GoTrue auth + PostgREST（anon apikey + Bearer JWT）+ Storage。
// dev/prod 端點走 Config。
import Foundation

// 目前登入 session（token / user）——各邏輯物件共用。
@MainActor final class WBAuth {
    static let shared = WBAuth()
    // 續登用 refresh token 的 UserDefaults key —— SupabaseSession 續登 + WBClient 自動續期共用（勿分歧）。
    static let refreshTokenKey = "wb_refresh_token"
    var accessToken: String?
    var userId: String?
    var email: String?
    func clear() { accessToken = nil; userId = nil; email = nil }
}

enum WBError: Error { case http(Int, String), emailNotConfirmed, badCredentials, decode }

@MainActor enum WBClient {
    private static var base: URL { Config.supabaseURL }

    // 短 timeout：離線/連不到 dev 時 12s 內快速失敗，不卡預設 60s（登入/續登不再卡死）
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    // test seam：可注入 URLSession（正式＝nil，用上面 12s-timeout session；測試塞帶 MockURLProtocol 的 session）。
    static var sessionOverride: URLSession?
    private static var activeSession: URLSession { sessionOverride ?? session }
    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await activeSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw WBError.decode }
        return (data, http)
    }

    // access token 過期自動續期（jwt_exp=3600 → 前景/背景 resume 超過 1 小時 access token 就死）。
    // 用存下的 refresh token 換新、寫回 WBAuth + UserDefaults。多筆請求同時撞 401 時 coalesce
    // 成單一 refresh（避免並發 refresh 撞 rotation reuse 而整個 session 被撤）。
    private static var refreshTask: Task<Bool, Never>?
    static func tryRefresh() async -> Bool {
        if let t = refreshTask { return await t.value }
        let task = Task { () -> Bool in
            guard let rt = UserDefaults.standard.string(forKey: WBAuth.refreshTokenKey), !rt.isEmpty else { return false }
            do {
                let r = try await refresh(refreshToken: rt)
                WBAuth.shared.accessToken = r.token
                WBAuth.shared.userId = r.userId
                if WBAuth.shared.email == nil { WBAuth.shared.email = r.email }
                if !r.refreshToken.isEmpty { UserDefaults.standard.set(r.refreshToken, forKey: WBAuth.refreshTokenKey) }
                return true
            } catch { return false }
        }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    // 送出帶 JWT 的請求；遇 401（access token 過期）→ 續期後用最新 token 重建請求、重試一次。
    // makeRequest 於呼叫當下讀 WBAuth.shared.accessToken → 重試自然帶到新 token。
    private static func sendAuthed(_ makeRequest: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var (data, http) = try await send(makeRequest())
        if http.statusCode == 401, await tryRefresh() {
            (data, http) = try await send(makeRequest())
        }
        return (data, http)
    }

    private static func base(_ path: String, method: String, json: Bool = true) -> URLRequest {
        var r = URLRequest(url: base.appending(path: path))
        r.httpMethod = method
        r.setValue(Config.anonKey, forHTTPHeaderField: "apikey")
        if let t = WBAuth.shared.accessToken { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if json { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    // MARK: - Auth
    static func signUp(email: String, password: String) async throws {
        var r = base("/auth/v1/signup", method: "POST")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, http) = try await send(r)
        if http.statusCode >= 400 { throw WBError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
    }

    struct SignInResult { let token: String; let refreshToken: String; let userId: String; let email: String?; let confirmed: Bool }

    static func signIn(email: String, password: String) async throws -> SignInResult {
        var r = base("/auth/v1/token", method: "POST")
        r.url = base.appending(path: "/auth/v1/token").appending(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        r.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, http) = try await send(r)
        let j = data.jsonObject
        if http.statusCode >= 400 {
            let code = (j["error_code"] as? String) ?? (j["error"] as? String) ?? ""
            let msg = (j["msg"] as? String) ?? (j["error_description"] as? String) ?? ""
            if code.contains("not_confirmed") || msg.lowercased().contains("not confirmed") { throw WBError.emailNotConfirmed }
            throw WBError.badCredentials
        }
        return try parseToken(j)
    }

    // exchange a stored refresh_token for a fresh session (app relaunch → keep login)
    static func refresh(refreshToken: String) async throws -> SignInResult {
        var r = base("/auth/v1/token", method: "POST")
        r.url = base.appending(path: "/auth/v1/token").appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        r.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let (data, http) = try await send(r)
        if http.statusCode >= 400 { throw WBError.badCredentials }
        return try parseToken(data.jsonObject)
    }

    private static func parseToken(_ j: [String: Any]) throws -> SignInResult {
        guard let token = j["access_token"] as? String,
              let user = j["user"] as? [String: Any],
              let uid = user["id"] as? String else { throw WBError.decode }
        let confirmed = (user["email_confirmed_at"] as? String) != nil || (user["confirmed_at"] as? String) != nil
        return SignInResult(token: token, refreshToken: (j["refresh_token"] as? String) ?? "",
                            userId: uid, email: user["email"] as? String, confirmed: confirmed)
    }

    static func signOut() async {
        guard WBAuth.shared.accessToken != nil else { return }
        _ = try? await send(base("/auth/v1/logout", method: "POST"))
    }

    static func recover(email: String) async throws {
        var r = base("/auth/v1/recover", method: "POST")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
        _ = try await send(r)
    }

    static func resend(email: String) async throws {
        var r = base("/auth/v1/resend", method: "POST")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "type": "signup"])
        _ = try await send(r)
    }

    // MARK: - PostgREST
    @discardableResult
    static func rest(_ method: String, table: String, query: [URLQueryItem] = [], body: Any? = nil, prefer: String? = nil) async throws -> Data {
        var url = base.appending(path: "/rest/v1/\(table)")
        if !query.isEmpty { url = url.appending(queryItems: query) }
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, http) = try await sendAuthed {
            var r = URLRequest(url: url)
            r.httpMethod = method
            r.setValue(Config.anonKey, forHTTPHeaderField: "apikey")
            if let t = WBAuth.shared.accessToken { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let prefer { r.setValue(prefer, forHTTPHeaderField: "Prefer") }
            r.httpBody = bodyData
            return r
        }
        if http.statusCode >= 400 { throw WBError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    // Edge Function（owner 平面）：apikey + Bearer JWT 由 base() 帶上 → 平台驗 JWT
    static func function(_ name: String, body: [String: Any]) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await sendAuthed {
            var r = base("/functions/v1/\(name)", method: "POST")
            r.httpBody = bodyData
            return r
        }
        if http.statusCode >= 400 { throw WBError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    static func rpc(_ fn: String, params: [String: Any] = [:]) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: params)
        let (data, http) = try await sendAuthed {
            var r = base("/rest/v1/rpc/\(fn)", method: "POST")
            r.httpBody = bodyData
            return r
        }
        if http.statusCode >= 400 { throw WBError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    // MARK: - Storage (avatars public bucket)
    static func uploadAvatar(_ jpeg: Data, uid: String) async throws {
        let (d, http) = try await sendAuthed {   // 走 sendAuthed → 繼承 401→refresh→retry（token 過期時頭貼上傳不再直接失敗）
            var r = base("/storage/v1/object/avatars/\(uid)/avatar.jpg", method: "POST", json: false)
            r.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            r.setValue("true", forHTTPHeaderField: "x-upsert")
            r.httpBody = jpeg
            return r
        }
        if http.statusCode >= 400 { throw WBError.http(http.statusCode, String(data: d, encoding: .utf8) ?? "") }
    }

    static func publicAvatarURL(uid: String) -> URL {
        base.appending(path: "/storage/v1/object/public/avatars/\(uid)/avatar.jpg")
    }

    // 抓 public 物件 bytes（走同一 12s-timeout session）→ 頭貼本地快取用
    static func data(from url: URL) async throws -> Data {
        let (data, http) = try await send(URLRequest(url: url))
        if http.statusCode >= 400 { throw WBError.http(http.statusCode, "") }
        return data
    }
}

// MARK: - JSON helpers
extension Data {
    var jsonArray: [[String: Any]] { (try? JSONSerialization.jsonObject(with: self)) as? [[String: Any]] ?? [] }
    var jsonObject: [String: Any] { (try? JSONSerialization.jsonObject(with: self)) as? [String: Any] ?? [:] }
    var jsonScalarString: String? { (try? JSONSerialization.jsonObject(with: self)) as? String }
}

// ISO8601 (with/without fractional seconds) → Date
// 診斷紀錄的時間一律用**裝置系統時區**顯示。
//
// 🔴 那一頁是給人看的，跟「我幾點出門」對照時 UTC 要心算加減時差，最容易看錯的就是
//    跨午夜那幾筆。上傳到後端的仍然是 UTC ISO —— 線上格式不變，只有顯示改。
//    用 autoupdatingCurrent：出國換時區、或系統時區被改，下一次寫入就自動跟著變。
enum WBLogTime {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        f.timeZone = .autoupdatingCurrent
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }
    static func text(_ d: Date) -> String { formatter().string(from: d) }
    /// 拿線上格式的 ISO 字串轉成當地時間顯示；解不出來就原樣回傳（不吞掉資訊）
    static func text(iso s: String?) -> String {
        guard let s else { return "?" }
        guard let d = WBDate.parse(s) else { return s }
        return text(d)
    }
}

enum WBDate {
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
    static func today(tz: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz) ?? .current
        let now = Date()
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
