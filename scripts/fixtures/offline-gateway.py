#!/usr/bin/env python3
"""A stand-in gateway that can go away: for the offline screen, the launch screen and reconnect behaviour
(docs/spec/3x-offline.md §7).

Stdlib only, loopback only, invented data, no network client. It loads the reference action-voice fixture
($HQN_REF/scripts/action-voice-fixture-gateway.py) for the password sign-in and the session cookies, and serves its
own roster, sessions, chats, REST and socket. It has TWO listeners: the gateway port, which can be told to refuse,
hang or answer errors, and a control port, which always answers.

  python3 scripts/fixtures/offline-gateway.py --port 9980 --control-port 9981 --credentials build/fixtures/offline.json
  python3 scripts/fixtures/offline-gateway.py --port 9982 --control-port 9983 --credentials build/fixtures/offline-b.json --label B

Flags: --start-down, --delay-ticket S, --roster-delay S, --no-change-events, --changed-on-ready, --label NAME,
--hermes-cookies, --keep-credentials. Ports outside 9980-9989 are refused unless HQN_ANY_PORT=1.

Controls (control port, and the gateway port while it is up; no auth):
  GET  /__fixture/state      {"rest":[…],"rpc":[…],"dials":[…],"tickets":n,"sockets":n,"probes":n,"full":n,"mode":…,"epoch":…}
  POST /__fixture/mode       {"mode":"up"|"refuse"|"blackhole"|"status"|"not-hermes"|"outdated", "scope", "status", "retry_after",
                              "body": raw text for "status" (Hermes turns a wrong address away with 400 "Invalid Host header")}
  POST /__fixture/stall      {"rest": S|null}
  POST /__fixture/delay      {"rpc":{"<method>":S},"rest":{"<path>":S}}
  POST /__fixture/fail       {"rpc":"<method>","code":N,"count":N} or {"method","path","status","count"} (+ "body": raw text)
  POST /__fixture/drop       every socket closed now, the epoch stays
  POST /__fixture/restart    sockets closed, a new replay epoch, runtime ids re-minted, replay ring emptied
  POST /__fixture/revoke     every session refused from now on (and sockets dropped unless {"drop":false})
  POST /__fixture/oversize   {"bytes":N} one text frame of N bytes to every socket
  POST /__fixture/turn       {"session_id","chars","drop_at","save_after","think","wait"} script the next prompt in that chat
                             ("wait": seconds before the turn's first frame, so a phone that leaves at once hears none)
  POST /__fixture/rich       {"session_id","turns"} a long chat in that session: markdown, code blocks, tables, tool
                             calls with their results (build 292's return catch-up measurements)
  POST /__fixture/work       {"session_id","subagents":[…],"processes":[…]}
  POST /__fixture/work/end   {"subagents":[…],"processes":[…]} (no event)
  POST /__fixture/touch      {"session_id"}
  POST /__fixture/broadcast  {"type":"cron.changed"|"sessions.changed"}
  POST /__fixture/options    {"change_events":bool} what the next gateway.ready says (reset restores the command line's)
  POST /__fixture/reset      {"bots":N,"sessions":N} forget ledgers, failures and modes; re-seed
"""
import argparse, base64, hashlib, importlib.util, json, os, pathlib, secrets, socket, struct, sys, threading, time
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
_spec = importlib.util.spec_from_file_location('fx', REF / 'scripts/action-voice-fixture-gateway.py')
fx = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(fx)
auth = fx.auth

HOME = '/home/hermes'
lock = threading.RLock()
DEFAULTS = {}        # the command line's own options, for /__fixture/reset
OPTIONS = {'label': '', 'delay_ticket': 0.0, 'roster_delay': 0.0, 'change_events': True, 'changed_on_ready': False}
LEDGER = {'rest': [], 'rpc': [], 'dials': [], 'tickets': 0, 'probes': 0, 'full': 0}
MODE = {'mode': 'up', 'scope': 'all', 'status': 503, 'retry_after': None, 'body': None}
STALL = {'rest': None}
DELAYS = {'rpc': {}, 'rest': {}}
FAILS = []
SOCKETS = set()
EPOCH = {'n': 1}
BOTS = []            # (name, title, about, pinned)
SESSIONS = {}        # stored id → session
RING = {}            # stored id → [event]
SEQ = {}             # stored id → latest seq
INFLIGHT = {}        # stored id → {'user','assistant','running'}
TURNS = {}           # stored id → {'chars','drop_at','save_after'}
WORK = {'subagents': {}, 'processes': {}}
JOBS = []
changed = threading.Condition(lock)   # notified on every mode/stall change, so held requests wake


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message); self.code = code; self.message = message


def now(): return time.time()
def epoch(): return f'offline-{EPOCH["n"]}'
def runtime(sid, n=None): return hashlib.sha256(f'{sid}:{EPOCH["n"] if n is None else n}'.encode()).hexdigest()[:8]
def bot_chat_id(profile): return f'20261011_090000_bc{hashlib.sha256(profile.encode()).hexdigest()[:6]}'
def label(text): return f'{OPTIONS["label"]} {text}' if OPTIONS['label'] else text

BOT_SEED = [('default', 'Hermes', 'Your right hand', True), ('research', 'Research', 'Reading and summaries', False),
            ('deploys', 'Deploys', 'Releases, builds and checks', False), ('finance', 'Finance', 'Bills and budgets', False),
            ('garden', 'Garden', 'Beds, seeds and watering', False)]
