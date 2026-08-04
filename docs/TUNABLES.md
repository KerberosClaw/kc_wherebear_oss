# TUNABLES — 可調參數速查

> **English summary:** A quick-reference for kc_wherebear's tunable behavior parameters and where each one lives in the source. It lists the stay-detection thresholds (minimum dwell, cluster radius, gap), the app's location-report frequencies and desired accuracy for saver/standard modes, the bridge daemon's poll interval, and the geocode cache's coordinate-rounding precision. It also covers the core-window union used when fusing a CLVisit dwell with a GPS cluster, and the app-side dedup window that drops a location fix delivered twice by two triggers. It also documents the versioned place-name adjudication policy — evidence-window bounds, the two vote thresholds, the live-fix accuracy cutoff, and the age limit past which an event is no longer pushed to the realtime channel. It also covers the stay-settling evidence thresholds and the 24-hour grace period bounding how long an unclosed stay may keep claiming presence. It records current values only — to change a parameter, edit it at its source.

> 「行為門檻／頻率」類參數的單一速查。**問參數先看這、免撈 code。** 本檔只記現值＋來源位置；要改請改對應來源。
> 🔴 born-clean：本檔只有通用參數，無座標／金鑰／身分。

## 停留段偵測 `detect_stays`（`supabase/migrations/*_detect_stays.sql` 的 function 預設值）

| 參數 | 現值 | 意義 |
|---|---|---|
| `p_min_dwell_s` | **600（10 分鐘）** | 同一處待逾此秒數才算一個「停留」；路過／短停不計。**時間軸只列 ≥ 此門檻的停留** |
| `p_radius_m` | 150 公尺 | 判「同一處」的半徑；離開此半徑＝換點 |
| `p_gap_s` | **28800（8 小時）** | 兩點時間差逾此＝斷開群集。🔴 **不要調回分鐘級**：人不動時 significant-change 本來就不觸發，30 分鐘會把整夜／一整個白天切成碎片（實測久坐不動最長合法沉默 7 小時 15 分；整夜的長停會整段消失）。不同地點靠下面的距離門檻擋，不靠這條 |

app 走 `my_today_stays` / `my_stays_range` / `my_stays_days`，皆用上述**預設值**。要改：改 migration 的 `default`（需 `create or replace` 重套 dev/prod），或呼叫端顯式傳參。

## 停留段合併 `stays_for_day`（D14；`supabase/migrations/*_visit_arrival_key_and_stay_merge.sql`）

| 參數 | 現值 | 意義 |
|---|---|---|
| `p_pair_radius_m` | **150 公尺** | CLVisit 段與 live 聚合段視為「同一段停留」的距離門檻（與 `detect_stays` 的 `p_radius_m` 同值）；配對成功者**時間取兩者聯集**、位置／名稱用 live 中心 |
| `p_core_radius_m` | **100 公尺** | 延伸停留邊界時，只採計「距合併中心此距離內」的 live 點首末（＝人真的在那裡的證據），把離場／接近路段排除在外 |
| alias 比對容差 | **CLVisit 自報的 `horizontalAccuracy`** | 僅套在「沒配對到 live 段」的 CLVisit 段（粗座標）；配對到的用 live 中心、容差 0。無魔術常數，舊列 `accuracy` 為 null ⇒ 不放寬 |

> **時間為什麼取「核心窗聯集」而非單純聯集**：兩邊是互補證據 —— CLVisit 在人不動時看得見（live 幾乎失明），live 在 CLVisit 沒觸發或已收尾時看得見。原規則「一律用 CLVisit」只有在 live 段必然較窄時才成立；`p_gap_s` 放寬到 8 小時後前提反過來，一整天的長停被 21 分鐘的 CLVisit 截斷。
>
> 🔴 **但不能直接取 max**：聯集單調只增，會保留兩邊所有「把區間撐大」的誤差、丟棄所有「收緊」的修正。而收緊那側正是刻意做的品質機制（`visits_close_on_departure_evidence` 算出的誠實離開時刻），撐大那側正是已知有污染的（`detect_stays` 判同一處是距**錨點**150 公尺，人往外走的頭兩百公尺仍被吃進群集）。實測某次短停：直接聯集把 9.6 分變 22.7 分，多出來的全是走路時間（延伸到的那點離該處 129 公尺、離下一個地點只剩 82 公尺）。改用核心窗後回到 9.6 分。
>
> `p_core_radius_m` 在 60～120 公尺之間輸出完全相同（平台中央，不是挑中的臨界值），**150 公尺會退化成直接聯集** —— 不要調到那裡。

