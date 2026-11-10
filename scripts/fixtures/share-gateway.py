#!/usr/bin/env python3
"""Loopback stand-in gateway for the Share extension (docs/spec/3x-share.md §10.1).

Loads scripts/fixtures/attachments-gateway.py by path (which loads the reference performance fixture, read-only) and so
inherits: password sign-in, the socket and streaming engine, the bots "Hermes" (profile `default`, Bot Chat
20260929_120000_aabbcc01, runtime 5cc537d1) and "Ivy" (`ivy`, 20260929_120000_aabbcc02, runtime bf611b3e),
GET /api/files, POST /api/files/upload-stream (GPS / camera detection), DELETE /api/files, strict image.attach /
file.attach / prompt.submit (4000 on an unknown key, 4001 for a wrong runtime id), stored user rows and a short
streamed reply. Loopback only, PORTS 9910-9919 ONLY, stdlib only, invented data. Never forwards anything anywhere.

On top, what a share needs:
  Hermes cookies      hermes_session_at (--access-ttl, default 43200 s) + hermes_session_rt; a lapsed access cookie
                      with a valid refresh cookie is served and answered with a fresh pair
                      (POST /__fixture/expire-access, POST /__fixture/revoke, GET /__fixture/auth: inherited)
  Session gate        every /api/* route and the ws-ticket need the cookie session or a live bearer, else 401
  Tickets             POST /api/auth/ws-ticket issues a single-use ticket; an upgrade naming a ticket needs a live one
  Strict params       also on session.resume and client.capabilities -> {"code":4000,"message":"invalid params"}
  client.capabilities answers {"server_requests":["approval.request","clarify.request"],"declines_not_shown":true}
  Nous                POST /__fixture/nous/issue {"ttl"} -> a bearer pair (no Portal); a live bearer is a session;
                      POST /auth/native/refresh rotates and revokes the family on a replay; GET /__fixture/nous ->
                      {"counts":{"refresh","replayed","bearerOk","bearerRejected"}}; POST /__fixture/nous/revoke
  Movie check         an upload ending .mov/.mp4/.m4v records `location: true` when it holds an ISO 6709 string
  Photo size          an uploaded JPEG records `pixels: [width, height]` (read from its frame header)
Controls (no auth, never under /api/):
  POST /__fixture/share-roster          {"hidden":[profiles], "noChat":[profiles], "extra": N, "lastActive": {profile: t}}
  POST /__fixture/share-fail            {"target": "me"|"files"|"upload"|"ticket"|"delete"|"refresh"|"<rpc method>"|
                                         "ready"|"socket", "status": N (REST; 302 points at --redirect-port) or
                                         "body": {...} / "html": true (REST, a 200 with that body) or "code": N,
                                         "message": "..." (RPC error) or "result": {...} (RPC answer), "times": 1}
                                        "ready": the socket sends no gateway.ready; "socket": it closes after the upgrade
  POST /__fixture/share-hold            {"target": ..., "seconds": S, "drop": bool}: the next such call waits S seconds;
                                        with `drop` an RPC is taken (a prompt is stored) and the socket closed unanswered
  POST /__fixture/share-server-request  {"before":"prompt.submit"}: sends an approval.request server request on that
                                        socket first and counts any reply frame in `serverRequestReplies`
  POST /__fixture/share-reset           records, faults, holds, roster shape, Nous tables, transcripts back to the start
  POST /__fixture/share-sim             {"content_size": "large"|…, "appearance": "light"|"dark", "increase_contrast":
                                         "enabled"|"disabled"}: with --sim UDID, sets that on that one simulator
                                         (`xcrun simctl ui`); a UI test cannot reach simctl itself. Names outside the
                                         lists below are refused, and nothing else is ever run.
  GET  /__fixture/state                 adds shareLedger, prompts (with `session`), uploads, deletes, held,
                                        serverRequestReplies, redirected, staged (the files on this gateway's disk under
                                        uploads/.dispatch-attachments right now, as "<folder>/<name>")
  GET  /__fixture/page                  a page with one sentence in a text field (the opt-in Safari text test)

  python3 scripts/fixtures/share-gateway.py --port 9910 --credentials build/fixtures/share.json \
      --files build/fixtures/share-files --log build/fixtures/share.jsonl
"""
import argparse, base64, copy, hashlib, importlib.util, json, os, pathlib, re, secrets, shutil, socket, struct, subprocess, \
    sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('hqn_attachments_fixture', HERE / 'attachments-gateway.py')
att = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(att)
b47, voice, auth = att.b47, att.voice, att.auth
LOCK = att.LOCK                      # an RLock shared by every layer

PORTS = range(9910, 9920)
LOG = None                           # --log: the ledger as JSON lines
REDIRECT_PORT = None
SIM = None                           # --sim: the one simulator share-sim may change the look of
SIM_SETTINGS = {
    'content_size': ('extra-small', 'small', 'medium', 'large', 'extra-large', 'extra-extra-large',
                     'extra-extra-extra-large', 'accessibility-medium', 'accessibility-large',
                     'accessibility-extra-large', 'accessibility-extra-extra-large',
                     'accessibility-extra-extra-extra-large'),
    'appearance': ('light', 'dark'),
    'increase_contrast': ('enabled', 'disabled'),
}


def sim_set(body):
    """Sets text size / appearance / contrast on the --sim simulator. Returns what was set, or an error string."""
    if not SIM:
        return 'started without --sim'
    done = {}
    for name, allowed in SIM_SETTINGS.items():
        if name not in body:
            continue
        value = str(body[name])
        if value not in allowed:
            return f'{name}: {value!r} is not one of {", ".join(allowed)}'
        result = subprocess.run(['xcrun', 'simctl', 'ui', SIM, name, value], capture_output=True, timeout=30)
        if result.returncode != 0:
            return f'{name}: simctl answered {result.returncode}'
        done[name] = value
    return done
TLS = threading.local()

SHARE_LEDGER, HELD, REDIRECTED = [], [], []
FAULTS, HOLDS = {}, {}
ROSTER = {'hidden': [], 'noChat': [], 'extra': 0, 'lastActive': {}}
SERVER_REQUEST = {'before': None}
COUNTS = {'serverRequestReplies': 0, 'sockets': 0, 'serverRequests': 0}
TICKETS = {}
NOUS = {'access': {}, 'refresh': {}, 'counts': {'refresh': 0, 'replayed': 0, 'bearerOk': 0, 'bearerRejected': 0}}
NOUS_USER = 'user_owner_fixture'
START_ACTIVE = {'default': 1790686800, 'ivy': 1790690400}       # Hermes last active before Ivy
RESUME_KEYS = {'session_id', 'profile', 'cols', 'source', 'lazy', 'defer_history', 'omit_messages', 'eager_build',
               'close_on_disconnect', 'inline_images'}
CAPABILITY_KEYS = {'server_requests'}
REST_TARGETS = {('GET', '/api/auth/me'): 'me', ('GET', '/api/files'): 'files', ('POST', '/api/files/upload-stream'): 'upload',
                ('POST', '/api/auth/ws-ticket'): 'ticket', ('DELETE', '/api/files'): 'delete',
                ('POST', '/auth/native/refresh'): 'refresh'}
PAGE = ('<!doctype html><meta name="viewport" content="width=device-width"><title>Hermes HQ share check</title>'
        '<body style="font:22px -apple-system;padding:24px"><p>Select the text below and share it to Hermes HQ.</p>'
        '<textarea id="quote" aria-label="Quote" rows="3" style="width:100%;font:22px -apple-system">'
        'Shared text from Safari for the Hermes HQ share check.</textarea></body>')


# ── the ledger ─────────────────────────────────────────────────────────────────────────────────────────────────────────

def record(entry):
    """Every HTTP request, upgrade and RPC, in order. Never a cookie, a token or a ticket: keys and lengths only."""
    with LOCK:
        entry['n'] = len(SHARE_LEDGER) + 1
        entry['t'] = round(time.time(), 3)
        SHARE_LEDGER.append(entry)
    return entry


