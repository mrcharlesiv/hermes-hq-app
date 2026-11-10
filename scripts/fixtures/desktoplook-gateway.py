#!/usr/bin/env python3
"""Stand-in gateway for the desktoplook stream (docs/spec/3x-desktoplook.md §11.1).

The settings fixture (bots, sections, chats with code and tables, skills, config) plus the two file routes the
"Hermes HQ Themes for Desktop" installer uses. Nothing is written to disk: a written file is kept in memory.

  POST /api/files/mkdir     {path}            200 {"ok":true,"path":…,"entry":{…}}   (401 without the session)
  POST /api/fs/write-text   {path, content}   200 {"ok":true,"path":…,"byteSize":n} | 400 parent missing | 413 too large
  GET  /__look/state                          {"calls":[…],"files":{path:{bytes,sha256}}}
  POST /__look/fail  {"route":"mkdir"|"write","status":401|403|404|409|500|"drop"|"slow"|"html"|"empty"|"text"|"rpc"|"notok" (the last five answer 200 with a body that is not Hermes's),"count":N}
  POST /__look/reset
RPC: session.branch_stored {parent_session_id} and session.branch {session_id, count} make a new chat of that bot.
Arguments are the settings fixture's: --port --credentials [--label] [--hermes-cookies] [--access-ttl].
"""
import copy, hashlib, importlib.util, json, pathlib, secrets, threading, time

_spec = importlib.util.spec_from_file_location('settings_fixture', pathlib.Path(__file__).parent / 'settings-gateway.py')
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

LOCK = threading.Lock()
LOOK = {'calls': [], 'files': {}, 'folders': set(), 'fail': {}}
MAX_BYTES = 8 * 1024 * 1024
BROKEN = {
    'html': (b'<html><body><h1>502 Bad Gateway</h1></body></html>', 'text/html'),
    'empty': (b'', 'application/json'),
    'text': (b'OK', 'text/plain'),
    'rpc': (b'{"jsonrpc":"2.0","id":null,"error":{"code":4000,"message":"no"}}', 'application/json'),
    'notok': (b'{"ok":false}', 'application/json'),
}
_base_handler = base.handler


def handler(gateway):
    parent = _base_handler(gateway)

    class Handler(parent):
        def _json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try:
                return json.loads(raw or b'{}')
            except ValueError:
                return None

        def _failure(self, route):
            """True when a planned failure answered (or dropped) the request."""
            with LOCK:
                plan = LOOK['fail'].get(route)
                if not plan or plan['count'] <= 0:
                    return False
                plan['count'] -= 1
                status = plan['status']
            if status == 'drop':
                try:
                    self.connection.shutdown(2)
                except OSError:
                    pass
                self.connection.close()
                return True
            if status == 'slow':
                time.sleep(20)
                return False
            if status in BROKEN:
                # A 200 that is not Hermes's answer (a proxy's page, an empty body, an error object): nothing is stored.
                raw, kind = BROKEN[status]
                self.send_response(200)
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return True
            self.reply(int(status), {'detail': 'A file already exists at that path' if status == 409 else 'planned failure'})
            return True

        def do_GET(self):
            if self.path.split('?')[0] == '/__look/state':
                with LOCK:
                    return self.reply(200, {'calls': list(LOOK['calls']), 'files': dict(LOOK['files'])})
            return super().do_GET()

        def do_POST(self):
            path = self.path.split('?')[0]
            if path == '/__look/reset':
                self._json()
                with LOCK:
                    LOOK.update({'calls': [], 'files': {}, 'folders': set(), 'fail': {}})
                return self.reply(200, {'ok': True})
            if path == '/__look/fail':
                body = self._json() or {}
                with LOCK:
                    LOOK['fail'][body.get('route')] = {'status': body.get('status'), 'count': int(body.get('count') or 1)}
                return self.reply(200, {'ok': True})
            if path not in ('/api/files/mkdir', '/api/fs/write-text'):
                return super().do_POST()
            body = self._json()
            if not self.authed(path):
                with LOCK:
                    LOOK['calls'].append({'route': 'mkdir' if path.endswith('mkdir') else 'write', 'status': 401})
                return
            route = 'mkdir' if path.endswith('mkdir') else 'write'
            if self._failure(route):
                with LOCK:
                    LOOK['calls'].append({'route': route, 'status': 'failed'})
                return
            if not isinstance(body, dict) or not isinstance(body.get('path'), str):
                return self.reply(422, {'detail': 'path must be a string'})
            target = body['path']
            if route == 'mkdir':
                extra = sorted(k for k in body if k != 'path')
                with LOCK:
                    LOOK['folders'].add(target)
                    LOOK['calls'].append({'route': 'mkdir', 'path': target, 'extraKeys': extra, 'status': 200})
                return self.reply(200, {'ok': True, 'path': target, 'entry': {'name': target.rsplit('/', 1)[-1], 'type': 'directory'}})
            content = body.get('content')
            if not isinstance(content, str):
                return self.reply(422, {'detail': 'content must be a string'})
            data = content.encode()
            with LOCK:
                known = target.rsplit('/', 1)[0] in LOOK['folders']
            if not known:
                return self.reply(400, {'detail': 'Parent directory does not exist'})
            if len(data) > MAX_BYTES:
                return self.reply(413, {'detail': 'Content too large'})
            digest = hashlib.sha256(data).hexdigest()
            with LOCK:
                LOOK['files'][target] = {'bytes': len(data), 'sha256': digest}
                LOOK['calls'].append({'route': 'write', 'path': target, 'bytes': len(data), 'sha256': digest,
                                      'extraKeys': sorted(k for k in body if k not in ('path', 'content')), 'status': 200})
            return self.reply(200, {'ok': True, 'path': target, 'byteSize': len(data)})

    return Handler


base.handler = handler

_base_rpc = base.rpc


def rpc(method, params):
    """Mac stress round 2 #49: Branch in New Chat. The settings fixture had no `session.branch_stored` /
    `session.branch`, so both fell through to the voice fixture's `{}` and the app said "Hermes answered the branch in
    a shape this app doesn't read". A branch is a new chat of the same bot holding the parent's messages (all of them,
    or the first `count` that say something, as the app counts), answered as Hermes does."""
    if method not in ('session.branch_stored', 'session.branch'):
        return _base_rpc(method, params)
    parent = params.get('parent_session_id') if method == 'session.branch_stored' else params.get('session_id')
    with base.LOCK:
        name, chat = base.find_chat(parent)
        if not chat:
            raise base.RPCFailure(4007, 'session not found')
        rows = chat['messages']
        if method == 'session.branch':
            rows = [m for m in rows if m.get('role') in ('user', 'assistant') and m.get('content')]
            count = int(params.get('count') or 0)
            if count <= 0 or count > len(rows):
                raise base.RPCFailure(4002, f'count out of range: {count}')
            rows = rows[:count]
        stored = time.strftime('%Y%m%d_%H%M%S_') + secrets.token_hex(4)
        now = time.time()
        base.S['profiles'][name]['extra_chats'].append({'id': stored, 'title': chat['title'], 'messages': copy.deepcopy(rows),
                                                        'last_active': now, 'started_at': now})
    return {'session_id': base.runtime_id(stored), 'stored_session_id': stored, 'message_count': len(rows)}


base.rpc = rpc

if __name__ == '__main__':
    base.main()
