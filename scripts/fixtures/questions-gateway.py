#!/usr/bin/env python3
"""Loopback-only questions fixture (docs/spec/1x-questions.md §6): server→client requests with Hermes' semantics.

Built on the reference performance fixture (itself on build47 + the action-voice fixture): invented state, no upstream
client, never forwards anything. Adds per-socket `client.capabilities`, srq frames (approval, clarify, sudo, secret,
vault.*, desktop panes, setup_choose), response routing (first answer wins, 4404 declines, silent settles),
`clarify.lock`, `approval.respond` / `approval.pending` over a request-id queue, `open_requests` / `pending_approval`
on resume/activate/events.since, `request.cancel` on timeout and interrupt, `approval.cancelled`, strict params (4000)
for the methods the questions stream sends, and a ledger at GET /__fixture/requests (typed values redacted).

Run: python3 scripts/fixtures/questions-gateway.py --port 9720 --credentials build/fixtures/questions.json
Prompt keywords that make a turn ask: approve, approve-once, approve-rule, ask, one, text, long, sudo, sudo-blank,
secret, unlock, login, code, setup, terminal, tour, two-approvals. "job applications" is the Tasks offer (hermes-hq-push
0.9.34's Ask First): a line of reply, one multi-select clarify ("Want help with …?"), then tasks_add for what was picked.
Controls (no auth, loopback): GET|POST /__fixture/ask, POST /__fixture/answer {id,result}, POST /__fixture/cancel
{id,reason}, POST /__fixture/kick, POST /__fixture/event {profile,type,payload}, POST /__fixture/config {approvals_timeout, declines_not_shown, capabilities,
clarify_timeout, pane_timeout, reported_timeout (what /api/config says, for an Expired card)}, POST /__fixture/reset, GET /__fixture/requests.
"""
import base64, hashlib, importlib.util, json, os, pathlib, re, socket, struct, threading, time, uuid
from urllib.parse import urlparse, parse_qs

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
_spec = importlib.util.spec_from_file_location('perf', REF / 'scripts/performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(perf)
base = perf.base; voice = base.voice

LOCK = threading.RLock()
CONFIG = {'approvals_timeout': None, 'declines_not_shown': True, 'capabilities': 'ok', 'clarify_timeout': 3600,
          'pane_timeout': 8}
SOCKETS = {}          # n → Sock
NEXT_SOCKET = [0]
OPEN = {}             # srq id → Req
LEDGER = []           # one dict per request (Req.ledger)
QUEUE = {}            # approval request_id → QueueEntry
RPC_LOG = []          # every RPC this stream sends, params kept (values redacted)
ERRORS_4000 = []
LAST_PROFILE = ['default']
NOT_SHOWN_VALUE = json.dumps({'success': False, 'error': 'No Hermes Desktop window is showing this chat, so its preview, '
                              'terminal and tour are out of reach. Ask the user to open this chat in the Desktop app, then retry.'})

STRICT = {
    'client.capabilities': {'server_requests'},
    'clarify.lock': {'request_id', 'question_id', 'answer', 'profile'},
    'approval.respond': {'session_id', 'profile', 'choice', 'all', 'request_id'},
    'approval.pending': {'session_id', 'profile'},
    'approval.received': {'session_id', 'profile', 'request_id'},
    'session.events.since': {'session_id', 'profile', 'last_seen'},
    'request.answer': {'id', 'result', 'profile'},
}


def runtime(profile):
    return voice.resumed(profile)['session_id']


def redact(result):
    if isinstance(result, dict) and 'value' in result:
        value = result.get('value')
        out = {'value': f'<{len(value)} chars>' if isinstance(value, str) else '<non-string>'}
        if isinstance(value, str) and value.startswith('{'):
            try:
                out['value_keys'] = sorted(json.loads(value).keys())
            except ValueError:
                pass
        return out
    return result


class Sock:
    def __init__(self, n, connection):
        self.n = n
        self.connection = connection
        self.client = base.Client(connection)
        self.advertised = False
        self.connected = True
        self.sessions = set()     # runtime ids this socket attached to (session.resume / session.activate)
        self.frames = []          # methods in arrival order (client → server)

    def send(self, value):
        try:
            self.client.send(value)
            return True
        except OSError:
            return False


class Req:
    def __init__(self, method, profile, params, timeout, qids=None, on_result=None):
        self.id = 'srq-' + uuid.uuid4().hex[:12]
        self.method = method
        self.profile = profile
        self.sid = runtime(profile)
        self.params = dict(params)
        self.timeout = timeout
        self.qids = list(qids) if qids else None
        self.locked = {}
        self.event = threading.Event()
        self.answered = False
        self.result = None
        self.declined = set()
        self.created = time.time()
        self.on_result = on_result
        self.ledger = {'id': self.id, 'method': method, 'profile': profile, 'session_id': self.sid, 'delivered': [],
                       'answers': [], 'outcome': 'open', 'settled_by': None}

    def frame(self):
        return {'jsonrpc': '2.0', 'id': self.id, 'method': self.method, 'params': {'session_id': self.sid, **self.params}}

    def snapshot(self):
        params = {'session_id': self.sid, **self.params}
        if self.locked:
            params['answers'] = dict(self.locked)
        return {'id': self.id, 'method': self.method, 'params': params}


def emit(profile, kind, payload=None):
    base.emit(profile, kind, payload or {})


def emit_cancel(req, reason):
    emit(req.profile, 'request.cancel', {'id': req.id, 'method': req.method, 'reason': reason})


def connected(sid=None):
    """Live sockets; with `sid`, only those attached to that session (Hermes writes a request to the session's
    transport, which fans out to its attached clients)."""
    with LOCK:
        return [s for s in SOCKETS.values() if s.connected and (sid is None or sid in s.sessions)]


def settle(req, *, answered, result, outcome, by):
    """Commit the outcome (caller popped it from OPEN under LOCK)."""
    req.answered, req.result = answered, result
    req.ledger['outcome'] = outcome
    req.ledger['settled_by'] = by
    if req.on_result is not None:
        try:
            req.on_result(result if answered else None)
        except Exception:
            pass
    req.event.set()


def open_request(method, profile, params, timeout, qids=None, on_result=None):
    """Hermes' server_requests.send / send_async: unanswerable when ≥ 1 socket is attached and none advertised."""
    req = Req(method, profile, params, timeout, qids=qids, on_result=on_result)
    with LOCK:
        LEDGER.append(req.ledger)
        sockets = connected(req.sid)
        # An older backend (capabilities answered -32601) has no answerability check: it always writes the frame.
        if sockets and CONFIG['capabilities'] != '-32601' and not any(s.advertised for s in sockets):
            req.ledger['outcome'] = 'unanswerable'
            req.ledger['settled_by'] = 'unanswerable'
            if on_result is not None:
                on_result(None)
            req.event.set()
            return req
        OPEN[req.id] = req
    frame = req.frame()
    for s in sockets:
        if s.send(frame):
            req.ledger['delivered'].append(s.n)
    if timeout is not None and timeout > 0:
        def expire():
            if req.event.wait(timeout):
                return
            with LOCK:
                still = OPEN.pop(req.id, None) is req
            if still:
                if req.qids is not None:
                    settle(req, answered=True, result={'answers': dict(req.locked), 'outcome': 'timed_out'}, outcome='timeout', by='timeout')
                else:
                    settle(req, answered=False, result=None, outcome='timeout', by='timeout')
                emit_cancel(req, 'timeout')
        threading.Thread(target=expire, daemon=True).start()
    return req


def route_response(frame, sock):
    """resolve_response: a 4404 is one client's decline; any other error = unanswered; the first answer wins."""
    rid = frame.get('id')
    if not isinstance(rid, str):
        return
    error = frame.get('error') if isinstance(frame.get('error'), dict) else None
    record = {'socket': sock.n, 'at': time.time(), 'kind': 'error' if error is not None else 'result'}
    if error is not None:
        record['code'] = error.get('code')
        record['message'] = error.get('message')
    else:
        record['result'] = redact(frame.get('result'))
    with LOCK:
        req = OPEN.get(rid)
        entry = next((e for e in LEDGER if e['id'] == rid), None)
        if entry is not None:
            entry['answers'].append(record)
        if req is None:
            record['dropped'] = True
            return
        if error is not None and error.get('code') == 4404:
            req.declined.add(sock.n)
            advertised = {s.n for s in SOCKETS.values() if s.connected and s.advertised and req.sid in s.sessions}
            if not advertised or not advertised <= req.declined:
                return
            OPEN.pop(rid, None)
            result = {'value': NOT_SHOWN_VALUE}
            outcome = 'declined'
        elif error is not None:
            OPEN.pop(rid, None)
            result, outcome = None, 'unanswered'
        else:
            OPEN.pop(rid, None)
            result = frame.get('result') if isinstance(frame.get('result'), dict) else {}
            if req.qids:
                if 'answers' in result:
                    merged = dict(req.locked); merged.update(result.get('answers') or {})
                    result, outcome = {**result, 'answers': merged, 'outcome': 'submitted'}, 'submitted'
                else:
                    result, outcome = {'answers': dict(req.locked), 'outcome': 'cancelled'}, 'skipped'
            else:
                outcome = 'answered'
    settle(req, answered=error is None or outcome == 'declined', result=result, outcome=outcome, by=f'socket {sock.n}')


# ── approval queue (tools/approval.py, approval_gateway_wait.py) ──────────────────────────────────────────────────

class QueueEntry:
    def __init__(self, profile, approval):
        self.request_id = uuid.uuid4().hex
        self.profile = profile
        self.approval = approval    # command, description, pattern_key(s), allow_permanent, allow_session, smart_denied, choices
        self.event = threading.Event()
        self.choice = None
        self.req = None

    def client_safe(self):
        a = self.approval
        return {'request_id': self.request_id, 'command': a['command'], 'description': a['description'],
                'pattern_key': a.get('pattern_key', a['description']), 'pattern_keys': a.get('pattern_keys', [a['description']]),
                'allow_permanent': a.get('allow_permanent', True), 'allow_session': a.get('allow_session', True),
                'smart_denied': a.get('smart_denied', False), 'choices': a['choices'], 'tool_name': a.get('tool_name', 'terminal')}


def resolve_queue(entry, choice, reason):
    """_drop_entry → settle(reason): the srq (if still open) is withdrawn with request.cancel."""
    with LOCK:
        if entry.event.is_set():
            return 0
        entry.choice = choice
        QUEUE.pop(entry.request_id, None)
        req = entry.req
        still = req is not None and OPEN.pop(req.id, None) is req
    entry.event.set()
    if still:
        req.ledger['outcome'] = 'resolved-elsewhere'
        req.ledger['settled_by'] = reason
        req.event.set()
        emit_cancel(req, 'resolved' if reason == 'approval.respond' else reason)
    return 1


def ask_approval(profile, approval, timeout):
    entry = QueueEntry(profile, approval)
    with LOCK:
        QUEUE[entry.request_id] = entry
    params = {k: v for k, v in entry.client_safe().items() if k != 'request_id'}
    params['request_id'] = entry.request_id

    def on_result(result):
        choice = (result or {}).get('choice') if isinstance(result, dict) else None
        with LOCK:
            QUEUE.pop(entry.request_id, None)
            if not entry.event.is_set():
                entry.choice = choice or 'deny'
        entry.event.set()

    entry.req = open_request('approval', profile, params, None, on_result=on_result)
    if not entry.event.wait(timeout):
        with LOCK:
            QUEUE.pop(entry.request_id, None)
            req = entry.req
            still = req is not None and OPEN.pop(req.id, None) is req
            entry.choice = 'deny'
        entry.event.set()
        if still:
            req.ledger['outcome'] = 'timeout'
            req.ledger['settled_by'] = 'timeout'
            req.event.set()
            emit_cancel(req, 'timeout')
        return 'timeout'
    return entry.choice or 'deny'


# ── turns that ask ─────────────────────────────────────────────────────────────────────────────────────────────

FORCE_PUSH = {'command': 'git push --force origin main', 'description': 'git force push (rewrites remote history)',
              'pattern_key': 'git force push (rewrites remote history)', 'pattern_keys': ['git force push (rewrites remote history)'],
              'allow_permanent': True, 'allow_session': True, 'choices': ['once', 'session', 'always', 'deny']}
ONCE_ONLY = {'command': 'rm -rf ./build/cache', 'description': 'recursive delete', 'smart_denied': True,
             'allow_permanent': False, 'allow_session': False, 'choices': ['once', 'deny']}
RULE = {'command': '<browser_exec> (plugin approval rule)', 'description': 'Open https://shop.example.com and click “Publish campaign”',
        'allow_permanent': True, 'allow_session': True, 'choices': ['once', 'session', 'always', 'deny'], 'tool_name': 'browser_exec'}

ASK = [{'qid': 'q0', 'question': 'Which branch should I deploy?', 'choices': ['main (Recommended)', 'staging'], 'multi_select': False},
       {'qid': 'q1', 'question': 'Anything to skip?', 'choices': ['Tests', 'Lint', 'Docs'], 'multi_select': True},
       {'qid': 'q2', 'question': 'What should the release be called?', 'choices': None, 'multi_select': False}]
ONE = [{'qid': 'q0', 'question': 'Which city should I book?', 'choices': ['Lisbon (Recommended)', 'Porto'], 'multi_select': False}]
TEXT = [{'qid': 'q0', 'question': 'What should I name the new project?', 'choices': None, 'multi_select': False}]
_long_reason = ('This option keeps the current layout and only changes the colours, so nothing moves on screen. '
                'It is the safest choice when people already know where everything is. ') * 4
LONG = [{'qid': f'q{i}', 'question': f'Question {i + 1} of 5: how should step {i + 1} work?\nPick the one that fits best.',
         'choices': [f'Option {c} for step {i + 1}\n' + _long_reason[:560].strip() + (' (Recommended)' if c == 'A' else '') for c in 'ABCD'],
         'multi_select': i % 2 == 1} for i in range(5)]

# [tasks] Ask First (hermes-hq-push 0.9.34): what the bot could do for a to-do you mentioned, best first, then "Just
# add it to my list"; skip and nothing is added.
OFFER_TITLE = 'Go through the job applications'
OFFER_JUST_ADD = 'Just add it to my list'
OFFER = [{'qid': 'q0', 'question': f'Want help with “{OFFER_TITLE}”?',
          'choices': ['Rank them, flagged ones first (Recommended)', 'Draft replies to the no’s', 'List who to call back',
                      OFFER_JUST_ADD], 'multi_select': True}]

KEYWORDS = ['two-approvals', 'approve-once', 'approve-rule', 'sudo-blank', 'approve', 'ask', 'one', 'text', 'long', 'sudo',
            'secret', 'unlock', 'login', 'code', 'setup', 'terminal', 'tour']


def keyword(text):
    lowered = (text or '').lower()
    if 'job applications' in lowered:
        return 'offer'
    for k in KEYWORDS:
        if re.search(r'(?<![\w-])' + re.escape(k) + r'(?![\w-])', lowered):
            return k
    return None


def plan(kind):
    """[(tool name, args, method, params, timeout)] for one keyword."""
    approvals = CONFIG['approvals_timeout'] or 300
    if kind == 'approve': return [('terminal', {'command': FORCE_PUSH['command']}, 'approval', FORCE_PUSH, approvals)]
    if kind == 'approve-once': return [('terminal', {'command': ONCE_ONLY['command']}, 'approval', ONCE_ONLY, approvals)]
    if kind == 'approve-rule': return [('browser_exec', {'action': 'click'}, 'approval', RULE, approvals)]
    if kind == 'two-approvals':
        second = dict(FORCE_PUSH, command='git push --force origin release')
        return [('terminal', {'command': FORCE_PUSH['command']}, 'approval', FORCE_PUSH, approvals),
                ('terminal', {'command': second['command']}, 'approval', second, approvals)]
    questions = {'ask': ASK, 'one': ONE, 'text': TEXT, 'long': LONG, 'offer': OFFER}.get(kind)
    if questions is not None:
        return [('clarify', {'questions': [{k: v for k, v in q.items() if k != 'qid'} for q in questions]}, 'clarify',
                 {'questions': questions}, CONFIG['clarify_timeout'])]
    if kind == 'sudo': return [('terminal', {'command': 'sudo apt-get install -y ffmpeg'}, 'sudo', {'command': 'apt-get install -y ffmpeg'}, 120)]
    if kind == 'sudo-blank': return [('terminal', {'command': 'sudo -v'}, 'sudo', {'command': ''}, 120)]
    if kind == 'secret': return [('skill_view', {'name': 'weather'}, 'secret', {'env_var': 'OPENWEATHER_API_KEY', 'prompt': 'Paste your OpenWeather API key'}, 300)]
    if kind == 'unlock': return [('browser_navigate', {'url': 'https://shop.example.com'}, 'vault.unlock_prompt', {'backend': 'bitwarden', 'display_name': 'Bitwarden'}, 120)]
    if kind == 'login': return [('browser_navigate', {'url': 'https://shop.example.com'}, 'vault.save_login', {'origin': 'https://shop.example.com', 'site': 'Example Shop'}, 180)]
    if kind == 'code': return [('browser_navigate', {'url': 'https://shop.example.com'}, 'vault.code', {'site': 'Example Shop', 'hint': 'Text message to •••• 42'}, 180)]
    if kind == 'setup': return [('setup', {}, 'setup_choose', {'kind': 'provider', 'question': 'Which provider?', 'options': ['Nous', 'OpenAI'], 'multi_select': False}, 30)]
    if kind == 'terminal': return [('terminal_read', {}, 'terminal.read', {'start': 0, 'count': 50}, CONFIG['pane_timeout'])]
    if kind == 'tour': return [('tour', {'action': 'start'}, 'tour', {'action': 'start', 'steps': []}, CONFIG['pane_timeout'])]
    return []


def clarify_result(questions, reply):
    answers = (reply or {}).get('answers') or {}
    responses = []
    for q in questions:
        raw = answers.get(q['qid'])
        cleaned = None
        if raw not in (None, ''):
            if q['multi_select']:
                try:
                    parsed = json.loads(raw) if isinstance(raw, str) else raw
                except ValueError:
                    parsed = None
                items = parsed if isinstance(parsed, list) else [raw]
                cleaned = [strip_rec(i) for i in items if str(i).strip()]
            else:
                cleaned = strip_rec(raw)
        status = 'answered' if cleaned else ('skipped' if q['qid'] in answers else 'unanswered')
        responses.append({'question': q['question'], 'choices_offered': [strip_rec(c) for c in q['choices']] if q['choices'] else None,
                          'status': status, 'user_response': cleaned if cleaned else None})
    return {'responses': responses, 'outcome': (reply or {}).get('outcome', 'cancelled')}


def strip_rec(text):
    text = str(text).strip()
    return text[:-len('(Recommended)')].strip() if text.lower().endswith('(recommended)') else text


def persist_tool(profile, name, tool_id, args, result):
    with base.LOCK:
        base.append(profile, 'assistant', '')
        base.MESSAGES[profile][-1]['tool_calls'] = [{'id': tool_id, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(args)}}]
        base.append(profile, 'tool', json.dumps(result) if not isinstance(result, str) else result)
        base.MESSAGES[profile][-1]['tool_call_id'] = tool_id


