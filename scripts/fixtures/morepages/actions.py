"""Status & Maintenance and Usage (once Command Center; docs/spec/3x-morepages.md §15): status, logs, usage and the long-running actions.

Not NEW: these routes exist on every gateway (`AG/hermes_cli/web_routers/status.py`, `analytics.py`, `actions.py`,
`ops.py`). Invented data only.

  GET  /api/status                      the base answer plus `status_extra()` (merged by the loader)
  GET  /api/logs?file=&lines=&level=    500 seeded lines with levels; `level` is a minimum (WARNING shows errors too)
  GET  /api/analytics/usage?days=N      90 seeded days
  GET  /api/hermes/update/check         3 commits behind until an update finishes
  POST /api/gateway/restart             a 3 s action; the sockets really drop for 2 s (`ctx.drop_sockets`)
  POST /api/hermes/update               a 6 s action with progress lines; the gateway restarts at its end
  POST /api/ops/doctor | security-audit | backup     1.5 s actions (the doctor has a failing check, exit code 1)
  GET  /api/actions/<name>/status?lines=N

Knobs, `POST /__fixture/actions {..}` (merged; cleared by /__fixture/reset):
  "restart": "fail" | "exit1"       the POST answers 500 | the action ends with exit code 1
  "restart_seconds": 3, "drop_seconds": 2
  "blackout": true                   the action status answers 503 while the sockets are down
  "update": "fail" | "refused"      the update ends with exit code 1 after 3 s | the POST answers ok:false + message
  "update_seconds": 6
  "behind": 0 | null | N, "can_apply": false, "update_message": "..."
  "doctor_seconds": 1.5
  "logs": "huge" | "empty"          5,000 lines of 4,000 characters | none
  "usage": "empty"                   a gateway nobody used yet
  "old": true                        an older gateway's trimmed status and usage (fewer keys, nulls, numbers as text)
  "status_delay": seconds, "status_fail": N    /api/status sleeps | drops the connection N times (it is not behind
                                     /__fixture/fail: sign-in reads it too)
"""
import datetime, random, threading, time

ACTION_NAMES = ('gateway-restart', 'hermes-update', 'doctor', 'security-audit', 'backup')
KNOBS = {}
ACTIONS = {}        # name -> {'started', 'seconds', 'lines': [(at, text)], 'exit', 'pid'}
GENERATION = [0]
UPDATED = [False]
LOGS = []
USAGE = []
MODELS = [('hermes-4', 0.62), ('claude-opus-5', 0.27), ('gemma-3-27b', 0.11)]
SKILLS = [('release-notes', 41, 3), ('inbox-triage', 33, 0), ('web-research', 18, 2), ('invoice-reader', 9, 0), ('calendar', 4, 1)]


def seed():
    GENERATION[0] += 1
    KNOBS.clear(); ACTIONS.clear(); UPDATED[0] = False
    rng = random.Random(15)
    LOGS.clear()
    start = datetime.datetime.now().replace(microsecond=0) - datetime.timedelta(seconds=500 * 7)
    parts = ['gateway.run', 'agent.loop', 'tools.terminal', 'cron.scheduler', 'gateway.platforms.telegram']
    words = {'INFO': ['Turn finished in 4.2s', 'Session resumed', 'Heartbeat ok', 'Cron tick: 0 jobs due', 'Delivered reply to chat'],
             'DEBUG': ['Cache hit for prompt prefix', 'Polling for updates'],
             'WARNING': ['Slow provider answer (12.4s)', 'Retrying after a rate limit (attempt 2)', 'Config key display.compact is deprecated'],
             'ERROR': ['Provider answered 529: overloaded', 'Telegram send failed: timed out', 'Tool terminal exited with code 127']}
    for index in range(500):
        roll = rng.random()
        level = 'ERROR' if roll < 0.08 else 'WARNING' if roll < 0.22 else 'DEBUG' if roll < 0.30 else 'INFO'
        stamp = (start + datetime.timedelta(seconds=index * 7)).strftime('%Y-%m-%d %H:%M:%S') + f',{rng.randrange(1000):03d}'
        LOGS.append(f'{stamp} {level} {rng.choice(parts)}: {rng.choice(words[level])} [{index + 1}]\n')
    USAGE.clear()
    for back in range(90):
        quiet = back % 7 in (5, 6)
        sessions = rng.randrange(1, 4) if quiet else rng.randrange(4, 19)
        tokens_in = sessions * rng.randrange(18_000, 61_000)
        tokens_out = sessions * rng.randrange(2_000, 9_000)
        USAGE.append({'back': back, 'input_tokens': tokens_in, 'output_tokens': tokens_out,
                      'cache_read_tokens': tokens_in // 3, 'reasoning_tokens': tokens_out // 5,
                      'estimated_cost': round((tokens_in * 3 + tokens_out * 15) / 1_000_000, 4),
                      'actual_cost': 0, 'sessions': sessions, 'api_calls': sessions * rng.randrange(3, 12)})


