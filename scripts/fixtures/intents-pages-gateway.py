#!/usr/bin/env python3
"""Quick-actions stand-in gateway for HQ Native (docs/spec/3x-intents.md §12.1, the second account "C2").
Loopback only, invented state, stdlib only. scripts/fixtures/restore-gateway.py (the pages fixture: five bots, listed
chats, and the /__restore/* controls) loaded by path, nothing there is edited, with one difference a real gateway has
and the pages fixture does not:

  session.resume / session.activate of a chat that was deleted (POST /__restore/delete {session_id}) answers
  error 4007 "session not found". The pages fixture falls back to a bot's chat there, which would hide what a Home
  Screen item for a deleted chat does (§13 A41).

Everything else, and every control, is restore-gateway.py's:
  POST /__restore/delete {session_id}   POST /__restore/remove-bot {profile}   POST /__restore/reset

  python3 scripts/fixtures/intents-pages-gateway.py --port 9922 --credentials build/fixtures/intents-pages.json \
      --files build/fixtures/intents-pages-files --tick-seconds 0
Never contacts a real gateway.
"""
import importlib.util, json, os, pathlib, re, socket, subprocess, sys

def asked_port():
    for index, word in enumerate(sys.argv):
        if word == '--port' and index + 1 < len(sys.argv): return int(sys.argv[index + 1])
        if word.startswith('--port='): return int(word.split('=', 1)[1])
    sys.exit('usage: intents-pages-gateway.py --port <9920-9929> --credentials <file> --files <folder> [--tick-seconds 0]')

PORT = asked_port()
if not 9920 <= PORT <= 9929 and not os.environ.get('HQN_INTENTS_ANY_PORT'):
    sys.exit('intents fixture ports are 9920-9929 (set HQN_INTENTS_ANY_PORT=1 to override)')

# Refuse a busy port before anything is loaded: another agent, or the owner's own Hermes, may be listening there.
# (A plain bind also fails for half a minute after this fixture's own last run closed the port; then nothing listens,
# which `lsof` tells apart without connecting to anything.)
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    probe.bind(('127.0.0.1', PORT))
except OSError:
    listening = subprocess.run(['lsof', '-nP', f'-iTCP:{PORT}', '-sTCP:LISTEN'], capture_output=True, text=True).stdout.strip()
    if listening: sys.exit(f'port {PORT} is already in use')
finally:
    probe.close()

_spec = importlib.util.spec_from_file_location('hqn_intents_restore', pathlib.Path(__file__).resolve().parent / 'restore-gateway.py')
restore = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(restore)
pages = restore.pages

# Every chat id this fixture has ever listed (and its runtime id): one of these that is no longer there was deleted.
KNOWN = set()

def remember():
    with pages.lock:
        for sid in pages.SESSIONS:
            KNOWN.add(sid)
            KNOWN.add(pages.runtime(sid))

_reseed = pages.reseed
def reseed():
    _reseed()
    remember()
pages.reseed = reseed

_rpc = pages.rpc
def rpc(method, params):
    remember()
    if method in ('session.resume', 'session.activate'):
        asked = params.get('session_id')
        if isinstance(asked, str) and asked in KNOWN:
            with pages.lock: found = pages.find_session(asked)
            if found is None:
                with pages.lock: pages.state['rpc'].append({'method': method, 'params': dict(params)})
                raise ValueError('4007|session not found')
    return _rpc(method, params)
pages.rpc = rpc
pages.fx.rpc = rpc


class Json:
    """The pages fixture's socket answers every refusal with code -32001. A message "<code>|text" carries its own."""
    def __getattr__(self, name): return getattr(json, name)

    def dumps(self, value, *args, **kwargs):
        error = value.get('error') if isinstance(value, dict) else None
        if isinstance(error, dict) and isinstance(error.get('message'), str):
            match = re.fullmatch(r'(\d{4})\|(.*)', error['message'], re.S)
            if match: value = dict(value, error={'code': int(match.group(1)), 'message': match.group(2)})
        return json.dumps(value, *args, **kwargs)

pages.json = Json()

if __name__ == '__main__':
    pages.main()
