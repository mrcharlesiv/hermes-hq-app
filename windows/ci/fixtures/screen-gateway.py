#!/usr/bin/env python3
"""Bot Screen stand-in gateway (docs/spec/3x-screen.md §2, the Mac's App/Screen at 93f984bb1): the build 47 acceptance
gateway (sign-in, ws ticket, JSON-RPC, chats) plus a synthetic display side for one demo bot, otto.

  display.status / display.start / display.observe / display.lease.acquire / display.lease.release, as Hermes answers
  them (unknown params are error 4000), and `display.status` events when the phase changes.
  GET /api/display/ws?display_ticket=...  the display socket: RFB 3.8 in binary WebSocket messages, no security, one
  raw-encoded synthetic test picture (a gradient with a lighter window, generated here; no desktop is read) for each
  full update request.
  GET /api/plugins/hermes-hq-screen/health  the Mac plugin's health for the phase.

The socket is a RECEIVER ONLY: the client's KeyEvent and PointerEvent messages are decoded and recorded, never
executed (nothing here moves a pointer or presses a key anywhere). Controls (loopback, invented data):

  POST /__fixture/screen {"phase": "setup"|"mac"|"ready"}
       setup  no live screen here (supported: false): the viewer shows the setup card on the screenshots page.
       mac    a live Mac screen whose control is not set up (health control: false): the Enable Control note.
       ready  the same screen with control set up: Take Control works and input reaches the socket.
  GET  /__fixture/screen  {"phase", "inputs": [{"kind": "pointer", "mask", "x", "y", "hex"} | {"kind": "key", "down",
       "keysym", "hex"}], "rpc": [{"method", "params"}], "sockets", "updates", "health", "chat": [...]}

[WIN-SCREEN-SETUP-SEND-WALK] otto is also in the roster (profiles.list, display name Otto) with a bot chat of its own, so
Set Up with Hermes can open it and send the setup there (the Mac's runScreenSetup). `file.attach` is answered with a
synthetic ref_text and `prompt.submit` as build 47 answers it; both are RECORDED in "chat", in order, and nothing in
them is ever unpacked or run:
  {"method": "file.attach", "keys", "owner", "session_id", "profile", "name", "data_url_prefix", "data_bytes",
   "data_sha256", "ref_text"}   (the data URL itself is not kept: its decoded size and SHA-256 are)
  {"method": "prompt.submit", "keys", "owner", "session_id", "profile", "text", "queued"}
"owner" is the bot whose chat the frame's session id belongs to.

  python3 windows/ci/fixtures/screen-gateway.py --port 9880 --credentials build/fixtures/e2e-screen.json
"""
import base64, hashlib, importlib.util, json, pathlib, secrets, struct, sys, threading, traceback
from urllib.parse import urlparse, parse_qs

