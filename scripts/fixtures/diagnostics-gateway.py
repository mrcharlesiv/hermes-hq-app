#!/usr/bin/env python3
"""Stand-in gateway for the diagnostics stream (docs/spec/3x-diagnostics.md §8, §14).

The settings fixture (scripts/fixtures/settings-gateway.py: password sign-in, bots, chat socket, config) with the
performance-log routes answered by the real sink code. POST /api/plugins/hermes-hq-push/logs and /logs/moment run
scripts/fixture-support/perf_logs.py (byte for byte the hermes-hq-push plugin's perf_logs.py, 0.8) against --log-dir,
after the same shape checks the plugin's routes make (device at most 40 characters, at most 4000 lines, an 8-16 hex
marker), so what the app sends is cleaned, limited and written exactly as on a real computer. Nothing here reads or
writes ~/.hermes.

Controls (no auth, loopback only):
  GET  /__diagnostics/state   {"uploads": [{reason, lines, dropped, status, kinds}], "moments": [...], "files": {...},
                               "events": {kind: count}, "dirty": [...], "page_crashes": [what, ...]}  (files and events are read back from --log-dir;
                               dirty lists any written event that carries a blocked field name or a long string)
  POST /__diagnostics/fail    {"status": 500, "times": 2}   the next uploads answer this status (back-off tests)

  python3 scripts/fixtures/diagnostics-gateway.py --port 10070 --credentials build/fixtures/diagnostics.json \\
      --log-dir build/fixtures/hq-logs
"""
import importlib.util, json, pathlib, re, sys, threading
from urllib.parse import urlparse

HERE = pathlib.Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


settings = load('settings_gateway', HERE / 'settings-gateway.py')
perf_logs = load('hermes_hq_perf_logs', HERE.parent / 'fixture-support' / 'perf_logs.py')

LOCK = threading.Lock()
D = {'uploads': [], 'moments': [], 'fail': {'status': 0, 'times': 0}}
LOG_DIR = pathlib.Path('build/fixtures/hq-logs')
MARKER = re.compile(r'^[0-9a-f]{8,16}$')
SETTINGS_HANDLER = settings.handler


def read_back():
    files, events, dirty, crashes = {}, {}, [], []
    for path in sorted(LOG_DIR.glob('*/*.jsonl')):
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        files[f'{path.parent.name}/{path.name}'] = len(rows)
        for row in rows:
            events[row.get('k')] = events.get(row.get('k'), 0) + 1
            if row.get('k') == 'page.crash':
                crashes.append(row.get('what', ''))
            for key, value in row.items():
                if key.lower() in perf_logs.BLOCKED or (isinstance(value, str) and len(value) > perf_logs.MAX_STRING):
                    dirty.append({'k': row.get('k'), 'field': key})
    moments = sorted(f'{p.parent.parent.name}/moments/{p.name}' for p in LOG_DIR.glob('*/moments/*.json'))
    return files, events, dirty, moments, crashes


def handler(gateway):
    base = SETTINGS_HANDLER(gateway)

    class Handler(base):
        def do_GET(self):
            if urlparse(self.path).path == '/__diagnostics/state':
                with LOCK:
                    files, events, dirty, moments, crashes = read_back()
                    return self.reply(200, {'uploads': D['uploads'], 'moments': D['moments'], 'files': files, 'events': events,
                                            'dirty': dirty, 'page_crashes': crashes, 'moment_files': moments, 'log_dir': str(LOG_DIR)})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__diagnostics/fail':
                body = self.body()
                with LOCK:
                    D['fail'] = {'status': int(body.get('status') or 500), 'times': int(body.get('times') or 1)}
                return self.reply(200, {'ok': True})
            if path not in ('/api/plugins/hermes-hq-push/logs', '/api/plugins/hermes-hq-push/logs/moment'):
                return super().do_POST()
            if not self.authed(path):
                return
            body = self.body()
            with LOCK:
                if D['fail']['times'] > 0:
                    D['fail']['times'] -= 1
                    D['uploads'].append({'reason': body.get('reason'), 'status': D['fail']['status']})
                    return self.reply(D['fail']['status'], {'detail': 'fixture failure'})
                device, app = body.get('device'), body.get('app', '')
                # The plugin's request models (dashboard/plugin_api.py LogsIn / MomentIn) refuse these before the sink runs.
                if not isinstance(device, str) or len(device) > 40 or not isinstance(app, str) or len(app) > 40:
                    return self.reply(422, {'detail': 'Invalid body.'})
                try:
                    if path.endswith('/moment'):
                        marker = body.get('marker')
                        if not isinstance(marker, str) or not MARKER.fullmatch(marker) or not isinstance(body.get('bundle', {}), dict):
                            return self.reply(422, {'detail': 'Invalid body.'})
                        result = perf_logs.write_moment(LOG_DIR, device, marker, body.get('bundle', {}), app=app)
                        D['moments'].append({'marker': marker, 'status': 200})
                        return self.reply(200, result)
                    lines = body.get('lines', [])
                    reason = body.get('reason', '')
                    if not isinstance(lines, list) or len(lines) > perf_logs.MAX_LINES or any(not isinstance(l, str) for l in lines) \
                            or not isinstance(reason, str) or len(reason) > 40 or not isinstance(body.get('lost', False), bool):
                        return self.reply(422, {'detail': 'Invalid body.'})
                    result = perf_logs.write(LOG_DIR, device, lines, app=app, reason=reason, lost=body.get('lost', False))
                    kinds = []
                    for line in lines:
                        try:
                            kinds.append(json.loads(line).get('k'))
                        except (ValueError, AttributeError):
                            kinds.append(None)
                    D['uploads'].append({'reason': reason, 'lines': result['lines'], 'dropped': result['dropped'], 'status': 200,
                                         'device': device, 'app': app, 'kinds': kinds})
                    # The settings fixture's own record, so its tests read the same uploads.
                    settings.S['logs'].append({'reason': reason, 'count': len(lines), 'kinds': kinds})
                    return self.reply(200, result)
                except perf_logs.LogError as error:
                    D['uploads'].append({'reason': body.get('reason'), 'status': error.status_code})
                    return self.reply(error.status_code, {'detail': error.detail})

    return Handler


def main():
    global LOG_DIR
    if '--log-dir' in sys.argv:
        at = sys.argv.index('--log-dir')
        LOG_DIR = pathlib.Path(sys.argv[at + 1]).resolve()
        del sys.argv[at:at + 2]
    home = pathlib.Path.home() / '.hermes'
    if home in LOG_DIR.parents or LOG_DIR == home:
        sys.exit('refusing to write under ~/.hermes')
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    settings.handler = handler          # the settings fixture's main() serves this stream's handler
    settings.main()


if __name__ == '__main__':
    main()
