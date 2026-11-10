#!/usr/bin/env python3
"""Loopback attachments fixture for HQ Native (docs/spec/1x-attachments.md §14.2).

Loads the reference performance fixture (sign-in, socket, streaming engine, plans, paging, Stop, /__fixture/history)
by path, read-only, and adds a Hermes-shaped attachment surface. Loopback only, ports 9700-9799 only, stdlib only,
invented data. Never forwards anything anywhere.

REST (every /api/* route needs the session cookie, as Hermes; 401 otherwise):
  GET    /api/files                    the managed root: {"path":"/fixture/uploads", ...}
  POST   /api/files/upload-stream      multipart {path, overwrite, file} under /fixture/uploads/ (403 outside, 409 exists,
                                       413 past maxBytes); answers Hermes' shape with `entry`; records gps/camera metadata
  DELETE /api/files                    {path, recursive}: a staging folder under uploads (404 when gone)
  GET    /api/fs/download              path/profile/session_id; Range; 404 File not found; 404 Session not found for an
                                       unknown session_id; a relative path resolves against /fixture with a known session
JSON-RPC (strict params → 4000 on image.attach, file.attach, image.detach, prompt.submit):
  image.attach   runtime must match (4001), path under uploads (4016), image extension (4016); queued per bot
  file.attach    copy into /fixture-home/attachments/<name> (-2… on clashes; `uploaded:true`) or in place
  image.detach   unqueues
  prompt.submit  takes the queued images; the stored user row is text + one `@image:<path>` line each (Hermes' form);
                 with no plan queued the reply is "Received N image(s) and M file(s)."
Controls (no auth):
  POST /__fixture/attach-reset       records, queued images, plans, running turns and transcripts back to the start
  POST /__fixture/attach-control     uploadDelay, uploadFailures, maxBytes, imageAttach (ok|empty|error|stale-once),
                                     fileAttach (copy|inplace|error), submitStaleOnce, downloadDelay, downloadFailures, strict
  POST /__fixture/attachments-history {"profile":"default"}: 16 history shapes (§14.2)
  POST /__fixture/agent-images-history {"profile":"default"}: bare picture paths, quoted MEDIA, a 404, your markdown
  POST /__fixture/photo-stack-history {"profile":"default"}: several photos in one message (stacks you swipe through)
  POST /__fixture/spreadsheet-history {"profile":"default"}: a reply with an Excel workbook and a CSV (Mac file windows)
  POST /__fixture/plan               the performance plans plus `mediaReply` and `imageGenerate`
  GET  /__fixture/state              adds uploads, deletes, attached, attachLedger, prompts, downloads

  python3 scripts/fixtures/attachments-gateway.py --port 9723 --credentials build/fixtures/attach.json \
      --files build/fixtures/attach-files
"""
import argparse, base64, hashlib, importlib.util, io, json, mimetypes, os, pathlib, posixpath, re, secrets, shutil, socket, struct, \
    sys, threading, time, zipfile, zlib
from email.parser import BytesParser
from email.policy import default as email_policy
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
_spec = importlib.util.spec_from_file_location('hqn_performance_fixture', REF / 'scripts' / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)
b47 = perf.base            # build47-fixture-gateway.py
voice = b47.voice          # action-voice-fixture-gateway.py
auth = voice.auth          # native-startup/fake-gateway.py

LOCK = b47.LOCK
FILES = None               # pathlib.Path, set in main()
ROOTS = {'/fixture/uploads': 'uploads', '/fixture-home/attachments': 'home-attachments', '/fixture/media': 'media'}
DEFAULT_CONTROL = {'uploadDelay': 0.0, 'uploadFailures': 0, 'maxBytes': 100 * 1024 * 1024, 'imageAttach': 'ok', 'fileAttach': 'copy',
                   'submitStaleOnce': False, 'downloadDelay': 0.0, 'downloadFailures': 0, 'strict': True}
CONTROL = {'uploadDelay': 0.0, 'uploadFailures': 0, 'maxBytes': 100 * 1024 * 1024, 'imageAttach': 'ok', 'fileAttach': 'copy',
           'submitStaleOnce': False, 'downloadDelay': 0.0, 'downloadFailures': 0, 'strict': True}
UPLOADS, DELETES, ATTACH_LEDGER, PROMPTS, DOWNLOADS = [], [], [], [], []
ATTACHED = {p: [] for p in voice.SIDS}
PENDING_IMAGES = {}
IMAGE_EXTS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tiff', '.tif', '.svg', '.ico'}

PROMPT_KEYS = {'session_id', 'profile', 'text', 'display_kind', 'interrupted', 'queued', 'surface', 'voice_context', 'voice_turn',
               'title_preview', 'truncate_before_user_ordinal', 'truncate_before_row_id', 'truncate_before_message_id',
               'confirm_truncate', 'confirm_empty_truncate', 'rebind_survivor_row_ids'}
ALLOWED = {'image.attach': {'session_id', 'profile', 'path'},
           'file.attach': {'session_id', 'profile', 'path', 'data_url', 'name'},
           'image.detach': {'session_id', 'profile', 'path'},
           'prompt.submit': PROMPT_KEYS}


