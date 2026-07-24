-- kc_wherebear — profile.display_name（暱稱）
-- 公開線 pre-phase-3：設定頁 / 未來好友清單顯示名字，不再只顯示 email。
-- 可空；UI 空值時 fallback 回 email。moddatetime（20260724000001）已在 profile 上
-- → display_name 更新時 updated_at 自動刷新，無需額外處理。

alter table public.profile add column if not exists display_name text;
comment on column public.profile.display_name is 'User-chosen display name (nickname). Nullable; UI falls back to email when empty.';

-- 讓 PostgREST 認得新欄位（dev 需要；cloud 套 migration 後會自行 reload）
notify pgrst, 'reload schema';