def flush(entry):
    if not LOG:
        return
    with LOCK, open(LOG, 'a', encoding='utf-8') as handle:
        handle.write(json.dumps(entry, sort_keys=True) + '\n')


def take(table, target):
    """The next fault or hold for `target` (one use of its `times`), or None."""
    with LOCK:
        item = table.get(target)
        if not item:
            return None
        item['times'] = int(item.get('times', 1)) - 1
        if item['times'] <= 0:
            table.pop(target, None)
        return dict(item)


# ── Sign in with Nous (as scripts/nous-fixture-gateway.py answers it, without Portal) ───────────────────────────────────

def nous_issue(ttl, family=None):
    family = family or secrets.token_urlsafe(8)
    at, rt = 'nat_' + secrets.token_urlsafe(24), 'nrt_' + secrets.token_urlsafe(24)
    with LOCK:
        NOUS['access'][at] = {'exp': time.time() + ttl, 'family': family, 'ttl': ttl}
        NOUS['refresh'][rt] = {'family': family, 'used': False, 'ttl': ttl}
    return {'access_token': at, 'refresh_token': rt, 'token_type': 'Bearer', 'expires_at': int(time.time() + ttl),
            'provider': 'nous', 'user_id': NOUS_USER}


def nous_refresh(token):
    with LOCK:
        NOUS['counts']['refresh'] += 1
        entry = NOUS['refresh'].get(token)
        if entry and entry['used']:
            # A replayed refresh token is theft to Portal: the whole family goes.
            NOUS['counts']['replayed'] += 1
            for table in ('access', 'refresh'):
                for key in [k for k, v in NOUS[table].items() if v['family'] == entry['family']]:
                    NOUS[table].pop(key, None)
            return None
        if not entry:
            return None
        entry['used'] = True
        # The spent access token dies with its refresh token (one live pair per family).
        for key in [k for k, v in NOUS['access'].items() if v['family'] == entry['family']]:
            NOUS['access'].pop(key, None)
    return nous_issue(entry['ttl'], entry['family'])


# ── prompts carry their session (the runtime id the call named) ────────────────────────────────────────────────────────

class PromptList(list):
    def append(self, entry):
        entry.setdefault('session', getattr(TLS, 'prompt_session', None))
        super().append(entry)


att.PROMPTS = PromptList()


# ── the roster answer ──────────────────────────────────────────────────────────────────────────────────────────────────

def shaped_roster(result):
    result = copy.deepcopy(result)
    rows = result.get('profiles') or []
    with LOCK:
        shape = copy.deepcopy(ROSTER)
    for row in rows:
        name = row.get('name')
        active = shape['lastActive'].get(name, START_ACTIVE.get(name))
        for session in [row.get('canonical_session')] + list(row.get('sessions') or []):
            if isinstance(session, dict) and active:
                session['last_active'] = active
        if name in shape['hidden']:
            row.setdefault('ui_meta', {}).setdefault('hermes-bots', {})['hidden'] = True
        if name in shape['noChat']:
            row.pop('canonical_session', None)
            row['sessions'] = []
    for index in range(1, int(shape['extra']) + 1):
        name = f'load-{index:03d}'
        session = {**voice.row('default'), 'id': f'20260930_120000_{index:08x}', 'profile': name, 'profile_name': name,
                   'last_active': 1790600000 - index * 60, 'started_at': 1790600000 - index * 60}
        rows.append({'name': name, 'is_active': False, 'description': 'Synthetic load bot', 'model': 'fixture-model',
                     'canonical_session': session, 'sessions': [session],
                     'ui_meta': {'hermes-bots': {'display_name': f'Load {index:03d}'}}})
    result['profiles'] = rows
    return result


