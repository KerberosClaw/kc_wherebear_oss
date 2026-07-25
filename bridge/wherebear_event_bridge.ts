#!/usr/bin/env -S deno run --allow-net --allow-read --allow-write --allow-env --allow-run
/**
 * kc_wherebear — event bridge（D13 的常駐半邊）
 *
 * 角色跟隔壁的 wherebear_bridge.py 一樣：**唯一碰網路、唯一持金鑰的那一格**。差別只在
 * 它不輪詢、改成掛著一條長連線聽事件。下游照舊只讀本地檔、永不打網路。
 *
 * 流程：wb_ key ──換發──► 短效 token ──► 訂閱 wb:events:<uid> ──► 寫每日 jsonl ──► 叫下游
 *
 * ── 為什麼是 Deno 而不是 Python（跟隔壁那支不同語言，值得交代）──────────────
 *   Realtime 走 Phoenix channel 協定，Python 標準函式庫沒有 WebSocket、也沒有 Phoenix。
 *   選項是「自己刻協定」「引 Python 套件」或「用官方 JS 客戶端」。選最後者因為：
 *     1. 這條路徑已經實測跑通（含私有頻道授權、斷線重連、setAuth 換 token）
 *     2. Deno 的相依寫在 import 那一行、首次執行自動快取 → **更新照舊只是 scp 一個檔**，
 *        不用在常駐機開 venv、不用管 pip
 *     3. 這個 repo 本來就有 Deno（Edge Functions），不是引進新生態
 *
 * ── 安全 ────────────────────────────────────────────────────────────────────
 *   叫下游時用 clearEnv 起乾淨環境：下游處理程式是「永不持金鑰」的一側，而子行程預設會繼承
 *   整份環境變數（含 WHEREBEAR_API_KEY）。這裡不給，下游那側還會自己再斷言一次。
 */

const ENV = (k: string, d = "") => Deno.env.get(k) ?? d;
const NUM = (k: string, d: number) => {
  const v = Number(Deno.env.get(k));
  return Number.isFinite(v) && v > 0 ? v : d;
};

const API_BASE = ENV("WHEREBEAR_API_BASE").replace(/\/+$/, "");
const API_KEY = ENV("WHEREBEAR_API_KEY");
const GATEWAY = ENV("WHEREBEAR_GATEWAY_APIKEY");            // 讀取口那支的保險，這裡沿用同一份 .env
const EVENT_DIR = ENV("WHEREBEAR_EVENT_DIR", "./bridge/out/events");
const JUDGE = ENV("WHEREBEAR_EVENT_JUDGE");                  // 空 = 只寫檔、不叫下游（先接管線時好用）
const COALESCE_S = NUM("WHEREBEAR_EVENT_COALESCE_S", 120);   // 同地點同類型 N 秒內只算一次
const JUDGE_TIMEOUT_S = NUM("WHEREBEAR_EVENT_JUDGE_TIMEOUT_S", 300);
// 健康告警要怎麼送是**部署環境的事**：給一個可執行檔路徑，收 <emoji> <text> 兩個參數。
// 空＝不送、只寫 log（本 repo 不預設任何特定通知工具）。
const NOTIFY_CMD = ENV("WHEREBEAR_NOTIFY_CMD");
const SCHEMA_VERSION = 1;

if (!API_BASE || !API_KEY) {
  console.error("[event-bridge] 缺 WHEREBEAR_API_BASE / WHEREBEAR_API_KEY");
  Deno.exit(2);
}
// 讀取口是 <project>/functions/v1，Realtime 要的是專案根
const PROJECT_URL = API_BASE.replace(/\/functions\/v1$/, "");

const log = (m: string) => console.log(`[event-bridge] ${new Date().toISOString()} ${m}`);

/** 一天一則的健康告警——蒐料/連線層壞掉不該吵爆，也不該完全沒聲音。 */
const alerted = new Set<string>();
async function notifyOnce(tag: string, text: string) {
  const key = `${taipeiDate()}\t${tag}`;
  if (alerted.has(key)) return;
  alerted.add(key);
  log(`ALERT ${text}`);                     // 不管有沒有外部通知管道，log 一定留一筆
  if (!NOTIFY_CMD) return;
  try {
    await new Deno.Command(NOTIFY_CMD, { args: ["🟡", text] }).output();
  } catch { /* 通知管道自己壞掉不該拖垮 daemon */ }
}

