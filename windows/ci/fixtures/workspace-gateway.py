#!/usr/bin/env python3
"""Loopback-only stand-in gateway for the Windows Workspace pages: Files, Changes and Terminal. Invented state only.

Built on the performance fixture in this folder (sign-in, /api/ws, credentials file), loaded as a module and layered on.
Files and Changes answer from the invented tree of scripts/fixtures/morepages/workspace.py (copied into this file, read
only, the real gateway's shapes):
  GET /api/fs/default-cwd                 {"cwd","branch"}
  GET /api/fs/list?path=                  {"entries":[{"name","path","isDirectory"}],"error"?}  ENOENT / ENOTDIR / EACCES
  GET /api/fs/read-text?path=             {"path","text","binary","truncated","byteSize"}; past 64 MiB → 413
  GET /api/fs/git-root?path=              {"root": "<repo>" | null}
  GET /api/git/review/list?path=&scope=   {"files":[{"path","added","removed","status","staged"}]}
  GET /api/git/review/diff?path=&file=&scope=&staged=   {"diff"}
  GET /api/fs/download?path=              the bytes
  GET /api/profiles                       the default profile in /home/hermes/.hermes ("~" in paths)
The Terminal (docs/spec/terminal.md): the Hermes HQ add-on's status and its socket, with a stand-in shell written in
Python (no pty, so it runs on Windows too): it echoes what is typed, runs `echo`, `pwd`, `ls`, `colors`, `title <t>`,
`clear` and `exit [code]`, prints "$ " as its prompt, and keeps each session's output for a socket that comes back
with `since` (the add-on's 15 minutes). A second socket on the same session closes the first with 4409.
  GET  /api/plugins/hermes-hq-push/status          {pluginVersion, terminal, terminalOff} (404 when plugin=missing)
  WS   /api/plugins/hermes-hq-push/terminal?session=&cols=&rows=&since=&ticket=
Controls (no auth):
  POST /__fixture/workspace  {"default_cwd": "/home/hermes/projects/notes", "gone": [paths], "reset": true}
  POST /__fixture/terminal   {plugin?: ready|missing|outdated, off?, supported?, blocked?, full?, reset?}
  GET  /__fixture/terminal   {sessions: [{id, printed, viewer, finished, cols, rows, typed}], dials, plugin, off, supported, blocked}

  python3 windows/ci/fixtures/workspace-gateway.py --port 9850 --credentials windows/build/fixtures/e2e-workspace.json
"""
import base64, hashlib, importlib.util, json, pathlib, struct, threading, time
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('workspace_perf', HERE / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)          # its __main__ guard keeps it from starting
b47 = perf.base

LOCK = threading.RLock()

# MARK: - Files and Changes (scripts/fixtures/morepages/workspace.py)

HOME = '/home/hermes'
SITE = HOME + '/projects/site'
NOTES = HOME + '/projects/notes'
APP = HOME + '/app'
PREVIEW = 512 * 1024
SOURCE_MAX = 64 * 1024 * 1024
REPOS = (SITE, APP)
KNOBS = {}
LOG_LINE = '2026-10-09T08:00:00Z build step ok: bundled chunk and wrote the map\n'


