// Logic.swift — 正式邏輯層（取代 PreviewMocks 的 7 個 @Observable，介面完全一致 → UI 零改）。
// mutating 方法保 sync 簽名，內部 fire async Task + 樂觀更新；讀取 async 載入後更新 @Observable → UI 反應式刷新。
import SwiftUI
import CoreLocation
import Photos
import CryptoKit
import Security
import UIKit

// MARK: - SupabaseSession
@Observable @MainActor final class SupabaseSession {
    var state: AuthState = .restoring // 啟動先判斷續登，別閃登入頁
    var userEmail: String?
    var emailVerified = false
    var lastError: String?
    var infoMessage: String?
    @ObservationIgnored private var pendingEmail: String?
    @ObservationIgnored private let refreshKey = WBAuth.refreshTokenKey   // WBClient 自動續期共用同一 key

    init() { Task { await restore() } } // app 啟動：用存下的 refresh_token 續登

    func restore() async {
        guard let rt = UserDefaults.standard.string(forKey: refreshKey), !rt.isEmpty else { state = .loggedOut; return }
        do { apply(try await WBClient.refresh(refreshToken: rt)) }
        catch { UserDefaults.standard.removeObject(forKey: refreshKey); state = .loggedOut }
    }

    private func apply(_ r: WBClient.SignInResult) {
        WBAuth.shared.accessToken = r.token
        WBAuth.shared.userId = r.userId
        WBAuth.shared.email = r.email
        userEmail = r.email
        emailVerified = r.confirmed
        if !r.refreshToken.isEmpty { UserDefaults.standard.set(r.refreshToken, forKey: refreshKey) }
        state = .loggedIn
    }

    func signUp(email: String, password: String) async {
        lastError = nil; infoMessage = nil
        do {
            try await WBClient.signUp(email: email, password: password)
            pendingEmail = email
            infoMessage = "驗證信已寄出，去收信點連結後回來登入。"
            state = .needsVerify
        } catch { lastError = "註冊失敗，請確認 email／密碼。" }
    }

    func signIn(email: String, password: String) async {
        lastError = nil; infoMessage = nil
        do {
            apply(try await WBClient.signIn(email: email, password: password))
        } catch WBError.emailNotConfirmed {
            pendingEmail = email; state = .needsVerify
            infoMessage = "請先驗證 email 再登入。"
        } catch WBError.badCredentials {
            lastError = "帳號或密碼錯誤。"
        } catch {
            lastError = "連不到伺服器，檢查網路或 dev 連線。"   // URLError（離線/timeout）→ 不誤報帳密錯
        }
    }

    func resendVerification() {
        guard let e = pendingEmail ?? userEmail else { return }
        Task { try? await WBClient.resend(email: e); infoMessage = "驗證信已重寄。" }
    }

    func resetPassword(email: String) async {
        do { try await WBClient.recover(email: email); infoMessage = "重設信已寄出，去收信改密碼。" }
        catch { lastError = "寄送失敗。" }
    }

    func changePassword() {
        guard let e = userEmail else { return }
        Task { try? await WBClient.recover(email: e); infoMessage = "已寄出改密碼信。" }
    }

    func signOut() {
        Task { await WBClient.signOut() }
        UserDefaults.standard.removeObject(forKey: refreshKey)
        WBAuth.shared.clear(); userEmail = nil; emailVerified = false; state = .loggedOut
    }
}

// MARK: - LocationReporter
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuth: ((CLAuthorizationStatus) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onHeading: ((CLHeading) -> Void)?
    var onVisit: ((CLVisit) -> Void)?
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { onAuth?(m.authorizationStatus) }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) { onLocations?(locs) }
    func locationManager(_ m: CLLocationManager, didUpdateHeading newHeading: CLHeading) { onHeading?(newHeading) }
    func locationManager(_ m: CLLocationManager, didVisit visit: CLVisit) { onVisit?(visit) }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { /* 一次性取位失敗：忽略、下輪再試（requestLocation 要求實作此法）*/ }
}

@Observable @MainActor final class LocationReporter {
    var isReporting = false
    var lastReportAt: Date?
    var permissionState: PermissionState = .notDetermined
    var connectivity: Connectivity = .online
    var frequency: ReportFrequency = .saver
    var lastLocation: CLLocation?          // 即時位置（poll/significant/prime 觸發即更新）→ 座標卡/跟隨相機用，不必等 DB round-trip
    var heading: CLLocationDirection?      // 羅盤朝向（連續、低耗）→ 熊掌跟隨(羅盤)模式相機旋轉

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var delegate = LocationDelegate()
    @ObservationIgnored private let liveManager = CLLocationManager()   // 地圖可見期間的即時位置流（顯示用、與回報解耦）
    @ObservationIgnored private var liveDelegate = LocationDelegate()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let outboxKey = "wb_outbox"   // 離線期間累積的 history 點；回線補送
    @ObservationIgnored private let outboxCap = 1000          // 上限、避免無限成長
    @ObservationIgnored private let visitOutboxKey = "wb_visit_outbox"  // 離線/連不到期間累積的 CLVisit 停留；回線補送（原本 try? 會靜默丟）
    @ObservationIgnored private let visitOutboxCap = 500

