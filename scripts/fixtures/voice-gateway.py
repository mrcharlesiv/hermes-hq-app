#!/usr/bin/env python3
"""Voice-memo stand-in gateway for HQ Native (docs/spec/1x-voice.md §8.1). Loopback only, invented state, stdlib only.

Loads the reference performance fixture (build47 streaming, plans and Stop; action-voice; fake-gateway sign-in) and
adds, gated on the session cookie:
  GET    /api/files?profile=                files root <media>/home            (control filesStatus)
  POST   /api/files/upload-stream?profile=  multipart into <root>/.dispatch-attachments/  (uploadStatus, uploadDelay)
  DELETE /api/files?profile=                removes a staging folder
  file.attach                               Hermes-shaped: strict keys (4000), 4001 stale (attachStale:n), 4015, 5028
                                            (attachFail); copies into <media>/home/.hermes[/profiles/ivy]/attachments
                                            with Hermes' -2, -3 … counter
  image.attach                              strict keys (4000), 4001 stale, 4016 not an uploaded picture; ledger
                                            `imageAttaches` (a picture sent beside dictated words, 3x-live-words §3.3)
  prompt.submit                             strict PromptSubmitParams keys (4000); submitRefuse:n refuses the next n
                                            (5000); then build47's plans
  GET    /api/config?profile=               stt.enabled per profile (control stt)
  POST   /api/audio/transcribe?profile=     Hermes' validation; controls transcript, transcribeDelay, transcribeFail,
                                            transcribeEmpty
  GET    /api/fs/download?path=&profile=    the file, with Range (fake-gateway's media())
  POST   /__fixture/voice                   set controls; {"reset":true} clears controls and the ledger
  GET    /__fixture/voice-state             the exactly-once ledger
  POST   /__fixture/memo-history            seeds WAV memos (+ an STT-off memo and a missing-file memo)

Live voice (docs/spec/3x-talk.md §12; ports 9900-9909):
  POST   /api/audio/speak?profile=          one WAV clip (a 440 Hz tone, 0.06 s per character); controls speakDelay,
                                            speakFail, speakMime, speakRaw
  WS     /api/audio/speak-stream?profile=   text in, 24 kHz PCM out in 100 ms binary frames; controls streamMode
                                            (ok, fallback, refuse, drop, silent), streamStartDelay, streamPace,
                                            streamDropAfterMs, streamScript, streamRate, streamChannels; the ledger's
                                            `spoken` is the text cleaned as the real gateway cleans it
  POST   /api/audio/tts-lease, /stt-lease   warm-up leases (leaseFail)
  GET    /api/audio/elevenlabs/voices       two invented voices (elevenVoices: ok, unavailable, fail)
  GET    /api/config, /api/config/schema, /api/config/defaults;  PUT /api/config {config}
                                            the settings fixture's record plus the voice keys (voiceConfig,
                                            schemaVoice, configPutFail)
  transcribe                                also: transcripts (a queue), transcribeFailTimes, transcribeRaw
  socket                                    {"dropSocket": true} closes every /api/ws client once;
                                            {"refuseSocketFor": seconds} refuses new sockets that long
  a question                                {"ask": {"profile": "ivy"}} writes one clarify request (two choices) to the
                                            open sockets; {"cancelAsk": {"profile": "ivy"}} withdraws it
  chats                                     {"resetChats": true} puts every bot's chat back to its one opening message
                                            (no turn running, no plan queued); {"emptyChat": "ivy"} empties one
  GET    /api/audio/voice-live/status       GPT-Live status (liveAvailable, default false); the mode follows voice_chat_mode
  POST   /api/audio/voice-live/session      503 no key (the fixture never makes a WebRTC answer)
  GET    /api/plugins/hermes-hq-push/voice/grok-live/status   Grok Live status (grokAvailable, default false)
  POST   /api/plugins/hermes-hq-push/voice/grok-live/session  503 no_credentials (the fixture never opens xAI)
  never-called routes (voice-config, transcribe-stream; RPC voice.*, wake.*) answer 404 / -32601 and are
  written to the ledger's `forbidden` list, which tests assert stays empty.

  python3 scripts/fixtures/voice-gateway.py --port 9726 --credentials build/fixtures/voice-dev.json \
      --media-dir build/fixtures/voice-media-9726 --ref /Users/me/Projects/hermes-hq-native-ref238
Never contacts a real gateway.
"""
import argparse, base64, binascii, copy, hashlib, importlib.util, json, math, os, pathlib, re, secrets, shutil, socket, struct, sys, threading, time
from email.parser import BytesParser
from email.policy import default as email_policy
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--credentials', required=True)
parser.add_argument('--media-dir', required=True)
parser.add_argument('--ref', default='/Users/me/Projects/hermes-hq-native-ref238')
args = parser.parse_args()
if args.port not in (9726, 9727, 9728) and not 9900 <= args.port <= 9909 and not os.environ.get('HQN_VOICE_ANY_PORT'):
    sys.exit('voice fixture ports are 9726-9728 and 9900-9909 (set HQN_VOICE_ANY_PORT=1 to override)')

