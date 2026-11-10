#!/usr/bin/env python3
"""A stand-in gateway for Bot Screen (docs/spec/3x-screen.md §7). Python stdlib only, loopback only, every value
invented, nothing forwarded. It loads the performance fixture (sign-in, roster, sessions, messages, /api/ws) and adds:

  /api/ws JSON-RPC (strict: a param outside the allowed set answers 4000 "unknown params")
    display.status {profile}                    the status of the current mode
    display.start {profile}                     off -> running; not-installed -> 5300
    display.observe {profile, viewer_id?}       a viewer id bound to THIS /api/ws connection, a single-use ticket, path
    display.lease.acquire {profile, viewer_id}  human lease, epoch + 1; evicts the previous human's stream with 4000
    display.lease.release {profile, viewer_id?, force?}   Hermes' rules (by id; by id + force; bare + force)
    display.stop/thumbnail/install/switchSandboxImage      answered and counted in forbidden_calls
    file.attach {session_id, profile, name, path?, data_url?}   recorded as {name, bytes, sha256}
    events pushed: display.status, display.lease, tool.start, tool.complete
  GET /api/display/ws?display_ticket=<t>        RFB 3.8 as a server in binary frames; frames only in answer to a
                                                FramebufferUpdateRequest; close 4401 (ticket), 4403 (other query item),
                                                4001 (not running), 4000 control-taken, 1003 (protocol)
  GET /api/plugins/hermes-hq-screen/health, /api/plugins/dispatch-screen/health   per health.plugin
  GET /api/fs/list?path=<dir>, /api/fs/download?path=<file>                        the screenshots
  GET /api/profiles/sessions?limit=3&order=recent…, /api/sessions/<id>/messages    screenshot sessions mixed in

  POST /__fixture/screen   any subset of (an unknown key answers 400 with this list):
    mode            mac (default) | linux | off | not-installed | unsupported | unavailable | blocked | no-answer
    starts_as       mac | linux: what `off` becomes on display.start (default linux)
    status_delay_ms, rpc_delay_ms               slow answers (status only / every display RPC and file.attach)
    fail            {method: message | null}    that method answers 5300 with the message
    blocker         text of mode blocked
    health          {plugin: new|legacy|none, installed, ok, platform, drift, enabled, control, blocker, helper,
                     helper_ok, tcc_screen, tcc_events, locked, secure_input, paused, capture_error, status, delay_ms}
    health_now      true: push a display.status event
    stream          {encoding: tight-jpeg|tight-basic|raw|copyrect|mixed, fps, size: [w, h], chunk, delay_ms,
                     throttle_kbps, stall_after, drop, drop_after_ms, close_code, rects_per_update, garbage,
                     first_frame_delay_ms}   (first_frame_delay_ms: the handshake finishes, then no picture for this
                     long, as the Mac helper does while it has no frame; -1 = never)
    tickets         {ttl_s, reject}
    other_takes     true or a count (with every_ms): another person acquires; a count also closes the phone's stream
                    with 4000 each time
    agent_takes     true: the lease returns to the agent
    drop_ws         true: closes the app's /api/ws connections
    shots           {seed, chat, live: {tool, action, app}, stored, expire: [names] | "latest", listing: fail|empty|ok,
                     sessions, messages, download_status: 503 | 0 (every screenshot download answers that status)}
    host            mac | windows | linux (session cwd and screenshot paths)
    busy            true/false: the bot is mid-reply
    finish_setup_after_ms   the mode becomes mac this long after the next setup prompt
  GET  /__fixture/screen          the ledger (see fresh_ledger)
  POST /__fixture/screen/reset    defaults, empty ledger
  GET  /__fixture/screen/expect   the newest stream's own picture at five points, hex BGR

  python3 scripts/fixtures/screen-gateway.py --port 9940 --credentials build/fixtures/e2e-screen.json \
      --frames build/fixtures/screen-frames
  python3 scripts/fixtures/screen-gateway.py --emit-vectors Tests/Fixtures/screen [--frames <dir>]

It refuses a port outside 9940-9949 unless --any-port is given, and binds 127.0.0.1 only.
"""
import base64, hashlib, importlib.util, json, os, pathlib, secrets, socket, struct, sys, threading, time, zlib
from urllib.parse import urlparse, parse_qs

REF = pathlib.Path('/Users/me/Projects/hermes-hq-native-ref238/scripts')
_spec = importlib.util.spec_from_file_location('hqn_screen_perf', REF / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)
b47 = perf.base
voice = b47.voice
LOCK = threading.RLock()
MODES = ('mac', 'linux', 'off', 'not-installed', 'unsupported', 'unavailable', 'blocked', 'no-answer')
KNOWN = ('mode', 'starts_as', 'status_delay_ms', 'rpc_delay_ms', 'fail', 'blocker', 'health', 'health_now', 'stream',
         'tickets', 'other_takes', 'every_ms', 'agent_takes', 'drop_ws', 'shots', 'host', 'busy', 'finish_setup_after_ms')
BLOCKER = 'Screen sharing is off on this Mac. Choose Set up with Hermes to enable it'
FRAMESETS = {}          # (w, h) -> {'dir', 'base', 'rects': [[...]]}
SAMPLES = ((0.25, 0.25), (0.75, 0.25), (0.5, 0.5), (0.25, 0.75), (0.75, 0.75))


def fresh_state():
    return {'mode': 'mac', 'starts_as': 'linux', 'status_delay_ms': 0, 'rpc_delay_ms': 0, 'fail': {}, 'blocker': BLOCKER,
            'health': {'plugin': 'new', 'installed': True, 'ok': True, 'platform': 'darwin', 'drift': [], 'enabled': True,
                       'control': True, 'blocker': None, 'helper': True, 'helper_ok': True, 'tcc_screen': True,
                       'tcc_events': True, 'locked': False, 'secure_input': False, 'paused': False, 'capture_error': None,
                       'status': 200, 'delay_ms': 0},
            'stream': {'encoding': None, 'fps': 15.0, 'size': [1280, 800], 'chunk': 65536, 'delay_ms': 0, 'throttle_kbps': 0,
                       'stall_after': 0, 'drop': False, 'drop_after_ms': 0, 'close_code': None, 'rects_per_update': 0,
                       'garbage': None, 'first_frame_delay_ms': 0},
            'tickets': {'ttl_s': 30, 'reject': False}, 'host': 'mac', 'finish_setup_after_ms': 0}


def fresh_ledger():
    return {'lease_log': [], 'status_calls': 0, 'calls': [], 'observes': [], 'unknown_params': [], 'forbidden_calls': 0,
            'sockets': [], 'open_sockets': 0, 'max_open_sockets': 0, 'max_outstanding_requests': 0, 'client_messages': {},
            'set_encodings': [], 'pixel_format': None, 'inputs': [], 'dropped_inputs': 0,
            'health_hits': {'new': 0, 'legacy': 0, 'times': []}, 'fs_list_hits': 0, 'fs_list_times': [], 'downloads': 0,
            'sessions_polls': 0, 'messages_fetches': 0, 'attach': [], 'prompts': [], 'ws_connections': 0}


def fresh_shots():
    return {'files': {}, 'sessions': {}, 'listing': 'ok', 'count': 0, 'chat_rows': [], 'live': 0, 'download_status': 0}


STATE = fresh_state()
LEDGER = fresh_ledger()
SHOTS = fresh_shots()
LEASES = {}             # profile -> lease
VIEWERS = {}            # viewer id -> {'conn': connection number, 'profile': p}
TICKETS = {}            # ticket -> {'viewer', 'profile', 'expires', 'used'}
CONNS = {}              # connection number -> Conn
STREAMS = []            # open Stream objects
LAST = {'stream': None, 'conn': 0}


class Refuse(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


def viewer_hash(viewer_id):
    return hashlib.sha256(viewer_id.encode()).hexdigest()[:12]


def home_key(profile):
    # Hermes' hermes_home_key(): the profile's home PATH, never its name.
    return '/fixture/home' if profile == 'default' else '/fixture/home/profiles/' + profile


def lease(profile):
    with LOCK:
        if profile not in LEASES:
            LEASES[profile] = {'holder': 'agent', 'viewer_id': None, 'viewer_hash': None, 'since': time.time(), 'epoch': 1,
                               'reason': ''}
        return LEASES[profile]


def public(entry):
    return {'holder': entry['holder'], 'viewer_id': None, 'viewer_hash': entry['viewer_hash'], 'since': entry['since'],
            'epoch': entry['epoch'], 'reason': entry['reason']}


def set_lease(profile, holder, viewer_id, why):
    with LOCK:
        entry = lease(profile)
        entry.update(holder=holder, viewer_id=viewer_id, viewer_hash=viewer_hash(viewer_id) if viewer_id else None,
                     since=time.time(), epoch=entry['epoch'] + 1, reason=why)
        LEDGER['lease_log'].append({'t': time.time(), 'holder': holder, 'viewer_hash': entry['viewer_hash'],
                                    'epoch': entry['epoch'], 'why': why})
        view = public(entry)
    push('display.lease', {'profile_key': home_key(profile), 'lease': view})
    return view


def running():
    return STATE['mode'] in ('mac', 'linux')


def status(profile):
    mode = STATE['mode']
    w, h = STATE['stream']['size']
    answer = {'profile': profile, 'profile_key': home_key(profile), 'supported': True, 'installed': True, 'missing': [], 'running': False,
              'pid': None, 'display': None, 'socket': None, 'geometry': None, 'install_command': None, 'browser': None,
              'blocker': None, 'placement': 'gateway', 'image_switch': None, 'lease': public(lease(profile))}
    if mode in ('mac', 'linux'):
        answer.update(running=True, pid=4242, display='This Mac' if mode == 'mac' else ':7', geometry=f'{w}x{h}',
                      socket='/fixture/bot-desktop/rfb.sock')
    elif mode == 'off':
        answer.update(display='This Mac' if STATE['starts_as'] == 'mac' else None)
    elif mode == 'not-installed':
        answer.update(installed=False, missing=['tigervnc-standalone-server', 'xfce4'],
                      install_command='sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies')
    elif mode == 'unsupported':
        answer.update(supported=False, installed=False)
    elif mode == 'blocked':
        answer.update(display='This Mac', blocker=STATE['blocker'])
    return answer


def push(kind, payload, session_id=None):
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'payload': payload}}
    if session_id:
        frame['params']['session_id'] = session_id
    with LOCK:
        conns = list(CONNS.values())
    for conn in conns:
        try:
            conn.send(frame)
        except OSError:
            pass