TOPICS = ['Garden plan', 'Trip to Lisbon', 'Release notes', 'Quarterly budget', 'Bread recipes', 'Reading list', 'Deploy checklist',
          'Standing desk', 'Birthday ideas', 'Tax folder', 'Bike repair', 'Podcast notes', 'Seed order', 'Server costs',
          'Book club', 'Moving boxes', 'Language practice', 'Camera settings', 'Meal plan', 'Roof quote']


def add_session(sid, profile, title, messages, last_active, hidden=False, source='desktop'):
    for index, message in enumerate(messages):
        message.setdefault('id', index + 1)
        message.setdefault('timestamp', last_active - (len(messages) - index) * 5)
    SESSIONS[sid] = {'id': sid, 'profile': profile, 'title': title, 'messages': messages, 'last_active': last_active,
                     'started_at': last_active - 600, 'hidden': hidden, 'source': source}


def seed(bots=5, sessions=20):
    BOTS.clear(); SESSIONS.clear(); RING.clear(); SEQ.clear(); INFLIGHT.clear(); TURNS.clear(); JOBS.clear()
    WORK['subagents'].clear(); WORK['processes'].clear()
    base = int(now()) - 60
    for index in range(bots):
        if index < len(BOT_SEED): name, title, about, pinned = BOT_SEED[index]
        else: name, title, about, pinned = f'bot{index}', f'Bot {index}', 'An invented helper', False
        BOTS.append((name, label(title), about, pinned))
        add_session(bot_chat_id(name), name, 'Bot Chat', [
            {'role': 'user', 'content': 'Morning. Anything for me?'},
            {'role': 'assistant', 'content': f'Morning. {label(title)} here: nothing urgent today.'},
        ], base - 3600 * (index + 1), hidden=True)
    for index in range(sessions):
        topic = TOPICS[index % len(TOPICS)] + ('' if index < len(TOPICS) else f' {index // len(TOPICS) + 1}')
        profile = BOTS[index % len(BOTS)][0]
        add_session(f's-{index + 1:03d}', profile, label(topic), [
            {'role': 'user', 'content': f'Help me with: {topic.lower()}.'},
            {'role': 'assistant', 'content': f'Here is a first pass at {topic.lower()}. Tell me what to change.'},
        ], base - 300 * (index + 1))
    for index, name in enumerate(['Morning summary', 'Weekly backup check', 'Inbox sweep']):
        JOBS.append({'id': f'job-{index + 1}', 'name': name, 'schedule': {'kind': 'cron', 'expr': f'0 {7 + index} * * *', 'display': f'Every day at {7 + index}:00'},
                     'prompt': f'{name}.', 'enabled': True, 'state': 'scheduled', 'profile': 'default',
                     'next_run_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now() + 3600 * (index + 1))), 'last_run_at': None,
                     'last_status': None, 'deliver': 'local', 'skills': [], 'repeat': {'times': None, 'completed': 0}})


def session_row(sid):
    s = SESSIONS[sid]
    last = next((m for m in reversed(s['messages']) if m['role'] == 'assistant' and isinstance(m.get('content'), str)), None)
    preview = (last['content'] if last else '').split('\n')[0][:140]
    return {'id': sid, 'title': s['title'], 'preview': preview, 'profile': s['profile'], 'profile_name': s['profile'],
            'is_default_profile': s['profile'] == 'default', 'hidden': s['hidden'], 'pinned': False, 'unread': False,
            'archived': False, 'model': 'hermes-4', 'billing_provider': 'nous', 'source': s['source'],
            'message_count': len(s['messages']), 'started_at': s['started_at'], 'last_active': s['last_active'],
            'ended_at': None, 'is_active': False, 'cwd': f'{HOME}/app', 'parent_session_id': None}


def find_session(asked):
    if asked in SESSIONS: return asked
    return next((sid for sid in SESSIONS if runtime(sid) == asked), None)


def stale_runtime(asked):
    """True when `asked` is a runtime id minted before the last restart."""
    return any(runtime(sid, n) == asked for n in range(1, EPOCH['n']) for sid in SESSIONS)


def roster(include_sessions=True):
    rows = []
    for index, (name, title, about, pinned) in enumerate(BOTS):
        sid = bot_chat_id(name)
        canon = session_row(sid)
        short = {'id': sid, 'resolved_id': sid, 'title': 'Bot Chat', 'preview': canon['preview'], 'last_active': canon['last_active'],
                 'message_count': canon['message_count']}
        meta = {'title': title, 'description': about, 'pinned': pinned, 'created': 1790000000000 + index}
        row = {'name': name, 'path': f'{HOME}/profiles/{name}', 'is_default': name == 'default', 'is_active': name == 'default',
               'model': 'hermes-4', 'provider': 'nous', 'display_name': title, 'description': about,
               'canonical_session': short, 'last_session': short, 'worker_session': None,
               'ui_meta': {'hermes-bots': meta}, 'ui_meta_revisions': {'hermes-bots': 1}}
        if include_sessions: row['sessions'] = [canon]
        rows.append(row)
    return {'active': 'default', 'profiles': rows, 'bot_mode_protocol': True}


