#!/usr/bin/env python3
"""A stateful stand-in gateway for the native Jobs, Kanban and Artifacts pages (docs/spec/1x-pages.md §9.3).

Stdlib only. It loads the reference repo's action-voice fixture ($HQN_REF/scripts/action-voice-fixture-gateway.py)
for the password sign-in, the ws-ticket and the WebSocket JSON-RPC base, and overrides `rpc`, `websocket` and the
REST handler. Everything it serves is invented. It binds 127.0.0.1 only and has no network client.

  python3 scripts/pages-fixture-gateway.py --port 9735 --credentials <scratch>/pages.json --files <scratch>/files
  python3 scripts/pages-fixture-gateway.py --port 9737 --credentials <scratch>/pages-nok.json --files <scratch>/files2 --no-kanban

Flags: --no-kanban (every /api/plugins/kanban/* answers 404), --empty-kanban (boards hold no tasks),
--trigger-seconds N (a job trigger blocks N s, default 3), --tick-seconds N (a cron.changed broadcast every N s,
default 60; 0 = off), --hermes-cookies (inherited session gating).

Test hooks (no auth):
  GET  /__fixture/state      {"rest":[{method,path,query,body}],"rpc":[...],"dispatch":n,"beacon":n}
  POST /__fixture/fail       {"method","path","status","detail","count"} or {"method","path","delay"}
  POST /__fixture/reset      forget the logs and failures, re-seed every table
  POST /__fixture/tile-job   a job of deploys that rewrites site/tile.html hourly, last run 5 minutes ago ([tiles])
                             ({"status": "error", "error": …, "model": …}: its last run failed, the model it names)
  POST /__fixture/live-bump  site/live.html's sales go from 12 to 13 ([live-tiles]: the tile's own refresh reads it)
  POST /__fixture/tile-edit  {"from","to"}: the tile's bot edited the page's look ([tile-versions])
  POST /__fixture/tile-ran   that job ran just now and rewrote the page (the headline becomes Revenue $14K)
  POST /__fixture/broadcast  {"type":"cron.changed"} to every open socket
  POST /__fixture/turn-end   {"match","text"} or {"match","error"}: the last streaming prompt holding `match` ends ([tiles])
  POST /__fixture/append     {"session_id","role","text"}: a new message (its session's count and last_active move)
  POST /__fixture/finish     {"job_id"}: the job's run out ends, as Hermes ends one (marked run, attempt completed);
                             with "bot":"claimed" (or "queued") a bot is still working on what it handed over
  POST /__fixture/bot-done   {"job_id"}: that bot is done (a cron.changed too, so the app reads now; Hermes sends none
                             then, and the app's 30 s backstop finds it)
  GET  /__fixture/beacon     counts a fetch (an HTML file's <img>; Quick Look must never fetch it)

Tasks ([tasks], hermes-hq-push 0.9.32, docs/tasks.md): /api/plugins/hermes-hq-push/tasks (GET ?since, POST),
/tasks/{id} (PATCH with rev: a stale one is a 409 {"detail": {"task": …}}; DELETE), /tasks/settings (GET, PUT), and
the add-on's /status with every flag on (tasks: true), POST /tasks/prep-job/{profile}. Seeded with the owner-approved
mockup's list and a chat ('s-tasks') where Hermes adds two with tasks_add; --tasks-chat puts that exchange at the end of
Hermes's own Bot Chat too; --no-tasks answers 404 for the routes (an add-on older than 0.9.32).
"""
import shutil
import argparse, base64, copy, datetime, hashlib, importlib.util, json, mimetypes, os, pathlib, socket, struct, sys, threading, time, zlib
from urllib.parse import urlparse, parse_qs, unquote

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
_spec = importlib.util.spec_from_file_location('fx', REF / 'scripts/action-voice-fixture-gateway.py')
fx = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(fx)

HOME = '/home/hermes'
FILES = pathlib.Path('/tmp/pages-fixture-files')
PERF_LOGS = pathlib.Path(__file__).resolve().parent / 'fixture-support' / 'perf_logs.py'   # copy of the plugin's log writer
TASK_PAGE = pathlib.Path(__file__).resolve().parent / 'fixture-support' / 'task_page.py'   # copy of the plugin's Task Page (0.9.38)
NO_KANBAN = False
EMPTY_KANBAN = False
TRIGGER_SECONDS = 3.0
lock = threading.RLock()
state = {'rest': [], 'rpc': [], 'dispatch': 0, 'beacon': 0}
fails = []
sockets = set()
T0 = 0.0

def now(): return time.time()
def local(ts): return datetime.datetime.fromtimestamp(ts).astimezone()
def iso(dt): return dt.isoformat(timespec='seconds') if dt else None
def minute(dt): return dt.replace(second=0, microsecond=0)

# ---- the roster ----------------------------------------------------------------------------------------
BOTS = [('default', 'Hermes', 'Your right hand'), ('inbox', 'Inbox', 'Triage, replies and follow-ups'),
        ('deploys', 'Deploys', 'Releases, builds and checks'), ('research', 'Research', 'Reading and summaries'),
        ('finance', 'Finance', 'Books, invoices and reports')]
# HQN_REAL_LISTING / HQN_REAL_MESSAGES: JSON files outside the repo with a real gateway's per-profile listing and its
# chats' messages (key "profile\x1fid"), so Artifacts runs over real data. The roster becomes that listing's profiles.
REAL_LISTING = json.load(open(os.environ['HQN_REAL_LISTING'])) if os.environ.get('HQN_REAL_LISTING') else None
REAL_MESSAGES = json.load(open(os.environ['HQN_REAL_MESSAGES'])) if os.environ.get('HQN_REAL_MESSAGES') else {}
if REAL_LISTING:
    BOTS = [(n, 'Hermes' if n == 'default' else n.replace('-', ' ').title(), 'Real') for n in sorted(REAL_LISTING)]
# HQN_FIXTURE_EXTRA_BOTS=N: N more plain bots, so the Bots list is long enough to scroll (bar screenshots).
BOTS += [(f'extra{i + 1}', f'Helper {i + 1}', 'Odds and ends') for i in range(int(os.environ.get('HQN_FIXTURE_EXTRA_BOTS', '0') or 0))]
BOT_NAMES = {name: title for name, title, _ in BOTS}

SESSIONS = {}
def add_session(sid, profile, title, messages, last_active, source='desktop', cwd=f'{HOME}/app', hidden=False, listed=True):
    for index, message in enumerate(messages):
        message.setdefault('id', index + 1)
        message.setdefault('timestamp', last_active - (len(messages) - index) * 5)
    SESSIONS[sid] = {'id': sid, 'profile': profile, 'title': title, 'messages': messages, 'last_active': last_active,
                     'started_at': last_active - 600, 'source': source, 'cwd': cwd, 'hidden': hidden, 'listed': listed}

def session_row(sid):
    s = SESSIONS[sid]
    last = next((m for m in reversed(s['messages']) if m['role'] == 'assistant' and isinstance(m.get('content'), str)), None)
    preview = (last['content'] if last else '').split('\n')[0][:140]
    return {'id': sid, 'title': s['title'], 'preview': preview, 'profile': s['profile'], 'profile_name': s['profile'],
            'is_default_profile': s['profile'] == 'default', 'hidden': s['hidden'], 'pinned': False, 'unread': False,
            'archived': False, 'model': 'hermes-4', 'billing_provider': 'nous', 'source': s['source'],
            'message_count': len(s['messages']), 'started_at': s['started_at'], 'last_active': s['last_active'],
            'ended_at': None, 'is_active': False, 'cwd': s['cwd']}

STREAMING = set()   # [tiles] runtime ids of tile changes still working (session.active_list lists them)
def runtime(sid): return hashlib.sha256(sid.encode()).hexdigest()[:8]
def find_session(asked):
    for sid in SESSIONS:
        if asked in (sid, runtime(sid)): return sid
    return None

def bot_chat_id(profile): return f'20261009_090000_bc{hashlib.sha256(profile.encode()).hexdigest()[:6]}'

def roster():
    rows = []
    for index, (name, title, about) in enumerate(BOTS):
        sid = bot_chat_id(name)
        canon = session_row(sid)
        short = {'id': sid, 'resolved_id': sid, 'title': 'Bot Chat', 'preview': canon['preview'], 'last_active': canon['last_active'],
                 'message_count': canon['message_count']}
        meta = {'title': title, 'description': about, 'pinned': name in ('default', 'deploys'), 'created': 1790000000000 + index}
        rows.append({'name': name, 'path': f'{HOME}/profiles/{name}', 'is_default': name == 'default', 'is_active': name == 'default',
                     'model': 'hermes-4', 'provider': 'nous', 'display_name': title, 'description': about,
                     'canonical_session': short, 'last_session': short, 'worker_session': None, 'sessions': [canon],
                     'ui_meta': {'hermes-bots': meta}, 'ui_meta_revisions': {'hermes-bots': 1}})
    return {'active': 'default', 'profiles': rows, 'bot_mode_protocol': True}

# ---- jobs -------------------------------------------------------------------------------------------------
JOBS = {}      # key "<profile>|<id>" → job
RUNS = {}      # job id → [run rows], newest first
RUNNING = set()
BOT_WORKING = {}   # key "<profile>|<id>" → the add-on's cron/working row (hermes-hq-push 0.9.2)

def job_record(jid, name, profile, schedule, **extra):
    job = {'id': jid, 'name': name, 'prompt': extra.pop('prompt', name), 'skills': [], 'script': None, 'no_agent': False,
           'schedule': schedule, 'schedule_display': schedule.get('display') or schedule.get('expr'), 'enabled': True,
           'state': 'scheduled', 'next_run_at': None, 'last_run_at': None, 'last_status': None, 'last_error': None,
           'deliver': 'local', 'origin': None, 'model': None, 'provider': None, 'profile': profile, 'profile_name': profile,
           'hermes_home': f'{HOME}/profiles/{profile}', 'is_default_profile': profile == 'default',
           # Hermes never stores a "running" state: a run out is the latest attempt's (cron/executions.py).
           'latest_execution': None}
    job.update(extra)
    return job

def execution(jid, status, claimed, finished=None):
    """A row of Hermes's run ledger as `latest_execution` carries it."""
    return {'id': f'exec-{jid}-{int(claimed.timestamp())}', 'job_id': jid, 'source': 'tick', 'status': status,
            'claimed_at': claimed.isoformat(), 'started_at': claimed.isoformat(),
            'finished_at': finished.isoformat() if finished else None, 'error': None}

def finish_run(job):
    """The job's run out ends: Hermes marks the job run, then completes the attempt."""
    stamp = local(now())
    job['last_run_at'] = iso(stamp); job['last_status'] = 'ok'; job['last_error'] = None
    if job.get('latest_execution'):
        job['latest_execution'].update(status='completed', finished_at=stamp.isoformat())
    for run in RUNS.get(job['id'], []):
        if run.get('is_active'): run.update(is_active=False, ended_at=now())

