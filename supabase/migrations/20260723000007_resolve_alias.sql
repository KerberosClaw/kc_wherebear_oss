-- kc_wherebear — landmark alias resolution (spec 06)
-- coord → nearest landmark whose radius contains it (tie-break smallest radius), else null.
-- alias > geocode > null is assembled in the read layer (spec 04 / app); this is the alias step.

create or replace function public.resolve_alias(
  p_user uuid, p_lat double precision, p_lng double precision
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
          l.radius)
  order by
    extensions.st_distance(
      l.geog,
      extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography) asc,
    l.radius asc
  limit 1;
$$;

comment on function public.resolve_alias(uuid,double precision,double precision) is
  'Nearest user landmark alias containing the coord (tie-break smallest radius), else null. service_role only.';

revoke all on function public.resolve_alias(uuid,double precision,double precision) from public;
grant execute on function public.resolve_alias(uuid,double precision,double precision) to service_role;

-- App-facing: resolve own alias (auth.uid()-scoped).
create or replace function public.my_resolve_alias(p_lat double precision, p_lng double precision)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select public.resolve_alias(auth.uid(), p_lat, p_lng);
$$;

revoke all on function public.my_resolve_alias(double precision,double precision) from public;
grant execute on function public.my_resolve_alias(double precision,double precision) to authenticated;

-- Redefine my_today_stays to include the resolved alias name (alias or null → app falls back to raw).
drop function if exists public.my_today_stays(date, text);
create function public.my_today_stays(p_day date, p_tz text default 'Asia/Taipei')
returns table (
  name          text,
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
  select public.resolve_alias(auth.uid(), s.centroid_lat, s.centroid_lng) as name,
         s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence
  from public.detect_stays(auth.uid(), p_day, p_tz) s;
$$;

comment on function public.my_today_stays(date,text) is
  'Own stays for a local day with resolved alias name (auth.uid()-scoped). authenticated.';

revoke all on function public.my_today_stays(date,text) from public;
grant execute on function public.my_today_stays(date,text) to authenticated;
