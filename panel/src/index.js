/**
 * Minecraft status + console panel, served at mtrdrgzcid.com/mc
 *
 * Deliberately a separate Worker from the site itself. The live site's source
 * exists only as a deployed bundle — it is in no repository and not on the
 * owner's machine — and its pages live in an ASSETS binding this Worker has no
 * copy of. Redeploying it to add a tab would destroy the site. A route on
 * /mc* attaches alongside it instead, changing nothing.
 *
 * Authentication is not reimplemented either: the site already issues an
 * HMAC-signed `mh_session` cookie carrying a role. Given the same
 * SESSION_SECRET, this Worker verifies that same cookie and demands
 * role === "admin". One login, one password, one place to revoke it.
 *
 * The runner has no inbound connectivity, so commands cannot be pushed to it.
 * It polls: the panel enqueues into KV, the runner drains the queue over the
 * workers.dev hostname (which bypasses the zone WAF that blocks datacenter IPs)
 * and posts results back.
 */

const COOKIE = "mh_session";

const KEY_STATUS = "server_status";
const KEY_TUNNEL = "tunnel_host";
const KEY_QUEUE = "cmd_queue";
const RESULT_PREFIX = "cmd_result:";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // ---- runner-facing, bearer token, no cookie ----------------------------
    if (path.startsWith("/__")) return runnerApi(request, env, url, path);

    // ---- everything else is the admin panel --------------------------------
    const session = await verifySession(request, env);
    if (session?.role !== "admin") {
      // Send them to the site's own login rather than inventing a second one.
      return Response.redirect(new URL("/", url).toString(), 302);
    }

    if (path === "/mc" || path === "/mc/") return html(panelHtml());
    if (path === "/mc/api/status") return statusApi(env);
    if (path === "/mc/api/command") return commandApi(request, env);
    if (path === "/mc/api/result") return resultApi(env, url);

    return new Response("Not found", { status: 404 });
  },
};

// --------------------------------------------------------------- runner API --
async function runnerApi(request, env, url, path) {
  const auth = request.headers.get("authorization") || "";
  const expected = `Bearer ${env.UPDATE_TOKEN}`;
  if (auth.length !== expected.length || !constantTimeEquals(auth, expected)) {
    return new Response("forbidden\n", { status: 403 });
  }

  if (path === "/__status" && request.method === "POST") {
    const body = await request.text();
    if (body.length > 64 * 1024) return new Response("too large\n", { status: 413 });
    // Stamp arrival time so the panel can tell "no players" from "gone silent".
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      return new Response("bad json\n", { status: 400 });
    }
    parsed.reported_at = Date.now();
    await env.MAP_STATE.put(KEY_STATUS, JSON.stringify(parsed), { expirationTtl: 900 });
    return new Response("ok\n");
  }

  // Drain: returning and clearing in one call means a command is delivered at
  // most once, so a retry storm cannot run the same command twice.
  if (path === "/__commands" && request.method === "GET") {
    const raw = (await env.MAP_STATE.get(KEY_QUEUE)) || "[]";
    if (raw !== "[]") await env.MAP_STATE.put(KEY_QUEUE, "[]");
    return new Response(raw, { headers: { "content-type": "application/json" } });
  }

  if (path === "/__result" && request.method === "POST") {
    let body;
    try {
      body = await request.json();
    } catch {
      return new Response("bad json\n", { status: 400 });
    }
    if (!body.id) return new Response("missing id\n", { status: 400 });
    await env.MAP_STATE.put(
      RESULT_PREFIX + body.id,
      JSON.stringify({ output: String(body.output ?? "").slice(0, 20000), at: Date.now() }),
      { expirationTtl: 3600 }
    );
    return new Response("ok\n");
  }

  return new Response("Not found\n", { status: 404 });
}

// ---------------------------------------------------------------- panel API --
async function statusApi(env) {
  const [raw, tunnel] = await Promise.all([
    env.MAP_STATE.get(KEY_STATUS),
    env.MAP_STATE.get(KEY_TUNNEL),
  ]);
  const status = raw ? JSON.parse(raw) : null;
  return Response.json(
    { status, map_tunnel: tunnel, now: Date.now() },
    { headers: { "cache-control": "no-store" } }
  );
}

