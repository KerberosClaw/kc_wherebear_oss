-- kc_wherebear — 收回「SECURITY DEFINER ＋ 吃 p_user 參數」函式對 authenticated 的執行權（IDOR）
--
-- ── 問題 ──
-- 一組函式同時具備三個條件：
--   ① SECURITY DEFINER（以 owner 身分執行 → **繞過 RLS**）
--   ② 簽章明確吃 `p_user uuid`（呼叫端自己指定要看誰）
--   ③ 授權給 `authenticated`
-- 三者同時成立 ＝ 任何登入者把別人的 user_id 傳進去，就讀得到別人的資料。
--
-- 可重現的驗證（在你自己的測試環境跑）：建兩個使用者 A / B，讓 B 有資料、A 完全沒有，
-- 然後以 A 的身分：
--   走正規介面 my_today_stays()        → 空的        ✅ auth.uid() 綁定正確
--   直接呼叫 visits_for_day(B, 某日)   → B 的停留紀錄 ❌ 越權
--   直接呼叫 resolve_name(B, 某座標)   → B 為該座標取的地標名 ❌ 可用座標暴搜出來
--
-- 第二個尤其惡劣：地標名稱是使用者自己取的私密標籤，配合座標窮舉等於把別人的
-- 私密地點反解出來。
--
-- 🔴 只要存在第二個可登入的帳號，這條就可利用。使用者數量少**不是防線** —— 那只是還沒有人去用，
-- 而且任何多使用者功能（分享、邀請）都會立刻讓它成真。
--
-- ── 另一個獨立的洞：archive_old_location_history ──
-- 它是 SECURITY DEFINER、回傳 integer（**可直接被 RPC 呼叫**）、且 anon 也叫得動，
-- 參數 `retention_days` 由呼叫端指定。
-- 以 anon 身分呼叫 `archive_old_location_history(0)`，就會把主表裡的定位點**整批**搬進封存表。
-- anon key 本來就公開在 app 內 → 任何人都能讓時間軸、停留偵測、地名裁決的證據同時失效。
--
-- ── 修法 ──
-- 全部收回 anon / authenticated 的執行權。確認過沒有任何呼叫端會壞：
--   * app 只呼叫 `my_*` 那組（內部用 auth.uid()，不吃 p_user）—— 那組維持原樣
--   * Edge Functions 走 service_role（current_for / resolve_alias / resolve_api_key / stays_for_day）
--   * 這四支在 app 與 Edge Functions 內都沒有直接呼叫端（改動前請自行再確認一次）
--   * 排程（pg_cron）以 `postgres` 身分執行 → 不受影響
--   * 內部呼叫（例如 stays_for_day → visits_for_day → visit_open_until）都在
--     SECURITY DEFINER 函式裡以 owner 身分發生，權限檢查看 owner，不需呼叫端持有 EXECUTE
--
-- ⚠️ 這些洞是 20260723000003 / 20260723000014 / 20260725000001 / 20260727000001 就存在的，
-- 不是新引入；但 20260728000003 沿用了 visits_for_day 的舊授權，等於把問題帶進新版。
-- 該檔的註解其實一直寫著「service_role only」，與實際 grant 不符——註解是對的、grant 是錯的。

-- ① 可被 anon 直接呼叫的破壞性封存函式
revoke all on function public.archive_old_location_history(integer) from public;
revoke all on function public.archive_old_location_history(integer) from anon, authenticated;

-- ② SECURITY DEFINER ＋ 吃 p_user ＋ 給 authenticated 的那一組
revoke all on function public.visits_for_day(uuid, date, text, integer) from anon, authenticated;
revoke all on function public.resolve_name(uuid, double precision, double precision) from anon, authenticated;
revoke all on function public.resolve_name(uuid, double precision, double precision, double precision) from anon, authenticated;
revoke all on function public.visit_open_until(uuid, timestamp with time zone, integer) from anon, authenticated;

-- service_role 維持（Edge Functions 讀取平面需要）
grant execute on function public.visits_for_day(uuid, date, text, integer) to service_role;
grant execute on function public.resolve_name(uuid, double precision, double precision) to service_role;
grant execute on function public.resolve_name(uuid, double precision, double precision, double precision) to service_role;
grant execute on function public.visit_open_until(uuid, timestamp with time zone, integer) to service_role;

comment on function public.archive_old_location_history(integer) is
  '把超過保留天數的定位點搬進封存表。🔴 SECURITY DEFINER ＋ 可直接呼叫 ＋ 具破壞性 → 只允許 owner（pg_cron 以 postgres 身分執行），不得授權任何 API 角色。';
