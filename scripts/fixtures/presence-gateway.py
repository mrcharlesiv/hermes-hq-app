#!/usr/bin/env python3
"""HQ Native presence fixture (docs/spec/3x-presence.md §12.2): the Watch Browser fixture (browser-gateway.py, itself
REF's performance fixture plus a stand-in hermes-hq-browser plugin) with what the presence stream needs on top.
Loopback only (127.0.0.1); every value is invented; nothing is forwarded.

Adds:
  profiles.list / profiles.configure   per-profile ui_meta and ui_meta_revisions, with Hermes' per-key compare-and-swap
                                       (configure_ui_meta, ported from scripts/fixtures/settings-gateway.py)
  the plugin's list                    one row per bot (POST /__fixture/presence {browsers}); any listed id can be watched
  an outage                            {gateway: "down"} closes every socket and answers 503 until {gateway: "up"}
  --bots N                             N more bots (bot-01 …) beside default (Hermes) and ivy (Ivy), each with a chat

Fixture control (no auth, like the other controls):
  POST /__fixture/presence   any of
      browsers:  [{profile, active?, url?, ask?, control?, id?, session_id?, agent_at?}] | null (back to the browser
                 fixture's own single row)
      configure: "ok" | "applied-false" | "old-gateway" | "refuse" | "hang", or {mode, count} for the next `count` calls
      edit:      {profile, screenAutoOpen}       another device changes the flag (revision + 1; null removes it)
      rename:    {profile, display_name}         another device renames the bot (long, emoji and right-to-left names)
      gateway:   "down" | "up"
      activity:  "drop" | "garbage" | "huge"
      flood:     {bots, rate, seconds}           that many list frames a second, hosts changing every frame
      burst:     {profile, name, count, interval_ms, complete?}   that many tool.start events (and tool.complete)
  GET  /__fixture/presence   {configure_calls: [{name, ui_meta, expected, mode}], ui_meta, revisions, activity_sockets,
                              watch_sockets, ws_clients, health_calls, gateway, configure, activity_opens, watch_opens,
                              max_activity_sockets, max_watch_sockets, browsers}
  POST /__fixture/presence/reset   (also resets the browser fixture's state, the chats and the prompt plans)

  python3 scripts/fixtures/presence-gateway.py --port 9930 --credentials build/fixtures/e2e-presence.json \
      --frames build/fixtures/browser-frames [--bots 50]
"""
import copy, hashlib, importlib.util, json, pathlib, socket, struct, sys, threading, time
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('hqn_presence_browser', HERE / 'browser-gateway.py')
bg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bg)
base = bg.base            # REF's build 47 gateway: /api/ws, streaming, the prompt ledger
voice = base.voice
PLUGIN = bg.PLUGIN
LEGACY_PLUGIN = '/api/plugins/dispatch-browser'
LOCK = bg.LOCK
MODES = ('ok', 'applied-false', 'old-gateway', 'refuse', 'hang')


def fresh():
    return {'browsers': None, 'configure': 'ok', 'configure_left': None, 'gateway': 'up', 'configure_calls': [],
            'health_calls': 0, 'activity_opens': 0, 'watch_opens': 0, 'max_activity_sockets': 0, 'max_watch_sockets': 0,
            'flood': 0}


P = fresh()
META, REVS = {}, {}
SEED_SIDS = dict(voice.SIDS)


def display(profile):
    return {'default': 'Hermes', 'ivy': 'Ivy'}.get(profile) or 'Bot ' + profile.rsplit('-', 1)[-1]


def seed_meta():
    META.clear()
    REVS.clear()
    for profile in voice.SIDS:
        META[profile] = {'hermes-bots': {'display_name': display(profile)}}
        REVS[profile] = {}


def add_bots(count):
    for n in range(1, max(0, min(200, count)) + 1):
        name = f'bot-{n:02d}'
        voice.SIDS[name] = f'20260929_120000_aabbdd{n:02x}'
        base.MESSAGES[name] = [{'role': 'assistant', 'content': f'Synthetic presence chat {n}.', 'row_id': 1, 'timestamp': 1790852400}]
        base.RUNNING[name] = False
        base.CANCEL[name] = threading.Event()


