-- kc_wherebear — visits 去重鍵改「到達時刻」＋停留段改「CLVisit 管時間、聚合管位置」合併（D14）
--
-- 三個症狀、兩條根因（2026-07-25 對 prod 實測坐實）：
--
-- 根因 1：`visits` 的 upsert 鍵含 lat/lng。CLVisit 對同一次停留投遞兩次（到達時 departureDate
--         = distantFuture → departed_at 留 null；離開時再投一次帶離開時間），而**兩次投遞的
--         coordinate 不同**（實測差 33～205 m）→ 離開那次沒 UPDATE 到到達那列、改 INSERT 出
--         第二列。實測 11 列只有 6 個相異 arrived_at、6 列 departed_at 為 null，每次到達都留下
--         一個永遠關不掉的孤兒列。症狀＝時間軸同一次停留出現兩筆（看似「沒聚合」），且孤兒列的
--         dwell 走 coalesce(departed_at, now()) 無上限、跨夜後長成 19～20 小時。
--         → 鍵改成 (user_id, arrived_at)：到達時刻已足以識別一次停留，座標不該進鍵。
--         附帶效果：離開改走 UPDATE 後，D13 的 Realtime 訂閱不再收到「同一次到達的第二筆 INSERT」。
--
-- 根因 2：CLVisit 的 coordinate 本質是粗略區域，落在 landmark 半徑外 → 同一個「家」時而解出
--         alias、時而掉回 geocode 路名（實測同一地點落點散在 94～205 m、landmark 半徑 100 m）。
--         → 兩手：(a) 收 CLVisit 自報的 horizontalAccuracy，比對 alias 時把半徑放寬該誤差；
--                 (b) 停留段改合併：時間邊界用 CLVisit（久坐不動時 live 幾乎失明），
--                     位置與名稱優先用配對到的 live 聚合中心（多點平均，比 CLVisit 準）。
--
-- 為什麼不是「停留只用 CLVisit 算」：實測 7/24 聚合抓到 9 段停留、CLVisit 只發 4 次，漏掉的 5 段
-- 全是 11～35 分鐘的短停。兩邊互補、不能二選一。相簿匯入點不受影響（本來就不走 detect_stays）。
--
-- 跨日：visits_for_day 改「與該當地日有交集就出、時間夾在當日邊界內」→ 跨午夜的停留在兩天各出
-- 一段（每日時間軸加總才合得起來），同時天然把孤兒 open 列的 dwell 夾在單日內。

-- ── 1. accuracy 欄（CLVisit horizontalAccuracy；舊列為 null＝不放寬）──
alter table public.visits add column if not exists accuracy double precision;
comment on column public.visits.accuracy is
  'CLVisit horizontalAccuracy (m). Used to widen landmark-alias matching for this coarse coordinate.';

-- ── 2. 併掉既有重複列：每個 (user_id, arrived_at) 只留最後一次投遞那列 ──
-- departed_at 取該組非 null 值（離開那次投遞才有）；座標留最後一次投遞的（決策：最後講的算）。
update public.visits v
set departed_at = g.merged_departed
from (
  select id,
         max(departed_at) over (partition by user_id, arrived_at) as merged_departed,
         row_number() over (partition by user_id, arrived_at order by created_at desc, id desc) as rn
  from public.visits
) g
where v.id = g.id and g.rn = 1 and v.departed_at is distinct from g.merged_departed;

delete from public.visits v
using (
  select id, row_number() over (partition by user_id, arrived_at order by created_at desc, id desc) as rn
  from public.visits
) g
where v.id = g.id and g.rn > 1;

-- ── 3. 換唯一鍵 ──
alter table public.visits drop constraint if exists visits_user_id_arrived_at_lat_lng_key;
alter table public.visits drop constraint if exists visits_user_arrival_key;
alter table public.visits add constraint visits_user_arrival_key unique (user_id, arrived_at);
comment on constraint visits_user_arrival_key on public.visits is
  'One row per arrival. CLVisit re-delivers the same arrival with a drifted coordinate on departure; keying on coordinates would insert a duplicate instead of closing the row.';

-- ── 4. alias／地名解析：加「容差」變體（半徑放寬 p_slack_m）──
create or replace function public.resolve_alias(
  p_user uuid, p_lat double precision, p_lng double precision, p_slack_m double precision
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select l.alias
  from public.landmarks l
  where l.user_id = p_user
    and extensions.st_dwithin(
          l.geog,
          extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
          l.radius + greatest(coalesce(p_slack_m, 0), 0))
  order by
    extensions.st_distance(
      l.geog,
      extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography) asc,
    l.radius asc
  limit 1;
$$;

comment on function public.resolve_alias(uuid,double precision,double precision,double precision) is
  'Nearest user landmark alias containing the coord, radius widened by p_slack_m (the coord own reported accuracy). service_role only.';

revoke all on function public.resolve_alias(uuid,double precision,double precision,double precision) from public;
grant execute on function public.resolve_alias(uuid,double precision,double precision,double precision) to service_role;

create or replace function public.resolve_name(
  p_user uuid, p_lat double precision, p_lng double precision, p_slack_m double precision
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    public.resolve_alias(p_user, p_lat, p_lng, p_slack_m),
    (select gc.name from public.geocode_cache gc
      where gc.lat_key = round(p_lat::numeric, 4)::double precision
        and gc.lng_key = round(p_lng::numeric, 4)::double precision
      limit 1)
  );
$$;

comment on function public.resolve_name(uuid,double precision,double precision,double precision) is
  'Name for a coord with positional slack: user alias (radius + slack) > cached reverse-geocode > null.';

revoke all on function public.resolve_name(uuid,double precision,double precision,double precision) from public;
grant execute on function public.resolve_name(uuid,double precision,double precision,double precision) to authenticated, service_role;

-- ── 5. visits_for_day：改「與當地日有交集」＋時間夾在當日邊界內＋帶出 accuracy 當容差 ──
-- 回傳型別變了（多 slack_m）→ 必須 drop 再建。
drop function if exists public.visits_for_day(uuid,date,text);
create function public.visits_for_day(p_user uuid, p_day date, p_tz text default 'Asia/Taipei')
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
  )
  select greatest(v.arrived_at, b.day_start),
         case
           when v.departed_at is not null then least(v.departed_at, b.day_end)
           when b.day_end <= now()        then b.day_end   -- 過去的日子且沒收到離開事件 → 截到當日結束
           else null                                        -- 今天且仍在停留中
         end,
         greatest(0, extract(epoch from (
           least(coalesce(v.departed_at, now()), b.day_end) - greatest(v.arrived_at, b.day_start)
         )))::integer,
         v.lat, v.lng, 1.0::double precision, v.accuracy
  from public.visits v, b
  where v.user_id = p_user
    and v.arrived_at < b.day_end
    and coalesce(v.departed_at, now()) >= b.day_start
