#!/usr/bin/env python3
"""Discover this agent's public playit address from the playit API.

Removes the need to copy the endpoint out of the dashboard into a repo variable,
where it would silently rot if the tunnel were ever recreated. The runner has
PLAYIT_SECRET, so it can ask playit directly.

  POST https://api.playit.gg/agents/rundata
  Authorization: Agent-Key <secret>

Prints "host:port" on success. With --json, dumps the tunnel list for debugging.
Exit 1 if the agent has no usable tunnel, with a message saying how to make one.
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.playit.gg"
SECRET = os.environ.get("PLAYIT_SECRET", "").strip()


def rundata() -> dict:
    req = urllib.request.Request(
        API + "/agents/rundata",
        data=b"{}",
        headers={
            "Content-Type": "application/json",
            # Format taken from PlayitApi::create in packages/api_client/src/lib.rs
            "Authorization": f"Agent-Key {SECRET}",
            "User-Agent": "mtrdrgzcid/minecraft-actions",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise SystemExit(f"playit API returned {e.code}: {body}")


def main() -> int:
    if not SECRET:
        print("PLAYIT_SECRET is not set", file=sys.stderr)
        return 1

    resp = rundata()
    data = resp.get("data") or {}
    tunnels = data.get("tunnels") or []
    pending = data.get("pending") or []

    if "--json" in sys.argv:
        print(json.dumps({"tunnels": tunnels, "pending": pending}, indent=2))

    if not tunnels:
        print("this agent has no tunnels yet.", file=sys.stderr)
        if pending:
            print(f"{len(pending)} pending tunnel(s) — approve them in the dashboard.",
                  file=sys.stderr)
        print("Create one at https://playit.gg/account/agents : type Minecraft Java, "
              "local address 127.0.0.1:25565", file=sys.stderr)
        return 1

    # Prefer a TCP tunnel already pointed at the Minecraft port; otherwise take
    # the first TCP tunnel rather than failing, so a differently-named tunnel
    # still works.
    def score(t):
        return (t.get("local_port") == 25565, (t.get("proto") or "") in ("tcp", "both"))

    usable = [t for t in tunnels if not t.get("disabled")]
    if not usable:
        print("all tunnels on this agent are disabled", file=sys.stderr)
        return 1
    best = sorted(usable, key=score, reverse=True)[0]

    host = best.get("custom_domain") or best.get("assigned_domain")
    port = (best.get("port") or {}).get("from")
    if not host or not port:
        print(f"tunnel is missing an address: {best}", file=sys.stderr)
        return 1

    print(f"{host}:{port}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
