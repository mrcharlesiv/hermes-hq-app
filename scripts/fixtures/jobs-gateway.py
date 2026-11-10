#!/usr/bin/env python3
"""Jobs-editor stand-in gateway for HQ Native (docs/spec/3x-jobs.md §7). Loopback only, invented state, stdlib only.

scripts/pages-fixture-gateway.py loaded by path (nothing there is edited): every route and hook it has stays, and
this adds what the New Job / Edit Job editor talks to, with the real gateway's refusal texts:

  POST /api/cron/jobs                        create (400 with the multi-line "Invalid schedule" text)
  PUT  /api/cron/jobs/<id>                   {"updates": {...}} (400 empty, 404 "Job not found")
  GET  /api/cron/delivery-targets            local, Telegram (home set), Discord (home NOT set), a Bot Chat per bot
  GET  /api/cron/blueprints                  seven entries of the real catalog, field for field
  POST /api/cron/blueprints/instantiate      404 "Unknown blueprint: <key>", 422 for a field, else the created job
  GET  /api/model/options                    two signed-in providers, one not signed in, one with no models

Flags (besides the pages fixture's --port --credentials --files --tick-seconds --trigger-seconds):
  --jobs N           N generated jobs across every section and bot, on top of the seeded ones
  --no-blueprints    the catalog is empty          --no-platforms   only local and the Bot Chats
  --no-models        no provider is signed in      --blueprint-422  every instantiate answers a field error
  --write-delay S    every POST / PUT under /api/cron waits S seconds before it is applied
  --read-only        every write under /api/cron answers 403

Test hooks (no auth), besides the pages fixture's /__fixture/state|fail|reset|broadcast|append:
  GET  /__fixture/state    adds "requests": every REST request since the last reset, with "at" (seconds)
  POST /__fixture/fail     also {"method","path","delay":S,"stale":true} (answer after S seconds with what was
                           there when the request arrived), {"method","path","drop":true} (close without answering) and
                           {"method","path","status","raw":"<html>…","content_type":"text/html"} (a body as given)
  POST /__fixture/fail     {"method","path","delay":S,"stale":true,"hold":true}: held until POST /__fixture/release
                           (S seconds at most)
  POST /__fixture/job      {"delete": "<id>"} | {"set": {"id": "<id>", …fields}} | {"add": {…job}}: another client's change
  POST /__fixture/set      {"targets": […]} {"blueprints": […]} {"models": {…}}: replace what those reads answer

  python3 scripts/fixtures/jobs-gateway.py --port 10000 --credentials build/fixtures/jobs.json \
      --files build/fixtures/jobs-files --tick-seconds 0
Ports 10000-10009 only. Never contacts a real gateway.
"""
import copy, datetime, importlib.util, json, os, pathlib, re, socket, subprocess, sys, time
from urllib.parse import urlparse, parse_qs, unquote


def take_flag(name, value=False):
    """Removes --name (and its value) from argv: the pages fixture's own parser does not know it."""
    for index, word in enumerate(sys.argv):
        if word == name:
            if not value:
                del sys.argv[index]
                return True
            if index + 1 >= len(sys.argv): sys.exit(f'{name} needs a value')
            found = sys.argv[index + 1]
            del sys.argv[index:index + 2]
            return found
        if value and word.startswith(name + '='):
            del sys.argv[index]
            return word.split('=', 1)[1]
    return None if value else False


def asked_port():
    for index, word in enumerate(sys.argv):
        if word == '--port' and index + 1 < len(sys.argv): return int(sys.argv[index + 1])
        if word.startswith('--port='): return int(word.split('=', 1)[1])
    sys.exit('usage: jobs-gateway.py --port <10000-10009> --credentials <file> --files <folder> [--tick-seconds 0] [--jobs N]')


if '-h' in sys.argv or '--help' in sys.argv:
    print(__doc__); sys.exit(0)

EXTRA_JOBS = int(take_flag('--jobs', value=True) or 0)
NO_BLUEPRINTS = take_flag('--no-blueprints')
NO_PLATFORMS = take_flag('--no-platforms')
NO_MODELS = take_flag('--no-models')
BLUEPRINT_422 = take_flag('--blueprint-422')
WRITE_DELAY = float(take_flag('--write-delay', value=True) or 0)
READ_ONLY = take_flag('--read-only')

