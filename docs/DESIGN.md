# DESIGN — kc_wherebear 後端架構與決策

> **English summary:** Records the rationale behind kc_wherebear's backend design as a numbered set of decisions (D1–D15), including choosing a self-hosted Supabase (BaaS) backend, a native Swift app, Supabase Auth + RLS bound to `auth.uid()` for writes, a read-only Edge Function for headless consumers, and the hot/cold dual-table model (`current_location` upsert + `location_history` append). It also covers the landmark-alias / reverse-geocode resolution layer, the pg_cron archival policy, the privacy stance, an optional Realtime channel for "just arrived at a named place" events (D13), how CLVisit dwells are keyed and fused with GPS-cluster stays so one visit never lands as two rows (D14), and how a stay is closed from two kinds of evidence — a newer arrival, or live positions proving the user is elsewhere (D15).

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
| **D13** | 到達／離開事件走獨立即時通道：**資料庫端解析地標 → 私有 broadcast**；消費端經 api-key 換一張「權限一無所有」的短效 token 訂閱 | headless 消費者要「剛到／剛離開命名地點」的即時信號，又不放 `service_role`／不破 D4 認證平面。實作與初稿不同，見下 |
| **D14** | `visits` 唯一鍵＝`(user_id, arrived_at)`（不含座標）；停留段＝「CLVisit 管時間、live 聚合管位置」合併 | CLVisit 同一次停留投遞兩次且座標會漂 → 鍵含座標會生出關不掉的第二列；兩種偵測各對一半，互補不可二選一。見下 |
| **D15** | 停留段的收尾接受**兩種證據**：新的到達、以及「當前位置持續在別處」的反證 | CLVisit 的離開投遞會遺失（app 被系統回收），且它對短距離移動不發新到達（實測 209 公尺、兩個半小時都沒有）→ 只等它給離開，停留會永遠開著 |

> 註：D11（`landmarks` 自訂地標 alias）、D12（alias 命中免打外部 geocode）已在 migrations／`API_CONTRACT.md` 引用、尚未回填本表；本篇順序取 D13。

### A vs B（後端型態）

選 **A：Supabase-native**（BaaS + Edge Functions），不選 **B：自架 FastAPI/servlet server**。B 的分家/自控優勢建立在團隊/部署規模上，solo 小專案沒有；A 把 DB/Auth/Realtime/RLS 全託管、只剩兩支小 Edge Function 要寫。

### 熱/冷雙表（D5 詳）

經典時序 pattern（等同 Redis 熱 + HBase 冷，但塌縮進單一 managed Postgres）：

- `current_location`：每 user 一列、`upsert`。服務「讀最新」（未來可加 Realtime、尊重 RLS）。
- `location_history`：每次回報 `insert` append。服務行程輪廓 + 封存。

**分兩張的理由不是效能**（本 scale 一張表也夠）**，是避免日後加即時功能時對 live 資料動 schema 手術**。現在多一張表＝一次性便宜保險。

欄位（初版）：`user_id` · `lat` · `lng` · `accuracy` · `captured_at`（裝置取得時間，防把舊座標當現在）· `updated_at`（server 寫入）· `place_label`（reverse-geocode 後回填）。

### 到達／離開事件即時通道（D13 詳）

`CLVisit` 靜止停留（`visits` 表）本已收「到達／離開某地」。要讓下游 headless 消費者**即時**收到（而非等 bridge 輪詢），做法是：

```
visits INSERT/UPDATE ──► 觸發器（資料庫端）
                            │  查 landmarks；沒命中就什麼都不做
                            ▼
                    realtime.send() 私有 broadcast → wb:events:<user_id>
                            │  payload 只有解析後的名字，不含原始座標
                            ▼
     消費端：wb_ key ──換發 Edge Function──► 短效 token ──► 訂閱
```

到達＝`INSERT`；離開＝`departed_at` 由 null 變成有值的那次 `UPDATE`（D14 改鍵後這兩個時機各自乾淨、不會重複觸發）。離開事件帶得出停留時長，到達不行。

**訂閱端的身分怎麼來**（這段是整個設計的重點）：`wb_` key 是自家發明的東西，只有自家 Edge Function 認得；Realtime 是平台服務、只認 JWT。所以要一次翻譯：換發端點查 `api_keys` 確認身分後，簽一張 `{role: "anon", wb_uid: <user_id>}` 的短效 token。

- `role: anon` 是**權限等級**——該角色在 `public` schema 一無所有（實測拿這張 token 打 `visits`／`landmarks`／`location_history`／`current_location`／`api_keys`／`profile` 全數 `permission denied`）。
- `wb_uid` 是**身分標籤**——`realtime.messages` 的 RLS policy 用它綁 topic。公開的 anon key 沒有這個 claim，對不上任何 topic（實測被拒）。

兩者拆開，才做得到「能收自己的事件、除此之外什麼都不能做」。token 僅存記憶體、不落檔、過期前重換。

**與初稿的差異（初稿寫的是訂閱 `visits` 的 `postgres_changes` ＋ 帳號級 user JWT）**：那條路要一把「看得見 `visits`」的 JWT，而同一把對 PostgREST 一樣有效 → 消費端權限從「兩支窄讀口」膨脹成「整個帳號讀寫」；而且「是不是命名地點」要查 `landmarks`，訂閱端得自己讀。改成資料庫端解析＋broadcast 之後兩個問題同時消失，`visits` 也不必加進 Realtime 發布集。

**放棄的替代**：
- `service_role` 直接給消費端 → 違 D4 紅線（繞 RLS 的萬能鑰匙落地）。
- anon key 直連 → 它是公開的（印在每支 app 裡），只證明「是這個專案」、不證明「是哪個人」。
- 短輪詢窄讀口 → 一天真實事件僅數次、輪詢多為空轉。

