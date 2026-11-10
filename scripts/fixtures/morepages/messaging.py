"""More › Messaging (docs/spec/3x-morepages.md §12): platforms, pairing and the Telegram onboarding flow.

Invented data only. Four platforms per bot: Chirp (connected), Telegram (not set up), Pigeon Post (off), Semaphore
(an error). Key writes are kept (a set key answers `is_set` and a redacted preview; the value itself is never answered).

  POST /__fixture/messaging  {"hot_served": bool}          PUT answers hot_served (default false: a restart is needed)
                             {"test": {"ok","message"}}    the next Test answers this (null: by the platform's state)
                             {"platforms": 40}             that many platforms (with one repeated id) instead of four
                             {"pending": 500}              that many people waiting on Chirp (with one repeated person)
                             {"expires_in": 3}             Telegram links expire after that many seconds (default 600)
                             {"restart_started": bool}     what Telegram apply says about the gateway restarting
  POST /__fixture/telegram   {"status":"ready","bot_username":"demo_bot","owner_user_id":"42"}   every open pairing turns ready
GET /__fixture/state → "messaging": {"platforms", "pairing", "telegram": {"started","cancelled","applied"}, "knobs"}
"""
import copy, datetime, re, secrets, time

NEW = True
REST_PREFIXES = ('/api/messaging', '/api/pairing')

def var(key, prompt, description='', password=False, required=False, advanced=False, url=None):
    return {'key': key, 'prompt': prompt, 'description': description, 'is_password': password, 'required': required,
            'advanced': advanced, 'url': url}

CATALOG = [
    {'id': 'chirp', 'name': 'Chirp', 'description': 'Short messages with your bots, from any phone.',
     'docs_url': 'https://example.com/docs/chirp', 'runtime': 'connected',
     'env_vars': [var('CHIRP_BOT_TOKEN', 'Bot Token', 'The token Chirp gives you when you make a bot.', password=True, required=True,
                      url='https://example.com/chirp/bots'),
                  var('CHIRP_ALLOWED_USERS', 'Allowed Chirp User IDs', 'Recommended. Comma-separated Chirp user IDs.'),
                  var('CHIRP_PROXY', 'Proxy URL', 'Only needed on networks where Chirp is blocked.', advanced=True),
                  var('CHIRP_HOME_CHANNEL', 'Home Channel ID', 'Where the bot sends reminders and scheduled results.', advanced=True)]},
    {'id': 'telegram', 'name': 'Telegram', 'description': 'Chat with your bots in Telegram.',
     'docs_url': 'https://example.com/docs/telegram', 'runtime': None,
     'env_vars': [var('TELEGRAM_BOT_TOKEN', 'Bot Token', 'Create a bot with @BotFather, then paste the token it gives you.',
                      password=True, required=True, url='https://example.com/telegram/botfather'),
                  var('TELEGRAM_ALLOWED_USERS', 'Allowed Telegram User IDs',
                      'Recommended. Comma-separated numeric IDs. Without this, anyone can message your bot.'),
                  var('TELEGRAM_PROXY', 'Proxy URL', 'Only needed on networks where Telegram is blocked.', advanced=True)]},
    {'id': 'pigeon', 'name': 'Pigeon Post', 'description': 'Slow, reliable, and fond of seeds.',
     'docs_url': 'https://example.com/docs/pigeon', 'runtime': None,
     'env_vars': [var('PIGEON_LOFT_KEY', 'Loft Key', 'The key of the loft your pigeons return to.', password=True, required=True)]},
    {'id': 'semaphore', 'name': 'Semaphore', 'description': 'Flags on a hill, for teams that can see each other.',
     'docs_url': '', 'runtime': 'fatal', 'error_message': 'Sign-in was refused. Check the bot token.',
     'env_vars': [var('SEMAPHORE_TOKEN', 'Bot Token', 'From the Semaphore developer page.', password=True, required=True),
                  var('SEMAPHORE_HILL', 'Hill Name', 'The hill the flags are shown on.')]},
]
SEED_ENV = {'chirp': {'CHIRP_BOT_TOKEN': 'chp-seed-0000-token-9f2a', 'CHIRP_ALLOWED_USERS': '1001,1002'},
            'pigeon': {'PIGEON_LOFT_KEY': 'loft-seed-key-0001'},
            'semaphore': {'SEMAPHORE_TOKEN': 'sem-seed-token-0002', 'SEMAPHORE_HILL': 'north'}}
