#!/usr/bin/env python3
"""Claim a playit.gg agent and store the secret straight into a GitHub secret.

There is no playit-cli build for Windows, so this reimplements the claim flow
the CLI performs (packages/playit-cli/src/main.rs):

  code  = hex(5 random bytes)
  setup = POST https://api.playit.gg/claim/setup  {code, agent_type, version}
          poll until the response is UserAccepted
  final = POST https://api.playit.gg/claim/exchange {code} -> {secret_key}

The secret is never printed. It is piped directly into `gh secret set`, so it
does not appear in the terminal, in scrollback, or in shell history.

  playit-claim.py url [agent_type]         -> start a claim, print the URL
  playit-claim.py wait <code> <repo> [type] -> wait for approval, store secret

agent_type defaults to "assignable". Do NOT use "self-managed" here: that kind
of agent defines its own tunnels and refuses ones created in the dashboard, so
the New Tunnel page shows "tunnel type not supported" and cannot continue.
The playit CLI defaults to self-managed, which is the wrong default for us.
"""
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.playit.gg"
DEFAULT_AGENT_TYPE = "assignable"
VERSION = "mtrdrgzcid-minecraft-actions"


def call(path: str, body: dict) -> dict:
    req = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "User-Agent": "mtrdrgzcid/minecraft-setup"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode())


def setup(code: str, agent_type: str) -> str:
    r = call("/claim/setup", {"code": code, "agent_type": agent_type, "version": VERSION})
    if r.get("status") == "fail":
        raise SystemExit(f"playit rejected the claim: {r.get('data')}")
    return r.get("data", "")


def cmd_url(agent_type: str) -> int:
    code = secrets.token_hex(5)          # 5 bytes, exactly what the CLI generates
    state = setup(code, agent_type)
    print(f"code={code}")
    print(f"agent_type={agent_type}")
    print(f"state={state}")
    print(f"url=https://playit.gg/claim/{code}")
    return 0


def cmd_wait(code: str, repo: str, agent_type: str) -> int:
    deadline = time.time() + 900
    state = ""
    while time.time() < deadline:
        state = setup(code, agent_type)
        if state == "UserAccepted":
            break
        if state == "UserRejected":
            print("you rejected the claim in the browser", file=sys.stderr)
            return 1
        time.sleep(3)
    else:
        print(f"timed out waiting for approval (last state: {state})", file=sys.stderr)
        return 1

    r = call("/claim/exchange", {"code": code})
    if r.get("status") == "fail":
        print(f"exchange failed: {r.get('data')}", file=sys.stderr)
        return 1
    secret = (r.get("data") or {}).get("secret_key")
    if not secret:
        print(f"no secret in response: {r}", file=sys.stderr)
        return 1

    # Straight into GitHub. The value is never written to stdout or to disk.
    p = subprocess.run(
        ["gh", "secret", "set", "PLAYIT_SECRET", "--repo", repo],
        input=secret, text=True, capture_output=True,
    )
    if p.returncode != 0:
        print(f"gh secret set failed: {p.stderr.strip()}", file=sys.stderr)
        return 1
    print(f"agent claimed; PLAYIT_SECRET stored in {repo} ({len(secret)} chars, not shown)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "url":
        sys.exit(cmd_url(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_AGENT_TYPE))
    if len(sys.argv) >= 4 and sys.argv[1] == "wait":
        sys.exit(cmd_wait(sys.argv[2], sys.argv[3],
                          sys.argv[4] if len(sys.argv) > 4 else DEFAULT_AGENT_TYPE))
    print(__doc__, file=sys.stderr)
    sys.exit(2)
