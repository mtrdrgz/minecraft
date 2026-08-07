#!/usr/bin/env python3
"""Mirror the deployed mtrdrgzcid.com assets back into a source tree.

Why this exists: the live site's Worker source is in no repository and on no
machine — only the deployed bundle survives — and its pages live in an ASSETS
binding, which cannot be downloaded from a deployed Worker. If that Worker is
ever deleted, the site is gone. This pulls the pages back over HTTP so the
project can be reconstructed in Git.

The password is read from a hidden prompt, used once to obtain a session cookie,
and never written to disk, printed, or passed as an argument (so it cannot land
in shell history or a process listing).

  python tools/mirror-site.py <output-dir>
"""
import getpass
import http.cookiejar
import json
import os
import re
import sys
import urllib.parse
import urllib.request

BASE = "https://mtrdrgzcid.com"

# Pages the Worker serves from the ASSETS binding. hub and admin need a session;
# the rest are public.
PAGES = {
    "/": "login-or-hub.html",
    "/admin": "admin.html",
    "/play?game=terraria": "play.html",
}
ASSETS = [
    "/assets/style.css",
    "/assets/i18n.js",
    "/favicon.svg",
]


def build_opener():
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar)), jar


def fetch(opener, path, binary=False):
    req = urllib.request.Request(
        BASE + path,
        headers={"User-Agent": "mtrdrgzcid-mirror/1.0"},
    )
    with opener.open(req, timeout=30) as r:
        data = r.read()
    return data if binary else data.decode("utf-8", "replace")


def main() -> int:
    out = sys.argv[1] if len(sys.argv) > 1 else "site-mirror"
    os.makedirs(out, exist_ok=True)

    opener, jar = build_opener()

    # getpass silently returns "" on some Windows consoles, which then looks
    # like a wrong password. Detect that instead of reporting a bogus 401.
    print("Contraseña de mtrdrgzcid.com (no se muestra ni se guarda):")
    try:
        password = getpass.getpass("  > ")
    except Exception as exc:
        print(f"  el prompt oculto fallo ({exc}); usando entrada visible")
        password = input("  > ")
    password = password.strip()
    if not password:
        print("  no se leyo ninguna contraseña. Si tu terminal no soporta el", file=sys.stderr)
        print("  prompt oculto, ejecuta el script desde PowerShell o cmd.", file=sys.stderr)
        return 2

    body = json.dumps({"password": password}).encode()
    req = urllib.request.Request(
        BASE + "/api/login",
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": "mtrdrgzcid-mirror/1.0"},
        method="POST",
    )
    try:
        with opener.open(req, timeout=30) as r:
            resp = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:200]
        print(f"  login rechazado: HTTP {e.code} {detail}", file=sys.stderr)
        if e.code == 401:
            print("  -> la contraseña no coincide con SITE_PASSWORD", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"  no se pudo contactar con el sitio: {type(e).__name__}: {e}", file=sys.stderr)
        return 1
    finally:
        del password  # not that it helps much, but do not keep it around

    role = resp.get("role")
    print(f"  sesión iniciada como: {role}")
    if role != "admin":
        print("  AVISO: sin rol admin no se puede descargar admin.html", file=sys.stderr)

    saved = 0
    for path, name in PAGES.items():
        try:
            text = fetch(opener, path)
        except Exception as exc:
            print(f"  x {path}: {exc}")
            continue
        # The page served at / depends on the session; name it for what it is.
        if path == "/":
            name = "hub.html" if "login-wrap" not in text else "login.html"
        with open(os.path.join(out, name), "w", encoding="utf-8") as f:
            f.write(text)
        print(f"  ✓ {path}  ->  {name}  ({len(text)} bytes)")
        saved += 1

    # Log out and grab the unauthenticated page too, so both are captured.
    try:
        urllib.request.Request(BASE + "/api/logout", method="POST")
        opener.open(urllib.request.Request(BASE + "/api/logout", method="POST"), timeout=20)
        text = fetch(opener, "/")
        with open(os.path.join(out, "login.html"), "w", encoding="utf-8") as f:
            f.write(text)
        print(f"  ✓ /  (sin sesión)  ->  login.html  ({len(text)} bytes)")
        saved += 1
    except Exception as exc:
        print(f"  x login.html: {exc}")

    for path in ASSETS:
        try:
            data = fetch(opener, path, binary=True)
        except Exception as exc:
            print(f"  x {path}: {exc}")
            continue
        dest = os.path.join(out, path.lstrip("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        print(f"  ✓ {path}  ({len(data)} bytes)")
        saved += 1

    # A static assets binding cannot be listed over HTTP, so completeness has to
    # be inferred: pull every same-origin URL referenced by what we already have,
    # plus the cover art the hub composes by convention rather than by link.
    referenced = set()
    for name in ("hub.html", "admin.html", "play.html", "login.html",
                 "assets/style.css", "assets/i18n.js"):
        fp = os.path.join(out, name)
        if not os.path.exists(fp):
            continue
        text = open(fp, encoding="utf-8", errors="replace").read()
        referenced.update(re.findall(r"""["'(](/[A-Za-z0-9_./-]+\.[A-Za-z0-9]{2,5})["')]""", text))
        for m in re.findall(r"url\((/[^)]+)\)", text):
            referenced.add(m.strip("\"'"))

    for slug in ("hollow-knight", "silksong", "stardew", "terraria", "celeste"):
        referenced.add(f"/art/{slug}.jpg")
        referenced.add(f"/art/{slug}.png")

    already = {
        "/" + os.path.relpath(os.path.join(r, f), out).replace(os.sep, "/")
        for r, _, fs in os.walk(out) for f in fs
    }
    todo = sorted(x for x in referenced if x not in already and not x.startswith("//"))

    print(f"\ncomprobando {len(todo)} rutas referenciadas...")
    for path in todo:
        try:
            data = fetch(opener, path, binary=True)
        except Exception:
            continue                       # a 404 or redirect just means it is absent
        if not data:
            continue
        dest = os.path.join(out, path.lstrip("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        print(f"  + {path}  ({len(data)} bytes)")
        saved += 1

    print(f"\n{saved} ficheros en {out}/")
    print("La contraseña no se ha escrito en disco ni en el historial.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
