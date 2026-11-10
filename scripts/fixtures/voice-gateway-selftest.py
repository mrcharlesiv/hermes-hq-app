#!/usr/bin/env python3
"""Self-test of the live-voice routes of scripts/fixtures/voice-gateway.py (3x-talk §12). Stdlib only.

  python3 scripts/fixtures/voice-gateway-selftest.py --port 9900 --credentials build/fixtures/talk-dev.json

Signs in with the fixture's own invented credentials (read from the file the fixture wrote) and talks to 127.0.0.1
only. Prints one line per check and exits 1 on the first failure.
"""
import argparse, base64, hashlib, http.cookiejar, json, os, socket, struct, sys, time, urllib.error, urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--credentials', required=True)
args = parser.parse_args()
BASE = f'http://127.0.0.1:{args.port}'
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def call(method, path, body=None, raw=False):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, method=method, headers={'Content-Type': 'application/json'})
    try:
        with opener.open(request, timeout=30) as response:
            text = response.read()
            return response.status, text if raw else json.loads(text or b'null')
    except urllib.error.HTTPError as error:
        text = error.read()
        try: return error.code, text if raw else json.loads(text or b'null')
        except ValueError: return error.code, text


def check(name, ok, detail=''):
    print(('ok   ' if ok else 'FAIL ') + name + (f'  {detail}' if detail and not ok else ''), flush=True)
    if not ok: sys.exit(1)


def control(**values): return call('POST', '/__fixture/voice', values)
def ledger(): return call('GET', '/__fixture/voice-state')[1]


