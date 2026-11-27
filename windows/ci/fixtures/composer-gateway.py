#!/usr/bin/env python3
"""Loopback-only stand-in gateway for the m9 composer stream (docs/spec/3x-composer.md §18). Invented state; no upstream.

Built on the menus fixture (scripts/fixtures/menus-gateway.py, itself on the ref238 performance fixture), loaded as a
module and layered on rather than copied. Everything the menus fixture answers still works here (strict params, the
call log at /__menus/state, /__menus/mode, /__menus/reset, /__fixture/plan and /__fixture/finish for slow replies).

This layer adds the modes the composer rows need. Built so far (the rows that are implemented):

  redirect ok | queued | rejected | 4010 | old | hang          `session.redirect` (steering a queued message)
  models   ok | fail_once | fail_twice | hang | error_text     `model.options`
           fail_once  = the next call fails, the one after answers
           fail_twice = the next two calls fail, the third answers
           hang       = never answers while the mode is set (the client's own time limit ends the call)
           error_text = fails with a 400-character message
  complete ok | hang | old | slow                              `complete.slash` and `complete.path` (the drawers, §9, §10)
           hang = never answers while the mode is set; old = -32601 (an older gateway);
           slow = a query of one or two characters after the "/" or "@" answers after 1.5 s (a stale answer arrives late)
  fs       ok | enoent | eacces                                `GET /api/fs/list` for the chats' folders
  side     ok | old | error | fail | slow                       `prompt.btw` / `prompt.background` (/btw and /bg, §8.4)
           ok = {task_id} at once, then `btw.complete` / `background.complete` on the asking runtime 2.5 s later;
           old = -32601 (the app falls back to `slash.exec`); error = the call fails (5035);
           fail = the task's text is "error: …"; slow = the result comes 6 s later (leave the chat meanwhile)

The drawers' chats have their own folders: the main bot's chat reports cwd /home/fx/proj, Ivy's /home/fx/other.
`complete.slash` answers from the commands catalog (+ /worktree, + the skill /pet), with options for /reasoning and
/model; `complete.path` lists the fake trees below (dotfiles included: the app hides them) and the profiles.

`session.create` without messages (`/new`, Bots › New Chat) makes a fresh empty stored chat for the bot, resumable as a
branch of the menus fixture, so a new chat opens in place and its first send is its own.

Controls (no auth, loopback):
  GET  /__composer/state   {mode, counts: {method: n}, modelCalls, modelFailures,
                            completeLog: [{method, params, start, end}] (call order and overlap), pathCwds: [cwd…]}
  POST /__composer/mode    any subset of the mode keys; answers the full mode map
  POST /__composer/reset   default modes and counters, then the menus fixture's own reset

  python3 scripts/fixtures/composer-gateway.py --port 10030 --credentials build/fixtures/composer.json
"""
import base64, copy, hashlib, importlib.util, json, pathlib, threading, time
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('composer_menus', HERE / 'menus-gateway.py')
menus = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(menus)          # its __main__ guard keeps it from starting
b47 = menus.b47

LOCK = threading.RLock()
DEFAULT_MODE = {'models': 'ok', 'redirect': 'ok', 'complete': 'ok', 'fs': 'ok', 'side': 'ok'}
MODE = dict(DEFAULT_MODE)
COUNTERS = {'modelCalls': 0, 'modelFailures': 0, 'failLeft': 0}
COMPLETE_LOG = []
LONG_TEXT = ('The model inventory could not be read because the provider list on this gateway is being rebuilt. ' * 5)[:400]


def set_mode(body):
    with LOCK:
        for key, value in body.items():
            if key in DEFAULT_MODE:
                MODE[key] = value
        if 'models' in body:
            COUNTERS['failLeft'] = {'fail_once': 1, 'fail_twice': 2}.get(body['models'], 0)


def reset():
    with LOCK:
        MODE.clear()
        MODE.update(DEFAULT_MODE)
        COUNTERS.update({'modelCalls': 0, 'modelFailures': 0, 'failLeft': 0})
        del COMPLETE_LOG[:]


