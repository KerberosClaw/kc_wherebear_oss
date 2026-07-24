-- kc_wherebear — arbitrary multi-day stays (#5 行事曆多選；可不連續)
-- App-facing: own stays for an arbitrary set of days (auth.uid()-scoped), each row tagged with its day.
create or replace function public.my_stays_days(p_days date[], p_tz text default 'Asia/Taipei')
returns table (
  day           date,
  name          text,
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
  d   date;
  arr date[];
begin
  arr := (p_days)[1:31];  -- 上限 31 天
  foreach d in array arr loop
    return query
      select d,
             public.resolve_alias(auth.uid(), s.centroid_lat, s.centroid_lng),
             s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence
      from public.detect_stays(auth.uid(), d, p_tz) s;
  end loop;
end $$;

comment on function public.my_stays_days(date[],text) is
  'Own stays for an arbitrary set of days (capped 31), each row tagged with its day. auth.uid()-scoped. authenticated.';

revoke all on function public.my_stays_days(date[],text) from public;
grant execute on function public.my_stays_days(date[],text) to authenticated;
