// kc_wherebear — owner-plane reverse geocode (app timeline / current-location naming)
// 由 app（owner JWT）呼叫：{lat,lng} → {name}。重用讀取層同一支 Nominatim 模組 → 地名來源全 app 一致。
// 快取：同座標（四捨五入 ~11m）查過就存 geocode_cache，之後直接回快取、不再打 Nominatim（省後端資源）。
// alias（使用者地標）已在 app 平面 my_today_stays / my_resolve_alias 先解，這裡只補「通用地名」。
// JWT 由 Supabase 平台驗（線上預設 verify_jwt；dev 可 --no-verify-jwt 方便測）。
import { serviceClient } from "../_shared/client.ts";
import { json, err } from "../_shared/respond.ts";
import { cors } from "../_shared/cors.ts";
import { reverseGeocode } from "../_shared/geocode.ts";

const round4 = (n: number) => Math.round(n * 1e4) / 1e4;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  let body: unknown;
  try { body = await req.json(); } catch { return err("bad_request", "invalid json", 400); }
  const b = body as { lat?: unknown; lng?: unknown };
  const lat = Number(b?.lat), lng = Number(b?.lng);
  if (!isFinite(lat) || !isFinite(lng)) return err("bad_request", "lat/lng required", 400);

  const latKey = round4(lat), lngKey = round4(lng);
  const sb = serviceClient();

  // 1) 先讀快取（含「查無結果」的 null，避免重打）
  const { data: hit, error: readErr } = await sb
    .from("geocode_cache").select("name")
    .eq("lat_key", latKey).eq("lng_key", lngKey).maybeSingle();
  if (readErr) console.error("cache read error:", JSON.stringify(readErr), "SUPABASE_URL=", Deno.env.get("SUPABASE_URL"));
  if (hit) return json({ name: hit.name });

  // 2) miss → 打 Nominatim，寫回快取（name 可能為 null）
  const name = await reverseGeocode(lat, lng);
  const { error: upErr } = await sb.from("geocode_cache").upsert({ lat_key: latKey, lng_key: lngKey, name });
  if (upErr) console.error("cache upsert error:", JSON.stringify(upErr));
  return json({ name });
});
