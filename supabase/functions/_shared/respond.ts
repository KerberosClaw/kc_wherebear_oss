import { cors } from "./cors.ts";

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "content-type": "application/json" },
  });
}

// API_CONTRACT §5 error shape: { error: { code, message } }
export function err(code: string, message: string, status: number): Response {
  return json({ error: { code, message } }, status);
}
