# DESIGN — kc_wherebear 後端架構與決策

> **English summary:** Records the rationale behind kc_wherebear's backend design as a numbered set of decisions (D1–D12), including choosing a self-hosted Supabase (BaaS) backend, a native Swift app, Supabase Auth + RLS bound to `auth.uid()` for writes, a read-only Edge Function for headless consumers, and the hot/cold dual-table model (`current_location` upsert + `location_history` append). It also covers the landmark-alias / reverse-geocode resolution layer, the pg_cron archival policy, the privacy stance, and how each requirement maps onto Supabase platform capabilities.

承接需求對齊（grill）的收斂。這份記「為什麼這樣設計」；隨實作演進回填。

## 目標

自架個人位置平台：手機低頻回報最新位置 → 自己的 Supabase → 本地 bridge 給下游。**不做**連續高精度追蹤。設計成多使用者 ready（`user_id`+RLS）、功能分期上線（見 [`ROADMAP.md`](ROADMAP.md)）。

## 關鍵決策

| # | 決策 | 理由 |
|---|---|---|
| **D1** | 後端＝自架 Supabase 專案（BaaS） | 託管 DB/Auth/Realtime/RLS，零 server 運維 |
| **D2** | 手機端＝native Swift app | 背景定位可靠度優於跨平台框架；OTA 對 sideload/native-權限 app 幾乎無價值（有引用比較） |
| **D3** | 寫入 auth＝Supabase Auth email/密碼 + RLS 綁 `auth.uid()` | 免設 OAuth provider、RLS 天生多使用者可擴；避開「秘鑰進 client」反模式 |
| **D4** | 讀取＝read-only Edge Function + shared secret（headless caller） | `service_role` 只在 server function secrets、對外只露窄讀口 |
| **D5** | 資料模型＝雙表 `current_location`(熱/upsert) + `location_history`(冷/append) | 見下「熱/冷」 |
| **D6** | reverse-geocode＝伺服器端 Edge Function | server 端呼叫地理 API OK；不破下游消費者「本地讀、零外呼」不變式 |
| **D7** | 封存＝pg_cron 三十天搬 archive、可調回 | 不刪、冷存、分區 |
| **D8** | schema 一開始就多使用者 ready（`user_id`+RLS）、功能分期 | 避免日後對 live 資料動 schema 手術 |
| **D9** | 下游消費側走「bridge 寫本地檔、消費者讀本地檔」 | 網路只在 bridge；下游維持零外呼 |
| **D10** | 獨立可開源 repo、born-clean、無 git-crypt | 內容全通用 code+佔位，無私密可藏；靠衛生紀律不靠加密 |

### A vs B（後端型態）

選 **A：Supabase-native**（BaaS + Edge Functions），不選 **B：自架 FastAPI/servlet server**。B 的分家/自控優勢建立在團隊/部署規模上，solo 小專案沒有；A 把 DB/Auth/Realtime/RLS 全託管、只剩兩支小 Edge Function 要寫。

### 熱/冷雙表（D5 詳）

經典時序 pattern（等同 Redis 熱 + HBase 冷，但塌縮進單一 managed Postgres）：

- `current_location`：每 user 一列、`upsert`。服務「讀最新」（未來可加 Realtime、尊重 RLS）。
- `location_history`：每次回報 `insert` append。服務行程輪廓 + 封存。

**分兩張的理由不是效能**（本 scale 一張表也夠）**，是避免日後加即時功能時對 live 資料動 schema 手術**。現在多一張表＝一次性便宜保險。

欄位（初版）：`user_id` · `lat` · `lng` · `accuracy` · `captured_at`（裝置取得時間，防把舊座標當現在）· `updated_at`（server 寫入）· `place_label`（reverse-geocode 後回填）。

## 下游消費者 需求（R1–R4，併入 Phase 1）

把「單一當前座標」升級成「今天的一個面 + 使用者自訂地標名」，讓下游消費者的訊息更貼處境。**併入 Phase 1 後端**；app 側「地標命名 UX / 時間軸 UI」仍留 Phase 2。

- **D11 `landmarks` 表（使用者自訂地標 alias）**：`user_id`(FK) · `alias` · `geog`(geography Point) · `radius`(公尺) · created/updated。RLS `auth.uid()`。🔴 **runtime 寫入、絕不 migration seed 真值**；語意標籤座標比匿名座標更敏感 → 嚴防跨使用者讀。
- **D12 解析層**：座標落某 landmark `radius` 內 → 回 `alias`（多點重疊取最近/最小半徑），否則通用 reverse-geocode。**優先序 alias ＞ geocode**；命中還免打外部 geocode API（優化 D6）。R1／R2 都套。
- **R1 讀口擴充**：last-location 回 `lat`·`lng`·`accuracy`·`captured_at`·`resolved_name`（alias-or-label；**raw lat/lng 必留**，供未命中新點與交叉校驗）。
- **R2 新讀口「今天足跡」**：server 把 `location_history` 聚成 labeled stays（`name`·`from`·`to`·`dwell`·`centroid`·`confidence`）。「今天」以**使用者時區**算、跨午夜歸日（走 config、勿硬編）。下游只吃「面」、不碰 raw 點。
- **R4 邊界不變**：兩讀口一律走 read-only Edge Function（A 模式：service_role owner-scope）→ bridge 寫本地檔 → 下游只讀本地檔（D9）。

**待調（spike，非現在拍板）**：停留段偵測（半徑 + 最短停留 + gap）拿真實資料調；stays 品質隨 history 累積 + 調參才成熟，`confidence` 欄承接初期粗糙。

## 平台能力對照（已對 Supabase 官方 docs 坐實）

| 需求 | 用什麼 |
|---|---|
| 讀最新 / 即時朋友 | Postgres + Realtime（**Postgres Changes 尊重 RLS** —— 只推被授權看到的列） |
| 行程輪廓 / 地理查詢 | Postgres + PostGIS（官方支援擴充） |
| 三十天封存排程 | pg_cron / Supabase Cron |
| headless 讀取認證 | Edge Function `auth: 'secret'`（apikey header 帶 secret） |

## 待驗（build-time spike，非現在）

開一個丟棄式本地 Supabase（`supabase start`，純本機、免帳號）跑端到端：雙表 + RLS + Realtime，用兩個測試帳號驗「RLS 有沒有正確擋掉不該看的列」。驗綠才 commit app 那側。
