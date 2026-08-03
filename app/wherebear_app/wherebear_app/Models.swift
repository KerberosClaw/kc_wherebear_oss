// Models.swift — 共用模型型別（對齊 API_CONTRACT；原本在 PreviewMocks，抽出供正式邏輯層共用）
import SwiftUI
import CoreLocation

enum AuthState { case restoring, loggedOut, needsVerify, loggedIn }

enum ReportFrequency: CaseIterable {
    case saver, standard
    var label: String { self == .saver ? "省電" : "標準" }
}

enum PermissionState { case notDetermined, whenInUse, always, denied }
enum Connectivity { case online, offline }

struct CurrentLocation {
    var coordinate: CLLocationCoordinate2D
    var accuracy: Double
    var resolvedName: String?   // 契約 §2.1：nullable（null → UI 顯示 raw 座標）
    var capturedAt: Date
    var isStale: Bool
}

struct Stay: Identifiable {
    enum Source { case live, photoImport, visit }
    let id = UUID()
    var name: String
    var from: Date
    var to: Date?               // 契約 §2.2：進行中／單點 import 可 null
    var dwellSeconds: Int       // 契約 §2.2：int 秒
    var confidence: Double = 1  // 契約 §2.2：float 0..1
    var source: Source = .live
    var coordinate: CLLocationCoordinate2D? = nil  // centroid
    // 這一段停留在後端的身分。有值才有辦法說「我指的就是這一段」——命名時直接把人為指定
    // 送回去，不必等感測器湊足票數。live／相片匯入來源沒有對應的 visit，因此為 nil。
    var visitId: Int? = nil
}

extension Stay {
    static let lowConfidenceThreshold = 0.6
    var isLowConfidence: Bool { confidence < Self.lowConfidenceThreshold }
    var dwellText: String {
        let m = dwellSeconds / 60
        if m < 60 { return "\(m) 分" }
        return m % 60 == 0 ? "\(m / 60) 小時" : "\(m / 60) 小時 \(m % 60) 分"
    }
}

struct ApiKey: Identifiable {
    var id: String              // server id（revoke 用）
    var name: String
    var keyLast4: String
    var lastUsedAt: Date?
    var createdAt: Date
}

extension ApiKey {
    var masked: String { "wb_…\(keyLast4)" }
    var lastUsedText: String {
        guard let lastUsedAt else { return "尚未使用" }   // 沒用過：只寫「尚未使用」、不加前綴
        return "上次使用 \(relativeZh(lastUsedAt))"
    }
}

struct Landmark: Identifiable {
    var id: String
    var alias: String
    var coordinate: CLLocationCoordinate2D
    var radius: Int             // 契約 §1.3：int 公尺
}