SEED_ENABLED = {'chirp': True, 'telegram': False, 'pigeon': False, 'semaphore': True}

STORES = {}      # profile -> {"env": {platform: {KEY: value}}, "enabled": {platform: bool}, "pending": [...], "approved": [...]}
KNOBS = {}
TELEGRAM = {}    # pairing_id -> {"profile","status","bot_username","owner_user_id","expires"}
LOG = {'started': [], 'cancelled': [], 'applied': []}

def seed():
    STORES.clear(); KNOBS.clear(); TELEGRAM.clear()
    KNOBS.update(hot_served=False, test=None, platforms=None, pending=None, expires_in=600, restart_started=False)
    for key in LOG: LOG[key] = []

def store(profile):
    profile = profile or 'default'
    if profile not in STORES:
        STORES[profile] = {
            'env': copy.deepcopy(SEED_ENV), 'enabled': dict(SEED_ENABLED),
            'pending': [{'platform': 'chirp', 'user_id': '2001', 'user_name': 'Ada Byron', 'request_id': 'req-2001', 'age_minutes': 12},
                        {'platform': 'chirp', 'user_id': '2002', 'user_name': 'Grace Hopper', 'request_id': 'req-2002', 'age_minutes': 0}],
            'approved': [{'platform': 'chirp', 'user_id': '1001', 'user_name': 'Alan Turing'}],
        }
    return STORES[profile]

def catalog():
    count = KNOBS.get('platforms')
    if not count: return CATALOG
    rows = list(CATALOG)
    for index in range(len(CATALOG), int(count)):
        rows.append({'id': f'app-{index:02d}', 'name': f'Messaging App {index:02d}', 'description': 'An invented messaging app.',
                     'docs_url': '', 'runtime': None,
                     'env_vars': [var(f'APP_{index:02d}_TOKEN', 'Bot Token', password=True, required=True)]})
    return rows + [dict(rows[0])]      # one repeated id: the list must show it once

def entry(platform_id): return next((e for e in catalog() if e['id'] == platform_id), None)

def redacted(value):
    if not value: return None
    return f'{value[:3]}…{value[-4:]}' if len(value) >= 12 else '…'

def payload(item, profile):
    data = store(profile)
    env = data['env'].get(item['id'], {})
    env_vars = [dict(v, is_set=bool(env.get(v['key'])), redacted_value=redacted(env.get(v['key']))) for v in item['env_vars']]
    configured = all(v['is_set'] for v in env_vars if v['required'])
    enabled = bool(data['enabled'].get(item['id'], False))
    state, error = item.get('runtime'), item.get('error_message')
    if not enabled: state, error = 'disabled', None
    elif not configured: state, error = 'not_configured', None
    elif not state: state = 'pending_restart'
    return {'id': item['id'], 'name': item['name'], 'description': item['description'], 'docs_url': item['docs_url'],
            'enabled': enabled, 'configured': configured, 'gateway_running': True, 'state': state,
            'error_code': 'auth_failed' if error else None, 'error_message': error,
            'updated_at': '2026-10-13T09:00:00Z' if item.get('runtime') else None, 'home_channel': None, 'ingress_url': None,
            'env_vars': env_vars}

def pairing(profile):
    data = store(profile)
    pending = list(data['pending'])
    count = KNOBS.get('pending')
    if count:
        pending = [{'platform': 'chirp', 'user_id': str(5000 + n), 'user_name': f'Person {n:03d}', 'request_id': f'req-{5000 + n}',
                    'age_minutes': n} for n in range(int(count))]
        pending = [p for p in pending if p['user_id'] not in {a['user_id'] for a in data['approved']}]
        if pending: pending.append(dict(pending[0]))      # one repeated person
    return {'pending': pending, 'approved': list(data['approved'])}

def iso(seconds): return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).isoformat(timespec='seconds')