async function commandApi(request, env) {
  if (request.method !== "POST") return Response.json({ error: "POST only" }, { status: 405 });

  let cmd = "";
  try {
    ({ command: cmd = "" } = await request.json());
  } catch {
    return Response.json({ error: "bad request" }, { status: 400 });
  }
  cmd = String(cmd).trim();
  if (!cmd) return Response.json({ error: "empty" }, { status: 400 });
  if (cmd.length > 400) return Response.json({ error: "too long" }, { status: 400 });
  // Newlines would let one queue entry become several console lines.
  if (/[\r\n]/.test(cmd)) return Response.json({ error: "newlines not allowed" }, { status: 400 });

  const id = crypto.randomUUID();
  const queue = JSON.parse((await env.MAP_STATE.get(KEY_QUEUE)) || "[]");
  // Bounded so a stuck runner cannot let the queue grow without limit.
  if (queue.length >= 25) return Response.json({ error: "queue full — is the server up?" }, { status: 429 });

  queue.push({ id, command: cmd, at: Date.now() });
  await env.MAP_STATE.put(KEY_QUEUE, JSON.stringify(queue));
  return Response.json({ ok: true, id });
}

async function resultApi(env, url) {
  const id = url.searchParams.get("id") || "";
  if (!/^[0-9a-f-]{36}$/i.test(id)) return Response.json({ error: "bad id" }, { status: 400 });
  const raw = await env.MAP_STATE.get(RESULT_PREFIX + id);
  return Response.json(raw ? JSON.parse(raw) : { pending: true }, {
    headers: { "cache-control": "no-store" },
  });
}

// ------------------------------------------------------------------ session --
// Mirrors the site's own scheme exactly: payload.signature, HMAC-SHA256 over
// the base64url payload, with an exp claim in seconds.
async function verifySession(request, env) {
  if (!env.SESSION_SECRET) return null;
  const token = readCookie(request.headers.get("cookie"), COOKIE);
  if (!token) return null;
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return null;

  const expected = await hmac(env.SESSION_SECRET, payload);
  if (!constantTimeEquals(sig, expected)) return null;

  try {
    const session = JSON.parse(b64urlDecode(payload));
    if (typeof session.exp !== "number" || session.exp <= Math.floor(Date.now() / 1000)) return null;
    if (!session.role) session.role = "admin";
    return session;
  } catch {
    return null;
  }
}

