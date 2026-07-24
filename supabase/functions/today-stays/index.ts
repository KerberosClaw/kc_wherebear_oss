// kc_wherebear — R2 today-stays (spec 04)
// x-wb-key → resolve → detect_stays(today, user tz) → per-stay name (alias > geocode > null).
import { serviceClient } from "../_shared/client.ts";
import { resolveKey } from "../_shared/auth.ts";
import { json, err } from "../_shared/respond.ts";
import { cors } from "../_shared/cors.ts";
import { reverseGeocode } from "../_shared/geocode.ts";

const TZ = Deno.env.get("WHEREBEAR_TZ") ?? "Asia/Taipei";

// local date YYYY-MM-DD in the user tz (cross-midnight correct; not naive UTC)
function todayInTz(tz: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const uid = await resolveKey(req);
  if (!uid) return err("unauthenticated", "invalid or missing API key", 401);

  const sb = serviceClient();
  const day = todayInTz(TZ);
  const { data, error } = await sb.rpc("detect_stays", { p_user: uid, p_day: day, p_tz: TZ });
  if (error) return err("server_error", "stay detection failed", 500);

  const stays = [];
  for (const s of (data ?? [])) {
    const { data: alias } = await sb.rpc("resolve_alias", {
      p_user: uid,
      p_lat: s.centroid_lat,
      p_lng: s.centroid_lng,
    });
    const name = (alias as string | null) ?? (await reverseGeocode(s.centroid_lat, s.centroid_lng));
    stays.push({
      name,
      from: s.from_ts,
      to: s.to_ts,
      dwell: s.dwell_seconds,
      centroid_lat: s.centroid_lat,
      centroid_lng: s.centroid_lng,
      confidence: s.confidence,
    });
  }

  return json({ date: day, tz: TZ, stays }); // empty day → stays: []
});