def knob(name, default=None): return KNOBS.get(name, default)


# ---- status ---------------------------------------------------------------------------------------------------
def status_extra():
    delay = float(knob('status_delay') or 0)
    if delay: time.sleep(delay)
    if int(knob('status_fail') or 0) > 0:
        KNOBS['status_fail'] = int(KNOBS['status_fail']) - 1
        raise ConnectionError('fixture: /api/status dropped')
    restarting = running('gateway-restart')
    version = '0.22.0' if UPDATED[0] else '0.21.5'
    if knob('old'):
        return {'version': version, 'gateway_running': not restarting, 'active_sessions': '2'}
    now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
    return {
        'version': version, 'release_date': '2026.10.01', 'config_version': 17, 'latest_config_version': 17,
        'can_update_hermes': True, 'gateway_running': not restarting,
        'gateway_state': 'restarting' if restarting else 'running', 'gateway_pid': 4242, 'gateway_updated_at': now,
        'gateway_exit_reason': None, 'gateway_heartbeat_stale_s': None, 'active_agents': 1, 'active_sessions': 3,
        'hermes_home': ctx.home + '/.hermes', 'overall': 'degraded',
        'gateway_platforms': {
            'telegram': {'state': 'connected', 'updated_at': now},
            'discord': {'state': 'error', 'updated_at': now, 'error_message': 'Login failed: the bot token was refused.'},
            'slack': {'state': 'disconnected', 'updated_at': now},
        },
    }


# ---- actions --------------------------------------------------------------------------------------------------
def running(name):
    action = ACTIONS.get(name)
    return bool(action) and time.time() - action['started'] < action['seconds']


def begin(name, seconds, lines, exit_code=0, at_end=None):
    stamp = time.strftime('%Y-%m-%d %H:%M:%S')
    ACTIONS[name] = {'started': time.time(), 'seconds': seconds, 'exit': exit_code, 'pid': 5000 + len(ACTIONS),
                     'lines': [(0, f'=== {name} started {stamp} ===')] + lines}
    ctx.wrote('actions', name)
    if at_end:
        generation = GENERATION[0]
        def later():
            if generation == GENERATION[0]: at_end()
        threading.Timer(seconds, later).start()
    return 200, {'ok': True, 'pid': ACTIONS[name]['pid'], 'name': name}


def action_status(name, count):
    if name not in ACTION_NAMES: return 404, {'detail': f'Unknown action: {name}'}
    if knob('blackout') and ctx_down(): return 503, {'detail': 'Service Unavailable'}
    action = ACTIONS.get(name)
    if not action: return 200, {'name': name, 'running': False, 'exit_code': None, 'pid': None, 'lines': []}
    elapsed = time.time() - action['started']
    done = elapsed >= action['seconds']
    lines = [text for at, text in action['lines'] if at <= elapsed]
    return 200, {'name': name, 'running': not done, 'exit_code': action['exit'] if done else None, 'pid': action['pid'],
                 'lines': lines[-max(1, min(count, 2000)):]}


