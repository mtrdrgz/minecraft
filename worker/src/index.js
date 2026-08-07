/**
 * Reverse proxy that keeps map.mtrdrgzcid.com pointing at a moving target.
 *
 * BlueMap runs on an ephemeral GitHub Actions runner behind a Cloudflare quick
 * tunnel, which is handed a brand new *.trycloudflare.com hostname every time it
 * starts — and the server restarts every ~5.4 hours.
 *
 * Two things rule out the simpler approaches:
 *   - A CNAME cannot work: trycloudflare vhosts strictly on the Host header, so
 *     a request arriving as map.mtrdrgzcid.com gets a 403.
 *   - An Origin Rule cannot work either: rewriting Host there is a paid
 *     feature, and Cloudflare answers "not entitled to use the HostHeader
 *     override" on a Free zone.
 *
 * So this Worker does the rewrite instead. It reads the current tunnel hostname
 * from KV and forwards each request with the Host the tunnel expects. DNS never
 * changes, so nothing downstream can cache a dead value.
 */

const KEY = "tunnel_host";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/__set") return setEndpoint(request, env, url);
    if (url.pathname === "/__status") return status(env);

    const host = await env.MAP_STATE.get(KEY, { cacheTtl: 30 });
    if (!host) return offline("The map has not reported an address yet.");

    const target = new URL(request.url);
    target.hostname = host;
    target.protocol = "https:";
    target.port = "";

    // The Host header is the whole point: the tunnel refuses anything else.
    const headers = new Headers(request.headers);
    headers.set("Host", host);
    // Let the origin negotiate its own encoding rather than forwarding ours.
    headers.delete("accept-encoding");

    // Measured: a single hop from this Worker to the quick tunnel fails with 530
    // about half the time, while the same request sent directly from a browser
    // succeeds every time. The tunnel is fine — the flakiness is on the
    // Worker-to-tunnel leg, most likely because a quick tunnel registers with a
    // couple of Cloudflare colos and a Worker can run anywhere. Retrying turns a
    // ~50% hop into a reliable one; three attempts leave roughly a 1-in-8 chance
    // of a visible failure, and a fourth makes it 1-in-16.
    const RETRYABLE = new Set([502, 503, 520, 521, 522, 523, 524, 530]);
    const idempotent = request.method === "GET" || request.method === "HEAD";
    const attempts = idempotent ? 4 : 1;

    let upstream = null;
    let lastError = null;

    for (let i = 0; i < attempts; i++) {
      try {
        upstream = await fetch(target.toString(), {
          method: request.method,
          headers,
          body: idempotent ? undefined : request.body,
          redirect: "manual",
        });
        if (!RETRYABLE.has(upstream.status)) break;
        lastError = `HTTP ${upstream.status}`;
      } catch (err) {
        lastError = err.message;
        upstream = null;
      }
      // Short backoff; the failure is a routing miss, not congestion.
      if (i < attempts - 1) await new Promise((r) => setTimeout(r, 150 * (i + 1)));
    }

    if (!upstream) {
      // Usually the shift ended: the tunnel is gone but KV still holds its
      // hostname until the next shift reports in.
      return offline(`The map server is not reachable right now (${lastError}).`);
    }

    if (upstream.status === 403) {
      // trycloudflare's answer to an unknown vhost. Means KV is stale.
      return offline("The map address is stale; it should recover within a few minutes.");
    }

    if (RETRYABLE.has(upstream.status)) {
      return offline(`The map server did not answer after ${attempts} attempts (${lastError}).`);
    }

    const out = new Headers(upstream.headers);
    out.delete("content-security-policy");
    out.set("x-map-origin", host);
    return new Response(upstream.body, { status: upstream.status, headers: out });
  },
};

async function setEndpoint(request, env, url) {
  if (request.method !== "POST") return new Response("POST only\n", { status: 405 });

  const auth = request.headers.get("authorization") || "";
  const expected = `Bearer ${env.UPDATE_TOKEN}`;
  // Length check first so the comparison below is over equal-length strings.
  if (auth.length !== expected.length || !timingSafeEqual(auth, expected)) {
    return new Response("forbidden\n", { status: 403 });
  }

  const host = url.searchParams.get("host");
  if (!host || !/^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(host)) {
    return new Response("bad host\n", { status: 400 });
  }

  await env.MAP_STATE.put(KEY, host);
  return new Response(`ok ${host}\n`);
}

async function status(env) {
  const host = await env.MAP_STATE.get(KEY);
  return Response.json({ tunnel_host: host || null });
}

function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const ba = enc.encode(a);
  const bb = enc.encode(b);
  if (ba.byteLength !== bb.byteLength) return false;
  return crypto.subtle.timingSafeEqual
    ? crypto.subtle.timingSafeEqual(ba, bb)
    : ba.every((v, i) => v === bb[i]);
}

function offline(detail) {
  const body = `<!doctype html>
<meta charset="utf-8">
<title>Map unavailable</title>
<style>
  body{font-family:system-ui,sans-serif;background:#0d1117;color:#c9d1d9;
       display:grid;place-items:center;height:100vh;margin:0;text-align:center}
  p{color:#8b949e;max-width:34rem;line-height:1.5}
  code{background:#161b22;padding:.15rem .4rem;border-radius:4px}
</style>
<div>
  <h1>The map is offline</h1>
  <p>${detail}</p>
  <p>The Minecraft server restarts roughly every 5 hours; the map comes back a
     few minutes after each restart. The game server itself is unaffected —
     it is on <code>minecraft.mtrdrgzcid.com</code>.</p>
</div>`;
  return new Response(body, {
    status: 503,
    headers: { "content-type": "text/html; charset=utf-8", "retry-after": "120" },
  });
}
