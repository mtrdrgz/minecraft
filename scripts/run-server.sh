#!/usr/bin/env bash
# Runs one server shift: boot -> serve -> warn -> hand off to a successor.
#
# A GitHub Actions job is killed hard at 6h, so this deliberately stops itself
# well before that, on its own terms, with a clean save. The successor is
# dispatched *before* shutdown so its slow prep overlaps with our last minutes
# of uptime and the visible gap stays small.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$HOME/mcbuild}"
RUN_DIR="${RUN_DIR:-$HOME/mcrun}"
export RUN_DIR

SERVE_MINUTES="${SERVE_MINUTES:-325}"
AUTOSAVE_MINUTES="${AUTOSAVE_MINUTES:-10}"
HANDOFF_LEAD_MINUTES="${HANDOFF_LEAD_MINUTES:-12}"

SERVE_SECONDS=$(( SERVE_MINUTES * 60 ))
AUTOSAVE_SECONDS=$(( AUTOSAVE_MINUTES * 60 ))
HANDOFF_LEAD_SECONDS=$(( HANDOFF_LEAD_MINUTES * 60 ))

export RCON_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)"
RCON="python3 $REPO_ROOT/tools/rcon.py"

log() { printf '\033[32m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[run]\033[0m %s\n' "$*"; }

SERVER_PID=""
PLAYIT_PID=""
DISPATCHED=0
SHUTTING_DOWN=0

# --------------------------------------------------------------- preparing ---
log "preparing run directory"
mkdir -p "$RUN_DIR"
# The build tree is immutable and cacheable; the run dir is the mutable copy.
rsync -a --exclude 'world/' "$BUILD_DIR/" "$RUN_DIR/"

log "restoring world from the '$WORLD_BRANCH' branch"
"$REPO_ROOT/scripts/world.sh" restore

sed -i "s|^rcon.password=.*|rcon.password=${RCON_PASSWORD}|" "$RUN_DIR/server.properties"

# The repo files and the runtime files are both authoritative: edits committed
# to server/*.json must take effect, and /whitelist add or /op done in-game must
# survive a handoff. Union them so neither source is silently discarded.
python3 - "$REPO_ROOT/server" "$RUN_DIR" <<'PY'
import json, os, sys
repo_dir, run_dir = sys.argv[1], sys.argv[2]

def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []

for name in ("whitelist.json", "ops.json"):
    merged, seen = [], set()
    # Repo entries come first so their fields win on conflict.
    for entry in load(os.path.join(repo_dir, name)) + load(os.path.join(run_dir, name)):
        if not isinstance(entry, dict):
            continue
        key = (entry.get("uuid") or entry.get("name") or "").lower()
        if key and key not in seen:
            seen.add(key)
            merged.append(entry)
    with open(os.path.join(run_dir, name), "w", encoding="utf-8") as f:
        json.dump(merged, f, indent=2)
    print(f"{name}: {len(merged)} entries")
PY

# ---------------------------------------------------------------- shutdown ---
graceful_stop() {
  [[ "$SHUTTING_DOWN" == 1 ]] && return 0
  SHUTTING_DOWN=1

  # Kill the tunnel first so nobody joins into a shutting-down server.
  if [[ -n "$PLAYIT_PID" ]] && kill -0 "$PLAYIT_PID" 2>/dev/null; then
    log "closing playit tunnel"
    kill "$PLAYIT_PID" 2>/dev/null || true
  fi

  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    log "stopping server"
    $RCON "say §cServer is restarting now. Reconnect in a few minutes." >/dev/null 2>&1 || true
    $RCON "kick @a Server restarting — reconnect shortly" >/dev/null 2>&1 || true
    $RCON "save-all flush" >/dev/null 2>&1 || true
    sleep 3
    $RCON "stop" >/dev/null 2>&1 || true

    # Give the JVM time to flush chunks before escalating.
    for _ in $(seq 1 120); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
      warn "server did not exit after 120s — sending SIGTERM"
      kill "$SERVER_PID" 2>/dev/null || true
      sleep 15
      kill -9 "$SERVER_PID" 2>/dev/null || true
    fi
  fi

  log "final world save + squash"
  "$REPO_ROOT/scripts/world.sh" squash || warn "final world push FAILED"
}
trap graceful_stop EXIT INT TERM

