#!/usr/bin/env python3
"""Capture real chat payloads from the loopback stand-in gateways for the chat-data unit tests.

Talks only to 127.0.0.1 fixtures (spec 05 Part A): the performance fixture and, when it runs, the Plaid stress
gateway. Signs in ONCE per gateway (never in a loop), records REST pages and raw WebSocket frames, and writes them
to Tests/Fixtures/chat/. All content is synthetic. Stdlib only.

  python3 scripts/capture-chat-fixtures.py --perf-port 9717 --perf-creds <perf.json> \
      [--plaid-port 9716 --plaid-creds <plaid.json>] --out Tests/Fixtures/chat
"""
import argparse, base64, json, os, pathlib, socket, struct, time, urllib.request, urllib.error


class Gateway:
    def __init__(self, port, creds):
        self.base = f'http://127.0.0.1:{port}'
        self.port = port
        c = json.loads(pathlib.Path(creds).read_text())
        self.cookie = None
        self.login(c['username'], c['password'])

    def request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None: req.add_header('Content-Type', 'application/json')
        if self.cookie: req.add_header('Cookie', self.cookie)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read(); headers = r.headers
        except urllib.error.HTTPError as e:
            raise SystemExit(f'{method} {path} -> HTTP {e.code}: {e.read()[:200]!r}')
        return raw, headers

    def login(self, username, password):
        raw, headers = self.request('POST', '/auth/password-login', {'provider': 'basic', 'username': username, 'password': password})
        cookies = [h.split(';', 1)[0] for h in headers.get_all('Set-Cookie') or []]
        self.cookie = '; '.join(cookies)

    def get_json(self, path):
        return json.loads(self.request('GET', path)[0])

    def ws(self):
        ticket = json.loads(self.request('POST', '/api/auth/ws-ticket', {})[0]).get('ticket', '')
        return WS(self.port, f'/api/ws?ticket={ticket}', self.cookie)


