-- kc_wherebear — multi-day stays range (#5 多日時間軸；spec 03/06 延伸)
-- App-facing: own stays across a date range (auth.uid()-scoped), each row tagged with its day.
create or replace function public.my_stays_range(p_from date, p_to date, p_tz text default 'Asia/Taipei')
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
  d  date;
  hi date;
begin
  hi := least(p_to, p_from + 31);  -- 上限 32 天，避免過大範圍
  d := p_from;
  while d <= hi loop
    return query
      select d,
             public.resolve_alias(auth.uid(), s.centroid_lat, s.centroid_lng),
             s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence
      from public.detect_stays(auth.uid(), d, p_tz) s;
    d := d + 1;
  end loop;
end $$;

comment on function public.my_stays_range(date,date,text) is
  'Own stays across [p_from, p_to] (capped 32 days), each row tagged with its day. auth.uid()-scoped. authenticated.';

revoke all on function public.my_stays_range(date,date,text) from public;
grant execute on function public.my_stays_range(date,date,text) to authenticated;