REF = pathlib.Path(args.ref)
spec = importlib.util.spec_from_file_location('perf', REF / 'scripts/performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)
base = perf.base            # build47 module; base.voice = action-voice; base.voice.auth = fake-gateway
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import settings_config_data as cfg   # the settings fixture's record, schema and defaults (stdlib only)

MEDIA = pathlib.Path(args.media_dir).resolve()
HOME = MEDIA / 'home'
STAGING = HOME / '.dispatch-attachments'
HOME.mkdir(parents=True, exist_ok=True)
LOCK = threading.RLock()
ATTACH_KEYS = {'session_id', 'profile', 'path', 'data_url', 'name'}
IMAGE_ATTACH_KEYS = {'session_id', 'profile', 'path'}
PROMPT_KEYS = {'session_id', 'profile', 'text', 'display_kind', 'interrupted', 'queued', 'surface', 'voice_context',
               'voice_turn', 'title_preview', 'truncate_before_user_ordinal', 'truncate_before_row_id',
               'truncate_before_message_id', 'confirm_truncate', 'confirm_empty_truncate', 'rebind_survivor_row_ids'}
DEFAULTS = {'filesStatus': None, 'uploadStatus': None, 'uploadDelay': 0, 'attachStale': 0, 'attachFail': False,
            'stt': {'default': True}, 'transcript': None, 'transcribeDelay': 0, 'transcribeFail': None, 'transcribeEmpty': False,
            'submitRefuse': 0,
            # Live voice (3x-talk §12)
            'transcripts': [], 'transcribeFailTimes': 0, 'transcribeRaw': None,
            'speakDelay': 0, 'speakFail': None, 'speakMime': None, 'speakRaw': None,
            'streamMode': 'ok', 'streamStartDelay': 0, 'streamPace': 1, 'streamDropAfterMs': 300, 'streamScript': None,
            'streamRate': 24000, 'streamChannels': 1,
            'leaseFail': False, 'elevenVoices': 'ok', 'voiceConfig': {}, 'schemaVoice': True, 'configPutFail': None,
            # GPT-Live (3x-gpt-live §3.1): status only; a session is refused as the real gateway does with no key
            'liveAvailable': False,
            # Grok Live (3x-grok-live §3.1): status only; the session is refused with no credentials
            'grokAvailable': False}
CONTROLS = json.loads(json.dumps(DEFAULTS))
def empty_ledger():
    return {'filesReads': 0, 'uploads': [], 'attaches': [], 'imageAttaches': [], 'deletes': [], 'configReads': [], 'transcribes': [], 'prompts': [],
            'speaks': [], 'streams': [], 'leases': {'tts': [], 'stt': []}, 'leaseCalls': [], 'voiceLists': 0,
            'configPuts': [], 'configPutProfiles': [], 'forbidden': [], 'socketDrops': 0, 'liveStatus': 0, 'liveSessions': 0,
            'grokStatus': 0, 'grokSessions': 0}
LEDGER = empty_ledger()
STORED = {'config': {}, 'refuseSocketUntil': 0.0}     # what PUT /api/config changed; when new sockets are let in again

VOICE_DEFAULTS = {
    'stt': {'enabled': True, 'provider': 'local', 'echo_transcripts': False,
            'local': {'model': 'base', 'language': ''},
            'openai': {'model': 'whisper-1'}, 'groq': {'model': 'whisper-large-v3-turbo'},
            'mistral': {'model': 'voxtral-mini-latest'},
            'elevenlabs': {'model_id': 'scribe_v2', 'language_code': '', 'tag_audio_events': False, 'diarize': False}},
    'tts': {'provider': 'edge', 'edge': {'voice': 'en-US-AriaNeural'},
            'openai': {'model': 'gpt-4o-mini-tts', 'voice': 'alloy'},
            'elevenlabs': {'voice_id': '21m00Tcm4TlvDq8ikWAM', 'model_id': 'eleven_multilingual_v2'},
            'xai': {'voice_id': 'eve', 'language': 'en', 'speed': 1.0, 'auto_speech_tags': False,
                    'optimize_streaming_latency': 0, 'sample_rate': 24000, 'bit_rate': 128000},
            'minimax': {'model': 'speech-2.8-hd', 'voice_id': 'English_Graceful_Lady'},
            'mistral': {'model': 'voxtral-mini-tts-2603', 'voice_id': 'c69964a6-ab8b-4f8a-9465-ec0925096ec8'},
            'gemini': {'model': 'gemini-2.5-flash-preview-tts', 'voice': 'Kore'},
            'neutts': {'model': 'neuphonic/neutts-air-q4-gguf', 'device': 'cpu'},
            'kittentts': {'model': 'KittenML/kitten-tts-nano-0.8-int8', 'voice': 'Jasper'},
            'piper': {'voice': 'en_US-lessac-medium'}},
    'voice': {'max_recording_seconds': 120, 'auto_tts': False, 'silence_duration': 3.0, 'barge_in': True,
              'barge_in_threshold_multiplier': 3, 'stop_phrases': ['stop'], 'thinking_sound': True,
              # Keys the phone must never show (row L546): a test proves they stay hidden.
              'voice_chat_mode': 'chained', 'client_direct': False, 'gpt_live': {'voice': 'alloy', 'instructions': ''},
              'wake_word': {'enabled': False, 'phrase': 'hey hermes'}},
}
def _field(kind, category, description=None, options=None):
    row = {'type': kind, 'category': category}
    if description: row['description'] = description
    if options is not None: row['options'] = options
    return row
VOICE_SCHEMA = {
    'stt.enabled': _field('boolean', 'stt', 'Enable local or provider-backed speech transcription.'),
    'stt.provider': _field('select', 'stt', None, ['local', 'groq', 'openai', 'mistral', 'xai', 'elevenlabs']),
    'stt.echo_transcripts': _field('boolean', 'stt', 'Post the transcript of each voice message back to the chat.'),
    'stt.local.model': _field('select', 'stt', None, ['tiny', 'base', 'small', 'medium', 'large-v3']),
    'stt.local.language': _field('string', 'stt'),
    'stt.openai.model': _field('select', 'stt', None, ['whisper-1', 'gpt-4o-mini-transcribe', 'gpt-4o-transcribe', 'gpt-transcribe']),
    'stt.groq.model': _field('string', 'stt'),
    'stt.mistral.model': _field('select', 'stt', None, ['voxtral-mini-latest', 'voxtral-mini-2602']),
    'stt.elevenlabs.model_id': _field('select', 'stt', None, ['scribe_v2', 'scribe_v1']),
    'stt.elevenlabs.language_code': _field('string', 'stt', 'Optional ISO-639-3 language code. Blank lets ElevenLabs auto-detect.'),
    'stt.elevenlabs.tag_audio_events': _field('boolean', 'stt'),
    'stt.elevenlabs.diarize': _field('boolean', 'stt'),
    'tts.provider': _field('select', 'tts', None, ['edge', 'elevenlabs', 'openai', 'xai', 'minimax', 'mistral', 'gemini', 'neutts', 'kittentts', 'piper']),
    'tts.edge.voice': _field('string', 'tts'),
    'tts.openai.model': _field('select', 'tts', None, ['gpt-4o-mini-tts', 'tts-1', 'tts-1-hd']),
    'tts.openai.voice': _field('select', 'tts', None, ['alloy', 'ash', 'coral', 'echo', 'fable', 'nova', 'onyx', 'sage', 'shimmer']),
    'tts.elevenlabs.voice_id': _field('string', 'tts'),
    'tts.elevenlabs.model_id': _field('string', 'tts'),
    'tts.xai.voice_id': _field('string', 'tts'),
    'tts.xai.language': _field('string', 'tts'),
    'tts.xai.speed': _field('number', 'tts'),
    'tts.xai.auto_speech_tags': _field('boolean', 'tts'),
    'tts.xai.optimize_streaming_latency': _field('number', 'tts'),
    'tts.xai.sample_rate': _field('number', 'tts'),
    'tts.xai.bit_rate': _field('number', 'tts'),
    'tts.minimax.model': _field('string', 'tts'), 'tts.minimax.voice_id': _field('string', 'tts'),
    'tts.mistral.model': _field('string', 'tts'), 'tts.mistral.voice_id': _field('string', 'tts'),
    'tts.gemini.model': _field('string', 'tts'), 'tts.gemini.voice': _field('string', 'tts'),
    'tts.neutts.model': _field('string', 'tts'), 'tts.neutts.device': _field('string', 'tts', 'Local inference device for NeuTTS.'),
    'tts.kittentts.model': _field('string', 'tts'), 'tts.kittentts.voice': _field('string', 'tts'),
    'tts.piper.voice': _field('string', 'tts'),
    'voice.max_recording_seconds': _field('number', 'voice', 'Maximum voice recording length in seconds.'),
    'voice.auto_tts': _field('boolean', 'voice', 'Speak replies to voice messages on messaging apps.'),
    'voice.silence_duration': _field('number', 'voice'),
    'voice.barge_in': _field('boolean', 'voice'),
    'voice.barge_in_threshold_multiplier': _field('number', 'voice'),
    'voice.stop_phrases': _field('list', 'voice'),
    'voice.thinking_sound': _field('boolean', 'voice'),
    'voice.voice_chat_mode': _field('select', 'voice', None, ['chained', 'gpt_live']),
    'voice.client_direct': _field('boolean', 'voice'),
    'voice.gpt_live.voice': _field('string', 'voice'),
    'voice.gpt_live.instructions': _field('string', 'voice'),
    'voice.wake_word.enabled': _field('boolean', 'voice'),
    'voice.wake_word.phrase': _field('string', 'voice'),
}
FORBIDDEN_PATHS = ('/api/audio/voice-config', '/api/audio/transcribe-stream')
FORBIDDEN_RPC = ('voice.toggle', 'voice.record', 'voice.tts')


def config_defaults():
    record = cfg.defaults()
    with LOCK: voice = CONTROLS['schemaVoice']
    if voice: cfg.deep_merge(record, copy.deepcopy(VOICE_DEFAULTS))
    return record


def config_record(profile):
    """Defaults, then the per-profile `stt` control, the `voiceConfig` control, and what PUT /api/config stored."""
    record = config_defaults()
    with LOCK:
        if CONTROLS['schemaVoice']:
            stt = CONTROLS['stt']
            record.setdefault('stt', {})['enabled'] = bool(stt.get(profile, stt.get('default', True)))
            if isinstance(CONTROLS['voiceConfig'], dict): cfg.deep_merge(record, CONTROLS['voiceConfig'])
        else:
            stt = CONTROLS['stt']
            if not stt.get(profile, stt.get('default', True)): record['stt'] = {'enabled': False}
        cfg.deep_merge(record, STORED['config'])
    return record


def config_schema():
    value = cfg.schema()
    with LOCK: voice = CONTROLS['schemaVoice']
    if voice:
        value['fields'].update(copy.deepcopy(VOICE_SCHEMA))
        value['category_order'] = value['category_order'] + ['stt', 'tts', 'voice']
    return value


def tone(seconds, rate=24000, channels=1, hz=440.0, start=0):
    """Little-endian int16 PCM of a quiet tone; `start` is the sample index it continues from."""
    count = max(0, int(seconds * rate))
    out = bytearray()
    for index in range(start, start + count):
        value = int(7000 * math.sin(2 * math.pi * hz * index / rate))
        out += struct.pack('<h', value) * channels
    return bytes(out)


def wav_bytes(pcm, rate=24000, channels=1):
    header = b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, channels, rate, rate * channels * 2, channels * 2, 16)
    return header + b'data' + struct.pack('<I', len(pcm)) + pcm


