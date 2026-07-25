# bridge/ — 本地拉取膠水（兩支）

**設計不變式：網路呼叫只活在這一格。** 下游消費者只讀 bridge 寫好的本地檔、永不自己打 Supabase（維持「本地讀、零外呼」）。金鑰也只住這一格。

兩支同住這裡、同吃一份 `.env`、同一把 `wb_` 金鑰，差別只在**怎麼被觸發**與**寫什麼檔**：

| | `wherebear_bridge.py` | `wherebear_event_bridge.ts` |
|---|---|---|
| 做什麼 | 定時拉兩支讀取口 → 寫**當下快照** | 掛長連線聽事件 → 寫**剛發生什麼** |
| 觸發 | launchd 定時叫醒、跑完就結束 | 常駐（launchd `KeepAlive`） |
| 輸出 | 一個 JSON、每次覆寫（原子 rename） | 每日一個 `.jsonl`、append |
| 下游怎麼吃 | 下游處理程式每次心跳讀最新狀態 | 事件來時把下游處理程式叫起來讀 |
| 語言／相依 | Python 3.12+、純標準函式庫 | Deno、`npm:@supabase/supabase-js` |

## 為什麼一支 Python 一支 Deno

Realtime 走 Phoenix channel 協定，Python 標準函式庫沒有 WebSocket、也沒有 Phoenix。選項是「自己刻協定」「引 Python 套件」或「用官方 JS 客戶端」，選最後者：

1. 這條路徑已實測跑通（私有頻道授權、斷線重連、`setAuth` 續期）
2. Deno 的相依寫在 `import` 那一行、首次執行自動快取 → **更新照舊只是複製一個檔過去**，常駐機不用開虛擬環境、不用管 pip
3. 這個 repo 本來就有 Deno（Edge Functions），不是引進新生態

## 事件通道長怎樣

```
手機 ──► visits 表 ──► 資料庫觸發器（查 landmarks、命中才發）
                            │  payload 只有解析後的名字，沒有座標
                            ▼
        event bridge ◄── 私有 broadcast（wb:events:<uid>）
             │  wb_ 金鑰 ──換發──► 短效 token（權限一無所有、只能聽自己那條）
             ▼
        events_YYYYMMDD.jsonl ──► 叫下游（🔴 clearEnv：金鑰不過繼給下游處理程式）
```

判定「這是不是命名過的地點」留在資料庫（`landmarks` 住那裡），所以 bridge 不需要、也拿不到讀表的權限。

## 設定

全走 repo 根的 `.env`（範本 `.env.example`）。產出的本地檔（真座標／真地名）**不入 git**（見 `.gitignore`）。

部署（launchd 兩種型態、相依、更新流程）見 [`../docs/DEPLOYMENT.md`](../docs/DEPLOYMENT.md)。可調參數見 [`../docs/TUNABLES.md`](../docs/TUNABLES.md)。輸出檔形狀是下游契約，定義在 [`../docs/API_CONTRACT.md`](../docs/API_CONTRACT.md)。
