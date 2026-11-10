#!/usr/bin/env python3
"""Stand-in for the part of Composio's API that Connect Apps uses (docs/spec/3x-capabilities.md §13).

    python3 scripts/fixtures/composio-mock.py --port 10012 [--latency MS] [--slow-activate SECONDS]

A DEBUG build talks to it when launched with HQN_COMPOSIO_BASE=http://127.0.0.1:<port>; a Release build never does.
The only key it accepts is `ak_mock_dispatch`. Loopback only.

API (shapes as docs.composio.dev shows them):
  POST   /api/v3.1/tool_router/session                 {user_id, multi_account}  -> session (config echoes multi_account)
  GET    /api/v3.1/tool_router/session/{id}                                 -> session
  GET    /api/v3.1/tool_router/session/{id}/toolkits   search, toolkits, limit, cursor, is_connected
  POST   /api/v3/tool_router/session/{id}/link         {toolkit, callback_url}
  POST   /api/v3.1/tool_router/session/{id}/link       {toolkit, alias, callback_url}   another account of an app
  GET    /api/v3.1/connected_accounts                  user_ids, toolkit_slugs   -> every account, alias + word_id
  PATCH  /api/v3.1/connected_accounts/{id}             {alias}
  GET    /api/v3/connected_accounts/{id}
  DELETE /api/v3/connected_accounts/{id}
  GET    /api/v3/tools?toolkit_slug=&important=
  POST   /api/v3/tools/execute/{TOOL}                  {connected_account_id, user_id, arguments}   who-am-I tools only
                                                       (GOOGLEDRIVE_GET_ABOUT, GMAIL_GET_PROFILE): the account's made-up
                                                       address ("email" in a seed row, else one from its alias); 410 when
                                                       the account isn't ACTIVE
  GET    /link/{token}[?choice=allow|deny]             the consent page; a choice answers 302 to the callback
Controls (no key):
  GET  /__state           sessions, accounts, links, log (method, path, status, key: none|good|bad, host)
  POST /__seed            {reset:true} | {accounts:[{toolkit,status,reason,created_at}]} (for every user) |
                          {drop_sessions:true} | {extra_toolkits:N} |
                          {single_account:true|false} (sessions made while true ignore multi_account, as before it existed)
  POST /__fail            {match:"<METHOD> <path part>", status:int, count:int, message:str}
  GET  /__mock/logo/{slug}   a small SVG, as logos.composio.dev answers (404 for slugs listed in --no-logo)
"""

from __future__ import annotations

import argparse
import html
import json
import secrets
import struct
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse, urlunparse

KEY = "ak_mock_dispatch"

BASE_TOOLKITS = [
    ("gmail", "Gmail", "Read, send and organize email."),
    ("googlecalendar", "Google Calendar", "Events, invites and free/busy."),
    ("googledrive", "Google Drive", "Files and folders."),
    ("slack", "Slack", "Channels, messages and people."),
    ("github", "GitHub", "Repositories, issues and pull requests."),
    ("notion", "Notion", "Pages and databases."),
    ("outlook", "Outlook", "Microsoft mail and calendar."),
    ("googlesheets", "Google Sheets", "Spreadsheets, rows and cells."),
    ("linear", "Linear", "Issues and projects."),
    ("hubspot", "HubSpot", "Contacts, deals and companies."),
    ("todoist", "Todoist", "Tasks and projects."),
    ("spotify", "Spotify", "Playback and playlists."),
    ("googledocs", "Google Docs", "Documents and comments."),
    ("jira", "Jira", "Issues, sprints and boards."),
    ("asana", "Asana", "Tasks and projects."),
    ("trello", "Trello", "Boards, lists and cards."),
    ("zoom", "Zoom", "Meetings and recordings."),
    ("dropbox", "Dropbox", "Files and sharing."),
    ("calendly", "Calendly", "Scheduling links and bookings."),
    ("discord", "Discord", "Servers, channels and messages."),
    ("gitlab", "GitLab", "Projects, issues and merge requests."),
    ("salesforce", "Salesforce", "Accounts, leads and opportunities."),
    ("airtable", "Airtable", "Bases, tables and records."),
    ("hackernews", "Hacker News", "Stories and comments. No sign-in needed."),
]
NO_AUTH = {"hackernews"}
TOOLS = {
    "gmail": [("GMAIL_FETCH_EMAILS", "Fetch emails"), ("GMAIL_SEND_EMAIL", "Send email"), ("GMAIL_CREATE_EMAIL_DRAFT", "Create email draft"),
              ("GMAIL_REPLY_TO_THREAD", "Reply to thread"), ("GMAIL_ADD_LABEL_TO_EMAIL", "Modify email labels")],
    "github": [("GITHUB_LIST_ISSUES", "List issues"), ("GITHUB_CREATE_ISSUE", "Create an issue"), ("GITHUB_LIST_PULLS", "List pull requests"),
               ("GITHUB_GET_REPO", "Get a repository")],
}