# MARK: - The drawers (docs/spec/3x-composer.md §9.3, §10.3)

FOLDERS = {'default': '/home/fx/proj', 'ivy': '/home/fx/other'}
TREES = {'/home/fx/proj': ['.config/', '.config/app.toml', '.env', 'src/', 'src/main.py', 'src/util/', 'src/util/deep/',
                           'my docs/', 'my docs/plan.md', 'README.md'],
         '/home/fx/other': ['notes.txt']}
PROFILES = [('@hermes', 'agent profile (primary)'), ('@ivy', 'agent profile')]
DIRECTIVES = [('@diff', 'git diff'), ('@staged', 'staged diff'), ('@file:', 'attach file'), ('@folder:', 'attach folder'),
              ('@url:', 'fetch url'), ('@git:', 'git log')]
menus.ALLOWED['complete.slash'] = {'text', 'session_id', 'profile'}
menus.ALLOWED['complete.path'] = {'word', 'cwd', 'session_id', 'profile'}
menus.LONG.update({'complete.slash', 'complete.path'})   # answered on worker threads: a hang never blocks the socket
menus.ALLOWED['prompt.btw'] = {'session_id', 'text', 'profile'}            # H/tui_gateway/contracts SideAgentParams
menus.ALLOWED['prompt.background'] = {'session_id', 'text', 'profile'}
menus.STALE_ABLE.update({'prompt.btw', 'prompt.background'})
SIDE_ANSWERS = {'btw.complete': 'The dev server listens on **port 8080** — `src/main.py` sets it.',
                'background.complete': 'Ran the tests: **42 passed**, 0 failed.\n\n- `test_main.py` 30 passed\n- `test_util.py` 12 passed'}

for _folder, _paths in TREES.items():
    menus.FILES[_folder] = [{'name': p.rstrip('/'), 'isDirectory': p.endswith('/')} for p in _paths if '/' not in p.rstrip('/')]


def complete_wait(params, word):
    with LOCK:
        mode = MODE['complete']
    if mode == 'old':
        raise menus.Fault(-32601, 'unknown method — the client and the Hermes backend are out of sync (different versions)')
    if mode == 'hang':
        deadline = time.time() + 300
        while time.time() < deadline:
            with LOCK:
                if MODE['complete'] != 'hang':
                    break
            time.sleep(0.1)
        raise menus.Fault(5034, 'completion failed (fixture, after a hang)')
    if mode == 'slow' and len(word) <= 3:
        time.sleep(1.5)


def complete_slash(text):
    if ' ' in text:
        name, _, rest = text[1:].partition(' ')
        options = {'reasoning': [('low', ''), ('medium', ''), ('high', ''), ('show', 'Show reasoning'), ('hide', 'Hide reasoning')],
                   'model': [('opus', 'anthropic'), ('sonnet', 'anthropic'), ('gpt-5.5', 'openai')]}.get(name.lower(), [])
        last = text.rfind(' ') + 1
        typed = text[last:].lower()
        items = [{'text': o, 'display': o, 'meta': m} for o, m in options if o.startswith(typed)]
        return {'items': items, 'replace_from': last}
    typed = text[1:].lower()
    catalog = menus.commands_catalog()
    rows = [(c, d, 'command') for c, d in catalog['pairs'] if c not in catalog['skills']]
    rows += [('/worktree', 'Work in a git worktree', 'command'), ('/pet', 'Pet the bot', 'command')]
    rows += [(c, d, 'skill') for c, d in menus.SKILLS]
    seen, items = set(), []
    for command, desc, kind in rows:
        name = command[1:]
        if name.lower().startswith(typed) and name not in seen:
            seen.add(name)
            items.append({'text': name, 'display': command, 'meta': desc, 'kind': kind})
    return {'items': items, 'replace_from': 1}