def files():
    """path -> text | bytes | ('virtual', size) for a file; None for a folder; 'EACCES' for a folder that refuses."""
    return {
        '/': None, '/home': None, HOME: None, HOME + '/projects': None,
        SITE: None,
        SITE + '/README.md': '# Site\n\nThe marketing site. Run `npm run dev`, then open the address it prints.\n\n'
                             '- `src/` pages and components\n- `assets/` images and styles\n',
        SITE + '/package.json': '{\n  "name": "site",\n  "version": "2.4.0",\n  "scripts": {"dev": "vite", "build": "vite build"}\n}\n',
        SITE + '/build.log': LOG_LINE * ((3 << 20) // len(LOG_LINE) + 1),
        SITE + '/huge.sql': ('virtual', 80 << 20),
        SITE + '/Makefile': 'build:\n\tnpm run build\n',
        SITE + '/assets': None,
        SITE + '/assets/logo.bin': bytes(range(256)) * 8,
        SITE + '/assets/styles.css': 'body { font: 16px/1.5 system-ui; margin: 0 }\n.hero { padding: 48px 16px }\n',
        SITE + '/src': None,
        SITE + '/src/index.html': '<!doctype html>\n<html>\n  <body>\n    <main class="hero">Release 2.4</main>\n  </body>\n</html>\n',
        SITE + '/src/app.js': "import {nav} from './components/nav.js'\n\nnav(document.body)\nconsole.log('ready')\n",
        SITE + '/src/components': None,
        SITE + '/src/components/nav.js': "export function nav(root) {\n  root.prepend(document.createElement('nav'))\n}\n",
        SITE + '/src/components/footer.js': "export function footer(root) {\n  root.append(document.createElement('footer'))\n}\n",
        SITE + '/private': 'EACCES',
        SITE + '/empty': None,
        SITE + '/שלום 👋 notes.txt': 'A name with right-to-left text and an emoji.\n',
        NOTES: None,
        NOTES + '/ideas.md': '# Ideas\n\n- A pricing page\n- A changelog feed\n',
        NOTES + '/todo.txt': 'Call the printer\nRenew the domain\n',
        APP: None,
        APP + '/CHANGELOG.md': '# Changelog\n\n## 2.4\n- Export\n- Faster sync\n',
    }


DIFFS = {
    'src/app.js': ('M', False, 3, 1,
                   "diff --git a/src/app.js b/src/app.js\nindex 3f1c2aa..9b0d4e1 100644\n--- a/src/app.js\n+++ b/src/app.js\n"
                   "@@ -1,4 +1,6 @@\n import {nav} from './components/nav.js'\n+import {footer} from './components/footer.js'\n \n"
                   " nav(document.body)\n-console.log('ready')\n+footer(document.body)\n+console.log('ready, with a footer')\n"),
    'src/pricing.html': ('?', False, 5, 0,
                         "diff --git a/src/pricing.html b/src/pricing.html\nnew file mode 100644\n--- /dev/null\n+++ b/src/pricing.html\n"
                         "@@ -0,0 +1,5 @@\n+<!doctype html>\n+<html>\n+  <body>Pricing</body>\n+</html>\n+<!-- draft -->\n"),
    'assets/logo.bin': ('M', False, 0, 0, 'diff --git a/assets/logo.bin b/assets/logo.bin\nindex 3333333..4444444 100644\n'
                                          'Binary files a/assets/logo.bin and b/assets/logo.bin differ\n'),
}


def clean(path):
    path = (path or '').strip()
    if len(path) > 1:
        path = path.rstrip('/')
    return path


def git_root(path):
    for repo in REPOS:
        if path == repo or path.startswith(repo + '/'):
            return repo
    return None


def workspace_rest(path, query):
    """(status, json | (content_type, bytes)) or None."""
    one = lambda name: (query.get(name) or [''])[0]
    asked = clean(one('path'))
    tree = files()
    if path == '/api/fs/default-cwd':
        cwd = KNOBS.get('default_cwd', SITE)
        return 200, {'cwd': cwd, 'branch': 'main' if cwd and git_root(cwd) else None}
    if path == '/api/fs/list':
        if asked not in tree or asked in (KNOBS.get('gone') or []):
            return 200, {'entries': [], 'error': 'ENOENT'}
        if tree[asked] == 'EACCES':
            return 200, {'entries': [], 'error': 'EACCES'}
        if tree[asked] is not None:
            return 200, {'entries': [], 'error': 'ENOTDIR'}
        prefix = asked.rstrip('/') + '/'
        entries = [{'name': p[len(prefix):], 'path': p, 'isDirectory': v is None or v == 'EACCES'}
                   for p, v in tree.items() if p.startswith(prefix) and p != asked and '/' not in p[len(prefix):] and p[len(prefix):]]
        entries.sort(key=lambda item: (not item['isDirectory'], item['name'].lower(), item['name']))
        return 200, {'entries': entries}
    if path == '/api/fs/read-text':
        value = tree.get(asked)
        if asked not in tree or value is None or value == 'EACCES':
            return 404, {'detail': 'File not found'}
        if isinstance(value, tuple):
            if value[1] > SOURCE_MAX:
                return 413, {'detail': 'File too large'}
            data, size = bytes(PREVIEW), value[1]
        else:
            data = value if isinstance(value, bytes) else value.encode()
            size = len(data)
        shown = data[:PREVIEW]
        return 200, {'binary': b'\x00' in shown[:4096], 'byteSize': size, 'language': 'text', 'mimeType': 'text/plain',
                     'path': asked, 'text': shown.decode('utf-8', errors='replace'), 'truncated': size > PREVIEW}
    if path == '/api/fs/git-root':
        return 200, {'root': git_root(asked)}
    if path == '/api/fs/download':
        value = tree.get(asked)
        if asked not in tree or value is None or value == 'EACCES':
            return 404, {'detail': 'File not found'}
        if isinstance(value, tuple):
            return 200, ('application/octet-stream', bytes(value[1]))
        if isinstance(value, bytes):
            return 200, ('application/octet-stream', value)
        return 200, ('text/plain; charset=utf-8', value.encode())
    if path == '/api/git/review/list':
        if git_root(asked) != SITE:
            return 200, {'files': [], 'base': None}
        return 200, {'files': [{'path': n, 'added': a, 'removed': r, 'status': s, 'staged': st}
                               for n, (s, st, a, r, _) in DIFFS.items()], 'base': None}
    if path == '/api/git/review/diff':
        name = one('file')
        if name.startswith(asked + '/'):
            name = name[len(asked) + 1:]
        return 200, {'diff': DIFFS[name][4] if name in DIFFS else ''}
    return None


# MARK: - The Terminal

ROUTE = '/api/plugins/hermes-hq-push'
TSTATE = {'plugin': 'ready', 'off': False, 'supported': True, 'blocked': False, 'full': False, 'dials': 0}
SESSIONS = {}


class Shell:
    """A stand-in shell: a line editor that echoes, a few commands, and everything it printed kept for `since`."""

    def __init__(self, ident):
        self.id, self.out, self.line, self.typed = ident, bytearray(), '', ''
        self.viewer, self.finished, self.code, self.cols, self.rows = None, False, None, 80, 24
        self.lock = threading.RLock()
        self.print('Hermes HQ  \x1b[31mred\x1b[0m \x1b[32mgreen\x1b[0m \x1b[33myellow\x1b[0m \x1b[34mblue\x1b[0m\r\n$ ')

    def print(self, text):
        data = text.encode()
        with self.lock:
            self.out.extend(data)
            viewer = self.viewer
        if viewer:
            try:
                viewer.send(2, data)
            except OSError:
                pass

    def key(self, data):
        text = data.decode('utf-8', errors='replace')
        with self.lock:
            self.typed += text
        if text.startswith('\x1b[200~'):
            text = text[6:].replace('\x1b[201~', '')
        for ch in text:
            if self.finished:
                return
            if ch == '\r':
                self.print('\r\n')
                self.run(self.line)
                self.line = ''
            elif ch == '\x7f':
                if self.line:
                    self.line = self.line[:-1]
                    self.print('\b \b')
            elif ch == '\x03':
                self.line = ''
                self.print('^C\r\n$ ')
            elif ch >= ' ':
                self.line += ch
                self.print(ch)

    def run(self, command):
        word, _, rest = command.strip().partition(' ')
        if word == 'exit':
            self.finish(int(rest) if rest.strip().isdigit() else 0)
            return
        if word == 'echo':
            self.print(rest + '\r\n')
        elif word == 'pwd':
            self.print(HOME + '\r\n')
        elif word == 'ls':
            self.print('notes.txt\r\nprojects\r\n')
        elif word == 'colors':
            self.print('\x1b[1;31mbold red\x1b[0m \x1b[38;5;208morange\x1b[0m \x1b[7minverse\x1b[0m\r\n')
        elif word == 'title':
            self.print('\x1b]0;' + rest + '\x07')
        elif word == 'clear':
            self.print('\x1b[H\x1b[2J')
        elif word == 'size':
            self.print(f'{self.cols}x{self.rows}\r\n')
        elif word:
            self.print(f'fixture-sh: {word}: command not found\r\n')
        self.print('$ ')

    def finish(self, code):
        with self.lock:
            self.finished, self.code, viewer = True, code, self.viewer
        if viewer:
            try:
                viewer.send(1, json.dumps({'type': 'exit', 'code': code}).encode())
                viewer.close(1000, 'exit')
            except OSError:
                pass


class Socket:
    """Server side of a WebSocket over the handler's raw connection."""

    def __init__(self, connection):
        self.connection, self.lock, self.closed = connection, threading.Lock(), False

    def read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError('closed')
            data += chunk
        return data

    def frame(self):
        parts, kind = bytearray(), None
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
                return None, None
            if opcode == 9:
                self.send(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode in (1, 2):
                kind = opcode
            parts.extend(payload)
            if final:
                return kind, bytes(parts)

    def send(self, opcode, payload):
        n = len(payload)
        head = bytes([0x80 | opcode]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536
                                         else bytes([127]) + struct.pack('>Q', n))
        with self.lock:
            if self.closed:
                raise ConnectionError('closed')
            self.connection.sendall(head + payload)

    def close(self, code, reason=''):
        try:
            self.send(8, struct.pack('>H', code) + reason.encode()[:120])
        except OSError:
            pass
        with self.lock:
            self.closed = True
        try:
            self.connection.shutdown(2)
        except OSError:
            pass


def serve_terminal(socket, query):
    one = lambda name: (query.get(name) or [''])[0]
    ident = one('session')
    if not TSTATE['supported']:
        return socket.close(4501, "This computer can't open a terminal")
    if TSTATE['off']:
        return socket.close(4403, 'Terminal is turned off on this computer')
    if len(ident) != 32 or any(c not in '0123456789abcdef' for c in ident):
        return socket.close(4400, 'Bad session')
    with LOCK:
        shell = SESSIONS.get(ident)
        if shell is None and (TSTATE['full'] or len([s for s in SESSIONS.values() if not s.finished]) >= 8):
            return socket.close(4429, 'Too many shells')
        if shell is None or shell.finished:
            shell = SESSIONS[ident] = Shell(ident)
        old = shell.viewer
        shell.viewer = None
    if old:
        old.close(4409, 'Opened elsewhere')
    try:
        shell.cols, shell.rows = int(one('cols') or 80), int(one('rows') or 24)
        since = int(one('since') or 0)
    except ValueError:
        since = 0
    with shell.lock:
        offset = since if 0 <= since <= len(shell.out) else 0
        socket.send(1, json.dumps({'type': 'ready', 'session': ident, 'offset': offset, 'shell': 'fixture-sh',
                                   'resumed': since > 0}).encode())
        if len(shell.out) > offset:
            socket.send(2, bytes(shell.out[offset:]))
        shell.viewer = socket
    while True:
        try:
            kind, payload = socket.frame()
        except (ConnectionError, OSError):
            kind = None
        if kind is None:
            with shell.lock:
                if shell.viewer is socket:
                    shell.viewer = None
            return
        if kind == 2:
            shell.key(payload)
        else:
            try:
                body = json.loads(payload.decode())
            except ValueError:
                continue
            if body.get('type') == 'resize':
                shell.cols, shell.rows = int(body.get('cols') or 0), int(body.get('rows') or 0)
            elif body.get('type') == 'end':
                shell.finish(None)
            elif body.get('type') == 'ping':
                socket.send(1, b'{"type":"pong"}')


def status_body():
    if TSTATE['plugin'] == 'outdated':
        return {'ok': True, 'pluginVersion': '0.9.20'}
    return {'ok': True, 'pluginVersion': '0.9.25', 'terminal': TSTATE['supported'], 'terminalOff': TSTATE['off']}


# MARK: - The handler

_parent_handler = b47.handler


def handler(gateway):
    parent = _parent_handler(gateway)

    class Handler(parent):
        def body_json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try:
                return json.loads(raw or b'{}')
            except ValueError:
                return {}

        def raw_reply(self, status, content_type, data):
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            if path == '/__fixture/terminal':
                with LOCK:
                    sessions = [{'id': s.id, 'printed': len(s.out), 'viewer': s.viewer is not None, 'finished': s.finished,
                                 'cols': s.cols, 'rows': s.rows, 'typed': s.typed} for s in SESSIONS.values()]
                    return self.reply(200, {'sessions': sessions, **TSTATE})
            if path == ROUTE + '/terminal' and (self.headers.get('Upgrade') or '').lower() == 'websocket':
                with LOCK:
                    TSTATE['dials'] += 1
                if TSTATE['blocked']:
                    self.close_connection = True
                    self.connection.sendall(b'HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
                    return
                if 'ticket' not in query or TSTATE['plugin'] != 'ready':
                    return self.reply(401 if 'ticket' not in query else 404, {'detail': 'Not Found'})
                key = self.headers['Sec-WebSocket-Key']
                accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                         'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
                self.close_connection = True
                serve_terminal(Socket(self.connection), query)
                return
            if path == ROUTE + '/status':
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                if TSTATE['plugin'] == 'missing':
                    return self.reply(404, {'detail': 'Not Found'})
                return self.reply(200, status_body())
            if path == '/api/profiles':
                return self.reply(200, {'profiles': [
                    {'name': 'default', 'path': HOME + '/.hermes', 'is_default': True},
                    {'name': 'ivy', 'path': HOME + '/.hermes/profiles/ivy', 'is_default': False}]})
            if path.startswith('/api/fs/') or path.startswith('/api/git/review/'):
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                with LOCK:
                    answer = workspace_rest(path, query)
                if answer is not None:
                    status, body = answer
                    if isinstance(body, tuple):
                        return self.raw_reply(status, body[0], body[1])
                    return self.reply(status, body)
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/workspace':
                body = self.body_json()
                with LOCK:
                    if body.get('reset'):
                        KNOBS.clear()
                    KNOBS.update({k: v for k, v in body.items() if k != 'reset'})
                    return self.reply(200, {'ok': True, 'knobs': dict(KNOBS)})
            if path == '/__fixture/terminal':
                body = self.body_json()
                with LOCK:
                    if body.get('reset'):
                        for shell in SESSIONS.values():
                            if shell.viewer:
                                shell.viewer.close(1001, 'reset')
                        SESSIONS.clear()
                        TSTATE.update(plugin='ready', off=False, supported=True, blocked=False, full=False, dials=0)
                    for key in ('plugin',):
                        if key in body:
                            TSTATE[key] = body[key]
                    for key in ('off', 'supported', 'blocked', 'full'):
                        if key in body:
                            TSTATE[key] = bool(body[key])
                    return self.reply(200, {'ok': True})
            return super().do_POST()

    return Handler


b47.handler = handler

if __name__ == '__main__':
    b47.main()