    init() {
        if UserDefaults.standard.string(forKey: "wb_frequency") == "standard" { frequency = .standard }
        manager.delegate = delegate
        manager.desiredAccuracy = (frequency == .saver) ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters
        permissionState = LocationReporter.map(manager.authorizationStatus)
        outboxCount = loadOutbox().count       // 啟動時同步既有佇列筆數
        delegate.onAuth = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.permissionState = LocationReporter.map(status)
                if status == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
                self.configureBackgroundUpdates()           // 拿到 Always → 開背景更新
                if self.isReporting { self.requestOnce() } // 授權完成後補取一次
            }
        }
        delegate.onLocations = { [weak self] locs in
            guard let loc = locs.last else { return }
            Task { @MainActor in
                guard let self else { return }
                self.lastLocation = loc                        // 顯示用：一律更新即時位置
                if self.isReporting { await self.report(loc) } // 回報用：只有回報開著才寫 DB（primeLocation 取的點不寫）
            }
        }
        liveManager.delegate = liveDelegate
        liveManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        liveManager.distanceFilter = 10   // 濾掉 <10m 的 GPS 抖動：站著不動時座標卡/跟隨相機不亂跳、真的走 10m+ 才更新
        liveDelegate.onLocations = { [weak self] locs in            // 即時顯示流：只更新 lastLocation、絕不寫 DB（與回報 poll/significant 解耦）
            guard let loc = locs.last else { return }
            Task { @MainActor in self?.lastLocation = loc }
        }
        delegate.onHeading = { [weak self] h in
            Task { @MainActor in
                self?.heading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
            }
        }
        delegate.onVisit = { [weak self] v in
            Task { @MainActor in await self?.recordVisit(v) }
        }
    }

    // 只在「已授權」時取一次新位置 —— 未授權就呼叫 requestLocation 會出事（#1 crash 根因）
    private func requestOnce() {
        let s = manager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func start() {
        isReporting = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        configureBackgroundUpdates()
        manager.startMonitoringSignificantLocationChanges()  // 背景/終止後 iOS 仍可喚醒送點（需 Always + 背景能力）
        manager.startMonitoringVisits()                      // CLVisit：低耗電背景偵測靜止長停留（在家/公司不動）
        requestOnce()   // 已授權才取；未授權等 onAuth 再補
        startPolling()
    }

    // 背景低頻回報：只有拿到 Always 且 Info.plist 有 UIBackgroundModes=location 才可開，
    // 否則設 allowsBackgroundLocationUpdates=true 會直接 crash。前景 poll 進背景會被 iOS 暫停、
    // 退回 significant-change（省電、約 500m 位移才觸發）。
    private func configureBackgroundUpdates() {
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = false
        } else {
            manager.allowsBackgroundLocationUpdates = false
        }
    }
    func stop() {
        isReporting = false
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        pollTask?.cancel(); pollTask = nil
    }

    // 地圖畫面顯示用（與「回報開關」解耦）：進地圖 seed 一次即時位置 + 開羅盤，離開關羅盤。
    // primeLocation 走 requestOnce（已授權才取）；取回的點只更新 lastLocation、不寫 DB（見 onLocations 的 isReporting 判斷）。
    func primeLocation() { requestOnce() }
    func startHeadingUpdates() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 3   // 每 3° 才回一次 → 降低 view 重算頻率
        manager.startUpdatingHeading()
    }
    func stopHeadingUpdates() { manager.stopUpdatingHeading() }
    // 地圖可見期間的即時位置流：只刷新 lastLocation（座標卡/跟隨相機），絕不寫 DB、不碰回報密度/電量設計。
    // 前景限定（離開地圖即停）；已授權才開（避免非預期權限彈窗）。修：移動中熊掌動但座標卡不動（原本 lastLocation 只在 poll/significant/prime 更新）。
    func startLiveUpdates() {
        let s = liveManager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return }
        liveManager.startUpdatingLocation()
    }
    func stopLiveUpdates() { liveManager.stopUpdatingLocation() }

    // 回前景（scenePhase → active）：立刻取一次最新位置 + 有網就把離線佇列補送（不必等下一個 poll tick）
    func onEnterForeground() {
        requestOnce()
        if let uid = WBAuth.shared.userId { Task { await flushOutbox(uid: uid); await flushVisitOutbox() } }
    }
    func setFrequency(_ f: ReportFrequency) {
        frequency = f
        UserDefaults.standard.set(f == .saver ? "saver" : "standard", forKey: "wb_frequency") // #2 記住頻率
        manager.desiredAccuracy = (f == .saver) ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters
        if isReporting { startPolling() }
    }

    // 前景定時取樣：人沒動也持續回報 → DB 保鮮 + 停留段聚得出來。
    // 背景時 iOS 暫停此 Task、退回 significant-change（省電）。
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let secs = (self?.frequency == .saver) ? 180.0 : 60.0
                try? await Task.sleep(for: .seconds(secs))
                guard let self, self.isReporting, !Task.isCancelled else { break }
                self.requestOnce()
            }
        }
    }

    private func report(_ loc: CLLocation) async {
        guard let uid = WBAuth.shared.userId else { return }
        await flushOutbox(uid: uid)   // 先把離線期間累積的點一次補送（用戶要的「回線一口氣打上去」）
        await flushVisitOutbox()      // 停留佇列同樣補送
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let point: [String: Any] = ["lat": loc.coordinate.latitude, "lng": loc.coordinate.longitude,
                                    "accuracy": max(loc.horizontalAccuracy, 0), "captured_at": iso.string(from: loc.timestamp)]
        do {
            var cur = point; cur["user_id"] = uid
            try await WBClient.rest("POST", table: "current_location", body: cur, prefer: "resolution=merge-duplicates")
            var hist = point; hist["user_id"] = uid; hist["source"] = "live"
            try await WBClient.rest("POST", table: "location_history",
                query: [URLQueryItem(name: "on_conflict", value: "user_id,source,captured_at,lat,lng")],
                body: hist, prefer: "resolution=ignore-duplicates")
            lastReportAt = Date(); connectivity = .online
        } catch {
            enqueueOutbox(point)   // 失敗 → 存 raw 點（current 下次成功時自然更新到最新，不需另存）
            connectivity = .offline
        }
    }

    // CLVisit → visits 表：到達時 departureDate=distantFuture（departed_at 留 null）；離開時同 arrivalDate 再投遞一次帶 departed_at
    // → merge-duplicates 依 (user_id,arrived_at,lat,lng) upsert 更新 departed_at。失敗進 visit outbox 補送（durable、不再靜默丟）。
    private func recordVisit(_ visit: CLVisit) async {
        guard let uid = WBAuth.shared.userId, visit.arrivalDate != .distantPast else { return }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        var body: [String: Any] = ["user_id": uid,
                                   "lat": visit.coordinate.latitude, "lng": visit.coordinate.longitude,
                                   "arrived_at": iso.string(from: visit.arrivalDate)]
        if visit.departureDate != .distantFuture { body["departed_at"] = iso.string(from: visit.departureDate) }
        await submitVisit(body)
    }

    // 送出停留：成功→順帶補送先前積的；失敗（401 已由 WBClient 自動續期吸收；剩離線/連不到）→ 進 outbox 不再靜默丟。
    // internal：測試可直接餵 body、免造 CLVisit（CLVisit 無公開 init）。
    func submitVisit(_ body: [String: Any]) async {
        do {
            try await postVisit(body)
            await flushVisitOutbox()
        } catch {
            enqueueVisit(body)
        }
    }

    private func postVisit(_ body: [String: Any]) async throws {
        try await WBClient.rest("POST", table: "visits",
            query: [URLQueryItem(name: "on_conflict", value: "user_id,arrived_at,lat,lng")],
            body: body, prefer: "resolution=merge-duplicates")
    }

    // MARK: - Outbox（離線補送 history 點）
    private func loadOutbox() -> [[String: Any]] {
        guard let d = UserDefaults.standard.data(forKey: outboxKey),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr
    }
    private func saveOutbox(_ arr: [[String: Any]]) {
        outboxCount = arr.count   // 同步觀察式計數 → 設定列筆數即時（enqueue/flush 都經這）
        if arr.isEmpty { UserDefaults.standard.removeObject(forKey: outboxKey); return }
        if let d = try? JSONSerialization.data(withJSONObject: arr) { UserDefaults.standard.set(d, forKey: outboxKey) }
    }
    private func enqueueOutbox(_ point: [String: Any]) {
        var q = loadOutbox(); q.append(point)
        if q.count > outboxCap { q.removeFirst(q.count - outboxCap) }
        saveOutbox(q)
    }
    private func flushOutbox(uid: String) async {
        let q = loadOutbox()
        guard !q.isEmpty else { return }
        var remaining: [[String: Any]] = []
        for point in q {
            var hist = point; hist["user_id"] = uid; hist["source"] = "live"
            do {
                try await WBClient.rest("POST", table: "location_history",
                    query: [URLQueryItem(name: "on_conflict", value: "user_id,source,captured_at,lat,lng")],
                    body: hist, prefer: "resolution=ignore-duplicates")
            } catch { remaining.append(point) }  // 這輪仍失敗 → 留到下次
        }
        saveOutbox(remaining)
    }

    // 除錯用（設定頁「離線佇列」）：唯讀窺看目前佇列筆數與內容
    private(set) var outboxCount = 0   // 觀察式儲存屬性（非 computed）→ enqueue/flush 改動時設定列筆數即時刷新
    func outboxPeek() -> [(lat: Double, lng: Double, at: String)] {
        loadOutbox().compactMap { p in
            guard let la = p["lat"] as? Double, let lo = p["lng"] as? Double else { return nil }
            return (la, lo, (p["captured_at"] as? String) ?? "")
        }
    }

    // MARK: - Visit outbox（離線補送 CLVisit；merge-duplicates 冪等、原樣 replay 安全——實測缺 departed_at 不會洗掉既有值）
    private func loadVisitOutbox() -> [[String: Any]] {
        guard let d = UserDefaults.standard.data(forKey: visitOutboxKey),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr
    }
    private func saveVisitOutbox(_ arr: [[String: Any]]) {
        if arr.isEmpty { UserDefaults.standard.removeObject(forKey: visitOutboxKey); return }
        if let d = try? JSONSerialization.data(withJSONObject: arr) { UserDefaults.standard.set(d, forKey: visitOutboxKey) }
    }
    private func visitKey(_ b: [String: Any]) -> String {
        "\(b["arrived_at"] ?? "")|\(b["lat"] ?? "")|\(b["lng"] ?? "")"
    }
    private func enqueueVisit(_ body: [String: Any]) {
        var q = loadVisitOutbox()
        let key = visitKey(body)
        q.removeAll { visitKey($0) == key }   // 同一 visit（到達+離開兩段）只留最新那版（departure 覆蓋 arrival）
        q.append(body)
        if q.count > visitOutboxCap { q.removeFirst(q.count - visitOutboxCap) }
        saveVisitOutbox(q)
    }
    private func flushVisitOutbox() async {
        let q = loadVisitOutbox()
        guard !q.isEmpty else { return }
        var remaining: [[String: Any]] = []
        for body in q {
            do { try await postVisit(body) } catch { remaining.append(body) }
        }
        saveVisitOutbox(remaining)
    }
    // 測試/除錯用：目前 visit 佇列筆數
    func visitOutboxCount() -> Int { loadVisitOutbox().count }

    static func map(_ s: CLAuthorizationStatus) -> PermissionState {
        switch s {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        default: return .denied
        }
    }
}

