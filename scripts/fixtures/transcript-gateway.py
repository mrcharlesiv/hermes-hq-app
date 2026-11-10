#!/usr/bin/env python3
"""Stand-in gateway of the m9 transcript stream (docs/spec/3x-transcript.md §0.1).

The activity fixture (scripted turns, strict params, /__fixture/rows, /event, /fail, /plan, /history) plus:
  POST /__fixture/preset {"profile": "default", "name": "cron" | "timeline" | "text" | "tools" | "table" | "widetable" | "widecode" | "links" | "math" | "long" | "huge" | "diffs" | "diffs7"}
      replaces the chat's stored rows with a named set (see PRESETS); "diffs"/"diffs7" (§12, n20 F10) also seed
      `/api/fs/list`, `/api/fs/read-text`, `/api/git/review/list` and `/api/git/review/diff` under the session's
      own cwd ('/fixture'), so the files card's "Review" and a file row's open answer for real;
  POST /__fixture/slow {"method": "session.resume", "seconds": 8, "times": 1}
      the next `times` calls of the method answer after `seconds` (a cold bot waking up);
  POST /__fixture/older {"seconds": 3, "fail": -1}
      reads of an older page (GET …/messages with offset > 0) wait `seconds`; the next `fail` answer 500 (-1 = all);
  POST /__fixture/drop        closes every connected socket (a link that drops mid-reply);
  GET  /__fixture/transcript  what was slowed, the presets seeded, the older-page reads.
All state and credentials are invented; nothing is forwarded anywhere. Loopback only.
"""
import importlib.util
import json
import pathlib
import time
from urllib.parse import urlparse, parse_qs

spec = importlib.util.spec_from_file_location('transcript_activity', pathlib.Path(__file__).with_name('activity-gateway.py'))
activity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activity)
base = activity.base

SLOW = {}
SEEDED = []
SLOWED = []

MODEL_SWITCH = ('[System: The active model for this chat has changed to claude-opus-5-5 via provider anthropic. '
                'From this point on, answer as that model.]')

