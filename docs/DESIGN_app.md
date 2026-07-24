# DESIGN_app — kc_wherebear iOS app 設計 brief（給 前端層）

> **English summary:** The design brief for the kc_wherebear native iOS SwiftUI app, handed to the front-end/visual layer. It specifies each screen — onboarding/login, map home, timeline, settings, API keys, and landmark naming — in terms of purpose, elements, states, flows, and rules, plus the visual direction (a playful 2D cel-shaded bear theme) and the logic-layer contract (the observable managers the UI binds to). It defines WHAT the app does and how it behaves, not the UI implementation itself.

> 這份餵 前端層 生前端。**分工：UI/視覺＝前端層；功能/狀態/流程（WHAT）＝這份 brief；邏輯/整合層實作＝repo。**
> 平台：native iOS **SwiftUI**、元件化拆檔（每控制項一檔 + 主 Screen 組裝 + 一支邏輯 client）。config 走 `Config.swift`（`#if DEV` 切端點：預設 prod、DEV 旗標才 dev）+ gitignored `Config.local.swift`（prod anon key、範本 `Config.local.swift.example`），詳 [`DEPLOYMENT.md`](DEPLOYMENT.md)。

## 這支 app 做什麼

背景**低頻**把最新位置回報到使用者自己的後端；讓使用者看自己的**當前位置**與**今天足跡**、管理 API 金鑰。不是連續高精度追蹤。

## 視覺方向：熊味活潑

- 調性：**可愛 2D cel-shaded 動畫「熊」**（暖棕、圓潤、大眼、友善吉祥物）、暖色系、溫馨。**不是**寫實、**不是**冷科技風。參考圖 out-of-band 提供（一張中性可愛 cel-shaded 熊 + 地圖大頭針），**不進 repo**。
- 可玩：地圖 pin 做成熊掌/熊臉、狀態用熊表情、空狀態用熊插畫。

---

## 畫面集（Phase 1：4 主畫面 + 1 子頁 + 地標命名〔疊在地圖/時間軸 + 清單〕）

每畫面規格＝**目的 · 元素 · 狀態 · 流程 · 規則**。

### 1. Onboarding / 登入
- **目的**：首啟引導 + 登入/註冊 + email 驗證 + 定位權限。
- **元素**：熊 mascot、一句說明「這 app 在背景把你的位置回報到**你自己的**後端」、email 欄、密碼欄（遮罩）、登入鈕、註冊切換、忘記密碼連結。
- **流程**：
  - 註冊 → 填 email/密碼 → 送出 → 「**驗證信已寄，去收信點連結**」→ 回登入。
  - 登入成功但 email 未驗證 → 擋住 + 「請先驗證 email」+ **重寄驗證信**鈕。
  - 忘記密碼 → 填 email → 「重設信已寄」。
  - 登入成功且已驗證 → 請求定位權限（先 When-in-use 再引導升 **Always**，附說明「背景回報需要 Always」）→ 進地圖首頁。
- **狀態**：idle / 送出中(loading) / 失敗(帳密錯、網路錯、email 未驗證，各自訊息) / 驗證信已寄 / 定位權限被拒(引導去系統設定開)。
- **規則**：錯誤訊息友善、不洩安全細節；Always 權限說明務必講清楚為什麼要。

### 2. 地圖首頁（Home）
- **目的**：看當前位置 + 控制回報開關。
- **元素**：地圖（當前位置 pin ＝熊掌/熊臉）、`resolved_name` 地名卡、**回報開關**（大、明確）、狀態列（上次回報時間、跑/停、定位權限、連線）、去時間軸/設定入口。
- **狀態**：
  - **回報中**（綠、「上次回報 X 分鐘前」）
  - **已停**（灰）
  - **定位權限不足**（黃/紅、一鍵跳系統設定）
  - 🔴 **座標過時**（`captured_at` 太舊 → 「位置可能不是最新」提示，別讓人誤以為是現在）
  - **離線**（回報 queue 中、有網補送的提示）
  - **初次無資料**（還沒回報過 → 熊插畫「開啟回報開始記錄」）
- **流程**：開關 on → 確認/請求權限 → 開始背景回報；off → 停。
- **規則**：過時門檻走 config；權限被拒要能一鍵跳設定。

### 3. 時間軸（Timeline）
- **目的**：看自己今天/歷史足跡 + 相簿匯入。
- **元素**：日期選擇（今天/選日期）、地圖軌跡、**stays 列表**（地點名 + 時段 + 停留時長 + confidence）、匯入鈕、空狀態熊插畫。
- **狀態**：
  - 有 stays（列表 + 地圖軌跡）
  - **低 confidence 段**（視覺弱化、標「約」，別講死）
  - 該日無資料（熊插畫）
  - 載入中 / 匯入中（進度）
- **相簿匯入流程**：點匯入 → **選時間範圍** → 掃該範圍帶 GPS 的照片 → 「找到 N 個帶定位的點，匯入？」→ 確認 → 匯入 → 回時間軸。🔴 UI **明講「只讀座標+時間、不看照片本身」**。
- **規則**：匯入點 `source=photo_import`（視覺可區分 live vs 匯入）；相簿權限請求 + 被拒引導。

### 4. 設定（Settings）
- **目的**：調參數 + 帳號 + API 金鑰 + 隱私。
- **元素/項目**：
  - **回報頻率**：省電 / 標準（2 選 1，預設省電）
  - **API 金鑰**（進子頁 4a）
  - 帳號：登出 / 改密碼（走 email 流程）
  - 定位權限狀態（+ 一鍵跳系統設定）
  - 隱私說明（資料進你自己的後端）
