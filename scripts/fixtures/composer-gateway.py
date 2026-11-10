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

Controls (no auth, loopback):
  GET  /__composer/state   {mode, counts: {method: n}, modelCalls, modelFailures,
                            completeLog: [{method, params, start, end}] (call order and overlap), pathCwds: [cwd…]}
  POST /__composer/mode    any subset of the mode keys; answers the full mode map
  POST /__composer/reset   default modes and counters, then the menus fixture's own reset

  python3 scripts/fixtures/composer-gateway.py --port 10030 --credentials build/fixtures/composer.json
"""
import hashlib, importlib.util, json, pathlib, threading, time
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

if __name__ == '__main__':
    b47.main()
