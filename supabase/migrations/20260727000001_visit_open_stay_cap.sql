-- kc_wherebear — 還開著的停留不再無限延伸（D15 殘留邊界的收尾）
--
-- 修的問題（實際發生過）：使用者按下停止回報 → app 呼叫 stopMonitoringVisits()
-- → iOS 從此不送任何事件 → 那列的 departed_at 永遠空著。而讀取層看到 departed_at 是 null
-- 就拿 now() 當結束時間，now() 每天往前跑 → 這列會出現在**往後的每一天**，過去的日子
-- 還會被填成整整 24 小時。實例：某次深夜到達的停留，在使用者停止回報之後就這樣掛著。
--
-- 這不是「停止回報」專屬：刪 app、手機沒電、換手機、iOS 單純沒回呼，任何「回報結束但沒有
-- 離開事件」的路徑都一樣。既有三道保險（visits_autoclose_stale／visits_close_on_departure_evidence
-- ／日界夾取）全都要求「之後還有新資料進來」，而這些情況正好把那個前提拿掉。
-- 20260725000004 的註解自己承認了這個邊界、說要靠排程收尾 —— 這支就是那個收尾。
--
-- ── 為什麼寬限給到 24 小時（不是 30 分鐘）──
-- 🔴 沉默是有歧義的：人在家不動時 significant-change 本來就不觸發，回報開著也可以好幾小時
-- 一筆都沒有。prod 實測合法沉默最長 416 分鐘（約 7 小時）。拿 detect_stays 的
-- p_gap_s（30 分）當寬限會把真實的整夜停留砍成半小時 —— 那是比原病更糟的錯。
-- 取 24 小時：① 遠高於實測合法沉默 ② 對齊本專案「按當地日切段」的既有模型，是可解釋的單位，
-- 不是憑感覺挑的數字 ③ 症狀從「每天都冒出 24 小時的家、永遠」收斂成「最多多算一天」。
--
-- ── 為什麼是讀取層封頂、不是排程改資料 ──
-- 不動 departed_at 這一欄：它的語意是「iOS 說的離開時刻」，塞推測值進去就分不出真假了。
-- 封頂只影響「怎麼畫」，可逆、且使用者一旦恢復回報就自動跟著往後長，不需要人去清。

-- ── 1. 單一真值：一段還開著的停留，最多還能宣稱到什麼時候 ──
-- ＝「最後一次我們還聽得到這個人」＋寬限。聽得到＝location_history 有任何一筆
-- （不限這個地點附近 —— 人跑去別的地方本來就該由 visits_close_on_departure_evidence 收）。
create or replace function public.visit_open_until(
  p_user uuid, p_arrived_at timestamptz, p_grace_s integer default 86400
) returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(
           p_arrived_at,
           coalesce(
             (select max(h.captured_at) from public.location_history h
               where h.user_id = p_user and h.captured_at >= p_arrived_at),
             p_arrived_at)
         ) + make_interval(secs => p_grace_s);
$$;

comment on function public.visit_open_until(uuid,timestamptz,integer) is
  '一段未關閉停留的宣稱上限＝最後一次收到該使用者任何位置回報的時刻＋寬限（預設 24h）。visits_for_day 與 visits_autoclose_stale 共用，避免兩處各寫一份門檻。';

revoke all on function public.visit_open_until(uuid,timestamptz,integer) from public;
grant execute on function public.visit_open_until(uuid,timestamptz,integer) to authenticated, service_role;

-- ── 2. visits_for_day：開著的停留改用封頂，而不是無條件 now() ──
-- 多一個參數 → 必須先 drop（三參數版留著的話，stays_for_day 的三參數呼叫會打到舊的、封頂失效）。
drop function if exists public.visits_for_day(uuid,date,text);
create function public.visits_for_day(
  p_user uuid, p_day date, p_tz text default 'Asia/Taipei',
  p_open_grace_s integer default 86400
)
returns table (
  from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision,
  slack_m double precision
)
language sql
stable
security definer
set search_path = ''
as $$
  with b as (
    select (p_day::text || ' 00:00:00')::timestamp at time zone p_tz as day_start,
           ((p_day::text || ' 00:00:00')::timestamp at time zone p_tz) + interval '1 day' as day_end
  ),
  x as (
    select v.*,
           public.visit_open_until(p_user, v.arrived_at, p_open_grace_s) as capped_at
    from public.visits v
    where v.user_id = p_user
  )
  select greatest(x.arrived_at, b.day_start),
         case
           when x.departed_at is not null then least(x.departed_at, b.day_end)
           -- 寬限用完 → 不再宣稱人還在那裡，給一個具體的結束時刻（而非 null）
           when x.capped_at <= now()      then least(x.capped_at, b.day_end)
           when b.day_end <= now()        then b.day_end   -- 過去的日子且沒收到離開事件 → 截到當日結束
           else null                                        -- 今天且仍在停留中
         end,
         greatest(0, extract(epoch from (
           least(coalesce(x.departed_at, least(now(), x.capped_at)), b.day_end)
           - greatest(x.arrived_at, b.day_start)
         )))::integer,
         x.lat, x.lng, 1.0::double precision, x.accuracy
  from x, b
  where x.arrived_at < b.day_end
    -- 封頂之後這條就不再成立 → 那列自然從往後的每一天消失（原本會永遠出現）
    and coalesce(x.departed_at, least(now(), x.capped_at)) >= b.day_start
$$;

comment on function public.visits_for_day(uuid,date,text,integer) is
  'CLVisit 停留與某當地日的交集，夾在當日邊界內（跨午夜的在兩天各出一段）。未關閉的停留以 visit_open_until 封頂，不會無限延伸到往後每一天。service_role 與 authenticated 皆可。';

revoke all on function public.visits_for_day(uuid,date,text,integer) from public;
grant execute on function public.visits_for_day(uuid,date,text,integer) to authenticated, service_role;

-- ── 3. visits_autoclose_stale：回頭補離開時刻時也要吃同一個封頂 ──
-- 不改的話封頂會被繞過：停掉回報一週後在原地重新開始 → iOS 送新到達 → 這支把舊列的
-- departed_at 設成「一週後的此刻」→ departed_at 有值了，第 2 節的封頂就不再套用
-- → 時間軸出現一段長達一週的停留，中間六天完全沒資料。取 least 才接得上。
create or replace function public.visits_autoclose_stale() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.visits v
     set departed_at = least(
           new.arrived_at,
           public.visit_open_until(v.user_id, v.arrived_at))
   where v.user_id = new.user_id
     and v.departed_at is null
     and v.arrived_at < new.arrived_at;
  return new;
end $$;

comment on function public.visits_autoclose_stale() is
  '新到達進來時，把同一使用者先前仍未關閉的停留關掉（人不可能同時在兩地）。關閉時刻取「新到達」與「visit_open_until 封頂」較早者 —— 中間有大段沒資料時不把它算成連續停留。';
