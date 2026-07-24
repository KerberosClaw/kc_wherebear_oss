// kc_wherebear — headless read-plane auth (spec 04)
// Presented wb_ key in the `x-wb-key` header → resolve_api_key RPC → user_id (or null → 401).
// (Custom header avoids colliding with Supabase's gateway `apikey`.)
import { serviceClient } from "./client.ts";

export async function resolveKey(req: Request): Promise<string | null> {
  const key = req.headers.get("x-wb-key");
  if (!key) return null;
  const sb = serviceClient();
  const { data, error } = await sb.rpc("resolve_api_key", { presented: key });
  if (error || !data) return null;
  return data as string; // resolved user_id (uuid)
}
