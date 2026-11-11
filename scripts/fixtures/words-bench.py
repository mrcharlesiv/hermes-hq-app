#!/usr/bin/env python3
"""Stand-in server for -HQDebugWordsBench (App/Debug/WordsBenchHook.swift): serves a folder's WAVs to the sandboxed
Mac app and keeps what it heard. Usage: words-bench.py <folder of 16 kHz mono WAVs> [port]. Writes status.txt and
out.json into that folder."""
import http.server, os, sys

folder, port = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 8791


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        name = os.path.basename(self.path)
        if name == "list.txt":
            body = "\n".join(sorted(f for f in os.listdir(folder) if f.endswith(".wav"))).encode()
        else:
            path = os.path.join(folder, name)
            if not (name.endswith(".wav") and os.path.isfile(path)):
                self.send_response(404); self.end_headers(); return
            body = open(path, "rb").read()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_POST(self):
        name = os.path.basename(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if name in ("status", "out.json"):
            with open(os.path.join(folder, "status.txt" if name == "status" else name), "wb") as f: f.write(body)
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