def snapshot(sid):
    s = SESSIONS[sid]
    flight = INFLIGHT.get(sid)
    running = bool(flight and flight.get('running'))
    info = {'model': 'hermes-4', 'provider': 'nous', 'cwd': f'{HOME}/app', 'title': s['title'], 'tools': {}, 'skills': {}, 'mcp_servers': [],
            'lazy': True, 'running': running, 'stored_session_id': sid, 'profile_name': s['profile'], 'desktop_contract': 8}
    return {'session_id': runtime(sid), 'resumed': sid, 'session_key': sid, 'stored_session_id': sid, 'messages': [],
            'messages_omitted': True, 'message_count': len(s['messages']), 'status': 'running' if running else 'idle',
            'running': running, 'inflight': {'user': flight['user'], 'assistant': flight['assistant']} if flight else None,
            'latest_seq': SEQ.get(sid, 0), 'info': info}


# ---- Events and sockets -----------------------------------------------------------------------------------

def frame_bytes(body: bytes) -> bytes:
    size = len(body)
    return bytes([0x81]) + (bytes([size]) if size < 126 else bytes([126]) + struct.pack('>H', size) if size < 65536
                            else bytes([127]) + struct.pack('>Q', size)) + body


class Sock:
    def __init__(self, connection):
        self.connection = connection; self.wlock = threading.Lock()

    def send(self, value): self.raw(frame_bytes(json.dumps(value).encode()))

    def raw(self, data):
        with self.wlock: self.connection.sendall(data)

    def close(self):
        try: self.connection.shutdown(socket.SHUT_RDWR)
        except OSError: pass


def to_all(value):
    for sock in list(SOCKETS):
        try: sock.send(value)
        except OSError: pass


def broadcast(kind, payload=None):
    to_all({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'payload': payload or {}}})


def emit(sid, kind, payload=None):
    """A seq'd session event: kept in the replay ring and sent to every socket."""
    with lock:
        SEQ[sid] = SEQ.get(sid, 0) + 1
        event = {'type': kind, 'session_id': runtime(sid), 'seq': SEQ[sid], 'payload': payload or {}}
        RING.setdefault(sid, []).append(event)
        del RING[sid][:-2000]
    to_all({'jsonrpc': '2.0', 'method': 'event', 'params': event})


def drop_sockets():
    for sock in list(SOCKETS): sock.close()


def restart():
    with lock:
        EPOCH['n'] += 1
        RING.clear(); SEQ.clear()
    drop_sockets()


RICH_CODE = '\n'.join(['```swift', 'struct Probe {'] + [f'    let field{i}: Int = {i} // an invented line {i}' for i in range(28)]
                      + ['}', '```'])


def rich_messages(turns):
    """An invented long chat with the shapes that cost the most to lay out: headed markdown, lists, a table, a
    30-line code block, and a tool call with its result before each reply."""
    out = []
    for n in range(turns):
        call = f'call-{n}'
        out += [
            {'role': 'user', 'content': f'Step {n}: check the build and show me the probe.'},
            {'role': 'assistant', 'content': '', 'tool_calls': [{'id': call, 'type': 'function', 'function': {
                'name': 'terminal', 'arguments': json.dumps({'command': f'swift build --target probe{n}', 'timeout': 60})}}]},
            {'role': 'tool', 'tool_call_id': call, 'content': json.dumps({'output': 'Compiling probe\n' * 20, 'exit_code': 0})},
            {'role': 'assistant', 'content': f'## Step {n} done\n\nThe build **passed**. What changed:\n\n'
                                             '- the probe has *28* fields\n- each one is `Int`\n- nothing else moved\n\n'
                                             '| Target | Time | Result |\n|---|---|---|\n| probe | 1.2 s | ok |\n| app | 4.0 s | ok |\n\n'
                                             + RICH_CODE + '\n\nTell me if you want the next step.'},
        ]
    return out


