# wherebear — Android 版移植

Kotlin + Jetpack Compose 原生 app，對接**現有的** Supabase 後端。
後端（migrations / Edge Functions / RLS / RPC）**一行都不用改** —— 這個 app 走的是
`docs/API_CONTRACT.md` 定義的同一組 A 平面介面，兩支 app 可以同時連同一個專案、同一個帳號。

> ⚠️ **這份程式碼還沒編譯過。** 產出環境沒有 Android SDK / Gradle 網路，所以能保證的是
> 邏輯與契約對得上、Android API 的用法對得上；**編譯層級的小錯（漏 import、型別、
> Compose 版本差異）請預期第一次 build 會有幾個**。先跑 `./gradlew :app:assembleDebug`。

---

## 1. 先跑起來

```bash
cp local.properties.example local.properties   # 填端點 / anon key / Maps key
./gradlew :app:assembleDebug
./gradlew :app:test                            # 純函式單測（isRedundantFix）
```

`local.properties`（gitignored，對應 iOS 的 `Config.local.swift`）要填四樣：

| key | 說明 |
|---|---|
| `WB_SUPABASE_URL` / `WB_SUPABASE_ANON_KEY` | prod 專案（release build 用） |
| `WB_DEV_SUPABASE_URL` / `WB_DEV_SUPABASE_ANON_KEY` | 本機 supabase（debug build 用；模擬器要連本機 supabase 的話，宿主機別名見 Android Emulator Networking 官方文件，port 54321） |
| `WB_MAPS_API_KEY` | Google Cloud Console → Maps SDK for Android |

dev/prod 用 **build type** 切（debug=dev、release=prod），對應 iOS 的 `DEV` 編譯旗標。
debug 版 applicationId 帶 `.dev` 後綴 → 兩版可以並存在同一支手機上。

---

## 2. 三個真正需要重新設計的地方

移植的九成是機械翻譯。真正需要判斷的是這三件事。

### 2.1 背景回報：前景服務取代 `UIBackgroundModes`

iOS 靠 significant-change ＋ `CLVisit` 讓系統偶爾把 app 叫醒；Android 沒有這套喚醒機制，
唯一穩定的背景定位載體是 **foreground service**（`ReportingService`）。

取捨很清楚：
- **好處**：只要服務活著，定位就穩定進來，不受 Doze 影響。原專案在 iOS 上踩過的
  「冷啟動沒註冊監控 → 好幾小時空白」，在 Android 這邊結構上不會發生（`START_STICKY` ＋ 開機接回）。
- **代價**：通知列會**常駐一則通知**，系統規定拿不掉。使用者看得見自己正在被記錄 ——
  以這個專案的立場來說，這其實不算壞事。

權限流程也不同：Android 10 起「一律允許」不能跟前景定位一起要，必須先拿前景、之後單獨要背景；
Android 11 起系統連第二次彈窗都不給，**只能把人帶去設定頁自己選**。
`MainActivity` 拆成 `requestLocationPermission()` / `requestBackgroundPermission()` 兩段就是為此。

### 2.2 `CLVisit` 沒有等價品 → 自己判（`StationaryDetector`）

這是整份移植唯一「Android 沒有對應 API」的地方。候選方案與否決理由：

| 方案 | 為什麼不用 |
|---|---|
| Geofencing API 的 `DWELL` transition | 只在**事先註冊的圈內**有效 → 覆蓋不了「今天第一次去的咖啡店」，而那正是 stay 最有價值的部分 |
| Activity Recognition API | 回的是「靜止/走路/開車」，沒有位置語意，還要再自己聚一次 |
| 全交給後端 `detect_stays` | 原專案 D14 已經證明過這條路的下場：一段 11 小時 32 分的停留，下游只看到 11 分 |

所以自己判：拿回報流**本來就會產生**的定位點（不額外耗電），維持一個 anchor —
點落在 `VISIT_RADIUS`(120m) 內就延長、待滿 `VISIT_MIN_DWELL`(5 分) 就開一段 visit、
離開 `VISIT_DEPART`(250m) 就關掉。

能這樣做的關鍵是**後端的去重鍵是 `(user_id, arrived_at)`** ——
第二次投遞帶 `departed_at` 走 `merge-duplicates` 就是更新同一列，
跟 iOS 端送出去的形狀一模一樣，後端完全不知道也不必知道這是哪支 app 送的。

半徑與門檻在 `Config` 裡，實際跑一陣子再調（跟原專案 `TUNABLES.md` 的態度一樣）。
120m/250m 之間刻意留了一段灰帶不做判定 —— GPS 在室內漂 150m 很常見，那段不該既算「還在」也算「走了」。

### 2.3 相簿匯入的隱形陷阱

Android 10 起 MediaStore **預設把照片的位置資訊洗掉**再給你。要拿到真座標必須兩件事都做到：
1. 宣告並取得 `ACCESS_MEDIA_LOCATION`
2. 用 `MediaStore.setRequireOriginal(uri)` 取原始檔