// MARK: - LocationVM
@Observable @MainActor final class LocationVM {
    var current: CurrentLocation?
    var todayStays: [Stay] = []
    var livePoints: [CLLocationCoordinate2D] = []   // 選定單日的 live 移動點（連成軌跡線；多日不畫）
    var selectedDays: [Date] = []          // 空 ⇒ 今天；1 天 ⇒ 單日；>1 ⇒ 多日。狀態存 VM → 切 tab 再回來保留
    var isRange: Bool { selectedDays.count > 1 }
    @ObservationIgnored private var loadGeneration = 0   // 每次載入 +1 → geocode 回來前若又重載就放棄

    init() { Task { await refresh() } }

    // 時間軸選擇：狀態集中在 VM（selectedDays）→ 切到地圖／設定再回來不會被重置成今天。
    // 畫面直接設 selectedDays 再 await reloadStays()（才好接框景），故不另留 setter。
    func selectRange(from: Date, to: Date) { Task { await loadRange(from, to) } }

    // 依目前選擇重載停留（今天 / 單日 / 多日）
    func reloadStays() async {
        if selectedDays.isEmpty { await loadStays(Date()); await loadLivePoints(Date()) }
        else if selectedDays.count == 1 { await loadStays(selectedDays[0]); await loadLivePoints(selectedDays[0]) }
        else { await loadDays(selectedDays); livePoints = [] }   // 多日不畫 live 線（避免糊）
    }
    func refreshCurrent() async { await loadCurrent() }   // 地圖 tab：只刷新目前位置、不動時間軸選擇
    func refresh() async { await loadCurrent(); await reloadStays() }

