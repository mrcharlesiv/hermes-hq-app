"""More › Webhooks (docs/spec/3x-morepages.md §13): the receiver and its subscriptions.

Invented data only. The receiver is off at seed with --webhooks-off (and has no subscriptions), else on with three.
Create answers the route plus a random `secret`, once.

  POST /__fixture/webhooks  {"create": 409}            the next create answers 409 (the name is taken); 500 likewise; 0 clears
                            {"count": 300}             that many subscriptions (with one repeated name) instead of three
                            {"restart_started": bool}  what enable says about the gateway restarting (default false)
                            {"empty": true}            no subscriptions
GET /__fixture/state → "webhooks": {"enabled", "names", "created": [{"name","keys","secret"}], "knobs"}
(`created` keeps each secret so a test can compare it with what Copy put on the pasteboard.)
"""
import re, secrets, time

NEW = True
REST_PREFIXES = ('/api/webhooks',)

STATE = {'enabled': True, 'routes': {}}
KNOBS = {}
CREATED = []

def route(description='', events=(), skills=(), deliver='log', deliver_only=False, prompt='', enabled=True,
          created_at='2026-10-01T08:30:00Z'):
    return {'description': description, 'events': list(events), 'skills': list(skills), 'deliver': deliver,
            'deliver_only': deliver_only, 'prompt': prompt, 'enabled': enabled, 'secret': 'seeded', 'created_at': created_at}

def seed():
    KNOBS.clear(); KNOBS.update(create=0, count=None, restart_started=False, empty=False)
    del CREATED[:]
    STATE['enabled'] = not ctx.webhooks_off
    STATE['routes'] = {} if ctx.webhooks_off else {
        'github-push': route('Runs the release checks when the main branch moves.', ['push', 'pull_request'], ['release-checks'],
                             'telegram', prompt='Summarise what changed and say whether the checks passed.'),
        'invoice-paid': route('', [], [], 'log'),
        'status-page': route('Posts incidents from the status page to the team.', ['incident.created'], [], 'slack',
                             deliver_only=True, enabled=False),
    }

def base_url(): return f'http://127.0.0.1:{ctx.port}'

def summary(name, item):
    return {'name': name, 'description': item.get('description', ''), 'events': list(item.get('events') or []),
            'deliver': item.get('deliver', 'log'), 'deliver_only': bool(item.get('deliver_only')), 'prompt': item.get('prompt', ''),
            'script': '', 'skills': list(item.get('skills') or []), 'created_at': item.get('created_at'),
            'url': f'{base_url()}/webhooks/{name}', 'secret_set': bool(item.get('secret')),
            'enabled': item.get('enabled', True) is not False}

def routes():
    if KNOBS.get('empty'): return {}
    count = KNOBS.get('count')
    if count and len(STATE['routes']) < int(count):
        for index in range(len(STATE['routes']), int(count)):
            STATE['routes'][f'hook-{index:03d}'] = route(f'Invented subscription {index}.' if index % 3 else '',
                                                        ['push'] if index % 2 else [], [], ('log', 'telegram', 'email')[index % 3],
                                                        enabled=index % 4 != 0)
    return STATE['routes']

def rest(method, path, query, body, handler):
    body = body if isinstance(body, dict) else {}
    with ctx.lock:
        if path == '/api/webhooks' and method == 'GET':
            rows = [summary(name, item) for name, item in routes().items()]
            if KNOBS.get('count') and rows: rows.append(dict(rows[0]))      # one repeated name
            return 200, {'enabled': STATE['enabled'], 'base_url': base_url(), 'subscriptions': rows}
        if path == '/api/webhooks/enable' and method == 'POST':
            STATE['enabled'] = True
            started = bool(KNOBS.get('restart_started'))
            ctx.wrote('webhooks', 'enable')
            return 200, {'ok': True, 'platform': 'webhook', 'enabled': True, 'needs_restart': not started, 'restart_started': started}
        if path == '/api/webhooks' and method == 'POST':
            if KNOBS.get('create'):
                status = int(KNOBS['create']); KNOBS['create'] = 0
                return status, {'detail': 'Subscription changed while it was being saved.' if status == 409 else 'Internal server error'}
            if not STATE['enabled']:
                return 400, {'detail': 'Webhook platform is not enabled. Enable it from the Webhooks page first.'}
            name = (body.get('name') or '').strip().lower().replace(' ', '-')
            if not re.match(r'^[a-z0-9][a-z0-9_-]*$', name):
                return 400, {'detail': 'Invalid name. Use lowercase alphanumeric with hyphens/underscores.'}
            if body.get('deliver_only') and (body.get('deliver') or 'log') == 'log':
                return 400, {'detail': "Direct delivery requires a real target (telegram, discord, …), not 'log'."}
            secret = secrets.token_urlsafe(32)
            item = {'description': body.get('description') or f'Dashboard-created subscription: {name}',
                    'events': [e.strip() for e in body.get('events') or [] if e.strip()], 'secret': secret,
                    'prompt': body.get('prompt') or '', 'skills': [s.strip() for s in body.get('skills') or [] if s.strip()],
                    'deliver': body.get('deliver') or 'log', 'created_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
            if body.get('deliver_only'): item['deliver_only'] = True
            if body.get('deliver_chat_id'): item['deliver_extra'] = {'chat_id': body['deliver_chat_id']}
            STATE['routes'][name] = item
            CREATED.append({'name': name, 'keys': sorted(body), 'secret': secret})
            ctx.wrote('webhooks', 'create', name=name, keys=sorted(body))
            return 200, dict(summary(name, item), secret=secret)
        match = re.fullmatch(r'/api/webhooks/([^/]+)(/enabled)?', path)
        if match:
            from urllib.parse import unquote
            name = unquote(match.group(1)).strip().lower()
            if name not in STATE['routes']: return 404, {'detail': f"No subscription named '{name}'"}
            if method == 'DELETE' and not match.group(2):
                del STATE['routes'][name]
                ctx.wrote('webhooks', 'delete', name=name)
                return 200, {'ok': True}
            if method == 'PUT' and match.group(2):
                STATE['routes'][name]['enabled'] = bool(body.get('enabled'))
                ctx.wrote('webhooks', 'enabled', name=name, enabled=bool(body.get('enabled')), keys=sorted(body))
                return 200, {'ok': True, 'name': name, 'enabled': bool(body.get('enabled'))}
    return None

def control(path, body):
    if path != '/__fixture/webhooks': return None
    with ctx.lock:
        for key in ('create', 'count', 'restart_started', 'empty'):
            if key in body: KNOBS[key] = body[key]
        return {'ok': True, 'knobs': dict(KNOBS)}

def state():
    return {'enabled': STATE['enabled'], 'names': sorted(STATE['routes']),
            'off': sorted(name for name, item in STATE['routes'].items() if item.get('enabled', True) is False),
            'created': list(CREATED), 'knobs': dict(KNOBS)}
