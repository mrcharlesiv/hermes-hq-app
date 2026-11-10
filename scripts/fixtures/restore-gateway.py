#!/usr/bin/env python3
"""[restore] The pages fixture (scripts/pages-fixture-gateway.py: five bots, listed chats, scheduled runs) plus what the
"reopen the last chat on launch" checks need. Loaded by path, nothing there is edited. Loopback only; invented data.

  GET  /api/config                  the pages fixture's answer, with display.resume_last_session when one is set
Controls (no auth):
  POST /__restore/config  {resume: true|false|null}   null = the key is absent (counts as on)
  POST /__restore/delete  {session_id}                the chat is deleted (gone from every list and read)
  POST /__restore/remove-bot {profile}                the bot is gone from the roster
  POST /__restore/reset                               resume absent, the pages fixture re-seeded

  python3 scripts/fixtures/restore-gateway.py --port 9800 --credentials <dir>/restore.json --files <dir>/files
"""
import importlib.util, json, pathlib, threading
from urllib.parse import urlparse

_spec = importlib.util.spec_from_file_location('hqn_restore_pages', pathlib.Path(__file__).resolve().parent.parent / 'pages-fixture-gateway.py')
pages = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pages)
LOCK = threading.Lock()
RESUME = {'value': None}
SEED_BOTS = list(pages.BOTS)

_pages_handler = pages.fx.handler


def handler(gateway):
    parent = _pages_handler(gateway)

    class Handler(parent):
        def restore_body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try: return json.loads(raw or b'{}')
            except ValueError: return {}

        def do_GET(self):
            if urlparse(self.path).path == '/api/config':
                answer = {'model': 'hermes-4', 'provider': 'nous', 'stt': {'enabled': False}}
                with LOCK: resume = RESUME['value']
                if resume is not None: answer['display'] = {'resume_last_session': resume}
                return self.reply(200, answer)
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__restore/config':
                value = self.restore_body().get('resume')
                with LOCK: RESUME['value'] = value if isinstance(value, bool) else None
                return self.reply(200, {'ok': True})
            if path == '/__restore/delete':
                sid = self.restore_body().get('session_id')
                with pages.lock: gone = pages.SESSIONS.pop(sid, None)
                return self.reply(200 if gone else 404, {'ok': bool(gone)})
            if path == '/__restore/remove-bot':
                profile = self.restore_body().get('profile')
                with pages.lock:
                    before = len(pages.BOTS)
                    pages.BOTS[:] = [bot for bot in pages.BOTS if bot[0] != profile]
                return self.reply(200, {'ok': len(pages.BOTS) < before})
            if path == '/__restore/reset':
                self.restore_body()
                with LOCK: RESUME['value'] = None
                with pages.lock: pages.BOTS[:] = SEED_BOTS
                pages.reseed()
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler


pages.fx.handler = handler

if __name__ == '__main__':
    pages.main()
