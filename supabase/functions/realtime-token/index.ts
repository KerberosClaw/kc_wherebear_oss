// kc_wherebear — 事件通道換發口（D13）
//
// x-wb-key（自家發明的 api key，只有這裡認得）→ resolve_api_key → 簽一張 Realtime 認得的短效 token。
//
// 為什麼要換發：Realtime 是平台服務、只認 JWT，不知道 wb_ key 是什麼。這支就是那道翻譯。
//
// 🔴 簽出來的 token 刻意「一無所有」：
//   role=anon —— 該角色在 public schema 沒有任何表權限（實測打 visits / landmarks /
//   location_history / current_location 全數 permission denied）。身分靠自訂 claim wb_uid，
//   由 realtime.messages 的 RLS policy 綁 topic。公開的 anon key 沒有這個 claim → 對不上任何 topic。
//   → 消費端拿到的東西只能做一件事：聽自己的事件。
//
// 順便回 topic：listener 因此完全不需要知道自己的 user_id，少一個要傳的東西。
import { resolveKey } from "../_shared/auth.ts";
import { json, err } from "../_shared/respond.ts";
import { cors } from "../_shared/cors.ts";

const TTL_S = Number(Deno.env.get("WB_REALTIME_TOKEN_TTL_S") ?? "1800"); // 預設 30 分；listener 到期前自行重換

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlStr = (s: string) => b64url(new TextEncoder().encode(s));

// 手刻 HS256：只為了簽一個固定形狀的小 payload，不值得為此拉一個第三方 JWT 套件進安全路徑。
async function signHS256(payload: Record<string, unknown>, secret: string): Promise<string> {
  const signing = `${b64urlStr(JSON.stringify({ alg: "HS256", typ: "JWT" }))}.${b64urlStr(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signing));
  return `${signing}.${b64url(new Uint8Array(sig))}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const secret = Deno.env.get("WB_JWT_SECRET");
  if (!secret) {
    // 設定沒做完就大聲壞掉，別默默發出一張沒人認得的 token
    return err("server_error", "token signing not configured", 500);
  }

  const uid = await resolveKey(req);
  if (!uid) return err("unauthenticated", "invalid or missing API key", 401);

  const now = Math.floor(Date.now() / 1000);
  const token = await signHS256({
    role: "anon",          // 權限等級：一無所有
    wb_uid: uid,           // 身分標籤：realtime.messages 的 policy 靠它綁 topic
    aud: "authenticated",
    iat: now,
    exp: now + TTL_S,
  }, secret);

  return json({
    token,
    topic: `wb:events:${uid}`,
    expires_at: new Date((now + TTL_S) * 1000).toISOString(),
    ttl_s: TTL_S,
  });
});
