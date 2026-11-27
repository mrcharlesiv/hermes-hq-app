"""A scoped WinUI run. Use only a fresh hosted runner and the app's own fixture-backed walks.

This is not system notification, installer, screen-reader or complete desktop acceptance.
No desktop configuration, system UI automation helpers, signing, or identity changes.
"""
from contextlib import ExitStack
from pathlib import Path
from typing import NamedTuple
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from check_walk_pngs import app_image, intact_png


class Suite(NamedTuple):
    tag: str
    script: str
    port: int
    walks: tuple[str, ...]
    shots: tuple[str, ...]
    args: tuple[str, ...] = ()


# A successful walk without the corresponding images does not show how Find was drawn.
CHAT_REFLOW = ('chat-find-narrow', 'chat-find-expanded')
ROOM_REFLOW = ('group-room-find-narrow', 'group-room-find-expanded')
REFLOW_FRAMES = frozenset(CHAT_REFLOW + ROOM_REFLOW)

SUITES = (
    Suite('composer', 'composer-gateway.py', 9750, ('open-quickly', 'chat-find'),
          ('open-quickly', 'open-quickly-recent', 'open-quickly-results', 'open-quickly-settings',
           'open-quickly-settings-opened', 'chat-find', *CHAT_REFLOW, 'chat-find-closed')),
    Suite('settings', 'settings-gateway.py', 9830, ('settings-file',),
          ('settings-file', 'settings-file-buttons', 'settings-file-not-settings', 'settings-file-imported',
           'settings-file-clear-models-confirm', 'settings-file-reset-confirm', 'settings-file-reset-done',
           'settings-file-search', 'settings-file-search-clear-models')),
    Suite('groups', 'settings-gateway.py', 9831, ('group-room',),
          ('group-room', 'group-room-open', 'group-room-replies', 'group-room-typing', 'group-room-find', *ROOM_REFLOW), ('--group-rooms',)),
    Suite('sessions', 'sessions-gateway.py', 9771, ('new-chat-here',),
          ('new-chat-here', 'new-chat-here-project', 'new-chat-here-home', 'new-chat-here-bot')),
    Suite('keyboard-only', 'pages-fixture-gateway.py', 9862, ('keyboard-only',),
          ('keyboard-only', 'keyboard-only-composer', 'keyboard-only-tasks'), ('--task-lists', '--tick-seconds', '0')),
    Suite('a11y-audit', 'pages-fixture-gateway.py', 9861, ('a11y-audit',),
          ('a11y-audit', 'a11y-audit-chats', 'a11y-audit-settings'), ('--task-lists', '--tick-seconds', '0')),
)
CI = Path(__file__).resolve().parent


def require_runner(env, platform):
    required = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'Windows',
                'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/heads/feat/windows',
                'GITHUB_REPOSITORY': 'mrcharlesiv/hermes-hq-windows'}
    if platform != 'win32' or any(env.get(k) != v for k, v in required.items()):
        raise ValueError('requires a disposable hosted Windows push runner for the private feat/windows mirror')


def extra(suite, receipt):
    url = f'http://127.0.0.1:{suite.port}'
    if receipt.get('url') != url or not all(isinstance(receipt.get(k), str) and receipt[k] for k in ('username', 'password')):
        raise ValueError(f'{suite.tag}: incorrect synthetic fixture receipt')
    return dict(url=url, username=receipt['username'], password=receipt['password'],
                tag=suite.tag, places=[], walks=list(suite.walks))


