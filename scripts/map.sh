#!/usr/bin/env bash
# Persists BlueMap's rendered tiles across shifts, on their own `map` branch.
#
# Why a separate branch and not the world branch: the world is restored on every
# handoff and its clone time is on the critical path for downtime. Map tiles are
# large, numerous, and nobody is waiting on them, so they must not slow that
# down. The server can start and serve players while the map is still syncing.
#
# Why persisting at all: a full render of this world takes longer than one
# 5.4-hour shift. Without persistence every shift would restart from zero and
# the map would never finish.
#
# Usage: map.sh {restore|save}
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIGFILE="$SCRIPT_DIR/bigfile.sh"

MAPGIT="${MAPGIT:-$HOME/mapgit}"
RUN_DIR="${RUN_DIR:?RUN_DIR must be set}"
MAP_BRANCH="${MAP_BRANCH:-map}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
TOKEN="${GH_TOKEN:?GH_TOKEN must be set}"
REMOTE="https://x-access-token:${TOKEN}@github.com/${REPO}.git"

# BlueMap writes everything under this directory in the server dir.
MAP_SRC="$RUN_DIR/bluemap"

log() { printf '\033[94m[map]\033[0m %s\n' "$*"; }
git_c() { git -C "$MAPGIT" "$@"; }

rsync_ok() {
  local rc=0
  rsync "$@" || rc=$?
  case "$rc" in
    0)     return 0 ;;
    23|24) log "rsync warnings (exit $rc)"; return 0 ;;
    *)     log "rsync FAILED (exit $rc)"; return "$rc" ;;
  esac
}

cmd_restore() {
  rm -rf "$MAPGIT"
  if git clone --quiet --depth 1 --single-branch --branch "$MAP_BRANCH" "$REMOTE" "$MAPGIT" 2>/dev/null; then
    log "restored map branch ($(du -sh "$MAPGIT/bluemap" 2>/dev/null | cut -f1 || echo empty))"
  else
    log "no '$MAP_BRANCH' branch yet — the map starts from scratch"
    mkdir -p "$MAPGIT"
    git_c init --quiet --initial-branch "$MAP_BRANCH"
    git_c remote add origin "$REMOTE"
    printf '* -text\n' > "$MAPGIT/.gitattributes"
  fi
  git_c config user.email "actions@github.com"
  git_c config user.name  "minecraft-server[bot]"
  git_c config core.autocrlf false
  git_c config gc.auto 0

  mkdir -p "$MAP_SRC"
  if [[ -d "$MAPGIT/bluemap" ]]; then
    rsync_ok -a "$MAPGIT/bluemap/" "$MAP_SRC/"
    "$BIGFILE" assemble "$MAP_SRC"
  fi
  return 0
}

cmd_save() {
  [[ -d "$MAP_SRC" ]] || { log "nothing rendered yet"; return 0; }

  mkdir -p "$MAPGIT/bluemap"
  # BlueMap re-downloads these; they are large and not worth versioning.
  rsync_ok -a --delete \
    --exclude='.bluemap/' \
    --exclude='*.tmp' \
    --filter='P *.bigfile/' \
    "$MAP_SRC/" "$MAPGIT/bluemap/" || return 1

  "$BIGFILE" split "$MAP_SRC" "$MAPGIT/bluemap"
  "$BIGFILE" prune "$MAP_SRC" "$MAPGIT/bluemap"

  git_c add -A
  if git_c diff --cached --quiet; then
    log "no map changes"
    return 0
  fi

  local n
  n="$(git_c diff --cached --name-only | wc -l)"
  git_c commit --quiet -m "map render $(date -u +%Y-%m-%dT%H:%M:%SZ) ($n files)"

  # Squash every time: tile history is worthless and this branch would otherwise
  # grow without bound, far faster than the world branch.
  git_c checkout --quiet --orphan __squash
  git_c add -A
  git_c commit --quiet -m "map snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git_c branch -M "$MAP_BRANCH"
  git_c push --quiet --force origin "$MAP_BRANCH"
  log "pushed map ($n changed, $(du -sh "$MAPGIT/bluemap" 2>/dev/null | cut -f1))"
}

case "${1:-}" in
  restore) cmd_restore ;;
  save)    cmd_save ;;
  *) echo "usage: map.sh {restore|save}" >&2; exit 2 ;;
esac
