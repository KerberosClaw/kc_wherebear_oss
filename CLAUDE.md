# kc_wherebear — repo guide

自架的個人位置平台：手機低頻回傳當前位置 → 你自己的 Supabase → 本地 bridge 撈給下游消費者。上手先讀 [`README.md`](README.md)，全景架構見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，架構與決策見 [`docs/DESIGN.md`](docs/DESIGN.md)，分期見 [`docs/ROADMAP.md`](docs/ROADMAP.md)，可調參數見 [`docs/TUNABLES.md`](docs/TUNABLES.md)，上 prod／切端點見 [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)，安全模型見 [`docs/SECURITY.md`](docs/SECURITY.md)，介面契約見 [`docs/API_CONTRACT.md`](docs/API_CONTRACT.md)。

> config 值走 `.env`（範本 `.env.example`）與 gitignored `Config.local.swift`（範本 `Config.local.swift.example`）。真實金鑰／端點不進 repo。

## 這在做什麼（一句話）

一支 native iOS app 在背景**低頻、粗略、省電**地把「最新位置」回傳到你自己的 Supabase；本地一支 bridge daemon 把最新座標拉下來寫成本地 JSON，給任何下游消費者（AI agent / timeline app / 朋友分享）讀。**不是**連續高精度追蹤。

## 架構（三元件 monorepo）

```
app/        FE：native SwiftUI（元件化 UI + 邏輯/整合層）
supabase/   BE：migrations（雙表 + RLS + pg_cron）+ functions（Edge Functions / Deno TS）
bridge/     膠水：本地 daemon 拉 Supabase 讀取口 → 寫本地 JSON（網路只在這一格）
```

雙表：`current_location`（熱、每人一列 upsert）+ `location_history`（冷、append）。詳見 `docs/DESIGN.md`。

## 端點配置

端點走 `Config.swift`（env 綁 `#if DEV`：預設 prod、`DEV` 旗標才 dev）+ gitignored `Config.local.swift`（`Secrets.prodAnonKey` / `Secrets.devURL` / `Secrets.prodURL`）。fresh clone 先 `cp Config.local.swift.example Config.local.swift` 填值。詳 [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)。

## 秘密紀律

- **零秘密進 git**：token / key / 真實座標一律不進 repo，只 commit `.example`。`service_role` 永不落地 client，只在 Supabase function secrets。
- config 驅動：路徑 / 端點全走 env 或 placeholder，不硬編。
- 建議啟用 gitleaks pre-push hook（`.githooks/pre-push`）：`git config core.hooksPath .githooks`（需 `brew install gitleaks`）。

## 本機 dev 啟動 SOP

時間軸「未命名地點」的地名反查走 `geocode` Edge Function（Nominatim + `geocode_cache` 快取表）。**dev 要這支 function serve 著才有地名**（其餘 PostgREST/RPC 路徑不靠它）。跑或測 dev 前，先在 repo 根：

```bash
supabase status >/dev/null 2>&1 || supabase start                 # dev stack
pgrep -f "supabase functions serve" >/dev/null \
  || nohup supabase functions serve --no-verify-jwt > /tmp/wb_functions_serve.log 2>&1 &
```

驗 endpoint（活＝回 `400 bad_request`；需帶 dev anon key，見 `Config.swift`）：

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  http://127.0.0.1:54321/functions/v1/geocode -H 'apikey: <dev anon key>' -d '{}'
```

- dev 用 `--no-verify-jwt`（LAN dev 可接受）；prod 走 `supabase functions deploy geocode`（線上預設驗 JWT）。
- migrations：dev 直接 `docker exec … psql < migration`（勿 `db reset`、保測試資料）；建表後 `notify pgrst, 'reload schema'` 讓 PostgREST 認得新表。

## 開發慣例

- 語言：Swift 5+/SwiftUI（app）· SQL（Postgres/RLS）· TypeScript/Deno（Edge Functions）· Python 3.12+（bridge）。
- snake_case；commit：`category: 描述`（`feat:`/`fix:`/`docs:`/`chore:`）。
- 推 GitHub 前跑 gitleaks（或等效）掃秘密。

## 檔案清單

| 路徑 | 職責 |
|---|---|
| `README.md` | 定位 + 介紹 |
| `docs/DESIGN.md` | 後端架構 + 決策 D1–Dn + 雙表 + 隱私 |
| `docs/DESIGN_app.md` | app 設計 brief（畫面／狀態／流程） |
| `docs/API_CONTRACT.md` | 介面 SSOT（endpoint／payload／bridge JSON schema） |
| `docs/ROADMAP.md` | 分期 |
| `docs/TUNABLES.md` | 可調參數速查（停留門檻／回報頻率／bridge poll…） |
| `docs/ARCHITECTURE.md` | 全景工程文件（系統總覽／ER／端到端資料流／App 架構，4 mermaid） |
| `docs/DEPLOYMENT.md` | 上 prod runbook + app 端點切換（Debug=dev／Release=prod）+ dev 變體共存 |
| `docs/SECURITY.md` | 安全模型 + 威脅模型 + 已驗／待驗 RLS 清單 |
| `supabase/migrations/` | SQL：雙表 + RLS + pg_cron 封存 |
| `supabase/functions/` | Edge Functions：讀取口、reverse-geocode |
| `bridge/` | 本地 daemon：拉 Supabase → 寫本地 JSON + 排程 |
| `app/` | iOS：Xcode 殼 + Sources/ |
| `app/wherebear_app/wherebear_appTests/` | iOS 單元測試（Swift Testing） |