def seed_jobs():
    JOBS.clear(); RUNS.clear(); RUNNING.clear(); BOT_WORKING.clear()
    t0 = local(T0)
    def weekday_after(d, hour, minute_=0):
        day = (d + datetime.timedelta(days=1)).replace(hour=hour, minute=minute_, second=0, microsecond=0)
        while day.weekday() >= 5: day += datetime.timedelta(days=1)
        return day
    def weekday_before(d, hour):
        day = (d - datetime.timedelta(days=1)).replace(hour=hour, minute=0, second=0, microsecond=0)
        while day.weekday() >= 5: day -= datetime.timedelta(days=1)
        return day
    run_at = (t0 + datetime.timedelta(days=2)).replace(hour=9, minute=0, second=0, microsecond=0)
    monday = (t0 + datetime.timedelta(days=(7 - t0.weekday()) % 7 or 7)).replace(hour=6, minute=0, second=0, microsecond=0)
    east = datetime.timezone(t0.utcoffset() + datetime.timedelta(hours=5))
    zone_next = monday.replace(tzinfo=None).replace(hour=6).replace(tzinfo=east)
    quarter = minute(t0) + datetime.timedelta(minutes=15 - t0.minute % 15)
    last_triage = weekday_before(t0, 8)
    jobs = [
        job_record('j-triage', 'Morning inbox triage', 'inbox', {'kind': 'cron', 'expr': '0 8 * * 1-5', 'display': '0 8 * * 1-5'},
                   next_run_at=iso(weekday_after(t0, 8)), last_run_at=iso(last_triage), last_status='ok', deliver='origin',
                   origin={'platform': 'telegram', 'chat_id': '100000001', 'chat_name': 'Alex Rivera', 'thread_id': None},
                   prompt='Triage the inbox. Draft replies for anything that needs <name>, and file the rest & move on.'),
        job_record('j-watch', 'release-watch', 'deploys', {'kind': 'interval', 'minutes': 30, 'display': 'every 30m'},
                   next_run_at=iso(minute(t0) + datetime.timedelta(minutes=12)),
                   last_run_at=iso(minute(t0) - datetime.timedelta(minutes=18)), last_status='ok',
                   latest_execution=execution('j-watch', 'running', minute(t0) - datetime.timedelta(minutes=2))),
        job_record('j-once', 'Pay the venue deposit', 'inbox',
                   {'kind': 'once', 'run_at': iso(run_at), 'display': run_at.strftime('once at %Y-%m-%d %H:%M')},
                   next_run_at=iso(run_at)),
        job_record('j-paused', 'Nightly finance report', 'finance', {'kind': 'cron', 'expr': '0 2 * * *', 'display': '0 2 * * *'},
                   enabled=False, state='paused', last_run_at=iso((t0 - datetime.timedelta(days=3)).replace(hour=2, minute=0, second=0, microsecond=0)),
                   last_status='ok'),
        job_record('j-fail', 'gbrain-daily-update-check-local', 'research', {'kind': 'cron', 'expr': '0 6 * * *', 'display': '0 6 * * *'},
                   next_run_at=iso((t0 + datetime.timedelta(days=1)).replace(hour=6, minute=0, second=0, microsecond=0)),
                   last_run_at=iso(t0.replace(hour=6, minute=0, second=0, microsecond=0) - datetime.timedelta(days=0 if t0.hour >= 6 else 1)),
                   last_status='error',
                   last_error="RuntimeError: Cron job 'x' has no model configured (job.model=None). Set a per-job model via `hermes cron edit`."),
        job_record('j-late', 'Weekly reading list', 'research', {'kind': 'cron', 'expr': '0 7 * * 1', 'display': '0 7 * * 1'},
                   next_run_at=iso(minute(t0) - datetime.timedelta(minutes=20))),
        job_record('j-done', 'One-off backup', 'default',
                   {'kind': 'once', 'run_at': iso(t0 - datetime.timedelta(days=4)), 'display': 'once at ' + (t0 - datetime.timedelta(days=4)).strftime('%Y-%m-%d %H:%M')},
                   enabled=False, state='completed', last_run_at=iso(t0 - datetime.timedelta(days=4)), last_status='ok'),
        job_record('j-script', 'Disk space check', 'deploys', {'kind': 'cron', 'expr': '*/15 * * * *', 'display': '*/15 * * * *'},
                   no_agent=True, script='check_disk.sh', prompt='', next_run_at=iso(quarter),
                   last_run_at=iso(quarter - datetime.timedelta(minutes=15)), last_status='ok'),
        job_record('j-zone', 'Weekly health check', 'default', {'kind': 'cron', 'expr': '0 6 * * 1', 'display': '0 6 * * 1'},
                   next_run_at=zone_next.isoformat(timespec='seconds')),
    ]
    for job in jobs: JOBS[f"{job['profile']}|{job['id']}"] = job
    # j-triage: three agent runs (sessions), one of them the cwd-less cron session for the Artifacts check.
    triage = []
    day = last_triage
    for n in range(3):
        stamp = day.strftime('%Y%m%d_%H%M%S')
        sid = f'cron_j-triage_{stamp}'
        add_session(sid, 'inbox', f"Morning inbox triage · {day.strftime('%b')} {day.day} 08:00", [
            {'role': 'user', 'content': '[IMPORTANT: You are running as a scheduled cron job. DELIVER your answer to the origin chat.]\n\nTriage the inbox'},
            {'role': 'assistant', 'content': f'Drafted 3 replies. The full triage is in {HOME}/inbox/triage.md.'},
            {'role': 'user', 'content': 'Morning inbox triage'},
            {'role': 'assistant', 'content': 'Drafted 3 replies\n\n' + 'Three threads need you today: the contract redline, the venue deposit, and a reply to Priya. ' * 3},
        ], day.timestamp() + 60, source='cron', listed=False)
        triage.append({'id': sid, 'source': 'cron', 'title': SESSIONS[sid]['title'], 'preview': 'Drafted 3 replies', 'message_count': 4,
                       'started_at': day.timestamp(), 'last_active': day.timestamp() + 60, 'ended_at': day.timestamp() + 60,
                       'is_active': False, 'scheduler_owned': True, 'profile': 'inbox'})
        day = weekday_before(day, 8)
    RUNS['j-triage'] = triage
    watch = minute(t0) - datetime.timedelta(minutes=2)
    wsid = f"cron_j-watch_{watch.strftime('%Y%m%d_%H%M%S')}"
    add_session(wsid, 'deploys', f"release-watch · {watch.strftime('%b')} {watch.day} {watch.strftime('%H:%M')}",
                [{'role': 'user', 'content': '[CRON] Watch the release.'}, {'role': 'assistant', 'content': 'Watching the 2.4 checks.'}],
                watch.timestamp(), source='cron', listed=False)
    RUNS['j-watch'] = [{'id': wsid, 'source': 'cron', 'title': SESSIONS[wsid]['title'], 'preview': 'Watching the 2.4 checks.',
                        'message_count': 2, 'started_at': watch.timestamp(), 'last_active': now(), 'ended_at': None,
                        'is_active': True, 'scheduler_owned': True, 'profile': 'deploys'}]
    RUNS['j-script'] = [
        {'id': 'cron_output:j-script:2026-10-09_08-00-00', 'source': 'cron_output', 'title': 'COMPLETED · Disk 71% used',
         'preview': None, 'message_count': 0, 'started_at': local(T0).replace(hour=8, minute=0, second=0, microsecond=0).timestamp() - 86400,
         'last_active': None, 'ended_at': None, 'is_active': False, 'profile': 'deploys'},
        {'id': 'cron_output:j-script:exec:2', 'source': 'cron_output', 'title': 'FAILED · PermissionError: Permission denied',
         'preview': None, 'message_count': 0, 'started_at': local(T0).replace(hour=7, minute=45, second=0, microsecond=0).timestamp() - 86400,
         'last_active': None, 'ended_at': None, 'is_active': False, 'profile': 'deploys'},
    ]

RUN_DOCUMENT = ('# Cron Job: Disk space check\n\n**Job ID:** j-script\n**Run Time:** 2026-10-09 08:00:00\n\n'
                '## Prompt\n\nRun check_disk.sh and say how full the disk is.\n\n'
                '## Response\n\nDisk 71% used. The largest folder is ~/Library/Caches (12 GB).\n')

def jobs_for(profile):
    rows = list(JOBS.values())
    if profile and profile != 'all': rows = [j for j in rows if j['profile'] == profile]
    return rows

def job_by(jid, profile):
    if profile and f'{profile}|{jid}' in JOBS: return JOBS[f'{profile}|{jid}']
    return next((j for j in JOBS.values() if j['id'] == jid), None)

def broadcast(kind='cron.changed'):
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'session_id': '', 'payload': {}}}
    for send in list(sockets):
        try: send(frame)
        except Exception: sockets.discard(send)

def trigger(job):
    key = f"{job['profile']}|{job['id']}"
    with lock:
        if key in RUNNING: return 409, {'detail': 'Job is already running or was claimed by another scheduler'}
        RUNNING.add(key)
        if not job['enabled'] or job['state'] == 'paused':
            job['enabled'] = True; job['state'] = 'scheduled'
        job['latest_execution'] = execution(job['id'], 'running', local(now()))
    broadcast()
    try:
        time.sleep(TRIGGER_SECONDS)
        with lock:
            stamp = local(now())
            if job['no_agent']:
                RUNS.setdefault(job['id'], []).insert(0, {'id': f"cron_output:{job['id']}:{stamp.strftime('%Y-%m-%d_%H-%M-%S')}",
                    'source': 'cron_output', 'title': 'COMPLETED · Disk 72% used', 'preview': None, 'message_count': 0,
                    'started_at': now(), 'last_active': None, 'ended_at': None, 'is_active': False, 'profile': job['profile']})
            else:
                sid = f"cron_{job['id']}_{stamp.strftime('%Y%m%d_%H%M%S')}"
                add_session(sid, job['profile'], f"{job['name']} · {stamp.strftime('%b')} {stamp.day} {stamp.strftime('%H:%M')}",
                            [{'role': 'user', 'content': f"[IMPORTANT: You are running as a scheduled cron job.]\n\n{job['prompt']}"},
                             {'role': 'assistant', 'content': 'Ran it now. Drafted 2 replies.'}], now(), source='cron', listed=False)
                RUNS.setdefault(job['id'], []).insert(0, {'id': sid, 'source': 'cron', 'title': SESSIONS[sid]['title'],
                    'preview': 'Ran it now. Drafted 2 replies.', 'message_count': 2, 'started_at': now() - TRIGGER_SECONDS,
                    'last_active': now(), 'ended_at': now(), 'is_active': False, 'scheduler_owned': True, 'profile': job['profile']})
            finish_run(job)
            answer = copy.deepcopy(job)
    finally:
        with lock: RUNNING.discard(key)
    broadcast()
    return 200, answer

# ---- kanban -----------------------------------------------------------------------------------------------
HOUR, DAY, MIN = 3600, 86400, 60
KCOLUMNS = ['triage', 'todo', 'scheduled', 'ready', 'running', 'blocked', 'review', 'done']
BOARDS = {}
KSTATE = {'current': 'release-2-4', 'event': 42}

def tid(title): return 't_' + hashlib.sha256(title.encode()).hexdigest()[:8]
def ktask(title, status, assignee, age, **extra):
    t0 = int(now())
    t = {'id': tid(title), 'title': title, 'status': status, 'assignee': assignee, 'priority': extra.pop('priority', 1),
         'created_at': t0 - age, 'comment_count': 0, 'link_counts': {'parents': 0, 'children': 0}, 'progress': None,
         'body': extra.pop('body', title + '.'), 'created_by': 'default', 'latest_summary': None, 'result': None,
         'workspace_path': None, 'model_override': None, 'consecutive_failures': 0, 'parents': [], 'comments': [],
         'events': [{'id': 1, 'kind': 'created', 'payload': {'status': status, 'assignee': assignee}, 'created_at': t0 - age}],
         'attachments': []}
    for key in ('started_at', 'current_run_started_at', 'last_heartbeat_at', 'completed_at'):
        if key in extra: extra[key] = t0 - extra[key]
    comments = extra.pop('comments', 0)
    for n in range(comments):
        t['comments'].append({'id': n + 1, 'author': assignee or 'default', 'created_at': t0 - age + HOUR,
                              'body': 'Want the export section first, or keep the order from the changelog?'})
    t['comment_count'] = comments
    t.update(extra); return t

def seed_kanban():
    BOARDS.clear(); KSTATE['current'] = 'release-2-4'; KSTATE['event'] = 42
    running = ktask('Run the 2.4 test suite', 'running', 'deploys', 40 * MIN, started_at=25 * MIN, current_run_started_at=25 * MIN,
                    latest_summary='148 of 212 checks passed', workspace_path='/Users/demo/.hermes/kanban/boards/release-2-4/workspaces/t_run24',
                    body='Run the whole 2.4 suite on the release branch: unit, UI and the export checks. Note anything flaky, '
                         'file a task for each real failure, write the summary to docs/release/2.4-tests.md and commit.')
    release = [
        ktask('Approve the 2.4 release notes', 'blocked', 'deploys', 3 * HOUR, block_kind='needs_input', comments=2,
              warnings={'count': 1, 'highest_severity': 'warning'}, priority=3,
              body='The notes are drafted. Needs a **yes**, or a list of changes, before the tag goes out.'),
        ktask('Confirm the venue deposit', 'blocked', 'inbox', DAY + 2 * HOUR, block_kind='needs_input', comments=1),
        ktask('Draft the launch thread', 'triage', 'research', 2 * HOUR, priority=0),
        ktask('Collect beta feedback', 'triage', None, 5 * HOUR, priority=0),
        ktask('Record the export demo', 'todo', 'deploys', DAY + 4 * HOUR, priority=2, comments=1),
        ktask('Send the September invoices', 'todo', 'finance', DAY),
        ktask('Publish the 2.4 changelog', 'todo', 'deploys', 3 * HOUR, parents=[running['id']],
              link_counts={'parents': 1, 'children': 0}, body='Waits for the test suite.'),
        ktask('Nightly finance report', 'scheduled', 'finance', 3 * DAY),
        ktask('Tidy the issue tracker', 'ready', None, 2 * HOUR),
        running,
        ktask('Summarize the open-planning paper', 'review', 'research', 6 * HOUR, result='One page, three takeaways'),
        ktask('Cut the 2.4 branch', 'done', 'deploys', 2 * DAY, completed_at=HOUR, result='Branch cut from main at a41f2c9'),
        ktask('Reconcile Q3', 'done', 'finance', 4 * DAY, completed_at=DAY, result='One duplicate charge, disputed'),
        ktask('Archive the 2.2 builds', 'done', 'deploys', 50 * DAY, completed_at=40 * DAY),
    ]
    attach = next(t for t in release if t['title'] == 'Record the export demo')
    attach['attachments'] = [{'id': 'a1', 'task_id': attach['id'], 'filename': 'demo-script.txt', 'content_type': 'text/plain',
                              'size': 64, 'uploaded_by': 'desktop', 'stored_path': '/kanban/a1', 'created_at': int(now()) - HOUR}]
    home = [ktask('Book the pump install', 'ready', 'default', 2 * DAY), ktask('Cover the tomatoes', 'todo', 'default', DAY),
            ktask('Quote for the fence', 'done', 'default', 9 * DAY, completed_at=3 * DAY)]
    BOARDS['release-2-4'] = {'name': 'Release 2.4', 'tasks': {} if EMPTY_KANBAN else {t['id']: t for t in release}}
    BOARDS['home'] = {'name': 'Home', 'tasks': {} if EMPTY_KANBAN else {t['id']: t for t in home}}