def run_turn(sid, text):
    plan = TURNS.pop(sid, None)
    chars = int((plan or {}).get('chars') or 240)
    words = ('This is an invented reply from the offline stand-in. ' * (chars // 50 + 1))[:chars].rstrip()
    session = SESSIONS[sid]
    with lock:
        row = len(session['messages']) + 1
        session['messages'].append({'id': row, 'role': 'user', 'content': text, 'timestamp': now()})
        session['last_active'] = now()
        INFLIGHT[sid] = {'user': text, 'assistant': '', 'running': True}
    time.sleep(0.15 + float((plan or {}).get('wait') or 0))
    emit(sid, 'message.start')
    if (plan or {}).get('think'): time.sleep(float(plan['think']))   # a turn that works a while before its first words
    drop_at = (plan or {}).get('drop_at')
    sent = 0
    for start in range(0, len(words), 12):
        chunk = words[start:start + 12]
        if drop_at is not None and sent + len(chunk) > int(drop_at):
            # The gateway restarts mid-reply: the turn ends unseen. The snapshot keeps the partial (running false)
            # and the full reply is saved `save_after` seconds later.
            with lock: INFLIGHT[sid] = {'user': text, 'assistant': words[:sent], 'running': False}
            restart()
            time.sleep(float((plan or {}).get('save_after') or 0))
            with lock:
                session['messages'].append({'id': len(session['messages']) + 1, 'role': 'assistant', 'content': words, 'timestamp': now()})
                session['last_active'] = now()
                INFLIGHT.pop(sid, None)
            broadcast('sessions.changed')
            return
        with lock: INFLIGHT[sid]['assistant'] += chunk
        emit(sid, 'message.delta', {'text': chunk})
        sent += len(chunk)
        time.sleep(0.03)
    with lock:
        row = len(session['messages']) + 1
        session['messages'].append({'id': row, 'role': 'assistant', 'content': words, 'timestamp': now()})
        session['last_active'] = now()
        INFLIGHT.pop(sid, None)
    emit(sid, 'message.complete', {'text': words, 'status': 'complete', 'row_id': row})
    broadcast('sessions.changed')


STRICT = {
    'session.events.since': {'session_id', 'profile', 'last_seen'},
    'delegation.status': {'profile'},
    'agents.list': {'profile'},
    'session.active_list': {'profile'},
    'ping': set(),
}
_fallback = fx.rpc
FALLBACK = {'gateway.ping', 'model.options', 'free_tier.status', 'setup.status', 'session.most_recent', 'session.usage',
            'session.control.read', 'setup.runtime_check', 'model.list', 'models.list', 'config.get', 'approval.pending',
            'process.list', 'commands.catalog', 'commands.list', 'tools.list', 'toolsets.list', 'cron.list', 'cron.manage',
            'plugins.list', 'plugins.manage', 'skills.list', 'skills.manage', 'status.get', 'gateway.status', 'settings.get',
            'client.capabilities'}


def rpc(method, params):
    entry = {'method': method, 'params': {k: v for k, v in params.items() if k not in ('data_url',)}, 'start': now(), 'end': None}
    with lock: LEDGER['rpc'].append(entry)
    try:
        return rpc_inner(method, params)
    finally:
        entry['end'] = now()


def rpc_inner(method, params):
    delay = DELAYS['rpc'].get(method)
    if delay: time.sleep(float(delay))
    with lock:
        for fail in list(FAILS):
            if fail.get('rpc') == method:
                fail['count'] = int(fail.get('count', 1)) - 1
                if fail['count'] <= 0: FAILS.remove(fail)
                if 'result' in fail: return fail['result']
                raise RpcError(int(fail.get('code', -32000)), fail.get('message', 'the stand-in was told to fail this'))
    allowed = STRICT.get(method)
    if allowed is not None and set(params) - allowed:
        raise RpcError(4000, f'unknown params: {sorted(set(params) - allowed)}')
    profile = params.get('profile') or 'default'
    if method == 'ping': return {'ok': True}
    if method == 'profiles.list':
        if OPTIONS['roster_delay']: time.sleep(OPTIONS['roster_delay'])
        with lock: return roster(params.get('include_sessions') is not False)
    if method == 'session.list':
        with lock:
            rows = [session_row(sid) for sid, s in SESSIONS.items() if s['profile'] == profile]
        return {'sessions': rows, 'total': len(rows)}
    if method == 'session.resume':
        with lock:
            sid = find_session(params.get('session_id')) or (bot_chat_id(profile) if bot_chat_id(profile) in SESSIONS else None)
            if not sid: raise RpcError(4007, 'session not found')
            return snapshot(sid)
    if method == 'session.activate':
        with lock:
            sid = find_session(params.get('session_id'))
            if not sid: raise RpcError(4007, 'session not found')
            return snapshot(sid)
    if method in ('session.info', 'session.get'):
        with lock:
            sid = find_session(params.get('session_id')) or bot_chat_id('default')
            return snapshot(sid)['info']
    if method == 'session.events.since':
        with lock:
            sid = find_session(params.get('session_id'))
            if not sid: raise RpcError(4007, 'session not found')
            last = int(params.get('last_seen') or 0)
            events = [e for e in RING.get(sid, []) if e['seq'] > last]
            return {'events': events, 'latest_seq': SEQ.get(sid, 0), 'truncated': False, 'count': len(events), 'epoch': epoch(),
                    'open_requests': []}
    if method == 'session.active_list':
        with lock:
            rows = [{'session_id': runtime(sid), 'stored_session_id': sid, 'status': 'running', 'running': True}
                    for sid, flight in INFLIGHT.items() if flight.get('running')]
        return {'sessions': rows}
    if method == 'prompt.submit':
        with lock:
            sid = find_session(params.get('session_id'))
            if not sid: raise RpcError(4007, 'session not found')
            if INFLIGHT.get(sid, {}).get('running'): raise RpcError(4009, 'session busy')
        text = params.get('text') or params.get('prompt') or ''
        threading.Thread(target=run_turn, args=(sid, text), daemon=True).start()
        return {'status': 'streaming'}
    if method == 'session.interrupt':
        with lock:
            sid = find_session(params.get('session_id'))
            if sid: INFLIGHT.pop(sid, None)
        return {'interrupted': True}
    if method == 'delegation.status':
        with lock:
            return {'active': [dict(row) for row in WORK['subagents'].values()], 'max_concurrent': 3}
    if method == 'agents.list':
        with lock:
            return {'processes': [dict(row) for row in WORK['processes'].values()]}
    if method == 'subagent.list':
        with lock:
            sid = find_session(params.get('session_id'))
            rows = [dict(row) for row in WORK['subagents'].values() if row.get('stored_session_id') == sid]
        return {'subagents': rows, 'delegations': []}
    if method in FALLBACK: return _fallback(method, params)
    raise RpcError(-32601, f'Method not found: {method}')


def websocket(connection: socket.socket, key: str):
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    sock = Sock(connection)

    def read(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data

    def answer(frame):
        reply = {'jsonrpc': '2.0', 'id': frame['id']}
        try: reply['result'] = rpc(frame['method'], frame.get('params') or {})
        except RpcError as error: reply['error'] = {'code': error.code, 'message': error.message}
        except ValueError as error: reply['error'] = {'code': -32001, 'message': str(error)}
        try: sock.send(reply)
        except OSError: pass

    with lock: SOCKETS.add(sock)
    try:
        sock.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
            'heartbeat': True, 'change_events': OPTIONS['change_events'], 'replay_epoch': epoch(), 'desktop_contract': 8}}})
        if OPTIONS['changed_on_ready']:
            sock.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'sessions.changed', 'payload': {}}})
        fragments = bytearray()
        while True:
            first, second = read(2); opcode, length, final = first & 15, second & 127, bool(first & 128)
            if length == 126: length = struct.unpack('>H', read(2))[0]
            elif length == 127: length = struct.unpack('>Q', read(8))[0]
            mask = read(4) if second & 128 else b'\0\0\0\0'
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(length)))
            if opcode == 8: return
            if opcode == 9:
                sock.raw(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 1: fragments = bytearray(payload)
            elif opcode == 0: fragments.extend(payload)
            else: continue
            if not final: continue
            frame = json.loads(fragments); fragments.clear()
            if 'id' not in frame or 'method' not in frame: continue
            # Each request on its own thread: a delayed answer must not hold the ones behind it (as Hermes' pool).
            threading.Thread(target=answer, args=(frame,), daemon=True).start()
    except (ConnectionError, OSError, ValueError):
        return
    finally:
        with lock: SOCKETS.discard(sock)


# ---- REST -------------------------------------------------------------------------------------------------

def hold_while(predicate, limit=600):
    """Blocks while `predicate()` holds (a black hole or a stall), waking on every control change."""
    deadline = now() + limit
    with changed:
        while predicate() and now() < deadline:
            changed.wait(timeout=0.5)


def handler(gateway, control_only=False):
    base = auth.handler(gateway)

    class Handler(base):
        def body_json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try: return json.loads(raw or b'{}')
            except ValueError: return {}

        def text(self, status, body, content_type='text/html', headers=None):
            data = body.encode()
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            for name, value in (headers or {}).items(): self.send_header(name, value)
            self.end_headers()
            self.wfile.write(data)

        def hang_up(self):
            self.close_connection = True
            try: self.connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass

        # -- controls --------------------------------------------------------------------------------------
        def control(self, method, path):
            if method == 'GET' and path == '/__fixture/state':
                with lock:
                    return self.reply(200, {**{k: (list(v) if isinstance(v, list) else v) for k, v in LEDGER.items()},
                                            'sockets': len(SOCKETS), 'mode': dict(MODE), 'epoch': epoch(), 'stall': STALL['rest'],
                                            'listening': SERVER['gateway'] is not None})
            if method == 'GET': return self.reply(404, {'detail': 'not a control'})
            body = self.body_json()
            if path == '/__fixture/mode':
                mode = body.get('mode') or 'up'
                with changed:
                    MODE.update({'mode': mode, 'scope': body.get('scope') or 'all', 'status': int(body.get('status') or 503),
                                 'retry_after': body.get('retry_after'), 'body': body.get('body')})
                    changed.notify_all()
                # Answer first: on the gateway port this very connection is one of those `refuse` closes.
                self.reply(200, {'ok': True, 'mode': mode})
                if mode == 'refuse': threading.Thread(target=stop_gateway, daemon=True).start()
                else:
                    start_gateway()
                    if mode in ('blackhole', 'status') and (body.get('scope') or 'all') != 'rest': drop_sockets()
                return
            if path == '/__fixture/stall':
                with changed:
                    STALL['rest'] = body.get('rest')
                    changed.notify_all()
            elif path == '/__fixture/delay':
                with lock:
                    DELAYS['rpc'].update(body.get('rpc') or {}); DELAYS['rest'].update(body.get('rest') or {})
                    for table in DELAYS.values():
                        for key in [k for k, v in table.items() if not v]: del table[key]
            elif path == '/__fixture/fail':
                with lock: FAILS.append(body)
            elif path == '/__fixture/drop':
                drop_sockets()
            elif path == '/__fixture/restart':
                restart()
            elif path == '/__fixture/revoke':
                with gateway.lock:
                    gateway.access.clear(); gateway.refresh.clear(); gateway.sessions.clear()
                if body.get('drop') is not False: drop_sockets()
            elif path == '/__fixture/oversize':
                size = int(body.get('bytes') or (64 * 1024 * 1024 + 1024))
                data = frame_bytes(b'{"jsonrpc":"2.0","method":"event","params":{"type":"noise","payload":{"pad":"' + b'x' * max(0, size - 80) + b'"}}}')
                def send():
                    for sock in list(SOCKETS):
                        try: sock.raw(data)
                        except OSError: pass
                threading.Thread(target=send, daemon=True).start()
            elif path == '/__fixture/turn':
                with lock:
                    sid = find_session(body.get('session_id'))
                    if not sid: return self.reply(404, {'detail': 'no such session'})
                    TURNS[sid] = {'chars': body.get('chars'), 'drop_at': body.get('drop_at'), 'save_after': body.get('save_after'),
                                 'think': body.get('think'), 'wait': body.get('wait')}
            elif path == '/__fixture/rich':
                with lock:
                    sid = find_session(body.get('session_id'))
                    if not sid: return self.reply(404, {'detail': 'no such session'})
                    session = SESSIONS[sid]
                    add_session(sid, session['profile'], session['title'], rich_messages(int(body.get('turns') or 40)),
                                now() - 60, hidden=session['hidden'], source=session['source'])
            elif path == '/__fixture/work':
                with lock:
                    sid = find_session(body.get('session_id'))
                    if not sid: return self.reply(404, {'detail': 'no such session'})
                    for ident in body.get('subagents') or []:
                        WORK['subagents'][ident] = {'subagent_id': ident, 'id': ident, 'goal': f'Invented task {ident}', 'status': 'running',
                                                    'session_id': runtime(sid), 'parent_session_id': runtime(sid), 'stored_session_id': sid,
                                                    'started_at': now(), 'model': 'hermes-4', 'depth': 1}
                    for ident in body.get('processes') or []:
                        # As Hermes' agents.list: a process row's `session_id` is the process's own id.
                        WORK['processes'][ident] = {'id': ident, 'process_id': ident, 'command': f'sleep 600 # {ident}', 'status': 'running',
                                                    'session_id': ident, 'parent_session_id': runtime(sid), 'stored_session_id': sid,
                                                    'started_at': now()}
                for ident in body.get('subagents') or []:
                    emit(sid, 'subagent.spawn_requested', {'subagent_id': ident, 'goal': f'Invented task {ident}', 'task_index': 0, 'task_count': 1, 'depth': 1})
                    emit(sid, 'subagent.start', {'subagent_id': ident, 'goal': f'Invented task {ident}', 'task_index': 0, 'task_count': 1, 'depth': 1})
            elif path == '/__fixture/work/end':
                with lock:
                    for ident in body.get('subagents') or []: WORK['subagents'].pop(ident, None)
                    for ident in body.get('processes') or []: WORK['processes'].pop(ident, None)
            elif path == '/__fixture/touch':
                with lock:
                    sid = find_session(body.get('session_id'))
                    if not sid: return self.reply(404, {'detail': 'no such session'})
                    SESSIONS[sid]['last_active'] = now()
            elif path == '/__fixture/broadcast':
                broadcast(body.get('type') or 'sessions.changed')
            elif path == '/__fixture/options':
                # Runtime switches: {"change_events": bool} = what the next gateway.ready says (a reset restores it).
                if 'change_events' in body: OPTIONS['change_events'] = bool(body['change_events'])
            elif path == '/__fixture/reset':
                OPTIONS['change_events'] = DEFAULTS.get('change_events', True)
                with changed:
                    for key in ('rest', 'rpc', 'dials'): LEDGER[key].clear()
                    LEDGER.update({'tickets': 0, 'probes': 0, 'full': 0})
                    FAILS.clear(); DELAYS['rpc'].clear(); DELAYS['rest'].clear(); STALL['rest'] = None
                    MODE.update({'mode': 'up', 'scope': 'all', 'status': 503, 'retry_after': None, 'body': None})
                    if body.get('seed') is not False: seed(int(body.get('bots') or 5), int(body.get('sessions') or 20))
                    changed.notify_all()
                start_gateway()
            else:
                return self.reply(404, {'detail': 'not a control'})
            return self.reply(200, {'ok': True})

        # -- the gateway -----------------------------------------------------------------------------------
        def serve(self, method):
            url = urlparse(self.path); path = url.path
            if path.startswith('/__fixture/'): return self.control(method, path)
            if control_only: return self.reply(404, {'detail': 'the control port serves /__fixture/ only'})
            upgrade = path == '/api/ws' and (self.headers.get('Upgrade') or '').lower() == 'websocket'
            mode, scope = MODE['mode'], MODE['scope']
            if mode == 'refuse': return self.hang_up()
            if mode == 'blackhole' and (scope == 'all' or (scope == 'ws') == upgrade):
                if upgrade:
                    with lock: LEDGER['dials'].append(now())
                hold_while(lambda: MODE['mode'] == 'blackhole')
                return self.hang_up()
            query = {k: v[0] if len(v) == 1 else v for k, v in parse_qs(url.query).items()}
            body = self.body_json() if method in ('POST', 'PATCH', 'PUT', 'DELETE') else None
            entry = {'method': method, 'path': path, 'query': query, 'start': now(), 'end': None}
            if not upgrade:
                with lock: LEDGER['rest'].append(entry)
            try:
                if mode == 'status':
                    headers = {'Retry-After': str(MODE['retry_after'])} if MODE['retry_after'] is not None else {}
                    if MODE['body'] is not None: return self.text(MODE['status'], str(MODE['body']), 'text/plain; charset=utf-8', headers)
                    return self.text(MODE['status'], json.dumps({'detail': 'the stand-in was told to answer this'}), 'application/json', headers)
                if upgrade:
                    if mode in ('not-hermes', 'outdated'): return self.reply(404, {'detail': 'Not Found'})
                    with lock: LEDGER['dials'].append(now())
                    return self.upgrade()
                if STALL['rest'] is not None and path.startswith('/api/') and not path.startswith('/api/auth/'):
                    until = now() + float(STALL['rest'])
                    hold_while(lambda: STALL['rest'] is not None and now() < until)
                delay = DELAYS['rest'].get(path)
                if delay: time.sleep(float(delay))
                with lock:
                    for fail in list(FAILS):
                        if fail.get('path') == path and fail.get('method', method) == method and 'rpc' not in fail:
                            fail['count'] = int(fail.get('count', 1)) - 1
                            if fail['count'] <= 0: FAILS.remove(fail)
                            if 'body' in fail: return self.text(int(fail.get('status', 200)), fail['body'], fail.get('content_type', 'application/json'))
                            return self.reply(int(fail.get('status', 500)), {'detail': fail.get('detail', 'the stand-in was told to fail this')})
                return self.route(method, path, query, body or {})
            finally:
                entry['end'] = now()

        def upgrade(self):
            if not self.session() and 'ticket=' not in self.path: return self.reply(401, {'detail': 'unauthorized'})
            websocket(self.connection, self.headers['Sec-WebSocket-Key'])
            self.close_connection = True

        def route(self, method, path, query, body):
            one = lambda key, default='': query.get(key, default) if not isinstance(query.get(key), list) else query[key][0]
            if path == '/api/status' and method == 'GET':
                if MODE['mode'] == 'not-hermes': return self.text(200, '<!doctype html><title>Welcome</title><p>It works.</p>')
                release = '2026.1.5' if MODE['mode'] == 'outdated' else '2026.10.1'
                return self.reply(200, {'version': '0.22.0', 'release_date': release, 'auth_required': True, 'auth_providers': ['basic'],
                                        'gateway_running': True})
            if path == '/api/auth/providers' and method == 'GET':
                if MODE['mode'] in ('not-hermes', 'outdated'): return self.reply(404, {'detail': 'Not Found'})
                return base.do_GET(self)
            if path == '/api/auth/me' and method == 'GET':
                # Another web server at the address, or a Hermes from before gateway sign-in: no session check there.
                if MODE['mode'] == 'not-hermes': return self.text(404, '<!doctype html><title>404</title><p>Not Found</p>')
                if MODE['mode'] == 'outdated': return self.reply(404, {'detail': 'Not Found'})
                return base.do_GET(self)
            if method == 'POST' and (path.startswith('/auth/') or path.startswith('/api/auth/')):
                if path == '/api/auth/ws-ticket':
                    # [connect-fast] The ticket is now the restore's session check: another web server, or a Hermes
                    # from before gateway sign-in, has no ticket route either.
                    if MODE['mode'] == 'not-hermes': return self.text(404, '<!doctype html><title>404</title><p>Not Found</p>')
                    if MODE['mode'] == 'outdated': return self.reply(404, {'detail': 'Not Found'})
                    if OPTIONS['delay_ticket']: time.sleep(OPTIONS['delay_ticket'])
                    if not self.session(): return self.reply(401, {'detail': 'unauthorized'})
                    with lock: LEDGER['tickets'] += 1
                    return self.reply(200, {'ticket': secrets.token_urlsafe(16)})
                return self.auth_post(path, body)
            if not self.session(): return self.reply(401, {'error': 'session_expired', 'detail': 'Unauthorized'})
            if path == '/api/profiles/sessions/sidebar' and method == 'GET':
                limits = [int(one(key, '50') or 50) for key in ('recents_limit', 'cron_limit', 'messaging_limit')]
                with lock:
                    LEDGER['probes' if limits[0] <= 1 else 'full'] += 1
                    rows = sorted((session_row(sid) for sid, s in SESSIONS.items() if not s['hidden'] and s['messages']), key=lambda r: -r['last_active'])
                return self.reply(200, {'recents': {'sessions': rows[:limits[0]], 'total': len(rows)}, 'cron': {'sessions': []}, 'messaging': {'sessions': []}})
            if path in ('/api/profiles/sessions', '/api/sessions') and method == 'GET':
                with lock:
                    rows = sorted((session_row(sid) for sid, s in SESSIONS.items() if not s['hidden']), key=lambda r: -r['last_active'])
                limit = int(one('limit', '50') or 50)
                return self.reply(200, {'sessions': rows[:limit], 'total': len(rows), 'limit': limit, 'offset': 0})
            if path.startswith('/api/sessions/'):
                asked = unquote(path[len('/api/sessions/'):].split('/')[0])
                with lock:
                    sid = find_session(asked)
                    s = SESSIONS.get(sid) if sid else None
                    if not s: return self.reply(404, {'detail': 'Session not found'})
                    if method == 'GET' and path.endswith('/messages'):
                        rows = s['messages']
                        limit = int(one('limit', '100') or 100); offset = int(one('offset', '0') or 0)
                        # `order=latest` counts back from the newest row and still answers oldest first (as Hermes does).
                        page = list(reversed(rows))[offset:offset + limit][::-1] if one('order') == 'latest' else rows[offset:offset + limit]
                        return self.reply(200, {'session_id': sid, 'profile': s['profile'], 'messages': page, 'total': len(rows),
                                                'pagination': {'limit': limit, 'offset': offset, 'order': one('order') or 'oldest', 'returned': len(page)}})
                    if method == 'GET': return self.reply(200, session_row(sid))
                    if method == 'PATCH':
                        if 'title' in body: s['title'] = body['title'] or None
                        return self.reply(200, {'ok': True})
                return self.reply(405, {'detail': 'Method Not Allowed'})
            if path == '/api/cron/jobs' and method == 'GET':
                with lock: return self.reply(200, list(JOBS))
            if path == '/api/skills' and method == 'GET':
                return self.reply(200, [{'name': name, 'description': about, 'category': 'invented', 'enabled': True, 'usage': index, 'provenance': 'bundled'}
                                        for index, (name, about) in enumerate([('garden-notes', 'Keeps the planting calendar.'),
                                                                               ('trip-planner', 'Plans days out from a list of places.'),
                                                                               ('bread-timer', 'Times a dough from mix to bake.')])])
            if path == '/api/config' and method == 'GET': return self.reply(200, {'model': 'hermes-4', 'provider': 'nous', 'stt': {'enabled': False}})
            if path == '/api/config/schema' and method == 'GET': return self.reply(200, {'fields': {}, 'category_order': []})
            if path == '/api/profiles' and method == 'GET':
                with lock: return self.reply(200, roster())
            if method == 'GET': return self.reply(200, {})
            return self.reply(404, {'detail': 'Not Found'})

        def auth_post(self, path, body):
            # The base handler reads the body itself; ours is already read, so the sign-in is answered here.
            if path == '/auth/password-login':
                with gateway.lock: gateway.counts['passwordPosts'] += 1
                if body.get('username') == gateway.username and body.get('password') == gateway.password:
                    token = secrets.token_urlsafe(24)
                    gateway.sessions.add(token)
                    if gateway.hermes: self.set_cookies = gateway.issue()
                    with gateway.lock: gateway.counts['logins'] += 1
                    return self.reply(200, {'ok': True}, cookie=token)
                return self.reply(401, {'detail': 'invalid credentials'})
            if path == '/auth/logout': return self.reply(200, {'ok': True})
            return self.reply(404, {'detail': 'not in this stand-in'})

        def do_GET(self): self.serve('GET')
        def do_HEAD(self): self.serve('GET')
        def do_POST(self): self.serve('POST')
        def do_PATCH(self): self.serve('PATCH')
        def do_DELETE(self): self.serve('DELETE')
        def do_PUT(self): self.serve('PUT')

    return Handler


# ---- Listeners --------------------------------------------------------------------------------------------

class Listener(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler_class):
        self.open = set()
        super().__init__(address, handler_class)

    def get_request(self):
        connection, address = super().get_request()
        self.open.add(connection)
        return connection, address

    def shutdown_request(self, request):
        self.open.discard(request)
        super().shutdown_request(request)

    def cut(self):
        for connection in list(self.open):
            try: connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass


SERVER = {'gateway': None, 'address': None, 'handler': None}
server_lock = threading.Lock()


def start_gateway():
    with server_lock:
        if SERVER['gateway'] is not None: return
        server = Listener(SERVER['address'], SERVER['handler'])
        SERVER['gateway'] = server
        threading.Thread(target=server.serve_forever, kwargs={'poll_interval': 0.05}, daemon=True).start()


def stop_gateway():
    """Connection refused from now on: the listener closes and every open connection is cut."""
    with server_lock:
        server = SERVER['gateway']
        if server is None: return
        SERVER['gateway'] = None
        server.shutdown(); server.server_close(); server.cut()
    drop_sockets()


def busy(port):
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.settimeout(0.3)
        return probe.connect_ex(('127.0.0.1', port)) == 0
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=9980)
    parser.add_argument('--control-port', type=int)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--hermes-cookies', action='store_true')
    parser.add_argument('--access-ttl', type=int, default=12 * 60 * 60)
    parser.add_argument('--start-down', action='store_true', help='the gateway port does not listen until told `up`')
    parser.add_argument('--delay-ticket', type=float, default=0)
    parser.add_argument('--roster-delay', type=float, default=0)
    parser.add_argument('--no-change-events', action='store_true')
    parser.add_argument('--changed-on-ready', action='store_true')
    parser.add_argument('--label', default='')
    parser.add_argument('--bots', type=int, default=5)
    parser.add_argument('--sessions', type=int, default=20)
    args = parser.parse_args()
    control_port = args.control_port or args.port + 1
    for port in (args.port, control_port):
        if not 9980 <= port <= 9989 and os.environ.get('HQN_ANY_PORT') != '1':
            sys.exit(f'Port {port} is outside 9980-9989 (set HQN_ANY_PORT=1 to allow it).')
        if busy(port): sys.exit(f'Port {port} is in use; this stand-in never shares a port.')
    OPTIONS.update({'label': args.label, 'delay_ticket': args.delay_ticket, 'roster_delay': args.roster_delay,
                    'change_events': not args.no_change_events, 'changed_on_ready': args.changed_on_ready})
    DEFAULTS.update(OPTIONS)
    seed(args.bots, args.sessions)
    username, password = 'offline-fixture', secrets.token_urlsafe(24)
    target = pathlib.Path(args.credentials)
    if args.keep_credentials and target.exists():
        kept = json.loads(target.read_text()); username, password = kept['username'], kept['password']
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{args.port}',
                   'control': f'http://127.0.0.1:{control_port}'}, output)
    gateway = auth.Gateway(username, password, True, None, hermes=args.hermes_cookies, access_ttl=args.access_ttl)
    SERVER['address'] = ('127.0.0.1', args.port)
    SERVER['handler'] = handler(gateway)
    if args.start_down: MODE['mode'] = 'refuse'
    else: start_gateway()
    control = Listener(('127.0.0.1', control_port), handler(gateway, control_only=True))
    print(f'Offline stand-in on 127.0.0.1:{args.port} (controls on {control_port})', flush=True)
    try: control.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt: pass


if __name__ == '__main__': main()