function taipeiDate(d = new Date()): string {
  return new Date(d.getTime() + 8 * 3600 * 1000).toISOString().slice(0, 10).replaceAll("-", "");
}

// ── 換發 ─────────────────────────────────────────────────────────────────────
type Tok = { token: string; topic: string; ttl_s: number };
async function exchange(): Promise<Tok> {
  const headers: Record<string, string> = { "x-wb-key": API_KEY };
  if (GATEWAY) {                       // 讀取口實測不需要，但重新部署漏了 --no-verify-jwt 時它是保險
    headers["apikey"] = GATEWAY;
    headers["Authorization"] = `Bearer ${GATEWAY}`;
  }
  const r = await fetch(`${API_BASE}/realtime-token`, { method: "POST", headers });
  if (!r.ok) throw new Error(`換發失敗 HTTP ${r.status}`);
  const d = await r.json();
  if (!d?.token || !d?.topic) throw new Error("換發回應缺 token/topic");
  return d as Tok;
}

// ── 事件落檔（每日一檔、append、單一寫入者）─────────────────────────────────
async function appendEvent(payload: Record<string, unknown>) {
  await Deno.mkdir(EVENT_DIR, { recursive: true });
  const line = JSON.stringify({
    schema_version: SCHEMA_VERSION,
    received_at: new Date().toISOString(),
    ...payload,
  }) + "\n";
  await Deno.writeTextFile(`${EVENT_DIR}/events_${taipeiDate()}.jsonl`, line, { append: true });
}

// ── 叫下游（白名單環境、序列化執行、有逾時）─────────────────────────────────
/**
 * 下游處理程式的環境用**白名單**組，不是原封不動繼承、也不是全空：
 *   - 全繼承 → `WHEREBEAR_API_KEY` 會跟著過去，違反下游「永不持金鑰」的不變式，而且看不出來
 *   - 全清空 → 下游連自己的設定（模型、工作目錄、狀態路徑…）都拿不到，
 *              會靜靜地用一套錯的預設值跑起來——比壞掉更糟
 * 所以：基本執行環境 ＋ `WHEREBEAR_EVENT_JUDGE_ENV_PREFIXES` 列出的前綴，其餘一律不給。
 *
 * 前綴走設定而不是寫死：那些變數叫什麼是**下游的事**，平台不該知道，也不該因為換了一個
 * 消費者就要改這裡的程式碼。
 */
const PASS_PREFIXES = ENV("WHEREBEAR_EVENT_JUDGE_ENV_PREFIXES")
  .split(",").map((s) => s.trim()).filter(Boolean);

function judgeEnv(): Record<string, string> {
  const env: Record<string, string> = {
    PATH: ENV("PATH"),
    HOME: ENV("HOME"),
    LANG: ENV("LANG", "en_US.UTF-8"),
  };
  if (PASS_PREFIXES.length) {
    for (const [k, v] of Object.entries(Deno.env.toObject())) {
      // 🔴 自家變數永不外流，即使前綴設定寫錯也一樣
      if (k.startsWith("WHEREBEAR_") || k.startsWith("SUPABASE_")) continue;
      if (PASS_PREFIXES.some((p) => k.startsWith(p))) env[k] = v;
    }
  }
  return env;
}

let judging: Promise<void> = Promise.resolve();
function callJudge() {
  if (!JUDGE) return;
  judging = judging.then(async () => {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), JUDGE_TIMEOUT_S * 1000);
    try {
      const out = await new Deno.Command(JUDGE, {
        clearEnv: true,                       // 🔴 金鑰不過繼：下游那側永不持金鑰
        env: judgeEnv(),
        signal: ac.signal,
        stdout: "piped",
        stderr: "piped",
      }).output();
      if (!out.success) {
        log(`下游 exit=${out.code}: ${new TextDecoder().decode(out.stderr).trim().slice(0, 200)}`);
      }
    } catch (e) {
      // 事件已經落檔了，這裡失敗就算了——不重試、不排隊（下一輪輪詢仍會知道人在哪）
      log(`下游呼叫失敗：${e instanceof Error ? e.message : e}`);
    } finally {
      clearTimeout(t);
    }
  });
}