def stop_owned(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def fixtures(stack, temp):
    # Fixture-only environment; never inherit a real gateway, proxy or credential configuration.
    env = {k: v for k, v in os.environ.items() if k.upper() in
           {'PATH', 'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'PATHEXT', 'COMSPEC', 'SYSTEMDRIVE'}}
    env.update(PYTHONUTF8='1', PYTHONDONTWRITEBYTECODE='1')
    result = []
    for suite in SUITES:
        receipt = temp / (suite.tag + '.json')
        args = [sys.executable, '-X', 'utf8', str(CI / 'fixtures' / suite.script), '--port', str(suite.port),
                '--credentials', str(receipt), *suite.args]
        if suite.script == 'pages-fixture-gateway.py':
            args += ['--files', str(temp / (suite.tag + '-files'))]
        # Check a port before starting anything on it. Hold no connection to an unrelated listener.
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', suite.port))
        proc = subprocess.Popen(args, cwd=temp, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stack.callback(stop_owned, proc)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and proc.poll() is None:
            if receipt.is_file():
                try:
                    data = json.loads(receipt.read_text(encoding='utf-8'))
                    with socket.create_connection(('127.0.0.1', suite.port), timeout=.3):
                        result.append(extra(suite, data))
                    break
                except (OSError, json.JSONDecodeError):
                    pass
            time.sleep(.1)
        else:
            raise ValueError(f'{suite.tag}: fixture did not start on its assigned port')
    return result


def check_evidence(out, suites=SUITES):
    # Automation logs per-extra errors and exits normally; process exit or a PNG by itself proves nothing.
    lines = (out / 'automation.log').read_text(encoding='utf-8-sig').splitlines()
    events = [re.sub(r'^\d\d:\d\d:\d\d\.\d{3} ', '', line) for line in lines]
    if not events or events[-1] != 'done' or 'extras only' not in events or any('failed:' in line.lower() for line in events):
        raise ValueError('the scoped app run did not finish cleanly')
    expected = [evt for suite in suites for walk in suite.walks
                for evt in (f'{suite.tag} walk {walk}', f'{suite.tag} walk {walk} finished')]
    if [line for line in events if ' walk ' in line] != expected:
        raise ValueError('the completed walks differ from the requested app proof')
    app_log = out / 'hermes-hq.log'
    if not app_log.is_file() or not app_log.stat().st_size: raise ValueError('the app log is missing')
    logs = [p for p in (out / 'hermes-hq.log.1', app_log) if p.exists()]
    composer = isolated = False
    for p in logs:
        for ln in p.read_text(encoding='utf-8-sig', errors='replace').splitlines():
            if ln.endswith('[automation] app-only: desktop notifications excluded'): isolated = True
            if '[unhandled]' in ln: raise ValueError('unhandled exception during the app walk')
            if '[automation] composer walk ' in ln: composer = True
            elif '[automation] signed in to ' in ln or ln.endswith('[automation] done'): composer = False
            if "couldn't open " in ln or (composer and ('[rpc] link dropped' in ln or 'listener threw' in ln)):
                raise ValueError('a page failed to open or the composer lost its connection; see the app log')
    if not isolated: raise ValueError('no app-only startup marker; refusing desktop-run evidence')
    hashes = {}
    for name in [shot for suite in suites for shot in suite.shots]:
        paths = [p for p in out.glob('*-' + name + '.png') if re.fullmatch(r'[0-9]+-' + re.escape(name) + r'\.png', p.name)]
        validate = app_image if name in REFLOW_FRAMES else intact_png
        if len(paths) != 1 or not validate(paths[0]):
            raise ValueError('missing, duplicate or invalid screenshot: ' + name)
        if name in REFLOW_FRAMES:
            hashes[name] = hashlib.sha256(paths[0].read_bytes()).digest()
    for narrow, expanded in (CHAT_REFLOW, ROOM_REFLOW):
        if narrow in hashes and hashes[narrow] == hashes.get(expanded):
            raise ValueError('same screenshot for ' + narrow + ' and ' + expanded)


def app_environment(parent, config):
    windows_env = {'SYSTEMROOT', 'WINDIR', 'PATH', 'PATHEXT', 'COMSPEC', 'SYSTEMDRIVE', 'TEMP', 'TMP',
                   'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA', 'PROGRAMFILES',
                   'PROGRAMFILES(X86)', 'COMMONPROGRAMFILES', 'COMMONPROGRAMFILES(X86)', 'DOTNET_ROOT'}
    env = {k: v for k, v in parent.items() if k.upper() in windows_env}
    env['HQW_AUTOMATION'] = str(config)
    env['HQW_APP_PROOF'] = '1'
    return env


def main():
    require_runner(os.environ, sys.platform)
    win = CI.parent
    exe = win / 'build/app/HermesHQ.exe'
    app_root = Path(os.environ['LOCALAPPDATA']) / 'HermesHQ'
    if app_root.exists(): raise ValueError('existing HermesHQ app data; refusing to use this desktop')
    if not exe.is_file(): raise ValueError('the scoped native app was not built')
    shots = win / 'build/shots'
    shots.mkdir(exist_ok=False, parents=True)
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP']) as folder, ExitStack() as stack:
        tmp = Path(folder)
        config = tmp / 'scoped-app.json'
        config.write_text(json.dumps(dict(extrasOnly=True, shots=str(shots), extras=fixtures(stack, tmp))), encoding='utf-8')
        env = app_environment(os.environ, config)
        try:
            with ExitStack() as owned:
                app = subprocess.Popen([str(exe)], cwd=exe.parent, env=env)
                owned.callback(stop_owned, app)
                if app.wait(timeout=780) != 0: raise ValueError('the native app exited unsuccessfully')
        finally:
            for name in ('hermes-hq.log', 'hermes-hq.log.1'):
                src = tmp / 'app-data' / 'logs' / name
                if src.is_file(): shutil.copyfile(src, shots / name)
        check_evidence(shots)
    print('Scoped WinUI walks finished; the images still need comparison with the Mac. Not full parity.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        raise SystemExit(str(e))