LOCK = threading.Lock()
ST: dict = {}
ARGS = None


def reset() -> None:
    ST.clear()
    ST.update(sessions={}, accounts={}, links={}, log=[], fail=[], seed=[], extra=0, single=False)


def toolkits() -> list:
    return BASE_TOOLKITS + [(f"extra{i:03d}", f"Extra App {i:03d}", "A made-up app for paging.") for i in range(ST["extra"])]


def svg_logo(slug):
    """A per-app coloured tile as SVG: a gradient square under a white disc, masked to a rounded square."""
    hue = sum(slug.encode()) * 37 % 360
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">'
            f'<defs><linearGradient id="g" x1="0" y1="0" x2="64" y2="64" gradientUnits="userSpaceOnUse">'
            f'<stop stop-color="hsl({hue},70%,50%)"/><stop offset="1" stop-color="#202020"/></linearGradient>'
            f'<mask id="m" style="mask-type:alpha"><rect width="64" height="64" rx="14" fill="#000"/></mask></defs>'
            f'<g mask="url(#m)"><rect width="64" height="64" fill="url(#g)"/><circle cx="32" cy="32" r="12" fill="#fff"/></g>'
            f'</svg>').encode()


def png(slug: str) -> bytes:
    """A 32×32 flat-colour PNG, the colour from the slug."""
    seed = zlib.crc32(slug.encode())
    r, g, b = 60 + seed % 160, 60 + (seed >> 8) % 160, 60 + (seed >> 16) % 160
    row = b"\x00" + bytes([r, g, b]) * 32
    raw = zlib.compress(row * 32)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")


def err(status: int, message: str, slug: str) -> tuple:
    return status, {"error": {"message": message, "code": status, "slug": slug, "status": status}}


def account_view(a: dict) -> dict:
    return {"id": a["id"], "status": a["status"], "status_reason": a.get("reason"), "toolkit": {"slug": a["toolkit"]},
            "created_at": a.get("created_at", "2026-09-29T20:00:00Z"), "alias": a.get("alias"), "word_id": a.get("word_id")}


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def account_for(user: str, slug: str):
    found = [a for a in ST["accounts"].values() if a["user"] == user and a["toolkit"] == slug and a["status"] != "DELETED"]
    return found[-1] if found else None


def made_up_email(alias) -> str:
    """A stand-in address, fixed when the account is made: "jordan@<alias>.com" for a named one."""
    return f"jordan@{alias}.com" if alias else "jordan.lee@gmail.com"


def apply_seed(user: str) -> None:
    for row in ST["seed"]:
        if account_for(user, row["toolkit"]) is None:
            aid = "ca_" + secrets.token_hex(5)
            ST["accounts"][aid] = {"id": aid, "status": row.get("status", "ACTIVE"), "reason": row.get("reason"), "toolkit": row["toolkit"],
                                   "user": user, "created_at": row.get("created_at", "2026-09-29T20:00:00Z"), "alias": row.get("alias"),
                                   "word_id": row.get("word_id") or f"{row['toolkit']}_{secrets.token_hex(2)}",
                                   "email": row.get("email") or made_up_email(row.get("alias")), "name": row.get("name", "Jordan Lee")}