PORT = asked_port()
if not 10000 <= PORT <= 10009 and not os.environ.get('HQN_JOBS_ANY_PORT'):
    sys.exit('jobs fixture ports are 10000-10009 (set HQN_JOBS_ANY_PORT=1 to override)')

# Refuse a busy port before anything is loaded: another agent, or the owner's own Hermes, may be listening there.
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    probe.bind(('127.0.0.1', PORT))
except OSError:
    listening = subprocess.run(['lsof', '-nP', f'-iTCP:{PORT}', '-sTCP:LISTEN'], capture_output=True, text=True).stdout.strip()
    if listening: sys.exit(f'port {PORT} is already in use:\n{listening}')
finally:
    probe.close()

_spec = importlib.util.spec_from_file_location('hqn_jobs_pages', pathlib.Path(__file__).resolve().parent.parent / 'pages-fixture-gateway.py')
pages = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pages)

# ---- schedules (a stand-in for cron/jobs.py parse_schedule; same refusal text) ---------------------------------
DURATION = re.compile(r'^(\d*)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$')
MULTIPLIER = {'m': 1, 'h': 60, 'd': 1440}
WEEKDAY = {'sunday': '0', 'sun': '0', 'monday': '1', 'mon': '1', 'tuesday': '2', 'tue': '2', 'tues': '2', 'wednesday': '3', 'wed': '3',
           'thursday': '4', 'thu': '4', 'thurs': '4', 'friday': '5', 'fri': '5', 'saturday': '6', 'sat': '6'}