PRESETS = {
    'cron': [
        {'role': 'user', 'content': 'Good morning'},
        {'role': 'assistant', 'content': 'Morning. Your jobs report in here.'},
        {'role': 'assistant', 'content': '[Cron delivery: Ivy morning brief]\n(job_id: 7f3a)\n---\n**Three things** today:\n\n'
                                         '- Stand-up at 10\n- Release notes due\n- Dentist at 4\n\n'
                                         'To stop or manage this job, send me a new message.'},
        {'role': 'assistant', 'content': 'Cronjob Response: Nightly check\nAll **12** services answered.'},
        {'role': 'assistant', 'content': '[Cron delivery: Disk watch]\n[SILENT]'},
        {'role': 'assistant', 'content': '[SILENT]'},
    ],
    'timeline': [
        {'role': 'user', 'content': 'Switch to the bigger model'},
        {'role': 'user', 'content': MODEL_SWITCH},
        {'role': 'assistant', 'content': 'Done. I am on the bigger model now.'},
        {'role': 'user', 'content': '[IMPORTANT: Background process 4412 finished with exit code 0]'},
        {'role': 'assistant', 'content': 'The build finished.'},
    ],
    'text': [
        {'role': 'user', 'content': 'How do I install it?'},
        {'role': 'assistant', 'content': 'Install it for **one user** with `--user`, or system-wide with `--break-system-packages` '
                                         'if you *really* must.\n\n## Read more\n\nThe [install guide](https://example.com/install) has the rest, '
                                         'and your own page is at http://127.0.0.1:8080/status.'},
    ],
    'tools': [
        {'role': 'user', 'content': 'Check the background build'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_td', 'type': 'function', 'function': {'name': 'tool_describe', 'arguments': json.dumps({'names': ['web_search']})}}]},
        {'role': 'tool', 'content': json.dumps({'ok': True}), 'tool_call_id': 'call_td'},
        {'role': 'assistant', 'content': 'I looked up how to search first.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_sh', 'type': 'function', 'function': {'name': 'terminal', 'arguments': json.dumps(
                {'command': "cd /app\nexport CI=1\npython3 - <<'PY'\nimport json\nprint(json.dumps({'ok': True}))\nPY"})}}]},
        {'role': 'tool', 'content': json.dumps({'stdout': '{"ok": true}', 'stderr': '', 'exit_code': 0}), 'tool_call_id': 'call_sh'},
        {'role': 'assistant', 'content': 'The script ran.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_rd', 'type': 'function', 'function': {'name': 'read_file', 'arguments': json.dumps({'path': 'notes/big.txt'})}}]},
        {'role': 'tool', 'content': json.dumps({'content': 'x' * 12000}), 'tool_call_id': 'call_rd'},
        {'role': 'assistant', 'content': 'I read the big file.'},
    ],
    'table': [
        {'role': 'user', 'content': 'Which plans are there?'},
        {'role': 'assistant', 'content': 'Here are the plans.\n\n| Plan | Price | Seats |\n| --- | --- | --- |\n'
                                         '| Starter | $5 | 1 |\n| Team | $20 | 10 |\n| Studio | $60 | 40 |\n\nPick one.'},
    ],
    # 2026-10-29 a sales bot's reply (names and numbers invented): a table wider than the phone, then a long one to search.
    'widetable': [
        {'role': 'user', 'content': 'How do the reps do at follow-up?'},
        {'role': 'assistant', 'content': 'Rep by rep (at least 40 chats each):\n\n'
            '| Strong at follow-up | Reply rate | Weak at follow-up | Reply rate |\n|---|---|---|---|\n'
            '| Jamie Lane | 22.4% | Sky Hart | 1.8% |\n| Robin Park | 18.1% | Quinn Ross | 2.4% |\n'
            '| Casey Moore | 16.9% | Avery Cole | 2.9% |\n| Morgan Lee | 15.2% | Rowan Gray | 3.1% |\n'
            '| Taylor Reed | 13.8% (7 booked) | Emery Shaw | 3.6% |\n| Jordan Fox | 12.6% | Blair Dunn | 4.0% |\n'
            '| Drew Hale | 10.9% | Reese Ford | 4.7% |\n\n'
            '**How much rep skill matters:** some, but less than the table suggests.\n\n### Pipeline by source\n\n'
            '| Source | Leads | Reply rate | Booked | Cost per reply |\n|---|---:|---:|---:|---:|\n'
            + ''.join('| %s | %s | %s | %d | %s |\n' % row for row in [
                ('Search ads', '1,900', '10.5%', 33, '$150'), ('Social', '1,600', '8.0%', 18, '$120'),
                ('Referrals', '500', '22.0%', 30, '$35'), ('Mail', '900', '4.5%', 7, '$280'),
                ('Radio', '300', '3.0%', 2, '$350'), ('Website form', '1,200', '12.5%', 25, '$80'),
                ('Partners', '350', '17.5%', 14, '$60'), ('Events', '200', '9.0%', 4, '$240'),
                ('Calls', '2,500', '2.5%', 6, '$170'), ('Email', '700', '6.0%', 8, '$50'),
                ('Video', '450', '7.0%', 6, '$110'), ('Podcasts', '150', '11.0%', 3, '$75')])
            + '\nReferrals convert best.'},
    ],
    # 2026-10-29 code wider than the card, labelled and compact: the sideways bar runs under the last line, not on it.
    'widecode': [
        {'role': 'user', 'content': 'Show me the config'},
        {'role': 'assistant', 'content': 'Here it is:\n\n```yaml\nservers:\n  hermes: {url: "https://gateway.example.invalid:8642/api/v1", '
                                         'token_env: HERMES_TOKEN, retries: 3, timeout_seconds: 45, verify_tls: true}\n'
                                         '  backup: {url: "https://backup.example.invalid:8642/api/v1", retries: 5}\n```\n\n'
                                         'Run it with `hermes up`:\n\n```\nhermes up --profile default --gateway https://gateway.example.invalid:8642 --verbose --log-file ~/hermes.log\n```\n\n'
                                         'That starts both.'},
    ],
    'links': [
        {'role': 'user', 'content': 'Where are the docs?'},
        {'role': 'assistant', 'content': 'They live here:\n\nhttps://docs.hermes-hq.invalid/guide\n\nStart with the first page.'},
    ],
    # [transcript] F17: an inline formula, a sum with limits (the n20 screenshot's cramped case), a display formula,
    # prices that stay plain text, and a formula outside the drawn subset (its TeX source).
    'math': [
        {'role': 'user', 'content': 'Show me the formulas'},
        {'role': 'assistant', 'content': 'Einstein wrote $E = mc^2$, and the sum is \\(\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\\).\n\n'
                                         '$$\n\\frac{a}{b} \\leq \\sqrt{x^2 + y^2}\n$$\n\n'
                                         'Not maths: it costs $5 and $10.\n\nOutside what the phone draws:\n\n'
                                         '$$\n\\begin{aligned} a &= b \\end{aligned}\n$$'},
    ],
    'huge': [{'role': 'assistant' if i % 2 else 'user', 'content': 'Line %d of a huge chat.%s' % (i, ' More words to fill the row.' * (i % 5))}
             for i in range(1, 1501)],
    'long': [{'role': 'assistant' if i % 2 else 'user', 'content': 'Line %d of a long chat.' % i} for i in range(1, 201)],
}


