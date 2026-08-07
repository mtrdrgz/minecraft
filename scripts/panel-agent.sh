#!/usr/bin/env bash
# Publishes server status to the web panel and executes commands it queues.
#
# The runner accepts no inbound connections, so the panel cannot push anything
# to it. This polls instead: status goes up on a slow cadence, the command queue
# is drained on a fast one, and results are posted back by id.
#
# Runs as a background loop for the whole shift. Everything is best-effort — a
# failure here must never take the game server down, so no exit is fatal.
set -uo pipefail

PANEL_HOST="${PANEL_HOST:?PANEL_HOST must be set}"
: "${MAP_UPDATE_TOKEN:?MAP_UPDATE_TOKEN must be set}"
: "${RCON_PASSWORD:?RCON_PASSWORD must be set}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SHIFT_END_EPOCH="${SHIFT_END_EPOCH:-0}"
PUBLIC_ADDRESS="${PUBLIC_ADDRESS:-}"
STATUS_EVERY="${STATUS_EVERY:-30}"
POLL_EVERY="${POLL_EVERY:-5}"

RCON="python3 $REPO_ROOT/tools/rcon.py"
log() { printf '\033[36m[panel]\033[0m %s\n' "$*"; }

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --max-time 20 -X "$method"
              -H "Authorization: Bearer $MAP_UPDATE_TOKEN")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  curl "${args[@]}" "https://${PANEL_HOST}${path}" 2>/dev/null
}

# `list` answers e.g. "There are 2 of a max of 20 players online: Mt2300, foo"
publish_status() {
  local out online max names ok
  out="$($RCON "list" 2>/dev/null)" && ok=1 || ok=0

  if [[ "$ok" == 1 && "$out" =~ ([0-9]+)[[:space:]]+of[[:space:]]+a[[:space:]]+max[[:space:]]+of[[:space:]]+([0-9]+) ]]; then
    online="${BASH_REMATCH[1]}"; max="${BASH_REMATCH[2]}"
    names="$(printf '%s' "$out" | sed -n 's/.*online:[[:space:]]*//p')"
  else
    online=0; max=0; names=""
  fi

  local now_ms ends_ms last_save
  now_ms=$(( $(date +%s) * 1000 ))
  ends_ms=$(( SHIFT_END_EPOCH > 0 ? (SHIFT_END_EPOCH - $(date +%s)) * 1000 : 0 ))
  (( ends_ms < 0 )) && ends_ms=0
  last_save="${LAST_SAVE_MS:-$now_ms}"

  local body
  body="$(ONLINE="$online" MAXP="$max" NAMES="$names" OK="$ok" \
          ENDS="$ends_ms" LASTSAVE="$last_save" ADDR="$PUBLIC_ADDRESS" python3 -c '
import json, os
names = [n.strip() for n in os.environ["NAMES"].split(",") if n.strip()]
print(json.dumps({
    "online": os.environ["OK"] == "1",
    "players_online": int(os.environ["ONLINE"]),
    "players_max": int(os.environ["MAXP"]),
    "players": names,
    "shift_ends_in_ms": int(os.environ["ENDS"]),
    "last_save_at": int(os.environ["LASTSAVE"]),
    "public_address": os.environ["ADDR"],
}))')"

  api POST /__status "$body" >/dev/null
}

drain_commands() {
  local queue
  queue="$(api GET /__commands)" || return 0
  [[ -z "$queue" || "$queue" == "[]" ]] && return 0

  # Each entry is executed once: the endpoint clears the queue as it hands it
  # over, so a crash here loses the command rather than repeating it — the safer
  # failure for something that can run `ban` or `op`.
  local n
  n="$(printf '%s' "$queue" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"
  (( n == 0 )) && return 0

  log "$n command(s) queued"
  local i
  for (( i = 0; i < n; i++ )); do
    local id cmd out
    id="$(printf '%s' "$queue" | IDX="$i" python3 -c 'import json,os,sys
print(json.load(sys.stdin)[int(os.environ["IDX"])]["id"])')"
    cmd="$(printf '%s' "$queue" | IDX="$i" python3 -c 'import json,os,sys
print(json.load(sys.stdin)[int(os.environ["IDX"])]["command"])')"

    log "running: $cmd"
    out="$($RCON "$cmd" 2>&1)" || out="${out:-(the command produced no output)}"
    [[ -z "$out" ]] && out="(no output)"

    local payload
    payload="$(ID="$id" OUT="$out" python3 -c '
import json, os
print(json.dumps({"id": os.environ["ID"], "output": os.environ["OUT"]}))')"
    api POST /__result "$payload" >/dev/null
  done
}

log "panel agent started (status every ${STATUS_EVERY}s, commands every ${POLL_EVERY}s)"
last_status=0
while true; do
  now=$(date +%s)
  if (( now - last_status >= STATUS_EVERY )); then
    last_status=$now
    publish_status
  fi
  drain_commands
  sleep "$POLL_EVERY"
done
