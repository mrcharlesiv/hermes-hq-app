#!/usr/bin/env python3
"""HQ Native notifications fixture: REF's performance fixture plus a stand-in for the hermes-hq-push plugin (routes as
gateway-plugin/hermes-hq-push/dashboard/plugin_api.py, build 240). Loopback only; every value is invented; it never
talks to Apple or the push relay. Delivery is `xcrun simctl push` to the simulator the test names (unsealed payloads:
simctl never runs the notification extension, whose work is unit-tested instead).

Plugin routes (cookie session, as the app's other REST calls):
  GET    /api/plugins/hermes-hq-push/status            {plugin: ready|missing|outdated} decides 200 / 404 / old body
  PUT    /api/plugins/hermes-hq-push/devices/<id>      registration (token, environment, topic, kinds, previews, seal, account)
  DELETE /api/plugins/hermes-hq-push/devices/<id>
  POST   /api/plugins/hermes-hq-push/approvals/<id>    {session_key, choice: once|deny, token} -> {ok, resolved}
  POST   /api/plugins/hermes-hq-push/logs              accepted and dropped
  /api/plugins/dispatch-push/...                       the old name: answers only while plugin == "outdated"
Fixture control:
  POST /__fixture/push  {plugin?, manager?, version?}   manager (plugins.manage): "" answers nothing (as before), "none" is an
                        unknown method (a Hermes too old for plugins), "reload" installs and the routes come up at once,
                        "restart" installs with restart_required (the routes wait for a restart: set plugin "ready")
                        version: the newest add-on out, what an install gets (default CURRENT; [addon-progress] an
                        older one is "not out yet" for the app, and the install leaves the plugin outdated)
  GET  /__fixture/push  {devices, removed, approvals, calls}
  POST /__fixture/push/reset
  POST /__fixture/push/deliver  {kind: turnDone|approval, profile, text?, request?}  -> xcrun simctl push to --sim/--bundle
[device-access] hermes-hq-push 0.9.21's Device Access routes (device_access.py), the phone's side:
  PUT    /api/plugins/hermes-hq-push/device-access/<id>                what the phone shares {access, account, name, platform}
  DELETE /api/plugins/hermes-hq-push/device-access/<id>
  POST   /api/plugins/hermes-hq-push/device-access/<id>/pending        {requests: [{id, op, args, created, profile}]}
                                                                       (handed out until answered, as the add-on)
  POST   /api/plugins/hermes-hq-push/device-access/<id>/files/<rid>    a photo before its answer {type, name, data: base64}
  POST   /api/plugins/hermes-hq-push/device-access/<id>/results/<rid>  {status, result, error}
  POST /__fixture/device  {op, args, wake?, profile?}  queues a bot's request for the phone that shares; wake: a silent
                          push (kind "device") through simctl. -> {id}
  GET  /__fixture/device  {shares, forgotten, requests: {id: {status, result, error, fetched, file?}}} (file: {type, name,
                          bytes, jpeg}, never the picture)
  POST /__fixture/device/setup  {grants?, location?, photo?}: grants the app Contacts (and each simctl privacy service in
                          `grants`, e.g. reminders, calendar, photos, location-always) on the simulator, adds the invented
                          contact "Ann Fixture" once, sets the simulator's location ("41.8781,-87.6298") and adds one
                          invented photo (photo: true). Before the app launches: a grant can end a running app.
"""
import hashlib, importlib.util, json, os, pathlib, re, subprocess, sys, tempfile, threading
from urllib.parse import urlparse

REF = pathlib.Path('/Users/me/Projects/hermes-hq-native-ref238/scripts')
_spec = importlib.util.spec_from_file_location('hqn_push_perf', REF / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)
base = perf.base
ROUTE = '/api/plugins/hermes-hq-push'
LEGACY = '/api/plugins/dispatch-push'
LOCK = threading.RLock()
SIM = {'udid': None, 'bundle': None}
TOKEN = 'f' * 64     # the action token the fixture puts in approval alerts


# The add-on version the app asks for (PushPolicy.wantedVersion / everyBotVersion): a "ready" plugin reports it.
CURRENT = '0.9.52'


def fresh_state():
    return {'plugin': 'missing', 'manager': '', 'version': CURRENT, 'installed': None, 'devices': {}, 'removed': [], 'approvals': [], 'calls': [], 'manage': [],
            'shares': {}, 'forgotten': [], 'requests': {}}


STATE = fresh_state()


