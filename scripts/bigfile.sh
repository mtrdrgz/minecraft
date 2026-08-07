#!/usr/bin/env bash
# Transparent large-file sharding for the world branch.
#
# GitHub hard-rejects any blob over 100MB. This splits oversized files into
# parts small enough to commit, and reassembles them byte-identically on the
# runner, so the per-file ceiling stops being a constraint.
#
# On-branch layout for an oversized file `world/data/Foo.sqlite`:
#
#   world/data/Foo.sqlite.bigfile/manifest.json
#   world/data/Foo.sqlite.bigfile/part-000
#   world/data/Foo.sqlite.bigfile/part-001   ...
#
# Parts are cut at fixed offsets, so an append-mostly file (which is what these
# usually are) reuses every unchanged part as the same Git blob and only the
# tail is actually pushed.
#
# Usage:
#   bigfile.sh split    <src_root> <dst_root>   src originals -> dst parts
#   bigfile.sh assemble <root>                  parts -> originals, in place
#   bigfile.sh list     <root>                  report oversized files
set -Eeuo pipefail

# Split anything above this. Below GitHub's 100MB hard limit with margin.
THRESHOLD_MB="${BIGFILE_THRESHOLD_MB:-90}"
# Part size. Under GitHub's 50MB advisory so pushes stay warning-free, and small
# enough that a localized change re-pushes little.
PART_MB="${BIGFILE_PART_MB:-48}"