def kboard(query):
    slug = (query.get('board') or [''])[0] or KSTATE['current']
    return slug, BOARDS.get(slug)

def public(t, detail=False):
    out = {k: v for k, v in t.items() if k not in ('parents', 'comments', 'events', 'attachments')}
    out['comment_count'] = len(t['comments'])
    if detail and t['status'] == 'blocked' and t.get('block_kind') == 'needs_input':
        out['diagnostics'] = [{'kind': 'needs_input', 'severity': 'warning', 'title': 'Waiting on you',
                               'detail': 'The worker asked a question it cannot answer itself.',
                               'actions': [{'kind': 'unblock', 'label': 'Unblock'}], 'count': 1,
                               'last_seen_at': t['created_at'] + HOUR, 'data': {}}]
    return out

def event(t, kind, payload):
    KSTATE['event'] += 1
    t['events'].append({'id': KSTATE['event'], 'kind': kind, 'payload': payload, 'created_at': int(now())})

def kanban(method, path, query, body):
    if NO_KANBAN: return 404, {'detail': 'Not Found'}
    sub = path[len('/api/plugins/kanban'):]
    slug, board = kboard(query)
    if board is None and sub not in ('/boards', '/profiles', '/orchestration', '/dispatch'):
        return 404, {'detail': f'board {slug} not found'}
    if method == 'GET' and sub == '/boards':
        rows = []
        for s, b in BOARDS.items():
            live = [t for t in b['tasks'].values() if t['status'] != 'archived']
            counts = {}
            for t in live: counts[t['status']] = counts.get(t['status'], 0) + 1
            rows.append({'slug': s, 'name': b['name'], 'description': None, 'is_current': s == KSTATE['current'], 'total': len(live),
                         'counts': counts, 'default_workdir': None, 'default_workspace_kind': 'scratch', 'project_id': None, 'project_name': None})
        return 200, {'boards': rows, 'current': KSTATE['current']}
    if method == 'GET' and sub == '/board':
        live = [t for t in board['tasks'].values() if t['status'] != 'archived']
        columns = []
        for c in KCOLUMNS:
            tasks = [public(t) for t in live if t['status'] == c]
            if c == 'done': tasks.sort(key=lambda t: -(t.get('completed_at') or 0))
            columns.append({'name': c, 'tasks': tasks})
        return 200, {'columns': columns, 'tenants': [], 'assignees': sorted({t['assignee'] for t in live if t['assignee']}),
                     'latest_event_id': KSTATE['event'], 'now': int(now())}
    if method == 'GET' and sub == '/profiles':
        return 200, {'profiles': [{'name': n, 'is_default': n == 'default', 'model': 'hermes-4', 'provider': 'nous', 'description': a,
                                   'description_auto': False, 'skill_count': 4} for n, _, a in BOTS]}
    if method == 'GET' and sub == '/orchestration':
        return 200, {'orchestrator_profile': '', 'default_assignee': '', 'auto_decompose': True,
                     'resolved_orchestrator_profile': 'default', 'resolved_default_assignee': 'default'}
    if method == 'POST' and sub == '/dispatch':
        state['dispatch'] += 1
        return 200, {'spawned': []}
    if sub.startswith('/attachments/'):
        aid = sub.split('/')[2]
        for b in BOARDS.values():
            for t in b['tasks'].values():
                if any(a['id'] == aid for a in t['attachments']): return 200, b'Open on the export menu. Show Markdown, then JSON. Say it is twice as fast.\n'
        return 404, {'detail': 'attachment not found'}
    if method == 'POST' and sub == '/tasks':
        title = (body.get('title') or '').strip()
        if not title: return 400, {'detail': 'title cannot be empty'}
        t = ktask(title, 'triage' if body.get('triage') else 'ready', body.get('assignee'), 0, priority=body.get('priority') or 0,
                  body=body.get('body'))
        t['id'] = 't_' + hashlib.sha256(f'{title}{now()}'.encode()).hexdigest()[:8]
        board['tasks'][t['id']] = t
        event(t, 'created', {'status': t['status'], 'assignee': t['assignee']})
        return 200, {'task': public(t)}
    parts = sub.split('/')
    if len(parts) < 3 or parts[1] != 'tasks': return 404, {'detail': 'not in this fixture'}
    t = board['tasks'].get(parts[2])
    if not t: return 404, {'detail': f'task {parts[2]} not found'}
    tail = '/'.join(parts[3:])
    if method == 'GET' and tail == '':
        links = {'parents': t['parents'], 'children': [x['id'] for x in board['tasks'].values() if t['id'] in x['parents']]}
        titles = [{'id': i, 'title': board['tasks'][i]['title'], 'status': board['tasks'][i]['status']} for i in links['parents'] + links['children'] if i in board['tasks']]
        return 200, {'task': public(t, detail=True), 'comments': t['comments'], 'events': t['events'], 'attachments': t['attachments'],
                     'links': links, 'link_tasks': titles, 'child_results': [],
                     'runs': [{'id': 1, 'profile': t['assignee'], 'status': 'done', 'outcome': 'completed', 'summary': t.get('result'),
                               'error': None, 'started_at': t['created_at'], 'ended_at': t['created_at'] + HOUR}] if t['status'] == 'done' else []}
    if method == 'GET' and tail == 'log':
        running = t['status'] == 'running'
        return 200, {'task_id': t['id'], 'path': '/fixture/worker.log', 'exists': running, 'size_bytes': 80 if running else 0,
                     'content': 'Checked out release/2.4\nRunning 212 checks...\n148 passed so far\n' if running else '', 'truncated': False}
    if method == 'PATCH' and tail == '':
        if 'status' in body:
            to = body['status']
            if to == 'running': return 400, {'detail': "Cannot set status to 'running' directly; use the dispatcher/claim path"}
            if to not in KCOLUMNS + ['archived']: return 400, {'detail': f'unknown status: {to}'}
            if to in ('scheduled', 'review'): return 409, {'detail': f"status transition to '{to}' not valid from current state"}
            if to == 'ready':
                blocking = [board['tasks'][p] for p in t['parents'] if p in board['tasks'] and board['tasks'][p]['status'] != 'done']
                if blocking:
                    b = blocking[0]
                    return 409, {'detail': f"Cannot move to 'ready': blocked by parent(s) not done — '{b['title']}' ({b['id']}, status={b['status']})"}
            t['status'] = to
            if to == 'done': t['completed_at'] = int(now())
            event(t, 'status', {'status': to})
        if 'priority' in body:
            t['priority'] = body['priority']; event(t, 'reprioritized', {'priority': body['priority']})
        if 'body' in body: t['body'] = body['body']; event(t, 'edited', {'field': 'body'})
        if 'title' in body:
            if not str(body['title']).strip(): return 400, {'detail': 'title cannot be empty'}
            t['title'] = body['title']
        return 200, {'task': public(t)}
    if method == 'DELETE' and tail == '':
        del board['tasks'][t['id']]
        return 200, {'deleted': True, 'task_id': t['id']}
    if method == 'POST' and tail == 'comments':
        text = (body.get('body') or '').strip()
        if not text: return 400, {'detail': 'comment body cannot be empty'}
        t['comments'].append({'id': len(t['comments']) + 1, 'author': body.get('author') or 'desktop', 'body': text, 'created_at': int(now())})
        event(t, 'commented', {'author': body.get('author') or 'desktop'})
        return 200, {'ok': True}
    if method == 'POST' and tail == 'reassign':
        t['assignee'] = body.get('profile') or None
        event(t, 'assigned', {'assignee': t['assignee']})
        return 200, {'ok': True, 'task_id': t['id'], 'assignee': t['assignee']}
    if method == 'POST' and tail == 'reclaim':
        if t['status'] != 'running': return 409, {'detail': f"cannot reclaim {t['id']}: not in a claimable state"}
        t['status'] = 'ready'; event(t, 'reclaimed', {})
        return 200, {'ok': True}
    if method == 'POST' and tail == 'estimate':
        return 200, {'ok': True, 'est_tokens': 42000, 'complexity': 'M'}
    return 404, {'detail': 'not in this fixture'}

# ---- tasks ([tasks], hermes-hq-push 0.9.32) ----------------------------------------------------------------
TASKS = {}
TPAGES = {}   # [tasks] what a bot wrote on each task's Task Page (hermes-hq-push 0.9.38's task_pages)
TSTATE = {'rev': 0, 'settings': {}, 'sections': []}
NO_TASKS = False
TASKS_CHAT = False
TASKS_JSON = None   # --tasks-json: a list exported from a real tasks.db (kept out of git), shown first
TASKS_ROUTE = '/api/plugins/hermes-hq-push/tasks'
TMODE = {'older_addon': False}   # [task-ideas] POST /__fixture/tasks-mode: act as an add-on before 0.9.39 (no Ideas)
IDEAS = {}    # [task-ideas] hermes-hq-push 0.9.39's task_ideas: suggested tasks, newest first; off until turned on
ISTATE = {'ran_at': None, 'asked_at': None}

