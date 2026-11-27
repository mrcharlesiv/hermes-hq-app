#!/usr/bin/env python3
"""Loopback-only Sign in with Nous acceptance gateway. Invented state; no upstream client, no real Portal.

The build 47 chat fixture (streamed replies, retained transcripts) with Hermes's RFC 8252 native sign-in in front,
answering the way hermes_cli/dashboard_auth/routes.py, native_flow.py and plugins/dashboard_auth/nous do:

  GET  /api/status               auth_providers [basic, nous], auth_flows [cookie, native_pkce]
  GET  /auth/native/authorize    S256 + loopback redirect only; pending entry; PKCE cookie; 302 to the fake Portal
  GET  /auth/callback            PKCE cookie + state check; one-time code bound to the client's challenge; 302 to loopback
  POST /auth/native/token        code + verifier (S256, single use) -> bearer pair
  POST /auth/native/refresh      rotating refresh token with reuse detection (a replayed one revokes the family)
  GET  /api/auth/me              the bearer's session (user_id, provider, expires_at)
  POST /api/auth/ws-ticket       single-use, 30 s; /api/ws refuses any other ticket

A second server on --portal-port stands in for Nous Portal's sign-in page: "Continue as owner" or "as someone else".
Fixture controls (direct to this port, never through the edge): GET /__fixture/nous (counts, live tokens),
POST /__fixture/nous/revoke (Portal revocation: every token dies), POST /__fixture/nous/ttl {"access": seconds}.
--tokens-file writes every token issued (0600) so a log scan can prove none was logged.
"""
import argparse, base64, hashlib, importlib.util, json, os, pathlib, secrets, struct, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

spec = importlib.util.spec_from_file_location('build47', pathlib.Path(__file__).with_name('build47-fixture-gateway.py'))
b47 = importlib.util.module_from_spec(spec); spec.loader.exec_module(b47)
voice, auth = b47.voice, b47.voice.auth

OWNER, STRANGER = 'user_owner_fixture', 'user_stranger_fixture'
LOCK = threading.RLock()
STATE = {'accessTtl': 30, 'pending': {}, 'codes': {}, 'upstream': {}, 'access': {}, 'refresh': {}, 'tickets': {},
         'counts': {'authorize': 0, 'callback': 0, 'token': 0, 'refresh': 0, 'refreshReplayed': 0, 'refreshRejected': 0,
                    'bearerOk': 0, 'bearerRejected': 0, 'ticketsMinted': 0, 'ticketsRejected': 0, 'wsOpened': 0,
                    'displayTickets': 0, 'displayRejected': 0, 'rfbOpened': 0, 'rfbFrames': 0, 'rfbPointer': 0, 'rfbPointerAsHolder': 0,
                    'rfbKeys': 0, 'leaseAcquired': 0, 'leaseReleased': 0}}
# Bot Screen, as hermes_cli/web_routers/display.py and tui_gateway's display.* handlers answer: display.observe mints a
# viewer id and a single-use 30 s display ticket; /api/display/ws admits that ticket once and speaks RFB 3.8.
DISPLAY = {'tickets': {}, 'lease': {'holder': 'agent', 'viewer_hash': None, 'since': time.time(), 'epoch': 1, 'reason': ''}, 'viewers': set()}
_b47_rpc = voice.rpc

def vhash(viewer):
    return hashlib.sha256(viewer.encode()).hexdigest()[:12]

