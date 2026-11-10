#!/usr/bin/env python3
"""Loopback stand-in gateway for the photoheads stream (docs/spec/3x-photoheads.md §10.1). Invented data only.

Loads the settings fixture by path (nothing in it is edited; the settings stream owns it) for sign-in, /api/ws,
profiles.list / configure / set_asset / get_asset with the gateway's contract checks, and adds what it lacks:
seeded avatars of every kind, failures for the two asset methods, a "network" switch, and a call log.

Seed (expected face):
  default   saved head   288x288 PNG, the app's own head copy        head
  ivy       -            256x256 PNG "photo A"                       photo
  research  saved head   640x480 JPEG (--media landscape.jpg)        photo, centre-cropped
  inbox     -            160x160 PNG, desktop's face copy            default head
  deploys   - (hidden)   96x104 PNG, pet-like                        photo, centre-cropped
  notes     -            none (has_avatar false)                     default head
  webp      -            96x96 WebP                                  photo
  broken    -            PNG header, cut body                        default head
  huge      saved head   4000x3000 JPEG, about 1.9 MB (--media huge.jpg)   photo

Options: --port, --credentials <file> (0600, never printed), --hermes-cookies, --label <name> (a second gateway: the
same profile names, different pictures), --media <folder> (scripts/fixtures/make-photoheads-media.swift), --bots N
(N more bots load-001..., each with its own 256 px PNG), --no-assets (an older gateway: rows carry no has_avatar and
both asset methods answer "method not found"), --access-ttl.

Controls (loopback, no auth, never under /api/, like /__settings/*; every /__settings/* control still works):
  GET  /__photoheads/state
       bots: per bot has_avatar, avatar_mime, avatar_size, avatar_png ([w, h] or null), avatar_sha, image_kind,
       revisions, get_asset_calls, set_asset_calls; calls: every asset call (data as a length, a PNG's size, a hash);
       writes: the settings fixture's write log; contract_4000; max_get_in_flight; net; methods (calls per RPC method); prompts (messages sent).
  POST /__photoheads/other-device {profile, avatar, bump}
       another device changes the picture. avatar: photo-a | photo-b | mirror | backfill | jpeg | webp | pet | broken |
       clear. bump: "hermes-bots" | "dispatch-head" | null (no revision moves).
  POST /__photoheads/fail {method, mode, count, seconds}
       method: profiles.get_asset | profiles.set_asset. mode: error (5066 / 5065 "disk full") | unknown-method |
       too-large (4069) | bad-format (4070) | slow (seconds, default 35, then answers) | drop (closes the socket instead
       of answering) | found-no-data ({"found": true}) | garbage (data is not base64).
  POST /__photoheads/net {mode, ms}      down (close every socket, refuse new ones) | up | lag (every answer waits ms)
  POST /__photoheads/reply-delay {seconds}   a bot's reply to a sent message waits that long first (the reply peek)
  POST /__photoheads/reset               back to the seed

  python3 scripts/fixtures/photoheads-gateway.py --port 9950 --hermes-cookies --credentials build/fixtures/photoheads-a.json \\
      --media build/fixtures/photoheads-media
"""
import argparse, base64, hashlib, importlib.util, json, os, pathlib, secrets, socket, struct, sys, threading, time, zlib
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse

_spec = importlib.util.spec_from_file_location('settings_fixture', pathlib.Path(__file__).parent / 'settings-gateway.py')
settings = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(settings)
voice = settings.voice
RPCFailure = settings.RPCFailure

# The same 96 x 96 lossless WebP the unit test proves ImageIO reads (Tests/PhotoHeads/PhotoHeadsTestSupport.swift):
# teal field, white ring, yellow centre. Made once with a local encoder; never downloaded.
WEBP = base64.b64decode(
    'UklGRuYAAABXRUJQVlA4TNoAAAAvX8AXAH+gEJIkZy77ex3CMXw9QNJQEwBochGGEnz0T8Gtc1UTSYq0RfQKIEcDrjCHNeJ75j/+/1lAARagMNBK0qbRXHS4c4NN'
    'EuPgMltk4YKbCACQCClABCugDcggCYjAUcGZmQjgu0YgArP9f4DfcYclov8K2rZhHA47FH7PRJXvLVDyHVKwzAJx3ZAIBhaIbC8vhGYmR4DToLE3uT80Ddn+JhfB'
    'z6JSU3s5n2W4At9LapZhy0ovsX5fLD8Hlp8zy8/t587yd+Dyd+byd/tFtfwft8Kf+Ej0Aw==')

