// kc_wherebear — server-side reverse geocode (spec 03 / DESIGN D6)
// Nominatim (OpenStreetMap) — no API key, keep volume low + set a User-Agent.
// Returns a concise human label, or null on any failure (network/rate-limit/parse).
// The read plane calls this only when no landmark alias matches (alias > geocode > null).

export async function reverseGeocode(lat: number, lng: number): Promise<string | null> {
  try {
    const url =
      `https://nominatim.openstreetmap.org/reverse?format=jsonv2` +
      `&lat=${lat}&lon=${lng}&zoom=16&accept-language=zh-TW`;
    const res = await fetch(url, {
      headers: { "User-Agent": "kc_wherebear/0.1 (personal location app)" },
    });
    if (!res.ok) return null;
    const j = await res.json();
    const a = j.address ?? {};
    // Road-level label "<road> · <district>" (API_CONTRACT §3). Previously picked only
    // 里/neighbourhood + city → too coarse; the road name is already in the response.
    // Degrade gracefully to area-only when no road is present (rural/park points).
    const road = a.road || a.pedestrian || a.footway || a.neighbourhood || a.suburb;
    const area = a.suburb || a.city_district || a.district || a.town || a.city || a.county;
    const parts = [...new Set([road, area].filter(Boolean))];
    if (parts.length) return parts.join(" · ");
    if (typeof j.name === "string" && j.name) return j.name;
    if (typeof j.display_name === "string") {
      return j.display_name.split(",").slice(0, 2).join(",").trim();
    }
    return null;
  } catch (_e) {
    return null;
  }
}