class Socket:
    def __init__(self, path):
        cookie = '; '.join(f'{c.name}={c.value}' for c in jar)
        self.s = socket.create_connection(('127.0.0.1', args.port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{args.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nCookie: {cookie}\r\n\r\n').encode())
        head = b''
        while b'\r\n\r\n' not in head:
            chunk = self.s.recv(1)
            if not chunk: break
            head += chunk
        self.status = int(head.split(b' ')[1]) if head else 0

    def send(self, value):
        body = json.dumps(value).encode()
        mask = os.urandom(4)
        n = len(body)
        header = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack('>H', n))
        self.s.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(body)))

    def read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.s.recv(n - len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data

    def frames(self, seconds=10):
        """Every frame until close / end of stream: ('json', value) | ('binary', bytes) | ('close', code) | ('eof', None)."""
        out, deadline = [], time.time() + seconds
        self.s.settimeout(seconds)
        try:
            while time.time() < deadline:
                first, second = self.read(2)
                opcode, n = first & 15, second & 127
                if n == 126: n = struct.unpack('>H', self.read(2))[0]
                elif n == 127: n = struct.unpack('>Q', self.read(8))[0]
                payload = self.read(n)
                if opcode == 1: out.append(('json', json.loads(payload)))
                elif opcode == 2: out.append(('binary', payload))
                elif opcode == 8:
                    out.append(('close', struct.unpack('>H', payload[:2])[0] if len(payload) >= 2 else 1005))
                    break
                if out and out[-1][0] == 'json' and out[-1][1].get('type') in ('end', 'fallback'): break
        except (ConnectionError, OSError):
            out.append(('eof', None))
        return out

    def close(self):
        try: self.s.close()
        except OSError: pass


credentials = json.load(open(args.credentials))
status, _ = call('POST', '/auth/password-login', {'username': credentials['username'], 'password': credentials['password']})
check('sign in to the stand-in', status == 200, str(status))
control(reset=True)

# speak (one clip)
status, answer = call('POST', '/api/audio/speak?profile=default', {'text': 'Your first meeting is at nine.'})
clip = base64.b64decode(answer['data_url'].split(',', 1)[1])
check('speak answers a WAV data URL', status == 200 and answer['mime_type'] == 'audio/wav' and clip[:4] == b'RIFF' and answer['provider'] == 'fixture')
check('speak length is 0.06 s a character', abs((len(clip) - 44) / 48000 - 0.06 * 30) < 0.01, str((len(clip) - 44) / 48000))
check('speak empty text is 400', call('POST', '/api/audio/speak', {'text': ' '}) == (400, {'detail': 'Text is required'}))
control(speakFail={'status': 503, 'detail': 'No voice today'})
check('speakFail', call('POST', '/api/audio/speak', {'text': 'hi'}) == (503, {'detail': 'No voice today'}))
control(speakFail=None, speakMime='audio/ogg')
check('speakMime', call('POST', '/api/audio/speak', {'text': 'hi'})[1]['mime_type'] == 'audio/ogg')
control(speakMime=None, speakRaw={'status': 200, 'body': 'not json'})
check('speakRaw', call('POST', '/api/audio/speak', {'text': 'hi'}, raw=True) == (200, b'not json'))
check('speakRaw is one-shot', call('POST', '/api/audio/speak', {'text': 'hi'})[0] == 200)
check('speak ledger', [s['text'] for s in ledger()['speaks']][:2] == ['Your first meeting is at nine.', ''] and ledger()['speaks'][0]['keys'] == ['text'])

# speak-stream
control(streamPace=0)
ws = Socket('/api/audio/speak-stream?profile=ivy&ticket=abc')
check('speak-stream upgrades', ws.status == 101, str(ws.status))
ws.send({'text': 'Sure. Your first meeting '}); ws.send({'text': 'is at nine.'}); ws.send({'done': True})
frames = ws.frames()
ws.close()
audio = sum(len(f[1]) for f in frames if f[0] == 'binary')
check('speak-stream start frame', frames[0] == ('json', {'type': 'start', 'sample_rate': 24000, 'channels': 1}), str(frames[0]))
check('speak-stream PCM length', abs(audio / 48000 - 0.06 * 36) < 0.02, str(audio / 48000))
check('speak-stream 100 ms frames', all(len(f[1]) <= 4800 for f in frames if f[0] == 'binary'))
check('speak-stream end frame', frames[-1] == ('json', {'type': 'end'}), str(frames[-1]))
time.sleep(0.3)
entry = ledger()['streams'][-1]
check('speak-stream ledger', entry['profile'] == 'ivy' and entry['texts'] == ['Sure. Your first meeting ', 'is at nine.'] and entry['done'] and not entry['stopped'] and entry['bytes'] == audio, str(entry))

control(streamPace=1)
ws = Socket('/api/audio/speak-stream?profile=default&ticket=abc')
ws.send({'text': 'x' * 100})
time.sleep(0.5)
ws.send({'stop': True})
frames = ws.frames(4)
ws.close()
time.sleep(0.3)
entry = ledger()['streams'][-1]
check('speak-stream stop ends early', entry['stopped'] and entry['bytes'] < 48000 * 2, str(entry))

control(streamMode='fallback')
ws = Socket('/api/audio/speak-stream?ticket=abc'); ws.send({'text': 'hello'})
check('streamMode fallback', ws.frames(4)[0] == ('json', {'type': 'fallback'})); ws.close()
control(streamMode='refuse')
ws = Socket('/api/audio/speak-stream?ticket=abc')
check('streamMode refuse closes 4401', ws.frames(4)[0] == ('close', 4401)); ws.close()
control(streamMode='drop', streamDropAfterMs=200)
ws = Socket('/api/audio/speak-stream?ticket=abc'); ws.send({'text': 'x' * 100})
frames = ws.frames(6)
check('streamMode drop aborts without a close frame', frames[-1][0] == 'eof' and frames[0][0] == 'json', str([f[0] for f in frames][-3:])); ws.close()
control(streamMode='silent')
ws = Socket('/api/audio/speak-stream?ticket=abc'); ws.send({'text': 'hello'}); ws.send({'done': True})
ws.s.settimeout(1.0)
try: silent = ws.s.recv(1) == b''
except socket.timeout: silent = True
check('streamMode silent never answers', silent); ws.close()
control(streamMode='ok', streamPace=0, streamScript=[{'json': {'type': 'start', 'sample_rate': 24000, 'channels': 1}}, {'toneMs': 200}, {'bytes': 3}, {'close': 4403}])
ws = Socket('/api/audio/speak-stream?ticket=abc'); ws.send({'text': 'hello'})
frames = ws.frames(4)
check('streamScript frames', [f[0] for f in frames] == ['json', 'binary', 'binary', 'binary', 'close'] and len(frames[3][1]) == 3 and frames[-1][1] == 4403, str([(f[0], len(f[1]) if f[0] == 'binary' else f[1]) for f in frames])); ws.close()
control(streamPace=0, streamScript=[{'json': {'type': 'start', 'sample_rate': 24000, 'channels': 1}}, {'toneMs': 100, 'frameBytes': 1001}, {'wait': 0.3}, {'toneMs': 50}, {'json': {'type': 'end'}}])
ws = Socket('/api/audio/speak-stream?ticket=abc'); ws.send({'text': 'Run `npm install` and read [the docs](https://example.com/guide).'})
frames = ws.frames(8)
sizes = [len(f[1]) for f in frames if f[0] == 'binary']
check('streamScript odd frames', sizes[:5] == [1001, 1001, 1001, 1001, 796] and sum(sizes) == 4800 + 2400 and frames[-1] == ('json', {'type': 'end'}), str(sizes)); ws.close()
time.sleep(0.2)
check('speak-stream ledger says what a voice would say', ledger()['streams'][-1]['spoken'] == 'Run npm install and read the docs.', str(ledger()['streams'][-1]['spoken']))
control(streamRate=16000, streamChannels=2)
ws = Socket('/api/audio/speak-stream?ticket=abc'); ws.send({'text': 'hello'}); ws.send({'done': True})
check('streamRate and streamChannels', ws.frames(4)[0][1] == {'type': 'start', 'sample_rate': 16000, 'channels': 2}); ws.close()
control(streamRate=24000, streamChannels=1)
status, _ = call('GET', '/api/audio/speak-stream')
check('speak-stream without an upgrade is 400', status == 400)

# leases
status, answer = call('POST', '/api/audio/tts-lease', {'active': True, 'lease': 'hqnative:conversation:test'})
check('tts lease held', status == 200 and answer == {'ok': True, 'lease': 'hqnative:conversation:test', 'active': True, 'leases': ['hqnative:conversation:test']}, str(answer))
call('POST', '/api/audio/stt-lease', {'active': True, 'lease': 'hqnative:conversation:test'})
check('lease ledger', ledger()['leases'] == {'tts': ['hqnative:conversation:test'], 'stt': ['hqnative:conversation:test']})
call('POST', '/api/audio/tts-lease', {'active': False, 'lease': 'hqnative:conversation:test'})
check('lease released', ledger()['leases']['tts'] == [])
check('lease is required', call('POST', '/api/audio/stt-lease', {'active': True}) == (400, {'detail': 'lease is required'}))
control(leaseFail=True)
check('leaseFail', call('POST', '/api/audio/tts-lease', {'active': True, 'lease': 'x'})[0] == 500)
control(leaseFail=False)

# voices
status, answer = call('GET', '/api/audio/elevenlabs/voices')
check('elevenlabs voices', status == 200 and answer['available'] and [v['label'] for v in answer['voices']] == ['Rachel', 'Adam'])
control(elevenVoices='unavailable'); check('elevenVoices unavailable', call('GET', '/api/audio/elevenlabs/voices')[1] == {'available': False, 'voices': []})
control(elevenVoices='fail'); check('elevenVoices fail', call('GET', '/api/audio/elevenlabs/voices')[0] == 500)
control(elevenVoices='ok')

# config
status, config = call('GET', '/api/config?profile=default')
check('config has the voice keys', status == 200 and config['stt']['enabled'] is True and config['tts']['provider'] == 'edge' and config['voice']['silence_duration'] == 3.0 and config['voice']['stop_phrases'] == ['stop'])
check('config has the keys that must stay hidden', config['voice']['voice_chat_mode'] == 'chained' and 'client_direct' in config['voice'] and 'gpt_live' in config['voice'] and 'wake_word' in config['voice'])
control(stt={'default': True, 'ivy': False})
check('stt control per profile', call('GET', '/api/config?profile=ivy')[1]['stt']['enabled'] is False and call('GET', '/api/config?profile=default')[1]['stt']['enabled'] is True)
control(stt={'default': True}, voiceConfig={'voice': {'barge_in': False, 'stop_phrases': ['fin']}})
check('voiceConfig control', call('GET', '/api/config')[1]['voice']['barge_in'] is False and call('GET', '/api/config')[1]['voice']['stop_phrases'] == ['fin'])
control(voiceConfig={})
schema = call('GET', '/api/config/schema')[1]
check('schema has the voice fields', schema['fields']['stt.provider']['options'][0] == 'local' and 'voice.wake_word.enabled' in schema['fields'] and 'display.personality' in schema['fields'])
check('defaults', call('GET', '/api/config/defaults')[1]['voice']['max_recording_seconds'] == 120)
check('PUT must be {config}', call('PUT', '/api/config', {'config': {}, 'x': 1})[0] == 400 and call('PUT', '/api/config', {'stt': {}})[0] == 400)
check('PUT merges', call('PUT', '/api/config', {'config': {'tts': {'provider': 'openai'}}}) == (200, {'ok': True}) and call('GET', '/api/config')[1]['tts']['provider'] == 'openai' and call('GET', '/api/config')[1]['tts']['edge']['voice'] == 'en-US-AriaNeural')
control(configPutFail={'status': 500, 'detail': 'Disk full'})
check('configPutFail', call('PUT', '/api/config', {'config': {'tts': {'provider': 'piper'}}}) == (500, {'detail': 'Disk full'}) and call('GET', '/api/config')[1]['tts']['provider'] == 'openai')
check('configPuts ledger', ledger()['configPuts'] == [{'tts': {'provider': 'openai'}}, {'tts': {'provider': 'piper'}}])
control(configPutFail=None, schemaVoice=False)
check('schemaVoice false', 'stt.provider' not in call('GET', '/api/config/schema')[1]['fields'] and 'voice' not in call('GET', '/api/config/defaults')[1])
control(reset=True)
check('reset clears the stored config', call('GET', '/api/config')[1]['tts']['provider'] == 'edge')

# transcribe
wave = b'RIFF' + struct.pack('<I', 36 + 32000) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, 16000, 32000, 2, 16) + b'data' + struct.pack('<I', 32000) + b'\0' * 32000
body = {'data_url': 'data:audio/wav;base64,' + base64.b64encode(wave).decode(), 'mime_type': 'audio/wav'}
control(transcripts=['first words', 'second words'], transcript='the rest')
said = [call('POST', '/api/audio/transcribe?profile=default', body)[1]['transcript'] for _ in range(3)]
check('transcripts queue then transcript', said == ['first words', 'second words', 'the rest'], str(said))
entry = ledger()['transcribes'][0]
check('transcribe ledger fields', entry['seconds'] == 1.0 and entry['sampleRate'] == 16000 and entry['channels'] == 1 and entry['keys'] == ['data_url', 'mime_type'] and entry['at'] > 0, str(entry))
control(transcribeFailTimes=2, transcribeFail={'status': 400, 'detail': 'No speech provider'})
answers = [call('POST', '/api/audio/transcribe', body) for _ in range(3)]
check('transcribeFailTimes fails n then recovers', answers[0] == (400, {'detail': 'No speech provider'}) and answers[1][0] == 400 and answers[2][0] == 200, str([a[0] for a in answers]))
control(transcribeRaw={'status': 200, 'body': '{"ok": false}'})
check('transcribeRaw', call('POST', '/api/audio/transcribe', body, raw=True) == (200, b'{"ok": false}'))