def jpeg_pixels(data):
    """[width, height] from a JPEG's frame header (SOF0-SOF15, never DHT/JPG/DAC), or None."""
    if data[:2] != b'\xff\xd8':
        return None
    at = 2
    while at + 9 < len(data):
        if data[at] != 0xff:
            return None
        marker = data[at + 1]
        if marker == 0xff:
            at += 1
            continue
        if 0xd0 <= marker <= 0xd9 or marker == 0x01:
            at += 2
            continue
        length = struct.unpack('>H', data[at + 2:at + 4])[0]
        if 0xc0 <= marker <= 0xcf and marker not in (0xc4, 0xc8, 0xcc):
            height, width = struct.unpack('>HH', data[at + 5:at + 9])
            return [width, height]
        at += 2 + length
    return None


def runtime_ids():
    return {hashlib.sha256(stored.encode()).hexdigest()[:8] for stored in voice.SIDS.values()}


# ── the socket ─────────────────────────────────────────────────────────────────────────────────────────────────────────

class DropAnswer:
    """A client whose answer goes missing: the call is taken, then the socket closes without a reply."""
    def __init__(self, client):
        self.client, self.connection, self.lock = client, client.connection, client.lock

    def send(self, value):
        if 'id' in value and 'method' not in value:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            return
        self.client.send(value)


def run_prompt(client, frame, entry, number):
    """prompt.submit on its own thread: the server request first when asked, then holds and faults, then the turn."""
    params = frame.get('params') or {}
    TLS.prompt_session = params.get('session_id')
    try:
        with LOCK:
            before = SERVER_REQUEST['before'] == 'prompt.submit'
            if before:
                SERVER_REQUEST['before'] = None
                COUNTS['serverRequests'] += 1
        if before:
            # What a bot asking for approval sends: a frame with both `method` and `id`. A share never answers it.
            client.send({'jsonrpc': '2.0', 'id': 'fixture-request-' + secrets.token_hex(3), 'method': 'approval.request',
                         'params': {'session_id': params.get('session_id'), 'request_id': 'fixture-approval',
                                    'command': 'printf synthetic', 'description': 'Synthetic approval request'}})
            time.sleep(0.6)
        fault = take(FAULTS, 'prompt.submit')
        if fault and 'code' in fault:
            entry['error'] = fault['code']
            return client.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': fault['code'], 'message': fault.get('message', '')}})
        if fault and 'result' in fault:
            entry['status'] = 'forced'
            return client.send({'jsonrpc': '2.0', 'id': frame['id'], 'result': fault['result']})
        if set(params) - att.PROMPT_KEYS:
            entry['error'] = 4000           # att.prompt below answers it (its strict check) and stores nothing
        elif params.get('session_id') not in runtime_ids():
            entry['error'] = 4001
            return client.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': 4001, 'message': 'session not found'}})
        hold = take(HOLDS, 'prompt.submit')
        target = client
        if hold:
            with LOCK:
                HELD.append('prompt.submit')
            if hold.get('drop'):
                time.sleep(float(hold.get('seconds') or 0))
                target = DropAnswer(client)
                entry['dropped'] = True
            else:
                # The prompt is taken at once; only its answer is late.
                with LOCK:
                    b47.PLANS.insert(0, {'ackDelay': float(hold.get('seconds') or 0), 'replyText': 'Received the held share.'})
        att.prompt(target, frame)
        entry['status'] = 'taken'
    except OSError:
        entry['status'] = 'socket-closed'
    finally:
        flush(entry)


