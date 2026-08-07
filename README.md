# minecraft

Create+ 1.0.0 (Minecraft 1.21.1 / NeoForge 21.1.233) running on GitHub Actions,
exposed through a playit.gg tunnel at `minecraft.mtrdrgzcid.com`, with the world
persisted to an orphan branch in this repo.

> [!WARNING]
> **This violates GitHub's Acceptable Use Policy.** Actions may not be used for
> "any activity unrelated to the production, testing, deployment, or publication
> of the software project associated with the repository." A self-relaunching
> workflow chain on a public repo — i.e. unmetered free minutes — is the exact
> pattern GitHub detects and suspends accounts for. This is set up as requested;
> the account risk is real and is yours.

## How it works

```
workflow_dispatch
      │
      ├─ prep job     assemble server tree → actions/cache      (runs in parallel
      │                                                          with the previous
      │                                                          shift's last minutes)
      └─ serve job    concurrency group "minecraft-serve"
                      ├─ restore world branch → boot server
                      ├─ start playit tunnel
                      ├─ autosave → push changed chunks   every 10 min
                      ├─ T-12m  dispatch successor  ─────────────┐
                      ├─ T-10/5/2/1m  in-game warnings           │
                      └─ T-0    stop, squash world, exit ────────┘
```

A shift serves for **325 minutes**, inside the job's 355-minute cap and GitHub's
hard 360-minute kill. The successor is dispatched 12 minutes early so its `prep`
job finishes while the current server is still up; it then waits on the
concurrency group and starts within seconds of the predecessor releasing it.

**Expected gap per handoff: ~4-6 minutes** (cache restore, world restore, and a
cold 120-mod boot). That is roughly **98.5% uptime**. It cannot go to zero —
only one process may hold the world at a time, so the successor cannot boot
until the predecessor has stopped and pushed.

### World persistence

The world lives on an orphan `world` branch, not in `main` and not in a tarball.

- Autosaves `git add`/`push` only the region files that changed — a few MB, not
  the whole world.
- Each handoff **squashes the branch to a single orphan commit**, so binary
  chunk history never accumulates and the repo stays at roughly one world's size.
- No Git LFS: its free tier is 1 GB and would be exhausted immediately.
- Files over 90 MB are **sharded**, so GitHub's 100 MB per-blob hard limit is
  not a constraint on world contents. See below.

### Large-file sharding

`scripts/bigfile.sh` splits any file above 90 MB into 48 MB parts and
reassembles it byte-identically on the runner. An oversized
`world/data/Foo.sqlite` is stored as:

```
world/data/Foo.sqlite.bigfile/manifest.json
world/data/Foo.sqlite.bigfile/part-000
world/data/Foo.sqlite.bigfile/part-001   ...
```

- Parts are cut at **fixed offsets**, so an append-mostly file reuses every
  unchanged part as the same Git blob — only the tail is actually pushed.
- The manifest records a **sha256 of the whole original**. Reassembly verifies
  it and aborts rather than handing the server a silently corrupt database.
- It is written *last*, so a crash mid-split leaves a manifest-less directory
  that the next run rebuilds instead of trusting.
- Splitting is skipped when the source's size and mtime are unchanged, so a
  multi-GB file does not get recut on every 10-minute autosave.
- The manifest is `key=value`, not JSON, deliberately: this code runs during
  shutdown and a missing `jq` must never be what loses a save.

`prune` removes shards whose source shrank back under the threshold or was
deleted — except for paths listed in the runtime-exclude file below.

### Runtime exclusions

`server/world-runtime-exclude.txt` lists paths that are **stored on the branch
but never handed to the running server**. They are skipped on restore and
protected from `--delete` on save.

This exists for data worth backing up that the server never reads. Distant
Horizons' LOD cache (~2.4 GB) is the default entry: DH is a client-side
renderer, is not in the server mod set, and in multiplayer **each client builds
its own per-server cache** — so the singleplayer cache is never read by anyone.
Restoring it every handoff would add gigabytes of download to each changeover
and directly widen the downtime gap.

`.github/workflows/selftest.yml` verifies all of this on a real runner, because
rsync filter semantics cannot be tested on a Windows dev box and getting them
wrong silently deletes world data.

Worst-case loss on an ungraceful runner kill is one autosave interval, 10 minutes.

