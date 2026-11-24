#!/usr/bin/env python3
"""SIMULATION ONLY. A fake samplehost v2 API on loopback TLS for the Phone Calls UI acceptance. Nothing is dialed.

The app's DEBUG build reaches it with the launch environment HQ_SAMPLEHOST_BASE_URL=https://127.0.0.1:<port>/v2.
Answers only the requests Phone Calls makes, in the shapes samplehost documents:
  GET  /v2/phone_numbers                       list-phone-numbers
  GET  /v2/ai/assistants                       list-assistants (none until the app creates one)
  POST /v2/ai/assistants                       create-an-assistant (checks name, instructions, Idempotency-Key)
  GET  /v2/ai/assistants/<id>                  get-an-assistant (enabled_features, model, telephony_settings)
  POST /v2/ai/assistants/<id>                  update-an-assistant (checks the WHOLE telephony_settings comes back)
  POST /v2/calls                               dial (checks connection_id/from/to/timeout_secs/time_limit_secs/AMD/
                                               assistant greeting, instructions, tools); answers call_leg_id/session id
  GET  /v2/call_events?filter[leg_id]=&filter[type]=webhook   list-call-events (rows appear `events_lag` s late)
  GET  /v2/ai/conversations?metadata->call_control_id=eq.<id>   list-conversations
  GET  /v2/ai/conversations/<id>/conversations-insights    get-insights-for-a-conversation
  GET  /v2/ai/conversations/<id>/messages      get-conversation-messages, released in lagged batches, with emotion
                                               tags, tool receipts and "[long silence]" rows as samplehost writes them
  POST /v2/calls/<id>/actions/ai_assistant_add_messages          add-messages-to-ai-assistant (answers, owner messages)
  POST /v2/calls/<id>/actions/hangup           hangup-call (a second one answers 90018 "already ended")
  GET  /v2/calls/<id>                          retrieve-a-call-status (start_time/end_time/call_duration after the end)
  GET  /v2/balance, /v2/call_control_applications/<id>, /v2/outbound_voice_profiles/<id>   (Check my setup)
Only the synthetic key KEYTEST is accepted. The key is never stored or printed: requests are logged with
`auth_ok`, `key_in_url` and `key_in_body` flags only.

Test hooks (no auth): GET /__fixture/state, POST /__fixture/reset,
POST /__fixture/scenario {"name": "answers"|"asks-twice"|"voicemail"|"no-answer"|"busy", "lag": s, "events_lag": s}
  answers     a person picks up after 1 s, says hello and asks one ask_owner question; the call stays on until hung up
  asks-twice  the same, and the model asks the same question twice (two tool calls, one batch apart)
  voicemail   machine detection says "machine" 1 s after the dial; a greeting plays; the far side hangs up at 4 s
  no-answer   never answered; samplehost gives up at 3 s (hangup_cause timeout)
  busy        the far side is busy (hangup_cause user_busy) at 1 s
"""
import argparse, datetime, json, ssl, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

KEY = 'KEYTEST'
FROM = '+12125550100'
CONNECTION = 'conn-sim'
ASSISTANT = 'assistant-sim'
PROFILE = 'ovp-sim'
CALL = 'v3:sim-call-1'
LEG = 'leg-sim'
CONVERSATION = 'conv-sim-1'
QUESTION = 'Which simulated time works?'
OWNER_PREFIX = 'Message from the owner, sent during the call: '
lock = threading.RLock()

def empty():
    return {'requests': [], 'problems': [], 'calls': [], 'answers': [], 'told': [], 'hangups': 0, 'assistants': [],
            'created_keys': [], 'dials': [], 'telephony_updates': [],
            'scenario': {'name': 'answers', 'lag': 0.0, 'events_lag': 2.0, 'summary_delay': 3.0},
            'assistant_config': {'greeting': '', 'transcription': {'model': 'deepgram/flux', 'language': 'auto'},
                                 'interruption_settings': {'enable': True}},
            'telephony': {'default_texml_app_id': 'texml-sim', 'noise_suppression': 'aicoustics',
                          'greeting_delay_ms': 400,
                          'time_limit_secs': 1800, 'user_idle_timeout_secs': 180, 'user_idle_reply_secs': 5,
                          'recording_settings': {'enabled': False, 'channels': 'dual', 'format': 'mp3'}}}