def websocket(connection, key):
    upgrade = getattr(TLS, 'upgrade', None)
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '
                        + accept + '\r\n\r\n').encode())
    client = b47.Client(connection)
    with LOCK:
        COUNTS['sockets'] += 1
        number = COUNTS['sockets']
    if upgrade is not None:
        upgrade['status'], upgrade['socket'] = 101, number
        flush(upgrade)

    def read(n):
        data = b''
        while len(data) < n:
            chunk = connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data

    if take(FAULTS, 'socket'):
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        return
    with LOCK:
        b47.CLIENTS.add(client)
    try:
        if not take(FAULTS, 'ready'):
            client.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
                'heartbeat': True, 'change_events': True, 'replay_epoch': 'share', 'desktop_contract': 8}}})
        fragments = bytearray()
        while True:
            first, second = read(2)
            opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126:
                n = struct.unpack('>H', read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', read(8))[0]
            if n > 16 * 1024 * 1024:
                raise ValueError('Oversized fixture frame')
            mask = read(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(n)))
            if opcode == 8:
                return
            if opcode == 9:
                with client.lock:
                    connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 1:
                fragments = bytearray(payload)
            elif opcode == 0:
                fragments.extend(payload)
            else:
                continue
            if not final:
                continue
            frame = json.loads(fragments)
            fragments.clear()
            if not isinstance(frame, dict):
                continue
            if 'method' not in frame:
                if 'id' in frame:       # an answer to a server request: a share must never send one
                    with LOCK:
                        COUNTS['serverRequestReplies'] += 1
                    record({'kind': 'reply', 'socket': number, 'keys': sorted(frame)})
                continue
            if 'id' not in frame:
                continue
            method, params = frame['method'], frame.get('params') or {}
            entry = record({'kind': 'rpc', 'rpc': method, 'socket': number, 'id': str(frame['id'])[:40],
                            'keys': sorted(params) if isinstance(params, dict) else [],
                            'sizes': {k: len(v) if isinstance(v, str) else None for k, v in params.items()} if isinstance(params, dict) else {},
                            'session': params.get('session_id') if isinstance(params, dict) else None,
                            'profile': params.get('profile') if isinstance(params, dict) else None,
                            'queued': params.get('queued') if isinstance(params, dict) and method == 'prompt.submit' else None})
            if not isinstance(params, dict):
                params = {}
            if method == 'prompt.submit':
                threading.Thread(target=run_prompt, args=(client, frame, entry, number), daemon=True).start()
                continue
            answer = {'jsonrpc': '2.0', 'id': frame['id']}
            hold = take(HOLDS, method)
            if hold:
                with LOCK:
                    HELD.append(method)
                time.sleep(float(hold.get('seconds') or 0))
            fault = take(FAULTS, method)
            try:
                if fault and 'code' in fault:
                    raise att.RPCFail(fault['code'], fault.get('message', ''))
                if fault and 'result' in fault:
                    answer['result'] = fault['result']
                elif method == 'session.resume' and set(params) - RESUME_KEYS:
                    raise att.RPCFail(4000, 'invalid params')
                elif method == 'client.capabilities':
                    if set(params) - CAPABILITY_KEYS:
                        raise att.RPCFail(4000, 'invalid params')
                    answer['result'] = {'server_requests': ['approval.request', 'clarify.request'], 'declines_not_shown': True}
                elif method == 'profiles.list':
                    answer['result'] = shaped_roster(b47.rpc(method, params))
                else:
                    answer['result'] = b47.rpc(method, params)
            except att.RPCFail as fail:
                answer['error'] = {'code': fail.code, 'message': fail.message}
                entry['error'] = fail.code
            except ValueError as error:
                answer['error'] = {'code': -32001, 'message': str(error)}
                entry['error'] = -32001
            flush(entry)
            if hold and hold.get('drop'):
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return
            client.send(answer)
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        with LOCK:
            b47.CLIENTS.discard(client)


auth.websocket = websocket


# ── HTTP ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

def reset_all():
    with LOCK:
        for records in (att.UPLOADS, att.DELETES, att.ATTACH_LEDGER, att.PROMPTS, att.DOWNLOADS, b47.LEDGER, b47.PLANS,
                        SHARE_LEDGER, HELD, REDIRECTED):
            records.clear()
        for profile in att.ATTACHED:
            att.ATTACHED[profile] = []
        att.PENDING_IMAGES.clear()
        att.CONTROL.update(att.DEFAULT_CONTROL)
        for profile in b47.RUNNING:
            b47.CANCEL[profile].set()
            b47.RUNNING[profile] = False
        for profile in b47.MESSAGES:
            b47.MESSAGES[profile] = [{'role': 'assistant', 'content': 'Build 47 synthetic acceptance chat.', 'row_id': 1,
                                      'timestamp': 1790852400}]
        for gate in b47.ACKS:
            gate.set()
        b47.ACKS.clear()
        FAULTS.clear()
        HOLDS.clear()
        ROSTER.update({'hidden': [], 'noChat': [], 'extra': 0, 'lastActive': {}})
        SERVER_REQUEST['before'] = None
        for key in COUNTS:
            if key != 'sockets':
                COUNTS[key] = 0
        NOUS['access'].clear()
        NOUS['refresh'].clear()
        for key in NOUS['counts']:
            NOUS['counts'][key] = 0
        TICKETS.clear()
        for sub in ('uploads', 'home-attachments'):
            folder = att.FILES / sub
            shutil.rmtree(folder, ignore_errors=True)
            folder.mkdir(parents=True, exist_ok=True)
            os.chmod(folder, 0o700)


