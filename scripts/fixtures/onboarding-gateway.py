#!/usr/bin/env python3
"""[onboarding] The settings fixture (scripts/fixtures/settings-gateway.py: password sign-in, bots, chats, the socket)
with a `GET /api/status` the tests control, for the version check after a typed sign-in and the "Update Hermes on Your
Gateway" screen (docs/spec/3x-onboarding.md §5.14, §5.15, §8). Loaded by path; nothing there is edited. Loopback only,
invented data.

  GET  /api/status        {"version","release_date","can_update_hermes","auth_required","auth_providers":["basic"],
                           "auth_flows":["cookie"],"desktop_contract":8}
                          A read without the session cookie (the form's probe) always answers plainly; a read with it
                          (the version check) follows the mode below.
Controls (no auth, never under /api/):
  POST /__onboarding/status  any of: release_date, version, can_update_hermes (a JSON null removes the key; any JSON
                             value is sent as given), mode: ok | slow | 500 | garbage | drop, delay_ms (for slow),
                             count (how many authed reads the mode lasts; default: until changed),
                             raw (a string sent as the whole 200 body), pad_bytes (adds that much padding to the JSON)
  GET  /__onboarding/state   {"status_reads":{"public":n,"authed":n},"logins":n,"login_bodies":[[key names]…],
                             "status":{…},"mode":…}: key names of each login body only, never values
  POST /__onboarding/lists   {"delay_ms": n}: every signed-in read but the status (the lists, the socket) waits that
                             long before it is answered, so the launch screen after a typed sign-in can be seen
                             (-1: 60 s, as good as never for a test). The state shows it as "lists_delay_ms"
  POST /__onboarding/reset   back to the start-up values, counters zeroed

  python3 scripts/fixtures/onboarding-gateway.py --port 9990 --credentials build/fixtures/onboarding-a.json
  python3 scripts/fixtures/onboarding-gateway.py --port 9991 --label Beta --credentials build/fixtures/onboarding-b.json \\
          --release-date 2026.9.10
"""
import copy, importlib.util, io, json, pathlib, sys, threading, time
from urllib.parse import urlparse

_spec = importlib.util.spec_from_file_location('hqn_onboarding_settings', pathlib.Path(__file__).resolve().parent / 'settings-gateway.py')
settings = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(settings)

LOCK = threading.Lock()
START = {'version': '0.21.5', 'release_date': '2026.10.01', 'can_update_hermes': True, 'auth_required': True,
         'auth_providers': ['basic'], 'auth_flows': ['cookie'], 'desktop_contract': 8}
O = {}


def reset():
    O.clear()
    O.update({'status': copy.deepcopy(START), 'mode': 'ok', 'delay_ms': 0, 'count': None, 'raw': None, 'pad_bytes': 0,
              'reads': {'public': 0, 'authed': 0}, 'logins': 0, 'login_bodies': [], 'lists_delay_ms': 0})


_settings_handler = settings.handler


def handler(gateway):
    parent = _settings_handler(gateway)

    class Handler(parent):
        def onboarding_body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try:
                value = json.loads(raw or b'{}')
            except ValueError:
                value = {}
            return value if isinstance(value, dict) else {}

        def send_raw(self, status, data, kind='application/json'):
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__onboarding/state':
                with LOCK:
                    return self.reply(200, {'status_reads': dict(O['reads']), 'logins': O['logins'],
                                            'login_bodies': list(O['login_bodies']), 'status': O['status'], 'mode': O['mode'],
                                            'lists_delay_ms': O['lists_delay_ms']})
            if path != '/api/status':
                if path.startswith('/api/') and not path.startswith('/api/auth/') and self.session():
                    with LOCK:
                        hold = O['lists_delay_ms']
                    if hold:
                        time.sleep(60 if hold < 0 else hold / 1000)
                return super().do_GET()
            authed = bool(self.session())
            with LOCK:
                O['reads']['authed' if authed else 'public'] += 1
                body = copy.deepcopy(O['status'])
                mode, delay, raw, pad = ('ok', 0, None, 0)
                if authed:
                    mode, delay, raw, pad = O['mode'], O['delay_ms'], O['raw'], O['pad_bytes']
                    if O['count'] is not None and mode != 'ok':
                        O['count'] -= 1
                        if O['count'] <= 0:
                            O['mode'], O['count'] = 'ok', None
            if mode == 'slow':
                time.sleep(max(0, delay) / 1000)
            if mode == 'drop':
                self.close_connection = True
                try:
                    self.connection.shutdown(2)
                except OSError:
                    pass
                return
            if mode == '500':
                return self.reply(500, {'detail': 'status unavailable'})
            if mode == 'garbage':
                return self.send_raw(200, b'<html>not json</html>', 'text/html')
            if raw is not None:
                return self.send_raw(200, str(raw).encode())
            if pad:
                body['padding'] = 'x' * int(pad)
            try:
                return self.reply(200, body)
            except (BrokenPipeError, ConnectionResetError):
                return

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__onboarding/status':
                change = self.onboarding_body()
                with LOCK:
                    for key in ('release_date', 'version', 'can_update_hermes'):
                        if key in change:
                            if change[key] is None:
                                O['status'].pop(key, None)
                            else:
                                O['status'][key] = change[key]
                    if 'mode' in change:
                        O['mode'] = str(change['mode'])
                        O['count'] = None
                    if 'delay_ms' in change:
                        O['delay_ms'] = int(change['delay_ms'])
                    if 'count' in change:
                        O['count'] = int(change['count']) if change['count'] is not None else None
                    if 'raw' in change:
                        O['raw'] = change['raw']
                    if 'pad_bytes' in change:
                        O['pad_bytes'] = int(change['pad_bytes'])
                return self.reply(200, {'ok': True})
            if path == '/__onboarding/lists':
                change = self.onboarding_body()
                with LOCK:
                    O['lists_delay_ms'] = int(change.get('delay_ms') or 0)
                return self.reply(200, {'ok': True})
            if path == '/__onboarding/reset':
                self.onboarding_body()
                with LOCK:
                    reset()
                return self.reply(200, {'ok': True})
            if path == '/auth/password-login':
                # Key names only (never a value), then the settings fixture's own sign-in reads the same bytes.
                raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
                try:
                    keys = sorted(json.loads(raw or b'{}').keys())
                except (ValueError, AttributeError):
                    keys = []
                with LOCK:
                    O['logins'] += 1
                    O['login_bodies'].append(keys)
                self.rfile = io.BytesIO(raw)
            return super().do_POST()

    return Handler


settings.handler = handler

if __name__ == '__main__':
    if '--release-date' in sys.argv:
        at = sys.argv.index('--release-date')
        START['release_date'] = sys.argv[at + 1]
        del sys.argv[at:at + 2]
    reset()
    settings.main()