def rest(method, path, query, body, handler):
    profile = ctx.one(query, 'profile')
    body = body if isinstance(body, dict) else {}
    with ctx.lock:
        if path == '/api/messaging/platforms' and method == 'GET':
            return 200, {'platforms': [payload(item, profile) for item in catalog()]}

        match = re.fullmatch(r'/api/messaging/platforms/([^/]+)(/test)?', path)
        if match:
            item = entry(match.group(1))
            if not item: return 404, {'detail': f'Unknown messaging platform: {match.group(1)}'}
            if match.group(2) and method == 'POST':
                if KNOBS.get('test'): return 200, dict(KNOBS['test'])
                now = payload(item, profile)
                def result(ok, message): return 200, {'ok': ok, 'state': now['state'], 'message': message}
                if not now['enabled']: return result(False, f"{item['name']} is disabled. Enable it, then restart the gateway.")
                if not now['configured']:
                    missing = [v['key'] for v in now['env_vars'] if v['required'] and not v['is_set']]
                    return result(False, f"Missing required setup: {', '.join(missing)}")
                if now['state'] == 'connected': return result(True, f"{item['name']} is connected.")
                if now.get('error_message'): return result(False, now['error_message'])
                return result(False, 'Setup looks complete, but the gateway has not reported a connection yet. Restart the gateway.')
            if not match.group(2) and method == 'PUT':
                allowed = {v['key'] for v in item['env_vars']}
                env, clear = body.get('env') or {}, body.get('clear_env') or []
                for key in list(env) + list(clear):
                    if key not in allowed: return 400, {'detail': f"{key} is not configurable for {item['name']}"}
                data = store(body.get('profile') or profile)
                kept = data['env'].setdefault(item['id'], {})
                for key in clear: kept.pop(key, None)
                for key, value in env.items():
                    if str(value).strip(): kept[key] = str(value).strip()
                if body.get('enabled') is not None: data['enabled'][item['id']] = bool(body['enabled'])
                # Names only: a key's value is never recorded here.
                ctx.wrote('messaging', 'platform.update', platform=item['id'], profile=profile or 'default',
                          keys=sorted(body), env=sorted(env), clear_env=sorted(clear), enabled=body.get('enabled'))
                answer = {'ok': True, 'platform': item['id']}
                if KNOBS.get('hot_served'): answer['hot_served'] = True
                return 200, answer

        if path == '/api/pairing' and method == 'GET':
            return 200, pairing(profile)
        if path == '/api/pairing/approve' and method == 'POST':
            target = body.get('profile') or 'default'
            platform, request = (body.get('platform') or '').lower().strip(), (body.get('request_id') or '').strip()
            if not platform or not request: return 400, {'detail': 'platform and request_id or code are required'}
            person = next((p for p in pairing(target)['pending'] if p['platform'] == platform and p['request_id'] == request), None)
            if not person:
                return 404, {'detail': f"Pairing request or code not found or expired for platform '{platform}'."}
            data = store(target)
            data['pending'] = [p for p in data['pending'] if p['request_id'] != request]
            user = {'platform': platform, 'user_id': person['user_id'], 'user_name': person.get('user_name')}
            data['approved'].append(user)
            ctx.wrote('messaging', 'pairing.approve', platform=platform, request_id=request, profile=target, keys=sorted(body))
            return 200, {'ok': True, 'user': user}
        if path == '/api/pairing/revoke' and method == 'POST':
            target = body.get('profile') or 'default'
            platform, user_id = (body.get('platform') or '').lower().strip(), str(body.get('user_id') or '')
            if not platform or not user_id: return 400, {'detail': 'platform and user_id are required'}
            data = store(target)
            if not any(a['platform'] == platform and a['user_id'] == user_id for a in data['approved']):
                return 404, {'detail': f'User {user_id} not found in approved list for {platform}.'}
            data['approved'] = [a for a in data['approved'] if not (a['platform'] == platform and a['user_id'] == user_id)]
            ctx.wrote('messaging', 'pairing.revoke', platform=platform, user_id=user_id, profile=target, keys=sorted(body))
            return 200, {'ok': True}

        if path == '/api/messaging/telegram/onboarding/start' and method == 'POST':
            pairing_id = secrets.token_hex(8)
            expires = time.time() + float(KNOBS.get('expires_in') or 600)
            TELEGRAM[pairing_id] = {'profile': profile or 'default', 'status': 'waiting', 'bot_username': None, 'owner_user_id': None,
                                    'expires': expires}
            LOG['started'].append({'pairing_id': pairing_id, 'profile': profile or 'default', 'body': dict(body)})
            ctx.wrote('messaging', 'telegram.start', profile=profile or 'default', keys=sorted(body))
            link = f'https://t.me/hermes_setup_demo_bot?start={pairing_id}'
            return 200, {'pairing_id': pairing_id, 'deep_link': link, 'qr_payload': link,
                         'suggested_username': 'hermes_demo_bot', 'expires_at': iso(expires)}
        match = re.fullmatch(r'/api/messaging/telegram/onboarding/([^/]+)(/apply)?', path)
        if match:
            pairing_id, record = match.group(1), TELEGRAM.get(match.group(1))
            if not record or record['profile'] != (profile or 'default'):
                return 404, {'detail': 'Telegram setup session was not found. Start again.'}
            if method == 'DELETE' and not match.group(2):
                TELEGRAM.pop(pairing_id, None)
                LOG['cancelled'].append(pairing_id)
                ctx.wrote('messaging', 'telegram.cancel', profile=record['profile'])
                return 200, {'ok': True}
            if time.time() >= record['expires']:
                TELEGRAM.pop(pairing_id, None)
                return 410, {'detail': 'Telegram setup expired. Start a new setup to try again.'}
            if method == 'GET' and not match.group(2):
                if record['status'] == 'ready':
                    return 200, {'status': 'ready', 'bot_username': record['bot_username'], 'owner_user_id': record['owner_user_id'],
                                 'expires_at': iso(record['expires'])}
                return 200, {'status': 'waiting', 'expires_at': iso(record['expires'])}
            if method == 'POST' and match.group(2):
                ids = [str(i).strip() for i in body.get('allowed_user_ids') or []]
                if not all(re.fullmatch(r'\d+', i) for i in ids): return 400, {'detail': 'Allowed Telegram user IDs must be numeric.'}
                if not ids: return 400, {'detail': 'Add at least one allowed Telegram user ID.'}
                if record['status'] != 'ready': return 409, {'detail': 'Telegram setup is not ready yet.'}
                target = body.get('profile') or profile or 'default'
                data = store(target)
                data['env'].setdefault('telegram', {}).update(TELEGRAM_BOT_TOKEN=f'tg-{secrets.token_hex(12)}',
                                                             TELEGRAM_ALLOWED_USERS=','.join(ids))
                data['enabled']['telegram'] = True
                TELEGRAM.pop(pairing_id, None)
                LOG['applied'].append({'pairing_id': pairing_id, 'profile': target, 'allowed_user_ids': ids, 'keys': sorted(body),
                                       'query_profile': profile or None})
                ctx.wrote('messaging', 'telegram.apply', profile=target, keys=sorted(body))
                started = bool(KNOBS.get('restart_started'))
                return 200, {'ok': True, 'platform': 'telegram', 'bot_username': record['bot_username'],
                             'needs_restart': not started, 'restart_started': started}
    return None

