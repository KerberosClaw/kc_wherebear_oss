# ROADMAP — kc_wherebear 分期

> **English summary:** The phased delivery roadmap for kc_wherebear, built on the principle that the schema is multi-user ready (`user_id` + RLS) from day one while features ship in stages. It records the completed work and current status across Phase 1 (standing up the backend, Edge Functions, bridge daemon, and app), Phase 1.5 (deploying to the cloud production project), and Phase 2 (deepening the in-app map/timeline views and adding iOS unit tests). It then sets out the frozen scope for Phase 3 (adding Google SSO to existing accounts while keeping email/password as a fallback, plus the reasoning for holding the OAuth client on a dedicated project account rather than a personal one) and Phase 4 (link-based location sharing through a static web page with revocable, non-JWT tokens, plus an opt-in high-frequency live mode), followed by an explicitly unscheduled backlog.

原則：**schema 從第一天就多使用者 ready（`user_id`+RLS），功能分期上線** —— 避免日後對 live 資料動 schema 手術。

> **現況（2026-07-24）**：**Phase 1 + 1.5 完成、prod 已上線在用** —— 雙認證平面 / Edge Functions / bridge / 手機回報 / 下游 reader 全鏈路走通並部署上雲；期間補上 reactive JWT 續期修復、CLVisit 停留 durable 化、iOS 單元測試（Swift Testing）。全景架構見 [`ARCHITECTURE.md`](ARCHITECTURE.md)、安全待驗見 [`SECURITY.md`](SECURITY.md)。

## Phase 1 — 後端立起來 ✅（dev 完成）

**後端：**
- [x] Supabase 專案（本地 `supabase start` dev；migrations 見 `supabase/migrations/`）
- [x] migrations：`current_location` + `location_history`(geography) + `landmarks` + `api_keys`(hashed) + `profile` + RLS（全綁 `auth.uid()`）
- [x] 頭貼 **public** `avatars` bucket（讀公開/寫只 owner）+ `profile.avatar_path`
- [x] 寫入路徑：app upsert current + insert history（RLS 擋、實測綠）
- [x] API key 認證：hashed `wb_` key + read-only Edge Function（`resolve_api_key` owner-scope；revoke→401 per-key 實測）
- [x] reverse-geocode Edge Function + alias 解析（`resolve_name`＝alias > `geocode_cache` > null）
- [x] **R1** last-location（`resolved_name` + raw 座標 + `captured_at`）
- [x] **R2** today-stays（`detect_stays` 停留段、使用者時區歸日、`confidence`）
- [x] pg_cron 三十天封存（搬 archive）
- [x] bridge daemon：拉兩讀口 → atomic 寫本地 JSON（`API_CONTRACT §6` 契約、下游 reader 端到端驗過）

**Phase 1 期間額外落地（原規劃外、實測驅動）：**
- [x] **CLVisit 靜止停留**（`visits` 表）補 `detect_stays` 抓不到的久坐（鎖屏靜止不寫點 → 靠 CLVisit 兜）
- [x] **geocode_cache** 快取表（同座標免重打 Nominatim、跨使用者共用只存公開地名）
- [x] **多日 stay RPC**（`my_stays_range` / `my_stays_days`，行事曆多選/區間）+ `my_recorded_days`
- [x] **相簿匯入點**（`source=photo_import`，只讀座標+時間、不讀像素）
- [x] `detect_stays` 參數 real-data spike 定案（150m / 停 10 分 / gap 30 分，見 [`TUNABLES.md`](TUNABLES.md)）

**app（前端層 UI + repo 邏輯層）：**
- [x] 邏輯層 managers（`LocationReporter` / `SupabaseSession` / `LocationVM` / `PhotoImporter` / `ApiKeyManager` / `ProfileManager` / `LandmarkManager`）
- [x] 地標命名 UX（三觸發：長停留卡片／時間軸 stay／手動 ＋ radius preset ＋ 清單編輯/刪除，含離線 CRUD 不靜默丟失）
- [x] UI 全畫面（地圖／時間軸／設定／金鑰子頁／登入／地標）＋ 啟動 splash（斜紋進度條 + 金句輪播）
- [x] 回報策略：前景 poll（靜止也寫）+ 背景 significant-change + CLVisit + 離線 outbox + 顯示即時流（不寫 DB）

## Phase 1.5 — 上雲 prod ✅（完成，2026-07-24）

dev 全綠 → 已搬上線、prod 每天在用。
- [x] 雲端 Supabase 專案 + 套 migrations（`supabase db push`）
- [x] Edge Functions 部署（last-location / today-stays `verify_jwt=off` 吃 API key；geocode 留 JWT）
- [x] app 指向 prod（`Config.swift` 綁 `#if DEV`：預設 prod、DEV 旗標才 dev；prod anon key 走 gitignored `Config.local.swift`）
- [x] bridge 指向 prod 讀口 + 常駐排程（launchd）
- [~] prod 端 RLS 再驗一輪：anon 打表 `permission denied` ✓ / 空資料 200 ✓ 已驗；**revoke 生效 / 跨使用者 IDOR 待驗** → 追蹤於 [`SECURITY.md`](SECURITY.md)

## Phase 2 — app 檢視深化（大致完成）