state = empty()

def utc(t):
    """`occurred_at` as list-call-events writes it: a space, no T, no zone, microseconds (UTC)."""
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S.%f')

def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'

def error(status, code, title, detail):
    return status, {'errors': [{'code': code, 'title': title, 'detail': detail}]}

def problem(text):
    state['problems'].append(text)

def ask(n, at, question=QUESTION, choices=None):
    return {'role': 'assistant', 'text': '', 'at': at, 'tool_calls': [{'id': 'call_ask_%d' % n, 'type': 'function', 'function': {
        'name': 'ask_owner', 'arguments': json.dumps({'question': question, 'choices': choices or ['Morning', 'Afternoon']})}}]}

# What each scenario does, in seconds after the dial. `answer` None: never picked up.
SCENARIOS = {
    'answers': {'answer': 1.0, 'machine': False, 'end': None, 'cause': None, 'script': lambda: [
        {'role': 'assistant', 'text': '<emotion value="calm"/>Hello from the simulated agent.', 'at': 1.2},
        {'role': 'user', 'text': 'The simulated recipient has a question.', 'at': 1.4},
        ask(1, 1.6),
        {'role': 'tool', 'text': 'Request failed', 'at': 1.7},
        {'role': 'system', 'text': '[long silence]', 'at': 1.8},
    ]},
    'asks-twice': {'answer': 1.0, 'machine': False, 'end': None, 'cause': None, 'script': lambda: [
        {'role': 'assistant', 'text': 'Hello from the simulated agent.', 'at': 1.2},
        {'role': 'user', 'text': 'The simulated recipient has a question.', 'at': 1.4},
        ask(1, 1.6),
        {'role': 'tool', 'text': '{"http_status":422,"error":"unreachable"}', 'at': 1.7},
        {'role': 'assistant', 'text': 'Let me check that for you.', 'at': 3.0},
        ask(2, 3.2),
        {'role': 'tool', 'text': '{"data":{"result":"ok"}}', 'at': 3.3},
    ]},
    'voicemail': {'answer': 1.0, 'machine': True, 'end': 4.0, 'cause': 'normal_clearing', 'script': lambda: [
        {'role': 'assistant', 'text': '<emotion value="calm"/>Hi, this is an AI assistant calling with a quick request.', 'at': 1.5},
        {'role': 'user', 'text': 'The person you are calling is not available. Please record your message at the tone.', 'at': 2.0},
        {'role': 'system', 'text': '[long silence]', 'at': 3.0},
    ]},
    'ringing': {'answer': None, 'machine': False, 'end': None, 'cause': None, 'script': lambda: []},
    'design': {'answer': 1.0, 'machine': False, 'end': None, 'cause': None, 'script': lambda: [
        {'role': 'assistant', 'text': "Hi, this is an AI assistant calling on behalf of Alex. I'd like to book a table for two tonight at 7.", 'at': 1.2},
        {'role': 'user', 'text': 'Sure. We have 7:15 or 8:00, which one?', 'at': 1.4},
        {'role': 'assistant', 'text': 'Let me check with Alex, one moment.', 'at': 4.0},
        ask(1, 35.0, '7:15 or 8:00 tonight?', ['7:15', '8:00']),
    ]},
    'long': {'answer': 1.0, 'machine': False, 'end': None, 'cause': None, 'script': lambda: [
        {'role': 'assistant', 'text': 'I am calling to arrange a quiet table for two this weekend.', 'at': 1.2},
        ask(1, 12.0, 'The quiet dining room is full this evening. Would you prefer a table in the main room tonight, or should I check for a quiet table tomorrow?', ['Main room at 7:15', 'Main room at 8:00', 'Quiet room tomorrow', 'Ask about next week']),
    ]},
    'no-summary': {'answer': 1.0, 'machine': False, 'end': 5.0, 'cause': 'normal_clearing', 'script': lambda: [
        {'role': 'assistant', 'text': 'Thanks for checking.', 'at': 2.0},
        {'role': 'user', 'text': 'You are welcome.', 'at': 3.0},
    ]},
    'no-answer': {'answer': None, 'machine': False, 'end': 3.0, 'cause': 'timeout', 'script': lambda: []},
    'busy': {'answer': None, 'machine': False, 'end': 1.0, 'cause': 'user_busy', 'script': lambda: []},
}

