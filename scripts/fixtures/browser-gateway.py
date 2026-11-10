#!/usr/bin/env python3
"""HQ Native Watch Browser fixture: REF's performance fixture plus a stand-in for the hermes-hq-browser plugin
(protocol 3, plus the 3.6 browser choice and 3.6.2's blocked / take-over). Loopback only; every value is invented; no
Chrome, nothing forwarded.

Plugin routes (cookie session for REST, a `ticket=` for websockets, like /api/ws):
  GET  /api/plugins/hermes-hq-browser/health | /bots | /sessions | /chrome-profiles | /choice?profile=
  POST /api/plugins/hermes-hq-browser/choice              {profile, mode?, source?, window?, refresh?} or {profile, take_over}
  WS   /api/plugins/hermes-hq-browser/activity           the browser list, pushed on change
  WS   /api/plugins/hermes-hq-browser/sessions/<id>/watch  hello, view, state, frames (JPEGs from --frames), acks,
                                                           take/give, input; a fake sign-in page whose username box is
                                                           at y 30–38 % and password box at 42–50 % (x 30–70 %)
Fixture control:
  POST /__fixture/browser  {active?, listed?, url?, ask?, choice_feature?, dialogs_feature?, plugin?: "ready"|"missing", frame_fps?,
                            blocked?: {profile: reason},   a bot whose browser the plugin doesn't run (3.6.2 codes)
                            dialog?: {id, kind, …} | null}  a box the page opened (3.7.0); an `answer` closes it
  GET  /__fixture/browser  {inputs, acks, frames_sent, hellos, views, control, choice (default's), choices, blocked,
                            take_overs, viewers}
  POST /__fixture/browser/reset
"""
import base64, hashlib, importlib.util, json, os, pathlib, socket, struct, sys, threading, time
from urllib.parse import urlparse, parse_qs

REF = pathlib.Path('/Users/me/Projects/hermes-hq-native-ref238/scripts')
_spec = importlib.util.spec_from_file_location('hqn_browser_perf', REF / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)
base = perf.base
PLUGIN = '/api/plugins/hermes-hq-browser'
BROWSER_ID = '0123456789abcdef01234567'
LOCK = threading.RLock()
FRAMES = []
CHROME_PROFILES = [{'dir': 'Default', 'name': 'Personal', 'account': 'person@example.test'},
                   {'dir': 'Profile 2', 'name': 'Work', 'account': None}]
FIELDS = {'username': (0.30, 0.38), 'password': (0.42, 0.50)}
TAKE_OVER = ('real_profile', 'released', 'external', 'fixed')   # what the plugin can take over (choice.py)
REFUSED = {'no_browser': "This bot’s browser tools are turned off in Hermes, so there’s no browser to run.",
           'off': "Hermes HQ’s browser add-on is switched off for this bot, so it can’t run its browser."}


def own_choice():
    return {'mode': 'own', 'source': None, 'window': 'hidden', 'copied_at': None}


def fresh_state():
    return {'active': False, 'listed': True, 'url': 'https://example.test/sign-in', 'ask': None, 'plugin': 'ready',
            'choice_feature': True, 'dialogs_feature': True, 'frame_fps': 60.0, 'control': 'bot', 'holder': None, 'epoch': 0, 'pointer': (0.5, 0.5),
            'focus': None, 'choices': {'default': own_choice()}, 'blocked': {}, 'take_overs': [], 'dialog': None,
            'inputs': [], 'acks': 0, 'frames_sent': 0, 'hellos': [], 'views': [], 'viewers': 0, 'version': 0}


STATE = fresh_state()
WATCHERS = set()     # Watch objects
ACTIVITY = set()     # WS objects


def bump():
    with LOCK:
        STATE['version'] += 1


def row():
    sid = base.voice.SIDS['default']
    now = time.time()
    return {'id': BROWSER_ID, 'profile': 'default', 'session_id': sid, 'session_ids': [sid], 'opened_at': now - 60,
            'agent_at': now if STATE['active'] else now - 600, 'url': STATE['url'], 'busy': 1 if STATE['active'] else 0,
            'active': STATE['active'], 'control': STATE['control'], 'ask': STATE['ask']}


def listing():
    with LOCK:
        rows = [row()] if STATE['listed'] else []
    return {'schema': 'dispatch-browser.list.v3', 'protocol': 3, 'browsers': rows}


def field_at(x, y):
    if not (0.30 <= x <= 0.70):
        return None
    for kind, (top, bottom) in FIELDS.items():
        if top <= y <= bottom:
            return kind
    return None