def display_rpc(method, params):
    if method in ('display.status', 'display.observe', 'display.lease.acquire', 'display.lease.release'):
        status = _b47_rpc('display.status', params)
        with LOCK:
            status['lease'] = dict(DISPLAY['lease'])
            if method == 'display.observe':
                viewer = params.get('viewer_id') if params.get('viewer_id') in DISPLAY['viewers'] else secrets.token_urlsafe(12)
                DISPLAY['viewers'].add(viewer)
                ticket = secrets.token_urlsafe(32)
                DISPLAY['tickets'][ticket] = time.time() + 30
                STATE['counts']['displayTickets'] += 1
                note_token('display-ticket', ticket)
                return {**status, 'viewer_id': viewer, 'ticket': ticket}
            if method == 'display.lease.acquire':
                if params.get('viewer_id') not in DISPLAY['viewers']: raise ValueError('unknown viewer')
                DISPLAY['lease'] = {'holder': 'human', 'viewer_hash': vhash(params['viewer_id']), 'since': time.time(), 'epoch': DISPLAY['lease']['epoch'] + 1, 'reason': ''}
                STATE['counts']['leaseAcquired'] += 1
                return {'lease': dict(DISPLAY['lease'])}
            if method == 'display.lease.release':
                DISPLAY['lease'] = {'holder': 'agent', 'viewer_hash': None, 'since': time.time(), 'epoch': DISPLAY['lease']['epoch'] + 1, 'reason': 'released'}
                STATE['counts']['leaseReleased'] += 1
                return {'lease': dict(DISPLAY['lease'])}
        return status
    return _b47_rpc(method, params)
voice.rpc = b47.rpc = display_rpc  # the build 47 socket calls its own module global

def rfb(connection, key):
    """A 320x200 synthetic desktop over RFB 3.8 (security None, raw encoding) in binary WebSocket frames."""
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    width, height, buffer = 320, 200, bytearray()
    fmt = {'bpp': 32, 'big': 0, 'rs': 16, 'gs': 8, 'bs': 0}
    def send(data):
        n = len(data)
        header = bytes([0x82]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536 else bytes([127]) + struct.pack('>Q', n))
        connection.sendall(header + data)
    def read_exact(n):
        data = b''
        while len(data) < n:
            chunk = connection.recv(n - len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data
    def need(n):
        while len(buffer) < n:
            first, second = read_exact(2); opcode, length = first & 15, second & 127
            if length == 126: length = struct.unpack('>H', read_exact(2))[0]
            elif length == 127: length = struct.unpack('>Q', read_exact(8))[0]
            mask = read_exact(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read_exact(length)))
            if opcode == 8: raise ConnectionError()
            if opcode in (0, 1, 2): buffer.extend(payload)
        out = bytes(buffer[:n]); del buffer[:n]; return out
    def frame(tick):
        rows = []
        for y in range(height):
            row = bytearray()
            for x in range(width):
                r, g, b = (x + tick * 8) % 256, (y * 255 // height), (40 if DISPLAY['lease']['holder'] == 'agent' else 200)
                value = (r << fmt['rs']) | (g << fmt['gs']) | (b << fmt['bs'])
                row += value.to_bytes(4, 'big' if fmt['big'] else 'little')
            rows.append(bytes(row))
        return b'\0\0' + struct.pack('>H', 1) + struct.pack('>HHHHi', 0, 0, width, height, 0) + b''.join(rows)
    try:
        send(b'RFB 003.008\n'); need(12)
        send(bytes([1, 1])); need(1)
        send(struct.pack('>I', 0)); need(1)
        name = b'Fixture Bot Desktop'
        send(struct.pack('>HHBBBBHHHBBB3x', width, height, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0) + struct.pack('>I', len(name)) + name)
        with LOCK: STATE['counts']['rfbOpened'] += 1
        tick = 0
        while True:
            kind = need(1)[0]
            if kind == 0:
                body = need(19); bpp, depth, big, true, rm, gm, bm, rs, gs, bs = struct.unpack('>3xBBBBHHHBBB3x', body)
                fmt = {'bpp': bpp, 'big': big, 'rs': rs, 'gs': gs, 'bs': bs}
            elif kind == 2:
                count = struct.unpack('>xH', need(3))[0]; need(4 * count)
            elif kind == 3:
                incremental = need(9)[0]
                if incremental: time.sleep(.5)
                tick += 1; send(frame(tick))
                with LOCK: STATE['counts']['rfbFrames'] += 1
            elif kind == 4:
                need(7)
                with LOCK: STATE['counts']['rfbKeys'] += 1
            elif kind == 5:
                need(5)
                with LOCK:
                    STATE['counts']['rfbPointer'] += 1
                    if DISPLAY['lease']['holder'] == 'human': STATE['counts']['rfbPointerAsHolder'] += 1
            elif kind == 6:
                length = struct.unpack('>3xI', need(7))[0]; need(length)
            else:
                return
    except (ConnectionError, OSError):
        pass
TOKENS_FILE = None

def s256(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode('ascii')).digest()).rstrip(b'=').decode()