SCENARIOS['live'] = dict(SCENARIOS['design'], script=lambda: SCENARIOS['design']['script']()[:-1])

def elapsed(call):
    return time.time() - call['started']

def tick(call):
    """Ends the call when its scenario says the far side hangs up."""
    plan = SCENARIOS[call['scenario']]
    if call['alive'] and plan['end'] is not None and elapsed(call) >= plan['end']:
        finish(call, plan['cause'], 'callee')

def finish(call, cause, source):
    if not call['alive']: return
    call['alive'] = False
    call['ended'] = time.time()
    call['cause'] = cause or 'normal_clearing'
    call['source'] = source

def events(call):
    """The webhook events samplehost would have sent, each logged `events_lag` seconds after it happened."""
    plan = SCENARIOS[call['scenario']]
    lag = call['config']['events_lag']
    out = [('call.initiated', call['started'], {})]
    if plan['answer'] is not None and (call['ended'] is None or call['ended'] >= call['started'] + plan['answer']):
        out.append(('call.answered', call['started'] + plan['answer'], {}))
        out.append(('call.machine.premium.detection.ended', call['started'] + plan['answer'] + 0.5,
                    {'result': 'machine' if plan['machine'] else 'human'}))
    if not call['alive']:
        out.append(('call.hangup', call['ended'], {'hangup_cause': call['cause'], 'hangup_source': call['source'],
                                                   'sip_hangup_cause': 'unspecified'}))
        out.append(('call.conversation.ended', call['ended'] + 0.1, {}))
    now = time.time()
    rows = []
    for name, at, inner in out:
        if at + lag > now: continue
        rows.append({'record_type': 'call_event', 'call_leg_id': call['leg'], 'call_session_id': call['session'], 'type': 'webhook',
                     'name': name, 'occurred_at': utc(at), 'metadata': {},
                     'payload': {'event_type': name, 'id': 'ev-%s' % name, 'occurred_at': iso(at),
                                 'payload': dict(inner, call_control_id=call['id'], call_leg_id=call['leg'])}})
    return list(reversed(rows))

def messages(call):
    """What get-conversation-messages returns now: batches appear `lag` seconds late, newest first."""
    lag = call['config']['lag']
    now = elapsed(call)
    out = []
    for m in SCENARIOS[call['scenario']]['script']():
        if m['at'] + lag <= now:
            row = {k: v for k, v in m.items() if k != 'at'}
            row['created_at'] = iso(call['started'] + m['at'])
            out.append(row)
    for extra in call['extra']:
        if extra['at'] + lag <= now:
            row = {k: v for k, v in extra.items() if k != 'at'}
            row['created_at'] = iso(call['started'] + extra['at'])
            out.append(row)
    return list(reversed(out))   # newest first: the app must sort

def check_dial(body):
    assistant = body.get('assistant') or {}
    tools = assistant.get('tools') or []
    webhook = next((t.get('webhook') or {} for t in tools if t.get('type') == 'webhook'), {})
    instructions = assistant.get('instructions') or ''
    for name, ok in [('connection_id', body.get('connection_id') == CONNECTION), ('from', body.get('from') == FROM),
                     ('to', str(body.get('to') or '').startswith('+') and str(body.get('to'))[1:].isdigit()),
                     ('time_limit_secs', body.get('time_limit_secs') == 1800), ('timeout_secs', body.get('timeout_secs') == 45),
                     ('answering_machine_detection', body.get('answering_machine_detection') == 'premium'),
                     ('command_id', bool(body.get('command_id'))), ('assistant.id', assistant.get('id') == ASSISTANT),
                     ('assistant.greeting', bool((assistant.get('greeting') or '').strip())
                      and 'on behalf of the owner' not in (assistant.get('greeting') or '').lower()
                      and '—' not in (assistant.get('greeting') or '')),
                     ('assistant.instructions', 'ask_owner' in instructions and '60 seconds' not in instructions
                      and 'Current local time:' in instructions and '—' not in instructions),
                     ('ask_owner tool', webhook.get('name') == 'ask_owner' and webhook.get('url', '').endswith('.invalid/hermes-hq'))]:
        if not ok: problem('dial ' + name)