def offer_added(reply):
    """[tasks] tasks_add for the offer's answer: what was picked as the bot's steps (started), or the task alone for
    "Just add it"; None when skipped (nothing is added)."""
    picked = [strip_rec(c) for c in (((clarify_result(OFFER, reply)['responses'] or [{}])[0]).get('user_response') or [])]
    if not picked:
        return None
    friday = (time.strftime('%Y-%m-%d', time.localtime(time.time() + ((4 - time.localtime().tm_wday) % 7 or 7) * 86400)))
    task = {'id': 't_offer', 'rev': 1, 'title': OFFER_TITLE, 'due': friday, 'due_said': 'Friday',
            'undo': "Say 'undo' and I'll remove it, or tap Undo in the app"}
    mine = [p for p in picked if p != OFFER_JUST_ADD]
    if not mine:
        return dict(task, who='me', bot=None, steps=[]), 'Added it to your list for Friday.'
    steps = [{'id': f'b{i}', 'title': p, 'who': 'bot', 'done': False} for i, p in enumerate(mine)]
    steps.append({'id': 'm0', 'title': 'Decide who moves on', 'who': 'me', 'done': False})
    return (dict(task, who='together', bot='default', prep=True, steps=steps, start='started: your Task prep job is working on it'),
            f'Added to Tasks for Friday. I started on “{mine[0]}” and will tell you when it’s ready.')


