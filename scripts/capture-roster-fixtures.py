#!/usr/bin/env python3
"""Capture roster / sessions payloads from a stand-in gateway as unit-test fixtures (stdlib only).

Signs in once with the fixture's own credentials file, opens /api/ws with a ticket, and saves the `result` of
profiles.list (full) and the Bot Chat title lookup, plus the REST sidebar answer, as JSON files.

  python3 scripts/capture-roster-fixtures.py --base http://127.0.0.1:9715 --credentials <scratch>/demo.json \
      --out Tests/Fixtures --prefix demo

Loopback fixtures only. Never point it at a real gateway (it signs in once; no retries).
"""
import argparse, base64, http.client, json, os, socket, struct, sys, urllib.parse

def http_json(base, method, path, body=None, cookie=None):
    url = urllib.parse.urlparse(base)
    conn = http.client.HTTPConnection(url.hostname, url.port, timeout=30)
    headers = {'Content-Type': 'application/json'}
    if cookie: headers['Cookie'] = cookie
    conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
    res = conn.getresponse()
    data = res.read()
    return res.status, res.getheader('Set-Cookie'), data

class WS:
    def __init__(self, base, path, cookie):
        url = urllib.parse.urlparse(base)
        self.sock = socket.create_connection((url.hostname, url.port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f'GET {path} HTTP/1.1\r\nHost: {url.hostname}:{url.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
               f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nCookie: {cookie}\r\n\r\n')
        self.sock.sendall(req.encode())
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = self.sock.recv(1)
            if not chunk: raise RuntimeError('socket closed during handshake')
            head += chunk
        if b' 101 ' not in head.split(b'\r\n')[0]: raise RuntimeError(head.decode(errors='replace'))
        self.next_id = 1

    def _read(self, n):
        out = b''
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk: raise RuntimeError('socket closed')
            out += chunk
        return out

    def recv(self):
        parts = b''
        while True:
            b1, b2 = self._read(2)
            fin, op, n = b1 & 0x80, b1 & 0x0F, b2 & 0x7F
            if n == 126: n = struct.unpack('>H', self._read(2))[0]
            elif n == 127: n = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if b2 & 0x80 else None
            data = self._read(n)
            if mask: data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
            if op == 8: raise RuntimeError('closed by server')
            if op in (9, 10): continue
            parts += data
            if fin: return json.loads(parts.decode())

    def send(self, obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        head = bytes([0x81])
        n = len(data)
        if n < 126: head += bytes([0x80 | n])
        elif n < 65536: head += bytes([0x80 | 126]) + struct.pack('>H', n)
        else: head += bytes([0x80 | 127]) + struct.pack('>Q', n)
        self.sock.sendall(head + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))

    def call(self, method, params):
        rid = self.next_id; self.next_id += 1
        self.send({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params})
        while True:
            frame = self.recv()
            if frame.get('id') == rid:
                if 'error' in frame: raise RuntimeError(f'{method}: {frame["error"]}')
                return frame['result']

RECENTS_EXCLUDE = 'acp,cron,kanban,oneshot,subagent,telegram,discord,slack,mattermost,matrix,signal,whatsapp,bluebubbles,photon,homeassistant,email,sms,webhook,api_server,weixin,wecom,qqbot,yuanbao,dingtalk,feishu'
MESSAGING_EXCLUDE = 'cron,acp,cli,codex,desktop,gateway,kanban,local,tui'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True)
    ap.add_argument('--credentials', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--prefix', required=True)
    ap.add_argument('--bot', default='deploys', help='profile whose Bot Chat title lookup is captured')
    args = ap.parse_args()
    host = urllib.parse.urlparse(args.base).hostname
    if host not in ('127.0.0.1', 'localhost', '::1'): sys.exit('loopback fixtures only')
    creds = json.load(open(args.credentials))
    status, set_cookie, body = http_json(args.base, 'POST', '/auth/password-login',
                                         {'provider': 'fake', 'username': creds['username'], 'password': creds['password']})
    if status != 200: sys.exit(f'sign-in failed: {status} {body[:200]!r}')
    cookie = set_cookie.split(';')[0]
    status, _, body = http_json(args.base, 'POST', '/api/auth/ws-ticket', {}, cookie)
    ticket = json.loads(body)['ticket']
    ws = WS(args.base, f'/api/ws?profile=default&ticket={urllib.parse.quote(ticket)}', cookie)
    ready = ws.recv()
    os.makedirs(args.out, exist_ok=True)
    def save(name, value):
        path = os.path.join(args.out, f'{args.prefix}-{name}.json')
        with open(path, 'w') as f: json.dump(value, f, indent=1, ensure_ascii=False, sort_keys=True)
        print('saved', path)
    save('gateway-ready', ready)
    save('profiles-list', ws.call('profiles.list', {}))
    # No slim capture: the stand-in gateways ignore include_sessions, so their "slim" answer is the full one.
    # Tests build a real slim answer from the full one (BotsTest.slimmed drops the session fields).
    save('session-list-bot-chat', ws.call('session.list', {'profile': args.bot, 'title': 'Bot Chat', 'limit': 200, 'include_hidden': True}))
    query = urllib.parse.urlencode({'recents_profile': 'all', 'recents_limit': 50, 'cron_limit': 50, 'messaging_limit': 100,
                                    'recents_exclude': RECENTS_EXCLUDE, 'messaging_exclude': MESSAGING_EXCLUDE, 'profile': 'default'})
    status, _, body = http_json(args.base, 'GET', f'/api/profiles/sessions/sidebar?{query}', cookie=cookie)
    if status != 200: sys.exit(f'sidebar failed: {status}')
    save('sidebar', json.loads(body))

if __name__ == '__main__':
    main()