    // 行事曆標記用：某範圍內「有記錄」的當地日（回 "yyyy-MM-dd" 集合，與月曆格子字串比對）
    func recordedDayKeys(from: Date, to: Date) async -> Set<String> {
        guard WBAuth.shared.userId != nil else { return [] }
        do {
            let data = try await WBClient.rpc("my_recorded_days",
                params: ["p_from": dayString(from), "p_to": dayString(to), "p_tz": Config.tz])
            return Set(data.jsonArray.compactMap { $0["day"] as? String })
        } catch { return [] }
    }

    private func loadCurrent() async {
        guard let uid = WBAuth.shared.userId else { return }
        do {
            let data = try await WBClient.rest("GET", table: "current_location",
                query: [URLQueryItem(name: "select", value: "lat,lng,accuracy,captured_at"),
                        URLQueryItem(name: "user_id", value: "eq.\(uid)")])
            guard let row = data.jsonArray.first,
                  let lat = row["lat"] as? Double, let lng = row["lng"] as? Double else { current = nil; return }
            let captured = WBDate.parse(row["captured_at"] as? String) ?? Date()
            let stale = Date().timeIntervalSince(captured) > Config.staleThresholdSeconds
            let nameData = try? await WBClient.rpc("my_resolve_alias", params: ["p_lat": lat, "p_lng": lng])
            current = CurrentLocation(coordinate: .init(latitude: lat, longitude: lng),
                accuracy: (row["accuracy"] as? Double) ?? 0, resolvedName: nameData?.jsonScalarString,
                capturedAt: captured, isStale: stale)
        } catch { }
    }

