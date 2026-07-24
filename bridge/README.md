# bridge/ — 本地拉取膠水

常駐 daemon：定時打 Supabase 讀取口（read-only Edge Function + shared secret）→ 把最新座標寫成本地 JSON，給下游消費者讀。

**設計不變式：網路呼叫只活在這一格。** 下游消費者只讀 bridge 寫好的本地檔、永不自己打 Supabase（維持「本地讀、零外呼」）。

- config 走 `.env`（範本見 repo 根 `.env.example`：讀取口 URL / shared secret / 輸出路徑 / 輪詢秒數）。
- 產出的本地 JSON（真座標）**不入 git**（見 `.gitignore`）。
- 語言：Python 3.12+（stdlib 為主）。🚧 Phase 1 施工中。
