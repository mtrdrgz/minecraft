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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIGFILE="$SCRIPT_DIR/bigfile.sh"

# Paths stored on the branch but never handed to the running server. Skipped on
# restore so handoffs do not pay their download cost, and protected from
# --delete on save so the server's absence of them does not wipe them.
RUNTIME_EXCLUDE="${RUNTIME_EXCLUDE:-$SCRIPT_DIR/../server/world-runtime-exclude.txt}"

WORLDGIT="${WORLDGIT:-$HOME/worldgit}"
RUN_DIR="${RUN_DIR:?RUN_DIR must be set}"
WORLD_BRANCH="${WORLD_BRANCH:-world}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
TOKEN="${GH_TOKEN:?GH_TOKEN must be set}"
REMOTE="https://x-access-token:${TOKEN}@github.com/${REPO}.git"

# Files above this are sharded by bigfile.sh rather than committed whole, so
# GitHub's 100MB per-blob hard limit is not a constraint on world contents.
BIGFILE_THRESHOLD_MB="${BIGFILE_THRESHOLD_MB:-90}"
export BIGFILE_THRESHOLD_MB

log() { printf '\033[35m[world]\033[0m %s\n' "$*"; }

# rsync exits 23/24 for partial-transfer and vanished-file conditions. Protect
# filters guarantee 23 ("cannot delete non-empty directory") on every save that
# keeps runtime-excluded data, and under `set -e` that would abort every single
# save. Treat those two as the warnings they are; anything else is fatal.
rsync_ok() {
  local rc=0
  rsync "$@" || rc=$?
  case "$rc" in
    0)     return 0 ;;
    23|24) log "rsync completed with warnings (exit $rc) — expected when protecting excluded paths"; return 0 ;;
    *)     log "rsync FAILED (exit $rc)"; return "$rc" ;;
  esac
}

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
    local ex=()
    [[ -f "$RUNTIME_EXCLUDE" ]] && ex=(--exclude-from="$RUNTIME_EXCLUDE")
    rsync_ok -a --delete "${ex[@]}" "$WORLDGIT/world/" "$RUN_DIR/world/"
    # Turn any sharded files back into the originals the server expects.
    # Verifies sha256 and aborts on mismatch rather than handing the server
    # a silently corrupt region file or database.
    "$BIGFILE" assemble "$RUN_DIR/world"
  fi
  # Runtime state that must survive a handoff but is not part of the world dir.
  for f in whitelist.json banned-players.json banned-ips.json usercache.json ops.json; do
    [[ -f "$WORLDGIT/state/$f" ]] && cp "$WORLDGIT/state/$f" "$RUN_DIR/$f"
  done

  # Baseline for assert_world_sane. Written after restore so it reflects what
  # we actually handed the server, not what the branch happened to contain.
  find "$RUN_DIR/world" -name '*.mca' 2>/dev/null | wc -l > "${RESTORE_MANIFEST:-$HOME/.mc-restore-manifest}"
  log "restored $(cat "${RESTORE_MANIFEST:-$HOME/.mc-restore-manifest}") region files"
  return 0
}

# Every push to the world branch is destructive by design (squash force-pushes).
# If a restore silently failed, or the server wiped the run dir, an unguarded
# shutdown would force-push an empty world over real progress. Refuse to push a
# world that lost its level.dat or most of its region files.
assert_world_sane() {
  local manifest="${RESTORE_MANIFEST:-$HOME/.mc-restore-manifest}"
  local mca
  mca="$(find "$RUN_DIR/world" -name '*.mca' 2>/dev/null | wc -l)"

  if [[ ! -f "$RUN_DIR/world/level.dat" ]]; then
    log "REFUSING TO PUSH: $RUN_DIR/world/level.dat is missing."
    log "The world branch has been left untouched. Investigate before rerunning."
    return 1
  fi

  if [[ -f "$manifest" ]]; then
    local before threshold
    before="$(cat "$manifest")"
    threshold=$(( before / 2 ))
    if (( before > 0 && mca < threshold )); then
      log "REFUSING TO PUSH: region count collapsed ($before -> $mca .mca files)."
      log "The world branch has been left untouched. Investigate before rerunning."
      return 1
    fi
  fi
  return 0
}

stage() {
  assert_world_sane || return 1
  mkdir -p "$WORLDGIT/state"

  if [[ -d "$RUN_DIR/world" ]]; then
    # Oversized files are copied as shards by bigfile.sh, never whole, so they
    # are excluded from the plain rsync. Existing shard dirs are protected from
    # --delete since the source side has the assembled file, not the parts.
    local excludes
    excludes="$(mktemp)"
    find "$RUN_DIR/world" -type f -size +"$(( BIGFILE_THRESHOLD_MB * 1024 * 1024 ))"c \
      -printf '/%P\n' > "$excludes" 2>/dev/null || true

    # Runtime-excluded paths are absent from RUN_DIR by design, so they must be
    # protected from --delete or the first save would erase them from the branch.
    local protect=()
    if [[ -f "$RUNTIME_EXCLUDE" ]]; then
      while IFS= read -r pat; do
        [[ -z "$pat" || "$pat" == \#* ]] && continue
        protect+=(--filter="P $pat")
      done < "$RUNTIME_EXCLUDE"
    fi

    # session.lock is a runtime mutex the server rewrites on every boot. Carrying
    # it between shifts is pure churn and risks a spurious "world is in use".
    rsync_ok -a --delete \
      --exclude-from="$excludes" \
      --exclude='session.lock' \
      --filter='P *.bigfile/' \
      "${protect[@]}" \
      "$RUN_DIR/world/" "$WORLDGIT/world/" || { rm -f "$excludes"; return 1; }
    rm -f "$excludes"

    "$BIGFILE" split "$RUN_DIR/world" "$WORLDGIT/world"
    BIGFILE_PRUNE_KEEP="$RUNTIME_EXCLUDE" "$BIGFILE" prune "$RUN_DIR/world" "$WORLDGIT/world"
  fi

  for f in whitelist.json banned-players.json banned-ips.json usercache.json ops.json; do
    [[ -f "$RUN_DIR/$f" ]] && cp "$RUN_DIR/$f" "$WORLDGIT/state/$f"
  done
  printf '* -text\n' > "$WORLDGIT/.gitattributes"

  # Nothing should reach Git above the limit now; if it does, that is a bug in
  # the sharding path and must be loud rather than a rejected push later.
  local big
  big="$(find "$WORLDGIT" -path "$WORLDGIT/.git" -prune -o -type f -size +99M -print 2>/dev/null || true)"
  if [[ -n "$big" ]]; then
    log "BUG: files still exceed GitHub's 100MB limit after sharding:"
    while IFS= read -r f; do log "  $(du -h "$f" | cut -f1)  ${f#"$WORLDGIT"/}"; done <<< "$big"
    return 1
  fi
  return 0
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