def run_ask(profile, kind, cancel):
    if cancel.wait(0.15):
        return
    emit(profile, 'message.start')
    lead = 'Got it, that’s a lot to read cold. ' if kind == 'offer' else ''
    for chunk in re.findall(r'\S+\s*', lead):
        emit(profile, 'message.delta', {'text': chunk})
    if lead and cancel.wait(1.5):   # the card comes after the line, as Hermes writes it (and after the sender's checks)
        return
    words = []
    for name, args, method, params, timeout in plan(kind):
        if cancel.is_set():
            return
        tool_id = f'{name}-{uuid.uuid4().hex[:8]}'
        emit(profile, 'tool.start', {'name': name, 'tool_id': tool_id, 'args': args})
        if method == 'approval':
            choice = ask_approval(profile, params, timeout)
            if cancel.is_set():
                return
            approved = choice in ('once', 'session', 'always')
            result = {'stdout': 'Everything up-to-date\n', 'exit_code': 0} if approved else \
                {'error': 'BLOCKED: the user denied this command' if choice != 'timeout' else
                 'timed out without user response. Silence is not consent.', 'exit_code': 1}
            words.append(f'Approval answered: {choice}.')
        else:
            qids = [q['qid'] for q in params['questions']] if method == 'clarify' else None
            req = open_request(method, profile, params, timeout, qids=qids)
            while not req.event.wait(0.2):
                if cancel.is_set():
                    return
            if cancel.is_set():
                return
            if method == 'clarify' and kind == 'offer':
                reply = req.result if req.answered else {'answers': dict(req.locked), 'outcome': 'cancelled'}
                result = json.dumps(clarify_result(params['questions'], reply), ensure_ascii=False)
                added = offer_added(reply)
                persist_tool(profile, name, tool_id, args, result)
                emit(profile, 'tool.complete', {'name': name, 'tool_id': tool_id, 'args': args, 'result': result})
                if added is None:
                    words.append('Okay, I won’t add it.')
                    continue
                task, said = added
                add_args = {k: task[k] for k in ('title', 'who', 'steps') if task.get(k)} | {'due': 'friday'}
                if task['who'] == 'together':
                    add_args |= {'prep': True, 'start_now': True}
                name, tool_id, args = 'tasks_add', f'tasks_add-{uuid.uuid4().hex[:8]}', add_args
                emit(profile, 'tool.start', {'name': name, 'tool_id': tool_id, 'args': args})
                result = json.dumps(task, ensure_ascii=False)
                words.append(said)
            elif method == 'clarify':
                reply = req.result if req.answered else {'answers': dict(req.locked), 'outcome': 'cancelled'}
                result = json.dumps(clarify_result(params['questions'], reply), ensure_ascii=False)
                words.append('Thanks, I have your answers.' if (reply or {}).get('outcome') == 'submitted' else 'Questions skipped.')
            elif method in ('sudo', 'secret', 'vault.unlock_prompt', 'vault.save_login', 'vault.code'):
                value = (req.result or {}).get('value', '') if req.answered else ''
                result = {'stdout': f'Received {len(value) if isinstance(value, str) else 0} characters.', 'exit_code': 0}
                words.append(f'Received {len(value) if isinstance(value, str) else 0} characters.')
            else:
                result = {'error': 'unanswered' if not req.answered else (req.result or {}).get('value', ''), 'exit_code': 1}
                words.append(f'{method}: {req.ledger["outcome"]}.')
        persist_tool(profile, name, tool_id, args, result)
        emit(profile, 'tool.complete', {'name': name, 'tool_id': tool_id, 'args': args, 'result': result})
    if cancel.is_set():
        return
    text = ' '.join(words) or 'Done.'
    for chunk in re.findall(r'\S+\s*', text):
        if cancel.wait(0.03):
            return
        emit(profile, 'message.delta', {'text': chunk})
    text = lead + text
    row = base.append(profile, 'assistant', text)
    base.RUNNING[profile] = False
    emit(profile, 'message.complete', {'text': text, 'row_id': row})


