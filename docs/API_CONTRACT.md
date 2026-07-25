# API_CONTRACT — kc_wherebear 介面 SSOT

> **English summary:** This is the single source of truth for kc_wherebear's interface contract. It defines the two authentication planes — the owner plane over Supabase PostgREST guarded by RLS, and the headless read plane over Edge Functions authenticated with a `wb_`-prefixed API key — along with the request/response payloads for every table and read endpoint. It also specifies the `resolved_name` resolution order (user alias > geocode cache > reverse-geocode > null), the timestamp/unit/timezone conventions, the error shapes and status codes, and the bridge's local JSON schema consumed by downstream readers.

> 這份是**介面契約單一真相源**。7 支 spec 的 machine-checkable AC 都掛這份 —— 任何 endpoint / payload / 錯誤形狀改動先改這裡，再改 spec，避免多消費者（app / bridge / 下游消費者）介面漂移。
> 對齊：DESIGN D1–D12、REQUIREMENT R1–R4。🔴 **born-clean**：本檔所有座標 / 金鑰 / 時間全是佔位示意值（null-island `0.0`、`wb_xxxx`），無真值。

---

## 0. 兩個認證平面（別混）

| 平面 | 誰用 | 認證 | 走什麼 | 授權 |
|---|---|---|---|---|
| **A. Owner 平面** | app（寫入 + 管理 UI） | Supabase Auth（GoTrue）**JWT**（email/密碼登入 + email 驗證） | Supabase **PostgREST** 自動 REST（直打資料表） | **RLS `auth.uid()`**（DB 內強制、跨使用者天生隔離） |
| **B. Headless 讀取平面** | bridge daemon（下游消費者 的取數層） | **API key**（`wb_` 前綴、presented 於 `apikey` header） | **Edge Function**（唯二窄讀口） | Edge Function 內用 `service_role`（繞 RLS）→ **函式自行 owner-scope**：解析 key→`user_id`、所有查詢 `WHERE user_id = 解析出的` |

**紅線**：
- `service_role` 金鑰**只**存 Supabase Edge Function secrets，**永不**進 client / repo / bridge。
- 授權邏輯全在 Postgres（RLS）＋ Edge Function 函式體，**不寫進 token/key 本身**（key 只是身分憑證、不攜權限）。
- B 平面 Edge Function 用 `service_role` 繞 RLS，所以**函式體必須自證 owner-scope**（漏掉 = 跨使用者洩漏）。

---

## 1. A 平面 — Owner 資料操作（PostgREST + RLS）

app 用 Supabase client SDK 打 PostgREST；下列每個操作 RLS 以 `auth.uid()` 綁定，跨使用者自動擋。timestamp 慣例見 §4。

### 1.1 `current_location`（熱表 · 每使用者一列 · upsert）
```jsonc
// UPSERT (onConflict: user_id)
{
  "lat": 0.0,              // float, required
  "lng": 0.0,              // float, required
  "accuracy": 0.0,         // float 公尺, required
  "captured_at": "2026-01-01T12:00:00+08:00"  // RFC3339 offset-aware, 裝置取得時間, required
  // user_id: 由 RLS/auth.uid() 注入, client 不送
  // updated_at / place_label: server 端寫, client 不送
}
```

### 1.2 `location_history`（冷表 · append · insert）
```jsonc
// INSERT (每次回報一列)
{
  "lat": 0.0,
  "lng": 0.0,
  "accuracy": 0.0,
  "captured_at": "2026-01-01T12:00:00+08:00",
  "source": "live"        // enum: "live" | "photo_import" ; 預設 "live"
}
```
- `source="photo_import"`＝時間軸相簿匯入的點（只讀 EXIF 座標+時間、不讀像素；見 DESIGN_app §3）。

### 1.3 `landmarks`（使用者自訂地標 alias · CRUD）
```jsonc
// INSERT / UPDATE
{
  "alias": "<user 命名>",  // string, required
  "lat": 0.0,              // float, required（存 geography Point）
  "lng": 0.0,              // float, required
  "radius": 100            // int 公尺, required（逐點容許誤差; radius preset）
}
// DELETE: by id (RLS 綁 auth.uid())
```
- 🔴 **runtime 寫入、絕不 migration seed**；語意標籤座標比匿名座標敏感 → RLS 嚴防跨使用者讀。

### 1.4 `api_keys`（PAT 式生命週期 · 給 B 平面用的讀取金鑰）
```jsonc
// CREATE — 產生流程（明文只回一次）
// 客端產亂數 wb_<random> → 算 sha256 → 只存 hash + 尾4碼；明文留記憶體顯示一次後丟
{
  "name": "<金鑰用途名>",      // string, required（如 "home-bridge"）
  "key_hash": "<sha256(明文)>",// string, required（DB 只存 hash）
  "key_last4": "xxxx"          // string, 遮罩顯示用（非敏感）
  // user_id: RLS 注入
}
// 回傳給 UI 的一次性明文（不落 DB）：wb_<random>  ← 顯示一次、離開不再現
// LIST → [{id, name, key_last4, created_at, last_used_at, revoked_at}]  (無 hash、無明文)
// REVOKE → set revoked_at=now() (by id, RLS 綁)
```
- 遮罩顯示格式：`wb_…{key_last4}`。明文**絕不**二次顯示、**絕不**入 DB/log/repo。

