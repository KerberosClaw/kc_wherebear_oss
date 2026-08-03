# API_CONTRACT — kc_wherebear 介面 SSOT

> **English summary:** This is the single source of truth for kc_wherebear's interface contract. It defines the two authentication planes — the owner plane over Supabase PostgREST guarded by RLS, and the headless read plane over Edge Functions authenticated with a `wb_`-prefixed API key — along with the request/response payloads for every table and read endpoint. It also specifies the `resolved_name` resolution order (user alias > geocode cache > reverse-geocode > null), the timestamp/unit/timezone conventions, the error shapes and status codes, and the bridge's local JSON schema consumed by downstream readers. On the realtime event channel, `schema_version` is versioned **per `kind`** rather than globally — consumers must branch on `kind` first, then on version — and alongside `arrival`/`departure` there is a `coverage_ended` event that declares "we stopped observing", which is deliberately *not* a claim that the user left anywhere. It also specifies the two app-plane RPCs for reconsidering an unresolved adjudication and for letting the user explicitly assign a stay to a landmark, together with the age limit past which a backfilled event is no longer pushed.

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

三支（兩支讀取 ＋ 一支換發），皆 `verify_jwt=off`（不吃 GoTrue JWT，吃 API key）。

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
- **多日（app 端）**：app JWT 平面 RPC —— `my_stays_days(p_days date[], p_tz)`（**任意多天、可不連續**，行事曆多選用、上限 31 天）＋ `my_stays_range(p_from, p_to, p_tz)`（連續區間、上限 32 天）。回 `[{day, name, from, to, dwell, centroid_lat, centroid_lng, confidence, source, visit_id}]`（同 stay 形狀＋`day` 欄）、`auth.uid()` scope。單日仍用 `my_today_stays(p_day, p_tz)`（回 `{name, from, to, dwell, centroid_lat, centroid_lng, confidence, source, visit_id}`）。
  - `visit_id`：這一段停留在後端的身分，供消費端說出「我指的就是這一段」（人為指定用，見 §2.4）。`live` / `photo_import` 來源沒有對應的 visit，為 `null`。**純新增欄位**，既有消費端按 key 取值不受影響。（headless 讀口 `/today-stays` 目前仍單日；下游要範圍再另議。）
- **`source`（app 平面三口專有，migration 11、D14 擴充）**：`"live"`＝實時回報聚出的**停留段**；`"visit"`＝`CLVisit` 靜止停留（時間邊界較準，位置／名稱已與重疊的 live 段合併）；`"photo_import"`＝相簿匯入的**個別點**（`to=null`、`dwell=0`、`confidence=1`）。app 端據此在時間軸／地圖以相機 icon 標匯入點、其餘顯示編號。
- **headless `/today-stays`（D14 起）**：改吃 `stays_for_day`（`visit` ＋ `live` 合併），**仍濾掉 `photo_import`** → 下游只吃「面」不變、回應形狀不變（無 `source` 欄）。改前只吃 `detect_stays`，久坐不動的長停留在下游會縮成碎片（實測一段 11 小時 32 分的停留，下游只看到 11 分）。

### 2.3 `POST /realtime-token`（D13 事件通道換發口）

把自家的 `wb_` key 翻譯成 Realtime 認得的短效 token。**唯一會回傳憑證的端點**。

```jsonc
// 200 OK
{
  "token": "<JWT，HS256，role=anon + wb_uid claim>",
  "topic": "wb:events:<user_id>",             // 順便回，訂閱端因此不需要知道自己的 user_id
  "expires_at": "2026-01-01T12:30:00.000Z",
  "ttl_s": 1800
}
// 無 key / 無效 key / 已撤銷 → 401（同 §5）
// 伺服器未設 WB_JWT_SECRET → 500（大聲壞掉，不默默發一張沒人認得的 token）
```

- 🔴 這張 token **權限刻意一無所有**：`role=anon` 在 `public` schema 無任何表權限；身分靠 `wb_uid` claim，由 `realtime.messages` 的 RLS policy 綁 topic。拿它打 PostgREST 一律 `permission denied`。
- 消費端**只存在記憶體、不落檔**，到期前自行重換。

