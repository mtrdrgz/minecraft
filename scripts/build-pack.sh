#!/usr/bin/env bash
# Assembles a runnable NeoForge server tree from the .mrpack + mods.lock.json.
#
# Output: $BUILD_DIR containing neoforge libraries, the server-safe mod set,
# pack config overrides, and the run script. Deterministic — the same lockfile
# always produces the same tree, which is what makes it safe to cache.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$HOME/mcbuild}"
LOCK="$REPO_ROOT/server/mods.lock.json"
MRPACK="$(find "$REPO_ROOT/pack" -maxdepth 1 -name '*.mrpack' -print -quit)"

log() { printf '\033[36m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[build] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$LOCK" ]] || die "missing $LOCK"
[[ -n "$MRPACK" ]] || die "no .mrpack found in $REPO_ROOT/pack"

MC_VERSION="$(jq -r .minecraft "$LOCK")"
NEOFORGE_VERSION="$(jq -r .neoforge "$LOCK")"
MOD_COUNT="$(jq -r '.mods | length' "$LOCK")"
log "pack=$(jq -r .packName "$LOCK") $(jq -r .packVersion "$LOCK")"
log "minecraft=$MC_VERSION neoforge=$NEOFORGE_VERSION mods=$MOD_COUNT"

if [[ -f "$BUILD_DIR/.build-complete" ]]; then
  log "reusing cached build at $BUILD_DIR"
  exit 0
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/mods"

# ---------------------------------------------------------------- neoforge ---
INSTALLER="$BUILD_DIR/neoforge-installer.jar"
INSTALLER_URL="https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEOFORGE_VERSION}/neoforge-${NEOFORGE_VERSION}-installer.jar"
log "downloading NeoForge $NEOFORGE_VERSION"
curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$INSTALLER" "$INSTALLER_URL" \
  || die "NeoForge installer download failed: $INSTALLER_URL"

log "running NeoForge server install (this pulls ~250MB of libraries)"
( cd "$BUILD_DIR" && java -jar "$INSTALLER" --installServer >/tmp/neoforge-install.log 2>&1 ) \
  || { tail -40 /tmp/neoforge-install.log >&2; die "NeoForge --installServer failed"; }
rm -f "$INSTALLER" "$INSTALLER".log
[[ -f "$BUILD_DIR/run.sh" ]] || die "NeoForge install produced no run.sh"
chmod +x "$BUILD_DIR/run.sh"

# -------------------------------------------------------------------- mods ---
# Downloaded in parallel with per-file sha512 verification. A corrupt or
# truncated mod jar is far more painful to diagnose at mod-load time.
log "downloading $MOD_COUNT server mods"
jq -r '.mods[] | [.url, .path, (.sha512 // "")] | @tsv' "$LOCK" > "$BUILD_DIR/.modlist.tsv"

download_line() {
  local line="$1"
  local url path want dest got
  url="$(printf '%s' "$line" | cut -f1)"
  path="$(printf '%s' "$line" | cut -f2)"
  want="$(printf '%s' "$line" | cut -f3)"

  dest="$BUILD_DIR/$path"
  mkdir -p "$(dirname "$dest")"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o "$dest" "$url" || {
    echo "DOWNLOAD FAILED: $path <- $url" >&2; return 1; }

  # A truncated jar surfaces later as an inscrutable mixin error, so verify here.
  if [[ -n "$want" ]]; then
    got="$(sha512sum "$dest" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { echo "SHA512 MISMATCH: $path" >&2; return 1; }
  fi
}
export -f download_line
export BUILD_DIR

# xargs exits 123 if any worker failed, so a single bad mod fails the build
# rather than producing a tree that dies at mod-load time.
tr '\n' '\0' < "$BUILD_DIR/.modlist.tsv" \
  | xargs -0 -P 8 -n 1 bash -c 'download_line "$1"' _ \
  || die "one or more mod downloads failed"
rm -f "$BUILD_DIR/.modlist.tsv"

# --------------------------------------------------------------- overrides ---
log "applying pack overrides"
OVR="$(mktemp -d)"
unzip -q "$MRPACK" -d "$OVR"
# The pack was zipped on Windows, so entries carry no POSIX read bits and every
# subsequent cp fails with EACCES. Restore sane modes before touching anything.
chmod -R u+rwX "$OVR"

if [[ -d "$OVR/overrides" ]]; then
  # Sinytra Connector's cache is a snapshot of the *client* instance: it holds
  # Fabric mods already transformed for the client, including ones excluded from
  # the server set. Connector rebuilds this at runtime, so ship it empty.
  if [[ -d "$OVR/overrides/mods/.connector" ]]; then
    log "dropping stale Connector cache ($(find "$OVR/overrides/mods/.connector" -type f | wc -l) files)"
    rm -rf "$OVR/overrides/mods/.connector"
  fi

  # Client-only asset trees are dead weight on a server; the jars inside
  # overrides/mods are checked against the lockfile drop list by name.
  rm -rf "$OVR/overrides/resourcepacks" "$OVR/overrides/shaderpacks"

  # Jars bundled in overrides are not Modrinth files, so the lockfile cannot
  # vouch for them. Drop the ones known to be client-only and surface anything
  # else rather than silently shipping a jar that may crash the server.
  if [[ -d "$OVR/overrides/mods" ]]; then
    for pat in 'essential*' '*iris*' '*sodium*' '*embeddium*' '*oculus*'; do
      find "$OVR/overrides/mods" -maxdepth 1 -type f -iname "$pat" -print -delete 2>/dev/null || true
    done
    remaining="$(find "$OVR/overrides/mods" -maxdepth 1 -type f -name '*.jar' | wc -l)"
    if (( remaining > 0 )); then
      log "NOTE: $remaining bundled override jar(s) kept unverified:"
      find "$OVR/overrides/mods" -maxdepth 1 -type f -name '*.jar' -printf '  %f\n'
    fi
  fi
  cp -a "$OVR/overrides/." "$BUILD_DIR/"
fi
rm -rf "$OVR"

# ------------------------------------------------------------------ config ---
cp "$REPO_ROOT/server/server.properties" "$BUILD_DIR/server.properties"
cp "$REPO_ROOT/server/ops.json"          "$BUILD_DIR/ops.json"
echo "eula=true" > "$BUILD_DIR/eula.txt"

# Heap is sized from the runner's actual RAM rather than hardcoded: public-repo
# runners are 16GB, but a downgrade to a 7GB runner would OOM a fixed -Xmx10G.
TOTAL_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
HEAP_MB=$(( TOTAL_MB - 3072 ))
(( HEAP_MB > 12288 )) && HEAP_MB=12288
(( HEAP_MB < 4096 ))  && HEAP_MB=4096
log "runner RAM ${TOTAL_MB}MB -> heap ${HEAP_MB}MB"

# Aikar's G1 tuning. Without these a 120-mod pack spends its life in GC pauses.
cat > "$BUILD_DIR/user_jvm_args.txt" <<EOF
-Xms${HEAP_MB}M
-Xmx${HEAP_MB}M
-XX:+UseG1GC
-XX:+ParallelRefProcEnabled
-XX:MaxGCPauseMillis=200
-XX:+UnlockExperimentalVMOptions
-XX:+DisableExplicitGC
-XX:+AlwaysPreTouch
-XX:G1NewSizePercent=30
-XX:G1MaxNewSizePercent=40
-XX:G1HeapRegionSize=8M
-XX:G1ReservePercent=20
-XX:G1HeapWastePercent=5
-XX:G1MixedGCCountTarget=4
-XX:InitiatingHeapOccupancyPercent=15
-XX:G1MixedGCLiveThresholdPercent=90
-XX:G1RSetUpdatingPauseTimePercent=5
-XX:SurvivorRatio=32
-XX:+PerfDisableSharedMem
-XX:MaxTenuringThreshold=1
-Dusing.aikars.flags=https://mcflags.emc.gs
-Daikars.new.flags=true
-Dfml.queryResult=confirm
EOF

touch "$BUILD_DIR/.build-complete"
log "build complete: $(du -sh "$BUILD_DIR" | cut -f1) at $BUILD_DIR"
log "mods installed: $(find "$BUILD_DIR/mods" -name '*.jar' | wc -l)"