def seed_tasks():
    TASKS.clear()
    TPAGES.clear()
    TSTATE['rev'] = 7 + int(time.time()) % 100000 * 10   # a new run never answers `unchanged` to the last run's cache
    TSTATE['settings'] = {'enabled': True, 'capture': 'ask', 'prep_per_day': 6, 'quiet_start': '22:00', 'quiet_end': '08:00', 'prep_every_hours': 3,
                          'group': 'smart', 'sort': 'smart', 'ideas': False, 'ideas_bot': 'default', 'ideas_at': '07:30', 'ideas_max': 3}
    TSTATE['sections'] = []
    t0 = local(T0)
    today = t0.date()
    def day(n): return (today + datetime.timedelta(days=n)).isoformat()
    def at(n, hour, minute_=0): return iso(datetime.datetime.combine(today + datetime.timedelta(days=n), datetime.time(hour, minute_)).astimezone())
    def ago(minutes): return iso(t0 - datetime.timedelta(minutes=minutes))
    def step(i, title, who, done=False): return {'id': f's{i}', 'title': title, 'who': who, 'done': done}
    def task(tid, title, who='me', bot=None, status='open', note='', due=None, prep=False, steps=(), made=(), notes='',
             source=None, created=600, updated=None, repeat=None, done_at=None, log=()):
        TASKS[tid] = {'id': tid, 'rev': 3, 'title': title, 'notes': notes, 'who': who, 'bot': bot, 'status': status,
                      'status_note': note, 'due': due, 'repeat': repeat, 'prep': prep, 'steps': list(steps), 'made': list(made),
                      'source': source or {'kind': 'app'}, 'created_at': ago(created), 'updated_at': ago(updated if updated is not None else created),
                      'done_at': done_at, 'created_by': 'you' if not source or source.get('kind') != 'chat' else bot or 'default',
                      'log': list(log), 'section': None, 'position': (t0 - datetime.timedelta(minutes=created)).timestamp(),
                      'watch': '', 'chat': {}}
    chat = lambda profile: {'kind': 'chat', 'profile': profile, 'session_id': 's-tasks' if profile == 'default' else bot_chat_id(profile)}
    task('t_dentist', 'Call the dentist', who='together', bot='default', status='ready', note='Number and a Dec 9 slot',
         due=day(0), prep=True, source=chat('default'), created=95, updated=12,
         notes="**Dr. Lee Dental** · (512) 555-0142\nOpen until 5:00 PM today\n\nYour last cleaning was May 2, so you're due. "
               "They have **Dec 9 at 10 AM** open.",
         steps=[step(1, 'Find the office number', 'bot', True), step(2, 'Check when I last went', 'bot', True),
                step(3, 'Call and book', 'me'), step(4, 'Add it to my calendar', 'bot')],
         made=[{'id': 'm1', 'title': 'Office hours and number', 'kind': 'note', 'ref': 'Dr. Lee Dental, (512) 555-0142. Mon-Fri 8-5.'},
               {'id': 'm2', 'title': 'Insurance card (from Files)', 'kind': 'file', 'ref': f'{HOME}/documents/insurance-card.pdf'}],
         log=[{'at': ago(95), 'by': 'default', 'text': 'Added from your chat'},
              {'at': ago(40), 'by': 'default', 'text': 'Found the office number'},
              {'at': ago(12), 'by': 'default', 'text': 'Ready: Number and a Dec 9 slot'}])
    task('t_ivy', 'Reply to Ivy about the venue', who='together', bot='default', status='ready', note='Draft ready',
         due=at(0, 17), prep=True, source=chat('default'), created=300, updated=30,
         steps=[step(1, 'Draft a reply', 'bot', True), step(2, 'Read it and send', 'me')],
         made=[{'id': 'm3', 'title': 'Reply to Ivy (draft)', 'kind': 'note', 'ref': 'Hi Ivy, the Elm Room works for us on the 14th...'}],
         log=[{'at': ago(30), 'by': 'default', 'text': 'Ready: Draft ready'}])
    task('t_passport', 'Renew passport', who='together', bot='default', status='working', note='Filling in the form',
         due=day(0), prep=True, source=chat('default'), created=95, updated=20,
         steps=[step(1, 'Find the renewal form', 'bot', True), step(2, 'Fill in what I know', 'bot', True),
                step(3, 'Get a new photo', 'me'), step(4, 'Mail it with the old passport', 'me')])
    task('t_cleaning', 'Pick up dry cleaning', due=at(0, 18), created=200)
    task('t_invoices', 'Summarize October invoices', who='bot', bot='finance', status='working', note='3 of 5 accounts',
         due=day(1), prep=True, created=500, updated=8,
         steps=[step(1, 'Pull the invoices', 'bot', True), step(2, 'Total by account', 'bot'), step(3, 'Write the summary', 'bot')])
    task('t_venues', 'Find 3 venues for the party', who='bot', bot='research', status='needs_you', note='What’s the budget?',
         due=day(4), prep=True, created=900, updated=25,
         log=[{'at': ago(25), 'by': 'research', 'text': 'Needs you: What’s the budget?'}])
    task('t_gift', 'Mom’s birthday gift', who='together', bot='default', due=day(8), created=1500)
    task('t_porch', 'Fix the porch light', created=4000)
    task('t_water', 'Pay the water bill', status='done', due=day(0), created=3000, updated=90, done_at=ago(90), repeat='monthly')
    task('t_flights', 'Book flights to Austin', who='together', bot='default', status='done', created=5000, updated=1500, done_at=ago(1500))
    # [tasks] UX pass 2026-11-04: shaped like the owner's first live tasks (places and numbers invented). A shortlist
    # written as one paragraph, a 200-character step, the bare "working"/"ready" log lines of 0.9.32/0.9.33, and paths.
    shortlist = f'{HOME}/documents/team-lunch-shortlist.md'
    task('t_lunch', 'Pick a spot for Friday’s team lunch', who='together', bot='default', status='ready',
         note='3 spots ready. Elm & Oak is my pick; pick one and give headcount', due=day(2), prep=True, created=60, updated=5,
         steps=[step(1, 'Shortlist 3 lunch spots near the office (100 Main St) for Fri: group-friendly, takes reservations or '
                        'large-party walk-ins, ~1hr lunch-friendly, with price range, drive time, and', 'bot', True),
                step(2, 'Pick one, confirm headcount, and approve the reservation', 'me')],
         made=[{'id': 'm4', 'title': 'Lunch shortlist: Elm & Oak (pick), Copper Kettle, Bayside Grill (+ Juniper Diner alt)',
                'kind': 'note',
                'ref': 'Elm & Oak: 410 Aspen Dr, ~5 min, $25 lunch prix fixe, book online up to 8 / call 9+ (512) 555-0168. '
                       'Copper Kettle: 402 Aspen Dr, ~5 min, ~$$, OpenTable + semi-private/patio for groups. Bayside Grill: '
                       '15 W Main St, ~6 min, $$-$$$, online up to 4 / call 5+ (512) 555-0177. Alt: Juniper Diner, 17 Harbor '
                       f'Blvd, ~4 min, call (512) 555-0190. Full table: {shortlist}'},
               {'id': 'm5', 'title': 'Shortlist file', 'kind': 'file', 'ref': shortlist}],
         log=[{'at': ago(60), 'by': 'default', 'text': 'Hermes taking the shortlist; you pick + approve booking.'},
              {'at': ago(58), 'by': 'default', 'text': 'working'}, {'at': ago(5), 'by': 'default', 'text': 'ready'}])
    task('t_apps', 'Go through the open job applications', due=at(0, 17), created=120, updated=20, source=chat('default'),
         notes='9 open (Design 3, Support 4, Ops 2). The review flagged what to check: 2 Support date + 1 '
               'Support place mismatches; Ops question wording flaw; 1 Design link broken.',
         log=[{'at': ago(100), 'by': 'default', 'text': f'Prep sheet ready: {HOME}/documents/review-sheet.md (9 open, 3 to check first).'},
              {'at': ago(20), 'by': 'default', 'text': 'Due corrected to today 5 PM'}])

    # [tasks] A task is a workspace (2026-11-04): Inbox watches for a reply and keeps the task's own chat.
    task('t_contract', 'Follow up with Ivy on the contract', who='together', bot='inbox', status='ready',
         note='No reply yet; a nudge is drafted', due=at(1, 10), prep=True, source=chat('inbox'), created=180, updated=15,
         steps=[step(1, 'Check for Ivy’s reply', 'bot', True), step(2, 'Draft a nudge', 'bot', True), step(3, 'Send the nudge', 'me')],
         made=[{'id': 'm6', 'title': 'Nudge to Ivy (draft)', 'kind': 'note',
                'ref': 'Hi Ivy, checking in on the contract. Anything you need from me to get it signed this week?'}],
         log=[{'at': ago(180), 'by': 'inbox', 'text': 'Added from your chat'}, {'at': ago(15), 'by': 'inbox', 'text': 'Ready: No reply yet; a nudge is drafted'}])
    TASKS['t_contract']['watch'] = 'a reply from Ivy with the signed contract, by email'
    # [tasks] 0.9.47 (owner 2026-11-09, the plain task view): one-tap answers, what Inbox just changed, its next look.
    TASKS['t_contract']['choices'] = ['Send the nudge', 'Let me edit it', 'Wait a day']
    TASKS['t_contract']['next_check'] = at(1, 9)
    TASKS['t_contract']['log'].append({'at': ago(15), 'by': 'inbox', 'text': 'Ticked \u201cDraft a nudge\u201d', 'kind': 'change'})
    TASKS['t_venues']['choices'] = ['Under $2,000', 'Under $5,000', 'Not sure yet']
    csid = '20261104_090000_tcsam01'
    add_session(csid, 'inbox', 'Task: Follow up with Ivy on the contract · t_cont', [
        {'role': 'user', 'content': 'Can you keep an eye out for it?\n\nAbout my task “Follow up with Ivy on the contract”\n(Task id t_contract)'},
        {'role': 'assistant', 'content': 'Yes. I’ll check your email an hour before it’s due. If Ivy has replied, I’ll tell you what Ivy said; '
                                         'if not, a short nudge will be ready to send.'},
        {'role': 'user', 'content': 'Keep the nudge friendly, not pushy.'},
        {'role': 'assistant', 'content': 'Done. The draft is under **Made**: one line, friendly, asks if Ivy needs anything from you.'},
    ], (t0 - datetime.timedelta(minutes=15)).timestamp(), hidden=True, listed=False)
    TASKS['t_contract']['chat'] = {'profile': 'inbox', 'session_id': csid}

    # [tasks] Owner's screenshot 2026-11-08: a long needs-you task (a long summary, the same draft saved twice, a reply
    # draft, three steps) whose brief met its chat in a jumble. Names and links invented.
    task('t_redlines', 'Follow up with Dana on Fixture Co redlines', who='together', bot='default', status='needs_you',
         note='Send the reply to Lee, or tell me it already went?', due=at(1, 8), prep=True, source=chat('default'),
         created=900, updated=720,
         steps=[step(1, 'Find Dana\u2019s redlines', 'bot', True), step(2, 'Draft a reply to Lee', 'bot'),
                step(3, 'Send the reply', 'me')],
         made=[{'id': 'm7', 'title': 'Nudge draft to Dana', 'kind': 'link', 'ref': 'https://sparkmailapp.com/d/1a2b'},
               {'id': 'm8', 'title': 'Nudge draft to Dana', 'kind': 'link', 'ref': 'https://sparkmailapp.com/d/3c4d'},
               {'id': 'm9', 'title': 'Reply to Lee (draft)', 'kind': 'link', 'ref': 'https://sparkmailapp.com/d/5e6f'}],
         log=[{'at': ago(900), 'by': 'default', 'text': 'Added from your chat'},
              {'at': ago(720), 'by': 'default', 'text': 'Needs you: Send the reply to Lee, or tell me it already went?'}])
    rsid = '20261107_170000_tcred01'
    add_session(rsid, 'default', 'Task: Follow up with Dana on Fixture Co redlines · t_redl', [
        {'role': 'user', 'content': 'Remind me Monday morning.\n\nAbout my task \u201cFollow up with Dana on Fixture Co redlines\u201d\n(Task id t_redlines)'},
        {'role': 'assistant', 'content': 'Will do. Monday at 8 AM I\u2019ll message you here in chat. Before it goes out, I\u2019ll check '
                                         'whether you\u2019ve already sent the reply, so if you have, it\u2019ll just confirm that instead.\n\n'
                                         'The draft to Lee is still waiting in your Spark drafts, with Dana cc\u2019d. Enjoy your weekend.'},
    ], (t0 - datetime.timedelta(minutes=19)).timestamp(), hidden=True, listed=False)
    TASKS['t_redlines']['chat'] = {'profile': 'default', 'session_id': rsid}
    TPAGES['t_redlines'] = {
        'summary': 'Dana\u2019s redlines came in Thursday at 4:15 PM, in Fixture Co\u2019s own shared doc. She struck auto-renewal and '
                   'the pay-through-termination clause, and asked about the Order Form fees. A reply to Lee is drafted.',
        'next': 'Monday 8 AM I\u2019ll message you to send the draft to Lee (or confirm it already went).', 'blocks': []}
    TASKS['t_redlines']['page_at'] = ago(720)

    # [tasks] Task Pages (0.9.38): what Inbox and Hermes wrote on two of them (names and numbers invented).
    TPAGES['t_contract'] = {
        'summary': 'No reply from Ivy yet. A friendly nudge is drafted and ready for you to send.',
        'next': 'You send the nudge; I check your email again tomorrow at 9 AM.',
        'blocks': [{'title': 'At a Glance', 'numbers': [{'label': 'Days since you sent it', 'value': '3'},
                                                        {'label': 'Emails checked', 'value': '14'}]},
                   {'title': 'What I Checked', 'text': '- [x] Your inbox and the **Contracts** folder\n- [x] Ivy’s out-of-office: none\n- [ ] A reply with the signed copy'}]}
    TASKS['t_contract']['page_at'] = ago(15)
    TPAGES['t_lunch'] = {
        'summary': '3 spots shortlisted near the office. **Elm & Oak** is my pick: 5 minutes away, $25 lunch, books online.',
        'next': 'You pick one and give the headcount; I hold the table.',
        'blocks': [{'title': 'Options', 'table': {'columns': ['Spot', 'Price', 'Drive', 'Booking'],
                                                  'rows': [['Elm & Oak', '$25 prix fixe', '5 min', 'Online up to 8'],
                                                           ['Copper Kettle', '$$', '5 min', 'OpenTable, patio'],
                                                           ['Bayside Grill', '$$-$$$', '6 min', 'Call for 5+']]}}]}
    TASKS['t_lunch']['page_at'] = ago(5)

    # [tasks] Ask First 2026-11-04: what bots added from chats weeks ago and nobody touched since sits under "Still
    # Need These?" (Keep / Done / Delete). One a bot works on, or with a date, is not asked about.
    task('t_desk', 'Look into a standing desk', source=chat('default'), created=20 * 1440)
    task('t_sitter', 'Find a plant sitter for December', source=chat('default'), created=17 * 1440)
    task('t_recipes', 'Collect the soup recipes from the group chat', who='together', bot='research', source=chat('research'),
         created=15 * 1440, steps=[step(1, 'Gather the recipes into one note', 'bot'), step(2, 'Pick two to try', 'me')])
    seed_ideas()

