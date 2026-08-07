#!/usr/bin/env bash
# Points a hostname at the relay domain e4mc assigned to this shift.
#
# e4mc requests a fresh domain every session (request_domain_assignment ->
# domain_assignment_complete), so the target changes on every runner handoff.
# This is the DDNS half of that: rewrite the CNAME each boot.
#
# Usage: dns-update.sh <fqdn> <target>
#   dns-update.sh minecraft.mtrdrgzcid.com abc123.e4mc.link
#
# Requires CF_API_TOKEN (Zone.DNS:Edit) and CF_ZONE_ID.
set -Eeuo pipefail

FQDN="${1:?usage: dns-update.sh <fqdn> <target>}"
TARGET="${2:?usage: dns-update.sh <fqdn> <target>}"

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

# Minecraft is raw TCP, which Cloudflare's proxy cannot carry (public hostnames
# on Tunnel are HTTP/HTTPS only; arbitrary TCP needs Spectrum). The record must
# stay unproxied or clients get an HTTP endpoint and fail to connect.
payload() {
  printf '{"type":"CNAME","name":"%s","content":"%s","ttl":%s,"proxied":false}' \
    "$FQDN" "$TARGET" "$TTL"
}

log "resolving existing record for $FQDN"
existing="$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$FQDN")" \
  || die "Cloudflare API unreachable or token rejected"

record_id="$(printf '%s' "$existing" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0]["id"] if r else "")')"
current="$(printf '%s' "$existing" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0]["content"] if r else "")')"

if [[ -n "$record_id" && "$current" == "$TARGET" ]]; then
  log "$FQDN already points at $TARGET — nothing to do"
  exit 0
fi

if [[ -n "$record_id" ]]; then
  log "updating $FQDN: $current -> $TARGET"
  out="$(cf PUT "/zones/$CF_ZONE_ID/dns_records/$record_id" "$(payload)")" \
    || die "failed to update record $record_id"
else
  log "creating $FQDN -> $TARGET"
  out="$(cf POST "/zones/$CF_ZONE_ID/dns_records" "$(payload)")" \
    || die "failed to create record"
fi

ok="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("success"))')"
[[ "$ok" == "True" ]] || die "Cloudflare rejected the change: $out"

log "$FQDN -> $TARGET (TTL ${TTL}s, unproxied)"
