#!/usr/bin/env python3
"""Siri, Shortcuts and quick actions stand-in gateway for HQ Native (docs/spec/3x-intents.md §12.1).
Loopback only, invented state, stdlib only. A thin layer over scripts/fixtures/voice-gateway.py, which is loaded by
path and not edited: two bots, `default` ("Hermes") and `ivy` ("Ivy"), with the voice fixture's whole memo pipeline
(/api/files, upload, file.attach, transcription, prompt.submit). On top of it:

  POST /__fixture/intents        any of
       {"names": {"ivy": "Samantha"}}                 renames in every profiles.list answer (the row's display_name
                                                       and its hermes-bots title)
       {"removed": ["ivy"]}                            drops bots from the roster
       {"extraBots": 300}                              appends that many invented bots (bot-001 …, "Bot 001" …;
                                                       they cannot be opened)
       {"delay": {"profiles.list": 8, "session.resume": 3}}   seconds before answering
       {"fail": {"session.resume": 2}}                 the next n calls answer error 5000 "Synthetic failure"
       {"reset": true}                                 clears all of it, and the counts
  GET  /__fixture/intents-state  {"counts": {"<method>": n}, "rpc": [the last 500 {method, params, at}], "controls": {…}}

/__fixture/voice, /__fixture/voice-state and /__fixture/memo-history are the voice fixture's, unchanged.

  python3 scripts/fixtures/intents-gateway.py --port 9920 --credentials build/fixtures/intents-dev.json \
      --media-dir build/fixtures/intents-media-9920 [--ref /Users/me/Projects/hermes-hq-native-ref238] [--label Beta]
Never contacts a real gateway.
"""
import argparse, collections, importlib.util, json, os, pathlib, socket, subprocess, sys, threading, time
from urllib.parse import urlparse

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--credentials', required=True)
parser.add_argument('--media-dir', required=True)
parser.add_argument('--ref', default='/Users/me/Projects/hermes-hq-native-ref238')
parser.add_argument('--label', default='')
own = parser.parse_args()
if not 9920 <= own.port <= 9929 and not os.environ.get('HQN_INTENTS_ANY_PORT'):
    sys.exit('intents fixture ports are 9920-9929 (set HQN_INTENTS_ANY_PORT=1 to override)')

# Refuse a busy port before anything is loaded: another agent, or the owner's own Hermes, may be listening there.
# (A plain bind also fails for half a minute after this fixture's own last run closed the port; then nothing listens,
# which `lsof` tells apart without connecting to anything.)
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    probe.bind(('127.0.0.1', own.port))
except OSError:
    listening = subprocess.run(['lsof', '-nP', f'-iTCP:{own.port}', '-sTCP:LISTEN'], capture_output=True, text=True).stdout.strip()
    if listening: sys.exit(f'port {own.port} is already in use')
finally:
    probe.close()

# The voice fixture parses its arguments as it is imported.
os.environ['HQN_VOICE_ANY_PORT'] = '1'
sys.argv = [sys.argv[0], '--port', str(own.port), '--credentials', own.credentials, '--media-dir', own.media_dir, '--ref', own.ref]
HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('voice_fixture', HERE / 'voice-gateway.py')
voice = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voice)
base = voice.base                       # build47 module; base.voice = action-voice (the roster lives there)
base.voice.LABEL = own.label

LOCK = threading.RLock()
DEFAULTS = {'names': {}, 'removed': [], 'extraBots': 0, 'delay': {}, 'fail': {}}
CONTROLS = json.loads(json.dumps(DEFAULTS))
COUNTS = collections.Counter()
CALLS = collections.deque(maxlen=500)


def note(method, params):
    logged = {k: v for k, v in (params or {}).items() if k not in ('data_url', 'soul')}
    with LOCK:
        COUNTS[method] += 1
        CALLS.append({'method': method, 'params': logged, 'at': time.time()})
        delay = float(CONTROLS['delay'].get(method) or 0)
        fail = int(CONTROLS['fail'].get(method) or 0)
        if fail > 0: CONTROLS['fail'][method] = fail - 1
    return delay, fail > 0