def push_status():
    for profile in voice.SIDS:
        push('display.status', status(profile))


# ---------------------------------------------------------------------------------------------- display RPC

ALLOWED = {'display.status': {'profile'}, 'display.start': {'profile'}, 'display.observe': {'profile', 'viewer_id'},
           'display.lease.acquire': {'profile', 'viewer_id'}, 'display.lease.release': {'profile', 'viewer_id', 'force'},
           'file.attach': {'session_id', 'profile', 'name', 'path', 'data_url'}}
FORBIDDEN = ('display.stop', 'display.thumbnail', 'display.install', 'display.switchSandboxImage')
NO_ANSWER = object()
MISMATCH = {'code': 'viewer_mismatch'}


def display_rpc(conn, method, params):
    extra = sorted(set(params) - ALLOWED.get(method, set(params)))
    with LOCK:
        LEDGER['calls'].append({'t': time.time(), 'method': method, 'keys': sorted(params), 'conn': conn.number,
                                'viewer_id': params.get('viewer_id'), 'force': params.get('force')})
        del LEDGER['calls'][:-2000]
        if extra:
            LEDGER['unknown_params'].append({'method': method, 'keys': extra})
    if extra:
        raise Refuse(4000, 'unknown params: ' + ', '.join(extra))
    delay = STATE['rpc_delay_ms'] + (STATE['status_delay_ms'] if method == 'display.status' else 0)
    if delay:
        time.sleep(delay / 1000)
    if method == 'file.attach':
        return file_attach(params)
    if method == 'display.status':
        with LOCK:
            LEDGER['status_calls'] += 1
    if STATE['mode'] == 'unavailable':
        raise Refuse(-32601, 'Method not found')
    if STATE['fail'].get(method):
        raise Refuse(5300, STATE['fail'][method])
    if method in FORBIDDEN:
        with LOCK:
            LEDGER['forbidden_calls'] += 1
        return {}
    profile = params.get('profile') if params.get('profile') in voice.SIDS else 'default'
    if method == 'display.status':
        return NO_ANSWER if STATE['mode'] == 'no-answer' else status(profile)
    if method == 'display.start':
        if STATE['mode'] == 'not-installed':
            raise Refuse(5300, 'Bot Desktop packages are missing')
        if STATE['mode'] == 'off':
            STATE['mode'] = STATE['starts_as']
            push_status()
        return status(profile)
    if method == 'display.observe':
        if not running():
            raise Refuse(5300, "this profile's Bot Desktop is not running; call display.start first")
        sent = params.get('viewer_id')
        with LOCK:
            kept = bool(sent) and VIEWERS.get(sent, {}).get('conn') == conn.number
            viewer = sent if kept else 'v_' + secrets.token_hex(12)
            VIEWERS[viewer] = {'conn': conn.number, 'profile': profile}
            ticket = secrets.token_urlsafe(18)
            TICKETS[ticket] = {'viewer': viewer, 'profile': profile, 'expires': time.time() + STATE['tickets']['ttl_s'],
                               'used': False}
            LEDGER['observes'].append({'t': time.time(), 'conn': conn.number, 'sent_viewer': bool(sent), 'kept': kept,
                                       'viewer_id': viewer, 'viewer_hash': viewer_hash(viewer)})
        return {**status(profile), 'ticket': ticket, 'path': '/api/display/ws', 'viewer_id': viewer}
    viewer = params.get('viewer_id')
    force = params.get('force') is True
    if method == 'display.lease.acquire':
        if not viewer:
            raise Refuse(5300, 'viewer_id required')
        if VIEWERS.get(viewer, {}).get('conn') != conn.number:
            raise Refuse(5300, 'viewer_id was not minted for this connection; call display.observe first', MISMATCH)
        return {'lease': acquire(profile, viewer, 'acquire')}
    if method == 'display.lease.release':
        entry = lease(profile)
        if viewer:
            if not force and VIEWERS.get(viewer, {}).get('conn') != conn.number:
                raise Refuse(5300, 'viewer_id was not minted for this connection; call display.observe first', MISMATCH)
            if entry['holder'] == 'human' and entry['viewer_id'] == viewer:
                return {'lease': set_lease(profile, 'agent', None, 'release')}
            return {'lease': public(entry)}
        if entry['holder'] == 'human':
            if not force:
                raise Refuse(5300, 'a human viewer holds control; pass force to release it', MISMATCH)
            return {'lease': set_lease(profile, 'agent', None, 'force release')}
        return {'lease': public(entry)}
    raise Refuse(-32601, 'Method not found')


def acquire(profile, viewer, why, evict_all=False):
    with LOCK:
        entry = lease(profile)
        previous = entry['viewer_id'] if entry['holder'] == 'human' else None
        victims = [s for s in STREAMS if s.profile == profile and (evict_all or (previous and s.viewer == previous and previous != viewer))]
    view = set_lease(profile, 'human', viewer, why)
    for stream in victims:
        stream.ws.close(4000, 'control-taken')
    return view


def file_attach(params):
    if STATE['fail'].get('file.attach'):
        raise Refuse(5300, STATE['fail']['file.attach'])
    name = str(params.get('name') or 'file')
    data = b''
    url = params.get('data_url')
    if isinstance(url, str) and ',' in url:
        try:
            data = base64.b64decode(url.split(',', 1)[1])
        except ValueError:
            data = b''
    with LOCK:
        LEDGER['attach'].append({'name': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                 'session_id': params.get('session_id'), 'profile': params.get('profile')})
    path = '/tmp/fixture/' + name
    return {'attached': True, 'name': name, 'path': path, 'ref_path': path, 'ref_text': '@file:' + path, 'uploaded': True}


# ---------------------------------------------------------------------------------------------- /api/ws

class Conn(b47.Client):
    def __init__(self, connection, number):
        super().__init__(connection)
        self.number = number

    def answer(self, frame):
        reply = {'jsonrpc': '2.0', 'id': frame['id']}
        try:
            result = display_rpc(self, frame['method'], frame.get('params') or {})
            if result is NO_ANSWER:
                return
            reply['result'] = result
        except Refuse as refusal:
            reply['error'] = {'code': refusal.code, 'message': refusal.message}
            if refusal.data:
                reply['error']['data'] = refusal.data
        try:
            self.send(reply)
        except OSError:
            pass


def setup_prompt(text):
    return 'Installer source:' in text