def complete_path(word, cwd):
    if word == '@':
        return {'items': [{'text': t, 'display': t, 'meta': m} for t, m in DIRECTIVES + PROFILES]}
    paths = TREES.get(cwd)
    for kind in ('file', 'folder'):
        prefix = '@' + kind + ':'
        if word.startswith(prefix):
            if paths is None:
                return {'items': []}
            rest = word[len(prefix):]
            base, _, leaf = rest.rpartition('/')
            base = base + '/' if base else ''
            items = []
            for p in paths:
                is_dir = p.endswith('/')
                if (kind == 'file') == is_dir:
                    continue
                if not p.startswith(base) or '/' in p[len(base):].rstrip('/'):
                    continue
                if not p[len(base):].lower().startswith(leaf.lower()):
                    continue
                items.append({'text': prefix + p, 'display': p, 'meta': 'dir' if is_dir else ''})
            return {'items': items}
    q = word[1:].lower()
    items = [{'text': t, 'display': t, 'meta': m} for t, m in PROFILES if t[1:].startswith(q)]
    items += [{'text': '@file:' + p, 'display': p, 'meta': ''} for p in (paths or []) if not p.endswith('/') and q in p.lower()]
    return {'items': items}


def complete_rpc(method, params):
    start = time.time()
    entry = {'method': method, 'params': dict(params), 'start': start, 'end': None}
    with LOCK:
        COMPLETE_LOG.append(entry)
    try:
        if method == 'complete.slash':
            text = params.get('text', '')
            complete_wait(params, text)
            return complete_slash(text)
        word = params.get('word', '')
        complete_wait(params, word)
        cwd = params.get('cwd') or FOLDERS.get(menus.profile_of(params), '')
        return complete_path(word, cwd)
    finally:
        with LOCK:
            entry['end'] = time.time()


_menus_resumed = b47.resumed


def composer_resumed(profile):
    answer = _menus_resumed(profile)
    if profile in FOLDERS:
        answer['info']['cwd'] = FOLDERS[profile]
    return answer


b47.resumed = composer_resumed


_prev_rpc = b47.rpc


def side_rpc(method, params):
    """`prompt.btw` / `prompt.background` (H/tui_gateway/methods_prompt.py:1174-1217): a task id at once, the result
    later on the runtime that asked, as `_spawn_side_agent` emits it."""
    with LOCK:
        mode = MODE['side']
    if mode == 'old':
        raise menus.Fault(-32601, 'method not found')
    if mode == 'error':
        raise menus.Fault(5035, 'backend is retiring; reconnect to continue')
    text = params.get('text', '')
    if not text:
        raise menus.Fault(4012, 'text required')
    btw = method == 'prompt.btw'
    task_id = ('btw_' if btw else 'bg_') + hashlib.sha256(f'{text}{time.time()}'.encode()).hexdigest()[:6]
    event = 'btw.complete' if btw else 'background.complete'
    payload = {'task_id': task_id, 'question': text} if btw else {'task_id': task_id}
    payload['text'] = 'error: the model provider timed out (fixture)' if mode == 'fail' else SIDE_ANSWERS[event]
    runtime = params.get('session_id', '')

    def later():
        time.sleep(6 if mode == 'slow' else 2.5)
        menus.emit_runtime(runtime, event, payload)
    threading.Thread(target=later, daemon=True).start()
    return {'task_id': task_id}


