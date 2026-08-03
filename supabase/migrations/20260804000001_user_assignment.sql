-- 人為指定：使用者說「這一段停留就是這個地標」
--
-- 目前系統把兩件事混成同一件：「使用者建立了一個圓」與「系統推論某段停留屬於它」。
-- 但時間軸上讓使用者對著某一段停留按命名，是很強的人類標註訊號——比任何感測器推論都可靠。
-- 那個訊號現在被丟掉了：stays_for_day 刻意沒回傳 visit_id（見 20260728000001 檔尾
-- 「刻意不做」那段），消費端只能靠時間與座標比對，說不出「清單這一列＝哪一段停留」。
--
-- 這份 migration 把那條路打通，並建立三層信任：
--   user_assignment     使用者明確指定    → 直接成立，留下來源記號
--   感測器互相佐證      CLVisit ＋ 一致的嚴格 live 點，或足夠共識 → 現行規則
--   感測器證據薄弱      單一未受佐證的點  → 維持靜默
--
-- 刻意不做：從地圖上手動建立地標**不會**自動被當成對歷史停留的指定。只有「對著某一段
-- 停留命名」這個動作才算。前者是畫一個圓，後者才是在指認。

-- ── 1. 讀取口帶出 visit_id（純新增欄位，回傳型別變了 → 必須先 drop）───────────
-- 相容性：app 走 key 取值解 JSON（Logic.swift 的 data.jsonArray.map），
-- Edge Function today-stays 也是挑欄位取 → 多一個欄位不會影響既有消費端。
drop function if exists public.stays_for_day(uuid, date, text, double precision, double precision);