**代價**：消費端多一條長連線的可靠性負擔（重連／退避／斷路器／token 續期）＋一支換發端點（新攻擊面，見 `SECURITY.md`）。此通道與既有讀取平面（D4/D9 輪詢＋本地檔）**並行、不取代**；消費端如何反應事件（節流、是否發話）屬消費端邏輯、不在本平台契約。

**已知邊界**：離線佇列補傳會把幾小時前的到達寫進資料庫，觸發器照發 → 事件本身是「剛收到的舊事」。消費端要看 `arrived_at`／`departed_at` 判新鮮度，別看收到的時間。

### 停留段的兩種來源與合併（D14 詳）

平台有兩套互不相同的停留偵測，**各對一半**（對真實資料實測）：

| | 時間邊界 | 位置精度 |
|---|---|---|
| `CLVisit`（`visits` 表） | **準**——iOS 低耗電硬體判定，久坐不動照樣完整 | **粗**——本質是區域，同一地點落點可散在 100～200 m |
| `detect_stays`（聚合 live 點） | **破碎**——背景靠顯著移動觸發，人不動就不回報 | **準**——多點平均 |

實測同一段長時間停留：`CLVisit` 給出完整的 11 小時 32 分，聚合只給得出其中 11 分鐘。反過來，同一天聚合抓到 9 段停留、`CLVisit` 只發 4 次，漏掉的 5 段全是 11～35 分鐘的短停。

→ **不二選一，改分工合併**（`stays_for_day`）：時間邊界取 `CLVisit`、位置與名稱取「時間重疊最久且距離 ≤ 150 m」那段聚合中心；沒配對到的兩邊都原樣保留。相簿匯入點是第三條獨立分支、不參與合併（`detect_stays` 本就只吃 `source='live'`）。

**唯一鍵不含座標**：`CLVisit` 到達時投一次（`departureDate = distantFuture` → `departed_at` 留 null）、離開時同 `arrivalDate` 再投一次，而**兩次的 coordinate 不同**（實測差 33～205 m）。鍵含座標時離開那次會 INSERT 出第二列 → 同一次停留在時間軸出現兩筆、且到達那列的 `departed_at` 永遠是 null，`coalesce(departed_at, now())` 無上限地長成 19～20 小時。改鍵後離開走 UPDATE，附帶讓 D13 的 Realtime 不再收到同一次到達的第二筆 INSERT。

**跨日**：`visits_for_day` 改「與該當地日有交集就出、時間夾在當日邊界內」→ 跨午夜的停留在兩天各出一段（每日時間軸加總才合得起來），並天然把「沒收到離開事件」的列夾在單日內。

**已知邊界**：若離開事件真的遺失（app 被砍、iOS 沒回呼），該列會以「仍在停留中」的姿態延續到後續每一天（每日上限 24 小時、不再無上限）。修鍵後這種列不會再由重複投遞產生。另 `CLVisit` 的離開偵測本身是事後確認、會落後，短停的時數可能偏長。

### 停留段怎麼收尾（D15 詳）

`visits` 的一列是 CLVisit 開的，理論上也由它關（離開投遞把 `departed_at` 填上）。實機跑一晚證明**不能只靠它**：

| 失效模式 | 實測 |
|---|---|
| 離開投遞遺失 | app 被系統記憶體壓力回收，離開回呼沒人接 → 該列永遠開著 |
| 短距離移動不算「換區域」 | 移動 209 公尺到隔壁店，**兩個半小時**都沒發新到達 |

沒關掉的後果不只是少一筆時間：`visits_for_day` 會把開著的列夾在當日邊界內，於是它**以「還在那裡」的姿態出現在往後的每一天**，下游拿到的 `to` 也是 null；同時「當前位置」那條路是對的 → 同一份資料兩個來源互相打架。

所以改成接受兩種關閉證據，兩者都是**保守估計、不會高估停留**：

```
證據一：新的到達進來（人不可能同時在兩個地方）
        → 先前還開著的停留，關在新到達的時刻
        → 亂序保護：只關 arrived_at 早於新到達的列（離線佇列補傳會晚一步送舊資料）

證據二：當前位置持續在別處（反證式修剪）
        → 夠遠 ＋ 超過 15 分鐘沒回去 → 關在「最後一次還在附近的 live 點」
        → 取最後一次在附近而不是現在：用現在會把路程算進停留、時間變假長
```

**距離門檻自適應**，不寫死：地板 120 公尺／命中地標的半徑＋50（公園之類要真的走出去）／兩邊定位誤差和＋100（誤差大時自動放寬）。第一版寫死 250 公尺，剛好擋不住當初要修的 209 公尺案例 —— 門檻要從實測反推、不要挑好看的整數。**真正防誤關的是那 15 分鐘寬限，距離只負責排除 GPS 抖動。**

**與真實離開投遞的關係**：若稍後真的收到 CLVisit 離開，upsert 會把我們推得的值覆蓋成真值（更準）。事件觸發條件是「`departed_at` 由 null 變成有值」，此時已非 null → **不會重播第二次離開事件**。

**殘留邊界（明講未解）**：
- 某段停留之後再也沒有任何新到達、人也沒再回報（換手機／長期不用）→ 仍會開著。要靠排程收尾，未做。
- 反證式修剪只補「該關的沒關」，補不了「**該有的到達沒出現**」——那段停留在時間軸上是缺的。要根治得靠地標地理圍欄（`CLCircularRegion`）——進出即觸發、不受顯著移動門檻限制，代價是多一組背景事件來源要與 CLVisit 對帳。

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
