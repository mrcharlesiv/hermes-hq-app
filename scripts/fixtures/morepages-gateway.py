#!/usr/bin/env python3
"""Stand-in gateway for the More pages and navigation chrome (docs/spec/3x-morepages.md §20).

Stdlib only, 127.0.0.1 only, invented data only. It loads scripts/pages-fixture-gateway.py by path (sign-in, /api/ws,
Jobs, Kanban, Artifacts and the /__fixture/* controls keep working; nothing there is edited) and adds one module per
feature from scripts/fixtures/morepages/<name>.py.

  python3 scripts/fixtures/morepages-gateway.py --port 10050 --credentials build/fixtures/morepages.json \
      --files build/fixtures/morepages-files --tick-seconds 0
  ... --old-gateway     every route and method of a module marked NEW answers 404 / -32601 (an older Hermes)
  ... --webhooks-off    the webhook receiver starts off
  ... --attachment-max-mb N   the Kanban attachment limit (default 25)

Ports are 10050-10059 (HQN_MOREPAGES_ANY_PORT=1 lifts that); a busy port is refused before anything is loaded.

A module is a plain Python file. The loader sets `module.ctx` (see `Ctx`) and then uses whichever of these it defines:
  NEW = True                       hidden by --old-gateway, with REST_PREFIXES = ('/api/x',) and RPC_METHODS = {'a.b'}
  setup()                          once, after the arguments are known
  seed()                           at start and on every POST /__fixture/reset
  rest(method, path, query, body, handler) -> (status, json | bytes | (content_type, bytes)) | None
                                   `query` is {name: [values]}; `handler.raw_body` holds the request's bytes
  rpc(method, params) -> result | None      refuse with ctx.refuse(code, message); check keys with ctx.keys(params, {...})
  control(path, body) -> dict | None        POST /__fixture/<anything>
  state() -> dict                  merged into GET /__fixture/state under the module's name
Every JSON-RPC method a module adds must call ctx.keys: Hermes answers error 4000 for a param it does not know.
"""
import importlib.util, json, os, pathlib, re, socket, subprocess, sys, threading, time
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent

def take_flag(name, value=False):
    """Removes `--name [value]` from sys.argv and returns it (the pages fixture's parser does not know it)."""
    for index, word in enumerate(sys.argv):
        if word == name:
            if not value:
                del sys.argv[index]; return True
            found = sys.argv[index + 1]; del sys.argv[index:index + 2]; return found
        if value and word.startswith(name + '='):
            del sys.argv[index]; return word.split('=', 1)[1]
    return None if value else False

def asked(name):
    for index, word in enumerate(sys.argv):
        if word == name and index + 1 < len(sys.argv): return sys.argv[index + 1]
        if word.startswith(name + '='): return word.split('=', 1)[1]
    return None

OLD_GATEWAY = take_flag('--old-gateway')
WEBHOOKS_OFF = take_flag('--webhooks-off')
ATTACHMENT_MAX_MB = float(take_flag('--attachment-max-mb', value=True) or 25)
if not asked('--port'): sys.exit('usage: morepages-gateway.py --port <10050-10059> --credentials <file> --files <folder> [--tick-seconds 0]')
PORT = int(asked('--port'))
if not 10050 <= PORT <= 10059 and not os.environ.get('HQN_MOREPAGES_ANY_PORT'):
    sys.exit('morepages fixture ports are 10050-10059 (set HQN_MOREPAGES_ANY_PORT=1 to override)')

# Refuse a busy port before anything is loaded: another agent, or the owner's own Hermes, may be listening there.
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    probe.bind(('127.0.0.1', PORT))
except OSError:
    listening = subprocess.run(['lsof', '-nP', f'-iTCP:{PORT}', '-sTCP:LISTEN'], capture_output=True, text=True).stdout.strip()
    if listening: sys.exit(f'port {PORT} is already in use')
finally:
    probe.close()

_spec = importlib.util.spec_from_file_location('hqn_morepages_pages', HERE.parent / 'pages-fixture-gateway.py')
pages = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pages)


class Refused(ValueError):
    """A JSON-RPC refusal with its own code (the pages fixture answers every ValueError with -32001)."""
    def __init__(self, code, message):
        super().__init__(f'{code}|{message}')


class Ctx:
    """What a module gets as `ctx`."""
    pages = pages
    lock = pages.lock
    old_gateway = OLD_GATEWAY
    webhooks_off = WEBHOOKS_OFF
    attachment_max_mb = ATTACHMENT_MAX_MB
    port = PORT
    home = pages.HOME
    writes = []          # every write a module records: {"module","what",...}; GET /__fixture/state "writes"

    @property
    def files(self): return pathlib.Path(pages.FILES)

    @staticmethod
    def refuse(code, message): raise Refused(code, message)

    @staticmethod
    def keys(params, allowed):
        """Hermes: error 4000 for any param key it does not know."""
        extra = sorted(set(params) - set(allowed))
        if extra: raise Refused(4000, f'unknown parameter: {extra[0]}')

    def wrote(self, module, what, **more):
        with pages.lock: self.writes.append(dict(module=module, what=what, **more))

    @staticmethod
    def broadcast(kind, payload=None):
        frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'payload': payload or {}}}
        for send in list(pages.sockets):
            try: send(frame)
            except OSError: pass

    @staticmethod
    def drop_sockets(seconds=2.0):
        """Closes every open socket and refuses new ones for `seconds` (a gateway restarting)."""
        global DOWN_UNTIL
        DOWN_UNTIL = time.time() + seconds
        for connection in list(CONNECTIONS):
            try: connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass

    @staticmethod
    def profiles(): return [name for name, _, _ in pages.BOTS]

    @staticmethod
    def one(query, key, default=''): return (query.get(key) or [default])[0]

