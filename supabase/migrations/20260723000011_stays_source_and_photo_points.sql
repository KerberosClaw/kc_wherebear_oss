-- kc_wherebear — P1 相簿匯入點以「個別點」呈現 + Q8 匯入去重
-- 問題：detect_stays 把 location_history 全部（live + photo_import）一起聚成停留段，
--       單一 photo_import 點 dwell=0 → 永遠聚不出 stay → 時間軸「沒有足跡」。
-- 修法：
--   (1) detect_stays 只聚 source='live'（photo 點不再污染 live 聚類、也不會被雙重計算）。
--   (2) 新增 photo_points()：把 photo_import 點以「個別點」回傳（to_ts=null、dwell=0）。
--   (3) app-facing 三口（my_today_stays / my_stays_range / my_stays_days）UNION 兩者，
--       並加 source 欄讓前端區分「停留段(live)」vs「匯入點(photo_import)」。
--   (4) 去重：unique index (user_id, source, captured_at, lat, lng) → 重複匯入同張照片被擋。
-- headless 讀口 /today-stays 仍走 detect_stays（live-only）→ 下游只吃「面」、不吃匯入點（符合契約 §2.2）。

-- ── (4) 去重：先清既有重複（保留最小 id），再建唯一索引 ──
-- 涵蓋所有 source：同 (user, source, captured_at, lat, lng) 的多筆＝同一筆讀數（live 亦可能因
-- poll×significant-change 幾乎同時觸發而重複），刪重無損。
delete from public.location_history a
using public.location_history b
where a.user_id = b.user_id
  and a.source = b.source
  and a.captured_at = b.captured_at
  and a.lat = b.lat
  and a.lng = b.lng
  and a.id > b.id;

create unique index if not exists location_history_dedup_idx
  on public.location_history (user_id, source, captured_at, lat, lng);