Because every push to `world` is destructive by design (the squash force-pushes),
`world.sh` refuses to push a world whose `level.dat` is missing or whose region
count has collapsed to under half of what was restored. A failed restore
therefore leaves the branch untouched instead of overwriting real progress with
an empty world.

### The world

The `world` branch was imported from the singleplayer save **Definitivo**
(`ModrinthApp/profiles/Create+/saves/Definitivo`), MC 1.21.1 / NeoForge —
1,414 files, ~1,146 MB on disk, ~384 MB packed.

The Distant Horizons caches — `data/DistantHorizons.sqlite` (2,245 MB) and
`DIM-1/data/DistantHorizons.sqlite` (171 MB) — are stored on the branch as
shards, since each far exceeds GitHub's 100 MB per-blob limit. They are listed
in `server/world-runtime-exclude.txt`, so they are backed up but never restored
to a runner. `session.lock` is excluded entirely; the server recreates it.

The original save on your PC is untouched — it was copied, not moved.

Because the repo is public, the `world` branch is publicly downloadable. The
whitelist protects the *server*, not the world download.

### Mod filtering

The `.mrpack` marks all 176 mods `server: required`, which is wrong — 51 are
`server_side: unsupported` on Modrinth (Sodium, Iris, Fresh Animations, the
shader and rendering stack) and 5 more are client-only in practice. Loading them
would crash the server on startup.

`server/mods.lock.json` is the resolved, server-safe set: **120 mods, 349 MB**.
Regenerate it if the modpack changes:

```bash
node tools/audit-pack.mjs <(unzip -p "pack/Create+ 1.0.0.mrpack" modrinth.index.json) audit.json
node tools/regen-lock.mjs audit.json modrinth.index.json server/mods.lock.json
```

## Setup

### 1. Transport: e4mc + dynamic DNS

The server is exposed by **e4mc**, which is already in your modpack. It needs no
account and no binary — its `ServerConnectionListener` mixin fires when the
dedicated server binds its TCP listener, asks the relay for a domain, and logs:

```
[e4mc/]: Domain assigned: quiet-forest-1234.e4mc.link
```

Two things to know before relying on this:

- **e4mc warns about this use case.** Its own source logs
  `e4mc running on Dedicated Server; This works, but isn't recommended as e4mc
  is designed for short-lived LAN servers`. It works; it is a free community
  relay with no guarantees.
- **The domain is different every shift.** The protocol requests a fresh
  assignment each session, so there is no fixed or custom domain. That is why
  the DNS record is rewritten on every boot — the dynamic DNS half of the setup.

`scripts/run-server.sh` reads the domain from the log and calls
`scripts/dns-update.sh`, which rewrites `minecraft.mtrdrgzcid.com` as an
**unproxied** CNAME with a 60-second TTL. Unproxied is mandatory: Minecraft is
raw TCP and Cloudflare's proxy cannot carry it.

Expect roughly **one extra minute** of unreachability per handoff on top of the
server gap, while the old CNAME expires from client resolvers.

playit.gg remains an opt-in fallback: set `PLAYIT_SECRET` and it runs alongside.

<details>
<summary>playit.gg setup (only if you use the fallback)</summary>

You need an **agent secret key**. Note that the `/account/agents/new-docker`
URL cited by most playit tutorials is dead — it 404s. Use one of these instead.

