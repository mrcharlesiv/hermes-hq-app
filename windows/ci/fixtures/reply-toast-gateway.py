#!/usr/bin/env python3
"""A loopback chat stand-in, NOT a questions server. Its four notification events have no caller-supplied arguments.
No prompt, request, approval/credential endpoint, command or upstream. Use the normal synthetic sign-in and WebSocket.
"""
import argparse
from http.server import ThreadingHTTPServer
import importlib.util
import json
import os
import pathlib
import re
import secrets
from typing import Any
from urllib.parse import urlparse

spec = importlib.util.spec_from_file_location('toast_chat', pathlib.Path(__file__).with_name('build47-fixture-gateway.py'))
assert spec is not None and spec.loader is not None
base: Any = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def event(path, run, attempt):
    if not all(re.fullmatch('[1-9][0-9]{0,19}', n or '') for n in (run, attempt)):
        raise ValueError('invalid fixture run')
    suffix = f' HQ test {run}.{attempt}'
    return {
        '/__toast/warm': ('message.complete', {'text': 'The draft is ready for review.' + suffix}),
        '/__toast/away': ('message.complete', {'text': 'The summary is ready too.'}),
        '/__toast/failure': ('error', {'message': 'Provider request timed out.', 'error_surface': {'code': 'timeout'}}),
        '/__toast/cold': ('message.complete', {'text': 'Cold launch check: the notes are ready.' + suffix}),
    }.get(path)


chat_handler = base.handler
read_rpc = base.rpc


def rpc(method, params):
    if method in ('session.resume', 'session.activate', 'session.info', 'session.get', 'session.active_list',
                  'session.list', 'session.most_recent', 'session.events.since', 'session.usage', 'session.control.read',
                  'profiles.list', 'approval.pending', 'gateway.ping', 'gateway.status', 'status.get', 'model.options',
                  'model.list', 'models.list', 'config.get', 'setup.status', 'setup.runtime_check', 'tools.list',
                  'commands.catalog', 'skills.list', 'free_tier.status', 'client.capabilities'):
        return read_rpc(method, params)
    raise ValueError('read-only fixture')


class ReadOnlyClient(base.Client):
    def prompt(self, frame):
        self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32601, 'message': 'read-only fixture'}})


def handler(gateway):
    class Handler(chat_handler(gateway)):
        def do_GET(self):
            if urlparse(self.path).path.startswith(('/__fixture', '/__toast')):
                return self.reply(404, {})
            return super().do_GET()

        def refuse_write(self):
            self.close_connection = True
            return self.reply(405, {'detail': 'read-only fixture'})

        do_PATCH = do_PUT = do_DELETE = refuse_write

        def do_POST(self):
            if self.path in ('/auth/password-login', '/api/auth/refresh', '/api/auth/ws-ticket', '/auth/logout'):
                return super().do_POST()  # only the stand-in's own sign-in and socket ticket
            selected = event(self.path, os.environ.get('GITHUB_RUN_ID'), os.environ.get('GITHUB_RUN_ATTEMPT'))
            if selected is None or (self.headers.get_all('Content-Length') or ['0']) != ['0'] or 'Transfer-Encoding' in self.headers:
                self.close_connection = True
                return self.reply(400, {'detail': 'expected a fixed fixture event without arguments'})
            kind, payload = selected
            if kind == 'message.complete': payload['row_id'] = base.append('sam', 'assistant', payload['text'])
            base.emit('sam', kind, payload)
            return self.reply(200, {'ok': True})

    return Handler


def configure():
    base.Client, base.handler, base.rpc = ReadOnlyClient, handler, rpc
    base.voice.rpc = rpc
    base.voice.ACCEPT_PROMPTS = False


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--port', required=True, type=int, choices=(9736,))
    parser.add_argument('--credentials', required=True, type=pathlib.Path)
    args = parser.parse_args()
    event('/__toast/warm', os.environ.get('GITHUB_RUN_ID'), os.environ.get('GITHUB_RUN_ATTEMPT'))
    configure()
    username, password = 'toast-fixture', secrets.token_urlsafe(24)
    gateway = base.voice.auth.Gateway(username, password, True, None)
    # Bind before writing readiness. Never overwrite/reuse an existing receipt or inherit a real account.
    with ThreadingHTTPServer(('127.0.0.1', args.port), handler(gateway)) as server:
        fd = os.open(args.credentials, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w') as receipt:
            json.dump(dict(url='http://127.0.0.1:9736', username=username, password=password), receipt)
        server.serve_forever()


if __name__ == '__main__':
    main()