def staged_on_disk():
    """What is on this gateway's disk under uploads/.dispatch-attachments right now: "<folder>/<name>", sorted."""
    root = att.FILES / 'uploads' / '.dispatch-attachments'
    if not root.is_dir():
        return []
    return sorted(str(item.relative_to(root)) for item in root.rglob('*') if item.is_file())


def movie_location(data):
    """An ISO 6709 location string (`+37.3349-122.0090+010.000/`) anywhere in a movie's bytes."""
    return re.search(rb'[+-]\d{2}\.\d{2,}[+-]\d{3}\.\d{2,}', data) is not None


def handler(gateway):
    base = att.handler(gateway)

    class Handler(base):
        last_status = None

        def send_response(self, code, message=None):
            self.last_status = code
            super().send_response(code, message)

        def session(self):
            # A Nous bearer is a session (Hermes' gated auth middleware); cookies stay as before.
            value = self.headers.get('Authorization') or ''
            if not value.startswith('Bearer '):
                return super().session()
            with LOCK:
                entry = NOUS['access'].get(value[7:])
                ok = bool(entry and entry['exp'] > time.time())
                NOUS['counts']['bearerOk' if ok else 'bearerRejected'] += 1
            return ok

        def auth_kind(self):
            if (self.headers.get('Authorization') or '').startswith('Bearer '):
                return 'bearer'
            return 'cookie' if 'hermes_session_' in (self.headers.get('Cookie') or '') else 'none'

        def swallow(self):
            return self.rfile.read(int(self.headers.get('Content-Length') or 0))

        def html(self, body):
            data = body.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def gate(self, method, serve):
            """Ledger, holds and faults around one request; `serve` is the layer below."""
            parsed = urlparse(self.path)
            path = parsed.path
            if path.startswith('/__fixture/'):
                return serve()
            upgrade = path == '/api/ws' and (self.headers.get('Upgrade') or '').lower() == 'websocket'
            entry = record({'kind': 'upgrade' if upgrade else 'http', 'method': method, 'path': path,
                            'keys': sorted(parse_qs(parsed.query)), 'ua': (self.headers.get('User-Agent') or '')[:120],
                            'auth': self.auth_kind(), 'cookie': bool(self.headers.get('Cookie')),
                            'profile': (parse_qs(parsed.query).get('profile') or [None])[0]})
            target = REST_TARGETS.get((method, path))
            hold = take(HOLDS, target) if target else None
            if hold:
                with LOCK:
                    HELD.append(target)
                time.sleep(float(hold.get('seconds') or 0))
                if hold.get('drop'):
                    self.swallow()
                    entry['status'] = 'dropped'
                    flush(entry)
                    self.close_connection = True
                    try:
                        self.connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    return
            fault = take(FAULTS, target) if target else None
            if fault:
                self.swallow()
                if fault.get('html'):
                    self.html('<!doctype html><title>Not Hermes</title><p>A synthetic page, not JSON.</p>')
                elif 'body' in fault:
                    self.reply(200, fault['body'])
                elif int(fault.get('status', 500)) == 302:
                    self.send_response(302)
                    self.send_header('Location', f'http://127.0.0.1:{REDIRECT_PORT or 9}{path}')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                else:
                    self.reply(int(fault.get('status', 500)), {'detail': 'Synthetic fault'})
                entry['status'], entry['fault'] = self.last_status, True
                return flush(entry)
            if upgrade:
                ticket = (parse_qs(parsed.query).get('ticket') or [None])[0]
                if ticket is not None:
                    with LOCK:
                        live = TICKETS.pop(ticket, 0) > time.time()
                    if not live:
                        entry['status'] = 401
                        flush(entry)
                        return self.reply(401, {'detail': 'Unauthorized'})
                TLS.upgrade = entry
                try:
                    return serve()
                finally:
                    TLS.upgrade = None
            serve()
            entry['status'] = self.last_status
            flush(entry)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/nous':
                with LOCK:
                    return self.reply(200, {'counts': dict(NOUS['counts'])})
            if path == '/__fixture/page':
                return self.html(PAGE)
            if path == '/__fixture/state':
                with LOCK:
                    return self.reply(200, {
                        **voice.state, 'ledger': list(b47.LEDGER), 'running': b47.RUNNING, 'plans': b47.PLANS,
                        'uploads': att.UPLOADS, 'deletes': att.DELETES, 'attached': att.ATTACHED,
                        'attachLedger': att.ATTACH_LEDGER, 'prompts': list(att.PROMPTS), 'downloads': att.DOWNLOADS,
                        'control': att.CONTROL, 'messages': {p: rows[-40:] for p, rows in b47.MESSAGES.items()},
                        'shareLedger': list(SHARE_LEDGER), 'held': list(HELD), 'redirected': list(REDIRECTED),
                        'serverRequestReplies': COUNTS['serverRequestReplies'], 'serverRequests': COUNTS['serverRequests'],
                        'roster': copy.deepcopy(ROSTER), 'faults': sorted(FAULTS), 'holds': sorted(HOLDS),
                        'staged': staged_on_disk()})
            return self.gate('GET', super().do_GET)

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/share-reset':
                self.swallow()
                reset_all()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/share-roster':
                body = self.json_body()
                with LOCK:
                    for key in ('hidden', 'noChat'):
                        if key in body:
                            ROSTER[key] = [str(name) for name in body[key] or []]
                    if 'extra' in body:
                        ROSTER['extra'] = max(0, min(1000, int(body['extra'] or 0)))
                    if 'lastActive' in body:
                        ROSTER['lastActive'] = {str(k): float(v) for k, v in (body['lastActive'] or {}).items()}
                    return self.reply(200, copy.deepcopy(ROSTER))
            if path in ('/__fixture/share-fail', '/__fixture/share-hold'):
                body = self.json_body()
                target = str(body.get('target') or body.get('method') or '')
                if not target:
                    return self.reply(400, {'detail': 'target required'})
                with LOCK:
                    (FAULTS if path.endswith('fail') else HOLDS)[target] = {**body, 'times': int(body.get('times', 1))}
                return self.reply(200, {'ok': True, 'target': target})
            if path == '/__fixture/share-sim':
                done = sim_set(self.json_body())
                return self.reply(400, {'detail': done}) if isinstance(done, str) else self.reply(200, done)
            if path == '/__fixture/share-server-request':
                body = self.json_body()
                with LOCK:
                    SERVER_REQUEST['before'] = body.get('before') or 'prompt.submit'
                return self.reply(200, {'ok': True})
            if path == '/__fixture/nous/issue':
                body = self.json_body()
                return self.reply(200, nous_issue(int(body.get('ttl') or 3600)))
            if path == '/__fixture/nous/revoke':
                self.swallow()
                with LOCK:
                    NOUS['access'].clear()
                    NOUS['refresh'].clear()
                return self.reply(200, {'ok': True})
            return self.gate('POST', self.post)

        def post(self):
            path = urlparse(self.path).path
            if path == '/auth/native/refresh':
                asked = self.json_body()
                pair = nous_refresh(str(asked.get('refresh_token') or '')) if asked.get('provider') == 'nous' else None
                return self.reply(200, pair) if pair else self.reply(401, {'error': 'session_expired'})
            if path == '/api/auth/ws-ticket':
                self.swallow()
                if not self.session():
                    return self.reply(401, {'detail': 'Unauthorized'})
                ticket = secrets.token_urlsafe(16)
                with LOCK:
                    TICKETS[ticket] = time.time() + 30
                return self.reply(200, {'ticket': ticket, 'ttl_seconds': 30})
            return super().do_POST()

        def do_DELETE(self):
            return self.gate('DELETE', super().do_DELETE)

        def upload(self):
            super().upload()
            # A movie that still says where it was filmed is what the share must never send.
            with LOCK:
                pending = [entry for entry in att.UPLOADS if entry.get('status') == 200 and 'location' not in entry]
            for entry in pending:
                path = str(entry.get('path') or '')
                target = att.real(path)
                movie = path.lower().endswith(('.mov', '.mp4', '.m4v'))
                data = target.read_bytes() if target is not None and target.is_file() else b''
                found = bool(movie and movie_location(data))
                with LOCK:
                    entry['location'], entry['movie'] = found, movie
                    entry['pixels'] = jpeg_pixels(data)      # [width, height] of a JPEG, else None

    return Handler