# [transcript] §12, n20 F10: the "N files changed" card and a landed edit's inline preview. The session's own cwd
# ('/fixture', action-voice's default) is where the card's "Review" / a file row's open resolve a relative path to.
def _diff(path, added=(), removed=()):
    out = [f'--- a/{path}', f'+++ b/{path}', '@@ -1 +1 @@']
    out += [f'-{line}' for line in removed]
    out += [f'+{line}' for line in added]
    return '\n'.join(out) + '\n'


def _edit(call_id, name, path, diff):
    return [{'role': 'assistant', 'content': '', 'tool_calls': [
                {'id': call_id, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps({'path': path})}}]},
            {'role': 'tool', 'content': json.dumps({'ok': True}), 'tool_call_id': call_id,
             'display_metadata': {'tool_result_metadata': {'inline_diff': diff}}}]


PRESETS['diffs'] = (
    [{'role': 'user', 'content': 'Fix the bug where a request with no user crashes, and note it in the README'}]
    + _edit('call_e1', 'edit_file', 'src/app.py', _diff('src/app.py',
            added=['        log.warning("no user on request")', '        return None'], removed=['        return None']))
    + _edit('call_e2', 'write_file', 'README.md', _diff('README.md',
            added=['', '## Error handling', '', 'Requests without a user now log a warning before returning early.',
                   'See `src/app.py` for details.']))
    + _edit('call_e3', 'edit_file', 'src/app.py', _diff('src/app.py', added=['    pass'],
            removed=['    # TODO remove this later', '    # old debug print', '    print("debug", req)']))
    + [{'role': 'assistant', 'content': 'Fixed it: a request with no user now logs a warning and returns early '
                                        'instead of crashing, and I noted it in the README.'}]
)
PRESETS['diffs7'] = (
    [{'role': 'user', 'content': 'Go through the whole module and clean it up'}]
    + _edit('call_f0', 'edit_file', 'src/app.py', _diff('src/app.py', added=['    pass', '    # tidy'], removed=[]))
    + _edit('call_f1', 'edit_file', 'src/models.py', _diff('src/models.py',
            added=['class User:', '    name: str', '    active: bool'], removed=['class User: pass']))
    + _edit('call_f2', 'edit_file', 'src/utils.py', _diff('src/utils.py', added=['def helper():'], removed=['def old_helper():']))
    + _edit('call_f3', 'write_file', 'tests/test_app.py', _diff('tests/test_app.py',
            added=['def test_handle():', '    assert True', '', 'def test_helper():', '    assert True', '']))
    + _edit('call_f4', 'edit_file', 'README.md', _diff('README.md', added=['', '## Tests', ''], removed=[]))
    + _edit('call_f5', 'write_file', 'docs/guide.md', _diff('docs/guide.md',
            added=['# Guide', '', 'Start here.', '']))
    + _edit('call_f6', 'edit_file', 'config.yaml', _diff('config.yaml', added=['debug: false'], removed=['debug: true']))
    + [{'role': 'assistant', 'content': 'Refactored every file across the module.'}]
)