# ---- profiles.list / profiles.configure ---------------------------------------------------------------------------
def profiles_list(params):
    include = params.get('include_sessions', True)
    include = include if isinstance(include, bool) else str(include).lower() not in ('0', 'false', 'no', '')
    rows = []
    with LOCK:
        for key in voice.SIDS:
            row = {'name': key, 'is_active': key == 'default', 'is_default': key == 'default',
                   'description': 'Synthetic presence QA', 'model': 'fixture-model',
                   'ui_meta': copy.deepcopy(META[key]), 'ui_meta_revisions': dict(REVS[key])}
            if include:
                row['canonical_session'] = voice.row(key)
                row['sessions'] = [voice.row(key)]
            rows.append(row)
    return {'active': 'default', 'profiles': rows}


def clean_revisions(raw):
    return {str(k): max(0, int(v)) for k, v in raw.items() if isinstance(v, int) and not isinstance(v, bool)}


def configure_ui_meta(p, params, applied):
    """Hermes' profiles.configure ui_meta (tui_gateway/methods_profiles.py), as scripts/fixtures/settings-gateway.py has it."""
    applied['ui_meta'] = False
    try:
        incoming = params['ui_meta']
        if len(json.dumps(incoming)) > 65536:
            return
        expected = params.get('ui_meta_expected_revisions')
        if expected is not None and not isinstance(expected, dict):
            raise ValueError('ui_meta_expected_revisions must be an object')
        revisions = clean_revisions(p['revisions'])
        conflicts = {}
        for key in (incoming if isinstance(expected, dict) else ()):
            wanted, actual = expected.get(key), revisions.get(key, 0)
            if not isinstance(wanted, int) or isinstance(wanted, bool) or wanted < 0 or wanted != actual:
                conflicts[key] = {'expected': wanted, 'actual': actual}
        if conflicts:
            applied['ui_meta_conflicts'] = conflicts
            applied['ui_meta_revisions'] = {key: revisions.get(key, 0) for key in incoming}
            return
        current = copy.deepcopy(p['ui_meta']) if isinstance(p['ui_meta'], dict) else {}
        for key, value in incoming.items():
            if value is None:
                current.pop(key, None)
            else:
                current[key] = value
            revisions[key] = revisions.get(key, 0) + 1
        p['ui_meta'] = current
        p['revisions'] = revisions
        applied['ui_meta'] = True
        applied['ui_meta_revisions'] = {key: revisions[key] for key in incoming}
    except Exception:
        applied['ui_meta'] = False


class NoAnswer(Exception):
    """The gateway took the call and never answers it."""


def take_mode():
    with LOCK:
        mode = P['configure']
        if P['configure_left'] is not None:
            P['configure_left'] -= 1
            if P['configure_left'] <= 0:
                P['configure'], P['configure_left'] = 'ok', None
    return mode


def profiles_configure(params):
    name = str(params.get('name') or '').strip()
    mode = take_mode()
    with LOCK:
        P['configure_calls'].append({'name': name, 'ui_meta': copy.deepcopy(params.get('ui_meta')),
                                     'expected': copy.deepcopy(params.get('ui_meta_expected_revisions')), 'mode': mode})
    if mode == 'hang':
        raise NoAnswer()
    if mode == 'refuse':
        raise ValueError('Synthetic refusal')
    if mode == 'old-gateway':
        return {}
    if mode == 'applied-false':
        return {'ok': False, 'applied': {'ui_meta': False}}
    if name not in META:
        raise ValueError(f"profile '{name}' not found")
    applied = {}
    with LOCK:
        if isinstance(params.get('ui_meta'), dict):
            p = {'ui_meta': META[name], 'revisions': REVS[name]}
            configure_ui_meta(p, params, applied)
            META[name], REVS[name] = p['ui_meta'], p['revisions']
    return {'ok': all(v is not False for v in applied.values()) if applied else True, 'applied': applied}


_base_rpc = base.rpc
_voice_rpc = voice.rpc


def logged(method, params):
    with voice.lock:
        voice.state['rpc'].append({'method': method, 'params': copy.deepcopy(params)})


def rpc(method, params):
    if method == 'profiles.list':
        logged(method, params)
        return profiles_list(params)
    if method == 'profiles.configure':
        logged(method, params)
        return profiles_configure(params)
    return _base_rpc(method, params)


def rest_rpc(method, params):
    return profiles_list(params) if method == 'profiles.list' else _voice_rpc(method, params)


base.rpc = rpc
voice.rpc = rest_rpc


