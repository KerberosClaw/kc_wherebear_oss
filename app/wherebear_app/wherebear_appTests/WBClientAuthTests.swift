// WBClientAuthTests.swift — WBClient JWT 自動續期回歸測試（2026-07-24 站裡那個 bug 的 guard）。
// 用 mock URLProtocol 模擬 server，不碰真 backend / 不需手機 / 不需網路。
// @Suite(.serialized)：WBClient/WBAuth/UserDefaults 是行程級全域狀態，序列跑避免並發互汙。
import Testing
import Foundation
@testable import wherebear_app

// MARK: - Mock server（依請求 URL + Authorization header 回不同結果）
final class MockURLProtocol: URLProtocol {
    // server 目前接受的 access token（app 拿舊的會被打 401）
    nonisolated(unsafe) static var validAccessToken = "fresh"
    // refresh 成功時發的新 token
    nonisolated(unsafe) static var newAccessToken = "fresh"
    nonisolated(unsafe) static var newRefreshToken = "refresh-2"
    nonisolated(unsafe) static var refreshSucceeds = true
    // 呼叫計數（斷言用）
    nonisolated(unsafe) static var refreshCallCount = 0
    nonisolated(unsafe) static var dataCallCount = 0
    // visits 端點（VisitOutboxTests 用）：visitsShouldFail=模擬離線
    nonisolated(unsafe) static var visitsShouldFail = false
    nonisolated(unsafe) static var visitPostCount = 0
    nonisolated(unsafe) static var lastVisitQuery: String?   // 斷言 on_conflict 用
    nonisolated(unsafe) static var lastVisitMethod: String?  // 斷言停止收尾走 PATCH 用