    private func loadStays(_ date: Date) async {
        guard WBAuth.shared.userId != nil else { return }
        do {
            let data = try await WBClient.rpc("my_today_stays", params: ["p_day": dayString(date), "p_tz": Config.tz])
            setStays(data)
        } catch { }
    }

    private func loadRange(_ from: Date, _ to: Date) async {
        guard WBAuth.shared.userId != nil else { return }
        do {
            let data = try await WBClient.rpc("my_stays_range", params: [
                "p_from": dayString(from), "p_to": dayString(to), "p_tz": Config.tz])
            setStays(data)
        } catch { }
    }

    private func loadDays(_ days: [Date]) async {
        guard WBAuth.shared.userId != nil, !days.isEmpty else { todayStays = []; return }
        let strs = days.map { dayString($0) }
        do {
            let data = try await WBClient.rpc("my_stays_days", params: ["p_days": strs, "p_tz": Config.tz])
            setStays(data)
        } catch { }
    }

    // live 軌跡線：撈某本地日的原始 live 點（依 captured_at 升冪）→ 直接連
    private func loadLivePoints(_ day: Date) async {
        guard let uid = WBAuth.shared.userId else { livePoints = []; return }
        let (start, end) = dayBounds(day)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        do {
            let data = try await WBClient.rest("GET", table: "location_history",
                query: [URLQueryItem(name: "select", value: "lat,lng,captured_at"),
                        URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                        URLQueryItem(name: "source", value: "eq.live"),
                        URLQueryItem(name: "captured_at", value: "gte.\(iso.string(from: start))"),
                        URLQueryItem(name: "captured_at", value: "lt.\(iso.string(from: end))"),
                        URLQueryItem(name: "order", value: "captured_at.asc"),
                        URLQueryItem(name: "limit", value: "2000")])
            livePoints = data.jsonArray.compactMap { r in
                guard let la = r["lat"] as? Double, let lo = r["lng"] as? Double else { return nil }
                return CLLocationCoordinate2D(latitude: la, longitude: lo)
            }
        } catch { livePoints = [] }
    }