def route(method, path, query, body, headers=None):
    calls = state['calls']
    for entry in calls: tick(entry)
    call = next((entry for entry in calls if path.startswith('/v2/calls/' + entry['id'] + '/') or path == '/v2/calls/' + entry['id']), None)

    if method == 'GET' and path == '/v2/phone_numbers':
        return 200, {'data': [{'id': '1293384261075731499', 'record_type': 'phone_number', 'phone_number': FROM, 'status': 'active',
                               'connection_id': CONNECTION, 'connection_name': 'Simulated connection'}],
                     'meta': {'total_pages': 1, 'total_results': 1, 'page_number': 1, 'page_size': 250}}
    if method == 'GET' and path == '/v2/ai/assistants':
        return 200, {'data': state['assistants']}
    if method == 'POST' and path == '/v2/ai/assistants':
        key = (headers or {}).get('Idempotency-Key') or ''
        if not key: problem('create assistant Idempotency-Key')
        if not (body or {}).get('name') or not (body or {}).get('instructions'): problem('create assistant required fields')
        if key not in state['created_keys']:
            state['created_keys'].append(key)
            state['assistants'].append({'id': ASSISTANT, 'name': (body or {}).get('name'), 'created_at': iso(0)})
            if isinstance((body or {}).get('telephony_settings'), dict):
                merged = dict(state['telephony'])
                merged.update(body['telephony_settings'])
                state['telephony'] = merged
            if 'greeting' in (body or {}): state['assistant_config']['greeting'] = body['greeting']
            if isinstance((body or {}).get('transcription'), dict): state['assistant_config']['transcription'] = body['transcription']
            if isinstance((body or {}).get('interruption_settings'), dict): state['assistant_config']['interruption_settings'] = body['interruption_settings']
        return 200, dict(state['assistants'][-1], model='simulated-default')
    if path == '/v2/ai/assistants/' + ASSISTANT and state['assistants']:
        if method == 'POST':
            sent = (body or {}).get('telephony_settings')
            if not isinstance(sent, dict) or not set(state['telephony'].keys()).issubset(set(sent.keys())):
                problem('update-an-assistant must send the whole telephony_settings')
            else:
                state['telephony'] = sent
                state['telephony_updates'].append(bool((sent.get('recording_settings') or {}).get('enabled')))
            if 'greeting' in (body or {}): state['assistant_config']['greeting'] = body['greeting']
            if isinstance((body or {}).get('transcription'), dict): state['assistant_config']['transcription'] = body['transcription']
            if isinstance((body or {}).get('interruption_settings'), dict): state['assistant_config']['interruption_settings'] = body['interruption_settings']
        return 200, {'id': ASSISTANT, 'name': state['assistants'][-1]['name'], 'model': 'openai/gpt-4o-mini',
                     'enabled_features': ['telephony'], 'greeting': state['assistant_config']['greeting'],
                     'transcription': state['assistant_config']['transcription'],
                     'interruption_settings': state['assistant_config']['interruption_settings'],
                     'telephony_settings': state['telephony']}
    if method == 'GET' and path == '/v2/balance':
        return 200, {'data': {'record_type': 'balance', 'balance': '25.00', 'currency': 'USD', 'credit_limit': '0.00'}}
    if method == 'GET' and path == '/v2/call_control_applications/' + CONNECTION:
        return 200, {'data': {'id': CONNECTION, 'record_type': 'call_control_application', 'active': True,
                              'application_name': 'Simulated connection', 'outbound': {'outbound_voice_profile_id': PROFILE}}}
    if method == 'GET' and path == '/v2/outbound_voice_profiles/' + PROFILE:
        return 200, {'data': {'id': PROFILE, 'record_type': 'outbound_voice_profile', 'enabled': True, 'whitelisted_destinations': ['US', 'CA']}}
    if method == 'POST' and path == '/v2/calls':
        check_dial(body or {})
        call = next((entry for entry in calls if entry['command_id'] == (body or {}).get('command_id')), None)
        if call is None:
            if any(entry['alive'] for entry in calls):
                return error(422, '90000', 'Busy', 'A simulated call is already going.')
            assistant = (body or {}).get('assistant') or {}
            state['dials'].append({'to': (body or {}).get('to'), 'greeting': assistant.get('greeting'),
                                   'leaves_message': 'leave one short friendly message' in (assistant.get('instructions') or '')})
            suffix = '' if not calls else '-%d' % (len(calls) + 1)
            call = {'id': CALL + suffix, 'leg': LEG + suffix, 'session': 'session-sim' + suffix,
                    'conversation': CONVERSATION + suffix, 'command_id': (body or {}).get('command_id'),
                    'alive': True, 'started': time.time(), 'scenario': state['scenario']['name'],
                    'config': dict(state['scenario']), 'extra': [], 'ended': None, 'cause': None, 'source': None}
            calls.append(call)
        return 200, {'data': {'call_control_id': call['id'], 'call_leg_id': call['leg'], 'call_session_id': call['session'],
                              'is_alive': False, 'record_type': 'call'}}
    if method == 'GET' and path == '/v2/call_events':
        if (query.get('filter[type]') or [''])[0] != 'webhook': problem('call_events filter[type]')
        leg = (query.get('filter[leg_id]') or [''])[0]
        call = next((entry for entry in calls if entry['leg'] == leg), None)
        data = events(call) if call else []
        return 200, {'data': data, 'meta': {'total_pages': 1, 'total_results': len(data), 'page_number': 1, 'page_size': 50}}
    if method == 'GET' and path == '/v2/ai/conversations':
        wanted = (query.get('metadata->call_control_id') or [''])[0]
        if (query.get('limit') or [''])[0] != '1': problem('conversations limit')
        call = next((entry for entry in calls if wanted == 'eq.' + entry['id']), None)
        pickup = SCENARIOS[call['scenario']]['answer'] if call else None
        found = call and pickup is not None and (call['ended'] or time.time()) >= call['started'] + pickup
        return 200, {'data': [{'id': call['conversation'], 'name': '', 'created_at': iso(call['started']),
                               'metadata': {'call_control_id': call['id']}}] if found else []}
    if method == 'GET' and path.startswith('/v2/ai/conversations/'):
        call = next((entry for entry in calls if path.startswith('/v2/ai/conversations/' + entry['conversation'] + '/')), None)
        if call and path.endswith('/messages'):
            data = messages(call)
            return 200, {'data': data, 'meta': {'total_pages': 1, 'total_results': len(data), 'page_number': 1, 'page_size': 100}}
        if call and path.endswith('/conversations-insights'):
            delay = call['config']['summary_delay']
            if call['ended'] is None or delay is None or call['scenario'] == 'no-summary':
                return 200, {'data': [], 'meta': {}}
            if time.time() < call['ended'] + delay:
                return 200, {'data': [{'id': 'insight-sim', 'status': 'pending', 'conversation_insights': []}], 'meta': {}}
            summary = ('Corner Bistro booked a table for two at 7:15 under Alex. A quiet table was requested.'
                       if call['scenario'] == 'design' else 'The assistant completed the simulated call.')
            return 200, {'data': [{'id': 'insight-sim', 'status': 'completed', 'created_at': iso(call['ended'] + delay),
                                   'conversation_insights': [{'insight_id': 'summary', 'result': summary}]}], 'meta': {}}
    call = next((entry for entry in calls if path.startswith('/v2/calls/' + entry['id'] + '/') or path == '/v2/calls/' + entry['id']), None)
    if call and path == '/v2/calls/' + call['id'] and method == 'GET':
        data = {'call_control_id': call['id'], 'call_leg_id': call['leg'], 'call_session_id': call['session'], 'is_alive': call['alive'], 'record_type': 'call'}
        if not call['alive']:
            answered = SCENARIOS[call['scenario']]['answer']
            data.update({'start_time': iso(call['started']), 'end_time': iso(call['ended']),
                         'call_duration': int(round(call['ended'] - call['started'] - answered)) if answered is not None else 0})
        return 200, {'data': data}
    if call and method == 'POST' and path == '/v2/calls/%s/actions/ai_assistant_add_messages' % call['id']:
        if not call['alive']: return error(422, '90018', 'Call has already ended', "This call is no longer active and can't receive commands.")
        sent = (body or {}).get('messages') or []
        trigger = (body or {}).get('trigger_response')
        if not isinstance(trigger, bool) or not (body or {}).get('command_id'):
            problem('add_messages shape'); return error(422, '10004', 'Invalid', 'trigger_response and command_id are required.')
        tools = [m for m in sent if m.get('role') == 'tool']
        systems = [m for m in sent if m.get('role') == 'system']
        now = elapsed(call)
        if tools:
            asked = {c['id'] for m in SCENARIOS[call['scenario']]['script']() for c in m.get('tool_calls') or []}
            ids = [t.get('tool_call_id') for t in tools]
            if not all(i in asked for i in ids): problem('add_messages unknown tool_call_id')
            content = tools[0].get('content') or ''
            answer = content.split('): ', 1)[1] if '): ' in content else content
            for t in tools: call['extra'].append({'role': 'tool', 'text': t.get('content') or '', 'at': now})
            if trigger: call['extra'].append({'role': 'assistant', 'text': 'Simulated answer received: ' + answer, 'at': now + 0.5})
            state['answers'].append({'tool_call_id': ids[0], 'tool_call_ids': ids, 'answer': answer,
                                     'roles': [m.get('role') for m in sent], 'trigger_response': trigger})
        elif len(systems) == 1 and (systems[0].get('content') or '').startswith(OWNER_PREFIX) and trigger is True:
            text = systems[0]['content'][len(OWNER_PREFIX):]
            call['extra'].append({'role': 'system', 'text': systems[0]['content'], 'at': now})
            call['extra'].append({'role': 'assistant', 'text': 'Simulated note received: ' + text, 'at': now + 0.5})
            state['told'].append(text)
        else:
            problem('add_messages shape'); return error(422, '10004', 'Invalid', 'Unexpected messages.')
        return 200, {'data': {'result': 'ok'}}
    if call and method == 'POST' and path == '/v2/calls/%s/actions/hangup' % call['id']:
        if not call['alive']: return error(422, '90018', 'Call has already ended', "This call is no longer active and can't receive commands.")
        finish(call, 'normal_clearing', 'caller'); state['hangups'] += 1
        return 200, {'data': {'result': 'ok'}}
    return error(404, '10005', 'Resource not found', 'The requested resource or URL could not be found.')

