-- kc_wherebear — CLVisit 靜止停留：背景 visit-monitoring 補 detect_stays 抓不到的長靜止停留（在家/公司久坐不動）。
-- visits 表 owner-only RLS；三個 stay 讀口 UNION 進來（source='visit'）。app 端把「detect_stays 聚出的 live 停留」
-- 與「visit 停留」時間+位置接近者去重（優先 visit）。空表時三讀口行為不變（純加一支空 UNION）。

-- ── visits 表 ──
create table if not exists public.visits (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  lat         double precision not null,
  lng         double precision not null,
  arrived_at  timestamptz not null,
  departed_at timestamptz,                       -- 仍在停留可為 null（CLVisit departureDate = distantFuture）
  created_at  timestamptz not null default now(),
  unique (user_id, arrived_at, lat, lng)         -- 同一 visit（到達＋離開兩次投遞）以此鍵 upsert 更新 departed_at
);

alter table public.visits enable row level security;

drop policy if exists "own visits" on public.visits;
create policy "own visits" on public.visits
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

grant select, insert, update, delete on public.visits to authenticated;

create index if not exists visits_user_time on public.visits (user_id, arrived_at);
comment on table public.visits is 'CLVisit-detected dwell periods (static long stays detect_stays misses). UNIONed into stay reads; deduped app-side.';

-- ── 某本地日的 visit（依 arrived_at 當地日期歸屬，與 stay 一致）──
create or replace function public.visits_for_day(p_user uuid, p_day date, p_tz text default 'Asia/Taipei')
returns table (
  from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision
)
language sql stable security definer set search_path = ''
as $$
  select v.arrived_at,
         v.departed_at,
         greatest(0, extract(epoch from (coalesce(v.departed_at, now()) - v.arrived_at)))::integer,
         v.lat, v.lng, 1.0::double precision
  from public.visits v
  where v.user_id = p_user
    and (v.arrived_at at time zone p_tz)::date = p_day
$$;

revoke all on function public.visits_for_day(uuid,date,text) from public;
grant execute on function public.visits_for_day(uuid,date,text) to authenticated, service_role;

-- ── 三個 stay 讀口：加 visits UNION 分支（source='visit'）──
create or replace function public.my_today_stays(p_day date, p_tz text default 'Asia/Taipei')
returns table (
  name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
)
language sql stable security definer set search_path = ''
as $$
  select public.resolve_name(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
         s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence, 'live'::text as source
  from public.detect_stays(auth.uid(), p_day, p_tz) s
  union all
  select public.resolve_name(auth.uid(), p.centroid_lat, p.centroid_lng),
         p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence, 'photo_import'::text
  from public.photo_points(auth.uid(), p_day, p_tz) p
  union all
  select public.resolve_name(auth.uid(), v.centroid_lat, v.centroid_lng),
         v.from_ts, v.to_ts, v.dwell_seconds, v.centroid_lat, v.centroid_lng, v.confidence, 'visit'::text
  from public.visits_for_day(auth.uid(), p_day, p_tz) v
  order by from_ts asc
$$;

create or replace function public.my_stays_range(p_from date, p_to date, p_tz text default 'Asia/Taipei')
returns table (
  day date, name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  d date; hi date;
begin
  hi := least(p_to, p_from + 31);
  d := p_from;
  while d <= hi loop
    return query
      select * from (
        select d as day,
               public.resolve_name(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
               s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence, 'live'::text as source
        from public.detect_stays(auth.uid(), d, p_tz) s
        union all
        select d,
               public.resolve_name(auth.uid(), p.centroid_lat, p.centroid_lng),
               p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence, 'photo_import'::text
        from public.photo_points(auth.uid(), d, p_tz) p
        union all
        select d,
               public.resolve_name(auth.uid(), v.centroid_lat, v.centroid_lng),
               v.from_ts, v.to_ts, v.dwell_seconds, v.centroid_lat, v.centroid_lng, v.confidence, 'visit'::text
        from public.visits_for_day(auth.uid(), d, p_tz) v
      ) t order by t.from_ts asc;
    d := d + 1;
  end loop;
end $$;

create or replace function public.my_stays_days(p_days date[], p_tz text default 'Asia/Taipei')
returns table (
  day date, name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
)
language plpgsql stable security definer set search_path = ''
as $$
declare
  d date; arr date[];
begin
  arr := (p_days)[1:31];
  foreach d in array arr loop
    return query
      select * from (
        select d as day,
               public.resolve_name(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
               s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence, 'live'::text as source
        from public.detect_stays(auth.uid(), d, p_tz) s
        union all
        select d,
               public.resolve_name(auth.uid(), p.centroid_lat, p.centroid_lng),
               p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence, 'photo_import'::text
        from public.photo_points(auth.uid(), d, p_tz) p
        union all
        select d,
               public.resolve_name(auth.uid(), v.centroid_lat, v.centroid_lng),
               v.from_ts, v.to_ts, v.dwell_seconds, v.centroid_lat, v.centroid_lng, v.confidence, 'visit'::text
        from public.visits_for_day(auth.uid(), d, p_tz) v
      ) t order by t.from_ts asc;
  end loop;
end $$;

grant execute on function public.my_today_stays(date,text) to authenticated;
grant execute on function public.my_stays_range(date,date,text) to authenticated;
grant execute on function public.my_stays_days(date[],text) to authenticated;