    private func dayBounds(_ day: Date) -> (start: Date, end: Date) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: Config.tz) ?? .current
        let start = cal.startOfDay(for: day)
        return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    // 設定停留清單 + 觸發未命名點的反向地理編碼（#7）
    private func setStays(_ data: Data) {
        loadGeneration += 1
        let gen = loadGeneration
        todayStays = Self.dedupeVisits(data.jsonArray.map(Self.makeStay))
        Task { await geocodeUnnamed(gen: gen) }
    }

    // visit 停留（CLVisit，較準）與 detect_stays 聚出的 live 停留 時間重疊+位置<150m → 砍那個 live、留 visit
    private static func dedupeVisits(_ stays: [Stay]) -> [Stay] {
        let visits = stays.filter { $0.source == .visit }
        guard !visits.isEmpty else { return stays }
        return stays.filter { s in
            guard s.source == .live, let sc = s.coordinate else { return true }
            let dup = visits.contains { v in
                guard let vc = v.coordinate else { return false }
                let near = CLLocation(latitude: sc.latitude, longitude: sc.longitude)
                    .distance(from: CLLocation(latitude: vc.latitude, longitude: vc.longitude)) <= 150
                let overlap = s.from < (v.to ?? .distantFuture) && v.from < (s.to ?? .distantFuture)
                return near && overlap
            }
            return !dup
        }
    }

    // 把「未命名地點」補成地名：走「我們自己」的後端 geocode function（Nominatim），不送蘋果、
    // 與下游讀取層同一來源。alias 命中的 server 已給名、跳過。generation 防過期、上限 12。
    private func geocodeUnnamed(gen: Int) async {
        let targets = todayStays.filter { $0.name == "未命名地點" && $0.coordinate != nil }.prefix(60)  // 多日範圍點多，拉高上限（快取命中的很快）
        for stay in targets {
            guard gen == loadGeneration, let c = stay.coordinate else { return }
            guard let data = try? await WBClient.function("geocode", body: ["lat": c.latitude, "lng": c.longitude]),
                  let name = data.jsonObject["name"] as? String, !name.isEmpty else {
                try? await Task.sleep(for: .milliseconds(300)); continue
            }
            guard gen == loadGeneration, let i = todayStays.firstIndex(where: { $0.id == stay.id }) else { continue }
            todayStays[i].name = name
            try? await Task.sleep(for: .milliseconds(300))   // 對 Nominatim 客氣點（別連發）
        }
    }

    // 統一把一筆 stay JSON → Stay（含 source：live 停留段 / photo_import 匯入點）
    private static func makeStay(_ r: [String: Any]) -> Stay {
        Stay(name: (r["name"] as? String) ?? "未命名地點",
             from: WBDate.parse(r["from_ts"] as? String) ?? Date(),
             to: WBDate.parse(r["to_ts"] as? String),
             dwellSeconds: (r["dwell_seconds"] as? Int) ?? 0,
             confidence: (r["confidence"] as? Double) ?? 1,
             source: parseSource(r["source"] as? String),
             coordinate: coord(r))
    }

    private static func parseSource(_ s: String?) -> Stay.Source {
        switch s {
        case "photo_import": return .photoImport
        case "visit": return .visit
        default: return .live
        }
    }

    private static func coord(_ r: [String: Any]) -> CLLocationCoordinate2D? {
        guard let la = r["centroid_lat"] as? Double, let lo = r["centroid_lng"] as? Double else { return nil }
        return .init(latitude: la, longitude: lo)
    }
    private func dayString(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: Config.tz) ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - PhotoImporter
@Observable @MainActor final class PhotoImporter {
    var progress: Double = 0
    @ObservationIgnored private var pending: [(CLLocation, Date)] = []

    func scan(range: DateInterval) async -> Int {
        progress = 0; pending = []
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { return 0 }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", range.start as NSDate, range.end as NSDate)
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        var found: [(CLLocation, Date)] = []
        assets.enumerateObjects { a, _, _ in
            if let loc = a.location, let d = a.creationDate { found.append((loc, d)) }
        }
        pending = found
        return found.count
    }

    struct ImportResult { let inserted: Int; let total: Int; var failed: Bool = false }   // inserted＝真的寫入；total-inserted＝重複略過；failed＝連不到伺服器、中途中止

    // 匯入待入的點；回傳結果讓 UI 提示（P2）。去重：命中唯一鍵略過（Q8），不再寫 n 筆。
    func importPoints() async -> ImportResult {
        let items = pending
        progress = 0
        guard let uid = WBAuth.shared.userId, !items.isEmpty else { pending = []; return ImportResult(inserted: 0, total: 0) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        var inserted = 0, done = 0
        for (loc, date) in items {
            let body: [String: Any] = ["user_id": uid, "lat": loc.coordinate.latitude, "lng": loc.coordinate.longitude,
                "accuracy": max(loc.horizontalAccuracy, 0), "captured_at": iso.string(from: date), "source": "photo_import"]
            do {
                // ignore-duplicates → 重複略過；return=representation → 有回 body 代表真的寫入（用來數新點）
                let data = try await WBClient.rest("POST", table: "location_history",
                    query: [URLQueryItem(name: "on_conflict", value: "user_id,source,captured_at,lat,lng")],
                    body: body, prefer: "resolution=ignore-duplicates,return=representation")
                if !data.jsonArray.isEmpty { inserted += 1 }
            } catch is URLError {
                // 連不到伺服器（離線/timeout）→ 立刻中止，別讓每點各 12s timeout 累加卡爆；已寫入的保留
                pending = []
                return ImportResult(inserted: inserted, total: items.count, failed: true)
            } catch {
                // 其他錯（單點被拒等）→ 跳過該點續跑
            }
            done += 1; progress = Double(done) / Double(items.count)
        }
        pending = []
        return ImportResult(inserted: inserted, total: items.count)
    }
}

// MARK: - ApiKeyManager
@Observable @MainActor final class ApiKeyManager {
    var keys: [ApiKey] = []
    init() { Task { await load() } }