---

### 2.4 裁決重新考慮與人為指定（app JWT 平面 RPC）

地名裁決原本是「一次定案、永不重看」。使用者「先到新地方、再把它加成地標」這個最自然的
操作順序，會讓那一段停留永遠拿不到推播 —— 裁決在地標出生之前就跑完了。下面兩支把
「尚未送出任何事件的 `unresolved`」定義成**可晉升的暫態**（只能往 `resolved` 走，不能倒退）。

| RPC | 參數 | 回傳 | 說明 |
|---|---|---|---|
| `my_reconsider_recent_visits()` | 無 | `integer`（晉升筆數）| app 在地標存檔**成功之後**另開一個請求呼叫。冪等、可重試、失敗不影響地標已經存好。**不接受任何 user 參數**，只認 `auth.uid()`。 |
| `assign_visit_landmark(p_visit_id, p_landmark_id)` | 停留 id ＋ 地標 id | `text` 處置字串 | 使用者對著某一段停留指認地標。人類標註優先於感測器推論，不需要湊足票數。兩個 id 都必須屬於呼叫者本人。 |

`assign_visit_landmark` 的處置字串：`assigned`（成功）／`already_resolved`（已定案，不覆寫）／
`already_announced`（已對外發過事件，收不回）／`no_decision`／`race_lost`。

**刻意不做**：不在 `landmarks` 上掛同步觸發器。那會把地標存檔綁進事件管線 —— 重判、搶旗標、
寫即時訊息全在同一筆交易裡，任何一段失敗使用者看到的會是「地標存不了」。

**安全網**：權威離開（`departure_source = ios_clvisit`）到來時，後端會對仍 `unresolved`
且未送出的那段自動重判一次。所以就算 app 沒呼叫上面的 RPC（舊版、離線、從地圖建地標），
離開的時候通常也補得回來。

**補發的年齡上限**：`visit_event_policies.emit_horizon_s`（預設 1500 秒）。`arrival` 看
`arrived_at`、`departure` 看 `departed_at`。過期就**不進即時通道，而且不寫 `*_sent_at`** ——
假寫會讓日後真的該發時被冪等旗標擋掉。過期的段仍會修好時間軸上的地名，只是不推播。
消費端多半自己也有新鮮度門檻，這條刻意設得比它小、留傳遞餘裕。

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

## 6.5 事件通道（D13 · 到達／離開／回報結束）

### 6.5.1 broadcast payload

私有頻道 `wb:events:<user_id>`、event 名 `visit`。由資料庫觸發器產生。

**隱私閘**：具名事件（v1）只在落在使用者 `landmarks` 半徑內才發。
但同一個頻道上還有兩種**天生沒有名字**的事件，別誤以為「有事件＝有命中地標」：
- **v2 不具名**（`arrival`/`departure`）：有停留、但裁決判不出名字。只在「舊規則本來就會出聲」時才發
  （`legacy_would_emit`），所以**未命名地點仍維持靜默**。
- **v3 `coverage_ended`**：回報結束，與地標無關。見 §6.5.3。

```jsonc
{
  "id": "550e8400-e29b-41d4-a716-446655440000", // 送出時產生的事件 uuid（見下方說明）
  "schema_version": 1,                          // 1=具名、2=不具名；依 kind 分版，見 §6.5.2
  "kind": "arrival" | "departure",
  "name": "<landmarks alias>",                // 🔴 只有名字，不含原始座標；v2 時為 null
  "visit_id": 123,
  "arrived_at": "2026-01-01T09:00:00+08:00",
  "departed_at": "2026-01-01T18:00:00+08:00", // arrival 時為 null
  "dwell_s": 32400,                           // arrival 時為 null（那時還算不出來）
  // 以下四欄自裁決機制起隨事件一起送
  "decision_status": "resolved" | "unresolved",
  "reason_code": "clvisit_live_agree",        // 判準走哪一條
  "evidence_count": 2,                        // 支持這個名字的定位點數
  "algorithm_version": "visit_name_v1",
  "policy_version": 1
}
```