### 1.5 `profile` + 頭貼 Storage（公開讀 · 只 owner 寫）
頭圖存 **public** Storage bucket `avatars`（讀＝公開 URL，任何人可見）；**寫＝只 owner**。object 路徑約定 `{user_id}/avatar.<ext>`；`profile.avatar_path` 記該 object 路徑。
```jsonc
// 設定頭圖（A 平面 · app · JWT）：
//   1) 上傳圖到 public bucket `avatars`，object = "{auth.uid()}/avatar.<ext>"（覆蓋舊的）
//      storage RLS：INSERT/UPDATE/DELETE 只 owner 可動自己 path
//   2) upsert profile { "avatar_path": "{uid}/avatar.<ext>" }
// 顯示頭圖：public URL（誰都能載）；null → 預設通用熊
{ "avatar_path": "{uid}/avatar.<ext>" }  // nullable; 空=用預設通用熊
```
**存取**：
- **讀＝公開**（public bucket URL）—— 頭圖是展示照、非位置資料。
- **寫＝只 owner** —— `storage.objects` RLS 綁 `auth.uid()`（object path 首段 = `auth.uid()`），防他人覆蓋你的頭圖。
- 🔴 **與位置隱私脫鉤**：public 只給頭圖；`current_location` / `location_history` / 兩讀口一律照舊 auth 綁定，**不因頭圖 public 而鬆動**。

---

## 2. B 平面 — Headless 讀口（Edge Functions）

只有兩支，皆 **read-only**、皆 `verify_jwt=off`（不吃 GoTrue JWT，吃 API key）。

**通用請求 header**：
```
x-wb-key: wb_xxxxxxxxxxxx    // B 平面 API key 明文（用 x-wb-key，避開 Supabase gateway 的 apikey）
```
> 註：cloud 上呼叫者另需帶 gateway `apikey: <anon>`（本機 functions serve 無 gateway，免帶）。
Edge Function：取 header key → `sha256` → 查 `api_keys` where `key_hash=` 且 `revoked_at IS NULL` → 命中得 `user_id` 並更新 `last_used_at`；未命中 → **401**。後續查詢一律 `WHERE user_id = 解析出的`。

### 2.1 `GET /last-location`（R1）
當前位置。`resolved_name` 解析見 §3。
```jsonc
// 200 OK
{
  "lat": 0.0,
  "lng": 0.0,
  "accuracy": 0.0,
  "captured_at": "2026-01-01T12:00:00+08:00",  // 裝置取得時間（下游判新鮮度用）
  "resolved_name": "<alias 或 geocode label 或 null>"
}
// 尚無任何回報 → 見 §5「空資料」約定（回 200 + null 欄位，非 404）
```
- 🔴 **raw `lat`/`lng` 一律保留**（未命中 alias 的新點、交叉校驗；下游不單靠 label）。

### 2.2 `GET /today-stays`（R2）
今天的 labeled stays 陣列。「今天」以**使用者時區**算、跨午夜正確歸日（tz 走 config，見 §4）。
```jsonc
// 200 OK
{
  "date": "2026-01-01",     // 使用者時區當地日期
  "tz": "<IANA tz, 走 config>",
  "stays": [
    {
      "name": "<alias 或 geocode label>",
      "from": "2026-01-01T09:00:00+08:00",
      "to":   "2026-01-01T11:30:00+08:00",
      "dwell": 9000,          // int 秒（停留時長）
      "centroid_lat": 0.0,
      "centroid_lng": 0.0,
      "confidence": 0.0       // float 0..1（稀疏點聚出的段給低值 → 下游措辭 hedge）
    }
  ]
}
// 今天無點 → stays: []（非 404）
```
- server 端把 raw 點聚成停留段（stay-point detection；半徑/最短停留/gap 參數 spike 調）；**下游只吃「面」、不碰 raw 點**。
- **多日（app 端）**：app JWT 平面 RPC —— `my_stays_days(p_days date[], p_tz)`（**任意多天、可不連續**，行事曆多選用、上限 31 天）＋ `my_stays_range(p_from, p_to, p_tz)`（連續區間、上限 32 天）。回 `[{day, name, from, to, dwell, centroid_lat, centroid_lng, confidence, source}]`（同 stay 形狀＋`day` 欄）、`auth.uid()` scope。單日仍用 `my_today_stays(p_day, p_tz)`（回 `{name, from, to, dwell, centroid_lat, centroid_lng, confidence, source}`）。（headless 讀口 `/today-stays` 目前仍單日；下游要範圍再另議。）
- **`source`（app 平面三口專有，migration 11、D14 擴充）**：`"live"`＝實時回報聚出的**停留段**；`"visit"`＝`CLVisit` 靜止停留（時間邊界較準，位置／名稱已與重疊的 live 段合併）；`"photo_import"`＝相簿匯入的**個別點**（`to=null`、`dwell=0`、`confidence=1`）。app 端據此在時間軸／地圖以相機 icon 標匯入點、其餘顯示編號。
- **headless `/today-stays`（D14 起）**：改吃 `stays_for_day`（`visit` ＋ `live` 合併），**仍濾掉 `photo_import`** → 下游只吃「面」不變、回應形狀不變（無 `source` 欄）。改前只吃 `detect_stays`，久坐不動的長停留在下游會縮成碎片（實測一段 11 小時 32 分的停留，下游只看到 11 分）。