def redirect_handler():
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def answer(self):
            self.rfile.read(int(self.headers.get('Content-Length') or 0))
            with LOCK:
                REDIRECTED.append({'method': self.command, 'path': urlparse(self.path).path, 'cookie': bool(self.headers.get('Cookie')),
                                   'authorization': bool(self.headers.get('Authorization')), 't': round(time.time(), 3)})
            data = b'{"redirected": true}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_GET = do_POST = do_DELETE = do_PUT = do_PATCH = answer

    return Handler


def main():
    global LOG, REDIRECT_PORT, SIM
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--credentials', required=True, help='written 0600, never printed: {"username","password","url"}')
    parser.add_argument('--files', required=True, help='a folder for uploads and generated media (0700)')
    parser.add_argument('--log', help='the ledger as JSON lines')
    parser.add_argument('--access-ttl', type=int, default=12 * 60 * 60)
    parser.add_argument('--redirect-port', type=int, help='a second listener in 9910-9919 that only counts requests')
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--sim', help='a simulator UDID: POST /__fixture/share-sim may set its text size and appearance')
    args = parser.parse_args()
    if args.sim and not re.fullmatch(r'[0-9A-Fa-f-]{36}', args.sim):
        sys.exit('--sim takes a simulator UDID')
    SIM = args.sim
    if args.port not in PORTS:
        sys.exit('refusing a port outside 9910-9919 (the share stream\'s)')
    if args.redirect_port is not None and (args.redirect_port not in PORTS or args.redirect_port == args.port):
        sys.exit('refusing a redirect port outside 9910-9919')
    att.FILES = pathlib.Path(args.files).resolve()
    if att.FILES.exists():
        shutil.rmtree(att.FILES)
    att.FILES.mkdir(parents=True)
    os.chmod(att.FILES, 0o700)
    att.make_media()
    LOG, REDIRECT_PORT = args.log, args.redirect_port
    if LOG:
        pathlib.Path(LOG).parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.close(descriptor)
    username, password = 'share-fixture', secrets.token_urlsafe(24)
    if args.keep_credentials and pathlib.Path(args.credentials).exists():
        kept = json.loads(pathlib.Path(args.credentials).read_text())
        username, password = kept['username'], kept['password']
    # Stress runs open many connections at once: the default backlog of 5 would refuse some before they are seen.
    ThreadingHTTPServer.request_queue_size = 128
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(
        auth.Gateway(username, password, True, None, hermes=True, access_ttl=args.access_ttl)))
    if args.redirect_port is not None:
        other = ThreadingHTTPServer(('127.0.0.1', args.redirect_port), redirect_handler())
        threading.Thread(target=other.serve_forever, daemon=True).start()
    pathlib.Path(args.credentials).parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{args.port}'}, file)
    print(f'Share fixture on 127.0.0.1:{args.port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