def extra_row(index):
    name = f'bot-{index:03d}'
    stored = f'20260929_130000_{index:08x}'
    session = {'id': stored, 'title': 'Bot Chat', 'profile': name, 'profile_name': name, 'hidden': True,
               'model': 'fixture-model', 'billing_provider': 'fixture', 'message_count': 1, 'started_at': 1790686800,
               'last_active': 1790686800, 'source': 'desktop', 'cwd': '/fixture'}
    return {'name': name, 'display_name': f'Bot {index:03d}', 'is_active': False, 'description': 'Synthetic extra bot',
            'model': 'fixture-model', 'canonical_session': session, 'sessions': [session],
            'ui_meta': {'hermes-bots': {'title': f'Bot {index:03d}'}}}


def roster(result):
    """The profiles.list answer with the controls applied (a copy; the base fixture's own rows are left alone)."""
    if not isinstance(result, dict) or not isinstance(result.get('profiles'), list): return result
    with LOCK:
        names, removed, extra = dict(CONTROLS['names']), set(CONTROLS['removed']), int(CONTROLS['extraBots'] or 0)
    rows = []
    for row in result['profiles']:
        if row.get('name') in removed: continue
        if row.get('name') in names:
            # As a gateway shows a renamed bot: the row's display name and the bot's title in its own meta.
            shown = names[row['name']]
            meta = dict(row.get('ui_meta') or {})
            meta['hermes-bots'] = {**(meta.get('hermes-bots') or {}), 'display_name': shown, 'title': shown}
            row = {**row, 'display_name': shown, 'ui_meta': meta}
        rows.append(row)
    rows += [extra_row(index) for index in range(1, extra + 1)]
    return {**result, 'profiles': rows}


def wrapped(original):
    def rpc(method, params):
        delay, fail = note(method, params)
        if delay: time.sleep(delay)
        if fail: raise ValueError('5000|Synthetic failure')        # the voice fixture's send turns "<code>|" into the code
        result = original(method, params)
        return roster(result) if method == 'profiles.list' else result
    return rpc


# The socket's calls go through the build47 module's `rpc` (the voice fixture's `voice_rpc` by now); the plain-HTTP
# roster read goes through the action-voice module's. The two never call one another, so each call counts once.
base.rpc = wrapped(base.rpc)
base.voice.rpc = wrapped(base.voice.rpc)

_original_prompt = base.Client.prompt
def counted_prompt(self, frame):
    delay, fail = note('prompt.submit', frame.get('params') or {})
    if delay: time.sleep(delay)
    if fail:
        try: self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': 5000, 'message': 'Synthetic failure'}})
        except OSError: pass
        return
    return _original_prompt(self, frame)
base.Client.prompt = counted_prompt

_voice_handler = voice.handler
def handler(gateway):
    parent = _voice_handler(gateway)

    class Handler(parent):
        def do_GET(self):
            if urlparse(self.path).path == '/__fixture/intents-state':
                with LOCK:
                    return self.reply(200, {'counts': dict(COUNTS), 'rpc': list(CALLS), 'controls': CONTROLS})
            return super().do_GET()

        def do_POST(self):
            if urlparse(self.path).path != '/__fixture/intents': return super().do_POST()
            try: payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
            except ValueError: return self.reply(400, {'detail': 'Invalid JSON'})
            with LOCK:
                if payload.pop('reset', False):
                    CONTROLS.clear(); CONTROLS.update(json.loads(json.dumps(DEFAULTS)))
                    COUNTS.clear(); CALLS.clear()
                for key, value in payload.items():
                    if key in DEFAULTS: CONTROLS[key] = value
                return self.reply(200, {'ok': True, 'controls': CONTROLS})

    return Handler
voice.handler = handler                  # voice.main() builds its server from the module's `handler`


if __name__ == '__main__':
    voice.main()
