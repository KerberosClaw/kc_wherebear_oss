# DEPLOYMENT — kc_wherebear 上線 / 切端點 runbook

> **English summary:** A repeatable runbook for deploying kc_wherebear to production, switching the app between the local dev backend and the cloud prod backend, and running dev and prod app variants side by side on one device. It covers loading Supabase credentials without interactive login, pushing migrations and deploying Edge Functions, verifying prod (migration alignment, endpoint liveness, RLS isolation, empty-data behavior), and the one-time Xcode setup for the `DEV` compile flag and a git-hash build-version stamp. Real project refs, keys, and identifiers stay out of the repo — only mechanisms and placeholder steps appear here.

> 「上 prod ／ 切 dev↔prod ／ dev 變體共存」的可重複 runbook。全景架構見 [`ARCHITECTURE.md`](ARCHITECTURE.md)、介面契約見 [`API_CONTRACT.md`](API_CONTRACT.md)。
> 🔴 **born-clean**：實際 project ref / bundle id / team / anon key 等真值住 gitignored `CLAUDE.local.md`（+ `supabase/.temp/`）；本檔只放**機制與步驟**（placeholder）。

---

## 0. 拓撲

| 環境 | 後端 | app build | 誰打 |
|---|---|---|---|
| **dev** | 本機 `supabase start`（PostgREST `:54321` + functions serve） | **Debug** build | 開發／測試 |
| **prod** | 雲端 Supabase 專案（已 `link`，ref 見 `supabase/.temp/project-ref`） | **Release** build | 日常使用 + bridge |

bridge（常駐本機）讀 prod 讀口 → 寫本地 JSON（網路只在這格）。

---

## 1. 前置：載入 creds（免互動登入）

🔴 **creds 已存 gitignored `.env.prod.local`**（`SUPABASE_ACCESS_TOKEN` PAT + `SUPABASE_PROJECT_REF` + `SUPABASE_DB_PASSWORD`）。進 repo 一行載入即可、**不用 `supabase login`**：

```bash
set -a; source .env.prod.local; set +a   # token / ref / DB 密碼進 env（不 echo）
supabase projects list                    # 驗 token 有效（列到 kc-wherebear = OK）
```

- 專案已 `link`（`.temp/project-ref` 有 ref）→ 不用重 link。
- fallback：`.env.prod.local` 不見了才 `supabase login`（互動、agent 代跑不了）或 dashboard 重發 PAT。

---

## 2. Prod 同步（schema + functions，**零資料**）

「除資料外全同步」＝ migrations（含 RLS / pg_cron / storage bucket）+ Edge Functions。**無 seed**（born-clean 本來就零 seed）。

```bash
# 先 set -a; source .env.prod.local; set +a（見 §1）

# 2a. migrations → 雲端（套 supabase/migrations/*.sql；--yes 免互動確認、無 seed）
supabase db push --yes -p "$SUPABASE_DB_PASSWORD"
supabase migration list --linked          # 驗 local/remote 對齊（全數 applied）

# 2b. Edge Functions → 雲端（headless 讀口關 JWT 走 API key；geocode 留 JWT 給 app）
supabase functions deploy last-location   --no-verify-jwt --project-ref "$SUPABASE_PROJECT_REF"
supabase functions deploy today-stays     --no-verify-jwt --project-ref "$SUPABASE_PROJECT_REF"
supabase functions deploy realtime-token  --no-verify-jwt --project-ref "$SUPABASE_PROJECT_REF"
supabase functions deploy geocode                         --project-ref "$SUPABASE_PROJECT_REF"
```

🔴 **改 `_shared/` 底下的東西 → 上面四支全部要重佈，不是只佈你改的那一支。** Edge Function 在**部署當下**把 `_shared` 打包進去，之後改原始碼不會自動生效。
> 實際踩過（2026-07-26 才發現）：`_shared/geocode.ts` 的地名改成路名級之後，只有 `geocode` 與後來因故重佈的 `today-stays` 生效；`last-location` 停在 22 小時前的舊版本，於是同一份下游 JSON 裡「當前位置」是里級、「今天足跡」是路名級，粗細不一致查了很久。
>
> 配套：`geocode_cache` **不會自己更新**——標籤格式改了，已快取的座標仍回舊格式。改格式時要一併清掉舊格式的列（例如 `delete from public.geocode_cache where name like '%里 · %'`）。