    static func reset() {
        validAccessToken = "fresh"; newAccessToken = "fresh"; newRefreshToken = "refresh-2"
        refreshSucceeds = true; refreshCallCount = 0; dataCallCount = 0
        visitsShouldFail = false; visitPostCount = 0; lastVisitQuery = nil; lastVisitMethod = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        // visits 端點：測 durability —— visitsShouldFail 模擬離線（網路錯、非 401）
        if path.contains("/rest/v1/visits") {
            Self.visitPostCount += 1
            Self.lastVisitQuery = request.url?.query
            Self.lastVisitMethod = request.httpMethod   // 停止收尾走 PATCH、到達/離開投遞走 POST
            if Self.visitsShouldFail {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let ok = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                                     headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status: Int
        let body: Data
        if path.contains("/auth/v1/token") {
            // refresh 端點
            Self.refreshCallCount += 1
            if Self.refreshSucceeds {
                let json: [String: Any] = [
                    "access_token": Self.newAccessToken,
                    "refresh_token": Self.newRefreshToken,
                    "token_type": "bearer",
                    "expires_in": 3600,
                    "user": ["id": "user-1", "email": "tester@example.com",
                             "email_confirmed_at": "2026-01-01T00:00:00Z"],
                ]
                status = 200
                body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            } else {
                status = 400
                body = Data(#"{"error":"invalid_grant"}"#.utf8)
            }
        } else {
            // 資料端點：Bearer 對得上才 200，否則 401（模擬 access token 過期）
            Self.dataCallCount += 1
            let auth = request.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer \(Self.validAccessToken)" {
                status = 200
                body = Data("[]".utf8)
            } else {
                status = 401
                body = Data(#"{"message":"JWT expired"}"#.utf8)
            }
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Tests
@Suite(.serialized) @MainActor
struct WBClientAuthTests {
    let reporter: LocationReporter

    init() {
        MockURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        WBClient.sessionOverride = URLSession(configuration: cfg)
        WBAuth.shared.clear()
        UserDefaults.standard.removeObject(forKey: WBAuth.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: "wb_visit_outbox")
        reporter = LocationReporter()
    }

    // 核心：資料請求收 401（access token 過期）→ 自動 refresh → 用新 token retry → 成功。
    @Test func refreshesOn401ThenRetriesAndSucceeds() async throws {
        WBAuth.shared.accessToken = "expired"          // app 手上是舊 token
        WBAuth.shared.userId = "user-1"
        UserDefaults.standard.set("refresh-1", forKey: WBAuth.refreshTokenKey)

        _ = try await WBClient.rest("POST", table: "current_location", body: ["user_id": "user-1"])

        #expect(MockURLProtocol.refreshCallCount == 1)   // refresh 換過一次
        #expect(MockURLProtocol.dataCallCount == 2)      // 401 + retry 共兩次
        #expect(WBAuth.shared.accessToken == "fresh")    // access token 已換新
        #expect(UserDefaults.standard.string(forKey: WBAuth.refreshTokenKey) == "refresh-2") // rotation 寫回
    }

    // refresh token 也死掉 → 丟錯給上層走離線佇列，不無限重試、不吞錯。
    @Test func refreshFailurePropagatesErrorWithoutLooping() async throws {
        WBAuth.shared.accessToken = "expired"
        WBAuth.shared.userId = "user-1"
        UserDefaults.standard.set("refresh-dead", forKey: WBAuth.refreshTokenKey)
        MockURLProtocol.refreshSucceeds = false

        do {
            _ = try await WBClient.rest("GET", table: "current_location")
            Issue.record("rest() 應在 refresh 失敗時丟錯，而非吞掉")
        } catch {
            #expect(error is WBError)
        }
        #expect(MockURLProtocol.refreshCallCount == 1)   // 只試一次、不迴圈
        #expect(MockURLProtocol.dataCallCount == 1)      // 原請求 1 次、無 retry
    }

    // 並發多筆 401 → coalesce 成單一 refresh（避免撞 rotation reuse 把 session 撤掉）。
    @Test func concurrent401sCoalesceIntoOneRefresh() async throws {
        WBAuth.shared.userId = "user-1"
        UserDefaults.standard.set("refresh-1", forKey: WBAuth.refreshTokenKey)

        async let a = WBClient.tryRefresh()
        async let b = WBClient.tryRefresh()
        let results = await [a, b]

        #expect(results == [true, true])
        #expect(MockURLProtocol.refreshCallCount == 1)   // 兩筆併成一次 refresh
    }

    // MARK: - Visit（CLVisit 停留）durability —— 原本 try? 靜默丟，現在失敗進 outbox 補送
    private func visit(arrived: String, departed: String? = nil,
                       lat: Double = 24.17, lng: Double = 120.68) -> [String: Any] {
        var b: [String: Any] = ["user_id": "user-1", "lat": lat, "lng": lng, "arrived_at": arrived]
        if let departed { b["departed_at"] = departed }
        return b
    }

    // 上傳成功 → 不進 outbox。
    @Test func visitUploadSuccessNotQueued() async {
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z"))
        #expect(reporter.visitOutboxCount == 0)
        #expect(MockURLProtocol.visitPostCount >= 1)
    }

    // 上傳失敗（離線/連不到）→ 進 outbox、不再靜默丟（昨晚停留遺失那個 bug 的 guard）。
    @Test func visitFailureQueuedNotDropped() async {
        MockURLProtocol.visitsShouldFail = true
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z"))
        #expect(reporter.visitOutboxCount == 1)
    }

    // 回線後：新 visit 成功 → 順帶把積的補送、佇列排空。
    @Test func queuedVisitsFlushOnRecovery() async {
        MockURLProtocol.visitsShouldFail = true
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z"))
        #expect(reporter.visitOutboxCount == 1)
        MockURLProtocol.visitsShouldFail = false                        // 回線
        await reporter.submitVisit(visit(arrived: "2026-07-24T03:00:00Z"))  // 新 visit 成功→順帶補送
        #expect(reporter.visitOutboxCount == 0)                       // 佇列排空
    }

    // 同一 visit 的到達+離開兩段都失敗 → 佇列只留一筆（離開覆蓋到達）。
    @Test func sameVisitDedupedInQueue() async {
        MockURLProtocol.visitsShouldFail = true
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z"))                                   // 到達
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z", departed: "2026-07-24T09:00:00Z"))  // 離開、同 key
        #expect(reporter.visitOutboxCount == 1)
    }

    // D14 回歸：iOS 對同一次停留的兩次投遞座標會漂（實測 33～205 m）。佇列鍵若含座標，
    // 到達與離開會各佔一格、replay 時再送出兩筆 → 正是 visits 表長出孤兒列的同一個病。
    @Test func sameVisitDedupedInQueueDespiteCoordinateDrift() async {
        MockURLProtocol.visitsShouldFail = true
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z", lat: 24.17, lng: 120.68))
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z", departed: "2026-07-24T09:00:00Z",
                                         lat: 24.1718, lng: 120.6802))   // 同一次停留、座標漂 ~200 m
        #expect(reporter.visitOutboxCount == 1)
    }

    // 停留佇列的除錯窺看：設定→離線佇列→「停留」分頁靠這支。停留佇列是後加的功能、
    // 原本只有位置點有 peek/計數 → 停留卡住時 UI 顯示 0、使用者完全看不見。
    @Test func visitOutboxPeekExposesQueuedStays() async {
        MockURLProtocol.visitsShouldFail = true
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z"))                                   // 到達
        await reporter.submitVisit(visit(arrived: "2026-07-24T05:00:00Z", departed: "2026-07-24T06:00:00Z"))  // 另一次的離開
        let q = reporter.visitOutboxPeek()
        #expect(q.count == 2)
        #expect(q.first?.departed == nil)    // 到達那筆沒有離開時間
        #expect(q.last?.departed != nil)     // 離開那筆有 → UI 才分得出「仍在停留中」
        #expect(reporter.visitOutboxCount == 2)
    }

    // D14 回歸：補送時走的 on_conflict 必須是「到達時刻」——含座標的話，DB 端會因座標漂移
    // 改走 INSERT、留下永遠關不掉的第二列（prod 實測 11 列裡 6 列是這樣來的）。
    @Test func visitUpsertKeysOnArrivalOnly() async {
        await reporter.submitVisit(visit(arrived: "2026-07-24T02:00:00Z"))
        let q = MockURLProtocol.lastVisitQuery ?? ""
        #expect(q.contains("on_conflict=user_id%2Carrived_at") || q.contains("on_conflict=user_id,arrived_at"))
        #expect(!q.contains("lat"))
    }

    // D15 收尾：按下停止之後 iOS 不再送任何事件，還開著那段停留的 departed_at 永遠補不上，
    // 讀取層會把它當成「人還在那裡」畫進往後的每一天。停止是最後一次能講話的機會。
    @Test func stoppingClosesOpenVisitsWithPatchFilter() async {
        WBAuth.shared.userId = "user-1"
        await reporter.closeOpenVisits()
        #expect(MockURLProtocol.lastVisitMethod == "PATCH")   // 不是 POST：手上沒有 arrived_at 可當去重鍵
        let q = MockURLProtocol.lastVisitQuery ?? ""
        #expect(q.contains("user_id=eq.user-1"))
        #expect(q.contains("departed_at=is.null"))            // 只碰還開著的，已關的不能被蓋掉
    }

    // 沒登入就按停止不該打 API（也不該 crash）。
    @Test func stoppingWithoutSessionSendsNothing() async {
        WBAuth.shared.userId = nil
        await reporter.closeOpenVisits()
        #expect(MockURLProtocol.visitPostCount == 0)
    }
}