create function public.stays_for_day(
  p_user uuid, p_day date, p_tz text default 'Asia/Taipei',
  p_pair_radius_m double precision default 150,
  p_core_radius_m double precision default 100
)
returns table (
  name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text,
  visit_id bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  with v as (
    select row_number() over (order by from_ts, centroid_lat, centroid_lng) as vid, *
    from public.visits_for_day(p_user, p_day, p_tz)
  ),
  s as (
    select row_number() over (order by from_ts) as sid, *
    from public.detect_stays(p_user, p_day, p_tz)
  ),
  pair as (
    select s.sid, v.vid, s.centroid_lat, s.centroid_lng, s.dwell_seconds as s_dwell,
           s.from_ts as s_from, s.to_ts as s_to,
           extract(epoch from (
             least(s.to_ts, coalesce(v.to_ts, s.to_ts)) - greatest(s.from_ts, v.from_ts)
           )) as overlap_s
    from s
    join v on s.from_ts < coalesce(v.to_ts, 'infinity'::timestamptz)
          and v.from_ts < coalesce(s.to_ts, 'infinity'::timestamptz)
          and extensions.st_dwithin(
                extensions.st_setsrid(extensions.st_point(s.centroid_lng, s.centroid_lat), 4326)::extensions.geography,
                extensions.st_setsrid(extensions.st_point(v.centroid_lng, v.centroid_lat), 4326)::extensions.geography,
                p_pair_radius_m)
  ),
  best as (
    select distinct on (vid) vid, sid, centroid_lat, centroid_lng, s_from, s_to
    from pair order by vid, overlap_s desc, s_dwell desc, sid asc
  ),
  base as (
    select v.vid, v.visit_id,
           coalesce(b.centroid_lat, v.centroid_lat) as lat,
           coalesce(b.centroid_lng, v.centroid_lng) as lng,
           case when b.vid is null then v.slack_m else 0 end as slack,
           b.s_from, b.s_to,
           v.from_ts as v_from, v.to_ts as v_to, v.dwell_seconds as v_dwell, v.confidence,
           lag(v.to_ts)    over (order by v.from_ts) as prev_to,
           lead(v.from_ts) over (order by v.from_ts) as next_from
    from v left join best b on b.vid = v.vid
  ),
  core as (
    select b.*,
           (select min(h.captured_at) from public.location_history h
             where h.user_id = p_user and h.source = 'live'
               and h.captured_at >= b.s_from and h.captured_at <= b.s_to
               and extensions.st_dwithin(h.geog,
                     extensions.st_setsrid(extensions.st_makepoint(b.lng, b.lat), 4326)::extensions.geography,
                     p_core_radius_m)) as c_from,
           (select max(h.captured_at) from public.location_history h
             where h.user_id = p_user and h.source = 'live'
               and h.captured_at >= b.s_from and h.captured_at <= b.s_to
               and extensions.st_dwithin(h.geog,
                     extensions.st_setsrid(extensions.st_makepoint(b.lng, b.lat), 4326)::extensions.geography,
                     p_core_radius_m)) as c_to
    from base b
  ),
  merged as (
    select c.*,
           greatest(least(c.v_from, coalesce(c.c_from, c.v_from)),
                    coalesce(c.prev_to, '-infinity'::timestamptz)) as u_from,
           case when c.v_to is null then null
                else least(greatest(c.v_to, coalesce(c.c_to, c.v_to)),
                           coalesce(c.next_from, 'infinity'::timestamptz)) end as u_to
    from core c
  )
  -- 🔴 只有 resolved 才鎖住名字 —— 那是唯一「已經對外宣告過名字」的狀態，時間軸必須跟它同源。
  -- unresolved 對外宣告的是「我判不出來」（v2 事件 name=null 或根本沒發），並沒有宣告任何名字，
  -- 所以時間軸沿用自己的最佳猜測不構成矛盾。實測：若連 unresolved 也鎖，會讓 7 段停留憑空變成無名。
  select case
           when d.decision_status = 'resolved' then d.name_snapshot
           else coalesce(public.visit_place_vote(m.visit_id),
                         public.resolve_name(p_user, m.lat, m.lng, m.slack))
         end as name,
         m.u_from as from_ts,
         m.u_to   as to_ts,
         greatest(0,
           m.v_dwell
           + extract(epoch from (m.v_from - m.u_from))
           + case when m.v_to is null then 0 else extract(epoch from (m.u_to - m.v_to)) end
         )::integer as dwell_seconds,
         m.lat as centroid_lat, m.lng as centroid_lng,
         m.confidence, 'visit'::text as source, m.visit_id
  from merged m
  left join public.visit_event_decisions d
         on d.visit_id = m.visit_id and d.user_id = p_user
  union all
  select public.resolve_name(p_user, s.centroid_lat, s.centroid_lng, 0),
         s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence, 'live'::text, null::bigint
  from s
  where not exists (select 1 from pair p where p.sid = s.sid)
  union all
  select public.resolve_name(p_user, p.centroid_lat, p.centroid_lng, 0),
         p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence, 'photo_import'::text, null::bigint
  from public.photo_points(p_user, p_day, p_tz) p
  order by from_ts asc
$$;

comment on function public.stays_for_day(uuid,date,text,double precision,double precision) is
  '某當地日的合併停留清單。地名：**只有 resolved** 的裁決會鎖定名字（用 name_snapshot、不重新投票）'
  '→ 與已對外發出的具名事件永遠同源；unresolved 從未宣告過名字，因此仍走「當場投票 > 座標現算」。'
  'visit_id 供消費端指認「這一列＝哪一段停留」（人為指定用）；live／photo_import 來源為 null。';

-- 🔴 權限維持 service_role only —— 這是 20260728000005 的越權修補結果，不可放寬。
--    app 是透過 Edge Function today-stays（service role）讀這支，不直接呼叫。
revoke all on function public.stays_for_day(uuid,date,text,double precision,double precision) from public;
grant execute on function public.stays_for_day(uuid,date,text,double precision,double precision) to service_role;

-- ── 2. 人為指定 ──────────────────────────────────────────────────────────────
-- 🔴 不收 user 參數，只認 auth.uid()。repo 已因「definer ＋ 呼叫端可傳 p_user」踩過
--    跨帳號讀取（見 20260728000005），這裡兩個 id 都要驗擁有權。
create or replace function public.assign_visit_landmark(p_visit_id bigint, p_landmark_id bigint)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  me     uuid := (select auth.uid());
  v_uid  uuid;
  l_alias text;
  d      public.visit_event_decisions%rowtype;
begin
  if me is null then
    raise exception '需要登入身分';
  end if;

  -- 兩個 id 都必須屬於呼叫者本人
  select user_id into v_uid from public.visits where id = p_visit_id;
  if v_uid is null or v_uid <> me then
    raise exception '找不到這段停留';           -- 刻意不區分「不存在」與「不屬於你」
  end if;

  select alias into l_alias from public.landmarks
   where id = p_landmark_id and user_id = me;
  if l_alias is null then
    raise exception '找不到這個地標';
  end if;

  select * into d from public.visit_event_decisions
   where visit_id = p_visit_id for update;
  if not found then
    return 'no_decision';
  end if;

  -- 與重判同一條終態守門：已 resolved 或已對外宣告過就不改。
  -- 「使用者想改掉一個已經宣告出去的名字」是還沒拍板的產品政策，不在這支的範圍。
  if d.decision_status = 'resolved' then
    return 'already_resolved';
  end if;
  if d.arrival_sent_at is not null or d.departure_sent_at is not null then
    return 'already_announced';
  end if;

  -- 🔴 pending 也要收。停留剛建立、還沒到裁決截止點時狀態是 pending；
  --    這種時候使用者講的話比「還沒做的感測器推論」更該算數。若只收 unresolved，
  --    人為指定會靜靜變成 race_lost（客戶端根本不看回傳值），之後由感測器決定。
  --    設成 resolved 之後，adjudicate_visit_place 的 upsert 只覆寫 pending → 不會被蓋掉。
  if not exists (select 1 from public.visit_decision_revisions where visit_id = p_visit_id) then
    perform public.record_decision_revision(p_visit_id, 'initial');
  end if;

  update public.visit_event_decisions
     set decision_status = 'resolved',
         reason_code     = 'user_assignment',
         name_snapshot   = l_alias,
         landmark_id     = p_landmark_id,
         decided_at      = coalesce(decided_at, now())
   where visit_id = p_visit_id
     and decision_status in ('unresolved', 'pending')
     and arrival_sent_at is null
     and departure_sent_at is null;

  if not found then
    return 'race_lost';
  end if;

  perform public.record_decision_revision(p_visit_id, 'user_assignment');

  -- 只補一則有意義的（已結束→離開、還開著→到達）；能不能真的送由新鮮度界線決定
  perform public.emit_after_promotion(p_visit_id);

  return 'assigned';
end $$;

comment on function public.assign_visit_landmark(bigint, bigint) is
  '使用者對著某一段停留指認地標。人類標註優先於感測器推論，不需要湊足票數。'
  '只作用於「未送出的 unresolved」；已 resolved 或已宣告過一律不改（回傳原因字串）。';

revoke all on function public.assign_visit_landmark(bigint, bigint) from public;
grant execute on function public.assign_visit_landmark(bigint, bigint) to authenticated;

-- ── 3. 三支對外包裝一併帶出 visit_id ─────────────────────────────────────────
-- 🔴 這一步不是選配：my_today_stays 的本體是 `select * from stays_for_day(...)`，
--    上面替 stays_for_day 加了欄位之後，它會回 9 欄、但宣告只有 8 欄 →
--    「return type mismatch ... returns too many columns」，時間軸整頁掛掉。
--    改回傳型別必須 drop 後重建。
drop function if exists public.my_today_stays(date, text);
create function public.my_today_stays(p_day date, p_tz text default 'Asia/Taipei')
returns table (
  name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision,
  source text, visit_id bigint
)
language sql stable security definer set search_path = ''
as $$
  select * from public.stays_for_day((select auth.uid()), p_day, p_tz)
$$;

revoke all on function public.my_today_stays(date,text) from public;
grant execute on function public.my_today_stays(date,text) to authenticated;

drop function if exists public.my_stays_range(date, date, text);
create function public.my_stays_range(p_from date, p_to date, p_tz text default 'Asia/Taipei')
returns table (
  day date, name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision,
  source text, visit_id bigint
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  d date; hi date;
begin
  hi := least(p_to, p_from + 31);
  d := p_from;
  while d <= hi loop
    return query select d, t.name, t.from_ts, t.to_ts, t.dwell_seconds,
                        t.centroid_lat, t.centroid_lng, t.confidence, t.source, t.visit_id
                 from public.stays_for_day((select auth.uid()), d, p_tz) t;
    d := d + 1;
  end loop;
end $$;

revoke all on function public.my_stays_range(date,date,text) from public;
grant execute on function public.my_stays_range(date,date,text) to authenticated;

drop function if exists public.my_stays_days(date[], text);
create function public.my_stays_days(p_days date[], p_tz text default 'Asia/Taipei')
returns table (
  day date, name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision,
  source text, visit_id bigint
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  d date; arr date[];
begin
  arr := (p_days)[1:31];
  foreach d in array arr loop
    return query select d, t.name, t.from_ts, t.to_ts, t.dwell_seconds,
                        t.centroid_lat, t.centroid_lng, t.confidence, t.source, t.visit_id
                 from public.stays_for_day((select auth.uid()), d, p_tz) t;
  end loop;
end $$;

revoke all on function public.my_stays_days(date[],text) from public;
grant execute on function public.my_stays_days(date[],text) to authenticated;