- `last-location` / `today-stays`：`config.toml` 已設 `verify_jwt = false`（headless 吃 API key，非 GoTrue JWT）。
- `geocode`：線上預設驗 JWT（app owner JWT 打）。
- storage `avatars` public bucket 由 migration 建（`db push` 一併，不需手動）。
- `service_role` 由平台自動注入已部署的 function（`SUPABASE_SERVICE_ROLE_KEY` env），**不需**手設 secret。
- ⚠️ `db push` 尾端若見 `pgdelta … ca.crt ENOENT`／`own visits does not exist, skipping` 警告＝**無害**（前者是套用後的本地 catalog 快取、後者是 `drop policy if exists` 冪等訊息）；migration 是否套以 `migration list --linked` 為準。

---


- `last-location` / `today-stays`：`config.toml` 已設 `verify_jwt = false`（headless 吃 API key，非 GoTrue JWT）。
- `geocode`：線上預設驗 JWT（app owner JWT 打）。
- storage `avatars` public bucket 由 migration 建（`db push` 一併，不需手動）。
- `service_role` 由平台自動注入已部署的 function（`SUPABASE_SERVICE_ROLE_KEY` env），**不需**手設 secret。
- ⚠️ `db push` 尾端若見 `pgdelta … ca.crt ENOENT`／`own visits does not exist, skipping` 警告＝**無害**（前者是套用後的本地 catalog 快取、後者是 `drop policy if exists` 冪等訊息）；migration 是否套以 `migration list --linked` 為準。

---

## 3. Prod 端驗證

- **migrations 對齊**：`supabase migration list`（local / remote 兩欄一致）。
- **讀口活著**：curl `/last-location`（帶 `x-wb-key: <API key>` + cloud gateway `apikey: <anon>`）→ 回 200 / 401（**不是**連不上 / 404）。
- **RLS 隔離**：兩測試帳號互相看不到對方的列（IDOR 防線）。
- **anon 讀不到**（快驗、免建帳號）：`curl "<prod-url>/rest/v1/current_location?select=*" -H "apikey: <anon>"`（不帶登入 JWT）→ 期 **401 `permission denied`**（anon 角色無 table grant → 反編譯挖到 anon key 也讀不到資料；安全靠 RLS+登入、非 key 保密）。
- **空資料**：尚無回報 → 200 + null 欄位（非 404）；今天無點 → `stays: []`。

---

## 4. App 切端點（預設 prod；免 Release／App Store）

`Config.swift`：`env` **預設 = prod**；只有帶 `DEV` 編譯旗標的 build 才切 dev。→ **正常 Xcode ⌘R 就是 prod「熊熊在哪裡」**，直接裝到自己手機、**不需 Release build、不需 Archive、不需上架**（Release 只是最佳化編譯、跟上架無關）。

- **本機機密** 住 gitignored `Config.local.swift`（`enum Secrets`：`prodAnonKey` + `devURL`）。**最快＝ `cp Config.local.swift.example Config.local.swift` 再填值**。`prodAnonKey` 取值＝Dashboard → Settings → API → **anon public**（或 `supabase projects api-keys` 取 `id=anon`）；`devURL`＝你 mac 的 Bonjour 名（dev build 用）。🔴 fresh checkout 需自建此檔（committed 只有 `.example`、synchronized group 會自動編譯）：

  ```swift
  // app/wherebear_app/wherebear_app/Config.local.swift  （gitignored）
  import Foundation
  enum Secrets {
      static let prodAnonKey = "<prod anon public key>"
      static let devURL = "http://your-mac.local:54321"   // 你 mac 的 Bonjour 名；mDNS 被擋改 LAN IP
  }
  ```