def api_ws(connection, key):
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    with LOCK:
        LAST['conn'] += 1
        conn = Conn(connection, LAST['conn'])
        CONNS[conn.number] = conn
        b47.CLIENTS.add(conn)
        LEDGER['ws_connections'] += 1

    def read(n):
        data = b''
        while len(data) < n:
            chunk = connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data
    try:
        conn.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
            'heartbeat': True, 'change_events': True, 'replay_epoch': 'screen', 'desktop_contract': 8}}})
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
            raw = read(n)
            payload = bytes(a ^ b for a, b in zip(raw, (mask * (n // 4 + 1))[:n])) if n else b''
            if opcode == 8:
                return
            if opcode == 9:
                with conn.lock:
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
            method = frame['method']
            if method == 'prompt.submit':
                text = (frame.get('params') or {}).get('text', '')
                with LOCK:
                    LEDGER['prompts'].append({'t': time.time(), 'text': text, 'session_id': (frame.get('params') or {}).get('session_id')})
                if setup_prompt(text) and STATE['finish_setup_after_ms']:
                    threading.Timer(STATE['finish_setup_after_ms'] / 1000, finish_setup, args=(LAST.get('epoch', 0),)).start()
                threading.Thread(target=conn.prompt, args=(frame,), daemon=True).start()
                continue
            if method.startswith('display.') or method == 'file.attach':
                threading.Thread(target=conn.answer, args=(frame,), daemon=True).start()
                continue
            answer = {'jsonrpc': '2.0', 'id': frame['id']}
            try:
                answer['result'] = b47.rpc(method, frame.get('params') or {})
            except ValueError as error:
                answer['error'] = {'code': -32001, 'message': str(error)}
            conn.send(answer)
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        with LOCK:
            CONNS.pop(conn.number, None)
            b47.CLIENTS.discard(conn)


voice.auth.websocket = api_ws


def finish_setup(epoch):
    if epoch != LAST.get('epoch', 0):      # a reset since: that run's setup is not this run's
        return
    STATE['mode'] = 'mac'
    STATE['finish_setup_after_ms'] = 0
    push_status()


# ---------------------------------------------------------------------------------------------- RFB encoders

def compact(n):
    out = bytearray([n & 0x7F])
    if n > 0x7F:
        out[0] |= 0x80
        out.append((n >> 7) & 0x7F)
        if n > 0x3FFF:
            out[1] |= 0x80
            out.append((n >> 14) & 0xFF)
    return bytes(out)


def rect(x, y, w, h, encoding):
    return struct.pack('>HHHHi', x, y, w, h, encoding)


def update(rects):
    return struct.pack('>BBH', 0, 0, len(rects)) + b''.join(rects)


def tpixels(bgrx):
    """BGRX bytes -> Tight's 3-byte RGB pixels."""
    n = len(bgrx) // 4
    out = bytearray(n * 3)
    out[0::3], out[1::3], out[2::3] = bgrx[2::4], bgrx[1::4], bgrx[0::4]
    return bytes(out)


def server_init(w, h, name):
    label = name.encode()
    return struct.pack('>HHBBBBHHHBBBxxxI', w, h, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, len(label)) + label


class Tight:
    """One connection's Tight encoder: four zlib streams that live as long as the connection."""
    def __init__(self):
        self.streams = [zlib.compressobj(2) for _ in range(4)]
        self.turn = 0

    def data(self, stream, payload, reset=False):
        control_reset = 0
        if reset:
            self.streams[stream] = zlib.compressobj(2)
            control_reset = 1 << stream
        if len(payload) < 12:
            return control_reset, payload
        packed = self.streams[stream].compress(payload) + self.streams[stream].flush(zlib.Z_SYNC_FLUSH)
        return control_reset, compact(len(packed)) + packed

    def fill(self, x, y, w, h, bgrx):
        return rect(x, y, w, h, 7) + bytes([0x80, bgrx[2], bgrx[1], bgrx[0]])

    def jpeg(self, x, y, w, h, data):
        return rect(x, y, w, h, 7) + bytes([0x90]) + compact(len(data)) + data

    def copy(self, x, y, w, h, bgrx, stream=0, reset=False):
        bits, body = self.data(stream, tpixels(bgrx), reset)
        return rect(x, y, w, h, 7) + bytes([(stream << 4) | bits]) + body

    def palette(self, x, y, w, h, bgrx, colours, stream=1, reset=False):
        index = {c: i for i, c in enumerate(colours)}
        pixels = [bytes(bgrx[i:i + 3]) for i in range(0, len(bgrx), 4)]
        if len(colours) == 2:
            packed = bytearray()
            for row in range(h):
                byte, bits = 0, 0
                for p in pixels[row * w:(row + 1) * w]:
                    byte = (byte << 1) | index[p]
                    bits += 1
                    if bits == 8:
                        packed.append(byte)
                        byte, bits = 0, 0
                if bits:
                    packed.append(byte << (8 - bits))
            payload = bytes(packed)
        else:
            payload = bytes(index[p] for p in pixels)
        bits, body = self.data(stream, payload, reset)
        table = b''.join(bytes([c[2], c[1], c[0]]) for c in colours)
        return rect(x, y, w, h, 7) + bytes([0x40 | (stream << 4) | bits, 1, len(colours) - 1]) + table + body

    def gradient(self, x, y, w, h, bgrx, stream=2, reset=False):
        rgb = tpixels(bgrx)
        out = bytearray(len(rgb))
        for row in range(h):
            for col in range(w):
                at = (row * w + col) * 3
                for c in range(3):
                    left = rgb[at - 3 + c] if col else 0
                    up = rgb[at - w * 3 + c] if row else 0
                    corner = rgb[at - w * 3 - 3 + c] if row and col else 0
                    out[at + c] = (rgb[at + c] - max(0, min(255, left + up - corner))) & 0xFF
        bits, body = self.data(stream, bytes(out), reset)
        return rect(x, y, w, h, 7) + bytes([0x40 | (stream << 4) | bits, 2]) + body

    def best(self, x, y, w, h, bgrx, analyse=True):
        """The rect as Tight Basic: Fill, a palette, or the copy/gradient filters in turn."""
        if analyse and w * h <= 65536:
            colours = []
            seen = set()
            for i in range(0, len(bgrx), 4):
                p = bytes(bgrx[i:i + 3])
                if p not in seen:
                    seen.add(p)
                    colours.append(p)
                    if len(colours) > 256:
                        break
            if len(colours) == 1:
                return self.fill(x, y, w, h, colours[0])
            if len(colours) <= 256:
                return self.palette(x, y, w, h, bgrx, colours)
            self.turn += 1
            if self.turn % 2 == 0 and w * h <= 16384:
                return self.gradient(x, y, w, h, bgrx)
        return self.copy(x, y, w, h, bgrx)


def raw(x, y, w, h, bgrx):
    return rect(x, y, w, h, 0) + bytes(bgrx)


def copyrect(x, y, w, h, sx, sy):
    return rect(x, y, w, h, 1) + struct.pack('>HH', sx, sy)


class Picture:
    """A BGRX framebuffer the fixture keeps so it knows what the phone should be showing."""
    def __init__(self, w, h, pixels=None):
        self.w, self.h = w, h
        self.px = bytearray(pixels) if pixels is not None else bytearray(w * h * 4)

    def clip(self, x, y, w, h):
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(self.w, x + w), min(self.h, y + h)
        return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))

    def get(self, x, y, w, h):
        out = bytearray()
        for row in range(y, y + h):
            at = (row * self.w + x) * 4
            out += self.px[at:at + w * 4]
        return out

    def put(self, x, y, w, h, data):
        for row in range(h):
            at = ((y + row) * self.w + x) * 4
            self.px[at:at + w * 4] = data[row * w * 4:(row + 1) * w * 4]

    def fill(self, x, y, w, h, bgrx):
        line = bytes(bgrx[:3]) + b'\0'
        self.put(x, y, w, h, line * (w * h))

    def copy(self, x, y, w, h, sx, sy):
        self.put(x, y, w, h, self.get(sx, sy, w, h))

    def probe(self):
        points = []
        for fx, fy in SAMPLES:
            at = (min(self.h - 1, int(self.h * fy)) * self.w + min(self.w - 1, int(self.w * fx))) * 4
            points.append(self.px[at:at + 3].hex())
        return points


def synthetic(w, h, index=0):
    """A desktop for a size with no prepared frames: colour bands and a block that moves."""
    picture = Picture(w, h)
    bands = max(1, min(8, h // 16))
    for i in range(bands):
        top = h * i // bands
        picture.fill(0, top, w, h * (i + 1) // bands - top, bytes([40 + 20 * i, 90 + 10 * i, 200 - 20 * i]))
    return picture


def synthetic_block(w, h, index):
    size = max(1, min(48, w // 8, h // 8))
    return ((index * 37) % max(1, w - size), min(h - size, 8), size, size)


# ---------------------------------------------------------------------------------------------- the display socket

class BinWS:
    """A server websocket carrying binary frames (client frames are masked)."""
    def __init__(self, connection):
        self.connection, self.lock, self.open, self.sent_close = connection, threading.Lock(), True, None

    def send(self, data, text=False):
        shaping = STATE['stream']
        chunk = max(1, int(shaping['chunk'] or 65536))
        for at in range(0, len(data), chunk):
            body = data[at:at + chunk]
            n = len(body)
            header = bytes([0x81 if text else 0x82]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n)
                                                        if n < 65536 else bytes([127]) + struct.pack('>Q', n))
            with self.lock:
                self.connection.sendall(header + body)
            if shaping['throttle_kbps']:
                time.sleep(n * 8 / (shaping['throttle_kbps'] * 1000))
        return len(data)

    def close(self, code, reason=''):
        if not self.open:
            return
        self.open, self.sent_close = False, code
        body = struct.pack('>H', code) + reason.encode()
        try:
            with self.lock:
                self.connection.sendall(bytes([0x88, len(body)]) + body)
            self.connection.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def cut(self):
        self.open = False
        try:
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
            self.connection.shutdown(socket.SHUT_RDWR)
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
        """('bin', bytes) | ('text', bytes) | ('close', code or None). Raises ConnectionError on a dropped link."""
        fragments, kind = bytearray(), 'bin'
        while True:
            first, second = self.read(2)
            opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126:
                n = struct.unpack('>H', self.read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', self.read(8))[0]
            mask = self.read(4) if second & 128 else b'\0' * 4
            rawbytes = self.read(n)
            payload = bytes(a ^ b for a, b in zip(rawbytes, (mask * (n // 4 + 1))[:n])) if n else b''
            if opcode == 8:
                return ('close', struct.unpack('>H', payload[:2])[0] if len(payload) >= 2 else None)
            if opcode == 9:
                with self.lock:
                    self.connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 10:
                continue
            if opcode in (1, 2):
                kind = 'text' if opcode == 1 else 'bin'
                fragments = bytearray(payload)
            elif opcode == 0:
                fragments.extend(payload)
            if final:
                return (kind, bytes(fragments))


class Stream:
    def __init__(self, ws, viewer, profile, entry):
        self.ws, self.viewer, self.profile, self.entry = ws, viewer, profile, entry
        self.buffer = bytearray()
        self.cond = threading.Condition()
        self.pending, self.want_full, self.alive = 0, False, True
        self.encodings, self.frames_sent, self.index = [], 0, 0
        self.tight = Tight()
        self.size = tuple(STATE['stream']['size'])
        self.picture = self.base = None
        self.pointer, self.under, self.mask, self.touched = None, None, 0, False
        self.marks, self.typed, self.garbage_done, self.resized, self.copied = [], 0, False, False, False
        self.opened = time.time()
        self.load()

    # -- the picture

    def load(self):
        w, h = self.size
        frames = FRAMESETS.get((w, h))
        self.index = 0
        self.base = Picture(w, h, frames['base']) if frames else synthetic(w, h)
        self.picture = Picture(w, h, self.base.px)
        self.pointer, self.under, self.marks, self.typed, self.copied = (w // 2, h // 2), None, [], 0, False

    def encoding(self):
        chosen = STATE['stream']['encoding'] or ('tight-jpeg' if STATE['mode'] == 'mac' else 'mixed')
        if 7 not in self.encodings and chosen != 'copyrect':
            return 'raw'
        return chosen

    def lossless(self, x, y, w, h, pixels, how, analyse=True):
        if how == 'raw' or 7 not in self.encodings:
            return raw(x, y, w, h, pixels)
        return self.tight.best(x, y, w, h, pixels, analyse)

    def full(self):
        """The whole desktop (a non-incremental request, or after a resize)."""
        w, h = self.size
        how = self.encoding()
        frames = FRAMESETS.get((w, h))
        self.picture = Picture(w, h, self.base.px)
        self.under, self.marks, self.typed, self.copied = None, [], 0, False
        rects = []
        if frames and how == 'tight-jpeg':
            rects.append(self.tight.jpeg(0, 0, w, h, (frames['dir'] / f'full-{self.index:02d}.jpg').read_bytes()))
        elif not frames and how != 'raw':
            bands = max(1, min(8, h // 16))
            for i in range(bands):
                top = h * i // bands
                rects.append(self.tight.fill(0, top, w, h * (i + 1) // bands - top, bytes([40 + 20 * i, 90 + 10 * i, 200 - 20 * i])))
        else:
            step = 64 if how in ('raw', 'copyrect') else 128
            for top in range(0, h, step):
                rows = min(step, h - top)
                pixels = self.picture.get(0, top, w, rows)
                rects.append(self.lossless(0, top, w, rows, pixels, 'raw' if how in ('raw', 'copyrect') else how, analyse=False))
        return rects

    def advance(self):
        """The next frame's changed parts (an incremental request)."""
        w, h = self.size
        how = self.encoding()
        frames = FRAMESETS.get((w, h))
        rects = []
        many = int(STATE['stream']['rects_per_update'] or 0)
        if many:
            for i in range(many):
                tx = ((self.frames_sent * 7 + i) * 64) % max(64, w - 64)
                ty = (((self.frames_sent * 7 + i) * 64) // max(64, w - 64) * 64) % max(64, h - 64)
                cw, ch = min(64, w - tx), min(64, h - ty)
                rects.append(raw(tx, ty, cw, ch, self.picture.get(tx, ty, cw, ch)))
            return rects
        if frames:
            self.index = (self.index + 1) % len(frames['rects'])
            folder = frames['dir'] / f'frame-{self.index:02d}'
            for i, (x, y, cw, ch) in enumerate(frames['rects'][self.index]):
                name = f'tile-{x}-{y}-{cw}x{ch}'
                pixels = (folder / (name + '.bgrx')).read_bytes()
                self.base.put(x, y, cw, ch, pixels)
                self.picture.put(x, y, cw, ch, pixels)
                if how == 'tight-jpeg':
                    rects.append(self.tight.jpeg(x, y, cw, ch, (folder / (name + '.jpg')).read_bytes()))
                elif how == 'mixed':
                    rects.append(self.lossless(x, y, cw, ch, pixels, 'raw' if i % 3 == 2 else 'tight-basic'))
                else:
                    rects.append(self.lossless(x, y, cw, ch, pixels, 'raw' if how in ('raw', 'copyrect') else how))
        else:
            self.index += 1
            ox, oy, s, _ = synthetic_block(w, h, self.index - 1)
            old = self.base.get(ox, oy, s, s)
            self.picture.put(ox, oy, s, s, old)
            rects.append(raw(ox, oy, s, s, old))
            nx, ny, s, _ = synthetic_block(w, h, self.index)
            colour = bytes([20, 160, 250])
            self.picture.fill(nx, ny, s, s, colour)
            rects.append(self.tight.fill(nx, ny, s, s, colour) if 7 in self.encodings else raw(nx, ny, s, s, self.picture.get(nx, ny, s, s)))
        if how in ('copyrect', 'mixed') and 1 in self.encodings and frames and not self.copied and w >= 640 and h >= 400:
            # One copy onto the (1/4, 3/4) sample point, and an overlapping one beside it.
            self.copied = True
            dx, dy, cw, ch = w // 4 - 40, h * 3 // 4 - 20, 80, 40
            sx, sy = dx + 24, dy - 100
            self.picture.copy(dx, dy, cw, ch, sx, sy)
            rects.append(copyrect(dx, dy, cw, ch, sx, sy))
            ox, oy = w // 2 + 100, h * 3 // 4
            self.picture.copy(ox + 8, oy + 6, 120, 60, ox, oy)
            rects.append(copyrect(ox + 8, oy + 6, 120, 60, ox, oy))
        return rects

    def overlay_off(self):
        """Take the drawn pointer off the picture before anything else changes it."""
        if not self.under:
            return []
        x, y, w, h, pixels = self.under
        self.under = None
        self.picture.put(x, y, w, h, pixels)
        return [raw(x, y, w, h, pixels)]

    def overlay_on(self):
        rects = []
        with self.cond:
            marks, self.marks = self.marks, []
        for kind, mx, my, colour in marks:
            if kind == 'key':
                x, y, w, h = self.picture.clip(16 + (mx % 80) * 14, self.size[1] - 40, 10, 18)
            else:
                x, y, w, h = self.picture.clip(mx - 3, my - 3, 7, 7)
            if w and h:
                self.picture.fill(x, y, w, h, colour)
                rects.append(self.tight.fill(x, y, w, h, colour) if 7 in self.encodings else raw(x, y, w, h, self.picture.get(x, y, w, h)))
        if self.touched:
            px, py = self.pointer
            x, y, w, h = self.picture.clip(px, py, 9, 9)
            if w and h:
                self.under = (x, y, w, h, self.picture.get(x, y, w, h))
                self.picture.fill(x, y, w, h, b'\xff\xff\xff')
                rects.append(self.tight.fill(x, y, w, h, b'\xff\xff\xff') if 7 in self.encodings else raw(x, y, w, h, self.picture.get(x, y, w, h)))
                ix, iy, iw, ih = self.picture.clip(px + 2, py + 2, 4, 4)
                if iw and ih:
                    self.picture.fill(ix, iy, iw, ih, b'\0\0\0')
                    rects.append(self.tight.fill(ix, iy, iw, ih, b'\0\0\0') if 7 in self.encodings else raw(ix, iy, iw, ih, self.picture.get(ix, iy, iw, ih)))
        return rects

    # -- client bytes

    def holds(self):
        entry = lease(self.profile)
        return entry['holder'] == 'human' and entry['viewer_id'] == self.viewer

    def note_input(self, item):
        with LOCK:
            if not self.holds():
                LEDGER['dropped_inputs'] += 1
                return False
            item['t'] = time.time()
            LEDGER['inputs'].append(item)
            del LEDGER['inputs'][:-40000]
        return True

    def parse(self):
        """Client messages with the gateway's own framing (RfbClientFilter). False: an unknown type (close 1003)."""
        b = self.buffer
        while b:
            kind = b[0]
            if kind == 0:
                need = 20
            elif kind == 2:
                need = 4 if len(b) < 4 else 4 + 4 * struct.unpack('>H', b[2:4])[0]
            elif kind == 3:
                need = 10
            elif kind == 4:
                need = 8
            elif kind == 5:
                need = 6
            elif kind == 6:
                need = 8 if len(b) < 8 else 8 + struct.unpack('>I', b[4:8])[0]
                if need > 8 + 262144:
                    return False
            elif kind == 150:
                need = 10
            elif kind == 248:
                need = 9 if len(b) < 9 else 9 + b[8]
            elif kind == 251:
                need = 8 if len(b) < 8 else 8 + 16 * b[6]
            elif kind == 255:
                need = 12
            else:
                return False
            if len(b) < need:
                return True
            message = bytes(b[:need])
            del b[:need]
            with LOCK:
                LEDGER['client_messages'][str(kind)] = LEDGER['client_messages'].get(str(kind), 0) + 1
            if kind == 0:
                bpp, depth, big, true, rmax, gmax, bmax, rs, gs, bs = struct.unpack('>BBBBHHHBBB', message[4:17])
                with LOCK:
                    LEDGER['pixel_format'] = {'bpp': bpp, 'depth': depth, 'big_endian': big, 'true_colour': true,
                                              'max': [rmax, gmax, bmax], 'shift': [rs, gs, bs]}
            elif kind == 2:
                self.encodings = list(struct.unpack('>' + 'i' * ((need - 4) // 4), message[4:]))
                with LOCK:
                    LEDGER['set_encodings'] = list(self.encodings)
            elif kind == 3:
                with self.cond:
                    self.pending += 1
                    if message[1] == 0:
                        self.want_full = True
                    with LOCK:
                        LEDGER['max_outstanding_requests'] = max(LEDGER['max_outstanding_requests'], self.pending)
                    self.cond.notify_all()
            elif kind == 4:
                keysym = struct.unpack('>I', message[4:8])[0]
                if self.note_input({'kind': 'key', 'keysym': keysym, 'down': bool(message[1])}) and message[1]:
                    with self.cond:
                        self.typed += 1
                        self.marks.append(('key', self.typed, 0, bytes([keysym * 53 % 200 + 40, keysym * 31 % 200 + 40, keysym * 17 % 200 + 40])))
            elif kind == 5:
                mask, x, y = message[1], *struct.unpack('>HH', message[2:6])
                if self.note_input({'kind': 'pointer', 'mask': mask, 'x': x, 'y': y}):
                    with self.cond:
                        self.pointer, self.touched = (min(x, self.size[0] - 1), min(y, self.size[1] - 1)), True
                        pressed = mask & ~self.mask
                        self.mask = mask
                        if pressed & 1:
                            self.marks.append(('click', x, y, bytes([40, 40, 230])))
                        if pressed & 4:
                            self.marks.append(('click', x, y, bytes([200, 40, 160])))
                        if pressed & 24:
                            self.marks.append(('click', x, y, bytes([230, 140, 40])))
            elif kind == 6:
                self.note_input({'kind': 'cut', 'length': need - 8, 'text': message[8:].decode('latin-1')})
        return True

    def reader(self):
        code, dropped = None, False
        try:
            while True:
                kind, payload = self.ws.receive()
                if kind == 'close':
                    code = payload if payload is not None else 1005
                    break
                if kind == 'text':
                    self.ws.close(1003, 'text frame')
                    break
                self.buffer += payload
                if not self.parse():
                    self.ws.close(1003, 'unknown client message')
                    break
        except (ConnectionError, OSError):
            dropped = True
        with self.cond:
            self.alive = False
            self.cond.notify_all()
        self.finish(code if not dropped else None)

    def finish(self, code):
        with LOCK:
            if self.entry['closed_at'] is not None:
                return
            self.entry.update(closed_at=time.time(), close_code=code, sent_close=self.ws.sent_close)
            if self in STREAMS:
                STREAMS.remove(self)
            LEDGER['open_sockets'] = len(STREAMS)
            hand_back = code in (1000, 1001) and self.ws.sent_close is None and self.holds()
        if hand_back:
            set_lease(self.profile, 'agent', None, 'viewer left')
        try:
            self.ws.connection.close()
        except OSError:
            pass

    # -- the handshake and the frame loop

    def take(self, n):
        while len(self.buffer) < n:
            kind, payload = self.ws.receive()
            if kind != 'bin':
                raise ConnectionError()
            self.buffer += payload
        out = bytes(self.buffer[:n])
        del self.buffer[:n]
        return out

    def send(self, data):
        sent = self.ws.send(data)
        self.entry['bytes_sent'] += sent

    def run(self):
        garbage = STATE['stream']['garbage']
        try:
            if garbage == 'text-frame':
                self.ws.send(b'RFB 003.008\n', text=True)
            self.send(b'HTTP/1.1 400 Bad Request\r\n\r\n' if garbage == 'bad-version' else b'RFB 003.008\n')
            self.take(12)
            self.send(bytes([1, 2]) if garbage == 'security-none-missing' else bytes([1, 1]))
            self.take(1)
            if garbage == 'security-failed':
                reason = b'Too many viewers'
                self.send(struct.pack('>II', 1, len(reason)) + reason)
                raise ConnectionError()
            self.send(struct.pack('>I', 0))
            self.take(1)
            w, h = self.size
            if garbage == 'zero-size':
                w, h = 0, 0
            if garbage == 'huge-size':
                w, h = 65535, 65535
            self.send(server_init(w, h, 'This Mac' if STATE['mode'] == 'mac' else 'fixture:7'))
        except (ConnectionError, OSError):
            return self.finish(None)
        self.parse()
        threading.Thread(target=self.reader, daemon=True).start()
        last = 0.0
        try:
            while True:
                with self.cond:
                    self.cond.wait_for(lambda: self.pending > 0 or not self.alive, timeout=0.1)
                    if not self.alive:
                        return
                    pending, full = self.pending, self.want_full
                shaping = STATE['stream']
                if shaping['drop'] or (shaping['drop_after_ms'] and (time.time() - self.opened) * 1000 >= shaping['drop_after_ms']):
                    shaping['drop'], shaping['drop_after_ms'] = False, 0
                    return self.ws.cut()
                if shaping['close_code']:
                    code, shaping['close_code'] = shaping['close_code'], None
                    return self.ws.close(int(code), 'fixture')
                if not self.ws.open:
                    return
                if not pending:
                    continue
                hold = shaping.get('first_frame_delay_ms') or 0
                if self.frames_sent == 0 and (hold < 0 or (time.time() - self.opened) * 1000 < hold):
                    time.sleep(0.05)        # handshake done, no picture yet (the helper has no frame to write)
                    continue
                wanted = tuple(shaping['size'])
                rects, open_ended = [], False
                if wanted != self.size:
                    self.size = wanted
                    self.load()
                    if -308 in self.encodings:
                        rects.append(rect(0, 0, wanted[0], wanted[1], -308) + struct.pack('>BxxxIHHHHI', 1, 1, 0, 0, wanted[0], wanted[1], 0))
                    else:
                        rects.append(rect(0, 0, wanted[0], wanted[1], -223))
                    self.resized = True
                elif full or self.resized:
                    self.resized = False
                    rects += self.full() + self.overlay_on()
                else:
                    wait = last + 1 / max(0.5, float(shaping['fps'] or 15)) - time.time()
                    if wait > 0:
                        time.sleep(min(wait, 2))
                    if garbage and not self.garbage_done and self.frames_sent >= 1:
                        self.garbage_done = True
                        if self.bad(garbage):
                            continue
                    rects += self.overlay_off() + self.advance() + self.overlay_on()
                    if -224 in self.encodings and self.frames_sent % 4 == 3:
                        rects.append(rect(0, 0, 0, 0, -224))
                        open_ended = True
                data = struct.pack('>BBH', 0, 0, 0xFFFF) + b''.join(rects) if open_ended else update(rects)
                if shaping['delay_ms']:
                    time.sleep(shaping['delay_ms'] / 1000)
                if shaping['stall_after'] and self.frames_sent >= shaping['stall_after']:
                    shaping['stall_after'] = 0
                    self.send(data[:max(4, len(data) // 2)])
                    with self.cond:
                        self.cond.wait_for(lambda: not self.alive, timeout=600)
                    return
                with self.cond:
                    self.pending -= 1
                    self.want_full = False
                self.send(data)
                last = time.time()
                self.frames_sent += 1
                self.entry['frames_sent'] = self.frames_sent
        except (ConnectionError, OSError):
            return
        finally:
            with self.cond:
                self.alive = False

    def bad(self, name):
        """One bad-data case (spec §9.4). True: nothing more is owed for this request."""
        w, h = self.size
        t = self.tight
        junk = bytes((i * 131 + 7) % 251 for i in range(600))
        one = lambda body: self.send(update([body]))
        if name == 'rect-outside':
            one(raw(w - 10, 0, 64, 4, bytes(64 * 4 * 4)))
        elif name == 'unknown-encoding':
            one(rect(0, 0, 16, 16, 16) + junk[:64])
        elif name == 'unknown-message':
            self.send(bytes([9]) + junk[:32])
        elif name == 'tight-length-overflow':
            one(rect(0, 0, 64, 64, 7) + bytes([0x00, 0xFF, 0xFF, 0xFF]))
        elif name == 'zlib-garbage':
            one(rect(0, 0, 64, 64, 7) + bytes([0x00]) + compact(len(junk)) + junk)
        elif name == 'zlib-truncated':
            packed = zlib.compress(bytes(64 * 64 * 3))[:9]
            one(rect(0, 0, 64, 64, 7) + bytes([0x0F]) + compact(len(packed)) + packed)
        elif name in ('jpeg-garbage', 'jpeg-garbage-3'):
            for _ in range(3 if name.endswith('3') else 1):
                self.send(update([t.jpeg(0, 0, 64, 64, junk)]))
            return False
        elif name == 'palette-zero':
            one(rect(0, 0, 8, 8, 7) + bytes([0x40, 1, 0, 1, 2, 3]) + bytes(8))
        elif name == 'copyrect-outside':
            one(copyrect(0, 0, 64, 64, w - 8, h - 8))
        elif name == 'cut-text-huge':
            self.send(struct.pack('>BxxxI', 3, 512 * 1024 * 1024) + junk)
        elif name == 'colour-map-huge':
            self.send(struct.pack('>BxHH', 1, 0, 65535) + bytes(6 * 65535))
            return False
        elif name == 'trailing-bytes':
            self.send(bytes([2, 2, 2]))
            return False
        elif name == 'never-ending-update':
            fills = [t.fill(i % w, (i // w) % h, 1, 1, b'\x10\x20\x30') for i in range(65535)]
            self.send(struct.pack('>BBH', 0, 0, 65535) + b''.join(fills))
            with self.cond:
                self.pending -= 1
            self.frames_sent += 1
            return True
        else:
            return False
        with self.cond:
            self.pending = max(0, self.pending - 1)
        return True


def display_ws(handler):
    query = parse_qs(urlparse(handler.path).query, keep_blank_values=True)
    key = handler.headers['Sec-WebSocket-Key']
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    handler.connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    handler.close_connection = True
    ws = BinWS(handler.connection)
    entry = {'opened_at': time.time(), 'closed_at': None, 'close_code': None, 'sent_close': None, 'frames_sent': 0,
             'bytes_sent': 0, 'viewer_hash': None}
    refuse = None
    with LOCK:
        LEDGER['sockets'].append(entry)
        del LEDGER['sockets'][:-500]
        ticket = TICKETS.get((query.get('display_ticket') or [''])[0])
        if set(query) - {'display_ticket'}:
            refuse = (4403, 'not allowed')
        elif not ticket or ticket['used'] or ticket['expires'] <= time.time() or STATE['tickets']['reject']:
            refuse = (4401, 'ticket')
        elif not running():
            refuse = (4001, 'Bot Desktop is not running')
        else:
            ticket['used'] = True
            entry['viewer_hash'] = viewer_hash(ticket['viewer'])
            stream = Stream(ws, ticket['viewer'], ticket['profile'], entry)
            STREAMS.append(stream)
            LAST['stream'] = stream
            LEDGER['open_sockets'] = len(STREAMS)
            LEDGER['max_open_sockets'] = max(LEDGER['max_open_sockets'], len(STREAMS))
    if refuse:
        ws.close(*refuse)
        entry.update(closed_at=time.time(), sent_close=refuse[0])
        return
    try:
        stream.run()
    finally:
        if not ws.open and ws.sent_close is None:
            stream.finish(None)
        elif ws.sent_close is not None:
            # We closed it: wait briefly for the peer, then record.
            time.sleep(0.05)
            stream.finish(None)


# ---------------------------------------------------------------------------------------------- screenshots

def png(w, h, n):
    """A small invented screenshot: bands, and a block whose place depends on its number."""
    rows = bytearray()
    block = (n * 61) % (w - 80)
    for y in range(h):
        colour = bytes([(30 + n * 40) % 256, 70 + (y * 120 // h), 160]) if y > 40 else bytes([235, 235, 240])
        line = bytearray(colour * w)
        if 80 <= y < 140:
            line[block * 3:(block + 80) * 3] = bytes([250, 160, 30]) * 80
        rows.append(0)
        rows += line

    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))


def shot_dir():
    return {'mac': '/Users/fixture/.hermes/screenshots', 'windows': 'C:\\Users\\fixture\\.hermes\\screenshots',
            'linux': '/home/fixture/.hermes/screenshots'}[STATE['host']]


def cwd():
    return {'mac': '/Users/fixture/work', 'windows': 'C:\\Users\\fixture\\work', 'linux': '/home/fixture/work'}[STATE['host']]


def shot_path(n):
    return shot_dir() + ('\\' if STATE['host'] == 'windows' else '/') + f'shot-{n:04d}.png'


def shot_call(n):
    kind = n % 3
    if kind == 0:
        return 'computer_use', {'action': 'capture'}
    if kind == 1:
        return 'computer_use', {'action': 'click', 'app': 'Safari'}
    return 'browser_navigate', {'url': 'https://example.test/pricing'}


def shot_rows(n, at):
    """The assistant row that calls the tool and the tool row holding the screenshot."""
    tool, args = shot_call(n)
    path = shot_path(n)
    SHOTS['files'][path] = {'n': n, 'expired': False, 'at': at}
    call = f'call_shot_{n}'
    content = (f'Done. Shareable screenshot saved to {path}' if tool == 'computer_use'
               else json.dumps({'success': True, 'screenshot_path': path}))
    return [{'role': 'assistant', 'content': '', 'timestamp': at - 1,
             'tool_calls': [{'id': call, 'type': 'function', 'function': {'name': tool, 'arguments': json.dumps(args)}}]},
            {'role': 'tool', 'tool_name': tool, 'tool_call_id': call, 'content': content, 'timestamp': at}]


def shot_session(profile='default', chat=False):
    sid = voice.SIDS[profile] if chat else 'shots_' + profile + '_0001'
    if sid not in SHOTS['sessions']:
        SHOTS['sessions'][sid] = {'profile': profile, 'chat': chat, 'rows': [], 'last_active': time.time()}
    return sid, SHOTS['sessions'][sid]


def add_rows(sid, session, rows):
    for item in rows:
        if session['chat']:
            with b47.LOCK:
                item['row_id'] = b47.NEXT_ROW
                b47.NEXT_ROW += 1
                b47.MESSAGES[session['profile']].append(item)
            SHOTS['chat_rows'].append((session['profile'], item))
        else:
            item['row_id'] = len(session['rows']) + 1
            session['rows'].append(item)
    session['last_active'] = time.time()


def shots_control(body):
    with LOCK:
        if 'listing' in body:
            SHOTS['listing'] = body['listing']
        if 'download_status' in body:       # e.g. 503: every screenshot download fails that way; 0/null: back to normal
            SHOTS['download_status'] = int(body['download_status'] or 0)
        chat = bool(body.get('chat')) or any(s['chat'] for s in SHOTS['sessions'].values())
        if body.get('sessions'):
            for i in range(int(body['sessions'])):
                SHOTS['sessions'][f'filler_{i:04d}'] = {'profile': 'default', 'chat': False, 'last_active': time.time() - 3600 - i,
                                                       'rows': [{'role': 'assistant', 'content': f'Filler chat {i}', 'row_id': 1, 'timestamp': time.time() - 3600}]}
        if body.get('seed') or body.get('messages'):
            sid, session = shot_session(chat=chat)
            now = time.time()
            filler = [{'role': 'assistant' if i % 2 else 'user', 'content': f'Filler message {i} for the screenshot chat.', 'timestamp': now - 4000}
                      for i in range(int(body.get('messages') or 0))]
            add_rows(sid, session, filler)
            count = int(body.get('seed') or 0)
            for i in range(count):
                SHOTS['count'] += 1
                add_rows(sid, session, shot_rows(SHOTS['count'], now - (count - i) * 12))
            if chat and count:
                add_rows(sid, session, [{'role': 'assistant', 'content': 'That is what I did on the screen.', 'timestamp': now}])
        if body.get('stored'):
            sid, session = shot_session(chat=chat)
            for _ in range(int(body['stored'])):
                SHOTS['count'] += 1
                add_rows(sid, session, shot_rows(SHOTS['count'], time.time()))
        if body.get('expire'):
            names = body['expire']
            if names == 'latest':
                names = [f"shot-{SHOTS['count']:04d}.png"]
            for path, info in SHOTS['files'].items():
                if any(path.endswith(name) for name in names):
                    info['expired'] = True
    if body.get('live'):
        live = body['live']
        with LOCK:
            SHOTS['count'] += 1
            SHOTS['live'] += 1
            n = SHOTS['count']
            path = shot_path(n)
            SHOTS['files'][path] = {'n': n, 'expired': False, 'at': time.time()}
            sid, session = shot_session(chat=chat)
            session['last_active'] = time.time()
        tool = live.get('tool', 'computer_use')
        args = {k: live[k] for k in ('action', 'app', 'url') if k in live}
        tool_id = f'live_shot_{n}'
        b47.emit('default', 'tool.start', {'tool_id': tool_id, 'name': tool, 'args': args})

        def complete():
            image = 'data:image/png;base64,' + base64.b64encode(png(640, 400, n)).decode()
            b47.emit('default', 'tool.complete', {'tool_id': tool_id, 'name': tool, 'args': args, 'duration_s': 0.4, 'result': {
                'content': [{'type': 'text', 'text': 'Done.'}, {'type': 'image_url', 'image_url': {'url': image}}],
                'meta': {'screenshot_path': path}}})
        threading.Timer(float(live.get('after_ms', 400)) / 1000, complete).start()


def sessions_poll(profile):
    with LOCK:
        LEDGER['sessions_polls'] += 1
        mine = [(sid, s) for sid, s in SHOTS['sessions'].items() if s['profile'] == profile]
        rows = [{'id': sid, 'last_active': s['last_active'], 'cwd': cwd(), 'title': 'Screenshots', 'message_count': len(s['rows']) or 6,
                 'profile': profile} for sid, s in sorted(mine, key=lambda item: -item[1]['last_active'])[:3]]
    if not rows and profile in voice.SIDS:
        rows = [{'id': voice.SIDS[profile], 'last_active': 1790852400, 'cwd': cwd(), 'title': 'Chat', 'message_count': 1, 'profile': profile}]
    return {'sessions': rows, 'total': len(rows)}


# ---------------------------------------------------------------------------------------------- HTTP

def health_body():
    h = STATE['health']
    helper = None
    if h['helper']:
        helper = {'ok': h['helper_ok'], 'running': True, 'tcc': {'screen': h['tcc_screen'], 'events': h['tcc_events']},
                  'locked': h['locked'], 'secure_input': h['secure_input'], 'paused': h['paused'], 'capture_error': h['capture_error']}
    return {'ok': h['ok'], 'installed': h['installed'], 'platform': h['platform'], 'drift': h['drift'], 'enabled': h['enabled'],
            'control': h['control'], 'profiles': None, 'blocker': h['blocker'], 'helper': helper, 'legacy_plugin_loaded': False,
            'legacy_app': False}


def ledger():
    with LOCK:
        default = lease('default')
        view = json.loads(json.dumps(LEDGER))
        view.update(mode=STATE['mode'], lease={**public(default), 'viewer_id': default['viewer_id']},
                    leases={p: public(e) for p, e in LEASES.items()}, viewers=len(STREAMS), state=STATE,
                    shots={'count': SHOTS['count'], 'files': sorted(SHOTS['files']), 'live': SHOTS['live']},
                    stream_serial=LAST['stream'].frames_sent if LAST['stream'] else 0)
    return view


def reset():
    with LOCK:
        for stream in list(STREAMS):
            stream.ws.cut()
        for profile, item in SHOTS['chat_rows']:
            if item in b47.MESSAGES[profile]:
                b47.MESSAGES[profile].remove(item)
        for profile in b47.RUNNING:
            b47.RUNNING[profile] = False
        STATE.clear(); STATE.update(fresh_state())
        LEDGER.clear(); LEDGER.update(fresh_ledger())
        SHOTS.clear(); SHOTS.update(fresh_shots())
        LEASES.clear(); VIEWERS.clear(); TICKETS.clear()
        LAST['stream'] = None
        LAST['epoch'] = LAST.get('epoch', 0) + 1


def others(count, every_ms):
    for i in range(count):
        if i:
            time.sleep(every_ms / 1000)
            deadline = time.time() + 5          # the phone re-attaches; wait for its new stream before taking again
            while time.time() < deadline and not STREAMS:
                time.sleep(0.05)
        acquire('default', 'v_other_' + secrets.token_hex(6), 'another viewer', evict_all=count > 1)


def control(body):
    unknown = sorted(set(body) - set(KNOWN))
    if unknown:
        return 400, {'error': 'unknown keys: ' + ', '.join(unknown), 'known': list(KNOWN)}
    if 'mode' in body and body['mode'] not in MODES:
        return 400, {'error': 'unknown mode', 'known': list(MODES)}
    changed = False
    with LOCK:
        for key in ('mode', 'starts_as', 'status_delay_ms', 'rpc_delay_ms', 'blocker', 'host', 'finish_setup_after_ms'):
            if key in body:
                changed = changed or (key in ('mode', 'blocker') and STATE[key] != body[key])
                STATE[key] = body[key]
        for key in ('health', 'stream', 'tickets'):
            if key in body:
                bad = sorted(set(body[key]) - set(STATE[key]))
                if bad:
                    return 400, {'error': f'unknown {key} keys: ' + ', '.join(bad), 'known': sorted(STATE[key])}
                STATE[key].update(body[key])
        if 'fail' in body:
            for method, message in (body['fail'] or {}).items():
                if message is None:
                    STATE['fail'].pop(method, None)
                else:
                    STATE['fail'][method] = message
            if not body['fail']:
                STATE['fail'].clear()
    if 'mode' in body and not running():
        with LOCK:
            streams = list(STREAMS)
        for stream in streams:
            stream.ws.close(4001, 'Bot Desktop is not running')
    if changed or body.get('health_now'):
        push_status()
    if 'shots' in body:
        shots_control(body['shots'])
    if body.get('other_takes'):
        count = 1 if body['other_takes'] is True else int(body['other_takes'])
        threading.Thread(target=others, args=(count, float(body.get('every_ms', 1500))), daemon=True).start()
    if body.get('agent_takes'):
        set_lease('default', 'agent', None, 'agent')
    if body.get('drop_ws'):
        with LOCK:
            conns = list(CONNS.values())
        for conn in conns:
            try:
                conn.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
    if 'busy' in body:
        b47.RUNNING['default'] = bool(body['busy'])
        if body['busy']:
            b47.CANCEL['default'].set()
            b47.emit('default', 'message.start')
        else:
            row = b47.append('default', 'assistant', 'Finished the earlier reply.')
            b47.emit('default', 'message.complete', {'text': 'Finished the earlier reply.', 'row_id': row})
    return 200, {'ok': True}


_perf_handler = b47.handler


def handler(gateway):
    parent = _perf_handler(gateway)

    class Handler(parent):
        def body(self):
            rawbody = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            return json.loads(rawbody or b'{}')

        def binary(self, status, data, kind):
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query, keep_blank_values=True)
            one = lambda name, default='': (query.get(name) or [default])[0]
            if path == '/__fixture/screen':
                return self.reply(200, ledger())
            if path == '/__fixture/screen/expect':
                stream = LAST['stream']
                if not stream:
                    return self.reply(200, {'points': [], 'probe': '', 'size': [0, 0], 'serial': 0})
                points = stream.picture.probe()
                return self.reply(200, {'points': points, 'probe': ''.join(points), 'size': list(stream.size), 'serial': stream.frames_sent})
            if path == '/api/display/ws':
                if (self.headers.get('Upgrade') or '').lower() != 'websocket':
                    return self.reply(400, {'detail': 'websocket only'})
                return display_ws(self)
            if path.startswith('/api/') and path != '/api/status' and not self.session():
                return super().do_GET()
            for name, route in (('new', '/api/plugins/hermes-hq-screen/health'), ('legacy', '/api/plugins/dispatch-screen/health')):
                if path == route:
                    h = STATE['health']
                    with LOCK:
                        LEDGER['health_hits'][name] += 1
                        LEDGER['health_hits']['times'].append([name, time.time()])
                        del LEDGER['health_hits']['times'][:-500]
                    if h['delay_ms']:
                        time.sleep(h['delay_ms'] / 1000)
                    if h['plugin'] != name:
                        return self.reply(404, {'detail': 'Not Found'})
                    if h['status'] != 200:
                        return self.reply(int(h['status']), {'detail': 'health failed'})
                    return self.reply(200, health_body())
            if path == '/api/fs/list':
                with LOCK:
                    LEDGER['fs_list_hits'] += 1
                    LEDGER['fs_list_times'].append(time.time())
                    del LEDGER['fs_list_times'][:-500]
                    folder = one('path')
                    sep = '\\' if '\\' in folder else '/'
                    names = sorted(p.rsplit(sep, 1)[1] for p, info in SHOTS['files'].items()
                                   if p.rsplit(sep, 1)[0] == folder.rstrip(sep) and not info['expired'])
                    mode = SHOTS['listing']
                if mode == 'fail':
                    return self.reply(500, {'detail': 'listing failed'})
                return self.reply(200, {'entries': [] if mode == 'empty' else [{'name': n, 'is_dir': False} for n in names]})
            if path == '/api/fs/download':
                with LOCK:
                    LEDGER['downloads'] += 1
                    info = SHOTS['files'].get(one('path'))
                    broken = SHOTS.get('download_status') or 0
                if broken:
                    return self.reply(broken, {'detail': 'fixture: download failed'})
                if not info or info['expired']:
                    return self.reply(404, {'detail': 'File not found'})
                return self.binary(200, png(640, 400, info['n']), 'image/png')
            if path == '/api/profiles/sessions' and one('limit') == '3' and one('order') == 'recent':
                return self.reply(200, sessions_poll(one('profile', 'default')))
            if path.startswith('/api/sessions/') and path.endswith('/messages'):
                sid = path.split('/')[3]
                with LOCK:
                    LEDGER['messages_fetches'] += 1
                    session = SHOTS['sessions'].get(sid)
                    rows = list(session['rows']) if session and not session['chat'] else None
                if rows is not None:
                    limit = max(1, int(one('limit', '40') or 40))
                    page = rows[-limit:]
                    return self.reply(200, {'session_id': sid, 'messages': page, 'total': len(rows), 'has_more': len(rows) > len(page)})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/screen':
                code, answer = control(self.body())
                return self.reply(code, answer)
            if path == '/__fixture/screen/reset':
                self.body()
                reset()
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler


b47.handler = handler


def load_frames(folder):
    for manifest in sorted(pathlib.Path(folder).glob('*/manifest.json')):
        info = json.loads(manifest.read_text())
        FRAMESETS[(info['width'], info['height'])] = {'dir': manifest.parent, 'base': (manifest.parent / 'base.bgrx').read_bytes(),
                                                      'rects': [f['rects'] for f in info['frames']]}


# ---------------------------------------------------------------------------------------------- test vectors

def emit_vectors(folder):
    """Decoder vectors for Tests/Screen: <name>.rfb is everything a server sends from its version line on, <name>.bgrx
    the picture it must leave (lossless cases), vectors.json the list."""
    out = pathlib.Path(folder)
    out.mkdir(parents=True, exist_ok=True)
    listing = []
    W, H = 64, 48

    def pattern(w, h, seed=0, colours=None):
        px = bytearray()
        for y in range(h):
            for x in range(w):
                if colours:
                    c = colours[(x // 3 + y // 2 + seed) % len(colours)]
                    px += bytes(c) + b'\0'
                else:
                    px += bytes([(x * 5 + seed * 3) % 256, (y * 7 + x + seed) % 256, (x * y + seed * 11) % 256, 0])
        return px

    def save(name, w, h, messages, picture, note, samples=None, tolerance=0, size=None):
        head = b'RFB 003.008\n' + bytes([1, 1]) + struct.pack('>I', 0) + server_init(w, h, 'This Mac')
        (out / (name + '.rfb')).write_bytes(head + b''.join(messages))
        entry = {'name': name, 'width': size[0] if size else w, 'height': size[1] if size else h, 'note': note}
        if picture is not None:
            (out / (name + '.bgrx')).write_bytes(bytes(picture.px))
        if samples:
            entry.update(samples=samples, tolerance=tolerance)
        listing.append(entry)

    # Raw
    p = Picture(W, H); data = pattern(W, H, 1); p.put(0, 0, W, H, data)
    save('raw', W, H, [update([raw(0, 0, W, H, data)])], p, 'one Raw rect')
    # CopyRect with overlap (right-down and left-up)
    p = Picture(W, H); data = pattern(W, H, 2); p.put(0, 0, W, H, data)
    p.copy(12, 10, 30, 20, 4, 4)
    p.copy(2, 2, 30, 20, 10, 8)
    save('copyrect-overlap', W, H, [update([raw(0, 0, W, H, data), copyrect(12, 10, 30, 20, 4, 4), copyrect(2, 2, 30, 20, 10, 8)])], p,
         'Raw, then two overlapping CopyRects')
    # Tight Fill
    t = Tight(); p = Picture(W, H)
    p.fill(0, 0, W, H, bytes([10, 20, 30])); p.fill(8, 6, 20, 10, bytes([200, 100, 50]))
    save('tight-fill', W, H, [update([t.fill(0, 0, W, H, bytes([10, 20, 30])), t.fill(8, 6, 20, 10, bytes([200, 100, 50]))])], p, 'two Tight Fill rects')
    # Tight Basic copy filter: under 12 bytes raw, then zlib, with 1- and 2-byte lengths, and a stream carried across rects
    t = Tight(); p = Picture(W, H)
    small = pattern(3, 1, 3); p.put(1, 1, 3, 1, small)
    a = pattern(16, 4, 4, [(1, 2, 3), (4, 5, 6)]); p.put(0, 8, 16, 4, a)
    b = pattern(W, 30, 5); p.put(0, 16, W, 30, b)
    c = pattern(20, 2, 6, [(9, 9, 9), (7, 7, 7), (5, 5, 5)]); p.put(30, 2, 20, 2, c)
    save('tight-copy', W, H, [update([t.copy(1, 1, 3, 1, small), t.copy(0, 8, 16, 4, a), t.copy(0, 16, W, 30, b)]), update([t.copy(30, 2, 20, 2, c)])], p,
         'copy filter: 9 raw bytes, a 1-byte length, a 2-byte length, the same zlib stream in a later update')
    # Tight palette: 2 colours (1 bit per pixel, a width that is not a multiple of 8), then 5 colours
    t = Tight(); p = Picture(W, H)
    two = [(250, 250, 250), (20, 30, 40)]
    a = pattern(13, 9, 0, two); p.put(3, 3, 13, 9, a)
    five = [(1, 2, 3), (40, 50, 60), (70, 80, 90), (100, 110, 120), (130, 140, 150)]
    b = pattern(40, 20, 1, five); p.put(20, 20, 40, 20, b)
    tiny = pattern(2, 2, 0, two); p.put(0, 40, 2, 2, tiny)
    save('tight-palette', W, H, [update([t.palette(3, 3, 13, 9, a, [bytes(c) for c in two]), t.palette(20, 20, 40, 20, b, [bytes(c) for c in five]),
                                         t.palette(0, 40, 2, 2, tiny, [bytes(c) for c in two])])], p,
         'palette filter: 2 colours packed in bits with padded rows, 5 colours as bytes, 2 colours under 12 bytes')
    # Tight gradient
    t = Tight(); p = Picture(W, H)
    a = pattern(24, 16, 7); p.put(5, 5, 24, 16, a)
    save('tight-gradient', W, H, [update([t.gradient(5, 5, 24, 16, a)])], p, 'gradient filter')
    # Stream reset bits
    t = Tight(); p = Picture(W, H)
    a = pattern(32, 16, 8); b = pattern(32, 16, 9); c = pattern(32, 16, 10)
    p.put(0, 0, 32, 16, a); p.put(32, 0, 32, 16, b); p.put(0, 16, 32, 16, c)
    save('tight-reset', W, H, [update([t.copy(0, 0, 32, 16, a), t.copy(32, 0, 32, 16, b, reset=True), t.copy(0, 16, 32, 16, c, stream=3, reset=True)])], p,
         'copy filter with reset bits on streams 0 and 3')
    # A 3-byte compact length: noise that zlib cannot shrink, over 16,384 bytes
    t = Tight(); big_w, big_h = 96, 80
    p = Picture(big_w, big_h)
    noise = bytearray()
    state = 12345
    for _ in range(big_w * big_h):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        noise += bytes([state & 255, (state >> 8) & 255, (state >> 16) & 255, 0])
    p.put(0, 0, big_w, big_h, noise)
    body = t.copy(0, 0, big_w, big_h, noise)
    assert body[13] & 0x80 and body[14] & 0x80, 'expected a 3-byte compact length'
    save('tight-long', big_w, big_h, [update([body])], p, 'copy filter with a 3-byte compact length')
    # DesktopSize and ExtendedDesktopSize, then a picture at the new size; LastRect
    for name, code in (('desktop-size', -223), ('ext-desktop-size', -308)):
        t = Tight(); p = Picture(40, 30)
        data = pattern(40, 30, 11); p.put(0, 0, 40, 30, data)
        size = rect(0, 0, 40, 30, code) + (struct.pack('>BxxxIHHHHI', 1, 1, 0, 0, 40, 30, 0) if code == -308 else b'')
        save(name, W, H, [update([raw(0, 0, W, H, pattern(W, H, 1))]), update([size]), update([raw(0, 0, 40, 30, data)])], p,
             'a picture, a resize to 40x30, a picture at the new size', size=(40, 30))
    p = Picture(W, H); data = pattern(W, 8, 12); p.put(0, 0, W, 8, data)
    last = struct.pack('>BBH', 0, 0, 0xFFFF) + raw(0, 0, W, 8, data) + rect(0, 0, 0, 0, -224)
    more = pattern(8, 8, 13); p.put(8, 20, 8, 8, more)
    save('last-rect', W, H, [last, update([raw(8, 20, 8, 8, more)])], p, 'an update of unknown length ended by LastRect, then a normal one')
    # Skipped server messages between updates
    p = Picture(W, H); data = pattern(W, H, 14); p.put(0, 0, W, H, data)
    skipped = struct.pack('>BxHH', 1, 0, 2) + bytes(12) + bytes([2]) + struct.pack('>BxxxI', 3, 5) + b'hello'
    save('skipped-messages', W, H, [skipped, update([raw(0, 0, W, H, data)])], p, 'colour map, bell and cut text before an update')
    # Tight JPEG (needs the prepared frames): a tile (2-byte length) and a whole frame (3-byte length)
    frames = FRAMESETS.get((1280, 800))
    if frames:
        t = Tight(); base = Picture(1280, 800, frames['base'])
        x, y, w, h = frames['rects'][0][0]
        tile = (frames['dir'] / 'frame-00' / f'tile-{x}-{y}-{w}x{h}.jpg').read_bytes()
        whole = (frames['dir'] / 'full-00.jpg').read_bytes()
        points = [[int(1280 * fx), int(800 * fy)] for fx, fy in SAMPLES] + [[x + w // 2, y + h - 4]]
        samples = [[px, py, *base.px[(py * 1280 + px) * 4:(py * 1280 + px) * 4 + 3]] for px, py in points]
        save('tight-jpeg', 1280, 800, [update([t.jpeg(0, 0, 1280, 800, whole)]), update([t.jpeg(x, y, w, h, tile)])], None,
             f'a whole frame ({len(whole)} bytes, 3-byte length) and a tile ({len(tile)} bytes, 2-byte length)', samples=samples, tolerance=40)
    (out / 'vectors.json').write_text(json.dumps(listing, indent=1) + '\n')
    print(f'wrote {len(listing)} vectors to {out}')


if __name__ == '__main__':
    def option(name):
        if name in sys.argv:
            at = sys.argv.index(name)
            value = sys.argv[at + 1]
            del sys.argv[at:at + 2]
            return value
        return None
    frames = option('--frames') or 'build/fixtures/screen-frames'
    vectors = option('--emit-vectors')
    load_frames(frames)
    if vectors:
        emit_vectors(vectors)
        sys.exit(0)
    any_port = '--any-port' in sys.argv
    if any_port:
        sys.argv.remove('--any-port')
    port = int(sys.argv[sys.argv.index('--port') + 1]) if '--port' in sys.argv else None
    if port is None or (not any_port and not 9940 <= port <= 9949):
        sys.exit('pass --port in 9940-9949 (this stream\'s ports), or --any-port with another port')
    if not FRAMESETS:
        print(f'no prepared frames in {frames}: sizes are drawn as colour bands '
              f'(swift scripts/fixtures/make-screen-frames.swift {frames})', flush=True)
    b47.main()