def websocket(connection, key):
    """REF's build 47 /api/ws loop, with this fixture's rpc and a call that can go unanswered."""
    import base64
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    client = base.Client(connection)

    def read(n):
        data = b''
        while len(data) < n:
            chunk = connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data
    with base.LOCK:
        base.CLIENTS.add(client)
    try:
        client.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
            'heartbeat': True, 'change_events': True, 'replay_epoch': 'presence', 'desktop_contract': 8}}})
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
            if 'id' not in frame or 'method' not in frame:
                continue
            if frame['method'] == 'prompt.submit':
                threading.Thread(target=client.prompt, args=(frame,), daemon=True).start()
                continue
            answer = {'jsonrpc': '2.0', 'id': frame['id']}
            try:
                answer['result'] = rpc(frame['method'], frame.get('params') or {})
            except NoAnswer:
                continue
            except ValueError as error:
                answer['error'] = {'code': -32001, 'message': str(error)}
            client.send(answer)
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        with base.LOCK:
            base.CLIENTS.discard(client)


voice.auth.websocket = websocket


# ---- the plugin's list --------------------------------------------------------------------------------------------
def row_id(profile):
    return bg.BROWSER_ID if profile == 'default' else hashlib.sha256(('presence:' + profile).encode()).hexdigest()[:24]


def make_row(entry):
    profile = str(entry.get('profile') or 'default')
    sid = entry.get('session_id', voice.SIDS.get(profile, ''))
    now = time.time()
    active = bool(entry.get('active', True))
    return {'id': entry.get('id') or row_id(profile), 'profile': profile, 'session_id': sid, 'session_ids': [sid] if sid else [],
            'opened_at': now - 60, 'agent_at': entry.get('agent_at', now if active else now - 600),
            'url': entry.get('url', 'https://example.test/sign-in'), 'busy': 1 if active else 0, 'active': active,
            'control': entry.get('control', 'bot'), 'ask': entry.get('ask')}


_browser_listing = bg.listing


def listing():
    with LOCK:
        rows = P['browsers']
        if rows is None:
            return _browser_listing()
        return {'schema': 'dispatch-browser.list.v3', 'protocol': 3, 'browsers': [dict(r) for r in rows]}


bg.listing = listing


def listed(rid):
    with LOCK:
        return next((dict(r) for r in (P['browsers'] or []) if r.get('id') == rid), None)


class Watch(bg.Watch):
    """The browser fixture's fake page, for whichever listed browser was asked for."""
    def __init__(self, ws, rid):
        super().__init__(ws)
        self.rid = rid

    def state(self):
        state = super().state()
        state['browser'] = self.rid
        row = listed(self.rid)
        if row and row.get('url'):
            state['tabs'][0]['url'] = row['url']
        return state


def send_text(ws, text):
    body = text.encode()
    n = len(body)
    header = bytes([0x81]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536 else bytes([127]) + struct.pack('>Q', n))
    with ws.lock:
        ws.connection.sendall(header + body)


def to_activity(send):
    with LOCK:
        sockets = list(bg.ACTIVITY)
    for ws in sockets:
        try:
            send(ws)
        except OSError:
            pass


def hard_close(connection):
    try:
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def drop_activity():
    def drop(ws):
        ws.close(1011)
        hard_close(ws.connection)
    to_activity(drop)


def drop_everything():
    with base.LOCK:
        clients = list(base.CLIENTS)
    for client in clients:
        hard_close(client.connection)
    drop_activity()
    with LOCK:
        watchers = list(bg.WATCHERS)
    for watch in watchers:
        watch.alive = False
        watch.ws.close(1012)
        hard_close(watch.ws.connection)


def garbage():
    def send(ws):
        send_text(ws, 'this is not JSON {')
        ws.send({'schema': 'something-else.v9', 'browsers': []})
        ws.send({'schema': 'dispatch-browser.list.v3', 'protocol': 3, 'browsers': 'not a list'})
        ws.send(listing())
    to_activity(send)


def huge():
    def send(ws):
        ws.send({'schema': 'dispatch-browser.list.v3', 'protocol': 3, 'browsers': [], 'pad': 'x' * 300_000})
        ws.send(listing())
    to_activity(send)


def flood(bots, rate, seconds):
    with LOCK:
        P['flood'] += 1
        mine = P['flood']
    profiles = [p for p in voice.SIDS if p not in ('default', 'ivy')][:bots] or list(voice.SIDS)[:bots]
    frames = max(1, int(rate * seconds))
    for frame in range(frames):
        with LOCK:
            if P['flood'] != mine:
                return
            P['browsers'] = [make_row({'profile': p, 'url': f'https://site-{frame}-{i}.example.test/page'}) for i, p in enumerate(profiles)]
        current = listing()
        to_activity(lambda ws: ws.send(current))
        time.sleep(1.0 / max(1.0, rate))