def control(path, body):
    with ctx.lock:
        if path == '/__fixture/messaging':
            for key in ('hot_served', 'test', 'platforms', 'pending', 'expires_in', 'restart_started'):
                if key in body: KNOBS[key] = body[key]
            return {'ok': True, 'knobs': dict(KNOBS)}
        if path == '/__fixture/telegram':
            for record in TELEGRAM.values():
                record.update(status=body.get('status', 'ready'), bot_username=body.get('bot_username'),
                              owner_user_id=body.get('owner_user_id'))
            return {'ok': True, 'pairings': len(TELEGRAM)}
    return None

def state():
    def summary(profile):
        return [{'id': p['id'], 'enabled': p['enabled'], 'configured': p['configured'], 'state': p['state'],
                 'set': [v['key'] for v in p['env_vars'] if v['is_set']]} for p in (payload(item, profile) for item in CATALOG)]
    return {'platforms': {profile: summary(profile) for profile in STORES},
            'pairing': {profile: {'pending': [p['user_id'] for p in data['pending']], 'approved': [a['user_id'] for a in data['approved']]}
                        for profile, data in STORES.items()},
            'telegram': {'open': len(TELEGRAM), **{key: list(value) for key, value in LOG.items()}},
            'knobs': dict(KNOBS)}