OPTIONS = {'label': '', 'media': None, 'bots': 0, 'no_assets': False}
PH = {}
CURRENT = threading.local()
ASSET_METHODS = ('profiles.get_asset', 'profiles.set_asset')


class Dropped(Exception):
    """The socket was closed instead of answering."""


def fresh():
    return {'calls': [], 'fail': [], 'contract_4000': 0, 'in_flight': 0, 'max_get_in_flight': 0, 'net': {'down': False, 'lag': 0},
            'reply_delay': 0, 'methods': {}}


# ---- pictures, drawn here (zlib + struct): flat fields with a clear mark ------------------------------------------
def png(width, height, base, rects=()):
    """An RGB PNG: `base` everywhere, then each (x0, y0, x1, y1, colour) rectangle over it."""
    rows, raw = {}, bytearray()
    for y in range(height):
        spans = tuple((x0, x1, colour) for x0, y0, x1, y1, colour in rects if y0 <= y < y1)
        row = rows.get(spans)
        if row is None:
            line = bytearray(bytes(base) * width)
            for x0, x1, colour in spans:
                x0, x1 = max(0, x0), min(width, x1)
                if x1 > x0:
                    line[x0 * 3:x1 * 3] = bytes(colour) * (x1 - x0)
            row = rows[spans] = b'\x00' + bytes(line)
        raw += row

    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b''))


WHITE, BLACK, YELLOW = (255, 255, 255), (20, 20, 24), (255, 210, 63)


def photo_a():
    """Photo A: a warm field, a white upright bar, a dark square top-left. On the second gateway the field is green."""
    base = (34, 160, 92) if OPTIONS['label'] else (232, 93, 58)
    return png(256, 256, base, [(104, 40, 152, 216, WHITE), (16, 16, 64, 64, BLACK)])


def photo_b():
    """Photo B: a blue field, a yellow bar lying down, a dark square top-left."""
    base = (150, 60, 190) if OPTIONS['label'] else (48, 96, 220)
    return png(256, 256, base, [(40, 104, 216, 152, YELLOW), (16, 16, 64, 64, BLACK)])


def mirror():
    """What the app stores for a saved head: exactly 288 x 288. Its pixels do not matter (only its size is read)."""
    return png(288, 288, (120, 122, 132), [(72, 72, 216, 216, (200, 202, 210))])


def backfill():
    """What desktop Hermes stores of its own face: exactly 160 x 160."""
    return png(160, 160, (28, 110, 116), [(40, 40, 120, 120, (220, 240, 240))])


def pet():
    """A desktop "Pet": 96 x 104, taller than wide."""
    return png(96, 104, (238, 130, 170), [(28, 24, 68, 64, WHITE), (36, 72, 60, 92, BLACK)])


def broken():
    """A PNG that says 200 x 200 and stops inside its pixel data."""
    return png(200, 200, (60, 180, 90), [(50, 50, 150, 150, WHITE)])[:60]


def load_photo(index):
    base = ((index * 37) % 200 + 40, (index * 91) % 200 + 40, (index * 53) % 200 + 40)
    x = 24 + (index * 17) % 160
    return png(256, 256, base, [(x, 32, x + 40, 224, WHITE), (16, 16, 48, 48, BLACK)])


def media(name, fallback):
    """A JPEG from --media, or a PNG drawn here when the folder (or the file) is missing."""
    folder = OPTIONS['media']
    if folder:
        path = pathlib.Path(folder) / name
        if path.is_file():
            return ('jpg', path.read_bytes())
    return ('png', fallback())


def jpeg_landscape():
    return media('landscape.jpg', lambda: png(640, 480, (70, 140, 200), [(0, 0, 320, 240, (230, 40, 40)), (320, 240, 640, 480, YELLOW)]))


def jpeg_huge():
    return media('huge.jpg', lambda: png(1200, 900, (90, 90, 160), [(0, 0, 600, 450, (230, 40, 40)), (600, 450, 1200, 900, YELLOW)]))


PICTURES = {
    'photo-a': lambda: ('png', photo_a()), 'photo-b': lambda: ('png', photo_b()), 'mirror': lambda: ('png', mirror()),
    'backfill': lambda: ('png', backfill()), 'jpeg': jpeg_landscape, 'huge': jpeg_huge, 'webp': lambda: ('webp', WEBP),
    'pet': lambda: ('png', pet()), 'broken': lambda: ('png', broken()),
}
PHOTO_KINDS = ('photo-a', 'photo-b', 'jpeg', 'huge', 'webp', 'pet')

