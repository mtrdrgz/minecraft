#!/usr/bin/env python3
"""Minimal Minecraft RCON client.

Exists so the workflow has no dependency on a distro package or a third-party
release for something this small. Reads the password from RCON_PASSWORD.

  rcon.py "save-all flush"
  rcon.py "say hello" "list"

Exit codes: 0 ok, 1 protocol/auth failure, 2 connection failure.
"""
import os
import socket
import struct
import sys
import time

HOST = os.environ.get("RCON_HOST", "127.0.0.1")
PORT = int(os.environ.get("RCON_PORT", "25575"))
PASSWORD = os.environ.get("RCON_PASSWORD", "")

TYPE_AUTH = 3
TYPE_AUTH_RESPONSE = 2
TYPE_COMMAND = 2
TYPE_RESPONSE = 0


def encode(req_id: int, req_type: int, body: str) -> bytes:
    payload = struct.pack("<ii", req_id, req_type) + body.encode("utf8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def read_exactly(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed mid-packet")
        buf += chunk
    return buf


def read_packet(sock: socket.socket):
    (length,) = struct.unpack("<i", read_exactly(sock, 4))
    payload = read_exactly(sock, length)
    req_id, req_type = struct.unpack("<ii", payload[:8])
    # Trailing two NUL bytes are padding, not part of the body.
    return req_id, req_type, payload[8:-2].decode("utf8", "replace")


def main() -> int:
    commands = sys.argv[1:]
    if not commands:
        print("usage: rcon.py <command> [command ...]", file=sys.stderr)
        return 1
    if not PASSWORD:
        print("RCON_PASSWORD is not set", file=sys.stderr)
        return 1

    # The server opens the RCON port a little after the process starts, so a
    # short connect retry keeps callers from having to sleep defensively.
    deadline = time.time() + float(os.environ.get("RCON_CONNECT_TIMEOUT", "10"))
    sock = None
    while True:
        try:
            sock = socket.create_connection((HOST, PORT), timeout=10)
            break
        except OSError as exc:
            if time.time() >= deadline:
                print(f"cannot connect to {HOST}:{PORT}: {exc}", file=sys.stderr)
                return 2
            time.sleep(0.5)

    with sock:
        sock.settimeout(30)
        sock.sendall(encode(1, TYPE_AUTH, PASSWORD))
        req_id, req_type, _ = read_packet(sock)
        # Some servers emit an empty RESPONSE packet before the auth result.
        if req_type == TYPE_RESPONSE:
            req_id, req_type, _ = read_packet(sock)
        if req_id == -1:
            print("RCON authentication failed", file=sys.stderr)
            return 1

        for i, cmd in enumerate(commands, start=2):
            sock.sendall(encode(i, TYPE_COMMAND, cmd))
            _, _, body = read_packet(sock)
            if body.strip():
                print(body.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
