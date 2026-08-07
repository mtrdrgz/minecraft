#!/usr/bin/env bash
# Points map.mtrdrgzcid.com at the current quick-tunnel URL, without touching DNS.
#
# The problem: a trycloudflare quick tunnel gets a brand new hostname every time
# it starts, and this server restarts every ~5.4 hours. Rewriting DNS each shift
# would mean propagation delays and stale client caches on every handoff — the
# exact failure that made e4mc unusable for the Minecraft port.
#
# The fix: DNS never changes. map.mtrdrgzcid.com is a *proxied* record pointing
# at a placeholder address, set once. What changes each shift is a Cloudflare
# Origin Rule, which rewrites where Cloudflare forwards the request:
#
#   client ──TLS(map.mtrdrgzcid.com)──> Cloudflare ──> <current>.trycloudflare.com
#
# Because the change happens inside Cloudflare rather than in DNS, it takes
# effect immediately and no resolver or browser ever caches a dead value.
#
# Requires CF_API_TOKEN with BOTH:
#   Zone > DNS > Edit           (the one-time placeholder record)
#   Zone > Origin Rules > Edit  (the per-shift rewrite)
#
# Usage: map-origin.sh <fqdn> <tunnel-host>
set -Eeuo pipefail

FQDN="${1:?usage: map-origin.sh <fqdn> <tunnel-host>}"
TARGET="${2:?usage: map-origin.sh <fqdn> <tunnel-host>}"

: "${CF_API_TOKEN:?CF_API_TOKEN is not set}"
: "${CF_ZONE_ID:?CF_ZONE_ID is not set}"

API="https://api.cloudflare.com/client/v4"
PHASE="http_request_origin"
RULE_REF="minecraft_map_tunnel"

# TEST-NET-1 (RFC 5737), guaranteed never routable. Nothing ever connects here:
# the record exists only so the hostname is proxied by Cloudflare, and the
# Origin Rule replaces the destination before any origin connection is made.
PLACEHOLDER_IP="192.0.2.1"

# Logs go to stderr, not stdout: several functions here return their value via
# stdout (ruleset_id, the python helpers), and a log line written to stdout gets
# captured into the value. That produced a ruleset id with a log message glued
# to it and a nonsensical API URL.
log() { printf '\033[95m[map-dns]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[map-dns] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# No -f: it makes curl discard the response body on an HTTP error, which is
# exactly where Cloudflare explains what it rejected. Success is judged from the
# JSON envelope instead, and the body is available to the caller either way.
cf() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" -H "Authorization: Bearer $CF_API_TOKEN"
              -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  curl "${args[@]}" "$API$path"
}

cf_ok() {
  python3 -c 'import json,sys
try:
    print("yes" if json.load(sys.stdin).get("success") else "no")
except Exception:
    print("no")'
}

cf_errors() {
  python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unparseable response"); raise SystemExit
for e in (d.get("errors") or []):
    print("  code %s: %s" % (e.get("code"), e.get("message")))
    for s in (e.get("error_chain") or []):
        print("    -> %s: %s" % (s.get("code"), s.get("message")))'
}

jqp() { python3 -c "$1"; }

# ------------------------------------------------ one-time placeholder record --
ensure_record() {
  local existing id proxied
  existing="$(cf GET "/zones/$CF_ZONE_ID/dns_records?name=$FQDN")" \
    || die "Cloudflare API unreachable or token rejected (needs DNS:Edit)"

  id="$(printf '%s' "$existing" | jqp 'import json,sys
r = json.load(sys.stdin).get("result") or []
print(r[0]["id"] if r else "")')"
  proxied="$(printf '%s' "$existing" | jqp 'import json,sys
r = json.load(sys.stdin).get("result") or []
print(str(r[0].get("proxied", False)).lower() if r else "")')"

  local body
  body="$(printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":true}' \
    "$FQDN" "$PLACEHOLDER_IP")"

  if [[ -z "$id" ]]; then
    log "creating proxied placeholder $FQDN -> $PLACEHOLDER_IP"
    cf POST "/zones/$CF_ZONE_ID/dns_records" "$body" >/dev/null \
      || die "could not create the placeholder record"
  elif [[ "$proxied" != "true" ]]; then
    # Unproxied would send the visitor straight to 192.0.2.1 and hang forever.
    log "record exists but is NOT proxied — fixing (it must be orange-clouded)"
    cf PUT "/zones/$CF_ZONE_ID/dns_records/$id" "$body" >/dev/null \
      || die "could not fix the placeholder record"
  else
    log "placeholder record already in place"
  fi
}