def composer_rpc(method, params):
    if method == 'session.create' and not params.get('messages'):
        # [walk proof] `/new` and Bots › New Chat (SessionStore.NewChatAsync): a fresh, empty stored chat for that bot that
        # resumes and reads like a branch (no rows until its first send), as Hermes' session.create answers it.
        with menus.LOCK:
            return menus.make_branch(params.get('profile') or 'default', None, [])
    if method in ('complete.slash', 'complete.path'):
        return complete_rpc(method, params)
    if method in ('prompt.btw', 'prompt.background'):
        return side_rpc(method, params)
    if method == 'session.redirect':          # spec 3x-composer §15.4: exactly session_id, text, optional profile
        extra = set(params) - {'session_id', 'text', 'profile'}
        if extra:
            raise menus.Fault(4000, 'unknown params: ' + ', '.join(sorted(extra)))
        with LOCK:
            mode = MODE['redirect']
        if mode == 'hang':
            time.sleep(60)
        if mode == '4010':
            raise menus.Fault(4010, 'agent does not support active-turn redirect')
        if mode == 'old':
            raise menus.Fault(-32601, 'method not found')
        if mode == 'rejected':
            return {'status': 'rejected', 'text': params.get('text', '')}
        return {'status': 'queued' if mode == 'queued' else 'redirected', 'text': params.get('text', '')}
    if method == 'model.options':
        with LOCK:
            COUNTERS['modelCalls'] += 1
            mode = MODE['models']
            fail = False
            if mode in ('fail_once', 'fail_twice') and COUNTERS['failLeft'] > 0:
                COUNTERS['failLeft'] -= 1
                fail = True
            if fail or mode == 'error_text':
                COUNTERS['modelFailures'] += 1
        if mode == 'hang':
            deadline = time.time() + 300
            while time.time() < deadline:
                with LOCK:
                    if MODE['models'] != 'hang':
                        break
                time.sleep(0.1)
            raise menus.Fault(5033, 'model inventory failed (fixture, after a hang)')
        if mode == 'error_text':
            raise menus.Fault(5033, LONG_TEXT)
        if fail:
            raise menus.Fault(5033, 'model inventory failed (fixture)')
    return _prev_rpc(method, params)


b47.rpc = composer_rpc

_prev_handler = b47.handler


def composer_handler(gateway):
    parent = _prev_handler(gateway)

    class Handler(parent):
        def do_GET(self):
            if urlparse(self.path).path == '/__composer/state':
                with menus.LOCK:
                    counts = {}
                    for call in menus.STATE['calls']:
                        counts[call['method']] = counts.get(call['method'], 0) + 1
                with LOCK:
                    return self.reply(200, {'mode': dict(MODE), 'counts': counts, 'modelCalls': COUNTERS['modelCalls'],
                                            'modelFailures': COUNTERS['modelFailures'], 'completeLog': list(COMPLETE_LOG),
                                            'pathCwds': [e['params'].get('cwd') for e in COMPLETE_LOG if e['method'] == 'complete.path']})
            parsed = urlparse(self.path)
            if parsed.path == '/api/fs/list':
                where = parse_qs(parsed.query).get('path', [''])[0]
                with LOCK:
                    fs = MODE['fs']
                if where in TREES and fs != 'ok':
                    error = f'No such folder: {where}' if fs == 'enoent' else f'Permission denied: {where}'
                    return self.reply(200, {'entries': [], 'error': error})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__composer/mode':
                set_mode(self._body())
                with LOCK:
                    return self.reply(200, {'ok': True, 'mode': dict(MODE)})
            if path == '/__composer/reset':
                reset()
                self.path = '/__menus/reset'      # the menus fixture reads the body and resets its own state
                return super().do_POST()
            return super().do_POST()

    return Handler


b47.handler = composer_handler


# MARK: - [WIN-36] The transcript extras chat (a Windows-only addition; windows/ci/fixtures/README.md)
#
# One stored chat of the main bot, "Release review", that is never listed (the sidebar, Sessions and the other walks
# don't see it) and that /__menus/reset leaves alone. Its history holds what the transcript draws beyond plain words: a
# reply whose last paragraph is a bare web address (a link chip), a wide Markdown table (its Expand footer and sheet), a
# timeline note (the model changed), a scheduled job's delivery, and a turn whose edits make an "N files changed" footer.
# A send in it: EXTRAS_REFUSED is refused (the "Couldn't Send" card); anything else is taken and fails with a usage
# limit (the error card's Choose a Model).
#
# The chip's page is served here too, on loopback only: GET /__extras/link/<host>/<path> answers a small synthetic HTML
# page titled EXTRAS_LINK_TITLE (a path ending .ico or .png: a 16x16 PNG). The app reads it only in the CI walk, which
# points its link reader at this stand-in (Hermes.Core LinkPreviewFetcher.LoopbackStandIn); nothing leaves the machine.
#
#   GET /__extras/state   {sends: [text...], linkReads: [path...]}

