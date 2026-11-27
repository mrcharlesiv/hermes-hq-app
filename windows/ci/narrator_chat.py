"""Isolated Narrator focus proof. See narrator-chat/README.md. No desktop calls on import."""
from __future__ import annotations
from contextlib import ExitStack, contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

from app_proof import app_environment, require_runner, stop_owned

CI = Path(__file__).resolve().parent
MIRROR = 'mrcharlesiv/hermes-hq-windows'
REF = 'refs/heads/feat/windows'
MAC_1245 = '484cd6acf574259345242ef5c4e61a74a13ca8ce'
TARGETS = ('Inspector', 'Message', 'Send')
# The real page may have intermediate Tab stops. No wildcard, unknown ID or second lap.
MIDDLE = ('Transcript', 'Regenerate', 'More', 'Commands', 'Attach')  # forward order; Attach immediately precedes Message
MAX_MOVES = 12


def control(s):
    ident, name, role = s['id'] or s.get('xaml', ''), s['name'], s['role']
    if ident == 'chat.composer' and role == 'Edit': return 'Message'
    if role == 'Button':
        # The native walk checks the exact target control. Its label is evidence, not its identity.
        if ident == 'InspectorToggle': return 'Inspector'
        if ident == 'chat.send': return 'Send'
        for key, label in (('composer.plus', 'Attach'), ('chat.reply-more', 'More'), ('chat.regenerate-reply', 'Regenerate')):
            if ident == key and name == label: return label
        if not ident and name in ('Commands', 'Model'): return name
    if (ident, role) == ('chat.transcript', 'List'): return 'Transcript'
    raise ValueError('unrecognized focused control')


def arrivals(r):
    """Replay the actual focus and keyboard streams, not a summary logged by a walk."""
    focus, physical = r['focus'], r['physical']
    hwnd = r['hwnd']
    if (type(hwnd) is not int or hwnd <= 0 or len(focus) != len(physical) + 1
            or len(focus) > 3 * MAX_MOVES + 2 or control(focus[0]) != 'Message'):
        raise ValueError('incomplete keyboard/focus streams')
    stops = [control(s) for s in focus]
    i = 0

    def take(key):
        nonlocal i
        p = physical[i]
        if not (p['api'] == 'SendInput' and p['key'] == p['receivedKey'] == key and p['inserted'] == (4 if key == 'Shift+Tab' else 2)
                and type(p['received']) is int and p['received'] == 1 and p['frontBefore'] == p['frontAfter'] == hwnd
                and type(p['focusEvents']) is int and p['focusEvents'] == (0 if key == 'Q' else 1)
                and p['focusState'] == 'Keyboard'):
            raise ValueError('key was not inserted and received in the fixture')
        i += 1
        return stops[i]

    def move(key, target, via):
        seen = {stops[i]}
        for _ in range(MAX_MOVES):
            stop = take(key)
            if stop == target: return i
            if stop not in via or stop in seen: break
            seen.add(stop)
        raise ValueError('missing or out-of-order keyboard stop')

    inspector = move('Shift+Tab', 'Inspector', MIDDLE)
    composer = move('Tab', 'Message', MIDDLE)
    if stops[:inspector + 1][::-1] != stops[inspector:composer + 1]:
        raise ValueError('forward traversal did not retrace the ordinary chat controls')
    middle = stops[inspector + 1:composer]
    if not middle or middle[-1] != 'Attach' or middle != [s for s in MIDDLE if s in middle]:
        raise ValueError('the known composer entry or order of chat controls was skipped')
    q = physical[i]
    if (take('Q') != 'Message' or q['emptyBefore'] is not True or q['draftAfter'] != 'q'
            or q['sendEnabled'] is not True):
        raise ValueError('the physical draft key did not enable Send')
    send = move('Tab', 'Send', ('Model',))
    if i != len(physical): raise ValueError('unexpected input after Send focus')
    return [0, inspector, composer, send]