def speech_clean(text):
    """What the real gateway's voice is given for written text (a small stand-in for `_strip_markdown_for_tts`, which
    the real speak-stream runs on each sentence it cuts): no code blocks, links as their words, no addresses, no
    markup characters."""
    text = re.sub(r'```[\s\S]*?(?:```|$)', ' ', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'\1', text)
    text = re.sub(r'`([^`]+)`', r'\1', text)
    text = re.sub(r'\bhttps?://\S+', '', text)
    text = re.sub(r'[*_~>#`]', '', text)
    return re.sub(r'\s+', ' ', text).strip()


def speech_seconds(text):
    return min(20.0, max(0.4, 0.06 * len(text)))


class SpeakSocket:
    """A server websocket for /api/audio/speak-stream: text and binary frames out, masked text frames in."""
    def __init__(self, connection):
        self.connection = connection
        self.lock = threading.Lock()
        self.open = True

    def frame(self, opcode, body):
        n = len(body)
        header = bytes([0x80 | opcode]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536 else bytes([127]) + struct.pack('>Q', n))
        with self.lock:
            self.connection.sendall(header + body)

    def send_json(self, value): self.frame(1, json.dumps(value).encode())
    def send_binary(self, data): self.frame(2, data)

    def close(self, code=1000):
        if not self.open: return
        self.open = False
        try: self.frame(8, struct.pack('>H', code))
        except OSError: pass

    def abort(self):
        self.open = False
        try: self.connection.shutdown(socket.SHUT_RDWR)
        except OSError: pass

    def read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.connection.recv(n - len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data

    def receive(self):
        """The next text message, or None once the other side closed."""
        fragments = bytearray()
        while True:
            first, second = self.read(2)
            opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126: n = struct.unpack('>H', self.read(2))[0]
            elif n == 127: n = struct.unpack('>Q', self.read(8))[0]
            mask = self.read(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self.read(n)))
            if opcode == 8:
                self.close()
                return None
            if opcode == 9:
                with self.lock: self.connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode in (0, 1, 2):
                fragments.extend(payload)
                if final: return fragments.decode('utf-8', 'replace')


