# SECURITY — kc_wherebear 安全模型 + 待驗清單

> **English summary:** The security and threat model for kc_wherebear, where RLS (Row Level Security) is the primary trust boundary protecting the owner's location coordinates. It lays out the assets, adversaries, and defenses, then keeps an explicit checklist split between what has already been verified (e.g. anonymous direct table reads are denied, auth signup is locked down) and what still needs verification (e.g. API-key revocation, cross-user IDOR isolation, Edge Function rejection of unauthorized reads). It is a living document — pending items should be treated as unverified until checked off.

自架個人位置平台，資產是 owner 的位置座標。**RLS（Row Level Security）是主要信任邊界。** 動 RLS / 上 prod 前先看這份；把「已驗」和「還沒驗、別假設」分清楚。

> 這份是**活文件**：想到或有空時照「待驗」逐項打勾；別把 ⏳ 當成 ✅。

---

## 威脅模型（誰、想拿什麼、怎麼防）

| 資產 | 對手 | 主要風險 | 防線 |
|---|---|---|---|
| `current_location`（熱·每人一列）| 匿名網路存取者（anon key 公開）| 直讀表偷位置 | RLS：`own current_location` 綁 `auth.uid()` |
| `location_history` / `visits`（冷·足跡）| 其他已登入使用者（多使用者情境）| IDOR 越權讀他人足跡 | RLS 綁 `auth.uid()`；讀取走 SECURITY DEFINER RPC |
| 讀取側（bridge → 下游）| 拿到讀取口 URL 的人 | 無授權拉座標 | Edge Function + shared secret（`x-wb-key`）；`service_role` 只在 function secrets |
| **事件通道**（D13）| 拿到換發口 URL 的人 | 換一張 token 來聽別人的行蹤 | 換發要有效 `wb_` key（無/錯 → 401）；簽出的 token `role=anon`（`public` schema 零權限）＋ `wb_uid` claim 綁 topic |
| **`WB_JWT_SECRET`**（新資產）| 拿到它的人 | 自簽任意 `wb_uid` 的 token → 聽任何人的事件 | 只在 Supabase function secrets，不進 repo / bridge / app |
| 全站 | 手滑 commit | 秘密 / 私域身分進 git | born-clean 紅線 + gitleaks pre-push（見 [`../CLAUDE.md`](../CLAUDE.md)）|

### 事件通道的攻擊面（D13 新增，2026-07-25）

多了一支**會回傳憑證**的端點，值得單獨看：

- **爆炸半徑刻意壓到零**：簽出的 token 用 `role=anon`，該角色在 `public` schema 沒有任何表權限。實測拿它打 `visits` / `landmarks` / `location_history` / `current_location` / `api_keys` / `profile` **六張表全數 `permission denied`**；訂閱他人 topic、用公開 anon key 訂閱亦皆被拒。
- **為什麼不用帳號級 JWT**：那種 token 對 PostgREST 一樣有效，消費端會從「兩支窄讀口」膨脹成「整個帳號讀寫」。
- **payload 不含座標**：事件只帶 `landmarks` 解析後的名字，連事件檔落到常駐機都沒有原始座標。
- **金鑰不過繼給下游**：event bridge 以 `clearEnv` 起下游行程（子行程預設會繼承 `WHEREBEAR_API_KEY`），下游那側另有開機自我斷言。
- **`WB_JWT_SECRET` 是新的單點**：拿到它等於能自簽任意 `wb_uid`。它只該存在 function secrets；輪替時要同步重啟 listener（舊 token 會失效、listener 會重連重換）。

---

## 已驗 ✅（2026-07-24 prod）

- **anon 直打表被擋**：帶 public anon key `GET current_location` → `42501 permission denied`（RLS 生效、不是靠隱藏）。
- **空資料回 200**（不洩結構、不 500）。
- **`service_role` 不落 client**：只在 Supabase function secrets。
- **寫入 RLS 綁 `auth.uid()`**：policy `own current_location` 等（見 `supabase/migrations/*_rls.sql`）。
- **Auth 鎖定**：`disable_signup=true`、匿名登入關、email 驗證留著；Free plan（超額只 pause、不可能計費）。

---

## 待驗 ⏳（有空再做，別假設已驗）

- [ ] **API key（`wb_`）revoke 生效**：撤銷後 bridge 讀取口真的被擋（走 `revoked_at` 判斷、不是還能讀）。
- [ ] **跨使用者不洩（IDOR）**：造第二個帳號，驗使用者 A 的 JWT **讀不到** B 的 `current_location` / `location_history` / `visits`。⚠️ 目前只有一個帳號 → 這條**測不出來**，要有第二個才驗得到，是 RLS 最關鍵的一條。
- [ ] **讀取口 Edge Function 拒絕未授權**：`last-location` / `today-stays` 帶錯或無 `x-wb-key` → 拒；確認回應不外露 `service_role` 能力。
- [ ] **revoke session / refresh token 生效**：撤銷後該 session 的請求真的被擋（配合 app 端 401 處理）。

> 驗的時候：**打 local dev（`supabase start`）、不要打 prod**（省 prod usage）。

---

## born-clean 提醒

零秘密 / 零私域身分（真名、化名、具體機器、下游私有脈絡）進 git —— 連 commit message 都算（git message 公開可見）。完整紅線見 [`../CLAUDE.md`](../CLAUDE.md)。
