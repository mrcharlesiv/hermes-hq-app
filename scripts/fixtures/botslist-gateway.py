#!/usr/bin/env python3
"""Bots-list stand-in gateway (docs/spec/3x-botslist.md): the settings fixture (same seed, controls and arguments) plus
one behaviour the Bots-list rows need:

  A message that starts with "fail:" ends its turn with an `error` event carrying the rest as its message
  ("fail:401 Unauthorized" → a provider sign-in failure; "fail:429 Too Many Requests" → a passing one), instead of the
  usual reply. A message that starts with "drop:" is never answered and never stored: the connection closes on it (a
  send that may not have arrived). Any other message is answered as the settings fixture answers it.

  python3 scripts/fixtures/botslist-gateway.py --port 10040 --hermes-cookies --credentials build/fixtures/botslist-a.json
"""
import importlib.util, pathlib, socket, sys, time

spec = importlib.util.spec_from_file_location('settings_gateway', pathlib.Path(__file__).with_name('settings-gateway.py'))
sg = importlib.util.module_from_spec(spec)
sys.modules['settings_gateway'] = sg
spec.loader.exec_module(sg)

_reply = sg.stream_intro


def stream(name, chat, user_text):
    text = (user_text or '').strip()
    if not text.lower().startswith('fail:'):
        return _reply(name, chat, user_text)
    time.sleep(0.5)
    sg.emit(chat['id'], 'message.start')
    time.sleep(0.15)
    sg.emit(chat['id'], 'error', {'message': text[5:].strip()})


sg.stream_intro = stream

_answer = sg.Client.answer


def answer(self, frame):
    text = str((frame.get('params') or {}).get('text', '')).strip().lower()
    if frame.get('method') == 'prompt.submit' and text.startswith('drop:'):
        for close in (lambda: self.connection.shutdown(socket.SHUT_RDWR), self.connection.close):
            try:
                close()
            except OSError:
                pass
        return
    return _answer(self, frame)


sg.Client.answer = answer

if __name__ == '__main__':
    sg.main()