HEAD = {'v': 6, 'theme': 'shape', 'color': 'mint', 'seed': 23, 'form': 'square', 'look': 'ovals', 'specs': 'none', 'hat': 'none',
        'mouth': 'none', 'blush': False, 'tile': 'none'}


# ---- the seed -----------------------------------------------------------------------------------------------------
_settings_seed = settings.seed


def seed():
    state = _settings_seed()
    profiles = state['profiles']
    label = OPTIONS['label']

    def add(name, shown, description, ui_meta=None, revisions=None):
        profiles[name] = {'display_name': f'{label} {shown}' if label else shown,
                          'description': f'{label} {description}' if label else description,
                          'ui_meta': ui_meta or {}, 'revisions': revisions or {}, 'chat': None, 'avatar': None, 'extra_chats': []}
        state['skills'][name] = settings.default_skills()
        state['mcp'][name] = settings.default_mcp()
    add('webp', 'Webp', 'Wears a WebP picture')
    add('broken', 'Broken', 'Has a picture that is cut off')
    add('huge', 'Huge', 'Wears a very large photo', {'dispatch-head': dict(HEAD)}, {'dispatch-head': 1})
    for index in range(1, OPTIONS['bots'] + 1):
        add(f'load-{index:03d}', f'Load {index:03d}', 'One of many')
    if not OPTIONS['no_assets']:
        for name, kind in (('default', 'mirror'), ('ivy', 'photo-a'), ('research', 'jpeg'), ('inbox', 'backfill'), ('deploys', 'pet'),
                           ('webp', 'webp'), ('broken', 'broken'), ('huge', 'huge')):
            profiles[name]['avatar'] = PICTURES[kind]()
        for index in range(1, OPTIONS['bots'] + 1):
            profiles[f'load-{index:03d}']['avatar'] = ('png', load_photo(index))
    return state


settings.seed = seed


# ---- rows: an older gateway has no has_avatar key ------------------------------------------------------------------
_settings_profile_row = settings.profile_row


def profile_row(name, include_sessions):
    row = _settings_profile_row(name, include_sessions)
    if OPTIONS['no_assets']:
        row.pop('has_avatar', None)
    return row


settings.profile_row = profile_row


# ---- RPC: the two asset methods, with their failures and a log ------------------------------------------------------
_settings_rpc = settings.rpc


def sha(blob):
    return hashlib.sha256(blob).hexdigest()[:16]


def decoded(data):
    """The bytes behind a data URL or bare base64, or None."""
    text = data.split(',', 1)[1] if data.startswith('data:') and ',' in data else data
    try:
        return base64.b64decode(text, validate=True)
    except Exception:
        return None


def take(method):
    with settings.LOCK:
        for entry in PH['fail']:
            if entry['method'] == method and entry['count'] > 0:
                entry['count'] -= 1
                return entry
    return None


def asset_rpc(method, params):
    reading = method == 'profiles.get_asset'
    entry = {'method': method, 'name': str(params.get('name') or ''), 'at': time.time(), 'keys': sorted(params.keys())}
    if not reading:
        entry['clear'] = params.get('clear') is True
        data = params.get('data')
        if isinstance(data, str):
            entry['data'] = len(data)
            blob = decoded(data)
            if blob is not None:
                entry['size'], entry['sha'] = len(blob), sha(blob)
                size = settings.png_size(blob)
                entry['png'] = list(size) if size else None
    with settings.LOCK:
        PH['calls'].append(entry)
        if reading:
            PH['in_flight'] += 1
            PH['max_get_in_flight'] = max(PH['max_get_in_flight'], PH['in_flight'])
    try:
        if OPTIONS['no_assets']:
            raise RPCFailure(-32601, f'Method not found: {method}')
        failure = take(method)
        mode = failure['mode'] if failure else None
        if mode == 'slow':
            time.sleep(float(failure.get('seconds') or 35))
        elif mode == 'error':
            raise RPCFailure(5066 if reading else 5065, 'disk full')
        elif mode == 'unknown-method':
            raise RPCFailure(-32601, f'Method not found: {method}')
        elif mode == 'too-large':
            raise RPCFailure(4069, 'asset too large (2400000 bytes; max 2MB)')
        elif mode == 'bad-format':
            raise RPCFailure(4070, 'unsupported image format (PNG/JPEG/WebP only)')
        elif mode == 'drop':
            entry['outcome'] = 'dropped'
            client = getattr(CURRENT, 'client', None)
            if client is not None:
                try:
                    client.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            raise Dropped()
        elif mode == 'found-no-data' and reading:
            entry['outcome'] = 'found-no-data'
            return {'found': True}
        elif mode == 'garbage' and reading:
            entry['outcome'] = 'garbage'
            return {'found': True, 'mime': 'image/png', 'size': 12, 'data': 'data:image/png;base64,@@@ this is not base64 @@@'}
        result = _settings_rpc(method, params)
        entry['outcome'] = 'ok'
        return result
    except RPCFailure as failure:
        entry['outcome'] = f'error:{failure.code}'
        if failure.code == 4000:
            with settings.LOCK:
                PH['contract_4000'] += 1
        raise
    finally:
        if reading:
            with settings.LOCK:
                PH['in_flight'] -= 1