def status_body(old=False):
    if old:
        return {'ok': True, 'version': 2, 'kinds': ['turnDone', 'approval'], 'seal': True, 'delivery': 'Relay'}
    return {'ok': True, 'version': 6, 'plugin': 'hermes-hq-push', 'pluginVersion': CURRENT, 'delivery': 'Relay', 'tasks': True,
            'kinds': ['turnDone', 'approval'], 'seal': True, 'replies': 'watcher', 'desktopThemes': True, 'ownChats': True, 'quietStandIns': True, 'desktopOpens': True, 'askCards': True, 'pagePreviews': True, 'warmup': True, 'desktopForward': True, 'gatewayLogins': True, 'namedSites': True,
            'restartGuard': True, 'perfLogs': True, 'moments': True, 'deviceAccess': True, 'deviceAccessKinds': True, 'liveSteps': True, 'liveEnds': True, 'liveQuick': True, 'terminal': True, 'terminalOff': False, 'draftCards': True, 'pluginUpdates': True, 'draftCardsShown': True,
            'devices': len(STATE['devices'])}


def payload(body):
    """An alert as the plugin builds it (push.Push.payload), unsealed, for simctl."""
    kind = body.get('kind', 'turnDone')
    profile = body.get('profile', 'ivy')
    session = base.voice.SIDS.get(profile, base.voice.SIDS['default'])
    name = 'Hermes' if profile == 'default' else profile.capitalize()
    with LOCK:
        account = next((d.get('account') for d in STATE['devices'].values() if d.get('account')), '')
    dispatch = {'kind': kind, 'session': session, 'profile': profile}
    if account:
        dispatch['account'] = account
    aps = {'sound': 'default', 'interruption-level': 'active', 'thread-id': session}
    if kind == 'approval':
        request = body.get('request', 'req_fixture_1')
        command = body.get('text', 'npm run deploy')
        aps.update({'alert': {'title': name, 'body': 'Wants to run: ' + command}, 'relevance-score': 1.0, 'category': 'DISPATCH_APPROVAL'})
        dispatch.update({'request': request, 'sessionKey': 'agent:main:fixture:' + profile, 'token': TOKEN})
    else:
        aps.update({'alert': {'title': name, 'body': body.get('text', 'The fixture reply is ready.')}, 'relevance-score': 0.6})
    return {'Simulator Target Bundle': SIM['bundle'], 'aps': aps, 'dispatch': dispatch}


def simctl_push(body):
    """One payload to the simulator the fixture was started with: (ok, stderr)."""
    if not SIM['udid'] or not SIM['bundle']:
        return False, 'start the fixture with --sim and --bundle'
    with tempfile.NamedTemporaryFile('w', suffix='.apns', delete=False) as handle:
        json.dump(body, handle)
        name = handle.name
    try:
        done = subprocess.run(['xcrun', 'simctl', 'push', SIM['udid'], SIM['bundle'], name], capture_output=True, text=True, timeout=30)
    finally:
        os.unlink(name)
    return done.returncode == 0, done.stderr[-300:]


# [device-access] An invented person for the lookup (every value made up).
ADDED = {'contact': False}
FIXTURE_CONTACT = """BEGIN:VCARD
VERSION:3.0
N:Fixture;Ann;;;
FN:Ann Fixture
ORG:Fixture Works
TEL;TYPE=CELL:+1 555 0100
EMAIL;TYPE=HOME:ann@fixture.example
BDAY:1990-05-12
ADR;TYPE=HOME:;;1 Fixture Way;Springfield;IL;62701;USA
END:VCARD
"""


