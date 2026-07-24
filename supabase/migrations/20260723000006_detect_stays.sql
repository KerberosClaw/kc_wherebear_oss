-- kc_wherebear — stay-point detection (spec 03)
-- Aggregates a user's location_history for a given local day (user tz) into stays.
-- Params are starting values (tunable via config / re-tune with real data spike):
--   radius_m=150, min_dwell_s=600 (10 min), gap_s=1800 (30 min).
-- Returns geometry + timing + confidence; NAME is filled later by the read layer
-- (resolve_alias / geocode). Two entry points:
--   detect_stays(p_user, ...)  — service_role only (read-plane Edge Function passes resolved user)
--   my_today_stays(...)        — authenticated, scoped to auth.uid() (app JWT plane)

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

  procedure_emit boolean;  -- placeholder (PL/pgSQL has no local procs; inline below)
begin
  day_start := (p_day::text || ' 00:00:00')::timestamp at time zone p_tz;
  day_end   := day_start + interval '1 day';

  for r in
    select lat, lng, captured_at
    from public.location_history
    where user_id = p_user
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

    -- time gap → break current cluster
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

comment on function public.detect_stays(uuid,date,text,double precision,integer,integer) is
  'Stay-point detection over a users location_history for a local day (user tz). service_role only.';

revoke all on function public.detect_stays(uuid,date,text,double precision,integer,integer) from public;
grant execute on function public.detect_stays(uuid,date,text,double precision,integer,integer) to service_role;

-- App-facing wrapper: caller can only get their OWN stays (auth.uid()).
create or replace function public.my_today_stays(
  p_day date,
  p_tz  text default 'Asia/Taipei'
)
returns table (
  from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.detect_stays(auth.uid(), p_day, p_tz);
$$;

comment on function public.my_today_stays(date,text) is
  'Own stays for a local day (auth.uid()-scoped). Granted to authenticated for the app JWT plane.';

revoke all on function public.my_today_stays(date,text) from public;
grant execute on function public.my_today_stays(date,text) to authenticated;