class WS:
    """A minimal server websocket (text frames; client frames are masked)."""
    def __init__(self, connection):
        self.connection = connection
        self.lock = threading.Lock()
        self.open = True

    def send(self, value):
        body = json.dumps(value).encode()
        n = len(body)
        header = bytes([0x81]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536 else bytes([127]) + struct.pack('>Q', n))
        with self.lock:
            self.connection.sendall(header + body)

    def close(self, code=1000):
        if not self.open:
            return
        self.open = False
        try:
            with self.lock:
                self.connection.sendall(bytes([0x88, 2]) + struct.pack('>H', code))
        except OSError:
            pass

    def read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data

    def receive(self):
        """The next text message, or None once closed."""
        fragments = bytearray()
        while True:
            first, second = self.read(2)
            opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126:
                n = struct.unpack('>H', self.read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', self.read(8))[0]
            mask = self.read(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.read(n)))
            if opcode == 8:
                self.close()
                return None
            if opcode == 9:
                with self.lock:
                    self.connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode in (0, 1):
                fragments.extend(payload)
                if final:
                    return fragments.decode()


def upgrade(handler):
    key = handler.headers['Sec-WebSocket-Key']
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    handler.connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    handler.close_connection = True
    return WS(handler.connection)


def activity(ws):
    with LOCK:
        ACTIVITY.add(ws)
    last, pinged = None, time.time()
    stop = threading.Event()

    def drain():
        try:
            while ws.receive() is not None:
                pass
        except (ConnectionError, OSError):
            pass
        stop.set()
    threading.Thread(target=drain, daemon=True).start()
    try:
        while not stop.is_set():
            current = listing()
            if current != last:
                last = current
                ws.send(current)
            elif time.time() - pinged > 20:
                pinged = time.time()
                ws.send({'type': 'ping'})
            stop.wait(0.25)
    except OSError:
        pass
    finally:
        with LOCK:
            ACTIVITY.discard(ws)
        ws.close()


