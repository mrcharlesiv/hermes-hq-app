#!/usr/bin/env python3
"""HQ Native Terminal fixture: the notifications fixture (push-gateway.py: sign-in, and the add-on's status saying
`terminal: true` once plugin is "ready") plus hermes-hq-push 0.9.25's real Terminal socket: the add-on's own
terminal.py (from --addon, default the dispatch-plugins terminal worktree) opens real login shells on this Mac, with
HOME a scratch folder (so no profile of the person running it is read). Loopback only.

  WS /api/plugins/hermes-hq-push/terminal?ticket=…&session=<32 hex>&cols=&rows=&since=   terminal.serve, as plugin_api.py
Fixture control:
  POST /__fixture/terminal  {plugin?: ready|missing|outdated, off?: bool, supported?: bool, blocked?: bool}
  GET  /__fixture/terminal  {sessions: [{id, printed, viewer, finished}], dials, off, supported, blocked}
  blocked: the socket is answered 404 with no body, as the Hermes HQ edge from before 2026-11-02 did (ws-path-blocked).
"""
import asyncio, base64, hashlib, importlib.util, json, os, pathlib, struct, sys, tempfile, threading
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent
ADDON = pathlib.Path('/Users/me/Projects/dispatch-plugins-wt/terminal/hermes-hq-push')
if '--addon' in sys.argv:
    at = sys.argv.index('--addon')
    ADDON = pathlib.Path(sys.argv[at + 1])
    del sys.argv[at:at + 2]

_spec = importlib.util.spec_from_file_location('hqn_terminal_push', HERE / 'push-gateway.py')
push = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(push)
base = push.base
_tspec = importlib.util.spec_from_file_location('hqn_terminal_addon', ADDON / 'terminal.py')
terminal = importlib.util.module_from_spec(_tspec)
_tspec.loader.exec_module(terminal)

HOME = pathlib.Path(tempfile.mkdtemp(prefix='hqn-terminal-home-'))
(HOME / '.zshrc').write_text("PS1='%n@fixture %1~ %# '\n")
(HOME / '.bashrc').write_text("PS1='\\u@fixture \\W \\$ '\n")
(HOME / 'notes.txt').write_text('a file in the scratch home\n')
STATE = {'off': False, 'supported': True, 'blocked': False, 'dials': 0}
LOOP = asyncio.new_event_loop()
threading.Thread(target=LOOP.run_forever, daemon=True, name='terminal-loop').start()

_shell_env = terminal.shell_env
terminal.shell_env = lambda shell, env=None: {**_shell_env(shell, env), 'HOME': str(HOME)}


class Socket:
    """terminal.serve's view of a Starlette WebSocket, over the handler's raw socket (blocking reads in a thread)."""

    def __init__(self, connection):
        self.connection = connection
        self.lock = threading.Lock()
        self.closed = False

    def _read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError('closed')
            data += chunk
        return data

    def _frame(self):
        parts, kind = bytearray(), None
        while True:
            first, second = self._read(2)
            opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126:
                n = struct.unpack('>H', self._read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self._read(n)))
            if opcode == 8:
                return {'type': 'websocket.disconnect', 'code': struct.unpack('>H', payload[:2])[0] if len(payload) >= 2 else 1005}
            if opcode == 9:
                self._send(0xA, payload)
                continue
            if opcode == 10:
                continue
            if opcode in (1, 2):
                kind = opcode
            parts.extend(payload)
            if final:
                if kind == 1:
                    return {'type': 'websocket.receive', 'text': parts.decode()}
                return {'type': 'websocket.receive', 'bytes': bytes(parts)}

    def _send(self, opcode, payload):
        n = len(payload)
        head = bytes([0x80 | opcode]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536
                                         else bytes([127]) + struct.pack('>Q', n))
        with self.lock:
            if self.closed:
                raise ConnectionError('closed')
            self.connection.sendall(head + payload)

    async def receive(self):
        try:
            return await asyncio.get_running_loop().run_in_executor(None, self._frame)
        except (ConnectionError, OSError):
            return {'type': 'websocket.disconnect', 'code': 1006}

    async def send_text(self, text):
        await asyncio.get_running_loop().run_in_executor(None, self._send, 1, text.encode())

    async def send_bytes(self, data):
        await asyncio.get_running_loop().run_in_executor(None, self._send, 2, bytes(data))

    async def close(self, code=1000, reason=''):
        def shut():
            try:
                self._send(8, struct.pack('>H', code) + reason.encode()[:120])
            except (ConnectionError, OSError):
                pass
            with self.lock:
                self.closed = True
            try:
                self.connection.shutdown(2)
            except OSError:
                pass
        await asyncio.get_running_loop().run_in_executor(None, shut)


async def serve(socket, query):
    if not STATE['supported']:
        return await socket.close(terminal.CLOSE_UNSUPPORTED, "This computer can't open a terminal")
    if STATE['off']:
        return await socket.close(terminal.CLOSE_OFF, 'Terminal is turned off on this computer')
    await terminal.serve(socket, query)


_push_handler = base.handler


def handler(gateway):
    parent = _push_handler(gateway)

    class Handler(parent):
        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == push.ROUTE + '/terminal' and (self.headers.get('Upgrade') or '').lower() == 'websocket':
                query = {k: v[-1] for k, v in parse_qs(parsed.query).items()}
                if STATE['blocked']:
                    STATE['dials'] += 1
                    self.close_connection = True
                    self.connection.sendall(b'HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n')
                    return
                if 'ticket' not in query or push.STATE['plugin'] != 'ready':
                    return self.reply(401 if 'ticket' not in query else 404, {'detail': 'Not Found'})
                key = self.headers['Sec-WebSocket-Key']
                accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                         'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
                self.close_connection = True
                STATE['dials'] += 1
                socket = Socket(self.connection)
                try:
                    asyncio.run_coroutine_threadsafe(serve(socket, query), LOOP).result()
                except Exception as error:  # noqa: BLE001
                    print('terminal fixture:', type(error).__name__, error, file=sys.stderr)
                return
            if parsed.path == '/__fixture/terminal':
                sessions = [{'id': ident, 'printed': s.printed, 'viewer': s.viewer is not None, 'finished': s.finished}
                            for ident, s in terminal._sessions.items()]
                return self.reply(200, {'sessions': sessions, 'dials': STATE['dials'], **{k: STATE[k] for k in ('off', 'supported', 'blocked')}})
            return super().do_GET()

        def do_POST(self):
            if urlparse(self.path).path == '/__fixture/terminal':
                body = self.body()
                if 'plugin' in body:
                    with push.LOCK:
                        push.STATE['plugin'] = body['plugin']
                for key in ('off', 'supported', 'blocked'):
                    if key in body:
                        STATE[key] = bool(body[key])
                return self.reply(200, {'ok': True})
            return super().do_POST()

    return Handler


base.handler = handler

_status = push.status_body


def status_body(old=False):
    body = _status(old)
    if not old:
        body.update(pluginVersion='0.9.25', terminal=STATE['supported'], terminalOff=STATE['off'])
    return body


push.status_body = status_body
push.STATE['plugin'] = 'ready'

if __name__ == '__main__':
    for flag in ('--sim', '--bundle'):
        if flag in sys.argv:
            at = sys.argv.index(flag)
            push.SIM[flag[2:] if flag == '--bundle' else 'udid'] = sys.argv[at + 1]
            del sys.argv[at:at + 2]
    print('terminal fixture: shells start in', HOME, file=sys.stderr)
    base.main()
