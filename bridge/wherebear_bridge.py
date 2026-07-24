#!/usr/bin/env python3
"""kc_wherebear bridge daemon (spec 05).

Pull the read-plane endpoints (last-location + today-stays) and write a single
atomic local JSON snapshot (API_CONTRACT §6) for downstream consumers.

Invariant (DESIGN D9 / R4): network only happens here; downstream reads the local
file only. Fetch failure degrades to current=null (never stale-as-now, never crash).

Config via env (see .env.example). stdlib only.
"""
import json
import os
import sys
import time
import tempfile
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta

SCHEMA_VERSION = 1


def _env(key, default=None, required=False):
    val = os.environ.get(key, default)
    if required and not val:
        sys.exit(f"[bridge] missing required env: {key}")
    return val


def _now_iso():
    # offset-aware timestamp (Taipei); downstream uses it for freshness
    return datetime.now(timezone(timedelta(hours=8))).isoformat(timespec="seconds")


def _get(base, path, api_key, gateway_apikey):
    req = urllib.request.Request(base + path)
    req.add_header("x-wb-key", api_key)
    if gateway_apikey:  # cloud/prod gateway; empty on local functions serve
        req.add_header("apikey", gateway_apikey)
        req.add_header("Authorization", "Bearer " + gateway_apikey)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def build_snapshot(base, api_key, gateway_apikey):
    current = None
    today = None
    try:
        last = _get(base, "/last-location", api_key, gateway_apikey)
        if last.get("lat") is not None:
            current = {
                "lat": last["lat"],
                "lng": last["lng"],
                "accuracy": last["accuracy"],
                "captured_at": last["captured_at"],
                "resolved_name": last.get("resolved_name"),
            }
    except Exception as e:  # noqa: BLE001 — degrade, never crash the loop
        print(f"[bridge] last-location fetch failed: {e}", file=sys.stderr)
    try:
        today = _get(base, "/today-stays", api_key, gateway_apikey)
    except Exception as e:  # noqa: BLE001
        print(f"[bridge] today-stays fetch failed: {e}", file=sys.stderr)
    return {
        "meta": {"fetched_at": _now_iso(), "schema_version": SCHEMA_VERSION},
        "current": current,  # null on failure/no-data → downstream hedges
        "today": today,
    }


def atomic_write(path, obj):
    abspath = os.path.abspath(path)
    d = os.path.dirname(abspath)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
        os.replace(tmp, abspath)  # atomic rename — downstream never sees a half file
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main():
    base = _env("WHEREBEAR_API_BASE", required=True).rstrip("/")
    api_key = _env("WHEREBEAR_API_KEY", required=True)
    gateway = _env("WHEREBEAR_GATEWAY_APIKEY", "")
    out = _env("WHEREBEAR_OUTPUT_PATH", "./bridge/out/wherebear_location.json")
    poll = int(_env("WHEREBEAR_POLL_SECONDS", "300"))
    once = "--once" in sys.argv

    while True:
        snap = build_snapshot(base, api_key, gateway)
        atomic_write(out, snap)
        print(f"[bridge] wrote {out} (current={'yes' if snap['current'] else 'null'})")
        if once:
            break
        time.sleep(poll)


if __name__ == "__main__":
    main()