def idea_row(iid, title, why='', source='', who='me', bot='default', help='', created=None):
    return {'id': iid, 'created_at': created or iso(local(now())), 'bot': bot, 'title': title, 'why': why, 'source': source,
            'who': who, 'help': help, 'state': 'new', 'task_id': None, 'decided_at': None}

def seed_ideas():
    IDEAS.clear()
    t0 = local(T0)
    def ago(minutes): return iso(t0 - datetime.timedelta(minutes=minutes))
    for row in (
        idea_row('i_registration', 'Renew the car registration', created=ago(182), source='Chat with Hermes, Mon',
                 why='You said it runs out at the end of the month, and the renewal needs the inspection done first.'),
        idea_row('i_internet', 'Compare internet plans before the promo ends', who='together', bot='finance', created=ago(181),
                 source='Chat with Finance, Tue', why='Your promo price ends on the 20th, and you asked which plans cost less.',
                 help='Compare the three plans you named and list the monthly prices.'),
        idea_row('i_offsite', 'Book the team offsite venue', who='together', bot='inbox', created=ago(180),
                 source='Chat with Inbox, yesterday', why='The offsite is in three weeks and the thread never picked a venue.',
                 help='Find three venues near the office for 12 people and draft the booking request.'),
    ):
        IDEAS[row['id']] = row
    ISTATE.update(ran_at=ago(180), asked_at=None)

def ideas_on(): return bool(TSTATE['settings'].get('ideas')) and TSTATE['settings'].get('enabled', True)

def ideas_new(): return sorted((i for i in IDEAS.values() if i['state'] == 'new'), key=lambda i: i['created_at'], reverse=True)

def ideas_page():
    st = TSTATE['settings']
    looking = bool(ISTATE['asked_at']) and ISTATE['asked_at'] > (ISTATE['ran_at'] or '')
    return {'on': ideas_on(), 'bot': st['ideas_bot'], 'at': st['ideas_at'], 'max': st['ideas_max'],
            'ideas': copy.deepcopy(ideas_new()), 'ran_at': ISTATE['ran_at'], 'looking': looking}

def ideas_looked():
    # Look Now's run answers 3 s later with one more idea.
    with lock:
        row = idea_row('i_meals', 'Plan dinners for next week', who='together', bot='research', source='Chat with Research, today',
                       why='You saved the soup recipes and said you want to cook more at home.',
                       help='Pick five dinners from your recipes and make one shopping list.')
        IDEAS.setdefault(row['id'], row)
        ISTATE['ran_at'] = iso(local(now()))
        TSTATE['rev'] += 1

def ideas_route(method, rest, body):
    if rest == 'ideas' and method == 'GET': return 200, ideas_page()
    if rest == 'ideas/run' and method == 'POST':
        if not ideas_on(): return 409, {'detail': 'Ideas is off.'}
        asked = ISTATE['asked_at']
        if asked and asked > iso(local(now() - 900)) and asked > (ISTATE['ran_at'] or ''): return 200, {'started': False}
        ISTATE['asked_at'] = iso(local(now()))
        threading.Timer(3, ideas_looked).start()
        return 200, {'started': True}
    parts = rest.split('/')
    if len(parts) != 3 or method != 'POST': return 405, {'detail': 'Method Not Allowed'}
    row = IDEAS.get(unquote(parts[1]))
    if not row: return 404, {'detail': 'No such idea.'}
    stamp = iso(local(now()))
    if parts[2] == 'dismiss':
        if row['state'] not in ('new', 'expired'): return 409, {'detail': 'That idea was already decided.'}
        row.update(state='dismissed', decided_at=stamp); TSTATE['rev'] += 1
        return 200, {'idea': copy.deepcopy(row)}
    if parts[2] == 'restore':
        if row['state'] != 'dismissed': return 409, {'detail': 'That idea was already decided.'}
        row.update(state='new', decided_at=None); TSTATE['rev'] += 1
        return 200, {'idea': copy.deepcopy(row)}
    if parts[2] == 'add':
        if row['state'] not in ('new', 'expired'): return 409, {'detail': 'That idea was already decided.'}
        start = bool(body.get('start')) and row['who'] != 'me'
        notes = '\n\n'.join(x for x in (row['why'], row['help']) if x)
        code, task = tasks_route('POST', TASKS_ROUTE, {}, {'title': row['title'], 'notes': notes, 'who': row['who'],
                                                         'bot': row['bot'], 'prep': start,
                                                         'source': {'kind': 'idea', 'idea': row['id'], 'profile': row['bot']}})
        if code != 200: return code, task
        if start:
            TASKS[task['id']].update(status='working', status_note='Getting it ready'); task = copy.deepcopy(TASKS[task['id']])
        row.update(state='added', task_id=task['id'], decided_at=stamp); TSTATE['rev'] += 1
        return 200, {'idea': copy.deepcopy(row), 'task': task, 'already': False}
    return 405, {'detail': 'Method Not Allowed'}

def load_tasks_json():
    if not TASKS_JSON: return
    for task in json.load(open(TASKS_JSON)):
        TASKS[task['id']] = task
    TSTATE['rev'] += 1

def tshown(task):
    """A task as the routes send it: with its Task Page's summary and next (hermes-hq-push 0.9.43), each ≤ 300
    characters, an empty one left out, and no `page` at all when the bot wrote neither."""
    out = copy.deepcopy(task)
    body = TPAGES.get(task['id']) or {}
    gist = {k: (body.get(k) or '').strip()[:300] for k in ('summary', 'next') if (body.get(k) or '').strip()}
    if gist: out['page'] = gist
    return out

def tasks_list(since):
    rev = TSTATE['rev']
    if since and since.isdigit() and int(since) == rev: return 200, {'rev': rev, 'unchanged': True}
    rows = sorted(TASKS.values(), key=lambda t: t['created_at'], reverse=True)
    answer = {'rev': rev, 'tasks': [tshown(t) for t in rows], 'settings': dict(TSTATE['settings']),
              'sections': copy.deepcopy(TSTATE['sections']), 'pages': True, 'ideas': len(ideas_new()) if ideas_on() else 0}
    if TMODE['older_addon']:
        answer.pop('ideas')
        answer['settings'] = {k: v for k, v in answer['settings'].items() if not k.startswith('ideas')}
    return 200, answer

def tasks_route(method, path, query, body):
    if NO_TASKS: return 404, {'detail': 'Not Found'}
    rest = path[len(TASKS_ROUTE):].strip('/')
    stamp = iso(local(now()))
    if rest == '' and method == 'GET': return tasks_list((query.get('since') or [''])[0])
    if rest == '' and method == 'POST':
        title = (body.get('title') or '').strip()
        if not title: return 422, {'detail': 'title is required'}
        tid = 't_' + hashlib.sha256(f'{title}{now()}'.encode()).hexdigest()[:10]
        who = body.get('who') or 'me'
        task = {'id': tid, 'rev': 1, 'title': title, 'notes': body.get('notes') or '', 'who': who,
                'bot': (body.get('bot') or 'default') if who != 'me' else None, 'status': 'open', 'status_note': '',
                'due': body.get('due'), 'repeat': body.get('repeat') if who == 'me' else None, 'prep': bool(body.get('prep')),
                'steps': [dict(s, id=s.get('id') or f's{i + 1}', done=bool(s.get('done'))) for i, s in enumerate(body.get('steps') or [])],
                'made': [], 'source': body.get('source') or {'kind': 'app'}, 'created_at': stamp, 'updated_at': stamp,
                'done_at': None, 'created_by': 'you', 'log': [{'at': stamp, 'by': 'you', 'text': 'Added'}],
                'section': body.get('section') if body.get('section') in {x['id'] for x in TSTATE['sections']} else None,
                'position': body.get('position') or now(), 'watch': body.get('watch') or '', 'chat': body.get('chat') or {}}
        TASKS[tid] = task; TSTATE['rev'] += 1
        return 200, copy.deepcopy(task)
    if rest == 'ideas' or rest.startswith('ideas/'):
        if TMODE['older_addon']: return 404, {'detail': 'Not Found'}
        return ideas_route(method, rest, body)
    if rest.startswith('prep-job/') and method == 'POST':
        return 200, {'ok': True}
    if rest == 'sections':   # hermes-hq-push 0.9.36: the whole list in order; a deleted one's tasks go to no section
        if method == 'PUT':
            clean = []
            for i, x in enumerate(body.get('sections') or []):
                name = (x.get('name') or '').strip()[:60]
                if name: clean.append({'id': x.get('id') or 'sec_' + hashlib.sha256(f'{name}{now()}{i}'.encode()).hexdigest()[:8], 'name': name})
            kept = {x['id'] for x in clean}
            for t in TASKS.values():
                if t.get('section') and t['section'] not in kept: t['section'] = None; t['rev'] += 1
            TSTATE['sections'] = clean; TSTATE['rev'] += 1
        return 200, {'rev': TSTATE['rev'], 'sections': copy.deepcopy(TSTATE['sections'])}
    if rest == 'settings':
        if method == 'PUT':
            TSTATE['settings'].update({k: v for k, v in body.items() if k in TSTATE['settings']}); TSTATE['rev'] += 1
        return 200, dict(TSTATE['settings'])
    if rest.endswith('/page') and method == 'GET':   # hermes-hq-push 0.9.38: the task's Task Page, drawn now
        task = TASKS.get(unquote(rest[:-len('/page')]))
        if not task: return 404, {'detail': 'Task not found'}
        spec = importlib.util.spec_from_file_location('task_page', TASK_PAGE)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        try: names = json.loads((query.get('names') or ['{}'])[0])
        except ValueError: names = {}
        page = module.render(task, TPAGES.get(task['id']), names if isinstance(names, dict) else {})
        return 200, ('text/html; charset=utf-8', page.encode())
    task = TASKS.get(unquote(rest))
    if not task: return 404, {'detail': 'Task not found'}
    if method == 'DELETE':
        TASKS.pop(task['id'], None); TSTATE['rev'] += 1
        return 200, {'ok': True}
    if method == 'PATCH':
        if int(body.get('rev', -1)) != task['rev']: return 409, {'detail': {'task': tshown(task)}}
        for key, value in body.items():
            if key in ('rev', 'id', 'created_at', 'created_by', 'log'): continue
            task[key] = value
        if 'status' in body:
            task['done_at'] = stamp if body['status'] == 'done' else None
            task['log'].append({'at': stamp, 'by': 'you', 'text': 'Marked done' if body['status'] == 'done' else f"Status: {body['status']}"})
        task['rev'] += 1; task['updated_at'] = stamp; TSTATE['rev'] += 1
        return 200, tshown(task)
    return 405, {'detail': 'Method Not Allowed'}

def addon_status():
    flags = ['seal', 'ownChats', 'quietStandIns', 'desktopOpens', 'askCards', 'pagePreviews', 'warmup', 'desktopForward',
             'gatewayLogins', 'namedSites', 'deviceAccess', 'liveSteps', 'liveEnds', 'liveQuick', 'terminal']
    body = {flag: True for flag in flags}
    body.update({'replies': 'watcher', 'deviceAccessKinds': ['contacts', 'calendar', 'reminders', 'location', 'photos'],
                 'pluginVersion': '0.9.31' if NO_TASKS else '0.9.44'})
    if not NO_TASKS: body.update(tasks=True, task_pages=True, task_ideas=not TMODE['older_addon'])
    if TMODE['older_addon']: body['pluginVersion'] = '0.9.38'
    return 200, body

# ---- artifacts --------------------------------------------------------------------------------------------
def tool(name, payload): return {'role': 'tool', 'tool_name': name, 'content': json.dumps(payload)}