spec = importlib.util.spec_from_file_location('build47_base', pathlib.Path(__file__).with_name('build47-fixture-gateway.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

BOT = 'otto'
HOME_KEY = '/fixture/home/otto'
WIDTH, HEIGHT = 640, 400
DISPLAY_PATH = '/api/display/ws'
LOCK = threading.RLock()
STATE = {'phase': 'setup', 'holder': 'agent', 'hash': None, 'epoch': 1}
RECORD = {'inputs': [], 'rpc': [], 'sockets': 0, 'updates': 0, 'health': 0, 'chat': []}
TICKETS = {}
MINTED = set()
COUNTER = [0]

# [WIN-SCREEN-SETUP-SEND-WALK] otto's bot chat (invented ids and words), beside build 47's Hermes and Sam.
BOT_SESSION = '20260929_120000_aabbcc0f'
SETUP_REF_TEXT = '@file:/fixture/uploads/hermes-hq-screen-setup.zip'
DATA_URL_PREFIX = 'data:application/zip;base64,'
voice = base.voice
voice.SIDS[BOT] = BOT_SESSION
base.MESSAGES[BOT] = [{'role': 'assistant', 'content': 'Synthetic Otto chat for the screen setup walk.', 'row_id': 1,
                       'timestamp': 1790852400}]
base.RUNNING[BOT] = False
base.CANCEL[BOT] = threading.Event()
_voice_rpc = base._original_rpc


def named(method, params):
    """The roster names otto Otto (the voice fixture names every non-default bot Sam)."""
    answer = _voice_rpc(method, params)
    if method == 'profiles.list':
        for profile in answer.get('profiles', []):
            if profile.get('name') == BOT:
                profile['ui_meta'] = {'hermes-bots': {'display_name': 'Otto'}}
                profile['description'] = 'Synthetic screen QA'
    return answer


base._original_rpc = named


def attach(params):
    """file.attach: recorded (the data URL's decoded size and SHA-256, never its bytes), answered, nothing unpacked."""
    data_url = params.get('data_url') if isinstance(params.get('data_url'), str) else ''
    prefix, data_bytes, data_sha = '', 0, None
    if data_url.startswith(DATA_URL_PREFIX):
        prefix = DATA_URL_PREFIX
        try:
            data = base64.b64decode(data_url[len(DATA_URL_PREFIX):], validate=True)
            data_bytes, data_sha = len(data), hashlib.sha256(data).hexdigest()
        except ValueError:
            data_bytes = -1
    entry = {'method': 'file.attach', 'keys': sorted(params), 'owner': base.owner(params), 'session_id': params.get('session_id'),
             'profile': params.get('profile'), 'name': params.get('name'), 'data_url_prefix': prefix, 'data_bytes': data_bytes,
             'data_sha256': data_sha, 'ref_text': SETUP_REF_TEXT}
    with LOCK:
        RECORD['chat'].append(entry)
    return {'attached': True, 'path': SETUP_REF_TEXT[len('@file:'):], 'ref_text': SETUP_REF_TEXT}


_base_prompt = base.Client.prompt


def prompt(self, frame):
    """prompt.submit: recorded, then answered as build 47 answers it (accepted, a short synthetic reply)."""
    params = frame.get('params') or {}
    with LOCK:
        RECORD['chat'].append({'method': 'prompt.submit', 'keys': sorted(params), 'owner': base.owner(params),
                               'session_id': params.get('session_id'), 'profile': params.get('profile'),
                               'text': params.get('text'), 'queued': bool(params.get('queued'))})
    return _base_prompt(self, frame)


base.Client.prompt = prompt


def pixel(x, y):
    """The synthetic picture (B, G, R): ScreenWireWalkProof.Pixel in Hermes.Core is the same rule."""
    if WIDTH // 4 <= x < WIDTH * 3 // 4 and HEIGHT // 4 <= y < HEIGHT * 3 // 4:
        return (200, 120, 40) if y < HEIGHT // 4 + 24 else (236, 236, 236)
    return (120 + x * 100 // WIDTH, 70 + y * 60 // HEIGHT, 40)


def picture():
    rows = []
    for y in range(HEIGHT):
        rows.append(b''.join(bytes((*pixel(x, y), 0)) for x in range(WIDTH)))
    return b''.join(rows)


PICTURE = picture()


def viewer_hash(viewer_id):
    return hashlib.sha256(viewer_id.encode()).hexdigest()[:12]


def lease():
    return {'holder': STATE['holder'], 'viewer_id': None, 'viewer_hash': STATE['hash'], 'since': 1791700000,
            'epoch': STATE['epoch'], 'reason': ''}


def status():
    live = STATE['phase'] != 'setup'
    return {'profile': BOT, 'profile_key': HOME_KEY, 'supported': live, 'installed': live, 'missing': [],
            'running': live, 'display': 'This Mac' if live else None, 'geometry': f'{WIDTH}x{HEIGHT}' if live else None,
            'install_command': None, 'blocker': None, 'placement': 'gateway', 'lease': lease()}


def health():
    ready = STATE['phase'] == 'ready'
    return {'installed': True, 'platform': 'darwin', 'ok': True, 'drift': [], 'enabled': True, 'control': ready,
            'helper': {'ok': True, 'locked': False, 'secure_input': False, 'tcc': {'capture': True, 'events': ready}}}


def broadcast(kind, payload):
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'payload': payload}}
    with base.LOCK:
        clients = list(base.CLIENTS)
    for client in clients:
        try:
            client.send(frame)
        except OSError:
            pass


class Refused(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


ALLOWED = {'display.status': {'profile'}, 'display.start': {'profile'}, 'display.observe': {'profile', 'viewer_id'},
           'display.lease.acquire': {'profile', 'viewer_id'}, 'display.lease.release': {'profile', 'viewer_id', 'force'}}

_base_rpc = base.rpc


def rpc(method, params):
    if method == 'file.attach':
        return attach(params)
    if not method.startswith('display.'):
        return _base_rpc(method, params)
    with LOCK:
        RECORD['rpc'].append({'method': method, 'params': params})
        if method not in ALLOWED:
            raise Refused(-32601, 'Method not found')
        if set(params) - ALLOWED[method]:
            raise Refused(4000, 'unknown params: ' + ', '.join(sorted(set(params) - ALLOWED[method])))
        if params.get('profile') != BOT:
            raise Refused(4004, 'unknown profile')
        viewer = params.get('viewer_id')
        if method in ('display.status', 'display.start'):
            return status()
        if method == 'display.observe':
            if STATE['phase'] == 'setup':
                raise Refused(4001, 'no live screen for this bot')
            if not (isinstance(viewer, str) and viewer in MINTED):
                COUNTER[0] += 1
                viewer = f'viewer-screen-{COUNTER[0]}'
                MINTED.add(viewer)
            COUNTER[0] += 1
            ticket = f'ticket-screen-{COUNTER[0]}-{secrets.token_hex(4)}'
            TICKETS[ticket] = viewer
            return {**status(), 'ticket': ticket, 'path': DISPLAY_PATH, 'viewer_id': viewer}
        if method == 'display.lease.acquire':
            if viewer not in MINTED:
                raise Refused(5300, 'viewer_id was not minted for this connection')
            if STATE['phase'] != 'ready':
                raise Refused(4003, 'control is not set up on this Mac')
            STATE.update(holder='human', hash=viewer_hash(viewer), epoch=STATE['epoch'] + 1)
            return {'lease': lease()}
        STATE.update(holder='agent', hash=None, epoch=STATE['epoch'] + 1)
        return {'lease': lease()}


base.rpc = rpc

# build47's socket loop answers a ValueError with -32001; a refusal carries Hermes' own code.
def _patch_answers():
    original_send = base.Client.send

    def send(self, value):
        error = value.get('error') if isinstance(value, dict) else None
        if error and error.get('message', '').startswith('\x00'):
            code, _, message = error['message'][1:].partition('\x00')
            value = {**value, 'error': {'code': int(code), 'message': message}}
        return original_send(self, value)

    base.Client.send = send

    def coded(method, params):
        try:
            return rpc(method, params)
        except Refused as refused:
            raise ValueError(f'\x00{refused.code}\x00{refused}') from None

    base.rpc = coded


_patch_answers()


def be16(v):
    return struct.pack('>H', v)


def be32(v):
    return struct.pack('>I', v)


def server_init():
    name = b'This Mac'
    return be16(WIDTH) + be16(HEIGHT) + bytes([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]) + be32(len(name)) + name


def full_update():
    return bytes([0, 0]) + be16(1) + be16(0) + be16(0) + be16(WIDTH) + be16(HEIGHT) + be32(0) + PICTURE


def display(connection, key):
    """The display socket: RFB 3.8 over binary WebSocket messages. Records input; executes nothing."""
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    send_lock = threading.Lock()

    def send(data):
        n = len(data)
        header = bytes([0x82]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536 else bytes([127]) + struct.pack('>Q', n))
        with send_lock:
            connection.sendall(header + data)

    def read(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data

    buffer = bytearray()

    def fill(count):
        while len(buffer) < count:
            first, second = read(2)
            opcode, n = first & 15, second & 127
            if n == 126:
                n = struct.unpack('>H', read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', read(8))[0]
            if n > 4 * 1024 * 1024:
                raise ValueError('oversized display message')
            mask = read(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(n)))
            if opcode == 8:
                raise ConnectionError()
            if opcode == 9:
                with send_lock:
                    connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode in (0, 2):
                buffer.extend(payload)

    def take(count):
        fill(count)
        out = bytes(buffer[:count])
        del buffer[:count]
        return out

    try:
        send(b'RFB 003.008\n')
        take(12)
        send(bytes([1, 1]))
        take(1)
        send(be32(0))
        take(1)
        send(server_init())
        while True:
            kind = take(1)[0]
            if kind == 0:
                take(19)
            elif kind == 2:
                rest = take(3)
                take(4 * struct.unpack('>H', rest[1:3])[0])
            elif kind == 3:
                body = take(9)
                if body[0] == 0:
                    with LOCK:
                        RECORD['updates'] += 1
                    send(full_update())
            elif kind == 4:
                body = take(7)
                with LOCK:
                    RECORD['inputs'].append({'kind': 'key', 'down': body[0] == 1, 'keysym': struct.unpack('>I', body[3:7])[0],
                                             'hex': (bytes([4]) + body).hex()})
            elif kind == 5:
                body = take(5)
                with LOCK:
                    RECORD['inputs'].append({'kind': 'pointer', 'mask': body[0], 'x': struct.unpack('>H', body[1:3])[0],
                                             'y': struct.unpack('>H', body[3:5])[0], 'hex': (bytes([5]) + body).hex()})
            elif kind == 6:
                rest = take(7)
                take(struct.unpack('>I', rest[3:7])[0])
            else:
                raise ValueError(f'unknown client message {kind}')
    except ConnectionError:
        return
    except Exception as error:
        print(f'[display] socket ended: {type(error).__name__}: {error}', file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()


_base_handler = base.handler


def handler(gateway):
    parent = _base_handler(gateway)

    class Handler(parent):
        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == DISPLAY_PATH:
                ticket = parse_qs(parsed.query).get('display_ticket', [''])[0]
                with LOCK:
                    viewer = TICKETS.pop(ticket, None)
                    if viewer is not None:
                        RECORD['sockets'] += 1
                if viewer is None or (self.headers.get('Upgrade') or '').lower() != 'websocket':
                    return self.reply(401, {'detail': 'invalid display ticket'})
                return display(self.connection, self.headers['Sec-WebSocket-Key'])
            if parsed.path == '/api/plugins/hermes-hq-screen/health':
                with LOCK:
                    RECORD['health'] += 1
                    return self.reply(200, health())
            if parsed.path == '/__fixture/screen':
                with LOCK:
                    return self.reply(200, {'phase': STATE['phase'], **json.loads(json.dumps(RECORD))})
            return super().do_GET()

        def do_POST(self):
            if urlparse(self.path).path == '/__fixture/screen':
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
                phase = body.get('phase')
                if phase not in ('setup', 'mac', 'ready'):
                    return self.reply(400, {'detail': 'phase: setup, mac or ready'})
                with LOCK:
                    STATE['phase'] = phase
                    if phase != 'ready':
                        STATE.update(holder='agent', hash=None)
                    STATE['epoch'] += 1
                    payload = status()
                broadcast('display.status', payload)
                return self.reply(200, {'ok': True, 'phase': phase})
            return super().do_POST()

    return Handler


base.handler = handler

if __name__ == '__main__':
    base.main()
