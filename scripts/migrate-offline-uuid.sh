#!/usr/bin/env bash
# Migrates a player's saved data from their Mojang UUID to their offline UUID.
#
# With online-mode=false the server no longer asks Mojang who a player is; it
# derives the UUID locally as UUID.nameUUIDFromBytes("OfflinePlayer:<name>").
# That is a different UUID, so an existing character is not found and the player
# spawns fresh — losing inventory, position, advancements and stats.
#
# Run against a checkout of the `world` branch, with no shift holding the world.
#
# Usage: migrate-offline-uuid.sh <world_dir> <player_name> <online_uuid>
set -Eeuo pipefail

WORLD="${1:?usage: migrate-offline-uuid.sh <world_dir> <name> <online_uuid>}"
NAME="${2:?player name}"
ONLINE="${3:?online uuid}"

log() { printf '\033[36m[migrate]\033[0m %s\n' "$*"; }

# Unlike the runner scripts, this one is meant to be run by hand, including from
# Git Bash on Windows. Probe by executing: Windows ships an App Execution Alias
# named python3 that resolves via `command -v` but exits with an error when run.
PY_BIN=""
for cand in python3 python py; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys' >/dev/null 2>&1; then
    PY_BIN="$cand"; break
  fi
done
[[ -n "$PY_BIN" ]] || { echo "no working python interpreter found" >&2; exit 1; }

OFFLINE="$("$PY_BIN" - "$NAME" <<'PY'
import hashlib, sys, uuid
name = sys.argv[1]
print(uuid.UUID(bytes=hashlib.md5(f"OfflinePlayer:{name}".encode()).digest()[:16], version=3))
PY
)"

log "$NAME: $ONLINE -> $OFFLINE"

moved=0
for spec in "playerdata:.dat" "playerdata:.dat_old" "advancements:.json" "stats:.json"; do
  dir="${spec%%:*}"; ext="${spec##*:}"
  src="$WORLD/$dir/$ONLINE$ext"
  dst="$WORLD/$dir/$OFFLINE$ext"
  if [[ -f "$src" ]]; then
    # Copy rather than move: if the player ever switches back to online mode,
    # the original character is still there.
    cp -p "$src" "$dst"
    log "  $dir/$(basename "$src") -> $(basename "$dst")"
    moved=$(( moved + 1 ))
  fi
done

if (( moved == 0 )); then
  log "WARNING: nothing found for $ONLINE — is the world dir correct?"
  exit 1
fi
log "migrated $moved file(s); the online-mode character is preserved as a copy"
