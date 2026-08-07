#!/usr/bin/env python3
"""Read-only listing of the zone's DNS records and Worker routes.

Kept as a file rather than inline YAML because quoting a Python program that
itself contains quotes inside a shell heredoc inside YAML is how the previous
attempt broke.
"""
import json
import os
import sys
import urllib.error
import urllib.request

TOKEN = os.environ["CF_API_TOKEN"]
ZONE = os.environ["CF_ZONE_ID"]
API = "https://api.cloudflare.com/client/v4"


def get(path: str) -> dict:
    req = urllib.request.Request(
        API + path,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode())


def main() -> int:
    print("===== DNS RECORDS =====")
    d = get(f"/zones/{ZONE}/dns_records?per_page=200")
    if not d.get("success"):
        print("ERROR:", d.get("errors"))
        return 1

    rows = sorted(d["result"], key=lambda r: (r["name"], r["type"]))
    print(f"{'TYPE':<7} {'NAME':<42} {'PROXY':<6} CONTENT")
    print("-" * 100)
    for r in rows:
        proxy = "ON" if r.get("proxied") else "-"
        content = r.get("content", "")
        if r["type"] == "SRV":
            dd = r.get("data") or {}
            content = f"{dd.get('target', '')}:{dd.get('port', '')}"
        print(f"{r['type']:<7} {r['name']:<42} {proxy:<6} {content}")
    print(f"\ntotal records: {len(rows)}")

    print("\n===== WORKER ROUTES ON THIS ZONE =====")
    w = get(f"/zones/{ZONE}/workers/routes")
    if not w.get("success"):
        print("(cannot list routes with this token):",
              [e.get("message") for e in (w.get("errors") or [])])
    else:
        routes = w.get("result") or []
        for r in routes:
            print(f"  {r.get('pattern'):<45} -> {r.get('script') or '(none)'}")
        if not routes:
            print("  (none)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
