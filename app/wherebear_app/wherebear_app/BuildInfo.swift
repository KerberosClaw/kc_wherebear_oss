// BuildInfo.swift — 建置版本識別（設定頁最下面顯示，用來分辨手機上裝的是哪一版）。
// 真實 short git hash 由 Xcode「Run Script」build phase 於每次建置寫進 Info.plist 的 GitHash key
//（一次性設定見 docs/DEPLOYMENT.md「建置版本戳記」）。沒設 build phase 時退回 MARKETING_VERSION(build)。
import Foundation

enum BuildInfo {
    /// 顯示字串：有 git hash 就顯示 hash（含 -dirty），否則退回版本號 `v1.0 (1)`。
    static let version: String = {
        let info = Bundle.main.infoDictionary
        if let h = (info?["GitHash"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !h.isEmpty, !h.hasPrefix("$(") {   // build phase 沒跑時值為空或殘留 "$(GIT_HASH)" → 視為未戳記
            return h
        }
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }()
}
