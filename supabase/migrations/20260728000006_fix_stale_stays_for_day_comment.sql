-- kc_wherebear — 修正 stays_for_day 說謊的函式註解（只改註解，不動任何行為）
--
-- ── 問題 ──
-- `20260728000003` 的實作與註解不一致：註解寫「resolved 與 unresolved 都鎖住名字」，
-- 但那樣會讓 unresolved 的停留憑空變成無名（它的 name_snapshot 是 null，而它**從未對外
-- 宣告過任何名字** —— v2 事件的 name 就是 null、或根本沒發），所以實作是**只有 resolved 鎖定**。
--
-- 程式改對了，`comment on function` 忘了跟著改，於是資料庫裡留下一句與實作相反的敘述：
--   「已定案（resolved/unresolved）一律用裁決快照、不重新投票」
-- 實際上 unresolved 會 fall through 去當場投票／用座標現算。
--
-- 這種註解比沒有註解更糟：下一個人會照它推理，而它剛好把最關鍵的那個判斷寫反。
--
-- ── 順帶記錄兩個既有瑕疵 ──
-- 依既有紀律（已套用的 migration 不回頭改 SQL，避免檔案與實際套用內容產生落差）：
--   1. `20260728000001` 第 98 行的區塊註解把 `visit_place_vote` 誤寫成 `visit_place_yote`。
--      純 `--` 註解、不影響任何已套用的 SQL；本次一併修正（不造成套用內容落差）。
--   2. `20260728000001` 第 93 行的 `comment on function visits_for_day` 寫「service_role only」，
--      但同檔下一行 grant 給了 authenticated —— **註解是對的、grant 是錯的**。
--      該 grant 已由 `20260728000005` 收回（IDOR 修補），且該註解本身已被 `20260728000003`
--      的版本取代 → 不需再動。

comment on function public.stays_for_day(uuid,date,text,double precision,double precision) is
  '某當地日的合併停留清單。地名：**只有 resolved** 的裁決會鎖定名字（用 name_snapshot、不重新投票）'
  '→ 與已對外發出的具名事件永遠同源；unresolved 從未宣告過名字，因此仍走「當場投票 > 座標現算」，'
  '這是刻意的 —— 若連 unresolved 也鎖，會讓那些停留憑空變成無名。';
