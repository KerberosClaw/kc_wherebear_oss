-- kc_wherebear — retention archive (spec 01, AC-8)
-- Move location_history rows older than N days into the archive (move, not delete).
-- Retention default 30d (configurable via the function arg / re-schedule).

create or replace function public.archive_old_location_history(retention_days integer default 30)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  moved integer;
begin
  with moved_rows as (
    delete from public.location_history lh
    where lh.captured_at < now() - make_interval(days => retention_days)
    returning lh.id, lh.user_id, lh.lat, lh.lng, lh.accuracy, lh.captured_at, lh.source, lh.created_at
  )
  insert into public.location_history_archive
    (id, user_id, lat, lng, accuracy, captured_at, source, created_at)
  select id, user_id, lat, lng, accuracy, captured_at, source, created_at
  from moved_rows;
  get diagnostics moved = row_count;
  return moved;
end $$;

comment on function public.archive_old_location_history(integer) is
  'Moves location_history rows older than retention_days into location_history_archive. Returns rows moved.';

-- Schedule daily at 04:00 via pg_cron when available (cloud / local with pg_cron).
-- Local stacks without pg_cron simply skip scheduling; the function can be called directly.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule('wherebear-archive-history')
      where exists (select 1 from cron.job where jobname = 'wherebear-archive-history');
    perform cron.schedule(
      'wherebear-archive-history',
      '0 4 * * *',
      $cron$ select public.archive_old_location_history(30); $cron$
    );
  end if;
end $$;