def seed_sessions():
    SESSIONS.clear()
    base = minute(local(T0)).timestamp()
    for index, (name, title, _) in enumerate(BOTS):
        add_session(bot_chat_id(name), name, 'Bot Chat', [
            {'role': 'user', 'content': 'Morning. Anything for me?'},
            {'role': 'assistant', 'content': f'Morning. {title} here: nothing urgent today.'},
        ], base - 3600 * (index + 1), hidden=True)
    # [tasks] Mockup 4-chat: Hermes adds two tasks with tasks_add; the card goes under its reply.
    def added(tid, title, due):
        return json.dumps({'id': tid, 'rev': 1, 'title': title, 'who': 'together', 'bot': 'default', 'status': 'open', 'due': due,
                           'undo': "Say 'undo' and I'll remove it, or tap Undo in the app"})
    week = (local(T0).date() + datetime.timedelta(days=2)).isoformat()
    later = (local(T0).date() + datetime.timedelta(days=16)).isoformat()
    exchange = [
        {'role': 'user', 'content': 'Ugh, I need to call the dentist this week. And renew my passport before Austin.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_t1', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({'title': 'Call the dentist', 'who': 'together', 'due': week, 'prep': True})}},
            {'id': 'call_t2', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({'title': 'Renew passport', 'who': 'together', 'due': later, 'prep': True})}}]},
        {'role': 'tool', 'tool_call_id': 'call_t1', 'tool_name': 'tasks_add', 'content': added('t_dentist', 'Call the dentist', week)},
        {'role': 'tool', 'tool_call_id': 'call_t2', 'tool_name': 'tasks_add', 'content': added('t_passport', 'Renew passport', later)},
        {'role': 'assistant', 'content': "On it. I added both to your Tasks. I'll find the dentist's number now and start the passport form tonight."},
    ]
    add_session('s-tasks', 'default', 'Dentist and passport', copy.deepcopy(exchange), base - 60)
    # [tasks] hermes-hq-push 0.9.33 (owner, build 755: "it just added it to my to-do list"): a task of yours alone gets
    # "Ask Hermes to Help"; one Hermes can help with is split into steps and its own step starts at once.
    today5 = local(T0).replace(hour=17, minute=0, second=0, microsecond=0).isoformat(timespec='seconds')
    helped = [
        {'role': 'user', 'content': 'Remind me to call the vet tomorrow.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_t3', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({'title': 'Call the vet', 'due': 'tomorrow'})}}]},
        {'role': 'tool', 'tool_call_id': 'call_t3', 'tool_name': 'tasks_add', 'content': json.dumps({
            'id': 't_vet', 'rev': 1, 'title': 'Call the vet', 'who': 'me', 'bot': None, 'status': 'open', 'steps': [], 'prep': False,
            'due': (local(T0).date() + datetime.timedelta(days=1)).isoformat(), 'due_said': 'tomorrow',
            'undo': "Say 'undo' and I'll remove it, or tap Undo in the app"})},
        {'role': 'assistant', 'content': "Added for tomorrow."},
        {'role': 'user', 'content': "I've really gotta remember to go through all of these job applications today."},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_t4', 'type': 'function', 'function': {'name': 'tasks_add', 'arguments': json.dumps({
                'title': 'Go through the open job applications in ADP', 'who': 'together', 'due': 'today 17:00', 'prep': True, 'start_now': True,
                'steps': [{'title': 'Rank all 167, flagged mismatches first', 'who': 'bot'},
                          {'title': 'Review the shortlist', 'who': 'me'}, {'title': 'Move the keepers forward in ADP', 'who': 'me'}]})}}]},
        {'role': 'tool', 'tool_call_id': 'call_t4', 'tool_name': 'tasks_add', 'content': json.dumps({
            'id': 't_apps', 'rev': 1, 'title': 'Go through the open job applications in ADP', 'who': 'together', 'bot': 'default',
            'status': 'open', 'due': today5, 'due_said': 'today, 5:00 PM', 'prep': True,
            'steps': [{'id': 'a1', 'title': 'Rank all 167, flagged mismatches first', 'who': 'bot', 'done': False},
                      {'id': 'a2', 'title': 'Review the shortlist', 'who': 'me', 'done': False},
                      {'id': 'a3', 'title': 'Move the keepers forward in ADP', 'who': 'me', 'done': False}],
            'start': 'started: your Task prep job is working on your step in the background now',
            'undo': "Say 'undo' and I'll remove it, or tap Undo in the app"})},
        {'role': 'assistant', 'content': "Added for today at 5 PM, and I've started on my part: I'm ranking all 167, "
                                         "with the 25 that Juno flagged at the top. You'll get the shortlist well "
                                         "before 5, so all you'll have to do is review it."},
    ]
    # Its own chat too, below the dentist one (testTasks_AskToHelp).
    add_session('s-help', 'default', 'Job applications', copy.deepcopy(helped), base - 1800)
    if TASKS_CHAT:   # --tasks-chat: Hermes's own Bot Chat ends with it too (-HQDebugOpenBot default opens it)
        chat = SESSIONS[bot_chat_id('default')]
        chat['messages'] += [dict(m, id=len(chat['messages']) + i + 1) for i, m in enumerate(copy.deepcopy(exchange + helped))]
        for i, m in enumerate(chat['messages']): m['timestamp'] = base - 60 - (len(chat['messages']) - i) * 5
        chat['last_active'] = base - 60
    research = f'{HOME}/reading'
    # HQN_FIXTURE_LONG_CHAT=1: earlier turns above it, so the transcript reaches under the bar (top edge shots).
    earlier = [m for n in range(8) for m in (
        {'role': 'user', 'content': f'What about paper {n + 1}?'},
        {'role': 'assistant', 'content': f'**Paper {n + 1}** is worth a skim. It shows each step as it happens, which makes '
                                         'long tasks easier to trust, and the appendix has the numbers if you want them.'},
    )] if os.environ.get('HQN_FIXTURE_LONG_CHAT') else []
    add_session('s-reading', 'research', 'Anything worth reading?', earlier + [
        {'role': 'user', 'content': 'Anything worth reading this morning?'},
        {'role': 'assistant', 'content': f'I put a one-page summary in {research}/summary.md and the chart in {research}/results.png. '
                                         'Sources: https://example.org/papers/open-planning and https://example.org/papers/long-memory'},
    ], base - 300)
    add_session('s-report', 'deploys', 'The 2.4 report', [
        {'role': 'user', 'content': 'Send me the report and the page.'},
        {'role': 'assistant', 'content': f'MEDIA:{HOME}/out/report.pdf'},
        {'role': 'assistant', 'content': 'Open [the page](#media:%2Fhome%2Fhermes%2Fsite%2Findex.html)'},
        {'role': 'assistant', 'content': f'MEDIA:{HOME}/app/Sources/App.swift'},
    ], base - 900)
    add_session('s-release', 'deploys', 'Ship the 2.4 release notes', [
        {'role': 'user', 'content': 'Ship the 2.4 release notes.'},
        tool('write_file', {'path': f'{HOME}/app/release-notes.md'}),
        tool('terminal', {'output': f'Saved {HOME}/data/export.csv\nDownloading https://files.pythonhosted.org/packages/x/y/pkg-1.0-py3-none-any.whl'}),
        tool('read_file', {'path': f'{HOME}/app/CHANGELOG.md'}),
        {'role': 'assistant', 'content': 'Done. The notes are drafted.'},
    ], base - 3 * 3600)
    add_session('s-cut', 'inbox', 'A cut-off link', [
        {'role': 'user', 'content': 'Where is the telephony doc?'},
        {'role': 'assistant', 'content': 'see https://telnyx.po…'},
    ], base - 26 * 3600)
    add_session('s-cron-nofolder', 'inbox', 'Morning inbox triage · run without a folder', [
        {'role': 'user', 'content': '[CRON] Summarize.'},
        {'role': 'assistant', 'content': 'wrote ./out/summary.md'},
    ], base - 27 * 3600, source='cron', cwd='')
    add_session('s-missing', 'research', 'An old chart', [
        {'role': 'user', 'content': 'Where did the old chart go?'},
        {'role': 'assistant', 'content': f'{HOME}/gone/old.png'},
    ], base - 2 * 86400)
    add_session('s-big', 'finance', 'The big log', [
        {'role': 'user', 'content': 'Show me the import log.'},
        {'role': 'assistant', 'content': f'{HOME}/big/log.txt'},
    ], base - 3 * 86400)
    for n in range(36):
        add_session(f's-note-{n:02d}', 'research', f'Reading note {n + 1}', [
            {'role': 'user', 'content': f'Note {n + 1}?'}, {'role': 'assistant', 'content': f'Reading note {n + 1}: nothing to keep.'},
        ], base - (4 + n) * 86400)

def listed_sessions(profile):
    rows = [session_row(sid) for sid, s in SESSIONS.items() if s['listed'] and (profile in ('', 'all') or s['profile'] == profile)]
    return sorted(rows, key=lambda r: -r['last_active'])

def png(width, height, pixel):
    raw = b''.join(b'\0' + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))
    chunk = lambda kind, data: struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

def pdf_one_page(text):
    stream = f'BT /F1 24 Tf 72 720 Td ({text}) Tj ET'.encode()
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
               b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    out, offsets = b'%PDF-1.4\n', []
    for i, body in enumerate(objects, 1):
        offsets.append(len(out)); out += f'{i} 0 obj\n'.encode() + body + b'\nendobj\n'
    xref = len(out)
    out += f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode() + b''.join(f'{o:010d} 00000 n \n'.encode() for o in offsets)
    out += f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return out