def speaks(words, target, exact=False):
    # en-US only. Match the announcement of the control, not a mention in another control's hint.
    if not isinstance(words, str) or len(words) > 240 or not re.fullmatch(r'[a-zA-Z\s.,:;!()\-]+', words): return False
    text = ' '.join(re.findall(r'[a-z]+', words.lower()))
    patterns = {'Inspector': r'inspector (?:off |on |not pressed |pressed )?(?:toggle )?button',
                'Message': r'message(?: proof hermes)? (?:multi line |multiline )?(?:edit|editing|text box)',
                'Send': r'send button'}
    first = re.match(patterns[target] + r'\b', text)
    if not first or (exact and target == 'Message' and text.startswith('message proof hermes ')): return False
    return not any(re.search(r'\b' + p + r'\b', text[first.end():]) for p in patterns.values())


def assess(r):
    labels: dict[str, bool | None] = {k: None for k in TARGETS}
    observed, spoken_labels = labels.copy(), labels.copy()
    v = {'pass': False, 'keyboard': False, 'spoken': False, 'macLabels': labels,
         'speechObserved': observed, 'spokenMacLabels': spoken_labels}
    try:
        if (r['schema'] != 1 or type(r['seededMessages']) is not int or r['seededMessages'] != 1
                or type(r['appPid']) is not int or type(r['narratorPid']) is not int
                or min(r['appPid'], r['narratorPid']) <= 0 or r['appPid'] == r['narratorPid']): return v
        indices = arrivals(r)
        v['keyboard'] = True
        for idx, target in zip(indices[1:], TARGETS): labels[target] = r['focus'][idx]['name'] == target
        if len(r['speech']) != len(indices): return v
        seq = None
        all_spoke = True
        for obs, at, target in zip(r['speech'], indices, ('Message', *TARGETS)):
            before, after = obs['sequenceBefore'], obs['sequenceAfter']
            words = obs['text']
            captured = (obs['at'] == at and obs['source'] == 'Narrator.CopyLastPhrase' and obs['key'] == 'Insert+Ctrl+X'
                        and obs['inserted'] == 6 and type(obs['receivedX']) is int and obs['receivedX'] == 0
                        and obs['ownerPid'] == r['narratorPid'] and obs['frontBefore'] == obs['frontAfter'] == r['hwnd']
                        and obs.get('unavailable') is None and type(before) is int and type(after) is int
                        and (seq is None or before == seq) and 0 <= before < after <= 0xffffffff
                        and isinstance(words, str) and 0 < len(words.strip()) <= 240)
            if at != 0:
                observed[target] = captured
                spoken_labels[target] = speaks(words, target, exact=True) if captured else None
            if not captured or not speaks(words, target): all_spoke = False
            seq = after
        v['spoken'] = all_spoke
        v['pass'] = all_spoke and r['completed'] is True and r['stop'] is None and all(labels.values()) and all(spoken_labels.values())
    except (KeyError, IndexError, TypeError, ValueError):
        pass  # Missing, partial, malformed and fallback records cannot certify a run.
    return v