def burst(profile, name, count, interval_ms, complete):
    for index in range(count):
        tool_id = f'presence-burst-{index}'
        base.emit(profile, 'tool.start', {'name': name, 'tool_id': tool_id, 'args': {}})
        if complete:
            base.emit(profile, 'tool.complete', {'name': name, 'tool_id': tool_id, 'args': {}, 'result': {'ok': True}})
        time.sleep(max(0, interval_ms) / 1000.0)


def sampler():
    while True:
        with LOCK:
            P['max_activity_sockets'] = max(P['max_activity_sockets'], len(bg.ACTIVITY))
            P['max_watch_sockets'] = max(P['max_watch_sockets'], len(bg.WATCHERS))
        time.sleep(0.02)


def snapshot():
    with base.LOCK:
        clients = len(base.CLIENTS)
    with LOCK:
        return {'configure_calls': copy.deepcopy(P['configure_calls']), 'ui_meta': copy.deepcopy(META), 'revisions': copy.deepcopy(REVS),
                'activity_sockets': len(bg.ACTIVITY), 'watch_sockets': len(bg.WATCHERS), 'ws_clients': clients,
                'health_calls': P['health_calls'], 'gateway': P['gateway'], 'configure': P['configure'],
                'activity_opens': P['activity_opens'], 'watch_opens': P['watch_opens'],
                'max_activity_sockets': P['max_activity_sockets'], 'max_watch_sockets': P['max_watch_sockets'],
                'browsers': copy.deepcopy(P['browsers'])}


def reset():
    with LOCK:
        for watch in list(bg.WATCHERS):
            watch.alive = False
            watch.ws.close()
        bg.STATE.clear()
        bg.STATE.update(bg.fresh_state())
        P.clear()
        P.update(fresh())
        seed_meta()
    with base.LOCK:
        base.PLANS.clear()
        base.LEDGER.clear()
        for gate in base.ACKS:
            gate.set()
        base.ACKS.clear()
        for profile in voice.SIDS:
            base.CANCEL[profile].set()
            base.RUNNING[profile] = False
            base.MESSAGES[profile] = [{'role': 'assistant', 'content': 'Synthetic presence chat.', 'row_id': 1, 'timestamp': 1790852400}]
    with voice.lock:
        voice.state['rpc'].clear()
        voice.state['rest'].clear()


def control(body):
    if 'browsers' in body:
        rows = body['browsers']
        with LOCK:
            P['flood'] += 1          # a flood under way stops
            P['browsers'] = None if rows is None else [make_row(e) for e in rows if isinstance(e, dict)]
            bg.bump()
    if 'configure' in body:
        value = body['configure']
        mode, left = (value.get('mode'), value.get('count')) if isinstance(value, dict) else (value, None)
        if mode not in MODES:
            return {'ok': False, 'detail': f'configure is one of {MODES}'}
        with LOCK:
            P['configure'], P['configure_left'] = mode, int(left) if isinstance(left, int) and left > 0 else None
    if isinstance(body.get('edit'), dict):
        profile, value = body['edit'].get('profile'), body['edit'].get('screenAutoOpen')
        if profile not in META:
            return {'ok': False, 'detail': 'unknown profile'}
        with LOCK:
            bots = dict(META[profile].get('hermes-bots') or {})
            if value is None:
                bots.pop('screenAutoOpen', None)
            else:
                bots['screenAutoOpen'] = value
            META[profile]['hermes-bots'] = bots
            REVS[profile]['hermes-bots'] = REVS[profile].get('hermes-bots', 0) + 1
    if isinstance(body.get('rename'), dict):
        profile, name = body['rename'].get('profile'), body['rename'].get('display_name')
        if profile not in META or not isinstance(name, str):
            return {'ok': False, 'detail': 'rename needs a known profile and a display_name'}
        with LOCK:
            bots = dict(META[profile].get('hermes-bots') or {})
            bots['title'] = name            # the name the apps show (displayName: the title, else the profile's name)
            META[profile]['hermes-bots'] = bots
            REVS[profile]['hermes-bots'] = REVS[profile].get('hermes-bots', 0) + 1
    if body.get('gateway') in ('down', 'up'):
        with LOCK:
            P['gateway'] = body['gateway']
        if body['gateway'] == 'down':
            drop_everything()
    if body.get('activity') == 'drop':
        drop_activity()
    elif body.get('activity') == 'garbage':
        garbage()
    elif body.get('activity') == 'huge':
        huge()
    if isinstance(body.get('flood'), dict):
        f = body['flood']
        args = (max(1, min(64, int(f.get('bots', 50)))), max(1.0, min(60.0, float(f.get('rate', 20)))), max(0.1, min(120.0, float(f.get('seconds', 30)))))
        threading.Thread(target=flood, args=args, daemon=True).start()
    if isinstance(body.get('burst'), dict):
        b = body['burst']
        profile = b.get('profile', 'ivy')
        if profile not in base.MESSAGES:
            return {'ok': False, 'detail': 'unknown profile'}
        args = (profile, b.get('name', 'browser_click'), max(0, min(5000, int(b.get('count', 500)))), float(b.get('interval_ms', 10)), bool(b.get('complete')))
        threading.Thread(target=burst, args=args, daemon=True).start()
    return {'ok': True}


