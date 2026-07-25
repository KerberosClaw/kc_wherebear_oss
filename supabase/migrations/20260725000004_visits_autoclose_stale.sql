-- kc_wherebear — 新的到達進來時，自動關掉先前還開著的停留
--
-- 修的問題（D14 已知邊界的實例，2026-07-25 實際發生）：
--   CLVisit 的離開投遞如果遺失（app 被系統 kill、iOS 沒回呼），那一列的 departed_at
--   永遠是 null。實測 visit 25：21:07 到達 → app 於 21:12 後被系統 kill → 離開回呼沒人接
--   → 到達有、離開沒有。後果不只是少一筆時間：`visits_for_day` 會把它夾在當日邊界內，
--   所以它會**以「還在那裡」的姿態出現在往後的每一天**，且下游拿到的 `to` 是 null。
--
-- 依據：一個人不可能同時在兩個地方。所以新的到達本身就是「先前那段已經結束」的證據，
-- 而且是我們拿得到的、最保守的證據——用新到達的時刻當離開時刻，不會高估停留。
--
-- BEFORE INSERT 而非 AFTER：讓「關掉舊的」發生在「新的那列插入」之前，事件順序才自然
-- （先離開、後到達）；AFTER 會變成先播到達、再播離開。
--
-- 與真實離開投遞的關係：若稍後真的收到離開事件，app 的 upsert 會把 departed_at 從我們
-- 推得的值改成真值（更準）。事件觸發器的條件是「departed_at 由 null 變成有值」，此時
-- 已不是 null → **不會重播第二次離開事件**。
--
-- 亂序保護：只關 arrived_at 早於新到達的列。離線佇列補傳可能把舊的到達晚一步送上來，
-- 這條防止我們拿舊時刻去關掉更新的停留。
--
-- 殘留邊界（沒解、明講）：如果某段停留之後再也沒有任何新到達（例如換手機、長期不用），
-- 它仍會開著。那種情況要靠排程收尾，不在本 migration 範圍。

create or replace function public.visits_autoclose_stale() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.visits v
     set departed_at = new.arrived_at
   where v.user_id = new.user_id
     and v.departed_at is null
     and v.arrived_at < new.arrived_at;
  return new;
end $$;

comment on function public.visits_autoclose_stale() is
  '新到達進來時，把同一使用者先前仍未關閉的停留關在新到達時刻（人不可能同時在兩地）。修補 CLVisit 離開投遞遺失造成的孤兒列。';

drop trigger if exists visits_autoclose_stale_t on public.visits;
create trigger visits_autoclose_stale_t
  before insert on public.visits
  for each row execute function public.visits_autoclose_stale();