# ------------------------------------------------------------------- boot ----
log "starting server (serving for ${SERVE_MINUTES}m)"
cd "$RUN_DIR"
./run.sh nogui > "$RUN_DIR/server.log" 2>&1 &
SERVER_PID=$!
tail -f "$RUN_DIR/server.log" &
TAIL_PID=$!

log "waiting for server to accept RCON"
READY=0
for _ in $(seq 1 90); do   # up to ~15 minutes; a cold 120-mod boot is slow
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    warn "server process died during boot — last 60 lines:"
    tail -60 "$RUN_DIR/server.log" >&2
    exit 1
  fi
  if RCON_CONNECT_TIMEOUT=2 $RCON "list" >/dev/null 2>&1; then READY=1; break; fi
  sleep 10
done
[[ "$READY" == 1 ]] || { warn "server never became ready"; tail -60 "$RUN_DIR/server.log" >&2; exit 1; }
log "server is up"

# ------------------------------------------------------------------ tunnel ---
# e4mc opens the tunnel itself: its ServerConnectionListener mixin fires when the
# dedicated server binds its TCP listener, requests a domain from the relay, and
# logs "Domain assigned: <host>". Nothing to start here — only to read.
current_domain() {
  grep -oE 'Domain assigned: [A-Za-z0-9.-]+' "$RUN_DIR/server.log" 2>/dev/null \
    | tail -1 | awk '{print $3}'
}

E4MC_DOMAIN=""
if [[ -z "${PLAYIT_SECRET:-}" ]]; then
  log "waiting for e4mc to be assigned a relay domain"
  for _ in $(seq 1 60); do          # up to ~5 minutes
    E4MC_DOMAIN="$(current_domain)"
    [[ -n "$E4MC_DOMAIN" ]] && break
    sleep 5
  done
fi

update_dns() {
  local target="$1" port="${2:-25565}"
  if [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ZONE_ID:-}" || -z "${DNS_NAME:-}" ]]; then
    warn "CF_API_TOKEN / CF_ZONE_ID / DNS_NAME not all set — skipping DNS update."
    warn "Players must connect to $target:$port directly this shift."
    return 0
  fi
  "$REPO_ROOT/scripts/dns-update.sh" "$DNS_NAME" "$target" "$port" \
    || warn "DNS update FAILED — players must use $target:$port directly this shift"
}

# --- playit: the primary transport ------------------------------------------
# e4mc was measured closing its tunnel after ~5 minutes with no players joined
# (three sessions: ~4m, 5m2s, and 12m+ only while a player was connected). Its
# own source warns it is built for short-lived LAN worlds. playit's endpoint is
# stable and does not expire on idle, so DNS is written once and never churns —
# which also removes the client-side SRV cache problem on every handoff.
PUBLIC_HOST=""
PUBLIC_PORT="25565"