    func load() async {
        guard let uid = WBAuth.shared.userId else { return }
        do {
            let data = try await WBClient.rest("GET", table: "api_keys",
                query: [URLQueryItem(name: "select", value: "id,name,key_last4,last_used_at,created_at"),
                        URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                        URLQueryItem(name: "revoked_at", value: "is.null"),
                        URLQueryItem(name: "order", value: "created_at.desc")])
            keys = data.jsonArray.map { r in
                ApiKey(id: String(describing: r["id"] ?? ""), name: r["name"] as? String ?? "",
                    keyLast4: r["key_last4"] as? String ?? "", lastUsedAt: WBDate.parse(r["last_used_at"] as? String),
                    createdAt: WBDate.parse(r["created_at"] as? String) ?? Date())
            }
        } catch { }
    }

    func create(name: String) -> String {
        let plaintext = "wb_" + Self.randomToken(32)
        let hash = SHA256.hash(data: Data(plaintext.utf8)).map { String(format: "%02x", $0) }.joined()
        let last4 = String(plaintext.suffix(4))
        keys.insert(ApiKey(id: UUID().uuidString, name: name, keyLast4: last4, lastUsedAt: nil, createdAt: Date()), at: 0)
        Task {
            guard let uid = WBAuth.shared.userId else { return }
            try? await WBClient.rest("POST", table: "api_keys",
                body: ["user_id": uid, "name": name, "key_hash": hash, "key_last4": last4])
            await load()
        }
        return plaintext
    }

    func revoke(id: String) {
        keys.removeAll { $0.id == id }
        Task {
            try? await WBClient.rest("PATCH", table: "api_keys",
                query: [URLQueryItem(name: "id", value: "eq.\(id)")],
                body: ["revoked_at": ISO8601DateFormatter().string(from: Date())])
        }
    }

    static func randomToken(_ n: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }
}

// MARK: - ProfileManager
// 頭貼本地快取：app 一開先吃 Documents/avatar.jpg → 即時顯示、離線也在、不閃預設熊。
// 跨裝置新鮮度靠 profile.updated_at 版本：版本沒變不重抓（省流量）；別台改過 → 抓一次存本地。無 TTL。
@Observable @MainActor final class ProfileManager {
    var avatarURL: URL?
    var avatarImage: UIImage?   // 顯示主體：本地快取 / 剛換的頭貼（免等網路 round-trip）
    var displayName: String?    // 暱稱（可空）；設定頁/未來好友清單顯示，空值 UI fallback email
    @ObservationIgnored private let versionKey = "wb_avatar_version"
    @ObservationIgnored private var localURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar.jpg")
    }

    init() {
        if let data = try? Data(contentsOf: localURL), let img = UIImage(data: data) { avatarImage = img } // 同步吃本地快取
        Task { await load() }
    }

    func load() async {
        guard let uid = WBAuth.shared.userId else { return }
        guard let data = try? await WBClient.rest("GET", table: "profile",
                query: [URLQueryItem(name: "select", value: "display_name,avatar_path,updated_at"),
                        URLQueryItem(name: "user_id", value: "eq.\(uid)")]),
              let row = data.jsonArray.first else { return }
        displayName = (row["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }   // 空字串→nil，UI 統一 fallback email
        guard (row["avatar_path"] as? String) != nil else { return }   // 沒頭貼就到此為止（暱稱已讀）
        avatarURL = WBClient.publicAvatarURL(uid: uid)
        let version = "\(uid)|\((row["updated_at"] as? String) ?? "")"   // 綁 uid：換帳號也視為版本變、重抓
        if UserDefaults.standard.string(forKey: versionKey) == version, avatarImage != nil { return } // 版本沒變＋本地有圖 → 免抓
        if let bytes = try? await WBClient.data(from: avatarURL!), let img = UIImage(data: bytes) {
            avatarImage = img
            try? bytes.write(to: localURL)
            UserDefaults.standard.set(version, forKey: versionKey)
        }
    }

    func setAvatar(_ image: UIImage) async {
        guard let uid = WBAuth.shared.userId, let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        avatarImage = image                 // 立刻反映到 UI（地圖角落 + 設定頁）
        try? jpeg.write(to: localURL)        // 本地快取同步更新（下次開 app 即時、離線也對）
        do {
            try await WBClient.uploadAvatar(jpeg, uid: uid)
            let now = ISO8601DateFormatter().string(from: Date())
            try await WBClient.rest("POST", table: "profile",
                body: ["user_id": uid, "avatar_path": "\(uid)/avatar.jpg", "updated_at": now], prefer: "resolution=merge-duplicates")
            UserDefaults.standard.set("\(uid)|\(now)", forKey: versionKey)
            avatarURL = WBClient.publicAvatarURL(uid: uid)
                .appending(queryItems: [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))])
        } catch { }
    }