$$;

comment on function public.visits_for_day(uuid,date,text) is
  'CLVisit dwells intersecting a local day, clamped to that day (cross-midnight stays appear on both days). service_role only.';

revoke all on function public.visits_for_day(uuid,date,text) from public;
grant execute on function public.visits_for_day(uuid,date,text) to authenticated, service_role;

-- ── 6. stays_for_day：三來源合併成單一停留清單（三支 app 讀口共用同一份邏輯）──
-- ① CLVisit 段：時間為準；位置／名稱優先用「重疊最久」那段 live 聚合中心（更準），沒配到才用
--    CLVisit 自己的粗座標（此時才用 accuracy 放寬 alias 比對）。
-- ② 沒被任何 CLVisit 段涵蓋的 live 聚合段：原樣保留（CLVisit 漏掉的短停）。
-- ③ 相簿匯入點：獨立、不參與合併。
-- 配對條件＝時間重疊 ∧ 距離 ≤ p_pair_radius_m（預設 150，與 detect_stays 的同一處半徑同值）。
create or replace function public.stays_for_day(
  p_user uuid, p_day date, p_tz text default 'Asia/Taipei',
  p_pair_radius_m double precision default 150
)
returns table (
  name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
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
    select distinct on (vid) vid, centroid_lat, centroid_lng
    from pair
    order by vid, overlap_s desc, s_dwell desc
  )
  select public.resolve_name(p_user,
           coalesce(b.centroid_lat, v.centroid_lat),
           coalesce(b.centroid_lng, v.centroid_lng),
           case when b.vid is null then v.slack_m else 0 end),
         v.from_ts, v.to_ts, v.dwell_seconds,
         coalesce(b.centroid_lat, v.centroid_lat),
         coalesce(b.centroid_lng, v.centroid_lng),
         v.confidence, 'visit'::text
  from v left join best b on b.vid = v.vid
  union all
  select public.resolve_name(p_user, s.centroid_lat, s.centroid_lng, 0),
         s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence, 'live'::text
  from s
  where not exists (select 1 from pair p where p.sid = s.sid)
  union all
  select public.resolve_name(p_user, p.centroid_lat, p.centroid_lng, 0),
         p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence, 'photo_import'::text
  from public.photo_points(p_user, p_day, p_tz) p
  order by from_ts asc
$$;

comment on function public.stays_for_day(uuid,date,text,double precision) is
  'Merged stay list for a local day: CLVisit dwells (time) fused with live clusters (position/name), plus unmatched live stays and photo-import points.';

revoke all on function public.stays_for_day(uuid,date,text,double precision) from public;
grant execute on function public.stays_for_day(uuid,date,text,double precision) to service_role;

-- ── 7. 三支 app 讀口：改用 stays_for_day（簽名不變）──
create or replace function public.my_today_stays(p_day date, p_tz text default 'Asia/Taipei')
returns table (
  name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.stays_for_day(auth.uid(), p_day, p_tz)
$$;

create or replace function public.my_stays_range(p_from date, p_to date, p_tz text default 'Asia/Taipei')
returns table (
  day date, name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d date; hi date;
begin
  hi := least(p_to, p_from + 31);
  d := p_from;
  while d <= hi loop
    return query select d, t.name, t.from_ts, t.to_ts, t.dwell_seconds,
                        t.centroid_lat, t.centroid_lng, t.confidence, t.source
                 from public.stays_for_day(auth.uid(), d, p_tz) t;
    d := d + 1;
  end loop;
end $$;

create or replace function public.my_stays_days(p_days date[], p_tz text default 'Asia/Taipei')
returns table (
  day date, name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d date; arr date[];
begin
  arr := (p_days)[1:31];
  foreach d in array arr loop
    return query select d, t.name, t.from_ts, t.to_ts, t.dwell_seconds,
                        t.centroid_lat, t.centroid_lng, t.confidence, t.source
                 from public.stays_for_day(auth.uid(), d, p_tz) t;
  end loop;
end $$;

grant execute on function public.my_today_stays(date,text) to authenticated;
grant execute on function public.my_stays_range(date,date,text) to authenticated;
grant execute on function public.my_stays_days(date[],text) to authenticated;
