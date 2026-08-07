#!/usr/bin/env python3
"""Minecraft Server List Ping against a public address.

Used as a liveness probe for the relay, not the server: the JVM can be perfectly
healthy while the e4mc tunnel behind it has silently dropped, in which case the
relay answers "Unknown server. Check address and try again." and players cannot
join. A local RCON check cannot see that.

  mcping.py <host> [port]

Exit 0 if a real Minecraft server answered, 1 otherwise. Prints the MOTD.
"""
import json
import socket
import struct
import sys


def varint(n: int) -> bytes:
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def read_varint(sock: socket.socket) -> int:
    n = shift = 0
    while True:
        c = sock.recv(1)
        if not c:
            raise EOFError("socket closed")
        b = c[0]
        n |= (b & 0x7F) << shift
        if not b & 0x80:
            return n
        shift += 7


def packet(pid: int, payload: bytes = b"") -> bytes:
    body = varint(pid) + payload
    return varint(len(body)) + body


def main() -> int:
    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 25565

    try:
        sock = socket.create_connection((host, port), timeout=15)
    except OSError as exc:
        print(f"unreachable: {exc}", file=sys.stderr)
        return 1

    with sock:
        addr = host.encode()
        # Protocol 767 = MC 1.21.1. next_state 1 = status.
        # The hostname in this handshake is what e4mc's relay routes on, so it
        # must be the relay domain, not our vanity domain.
        sock.sendall(packet(0x00, varint(767) + varint(len(addr))
                            + addr + struct.pack(">H", port) + varint(1)))
        sock.sendall(packet(0x00))
        try:
            read_varint(sock)          # frame length
            read_varint(sock)          # packet id
            n = read_varint(sock)
            buf = b""
            while len(buf) < n:
                chunk = sock.recv(n - len(buf))
                if not chunk:
                    break
                buf += chunk
            data = json.loads(buf.decode("utf8"))
        except Exception as exc:
            print(f"bad response: {type(exc).__name__}: {exc}", file=sys.stderr)
            return 1

    desc = data.get("description")
    if isinstance(desc, dict):
        desc = desc.get("text") or "".join(x.get("text", "") for x in desc.get("extra", []))

    # The relay answers the handshake even when it has no session for this
    # hostname, reporting protocol -1. That is a dead tunnel, not a live server.
    proto = data.get("version", {}).get("protocol", -1)
    if proto == -1:
        print(f"relay has no session: {desc}", file=sys.stderr)
        return 1

    players = data.get("players", {})
    print(f"{data.get('version', {}).get('name')} | {desc} | "
          f"{players.get('online')}/{players.get('max')} players")
    return 0


if __name__ == "__main__":
    sys.exit(main())