# ---- the handler --------------------------------------------------------------------------------------------------
_browser_handler = base.handler


def handler(gateway):
    parent = _browser_handler(gateway)

    class Handler(parent):
        def read_json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try:
                value = json.loads(raw or b'{}')
            except ValueError:
                value = {}
            return value if isinstance(value, dict) else {}

        def outage(self, path):
            return P['gateway'] == 'down' and not path.startswith('/__fixture/')

        def do_GET(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            if self.outage(path):
                return self.reply(503, {'detail': 'Synthetic outage'})
            if path == '/__fixture/presence':
                return self.reply(200, snapshot())
            upgrade = (self.headers.get('Upgrade') or '').lower() == 'websocket'
            # The old plugin name is not on this gateway (the base fixture answers {} to any unknown read).
            if path.startswith(LEGACY_PLUGIN + '/'):
                if path.endswith('/health'):
                    with LOCK:
                        P['health_calls'] += 1
                return self.reply(404, {'detail': 'Not Found'})
            if path == PLUGIN + '/health':
                with LOCK:
                    P['health_calls'] += 1
            if upgrade and path == PLUGIN + '/activity':
                with LOCK:
                    P['activity_opens'] += 1
            sessions = PLUGIN + '/sessions/'
            if upgrade and path.startswith(sessions) and path.endswith('/watch'):
                with LOCK:
                    P['watch_opens'] += 1
                    own = P['browsers'] is not None
                if own:
                    if 'ticket' not in query or bg.STATE['plugin'] == 'missing':
                        return self.reply(401, {'detail': 'unauthorized'})
                    rid = path[len(sessions):-len('/watch')]
                    if listed(rid) is None:
                        return bg.upgrade(self).close(4404)
                    return Watch(bg.upgrade(self), rid).run()
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if self.outage(path):
                self.rfile.read(int(self.headers.get('Content-Length') or 0))
                return self.reply(503, {'detail': 'Synthetic outage'})
            if path == '/__fixture/presence':
                answer = control(self.read_json())
                return self.reply(200 if answer.get('ok') else 400, answer)
            if path == '/__fixture/presence/reset':
                self.read_json()
                reset()
                return self.reply(200, {'ok': True})
            return super().do_POST()

        def do_DELETE(self):
            if self.outage(urlparse(self.path).path):
                self.rfile.read(int(self.headers.get('Content-Length') or 0))
                return self.reply(503, {'detail': 'Synthetic outage'})
            return super().do_DELETE()

        def do_PATCH(self):
            if self.outage(urlparse(self.path).path):
                self.rfile.read(int(self.headers.get('Content-Length') or 0))
                return self.reply(503, {'detail': 'Synthetic outage'})
            return super().do_PATCH()
    return Handler


base.handler = handler


def take_option(name, default):
    if name not in sys.argv:
        return default
    at = sys.argv.index(name)
    value = sys.argv[at + 1]
    del sys.argv[at:at + 2]
    return value


if __name__ == '__main__':
    frames = take_option('--frames', 'build/fixtures/browser-frames')
    add_bots(int(take_option('--bots', '0')))
    seed_meta()
    bg.load_frames(frames)
    if not bg.FRAMES:
        sys.exit(f'no frames in {frames} (swift scripts/fixtures/make-browser-frames.swift {frames})')
    threading.Thread(target=sampler, daemon=True).start()
    base.main()       # binds 127.0.0.1 only