def rpc(method, params):
    with settings.LOCK:
        PH['methods'][method] = PH['methods'].get(method, 0) + 1
    lag = PH['net']['lag']
    if lag:
        time.sleep(lag / 1000)
    if method in ASSET_METHODS:
        return asset_rpc(method, params)
    try:
        return _settings_rpc(method, params)
    except RPCFailure as failure:
        if failure.code == 4000:
            with settings.LOCK:
                PH['contract_4000'] += 1
        raise


settings.rpc = rpc

_settings_answer = settings.Client.answer


def answer(self, frame):
    CURRENT.client = self
    try:
        _settings_answer(self, frame)
    except Dropped:
        pass


settings.Client.answer = answer

# A bot's reply can be held back, so a test can be in another chat when it lands (the reply peek).
_settings_stream_intro = settings.stream_intro


def stream_intro(name, chat, user_text):
    delay = PH.get('reply_delay') or 0
    if delay:
        time.sleep(delay)
    return _settings_stream_intro(name, chat, user_text)


settings.stream_intro = stream_intro


# ---- state and controls -------------------------------------------------------------------------------------------
def state():
    with settings.LOCK:
        bots = {}
        for name, p in settings.S['profiles'].items():
            avatar = p['avatar']
            meta = p['ui_meta'].get('hermes-bots') if isinstance(p['ui_meta'], dict) else None
            size = settings.png_size(avatar[1]) if avatar else None
            bots[name] = {
                'has_avatar': avatar is not None,
                'avatar_mime': settings.MIMES[avatar[0]] if avatar else None,
                'avatar_size': len(avatar[1]) if avatar else 0,
                'avatar_png': list(size) if size else None,
                'avatar_sha': sha(avatar[1]) if avatar else None,
                'image_kind': meta.get('imageKind') if isinstance(meta, dict) else None,
                'ui_meta': p['ui_meta'],
                'revisions': dict(p['revisions']),
                'get_asset_calls': sum(1 for c in PH['calls'] if c['method'] == 'profiles.get_asset' and c['name'] == name),
                'set_asset_calls': sum(1 for c in PH['calls'] if c['method'] == 'profiles.set_asset' and c['name'] == name),
            }
        return {'bots': bots, 'calls': list(PH['calls']), 'writes': list(settings.S['writes']), 'fail': list(PH['fail']),
                'contract_4000': PH['contract_4000'], 'max_get_in_flight': PH['max_get_in_flight'], 'net': dict(PH['net']),
                'methods': dict(PH['methods']), 'prompts': len(settings.S['prompts']),
                'no_assets': OPTIONS['no_assets'], 'label': OPTIONS['label']}


def close_sockets():
    with settings.LOCK:
        clients = list(settings.CLIENTS)
    for client in clients:
        try:
            client.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def other_device(body):
    with settings.LOCK:
        p = settings.S['profiles'].get(body.get('profile'))
        kind = body.get('avatar')
        if p is None or (kind != 'clear' and kind not in PICTURES):
            return 400, {'detail': 'profile and avatar (photo-a | photo-b | mirror | backfill | jpeg | webp | pet | broken | clear)'}
        p['avatar'] = None if kind == 'clear' else PICTURES[kind]()
        bump = body.get('bump')
        if bump in ('hermes-bots', 'dispatch-head'):
            if bump == 'hermes-bots':
                # What desktop's Save writes with a picture change: the whole object, with the picture flags.
                meta = dict(p['ui_meta'].get('hermes-bots') or {})
                meta['imageKind'] = 'photo' if kind in PHOTO_KINDS else 'shape'
                meta['custom'] = True
                p['ui_meta']['hermes-bots'] = meta
            p['revisions'][bump] = p['revisions'].get(bump, 0) + 1
        elif bump is not None:
            return 400, {'detail': 'bump is "hermes-bots", "dispatch-head" or null'}
        return 200, {'ok': True, 'has_avatar': p['avatar'] is not None, 'avatar_sha': sha(p['avatar'][1]) if p['avatar'] else None,
                     'revisions': dict(p['revisions'])}