WORK_FILES = {
    '/fixture': [{'name': 'src', 'isDirectory': True}, {'name': 'tests', 'isDirectory': True},
                 {'name': 'docs', 'isDirectory': True}, {'name': 'README.md', 'isDirectory': False},
                 {'name': 'config.yaml', 'isDirectory': False}],
    '/fixture/src': [{'name': 'app.py', 'isDirectory': False}, {'name': 'models.py', 'isDirectory': False},
                      {'name': 'utils.py', 'isDirectory': False}],
    '/fixture/tests': [{'name': 'test_app.py', 'isDirectory': False}],
    '/fixture/docs': [{'name': 'guide.md', 'isDirectory': False}],
}
WORK_TEXTS = {
    '/fixture/src/app.py': 'def handle(req):\n    if req.user is None:\n        log.warning("no user on request")\n'
                           '        return None\n    return render(req)\n',
    '/fixture/src/models.py': 'class User:\n    name: str\n    active: bool\n',
    '/fixture/src/utils.py': 'def helper():\n    return True\n',
    '/fixture/tests/test_app.py': 'def test_handle():\n    assert True\n\ndef test_helper():\n    assert True\n',
    '/fixture/README.md': '# Demo\n\n## Error handling\n\nRequests without a user now log a warning before returning early.\n'
                          'See `src/app.py` for details.\n\n## Tests\n',
    '/fixture/docs/guide.md': '# Guide\n\nStart here.\n',
    '/fixture/config.yaml': 'debug: false\n',
}
# The Changes page's own list: a git status, always the union of what either preset touches (not switched by
# preset, as `menus-gateway.py`'s own CHANGES never was) so Review reads right under either one.
WORK_CHANGES = [
    {'path': 'src/app.py', 'added': 3, 'removed': 4, 'status': 'M', 'staged': False},
    {'path': 'src/models.py', 'added': 3, 'removed': 1, 'status': 'M', 'staged': False},
    {'path': 'src/utils.py', 'added': 1, 'removed': 1, 'status': 'M', 'staged': False},
    {'path': 'tests/test_app.py', 'added': 6, 'removed': 0, 'status': 'A', 'staged': False},
    {'path': 'README.md', 'added': 7, 'removed': 0, 'status': 'M', 'staged': False},
    {'path': 'docs/guide.md', 'added': 4, 'removed': 0, 'status': 'A', 'staged': False},
    {'path': 'config.yaml', 'added': 1, 'removed': 1, 'status': 'M', 'staged': False},
]
WORK_DIFFS = {
    'src/app.py': _diff('src/app.py', added=['        log.warning("no user on request")', '        return None', '    pass'],
                        removed=['        return None', '    # TODO remove this later', '    # old debug print', '    print("debug", req)']),
    'src/models.py': _diff('src/models.py', added=['class User:', '    name: str', '    active: bool'], removed=['class User: pass']),
    'src/utils.py': _diff('src/utils.py', added=['def helper():'], removed=['def old_helper():']),
    'tests/test_app.py': _diff('tests/test_app.py', added=['def test_handle():', '    assert True', '', 'def test_helper():',
                               '    assert True', '']),
    'README.md': _diff('README.md', added=['', '## Error handling', '', 'Requests without a user now log a warning before '
                       'returning early.', 'See `src/app.py` for details.', '', '## Tests', ''], removed=[]),
    'docs/guide.md': _diff('docs/guide.md', added=['# Guide', '', 'Start here.', '']),
    'config.yaml': _diff('config.yaml', added=['debug: false'], removed=['debug: true']),
}

OLDER = {'seconds': 0.0, 'fail': 0}     # reads of an older page (offset > 0): a delay, and how many answer 500 (-1 = all)
OLDER_SEEN = []


def seed(profile, name):
    rows = PRESETS[name]
    with base.LOCK:
        base.MESSAGES[profile] = []
        ids = []
        for raw in rows:
            ids.append(base.append(profile, raw['role'], raw.get('content', '')))
            base.MESSAGES[profile][-1].update({k: v for k, v in raw.items() if k not in ('role', 'content')})
        SEEDED.append({'profile': profile, 'name': name, 'rows': len(rows)})
    return ids


