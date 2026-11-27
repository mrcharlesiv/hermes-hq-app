#!/usr/bin/env python3
"""A throwaway stand-in for a Hermes gateway's sign-in surface, for Simulator sign-in checks.

Never talks to a real gateway. It generates a one-off username and password per run and writes
them (0600) to --credentials; nothing secret is printed. It answers:

  GET  /api/auth/providers       one password provider (none with --no-password)
  POST /auth/password-login      sets an HMAC-free random session cookie on a match, else 401
  GET  /api/auth/me              200 with the cookie, else 401
  POST /api/auth/ws-ticket       a random ticket with the cookie, else 401
  GET  /api/ws                   a WebSocket that answers every JSON-RPC request with -32601
  GET  /api/fs/download?path=    with --media-dir: a file under it, honouring Range like the gateway's
                                 FileResponse (206 + Content-Range), for playback checks
  anything else under /api/      404 {"detail": "not in this fake"}

Each request's method and path (no query, headers or body) is appended to --log, so a test
can count what a launch asked for (a warm restore must be exactly one /api/auth/me).
--delay-auth makes every sign-in request slow; --keep-credentials restarts with the same account
(its sessions are gone, as after a gateway restart).

--hermes-cookies issues Hermes' basic-auth session instead (P2-3 checks): hermes_session_at (an access token
of --access-ttl seconds) and hermes_session_rt (a 30-day refresh token). As Hermes' auth middleware does, a
request whose access token has lapsed is served on its refresh token, and the response sets a fresh pair;
the older refresh token stays valid (stateless tokens: one client renewing never signs another out). With
neither valid it answers 401 and clears both. Fixture-only routes, never under /api/:
  GET  /__fixture/auth           counts: logins, password posts, refreshes, rejected sessions
  POST /__fixture/expire-access  lapse every access token (the next request renews)
  POST /__fixture/revoke         invalidate every session (a refused session)

  python3 scripts/native-startup/fake-gateway.py --port 9331 --credentials /tmp/x.json --log /tmp/x.log
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import socket
import struct
import sys
import mimetypes
import threading
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Gateway:
    def __init__(self, username: str, password: str, passwords: bool, log: str | None, media: str | None = None, delay: float = 0,
                 hermes: bool = False, access_ttl: int = 12 * 60 * 60):
        self.username, self.password, self.passwords, self.log, self.media, self.delay = username, password, passwords, log, media, delay
        self.sessions: set[str] = set()
        self.lock = threading.Lock()
        self.hermes, self.access_ttl = hermes, access_ttl
        self.access: dict[str, float] = {}
        self.refresh: dict[str, float] = {}
        self.counts = {"logins": 0, "passwordPosts": 0, "refreshes": 0, "rejected": 0}

    def issue(self) -> list[str]:
        """A fresh access and refresh token, as Set-Cookie values."""
        now = time.time()
        at, rt = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
        with self.lock:
            self.access[at] = now + self.access_ttl
            self.refresh[rt] = now + 30 * 24 * 60 * 60
        return [f"hermes_session_at={at}; Max-Age={self.access_ttl}; Path=/; HttpOnly; SameSite=Lax",
                f"hermes_session_rt={rt}; Max-Age={30 * 24 * 60 * 60}; Path=/; HttpOnly; SameSite=Lax"]

    CLEAR = ["hermes_session_at=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax", "hermes_session_rt=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax"]

    def record(self, method: str, path: str):
        if self.delay and "/auth/" in path:
            time.sleep(self.delay)  # A slow or busy gateway (restore deadline checks).
        if self.log:
            with self.lock, open(self.log, "a", encoding="utf-8") as handle:
                handle.write(f"{method} {path.split('?')[0]}\n")


def websocket(connection: socket.socket, key: str):
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())

    def read(count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                raise ConnectionError
            data += chunk
        return data

    def send(payload: dict):
        body = json.dumps(payload).encode()
        header = bytes([0x81]) + (bytes([len(body)]) if len(body) < 126 else bytes([126]) + struct.pack(">H", len(body)) if len(body) < 65536 else bytes([127]) + struct.pack(">Q", len(body)))
        connection.sendall(header + body)

    try:
        while True:
            first, second = read(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                length = struct.unpack(">H", read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", read(8))[0]
            mask = read(4) if second & 0x80 else b"\0\0\0\0"
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(read(length)))
            if opcode == 8:
                connection.sendall(b"\x88\x00")
                return
            if opcode == 9:
                connection.sendall(bytes([0x8A, len(data)]) + data)
                continue
            try:
                message = json.loads(data)
            except ValueError:
                continue
            if isinstance(message, dict) and "id" in message and "method" in message:
                send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "not in this fake gateway"}})
    except ConnectionError:
        return
    except Exception as error:   # The app only sees WebSocketException when this loop ends; stderr says why (WIN-29). The app hanging up is quiet.
        print(f'[ws] socket loop ended: {type(error).__name__}: {error}', file=sys.stderr)
        traceback.print_exc(file=sys.stderr); sys.stderr.flush()


def handler(gateway: Gateway):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        set_cookies: list[str] = []

        def end_headers(self):
            # Hermes mode: whatever this request renewed or cleared goes out with its answer (REST or upgrade).
            for value in self.set_cookies:
                self.send_header("Set-Cookie", value)
            self.set_cookies = []
            super().end_headers()

        def reply(self, status: int, body: dict | None = None, cookie: str | None = None):
            data = json.dumps(body if body is not None else {}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            if cookie and not gateway.hermes:
                self.send_header("Set-Cookie", f"fake_session={cookie}; Path=/; HttpOnly; SameSite=Lax")
            self.end_headers()
            self.wfile.write(data)

        def cookies(self) -> dict[str, str]:
            found = {}
            for part in (self.headers.get("Cookie") or "").split(";"):
                name, _, value = part.strip().partition("=")
                if name:
                    found[name] = value
            return found

        def session(self) -> bool:
            jar = self.cookies()
            if not gateway.hermes:
                return jar.get("fake_session") in gateway.sessions
            now = time.time()
            at, rt = jar.get("hermes_session_at"), jar.get("hermes_session_rt")
            if at and gateway.access.get(at, 0) > now:
                return True
            if rt and gateway.refresh.get(rt, 0) > now:
                # Served on the refresh token, with a fresh pair on this response; the old one stays valid.
                self.set_cookies = gateway.issue()
                with gateway.lock:
                    gateway.counts["refreshes"] += 1
                return True
            if at or rt:
                self.set_cookies = list(Gateway.CLEAR)
                with gateway.lock:
                    gateway.counts["rejected"] += 1
            return False

        def do_GET(self):
            gateway.record("GET", self.path)
            path = self.path.split("?")[0]
            if path == "/__fixture/auth":
                with gateway.lock:
                    return self.reply(200, dict(gateway.counts))
            if path == "/api/auth/providers":
                return self.reply(200, {"providers": [{"name": "fake", "supports_password": gateway.passwords}]})
            if path == "/api/auth/me":
                return self.reply(200, {"username": gateway.username}) if self.session() else self.reply(401, {"detail": "unauthorized"})
            if path == "/api/fs/download" and gateway.media:
                return self.media() if self.session() else self.reply(401, {"detail": "unauthorized"})
            if path == "/api/ws" and (self.headers.get("Upgrade") or "").lower() == "websocket":
                if not self.session() and "ticket=" not in self.path:
                    return self.reply(401, {"detail": "unauthorized"})
                websocket(self.connection, self.headers["Sec-WebSocket-Key"])
                self.close_connection = True
                return
            return self.reply(404, {"detail": "not in this fake"}) if path.startswith("/api/") else self.reply(404, {"detail": "not found"})

        def media(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            root = os.path.realpath(gateway.media)
            target = os.path.realpath(query.get("path", [""])[0])
            if not target.startswith(root + os.sep) or not os.path.isfile(target):
                return self.reply(404, {"detail": "File not found"})
            size = os.path.getsize(target)
            start, end, status = 0, size - 1, 200
            spec = (self.headers.get("Range") or "").partition("=")[2].split(",")[0].strip()
            if spec:
                first, _, last = spec.partition("-")
                start, end = (max(0, size - int(last)), size - 1) if first == "" else (int(first), min(int(last) if last else size - 1, size - 1))
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                status = 206
            self.send_response(status)
            self.send_header("Content-Type", mimetypes.guess_type(target)[0] or "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            with open(target, "rb") as handle:
                handle.seek(start)
                left = end - start + 1
                try:
                    while left > 0:
                        block = handle.read(min(left, 262144))
                        if not block:
                            break
                        self.wfile.write(block)
                        left -= len(block)
                except (BrokenPipeError, ConnectionResetError):
                    self.close_connection = True

        def do_POST(self):
            gateway.record("POST", self.path)
            path = self.path.split("?")[0]
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if path == "/auth/password-login":
                try:
                    payload = json.loads(body or b"{}")
                except ValueError:
                    payload = {}
                with gateway.lock:
                    gateway.counts["passwordPosts"] += 1
                if gateway.passwords and payload.get("username") == gateway.username and payload.get("password") == gateway.password:
                    token = secrets.token_urlsafe(24)
                    gateway.sessions.add(token)
                    if gateway.hermes:
                        self.set_cookies = gateway.issue()
                    with gateway.lock:
                        gateway.counts["logins"] += 1
                    return self.reply(200, {"ok": True}, cookie=token)
                return self.reply(401, {"detail": "invalid credentials"})
            if path == "/__fixture/expire-access":
                with gateway.lock:
                    gateway.access.clear()
                return self.reply(200, {"ok": True})
            if path == "/__fixture/revoke":
                with gateway.lock:
                    gateway.access.clear(); gateway.refresh.clear(); gateway.sessions.clear()
                return self.reply(200, {"ok": True})
            if path == "/api/auth/ws-ticket":
                return self.reply(200, {"ticket": secrets.token_urlsafe(16)}) if self.session() else self.reply(401, {"detail": "unauthorized"})
            if path == "/auth/logout":
                return self.reply(200, {"ok": True})
            return self.reply(404, {"detail": "not in this fake"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9331)
    parser.add_argument("--credentials", required=True, help="where to write the one-off username/password (0600)")
    parser.add_argument("--log")
    parser.add_argument("--no-password", action="store_true")
    parser.add_argument("--media-dir", help="serve files under this directory at /api/fs/download (playback checks)")
    parser.add_argument("--delay-auth", type=float, default=0, help="seconds before answering each sign-in request (a slow gateway)")
    parser.add_argument("--keep-credentials", action="store_true", help="reuse --credentials if it exists (a restarted gateway, same account)")
    parser.add_argument("--hermes-cookies", action="store_true", help="issue Hermes' hermes_session_at/rt session (P2-3 checks)")
    parser.add_argument("--access-ttl", type=int, default=12 * 60 * 60, help="access-token seconds with --hermes-cookies")
    args = parser.parse_args()
    if args.keep_credentials and os.path.exists(args.credentials):
        with open(args.credentials, encoding="utf-8") as handle:
            kept = json.load(handle)
        username, password = kept["username"], kept["password"]
    else:
        username, password = "fake-" + secrets.token_hex(3), secrets.token_urlsafe(12)
        descriptor = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            json.dump({"username": username, "password": password}, handle)
    server = ThreadingHTTPServer((args.host, args.port), handler(Gateway(username, password, not args.no_password, args.log, args.media_dir, args.delay_auth, args.hermes_cookies, args.access_ttl)))
    print(f"fake gateway on {args.host}:{args.port} (credentials in {args.credentials})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
