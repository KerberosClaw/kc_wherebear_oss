-- kc_wherebear — updated_at 自動更新（moddatetime）
--
-- 修的問題：updated_at 欄只有 `default now()`，那只在 INSERT 建列時設一次；
-- 之後 upsert / PATCH 的 UPDATE 不會動它（app payload 沒送 updated_at、DB 也沒 trigger）
-- → updated_at 永遠卡在「這列第一次被建立的時間」，名不符實。
--
-- 解：moddatetime（Postgres 標準 contrib、Supabase 預裝可用）BEFORE UPDATE 自動把指定欄設成 now()。
-- 套用對象＝有 updated_at 且會被 UPDATE 的表：current_location（upsert）/ landmarks（PATCH）/ profile（改頭貼）。
-- （location_history/archive 為 append-only、visits 無 updated_at 欄 → 不需要。）

create extension if not exists moddatetime schema extensions;

drop trigger if exists set_updated_at on public.current_location;
create trigger set_updated_at
  before update on public.current_location
  for each row execute function extensions.moddatetime(updated_at);

drop trigger if exists set_updated_at on public.landmarks;
create trigger set_updated_at
  before update on public.landmarks
  for each row execute function extensions.moddatetime(updated_at);

drop trigger if exists set_updated_at on public.profile;
create trigger set_updated_at
  before update on public.profile
  for each row execute function extensions.moddatetime(updated_at);