class WS:
    def __init__(self, port, path, cookie):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
               f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nCookie: {cookie}\r\n\r\n')
        self.sock.sendall(req.encode())
        head = b''
        while b'\r\n\r\n' not in head:
            head += self.sock.recv(1)
        assert b' 101 ' in head.split(b'\r\n')[0], head
        self.next_id = 1
        self.frames = []

    def _read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk: raise ConnectionError('eof')
            data += chunk
        return data

    def recv(self, timeout=30):
        self.sock.settimeout(timeout)
        buf = bytearray()
        while True:
            first, second = self._read(2)
            opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126: n = struct.unpack('>H', self._read(2))[0]
            elif n == 127: n = struct.unpack('>Q', self._read(8))[0]
            payload = self._read(n)
            if opcode == 9: self._send(0xA, payload); continue
            if opcode in (1, 0): buf.extend(payload)
            if opcode == 8: raise ConnectionError('closed')
            if final and opcode in (0, 1):
                frame = json.loads(bytes(buf)); self.frames.append(frame); return frame

    def _send(self, opcode, body):
        mask = os.urandom(4)
        n = len(body)
        header = bytes([0x80 | opcode]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack('>H', n) if n < 65536 else bytes([0x80 | 127]) + struct.pack('>Q', n))
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(body)))

    def send(self, method, params):
        rid = self.next_id; self.next_id += 1
        frame = {'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}
        self.frames.append({'_sent': frame})
        self._send(1, json.dumps(frame).encode())
        return rid

    def call(self, method, params, timeout=30):
        rid = self.send(method, params)
        while True:
            f = self.recv(timeout)
            if f.get('id') == rid: return f

    def until(self, predicate, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            f = self.recv(max(0.5, end - time.time()))
            if predicate(f): return f
        raise TimeoutError('frame not seen')


def resume_params(stored, profile):
    return {'session_id': stored, 'cols': 96, 'source': 'desktop', 'defer_history': True, 'omit_messages': True, 'profile': profile}


def write(out, name, value):
    path = out / name
    path.write_text(json.dumps(value, indent=1, ensure_ascii=False) + '\n')
    print(f'  {name}: {path.stat().st_size:,} bytes')


def clip_big_strings(value, limit):
    if isinstance(value, str): return value if len(value) <= limit else value[:limit] + f'\n[fixture: clipped {len(value) - limit} chars]'
    if isinstance(value, list): return [clip_big_strings(v, limit) for v in value]
    if isinstance(value, dict): return {k: clip_big_strings(v, limit) for k, v in value.items()}
    return value


def capture_perf(port, creds, out):
    print(f'performance fixture :{port}')
    g = Gateway(port, creds)
    stored = '20260929_120000_aabbcc01'
    ws = g.ws()
    ready = ws.recv()
    write(out, 'chat-perf-gateway-ready.json', ready)
    resume = ws.call('session.resume', resume_params(stored, 'default'))
    write(out, 'perf-resume.json', resume)
    rid = resume['result']['session_id']
    g.request('POST', '/__fixture/history', {'profile': 'default', 'count': 300, 'non_dense': True})
    q = 'profile=default&limit=24&order=latest&include_compacted=true'
    write(out, 'perf-page-latest-24.json', g.get_json(f'/api/sessions/{stored}/messages?{q}'))
    write(out, 'perf-page-older.json', g.get_json(f'/api/sessions/{stored}/messages?profile=default&limit=97&offset=23&order=latest&include_compacted=true'))
    write(out, 'perf-page-probe-1.json', g.get_json(f'/api/sessions/{stored}/messages?profile=default&limit=1&order=latest&include_compacted=true'))

    # A scripted streaming turn with interleaved tool calls.
    g.request('POST', '/__fixture/plan', {'plans': [{'chunks': ['Let me ', 'run ', 'three ', 'steps. ', 'All ', 'done.'], 'tools': 3,
                                                     'toolBytes': 300, 'chunkDelay': 0.04}]})
    ws.frames = []
    ws.send('prompt.submit', {'session_id': rid, 'text': 'Run three steps', 'profile': 'default'})
    ws.until(lambda f: f.get('params', {}).get('type') == 'message.complete')
    write(out, 'perf-turn-frames.json', ws.frames)
    write(out, 'perf-page-after-turn.json', g.get_json(f'/api/sessions/{stored}/messages?{q}'))

    # Stop mid-stream.
    g.request('POST', '/__fixture/plan', {'plans': [{'chunks': [f'word{i} ' for i in range(200)], 'chunkDelay': 0.03}]})
    ws.frames = []
    ws.send('prompt.submit', {'session_id': rid, 'text': 'Write a long answer', 'profile': 'default'})
    deltas = 0
    while deltas < 10:
        f = ws.recv()
        if f.get('params', {}).get('type') == 'message.delta': deltas += 1
    rid_stop = ws.send('session.interrupt', {'session_id': rid, 'profile': 'default'})
    ws.until(lambda f: f.get('id') == rid_stop)
    end = time.time() + 1.0
    while time.time() < end:
        try: ws.recv(timeout=max(0.1, end - time.time()))
        except (socket.timeout, TimeoutError): break
    write(out, 'perf-stop-frames.json', ws.frames)

    # Explicit refusal (busy) as the gateway sends it.
    g.request('POST', '/__fixture/plan', {'plans': [{'reject': 'session busy', 'code': 4009}]})
    ws.frames = []
    ws.call('prompt.submit', {'session_id': rid, 'text': 'Are you there?', 'profile': 'default'})
    write(out, 'perf-reject-4009-frames.json', ws.frames)
    ws.frames = []
    write(out, 'perf-active-list.json', ws.call('session.active_list', {}))


def capture_plaid(port, creds, out):
    print(f'Plaid gateway :{port}')
    g = Gateway(port, creds)
    stored = '20260101_090000_aa0001aa'
    q = 'profile=default&limit=24&order=latest&include_compacted=true'
    page = g.get_json(f'/api/sessions/{stored}/messages?{q}')
    write(out, 'plaid-page-latest-24.json', page)
    write(out, 'plaid-page-older.json', clip_big_strings(
        g.get_json(f'/api/sessions/{stored}/messages?profile=default&limit=97&offset=23&order=latest&include_compacted=true'), 16000))
    ws = g.ws()
    ready = ws.recv()
    write(out, 'plaid-gateway-ready.json', ready)
    resume = ws.call('session.resume', resume_params(stored, 'default'))
    write(out, 'plaid-resume.json', resume)
    rid = resume['result']['session_id']
    g.request('GET', '/__plaid/opts?minutes=0.12&subagents=0&browser=0&vault=0')
    ws.frames = []
    ws.send('prompt.submit', {'session_id': rid, 'text': 'Finish the Plaid setup.', 'profile': 'default'})
    ws.until(lambda f: f.get('params', {}).get('type') == 'message.complete', timeout=120)
    frames = [f for f in ws.frames if f.get('params', {}).get('type') != 'sessions.changed' or True]
    write(out, 'plaid-turn-frames.json', clip_big_strings(frames, 16000))
    seqs = [f['params']['seq'] for f in frames if isinstance(f.get('params'), dict) and 'seq' in f['params']]
    middle = seqs[len(seqs) // 2] if seqs else 0
    since = ws.call('session.events.since', {'session_id': rid, 'last_seen': middle, 'profile': 'default'})
    write(out, 'plaid-events-since.json', clip_big_strings(since, 16000))
    write(out, 'plaid-page-after-turn.json', clip_big_strings(g.get_json(f'/api/sessions/{stored}/messages?{q}'), 16000))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--perf-port', type=int, default=9717)
    ap.add_argument('--perf-creds', required=True)
    ap.add_argument('--plaid-port', type=int)
    ap.add_argument('--plaid-creds')
    ap.add_argument('--out', default='Tests/Fixtures/chat')
    a = ap.parse_args()
    out = pathlib.Path(a.out); out.mkdir(parents=True, exist_ok=True)
    capture_perf(a.perf_port, a.perf_creds, out)
    if a.plaid_port and a.plaid_creds: capture_plaid(a.plaid_port, a.plaid_creds, out)


if __name__ == '__main__':
    main()