def note_token(kind, value):
    if not TOKENS_FILE: return
    with LOCK, open(TOKENS_FILE, 'a') as handle: handle.write(f'{kind} {value}\n')

def issue(user, family=None):
    now = time.time()
    family = family or secrets.token_urlsafe(8)
    at, rt = 'nat_' + secrets.token_urlsafe(24), 'nrt_' + secrets.token_urlsafe(24)
    with LOCK:
        STATE['access'][at] = {'user': user, 'exp': now + STATE['accessTtl'], 'family': family}
        STATE['refresh'][rt] = {'user': user, 'exp': now + 24 * 3600, 'family': family, 'used': False}
    note_token('access', at); note_token('refresh', rt)
    return {'access_token': at, 'refresh_token': rt, 'token_type': 'Bearer', 'expires_at': int(now + STATE['accessTtl']), 'provider': 'nous', 'user_id': user}

def bearer_user(headers):
    value = headers.get('Authorization') or ''
    if not value.startswith('Bearer '): return None
    with LOCK:
        entry = STATE['access'].get(value[7:])
        if entry and entry['exp'] > time.time():
            STATE['counts']['bearerOk'] += 1
            return entry
        STATE['counts']['bearerRejected'] += 1
    return None

def handler(gateway, portal_origin):
    base = b47.handler(gateway)
    class Handler(base):
        def session(self):
            # A Nous bearer is a session, like Hermes's gate (middleware.gated_auth_middleware); cookies stay as before.
            if (self.headers.get('Authorization') or '').startswith('Bearer '):
                return bearer_user(self.headers) is not None
            return super().session()

        def body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try: return json.loads(raw or b'{}')
            except ValueError: return {}

        def redirect(self, location, cookies=()):
            self.send_response(302)
            self.send_header('Location', location)
            for cookie in cookies: self.send_header('Set-Cookie', cookie)
            self.send_header('Content-Length', '0')
            self.end_headers()

        def do_GET(self):
            url = urlparse(self.path); path = url.path; query = {k: v[0] for k, v in parse_qs(url.query).items()}
            if path == '/api/status':
                return self.reply(200, {'version': '1.0.0', 'release_date': '2026.10.01', 'desktop_contract': 8, 'auth_required': True,
                                        'auth_providers': ['basic', 'nous'], 'auth_flows': ['cookie', 'native_pkce']})
            if path == '/__fixture/nous':
                with LOCK:
                    return self.reply(200, {'counts': dict(STATE['counts']), 'liveAccess': sum(1 for e in STATE['access'].values() if e['exp'] > time.time()),
                                            'liveRefresh': sum(1 for e in STATE['refresh'].values() if not e['used']), 'accessTtl': STATE['accessTtl']})
            if path == '/auth/native/authorize':
                redirect = query.get('redirect_uri', '')
                parsed = urlparse(redirect)
                if query.get('code_challenge_method', '').upper() != 'S256' or not query.get('code_challenge'):
                    return self.reply(400, {'detail': 'code_challenge_method must be S256'})
                if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', '::1'):
                    return self.reply(400, {'detail': 'native redirect_uri host must be a loopback IP literal (127.0.0.1 / ::1)'})
                if query.get('provider', 'nous') != 'nous': return self.reply(404, {'detail': f"Unknown provider: {query.get('provider')!r}"})
                broker, upstream_state = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
                with LOCK:
                    STATE['pending'][broker] = {'challenge': query['code_challenge'], 'redirect': redirect, 'state': query.get('state', ''), 'exp': time.time() + 600}
                    STATE['counts']['authorize'] += 1
                cookie = 'hermes_session_pkce=' + base64.urlsafe_b64encode(f'provider=nous;state={upstream_state};broker={broker}'.encode()).decode() + '; HttpOnly; Path=/; SameSite=Lax; Max-Age=600'
                return self.redirect(f'{portal_origin}/oauth/authorize?' + urlencode({'state': upstream_state, 'client_id': 'agent:fixture'}), [cookie])
            if path == '/auth/callback':
                raw = self.cookies().get('hermes_session_pkce', '')
                try: parts = dict(seg.split('=', 1) for seg in base64.urlsafe_b64decode(raw.encode()).decode().split(';') if '=' in seg)
                except Exception: parts = {}
                if not parts: return self.reply(400, {'detail': 'Missing PKCE state cookie'})
                if query.get('state') != parts.get('state'): return self.reply(400, {'detail': 'OAuth state mismatch (CSRF check failed)'})
                with LOCK:
                    user = STATE['upstream'].pop(query.get('code', ''), None)
                    pending = STATE['pending'].pop(parts.get('broker', ''), None)
                    STATE['counts']['callback'] += 1
                    if not user: return self.reply(400, {'detail': 'Invalid code'})
                    if not pending or pending['exp'] < time.time(): return self.reply(400, {'detail': 'Native login expired or unknown; restart sign-in.'})
                    code = secrets.token_urlsafe(32)
                    STATE['codes'][code] = {'challenge': pending['challenge'], 'user': user, 'exp': time.time() + 120}
                note_token('code', code)
                sep = '&' if '?' in pending['redirect'] else '?'
                return self.redirect(pending['redirect'] + sep + urlencode({'code': code, 'state': pending['state']}), ['hermes_session_pkce=; Max-Age=0; Path=/'])
            if path == '/api/auth/me':
                entry = bearer_user(self.headers)
                if entry: return self.reply(200, {'user_id': entry['user'], 'email': '', 'display_name': '', 'org_id': '', 'provider': 'nous', 'expires_at': int(entry['exp'])})
                if (self.headers.get('Authorization') or '').startswith('Bearer '):
                    return self.reply(401, {'error': 'session_expired', 'detail': 'Unauthorized', 'reason': 'invalid_or_expired_session'})
                return super().do_GET()
            if path == '/api/display/ws' and (self.headers.get('Upgrade') or '').lower() == 'websocket':
                with LOCK:
                    expiry = DISPLAY['tickets'].pop(query.get('display_ticket', ''), None)
                    ok = expiry is not None and expiry > time.time()
                    if not ok: STATE['counts']['displayRejected'] += 1
                if not ok: return self.reply(403, {'detail': 'display ticket invalid'})
                rfb(self.connection, self.headers['Sec-WebSocket-Key'])
                self.close_connection = True
                return
            if path == '/api/ws' and (self.headers.get('Upgrade') or '').lower() == 'websocket':
                ticket = query.get('ticket', '')
                with LOCK:
                    entry = STATE['tickets'].pop(ticket, None)
                    ok = entry is not None and entry > time.time()
                    STATE['counts']['wsOpened' if ok else 'ticketsRejected'] += 1
                if not ok: return self.reply(403, {'detail': 'ticket_invalid'})
                auth.websocket(self.connection, self.headers['Sec-WebSocket-Key'])
                self.close_connection = True
                return
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/nous/revoke':
                self.body()
                with LOCK:
                    STATE['access'].clear(); STATE['refresh'].clear()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/nous/ttl':
                with LOCK: STATE['accessTtl'] = int(self.body().get('access', 30))
                return self.reply(200, {'ok': True})
            if path == '/auth/native/token':
                body = self.body()
                with LOCK:
                    STATE['counts']['token'] += 1
                    entry = STATE['codes'].pop(body.get('code', ''), None)  # consumed on every path: no verifier oracle
                if not entry or entry['exp'] < time.time() or not secrets.compare_digest(entry['challenge'], s256(body.get('code_verifier', ''))):
                    return self.reply(400, {'detail': 'Invalid or expired authorization code.'})
                return self.reply(200, issue(entry['user']))
            if path == '/auth/native/refresh':
                body = self.body()
                with LOCK:
                    STATE['counts']['refresh'] += 1
                    entry = STATE['refresh'].get(body.get('refresh_token', ''))
                    if entry and entry['used']:
                        # Reuse detection: a rotated token came back, so the whole family dies (Portal's contract).
                        STATE['counts']['refreshReplayed'] += 1
                        family = entry['family']
                        for table in ('access', 'refresh'):
                            for key in [k for k, v in STATE[table].items() if v['family'] == family]: STATE[table].pop(key, None)
                        entry = None
                    elif entry and entry['exp'] > time.time():
                        entry['used'] = True
                    else:
                        entry = None
                    if not entry: STATE['counts']['refreshRejected'] += 1
                if not entry:
                    return self.reply(401, {'error': 'session_expired', 'detail': 'Refresh token expired or invalid; start a new sign-in.'})
                return self.reply(200, issue(entry['user'], entry['family']))
            if path == '/api/auth/ws-ticket':
                self.body()
                if not self.session(): return self.reply(401, {'error': 'unauthenticated', 'detail': 'Unauthorized'})
                ticket = secrets.token_urlsafe(32)
                with LOCK:
                    STATE['tickets'][ticket] = time.time() + 30
                    STATE['counts']['ticketsMinted'] += 1
                note_token('ticket', ticket)
                return self.reply(200, {'ticket': ticket, 'ttl_seconds': 30})
            return super().do_POST()
    return Handler