def device_setup(body=None):
    """Contacts (and `grants`) allowed for the app (before it launches: a grant can end a running app), Ann Fixture
    added once, the simulator's location set and an invented photo added when asked."""
    body = body or {}
    if not SIM['udid'] or not SIM['bundle']:
        return 409, {'detail': 'start the fixture with --sim and --bundle'}
    errors = []
    for service in ['contacts'] + [g for g in body.get('grants') or [] if re.fullmatch(r'[a-z-]{3,30}', str(g))]:
        granted = subprocess.run(['xcrun', 'simctl', 'privacy', SIM['udid'], 'grant', service, SIM['bundle']],
                                 capture_output=True, text=True, timeout=30)
        if granted.returncode != 0:
            errors.append(service + ': ' + granted.stderr[-200:])
    if re.fullmatch(r'-?\d+(\.\d+)?,-?\d+(\.\d+)?', str(body.get('location') or '')):
        placed = subprocess.run(['xcrun', 'simctl', 'location', SIM['udid'], 'set', body['location']],
                                capture_output=True, text=True, timeout=30)
        if placed.returncode != 0:
            errors.append('location: ' + placed.stderr[-200:])
    if body.get('photo') and not ADDED.get('photo'):
        with tempfile.TemporaryDirectory() as folder:
            png = pathlib.Path(folder) / 'fixture.png'
            jpg = pathlib.Path(folder) / 'fixture-photo.jpg'
            # An invented 64x48 picture: one flat colour, made here, never a real photo.
            import struct, zlib
            rows = b''.join(b'\x00' + bytes((40, 120, 200)) * 64 for _ in range(48))
            chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
            png.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 48, 8, 2, 0, 0, 0))
                            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
            subprocess.run(['sips', '-s', 'format', 'jpeg', str(png), '--out', str(jpg)], capture_output=True, timeout=30)
            added = subprocess.run(['xcrun', 'simctl', 'addmedia', SIM['udid'], str(jpg)], capture_output=True, text=True,
                                   timeout=30)
        if added.returncode != 0:
            errors.append('photo: ' + added.stderr[-200:])
        else:
            ADDED['photo'] = True
    grant = subprocess.CompletedProcess([], 1 if errors else 0, '', '; '.join(errors))
    if not ADDED['contact']:
        with tempfile.NamedTemporaryFile('w', suffix='.vcf', delete=False) as handle:
            handle.write(FIXTURE_CONTACT)
            name = handle.name
        try:
            added = subprocess.run(['xcrun', 'simctl', 'addmedia', SIM['udid'], name], capture_output=True, text=True, timeout=30)
        finally:
            os.unlink(name)
        if added.returncode != 0:
            return 500, {'detail': 'addmedia failed', 'stderr': added.stderr[-300:]}
        ADDED['contact'] = True
    return (200 if grant.returncode == 0 else 500), {'ok': grant.returncode == 0, 'stderr': grant.stderr[-300:]}


_perf_handler = base.handler


