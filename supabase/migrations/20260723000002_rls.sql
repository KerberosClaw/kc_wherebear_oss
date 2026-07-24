-- kc_wherebear — RLS + Data API grants (spec 01)
-- Every user table: RLS on, all ops scoped to auth.uid(). Archive: RLS on, no policy (deny).
-- Self-contained grants so exposure does not depend on the project's "auto-expose" toggle.

alter table public.current_location          enable row level security;
alter table public.location_history          enable row level security;
alter table public.location_history_archive  enable row level security;
alter table public.landmarks                 enable row level security;
alter table public.api_keys                  enable row level security;
alter table public.profile                   enable row level security;

-- ── per-table owner policies (auth.uid() = user_id) ──
drop policy if exists "own current_location" on public.current_location;
create policy "own current_location" on public.current_location
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own location_history" on public.location_history;
create policy "own location_history" on public.location_history
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own landmarks" on public.landmarks;
create policy "own landmarks" on public.landmarks
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own api_keys" on public.api_keys;
create policy "own api_keys" on public.api_keys
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own profile" on public.profile;
create policy "own profile" on public.profile
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- location_history_archive: RLS enabled, NO policy → authenticated denied.
-- Only service_role / SECURITY DEFINER functions (e.g. archive job) reach it.

-- ── Data API exposure (grant only app-facing tables; archive stays hidden) ──
grant select, insert, update, delete on public.current_location to authenticated;
grant select, insert, update, delete on public.location_history to authenticated;
grant select, insert, update, delete on public.landmarks        to authenticated;
grant select, insert, update, delete on public.api_keys         to authenticated;
grant select, insert, update, delete on public.profile          to authenticated;
-- location_history_archive: intentionally NOT granted to authenticated/anon.