def start_ask_turn(profile, kind, user_text=None):
    """A running turn that asks (a prompt with a keyword, or /__fixture/ask with nothing running)."""
    with base.LOCK:
        row = base.append(profile, 'user', user_text) if user_text is not None else None
        base.CANCEL[profile].set(); base.CANCEL[profile] = threading.Event(); base.RUNNING[profile] = True
        cancel = base.CANCEL[profile]
    threading.Thread(target=run_ask, args=(profile, kind, cancel), daemon=True).start()
    return row


def ask_in_running(profile, kind):
    """/__fixture/ask while a turn runs (or none): one more request in that chat."""
    if not base.RUNNING.get(profile):
        return start_ask_turn(profile, kind)
    def run():
        cancel = base.CANCEL[profile]
        for name, args, method, params, timeout in plan(kind):
            if method == 'approval':
                ask_approval(profile, params, timeout)
            else:
                qids = [q['qid'] for q in params['questions']] if method == 'clarify' else None
                open_request(method, profile, params, timeout, qids=qids)
    threading.Thread(target=run, daemon=True).start()
    return None


# ── RPCs ───────────────────────────────────────────────────────────────────────────────────────────────────────

def log_rpc(method, params):
    logged = {}
    for k, v in params.items():
        logged[k] = v
    with LOCK:
        RPC_LOG.append({'method': method, 'params': logged, 'at': time.time()})