def handler(gateway):
    parent = _perf_handler(gateway)

    class Handler(parent):
        def body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            return json.loads(raw or b'{}')

        def plugin(self, method):
            parsed = urlparse(self.path)
            path = parsed.path
            legacy = path.startswith(LEGACY + '/')
            if not (legacy or path.startswith(ROUTE + '/')):
                return False
            body = self.body() if method in ('PUT', 'POST') else {}
            route = path[len(LEGACY if legacy else ROUTE):]
            with LOCK:
                STATE['calls'].append({'method': method, 'route': route, 'legacy': legacy})
                plugin = STATE['plugin']
            if not self.session():
                self.reply(401, {'detail': 'unauthorized'}); return True
            if (legacy and plugin != 'outdated') or (not legacy and plugin != 'ready'):
                self.reply(404, {'detail': 'Not Found'}); return True
            if method == 'GET' and route == '/status':
                self.reply(200, status_body(old=legacy)); return True
            if route == '/logs' or route == '/logs/moment':
                self.reply(200, {'ok': True}); return True
            device = re.fullmatch(r'/devices/([A-Za-z0-9-]{8,64})', route)
            if device and method == 'PUT':
                ok = (re.fullmatch(r'[0-9a-f]{64,200}', str(body.get('token', '')).lower())
                      and body.get('environment') in ('sandbox', 'production') and body.get('topic'))
                if not ok:
                    self.reply(400, {'detail': 'Invalid device registration.'}); return True
                record = {k: body.get(k) for k in ('environment', 'topic', 'profile', 'kinds', 'previews', 'account')}
                record['token'] = hashlib.sha256(str(body.get('token')).encode()).hexdigest()[:12]   # never kept whole
                record['sealKeyBytes'] = len(__import__('base64').b64decode(body.get('seal') or ''))
                with LOCK:
                    STATE['devices'][device.group(1)] = record
                self.reply(200, {'ok': True}); return True
            if device and method == 'DELETE':
                with LOCK:
                    removed = STATE['devices'].pop(device.group(1), None) is not None
                    STATE['removed'].append(device.group(1))
                self.reply(200, {'ok': True, 'removed': removed}); return True
            if self.device_access(method, route, body):
                return True
            approval = re.fullmatch(r'/approvals/([A-Za-z0-9_-]{1,128})', route)
            if approval and method == 'POST':
                if body.get('token') != TOKEN:
                    self.reply(403, {'detail': "This notification can't answer that request."}); return True
                if body.get('choice') not in ('once', 'deny'):
                    self.reply(422, {'detail': 'Invalid approval choice.'}); return True
                with LOCK:
                    first = not any(a['request'] == approval.group(1) for a in STATE['approvals'])
                    STATE['approvals'].append({'request': approval.group(1), 'choice': body.get('choice'),
                                               'session_key': body.get('session_key')})
                self.reply(200, {'ok': True, 'resolved': 1 if first else 0}); return True
            self.reply(404, {'detail': 'Not Found'})
            return True

        def device_access(self, method, route, body):
            """[device-access] The phone's side of device_access.py; False when the route isn't one of these."""
            share = re.fullmatch(r'/device-access/([A-Za-z0-9-]{8,64})', route)
            pending = re.fullmatch(r'/device-access/([A-Za-z0-9-]{8,64})/pending', route)
            result = re.fullmatch(r'/device-access/([A-Za-z0-9-]{8,64})/results/([0-9a-f]{32})', route)
            upload = re.fullmatch(r'/device-access/([A-Za-z0-9-]{8,64})/files/([0-9a-f]{32})', route)
            with LOCK:
                if share and method == 'PUT':
                    STATE['shares'][share.group(1)] = {k: body.get(k) for k in ('access', 'account', 'name', 'platform')}
                    self.reply(200, {'ok': True, 'access': body.get('access')}); return True
                if share and method == 'DELETE':
                    removed = STATE['shares'].pop(share.group(1), None) is not None
                    STATE['forgotten'].append(share.group(1))
                    self.reply(200, {'ok': True, 'removed': removed}); return True
                if pending and method == 'POST':
                    waiting = [{'id': rid, 'op': r['op'], 'args': r['args'], 'created': r['created'], 'profile': r['profile']}
                               for rid, r in STATE['requests'].items() if r['device'] == pending.group(1) and r['status'] == 'pending']
                    for item in waiting:
                        STATE['requests'][item['id']]['fetched'] += 1
                    self.reply(200, {'requests': waiting}); return True
                if upload and method == 'POST':
                    request = STATE['requests'].get(upload.group(2))
                    if request is None or request['device'] != upload.group(1):
                        self.reply(404, {'detail': 'No such request for this device.'}); return True
                    if request['op'] != 'photos.get' or body.get('type') not in ('image/jpeg', 'image/png'):
                        self.reply(400, {'detail': 'This request takes no file.'}); return True
                    try:
                        raw = __import__('base64').b64decode(body.get('data') or '', validate=True)
                    except ValueError:
                        self.reply(400, {'detail': 'Invalid file data.'}); return True
                    request['file'] = {'type': body.get('type'), 'name': body.get('name', ''), 'bytes': len(raw),
                                       'jpeg': raw[:3] == b'\xff\xd8\xff'}
                    self.reply(200, {'ok': True, 'accepted': True}); return True
                if result and method == 'POST':
                    request = STATE['requests'].get(result.group(2))
                    if request is None or request['device'] != result.group(1):
                        self.reply(404, {'detail': 'No such request for this device.'}); return True
                    if request['status'] != 'pending':
                        self.reply(200, {'ok': True, 'accepted': False, 'status': request['status']}); return True
                    request.update(status=body.get('status'), result=body.get('result'), error=body.get('error', ''))
                    self.reply(200, {'ok': True, 'accepted': True, 'status': request['status']}); return True
            return False

        def do_GET(self):
            if self.plugin('GET'):
                return
            if urlparse(self.path).path == '/__fixture/device':
                with LOCK:
                    return self.reply(200, {k: STATE[k] for k in ('shares', 'forgotten', 'requests')})
            if urlparse(self.path).path == '/__fixture/push':
                with LOCK:
                    return self.reply(200, {k: STATE[k] for k in ('plugin', 'manager', 'devices', 'removed', 'approvals', 'calls', 'manage')})
            return super().do_GET()

        def do_PUT(self):
            if self.plugin('PUT'):
                return
            self.reply(404, {'detail': 'Not Found'})

        def do_DELETE(self):
            if self.plugin('DELETE'):
                return
            return super().do_DELETE()

        def do_POST(self):
            if self.plugin('POST'):
                return
            path = urlparse(self.path).path
            if path == '/__fixture/push':
                body = self.body()
                with LOCK:
                    if body.get('plugin') in ('ready', 'missing', 'outdated'):
                        STATE['plugin'] = body['plugin']
                    if body.get('manager') in ('', 'none', 'reload', 'restart'):
                        STATE['manager'] = body['manager']
                    if isinstance(body.get('version'), str):
                        STATE['version'] = body['version']
                return self.reply(200, {'ok': True})
            if path == '/__fixture/push/reset':
                self.body()
                with LOCK:
                    STATE.clear(); STATE.update(fresh_state())
                return self.reply(200, {'ok': True})
            if path == '/__fixture/device/setup':
                return self.reply(*device_setup(self.body()))
            if path == '/__fixture/device':
                body = self.body()
                with LOCK:
                    device = next(iter(STATE['shares']), None)
                    if device is None:
                        return self.reply(409, {'detail': 'no phone shares anything'})
                    rid = os.urandom(16).hex()
                    STATE['requests'][rid] = {'device': device, 'op': body.get('op', 'contacts.search'), 'args': body.get('args') or {},
                                              'created': __import__('time').time(), 'status': 'pending', 'result': None,
                                              'error': '', 'fetched': 0, 'profile': body.get('profile', 'default')}
                delivered = None
                if body.get('wake'):
                    wake = {'Simulator Target Bundle': SIM['bundle'], 'aps': {'content-available': 1},
                            'dispatch': {'kind': 'device', 'request': rid, 'profile': STATE['requests'][rid]['profile'], 'settled': True}}
                    ok, err = simctl_push(wake)
                    delivered = 'silent'
                    if not ok and 'no user visible content' in err:
                        # Some simulators refuse a silent push (UNErrorDomain 1401): the same wake-up with words on it
                        # still reaches application(_:didReceiveRemoteNotification:fetchCompletionHandler:).
                        wake['aps']['alert'] = {'title': 'Fixture', 'body': 'Device Access wake-up'}
                        ok, err = simctl_push(wake)
                        delivered = 'visible'
                    if not ok:
                        return self.reply(500, {'id': rid, 'stderr': err})
                return self.reply(200, {'id': rid, 'delivered': delivered})
            if path == '/__fixture/push/deliver':
                body = self.body()
                if not SIM['udid'] or not SIM['bundle']:
                    return self.reply(409, {'detail': 'start the fixture with --sim and --bundle'})
                with tempfile.NamedTemporaryFile('w', suffix='.apns', delete=False) as handle:
                    json.dump(payload(body), handle)
                    name = handle.name
                try:
                    done = subprocess.run(['xcrun', 'simctl', 'push', SIM['udid'], SIM['bundle'], name], capture_output=True, text=True, timeout=30)
                finally:
                    os.unlink(name)
                return self.reply(200 if done.returncode == 0 else 500, {'ok': done.returncode == 0, 'stderr': done.stderr[-300:]})
            return super().do_POST()
    return Handler