class Watch:
    def __init__(self, ws):
        self.ws = ws
        self.viewer = None
        self.in_flight = 0
        self.seq = 0
        self.wake = threading.Event()
        self.alive = True
        self.sent_version = -1

    def state(self):
        with LOCK:
            mine = STATE['holder'] == self.viewer and self.viewer is not None
            control = STATE['control']
            under = field_at(*STATE['pointer']) if mine and control == 'person' else None
            field = {'under': under, 'focus': STATE['focus']} if mine and control == 'person' else None
            return {'type': 'state', 'browser': BROWSER_ID, 'tabs': [{'id': 'tab-1', 'title': 'Example Sign In', 'url': STATE['url']}],
                    'tab': 'tab-1', 'follow': True, 'control': {'state': control, 'mine': mine, 'epoch': STATE['epoch'] if mine else None},
                    'ask': STATE['ask'], 'field': field, 'dialog': STATE['dialog']}

    def push_state(self):
        try:
            self.ws.send(self.state())
        except OSError:
            self.alive = False

    def frames(self):
        index = 0
        while self.alive:
            fps = max(1.0, float(STATE['frame_fps']))
            if self.in_flight < 2 and FRAMES:
                self.seq += 1
                index = (index + 1) % len(FRAMES)
                try:
                    self.ws.send({'type': 'frame', 'seq': self.seq, 'tab': 'tab-1', 'epoch': STATE['epoch'] or None,
                                  'width': 1280, 'height': 720, 'image': FRAMES[index]})
                except OSError:
                    self.alive = False
                    return
                self.in_flight += 1
                with LOCK:
                    STATE['frames_sent'] += 1
            self.wake.wait(1.0 / fps)
            self.wake.clear()

    def handle(self, message):
        kind = message.get('type')
        epoch = message.get('epoch')
        with LOCK:
            if kind == 'ack':
                STATE['acks'] += 1
                self.in_flight = max(0, self.in_flight - 1)
                self.wake.set()
                return
            if kind == 'view':
                STATE['views'].append({k: message.get(k) for k in ('width', 'height', 'scale')})
                return
            if kind in ('pong', 'tab', 'follow'):
                return
            if kind == 'take':
                STATE['control'], STATE['holder'] = 'waiting', self.viewer
                bump()
                threading.Timer(0.4, self.granted).start()
                return
            if kind == 'give':
                STATE['control'], STATE['holder'], STATE['focus'] = 'bot', None, None
                bump()
                return
            held = STATE['holder'] == self.viewer and STATE['control'] == 'person' and epoch == STATE['epoch']
            if not held:
                self.ws.send({'type': 'error', 'message': 'Take control first.'})
                return
            entry = {'type': kind}
            for key in ('x', 'y', 'dx', 'dy', 'key', 'url', 'action', 'text', 'id', 'accept', 'account'):
                if key in message:
                    entry[key] = message[key]
            entry['field'] = STATE['focus']
            STATE['inputs'].append(entry)
            if kind in ('move', 'tap', 'down', 'up', 'scroll'):
                STATE['pointer'] = (float(message.get('x', 0.5)), float(message.get('y', 0.5)))
                if kind == 'tap':
                    STATE['focus'] = field_at(*STATE['pointer'])
                bump()
            elif kind == 'go':
                STATE['url'] = message.get('url') or STATE['url']
                bump()
            elif kind == 'copy':
                self.ws.send({'type': 'copied', 'text': 'Example Sign In'})
            elif kind == 'answer' and STATE['dialog'] and message.get('id') == STATE['dialog'].get('id'):
                STATE['dialog'] = None   # Chrome closes the box
                bump()

    def granted(self):
        with LOCK:
            if STATE['control'] == 'waiting' and STATE['holder'] == self.viewer:
                STATE['control'] = 'person'
                STATE['epoch'] += 1
                bump()

    def run(self):
        try:
            first = self.ws.receive()
            hello = json.loads(first or '{}')
            self.viewer = hello.get('viewer') if hello.get('type') == 'hello' else None
            with LOCK:
                STATE['hellos'].append(self.viewer)
                STATE['viewers'] += 1
                WATCHERS.add(self)
            threading.Thread(target=self.frames, daemon=True).start()
            threading.Thread(target=self.states, daemon=True).start()
            self.push_state()
            while self.alive:
                text = self.ws.receive()
                if text is None:
                    break
                try:
                    self.handle(json.loads(text))
                except ValueError:
                    continue
        except (ConnectionError, OSError, ValueError):
            pass
        finally:
            self.alive = False
            self.wake.set()
            with LOCK:
                WATCHERS.discard(self)
                STATE['viewers'] -= 1
            self.ws.close()

    def states(self):
        pinged = time.time()
        while self.alive:
            with LOCK:
                version = STATE['version']
            if version != self.sent_version:
                self.sent_version = version
                self.push_state()
            if time.time() - pinged > 10:
                pinged = time.time()
                try:
                    self.ws.send({'type': 'ping'})
                except OSError:
                    self.alive = False
            time.sleep(0.05)


_perf_handler = base.handler