def handler(gateway):
    base = _settings_handler(gateway)

    class Handler(base):
        def refused(self):
            """The "network" is down: the connection is closed without an answer. Lag waits first."""
            path = urlparse(self.path).path
            if path.startswith('/__'):
                return False
            if PH['net']['down']:
                self.close_connection = True
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return True
            if PH['net']['lag'] and path.startswith('/api/') and path != '/api/ws':
                time.sleep(PH['net']['lag'] / 1000)
            return False

        def do_GET(self):
            if urlparse(self.path).path == '/__photoheads/state':
                return self.reply(200, state())
            if self.refused():
                return
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path.startswith('/__photoheads/'):
                return self.photo_control(path, self.body())
            if self.refused():
                return
            return super().do_POST()

        def do_PUT(self):
            if self.refused():
                return
            return super().do_PUT()

        def do_DELETE(self):
            if self.refused():
                return
            return super().do_DELETE()

        def do_PATCH(self):
            if self.refused():
                return
            return super().do_PATCH() if hasattr(base, 'do_PATCH') else self.reply(405, {'detail': 'Method not allowed'})

        def photo_control(self, path, body):
            global PH
            if path == '/__photoheads/other-device':
                return self.reply(*other_device(body))
            if path == '/__photoheads/fail':
                method, mode = body.get('method'), body.get('mode', 'error')
                modes = ('error', 'unknown-method', 'too-large', 'bad-format', 'slow', 'drop', 'found-no-data', 'garbage')
                if method not in ASSET_METHODS or mode not in modes:
                    return self.reply(400, {'detail': 'method (profiles.get_asset | profiles.set_asset) and mode'})
                with settings.LOCK:
                    PH['fail'].append({'method': method, 'mode': mode, 'count': int(body.get('count', 1)), 'seconds': body.get('seconds')})
                return self.reply(200, {'ok': True})
            if path == '/__photoheads/net':
                mode = body.get('mode')
                if mode == 'down':
                    PH['net']['down'] = True
                    close_sockets()
                elif mode == 'up':
                    PH['net'] = {'down': False, 'lag': 0}
                elif mode == 'lag':
                    PH['net']['lag'] = max(0, int(body.get('ms', 0)))
                else:
                    return self.reply(400, {'detail': 'mode is down, up or lag'})
                return self.reply(200, {'ok': True, 'net': PH['net']})
            if path == '/__photoheads/reply-delay':
                PH['reply_delay'] = max(0.0, float(body.get('seconds') or 0))
                return self.reply(200, {'ok': True, 'reply_delay': PH['reply_delay']})
            if path == '/__photoheads/reset':
                with settings.LOCK:
                    settings.S = settings.seed()
                    PH = fresh()
                return self.reply(200, {'ok': True})
            return self.reply(404, {'detail': 'unknown control'})

    return Handler


_settings_handler = settings.handler


def main():
    global PH
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=9950)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--label', default='', help="a second gateway: the same profile names, different pictures")
    parser.add_argument('--hermes-cookies', action='store_true', help="Hermes' hermes_session_at/rt session, renewed on any API read")
    parser.add_argument('--access-ttl', type=int, default=12 * 60 * 60)
    parser.add_argument('--media', default=None, help='folder made by scripts/fixtures/make-photoheads-media.swift (landscape.jpg, huge.jpg)')
    parser.add_argument('--bots', type=int, default=0, help='N more bots load-001..., each with its own 256 px PNG')
    parser.add_argument('--no-assets', action='store_true', help='an older gateway: no has_avatar, no asset methods')
    args = parser.parse_args()
    OPTIONS.update(label=args.label, media=args.media, bots=max(0, args.bots), no_assets=args.no_assets)
    settings.LABEL = args.label
    voice.LABEL = args.label
    voice.ACCEPT_PROMPTS = True
    PH = fresh()
    settings.S = settings.seed()
    username, password = 'photoheads-fixture', secrets.token_urlsafe(24)
    if args.keep_credentials and pathlib.Path(args.credentials).exists():
        kept = json.loads(pathlib.Path(args.credentials).read_text())
        username, password = kept['username'], kept['password']
    descriptor = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{args.port}'}, output)
    gateway = voice.auth.Gateway(username, password, True, None, hermes=args.hermes_cookies, access_ttl=args.access_ttl)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(gateway))
    described = ', '.join(filter(None, [args.label, 'no assets' if args.no_assets else '', f'{args.bots} extra bots' if args.bots else '']))
    print(f'Photoheads fixture on 127.0.0.1:{args.port}' + (f' ({described})' if described else ''), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