log() { printf '\033[34m[bigfile]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[bigfile] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

file_size() { stat -c %s "$1"; }
file_mtime() { stat -c %Y "$1"; }

# The manifest is key=value rather than JSON on purpose: this script runs during
# server shutdown, and a missing jq must never be what loses a save. Values are
# rest-of-line, so filenames with spaces are fine.
manifest_get() {
  local file="$1" key="$2" line
  [[ -f "$file" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] && { printf '%s' "${line#"$key"=}"; return 0; }
  done < "$file"
  return 1
}

# ------------------------------------------------------------------- split ---
cmd_split() {
  local src="${1:?src_root}" dst="${2:?dst_root}"
  [[ -d "$src" ]] || return 0
  local threshold=$(( THRESHOLD_MB * 1024 * 1024 ))
  local count=0 reused=0

  while IFS= read -r -d '' f; do
    local rel size mtime bfdir manifest
    rel="${f#"$src"/}"
    size="$(file_size "$f")"
    mtime="$(file_mtime "$f")"
    bfdir="$dst/$rel.bigfile"
    manifest="$bfdir/manifest.json"

    # Re-splitting a multi-GB file every autosave would dominate the save
    # window. Size+mtime is enough to know the source is untouched.
    if [[ -f "$manifest" ]] \
       && [[ "$(manifest_get "$manifest" size  || true)" == "$size"  ]] \
       && [[ "$(manifest_get "$manifest" mtime || true)" == "$mtime" ]]; then
      reused=$(( reused + 1 ))
      continue
    fi

    log "splitting $rel ($(( size / 1048576 ))MB)"
    rm -rf "$bfdir"
    mkdir -p "$bfdir"
    split -b "${PART_MB}m" -d -a 3 --suffix-length=3 "$f" "$bfdir/part-" \
      || die "split failed for $rel"

    local parts sha
    parts="$(find "$bfdir" -name 'part-*' | wc -l)"
    sha="$(sha256sum "$f" | cut -d' ' -f1)"
    # Written last, after the parts exist, so a crash mid-split leaves a
    # manifest-less dir that the next run rebuilds rather than trusts.
    {
      printf 'name=%s\n'    "$(basename "$rel")"
      printf 'size=%s\n'    "$size"
      printf 'mtime=%s\n'   "$mtime"
      printf 'sha256=%s\n'  "$sha"
      printf 'parts=%s\n'   "$parts"
      printf 'partMB=%s\n'  "$PART_MB"
    } > "$manifest"
    count=$(( count + 1 ))
  done < <(find "$src" -type f -size +"${threshold}"c -print0)

  (( count > 0 || reused > 0 )) && log "split: $count rebuilt, $reused unchanged"
  return 0
}

# ---------------------------------------------------------------- assemble ---
cmd_assemble() {
  local root="${1:?root}"
  [[ -d "$root" ]] || return 0
  local count=0

  while IFS= read -r -d '' bfdir; do
    local manifest target name want got
    manifest="$bfdir/manifest.json"
    [[ -f "$manifest" ]] || { log "WARNING: $bfdir has no manifest — skipping"; continue; }

    name="$(manifest_get "$manifest" name)"   || die "manifest for $bfdir has no name"
    want="$(manifest_get "$manifest" sha256)" || die "manifest for $bfdir has no sha256"
    target="$(dirname "$bfdir")/$name"

    # Parts must concatenate in lexical order; -d -a 3 guarantees that.
    find "$bfdir" -name 'part-*' -print0 \
      | sort -z \
      | xargs -0 cat > "$target" || die "reassembly failed for $name"

    got="$(sha256sum "$target" | cut -d' ' -f1)"
    if [[ "$got" != "$want" ]]; then
      rm -f "$target"
      die "checksum mismatch reassembling $name (want $want, got $got) — refusing to use corrupt data"
    fi

    rm -rf "$bfdir"
    log "reassembled $name ($(( $(file_size "$target") / 1048576 ))MB, sha256 ok)"
    count=$(( count + 1 ))
  done < <(find "$root" -type d -name '*.bigfile' -print0)

  (( count > 0 )) && log "assembled $count file(s)"
  return 0
}

# -------------------------------------------------------------------- list ---
cmd_list() {
  local root="${1:?root}"
  local threshold=$(( THRESHOLD_MB * 1024 * 1024 ))
  find "$root" -type f -size +"${threshold}"c -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn \
    | awk -F'\t' '{ printf "  %8.1f MB  %s\n", $1/1048576, $2 }'
}

# ------------------------------------------------------------------- prune ---
# Drop shards whose source file was deleted or has shrunk back under the
# threshold. Without this, a file that stops being oversized would keep its
# stale parts on the branch forever alongside the now-normal file.
cmd_prune() {
  local src="${1:?src_root}" dst="${2:?dst_root}"
  [[ -d "$dst" ]] || return 0
  local threshold=$(( THRESHOLD_MB * 1024 * 1024 ))
  local pruned=0

  # Shards for files that are deliberately absent from src (stored on the branch
  # but never restored to the server) must not be treated as stale. Without this
  # the first save after a restore would delete them.
  local keep=()
  if [[ -n "${BIGFILE_PRUNE_KEEP:-}" && -f "$BIGFILE_PRUNE_KEEP" ]]; then
    local pat
    while IFS= read -r pat; do
      [[ -z "$pat" || "$pat" == \#* ]] && continue
      keep+=("$pat")
    done < "$BIGFILE_PRUNE_KEEP"
  fi

  while IFS= read -r -d '' bfdir; do
    local rel origin skip=0
    rel="${bfdir#"$dst"/}"

    local k
    for k in ${keep+"${keep[@]}"}; do
      # shellcheck disable=SC2053  # glob match against the pattern is intended
      if [[ "/$rel" == $k ]]; then skip=1; break; fi
    done
    if (( skip )); then
      log "keeping protected shards: ${rel%.bigfile}"
      continue
    fi

    origin="$src/${rel%.bigfile}"
    if [[ ! -f "$origin" ]] || (( $(file_size "$origin") <= threshold )); then
      log "pruning stale shards: ${rel%.bigfile}"
      rm -rf "$bfdir"
      pruned=$(( pruned + 1 ))
    fi
  done < <(find "$dst" -type d -name '*.bigfile' -print0)

  (( pruned > 0 )) && log "pruned $pruned stale shard dir(s)"
  return 0
}

case "${1:-}" in
  split)    shift; cmd_split "$@" ;;
  assemble) shift; cmd_assemble "$@" ;;
  prune)    shift; cmd_prune "$@" ;;
  list)     shift; cmd_list "$@" ;;
  *) echo "usage: bigfile.sh {split <src> <dst>|assemble <root>|prune <src> <dst>|list <root>}" >&2; exit 2 ;;
esac