> 同一地點時而解出 alias、時而掉回 geocode 路名，多半是 **landmark 自身半徑太小**（實測某個常去地點，連 live 精確中心都會落到 120 公尺外）。先調 `landmarks.radius`，不要動這裡。

## 回報頻率 `LocationReporter`（`app/wherebear_app/wherebear_app/Logic.swift`）

| 項目 | 現值 |
|---|---|
| 前景 poll · 省電（saver） | 180 秒 |
| 前景 poll · 標準（standard） | 60 秒 |
| desiredAccuracy | saver＝百米 / standard＝十米 |
| 背景 | significant-change（~500m 位移）＋ CLVisit（靜止久留，iOS 自排程） |
| 即時顯示流（地圖可見時） | 連續 `startUpdatingLocation`（`distanceFilter=10m` 濾 GPS 抖動），只刷新顯示、不寫 DB |
| 同一次定位去重視窗 | **2 秒**（`fixDedupWindow`）；座標**完全相等**且在此秒數內＝同一個 fix 被兩條觸發源各回一次，只寫一列 |
| outbox 上限 | 1000 筆 |

> 去重視窗刻意遠小於最密的回報間隔（標準輪詢 60 秒），所以不會吃掉正常取樣；比對用座標完全相等、**不是**距離門檻——距離門檻會連真實小幅移動一起丟掉。

## bridge daemon（`bridge/wherebear_bridge.py`，env 設定）

| 參數 | 現值 |
|---|---|
| `WHEREBEAR_POLL_SECONDS` | 300（5 分）；**prod 建議 600（10 分）**——下游消費者間隔更長、5 分過密 |

## event bridge（`bridge/wherebear_event_bridge.ts`，env 設定）

| 參數 | 現值 | 說明 |
|---|---|---|
| `WHEREBEAR_EVENT_COALESCE_S` | 120 | 同地點同類型事件在幾秒內只算一次（CLVisit 會抖、一天也可能進出同一處多次） |
| `WHEREBEAR_EVENT_JUDGE_TIMEOUT_S` | 300 | 下游處理程式單次執行逾時 |
| `WB_REALTIME_TOKEN_TTL_S`（function secret） | 1800 | 短效 token 存活秒數；listener 在到期前 60 秒自行重換 |

重連退避是 1s 起、每次加倍、上限 300s；連續失敗 5 次發一次 🟡（**不停止重試**——這一格壞掉不該讓下游陪葬）。

> 下游事件下游處理程式自己的節流（新鮮度、同地點冷卻、每日額度、最小間隔）**不在本 repo** —— 那些屬消費端邏輯，住消費端自己的 config。

## 停留段收尾（D15；`supabase/migrations/*_visits_autoclose_stale.sql` ／ `*_departure_evidence_adaptive_threshold.sql`）

| 參數 | 現值 | 說明 |
|---|---|---|
| 反證寬限 `gap_min` | 15 分 | 走開多久才算真的離開（**防誤關主要靠這條**，不是距離） |
| 距離門檻地板 | 120 公尺 | |
| 地標加成 | 該地標半徑 ＋ 50 公尺 | 公園之類半徑大的地方要真的走出去 |
| 誤差加成 | 停留誤差 ＋ 當前定位誤差 ＋ 100 公尺 | 兩邊定位都爛時自動放寬 |

實際門檻＝三者取大。🔴 **不要改回寫死常數**：第一版寫死 250 公尺，剛好擋不住當初要修的 209 公尺實例。