# ------------------------------------------------------------- origin rule ----
ruleset_id() {
  local out
  out="$(cf GET "/zones/$CF_ZONE_ID/rulesets/phases/$PHASE/entrypoint" 2>/dev/null)"
  if [[ "$(printf '%s' "$out" | cf_ok)" == "yes" ]]; then
    printf '%s' "$out" | jqp 'import json,sys
print((json.load(sys.stdin).get("result") or {}).get("id",""))'
    return 0
  fi
  # The phase entrypoint does not exist until the zone has its first origin rule.
  log "creating the $PHASE ruleset (first origin rule on this zone)"
  cf POST "/zones/$CF_ZONE_ID/rulesets" \
    "$(printf '{"name":"minecraft map origin","kind":"zone","phase":"%s","rules":[]}' "$PHASE")" \
    | jqp 'import json,sys
print((json.load(sys.stdin).get("result") or {}).get("id",""))'
}

update_rule() {
  local rsid="$1"
  # The whole rule list is replaced, so any rule we did not create would be lost.
  # Read what is there and keep everything except our own.
  local current others
  current="$(cf GET "/zones/$CF_ZONE_ID/rulesets/$rsid")" \
    || die "cannot read ruleset $rsid (token needs Origin Rules:Edit)"

  others="$(printf '%s' "$current" | RULE_REF="$RULE_REF" jqp 'import json,os,sys
rules = ((json.load(sys.stdin).get("result") or {}).get("rules") or [])
ref = os.environ["RULE_REF"]
keep = [r for r in rules if r.get("ref") != ref and ref not in (r.get("description") or "")]
for r in keep:
    r.pop("id", None); r.pop("version", None); r.pop("last_updated", None); r.pop("ref", None)
print(json.dumps(keep))')"

  # Heredoc rather than python3 -c: the rule expression needs both quote styles,
  # and single quotes cannot be nested inside a single-quoted bash string.
  local body
  body="$(TARGET="$TARGET" FQDN="$FQDN" RULE_REF="$RULE_REF" OTHERS="$others" python3 <<'PY'
import json, os
others = json.loads(os.environ["OTHERS"])
target = os.environ["TARGET"]
fqdn = os.environ["FQDN"]
ref = os.environ["RULE_REF"]
mine = {
    "ref": ref,
    "description": ref + ": route the map hostname to the current quick tunnel",
    "expression": '(http.host eq "%s")' % fqdn,
    "action": "route",
    "action_parameters": {
        # host_header must match origin.host: trycloudflare vhosts on it and
        # answers 403 to anything else.
        "host_header": target,
        "origin": {"host": target},
    },
    "enabled": True,
}
print(json.dumps({"rules": others + [mine]}))
PY
)"

  local resp
  resp="$(cf PUT "/zones/$CF_ZONE_ID/rulesets/$rsid" "$body")"
  if [[ "$(printf '%s' "$resp" | cf_ok)" != "yes" ]]; then
    log "Cloudflare rejected the origin rule:"
    printf '%s' "$resp" | cf_errors >&2
    log "rule sent was:"
    printf '%s\n' "$body" | head -c 1200 >&2
    die "origin rule update failed"
  fi

  local kept
  kept="$(printf '%s' "$others" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  log "$FQDN now routes to $TARGET ($kept other origin rule(s) preserved)"
}

ensure_record
RSID="$(ruleset_id)"
[[ -n "$RSID" ]] || die "could not resolve the $PHASE ruleset id"
update_rule "$RSID"
log "done — DNS untouched, only the origin rule changed"

# ---------------------------------------------------------------------------
# DEAD END, recorded so nobody retries it:
#
# This script cannot work on a Free zone. Cloudflare rejects the rule with
#     "not entitled to use the HostHeader override"
# because host_header in Origin Rules is a paid feature. And without rewriting
# the Host, trycloudflare answers 403 — measured directly: the correct host
# returns 200, map.mtrdrgzcid.com and example.com both return 403.
#
# Remaining ways to serve the map on a stable hostname:
#   1. Cloudflare Worker proxying map.mtrdrgzcid.com to the current tunnel,
#      reading the hostname from KV. Free, but needs Workers deploy access.
#   2. Zero Trust named tunnel. Needs a card on file; in exchange the tunnel
#      hostname is fixed, so nothing rotates and DNS is set once.
#   3. A second playit tunnel to port 8100. No card, stable endpoint, but the
#      URL carries a port and is plain HTTP.
# ---------------------------------------------------------------------------