- **裝 prod app**：接手機 → 選它當 destination → **⌘R**。就這樣（免 Release/Archive/上架）。
- **裝 dev app**：選 `wherebear-dev` scheme（帶 `DEV` 旗標）→ ⌘R（見 §5）。

---

## 5. Dev 變體共存（兩支 app 同機不打架）

目標：正式「熊熊在哪裡」＋ 開發「熊熊 dev」並存、各打各後端，兩支都用普通 ⌘R（不碰 Release/Archive）。靠一個 `DEV` 編譯旗標 + 專屬 scheme 分：

| build/scheme | 端點(env) | bundle id | 顯示名 |
|---|---|---|---|
| 預設（⌘R） | **prod**（雲端） | `<你的 bundle id>` | 熊熊在哪裡 |
| `wherebear-dev`（帶 DEV 旗標） | **dev**（本機） | `<你的 bundle id>.dev` | 熊熊 dev |

Xcode 設定（一次性，走本機 skip-worktree、不 commit）：

1. **複製 build configuration**：Project → Info → Configurations → 複製 `Debug` 成 `Debug-Dev`。
2. **`Debug-Dev` 加旗標 + 改身分**：
   - `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 加 `DEV`（讓 `Config.swift` 的 `#if DEV` 切 dev backend）
   - `PRODUCT_BUNDLE_IDENTIFIER = <bundle>.dev`
   - `INFOPLIST_KEY_CFBundleDisplayName = 熊熊 dev`
3. **建 scheme `wherebear-dev`**：Run action 的 Build Configuration 選 `Debug-Dev`。
4. 正式 app 顯示名 → 在 `Debug`/`Release` config 設 `INFOPLIST_KEY_CFBundleDisplayName = 熊熊在哪裡`。

- **env 由 `Config.swift` 的 `#if DEV` 自動對上**（有 DEV 旗標→dev backend、否則 prod）。
- 🔴 這些 pbxproj/scheme 改動走**本機 skip-worktree、不 commit**（比照 `DEVELOPMENT_TEAM` / bundle id 既有慣例，見 `CLAUDE.local.md`）—— 真值不進公庫。

---

## 5.5 建置版本戳記（設定頁最下面顯示 git hash）

設定頁最下面顯示一行版本字串，用來分辨手機上裝的是哪一版（可長按複製）。來源：App 讀 `Info.plist` 的 `GitHash` key（`BuildInfo.swift`），該 key 由一個 Xcode「Run Script」build phase 於**每次建置**寫入 short git hash（含 `-dirty`）。**沒設這個 build phase 時，退回顯示 `v1.0 (1)`**（MARKETING_VERSION/build）—— app 照樣 build 得起來。

一次性設定（Xcode，走本機 skip-worktree、不 commit —— 比照 §5）：

Target `wherebear_app` → **Build Phases** → `+` → **New Run Script Phase** → 拖到**最後**（在 "Copy Bundle Resources" 之後）→ 貼：

```sh
HASH=$(git -C "$SRCROOT" describe --always --dirty --abbrev=8 2>/dev/null || echo nogit)
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
if [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :GitHash $HASH" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :GitHash string $HASH" "$PLIST"
fi
```

- 取消勾選 **"Based on dependency analysis"** → 每次 build 都跑、hash 才會跟著 HEAD 走。
- committed `wherebear-app-Info.plist` 已放 `GitHash = $(GIT_HASH)` 佔位；build phase 會覆蓋成真實 hash。
- 這樣每次 ⌘R 裝機後，設定頁最底就是這次 build 的 commit（工作區有未提交改動會帶 `-dirty`）。

---

## 6. Prod 一次性 dashboard 設定

- **Auth → URL Configuration**：`site_url` / redirect allow-list（email 驗證信連結指向；`config.toml` 的 `127.0.0.1:3000` 只是 dev）。
- **bridge**（常駐本機）：指向 prod 讀口 + app 內發的 API key（`API_CONTRACT §1.4`）+ 常駐排程（launchd 或等效）。

---

## 7. bridge 部署（常駐機）

