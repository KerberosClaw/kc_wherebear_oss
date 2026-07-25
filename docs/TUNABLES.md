# TUNABLES — 可調參數速查

> **English summary:** A quick-reference for kc_wherebear's tunable behavior parameters and where each one lives in the source. It lists the stay-detection thresholds (minimum dwell, cluster radius, gap), the app's location-report frequencies and desired accuracy for saver/standard modes, the bridge daemon's poll interval, and the geocode cache's coordinate-rounding precision. It records current values only — to change a parameter, edit it at its source.

> 「行為門檻／頻率」類參數的單一速查。**問參數先看這、免撈 code。** 本檔只記現值＋來源位置；要改請改對應來源。
> 🔴 born-clean：本檔只有通用參數，無座標／金鑰／身分。

## 停留段偵測 `detect_stays`（`supabase/migrations/*_detect_stays.sql` 的 function 預設值）

| 參數 | 現值 | 意義 |
|---|---|---|
| `p_min_dwell_s` | **600（10 分鐘）** | 同一處待逾此秒數才算一個「停留」；路過／短停不計。**時間軸只列 ≥ 此門檻的停留** |
| `p_radius_m` | 150 公尺 | 判「同一處」的半徑；離開此半徑＝換點 |
| `p_gap_s` | 1800（30 分鐘） | 兩點時間差逾此＝斷開群集（中間沒回報視為離開） |

app 走 `my_today_stays` / `my_stays_range` / `my_stays_days`，皆用上述**預設值**。要改：改 migration 的 `default`（需 `create or replace` 重套 dev/prod），或呼叫端顯式傳參。

## 停留段合併 `stays_for_day`（D14；`supabase/migrations/*_visit_arrival_key_and_stay_merge.sql`）

| 參數 | 現值 | 意義 |
|---|---|---|
| `p_pair_radius_m` | **150 公尺** | CLVisit 段與 live 聚合段視為「同一段停留」的距離門檻（與 `detect_stays` 的 `p_radius_m` 同值）；配對成功者時間用 CLVisit、位置／名稱用 live 中心 |
| alias 比對容差 | **CLVisit 自報的 `horizontalAccuracy`** | 僅套在「沒配對到 live 段」的 CLVisit 段（粗座標）；配對到的用 live 中心、容差 0。無魔術常數，舊列 `accuracy` 為 null ⇒ 不放寬 |

> 同一地點時而解出 alias、時而掉回 geocode 路名，多半是 **landmark 自身半徑太小**（實測某個常去地點，連 live 精確中心都會落到 120 公尺外）。先調 `landmarks.radius`，不要動這裡。

## 回報頻率 `LocationReporter`（`app/wherebear_app/wherebear_app/Logic.swift`）

| 項目 | 現值 |
|---|---|
| 前景 poll · 省電（saver） | 180 秒 |
| 前景 poll · 標準（standard） | 60 秒 |
| desiredAccuracy | saver＝百米 / standard＝十米 |
| 背景 | significant-change（~500m 位移）＋ CLVisit（靜止久留，iOS 自排程） |
| 即時顯示流（地圖可見時） | 連續 `startUpdatingLocation`（`distanceFilter=10m` 濾 GPS 抖動），只刷新顯示、不寫 DB |
| outbox 上限 | 1000 筆 |

## bridge daemon（`bridge/wherebear_bridge.py`，env 設定）

| 參數 | 現值 |
|---|---|
| `WHEREBEAR_POLL_SECONDS` | 300（5 分）；**prod 建議 600（10 分）**——下游消費者間隔更長、5 分過密 |

## 地名快取 `geocode_cache`

| 參數 | 現值 |
|---|---|
| 座標 round 精度（快取鍵） | ~11 公尺（四捨五入） |

> 下游消費端（本 repo 之外）另有自己的新鮮度門檻，其參數住該消費者自己的 config，不在本 repo。
