# ROADMAP — kc_wherebear 分期

> **English summary:** The phased delivery roadmap for kc_wherebear, built on the principle that the schema is multi-user ready (`user_id` + RLS) from day one while features ship in stages. It records the completed work and current status across Phase 1 (standing up the backend, Edge Functions, bridge daemon, and app), Phase 1.5 (deploying to the cloud production project), and Phase 2 (deepening the in-app map/timeline views and adding iOS unit tests).

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
