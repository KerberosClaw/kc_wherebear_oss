# app/ — 客戶端（FE）

| 目錄 | 平台 | 狀態 |
|---|---|---|
| `wherebear_app/` | iOS（SwiftUI） | Phase 1 已完成、prod 上線可裝用 |
| `wherebear_app_android/` | Android | **尚未進 repo —— 歡迎 PR**（見文末） |

## iOS（`wherebear_app/`）

native SwiftUI app：把最新位置低頻回報到你自己的 Supabase，並看**當前位置 / 今天足跡**、管理**讀取金鑰**與**地標命名**。**Phase 1 已完成、prod 上線可裝用**（架構全景見 [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §4）。不是連續高精度追蹤。

## 分工

- **UI（元件化 SwiftUI）＝ 前端層 產**，來源＝ [`../docs/DESIGN_app.md`](../docs/DESIGN_app.md)。**不在此做 design 判斷。**
- **邏輯/整合層＝本 repo**：`Logic.swift` 的 `@Observable @MainActor` managers（定位回報、auth、金鑰、地標、頭貼、時間軸）＋ `WBClient.swift`（PostgREST / Edge Function / avatar client）。
- **Xcode 專案殼由 owner 開**（synchronized groups，新 `.swift` / 資源自動納入）；更新走 scp `.swift` + owner clean build + install。簽章 / bundle id 走本機 skip-worktree（見 `../CLAUDE.local.md`）。

## 結構

- `Screens/`：`RootView`（auth gate + 啟動 splash + `TabView`）、`MapHomeScreen`、`TimelineScreen`、`SettingsScreen`、`ApiKeysScreen`、`LandmarksScreen`、`AuthScreen`
- `Components/`：單一控制項（`StayRow` / `ApiKeyRow` / `CollapsibleSheet` / `BearCalendar` / `PhotoImportSheet` / `LandmarkFormSheet` / `PawPinView` / `StatusPill`…）
- `Logic.swift`：managers — `SupabaseSession`、`LocationReporter`、`LocationVM`、`PhotoImporter`、`ApiKeyManager`、`ProfileManager`、`LandmarkManager`
- `WBClient.swift` · `Models.swift` · `Config.swift` · `Theme/BearTheme.swift` · `Taglines.swift`（splash 氛圍小字）· `RelativeTime.swift`

## 端點切換 / config（born-clean）

端點走 `Config.swift`：`env` 綁 **`#if DEV`** —— **正常 Xcode ⌘R ＝ prod（正式 app），帶 `DEV` 旗標的 scheme ＝ dev（本機 supabase）**。免 Release / 上架，一般 ⌘R 直接裝到自己手機。

- dev anon key ＝ supabase 本地公開 demo key（committed、非機密）。
- **prod anon key ＝專案專屬 → 不進 repo**，住 gitignored `Config.local.swift`（`enum Secrets { static let prodAnonKey = "…" }`）；fresh checkout 需自建（synchronized group 會自動編譯）。
- 上 prod / 切端點 / dev 變體（「熊熊 dev」）共存的完整 runbook → [`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md)。

## 回報策略（`LocationReporter`）

- **前景 poll**（標準 60s / 省電 180s）：**靜止也寫**（停留偵測的原料）。
- **背景**：significant-change（~500m）＋ **CLVisit**（久坐靜止補點，detect_stays 抓不到的）。
- **離線 outbox**：寫失敗本地佇列、回前景補送。
- **顯示即時流**（地圖，`distanceFilter=10m`）：只更新畫面、**不寫 DB**（抗抖）。
- `captured_at` ＝ GPS 定位那刻的時間戳（非送出時間）；超過 `Config.staleThresholdSeconds`（15 分）→ UI 標「位置可能不是最新」。參數速查 → [`../docs/TUNABLES.md`](../docs/TUNABLES.md)。

---

## 要貢獻 Android 版

歡迎 PR。路徑放 **`app/wherebear_app_android/`**，跟 iOS 那包並列。

- **端點與金鑰照 iOS 那套**：值不進 repo，走 gitignored 的本機設定檔（iOS 是 `Config.local.swift`，Android 建議 `local.properties`），並附一份 `.example` 讓別人 fresh checkout 補得起來。**任何 key / URL / 私網位址都不要 commit。**
- **契約以 [`../docs/API_CONTRACT.md`](../docs/API_CONTRACT.md) 為準**，那份是唯一事實來源。特別注意事件通道：`schema_version` 是**按 `kind` 各自版本**，而 `coverage_ended` 的語意是「我們停止觀測了」，**不等於**使用者離開了任何地方。
- **請附 JVM 單元測試**（`./gradlew test` 跑得到的那種）。instrumented test 需要模擬器，CI 上不跑。
- 平台差異的判準請攤在 config 裡、別藏在邏輯中間——例如 Android 沒有 `CLVisit`，停留偵測的半徑與門檻要看得見、可調、可被測試。