if [[ -n "${PLAYIT_SECRET:-}" && -x "$HOME/bin/playitd" ]]; then
  log "starting playit tunnel"
  "$HOME/bin/playitd" --secret "$PLAYIT_SECRET" > "$RUN_DIR/playit.log" 2>&1 &
  PLAYIT_PID=$!
  sleep 10
  if ! kill -0 "$PLAYIT_PID" 2>/dev/null; then
    warn "playit agent exited immediately — players cannot connect. Log:"
    tail -30 "$RUN_DIR/playit.log" >&2
  else
    # Ask playit for the agent's own endpoint rather than reading it from a repo
    # variable, which would silently rot if the tunnel were ever recreated.
    # PLAYIT_ADDRESS still wins if set, as an escape hatch.
    ADDR="${PLAYIT_ADDRESS:-}"
    if [[ -z "$ADDR" ]]; then
      ADDR="$(python3 "$REPO_ROOT/tools/playit-address.py" 2>"$RUN_DIR/playit-addr.err")" || ADDR=""
    fi

    if [[ -n "$ADDR" ]]; then
      PUBLIC_HOST="${ADDR%%:*}"
      [[ "$ADDR" == *:* ]] && PUBLIC_PORT="${ADDR##*:}"
      log "playit endpoint: $PUBLIC_HOST:$PUBLIC_PORT"
      update_dns "$PUBLIC_HOST" "$PUBLIC_PORT"
    else
      warn "could not determine the playit endpoint:"
      sed 's/^/  /' "$RUN_DIR/playit-addr.err" >&2 2>/dev/null || true
    fi
  fi
elif [[ -n "$E4MC_DOMAIN" ]]; then
  warn "falling back to e4mc — expect the tunnel to close after ~5 idle minutes"
  PUBLIC_HOST="$E4MC_DOMAIN"
  log "e4mc domain: $E4MC_DOMAIN"
  update_dns "$E4MC_DOMAIN" 25565
else
  warn "no tunnel available — the server is up but unreachable from outside."
  warn "Set PLAYIT_SECRET (+ PLAYIT_ADDRESS), or enable e4mc's hostEnabled."
fi

$RCON "say §aServer is online. This shift ends in ${SERVE_MINUTES} minutes." >/dev/null 2>&1 || true

# ---------------------------------------------------------------- main loop ---
dispatch_successor() {
  [[ "$DISPATCHED" == 1 ]] && return 0
  DISPATCHED=1
  if [[ "${CONTINUE_CHAIN:-true}" == "false" ]]; then
    log "CONTINUE_CHAIN=false — not starting a successor (this shift is the last)"
    return 0
  fi
  if [[ -z "${DISPATCH_TOKEN:-}" ]]; then
    warn "DISPATCH_TOKEN unset — cannot start the successor; watchdog must recover this"
    return 0
  fi
  log "dispatching successor run"
  GH_TOKEN="$DISPATCH_TOKEN" gh workflow run server.yml --repo "$GITHUB_REPOSITORY" --ref main \
    && log "successor dispatched — it will queue on the concurrency group and take over on exit" \
    || warn "successor dispatch FAILED — watchdog must recover this"
}

START=$SECONDS
last_save=$SECONDS
declare -A warned=()

# Three consecutive failed probes, two minutes apart, before giving up on the
# tunnel. A single failure is usually a transient relay hiccup.
TUNNEL_FAILS=0
TUNNEL_FAIL_LIMIT="${TUNNEL_FAIL_LIMIT:-3}"