**Option A — desktop app (easiest on Windows).** Install playit from
[playit.gg/download](https://playit.gg/download) and claim the agent through the
app. Then print where the secret is stored and open that file:

```bash
playit-cli secret-path
```

**Option B — claim from the command line.** This is the flow the CLI actually
implements (`playit-cli --help`); `exchange` prints the secret to stdout:

```bash
playit-cli claim generate
```

Take the code it prints, then:

```bash
playit-cli claim url <CODE> --name minecraft-actions
```

Open that URL in a browser and approve the agent. Then:

```bash
playit-cli claim exchange <CODE>
```

It blocks until you approve, then prints the secret key.

Either way, finish in the web dashboard at
[playit.gg/account/agents](https://playit.gg/account/agents): add a tunnel of
type **Minecraft Java** pointing at local address `127.0.0.1:25565`, bound to
that agent. Note the assigned public address, e.g. `abc-def.gl.at.ply.gg:41234`.

> The secret is shown once and grants control of your tunnels. Put it straight
> into the `PLAYIT_SECRET` repo secret; never commit it.

</details>

### 2. Repository secrets

**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Required | Value |
|---|---|---|
| `DISPATCH_TOKEN` | yes | Fine-grained PAT scoped to this repo with **Actions: read and write**, **Contents: read**. |
| `CF_API_TOKEN` | yes | Cloudflare API token with **Zone → DNS → Edit** on `mtrdrgzcid.com`. Create at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) using the *Edit zone DNS* template. |
| `CF_ZONE_ID` | yes | Zone ID for `mtrdrgzcid.com`, shown in the domain's Overview page sidebar. |
| `PLAYIT_SECRET` | no | Only if you want the playit fallback running alongside e4mc. |

Without `CF_API_TOKEN`/`CF_ZONE_ID` the server still runs and still gets an e4mc
domain — it just logs it instead of publishing it, and players must connect to
the `*.e4mc.link` address directly that shift.

`DISPATCH_TOKEN` is required because events triggered with the built-in
`GITHUB_TOKEN` deliberately do not start new workflow runs — without it the
chain cannot relaunch itself. World pushes use `GITHUB_TOKEN` and need no PAT.

### 3. DNS

Nothing to create by hand. `dns-update.sh` manages the record itself on every
boot, creating it the first time and updating it thereafter:

| Type | Name | Value | Proxy | TTL |
|---|---|---|---|---|
| `CNAME` | `minecraft` | `<assigned>.e4mc.link` | **DNS only** | 60 |

Never turn the orange cloud on for this record. Cloudflare's proxy handles
HTTP/HTTPS only; raw TCP requires Spectrum, and Spectrum cannot use a Tunnel or
a runner without an inbound address as its origin. Proxying it silently breaks
every connection.

### 4. Whitelist

Edit `server/whitelist.json` and commit:

```json
[
  { "uuid": "069a79f4-44e9-4726-a5be-fca90e38aaf5", "name": "Notch" }
]
```

Get UUIDs from [mcuuid.net](https://mcuuid.net). `/whitelist add` in-game also
works and is persisted to the `world` branch — the two are merged at boot, so
neither is lost. Add operators the same way in `server/ops.json`.

### 5. Start it

```bash
gh workflow run server.yml --repo mtrdrgz/minecraft --ref main
```

The chain sustains itself from there. To stop it permanently, disable both
workflows — otherwise the watchdog restarts the server within five minutes.

## Operating

| Task | How |
|---|---|
| Watch the current shift | `gh run watch --repo mtrdrgz/minecraft` |
| Force a restart | Cancel the running `serve` job; the watchdog recovers it |
| Stop everything | Disable `server` **and** `watchdog` in the Actions tab |
| Download the world | `git clone --branch world --depth 1 <repo>` |
| Read crash logs | Download the `server-logs-*` artifact from the run |

### Tuning

Timings are environment variables in `.github/workflows/server.yml`:

- `SERVE_MINUTES` (325) — shift length. Raising it past ~340 risks GitHub
  killing the job mid-save.
- `AUTOSAVE_MINUTES` (10) — also your worst-case data loss window.
- `HANDOFF_LEAD_MINUTES` (12) — must exceed the successor's `prep` time.

Heap is sized from the runner's actual RAM at build time (`total - 3 GB`, capped
at 12 GB) rather than hardcoded, so a downgrade to a smaller runner degrades
instead of OOM-ing.

## Known limitations

- **~4-6 minutes of downtime every 5.4 hours.** Unavoidable with this design.
- **The world is public.** The repo must be public for unmetered Actions minutes
  (private repos cap at 2,000/month; 24/7 needs ~43,200), and the `world` branch
  is therefore world-readable. The whitelist protects the *server*, not the
  world download.
- **Scheduled workflows drift.** The watchdog's 5-minute cron is queued at low
  priority on public repos and can fire late.
- **Actions caches expire after 7 days of no use** and are evicted at 10 GB per
  repo. A cache miss adds ~5 minutes to a handoff, and the `serve` job rebuilds
  the tree inline rather than failing.
- Create contraptions in motion during a restart are saved as-is; nothing is
  lost, but in-flight items on belts can settle oddly.