def require_push(env, platform, event):
    require_runner(env, platform)
    repo = event.get('repository') if isinstance(event, dict) else None
    if not (isinstance(repo, dict) and repo.get('private') is True and repo.get('full_name') == MIRROR and event.get('ref') == REF
            and event.get('deleted') is False and re.fullmatch('[0-9a-f]{40}', env.get('GITHUB_SHA', ''))
            and all(re.fullmatch('[1-9][0-9]*', env.get(k, '')) for k in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'))
            and event.get('after') == env['GITHUB_SHA']):
        raise ValueError('expected the private mirror push payload for this exact checkout')


def require_build(folder, sha):
    # Bind the separate publish to this push. In particular never start a normal shipping binary by accident.
    stamp = folder / 'narrator-chat.build'
    if not stamp.is_file() or stamp.stat().st_size > 384: raise ValueError('opt-in build receipt missing or invalid')
    actual = [sha]
    for name in ('HermesHQ.exe', 'HermesHQ.dll'):
        h = hashlib.sha256()
        with (folder / name).open('rb') as f:
            for block in iter(lambda: f.read(65536), b''): h.update(block)
        actual.append(h.hexdigest().upper())
    if stamp.read_text(encoding='utf-8-sig').splitlines() != actual: raise ValueError('wrong fixture build for this push')


def read_owned_trace(path, app_pid, narrator_pid):
    if path.stat().st_size > 65536: raise ValueError('oversize fixture trace')
    trace = json.loads(path.read_text(encoding='utf-8-sig'))
    if not (isinstance(trace, dict) and trace.get('schema') == 1 and trace.get('appPid') == app_pid
            and trace.get('narratorPid') == narrator_pid): raise ValueError('trace does not belong to the owned app and reader')
    return trace


@contextmanager
def standin():
    # Bind before publishing the port. This process owns the server until the child has exited.
    from http.server import ThreadingHTTPServer
    spec = importlib.util.spec_from_file_location('narrator_fixture', CI / 'fixtures/action-voice-fixture-gateway.py')
    if spec is None or spec.loader is None: raise ValueError('loopback fixture module unavailable')
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    fixture.LABEL = 'Proof'
    phrase = secrets.token_hex(16)
    class LoopbackServer(ThreadingHTTPServer):
        allow_reuse_address = False

        def server_bind(self):
            exclusive = getattr(socket, 'SO_EXCLUSIVEADDRUSE', None)
            if exclusive is not None: self.socket.setsockopt(socket.SOL_SOCKET, exclusive, 1)
            super().server_bind()

    gateway = fixture.auth.Gateway('fixture', phrase, True, None, hermes=True)
    with LoopbackServer(('127.0.0.1', 0), fixture.handler(gateway)) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield {'port': server.server_port, 'phrase': phrase}, fixture.state
        finally:
            server.shutdown()
            thread.join(2)


def _fresh_output(env):
    require_runner(env, sys.platform)  # before even opening the event file, much less a desktop or clipboard
    require_push(env, sys.platform, json.loads(Path(env['GITHUB_EVENT_PATH']).read_text(encoding='utf-8')))
    if (Path(env['GITHUB_WORKSPACE']).resolve() / 'windows/ci' != CI
            or Path(env['LOCALAPPDATA'], 'HermesHQ').exists()):
        raise ValueError('requires a fresh mirror checkout and empty app profile')
    out = CI.parent / 'build/narrator-chat'
    out.mkdir(parents=True, exist_ok=False)  # never certify another run's trace
    return out


def run(env):
    out = _fresh_output(env)  # refusals before admission cannot mint a receipt
    exe = out.parent / 'narrator-chat-app/HermesHQ.exe'
    result: dict[str, Any] = dict(mirrorSha=env['GITHUB_SHA'], runId=env['GITHUB_RUN_ID'], attempt=env['GITHUB_RUN_ATTEMPT'],
                  receiptVersion=2, macReference=MAC_1245, trace={}, runnerStop=None, cleanupStop=None,
                  appExit=None, readerAliveAtAppExit=None, fixture=None)

    def cleanup(name, release, *args):
        try:
            release(*args)
            return True
        except Exception:
            # Continue releasing the other owned resources; never replace the primary stop.
            result['cleanupStop'] = result['cleanupStop'] or name
            return False

    with ExitStack() as owned:
        def enter(name, resource):
            lease = ExitStack()
            value = lease.enter_context(resource)
            owned.callback(cleanup, name, lease.close)  # only once acquisition succeeded
            return value

        phase = 'verify-build'
        try:
            require_build(exe.parent, env['GITHUB_SHA'])
            phase = 'create-temp'
            tmp = Path(enter('remove-temp', tempfile.TemporaryDirectory(prefix='hq-narrator-', dir=env['RUNNER_TEMP'])))
            phase = 'prepare-env'
            seed = tmp / 'seed.json'
            platform_env = app_environment(env, seed)
            # No ambient gateway, proxy, identity, token or other job configuration in either child.
            os_env = {k: v for k, v in platform_env.items() if not k.startswith('HQW_')}
            system = Path(env['SystemRoot']) / 'System32'
            phase = 'verify-head'
            head = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=CI.parents[1], env=os_env,
                                  capture_output=True, check=True, text=True, timeout=5).stdout.strip()
            if head != env['GITHUB_SHA']: raise ValueError('checked-out mirror commit is not the admitted push')
            # Never switch sessions, open a desktop or attach to an existing reader.
            phase = 'probe-session'
            check = subprocess.run([str(system / 'WindowsPowerShell/v1.0/powershell.exe'), '-NoProfile', '-NonInteractive',
                                    '-Command', "try { if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {exit 42}; "
                                    "if ([Diagnostics.Process]::GetProcessesByName('Narrator').Length) {exit 41}; exit 0 } catch {exit 3}"],
                                   env=os_env, timeout=8, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if check.returncode:
                # Only the guard branches return these reserved statuses. A generic host failure (e.g. 1) is not a finding.
                phase = {41: 'require-no-reader', 42: 'require-interactive'}.get(check.returncode, phase)
                raise ValueError
            phase = 'start-standin'
            auth, state = enter('stop-standin', standin())
            phase = 'launch-reader'
            reader = subprocess.Popen([str(system / 'Narrator.exe')], cwd=system, env=os_env)
            owned.callback(cleanup, 'stop-reader', stop_owned, reader)
            phase = 'check-reader'
            time.sleep(2)  # launch normally first; don't dismiss Narrator Home or a first-run prompt
            if reader.poll() is not None: raise ValueError('the launched Narrator did not remain available')
            phase = 'write-seed'
            seed.write_text(json.dumps({**auth, 'narratorPid': reader.pid}), encoding='utf-8')
            phase = 'prepare-app-env'
            names = ('GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'RUNNER_OS', 'GITHUB_EVENT_NAME', 'GITHUB_REF',
                     'GITHUB_REPOSITORY', 'GITHUB_EVENT_PATH', 'GITHUB_SHA', 'RUNNER_TEMP')
            child_env = {**platform_env, **{k: env[k] for k in names}, 'HQW_NARRATOR_CHAT': '1'}
            phase = 'launch-app'
            app = subprocess.Popen([str(exe)], cwd=exe.parent, env=child_env)
            owned.callback(cleanup, 'stop-app', stop_owned, app)
            phase = 'wait-app'
            try:
                result['appExit'] = app.wait(timeout=90)
                phase = 'check-reader-exit'
                result['readerAliveAtAppExit'] = reader.poll() is None
                if result['appExit'] != 0 or not result['readerAliveAtAppExit']: result['runnerStop'] = 'check-exit'
            except Exception:
                result['runnerStop'] = phase  # take the first fault *before* collecting partial evidence

            if cleanup('stop-app', stop_owned, app):
                # A timeout or safe abort may still have useful observations. Never read a still-running app's trace.
                phase = 'read-trace'
                tracefile = tmp / 'trace.json'
                if tracefile.is_file(): result['trace'] = read_owned_trace(tracefile, app.pid, reader.pid)
                phase = 'read-fixture'
                result['fixture'] = dict(promptAttempts=state['promptAttempts'], upstreamCalls=state['upstreamCalls'],
                    uploads=len(state['uploads']), historyRequested=any(call['method'] == 'GET' and
                    call['path'].split('?')[0] == '/api/sessions/20260929_120000_aabbcc01/messages' for call in state['rest']))
                if result['runnerStop'] is None:
                    if not result['trace']: result['runnerStop'] = 'require-trace'
                    elif result['fixture'] != dict(promptAttempts=0, upstreamCalls=0, uploads=0, historyRequested=True):
                        result['runnerStop'] = 'check-fixture'
        except Exception:
            result['runnerStop'] = result['runnerStop'] or phase  # neither exception text nor its class goes on the wire
    result['verdict'] = assess(result['trace'])
    if result['runnerStop'] or result['cleanupStop']: result['verdict']['pass'] = False
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result['verdict']['pass']


if __name__ == '__main__':
    if sys.argv[1:] != ['--disposable-narrator-chat']: raise SystemExit('explicit disposable-runner opt-in required')
    try:
        raise SystemExit(0 if run(os.environ) else 1)
    except Exception:
        raise SystemExit('Narrator driver refused the request or could not write the receipt.')