def strict_error(method, params):
    allowed = STRICT.get(method)
    if allowed is None:
        return None
    for key in params:
        if key not in allowed:
            message = (f'invalid params for {method}: {key}: Extra inputs are not permitted — the client and the Hermes backend '
                       'are out of sync (different versions); run `hermes update` and restart both')
            with LOCK:
                ERRORS_4000.append({'method': method, 'key': key})
            return {'code': 4000, 'message': message}
    return None


def open_snapshots(sid):
    with LOCK:
        reqs = sorted((r for r in OPEN.values() if r.sid == sid), key=lambda r: r.created)
        return [r.snapshot() for r in reqs]


def oldest_pending(profile):
    with LOCK:
        entries = [e for e in QUEUE.values() if e.profile == profile and not e.event.is_set()]
    return entries[0].client_safe() if entries else None


def handle_rpc(sock, frame):
    method = frame['method']; params = frame.get('params') or {}
    rid = frame.get('id')
    answer = {'jsonrpc': '2.0', 'id': rid}
    if method in STRICT or method.startswith('approval.') or method in ('clarify.lock', 'session.interrupt'):
        log_rpc(method, params)
    problem = strict_error(method, params)
    if problem is not None:
        answer['error'] = problem
        return sock.send(answer)
    profile = base.owner(params)
    try:
        if method == 'client.capabilities':
            if CONFIG['capabilities'] == '-32601':
                answer['error'] = {'code': -32601, 'message': 'unknown method: client.capabilities'}
            else:
                sock.advertised = bool(params.get('server_requests'))
                answer['result'] = {'server_requests': ['approval', 'clarify', 'display.install.sudo', 'preview.act', 'preview.read',
                                                        'secret', 'setup_choose', 'sudo', 'terminal.read', 'tour', 'vault.code',
                                                        'vault.save_login', 'vault.unlock_prompt', 'window.read'],
                                    'declines_not_shown': bool(CONFIG['declines_not_shown'])}
        elif method == 'clarify.lock':
            request_id = str(params.get('request_id') or ''); question_id = str(params.get('question_id') or '')
            if not request_id or not question_id:
                answer['error'] = {'code': 4002, 'message': 'request_id and question_id required'}
            else:
                value = params.get('answer', '')
                if value is not None and not isinstance(value, str):
                    value = json.dumps(value, ensure_ascii=False)
                with LOCK:
                    req = OPEN.get(request_id)
                    if req is None or req.qids is None:
                        answer['result'] = {'status': 'expired'}
                        req = None
                    elif question_id not in req.qids:
                        answer['error'] = {'code': 4002, 'message': f'unknown question_id {question_id!r}'}
                        req = None
                    else:
                        req.locked[question_id] = value
                        remaining = [q for q in req.qids if q not in req.locked]
                        answer['result'] = {'status': 'ok', 'remaining': remaining}
                        req.ledger['answers'].append({'socket': sock.n, 'at': time.time(), 'kind': 'lock', 'question_id': question_id, 'answer': value})
                        if not remaining:
                            OPEN.pop(request_id, None)
                if req is not None and not answer['result']['remaining']:
                    settle(req, answered=True, result={'answers': dict(req.locked), 'outcome': 'submitted'}, outcome='submitted', by='clarify.lock')
        elif method == 'approval.respond':
            choice = params.get('choice') or 'deny'
            with LOCK:
                entries = [e for e in QUEUE.values() if runtime(e.profile) == params.get('session_id') or e.profile == profile]
                target = [e for e in entries if e.request_id == params.get('request_id')] if params.get('request_id') else (entries if params.get('all') else entries[:1])
            resolved = sum(resolve_queue(e, choice, 'approval.respond') for e in target)
            answer['result'] = {'resolved': resolved}
        elif method == 'approval.pending':
            with LOCK:
                entries = [e.client_safe() for e in QUEUE.values() if e.profile == profile and not e.event.is_set()]
            answer['result'] = {'approvals': entries}
        elif method == 'approval.received':
            answer['result'] = {'acknowledged': True}
        elif method == 'request.answer':
            answer['result'] = {'status': 'expired'}
        elif method in ('session.resume', 'session.activate'):
            result = voice.rpc(method, params)
            sid = result.get('session_id')
            with LOCK:
                sock.sessions.add(sid)
            opened = open_snapshots(sid)
            if opened:
                result['open_requests'] = opened
            pending = oldest_pending(base.owner({'session_id': sid}))
            if pending:
                result['pending_approval'] = pending
            answer['result'] = result
        elif method == 'session.events.since':
            sid = params.get('session_id')
            answer['result'] = {'events': [], 'latest_seq': 0, 'truncated': False, 'count': 0, 'epoch': 'build47',
                                'open_requests': open_snapshots(sid)}
        elif method == 'session.active_list':
            sessions = []
            for p in voice.SIDS:
                sid = runtime(p)
                waiting = any(r.sid == sid for r in list(OPEN.values()))
                if base.RUNNING[p] or waiting:
                    sessions.append({'session_id': sid, 'stored_session_id': voice.SIDS[p], 'status': 'waiting' if waiting else 'running', 'running': True})
            answer['result'] = {'sessions': sessions}
        elif method == 'session.interrupt':
            sid = runtime(profile)
            with LOCK:
                targets = [r for r in OPEN.values() if r.sid == sid]
                for r in targets:
                    OPEN.pop(r.id, None)
                queued = [e for e in QUEUE.values() if e.profile == profile and not e.event.is_set()]
            if queued:
                emit(profile, 'approval.cancelled', {'session_id': sid, 'stored_session_id': voice.SIDS[profile], 'reason': 'interrupted',
                                                     'cancelled_count': len(queued), 'request_ids': [e.request_id for e in queued]})
            for r in targets:
                if r.qids is not None:
                    settle(r, answered=True, result={'answers': dict(r.locked), 'outcome': 'cancelled'}, outcome='interrupted', by='interrupt')
                else:
                    settle(r, answered=False, result=None, outcome='interrupted', by='interrupt')
                emit_cancel(r, 'interrupted')
            for e in queued:
                with LOCK:
                    QUEUE.pop(e.request_id, None)
                    e.choice = 'deny'
                e.event.set()
            answer['result'] = base.rpc(method, params)
        else:
            answer['result'] = voice.rpc(method, params)
    except ValueError as error:
        answer.pop('result', None)
        answer['error'] = {'code': -32001, 'message': str(error)}
    sock.send(answer)


