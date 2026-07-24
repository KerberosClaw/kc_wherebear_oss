-- kc_wherebear — 地名解析改「alias > geocode 快取 > null」，讓後端一次帶回已快取地名
-- 原本 app 平面只解 alias、通用地名全靠 app 逐點呼叫 geocode function（有上限、多點慢）。
-- 這裡讓三個 stay RPC 的 name 改走 resolve_name：先 alias、再查 geocode_cache（app 之前查過的座標）。
-- app 只需再補「快取還沒有的新座標」。geocode_cache 是 service_role only，但本函式 SECURITY DEFINER
-- 以 owner(postgres) 執行 → 讀得到；快取鍵＝座標四捨五入 4 位（與 app／geocode function 一致）。

create or replace function public.resolve_name(p_user uuid, p_lat double precision, p_lng double precision)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    public.resolve_alias(p_user, p_lat, p_lng),
    -- 對「常數 p_lat」round，不碰欄位 gc.lat_key → 走 PK index (lat_key,lng_key) 點查、不全表掃
    (select gc.name from public.geocode_cache gc
      where gc.lat_key = round(p_lat::numeric, 4)::double precision
        and gc.lng_key = round(p_lng::numeric, 4)::double precision
      limit 1)
  );
$$;

comment on function public.resolve_name(uuid,double precision,double precision) is
  'Name for a coord: user alias > cached reverse-geocode (geocode_cache) > null.';

revoke all on function public.resolve_name(uuid,double precision,double precision) from public;
grant execute on function public.resolve_name(uuid,double precision,double precision) to authenticated, service_role;

-- ── 三個 app 平面 RPC：name 從 resolve_alias 換成 resolve_name（其餘不變）──

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
  select public.resolve_name(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
         s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence, 'live'::text as source
  from public.detect_stays(auth.uid(), p_day, p_tz) s
  union all
  select public.resolve_name(auth.uid(), p.centroid_lat, p.centroid_lng),
         p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence, 'photo_import'::text
  from public.photo_points(auth.uid(), p_day, p_tz) p
  order by from_ts asc
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
      ) t order by t.from_ts asc;
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
      ) t order by t.from_ts asc;
  end loop;
end $$;