---

## 3. `resolved_name` 解析規則（R1/R2 共用）

座標 → 名稱，固定優先序：
1. **使用者 alias**：座標落某 `landmark.radius` 內 → 回該 `alias`。多點重疊取**最近 / 最小半徑**。
2. **通用 reverse-geocode label**：無 alias 命中 → server 端 geocode Edge Function 回 label。
3. **null**：兩者皆無 → `resolved_name = null`（raw 座標仍在）。
- 優化（D12）：先查 alias、命中就**免打**外部 geocode API。
- **app 平面地名**（migration 14）：三個 stay RPC 的 name 走 `resolve_name` ＝ **alias > `geocode_cache` > null**——已查過的座標**後端 SQL 一次帶回快取地名**（`geocode_cache` 是 service_role only，`resolve_name` SECURITY DEFINER 以 owner 讀）。只有「**快取還沒有的新座標**」才由 app 呼叫 `geocode` Edge Function（owner JWT，**重用 `_shared/geocode.ts` 同一支 Nominatim**）補查 → 存快取 → 下次 SQL 就有。地名來源全 app ＋ 下游一致、**不走裝置端 geocoder（如 Apple）**。快取鍵＝座標四捨五入 4 位（app／function／SQL 一致）。

---

## 4. 慣例（時間 / 單位 / 時區）

| 項目 | 約定 |
|---|---|
| 時間戳 | **RFC3339 offset-aware**（`2026-01-01T12:00:00+08:00`）；naive 一律拒（422） |
| `captured_at` vs server 時間 | `captured_at`＝裝置取得時間（防把舊座標當現在）；server 另記 `updated_at` |
| `dwell` | int **秒** |
| `accuracy` / `radius` | float / int **公尺** |
| `confidence` | float **0..1** |
| 時區 | **走 config、勿硬編**；「今天」邊界、跨午夜歸日皆以使用者時區算 |
| 座標 | WGS84 十進位度；lat/lng float |

---

## 5. 錯誤形狀 + status code

統一錯誤 body：
```jsonc
{ "error": { "code": "<machine_slug>", "message": "<友善、不洩安全細節>" } }
```

| code | 意義 | 觸發 |
|---|---|---|
| **401** unauthenticated | 沒帶 / 帶錯憑證 | A 平面：JWT 缺/過期；B 平面：`apikey` 缺 / 無匹配 hash / 已 revoke |
| **403** forbidden | 已認證但無權 | RLS 擋下（讀別人列） |
| **404** not found | 資源路徑不存在 | 打了不存在的 endpoint |
| **422** unprocessable | payload 形狀/型別錯 | 缺必填、naive timestamp、型別不符、`radius`≤0 等 |
| **200 + 空** | 「查得到但沒資料」**不是錯** | `/last-location` 尚無回報 → 欄位 null；`/today-stays` 今天無點 → `stays: []` |

- 認證（401）與授權（403）**分清**：憑證問題是 401、憑證有效但無權是 403。
- 錯誤 `message` 友善、**不洩安全細節**（DESIGN_app 登入規則）。

---

## 6. bridge 本地 JSON schema（D9 / R4 · 下游消費契約）

bridge daemon 拉 §2 兩讀口 → **atomic 寫**一份本地 JSON；下游（消費端 reader）**只讀本地檔、永不自己打後端**。網路只在 bridge 這格。

檔名（示意）：`wherebear_location.json`（實際路徑走 config）。
```jsonc
{
  "meta": {
    "fetched_at": "2026-01-01T12:05:00+08:00",  // bridge 抓取時間（下游算檔案新鮮度用）
    "schema_version": 1
  },
  "current": {                    // 對應 §2.1；抓取失敗/無資料時為 null
    "lat": 0.0,
    "lng": 0.0,
    "accuracy": 0.0,
    "captured_at": "2026-01-01T12:00:00+08:00",
    "resolved_name": "<alias/label/null>"
  },
  "today": {                      // 對應 §2.2
    "date": "2026-01-01",
    "tz": "<IANA tz>",
    "stays": [ /* §2.2 stay 物件 */ ]
  }
}
```
- **原子寫**（temp 檔 + rename），避免下游讀到半截。
- `current` 為 `null` = bridge 這輪抓不到（下游據此 hedge，不當「人在 null-island」）。
- 下游用 `meta.fetched_at` + `current.captured_at` 各自判新鮮度、對過時 hedge（R4：下游需 `captured_at`）。
- `schema_version` 供未來相容演進；破壞性改動 bump 版本 + 更新本契約。

---

## 7. 範圍界線

- app **UI** 不在本契約（交 前端層）；本契約定的是 app 邏輯層打後端的**資料形狀** + headless 讀口。