def speak_stream(handler, profile):
    """One /api/audio/speak-stream socket (3x-talk §3.3, §12.1, §12.3)."""
    key = handler.headers['Sec-WebSocket-Key']
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    handler.connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                                'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    handler.close_connection = True
    ws = SpeakSocket(handler.connection)
    with LOCK:
        mode, start_delay, pace = CONTROLS['streamMode'], float(CONTROLS['streamStartDelay'] or 0), float(CONTROLS['streamPace'])
        drop_after, script = float(CONTROLS['streamDropAfterMs'] or 0), CONTROLS['streamScript']
        rate, channels = int(CONTROLS['streamRate']), int(CONTROLS['streamChannels'] or 1)
        CONTROLS['streamScript'] = None                     # a script is for the next stream only
        entry = {'profile': profile, 'texts': [], 'spoken': '', 'done': False, 'stopped': False, 'bytes': 0, 'closedBy': None, 'mode': mode, 'at': time.time()}
        LEDGER['streams'].append(entry)
    if mode == 'refuse':
        entry['closedBy'] = 'server 4401'
        ws.close(4401)
        return
    pending, wake, state = [], threading.Condition(), {'done': False, 'stop': False, 'gone': False}

    def read():
        try:
            while True:
                text = ws.receive()
                if text is None: break
                try: message = json.loads(text)
                except ValueError: continue
                with wake:
                    if isinstance(message.get('text'), str):
                        entry['texts'].append(message['text'])
                        entry['spoken'] = speech_clean(''.join(entry['texts']))
                        pending.append(message['text'])
                    if message.get('done'): entry['done'] = state['done'] = True
                    if message.get('stop'): entry['stopped'] = state['stop'] = True
                    wake.notify_all()
                if state['stop']: break
        except (ConnectionError, OSError):
            pass
        with wake:
            state['gone'] = True
            if entry['closedBy'] is None: entry['closedBy'] = 'client'
            wake.notify_all()
    threading.Thread(target=read, daemon=True).start()

    def halted(): return state['stop'] or state['gone'] or not ws.open

    def send_audio(pcm):
        """100 ms frames, paced. False when the stream should end here."""
        step = max(2 * channels, int((rate or 24000) * 0.1) * 2 * channels)
        for offset in range(0, len(pcm), step):
            if halted(): return False
            if mode == 'drop' and entry['bytes'] / (2 * channels * (rate or 24000)) * 1000 >= drop_after:
                entry['closedBy'] = 'server abort'
                ws.abort()
                return False
            chunk = pcm[offset:offset + step]
            ws.send_binary(chunk)
            entry['bytes'] += len(chunk)
            if pace > 0: time.sleep(0.1 * pace)
        return True

    try:
        with wake:
            while not pending and not halted() and not state['done']: wake.wait(0.25)
        if halted():
            ws.close()
            return
        if mode == 'silent':
            with wake:
                while not halted(): wake.wait(0.25)
            ws.close()
            return
        if mode == 'fallback':
            ws.send_json({'type': 'fallback'})
            entry['closedBy'] = entry['closedBy'] or 'server fallback'
            time.sleep(0.2)
            ws.close()
            return
        if start_delay: time.sleep(start_delay)
        if script is not None:
            for step in script:
                if halted(): break
                if 'json' in step: ws.send_json(step['json'])
                elif 'toneMs' in step and 'frameBytes' in step:
                    # Frames of any length, as a provider's HTTP chunks come: a sample may be split across two frames.
                    pcm, size = tone(step['toneMs'] / 1000.0, rate or 24000, channels), max(1, int(step['frameBytes']))
                    for offset in range(0, len(pcm), size):
                        if halted(): break
                        ws.send_binary(pcm[offset:offset + size]); entry['bytes'] += len(pcm[offset:offset + size])
                elif 'toneMs' in step: send_audio(tone(step['toneMs'] / 1000.0, rate or 24000, channels))
                elif 'bytes' in step: ws.send_binary(b'\x01' * int(step['bytes'])); entry['bytes'] += int(step['bytes'])
                elif 'big' in step: ws.send_binary(b'\0' * int(step['big'])); entry['bytes'] += int(step['big'])
                elif 'wait' in step:
                    # A quiet socket (a tool is running): ends early only when the client goes.
                    until = time.time() + float(step['wait'])
                    with wake:
                        while not halted() and time.time() < until: wake.wait(min(0.25, max(0.01, until - time.time())))
                elif 'close' in step:
                    entry['closedBy'] = f"server {int(step['close'])}"
                    ws.close(int(step['close']))
                    return
                elif step.get('abort'):
                    entry['closedBy'] = 'server abort'
                    ws.abort()
                    return
            with wake:
                while not halted(): wake.wait(0.25)
            ws.close()
            return
        ws.send_json({'type': 'start', 'sample_rate': rate, 'channels': channels})
        sample = 0
        while True:
            with wake:
                while not pending and not halted() and not state['done']: wake.wait(0.25)
                text = pending.pop(0) if pending else None
            if halted(): break
            if text is None:
                if state['done']:
                    ws.send_json({'type': 'end'})
                    entry['closedBy'] = entry['closedBy'] or 'server end'
                    break
                continue
            seconds = min(20.0, 0.06 * len(text))
            pcm = tone(seconds, rate or 24000, channels, start=sample)
            sample += int(seconds * (rate or 24000))
            if not send_audio(pcm): break
        deadline = time.time() + 5
        with wake:
            while not state['gone'] and ws.open and time.time() < deadline: wake.wait(0.25)
        ws.close()
    except (ConnectionError, OSError):
        if entry['closedBy'] is None: entry['closedBy'] = 'client'


def attachments_dir(profile):
    return HOME / '.hermes' / 'attachments' if profile in (None, '', 'default') else HOME / '.hermes' / 'profiles' / profile / 'attachments'


def runtime_profile(session_id):
    for p, stored in base.voice.SIDS.items():
        if session_id in (stored, hashlib.sha256(stored.encode()).hexdigest()[:8]):
            return p
    return None


# ── Codes other than −32001: raise ValueError("<code>|<text>") and the socket answer carries that code ───────────
_original_send = base.Client.send
def coded_send(self, value):
    error = value.get('error') if isinstance(value, dict) else None
    if isinstance(error, dict) and isinstance(error.get('message'), str):
        match = re.match(r'^(-?\d+)\|(.*)$', error['message'], re.S)
        if match:
            value = {**value, 'error': {**error, 'code': int(match.group(1)), 'message': match.group(2)}}
    return _original_send(self, value)
base.Client.send = coded_send