DOWN = [0.0]
def ctx_down(): return time.time() < DOWN[0]


def drop(seconds):
    DOWN[0] = time.time() + seconds
    ctx.drop_sockets(seconds)


def restart():
    mode = knob('restart')
    if mode == 'fail': return 500, {'detail': 'Failed to restart gateway: launchctl answered 5'}
    seconds = float(knob('restart_seconds', 3))
    lines = [(0.2, 'Stopping gateway (pid 4242)…'), (1.2, 'Waiting for running turns to drain…'), (2.2, 'Starting gateway…')]
    if mode == 'exit1':
        lines.append((seconds, 'Gateway did not come back: port 8642 is still in use'))
        answer = begin('gateway-restart', seconds, lines, exit_code=1)
    else:
        lines.append((seconds, '✓ Gateway restarted'))
        answer = begin('gateway-restart', seconds, lines)
    generation = GENERATION[0]
    def later():
        if generation == GENERATION[0]: drop(float(knob('drop_seconds', 2)))
    threading.Timer(0.3, later).start()      # after this answer is out
    return answer


def update():
    mode = knob('update')
    if mode == 'refused':
        message = 'Hermes is managed by Docker here. Pull the new image on your gateway computer.'
        return 200, {'ok': False, 'pid': None, 'name': 'hermes-update', 'error': 'docker_update_unsupported',
                     'message': message, 'update_command': 'docker compose pull'}
    if running('hermes-update'):
        return 200, {'ok': True, 'pid': ACTIONS['hermes-update']['pid'], 'name': 'hermes-update', 'already_running': True}
    if mode == 'fail':
        lines = [(0.3, '⚕ Updating Hermes Agent…'), (1.0, '→ Fetching origin…'), (2.0, '→ Installing dependencies…'),
                 (3.0, 'error: Your local changes to the following files would be overwritten by merge:'),
                 (3.0, '    hermes_cli/config.py'), (3.0, '✗ Update failed. Nothing was changed.')]
        return begin('hermes-update', 3.0, lines, exit_code=1)
    seconds = float(knob('update_seconds', 6))
    step = seconds / 6
    lines = [(0.3, '⚕ Updating Hermes Agent…'), (step, '→ Fetching origin…'), (step * 2, '→ 3 new commits'),
             (step * 3, '→ Installing dependencies…'), (step * 4, '→ Migrating config (17 → 17)…'),
             (step * 5, '→ Restarting gateway…'), (seconds, '✓ Hermes updated to 0.22.0')]
    def finished():
        UPDATED[0] = True
        drop(1.5)
    return begin('hermes-update', seconds, lines, at_end=finished)


def update_check():
    behind = 0 if UPDATED[0] else knob('behind', 3)
    can_apply = knob('can_apply', True)
    answer = {'install_method': 'git' if can_apply else 'docker', 'current_version': '0.22.0' if UPDATED[0] else '0.21.5',
              'behind': behind, 'update_available': bool(behind and behind > 0), 'can_apply': bool(can_apply),
              'update_command': 'hermes update', 'message': knob('update_message')}
    if behind is None and not answer['message']: answer['message'] = "Couldn't reach the update source — try again later."
    if behind == 0 and not answer['message']: answer['message'] = "You're on the latest version."
    if behind and behind > 0:
        answer['commits'] = [{'sha': f'{0xabc1230 + n:07x}', 'summary': f'Invented change {n + 1}', 'author': 'Fixture',
                              'at': int(time.time()) - 3600 * (n + 1)} for n in range(min(int(behind), 20))]
    return 200, answer