-- ── (1) detect_stays：只聚 live 點（簽名不變 → 直接 replace、依賴者不受影響）──
create or replace function public.detect_stays(
  p_user        uuid,
  p_day         date,
  p_tz          text default 'Asia/Taipei',
  p_radius_m    double precision default 150,
  p_min_dwell_s integer default 600,
  p_gap_s       integer default 1800
)
returns table (
  from_ts       timestamptz,
  to_ts         timestamptz,
  dwell_seconds integer,
  centroid_lat  double precision,
  centroid_lng  double precision,
  confidence    double precision
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  day_start timestamptz;
  day_end   timestamptz;
  r         record;
  a_lat double precision; a_lng double precision;     -- anchor of current cluster
  c_from timestamptz; c_to timestamptz;
  c_sum_lat double precision; c_sum_lng double precision; c_n int;
  prev_ts timestamptz;
  d double precision;
  have boolean := false;
begin
  day_start := (p_day::text || ' 00:00:00')::timestamp at time zone p_tz;
  day_end   := day_start + interval '1 day';

  for r in
    select lat, lng, captured_at
    from public.location_history
    where user_id = p_user
      and source = 'live'                 -- ⬅ 只聚實時點；匯入點另走 photo_points()
      and captured_at >= day_start
      and captured_at <  day_end
    order by captured_at asc
  loop
    if not have then
      a_lat := r.lat; a_lng := r.lng;
      c_from := r.captured_at; c_to := r.captured_at;
      c_sum_lat := r.lat; c_sum_lng := r.lng; c_n := 1;
      prev_ts := r.captured_at; have := true;
      continue;
    end if;

    if extract(epoch from (r.captured_at - prev_ts)) > p_gap_s then
      if extract(epoch from (c_to - c_from)) >= p_min_dwell_s then
        from_ts := c_from; to_ts := c_to;
        dwell_seconds := floor(extract(epoch from (c_to - c_from)))::int;
        centroid_lat := c_sum_lat / c_n; centroid_lng := c_sum_lng / c_n;
        confidence := least(1.0, greatest(0.2, c_n::double precision / 6.0));
        return next;
      end if;
      a_lat := r.lat; a_lng := r.lng;
      c_from := r.captured_at; c_to := r.captured_at;
      c_sum_lat := r.lat; c_sum_lng := r.lng; c_n := 1;
      prev_ts := r.captured_at;
      continue;
    end if;

    d := extensions.st_distance(
      extensions.st_setsrid(extensions.st_point(a_lng, a_lat), 4326)::extensions.geography,
      extensions.st_setsrid(extensions.st_point(r.lng, r.lat), 4326)::extensions.geography
    );
    if d <= p_radius_m then
      c_to := r.captured_at;
      c_sum_lat := c_sum_lat + r.lat; c_sum_lng := c_sum_lng + r.lng; c_n := c_n + 1;
      prev_ts := r.captured_at;
    else
      if extract(epoch from (c_to - c_from)) >= p_min_dwell_s then
        from_ts := c_from; to_ts := c_to;
        dwell_seconds := floor(extract(epoch from (c_to - c_from)))::int;
        centroid_lat := c_sum_lat / c_n; centroid_lng := c_sum_lng / c_n;
        confidence := least(1.0, greatest(0.2, c_n::double precision / 6.0));
        return next;
      end if;
      a_lat := r.lat; a_lng := r.lng;
      c_from := r.captured_at; c_to := r.captured_at;
      c_sum_lat := r.lat; c_sum_lng := r.lng; c_n := 1;
      prev_ts := r.captured_at;
    end if;
  end loop;

  if have and extract(epoch from (c_to - c_from)) >= p_min_dwell_s then
    from_ts := c_from; to_ts := c_to;
    dwell_seconds := floor(extract(epoch from (c_to - c_from)))::int;
    centroid_lat := c_sum_lat / c_n; centroid_lng := c_sum_lng / c_n;
    confidence := least(1.0, greatest(0.2, c_n::double precision / 6.0));
    return next;
  end if;
  return;
end $$;

-- ── (2) photo_points：把某日的匯入點以「個別點」回傳（內部用；service_role）──
create or replace function public.photo_points(
  p_user uuid,
  p_day  date,
  p_tz   text default 'Asia/Taipei'
)
returns table (
  from_ts       timestamptz,
  to_ts         timestamptz,
  dwell_seconds integer,
  centroid_lat  double precision,
  centroid_lng  double precision,
  confidence    double precision
)
language sql
stable
security definer
set search_path = ''
as $$
  select h.captured_at as from_ts,
         null::timestamptz as to_ts,
         0 as dwell_seconds,
         h.lat as centroid_lat,
         h.lng as centroid_lng,
         1.0::double precision as confidence
  from public.location_history h
  where h.user_id = p_user
    and h.source = 'photo_import'
    and h.captured_at >= (p_day::text || ' 00:00:00')::timestamp at time zone p_tz
    and h.captured_at <  ((p_day::text || ' 00:00:00')::timestamp at time zone p_tz) + interval '1 day'
  order by h.captured_at asc
$$;

revoke all on function public.photo_points(uuid,date,text) from public;
grant execute on function public.photo_points(uuid,date,text) to service_role;

-- ── (3) app-facing 三口：加 name + source，UNION 停留段(live) + 匯入點(photo_import) ──

drop function if exists public.my_today_stays(date, text);
create or replace function public.my_today_stays(p_day date, p_tz text default 'Asia/Taipei')
returns table (
  name          text,
  from_ts       timestamptz,
  to_ts         timestamptz,
  dwell_seconds integer,
  centroid_lat  double precision,
  centroid_lng  double precision,
  confidence    double precision,
  source        text
)
language sql
stable
security definer
set search_path = ''
as $$
  select public.resolve_alias(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
         s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence,
         'live'::text as source
  from public.detect_stays(auth.uid(), p_day, p_tz) s
  union all
  select public.resolve_alias(auth.uid(), p.centroid_lat, p.centroid_lng),
         p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence,
         'photo_import'::text
  from public.photo_points(auth.uid(), p_day, p_tz) p
  order by from_ts asc
$$;

comment on function public.my_today_stays(date,text) is
  'Own stays for a local day (auth.uid()-scoped): live dwell-stays + photo_import individual points, tagged by source.';

revoke all on function public.my_today_stays(date,text) from public;
grant execute on function public.my_today_stays(date,text) to authenticated;

drop function if exists public.my_stays_range(date, date, text);
create or replace function public.my_stays_range(p_from date, p_to date, p_tz text default 'Asia/Taipei')
returns table (
  day           date,
  name          text,
  from_ts       timestamptz,
  to_ts         timestamptz,
  dwell_seconds integer,
  centroid_lat  double precision,
  centroid_lng  double precision,
  confidence    double precision,
  source        text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d  date;
  hi date;
begin
  hi := least(p_to, p_from + 31);  -- 上限 32 天
  d := p_from;
  while d <= hi loop
    return query
      select * from (
        select d as day,
               public.resolve_alias(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
               s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence,
               'live'::text as source
        from public.detect_stays(auth.uid(), d, p_tz) s
        union all
        select d,
               public.resolve_alias(auth.uid(), p.centroid_lat, p.centroid_lng),
               p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence,
               'photo_import'::text
        from public.photo_points(auth.uid(), d, p_tz) p
      ) t order by t.from_ts asc;
    d := d + 1;
  end loop;
end $$;

comment on function public.my_stays_range(date,date,text) is
  'Own stays across [p_from, p_to] (capped 32 days): live stays + photo_import points, tagged by day+source. auth.uid()-scoped.';

revoke all on function public.my_stays_range(date,date,text) from public;
grant execute on function public.my_stays_range(date,date,text) to authenticated;

drop function if exists public.my_stays_days(date[], text);
create or replace function public.my_stays_days(p_days date[], p_tz text default 'Asia/Taipei')
returns table (
  day           date,
  name          text,
  from_ts       timestamptz,
  to_ts         timestamptz,
  dwell_seconds integer,
  centroid_lat  double precision,
  centroid_lng  double precision,
  confidence    double precision,
  source        text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  d   date;
  arr date[];
begin
  arr := (p_days)[1:31];  -- 上限 31 天
  foreach d in array arr loop
    return query
      select * from (
        select d as day,
               public.resolve_alias(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
               s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence,
               'live'::text as source
        from public.detect_stays(auth.uid(), d, p_tz) s
        union all
        select d,
               public.resolve_alias(auth.uid(), p.centroid_lat, p.centroid_lng),
               p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence,
               'photo_import'::text
        from public.photo_points(auth.uid(), d, p_tz) p
      ) t order by t.from_ts asc;
  end loop;
end $$;

comment on function public.my_stays_days(date[],text) is
  'Own stays for an arbitrary set of days (capped 31): live stays + photo_import points, tagged by day+source. auth.uid()-scoped.';

revoke all on function public.my_stays_days(date[],text) from public;
grant execute on function public.my_stays_days(date[],text) to authenticated;
