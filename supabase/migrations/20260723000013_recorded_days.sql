-- kc_wherebear — 查某範圍內「哪幾天有記錄」（給時間軸行事曆標記有足跡的日子）
-- 回當地日期（使用者時區）distinct 清單；auth.uid() scope。
create or replace function public.my_recorded_days(p_from date, p_to date, p_tz text default 'Asia/Taipei')
returns table (day date)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct (h.captured_at at time zone p_tz)::date as day
  from public.location_history h
  where h.user_id = auth.uid()
    and h.captured_at >= (p_from::text || ' 00:00:00')::timestamp at time zone p_tz
    and h.captured_at <  ((p_to::text   || ' 00:00:00')::timestamp at time zone p_tz) + interval '1 day'
  order by day;
$$;

comment on function public.my_recorded_days(date,date,text) is
  'Distinct local days (user tz) that have any location_history in [p_from, p_to]. auth.uid()-scoped.';

revoke all on function public.my_recorded_days(date,date,text) from public;
grant execute on function public.my_recorded_days(date,date,text) to authenticated;