- **規則**：登出清 session。

#### 4a. API 金鑰（子頁）
- **目的**：發/撤讀取金鑰，給外部工具讀你的位置。
- **元素**：金鑰列表（名稱 + 遮罩 `wb_…xxxx` + last_used + 建立日）、建新鈕、每項 revoke。
- **狀態**：空（說明用途 + 建新引導）/ 有列表 / 建立中 / **顯示新金鑰一次**。
- **建立流程**：點建新 → 命名 → 產生 → 🔴 **明文只顯示一次**（大字 + 複製鈕 + 「離開就看不到了」警告）→ 確認已存 → 回列表（之後只剩遮罩）。
- **revoke 流程**：點 revoke → 確認 → 該金鑰失效、列表移除（或標 revoked）。
- **規則**：明文**絕不**二次顯示；一句說明「這是給你自己的工具讀你位置用的」。

### 5. 地標命名（Landmarks · Phase 1）
- **目的**：讓使用者為常去點自訂名稱，覆蓋通用 geocode（R1/R2 的 `resolved_name` 優先用 alias）。
- **三個入口**：
  - ① **地圖長停留卡片**：偵測到長停留 → 首頁浮出「幫這裡命名？」卡片（一鍵命名／略過）。
  - ② **時間軸 stay 命名**：時間軸某 stay 點「命名」→ 帶該 stay centroid 進命名。
  - ③ **手動新增**：地標清單頁「＋」（地圖點位或用當前位置）。
- **命名表單**：名稱欄、地圖點位、**radius preset**（幾段語意：精確點／一般場所／大範圍，或自訂公尺）、儲存。
- **地標清單**（設定或獨立入口進）：列已命名地標（名稱＋範圍），可**編輯／刪除**。
- **狀態**：無地標（空狀態熊插畫＋「把常去的地方命名」引導）／有清單／命名中／重疊提示（新點落既有地標範圍內時提醒）。
- **綁定**：`LandmarkManager`（`create`/`update`/`delete`/`resolvePreview` ＋ 三觸發信號）。
- **規則**：alias 是個人資料、只自己可寫（RLS）；純自訂、不逼問。

---

## 邏輯層契約（repo 寫、前端層 把 UI 綁上去）

每個給畫面綁的物件 —— 名稱 + 對外狀態/動作：

- **`SupabaseSession`**：`state`(loggedOut/needsVerify/loggedIn)、`signUp`、`signIn`、`resendVerification`、`resetPassword`、`changePassword`、`signOut`。
- **`LocationReporter`**：`isReporting`、`lastReportAt`、`permissionState`、`connectivity`、`frequency`(saver/standard)、`start`、`stop`、`setFrequency`。背景 significant-change；offline 失敗本地 queue、有網補送。
- **`LocationVM`**（首頁/時間軸綁）：`current`(lat/lng/accuracy/`resolved_name`/`captured_at` + `isStale`)、`todayStays`([name/from/to/dwell/confidence])、`selectDate`。
- **`PhotoImporter`**：`pickRange`、`scan`(回帶 GPS 點數，**只讀 location+date、不讀像素**)、`import`、`progress`。
- **`ApiKeyManager`**：`keys`([name/masked/lastUsed/createdAt])、`create`(回**一次性明文**)、`revoke`。
- **`ProfileManager`**：`avatarURL`(public URL、顯示用)、`setAvatar`(選圖→上傳 public `avatars` bucket、owner-write→存 `avatar_path`)；null＝預設通用熊。讀公開、寫只 owner。

## 導覽 · 主題 · 大頭貼（IG / pikmin 參考）

- **主題＝深色底 + 暖熊 accent**：深色 UI（半夜滑不刺眼，用戶明確要），暖意走 mascot / 地圖 pin / highlight / 熊掌。**不做亮面。**
- **導覽＝原生 SwiftUI `TabView`（iOS 26 Liquid Glass）**：浮動毛玻璃 tab bar + 滑動選取，**Xcode 26 重編譯即自動套、不自己刻**（IG 新 tab bar 那個就是原生的）。自訂浮動玻璃元件才用 `.glassEffect()`；目標 **iOS 26+**。tab：**地圖 / 時間軸 / 設定**。參考文件 [LiquidGlassReference](https://github.com/conorluddy/LiquidGlassReference) 可一起餵 前端層。
- **登入後直接進地圖 tab**，角落顯示**可設定的 user 大頭貼**（設定/個人頁改）。
  - 後端（契約 §1.5）：頭圖存 **public** `avatars` bucket（讀公開 URL、寫只 owner）、`profile.avatar_path` 記路徑；顯示走 public URL、任何人可見、**與位置隱私脫鉤**。app 綁 `ProfileManager`（設定/個人頁換圖）。
  - born-clean：repo 預設頭貼＝通用熊；個人頭貼＝用戶資料（存 Supabase Storage、不進 repo）。
- 視覺參考（out-of-band、不進 repo）：IG 新 tab bar（毛玻璃滑動）、pikmin app（深色 + 角落頭貼）。

## born-clean（🔴 盯）
- 零私有素材/真值進 repo；參考圖走 out-of-band。
- 無真座標/金鑰進 repo；config 走 `Config.swift` + gitignored `Config.local.swift`（範本 `Config.local.swift.example` committed，見 DEPLOYMENT.md）。
- 標地名的座標（landmark alias / resolved_name）比匿名座標敏感 —— UI 別把它當普通字串到處秀。