def doctor():
    lines = [(0.2, '🩺 Hermes Doctor'), (0.3, ''), (0.4, '◆ Python Environment'), (0.4, '  ✓ Python 3.12.4'),
             (0.6, '◆ Configuration Files'), (0.6, '  ✓ config.yaml exists'), (0.8, '  ✓ .env file exists'),
             (1.0, '◆ Providers'), (1.0, '  ✓ nous: key works'),
             (1.2, '  ✗ openrouter: the key was refused (401). Run: hermes setup openrouter'),
             (1.4, ''), (1.4, 'Found 1 issue(s) to address.')]
    return begin('doctor', float(knob('doctor_seconds', 1.5)), lines, exit_code=1)


def security_audit():
    lines = [(0.2, 'Hermes Security Audit'), (0.5, '  ✓ No secrets in config.yaml'), (0.8, '  ✓ Dashboard is behind sign-in'),
             (1.1, '  ! 1 skill may run shell commands: release-notes'), (1.4, 'Audit finished: 0 critical, 1 note.')]
    return begin('security-audit', float(knob('doctor_seconds', 1.5)), lines)


def backup():
    archive = ctx.home + '/.hermes/backups/hermes-backup-2026-10-13-091500-ab12cd34.zip'
    lines = [(0.2, 'Backing up config, memories, skills and sessions…'), (0.9, '  412 files'), (1.4, f'✓ Backup written to {archive}')]
    status, answer = begin('backup', float(knob('doctor_seconds', 1.5)), lines)
    answer['archive'] = archive
    return status, answer


# ---- logs and usage -------------------------------------------------------------------------------------------
ORDER = {'DEBUG': 0, 'INFO': 1, 'WARNING': 2, 'ERROR': 3, 'CRITICAL': 4}
def logs(query):
    file = ctx.one(query, 'file', 'agent')
    if file not in ('agent', 'errors', 'gateway', 'gui', 'desktop', 'update', 'handoff'):
        return 400, {'detail': f'Unknown log file: {file}'}
    count = int(ctx.one(query, 'lines', '100') or 100)
    level = ctx.one(query, 'level', '').upper()
    if knob('logs') == 'empty': return 200, {'file': file, 'lines': []}
    if knob('logs') == 'huge':
        rows = []
        for index in range(5000):
            which = 'ERROR' if index % 9 == 0 else 'WARNING' if index % 5 == 0 else 'INFO'
            head = f'2026-10-13 09:{index // 60 % 60:02d}:{index % 60:02d},000 {which} agent.loop: line {index + 1} '
            rows.append(head + ('x' * 79 + ' ') * 50 + '\n')
            rows[-1] = rows[-1][:3999] + '\n'
    else:
        rows = LOGS[-min(count, 500):] if not level or level == 'ALL' else LOGS
    if level and level != 'ALL':
        if level not in ORDER: return 200, {'file': file, 'lines': []}
        rows = [row for row in rows if ORDER.get(row.split(' ')[2], 0) >= ORDER[level]]
        if knob('logs') != 'huge': rows = rows[-min(count, 500):]
    return 200, {'file': file, 'lines': rows}


