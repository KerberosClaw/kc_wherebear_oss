-- kc_wherebear — API key resolution primitive (spec 02)
--
-- Canonical hashing (SHARED between client issuance [app spec 07] and this resolver):
--   plaintext key = 'wb_' || <>=32 bytes random>       (client generates, shown once)
--   stored key_hash = lower(hex(sha256(utf8(plaintext))))
--   resolve = sha256-hex of the presented key, matched against non-revoked rows.
-- No per-key salt: keys are high-entropy random, so a plain sha256 is sufficient and
-- allows an equality lookup by hash.

create extension if not exists pgcrypto with schema extensions;

create or replace function public.resolve_api_key(presented text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid;
begin
  if presented is null or presented = '' then
    return null;
  end if;
  update public.api_keys k
     set last_used_at = now()
   where k.key_hash = encode(extensions.digest(convert_to(presented, 'UTF8'), 'sha256'), 'hex')
     and k.revoked_at is null
  returning k.user_id into uid;
  return uid;  -- null when no active key matches → caller returns 401
end $$;

comment on function public.resolve_api_key(text) is
  'Resolves a presented wb_ API key to its user_id (sha256-hex match on non-revoked rows) and bumps last_used_at. Returns null when no active key matches. Called by read-plane Edge Functions under service_role only.';

-- Only the headless read plane (service_role) may resolve keys — never anon/authenticated
-- (prevents a logged-in user from brute-forcing keys via the function).
revoke all on function public.resolve_api_key(text) from public;
grant execute on function public.resolve_api_key(text) to service_role;
