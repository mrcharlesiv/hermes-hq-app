#!/bin/zsh
# Guards of the live-voice stream (docs/spec/3x-talk.md §3.8, §9.2 "Never shown", row L546). Exits non-zero on a hit.
#   1. The never-called gateway routes and RPC methods appear nowhere in App/ or HermesKit/. GPT-Live's routes are
#      named only in HermesKit/Voice/LiveVoiceWire.swift (docs/spec/3x-gpt-live.md).
#   2. The Voice settings catalog lists no wake-word, stop-word, engine-choice or GPT-Live key.
#   3. The word "Dispatch" is in no string literal of this stream's files (identifiers such as bundle ids are fine).
#   4. No screen of this stream says "Live voice", "wake" or "Hey Hermes" (GPT-Live is built since 2026-10-26).
# Usage: scripts/check-talk-guards.sh        (scripts/e2e-talk.sh runs it first)
cd "$(dirname "$0")/.."
python3 - <<'EOF'
import re, sys, pathlib

root = pathlib.Path('.')
problems = []

def swift(*folders):
    for folder in folders:
        yield from sorted(root.joinpath(folder).rglob('*.swift'))

# 1. Never called.
NEVER = ['/api/audio/voice-config', '/api/audio/voice-live', '/api/audio/transcribe-stream',
         '"voice.toggle"', '"voice.record"', '"voice.tts"', '"wake.']
LIVE_WIRE = root / 'HermesKit/Voice/LiveVoiceWire.swift'
for path in swift('App', 'HermesKit'):
    text = path.read_text(encoding='utf-8')
    for needle in NEVER:
        if needle == '/api/audio/voice-live' and path == LIVE_WIRE: continue
        if needle in text:
            problems.append(f'{path}: calls or names {needle}')

# String literals of a Swift file (single-line ones; a comment's text is not one).
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
def literals(path):
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        code = line.split('//', 1)[0] if not re.search(r'"[^"]*//', line) else line
        for found in LITERAL.finditer(code):
            yield number, found.group(1)

# 2. The catalog's keys.
catalog = root / 'HermesKit/Settings/VoiceSettingsCatalog.swift'
HIDDEN = re.compile(r'wake|stop_word|^voice\.client_direct$|^voice\.voice_chat_mode$|^voice\.gpt_live', re.I)
inside_gate = False
for number, line in enumerate(catalog.read_text(encoding='utf-8').splitlines(), 1):
    if 'static func isHidden' in line: inside_gate = True
    elif inside_gate and line.startswith('    }'): inside_gate = False
    if inside_gate: continue
    code = line.split('//', 1)[0]
    for found in LITERAL.finditer(code):
        value = found.group(1)
        if re.fullmatch(r'(stt|tts|voice)\.[a-z0-9_.]+', value) and HIDDEN.search(value):
            problems.append(f'{catalog}:{number}: lists the hidden key {value}')

# 3 and 4. This stream's files.
MINE = [p for p in swift('App/Chat/Voice', 'App/Settings/Voice', 'HermesKit/Voice')
        if p.name.startswith(('Talk', 'Dictation', 'ReadAloud', 'ChatTalk', 'ChatReadAloud', 'Voice', 'KeepAwake', 'SpeechText'))]
MINE += [root / 'HermesKit/Settings/VoiceSettingsCatalog.swift', root / 'App/Integration/TalkWiring.swift',
         root / 'App/Chat/Voice/ChatVoiceHost.swift']
MINE += [p for p in swift('App/Chat/Attachments') if p.name == 'AudioPreviewSheet.swift']
MINE += list(swift('TalkActivityKit', 'TalkActivityWidget'))   # [talk-background] the Lock Screen's words
IDENTIFIER = re.compile(r'^[A-Za-z0-9_.\-:]+$')
SCREEN_WORDS = re.compile(r'Live voice|\bwake\b|Hey Hermes', re.I)
for path in MINE:
    if not path.exists(): continue
    inside_gate = False
    for number, value in literals(path):
        if re.search(r'dispatch', value, re.I) and not IDENTIFIER.match(value):
            problems.append(f'{path}:{number}: a string says "Dispatch": {value!r}')
        # Words a person could read (a space in it), outside the catalog's own gate and the debug log.
        # TalkStopWord.swift matches what a person SAYS ("hey hermes, stop"); nothing of it is shown.
        if ' ' in value and SCREEN_WORDS.search(value) and path.name not in ('KeepAwake.swift', 'TalkStopWord.swift'):
            if re.search(r'kept awake|keep awake|keeps? the screen awake|stay awake|stays awake', value, re.I): continue
            problems.append(f'{path}:{number}: a string names a hidden feature: {value!r}')

if problems:
    print('\n'.join(problems))
    print(f'talk guards: {len(problems)} problem(s)')
    sys.exit(1)
print(f'talk guards: clean ({len(MINE)} files of this stream, App/ and HermesKit/ for the never-called routes)')
EOF