# never-called routes
check('voice-config is 404', call('GET', '/api/audio/voice-config')[0] == 404)
status = call('GET', '/api/audio/voice-live/status')
check('voice-live status says no key', status[0] == 200 and status[1]['ok'] is True and status[1]['available'] is False and status[1]['mode'] == 'chained', str(status))
check('voice-live session is 503 without a key', call('POST', '/api/audio/voice-live/session', {'sdp': 'v=0'})[0] == 503)
check('voice-live is counted', ledger()['liveStatus'] == 1 and ledger()['liveSessions'] == 1, str(ledger()))
check('forbidden ledger', ledger()['forbidden'] == ['/api/audio/voice-config'], str(ledger()['forbidden']))

# the chat socket: prompt carries `interrupted`, drop and refuse
def rpc(ws, id, method, params):
    ws.send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})
control(reset=True)
chat = Socket('/api/ws?ticket=abc')
check('chat socket upgrades', chat.status == 101)
chat.s.settimeout(5)
state = call('GET', '/__fixture/state')[1] if call('GET', '/__fixture/state')[0] == 200 else {}
rpc(chat, 1, 'voice.toggle', {})
rpc(chat, 2, 'wake.start', {})
time.sleep(0.5)
check('forbidden RPC is recorded', ledger()['forbidden'] == ['voice.toggle', 'wake.start'], str(ledger()['forbidden']))
control(dropSocket=True)
chat.s.settimeout(3)
try:
    gone = False
    while True:
        if chat.s.recv(4096) == b'': gone = True; break
except (socket.timeout, OSError) as error:
    gone = not isinstance(error, socket.timeout)
check('dropSocket closes the chat socket', gone and ledger()['socketDrops'] == 1)
chat.close()
control(refuseSocketFor=1.5)
check('refuseSocketFor refuses', Socket('/api/ws?ticket=abc').status == 503)
time.sleep(1.7)
again = Socket('/api/ws?ticket=abc')
check('sockets are let in again', again.status == 101); again.close()
control(reset=True)
print('all checks passed')
