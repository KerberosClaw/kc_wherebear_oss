-- kc_wherebear — read-plane current_location accessor (spec 04)
-- The read Edge Function uses service_role, which (with auto-expose off) has no direct
-- table grants. Route current_location reads through a SECURITY DEFINER RPC — same pattern
-- as detect_stays / resolve_alias: service_role-only, self-scoped by the caller-passed user.

create or replace function public.current_for(p_user uuid)
returns table (
  lat double precision, lng double precision, accuracy double precision, captured_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select lat, lng, accuracy, captured_at
  from public.current_location
  where user_id = p_user;
$$;

comment on function public.current_for(uuid) is
  'Current location row for a user (read plane). service_role only.';

revoke all on function public.current_for(uuid) from public;
grant execute on function public.current_for(uuid) to service_role;
