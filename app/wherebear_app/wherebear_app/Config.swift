// Config.swift — dev / prod 端點切換（用戶要的「變數切換」）
// dev = 本機 supabase（mac LAN，手機插線連）；prod = 雲端。
// 切換：env 預設 = prod；只有帶 `DEV` 編譯旗標的 build 才切 dev。正常 ⌘R = prod、免 Release/上架。
//
// born-clean 註：dev 值＝私有 LAN + supabase 本地「公開 demo anon key」（全球一致、非機密、committed）。
// prod 端點與 anon key 都不進 repo，住 gitignored 的 Config.local.swift（Secrets.prodURL / prodAnonKey）。
// 專案 ref 嚴格說不是秘密（它是 API 子網域、也編在 app 二進位檔裡，擋人的是 RLS 與認證），
// 但沒理由把它白送出去——知道 ref 才能針對性地打（試登入、耗 rate limit、盯 RLS 有沒有被改鬆）。
import Foundation

enum AppEnv { case dev, prod }

enum Config {
    // env 預設 = prod（正式 app）。dev 變體 app 靠一個 `DEV` 編譯旗標切到 dev backend。
    // → 正常 Xcode ⌘R（無 DEV 旗標）＝ prod「熊熊在哪裡」，直接裝手機、不需 Release/Archive/上架。
    // → 「wherebear-dev」scheme（config 的 SWIFT_ACTIVE_COMPILATION_CONDITIONS 帶 DEV + bundle .dev）＝ dev backend。詳 docs/DEPLOYMENT.md §5。
    static let env: AppEnv = {
        #if DEV
        return .dev
        #else
        return .prod
        #endif
    }()

    static var supabaseURL: URL {
        switch env {
        case .dev:  return URL(string: Secrets.devURL)!          // dev 端點＝你的 mac Bonjour 名（<name>.local:54321），住 gitignored Config.local.swift（mDNS 被擋就在那改成 LAN IP）
        case .prod: return URL(string: Secrets.prodURL)!         // prod 端點＝你的 Supabase 專案（住 gitignored Config.local.swift）
        }
    }

    static var anonKey: String {
        switch env {
        case .dev:
            // supabase 本地 demo anon key（公開常數、非機密）
            return "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0" // gitleaks:allow — 公開 supabase 本地 demo key
        case .prod:
            return Secrets.prodAnonKey   // 住 gitignored Config.local.swift（born-clean：專案 anon key 不進 repo）
        }
    }

    // today-stays / 停留段的使用者時區
    static let tz = "Asia/Taipei"
    // 座標過時門檻（秒）— 超過視為 isStale
    static let staleThresholdSeconds: TimeInterval = 15 * 60

    // 啟動 splash 停留秒數（進度條 0→1 + 金句輪播讓等待「有東西看」而無感）。
    // 設 0 → 直接跳過 splash 停留（cloner 可關）。開源版可調短（如 4）讓人快點進 app；本機沿用現值 8。
    static let splashSeconds: Double = 8
}