DAYSPEC = {'day': '*', 'daily': '*', 'weekday': '1-5', 'weekdays': '1-5', 'weekend': '0,6', 'weekends': '0,6'}
CLOCK = re.compile(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$')


def duration(text):
    match = DURATION.match(text.strip().lower())
    if not match:
        raise ValueError(f"Invalid duration: '{text.strip().lower()}'. Use format like '30m', '2h', '1d', or a bare unit like 'hour' (defaults to 1).")
    return (int(match.group(1)) if match.group(1) else 1) * MULTIPLIER[match.group(2)[0]]


def natural(rest):
    tokens = rest.lower().replace(',', ' ').split()
    if not tokens: return None
    dow = DAYSPEC.get(tokens[0]); index = 1
    if dow is None:
        days = []; index = len(tokens)
        for i, token in enumerate(tokens):
            if token == 'and': continue
            mapped = WEEKDAY.get(token)
            if mapped is None: index = i; break
            if mapped not in days: days.append(mapped)
        if not days: return None
        dow = ','.join(days)
    clock = tokens[index:]
    if clock and clock[0] == 'at': clock = clock[1:]
    if not clock: return None
    match = CLOCK.match(' '.join(clock))
    if not match: return None
    hour, minute, half = int(match.group(1)), int(match.group(2) or 0), match.group(3)
    if half == 'pm' and hour < 12: hour += 12
    if half == 'am' and hour == 12: hour = 0
    if hour > 23 or minute > 59: return None
    return f'{minute} {hour} * * {dow}'


def parse_schedule(schedule):
    schedule = (schedule or '').strip(); original = schedule; lower = schedule.lower()
    every = lower.startswith('every ')
    rest = schedule[6:].strip() if every else lower
    cron = natural(rest)
    if cron is not None: return {'kind': 'cron', 'expr': cron, 'display': original}
    if every: return {'kind': 'interval', 'minutes': duration(rest), 'display': f'every {duration(rest)}m'}
    parts = schedule.split()
    if len(parts) >= 5 and all(re.match(r'^[A-Za-z\d\*\-,/]+$', p) for p in parts[:5]):
        return {'kind': 'cron', 'expr': schedule, 'display': schedule}
    if 'T' in schedule or re.match(r'^\d{4}-\d{2}-\d{2}', schedule):
        try:
            at = datetime.datetime.fromisoformat(schedule.replace('Z', '+00:00'))
        except ValueError as error:
            raise ValueError(f"Invalid timestamp '{schedule}': {error}")
        if at.tzinfo is None: at = at.astimezone()
        return {'kind': 'once', 'run_at': at.isoformat(), 'display': f"once at {at.strftime('%Y-%m-%d %H:%M')}"}
    if lower.startswith('in '):
        try: minutes = duration(schedule[3:])
        except ValueError: raise ValueError(f"Invalid duration '{schedule[3:].strip()}' after 'in '. Use e.g. 'in 30m', 'in 2h'.")
        at = pages.local(pages.now()) + datetime.timedelta(minutes=minutes)
        return {'kind': 'once', 'run_at': at.isoformat(timespec='seconds'), 'display': f'once in {schedule[3:].strip()}'}
    try: return {'kind': 'interval', 'minutes': duration(schedule), 'display': f'every {duration(schedule)}m'}
    except ValueError: pass
    raise ValueError(
        f"Invalid schedule '{original}'. Use:\n"
        f"  - Interval: '30m', 'every 30m', 'every 2h' (recurring)\n"
        f"  - One-shot delay: 'in 30m', 'in 2h' (fires once)\n"
        f"  - Weekly/daily: 'every monday 9am', 'weekdays at 9am' (recurring)\n"
        f"  - Cron: '0 9 * * *' (cron expression)\n"
        f"  - Timestamp: '2026-02-03T14:00:00' (one-shot at time)")


def field_set(text, low, high):
    out = set()
    for piece in text.split(','):
        step = 1
        if '/' in piece:
            piece, raw = piece.split('/', 1)
            if not raw.isdigit() or int(raw) < 1: return None
            step = int(raw)
        if piece == '*': start, end = low, high
        elif '-' in piece:
            a, b = piece.split('-', 1)
            if not (a.isdigit() and b.isdigit()): return None
            start, end = int(a), int(b)
        elif piece.isdigit(): start = end = int(piece)
        else: return None
        out.update(range(start, end + 1, step))
    return out


def next_run(schedule, after=None):
    after = after or pages.local(pages.now())
    if schedule['kind'] == 'interval': return pages.iso(pages.minute(after) + datetime.timedelta(minutes=schedule['minutes']))
    if schedule['kind'] == 'once': return schedule['run_at']
    parts = schedule['expr'].split()
    sets = [field_set(parts[0], 0, 59), field_set(parts[1], 0, 23), field_set(parts[2], 1, 31), field_set(parts[3], 1, 12), field_set(parts[4], 0, 7)]
    if any(s is None for s in sets): return pages.iso(pages.minute(after) + datetime.timedelta(hours=1))
    minutes, hours, days, months, dows = sets
    dows = {d % 7 for d in dows}
    day = pages.minute(after) + datetime.timedelta(minutes=1)
    for _ in range(370):
        if day.month in months and day.day in days and (day.weekday() + 1) % 7 in dows:
            for hour in sorted(h for h in hours if h >= day.hour):
                for minute in sorted(minutes):
                    if hour > day.hour or minute >= day.minute: return pages.iso(day.replace(hour=hour, minute=minute))
        day = (day + datetime.timedelta(days=1)).replace(hour=0, minute=0)
    return None


# ---- what the editor reads -------------------------------------------------------------------------------------
OVERRIDE = {}


def delivery_targets():
    if 'targets' in OVERRIDE: return OVERRIDE['targets']
    targets = [{'id': 'local', 'name': 'Local (save only)', 'home_target_set': True, 'home_env_var': None}]
    if not NO_PLATFORMS:
        targets += [{'id': 'telegram', 'name': 'Telegram', 'home_target_set': True, 'home_env_var': 'TELEGRAM_HOME_CHANNEL'},
                    {'id': 'discord', 'name': 'Discord', 'home_target_set': False, 'home_env_var': 'DISCORD_HOME_CHANNEL'}]
    targets += [{'id': f'bot-chat:{name}', 'name': f'Bot Chat ({name})', 'home_target_set': True, 'home_env_var': None} for name, _, _ in pages.BOTS]
    return targets


def model_options():
    if 'models' in OVERRIDE: return OVERRIDE['models']
    if NO_MODELS:
        return {'providers': [{'slug': 'openai', 'name': 'OpenAI', 'models': ['gpt-5'], 'authenticated': False}], 'model': '', 'provider': ''}
    return {'model': 'hermes-4', 'provider': 'nous', 'providers': [
        {'slug': 'anthropic', 'name': 'Anthropic', 'models': ['claude-sonnet-5', 'claude-opus-5'], 'authenticated': True, 'is_current': False},
        {'slug': 'nous', 'name': 'Nous Portal', 'models': ['hermes-4', 'hermes-4-mini'], 'authenticated': True, 'is_current': True},
        {'slug': 'openai', 'name': 'OpenAI', 'models': ['gpt-5'], 'authenticated': False, 'is_current': False},
        {'slug': 'xai', 'name': 'xAI', 'models': [], 'authenticated': True, 'is_current': False}]}


def slot(name, kind, label, default=None, options=(), optional=False, help='', strict=True):
    return {'name': name, 'type': kind, 'label': label, 'default': default, 'options': list(options), 'optional': optional, 'strict': strict, 'help': help}

TIME = lambda default='08:00': slot('time', 'time', 'What time?', default, help='24h local time, e.g. 08:00')
DELIVER = lambda: slot('deliver', 'enum', 'Where to deliver?', 'origin', ('origin', 'local', 'telegram', 'discord', 'email'), strict=False,
                       help='origin = the chat you set this up from (or your configured home channel when created from the dashboard); '
                            'local = save only, no message; or any connected platform name')
RECUR = lambda default: slot('recurrence', 'weekdays', 'Repeat on', default, ('everyday', 'weekdays', 'weekends'))
PRESETS = {'everyday': '*', 'weekdays': '1-5', 'weekends': '0,6'}
DAY_DOW = {'sunday': '0', 'monday': '1', 'tuesday': '2', 'wednesday': '3', 'thursday': '4', 'friday': '5', 'saturday': '6'}

# Seven entries of cron/blueprint_catalog.py CATALOG, copied field for field (key, title, description, slots).
CATALOG = [
    {'key': 'morning-brief', 'title': 'Morning briefing', 'category': 'daily', 'tags': ['daily', 'briefing'],
     'description': "A short daily briefing: today's calendar, weather, and anything urgent waiting on you.",
     'schedule': '{minute} {hour} * * *', 'prompt': 'Produce a concise morning briefing for the user.', 'fields': [TIME('08:00'), DELIVER()]},
    {'key': 'weekly-review', 'title': 'Weekly review', 'category': 'weekly', 'tags': ['weekly', 'review'],
     'description': "A weekly recap: what got done, what's still open, and what's coming up.",
     'schedule': '{minute} {hour} * * {dow}', 'prompt': "Run the weekly-review-planning skill's procedure for the user.",
     'fields': [TIME('18:00'), slot('day', 'enum', 'Which day?', 'sunday', ('sunday', 'monday', 'friday', 'saturday')), DELIVER()]},
    {'key': 'custom-reminder', 'title': 'Custom reminder', 'category': 'general', 'tags': ['reminder'],
     'description': 'A recurring reminder in your own words, on your schedule.',
     'schedule': '{minute} {hour} * * {dow}', 'prompt': 'Remind the user: {what}',
     'fields': [slot('what', 'text', 'Remind me to…', 'take a break and stretch'), TIME('14:00'), RECUR('everyday'), DELIVER()]},
    {'key': 'price-watch', 'title': 'Price & availability watch', 'category': 'general', 'tags': ['prices', 'shopping', 'travel', 'monitor'],
     'description': 'Watch an exact product, flight, hotel, or listing and alert when your price or availability condition is met.',
     'schedule': '0 */{interval_h} * * *', 'prompt': 'Run the tick for this watch: {item}. Alert condition: {condition}.',
     'fields': [slot('item', 'text', 'What exactly to watch?', 'a product URL or exact flight/hotel/listing description',
                     help='URL or precise description — variant, dates, seller'),
                slot('condition', 'text', 'Alert me when…', 'the all-in price drops below my target',
                     help='threshold price (state the currency), availability, or terms change'),
                slot('interval_h', 'enum', 'How often?', '6', ('1', '3', '6', '12', '24'), help='hours between checks — be gentle with rate limits'),
                DELIVER()]},
    {'key': 'habit-checkin', 'title': 'Habit check-in', 'category': 'general', 'tags': ['habit', 'wellbeing'],
     'description': 'A recurring nudge to keep a habit on track and reflect on whether you did it.',
     'schedule': '{minute} {hour} * * {dow}', 'prompt': 'Nudge the user about their habit: {habit}.',
     'fields': [slot('habit', 'text', 'Which habit?', '20 minutes of reading'), TIME('20:00'), RECUR('everyday'), DELIVER()]},
    {'key': 'hydration-move', 'title': 'Hydration & movement nudge', 'category': 'general', 'tags': ['wellbeing', 'focus'],
     'description': 'A periodic nudge during the day to drink water, stand up, and stretch.',
     'schedule': '0 {start_hour}-{end_hour}/{interval_hours} * * 1-5', 'prompt': 'Send the user a brief, friendly nudge to drink some water.',
     'fields': [slot('interval_hours', 'enum', 'How often?', '1', ('1', '2', '3'), help='hours between nudges'),
                slot('start_hour', 'enum', 'Start hour', '9', ('7', '8', '9', '10'), help='first hour of the active window (24h)'),
                slot('end_hour', 'enum', 'End hour', '17', ('16', '17', '18', '19'), help='last hour of the active window (24h)'),
                DELIVER()]},
    {'key': 'learn-daily', 'title': 'Daily learning drip', 'category': 'daily', 'tags': ['learning', 'daily'],
     'description': 'One bite-sized lesson a day on a topic you want to learn, building progressively over time.',
     'schedule': '{minute} {hour} * * {dow}', 'prompt': 'Teach the user one bite-sized lesson about: {topic}.',
     'fields': [slot('topic', 'text', 'Learn about…', 'Spanish vocabulary'), TIME('08:30'), RECUR('weekdays'), DELIVER()]},
]


def blueprints():
    if 'blueprints' in OVERRIDE: return OVERRIDE['blueprints']
    if NO_BLUEPRINTS: return []
    deliver_options = ['origin'] + [t['id'] for t in delivery_targets() if t.get('home_target_set')]
    out = []
    for entry in CATALOG:
        row = {k: copy.deepcopy(v) for k, v in entry.items() if k not in ('prompt',)}
        for field in row['fields']:
            if field['name'] == 'deliver': field['options'] = deliver_options
        row.update({'source': 'builtin', 'plugin': None, 'scheduleHuman': '', 'command': f"/blueprint {entry['key']}",
                    'appUrl': f"hermes://blueprint/{entry['key']}"})
        out.append(row)
    return out


class Fill(ValueError): pass


def fill(blueprint, values):
    """cron/blueprint_catalog.py fill_blueprint + _resolve_schedule, with its refusal texts."""
    fields = blueprint['fields']
    known = [f['name'] for f in fields]
    unknown = sorted(set(values) - set(known))
    if unknown: raise Fill(f"unknown slot{'s' if len(unknown) > 1 else ''}: {', '.join(unknown)} — valid: {', '.join(known)}")
    resolved = {}
    for field in fields:
        raw = values.get(field['name'], field['default'])
        if raw in (None, ''):
            if field['optional']: continue
            raise Fill(f"missing required value: {field['name']} ({field['label']})")
        if field['type'] == 'enum' and field['strict'] and field['options'] and str(raw) not in {str(o) for o in field['options']}:
            raise Fill(f"{field['name']}={raw!r} not allowed — one of {', '.join(map(str, field['options']))}")
        resolved[field['name']] = raw
    template = blueprint['schedule']; fills = {}
    if '{minute}' in template or '{hour}' in template:
        when = resolved.get('time')
        if not when: raise Fill('a time is required')
        match = re.match(r'^([01]?\d|2[0-3]):([0-5]\d)$', str(when).strip())
        if not match: raise Fill(f'invalid time {when!r} — use HH:MM (24h)')
        fills['hour'] = str(int(match.group(1))); fills['minute'] = str(int(match.group(2)))
    if '{dow}' in template:
        if 'recurrence' in resolved:
            preset = str(resolved['recurrence']).lower()
            if preset not in PRESETS: raise Fill(f"unknown recurrence {preset!r} — one of {', '.join(PRESETS)}")
            fills['dow'] = PRESETS[preset]
        elif 'day' in resolved:
            day = str(resolved['day']).lower()
            if day not in DAY_DOW: raise Fill(f'unknown day {day!r}')
            fills['dow'] = DAY_DOW[day]
        else: fills['dow'] = '*'
    for name in re.findall(r'\{(\w+)\}', template):
        if name not in fills and name in resolved: fills[name] = str(resolved[name])
    schedule = template.format(**fills)
    prompt = next(e for e in CATALOG if e['key'] == blueprint['key'])['prompt'] if any(e['key'] == blueprint['key'] for e in CATALOG) else blueprint['title']
    try: prompt = prompt.format(**resolved)
    except (KeyError, IndexError): pass
    return {'prompt': prompt, 'schedule': schedule, 'name': blueprint['title'], 'deliver': resolved.get('deliver', 'origin')}


# ---- jobs ------------------------------------------------------------------------------------------------------
COUNTER = {'n': 0}
EMPTY_PAYLOAD = ('Cron job has nothing to run: the prompt is blank and no script or skill(s) are set. '
                 'Provide a prompt, a script, or at least one skill.')


def make_job(profile, spec):
    schedule = parse_schedule(spec.get('schedule') or '')
    prompt = (spec.get('prompt') or '')
    if not prompt.strip() and not spec.get('script') and not spec.get('skills'): raise ValueError(EMPTY_PAYLOAD)
    COUNTER['n'] += 1
    jid = f"jn{COUNTER['n']:04d}"
    name = (spec.get('name') or '').strip() or prompt.strip().split('\n')[0][:50]
    job = pages.job_record(jid, name, profile, schedule, prompt=prompt, deliver=(spec.get('deliver') or 'local'),
                           model=spec.get('model') or None, provider=spec.get('provider') or None)
    job['next_run_at'] = next_run(schedule)
    pages.JOBS[f'{profile}|{jid}'] = job
    return job


def update_job(job, updates):
    if not isinstance(updates, dict) or not updates: raise ValueError('No updates provided')
    if 'id' in updates: raise ValueError('Cron job field(s) cannot be updated: id')
    merged = dict(job)
    for key, value in updates.items():
        if key == 'schedule':
            merged['schedule'] = parse_schedule(value if isinstance(value, str) else '')
            merged['schedule_display'] = merged['schedule'].get('display') or merged['schedule'].get('expr')
            merged['next_run_at'] = None
        elif key in ('model', 'provider'): merged[key] = (value or None) if not isinstance(value, str) else (value.strip() or None)
        else: merged[key] = value
    if any(k in updates for k in ('prompt', 'script', 'skills')) and not (merged.get('prompt') or '').strip() and not merged.get('script') and not merged.get('skills'):
        raise ValueError(EMPTY_PAYLOAD)
    if merged.get('enabled', True) and merged.get('state') != 'paused' and not merged.get('next_run_at'):
        merged['next_run_at'] = next_run(merged['schedule'])
    job.clear(); job.update(merged)
    return job


def seed_more():
    """Jobs the editor's checks need, beside the pages fixture's nine."""
    t0 = pages.local(pages.T0)
    extra = [
        pages.job_record('j-pinned', 'Family dinner plan', 'default', {'kind': 'cron', 'expr': '30 18 * * 3', 'display': '30 18 * * 3'},
                         deliver='telegram:-100123:7', model='retired-model-1', provider='oldco',
                         prompt='Plan a family dinner for Wednesday and post the shopping list.'),
        pages.job_record('j-model', 'Daily standup notes', 'default', {'kind': 'cron', 'expr': '0 9 * * 1-5', 'display': '0 9 * * 1-5'},
                         model='claude-sonnet-5', provider='anthropic', deliver='local,telegram',
                         prompt='Collect what changed since yesterday and write the standup notes.'),
    ]
    for job in extra:
        job['next_run_at'] = next_run(job['schedule'], t0)
        pages.JOBS[f"{job['profile']}|{job['id']}"] = job
    states = ['scheduled', 'scheduled', 'scheduled', 'paused', 'completed', 'failed', 'running']
    presets = ['0 9 * * *', '0 9 * * 1-5', '30 18 * * 3', '0 9 1 * *', '25 * * * *', '*/15 * * * *', '0 6,18 * * *']
    topics = ['inbox triage', 'release watch', 'reading list', 'finance report', 'disk check', 'standup notes', 'backup', 'invoice run',
              'calendar review', 'habit check-in', 'price watch', 'news digest']
    bots = [name for name, _, _ in pages.BOTS]
    for n in range(EXTRA_JOBS):
        state = states[n % len(states)]
        expr = presets[n % len(presets)]
        schedule = {'kind': 'cron', 'expr': expr, 'display': expr}
        profile = bots[n % len(bots)]
        job = pages.job_record(f'g{n:05d}', f'{topics[n % len(topics)].capitalize()} {n + 1}', profile, schedule,
                               prompt=f'Generated job {n + 1}: do the {topics[n % len(topics)]} and say what changed. ' * 3)
        job['next_run_at'] = pages.iso(pages.minute(t0) + datetime.timedelta(minutes=5 + (n * 7) % 9000))
        if state == 'paused': job.update(enabled=False, state='paused', next_run_at=None)
        if state == 'completed': job.update(enabled=False, state='completed', next_run_at=None, last_run_at=pages.iso(t0 - datetime.timedelta(days=2)), last_status='ok')
        if state == 'failed': job.update(last_run_at=pages.iso(t0 - datetime.timedelta(hours=3)), last_status='error', last_error='RuntimeError: The provider refused the request.')
        if state == 'running': job.update(state='running', last_run_at=pages.iso(t0 - datetime.timedelta(minutes=30)), last_status='ok')
        pages.JOBS[f'{profile}|{job["id"]}'] = job


_reseed = pages.reseed
def reseed():
    _reseed()
    with pages.lock:
        COUNTER['n'] = 0
        OVERRIDE.clear()
        seed_more()
pages.reseed = reseed

import threading
RELEASE = threading.Event()   # set by POST /__fixture/release: ends a {"hold": true} delay
HELD_UNTIL = []               # when each held request was let go (seconds)

# ---- REST ------------------------------------------------------------------------------------------------------
_pages_handler = pages.fx.handler
def handler(gateway):
    base = _pages_handler(gateway)
    class Handler(base):
        def logged(self, method, body=None):
            url = urlparse(self.path)
            query = {k: v[0] if len(v) == 1 else v for k, v in parse_qs(url.query).items()}
            with pages.lock: pages.state['rest'].append({'method': method, 'path': url.path, 'query': query, 'body': body, 'at': time.time()})
            for fail in list(pages.fails):
                if fail.get('method', method) != method or fail.get('path') != url.path: continue
                if fail.get('delay'):
                    with pages.lock: pages.fails.remove(fail)
                    # "stale": the answer is what the gateway had when the read began (a slow read that a later
                    # write overtakes), sent after the delay.
                    stale = self.route(method, body if body is not None else {}) if fail.get('stale') else None
                    if fail.get('hold'):
                        # Held until POST /__fixture/release (or `delay` seconds at most): a test on a loaded Mac
                        # cannot know how long its own taps will take.
                        RELEASE.clear()
                        RELEASE.wait(float(fail['delay']))
                        HELD_UNTIL.append(time.time())
                    else:
                        time.sleep(float(fail['delay']))
                    return stale
                with pages.lock:
                    fail['count'] = int(fail.get('count', 1)) - 1
                    if fail['count'] <= 0: pages.fails.remove(fail)
                if fail.get('drop'):
                    # The connection goes away mid-request: no status line, no body.
                    try: self.connection.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
                    self.close_connection = True
                    return 'dropped'
                if 'raw' in fail:
                    return int(fail.get('status', 500)), (fail.get('content_type', 'text/html'), str(fail['raw']).encode())
                return int(fail.get('status', 500)), {'detail': fail.get('detail', 'boom')}
            return None

        def handle_api(self, method):
            body = self.body_json() if method in ('POST', 'PATCH', 'PUT', 'DELETE') else None
            failed = self.logged(method, body)
            if failed == 'dropped': return
            if failed: return self.answer(*failed)
            result = self.route(method, body if body is not None else {})
            if result is None:
                return super(base, self).do_GET() if method == 'GET' else self.answer(404, {'detail': 'Not Found'})
            return self.answer(*result)

        def route(self, method, body):
            url = urlparse(self.path); path, query = url.path, parse_qs(url.query)
            profile = (query.get('profile') or [''])[0] or 'default'
            write = method in ('POST', 'PUT', 'DELETE', 'PATCH') and path.startswith('/api/cron')
            if write and READ_ONLY: return 403, {'detail': 'This gateway is read-only.'}
            if write and method in ('POST', 'PUT') and WRITE_DELAY > 0 and not path.endswith('/trigger'): time.sleep(WRITE_DELAY)
            if path == '/api/cron/delivery-targets' and method == 'GET':
                with pages.lock: return 200, {'targets': copy.deepcopy(delivery_targets())}
            if path == '/api/cron/blueprints' and method == 'GET':
                with pages.lock: return 200, {'blueprints': copy.deepcopy(blueprints())}
            if path == '/api/model/options' and method == 'GET':
                with pages.lock: return 200, copy.deepcopy(model_options())
            if path == '/api/cron/blueprints/instantiate' and method == 'POST':
                if not isinstance(body, dict): return 422, {'detail': 'Input should be a valid dictionary'}
                with pages.lock:
                    blueprint = next((b for b in blueprints() if b['key'] == body.get('blueprint')), None)
                    if blueprint is None: return 404, {'detail': f"Unknown blueprint: {body.get('blueprint')}"}
                    if BLUEPRINT_422: return 422, {'detail': f"invalid time {str((body.get('values') or {}).get('time', '25:00'))!r} — use HH:MM (24h)"}
                    try:
                        spec = fill(blueprint, body.get('values') or {})
                        job = copy.deepcopy(make_job(profile, spec))
                    except Fill as error: return 422, {'detail': str(error)}
                    except ValueError as error: return 400, {'detail': str(error)}
                pages.broadcast(); return 200, job
            if path == '/api/cron/jobs' and method == 'POST':
                if not isinstance(body, dict) or not isinstance(body.get('schedule'), str):
                    return 422, {'detail': [{'type': 'missing', 'loc': ['body', 'schedule'], 'msg': 'Field required'}]}
                with pages.lock:
                    try: job = copy.deepcopy(make_job(profile, body))
                    except ValueError as error: return 400, {'detail': str(error)}
                pages.broadcast(); return 200, job
            if path.startswith('/api/cron/jobs/') and method == 'PUT':
                parts = [unquote(p) for p in path[len('/api/cron/jobs/'):].split('/')]
                if len(parts) != 1: return 404, {'detail': 'Not Found'}
                with pages.lock:
                    job = pages.job_by(parts[0], (query.get('profile') or [''])[0])
                    if not job: return 404, {'detail': 'Job not found'}
                    try: answer = copy.deepcopy(update_job(job, (body or {}).get('updates') if isinstance(body, dict) else None))
                    except ValueError as error: return 400, {'detail': str(error)}
                pages.broadcast(); return 200, answer
            return super().route(method, body)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/state':
                with pages.lock:
                    return self.reply(200, {'rest': pages.state['rest'], 'requests': pages.state['rest'], 'rpc': pages.state['rpc'],
                                            'dispatch': pages.state['dispatch'], 'beacon': pages.state['beacon'],
                                            'jobs': len(pages.JOBS), 'sockets': len(pages.sockets), 'held_until': list(HELD_UNTIL)})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/release':
                RELEASE.set()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/job':
                body = self.body_json()
                with pages.lock:
                    if 'delete' in body:
                        for key in [k for k, j in pages.JOBS.items() if j['id'] == body['delete']]: pages.JOBS.pop(key)
                    if 'set' in body:
                        job = pages.job_by(body['set'].get('id'), body['set'].get('profile'))
                        if not job: return self.reply(404, {'detail': 'Job not found'})
                        job.update({k: v for k, v in body['set'].items() if k != 'id'})
                    if 'add' in body:
                        job = pages.job_record(body['add']['id'], body['add'].get('name', ''), body['add'].get('profile', 'default'),
                                               body['add'].get('schedule') or {'kind': 'cron', 'expr': '0 9 * * *', 'display': '0 9 * * *'})
                        job.update({k: v for k, v in body['add'].items() if k not in ('id',)})
                        pages.JOBS[f"{job['profile']}|{job['id']}"] = job
                if body.get('broadcast', True): pages.broadcast()
                return self.reply(200, {'ok': True, 'jobs': len(pages.JOBS)})
            if path == '/__fixture/set':
                body = self.body_json()
                with pages.lock:
                    for key in ('targets', 'blueprints', 'models'):
                        if key in body: OVERRIDE[key] = body[key]
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler
pages.fx.handler = handler

if __name__ == '__main__':
    pages.main()
