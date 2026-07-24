// kc_wherebear — service_role client for the headless read plane (spec 04)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected by the edge runtime (local + cloud).
// service_role bypasses RLS → every query MUST self-scope to the resolved user_id.
import { createClient } from "jsr:@supabase/supabase-js@2";

export function serviceClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}