def usage(query):
    try: days = int(ctx.one(query, 'days', '30'))
    except ValueError: return 422, {'detail': 'days must be a number'}
    if not 1 <= days <= 365: return 422, {'detail': 'days must be between 1 and 365'}
    empty_skills = {'summary': {'total_skill_loads': 0, 'total_skill_edits': 0, 'total_skill_actions': 0, 'distinct_skills_used': 0},
                    'top_skills': []}
    if knob('usage') == 'empty':
        return 200, {'daily': [], 'by_model': [], 'by_task': [], 'period_days': days, 'skills': empty_skills, 'tools': [],
                     'totals': {'total_input': None, 'total_output': None, 'total_cache_read': None, 'total_reasoning': None,
                                'total_estimated_cost': 0, 'total_actual_cost': 0, 'total_sessions': 0, 'total_api_calls': None}}
    today = datetime.date.today()
    rows = [row for row in USAGE if row['back'] < days]
    daily = [dict({k: v for k, v in row.items() if k != 'back'}, day=(today - datetime.timedelta(days=row['back'])).isoformat())
             for row in sorted(rows, key=lambda r: -r['back'])]
    total = lambda key: sum(row[key] for row in rows)
    totals = {'total_input': total('input_tokens'), 'total_output': total('output_tokens'),
              'total_cache_read': total('cache_read_tokens'), 'total_reasoning': total('reasoning_tokens'),
              'total_estimated_cost': round(total('estimated_cost'), 4), 'total_actual_cost': 0,
              'total_sessions': total('sessions'), 'total_api_calls': total('api_calls')}
    by_model = [{'model': name, 'input_tokens': int(totals['total_input'] * share), 'output_tokens': int(totals['total_output'] * share),
                 'estimated_cost': round(totals['total_estimated_cost'] * share, 4), 'sessions': max(1, int(totals['total_sessions'] * share)),
                 'api_calls': int(totals['total_api_calls'] * share)} for name, share in MODELS]
    scale = days / 90
    skills = [(name, max(1, int(views * scale)), int(edits * scale)) for name, views, edits in SKILLS]
    actions = sum(v + e for _, v, e in skills)
    top = [{'skill': name, 'view_count': v, 'manage_count': e, 'total_count': v + e, 'percentage': (v + e) / actions * 100,
            'last_used_at': time.time() - 3600 * (n + 1)} for n, (name, v, e) in enumerate(skills)]
    if knob('old'):
        # An older gateway: no skills, no tools, totals as text or null, a day without a date.
        return 200, {'daily': [dict(daily[0], input_tokens=str(daily[0]['input_tokens']))] + daily[1:] + [{'sessions': 1}],
                     'by_model': [{'model': 'hermes-4', 'input_tokens': None, 'output_tokens': '1200'}, {'sessions': 2}],
                     'totals': {'total_input': str(totals['total_input']), 'total_output': None, 'total_sessions': str(totals['total_sessions'])},
                     'period_days': days}
    return 200, {'daily': daily, 'by_model': by_model, 'by_task': [], 'period_days': days, 'totals': totals,
                 'skills': {'summary': {'total_skill_loads': sum(v for _, v, _ in skills), 'total_skill_edits': sum(e for _, _, e in skills),
                                        'total_skill_actions': actions, 'distinct_skills_used': len(skills)}, 'top_skills': top},
                 'tools': [{'tool': 'terminal', 'count': 120, 'percentage': 60.0}, {'tool': 'read_file', 'count': 80, 'percentage': 40.0}]}


# ---- routes ---------------------------------------------------------------------------------------------------
def rest(method, path, query, body, handler):
    if method == 'GET' and path == '/api/logs': return logs(query)
    if method == 'GET' and path == '/api/analytics/usage': return usage(query)
    if method == 'GET' and path == '/api/hermes/update/check': return update_check()
    if method == 'GET' and path.startswith('/api/actions/') and path.endswith('/status'):
        try: count = int(ctx.one(query, 'lines', '200'))
        except ValueError: count = 200
        return action_status(path[len('/api/actions/'):-len('/status')], count)
    if method == 'POST':
        if path == '/api/gateway/restart': return restart()
        if path == '/api/hermes/update': return update()
        if path == '/api/ops/doctor': return doctor()
        if path == '/api/ops/security-audit': return security_audit()
        if path == '/api/ops/backup': return backup()
    return None


def control(path, body):
    if path != '/__fixture/actions': return None
    KNOBS.update(body or {})
    return {'ok': True, 'knobs': dict(KNOBS)}


def state():
    return {'knobs': dict(KNOBS), 'updated': UPDATED[0],
            'actions': {name: {'running': running(name), 'exit': action['exit']} for name, action in ACTIONS.items()}}
