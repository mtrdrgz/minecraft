#!/usr/bin/env bash
# World persistence against an orphan `world` branch in this same repo.
#
# Why a branch and not a tarball: autosaves push only the region files that
# actually changed (a few MB), instead of re-uploading the whole world every
# cycle. Why orphan + periodic squash: history of binary chunk data would grow
# without bound, so each handoff collapses the branch back to one commit.
#
# Usage: world.sh {restore|stage|commit|save|squash}
#
# stage and commit are separate on purpose: the caller holds the server's
# save-off across `stage` (a fast incremental rsync) and releases it before
# `commit` (the slow git push), so players feel ~2s, not ~60s.
set -Eeuo pipefail

WORLDGIT="${WORLDGIT:-$HOME/worldgit}"
RUN_DIR="${RUN_DIR:?RUN_DIR must be set}"
WORLD_BRANCH="${WORLD_BRANCH:-world}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
TOKEN="${GH_TOKEN:?GH_TOKEN must be set}"
REMOTE="https://x-access-token:${TOKEN}@github.com/${REPO}.git"

# GitHub hard-rejects any blob over 100MB. Region files sit far below this, but
# a corrupt level.dat or a mod dumping a huge cache would wedge the branch.
MAX_BLOB_MB=95

log() { printf '\033[35m[world]\033[0m %s\n' "$*"; }

git_c() { git -C "$WORLDGIT" "$@"; }

configure() {
  git_c config user.email "actions@github.com"
  git_c config user.name  "minecraft-server[bot]"
  git_c config core.autocrlf false
  git_c config gc.auto 0
}

cmd_restore() {
  rm -rf "$WORLDGIT"
  if git clone --quiet --depth 1 --single-branch --branch "$WORLD_BRANCH" "$REMOTE" "$WORLDGIT" 2>/dev/null; then
    log "restored world branch ($(du -sh "$WORLDGIT/world" 2>/dev/null | cut -f1 || echo 'empty'))"
  else
    log "no '$WORLD_BRANCH' branch yet — starting a fresh world"
    mkdir -p "$WORLDGIT"
    git_c init --quiet --initial-branch "$WORLD_BRANCH"
    git_c remote add origin "$REMOTE"
    printf '* -text\n' > "$WORLDGIT/.gitattributes"
  fi
  configure

  mkdir -p "$RUN_DIR"
  if [[ -d "$WORLDGIT/world" ]]; then
    rsync -a --delete "$WORLDGIT/world/" "$RUN_DIR/world/"
  fi
  # Runtime state that must survive a handoff but is not part of the world dir.
  for f in whitelist.json banned-players.json banned-ips.json usercache.json ops.json; do
    [[ -f "$WORLDGIT/state/$f" ]] && cp "$WORLDGIT/state/$f" "$RUN_DIR/$f"
  done
  return 0
}

stage() {
  mkdir -p "$WORLDGIT/state"
  [[ -d "$RUN_DIR/world" ]] && rsync -a --delete "$RUN_DIR/world/" "$WORLDGIT/world/"
  for f in whitelist.json banned-players.json banned-ips.json usercache.json ops.json; do
    [[ -f "$RUN_DIR/$f" ]] && cp "$RUN_DIR/$f" "$WORLDGIT/state/$f"
  done
  printf '* -text\n' > "$WORLDGIT/.gitattributes"

  local big
  big="$(find "$WORLDGIT" -path "$WORLDGIT/.git" -prune -o -type f -size +${MAX_BLOB_MB}M -print 2>/dev/null || true)"
  if [[ -n "$big" ]]; then
    log "WARNING: files exceed ${MAX_BLOB_MB}MB and will be excluded from the push:"
    while IFS= read -r f; do
      log "  $(du -h "$f" | cut -f1)  ${f#$WORLDGIT/}"
      echo "${f#$WORLDGIT/}" >> "$WORLDGIT/.git/info/exclude"
      rm -f "$f"
    done <<< "$big"
  fi
}

# Push ladder: a shallow clone can occasionally be refused by the remote, and a
# concurrent push from a lingering predecessor can cause a non-fast-forward.
# Rather than lose a save, escalate to a full-history push, then to an orphan
# force-push, which always succeeds.
push_branch() {
  if git_c push --quiet origin "HEAD:$WORLD_BRANCH" 2>/dev/null; then return 0; fi
  log "incremental push rejected — unshallowing and retrying"
  git_c fetch --quiet --unshallow origin "$WORLD_BRANCH" 2>/dev/null || true
  if git_c push --quiet origin "HEAD:$WORLD_BRANCH" 2>/dev/null; then return 0; fi
  log "still rejected — falling back to orphan force-push"
  cmd_squash
}

cmd_commit() {
  git_c add -A
  if git_c diff --cached --quiet; then
    log "no changes since last save"
    return 0
  fi
  git_c commit --quiet -m "autosave $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  push_branch
  log "saved ($(git_c rev-parse --short HEAD))"
}

# Collapse the branch to a single commit so binary history never accumulates.
cmd_squash() {
  stage
  git_c checkout --quiet --orphan __squash
  git_c add -A
  git_c commit --quiet -m "world snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git_c branch -M "$WORLD_BRANCH"
  git_c push --quiet --force origin "$WORLD_BRANCH"
  log "squashed world branch to a single commit ($(du -sh "$WORLDGIT/world" 2>/dev/null | cut -f1))"
}

case "${1:-}" in
  restore) cmd_restore ;;
  stage)   stage ;;
  commit)  cmd_commit ;;
  save)    stage; cmd_commit ;;
  squash)  cmd_squash ;;
  *) echo "usage: world.sh {restore|stage|commit|save|squash}" >&2; exit 2 ;;
esac