_original_prompt = base.Client.prompt
def strict_prompt(self, frame):
    params = frame.get('params') or {}
    extra = sorted(set(params) - PROMPT_KEYS)
    with LOCK:
        # Control submitRefuse:n refuses the next n well-formed submits (a provider out of credits, say).
        refuse = not extra and CONTROLS['submitRefuse'] > 0
        if refuse: CONTROLS['submitRefuse'] -= 1
        LEDGER['prompts'].append({'profile': params.get('profile'), 'text': params.get('text'), 'queued': params.get('queued'),
                                  'interrupted': params.get('interrupted'),
                                  'keys': sorted(params), 'refused': bool(extra) or refuse, 'at': time.time()})
    if extra or refuse:
        error = {'code': 4000, 'message': f'Invalid params: unexpected {extra}'} if extra else \
            {'code': 5000, 'message': 'Synthetic refusal: the model provider is out of credits.'}
        try: self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': error})
        except OSError: pass
        return
    return _original_prompt(self, frame)
base.Client.prompt = strict_prompt

_original_rpc = base.rpc
def voice_rpc(method, params):
    if method in FORBIDDEN_RPC or method.startswith('wake.'):
        with LOCK: LEDGER['forbidden'].append(method)
        raise ValueError('-32601|Method not found')
    if method == 'image.attach':
        return image_attach(params)
    if method != 'file.attach':
        return _original_rpc(method, params)
    entry = {k: v for k, v in params.items() if k != 'data_url'}
    if 'data_url' in params: entry['dataUrlBytes'] = len(params['data_url'])
    with LOCK:
        LEDGER['attaches'].append(entry)
        extra = sorted(set(params) - ATTACH_KEYS)
        if extra:
            entry['result'] = 4000
            raise ValueError(f'4000|Invalid params: unexpected {extra}')
        if CONTROLS['attachStale'] > 0:
            CONTROLS['attachStale'] -= 1
            entry['result'] = 4001
            raise ValueError('4001|session not found')
    profile = runtime_profile(params.get('session_id'))
    if profile is None:
        entry['result'] = 4001
        raise ValueError('4001|session not found')
    raw, data_url, name = (str(params.get(k, '') or '').strip() for k in ('path', 'data_url', 'name'))
    if not raw and not data_url:
        entry['result'] = 4015
        raise ValueError('4015|path or data_url required')
    if CONTROLS['attachFail']:
        entry['result'] = 5028
        raise ValueError('5028|Synthetic staging failure')
    source = pathlib.Path(raw).resolve()
    if not raw or not source.is_file() or not str(source).startswith(str(MEDIA) + os.sep):
        entry['result'] = 5028
        raise ValueError('5028|file not found on gateway and no data_url provided')
    root = attachments_dir(profile)
    root.mkdir(parents=True, exist_ok=True)
    filename = re.sub(r'[\x00-\x1f]+', '_', source.name).strip().strip('.') or 'attachment'
    stem, suffix = pathlib.Path(filename).stem or 'attachment', pathlib.Path(filename).suffix
    target, counter = root / filename, 2
    with LOCK:
        while target.exists():
            target = root / f'{stem}-{counter}{suffix}'
            counter += 1
        shutil.copyfile(source, target)
    ref = os.path.relpath(target, HOME)
    entry['result'] = 'ok'
    entry['stored'] = str(target)
    return {'attached': True, 'name': target.name, 'path': str(target), 'ref_path': ref, 'ref_text': f'@file:{ref}', 'uploaded': True}
base.rpc = voice_rpc


def image_attach(params):
    """Hermes' image.attach, as far as a send needs it: a picture uploaded to this fixture, attached to a live runtime."""
    entry = dict(params)
    with LOCK:
        LEDGER['imageAttaches'].append(entry)
        extra = sorted(set(params) - IMAGE_ATTACH_KEYS)
    if extra:
        entry['result'] = 4000
        raise ValueError(f'4000|Invalid params: unexpected {extra}')
    if runtime_profile(params.get('session_id')) is None:
        entry['result'] = 4001
        raise ValueError('4001|session not found')
    raw = str(params.get('path', '') or '').strip()
    source = pathlib.Path(raw).resolve() if raw else None
    if source is None or not source.is_file() or not str(source).startswith(str(MEDIA) + os.sep) \
            or source.suffix.lower() not in ('.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic'):
        entry['result'] = 4016
        raise ValueError(f'4016|image not found: {raw}')
    entry['result'] = 'ok'
    return {'attached': True, 'path': raw, 'name': source.name, 'remainder': '', 'text': f'[User attached image: {source.name}]'}


def wav_seconds(data):
    if data[:4] == b'RIFF' and data[8:12] == b'WAVE':
        offset, rate, channels, bits, size = 12, 16000, 1, 16, None
        while offset + 8 <= len(data):
            chunk, length = data[offset:offset + 4], struct.unpack('<I', data[offset + 4:offset + 8])[0]
            if chunk == b'fmt ':
                channels, rate = struct.unpack('<HI', data[offset + 10:offset + 16])
                bits = struct.unpack('<H', data[offset + 22:offset + 24])[0]
            if chunk == b'data':
                size = length
                break
            offset += 8 + length + (length & 1)
        if size is not None and rate and channels and bits:
            return size / (rate * channels * bits / 8)
    at = data.find(b'mvhd')
    if at >= 4:
        version = data[at + 4]
        scale = struct.unpack('>I', data[at + (24 if version == 1 else 16):at + (28 if version == 1 else 20)])[0]
        length = struct.unpack('>Q', data[at + 28:at + 36])[0] if version == 1 else struct.unpack('>I', data[at + 20:at + 24])[0]
        if scale: return length / scale
    return None


def fixture_wave(seconds):
    """The app's fixture recorder formula (W:ios/App/App/HermesVoice.swift:553-572), levels from its 15 Hz voice."""
    rate = 16000
    count = max(1, int(seconds * rate))
    levels = [max(0.04, 0.42 + 0.3 * math.sin(t / 10 * 4.1) * math.sin(t / 10 * 0.9 + 1) + 0.12 * math.sin(t / 10 * 17))
              for t in range(int(seconds * 10) + 1)]
    pcm = bytearray()
    for index in range(count):
        t = index / rate
        level = levels[min(len(levels) - 1, int(t * 10))]
        value = int(max(-32767, min(32767, level * 9000 * math.sin(2 * math.pi * 220 * t) * (0.6 + 0.4 * math.sin(2 * math.pi * 3 * t)))))
        pcm += struct.pack('<h', value)
    header = b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16)
    return header + b'data' + struct.pack('<I', len(pcm)) + bytes(pcm)