def handler(gateway):
    parent = _perf_handler(gateway)

    class Handler(parent):
        def body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            return json.loads(raw or b'{}')

        def plugin_get(self, path, query):
            if STATE['plugin'] == 'missing':
                return self.reply(404, {'detail': 'Not Found'})
            route = path[len(PLUGIN):]
            if route == '/health':
                return self.reply(200, {'ok': True, 'schema': 'dispatch-browser.health.v3', 'version': '3.7.0' if STATE['dialogs_feature'] else '3.6.2', 'protocol': 3,
                                        'installed': True, 'missing': [], 'drift': [],
                                        'features': {'watch': True, 'control': True, 'ask': True, 'own_chrome': True,
                                                     'choice': bool(STATE['choice_feature']), 'dialogs': bool(STATE['dialogs_feature'])}})
            if route == '/bots':
                return self.reply(200, {'schema': 'dispatch-browser.bots.v1', 'own_chrome': True,
                                        'bots': [{'profile': 'default', 'status': 'ready', 'port': 9222}]})
            if route == '/sessions':
                return self.reply(200, listing())
            if route == '/chrome-profiles' and STATE['choice_feature']:
                return self.reply(200, {'schema': 'hermes-hq-browser.chrome-profiles.v1', 'supported': True,
                                        'browser': 'Google Chrome', 'profiles': CHROME_PROFILES, 'last_used': 'Default'})
            if route == '/choice' and STATE['choice_feature']:
                return self.reply(200, self.choice(query.get('profile', ['default'])[0]))
            return self.reply(404, {'detail': 'Not Found'})

        def choice(self, profile):
            with LOCK:
                c = STATE['choices'].setdefault(profile, own_choice())
                blocked = STATE['blocked'].get(profile)
            source = next((p for p in CHROME_PROFILES if p['dir'] == c['source']), None) if c['mode'] == 'copy' else None
            return {'schema': 'hermes-hq-browser.choice.v1', 'profile': profile, 'mode': c['mode'], 'source': source,
                    'copied_at': c['copied_at'], 'window': c['window'], 'changeable': blocked is None,
                    'blocked': blocked, 'can_take_over': blocked in TAKE_OVER, 'status': None if blocked else 'ready'}

        def do_GET(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            if path.startswith(PLUGIN + '/') and (self.headers.get('Upgrade') or '').lower() == 'websocket':
                if 'ticket' not in query or STATE['plugin'] == 'missing':
                    return self.reply(401, {'detail': 'unauthorized'})
                if path == PLUGIN + '/activity':
                    return activity(upgrade(self))
                if path == f'{PLUGIN}/sessions/{BROWSER_ID}/watch':
                    if not STATE['listed']:
                        ws = upgrade(self)
                        return ws.close(4404)
                    return Watch(upgrade(self)).run()
                return self.reply(404, {'detail': 'Not Found'})
            if path.startswith(PLUGIN + '/'):
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                return self.plugin_get(path, query)
            if path == '/__fixture/browser':
                with LOCK:
                    view = {k: STATE[k] for k in ('inputs', 'acks', 'frames_sent', 'hellos', 'views', 'control', 'choices',
                                                  'blocked', 'take_overs', 'viewers', 'focus', 'url', 'epoch')}
                    view['choice'] = STATE['choices'].get('default') or own_choice()
                return self.reply(200, view)
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == PLUGIN + '/choice':
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                if STATE['plugin'] == 'missing' or not STATE['choice_feature']:
                    return self.reply(404, {'detail': 'Not Found'})
                body = self.body()
                profile = body.get('profile') or 'default'
                with LOCK:
                    c = STATE['choices'].setdefault(profile, own_choice())
                    blocked = STATE['blocked'].get(profile)
                if body.get('take_over') is True:
                    if blocked is not None and blocked not in TAKE_OVER:
                        return self.reply(409, {'detail': REFUSED.get(blocked, 'Hermes HQ can’t run this bot’s browser.')})
                    if blocked is not None:
                        time.sleep(1.0)   # the plugin writes the config and waits for the bot's Chrome
                        with LOCK:
                            STATE['blocked'].pop(profile, None)
                            STATE['take_overs'].append(profile)
                    return self.reply(200, self.choice(profile))
                if blocked is not None:
                    return self.reply(409, {'detail': "This bot's browser was set up by hand, so Hermes HQ leaves it alone."})
                mode, source, window = body.get('mode'), body.get('source'), body.get('window')
                if mode == 'copy' and source not in {p['dir'] for p in CHROME_PROFILES}:
                    return self.reply(409, {'detail': "That Chrome profile isn't on this computer."})
                time.sleep(0.6)   # a copy takes a moment
                with LOCK:
                    if mode == 'copy':
                        c.update(mode='copy', source=source, copied_at=time.time())
                    elif mode == 'own':
                        c.update(mode='own', source=None, copied_at=None)
                    if body.get('refresh') is True and c['mode'] == 'copy':
                        c['copied_at'] = time.time()
                    if window in ('hidden', 'normal'):
                        c['window'] = window
                return self.reply(200, self.choice(profile))
            if path == '/__fixture/browser':
                body = self.body()
                with LOCK:
                    for key in ('active', 'listed', 'url', 'ask', 'choice_feature', 'dialogs_feature', 'plugin', 'frame_fps', 'dialog'):
                        if key in body:
                            STATE[key] = body[key]
                    if isinstance(body.get('blocked'), dict):
                        STATE['blocked'] = {str(k): str(v) for k, v in body['blocked'].items() if v}
                    bump()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/browser/reset':
                self.body()
                with LOCK:
                    for watch in list(WATCHERS):
                        watch.alive = False
                        watch.ws.close()
                    STATE.clear()
                    STATE.update(fresh_state())
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler


base.handler = handler


def load_frames(folder):
    for path in sorted(pathlib.Path(folder).glob('*.jpg')):
        FRAMES.append('data:image/jpeg;base64,' + base64.b64encode(path.read_bytes()).decode())


if __name__ == '__main__':
    frames = 'build/fixtures/browser-frames'
    if '--frames' in sys.argv:
        at = sys.argv.index('--frames')
        frames = sys.argv[at + 1]
        del sys.argv[at:at + 2]
    load_frames(frames)
    if not FRAMES:
        sys.exit(f'no frames in {frames} (swift scripts/fixtures/make-browser-frames.swift {frames})')
    base.main()
