// kc_wherebear — R2 today-stays (spec 04)
// x-wb-key → resolve → stays_for_day(today, user tz) → per-stay name (alias > geocode cache > geocode > null).
// D14：改吃 stays_for_day（CLVisit 時間 ＋ live 聚合位置的合併結果），不再只吃 detect_stays。
// 只吃 detect_stays 時，久坐不動的長停留在下游會縮成碎片（實測一段 11 小時 32 分的停留 → 下游只看到 11 分）。
// 契約 §2.2 不變：下游只吃「面」→ 這裡濾掉 photo_import 個別點。
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
  const { data, error } = await sb.rpc("stays_for_day", { p_user: uid, p_day: day, p_tz: TZ });
  if (error) return err("server_error", "stay detection failed", 500);

  const stays = [];
  for (const s of (data ?? [])) {
    if (s.source === "photo_import") continue;   // 契約 §2.2：下游只吃「面」、不含匯入的個別點
    // name 已由 stays_for_day 解過（alias > geocode_cache）；只有兩者皆無才打外部 geocode。
    const name = (s.name as string | null) ?? (await reverseGeocode(s.centroid_lat, s.centroid_lng));
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