def handler(gateway):
    parent = perf.base.handler(gateway)

    class Handler(parent):
        def body(self):
            return self.rfile.read(int(self.headers.get('Content-Length') or 0))

        def query(self):
            return {k: v[0] for k, v in parse_qs(urlparse(self.path).query).items()}

        def gated(self):
            if self.session(): return True
            self.reply(401, {'detail': 'Unauthorized'})
            return False

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/voice-state':
                with LOCK: return self.reply(200, {**LEDGER, 'controls': CONTROLS})
            if path == '/api/files':
                if not self.gated(): return
                with LOCK:
                    LEDGER['filesReads'] += 1
                    status = CONTROLS['filesStatus']
                if status: return self.reply(int(status), {'detail': 'Synthetic files failure'})
                return self.reply(200, {'path': str(HOME), 'parent': None, 'entries': []})
            if path.startswith(FORBIDDEN_PATHS):
                with LOCK: LEDGER['forbidden'].append(path)
                return self.reply(404, {'detail': 'Not found'})
            if path == '/api/audio/voice-live/status':
                if not self.gated(): return
                with LOCK:
                    LEDGER['liveStatus'] += 1
                    available = bool(CONTROLS['liveAvailable'])
                mode = str((config_record(self.query().get("profile") or "default").get("voice") or {}).get('voice_chat_mode') or 'chained')
                live = mode.replace('_', '-').lower() in ('gpt-live', 'gptlive', 'live')
                record = config_record(self.query().get("profile") or "default")
                answer = {'ok': True, 'mode': 'gpt-live' if live else 'chained', 'available': available,
                          'model': 'gpt-live-1', 'voice': ((record.get('voice') or {}).get('gpt_live') or {}).get('voice') or 'marin'}
                if not available: answer['reason'] = 'missing_key'
                return self.reply(200, answer)
            if path == '/api/plugins/hermes-hq-push/voice/grok-live/status':
                if not self.gated(): return
                with LOCK:
                    LEDGER['grokStatus'] += 1
                    available = bool(CONTROLS['grokAvailable'])
                record = config_record(self.query().get("profile") or "default")
                answer = {'ok': True, 'available': available, 'auth': 'subscription' if available else None,
                          'model': 'fixture-voice', 'voice': ((record.get('voice') or {}).get('grok_live') or {}).get('voice') or 'eve'}
                if not available: answer['reason'] = 'no_credentials'
                return self.reply(200, answer)
            if path == '/api/ws' and (self.headers.get('Upgrade') or '').lower() == 'websocket':
                with LOCK: refused = time.time() < STORED['refuseSocketUntil']
                if refused: return self.reply(503, {'detail': 'Synthetic socket refusal'})
                return super().do_GET()
            if path == '/api/audio/speak-stream':
                if (self.headers.get('Upgrade') or '').lower() != 'websocket': return self.reply(400, {'detail': 'WebSocket required'})
                if not self.session() and 'ticket=' not in self.path: return self.reply(401, {'detail': 'Unauthorized'})
                return speak_stream(self, self.query().get('profile') or 'default')
            if path == '/api/audio/elevenlabs/voices':
                if not self.gated(): return
                with LOCK:
                    LEDGER['voiceLists'] += 1
                    mode = CONTROLS['elevenVoices']
                if mode == 'fail': return self.reply(500, {'detail': 'Synthetic voice list failure'})
                if mode == 'unavailable': return self.reply(200, {'available': False, 'voices': []})
                return self.reply(200, {'available': True, 'voices': [
                    {'label': 'Rachel', 'name': 'Rachel', 'voice_id': '21m00Tcm4TlvDq8ikWAM'},
                    {'label': 'Adam', 'name': 'Adam', 'voice_id': 'pNInz6obpgDQGcFmaJgB'}]})
            if path == '/api/config':
                if not self.gated(): return
                profile = self.query().get('profile') or 'default'
                with LOCK: LEDGER['configReads'].append(profile)
                return self.reply(200, config_record(profile))
            if path == '/api/config/schema':
                if not self.gated(): return
                return self.reply(200, config_schema())
            if path == '/api/config/defaults':
                if not self.gated(): return
                return self.reply(200, config_defaults())
            if path == '/api/fs/download':
                if not self.gated(): return
                return self.media()
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/voice':
                payload = json.loads(self.body() or b'{}')
                with LOCK:
                    if payload.pop('reset', False):
                        CONTROLS.clear(); CONTROLS.update(json.loads(json.dumps(DEFAULTS)))
                        LEDGER.clear(); LEDGER.update(empty_ledger())
                        STORED['config'] = {}; STORED['refuseSocketUntil'] = 0.0
                    if 'refuseSocketFor' in payload:
                        STORED['refuseSocketUntil'] = time.time() + float(payload.pop('refuseSocketFor') or 0)
                    drop = payload.pop('dropSocket', False)
                    ask, unask = payload.pop('ask', None), payload.pop('cancelAsk', None)
                    fresh, emptied = payload.pop('resetChats', False), payload.pop('emptyChat', None)
                    for key, value in payload.items():
                        if key in DEFAULTS: CONTROLS[key] = value
                    clients = list(base.CLIENTS) if drop else []
                    listeners = list(base.CLIENTS) if (ask or unask) and not drop else []
                    if drop: LEDGER['socketDrops'] += 1
                for client in clients:
                    try: client.connection.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
                # `resetChats`: every bot's chat back to its one opening message, no turn running, no plan queued (a
                # UI test starts from the same transcript whatever ran before it). `emptyChat: <profile>`: that bot's
                # chat has no messages at all (the empty-chat intro, 3x-talk §5.6).
                if fresh or emptied:
                    with base.LOCK:
                        if fresh:
                            del base.PLANS[:]
                            for name in list(base.MESSAGES):
                                base.CANCEL[name].set(); base.RUNNING[name] = False
                                base.MESSAGES[name] = [{'role': 'assistant', 'content': 'Build 47 synthetic acceptance chat.',
                                                        'row_id': 1, 'timestamp': 1790852400}]
                        if emptied in base.MESSAGES:
                            base.CANCEL[emptied].set(); base.RUNNING[emptied] = False
                            base.MESSAGES[emptied] = []
                # A question for the chat (3x-talk §6.1, E20): one clarify request written to every open socket, as
                # Hermes writes a server request to a session's clients. The answer frame has no method, so the
                # socket loop of the reference fixture drops it; `cancelAsk` withdraws the question.
                if ask:
                    profile = ask.get('profile', 'ivy') if isinstance(ask, dict) else 'ivy'
                    STORED['ask'] = STORED.get('ask', 0) + 1
                    frame = {'jsonrpc': '2.0', 'id': f"srq-talk-{STORED['ask']}", 'method': 'clarify', 'params': {
                        'session_id': base.voice.resumed(profile)['session_id'],
                        'questions': [{'qid': 'q0', 'question': 'Which city should I book?',
                                       'choices': ['Lisbon (Recommended)', 'Porto'], 'multi_select': False}]}}
                    for client in listeners:
                        try: client.send(frame)
                        except OSError: pass
                if unask:
                    profile = unask.get('profile', 'ivy') if isinstance(unask, dict) else 'ivy'
                    base.emit(profile, 'request.cancel', {'id': f"srq-talk-{STORED.get('ask', 0)}", 'method': 'clarify', 'reason': 'answered'})
                with LOCK: return self.reply(200, {'ok': True, 'controls': CONTROLS})
            if path.startswith(FORBIDDEN_PATHS):
                with LOCK: LEDGER['forbidden'].append(path)
                return self.reply(404, {'detail': 'Not found'})
            if path == '/api/audio/voice-live/session':
                if not self.gated(): return
                with LOCK: LEDGER['liveSessions'] += 1
                return self.reply(503, {'detail': 'GPT-Live needs an OpenAI API key on the gateway.'})
            if path == '/api/plugins/hermes-hq-push/voice/grok-live/session':
                if not self.gated(): return
                with LOCK: LEDGER['grokSessions'] += 1
                return self.reply(503, {'detail': 'no_credentials'})
            if path == '/api/audio/speak':
                if not self.gated(): return
                return self.speak(self.body())
            if path in ('/api/audio/tts-lease', '/api/audio/stt-lease'):
                if not self.gated(): return
                kind = 'tts' if path.endswith('tts-lease') else 'stt'
                try: payload = json.loads(self.body() or b'{}')
                except ValueError: payload = {}
                lease = str(payload.get('lease') or '').strip() if isinstance(payload, dict) else ''
                with LOCK:
                    LEDGER['leaseCalls'].append({'kind': kind, 'lease': lease, 'active': payload.get('active') if isinstance(payload, dict) else None,
                                                 'profile': self.query().get('profile') or 'default',
                                                 'keys': sorted(payload) if isinstance(payload, dict) else [], 'at': time.time()})
                    if CONTROLS['leaseFail']: return self.reply(500, {'detail': 'Synthetic lease failure'})
                    if not lease: return self.reply(400, {'detail': 'lease is required'})
                    held = LEDGER['leases'][kind]
                    if payload.get('active'):
                        if lease not in held: held.append(lease)
                    elif lease in held: held.remove(lease)
                    return self.reply(200, {'ok': True, 'lease': lease, 'active': bool(payload.get('active')), 'leases': list(held)})
            if path == '/__fixture/memo-history':
                return self.memo_history(json.loads(self.body() or b'{}'))
            if path == '/api/files/upload-stream':
                if not self.gated(): return
                raw = self.body()
                with LOCK: delay, status = CONTROLS['uploadDelay'], CONTROLS['uploadStatus']
                if delay: time.sleep(float(delay))
                if status: return self.reply(int(status), {'detail': 'Synthetic upload failure'})
                message = BytesParser(policy=email_policy).parsebytes(
                    ('Content-Type: ' + self.headers.get('Content-Type', '') + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + raw)
                fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True) for part in message.iter_parts()}
                target = (fields.get('path') or b'').decode()
                data = fields.get('file') or b''
                resolved = pathlib.Path(target).resolve() if target else None
                if not resolved or not str(resolved).startswith(str(STAGING) + os.sep) or not data:
                    return self.reply(400, {'detail': 'Invalid synthetic upload'})
                if resolved.exists() and (fields.get('overwrite') or b'false') != b'true':
                    return self.reply(409, {'detail': 'File exists'})
                resolved.parent.mkdir(parents=True, exist_ok=True)
                resolved.write_bytes(data)
                with LOCK:
                    LEDGER['uploads'].append({'path': str(resolved), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                              'overwrite': (fields.get('overwrite') or b'').decode(), 'boundary': self.headers.get('Content-Type', '')})
                return self.reply(200, {'ok': True, 'path': str(resolved), 'entry': {'name': resolved.name, 'size': len(data)}})
            if path == '/api/audio/transcribe':
                if not self.gated(): return
                return self.transcribe(self.body())
            return super().do_POST()

        def do_PUT(self):
            path = urlparse(self.path).path
            if path != '/api/config':
                parent_put = getattr(super(), 'do_PUT', None)
                return parent_put() if parent_put else self.reply(404, {'detail': 'Not found'})
            if not self.gated(): return
            try: payload = json.loads(self.body() or b'{}')
            except ValueError: return self.reply(400, {'detail': 'Invalid JSON'})
            if not isinstance(payload, dict) or set(payload) != {'config'} or not isinstance(payload['config'], dict):
                return self.reply(400, {'detail': 'Body must be {"config": {…}}'})
            with LOCK:
                fail = CONTROLS['configPutFail']
                LEDGER['configPuts'].append(payload['config'])
                LEDGER['configPutProfiles'].append(self.query().get('profile') or 'default')
                if fail:
                    fail = fail if isinstance(fail, dict) else {}
                    return self.reply(int(fail.get('status', 500)), {'detail': fail.get('detail', 'Synthetic save failure')})
                cfg.deep_merge(STORED['config'], payload['config'])
            return self.reply(200, {'ok': True})

        def speak(self, raw):
            profile = self.query().get('profile') or 'default'
            try: payload = json.loads(raw or b'{}')
            except ValueError: return self.reply(400, {'detail': 'Invalid JSON'})
            text = str(payload.get('text') or '').strip() if isinstance(payload, dict) else ''
            with LOCK:
                LEDGER['speaks'].append({'profile': profile, 'text': text, 'keys': sorted(payload) if isinstance(payload, dict) else [], 'at': time.time()})
                delay, fail, mime, rawAnswer = CONTROLS['speakDelay'], CONTROLS['speakFail'], CONTROLS['speakMime'], CONTROLS['speakRaw']
                if rawAnswer: CONTROLS['speakRaw'] = None
            if delay: time.sleep(float(delay))
            if rawAnswer: return self.raw_reply(rawAnswer)
            if fail:
                fail = fail if isinstance(fail, dict) else {}
                return self.reply(int(fail.get('status', 500)), {'detail': fail.get('detail', 'Speech failed')})
            if not text: return self.reply(400, {'detail': 'Text is required'})
            mime = mime or 'audio/wav'
            clip = wav_bytes(tone(speech_seconds(text)))
            return self.reply(200, {'ok': True, 'data_url': f'data:{mime};base64,' + base64.b64encode(clip).decode(),
                                    'mime_type': mime, 'provider': 'fixture'})

        def raw_reply(self, answer):
            """`{status, body}`: this status and this exact body text (bad-data controls, 3x-talk §12.3)."""
            answer = answer if isinstance(answer, dict) else {}
            body = answer.get('body', '')
            data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
            self.send_response(int(answer.get('status', 200)))
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_DELETE(self):
            path = urlparse(self.path).path
            if path != '/api/files': return super().do_DELETE()
            if not self.gated(): return
            try: requested = json.loads(self.body() or b'{}')
            except ValueError: requested = {}
            folder = pathlib.Path(str(requested.get('path') or '')).resolve()
            with LOCK: LEDGER['deletes'].append({'path': str(folder), 'recursive': requested.get('recursive')})
            if not str(folder).startswith(str(STAGING) + os.sep) or not folder.exists():
                return self.reply(404, {'detail': 'Not found'})
            shutil.rmtree(folder, ignore_errors=True)
            return self.reply(200, {'ok': True})

        def transcribe(self, raw):
            profile = self.query().get('profile') or 'default'
            try: payload = json.loads(raw or b'{}')
            except ValueError: return self.reply(400, {'detail': 'Invalid JSON'})
            data_url = str(payload.get('data_url') or '').strip()
            if not data_url.startswith('data:') or ',' not in data_url: return self.reply(400, {'detail': 'Invalid audio payload'})
            header, encoded = data_url.split(',', 1)
            if ';base64' not in header: return self.reply(400, {'detail': 'Audio payload must be base64 encoded'})
            mime = (payload.get('mime_type') or header[5:].split(';', 1)[0] or 'audio/webm').strip()
            normalized = mime.split(';', 1)[0].lower()
            if not (normalized.startswith('audio/') or normalized == 'video/webm'):
                return self.reply(400, {'detail': 'Payload must be an audio recording'})
            try: audio = base64.b64decode(encoded, validate=True)
            except (binascii.Error, ValueError): return self.reply(400, {'detail': 'Audio payload is not valid base64'})
            if not audio: return self.reply(400, {'detail': 'Audio recording is empty'})
            if len(audio) > 25 * 1024 * 1024: return self.reply(413, {'detail': 'Audio recording is too large'})
            seconds = wav_seconds(audio)
            rate = channels = None
            if audio[:4] == b'RIFF' and audio[8:12] == b'WAVE' and len(audio) >= 28:
                channels, rate = struct.unpack('<HI', audio[22:28])
            with LOCK:
                LEDGER['transcribes'].append({'profile': profile, 'mime': mime, 'bytes': len(audio), 'seconds': seconds,
                                              'sampleRate': rate, 'channels': channels, 'keys': sorted(payload), 'at': time.time()})
                delay, fail, empty, words = CONTROLS['transcribeDelay'], CONTROLS['transcribeFail'], CONTROLS['transcribeEmpty'], CONTROLS['transcript']
                rawAnswer = CONTROLS['transcribeRaw']
                if rawAnswer: CONTROLS['transcribeRaw'] = None
                # transcribeFailTimes:n fails the next n calls (with transcribeFail's status and detail), then clears both.
                failTimes = int(CONTROLS['transcribeFailTimes'] or 0)
                if failTimes > 0 and not rawAnswer:
                    CONTROLS['transcribeFailTimes'] = failTimes - 1
                    fail = fail or {}
                    if failTimes == 1: CONTROLS['transcribeFail'] = None
                failing = not rawAnswer and (failTimes > 0 or bool(fail))
                queued = CONTROLS['transcripts'].pop(0) if not rawAnswer and not failing and not empty and CONTROLS['transcripts'] else None
            if delay: time.sleep(float(delay))
            if rawAnswer: return self.raw_reply(rawAnswer)
            if failing:
                fail = fail if isinstance(fail, dict) else {}
                return self.reply(int(fail.get('status', 500)), {'detail': fail.get('detail', 'Transcription failed')})
            if empty: return self.reply(200, {'ok': True, 'transcript': '', 'provider': 'fixture'})
            text = queued if queued is not None else words if words is not None else f'Synthetic transcript of a {int(round(seconds or 0))} s voice memo.'
            return self.reply(200, {'ok': True, 'transcript': text, 'provider': 'fixture'})

        def memo_history(self, body):
            profile = body.get('profile', 'default')
            if profile not in base.MESSAGES: return self.reply(404, {'detail': 'Unknown synthetic profile'})
            root = attachments_dir(profile)
            root.mkdir(parents=True, exist_ok=True)
            seeded = []
            with base.LOCK:
                if base.RUNNING[profile]: return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                for memo in body.get('memos', []):
                    seconds = float(memo.get('seconds', 4))
                    counter, target = 2, root / 'voice-memo.wav'
                    while target.exists() or str(target) in seeded:
                        target = root / f'voice-memo-{counter}.wav'
                        counter += 1
                    if not memo.get('missing'): target.write_bytes(fixture_wave(seconds))
                    said = '(unavailable: speech-to-text is off on the gateway)' if memo.get('off') else memo.get('transcript', f'Seeded memo of {int(seconds)} seconds.')
                    base.append(profile, 'user', f'MEDIA:"{target}"\n\nVoice memo transcript: {said}')
                    seeded.append(str(target))
                if body.get('reply', 'Got it.'):
                    base.append(profile, 'assistant', body.get('reply', 'Got it.'))
            return self.reply(200, {'ok': True, 'paths': seeded})

    return Handler


def main():
    username, password = 'voice-fixture', secrets.token_urlsafe(24)
    folder = pathlib.Path(args.credentials).resolve().parent
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    descriptor = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{args.port}'}, file)
    gateway = base.voice.auth.Gateway(username, password, True, None, str(MEDIA))
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(gateway))
    print(f'Voice memo synthetic gateway on 127.0.0.1:{args.port} (media {MEDIA})', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
