#!/usr/bin/env bash
# Points a hostname at the relay domain e4mc assigned to this shift.
#
# e4mc requests a fresh domain every session (request_domain_assignment ->
# domain_assignment_complete), so the target changes on every runner handoff.
# This is the DDNS half of that: rewrite the CNAME each boot.
#
# Usage: dns-update.sh <fqdn> <target> [port]
#   dns-update.sh minecraft.mtrdrgzcid.com abc.gl.at.ply.gg 41234
#
# The port matters: playit's free tier assigns a random one, and the SRV record
# is what lets players type a bare domain instead of host:port.
#
# Requires CF_API_TOKEN (Zone.DNS:Edit) and CF_ZONE_ID.
set -Eeuo pipefail

FQDN="${1:?usage: dns-update.sh <fqdn> <target> [port]}"
TARGET="${2:?usage: dns-update.sh <fqdn> <target> [port]}"
PORT="${3:-25565}"

: "${CF_API_TOKEN:?CF_API_TOKEN is not set}"
: "${CF_ZONE_ID:?CF_ZONE_ID is not set}"

API="https://api.cloudflare.com/client/v4"
# Low TTL because this record is rewritten every ~5.4h at handoff; anything
# higher and players keep resolving the previous shift's dead relay.
TTL="${DNS_TTL:-60}"

log() { printf '\033[36m[dns]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[dns] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

cf() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS -X "$method" -H "Authorization: Bearer $CF_API_TOKEN"
              -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  curl "${args[@]}" "$API$path"
}

# An SRV record is mandatory here, not a nicety. e4mc's relay is a virtual host:
# it routes on the hostname inside the Minecraft handshake, not on IP or port.
# A plain CNAME therefore CANNOT work — the vanilla client puts whatever the
# player typed in the handshake, the relay does not recognise it, and answers
# "Unknown server. Check address and try again."
#
# With an SRV record the client connects to the SRV *target* and sends that
# target hostname in the handshake, which is exactly what the relay expects.
# The CNAME is still written so the name resolves for anything that ignores SRV.
SRV_NAME="_minecraft._tcp.${FQDN}"

upsert() {
  local type="$1" name="$2" body="$3" desc="$4"
  local existing record_id current

  existing="$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=$type&name=$name")" \
    || die "Cloudflare API unreachable or token rejected"

  record_id="$(printf '%s' "$existing" | python3 -c \
    'import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0]["id"] if r else "")')"
  # Compare target *and* port. Comparing only the target would silently skip the
  # update when a relay keeps its hostname but moves to a different port.
  local want
  if [[ "$type" == "SRV" ]]; then
    # No f-string and no escaped quotes here: this snippet lives inside a
    # single-quoted bash string, so a backslash reaches Python literally and a
    # backslash inside an f-string expression is a SyntaxError. That silently
    # broke every SRV update.
    current="$(printf '%s' "$existing" | python3 -c \
      'import json,sys
r = json.load(sys.stdin).get("result") or []
if r:
    d = r[0].get("data") or {}
    print(str(d.get("target","")) + ":" + str(d.get("port","")))
else:
    print("")')"
    want="$TARGET:$PORT"
  else
    current="$(printf '%s' "$existing" | python3 -c \
      'import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0].get("content","") if r else "")')"
    want="$TARGET"
  fi

  if [[ -n "$record_id" && "$current" == "$want" ]]; then
    log "$type $name already points at $want"
    return 0
  fi

  local out
  if [[ -n "$record_id" ]]; then
    log "updating $type $name: ${current:-<none>} -> $want"
    out="$(cf PUT "/zones/$CF_ZONE_ID/dns_records/$record_id" "$body")" \
      || die "failed to update $type $name"
  else
    log "creating $type $name -> $TARGET"
    out="$(cf POST "/zones/$CF_ZONE_ID/dns_records" "$body")" \
      || die "failed to create $type $name"
  fi

  local ok
  ok="$(printf '%s' "$out" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("success"))')"
  [[ "$ok" == "True" ]] || die "Cloudflare rejected the $type change: $out"
  log "$desc"
}

srv_body() {
  python3 - "$SRV_NAME" "$FQDN" "$TARGET" "$TTL" "$PORT" <<'PY'
import json, sys
name, host, target, ttl, port = sys.argv[1:6]
print(json.dumps({
    "type": "SRV",
    "name": name,
    "ttl": int(ttl),
    "data": {
        "service": "_minecraft", "proto": "_tcp", "name": host,
        "priority": 0, "weight": 0, "port": int(port), "target": target,
    },
}))
PY
}

# Must stay unproxied: Cloudflare's proxy carries HTTP/HTTPS only, and Minecraft
# is raw TCP. Proxying silently breaks every connection.
cname_body() {
  printf '{"type":"CNAME","name":"%s","content":"%s","ttl":%s,"proxied":false}' \
    "$FQDN" "$TARGET" "$TTL"
}

upsert SRV   "$SRV_NAME" "$(srv_body)"   "SRV $SRV_NAME -> $TARGET:$PORT (TTL ${TTL}s)"
upsert CNAME "$FQDN"     "$(cname_body)" "CNAME $FQDN -> $TARGET (TTL ${TTL}s, unproxied)"