def public(value):
    """The state as JSON (no functions, no raw times)."""
    return json.loads(json.dumps(value, default=str))

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def handle_any(self, method):
        u = urlparse(self.path)
        path = unquote(u.path)
        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length) if length else b''
        try: body = json.loads(raw) if raw else None
        except ValueError: body = None
        if path == '/__fixture/state' and method == 'GET':
            with lock:
                for call in state['calls']: tick(call)
                return self.reply(200, public(state))
        if path == '/__fixture/reset' and method == 'POST':
            with lock: state.clear(); state.update(empty())
            return self.reply(200, {'ok': True})
        if path == '/__fixture/scenario' and method == 'POST':
            name = (body or {}).get('name', 'answers')
            if name not in SCENARIOS: return self.reply(400, {'error': 'unknown scenario'})
            with lock:
                state['scenario'] = {'name': name, 'lag': float((body or {}).get('lag', 0)), 'events_lag': float((body or {}).get('events_lag', 2)),
                                     'summary_delay': (body or {}).get('summary_delay', 3)}
            return self.reply(200, {'ok': True})
        auth_ok = self.headers.get('Authorization') == 'Bearer ' + KEY
        with lock:
            state['requests'].append({'method': method, 'path': path, 'auth_ok': auth_ok, 'key_in_url': KEY in self.path,
                                      'key_in_body': KEY.encode() in raw})
            if not auth_ok:
                return self.reply(*error(401, '10009', 'Authentication failed', 'Could not understand the provided credentials.'))
            status, obj = route(method, path, parse_qs(u.query), body, {'Idempotency-Key': self.headers.get('Idempotency-Key')})
        return self.reply(status, obj)
    def do_GET(self): self.handle_any('GET')
    def do_POST(self): self.handle_any('POST')

def main():
    p = argparse.ArgumentParser(); p.add_argument('--port', type=int, required=True); p.add_argument('--cert', required=True); p.add_argument('--key', required=True); a = p.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', a.port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(a.cert, a.key); server.socket = context.wrap_socket(server.socket, server_side=True)
    print('SIMULATED samplehost listening on loopback only', flush=True); server.serve_forever()
if __name__ == '__main__': main()
