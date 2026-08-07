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
- Nothing is ever committed larger than 95 MB (GitHub hard-rejects >100 MB).

Worst-case loss on an ungraceful runner kill is one autosave interval, 10 minutes.

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

### 1. playit.gg tunnel

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

### 2. Repository secrets

**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|---|---|
| `PLAYIT_SECRET` | The playit agent secret key from step 1. |
| `DISPATCH_TOKEN` | A fine-grained PAT scoped to this repo with **Actions: read and write** and **Contents: read**. |

`DISPATCH_TOKEN` is required because events triggered with the built-in
`GITHUB_TOKEN` deliberately do not start new workflow runs — without it the
chain cannot relaunch itself. World pushes use `GITHUB_TOKEN` and need no PAT.

### 3. DNS

Cloudflare's proxy cannot carry Minecraft traffic — public hostnames on Tunnel
are HTTP/HTTPS only, and raw TCP requires Spectrum (Enterprise). Both records
must therefore be **DNS only (grey cloud)**, not proxied.

| Type | Name | Value |
|---|---|---|
| `CNAME` | `minecraft` | `abc-def.gl.at.ply.gg` *(DNS only)* |
| `SRV` | `_minecraft._tcp.minecraft` | priority `0`, weight `0`, port `41234`, target `minecraft.mtrdrgzcid.com` |

The SRV record is what lets players type `minecraft.mtrdrgzcid.com` without a
port. playit's free tier assigns a random port; a paid plan can give you 25565
directly, in which case the SRV record is optional.

No dynamic DNS is needed — the playit endpoint is stable across runner
restarts, so these records are set once.

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