class Handler(BaseHTTPRequestHandler):
    server_version = "composio-standin/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def note(self, status: int) -> None:
        key = self.headers.get("x-api-key")
        ST["log"].append({"method": self.command, "path": self.path, "status": status,
                          "key": "none" if key is None else "good" if key == KEY else "bad", "host": self.headers.get("Host")})

    def origin(self) -> str:
        return f"http://{self.headers.get('Host') or '127.0.0.1'}"

    def send(self, status: int, data: bytes, kind: str, extra: dict | None = None) -> None:
        with LOCK:
            self.note(status)
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def reply(self, status: int, body: dict) -> None:
        self.send(status, json.dumps(body).encode(), "application/json")

    def body(self) -> dict:
        if getattr(self, "_body_for", None) is not self.raw_requestline:
            length = int(self.headers.get("Content-Length") or 0)
            try:
                self._body = json.loads(self.rfile.read(length) or b"{}") if length else {}
            except json.JSONDecodeError:
                self._body = {}
            self._body_for = self.raw_requestline
        return self._body

    def session_view(self, sid: str) -> dict:
        s = ST["sessions"][sid]
        config = {"user_id": s["user"], "manage_connections": {"enable": True}, "multi_account": s["multi"]}
        return {"session_id": sid, "mcp": {"type": "http", "url": f"{self.origin()}/tool_router/v3/{sid}/mcp"},
                "config": config, "config_version": 1}

    def gate(self) -> bool:
        """False when the call was already answered: a bad key or a planned failure."""
        if ARGS.latency:
            time.sleep(ARGS.latency / 1000)
        if self.headers.get("x-api-key") != KEY:
            self.reply(*err(401, "Invalid API key", "Auth_InvalidApiKey"))
            return False
        with LOCK:
            for rule in ST["fail"]:
                method, _, part = rule["match"].partition(" ")
                if rule["count"] > 0 and method == self.command and part in self.path:
                    rule["count"] -= 1
                    planned = err(rule["status"], rule.get("message") or "Planned failure", "Planned")
                    break
            else:
                planned = None
        if planned:
            self.reply(*planned)
            return False
        return True

    def handle_control(self, parts: list) -> bool:
        if not parts or not parts[0].startswith("__"):
            return False
        if parts == ["__state"]:
            with LOCK:
                state = {k: ST[k] for k in ("sessions", "accounts", "links", "log", "seed")}
                data = json.loads(json.dumps(state))
            self.send_response(200)
            raw = json.dumps(data).encode()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return True
        if parts[:2] == ["__mock", "logo"] and len(parts) == 3:
            if parts[2] in ARGS.no_logo:
                self.send(404, b"", "text/plain")
            else:
                # As logos.composio.dev answers: SVG (with a gradient and a mask, so the app's drawer is exercised).
                self.send(200, svg_logo(parts[2]), "image/svg+xml")
            return True
        if self.command == "POST" and parts == ["__seed"]:
            body = self.body()
            with LOCK:
                if body.get("reset"):
                    reset()
                if "accounts" in body:
                    ST["seed"] = body["accounts"] or []
                    for s in ST["sessions"].values():
                        apply_seed(s["user"])
                for patch in body.get("set") or []:
                    for a in ST["accounts"].values():
                        if a["toolkit"] == patch["toolkit"] and a["status"] != "DELETED":
                            a["status"] = patch.get("status", a["status"])
                            a["reason"] = patch.get("reason", a.get("reason"))
                if body.get("drop_sessions"):
                    ST["sessions"].clear()
                if "extra_toolkits" in body:
                    ST["extra"] = int(body["extra_toolkits"])
                if "single_account" in body:
                    ST["single"] = bool(body["single_account"])
            self.reply(200, {"ok": True})
            return True
        if self.command == "POST" and parts == ["__fail"]:
            body = self.body()
            with LOCK:
                ST["fail"].append({"match": str(body.get("match")), "status": int(body.get("status", 500)), "count": int(body.get("count", 1)),
                                   "message": body.get("message")})
            self.reply(200, {"ok": True})
            return True
        self.reply(404, {"error": "no such control"})
        return True

    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        if self.handle_control(parts):
            return
        if parts[:1] == ["link"] and len(parts) == 2:
            return self.consent(parts[1], (parse_qs(url.query).get("choice") or [""])[0])
        if not self.gate():
            return
        with LOCK:
            answer = self.read(parts, parse_qs(url.query))
        self.reply(*answer)

    def read(self, parts: list, query: dict) -> tuple:
        if parts[:4] == ["api", "v3.1", "tool_router", "session"] and len(parts) == 5:
            if parts[4] not in ST["sessions"]:
                return err(404, "Session not found", "ToolRouter_SessionNotFound")
            return 200, self.session_view(parts[4])
        if parts[:4] == ["api", "v3.1", "tool_router", "session"] and len(parts) == 6 and parts[5] == "toolkits":
            sid = parts[4]
            if sid not in ST["sessions"]:
                return err(404, "Session not found", "ToolRouter_SessionNotFound")
            user = ST["sessions"][sid]["user"]
            search = (query.get("search") or [""])[0].strip().lower()
            limit = max(1, min(50, int((query.get("limit") or ["20"])[0])))
            start = int((query.get("cursor") or ["0"])[0] or 0)
            only = (query.get("is_connected") or [""])[0] == "true"
            wanted = {s for s in (query.get("toolkits") or [""])[0].split(",") if s}
            rows = [t for t in toolkits() if (not search or search in t[0] or search in t[1].lower()) and (not wanted or t[0] in wanted)
                    and (not only or (account_for(user, t[0]) or {}).get("status") in ("ACTIVE", "EXPIRED", "INACTIVE"))]
            items = []
            for slug, name, about in rows[start:start + limit]:
                a = account_for(user, slug)
                items.append({"name": name, "slug": slug, "enabled": True, "is_no_auth": slug in NO_AUTH,
                              "meta": {"logo": f"https://logos.composio.dev/api/{slug}", "description": about},
                              "connected_account": account_view(a) if a else None})
            nxt = start + limit
            return 200, {"items": items, "next_cursor": str(nxt) if nxt < len(rows) else None, "total_items": len(rows)}
        if parts == ["api", "v3", "tools"]:
            slug = (query.get("toolkit_slug") or [""])[0]
            tools = TOOLS.get(slug) or [(f"{slug.upper()}_LIST", "List items"), (f"{slug.upper()}_GET", "Get an item")]
            return 200, {"items": [{"slug": t[0], "name": t[1], "description": t[1] + ".", "toolkit": {"slug": slug}} for t in tools],
                         "next_cursor": None}
        if parts == ["api", "v3.1", "connected_accounts"]:
            users = {u for u in (query.get("user_ids") or [""])[0].split(",") if u}
            slugs = {t for t in (query.get("toolkit_slugs") or [""])[0].split(",") if t}
            rows = [a for a in ST["accounts"].values() if a["status"] != "DELETED" and (not users or a["user"] in users)
                    and (not slugs or a["toolkit"] in slugs)]
            rows.sort(key=lambda a: a.get("created_at", ""))
            return 200, {"items": [account_view(a) for a in rows], "next_cursor": None, "total_items": len(rows)}
        if parts[:3] == ["api", "v3", "connected_accounts"] and len(parts) == 4:
            a = ST["accounts"].get(parts[3])
            if not a or a["status"] == "DELETED":
                return err(404, "Connected account not found", "ConnectedAccount_NotFound")
            if a.get("activate_at") and time.time() >= a["activate_at"]:
                a["status"] = "ACTIVE"
                a.pop("activate_at")
            return 200, account_view(a)
        return err(404, "No such route", "NotFound")

    def do_POST(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if self.handle_control(parts):
            return
        body = self.body()   # read before any answer: an unread body corrupts a kept-alive connection
        if not self.gate():
            return
        with LOCK:
            answer = self.write(parts, body)
        self.reply(*answer)

    def write(self, parts: list, body: dict) -> tuple:
        if parts == ["api", "v3.1", "tool_router", "session"]:
            user = str(body.get("user_id") or "").strip()
            if not user:
                return err(400, "user_id is required", "ToolRouter_InvalidRequest")
            sid = "trs_" + secrets.token_hex(6)
            multi = body.get("multi_account") if isinstance(body.get("multi_account"), dict) else {}
            ST["sessions"][sid] = {"user": user, "multi": {"enable": bool(multi.get("enable")) and not ST["single"],
                                                           "max_accounts_per_toolkit": int(multi.get("max_accounts_per_toolkit") or 5)}}
            apply_seed(user)
            return 201, self.session_view(sid)
        if parts[:4] in (["api", "v3", "tool_router", "session"], ["api", "v3.1", "tool_router", "session"]) and len(parts) == 6 and parts[5] == "link":
            sid, slug, alias = parts[4], str(body.get("toolkit") or ""), body.get("alias")
            named = parts[1] == "v3.1"
            if alias is not None and not named:
                return err(400, "alias is not accepted on this route", "ToolRouter_InvalidRequest")
            if sid not in ST["sessions"]:
                return err(404, "Session not found", "ToolRouter_SessionNotFound")
            if slug not in {t[0] for t in toolkits()}:
                return err(404, "Toolkit not found", "Toolkit_NotFound")
            if slug in NO_AUTH:
                return err(400, "This toolkit needs no connection", "Toolkit_NoAuth")
            session = ST["sessions"][sid]
            user = session["user"]
            existing = account_for(user, slug)
            live = [a for a in ST["accounts"].values() if a["user"] == user and a["toolkit"] == slug and a["status"] in ("ACTIVE", "EXPIRED", "INACTIVE")]
            if named:
                if alias is not None and (not isinstance(alias, str) or not alias or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in alias)):
                    return err(400, "alias must be lowercase letters, digits and '-'", "ConnectedAccount_InvalidAlias")
                if alias and any(a.get("alias") == alias for a in live):
                    return err(400, "An account with this alias already exists", "ConnectedAccount_AliasExists")
                if session["multi"]["enable"] and len([a for a in live if a["status"] == "ACTIVE"]) >= session["multi"]["max_accounts_per_toolkit"]:
                    return err(400, "Too many accounts for this toolkit", "ConnectedAccount_LimitReached")
            elif existing and existing["status"] == "ACTIVE":
                return err(400, "Already connected", "ConnectedAccount_AlreadyExists")
            aid, token = "ca_" + secrets.token_hex(5), "lk_" + secrets.token_hex(8)
            ST["accounts"][aid] = {"id": aid, "status": "INITIATED", "toolkit": slug, "user": user, "alias": alias or None,
                                   "word_id": f"{slug}_{secrets.token_hex(2)}", "created_at": now_iso(), "session": sid,
                                   "email": made_up_email(alias), "name": "Jordan Lee"}
            ST["links"][token] = {"account": aid, "callback": body.get("callback_url"), "opens": 0, "used": False}
            return 201, {"link_token": token, "redirect_url": f"{self.origin()}/link/{token}", "connected_account_id": aid}
        if parts[:4] == ["api", "v3", "tools", "execute"] and len(parts) == 5:
            a = ST["accounts"].get(str(body.get("connected_account_id") or ""))
            if not a or a["status"] == "DELETED":
                return err(404, "Connected account not found", "ConnectedAccount_NotFound")
            if body.get("user_id") != a["user"]:
                return err(400, "The account belongs to another user", "ActionExecute_UserMismatch")
            if a["status"] != "ACTIVE":
                return err(410, f"Connected account {a['id']} is in {a['status']} state", "ActionExecute_ConnectedAccountExpired")
            email, name = a.get("email") or made_up_email(a.get("alias")), a.get("name") or "Jordan Lee"
            if parts[4] == "GOOGLEDRIVE_GET_ABOUT":
                data = {"user": {"kind": "drive#user", "displayName": name, "emailAddress": email, "me": True, "permissionId": "1234"}}
            elif parts[4] == "GMAIL_GET_PROFILE":
                data = {"response_data": {"emailAddress": email, "messagesTotal": 12, "threadsTotal": 9, "historyId": "77"}}
            else:
                return err(404, "Tool not found", "Tool_NotFound")
            return 200, {"successful": True, "data": data, "error": None, "log_id": "log_mock"}
        return err(404, "No such route", "NotFound")

    def do_PATCH(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        body = self.body()
        if not self.gate():
            return
        with LOCK:
            a = ST["accounts"].get(parts[3]) if parts[:3] == ["api", "v3.1", "connected_accounts"] and len(parts) == 4 else None
            alias = body.get("alias")
            if not a or a["status"] == "DELETED":
                answer = err(404, "Connected account not found", "ConnectedAccount_NotFound")
            elif not isinstance(alias, str) or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in alias):
                answer = err(400, "alias must be lowercase letters, digits and '-'", "ConnectedAccount_InvalidAlias")
            elif alias and any(b is not a and b.get("alias") == alias and b["user"] == a["user"] and b["toolkit"] == a["toolkit"]
                               and b["status"] != "DELETED" for b in ST["accounts"].values()):
                answer = err(400, "An account with this alias already exists", "ConnectedAccount_AliasExists")
            else:
                a["alias"] = alias or None
                answer = (200, account_view(a))
        self.reply(*answer)

    def do_DELETE(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        self.body()
        if not self.gate():
            return
        with LOCK:
            if parts[:3] == ["api", "v3", "connected_accounts"] and len(parts) == 4 and parts[3] in ST["accounts"]:
                ST["accounts"][parts[3]]["status"] = "DELETED"
                answer = (200, {"success": True})
            else:
                answer = err(404, "Connected account not found", "ConnectedAccount_NotFound")
        self.reply(*answer)

    def consent(self, token: str, choice: str) -> None:
        with LOCK:
            link = ST["links"].get(token)
            if link:
                link["opens"] += 1
            gone = not link or link["used"]
            if not gone and choice in ("allow", "deny"):
                link["used"] = True
                a = ST["accounts"][link["account"]]
                if choice == "allow":
                    if ARGS.slow_activate:
                        a["activate_at"] = time.time() + ARGS.slow_activate
                    else:
                        a["status"] = "ACTIVE"
                else:
                    a["status"], a["reason"] = "FAILED", "The user denied access."
                target, aid = link["callback"], a["id"]
            else:
                target = aid = None
            name = "" if gone else dict((t[0], t[1]) for t in toolkits())[ST["accounts"][link["account"]]["toolkit"]]
        if aid and target:
            u = urlparse(target)
            extra = urlencode({"status": "success" if choice == "allow" else "failed", "connected_account_id": aid})
            return self.send(302, b"", "text/plain", {"Location": urlunparse(u._replace(query=f"{u.query}&{extra}" if u.query else extra))})
        if aid:
            return self.send(200, b"<!doctype html><h1>Done</h1><p>You can close this window.</p>", "text/html; charset=utf-8")
        if gone:
            page, status = "<h1>This link has expired</h1><p>Connect links work once. Start again from the app.</p>", 410
        else:
            page, status = (f"<h1>Connect {html.escape(name)}</h1><p>Stand-in consent page.</p><p><a id='allow' href='/link/{token}?choice=allow'>Allow</a>"
                            f" &nbsp; <a id='deny' href='/link/{token}?choice=deny'>Deny</a></p>"), 200
        style = ("<!doctype html><meta name=viewport content='width=device-width'><style>body{font:17px -apple-system;padding:24px}"
                 "a{display:inline-block;padding:12px 20px;border-radius:10px;background:#0a84ff;color:#fff;text-decoration:none}"
                 "#deny{background:#8e8e93}</style>")
        self.send(status, (style + page).encode(), "text/html; charset=utf-8")


def main() -> None:
    global ARGS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=10012)
    parser.add_argument("--latency", type=int, default=0, help="milliseconds added to every API call")
    parser.add_argument("--slow-activate", type=float, default=0, help="seconds an allowed account stays INITIATED")
    parser.add_argument("--no-logo", default="", help="comma-separated slugs whose logo answers 404")
    ARGS = parser.parse_args()
    ARGS.no_logo = {s for s in ARGS.no_logo.split(",") if s}
    reset()
    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print(f"composio stand-in on http://127.0.0.1:{ARGS.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