def make_files(port):
    FILES.mkdir(parents=True, exist_ok=True)
    for kept in FILES.glob('*.versions'): shutil.rmtree(kept, ignore_errors=True)   # [tile-versions] a run starts with none kept
    (FILES / 'summary.md').write_text('---\ntitle: Morning reading\ntags:\n- agents\n- memory\n---\n\n# Morning reading\n\n'
                                      '**Agents that plan in the open.** Showing each step as it happens makes long tasks easier to trust.\n\n'
                                      '- Small models, long memory\n- Evaluating tool use\n\n```python\nprint("three papers")\n```\n\n'
                                      '## Mail removed\n\n'   # [preview-tables] wider than the page: a card that scrolls sideways
                                      '| Sender | Date confirmed | Note |\n|---|---|---|\n'
                                      '| MailPrefs (most junk) | 2026-10-18 | active to 2036 |\n'
                                      '| Catalog list (credit/insurance offers) | 2026-10-18 | 5 yrs |\n'
                                      '| Shop A, Shop B, Shop C, Shop D | 2026-10-18–21 | web form confirmed |\n'
                                      '| Shop E | 2026-10-21 | 6–8 wks |\n\nWatch the mail for 6–8 weeks.\n')
    bars = [(.35, (46, 196, 182)), (.55, (0, 83, 253)), (.8, (148, 121, 255)), (.62, (255, 102, 173)), (.92, (255, 160, 67))]
    def pixel(x, y):
        u = (x - 45) / 62; column = int(u) if u >= 0 else -1; inside = 0 <= column < 5 and u % 1 < .72
        if inside and 350 - bars[column][0] * 280 < y < 350: return bars[column][1]
        return (10, 10, 10) if 350 <= y < 353 and 35 < x < 365 else (247, 245, 240)
    (FILES / 'results.png').write_bytes(png(400, 400, pixel))
    (FILES / 'report.pdf').write_bytes(pdf_one_page('Release 2.4 report'))
    (FILES / 'team-lunch-shortlist.md').write_text('# Friday team lunch\n\n| Place | Drive | Price | Book |\n|---|---|---|---|\n'
                                                  '| Elm & Oak | 5 min | $25 prix fixe | online up to 8 |\n'
                                                  '| Copper Kettle | 5 min | $$ | OpenTable |\n| Bayside Grill | 6 min | $$-$$$ | call 5+ |\n')
    (FILES / 'review-sheet.md').write_text('# Open applications\n\n## Verify first\n- Support date: 2\n- Support place: 1\n')
    (FILES / 'export.csv').write_text('month,invoices,total\nJuly,12,4180\nAugust,14,5020\nSeptember,11,3890\n')
    (FILES / 'release-notes.md').write_text('# Release 2.4\n\n## New\n- Export any chat as Markdown or JSON\n- Sync is about twice as fast\n')
    (FILES / 'index.html').write_text(f'<!doctype html><html><body><h1>Release 2.4</h1><p>Export, faster sync, six fixes.</p>'
                                      f'<img src="http://127.0.0.1:{port}/__fixture/beacon" width="1" height="1"></body></html>')
    # [tiles] A tile: fills its window exactly, no scrolling, headline at the top and a footer at the bottom.
    (FILES / 'tile.html').write_text('<!doctype html><html><head><meta name="viewport" content="width=device-width">'
                                     '<title>Revenue This Week</title>'
                                     '<style>html,body{margin:0;height:100vh;overflow:hidden;background:#f4f4f4}'
                                     'body{display:flex;flex-direction:column;justify-content:space-between;font:16px -apple-system}'
                                     '</style></head><body><h1 style="margin:0">Revenue $12K</h1>'
                                     '<p style="margin:0">Updated Tue 1:30 PM</p></body></html>')
    # [live-tiles] A live tile: read again every 30 s, a button that asks its bot (the lower half, for a tap test).
    (FILES / 'live.html').write_text(live_page(12))
    (FILES / 'App.swift').write_text('import SwiftUI\n\n@main\nstruct ReleaseApp: App {\n    var body: some Scene {\n'
                                     '        WindowGroup { Text("Release 2.4") }\n    }\n}\n')
    line = 'INFO import row ok — 2026-10-09T08:00:00Z\n'
    (FILES / 'log.txt').write_text(line * ((3 << 20) // len(line) + 1))

def live_page(sales):
    return ('<!doctype html><html><head><meta name="viewport" content="width=device-width">'
            '<title>Sales Today</title><meta name="hq-tile-refresh" content="30">'
            '<style>html,body{margin:0;height:100vh;overflow:hidden;background:#eef6ff;font:16px -apple-system}'
            'h1{margin:8px}button{position:absolute;left:0;right:0;bottom:0;height:55%;font-size:18px;border:0;'
            'background:#0053fd;color:#fff}</style></head>'
            f'<body><h1 id="sales">Sales {sales}</h1>'
            '<button data-hermes-send="Add one more sale">Add one</button></body></html>')

def real_file(asked):
    # A file by its name; one in a tile's versions folder ("…/tile.versions/v1.html") keeps that folder ([tile-versions]).
    pure = pathlib.PurePosixPath(asked)
    if pure.parent.name.endswith('.versions'): return FILES / pure.parent.name / pure.name
    return FILES / pure.name

def serve_file(gateway_handler, query, data_url):
    asked = (query.get('path') or [''])[0]
    sid = (query.get('session_id') or [''])[0]
    if sid:
        session = SESSIONS.get(sid)
        if not session: return 404, {'detail': 'Session not found'}
        if not asked.startswith(('/', '~')) and not session['cwd']:
            return 400, {'detail': 'Session working directory is unavailable'}
    if asked == f'{HOME}/profiles/deploys/cron/output/j-script/2026-10-09_08-00-00.md':
        content = RUN_DOCUMENT.encode()
        return 200, ('text/markdown', content)
    real = real_file(asked)
    if not asked or not real.is_file(): return 404, {'detail': 'File not found'}
    data = real.read_bytes()
    kind = mimetypes.guess_type(real.name)[0] or 'application/octet-stream'
    if data_url:
        if len(data) > 16 * 1024 * 1024: return 413, {'detail': 'File too large to preview'}
        return 200, {'dataUrl': f'data:{kind};base64,' + base64.b64encode(data).decode()}
    return 200, (kind, data)

# ---- RPC and socket ---------------------------------------------------------------------------------------
_rpc = fx.rpc
def resumed(sid):
    s = SESSIONS[sid]
    info = {'model': 'hermes-4', 'provider': 'nous', 'cwd': s['cwd'], 'title': s['title'], 'tools': {}, 'skills': {}, 'mcp_servers': [],
            'lazy': True, 'running': False, 'stored_session_id': sid, 'profile_name': s['profile'], 'desktop_contract': 8}
    return {'session_id': runtime(sid), 'resumed': sid, 'session_key': sid, 'stored_session_id': sid, 'messages': [],
            'messages_omitted': True, 'message_count': len(s['messages']), 'status': 'idle', 'running': False, 'inflight': None, 'info': info}

def rpc(method, params):
    with lock: state['rpc'].append({'method': method, 'params': {k: v for k, v in params.items() if k != 'data_url'}})
    profile = params.get('profile') or 'default'
    if method == 'profiles.list': return roster()
    if method == 'session.list':
        rows = [session_row(sid) for sid, s in SESSIONS.items() if s['profile'] == profile and (not params.get('title') or s['title'] == params['title'])]
        return {'sessions': rows, 'total': len(rows)}
    if method in ('session.resume', 'session.activate'):
        sid = find_session(params.get('session_id')) or bot_chat_id(profile if profile in BOT_NAMES else 'default')
        return resumed(sid)
    if method in ('session.info', 'session.get'):
        sid = find_session(params.get('session_id')) or bot_chat_id('default')
        return resumed(sid)['info']
    if method == 'session.active_list':   # [tiles] a tile change still working until /__fixture/turn-end
        with lock: return {'sessions': [{'session_id': rid, 'status': 'running'} for rid in sorted(STREAMING)]}
    # [tiles] New Tile's ask is taken and left running (a bot making a tile works for minutes): the Tiles page's
    # "making" row shows meanwhile.
    if method == 'session.create' and str(params.get('title') or '').startswith('Task: '):
        # [tasks] A task's own chat (2026-11-04): a titled create makes one hidden session per title (a taken title
        # reopens it, as Hermes's titled create does).
        title = params['title']
        sid = next((k for k, v in SESSIONS.items() if v['title'] == title), None)
        if not sid:
            sid = '20261104_120000_tc' + hashlib.sha256(title.encode()).hexdigest()[:6]
            add_session(sid, profile, title, [], now(), hidden=params.get('hidden') is True, listed=False)
        return resumed(sid)
    if method == 'session.create': return resumed(bot_chat_id(profile if profile in BOT_NAMES else 'default'))
    if method == 'prompt.submit' and ('live tile' in json.dumps(params) or 'Change my Hermes HQ Dashboard tile' in json.dumps(params)
                                      or 'I rolled my Hermes HQ tile' in json.dumps(params)   # [tile-versions] after a roll back
                                      or '(Task id ' in json.dumps(params)):   # [tasks] Ask Hermes to Help
        if 'Change my Hermes HQ Dashboard tile' in json.dumps(params) or 'I rolled my Hermes HQ tile' in json.dumps(params):
            with lock: STREAMING.add(params.get('session_id') or '')
        return {'status': 'streaming', 'user_row_id': 1}
    if method == 'prompt.submit' and SESSIONS.get(find_session(params.get('session_id')) or '', {}).get('title', '').startswith('Task: '):
        return {'status': 'streaming', 'user_row_id': 1}   # [tasks] a task's own chat takes any words
    if method == 'prompt.submit': raise ValueError('The pages fixture does not run prompts')
    return _rpc(method, params)
fx.rpc = rpc

def websocket(connection: socket.socket, key: str):
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    wlock = threading.Lock()
    def read(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data
    def send(value):
        body = json.dumps(value).encode(); size = len(body)
        header = bytes([0x81]) + (bytes([size]) if size < 126 else bytes([126]) + struct.pack('>H', size) if size < 65536 else bytes([127]) + struct.pack('>Q', size))
        with wlock: connection.sendall(header + body)
    sockets.add(send)
    try:
        send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {'heartbeat': True, 'change_events': True, 'replay_epoch': 'pages', 'desktop_contract': 8}}})
        fragments = bytearray()
        while True:
            first, second = read(2); opcode, length, final = first & 15, second & 127, bool(first & 128)
            if length == 126: length = struct.unpack('>H', read(2))[0]
            elif length == 127: length = struct.unpack('>Q', read(8))[0]
            mask = read(4) if second & 128 else b'\0\0\0\0'
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(length)))
            if opcode == 8: return
            if opcode == 9:
                with wlock: connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 1: fragments = bytearray(payload)
            elif opcode == 0: fragments.extend(payload)
            else: continue
            if not final: continue
            frame = json.loads(fragments); fragments.clear()
            if 'id' not in frame or 'method' not in frame: continue
            answer = {'jsonrpc': '2.0', 'id': frame['id']}
            try: answer['result'] = rpc(frame['method'], frame.get('params') or {})
            except ValueError as error: answer['error'] = {'code': -32001, 'message': str(error)}
            send(answer)
    except (ConnectionError, OSError, ValueError): return
    finally: sockets.discard(send)
fx.auth.websocket = websocket