🔴 **`id` 由送出端（`realtime_send_strict`）在送出當下產生**，是這「一則訊息」的識別碼，不是業務欄位。
同一段停留的到達與離開是兩則不同訊息、`id` 不同。消費端不應拿它當停留身分 ——
那是 `visit_id` 的職責，而 `coverage_ended` 根本沒有 `visit_id`（它不綁停留）。

### 6.5.2 事件檔（下游消費契約）

event bridge 把收到的事件 append 成**每日一檔** `events_YYYYMMDD.jsonl`（當地日期），一行一則，內容＝上面的 payload 外加：

```jsonc
{ "received_at": "2026-01-01T09:00:12.345Z", ...payload }
```

- **`received_at` 只用來排序與記水位，不可拿來判新鮮度** —— 離線佇列補傳會在數小時後才把舊的到達寫進資料庫，那時 `received_at` 是「剛剛」。判新鮮度要看 `arrived_at` / `departed_at`。
- 寫入者只有 event bridge 一個，讀取端只 append-only 地往後讀。
- 同地點同類型的重複事件在 bridge 端已先合併（見 `TUNABLES.md`）。
- 🔴 **`schema_version` 依 `kind` 分版，不是全域單一版本**：同一個檔案裡不同 `kind` 的版本號各自演進
  （目前 `arrival`/`departure` 是 1（具名）與 2（不具名）、`coverage_ended` 是 3）。
  消費端要**先看 `kind` 再看版本**；只用版本號當總開關會把不相干的事件一起濾掉。
- 破壞性改動 bump 該 `kind` 的 `schema_version`；消費端對不上的版本應視為不認識、跳過。
- 🔴 **「跳過未知版本」是最終消費端的責任，不是 bridge 的。** bridge 刻意是**純轉送**：
  它的放行條件只有三條、且**刻意寬鬆**：有 `kind`，且（有 `name`／`decision_status="unresolved"`／
  `kind="coverage_ended"`）三者之一。**不檢查 `schema_version`，也不檢查該 `kind` 是否為已知類型** ——
  例如任何帶著 `decision_status="unresolved"` 的未知 `kind` 都會被放行。
  這是刻意的取捨：bridge 若自作主張過濾，新版事件在 bridge 更新前會被**永久吞掉**
  （事件是一次性的、沒有補送）。代價是 **未知版本仍會消耗下游的喚醒次數** ——
  真正的版本過濾必須做在會消耗額度的那一層。

### 6.5.3 `coverage_ended`（回報結束）

使用者按下「停止回報」時發出。**它宣告的是「我們從此看不到了」，不是「他離開了某地」** ——
這兩件事在語意上不同：按停止時人可能還待在原地。

```jsonc
{
  "id": "550e8400-e29b-41d4-a716-446655440000", // 同 §6.5.1：送出時產生的訊息 uuid
  "schema_version": 3,
  "kind": "coverage_ended",
  "occurred_at": "2026-01-01T18:00:00+08:00",       // 觀測邊界（已做時鐘防呆夾取）
  "last_observed_at": "2026-01-01T17:58:12+08:00",  // 最後一次真的看到人的時刻；無資料時為 null
  "last_known_name": "<landmarks alias>",           // 就 last_observed_at 那一點當場解析；解不出為 null
  "reason": "reporting_stop",
  "source_confidence": "inferred_from_http_shape"
}
```

- 🔴 **不帶 `dwell_s`、不帶 `visit_id`、不帶座標。** 它不是停留事件，不得被當成離開來渲染。
- `last_known_name` **只取那一個時間點的解析結果**，不往前搜尋「最後一個有名字的地方」——
  否則在未命名地點按停止時會洩漏前一個地點。
- 合併鍵是 `occurred_at`（事件本身的身分），不是地點名：
  「停止 → 開始 → 兩分鐘內再停止」是兩個合法事件，不可被時間窗合併吃掉。

## 7. 範圍界線

- app **UI** 不在本契約（交 前端層）；本契約定的是 app 邏輯層打後端的**資料形狀** + headless 讀口。
