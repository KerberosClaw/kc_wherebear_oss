-- kc_wherebear — core schema (spec 01: db-foundation)
-- born-clean: schema only, zero seed data. All coords stored as raw lat/lng
-- (contract requires raw kept) + a generated geography(Point,4326) for spatial.

create extension if not exists postgis with schema extensions;

-- ── location_source enum (idempotent) ──
do $$
begin
  if not exists (select 1 from pg_type where typname = 'location_source') then
    create type public.location_source as enum ('live', 'photo_import');
  end if;
end $$;

-- ── current_location (hot · one row per user · upsert) ── (API_CONTRACT §1.1)
create table if not exists public.current_location (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  lat         double precision not null,
  lng         double precision not null,
  geog        geography(Point, 4326)
              generated always as (extensions.st_setsrid(extensions.st_point(lng, lat), 4326)::geography) stored,
  accuracy    double precision not null,
  captured_at timestamptz not null,
  place_label text,
  updated_at  timestamptz not null default now()
);
comment on table public.current_location is 'Hot table: latest location per user (upsert target).';

-- ── location_history (cold · append) ── (API_CONTRACT §1.2)
create table if not exists public.location_history (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  lat         double precision not null,
  lng         double precision not null,
  geog        geography(Point, 4326)
              generated always as (extensions.st_setsrid(extensions.st_point(lng, lat), 4326)::geography) stored,
  accuracy    double precision not null,
  captured_at timestamptz not null,
  source      public.location_source not null default 'live',
  created_at  timestamptz not null default now()
);
create index if not exists location_history_user_captured_idx
  on public.location_history (user_id, captured_at desc);
create index if not exists location_history_geog_idx
  on public.location_history using gist (geog);
comment on table public.location_history is 'Cold table: append-only history for stay detection + archive.';

-- ── location_history_archive (retention cold storage · move-not-delete) ── (API_CONTRACT / DESIGN D7)
-- plain mirror (no generated/identity) so archive_old_location_history() can insert original ids.
create table if not exists public.location_history_archive (
  id          bigint primary key,
  user_id     uuid not null,
  lat         double precision not null,
  lng         double precision not null,
  accuracy    double precision not null,
  captured_at timestamptz not null,
  source      public.location_source not null,
  created_at  timestamptz not null,
  archived_at timestamptz not null default now()
);
comment on table public.location_history_archive is 'Rows moved out of location_history past the retention window (moved, not deleted).';

-- ── landmarks (user-defined aliases) ── (API_CONTRACT §1.3 / DESIGN D11)
create table if not exists public.landmarks (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  alias      text not null,
  lat        double precision not null,
  lng        double precision not null,
  geog       geography(Point, 4326)
             generated always as (extensions.st_setsrid(extensions.st_point(lng, lat), 4326)::geography) stored,
  radius     integer not null check (radius > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists landmarks_user_idx on public.landmarks (user_id);
create index if not exists landmarks_geog_idx on public.landmarks using gist (geog);
comment on table public.landmarks is 'User-defined landmark aliases (runtime data; NEVER seeded).';

-- ── api_keys (hashed wb_ PAT for headless read plane) ── (API_CONTRACT §1.4)
create table if not exists public.api_keys (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  name         text not null,
  key_hash     text not null unique,
  key_last4    text not null,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
create index if not exists api_keys_user_idx on public.api_keys (user_id);
create index if not exists api_keys_active_hash_idx on public.api_keys (key_hash) where revoked_at is null;
comment on table public.api_keys is 'Hashed wb_ API keys (PAT). Stores sha256 hash + last4 only, never plaintext.';

-- ── profile (avatar) ── (API_CONTRACT §1.5)
create table if not exists public.profile (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  avatar_path text,
  updated_at  timestamptz not null default now()
);
comment on table public.profile is 'Per-user profile; avatar_path points into the public avatars storage bucket.';