def portal(gateway_public):
    class Portal(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            url = urlparse(self.path); query = {k: v[0] for k, v in parse_qs(url.query).items()}
            if url.path == '/oauth/authorize':
                state = query.get('state', '')
                links = []
                for label, user in (('Continue as owner', OWNER), ('Continue as someone else', STRANGER)):
                    code = secrets.token_urlsafe(24)
                    with LOCK: STATE['upstream'][code] = user
                    links.append(f'<a class="b" href="{gateway_public}/auth/callback?{urlencode({"code": code, "state": state})}">{label}</a>')
                page = ('<!doctype html><meta name="viewport" content="width=device-width"><title>Nous Portal (fixture)</title>'
                        '<style>body{font:17px -apple-system;margin:3rem 1.5rem;text-align:center}.b{display:block;margin:1rem 0;padding:14px;border-radius:12px;background:#111;color:#fff;text-decoration:none}</style>'
                        '<h2>Nous Portal</h2><p>Fixture sign-in for Dispatch tests</p>' + ''.join(links))
                data = page.encode()
                self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.send_header('Content-Length', str(len(data))); self.end_headers()
                self.wfile.write(data); return
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
    return Portal

def main():
    global TOKENS_FILE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=19447)
    parser.add_argument('--portal-port', type=int, default=19449)
    parser.add_argument('--public-url', required=True, help='the address the browser reaches this gateway at (the edge)')
    parser.add_argument('--access-ttl', type=int, default=30)
    parser.add_argument('--tokens-file')
    args = parser.parse_args()
    STATE['accessTtl'] = args.access_ttl
    if args.tokens_file:
        TOKENS_FILE = args.tokens_file
        os.close(os.open(TOKENS_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
    # Cookie (password) sessions stay for comparison; the password is random unless given, and never printed.
    # NOUS_FIXTURE_PASSWORD (environment, never an argument) lets a test sign in with the password too.
    gateway = auth.Gateway('fleet-fixture', os.environ.get('NOUS_FIXTURE_PASSWORD') or secrets.token_urlsafe(24), True, None, None, 0, True)
    portal_server = ThreadingHTTPServer(('127.0.0.1', args.portal_port), portal(args.public_url.rstrip('/')))
    threading.Thread(target=portal_server.serve_forever, daemon=True).start()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(gateway, f'http://127.0.0.1:{args.portal_port}'))
    print(f'Nous fixture gateway on 127.0.0.1:{args.port}, fake Portal on 127.0.0.1:{args.portal_port}, owner {OWNER}', flush=True)
    server.serve_forever()

if __name__ == '__main__': main()
