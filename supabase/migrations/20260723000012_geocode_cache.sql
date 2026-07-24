-- kc_wherebear — geocode 快取（同座標查過就存，之後直接讀快取、不再打 Nominatim → 省後端資源）
-- 鍵＝座標四捨五入到 1e-4（~11m）；連「查無結果」也快取（name null）避免重打。
-- 只有 service_role（geocode Edge Function）能存取：開 RLS 但不給 policy → anon/authenticated 讀不到。
create table if not exists public.geocode_cache (
  lat_key    double precision not null,
  lng_key    double precision not null,
  name       text,
  created_at timestamptz not null default now(),
  primary key (lat_key, lng_key)
);
alter table public.geocode_cache enable row level security;
-- geocode Edge Function 以 service_role 直接讀寫這張（非使用者資料、全域共用）→ 明確授權，
-- 不給 anon/authenticated（他們無 grant + RLS 無 policy → 完全讀不到）。
revoke all on public.geocode_cache from anon, authenticated;
grant select, insert, update on public.geocode_cache to service_role;
comment on table public.geocode_cache is
  'Reverse-geocode result cache keyed by rounded coord (~11m). service_role only (geocode Edge Function).';