ctx = Ctx()

# ---- modules ----------------------------------------------------------------------------------------------
MODULES = []
for path in sorted((HERE / 'morepages').glob('*.py')):
    if path.name.startswith('_'): continue
    spec = importlib.util.spec_from_file_location('hqn_morepages_' + path.stem, path)
    module = importlib.util.module_from_spec(spec)
    module.ctx = ctx
    spec.loader.exec_module(module)
    module.NAME = path.stem
    MODULES.append(module)

def hidden(module): return OLD_GATEWAY and getattr(module, 'NEW', False)

# ---- JSON-RPC ---------------------------------------------------------------------------------------------
_rpc = pages.rpc
def rpc(method, params):
    for module in MODULES:
        if hidden(module):
            if method in getattr(module, 'RPC_METHODS', ()):
                with pages.lock: pages.state['rpc'].append({'method': method, 'params': dict(params)})
                raise Refused(-32601, f'Method not found: {method}')
            continue
        if not hasattr(module, 'rpc'): continue
        if method not in getattr(module, 'RPC_METHODS', (method,)): continue
        with pages.lock: pages.state['rpc'].append({'method': method, 'params': dict(params)})
        answer = module.rpc(method, params)
        if answer is not None: return answer
        with pages.lock: pages.state['rpc'].pop()
    return _rpc(method, params)
pages.rpc = rpc
pages.fx.rpc = rpc


class Json:
    """A refusal "<code>|text" carries its own code out of the pages fixture's socket loop."""
    def __getattr__(self, name): return getattr(json, name)
    def dumps(self, value, *args, **kwargs):
        error = value.get('error') if isinstance(value, dict) else None
        if isinstance(error, dict) and isinstance(error.get('message'), str):
            match = re.fullmatch(r'(-?\d{4,5})\|(.*)', error['message'], re.S)
            if match: value = dict(value, error={'code': int(match.group(1)), 'message': match.group(2)})
        return json.dumps(value, *args, **kwargs)
pages.json = Json()

# ---- the socket (so a restart can really drop it) ------------------------------------------------------------
CONNECTIONS = set()
DOWN_UNTIL = 0.0
_websocket = pages.websocket
def websocket(connection, key):
    if time.time() < DOWN_UNTIL:
        try: connection.close()
        except OSError: pass
        return
    CONNECTIONS.add(connection)
    try: return _websocket(connection, key)
    finally: CONNECTIONS.discard(connection)
pages.websocket = websocket
pages.fx.auth.websocket = websocket

# ---- REST -------------------------------------------------------------------------------------------------
_handler = pages.fx.handler
def handler(gateway):
    Base = _handler(gateway)
    class Handler(Base):
        raw_body = b''

        def body_json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            self.raw_body = raw
            try: value = json.loads(raw or b'{}')
            except ValueError: return {}
            return value

        def route(self, method, body):
            url = urlparse(self.path); query = parse_qs(url.query)
            for module in MODULES:
                if hidden(module):
                    if any(url.path.startswith(prefix) for prefix in getattr(module, 'REST_PREFIXES', ())):
                        return 404, {'detail': 'Not Found'}
                    continue
                if hasattr(module, 'rest'):
                    answer = module.rest(method, url.path, query, body, self)
                    if answer is not None: return answer
            return super().route(method, body)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/state':
                with pages.lock:
                    out = {'rest': pages.state['rest'], 'rpc': pages.state['rpc'], 'dispatch': pages.state['dispatch'],
                           'beacon': pages.state['beacon'], 'writes': list(ctx.writes)}
                    for module in MODULES:
                        if hasattr(module, 'state'): out[module.NAME] = module.state()
                return self.reply(200, out)
            if path == '/api/status':
                # Status & Maintenance's module (once Command Center) answers the status; sign-in probes still get the base answer's keys.
                for module in MODULES:
                    if hasattr(module, 'status_extra') and not hidden(module):
                        base = self.base_status()
                        if base is not None:
                            base.update(module.status_extra())
                            with pages.lock: pages.state['rest'].append({'method': 'GET', 'path': path, 'query': {}, 'body': None})
                            return self.reply(200, base)
            return super().do_GET()

        def base_status(self):
            """The base fixture's /api/status body, captured instead of sent."""
            captured = {}
            original = self.reply
            def capture(status, body): captured['body'] = body
            self.reply = capture
            try: Base.do_GET(self)
            finally: self.reply = original
            body = captured.get('body')
            return dict(body) if isinstance(body, dict) else None

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/reset':
                self.body_json()
                reseed()
                return self.reply(200, {'ok': True})
            if path.startswith('/__fixture/') and path not in ('/__fixture/fail', '/__fixture/broadcast', '/__fixture/append'):
                body = self.body_json()
                for module in MODULES:
                    if hasattr(module, 'control'):
                        answer = module.control(path, body)
                        if answer is not None: return self.reply(200, answer)
            return super().do_POST()
    return Handler
pages.fx.handler = handler

_reseed = pages.reseed
def reseed():
    _reseed()
    with pages.lock:
        ctx.writes.clear()
        for module in MODULES:
            if hasattr(module, 'seed'): module.seed()
pages.reseed = reseed

if __name__ == '__main__':
    for module in MODULES:
        if hasattr(module, 'setup'): module.setup()
    print(f'More pages fixture: modules {", ".join(m.NAME for m in MODULES) or "none"}'
          + (' (old gateway)' if OLD_GATEWAY else ''), flush=True)
    pages.main()