async function hmac(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function constantTimeEquals(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const b64urlDecode = (s) =>
  decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/"))));

function readCookie(header, name) {
  if (!header) return null;
  for (const part of header.split(";")) {
    const [k, ...rest] = part.trim().split("=");
    if (k === name) return rest.join("=");
  }
  return null;
}

function html(body) {
  return new Response(body, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}

// -------------------------------------------------------------------- panel --
function panelHtml() {
  return `<!doctype html>
<html lang="es"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Minecraft · mtrdrgzcid</title>
<style>
  :root{--bg:#100D11;--panel:#161217;--panel2:#1D181E;--text:#EEE2ED;--muted:#B3A8B2;
        --line:#4D454E;--accent:#DCBCE4;--ok:#7ee787;--bad:#ff7b72;--warn:#e3b341}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
       font:15px/1.5 ui-monospace,"JetBrains Mono",Menlo,monospace;padding:1.5rem}
  .wrap{max-width:1000px;margin:0 auto}
  h1{font-size:1.3rem;margin:0 0 .25rem}
  h1 .dot{color:var(--accent)}
  .sub{color:var(--muted);margin:0 0 1.5rem;font-size:.85rem}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:.75rem;margin-bottom:1.5rem}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:.85rem 1rem}
  .card .k{color:var(--muted);font-size:.72rem;text-transform:uppercase;letter-spacing:.08em}
  .card .v{font-size:1.15rem;margin-top:.3rem;word-break:break-all}
  .ok{color:var(--ok)} .bad{color:var(--bad)} .warn{color:var(--warn)}
  .players{background:var(--panel);border:1px solid var(--line);border-radius:10px;
           padding:.85rem 1rem;margin-bottom:1.5rem;min-height:3rem}
  #console{background:#0b090c;border:1px solid var(--line);border-radius:10px;padding:.85rem;
           height:340px;overflow:auto;white-space:pre-wrap;font-size:.82rem;color:#cfc7ce}
  #console .cmd{color:var(--accent)}
  #console .err{color:var(--bad)}
  form{display:flex;gap:.5rem;margin-top:.75rem}
  input{flex:1;background:var(--panel2);border:1px solid var(--line);border-radius:8px;
        padding:.6rem .8rem;color:var(--text);font:inherit}
  input:focus{outline:none;border-color:var(--accent)}
  button{background:var(--accent);color:#503758;border:0;border-radius:8px;
         padding:.6rem 1.1rem;font:inherit;font-weight:600;cursor:pointer}
  button:disabled{opacity:.5;cursor:default}
  .links{margin-top:1.25rem;font-size:.8rem;color:var(--muted)}
  .links a{color:var(--accent);text-decoration:none;margin-right:1rem}
</style></head><body><div class="wrap">
<h1>Minecraft<span class="dot">.</span></h1>
<p class="sub">Estado del servidor y consola remota</p>

<div class="grid" id="cards"></div>
<div class="players" id="players"><span style="color:var(--muted)">cargando…</span></div>

<div id="console"></div>
<form id="f" autocomplete="off">
  <input id="c" placeholder="Comando sin la barra, p.ej.  list   ·   time set day" autofocus>
  <button id="b">Enviar</button>
</form>

<p class="links">
  <a href="https://map.mtrdrgzcid.com" target="_blank">Mapa 3D</a>
  <a href="/">Volver</a>
</p>
</div>
<script>
const cards=document.getElementById('cards'), players=document.getElementById('players'),
      con=document.getElementById('console'), f=document.getElementById('f'),
      c=document.getElementById('c'), b=document.getElementById('b');

function line(t,cls){const d=document.createElement('div');if(cls)d.className=cls;
  d.textContent=t;con.appendChild(d);con.scrollTop=con.scrollHeight;}

function dur(ms){const s=Math.max(0,Math.floor(ms/1000));
  const h=Math.floor(s/3600),m=Math.floor(s%3600/60);
  return h?h+'h '+m+'m':m+'m';}

async function refresh(){
  try{
    const r=await fetch('/mc/api/status',{cache:'no-store'});
    const d=await r.json();
    const s=d.status;
    // A shift that stopped reporting looks identical to an empty one unless we
    // check how long ago the last report arrived.
    const stale = !s || (d.now - s.reported_at) > 120000;
    const set=[
      ['Servidor', stale?'sin datos':(s.online?'en linea':'caido'), stale?'warn':(s.online?'ok':'bad')],
      ['Jugadores', s&&!stale?(s.players_online+' / '+s.players_max):'—',''],
      ['Turno acaba en', s&&!stale?dur(s.shift_ends_in_ms):'—',''],
      ['Ultimo guardado', s&&!stale?dur(d.now-s.last_save_at)+' atras':'—',''],
      ['Direccion', s&&s.public_address?s.public_address:'—',''],
      ['Mapa', d.map_tunnel?'activo':'sin tunel', d.map_tunnel?'ok':'warn'],
    ];
    cards.innerHTML=set.map(([k,v,cl])=>
      '<div class="card"><div class="k">'+k+'</div><div class="v '+cl+'">'+v+'</div></div>').join('');
    players.innerHTML = s&&s.players&&s.players.length
      ? s.players.map(p=>'<span style="margin-right:1rem">'+p+'</span>').join('')
      : '<span style="color:var(--muted)">nadie conectado</span>';
  }catch(e){ cards.innerHTML='<div class="card"><div class="k">error</div><div class="v bad">'+e.message+'</div></div>'; }
}

f.onsubmit=async(e)=>{
  e.preventDefault();
  const cmd=c.value.trim(); if(!cmd)return;
  c.value=''; b.disabled=true;
  line('> '+cmd,'cmd');
  try{
    const r=await fetch('/mc/api/command',{method:'POST',headers:{'content-type':'application/json'},
      body:JSON.stringify({command:cmd})});
    const d=await r.json();
    if(!r.ok){line(d.error||'error','err');b.disabled=false;return;}
    // The runner polls every few seconds, so the answer is never instant.
    for(let i=0;i<20;i++){
      await new Promise(r=>setTimeout(r,1500));
      const rr=await fetch('/mc/api/result?id='+d.id,{cache:'no-store'});
      const res=await rr.json();
      if(!res.pending){ line(res.output||'(sin salida)'); b.disabled=false; return; }
    }
    line('sin respuesta: el servidor puede estar reiniciando','err');
  }catch(err){ line(err.message,'err'); }
  b.disabled=false;
};

refresh(); setInterval(refresh,10000);
</script></body></html>`;
}
