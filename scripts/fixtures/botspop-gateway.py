#!/usr/bin/env python3
"""Back-to-Bots smoothness stand-in gateway (build 297, scripts/perf-botspop.sh): the Bots-list fixture
(botslist-gateway.py, itself the settings fixture) with a roster the size of the owner's (twelve bots: six pinned
faces in several themes, a Work section, unassigned rows, one hidden) and one more behaviour:

  A message that starts with "slow:" keeps its bot working: the reply streams a word every 0.4 s for 90 s, so the bot's
  ring travels and its row's preview changes while another chat is open (as a real turn does).

The app's log upload (POST /api/plugins/hermes-hq-push/logs) is also appended, line by line, to $BOTSPOP_LOG_OUT
when it is set: FrameMeter's `frames` records come home that way, one upload per phase the test cuts.

  BOTSPOP_LOG_OUT=build/fixtures/botspop-lines.jsonl \
  python3 scripts/fixtures/botspop-gateway.py --port 10000 --hermes-cookies --credentials build/fixtures/botspop.json
"""
import importlib.util, json, os, pathlib, sys, time
from urllib.parse import urlparse

spec = importlib.util.spec_from_file_location('botslist_gateway', pathlib.Path(__file__).with_name('botslist-gateway.py'))
bl = importlib.util.module_from_spec(spec)
sys.modules['botslist_gateway'] = bl
spec.loader.exec_module(bl)
sg = bl.sg


def shape(color, seed, form='round', look='ovals'):
    return {'v': 6, 'theme': 'shape', 'color': color, 'seed': seed, 'form': form, 'look': look,
            'specs': 'none', 'hat': 'none', 'mouth': 'none', 'blush': False, 'tile': 'none'}


PINNED = {'hermes-bots': {'pinned': True, 'sectionId': 'hermes-hq-pinned', 'sectionName': 'Pinned', 'pinnedFrom': None}}
EXTRA = [
    # name, display, description, pinned, head, preview
    ('writer', 'Writer', 'Drafts posts', True, {'v': 6, 'theme': 'robot', 'seed': 5}, 'The draft is in your folder.'),
    ('ops', 'Ops', 'Watches the servers', True, {'v': 6, 'theme': 'dots', 'seed': 8}, 'All twelve checks are green.'),
    ('chef', 'Chef', 'Plans meals', True, shape('coral', 9, 'hex', 'slits'), 'Tacos on Tuesday, soup on Wednesday.'),
    ('pixel', 'Pixel', 'Makes art', True, {'v': 6, 'theme': 'pixel', 'seed': 21}, 'Three sketches ready.'),
    ('coach', 'Coach', 'Runs workouts', False, shape('lime', 13), 'Rest day today, stretch for ten minutes.'),
    ('money', 'Money', 'Tracks spending', False, {'v': 6, 'theme': 'orb', 'seed': 4}, 'You are under budget this month.'),
]


_seed = sg.seed


def seed():
    state = _seed()
    now = int(time.time())
    profiles = state['profiles']
    profiles['ivy']['ui_meta']['dispatch-head'] = shape('butter', 3)
    profiles['inbox']['ui_meta']['dispatch-head'] = shape('grape', 5, 'round', 'dots')
    for n, (name, display, description, pinned, head, preview) in enumerate(EXTRA):
        meta = {'dispatch-head': head}
        if pinned:
            meta.update({k: dict(v) for k, v in PINNED.items()})
        chat = {'id': f'20260929_120000_ddeeff{n:02d}', 'title': 'Bot Chat', 'started_at': now - 86400,
                'last_active': now - 600 * (n + 2),
                'messages': [{'role': 'user' if i % 2 == 0 else 'assistant',
                              'content': (f'Line {i + 1} of a longer chat about {description.lower()}.' if i < 19 else preview),
                              'timestamp': now - 600 * (n + 2) - (20 - i) * 60} for i in range(20)]}
        profiles[name] = {'display_name': display, 'description': description, 'ui_meta': meta,
                          'revisions': {'hermes-bots': 1, 'dispatch-head': 1}, 'chat': chat, 'avatar': None, 'extra_chats': []}
        state['skills'][name] = sg.default_skills()
        state['mcp'][name] = sg.default_mcp()
    return state


sg.seed = seed
_stream = sg.stream_intro


def stream(name, chat, user_text):
    text = (user_text or '').strip()
    if not text.lower().startswith('slow:'):
        return _stream(name, chat, user_text)
    time.sleep(0.3)
    sg.emit(chat['id'], 'message.start')
    words = []
    end = time.time() + 90
    while time.time() < end:
        time.sleep(0.4)
        word = f'word{len(words) + 1} '
        words.append(word)
        sg.emit(chat['id'], 'message.delta', {'text': word})
    reply = ''.join(words).strip()
    with sg.LOCK:
        chat['messages'].append({'role': 'assistant', 'content': reply, 'timestamp': time.time()})
        chat['last_active'] = time.time()
        row = len(chat['messages'])
    sg.emit(chat['id'], 'message.complete', {'text': reply, 'status': 'complete', 'row_id': row})


sg.stream_intro = stream
_handler = sg.handler


def handler(gateway):
    base = _handler(gateway)

    class Handler(base):
        def do_POST(self):
            out = os.environ.get('BOTSPOP_LOG_OUT')
            if not out or urlparse(self.path).path != '/api/plugins/hermes-hq-push/logs':
                return super().do_POST()
            if not self.authed(urlparse(self.path).path):
                return
            body = self.body()
            lines = body.get('lines') if isinstance(body.get('lines'), list) else []
            with open(out, 'a') as handle:
                handle.write(json.dumps({'k': 'upload', 'reason': body.get('reason'), 'count': len(lines)}) + '\n')
                for line in lines:
                    handle.write(str(line).strip() + '\n')
            return self.reply(200, {'ok': True, 'written': len(lines)})

    return Handler


sg.handler = handler

if __name__ == '__main__':
    sg.main()