- [x] MapKit 時間軸（停留段列表 + 地圖軌跡 + 行事曆選日期）
- [x] 停留段演算法：初版 real-data spike 定案（隨 history 累積持續調、`confidence` 承接初期粗糙）
- [x] iOS 單元測試（Swift Testing）：WBClient JWT `401→refresh→retry` / CLVisit 停留 outbox durability 回歸（`app/wherebear_app/wherebear_appTests/`）

## Phase 3 — Google SSO（登入基建，小）

- [ ] 既有帳號掛 Google 身分（uid 不變、email 逐字相同）
- [ ] email/密碼**留著當備援**（單使用者系統多留一把鑰匙，無攻擊面代價）

> 登入基建先換好、排在分享功能之前 —— 遷移成本隨帳號數成長，越早換越便宜，之後進來的人也不受影響。

### 專案 SSO 帳號（已拍板）

**另開一個專用 Google 帳號當本專案的 SSO admin，不掛維運者的私人帳號。** 未來要串其他 provider（Apple、Meta…）也一律用這個帳號去申請，讓「身分供應商的管理權」集中在一個與私人生活分離的帳號上。

理由不是整潔，是**單點故障**：OAuth client 掛在私人帳號上，那個帳號一旦被鎖、停用或棄管，**整個登入一起死**，app 就進不去了。

開之前先把這幾件想清楚：

- 🔴 **不可讓新帳號成為唯一 owner** —— GCP 專案要加第二個 owner（或至少留一條復原路徑）。分離的目的是隔離風險，不是換一個新的單點；這條沒做，分開反而更脆弱。
- 🔴 **新帳號自身有存活風險** —— 長期無活動、只用於管理的帳號被判濫用而停用的機率不低。要綁手機驗證、設復原信箱、偶爾登入。
- 🔴 **發佈狀態會影響體感** —— consent screen 留在 **Testing** 會讓 refresh token 約 7 天過期，等於每週被踢出來重新登入一次。scope 僅 `openid` / `email` / `profile`（非敏感）時，切 **In production** 通常免人工審核。⚠️ Google 這塊政策改過數次，動之前看 console 上的說明，不要照這份文件當定論。
- **scope 只要那三個** —— 多勾任何敏感 scope 就會掉進 verification 流程。
- **各 provider 的限制不對稱** —— Apple Developer 綁的是 Apple ID（$100/年＋實名，付款與實名無法轉移到專案帳號）；Meta 對新開、無社交活動的帳號審核嚴格，可能要求證件或直接鎖，需提前養或改用既有帳號（後者又回到單點問題，取捨自負）。
- **帳號本身當資產管理** —— 密碼進密碼管理器、2FA 備份碼離線保存、復原信箱指向維運者的私人信箱。它掛掉不是一個 provider 死，是全部一起死。

> born-clean：本 repo 一律以「專案 SSO 帳號」代稱，**不寫實際 email**；真值只留在部署者自己的本機筆記。

## Phase 4 — 分享連結 ＋ 即時模式（一包做完）

> 原「多人＋信任帳號分享」構想改判為**連結制**：app 沒上架，朋友裝不了 app，
> 連結＋網頁是朋友唯一點得開的形態；日後 app 上架，連結對沒裝 app 的人依然有用。

**web（Cloudflare Worker ＋ Leaflet/OSM，零費用零金鑰）：**
- [ ] 分享頁：只顯示**當前位置一個點**（熊掌 pin）＋更新時間——不給地名/alias、不給足跡與歷史
- [ ] token 走**名冊制、非 JWT**：`share_tokens` 表（不記名亂碼、效期、首用綁 cookie、撤銷＝刪列即刻生效）
- [ ] 效期預設 2h，產生時可選 1/2/4/8
- [ ] 網頁輪詢更新（即時模式期間 5~10s、否則 30~60s，數字進 [`TUNABLES.md`](TUNABLES.md)）；**不用 WebSocket**——延遲主要來自手機回報間隔，長連線省不到東西還得上 Durable Objects；日後體感不足再只動 web/Worker 升級推送

**app：**
- [ ] 「即時模式」（高頻回報）：預設不啟用；手動啟用跳「超耗電」提醒
- [ ] 產生分享連結時跳提醒並**預設啟用即時模式**；連結失效（到期或撤銷）→ **自動調回標準模式**（app 自產連結、自知效期，本地鬧鐘即可，不需後端回通知）

🔴 **開工前單獨跑一輪連結制安全審查**（`share_tokens` 的 RLS、Worker 讀口權限、token 熵與比對方式），別跟功能混。

## Backlog — 觸發條件到了才做（明確不排期）

| 項目 | 觸發條件 |
|---|---|
| 帳號制好友分享（登入＋信任名單＋RLS 可見性） | app 上架之後 |
| app 上架（Apple Developer $100/年） | 哪天決定花這筆錢 |
| 事件持久化 outbox（斷線時推播事件可能永久漏掉） | 真的發生「漏掉一則重要推播」 |
| 分享期間之外的推送式即時（WebSocket/SSE） | Phase 4 上線後實測體感真的頓 |
| i18n | 決定 publish 時 |

> 「24h 封頂實證」「coverage_ended 首發」不是工項——等日常使用自然發生，發生時核對銷帳。
