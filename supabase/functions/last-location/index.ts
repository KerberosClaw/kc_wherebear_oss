// kc_wherebear — R1 last-location (spec 04)
// x-wb-key → resolve → self-scoped current_location → resolved_name (alias > geocode > null).
import { serviceClient } from "../_shared/client.ts";
import { resolveKey } from "../_shared/auth.ts";
import { json, err } from "../_shared/respond.ts";
import { cors } from "../_shared/cors.ts";
import { reverseGeocode } from "../_shared/geocode.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const uid = await resolveKey(req);
  if (!uid) return err("unauthenticated", "invalid or missing API key", 401);

  const sb = serviceClient();
  // owner-scope via SECURITY DEFINER RPC (service_role has no direct table grants under auto-expose off)
  const { data, error } = await sb.rpc("current_for", { p_user: uid });
  if (error) return err("server_error", "query failed", 500);
  const row = (Array.isArray(data) && data.length > 0) ? data[0] : null;
  if (!row) {
    // 200 + null: queryable but no data yet (API_CONTRACT §5)
    return json({ lat: null, lng: null, accuracy: null, captured_at: null, resolved_name: null });
  }
  const { data: alias } = await sb.rpc("resolve_alias", {
    p_user: uid,
    p_lat: row.lat,
    p_lng: row.lng,
  });
  const resolved_name = (alias as string | null) ?? (await reverseGeocode(row.lat, row.lng));

  return json({
    lat: row.lat,
    lng: row.lng,
    accuracy: row.accuracy,
    captured_at: row.captured_at,
    resolved_name,
  });
});
