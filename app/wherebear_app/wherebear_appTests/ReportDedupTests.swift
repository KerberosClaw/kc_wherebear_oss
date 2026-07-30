// ReportDedupTests.swift — 同一次定位被寫成兩列的回歸測試（2026-07-27 prod 實測）。
// 純函式測試：不碰 CLLocationManager、不需網路、不需手機。
import Testing
import Foundation
@testable import wherebear_app

@Suite @MainActor
struct ReportDedupTests {
    private let window: TimeInterval = 2
    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)
    private let baseAcc: Double = 8

    private func redundant(lat: Double, lng: Double, offset: TimeInterval, acc: Double? = nil) -> Bool {
        LocationReporter.isRedundantFix(lat: lat, lng: lng, at: t0.addingTimeInterval(offset),
                                        accuracy: acc ?? baseAcc,
                                        previous: (25.0, 121.5, t0, baseAcc), window: window)
    }

    // prod 實測的兩個間距：23:30:28.080／.136 相距 0.056 秒，另一批相距約 0.6 秒。都該擋。
    @Test func sameFixDeliveredTwiceIsDropped() {
        #expect(redundant(lat: 25.0, lng: 121.5, offset: 0.056))
        #expect(redundant(lat: 25.0, lng: 121.5, offset: 0.6))
    }

    // 兩條觸發源誰先到不保證 —— 時間差為負也是同一個 fix，一樣要擋。
    @Test func outOfOrderDeliveryIsDropped() {
        #expect(redundant(lat: 25.0, lng: 121.5, offset: -0.056))
    }

    // 🔴 最重要的一條：去重不能吃掉真實移動。significant-change 節流是 5 分鐘一筆，
    // 但前景輪詢最密到 60 秒，兩者都遠在視窗外；這裡驗更兇的情境 —— 才過 2 秒但人真的動了。
    @Test func differentCoordinateWithinWindowIsKept() {
        #expect(!redundant(lat: 25.00001, lng: 121.5, offset: 0.1))   // 緯度差 1e-5 ≈ 1.1 公尺
        #expect(!redundant(lat: 25.0, lng: 121.50001, offset: 0.1))
    }

    // 🔴 座標相同不代表誤差相同：prod 25 對同座標成對點裡有 8 對 accuracy 不同。
    // accuracy 有下游在吃（departure_evidence 的自適應門檻、visit_event_channel 的地標比對容差），
    // 丟掉較準的那筆＝把後端判斷餵差。
    @Test func moreAccurateDuplicateIsKept() {
        #expect(!redundant(lat: 25.0, lng: 121.5, offset: 0.1, acc: baseAcc - 0.1))   // 更準 → 放行
        #expect(!redundant(lat: 25.0, lng: 121.5, offset: 0.1, acc: 4.0))             // 實測 4.0/7.8 那對的方向
    }

    // 反向：誤差相同或更差的重複投遞照擋（實測 25/25 都是這一種）。
    @Test func equalOrWorseAccuracyDuplicateIsDropped() {
        #expect(redundant(lat: 25.0, lng: 121.5, offset: 0.1, acc: baseAcc))
        #expect(redundant(lat: 25.0, lng: 121.5, offset: 0.1, acc: baseAcc + 0.1))
        #expect(redundant(lat: 25.0, lng: 121.5, offset: 0.1, acc: 7.8))   // 實測 4.0→7.8 的較差那筆
    }

    // 站著不動時，下一次取樣座標可能一位不差 —— 只要超出視窗就是新的一筆，不能當重複丟掉，
    // 否則 detect_stays 聚不出停留（DB 保鮮也會斷）。
    @Test func sameCoordinateOutsideWindowIsKept() {
        #expect(!redundant(lat: 25.0, lng: 121.5, offset: 60))    // 前景輪詢（標準）
        #expect(!redundant(lat: 25.0, lng: 121.5, offset: 180))   // 前景輪詢（省電）
        #expect(!redundant(lat: 25.0, lng: 121.5, offset: 300))   // significant-change 節流
    }

    // 邊界取嚴格小於：剛好等於視窗長度算新的一筆。
    @Test func windowBoundaryIsExclusive() {
        #expect(!redundant(lat: 25.0, lng: 121.5, offset: window))
        #expect(redundant(lat: 25.0, lng: 121.5, offset: window - 0.001))
    }

    // 冷啟動第一筆沒有前一筆可比 —— 必須放行，否則開 app 後第一個點永遠不會上傳。
    @Test func firstFixAfterLaunchIsKept() {
        #expect(!LocationReporter.isRedundantFix(lat: 25.0, lng: 121.5, at: t0, accuracy: baseAcc,
                                                 previous: nil, window: window))
    }
}