EXTRAS = '20261012_100000_extras01'
EXTRAS_RT = menus.runtime_of(EXTRAS)
EXTRAS_TITLE = 'Release review'
EXTRAS_LINK = 'https://example.com/releases/2-4'
EXTRAS_LINK_TITLE = 'Release 2.4 notes'
EXTRAS_REFUSED = 'Send the release notes'
EXTRAS_REFUSAL = 'The gateway is restarting'
EXTRAS_LIMIT = 'Error code: 429 - usage limit reached for claude-sonnet-5 (fixture)'
EXTRAS_TABLE = ('| Build | Platform | Started | Duration | Tests | Result | Notes |\n'
                '|---|---|---|---|---|---|---|\n'
                '| 2.4.0 (118) | macOS | 09:12 | 14 min | 1,204 passed | Shipped | Signed and notarised before lunch |\n'
                '| 2.4.0 (118) | Windows | 09:15 | 21 min | 1,198 passed | Shipped | The installer uploaded to the store |\n'
                '| 2.4.0 (117) | iOS | 08:40 | 11 min | 1,180 passed | Held | One flaky snapshot test, rerun at noon |')
_DIFF_PLAN = '--- a/notes/plan.md\n+++ b/notes/plan.md\n@@ -1,2 +1,3 @@\n # Plan\n-Ship 2.3\n+Ship 2.4\n+Write the notes\n'
_DIFF_TODO = '--- /dev/null\n+++ b/notes/todo.md\n@@ -0,0 +1,2 @@\n+- tag the build\n+- send the notes\n'
_ICON = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFUlEQVR42mNgqPpPGhrVMKph+GoAAG3QeRDihKnIAAAAAElFTkSuQmCC')
_T0 = 1791799200   # 2026-10-12 06:00 UTC


def _extras_rows():
    rows = [
        {'role': 'user', 'content': 'Where are the 2.4 release notes?'},
        {'role': 'assistant', 'content': 'They went up this morning:\n\n' + EXTRAS_LINK},
        {'role': 'system', 'content': '[System: The active model for this chat has changed to claude-sonnet-5. From this point on, answer as that model.]'},
        {'role': 'assistant', 'content': 'Cronjob Response: Morning brief\n(job_id: brief01)\n-------------\n\nTwo builds shipped and one is held for a rerun.'},
        {'role': 'user', 'content': 'How did the builds do?'},
        {'role': 'assistant', 'content': 'All three finished overnight.\n\n' + EXTRAS_TABLE},
        {'role': 'user', 'content': 'Tidy the notes for the release.'},
        {'role': 'assistant', 'content': '', 'tool_calls': [
            {'id': 'call_plan', 'function': {'name': 'patch', 'arguments': json.dumps({'path': 'notes/plan.md'})}},
            {'id': 'call_todo', 'function': {'name': 'write_file', 'arguments': json.dumps({'path': 'notes/todo.md'})}}]},
        {'role': 'tool', 'tool_call_id': 'call_plan', 'content': json.dumps({'success': True, 'inline_diff': _DIFF_PLAN})},
        {'role': 'tool', 'tool_call_id': 'call_todo', 'content': json.dumps({'success': True, 'inline_diff': _DIFF_TODO})},
        {'role': 'assistant', 'content': 'Done: the plan names 2.4 and the to-do list is new.'},
    ]
    return [{**r, 'row_id': 30001 + i, 'timestamp': _T0 + i * 60} for i, r in enumerate(rows)]


EXTRAS_ROWS = _extras_rows()
EXTRAS_STATE = {'sends': [], 'linkReads': []}


def is_extras(params):
    return params.get('session_id') in (EXTRAS, EXTRAS_RT)