// ── 同地點合併 ───────────────────────────────────────────────────────────────
const lastSeen = new Map<string, number>();
function shouldCoalesce(kind: string, name: string): boolean {
  const k = `${kind}:${name}`;
  const now = Date.now();
  const prev = lastSeen.get(k);
  lastSeen.set(k, now);
  return prev !== undefined && (now - prev) / 1000 < COALESCE_S;
}

// ── 主迴圈：連線 → 聽 → 斷線退避重連；token 到期前重換 ──────────────────────
const { createClient } = await import("npm:@supabase/supabase-js@2");

let backoff = 1;
const BACKOFF_MAX = 300;
let consecutiveFailures = 0;

while (true) {
  let refreshTimer: number | undefined;
  try {
    const tok = await exchange();
    // 🔴 client key 與身分是兩件事，雲端會分得很清楚：
    //   client key = 給閘道看的「這請求是要進哪個專案」→ 雲端**必須**是真的專案 key（anon）。
    //     實測把換發來的 token 當 client key，雲端一律 `CHANNEL_ERROR (transport failure)`；
    //     本機 stack 的閘道比較寬鬆、兩種都收，所以這個差異只有上雲才看得到。
    //   身分 = setAuth() 那張短效 token（wb_uid claim → RLS 綁 topic）。
    // anon key 本來就是公開的（印在每支 app 裡），拿它過閘道不放大任何權限。
    const sb = createClient(PROJECT_URL, GATEWAY || tok.token, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    sb.realtime.setAuth(tok.token);

    // 到期前 60 秒重換並推給連線（不必重連）
    const refreshIn = Math.max(30, tok.ttl_s - 60) * 1000;
    refreshTimer = setTimeout(async function again() {
      try {
        const fresh = await exchange();
        sb.realtime.setAuth(fresh.token);
        log("token 已續期");
        refreshTimer = setTimeout(again, Math.max(30, fresh.ttl_s - 60) * 1000);
      } catch (e) {
        log(`token 續期失敗：${e instanceof Error ? e.message : e}`);
        await notifyOnce("token", "wherebear event bridge：token 續期失敗，連線可能斷掉");
      }
    }, refreshIn);

    const closed = Promise.withResolvers<string>();
    const ch = sb.channel(tok.topic, { config: { private: true } });

    ch.on("broadcast", { event: "visit" }, async (msg: { payload: Record<string, unknown> }) => {
      const p = msg.payload ?? {};
      const kind = String(p.kind ?? "");
      const name = String(p.name ?? "");
      if (!kind || !name) return;
      if (shouldCoalesce(kind, name)) {
        log(`合併掉重複事件 ${kind}/${name}`);
        return;
      }
      log(`事件 ${kind} ${name}`);
      try {
        await appendEvent(p);
        callJudge();
      } catch (e) {
        log(`寫事件檔失敗：${e instanceof Error ? e.message : e}`);
        await notifyOnce("write", "wherebear event bridge：事件檔寫不進去（查磁碟/權限）");
      }
    });

    ch.subscribe((status: string, err?: Error) => {
      if (status === "SUBSCRIBED") {
        log(`已訂閱 ${tok.topic}`);
        backoff = 1;
        consecutiveFailures = 0;
      } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
        closed.resolve(`${status}${err ? ` (${err.message})` : ""}`);
      }
    });

    const why = await closed.promise;
    log(`連線結束：${why}`);
    await sb.removeAllChannels();
  } catch (e) {
    log(`連線失敗：${e instanceof Error ? e.message : e}`);
  } finally {
    if (refreshTimer !== undefined) clearTimeout(refreshTimer);
  }

  // 斷路器：連續失敗到一定次數才吵一次（一天一則），但不停止重試——這一格壞掉不該讓下游陪葬
  if (++consecutiveFailures >= 5) {
    await notifyOnce("conn", `wherebear event bridge：連續 ${consecutiveFailures} 次連不上（仍在重試）`);
  }
  log(`${backoff}s 後重連`);
  await new Promise((r) => setTimeout(r, backoff * 1000));
  backoff = Math.min(BACKOFF_MAX, backoff * 2);
}
