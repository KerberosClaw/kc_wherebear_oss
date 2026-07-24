-- kc_wherebear — avatars storage (spec 01, AC-11)
-- PUBLIC bucket (public URL read) + owner-only write via storage.objects RLS.
-- Object path convention: "{user_id}/avatar.<ext>" → path first segment encodes owner.
-- Avatar is a display photo; PUBLIC read is decoupled from location privacy (API_CONTRACT §1.5).

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

-- public read (anyone) — bucket is public; explicit select policy covers direct queries
drop policy if exists "avatars public read" on storage.objects;
create policy "avatars public read" on storage.objects
  for select to public
  using (bucket_id = 'avatars');

-- owner-only write: first path segment must equal auth.uid()
drop policy if exists "avatars owner insert" on storage.objects;
create policy "avatars owner insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars owner update" on storage.objects;
create policy "avatars owner update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars owner delete" on storage.objects;
create policy "avatars owner delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