_rpc = base.rpc
def rpc(method, params):
    slow = SLOW.get(method)
    if slow and slow['times'] != 0:
        if slow['times'] > 0:
            slow['times'] -= 1
        SLOWED.append({'method': method, 'seconds': slow['seconds'], 'at': time.time()})
        time.sleep(slow['seconds'])
    return _rpc(method, params)
base.rpc = rpc
if getattr(base, 'voice', None) is not None and base.voice.rpc is _rpc:
    base.voice.rpc = rpc

_handler = base.handler
def handler(gateway):
    parent = _handler(gateway)

    class Handler(parent):
        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == '/__fixture/transcript':
                return self.reply(200, {'seeded': list(SEEDED), 'slowed': list(SLOWED), 'presets': sorted(PRESETS),
                                        'older': list(OLDER_SEEN)})
            # [transcript] §12, n20 F10: the card's "Review" (the Changes page) and a file row's open (its current
            # text) — the chat's folder reads, as `menus-gateway.py`'s own Trip planning chat already serves them.
            if parsed.path in ('/api/fs/list', '/api/fs/read-text', '/api/git/review/list', '/api/git/review/diff'):
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
                where = params.get('path', '')
                if parsed.path == '/api/fs/list':
                    if where not in WORK_FILES:
                        return self.reply(200, {'entries': [], 'error': f'No such folder: {where}'})
                    return self.reply(200, {'entries': [{**e, 'path': f"{where}/{e['name']}"} for e in WORK_FILES[where]]})
                if parsed.path == '/api/fs/read-text':
                    if where not in WORK_TEXTS:
                        return self.reply(404, {'detail': 'not found'})
                    return self.reply(200, {'path': where, 'text': WORK_TEXTS[where], 'binary': False, 'truncated': False})
                if parsed.path == '/api/git/review/list':
                    return self.reply(200, {'files': WORK_CHANGES, 'base': None})
                return self.reply(200, {'diff': WORK_DIFFS.get(params.get('file', ''), '')})
            if parsed.path.startswith('/api/sessions/') and parsed.path.endswith('/messages'):
                offset = int((parse_qs(parsed.query).get('offset') or ['0'])[0] or 0)
                if offset > 0:
                    failed = OLDER['fail'] != 0
                    OLDER_SEEN.append({'offset': offset, 'failed': failed, 'at': time.time()})
                    if OLDER['seconds']:
                        time.sleep(OLDER['seconds'])
                    if failed:
                        if OLDER['fail'] > 0:
                            OLDER['fail'] -= 1
                        return self.reply(500, {'detail': 'fixture: the older page failed'})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/preset':
                body = self.body()
                profile, name = body.get('profile', 'default'), body.get('name')
                if profile not in base.MESSAGES or name not in PRESETS:
                    return self.reply(404, {'detail': 'unknown profile or preset'})
                if base.RUNNING[profile]:
                    return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                return self.reply(200, {'ok': True, 'row_ids': seed(profile, name)})
            if path == '/__fixture/slow':
                body = self.body()
                seconds = min(180.0, max(0.0, float(body.get('seconds', 0))))
                SLOW[body['method']] = {'seconds': seconds, 'times': int(body.get('times', 1))}
                return self.reply(200, {'ok': True})
            if path == '/__fixture/drop':      # the gateway goes away under every connected phone (a dropped link)
                import socket
                self.body()                    # read, or it stays on the connection and the next request answers 501
                with base.LOCK:
                    clients = list(base.CLIENTS)
                for client in clients:
                    try:
                        client.connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                return self.reply(200, {'ok': True, 'dropped': len(clients)})
            if path == '/__fixture/older':
                body = self.body()
                OLDER['seconds'] = min(30.0, max(0.0, float(body.get('seconds', 0))))
                OLDER['fail'] = int(body.get('fail', 0))
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler
base.handler = handler


if __name__ == '__main__':
    base.main()