def extras_resumed():
    info = {**menus.info_for('default'), 'cwd': FOLDERS['default'], 'tools': {}, 'skills': {}, 'mcp_servers': [], 'lazy': True,
            'stored_session_id': EXTRAS, 'profile_name': 'default', 'desktop_contract': 8, 'title': EXTRAS_TITLE, 'running': False}
    return {'session_id': EXTRAS_RT, 'resumed': EXTRAS, 'session_key': EXTRAS, 'stored_session_id': EXTRAS, 'messages': [],
            'messages_omitted': True, 'message_count': len(EXTRAS_ROWS), 'status': 'idle', 'running': False, 'inflight': None,
            'info': info}


_extras_prev_rpc = b47.rpc


def extras_rpc(method, params):
    if method in ('session.resume', 'session.activate') and is_extras(params):
        return extras_resumed()
    return _extras_prev_rpc(method, params)


b47.rpc = extras_rpc

_extras_prev_prompt = menus.MenusClient.prompt


def extras_prompt(self, frame):
    params = frame.get('params') or {}
    if not is_extras(params):
        return _extras_prev_prompt(self, frame)
    text = str(params.get('text') or '')
    with LOCK:
        EXTRAS_STATE['sends'].append(text)
        n = len(EXTRAS_STATE['sends'])
    try:
        if text.strip() == EXTRAS_REFUSED:
            self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': 5032, 'message': EXTRAS_REFUSAL}})
            return
        self.send({'jsonrpc': '2.0', 'id': frame['id'], 'result': {'status': 'streaming', 'user_row_id': 30100 + n}})
    except OSError:
        return
    time.sleep(0.3)
    menus.emit_runtime(EXTRAS_RT, 'error', {'message': EXTRAS_LIMIT})


menus.MenusClient.prompt = extras_prompt

_extras_prev_handler = b47.handler


def extras_handler(gateway):
    parent = _extras_prev_handler(gateway)

    class Handler(parent):
        def _raw(self, status, kind, data):
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            parsed = urlparse(self.path)
            path = parsed.path
            if path == '/__extras/state':
                with LOCK:
                    return self.reply(200, {'sends': list(EXTRAS_STATE['sends']), 'linkReads': list(EXTRAS_STATE['linkReads'])})
            if path.startswith('/__extras/link/'):
                if self.client_address[0] not in ('127.0.0.1', '::1'):
                    return self.reply(403, {'detail': 'loopback only'})
                with LOCK:
                    EXTRAS_STATE['linkReads'].append(path[len('/__extras/link'):])
                if path.endswith(('.ico', '.png')):
                    return self._raw(200, 'image/png', _ICON)
                page = ('<!doctype html><html><head><meta charset="utf-8"><title>' + EXTRAS_LINK_TITLE
                        + '</title></head><body><h1>' + EXTRAS_LINK_TITLE + '</h1><p>Synthetic page (fixture).</p></body></html>')
                return self._raw(200, 'text/html; charset=utf-8', page.encode('utf-8'))
            if path.startswith(f'/api/sessions/{EXTRAS}') and path.endswith('/messages'):
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                q = parse_qs(parsed.query)
                offset = max(0, int(q.get('offset', ['0'])[0]))
                limit = min(500, max(1, int(q.get('limit', ['500'])[0])))
                order = q.get('order', ['latest'])[0]
                rows = copy.deepcopy(EXTRAS_ROWS)
                page = list(reversed(rows))[offset:offset + limit][::-1] if order == 'latest' else rows[offset:offset + limit]
                return self.reply(200, {'session_id': EXTRAS, 'profile': 'default', 'messages': page,
                                        'pagination': {'limit': limit, 'offset': offset, 'order': order, 'returned': len(page),
                                                       'has_more': offset + len(page) < len(rows), 'next_offset': offset + len(page)}})
            return super().do_GET()

    return Handler


b47.handler = extras_handler

if __name__ == '__main__':
    b47.main()