def prompt(sock, frame):
    params = frame.get('params') or {}
    profile = base.owner(params)
    LAST_PROFILE[0] = profile
    kind = keyword(params.get('text', ''))
    if kind is None:
        return sock.client.prompt(frame)
    with base.LOCK:
        voice.state['rpc'].append({'method': 'prompt.submit', 'params': params})
        voice.state['promptAttempts'] += 1
    row = start_ask_turn(profile, kind, params.get('text', ''))
    sock.send({'jsonrpc': '2.0', 'id': frame['id'], 'result': {'status': 'streaming', 'user_row_id': row}})


def websocket(connection, key):
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    with LOCK:
        NEXT_SOCKET[0] += 1
        sock = Sock(NEXT_SOCKET[0], connection)
        SOCKETS[sock.n] = sock

    def read(n):
        data = b''
        while len(data) < n:
            chunk = connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data

    with base.LOCK:
        base.CLIENTS.add(sock.client)
    try:
        sock.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
            'heartbeat': True, 'change_events': True, 'replay_epoch': 'build47', 'desktop_contract': 8}}})
        fragments = bytearray()
        while True:
            first, second = read(2); opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126: n = struct.unpack('>H', read(2))[0]
            elif n == 127: n = struct.unpack('>Q', read(8))[0]
            if n > 16 * 1024 * 1024: raise ValueError('Oversized fixture frame')
            mask = read(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(n)))
            if opcode == 8: return
            if opcode == 9:
                with sock.client.lock: connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 1: fragments = bytearray(payload)
            elif opcode == 0: fragments.extend(payload)
            else: continue
            if not final: continue
            frame = json.loads(fragments); fragments.clear()
            if 'method' not in frame:
                if 'id' in frame and ('result' in frame or 'error' in frame):
                    with LOCK:
                        sock.frames.append('<response>')
                    route_response(frame, sock)
                continue
            if 'id' not in frame: continue
            with LOCK:
                sock.frames.append(frame['method'])
            if frame['method'] == 'prompt.submit':
                threading.Thread(target=prompt, args=(sock, frame), daemon=True).start(); continue
            handle_rpc(sock, frame)
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        with LOCK:
            sock.connected = False
        with base.LOCK:
            base.CLIENTS.discard(sock.client)