while true; do
  elapsed=$(( SECONDS - START ))
  remaining=$(( SERVE_SECONDS - elapsed ))

  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    warn "server process exited unexpectedly after ${elapsed}s — last 60 lines:"
    tail -60 "$RUN_DIR/server.log" >&2
    exit 1
  fi

  (( remaining <= 0 )) && { log "shift complete"; break; }

  if (( remaining <= HANDOFF_LEAD_SECONDS )); then dispatch_successor; fi

  for m in 10 5 2 1; do
    if (( remaining <= m * 60 )) && [[ -z "${warned[$m]:-}" ]]; then
      warned[$m]=1
      $RCON "say §eRestart in ${m} minute(s). Your progress is saved automatically." >/dev/null 2>&1 || true
    fi
  done

  # e4mc can be reassigned a different relay domain if its session drops and
  # reconnects mid-shift. Without this the DNS record would point at a dead
  # relay for the rest of the shift.
  # Only relevant on the e4mc fallback; playit's endpoint never changes.
  if [[ -z "${PLAYIT_SECRET:-}" ]] && (( elapsed % 60 < 10 )); then
    latest="$(current_domain)"
    if [[ -n "$latest" && "$latest" != "$E4MC_DOMAIN" ]]; then
      warn "e4mc domain changed: $E4MC_DOMAIN -> $latest"
      E4MC_DOMAIN="$latest"
      PUBLIC_HOST="$latest"
      TUNNEL_FAILS=0
      update_dns "$E4MC_DOMAIN" 25565
      $RCON "say §ePublic address changed. If you disconnect, rejoin in a minute." >/dev/null 2>&1 || true
    fi
  fi

  # The tunnel can die silently while the JVM stays perfectly healthy: e4mc's
  # relay keeps answering, but with "Unknown server", and nobody can join. RCON
  # cannot see that because the server itself is fine. Probe from outside.
  if [[ -n "$PUBLIC_HOST" ]] && (( elapsed % 120 < 10 )); then
    if python3 "$REPO_ROOT/tools/mcping.py" "$PUBLIC_HOST" "$PUBLIC_PORT" >/dev/null 2>&1; then
      TUNNEL_FAILS=0
    else
      TUNNEL_FAILS=$(( TUNNEL_FAILS + 1 ))
      warn "tunnel probe failed ($TUNNEL_FAILS/$TUNNEL_FAIL_LIMIT) for $PUBLIC_HOST:$PUBLIC_PORT"
      if (( TUNNEL_FAILS >= TUNNEL_FAIL_LIMIT )); then
        warn "e4mc tunnel is dead and did not recover — ending this shift so a"
        warn "fresh one takes over with a new session."
        dispatch_successor
        break
      fi
    fi
  fi

  # The server reads whitelist.json once, at boot. Without this, editing
  # server/whitelist.json would not take effect until the next handoff — up to
  # 5.4 hours of a player being unable to join for no visible reason.
  if (( elapsed % 120 < 10 )); then
    if curl -fsSL --max-time 15 \
         "https://raw.githubusercontent.com/$GITHUB_REPOSITORY/main/server/whitelist.json" \
         -o "$RUN_DIR/.whitelist.remote" 2>/dev/null; then
      if ! cmp -s "$RUN_DIR/.whitelist.remote" "$RUN_DIR/.whitelist.seen" 2>/dev/null; then
        log "whitelist changed upstream — merging and reloading"
        python3 - "$RUN_DIR/.whitelist.remote" "$RUN_DIR/whitelist.json" <<'PY'
import json, sys
def load(p):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, list) else []
    except Exception:
        return []
merged, seen = [], set()
for e in load(sys.argv[1]) + load(sys.argv[2]):
    if not isinstance(e, dict):
        continue
    k = (e.get("uuid") or e.get("name") or "").lower()
    if k and k not in seen:
        seen.add(k); merged.append(e)
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(merged, f, indent=2)
print(f"whitelist now {len(merged)} entries")
PY
        $RCON "whitelist reload" >/dev/null 2>&1 || warn "whitelist reload failed"
        cp "$RUN_DIR/.whitelist.remote" "$RUN_DIR/.whitelist.seen"
      fi
    fi
  fi

  if (( SECONDS - last_save >= AUTOSAVE_SECONDS )); then
    last_save=$SECONDS
    log "autosave"
    # The world is frozen only for the incremental rsync, then immediately
    # unfrozen; the slow git push happens with the server running normally.
    $RCON "save-off" "save-all flush" >/dev/null 2>&1 || true
    sleep 2
    "$REPO_ROOT/scripts/world.sh" stage || warn "autosave stage failed"
    $RCON "save-on" >/dev/null 2>&1 || true
    "$REPO_ROOT/scripts/world.sh" commit || warn "autosave push failed — continuing"
  fi

  sleep 10
done

kill "$TAIL_PID" 2>/dev/null || true
graceful_stop
log "shift ended cleanly"