兩支 bridge 同吃一份 `.env`、同一把 `wb_` 金鑰，但**launchd 型態相反**，這是最容易搞混的地方：

| | `wherebear_bridge.py`（快照） | `wherebear_event_bridge.ts`（事件） |
|---|---|---|
| launchd | `StartInterval` 定時叫醒、跑 `--once` 就結束 | `KeepAlive` 常駐、掛了自動拉起 |
| 相依 | 無（純標準函式庫） | Deno ＋ `npm:@supabase/supabase-js`（首次執行自動快取） |
| 更新 | 複製檔案過去 | 複製檔案過去（相依寫在 `import` 行，**不需要虛擬環境**） |

### 7.1 相依（🔴 這是本 repo 第一個外部相依）

事件那支需要 Deno（`brew install deno`）。**更新流程不變** —— 相依宣告在 `import` 那一行、首次執行自動下載並快取，所以照舊只是把一個檔案複製過去。想預先暖機：

```bash
deno cache bridge/wherebear_event_bridge.ts
```

離線環境要先跑過一次（或 `deno vendor`）才有快取。

### 7.2 事件通道的前置

1. **function secret**（沒設的話換發口回 500）：
   ```bash
   supabase secrets set WB_JWT_SECRET="<專案的 JWT secret>" --project-ref "$SUPABASE_PROJECT_REF"
   ```
   JWT secret 來源：Dashboard → Settings → API → JWT Secret。🔴 它是新的單點資產（拿到能自簽任意身分的 token），只該存在這裡。
2. **部署換發口**：`supabase functions deploy realtime-token --no-verify-jwt --project-ref "$SUPABASE_PROJECT_REF"`
3. **migrations** 要含事件觸發器與 `realtime.messages` 的 policy（`supabase db push`）。

### 7.3 launchd（常駐那支的重點）

```xml
<key>KeepAlive</key><true/>
<key>RunAtLoad</key><true/>
<key>ProgramArguments</key>
<array>
  <string>/opt/homebrew/bin/deno</string>
  <string>run</string>
  <string>--allow-net</string><string>--allow-read</string><string>--allow-write</string>
  <string>--allow-env</string><string>--allow-run</string>
  <string>--env-file=<repo 絕對路徑>/.env</string>
  <string><repo 絕對路徑>/bridge/wherebear_event_bridge.ts</string>
</array>
```

- `--env-file` 指向同一份 `.env`（不要另抄一份，會漂）。
- 🔴 **prod 必須有 `WHEREBEAR_GATEWAY_APIKEY`**（該專案 anon key）：雲端 Realtime 的 WebSocket 閘道只收真的專案 key，拿換發來的短效 token 當閘道鑰匙會被擋（`CHANNEL_ERROR: transport failure`）。本機 stack 的閘道較寬鬆、兩種都收，**所以這個差異只有上雲才看得到**。身分仍然是 `setAuth()` 那張短效 token，anon key 只是過門用、公開值、不放大權限。
- `WHEREBEAR_EVENT_JUDGE` 留空＝只寫事件檔不叫人（第一次接管線時建議這樣跑一天看看）。
- 驗活著：看 log 有沒有 `已訂閱 wb:events:…`。驗端到端：出門一趟，事件檔應該出現一則 `departure`。
- **首次連線可能先吐一次 `MissingPartition`**：雲端 Realtime 冷啟動時才建當日的訊息分割表。退避重連會自己過關，不用理它。

### 7.4 驗證與反操作

```bash
# 換發口活著（無 key 應 401）
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/realtime-token"
# 有 key 應回 token/topic
curl -s -X POST "$BASE/realtime-token" -H "x-wb-key: $WB_KEY"
```

反操作：`launchctl bootout gui/$(id -u) <plist>` 後刪 plist；事件檔留著無害（純本地、gitignored）。

---

## 附：本機 dev 啟動（每次測 dev 前）

見 [`../CLAUDE.md`](../CLAUDE.md)「本機 dev 啟動 SOP」：`supabase start` + `supabase functions serve --no-verify-jwt`（geocode 要 serve 著才有地名反查）。
