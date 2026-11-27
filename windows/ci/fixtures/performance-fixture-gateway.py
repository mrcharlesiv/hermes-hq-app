#!/usr/bin/env python3
"""Loopback performance fixture: paged synthetic history and interleaved tool/text events.

Uses the existing authenticated acceptance gateway. All state and credentials are invented;
never forwards requests. Plan keys: tools, toolBytes, chunks, chunkDelay, replyDelay.
"""
import importlib.util
import json
import pathlib
import uuid
from urllib.parse import urlparse, parse_qs

spec = importlib.util.spec_from_file_location('performance_base', pathlib.Path(__file__).with_name('build47-fixture-gateway.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
original_handler = base.handler


def stream(profile, plan):
    cancel = base.CANCEL[profile]
    if cancel.wait(float(plan.get('replyDelay', .1))): return
    chunks = plan.get('chunks') or [plan.get('replyText', 'Synthetic performance reply.')]
    if chunks == [None]: return
    tools = min(100, max(0, int(plan.get('tools', 0))))
    output_bytes = min(2 * 1024 * 1024, max(0, int(plan.get('toolBytes', 2048))))
    base.emit(profile, 'message.start')
    for index, chunk in enumerate(chunks):
        if cancel.wait(float(plan.get('chunkDelay', .015))): return
        base.emit(profile, 'message.delta', {'text': chunk})
        if index < tools:
            call_id = f'performance-tool-{index}'
            args = {'command': f'printf synthetic-step-{index}', 'timeout': 5}
            base.emit(profile, 'tool.start', {'name': 'terminal', 'tool_id': call_id, 'args': args})
            if cancel.wait(.015): return
            output = ('synthetic output\n' * (output_bytes // 17 + 1))[:output_bytes]
            result = {'stdout': output, 'stderr': '', 'exit_code': 0}
            with base.LOCK:
                row = base.append(profile, 'assistant', '')
                base.MESSAGES[profile][-1]['tool_calls'] = [{'id': call_id, 'type': 'function', 'function': {'name': 'terminal', 'arguments': json.dumps(args)}}]
                base.append(profile, 'tool', json.dumps(result))
                base.MESSAGES[profile][-1]['tool_call_id'] = call_id
            base.emit(profile, 'tool.complete', {'name': 'terminal', 'tool_id': call_id, 'args': args, 'result': result})
    text = ''.join(chunks)
    row = base.append(profile, 'assistant', text)
    base.RUNNING[profile] = False
    base.emit(profile, 'message.complete', {'text': text, 'row_id': row})


base.stream = stream
_original_row = base.voice.row
def current_row(profile):
    row = _original_row(profile)
    row['message_count'] = len(base.MESSAGES[profile])
    return row
base.voice.row = current_row

# Subagents started through /__fixture/event, so the app's subagent.list reconcile keeps them.
SUBAGENTS = {}

# This synthetic account explicitly enables cached reopen; never supplies real user settings.
_original_rpc = base.voice.rpc
def performance_rpc(method, params):
    result = _original_rpc(method, params)
    if method == 'subagent.list': return {'subagents': list(SUBAGENTS.values()), 'delegations': []}
    if method == 'config.get' and isinstance(result, dict):
        result = {**result, 'config': {**result.get('config', {}), 'display': {'resume_last_session': True}}}
    return result
base.voice.rpc = performance_rpc


def handler(gateway):
    parent = original_handler(gateway)
    class Handler(parent):
        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == '/api/config': return self.reply(200, {'model':'fixture-model','provider':'fixture','stt':{'enabled':False},'display':{'resume_last_session':True}})
            if parsed.path == '/__fixture/performance': return self.reply(200, {'schema':'dispatch-performance.fixture.v1', 'synthetic':True})
            if parsed.path.startswith('/api/sessions/') and parsed.path.endswith(('/timeline', '/messages/around')):
                params = parse_qs(parsed.query)
                profile = params.get('profile', [None])[0] or next((p for p, sid in base.voice.SIDS.items() if sid in parsed.path), 'default')
                if profile not in base.MESSAGES: return self.reply(404, {'detail': 'Unknown synthetic profile'})
                with base.LOCK: messages = list(base.MESSAGES[profile])
                if parsed.path.endswith('/timeline'):
                    after = int(params.get('after_row_id', ['0'])[0])
                    limit = min(500, max(1, int(params.get('limit', ['500'])[0])))
                    all_entries = [row for row in messages if row['role'] == 'user' and row['row_id'] > after]
                    entries = all_entries[:limit]
                    return self.reply(200, {'entries': [{'row_id': row['row_id'], 'preview': row['content'][:120], 'timestamp': row['timestamp']} for row in entries],
                        'pagination': {'has_more': len(all_entries) > len(entries), 'next_cursor': entries[-1]['row_id'] if entries else None}})
                row_id = int(params.get('row_id', ['0'])[0])
                offset = next((i for i, row in enumerate(messages) if row['row_id'] == row_id and row['role'] == 'user'), None)
                if offset is None: return self.reply(404, {'detail': 'Synthetic prompt not found'})
                limit = min(120, max(1, int(params.get('limit', ['120'])[0])))
                page = messages[offset:offset + limit]
                return self.reply(200, {'messages': page, 'pagination': {'offset': offset, 'returned': len(page), 'limit': limit,
                    'has_older': offset > 0, 'has_newer': offset + len(page) < len(messages), 'next_offset': offset + len(page), 'total': len(messages)}})
            if parsed.path.startswith('/api/sessions/') and parsed.path.endswith('/messages'):
                params = parse_qs(parsed.query)
                profile = params.get('profile', [None])[0] or next((p for p, sid in base.voice.SIDS.items() if sid in parsed.path), 'default')
                if profile not in base.MESSAGES: return self.reply(404, {'detail': 'Unknown synthetic profile'})
                offset = max(0, int(params.get('offset', ['0'])[0]))
                limit = min(500, max(1, int(params.get('limit', ['500'])[0])))
                order = params.get('order', ['latest' if 'limit' not in params else 'oldest'])[0]
                with base.LOCK:
                    messages = list(base.MESSAGES[profile])
                page = list(reversed(messages))[offset:offset + limit][::-1] if order == 'latest' else messages[offset:offset + limit]
                more = offset + len(page) < len(messages)
                return self.reply(200, {'session_id': base.voice.SIDS[profile], 'profile': profile, 'messages': page,
                    'pagination': {'limit': limit, 'offset': offset, 'order': order, 'returned': len(page), 'has_more': more, 'next_offset': offset + len(page)}})
            return super().do_GET()
        def do_POST(self):
            if self.path == '/__fixture/history':
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
                profile = body.get('profile', 'default')
                count = min(10000, max(0, int(body.get('count', 1000))))
                if profile not in base.MESSAGES: return self.reply(404, {'detail': 'Unknown synthetic profile'})
                with base.LOCK:
                    if base.RUNNING[profile]: return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                    if body.get('new_session'): base.voice.SIDS[profile] = '20261002_120000_' + uuid.uuid4().hex[:8]
                    base.MESSAGES[profile] = []
                    for index in range(count):
                        if body.get('non_dense'): base.NEXT_ROW += 3
                        role = ('user' if index == 0 else 'assistant') if body.get('long_turn') else ('user' if index % 2 == 0 else 'assistant')
                        base.append(profile, role, f'Synthetic history row {index}. ' + 'Readable history. ' * 12)
                return self.reply(200, {'ok': True, 'rows': count, 'session_id': base.voice.SIDS[profile]})
            if self.path == '/__fixture/event':
                # One synthetic gateway event (a subagent's start, say) into the open session.
                body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
                profile = body.get('profile', 'default')
                if profile not in base.MESSAGES or not isinstance(body.get('type'), str): return self.reply(400, {'detail': 'profile and type'})
                payload = body.get('payload') or {}
                if body['type'].startswith('subagent.') and payload.get('subagent_id'):
                    if body['type'] == 'subagent.complete': SUBAGENTS.pop(payload['subagent_id'], None)
                    else: SUBAGENTS[payload['subagent_id']] = payload
                base.emit(profile, body['type'], payload)
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler


base.handler = handler
if __name__ == '__main__': base.main()
