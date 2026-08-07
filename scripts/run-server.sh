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

# Repo whitelist is the source of truth, but /whitelist add done in-game is
# persisted too — union them so neither is silently lost.
python3 - "$REPO_ROOT/server/whitelist.json" "$RUN_DIR/whitelist.json" <<'PY'
import json, os, sys
def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return []
merged, seen = [], set()
for entry in load(sys.argv[1]) + load(sys.argv[2]):
    key = (entry.get("uuid") or entry.get("name", "")).lower()
    if key and key not in seen:
        seen.add(key); merged.append(entry)
with open(sys.argv[2], "w") as f: json.dump(merged, f, indent=2)
print(f"whitelist: {len(merged)} entries")
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
if [[ -n "${PLAYIT_SECRET:-}" ]]; then
  log "starting playit tunnel"
  "$HOME/bin/playitd" --secret "$PLAYIT_SECRET" > "$RUN_DIR/playit.log" 2>&1 &
  PLAYIT_PID=$!
  sleep 5
  if ! kill -0 "$PLAYIT_PID" 2>/dev/null; then
    warn "playit agent exited immediately — players cannot connect. Log:"
    cat "$RUN_DIR/playit.log" >&2
  fi
else
  warn "PLAYIT_SECRET is not set — the server is running but unreachable"
fi

$RCON "say §aServer is online. This shift ends in ${SERVE_MINUTES} minutes." >/dev/null 2>&1 || true

# ---------------------------------------------------------------- main loop ---
dispatch_successor() {
  [[ "$DISPATCHED" == 1 ]] && return 0
  DISPATCHED=1
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