class RPCFail(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


# ── paths ──────────────────────────────────────────────────────────────────────────────────────────────────────────────

def real(vpath):
    """The file behind a gateway path, or None outside the fixture's roots (never escapes --files)."""
    if not isinstance(vpath, str) or not vpath.startswith('/') or '\x00' in vpath:
        return None
    norm = posixpath.normpath(vpath)
    if '..' in norm.split('/'):
        return None
    for prefix, sub in ROOTS.items():
        if norm == prefix or norm.startswith(prefix + '/'):
            rest = norm[len(prefix):].lstrip('/')
            return FILES / sub / rest if rest else FILES / sub
    return None


def runtime_id(profile):
    return voice.resumed(profile)['session_id']


def fmt_ref(value):
    """`format_reference_value` (H:agent/context_references.py:139-148): quote whitespace/brackets/quotes."""
    if not re.search(r"""[\s()\[\]{}<>"'`]""", value):
        return value
    for quote in ('`', '"', "'"):
        if quote not in value:
            return f'{quote}{value}{quote}'
    return value


def image_size(data):
    if data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 24:
        return struct.unpack('>II', data[16:24])
    if data[:2] == b'\xff\xd8':
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack('>HH', data[i + 5:i + 9])
                return w, h
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seglen = struct.unpack('>H', data[i + 2:i + 4])[0]
            i += 2 + seglen
    return None, None


def exif_tags(data):
    """TIFF tags in a JPEG's Exif APP1 (IFD0 and the Exif IFD) or a PNG's eXIf chunk."""
    tiff = None
    if data[:2] == b'\xff\xd8':
        i = 2
        while i + 4 <= len(data) and data[i] == 0xFF:
            marker = data[i + 1]
            if marker in (0xD9, 0xDA):
                break
            seglen = struct.unpack('>H', data[i + 2:i + 4])[0]
            seg = data[i + 4:i + 2 + seglen]
            if marker == 0xE1 and seg[:6] == b'Exif\x00\x00':
                tiff = seg[6:]
                break
            i += 2 + seglen
    elif data[:8] == b'\x89PNG\r\n\x1a\n':
        i = 8
        while i + 8 <= len(data):
            n, kind = struct.unpack('>I4s', data[i:i + 8])
            if kind == b'eXIf':
                tiff = data[i + 8:i + 8 + n]
                break
            i += 12 + n
    if not tiff or len(tiff) < 8:
        return set()
    bo = '<' if tiff[:2] == b'II' else '>'
    tags = set()

    def ifd(offset, depth):
        if depth > 3 or offset + 2 > len(tiff):
            return
        count = struct.unpack(bo + 'H', tiff[offset:offset + 2])[0]
        for k in range(count):
            e = offset + 2 + 12 * k
            if e + 12 > len(tiff):
                return
            tag = struct.unpack(bo + 'H', tiff[e:e + 2])[0]
            tags.add(tag)
            if tag == 0x8769:
                ifd(struct.unpack(bo + 'I', tiff[e + 8:e + 12])[0], depth + 1)

    ifd(struct.unpack(bo + 'I', tiff[4:8])[0], 0)
    return tags


# ── media made at start ────────────────────────────────────────────────────────────────────────────────────────────────

def png(width, height, color_of_row):
    """A PNG drawn row by row (color_of_row(y) → (r, g, b)); banded rows compress to almost nothing."""
    raw = bytearray()
    cache = {}
    for y in range(height):
        c = color_of_row(y)
        if c not in cache:
            cache[c] = b'\x00' + bytes(c) * width
        raw += cache[c]
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')


def bands(colors, size):
    return lambda y: colors[(y // size) % len(colors)]


PDF = b"""%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 52>>stream
BT /F1 18 Tf 40 100 Td (Synthetic fixture report) Tj ET
endstream endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
xref
0 6
0000000000 65535 f
trailer<</Size 6/Root 1 0 R>>
startxref
0
%%EOF
"""


def make_media():
    media = FILES / 'media'
    home = FILES / 'home-attachments'
    for d in (media, home, FILES / 'uploads'):
        d.mkdir(parents=True, exist_ok=True)
        os.chmod(d, 0o700)
    blue, white = (0, 83, 253), (240, 244, 255)
    files = {
        media / 'chart.png': png(1200, 800, bands([blue, white], 40)),
        media / 'two words.png': png(400, 300, bands([(0, 150, 136), (224, 242, 241)], 30)),
        media / 'a.png': png(300, 300, bands([(220, 40, 40), (255, 220, 220)], 25)),
        media / 'b.png': png(300, 300, bands([(40, 160, 70), (220, 255, 225)], 25)),
        media / 'result.png': png(640, 480, lambda y: (255, min(255, 120 + y // 4), 40)),
        media / 'diagram.png': png(500, 500, bands([(120, 60, 200), (240, 230, 255)], 50)),
        media / 'fox.png': png(1024, 1024, bands([(230, 100, 20), (250, 180, 120), (60, 30, 10)], 64)),
        media / 'portrait.png': png(576, 1024, bands([(230, 100, 20), (250, 200, 160)], 64)),
        media / 'huge.png': png(3000, 2000, bands([(20, 20, 20), (200, 200, 200)], 100)),
        media / 'data.csv': b'name,value\nalpha,1\nbeta,2\ngamma,3\n',
        media / 'notes.md': b'# Notes\n\nSynthetic fixture notes.\n\n- one\n- two\n',
        media / 'clip.mov': b'not really a movie',
    }
    for path, data in files.items():
        path.write_bytes(data)
        os.chmod(path, 0o600)
    bundle = media / 'bundle.zip'
    with zipfile.ZipFile(bundle, 'w') as z:
        z.writestr('readme.txt', 'Synthetic bundle.\n')
    os.chmod(bundle, 0o600)


def data_url(png_bytes):
    return 'data:image/png;base64,' + base64.b64encode(png_bytes).decode()


# ── JSON-RPC ───────────────────────────────────────────────────────────────────────────────────────────────────────────

def strict(method, params):
    if not CONTROL['strict'] or method not in ALLOWED:
        return
    extra = sorted(set(params) - ALLOWED[method])
    if extra:
        raise RPCFail(4000, f'invalid params for {method}: {extra[0]}: Extra inputs are not permitted '
                            f'[type=extra_forbidden, input_value={json.dumps(params[extra[0]])[:40]}]')


def ledger(method, params, **extra):
    with LOCK:
        ATTACH_LEDGER.append({'method': method, 'params': {k: v for k, v in params.items() if k != 'data_url'}, 'at': time.time(), **extra})


def image_attach(params):
    profile = b47.owner(params)
    with LOCK:
        mode = CONTROL['imageAttach']
        if mode == 'stale-once':
            CONTROL['imageAttach'] = 'ok'
    if mode == 'stale-once' or params.get('session_id') != runtime_id(profile):
        raise RPCFail(4001, 'session not found')
    if mode == 'empty':
        return {}
    if mode == 'error':
        raise RPCFail(5027, 'synthetic attach failure')
    path = params.get('path') or ''
    if not path:
        raise RPCFail(4015, 'path required')
    target = real(path)
    if target is None or not target.is_file():
        raise RPCFail(4016, f'image not found: {path}')
    name = posixpath.basename(path)
    if posixpath.splitext(name)[1].lower() not in IMAGE_EXTS:
        raise RPCFail(4016, f'unsupported image: {name}')
    data = target.read_bytes()
    w, h = image_size(data)
    with LOCK:
        ATTACHED[profile].append(path)
        count = len(ATTACHED[profile])
    answer = {'attached': True, 'path': path, 'count': count, 'remainder': '', 'text': f'[User attached image: {name}]', 'name': name}
    if w and h:
        answer.update(width=w, height=h, token_estimate=max(85, (w * h) // 750))
    return answer


def file_attach(params):
    profile = b47.owner(params)
    if params.get('session_id') != runtime_id(profile):
        raise RPCFail(4001, 'session not found')
    mode = CONTROL['fileAttach']
    if mode == 'error':
        raise RPCFail(5028, 'synthetic attach failure')
    path = params.get('path') or ''
    if not path and not params.get('data_url'):
        raise RPCFail(4015, 'path or data_url required')
    target = real(path) if path else None
    if target is None or not target.is_file():
        raise RPCFail(5028, 'file not found on gateway and no data_url provided')
    name = re.sub(r'[\x00-\x1f]+', '_', posixpath.basename(params.get('name') or path)).strip().strip('.') or 'attachment'
    if mode == 'inplace':
        stored, uploaded = path, False
    else:
        stem, suffix = posixpath.splitext(name)
        candidate, counter = name, 2
        home = FILES / 'home-attachments'
        while (home / candidate).exists():
            candidate = f'{stem or "attachment"}-{counter}{suffix}'
            counter += 1
        shutil.copyfile(target, home / candidate)
        os.chmod(home / candidate, 0o600)
        stored, uploaded = '/fixture-home/attachments/' + candidate, True
    return {'attached': True, 'name': name, 'path': stored, 'ref_path': stored, 'ref_text': '@file:' + fmt_ref(stored), 'uploaded': uploaded}


def image_detach(params):
    profile = b47.owner(params)
    path = params.get('path') or ''
    with LOCK:
        queued = ATTACHED[profile]
        detached = path in queued
        if detached:
            queued.remove(path)
        count = len(queued)
    return {'detached': detached, 'count': count}


_previous_rpc = b47.rpc


def rpc(method, params):
    if method in ('image.attach', 'file.attach', 'image.detach'):
        try:
            strict(method, params)
            result = {'image.attach': image_attach, 'file.attach': file_attach, 'image.detach': image_detach}[method](params)
        except RPCFail as fail:
            ledger(method, params, error=fail.code, message=fail.message)
            raise
        ledger(method, params, result=result)
        return result
    if method == 'session.resume':
        ledger(method, {k: v for k, v in params.items() if k in ('session_id', 'profile')})
    return _previous_rpc(method, params)


b47.rpc = rpc


# prompt.submit runs on its own thread in Client.prompt (build47); wrap it.
_original_prompt = b47.Client.prompt


def persist(text, images):
    refs = '\n'.join('@image:' + fmt_ref(p) for p in images if real(p) is not None and real(p).exists())
    if not refs:
        return text
    return f'{text}\n{refs}' if text else refs


def prompt(self, frame):
    params = frame.get('params') or {}
    try:
        strict('prompt.submit', params)
    except RPCFail as fail:
        ledger('prompt.submit', params, error=fail.code, message=fail.message)
        self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': fail.code, 'message': fail.message}})
        return
    profile = b47.owner(params)
    with LOCK:
        stale = CONTROL['submitStaleOnce']
        CONTROL['submitStaleOnce'] = False
    if stale:
        # A runtime that went away before the turn was admitted (Hermes drops what was queued on it).
        with LOCK:
            ATTACHED[profile] = []
        ledger('prompt.submit', params, error=4001, message='session not found')
        self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': 4001, 'message': 'session not found'}})
        return
    text = params.get('text', '') if isinstance(params.get('text', ''), str) else json.dumps(params.get('text'))
    with LOCK:
        images = ATTACHED[profile]
        ATTACHED[profile] = []
        PENDING_IMAGES[profile] = list(images)
        files = len(re.findall(r'(?m)^@file:', text))
        PROMPTS.append({'profile': profile, 'text': text, 'queued': bool(params.get('queued')), 'images': list(images), 'at': time.time()})
        if not b47.PLANS:
            b47.PLANS.append({'replyText': f'Received {len(images)} image(s) and {files} file(s).'})
    ledger('prompt.submit', params, images=list(images))
    _original_prompt(self, frame)


b47.Client.prompt = prompt

_original_append = b47.append


def append(profile, role, text):
    if role == 'user':
        with LOCK:
            images = PENDING_IMAGES.pop(profile, None)
        if images:
            text = persist(text, images)
    return _original_append(profile, role, text)


b47.append = append

# Live media plans.
_performance_stream = b47.stream


def stream(profile, plan):
    if 'mediaReply' in plan or 'imageGenerate' in plan:
        return media_stream(profile, plan)
    return _performance_stream(profile, plan)


b47.stream = stream


def media_stream(profile, plan):
    cancel = b47.CANCEL[profile]
    if cancel.wait(float(plan.get('replyDelay', .2))):
        return
    b47.emit(profile, 'message.start')
    if 'imageGenerate' in plan:
        g = plan['imageGenerate'] or {}
        args = {'prompt': g.get('prompt', 'a red fox'), 'aspect_ratio': g.get('aspect_ratio', 'landscape')}
        call_id = 'fixture-image-generate-' + secrets.token_hex(3)
        b47.emit(profile, 'tool.start', {'name': 'image_generate', 'tool_id': call_id, 'args': args})
        if cancel.wait(float(g.get('delay', 1.0))):
            return
        if g.get('fail'):
            result = {'success': False, 'error': 'No image backend configured'}
        else:
            result = {'success': True, 'image': g.get('image', '/fixture/media/fox.png')}
            if g.get('pixel_size'):
                result['pixel_size'] = g['pixel_size']
        with LOCK:
            _original_append(profile, 'assistant', '')
            b47.MESSAGES[profile][-1]['tool_calls'] = [{'id': call_id, 'type': 'function',
                                                        'function': {'name': 'image_generate', 'arguments': json.dumps(args)}}]
            _original_append(profile, 'tool', json.dumps(result))
            b47.MESSAGES[profile][-1]['tool_call_id'] = call_id
            b47.MESSAGES[profile][-1]['tool_name'] = 'image_generate'
        b47.emit(profile, 'tool.complete', {'name': 'image_generate', 'tool_id': call_id, 'args': args, 'result': result})
        text = g.get('text', "Here's the image.")
    else:
        text = 'Here it is:\nMEDIA:' + plan['mediaReply']
    for chunk in [text[i:i + 12] for i in range(0, len(text), 12)]:
        if cancel.wait(float(plan.get('chunkDelay', .03))):
            return
        b47.emit(profile, 'message.delta', {'text': chunk})
    row = _original_append(profile, 'assistant', text)
    b47.RUNNING[profile] = False
    b47.emit(profile, 'message.complete', {'text': text, 'row_id': row})


# The socket: build47's, with error codes (4000, 4001, 4016, 5027, 5028) instead of its fixed -32001.
def websocket(connection, key):
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '
                        + accept + '\r\n\r\n').encode())
    client = b47.Client(connection)

    def read(n):
        data = b''
        while len(data) < n:
            chunk = connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data

    with LOCK:
        b47.CLIENTS.add(client)
    try:
        client.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
            'heartbeat': True, 'change_events': True, 'replay_epoch': 'attachments', 'desktop_contract': 8}}})
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
                answer['result'] = b47.rpc(frame['method'], frame.get('params') or {})
            except RPCFail as fail:
                answer['error'] = {'code': fail.code, 'message': fail.message}
            except ValueError as error:
                answer['error'] = {'code': -32001, 'message': str(error)}
            client.send(answer)
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        with LOCK:
            b47.CLIENTS.discard(client)


auth.websocket = websocket


# ── history shapes (§14.2) ─────────────────────────────────────────────────────────────────────────────────────────────

# A note with the formats the viewer draws (test18: opened from the chat it reads formatted, not as raw text).
MY_NOTES = (b'# My Notes\n\nA **synthetic** note with a few _formats_ and a [link](https://example.com).\n\n'
            b'## Checklist\n\n- one\n- two with `inline code`\n\n'
            b'| Item | Count |\n| --- | ---: |\n| Apples | 3 |\n| Pears | 12 |\n\n'
            b'```swift\nlet ready = true\n```\n\n> A quoted line.\n')


def seed_history(profile):
    # The files history rows 6-7 name (made here, not at start, so a fresh fixture's first file.attach keeps its name).
    home = FILES / 'home-attachments'
    for name, data in (('report.pdf', PDF), ('My Notes.md', MY_NOTES)):
        if not (home / name).exists():
            (home / name).write_bytes(data)
            os.chmod(home / name, 0o600)
    a = (FILES / 'media' / 'a.png').read_bytes()
    b = (FILES / 'media' / 'b.png').read_bytes()
    part = png(240, 180, bands([(255, 160, 0), (255, 240, 200)], 20))
    with LOCK:
        if b47.RUNNING[profile]:
            return None
        b47.MESSAGES[profile] = []
        rows = b47.MESSAGES[profile]

        def add(role, content, **extra):
            _original_append(profile, role, content if isinstance(content, str) else '')
            if not isinstance(content, str):
                rows[-1]['content'] = content
            rows[-1].update(extra)

        add('user', 'Here is the chart\n@image:/fixture/media/chart.png')                                  # 1
        add('assistant', 'Got it.')                                                                          # 2
        add('user', '@image:`/fixture/media/two words.png`\n[screenshot]')                                   # 3
        add('user', [{'type': 'text', 'text': 'what is this?'}, {'type': 'image_url', 'image_url': {'url': data_url(part)}}])  # 4
        add('user', [{'type': 'text', 'text': 'compare these\n@image:/fixture/media/a.png\n@image:/fixture/media/b.png'},
                     {'type': 'image_url', 'image_url': {'url': data_url(a)}},
                     {'type': 'image_url', 'image_url': {'url': data_url(b)}}])                              # 5
        add('user', '@file:/fixture-home/attachments/report.pdf\n\nPlease summarise this')                   # 6
        add('user', '@file:/fixture-home/attachments/report.pdf\n@file:`/fixture-home/attachments/My Notes.md`')  # 7
        add('user', 'What do you see in this image?\n@image:/fixture/media/chart.png')                       # 8
        add('user', '[Image attached at: /fixture/media/a.png]')                                             # 9
        add('assistant', 'Here you go:\nMEDIA:/fixture/media/result.png\nAnd the data: MEDIA:/fixture/media/data.csv')  # 10
        add('assistant', '![diagram](/fixture/media/diagram.png)\n\nSee [the notes](/fixture/media/notes.md) and the archive '
                         'MEDIA:/fixture/media/bundle.zip')                                                  # 11
        add('user', 'Draw a fox')
        add('assistant', '', tool_calls=[{'id': 'gen-fox', 'type': 'function', 'function': {
            'name': 'image_generate', 'arguments': json.dumps({'prompt': 'a red fox', 'aspect_ratio': 'square'})}}])   # 12
        add('tool', json.dumps({'success': True, 'image': '/fixture/media/fox.png', 'pixel_size': '1024x1024'}),
            tool_call_id='gen-fox', tool_name='image_generate')
        add('assistant', "Here's the fox.")
        add('user', 'Draw another')
        add('assistant', '', tool_calls=[{'id': 'gen-fail', 'type': 'function', 'function': {
            'name': 'image_generate', 'arguments': json.dumps({'prompt': 'a blue fox', 'aspect_ratio': 'square'})}}])  # 13
        add('tool', json.dumps({'success': False, 'error': 'No image backend configured'}), tool_call_id='gen-fail',
            tool_name='image_generate')
        add('assistant', "I couldn't draw that one.")
        add('user', '@image:/fixture/media/missing.png')                                                     # 14
        add('user', '@image:/fixture/media/huge.png')                                                        # 15
        add('assistant', 'MEDIA:/fixture/media/clip.mov')                                                    # 16
        return len(rows)


def seed_screenshot(profile):
    """A pasted phone screenshot (tall, 1179 × 2556) with a long caption, stored the way Hermes keeps a photo turn:
    the text projection with the browser plugin's steer appended (H:agent/turn_context.py _append_multimodal_context)."""
    shot = FILES / 'media' / 'phone-shot.png'
    if not shot.exists():
        shot.write_bytes(png(1179, 2556, bands([(70, 110, 200), (235, 240, 250), (250, 200, 80)], 160)))
        os.chmod(shot, 0o600)
    steer = ("(Hermes HQ: for websites use your own browser tools, which the user can watch and take over in Watch "
             "Browser; desktop_preview would open the page on the user's phone instead. A page that seems empty may "
             "be a sign-in in a frame: print(capture_screenshot()) to see it.)")
    with LOCK:
        if b47.RUNNING[profile]:
            return None
        b47.MESSAGES[profile] = []
        rows = b47.MESSAGES[profile]
        _original_append(profile, 'assistant', 'Copy the code from the browser into the login terminal.')
        _original_append(profile, 'user', 'This is what I see in the app when I open the remote control setup page\n\n'
                                          '[Image attached at: /fixture/media/phone-shot.png]\n[screenshot]\n' + steer)
        _original_append(profile, 'assistant', 'Thanks, that helps.')
        return len(rows)


def xlsx(rows):
    """A small real Excel workbook (one sheet, inline strings and numbers), stdlib only."""
    def col(i):
        name = ''
        while True:
            name = chr(65 + i % 26) + name
            i = i // 26 - 1
            if i < 0:
                return name
    def cell(r, c, v):
        ref = f'{col(c)}{r + 1}'
        if isinstance(v, (int, float)):
            return f'<c r="{ref}"><v>{v}</v></c>'
        text = str(v).replace('&', '&amp;').replace('<', '&lt;')
        return f'<c r="{ref}" t="inlineStr"><is><t>{text}</t></is></c>'
    sheet = ''.join(f'<row r="{r + 1}">' + ''.join(cell(r, c, v) for c, v in enumerate(row)) + '</row>'
                    for r, row in enumerate(rows))
    ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    parts = {
        '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
        '_rels/.rels': '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{rel}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
        'xl/workbook.xml': f'<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="{ns}" xmlns:r="{rel}"><sheets>'
            '<sheet name="Budget" sheetId="1" r:id="rId1"/></sheets></workbook>',
        'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            f'<Relationship Id="rId1" Type="{rel}/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
        'xl/worksheets/sheet1.xml': f'<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="{ns}"><sheetData>{sheet}</sheetData></worksheet>',
    }
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, text in parts.items():
            z.writestr(name, text)
    return out.getvalue()


def seed_spreadsheet(profile):
    """[mac-files] A reply with an Excel workbook wide enough to need a real window (9 columns, 40 rows)."""
    book = FILES / 'media' / 'Q4 Budget.xlsx'
    months = ['Oct', 'Nov', 'Dec']
    rows = [['Team', 'Owner', 'Category'] + [f'{m} plan' for m in months] + [f'{m} actual' for m in months]]
    teams = ['Design', 'Platform', 'Mobile', 'Data', 'Support', 'Growth', 'Infra', 'Research']
    cats = ['Salaries', 'Tools', 'Travel', 'Cloud', 'Contractors']
    for i in range(39):
        base = 1200 + (i * 373) % 9000
        rows.append([teams[i % len(teams)], f'Owner {i + 1}', cats[i % len(cats)]]
                    + [base + 100 * k for k in range(3)] + [base + 100 * k - (i * 37) % 400 for k in range(3)])
    book.write_bytes(xlsx(rows))
    os.chmod(book, 0o600)
    with LOCK:
        if b47.RUNNING[profile]:
            return None
        b47.MESSAGES[profile] = []
        rows = b47.MESSAGES[profile]
        _original_append(profile, 'user', 'Can you put the Q4 budget in a spreadsheet?')
        _original_append(profile, 'assistant', 'Here it is, plan and actuals by team:\nMEDIA:`/fixture/media/Q4 Budget.xlsx`\n'
                                               'And the raw numbers: MEDIA:/fixture/media/data.csv')
        return len(rows)


def seed_agent_images(profile):
    """Tester reports of 2026-10-26 (docs/briefs/agent-images-markdown.md): pictures an agent names the way Hermes'
    terminal hint tells it to (a bare path, alone or in a sentence), a quoted `MEDIA:` path with a space, a path the
    gateway can't serve (404), and your own messages with inline markdown and a code fence."""
    with LOCK:
        if b47.RUNNING[profile]:
            return None
        b47.MESSAGES[profile] = []
        rows = b47.MESSAGES[profile]
        _original_append(profile, 'user', 'Take a **screenshot** of the `login` page, *quickly*, and ~~don\'t~~ save it')
        _original_append(profile, 'assistant', 'Here it is:\n/fixture/media/result.png')
        _original_append(profile, 'user', 'And the chart? See [the docs](https://example.com/docs)')
        _original_append(profile, 'assistant', 'I saved the chart to /fixture/media/chart.png for you.')
        _original_append(profile, 'assistant', 'MEDIA:"/fixture/media/two words.png"')
        _original_append(profile, 'user', 'Run this:\n```\nprint("hi")\n```\n- keep this dash\n# and this hash')
        _original_append(profile, 'assistant', 'The old one was at /fixture/media/gone-shot.png')
        return len(rows)


def seed_photo_stacks(profile):
    """Several photos in one message, drawn as a stack you swipe through (owner 2026-10-30): your three with a caption,
    your four alone, a reply listing three phone screenshots, and a photo-only reply of two shapes; first, a reply that
    made five pictures one after another (no pixel size, like fal's) and then answered with a table (owner 2026-10-31:
    one stack, and the words their own formatted bubble). Leaves a file in
    the media folder alone when it is already there; HQN_STACK_PICTURES names a folder of real pictures to use in
    their place (same names: stack-1.png … shot-3.png, wide.png, square.png; never committed)."""
    media = FILES / 'media'
    pictures = {
        'stack-1.png': (1600, 1200, [(64, 120, 220), (230, 238, 252)]),
        'stack-2.png': (1600, 1200, [(240, 140, 60), (252, 236, 220)]),
        'stack-3.png': (1600, 1200, [(60, 170, 120), (222, 246, 234)]),
        'stack-4.png': (1600, 1200, [(170, 90, 200), (242, 228, 250)]),
        'shot-1.png': (1179, 2556, [(30, 30, 40), (245, 245, 250)]),
        'shot-2.png': (1179, 2556, [(200, 60, 80), (250, 236, 240)]),
        'shot-3.png': (1179, 2556, [(40, 140, 200), (230, 244, 252)]),
        'wide.png': (1920, 1080, [(250, 200, 60), (60, 60, 70)]),
        'square.png': (1200, 1200, [(90, 200, 220), (250, 250, 250)]),
        'gen-1.png': (1024, 1024, [(20, 20, 24), (240, 240, 240)]),
        'gen-2.png': (1024, 1024, [(200, 40, 60), (250, 230, 230)]),
        'gen-3.png': (1024, 1024, [(40, 90, 200), (226, 236, 252)]),
        'gen-4.png': (1024, 1024, [(230, 170, 40), (252, 244, 220)]),
        'gen-5.png': (1024, 1024, [(60, 160, 90), (226, 246, 232)]),
    }
    real = pathlib.Path(os.environ.get('HQN_STACK_PICTURES') or '/nonexistent')
    for name, (w, h, colors) in pictures.items():
        if (real / name).is_file() and not (media / name).exists():
            shutil.copyfile(real / name, media / name)
            os.chmod(media / name, 0o600)
        if not (media / name).exists():
            (media / name).write_bytes(png(w, h, bands(colors, max(24, h // 12))))
            os.chmod(media / name, 0o600)
    with LOCK:
        if b47.RUNNING[profile]:
            return None
        b47.MESSAGES[profile] = []
        rows = b47.MESSAGES[profile]
        _original_append(profile, 'user', 'Make five icon ideas.')
        _original_append(profile, 'assistant', 'One brief each.')
        rows[-1]['tool_calls'] = [{'id': f'gen-{i}', 'type': 'function', 'function': {
            'name': 'image_generate', 'arguments': json.dumps({'prompt': f'icon {i}', 'aspect_ratio': 'square'})}}
            for i in range(1, 6)]
        for i in range(1, 6):
            _original_append(profile, 'tool', json.dumps({'success': True, 'image': f'/fixture/media/gen-{i}.png'}))
            rows[-1].update(tool_call_id=f'gen-{i}', tool_name='image_generate')
        _original_append(profile, 'assistant', 'Five ideas, best first:\n\n| Version | Score |\n|---|---|\n'
                                               '| **Bust, refined B** | **8.5** |\n| Plane | 7 |\n\n'
                                               '- **Bust B:** the only one in flat manga ink.')
        _original_append(profile, 'user', 'Which of these three works best for the header?\n@image:/fixture/media/stack-1.png\n'
                                          '@image:/fixture/media/stack-2.png\n@image:/fixture/media/stack-3.png')
        _original_append(profile, 'assistant', 'The second one: the warm tone reads best at small sizes.')
        _original_append(profile, 'user', '@image:/fixture/media/stack-1.png\n@image:/fixture/media/stack-2.png\n'
                                          '@image:/fixture/media/stack-3.png\n@image:/fixture/media/stack-4.png')
        _original_append(profile, 'assistant', 'Here are the screenshots:\n\n- /fixture/media/shot-1.png\n- /fixture/media/shot-2.png\n'
                                               '- /fixture/media/shot-3.png\n\nAll three use demo data.')
        _original_append(profile, 'assistant', 'MEDIA:/fixture/media/wide.png\nMEDIA:/fixture/media/square.png')
        _original_append(profile, 'user', 'Perfect, thanks!')
        return len(rows)


# ── HTTP ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

def handler(gateway):
    base = b47.handler(gateway)

    class Handler(base):
        def body(self):
            return self.rfile.read(int(self.headers.get('Content-Length') or 0))

        def json_body(self):
            try:
                return json.loads(self.body() or b'{}')
            except ValueError:
                return {}

        def do_GET(self):
            parsed = urlparse(self.path)
            path = parsed.path
            if path == '/__fixture/state':
                with LOCK:
                    return self.reply(200, {**voice.state, 'ledger': list(b47.LEDGER), 'running': b47.RUNNING, 'plans': b47.PLANS,
                                            'uploads': UPLOADS, 'deletes': DELETES, 'attached': ATTACHED, 'attachLedger': ATTACH_LEDGER,
                                            'prompts': PROMPTS, 'downloads': DOWNLOADS, 'control': CONTROL,
                                            'messages': {p: rows[-40:] for p, rows in b47.MESSAGES.items()}})
            if path in ('/api/files', '/api/fs/download') and not self.session():
                return self.reply(401, {'detail': 'Unauthorized'})
            if path == '/api/files':
                return self.reply(200, {'path': '/fixture/uploads', 'parent': '/fixture', 'entries': [], 'root': None,
                                        'locked_root': None, 'can_change_path': True})
            if path == '/api/fs/download':
                return self.download(parse_qs(parsed.query))
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/attach-control':
                body = self.json_body()
                with LOCK:
                    for k, v in body.items():
                        if k in CONTROL:
                            CONTROL[k] = v
                    return self.reply(200, dict(CONTROL))
            if path == '/__fixture/attach-reset':
                # A clean gateway for the next test: records, queued images, plans, running turns and transcripts.
                self.body()
                with LOCK:
                    for records in (UPLOADS, DELETES, ATTACH_LEDGER, PROMPTS, DOWNLOADS, b47.LEDGER, b47.PLANS):
                        records.clear()
                    for p in ATTACHED:
                        ATTACHED[p] = []
                    PENDING_IMAGES.clear()
                    CONTROL.update(DEFAULT_CONTROL)
                    for p in b47.RUNNING:
                        b47.CANCEL[p].set()
                        b47.RUNNING[p] = False
                    for p in b47.MESSAGES:
                        b47.MESSAGES[p] = [{'role': 'assistant', 'content': 'Build 47 synthetic acceptance chat.', 'row_id': 1,
                                            'timestamp': 1790852400}]
                return self.reply(200, {'ok': True})
            if path == '/__fixture/attachments-history':
                profile = self.json_body().get('profile', 'default')
                if profile not in b47.MESSAGES:
                    return self.reply(404, {'detail': 'Unknown synthetic profile'})
                count = seed_history(profile)
                if count is None:
                    return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                return self.reply(200, {'ok': True, 'rows': count, 'session_id': voice.SIDS[profile]})
            if path == '/__fixture/agent-images-history':
                profile = self.json_body().get('profile', 'default')
                if profile not in b47.MESSAGES:
                    return self.reply(404, {'detail': 'Unknown synthetic profile'})
                count = seed_agent_images(profile)
                if count is None:
                    return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                return self.reply(200, {'ok': True, 'rows': count, 'session_id': voice.SIDS[profile]})
            if path == '/__fixture/photo-stack-history':
                profile = self.json_body().get('profile', 'default')
                if profile not in b47.MESSAGES:
                    return self.reply(404, {'detail': 'Unknown synthetic profile'})
                count = seed_photo_stacks(profile)
                if count is None:
                    return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                return self.reply(200, {'ok': True, 'rows': count, 'session_id': voice.SIDS[profile]})
            if path == '/__fixture/spreadsheet-history':
                profile = self.json_body().get('profile', 'default')
                if profile not in b47.MESSAGES:
                    return self.reply(404, {'detail': 'Unknown synthetic profile'})
                count = seed_spreadsheet(profile)
                if count is None:
                    return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                return self.reply(200, {'ok': True, 'rows': count, 'session_id': voice.SIDS[profile]})
            if path == '/__fixture/screenshot-history':
                profile = self.json_body().get('profile', 'default')
                if profile not in b47.MESSAGES:
                    return self.reply(404, {'detail': 'Unknown synthetic profile'})
                count = seed_screenshot(profile)
                if count is None:
                    return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                return self.reply(200, {'ok': True, 'rows': count, 'session_id': voice.SIDS[profile]})
            if path == '/api/files/upload-stream':
                return self.upload()
            return super().do_POST()

        def do_DELETE(self):
            path = urlparse(self.path).path
            if path != '/api/files':
                self.body()
                return self.reply(404, {'detail': 'not in this fake'})
            if not self.session():
                self.body()
                return self.reply(401, {'detail': 'Unauthorized'})
            body = self.json_body()
            target_path = body.get('path') or ''
            target = real(target_path)
            entry = {'path': target_path, 'recursive': bool(body.get('recursive')), 'at': time.time()}
            if target is None or not target_path.startswith('/fixture/uploads/'):
                entry['status'] = 400
                with LOCK:
                    DELETES.append(entry)
                return self.reply(400, {'detail': 'Invalid path'})
            if not target.exists():
                entry['status'] = 404
                with LOCK:
                    DELETES.append(entry)
                return self.reply(404, {'detail': 'File not found'})
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
            entry['status'] = 200
            with LOCK:
                DELETES.append(entry)
            return self.reply(200, {'ok': True, 'path': target_path, 'root': None})

        def upload(self):
            if not self.session():
                self.body()
                return self.reply(401, {'detail': 'Unauthorized'})
            raw = self.body()
            with LOCK:
                delay = float(CONTROL['uploadDelay'])
                fail = CONTROL['uploadFailures'] > 0
                if fail:
                    CONTROL['uploadFailures'] -= 1
            if delay:
                time.sleep(delay)
            if fail:
                with LOCK:
                    UPLOADS.append({'status': 500, 'at': time.time()})
                return self.reply(500, {'detail': 'Synthetic upload failure'})
            message = BytesParser(policy=email_policy).parsebytes(
                ('Content-Type: ' + self.headers.get('Content-Type', '') + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + raw)
            fields = {part.get_param('name', header='content-disposition'): part for part in message.iter_parts()}
            vpath = (fields['path'].get_payload(decode=True) or b'').decode() if 'path' in fields else ''
            overwrite = (fields['overwrite'].get_payload(decode=True) or b'').decode().lower() == 'true' if 'overwrite' in fields else False
            data = fields['file'].get_payload(decode=True) if 'file' in fields else b''
            filename = fields['file'].get_filename() if 'file' in fields else None
            if not vpath.startswith('/'):
                return self.reply(400, {'detail': 'Path must be absolute'})
            if '..' in vpath.split('/'):
                return self.reply(400, {'detail': "Path cannot contain '..'"})
            if not vpath.startswith('/fixture/uploads/'):
                return self.reply(403, {'detail': 'Path outside managed files root'})
            target = real(vpath)
            if target is None:
                return self.reply(400, {'detail': 'Invalid path'})
            if target.exists() and not overwrite:
                return self.reply(409, {'detail': 'File already exists'})
            if len(data) > int(CONTROL['maxBytes']):
                return self.reply(413, {'detail': 'File is too large'})
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            os.chmod(target, 0o600)
            tags = exif_tags(data)
            entry = {'path': vpath, 'filename': filename, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                     'jpeg': data[:3] == b'\xff\xd8\xff', 'png': data[:8] == b'\x89PNG\r\n\x1a\n', 'gps': 0x8825 in tags,
                     'camera': bool(tags & {0x010F, 0x0110, 0x9003}), 'status': 200, 'at': time.time()}
            with LOCK:
                UPLOADS.append(entry)
            name = posixpath.basename(vpath)
            return self.reply(200, {'ok': True, 'entry': {'name': name, 'path': vpath, 'is_directory': False, 'size': len(data),
                                                          'mtime': time.time(), 'mime_type': mimetypes.guess_type(name)[0]},
                                    'path': vpath, 'root': None, 'locked_root': None, 'can_change_path': True})

        def download(self, query):
            vpath = query.get('path', [''])[0]
            sid = query.get('session_id', [None])[0]
            entry = {'path': vpath, 'profile': query.get('profile', [None])[0], 'session_id': sid,
                     'range': self.headers.get('Range'), 'at': time.time()}

            def done(status, body=None):
                entry['status'] = status
                with LOCK:
                    DOWNLOADS.append(entry)
                if body is not None:
                    return self.reply(status, body)

            with LOCK:
                delay = float(CONTROL['downloadDelay'])
                fail = CONTROL['downloadFailures'] > 0
                if fail:
                    CONTROL['downloadFailures'] -= 1
            if delay:
                time.sleep(delay)
            if fail:
                return done(500, {'detail': 'Synthetic download failure'})
            if sid is not None and sid not in voice.SIDS.values():
                return done(404, {'detail': 'Session not found'})
            if not vpath.startswith('/'):
                if sid is None:
                    return done(404, {'detail': 'File not found'})
                vpath = '/fixture/' + vpath
            target = real(vpath)
            if target is None or not target.exists():
                return done(404, {'detail': 'File not found'})
            if target.is_dir():
                return done(400, {'detail': 'Path points to a directory'})
            size = target.stat().st_size
            start, end, status = 0, size - 1, 200
            spec = (self.headers.get('Range') or '').partition('=')[2].split(',')[0].strip()
            if spec:
                first, _, last = spec.partition('-')
                start, end = (max(0, size - int(last)), size - 1) if first == '' else (int(first), min(int(last) if last else size - 1, size - 1))
                if start >= size:
                    done(416)
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                status = 206
            done(status)
            self.send_response(status)
            self.send_header('Content-Type', mimetypes.guess_type(target.name)[0] or 'application/octet-stream')
            self.send_header('Content-Disposition', f'attachment; filename="{target.name}"')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            if status == 206:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            with open(target, 'rb') as handle:
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

    return Handler


def main():
    global FILES
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=9723)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--files', required=True, help='a folder for uploads and generated media (0700)')
    parser.add_argument('--keep-credentials', action='store_true')
    args = parser.parse_args()
    # HQN_ANY_PORT=1: an integration run on its own port range (as the other fixtures and e2e scripts allow).
    if not 9700 <= args.port <= 9799 and not os.environ.get('HQN_ANY_PORT'):
        sys.exit('refusing a port outside 9700-9799')
    FILES = pathlib.Path(args.files).resolve()
    if FILES.exists():
        shutil.rmtree(FILES)
    FILES.mkdir(parents=True)
    os.chmod(FILES, 0o700)
    make_media()
    username, password = 'attachments-fixture', secrets.token_urlsafe(24)
    if args.keep_credentials and pathlib.Path(args.credentials).exists():
        kept = json.loads(pathlib.Path(args.credentials).read_text())
        username, password = kept['username'], kept['password']
    descriptor = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{args.port}'}, file)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(auth.Gateway(username, password, True, None)))
    print(f'Attachments fixture on 127.0.0.1:{args.port}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