base.handler = handler

# plugins.manage, as the manager mode says (the app installs hermes-hq-push itself before asking the bot).
_rpc = base.rpc      # the socket handler calls this module global by name
def push_rpc(method, params):
    if method != 'plugins.manage':
        return _rpc(method, params)
    with LOCK:
        mode = STATE['manager']
        STATE['manage'].append({k: v for k, v in params.items()})
        if mode == '':
            return _rpc(method, params)
        if mode == 'none':
            raise ValueError('unknown method: plugins.manage')
        action = params.get('action')
        if action == 'list':
            have = STATE['installed'] or ('0.6.0' if STATE['plugin'] == 'outdated' else CURRENT)
            rows = [] if STATE['plugin'] == 'missing' and not STATE['installed'] else [{'name': 'hermes-hq-push', 'key': 'hermes-hq-push', 'version': have,
                                                             'source': 'git', 'status': 'enabled'}]
            return {'plugins': rows}
        if action == 'install':
            STATE['installed'] = STATE['version']
            # Only the version the app asks for brings the routes up as current; an older one stays outdated.
            if mode == 'reload':
                STATE['plugin'] = 'ready' if STATE['version'] == CURRENT else 'outdated'
            return {'ok': True, 'plugin_name': 'hermes-hq-push', 'restart_required': mode == 'restart', 'gateway_reloaded': False}
        return {'ok': True}
base.rpc = push_rpc

if __name__ == '__main__':
    for flag in ('--sim', '--bundle'):
        if flag in sys.argv:
            at = sys.argv.index(flag)
            SIM[flag[2:] if flag == '--bundle' else 'udid'] = sys.argv[at + 1]
            del sys.argv[at:at + 2]
    base.main()
