#!/usr/bin/env bash
# Tells the map Worker which quick tunnel is currently live.
#
# Replaces the Origin Rule approach, which cannot work on a Free zone: Cloudflare
# rejects host_header overrides with "not entitled to use the HostHeader
# override". The Worker does the Host rewrite instead, and this is how it learns
# where to point.
#
# Nothing here touches DNS. map.mtrdrgzcid.com resolves to a proxied placeholder
# that never changes, the Worker intercepts on a route, and only a KV value
# moves — so no resolver or browser can cache a dead address.
#
# Usage: map-publish.sh <worker-host> <tunnel-host>
set -Eeuo pipefail

WORKER_HOST="${1:?usage: map-publish.sh <worker-host> <tunnel-host>}"
TUNNEL_HOST="${2:?usage: map-publish.sh <worker-host> <tunnel-host>}"
: "${MAP_UPDATE_TOKEN:?MAP_UPDATE_TOKEN is not set}"

log() { printf '\033[95m[map]\033[0m %s\n' "$*" >&2; }

# The tunnel has just come up; give the Worker a few tries in case of a blip.
for attempt in 1 2 3 4 5; do
  code="$(curl -sS -o /tmp/map-publish.out -w '%{http_code}' --max-time 20 \
    -X POST \
    -H "Authorization: Bearer $MAP_UPDATE_TOKEN" \
    "https://${WORKER_HOST}/__set?host=${TUNNEL_HOST}" || echo 000)"

  if [[ "$code" == "200" ]]; then
    log "published: $WORKER_HOST -> $TUNNEL_HOST"
    exit 0
  fi
  log "attempt $attempt failed (HTTP $code): $(head -c 200 /tmp/map-publish.out 2>/dev/null)"
  sleep 5
done

log "could not publish the tunnel address; the map will keep serving the previous one"
exit 1