# ---- REST -------------------------------------------------------------------------------------------------
_handler = fx.handler
def handler(gateway):
    base = _handler(gateway)
    class Handler(base):
        def body_json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try: return json.loads(raw or b'{}')
            except ValueError: return {}

        def answer(self, status, body):
            if isinstance(body, tuple):
                kind, data = body
                self.send_response(status)
                self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data)
                return
            if isinstance(body, bytes):
                return self.answer(status, ('application/octet-stream', body))
            self.reply(status, body)

        def logged(self, method, body=None):
            url = urlparse(self.path)
            query = {k: v[0] if len(v) == 1 else v for k, v in parse_qs(url.query).items()}
            with lock: state['rest'].append({'method': method, 'path': url.path, 'query': query, 'body': body})
            # A scripted failure or delay for the next matching request.
            for fail in list(fails):
                if fail.get('method', method) == method and fail.get('path') == url.path:
                    if fail.get('delay'):
                        with lock: fails.remove(fail)
                        time.sleep(float(fail['delay']))
                        return None
                    with lock:
                        fail['count'] = int(fail.get('count', 1)) - 1
                        if fail['count'] <= 0: fails.remove(fail)
                    return int(fail.get('status', 500)), {'detail': fail.get('detail', 'boom')}
            return None

        def route(self, method, body):
            url = urlparse(self.path); path, query = url.path, parse_qs(url.query)
            one = lambda key: (query.get(key) or [''])[0]
            if path == '/api/plugins/hermes-hq-push/logs' and method == 'POST':
                # The plugin's own writer (gateway-plugin/hermes-hq-push/perf_logs.py from the web app's reference),
                # into <files>/hq-logs: the native app's diagnostic log upload (HermesKit/Diagnostics/LogUploader.swift).
                spec = importlib.util.spec_from_file_location('perf_logs', PERF_LOGS)
                module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
                try:
                    return 200, module.write(pathlib.Path(FILES) / 'hq-logs', body.get('device', ''), body.get('lines', []),
                                             app=body.get('app', ''), reason=body.get('reason', ''), lost=bool(body.get('lost')))
                except module.LogError as error:
                    return error.status_code, {'detail': error.detail}
            if path == '/api/plugins/hermes-hq-push/cron/working' and method == 'GET':
                # hermes-hq-push 0.9.2: jobs whose latest run's output a bot is still working on (cron_working.py).
                with lock: return 200, {'jobs': list(copy.deepcopy(BOT_WORKING).values())}
            if path == TASKS_ROUTE or path.startswith(TASKS_ROUTE + '/'):
                with lock: return tasks_route(method, path, query, body)
            if path == '/api/plugins/hermes-hq-push/status' and method == 'GET':
                return addon_status()
            if path.startswith('/api/plugins/kanban'):
                with lock: return kanban(method, path, query, body)
            if path == '/api/cron/jobs' and method == 'GET':
                with lock: return 200, copy.deepcopy(jobs_for(one('profile')))
            if path.startswith('/api/cron/jobs/'):
                parts = [unquote(p) for p in path[len('/api/cron/jobs/'):].split('/')]
                with lock: job = job_by(parts[0], one('profile'))
                if not job: return 404, {'detail': 'Job not found'}
                action = parts[1] if len(parts) > 1 else ''
                if method == 'GET' and action == '':
                    with lock: return 200, copy.deepcopy(job)
                if method == 'GET' and action == 'runs':
                    limit = max(1, min(100, int(one('limit') or 20)))
                    with lock: return 200, {'runs': copy.deepcopy(RUNS.get(job['id'], [])[:limit]), 'limit': limit}
                if method == 'POST' and action == 'trigger': return trigger(job)
                if method == 'POST' and action in ('pause', 'resume'):
                    with lock:
                        job['enabled'] = action == 'resume'
                        job['state'] = 'paused' if action == 'pause' else 'scheduled'
                        answer = copy.deepcopy(job)
                    broadcast(); return 200, answer
                if method == 'PUT' and action == '':
                    # Hermes's edit: `{"updates": {...}}`; a schedule string becomes a cron schedule.
                    updates = (body or {}).get('updates') or {}
                    with lock:
                        for k, v in updates.items():
                            if k == 'schedule':
                                job['schedule'] = {'kind': 'cron', 'expr': v, 'display': v}; job['schedule_display'] = v
                            else: job[k] = v
                        answer = copy.deepcopy(job)
                    broadcast(); return 200, answer
                if method == 'DELETE' and action == '':
                    with lock: JOBS.pop(f"{job['profile']}|{job['id']}", None)
                    broadcast(); return 200, {'ok': True}
                return 404, {'detail': 'Not Found'}
            if path == '/api/profiles/sessions' and method == 'GET' and REAL_LISTING and one('profile') in REAL_LISTING:
                return 200, REAL_LISTING[one('profile')]
            if path.startswith('/api/sessions/') and path.endswith('/messages') and method == 'GET' and REAL_LISTING:
                sid = unquote(path[len('/api/sessions/'):].split('/')[0])
                rows = REAL_MESSAGES.get((one('profile') or 'default') + '\x1f' + sid, [])
                limit = int(one('limit') or 100); offset = int(one('offset') or 0)
                page = rows[offset:offset + limit]
                return 200, {'session_id': sid, 'profile': one('profile') or 'default', 'messages': page,
                             'pagination': {'limit': limit, 'offset': offset, 'order': one('order') or 'oldest', 'returned': len(page)}}
            if path in ('/api/profiles/sessions', '/api/sessions') and method == 'GET':
                rows = listed_sessions(one('profile'))
                limit = int(one('limit') or 30); offset = int(one('offset') or 0)
                return 200, {'sessions': rows[offset:offset + limit], 'total': len(rows), 'limit': limit, 'offset': offset}
            if path == '/api/profiles/sessions/sidebar' and method == 'GET':
                rows = sorted((session_row(sid) for sid, s in SESSIONS.items() if not s['hidden'] and s['source'] != 'cron'), key=lambda r: -r['last_active'])
                cron = sorted((session_row(sid) for sid, s in SESSIONS.items() if s['source'] == 'cron'), key=lambda r: -r['last_active'])
                return 200, {'recents': {'sessions': rows}, 'cron': {'sessions': cron}, 'messaging': {'sessions': []}}
            if path.startswith('/api/sessions/') and method == 'GET':
                sid = unquote(path[len('/api/sessions/'):].split('/')[0])
                s = SESSIONS.get(sid)
                if not s: return 404, {'detail': 'Session not found'}
                if path.endswith('/messages'):
                    rows = s['messages'] if one('order') != 'newest' else list(reversed(s['messages']))
                    limit = int(one('limit') or 100); offset = int(one('offset') or 0)
                    page = rows[offset:offset + limit]
                    return 200, {'session_id': sid, 'profile': s['profile'], 'messages': page,
                                 'pagination': {'limit': limit, 'offset': offset, 'order': one('order') or 'oldest', 'returned': len(page)}}
                return 200, session_row(sid)
            if path == '/api/profiles' and method == 'GET':
                return 200, {'profiles': [{'name': n, 'display_name': t, 'is_default': n == 'default', 'path': f'{HOME}/profiles/{n}',
                                           'model': 'hermes-4', 'provider': 'nous'} for n, t, _ in BOTS]}
            if path in ('/api/fs/download', '/api/fs/read-data-url') and method == 'GET':
                return serve_file(self, query, path.endswith('read-data-url'))
            # [tile-versions] The text routes a tile's versions are kept with.
            if path == '/api/fs/read-text' and method == 'GET':
                real = real_file(one('path') or '')
                if not real.is_file(): return 404, {'detail': 'File not found'}
                data = real.read_bytes()
                return 200, {'path': one('path'), 'text': data.decode('utf-8', 'replace'), 'binary': False, 'truncated': False,
                             'byteSize': len(data)}
            if path == '/api/fs/write-text' and method == 'POST':
                real = real_file(body.get('path') or '')
                if not real.parent.is_dir(): return 400, {'detail': 'Parent directory does not exist'}
                real.write_text(body.get('content') or '')
                return 200, {'ok': True, 'path': body.get('path'), 'byteSize': real.stat().st_size}
            if path == '/api/files/mkdir' and method == 'POST':
                real_file((body.get('path') or '') + '/x').parent.mkdir(parents=True, exist_ok=True)
                return 200, {'ok': True, 'path': body.get('path')}
            return None

        def handle_api(self, method):
            body = self.body_json() if method in ('POST', 'PATCH', 'PUT', 'DELETE') else None
            failed = self.logged(method, body)
            if failed: return self.answer(*failed)
            result = self.route(method, body or {})
            if result is None:
                return super().do_GET() if method == 'GET' else self.answer(404, {'detail': 'Not Found'})
            return self.answer(*result)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/state':
                with lock: return self.reply(200, {'rest': state['rest'], 'rpc': state['rpc'], 'dispatch': state['dispatch'], 'beacon': state['beacon']})
            if path == '/__fixture/beacon':
                with lock: state['beacon'] += 1
                return self.answer(200, ('image/png', png(1, 1, lambda x, y: (0, 0, 0))))
            if path.startswith('/api/auth/') or path == '/api/ws' or path.startswith('/__fixture/') or path == '/api/status':
                return super().do_GET()
            return self.handle_api('GET')

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/fail':
                fail = self.body_json()
                with lock: fails.append(fail)
                return self.reply(200, {'ok': True})
            if path == '/__fixture/reset':
                self.body_json()
                reseed()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tasks-mode':   # [task-ideas] {"older_addon": true} and/or {"empty": true} (no tasks)
                mode = self.body_json()
                with lock:
                    TMODE['older_addon'] = bool(mode.get('older_addon'))
                    if mode.get('empty'): TASKS.clear()
                    # "keep_rev": as an add-on update does (before 0.9.40), the list's rev stays, so `?since=` says unchanged
                    if not mode.get('keep_rev'): TSTATE['rev'] += 1
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tile-job':
                # {"status": "error", "error": "…", "model": "…"}: a tile whose last update failed, run by that model.
                body = self.body_json() or {}
                t = local(now())
                with lock:
                    JOBS['deploys|j-tile'] = job_record(
                        'j-tile', 'Revenue tile', 'deploys', {'kind': 'cron', 'expr': '0 * * * *', 'display': '0 * * * *'},
                        prompt=f'Update the Dashboard tile {HOME}/site/tile.html with the dashboard-tile skill. Reply [SILENT].',
                        last_run_at=iso(t - datetime.timedelta(minutes=5)), last_status=body.get('status', 'ok'),
                        last_error=body.get('error'), model=body.get('model'),
                        next_run_at=iso(t + datetime.timedelta(minutes=55)))
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tile-ran':
                # [tiles] The tile's job ran just now and rewrote the page: the app draws it again.
                self.body_json()
                t = local(now())
                with lock:
                    job = JOBS.get('deploys|j-tile')
                    if job: job.update(last_run_at=iso(t), last_status='ok', last_error=None)
                    page = (FILES / 'tile.html').read_text().replace('Revenue $12K', 'Revenue $14K')
                    (FILES / 'tile.html').write_text(page)
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tile-edit':
                # [tile-versions] The tile's bot edited the page's look: {"from","to"} in its text.
                edit = self.body_json()
                with lock:
                    page = (FILES / 'tile.html').read_text().replace(edit.get('from', ''), edit.get('to', ''))
                    (FILES / 'tile.html').write_text(page)
                return self.reply(200, {'ok': True})
            if path == '/__fixture/live-bump':
                # [live-tiles] The live tile's page changes on disk (no broadcast: its own refresh reads it).
                self.body_json()
                with lock:
                    (FILES / 'live.html').write_text(live_page(13))
                return self.reply(200, {'ok': True})
            if path == '/__fixture/broadcast':
                kind = self.body_json().get('type') or 'cron.changed'
                broadcast(kind)
                return self.reply(200, {'ok': True, 'sockets': len(sockets)})
            if path == '/__fixture/finish':
                body = self.body_json(); jid = body.get('job_id')
                with lock:
                    job = next((j for j in JOBS.values() if j['id'] == jid), None)
                    if not job: return self.reply(404, {'detail': 'Job not found'})
                    finish_run(job)
                    if body.get('bot'):
                        BOT_WORKING[f"{job['profile']}|{jid}"] = {
                            'profile': job['profile'], 'id': jid, 'status': body['bot'],
                            'run': (job.get('latest_execution') or {}).get('id') or f'exec-{jid}', 'since': iso(local(now()))}
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/bot-done':
                jid = self.body_json().get('job_id')
                with lock:
                    for key in [k for k, row in BOT_WORKING.items() if row['id'] == jid]: del BOT_WORKING[key]
                broadcast()
                return self.reply(200, {'ok': True})
            if path == '/__fixture/turn-end':
                # [tiles] The last streaming prompt whose words hold `match` ends: its reply `text` streams and completes
                # (or an `error` ends it), as a bot's turn ends on Hermes.
                body = self.body_json()
                match = body.get('match') or ''
                with lock:
                    asks = [r for r in state['rpc'] if r['method'] == 'prompt.submit' and match in json.dumps(r['params'])]
                if not asks: return self.reply(404, {'detail': 'No such prompt'})
                rid = asks[-1]['params'].get('session_id') or ''
                with lock: STREAMING.discard(rid)
                def event(kind, payload):
                    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'session_id': rid, 'payload': payload}}
                    for send in list(sockets):
                        try: send(frame)
                        except Exception: sockets.discard(send)
                if body.get('error'):
                    event('error', {'message': body['error']})
                else:
                    text = body.get('text') or ''
                    sid = find_session(rid)
                    if sid:
                        with lock:
                            SESSIONS[sid]['messages'].append({'id': len(SESSIONS[sid]['messages']) + 1, 'role': 'assistant',
                                                              'content': text, 'timestamp': now()})
                    event('message.delta', {'text': text})
                    event('message.complete', {'text': text, 'status': 'complete'})
                return self.reply(200, {'ok': True, 'session_id': rid})
            if path == '/__fixture/append':
                body = self.body_json()
                with lock:
                    s = SESSIONS.get(body.get('session_id'))
                    if not s: return self.reply(404, {'detail': 'Session not found'})
                    s['messages'].append({'id': len(s['messages']) + 1, 'role': body.get('role') or 'assistant',
                                          'content': body.get('text') or '', 'timestamp': now()})
                    s['last_active'] = now()
                return self.reply(200, {'ok': True, 'message_count': len(s['messages'])})
            if path.startswith('/auth/') or path.startswith('/api/auth/') or path.startswith('/__fixture/'):
                return super().do_POST()
            return self.handle_api('POST')

        def do_PATCH(self): return self.handle_api('PATCH')
        def do_DELETE(self): return self.handle_api('DELETE')
        def do_PUT(self): return self.handle_api('PUT')
    return Handler
fx.handler = handler

def reseed():
    global T0
    with lock:
        T0 = time.time()
        state['rest'].clear(); state['rpc'].clear(); state['dispatch'] = 0; state['beacon'] = 0
        fails.clear()
        TMODE['older_addon'] = False
        seed_sessions(); seed_jobs(); seed_kanban(); seed_tasks(); load_tasks_json()

def ticker(seconds):
    while True:
        time.sleep(seconds)
        broadcast()

def main():
    global NO_KANBAN, EMPTY_KANBAN, TRIGGER_SECONDS, FILES, NO_TASKS, TASKS_CHAT, TASKS_JSON
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=9735)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--files', required=True)
    parser.add_argument('--no-kanban', action='store_true')
    parser.add_argument('--no-tasks', action='store_true')   # [tasks] an add-on older than 0.9.32
    parser.add_argument('--tasks-chat', action='store_true')   # [tasks] Hermes's Bot Chat ends with the tasks_add exchange
    parser.add_argument('--tasks-json')   # [tasks] add tasks exported from a real tasks.db (a private file, never committed)
    parser.add_argument('--empty-kanban', action='store_true')
    parser.add_argument('--trigger-seconds', type=float, default=3)
    parser.add_argument('--tick-seconds', type=float, default=60)
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--hermes-cookies', action='store_true')
    args = parser.parse_args()
    NO_KANBAN, EMPTY_KANBAN, TRIGGER_SECONDS = args.no_kanban, args.empty_kanban, args.trigger_seconds
    NO_TASKS, TASKS_CHAT, TASKS_JSON = args.no_tasks, args.tasks_chat, args.tasks_json
    FILES = pathlib.Path(args.files)
    make_files(args.port)
    reseed()
    if args.tick_seconds > 0: threading.Thread(target=ticker, args=(args.tick_seconds,), daemon=True).start()
    sys.argv = [sys.argv[0], '--port', str(args.port), '--credentials', args.credentials] + \
               (['--keep-credentials'] if args.keep_credentials else []) + (['--hermes-cookies'] if args.hermes_cookies else [])
    print(f'Pages fixture listening on 127.0.0.1:{args.port}', flush=True)
    fx.main()

if __name__ == '__main__': main()