    // 暱稱：樂觀更新 + upsert（merge-duplicates；moddatetime 自動刷 updated_at）。
    // 留空＝清除暱稱（存空字串，UI 依 displayName 為 nil fallback email）。
    func setDisplayName(_ name: String) async {
        guard let uid = WBAuth.shared.userId else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = trimmed.isEmpty ? nil : trimmed
        try? await WBClient.rest("POST", table: "profile",
            body: ["user_id": uid, "display_name": trimmed], prefer: "resolution=merge-duplicates")
    }
}

// MARK: - LandmarkManager
@Observable @MainActor final class LandmarkManager {
    var landmarks: [Landmark] = []
    var pendingLongStay: CLLocationCoordinate2D?
    var lastError: String? = nil   // 地標 CRUD 失敗（離線/連不到）提示；UI 綁 alert
    init() { Task { await load() } }

    func load() async {
        guard let uid = WBAuth.shared.userId else { return }
        if let data = try? await WBClient.rest("GET", table: "landmarks",
            query: [URLQueryItem(name: "select", value: "id,alias,lat,lng,radius"),
                    URLQueryItem(name: "user_id", value: "eq.\(uid)")]) {
            landmarks = data.jsonArray.compactMap { r in
                guard let la = r["lat"] as? Double, let lo = r["lng"] as? Double else { return nil }
                return Landmark(id: String(describing: r["id"] ?? ""), alias: r["alias"] as? String ?? "",
                    coordinate: .init(latitude: la, longitude: lo), radius: (r["radius"] as? Int) ?? 100)
            }
        }
    }

    // create/update/delete：樂觀改 → await 結果 → 失敗（離線/連不到）還原本地 + lastError 提示（不再靜默吞錯，UI 不說謊）
    func create(alias: String, coordinate: CLLocationCoordinate2D, radius: Int) {
        guard let uid = WBAuth.shared.userId else { return }
        let new = Landmark(id: UUID().uuidString, alias: alias, coordinate: coordinate, radius: radius)
        landmarks.append(new)
        Task {
            do {
                try await WBClient.rest("POST", table: "landmarks",
                    body: ["user_id": uid, "alias": alias, "lat": coordinate.latitude, "lng": coordinate.longitude, "radius": radius])
                await load()   // 成功才重載同步（拿 server id）
            } catch {
                landmarks.removeAll { $0.id == new.id }
                lastError = "地標沒建立成功——沒網路或連不到伺服器。"
            }
        }
    }

    func update(_ landmark: Landmark) {
        guard let i = landmarks.firstIndex(where: { $0.id == landmark.id }) else { return }
        let old = landmarks[i]
        landmarks[i] = landmark
        Task {
            do {
                try await WBClient.rest("PATCH", table: "landmarks",
                    query: [URLQueryItem(name: "id", value: "eq.\(landmark.id)")],
                    body: ["alias": landmark.alias, "lat": landmark.coordinate.latitude,
                           "lng": landmark.coordinate.longitude, "radius": landmark.radius])
            } catch {
                if let j = landmarks.firstIndex(where: { $0.id == landmark.id }) { landmarks[j] = old }
                lastError = "地標沒更新成功——沒網路或連不到伺服器。"
            }
        }
    }

    func delete(id: String) {
        guard let idx = landmarks.firstIndex(where: { $0.id == id }) else { return }
        let removed = landmarks.remove(at: idx)
        Task {
            do {
                try await WBClient.rest("DELETE", table: "landmarks", query: [URLQueryItem(name: "id", value: "eq.\(id)")])
            } catch {
                landmarks.insert(removed, at: min(idx, landmarks.count))
                lastError = "地標沒刪成功——沒網路或連不到伺服器，地標還在。"
            }
        }
    }

    func resolvePreview(_ c: CLLocationCoordinate2D) -> Landmark? {
        landmarks.first { l in
            CLLocation(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) <= Double(l.radius)
        }
    }

    func dismissLongStay() { pendingLongStay = nil }
}