### 未關閉停留的封頂（`supabase/migrations/*_visit_open_stay_cap.sql`）

上面那三道保險都要求「之後還有新資料進來」。使用者停掉回報／刪 app／手機沒電時前提不成立，那列會永遠開著、被讀取層當成「還在那裡」畫進往後每一天。封頂是兜底。

| 參數 | 現值 | 說明 |
|---|---|---|
| `p_open_grace_s`（`visit_open_until`） | **86400（24 小時）** | 未關閉的停留最多還能宣稱到「最後一次收到任何位置回報 ＋ 此秒數」；`visits_for_day` 與 `visits_autoclose_stale` 共用同一支、不各寫一份 |

🔴 **不要把它調到分鐘級**：沉默是有歧義的 —— 人不動時 significant-change 本來就不觸發，回報開著也可能好幾小時沒有任何一筆（實測合法沉默最長 416 分鐘）。用分鐘級的值當寬限會把真實的整夜停留砍成半小時，比原本的病更糟（`detect_stays` 的 `p_gap_s` 原本設 30 分，就是踩到這個坑才改成 8 小時）。這裡取 24 小時＝遠高於實測合法沉默、且對齊「按當地日切段」的既有模型；**比 `p_gap_s` 更寬是刻意的** —— 那條管「同一段停留怎麼聚」，這條管「還能不能宣稱人在那裡」，後者該更保守。

app 端另有一層更準的：按下停止時直接 PATCH 補上 `departed_at`（`LocationReporter.closeOpenVisits`）。兩層刻意並存 —— app 那層準（知道確切時刻）、後端這層兜底（app 沒機會講話時也不會爛）。

## 事件地名裁決 `visit_event_policies`（版本化；調參＝新增一列並切換 active，**不可原地改**）

原地改會讓歷史事件無法重現當初的判準。門檻是拿既有停留做唯讀回放校準出來的，不是拍腦袋。

| 參數 | 現值 | 意義 |
|---|---|---|
| `pre_window_s` | 120 秒 | 命名證據窗的上緣：到達前多久的定位點也算數 |
| `post_window_s` | 300 秒 | 證據窗的下緣：到達後多久之內。**不隨停留長短延長** —— 到達五分鐘時還不知道最終待多久，而全域放長會直接延後所有正常的到達通知 |
| `min_agree_points` | 1 | CLVisit 座標已經判出名字時，只要**一個**嚴格定位點同名就成立（兩個不同來源互相印證） |
| `min_consensus_points` | 2 | CLVisit 沒答案或與定位點不同名時，定位點必須自己湊到**兩票**。🔴 **不要調成 1**：回放中出現過「窗內只有一筆定位點、而那筆是走路途中的點」→ 把 A 判成隔壁的 B。漏報只是安靜，誤報是信任問題 |
| `max_live_accuracy_m` | 100 公尺 | 誤差大於此的定位點不採信 |
| `emit_horizon_s` | **1500 秒（25 分鐘）** | 事件可進即時通道的年齡上限。`arrival` 看 `arrived_at`、`departure` 看 `departed_at`。刻意小於消費端的新鮮度門檻，留傳遞餘裕。過期＝不送，且**不寫 `*_sent_at`**（假寫會讓日後真的該發時被冪等擋掉） |

**精度寬容的不對稱是刻意的**：`resolve_alias` 的四參數形式把半徑放寬成 `radius + accuracy`
且**沒有上限**，只用在「停留自身座標」這一側去提出候選；證據點那側一律嚴格（寬容 0）。
粗座標單獨命中不足以命名 —— 放寬到隔壁地標時，它會很有把握地指向錯的那個。

## 地名快取 `geocode_cache`

| 參數 | 現值 |
|---|---|
| 座標 round 精度（快取鍵） | ~11 公尺（四捨五入） |

> 下游消費端（本 repo 之外）另有自己的新鮮度與節流門檻，住該消費者自己的 config，不在本 repo。