voice.auth.websocket = websocket
_perf_handler = perf.handler


def handler(gateway):
    parent = _perf_handler(gateway)

    class Handler(parent):
        def body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            return json.loads(raw or b'{}')

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == '/__fixture/requests':
                with LOCK:
                    return self.reply(200, {'requests': list(LEDGER), 'rpc': list(RPC_LOG), 'errors4000': list(ERRORS_4000),
                                            'config': dict(CONFIG), 'open': list(OPEN.keys()),
                                            'queue': [e.request_id for e in QUEUE.values()],
                                            'sockets': [{'n': s.n, 'advertised': s.advertised, 'connected': s.connected,
                                                         'sessions': sorted(s.sessions),
                                                         'frames': list(s.frames[:40])} for s in SOCKETS.values()]})
            if parsed.path == '/__fixture/ask':
                q = parse_qs(parsed.query)
                kind = q.get('kind', ['ask'])[0]; profile = q.get('profile', [LAST_PROFILE[0]])[0]
                if profile not in voice.SIDS or not plan(kind): return self.reply(400, {'detail': 'profile and a known kind'})
                ask_in_running(profile, kind)
                return self.reply(200, {'ok': True, 'profile': profile, 'kind': kind})
            if parsed.path == '/api/config':
                body = {'model': 'fixture-model', 'provider': 'fixture', 'stt': {'enabled': False}, 'display': {'resume_last_session': True}}
                reported = CONFIG.get('reported_timeout') or CONFIG['approvals_timeout']
                if reported:
                    body['approvals'] = {'timeout': reported}
                return self.reply(200, body)
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/ask':
                body = self.body(); profile = body.get('profile', LAST_PROFILE[0])
                if profile not in voice.SIDS: return self.reply(400, {'detail': 'unknown profile'})
                if body.get('method'):
                    req = open_request(body['method'], profile, body.get('params') or {}, body.get('timeout', 300))
                    return self.reply(200, {'ok': True, 'id': req.id})
                ask_in_running(profile, body.get('kind', 'ask'))
                return self.reply(200, {'ok': True})
            if path == '/__fixture/event':
                # [preview-tab] One event in a bot's live chat (e.g. preview.open {url, label}, preview.close {url}).
                body = self.body(); profile = body.get('profile', LAST_PROFILE[0])
                if profile not in voice.SIDS or not isinstance(body.get('type'), str): return self.reply(400, {'detail': 'profile and type'})
                emit(profile, body['type'], body.get('payload') or {})
                return self.reply(200, {'ok': True, 'profile': profile})
            if path == '/__fixture/answer':
                body = self.body(); rid = body.get('id')
                with LOCK:
                    req = OPEN.pop(rid, None)
                if req is None: return self.reply(404, {'detail': 'not open'})
                result = body.get('result') if isinstance(body.get('result'), dict) else {}
                if req.qids:
                    merged = dict(req.locked); merged.update(result.get('answers') or {})
                    result = {**result, 'answers': merged, 'outcome': 'submitted'}
                req.ledger['answers'].append({'socket': 'other-client', 'at': time.time(), 'kind': 'result', 'result': redact(result)})
                settle(req, answered=True, result=result, outcome='answered-elsewhere', by='other-client')
                return self.reply(200, {'ok': True})
            if path == '/__fixture/cancel':
                body = self.body(); rid = body.get('id')
                with LOCK:
                    req = OPEN.pop(rid, None)
                if req is None: return self.reply(404, {'detail': 'not open'})
                settle(req, answered=req.qids is not None, result={'answers': dict(req.locked), 'outcome': 'cancelled'} if req.qids else None,
                       outcome='cancelled', by='fixture')
                emit_cancel(req, body.get('reason', 'interrupted'))
                return self.reply(200, {'ok': True})
            if path == '/__fixture/kick':
                self.body()
                for s in connected():
                    try: s.connection.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
                return self.reply(200, {'ok': True})
            if path == '/__fixture/config':
                body = self.body()
                with LOCK:
                    for key in ('approvals_timeout', 'declines_not_shown', 'capabilities', 'clarify_timeout', 'pane_timeout',
                                'reported_timeout'):
                        if key in body: CONFIG[key] = body[key]
                    return self.reply(200, dict(CONFIG))
            if path == '/__fixture/reset':
                self.body()
                # Every running turn and open request ends quietly (a test's leftovers never block the next one).
                with LOCK:
                    stale = list(OPEN.values()); OPEN.clear()
                    queued = list(QUEUE.values()); QUEUE.clear()
                for r in stale:
                    settle(r, answered=False, result=None, outcome='reset', by='reset')
                for e in queued:
                    e.choice = 'deny'; e.event.set()
                with base.LOCK:
                    for p in voice.SIDS:
                        base.CANCEL[p].set(); base.RUNNING[p] = False
                with LOCK:
                    LEDGER.clear(); RPC_LOG.clear()          # 4000s are kept for the whole run (check 15)
                    CONFIG.update({'approvals_timeout': None, 'declines_not_shown': True, 'capabilities': 'ok', 'clarify_timeout': 3600,
                                   'pane_timeout': 8, 'reported_timeout': None})
                return self.reply(200, {'ok': True})
            return super().do_POST()

    return Handler


base.handler = handler
if __name__ == '__main__':
    base.main()