少任一步的症狀是：**不報錯、掃出 0 張**。這種安靜的失敗最難查，所以寫在這裡。

---

## 3. 對照表

| iOS | Android | 檔案 |
|---|---|---|
| `WBClient.swift`（URLSession） | OkHttp，同樣手刻、不用 Supabase SDK | `net/WBClient.kt` |
| `WBAuth` + UserDefaults refresh token | `WBAuth` + EncryptedSharedPreferences | `net/WBAuth.kt` |
| 401 → refresh → retry（coalesce） | 同左，`Mutex` + 共用 `Deferred` | `WBClient.tryRefresh` |
| `SupabaseSession` | `SessionViewModel` | `vm/SessionViewModel.kt` |
| `LocationReporter`（`CLLocationManager`） | `LocationReporter`（大腦）＋ `ReportingService`（取點） | `location/` |
| `significantLocationChanges` | FusedLocation `BALANCED_POWER` + 批次遞送 | `ReportingService` |
| `CLVisit` | `StationaryDetector`（自刻） | `location/StationaryDetector.kt` |
| 冷啟動恢復（UserDefaults 開關） | 同左 ＋ `BootReceiver` ＋ `START_STICKY` | `location/BootReceiver.kt` |
| `isRedundantFix` | 逐條照搬（純函式、有單測） | `LocationReporter.isRedundantFix` |
| outbox / visitOutbox | 同構，存 SharedPreferences | `location/Outbox.kt` |
| `LocationVM` | `LocationViewModel` | `vm/LocationViewModel.kt` |
| `LandmarkManager` / `ApiKeyManager` / `ProfileManager` | 三個對應 ViewModel | `vm/` |
| `PhotoImporter`（PHAsset） | MediaStore + ExifInterface | `photo/PhotoImporter.kt` |
| MapKit `Map` | Google Maps Compose | `ui/MapHomeScreen.kt` |
| `BearTheme.swift` | 同一組色票 | `ui/theme/BearTheme.kt` |
| Keychain / `SecRandomCopyBytes` | `SecureRandom` + `MessageDigest` | `vm/ApiKeyViewModel.kt` |

### 刻意保留的行為

- **地名不走裝置端 Geocoder**。Android 的 `Geocoder` 是 Google 的；走它會讓 app 顯示的地名
  跟 bridge / 下游不一致。維持契約 §3：alias → `geocode_cache` → 自家 geocode Edge Function（Nominatim）。
- **停止回報時收掉還開著的停留**（`PATCH visits where departed_at is null`）。
  少了這步，讀取層看到空的 `departed_at` 會當成「人還在那裡」，往後每天都畫一段。
- **API key 明文只出現一次**，DB 只存 sha256 + 尾 4 碼。
- **地標只在 runtime 寫入**，絕不 seed。

---

## 4. 還沒做的

第一版對齊了功能面，這幾項是 UI 深度上的差距：

- **時間軸只有「今天／昨天／近 7 天」快選**，iOS 的月曆多選（`my_stays_days` 任意多天）沒做。
  RPC 呼叫已經接好（`LocationViewModel.setSelectedDays` 吃任意 `List<LocalDate>`），
  缺的只是月曆 UI ＋ `my_recorded_days` 的有記錄日標記（函式也已備好）。
- **地圖上沒畫 stays 的編號 pin 與 live 軌跡線**。資料都在（`stays` / `livePoints`），
  少的是 `Polyline` + 自訂 marker 那幾十行。
- **長停留命名卡沒有觸發源**。`landmarkVm.promptLongStay()` 已備好，
  要接的是「`StationaryDetector` 開了一段 visit 且該座標沒命中任何 landmark」時去呼叫它。
- **Realtime 事件通道（D13 / `realtime-token`）沒接**。那是 bridge 的消費面，app 端可有可無。
- **splash 的金句輪播、皮克敏斜紋進度條、熊掌動畫**：目前是素的 Material 進度條。
  `Taglines.json` 可以直接搬進 `res/raw/`。
- **app icon / LaunchImage** 沒放（原 repo 的圖是 iOS asset catalog 格式）。

---

## 5. 一個建議

Google Maps 需要 API key、而且會把地圖請求送到 Google —— 對一個「不想把移動軌跡交給第三方」
的專案來說，這一塊有點刺眼。**位置資料本身沒有外流**（座標只進你自己的 Supabase），
但你瀏覽地圖的區域會被 Google 看到。

真的介意的話，`MapHomeScreen` 是唯一綁 Maps SDK 的檔案，換成 **MapLibre 或 osmdroid** 只動那一支，
而且跟已經在用 Nominatim 的後端是同一個生態。要換的話再說一聲。

---

## 附註：gradle wrapper

`gradle/wrapper/gradle-wrapper.properties` 有給（Gradle 8.9），但 `gradlew` 腳本與
`gradle-wrapper.jar` 是二進位／可執行檔，沒放進來。用 Android Studio 開專案會自動補齊；
或本機已有 gradle 的話：

```bash
gradle wrapper --gradle-version 8.9
```
