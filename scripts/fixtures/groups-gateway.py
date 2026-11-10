#!/usr/bin/env python3
"""Loopback stand-in gateway for the groups stream (docs/spec/3x-groups.md §8). Invented data only.

Loads scripts/fixtures/settings-gateway.py as a module (nothing there is edited) for its sign-in, roster,
profiles.list / profiles.configure with Hermes' per-key compare-and-swap, strict unknown-parameter answer (4000),
REST and WebSocket, and adds what a group chat needs:

  * a seeded room (Launch Room) as membership on three bots plus the bounded mirror on the default profile
    (ui_meta["hermes-bots-groups"], a version-3 envelope), and one ordinary chat that ends with deliveries;
  * the hidden per-(thread, member) sessions the app drives: session.create (strict keys, idempotent by
    idempotency_key), session.resume by stored id or exact title (4007 when unknown), prompt.submit by runtime id only
    (4001 for a stored id), session.interrupt by runtime id only, each scripted by a per-profile turn mode;
  * clarify / approval server requests for a member's turn;
  * groups.* and bot_relay.* answer -32601 and are recorded (the app must never call them).

It imports nothing from Hermes and never opens a port it was not given.

Controls (loopback, no auth, never under /api/), all under /__groups/:
  GET  state                           calls, writes, sessions, prompts, interrupts, profiles, mirror, modes
  POST turn-mode {"ivy": "<mode>"}     reply | pass | say:<text> | once[:<text>] | slow[:s] | hang | late:<text> | fail | error | busy |
                                       gone | clarify | approval | long        ({} clears all)
  POST release {"profile"}             lets a hang / late turn finish
  POST desktop-edit {"op": …}          append | rename | members | delete | image | remove-bot | raw
  POST fail {"method","match"?,"mode","count"}   error | conflict | applied-false | slow (35 s) | drop
  POST mode {"offline"|"latency"|"dropSocketAfter"|"rotateRuntime"|"noRevisions"}
  POST seed {"preset": …}              standup | full | other-gateway | v1 | v2 | no-id | cap | emoji | malformed (+case) |
                                       section | one-bot | load
  POST reset                           back to the seed, logs cleared

  python3 scripts/fixtures/groups-gateway.py --port 9960 --credentials build/fixtures/groups.json
  python3 scripts/fixtures/groups-gateway.py --self-test          (no port opened)
"""
import argparse, copy, hashlib, importlib.util, json, os, pathlib, re, secrets, socket, struct, sys, threading, time, uuid
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse

HERE = pathlib.Path(__file__).parent


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


settings = _load('settings_fixture', 'settings-gateway.py')
gp = _load('groups_prompt', 'groups_prompt.py')
voice = settings.voice
LOCK = settings.LOCK
RPCFailure = settings.RPCFailure

BOTS = 'hermes-bots'
MIRROR = 'hermes-bots-groups'
SYNC_BYTES = 48000
SYNC_LOG = 16
SYNC_TEXT = 1200
SYNC_IMAGE = 24000
TRUNCATED = '… [truncated]'
OPTIONS = {'bots': 8, 'rooms': True, 'revisions': True, 'load': None}
SOCKETS = set()
RELEASES = {}          # stored session id → threading.Event (hang / late turns)
REQUESTS = {}          # srq id → request record (clarify / approval)


class Drop(Exception):
    """The socket closes before the answer."""


# ---- contract keys (tui_gateway/contracts/sessions.py, prompt_voice.py): anything else answers 4000 --------------
STRICT = {
    'session.create': {'profile', 'cols', 'source', 'cwd', 'cwd_explicit', 'messages', 'parent_session_id', 'title', 'model',
                       'provider', 'reasoning_effort', 'fast', 'service_tier', 'close_on_disconnect', 'hidden', 'room_plumbing',
                       'follow_profile_config', 'idempotency_key'},
    'session.resume': {'session_id', 'profile', 'cols', 'source', 'lazy', 'defer_history', 'omit_messages', 'eager_build',
                       'close_on_disconnect', 'inline_images'},
    'session.interrupt': {'session_id', 'profile', 'expected_hosted_task_id'},
    'prompt.submit': {'session_id', 'profile', 'text', 'display_kind', 'interrupted', 'queued', 'surface', 'voice_context',
                      'voice_turn', 'title_preview', 'truncate_before_user_ordinal', 'truncate_before_row_id',
                      'truncate_before_message_id', 'confirm_truncate', 'confirm_empty_truncate', 'rebind_survivor_row_ids'},
    'client.capabilities': {'server_requests'},
    'clarify.lock': {'request_id', 'question_id', 'answer', 'profile'},
    'approval.respond': {'session_id', 'profile', 'choice', 'all', 'request_id'},
}


def S():
    return settings.S


def G():
    return settings.S['groups']


def now_ms():
    return int(time.time() * 1000)


# ---- sizes (the web's count and Python's own) --------------------------------------------------------------------
def web_size(value):
    """`groupChatGatewayJsonSize`: bytes of the compact JSON, with Python's separator spaces and ASCII escapes."""
    text = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    size = 0
    for ch in text:
        code = ord(ch)
        if code <= 0x7F:
            size += 2 if ch in ',:' else 1
        else:
            size += 6 if code <= 0xFFFF else 12
    return size


def python_size(value):
    return len(json.dumps(value))


def compact_text(text, limit=SYNC_TEXT):
    units = text.encode('utf-16-le')
    if len(units) // 2 <= limit:
        return text, False
    budget = max(0, limit - len(TRUNCATED))
    return units[:budget * 2].decode('utf-16-le', errors='ignore') + TRUNCATED, True


def last_at(room):
    log = room.get('log') if isinstance(room.get('log'), list) else []
    ats = [e.get('at') for e in log if isinstance(e, dict) and isinstance(e.get('at'), (int, float))]
    return max(ats) if ats else 0


def fit(envelope, limit=SYNC_BYTES):
    """The web's cap: rooms newest first; a room that pushes the envelope over loses its oldest entries down to one,
    then its image, then is left out."""
    out = dict(envelope, rooms={})
    for key, room in sorted(envelope.get('rooms', {}).items(), key=lambda kv: -last_at(kv[1])):
        room = copy.deepcopy(room)
        out['rooms'][key] = room
        while python_size(out) > limit:
            if len(room['log']) > 1:
                room['log'].pop(0)
                room['omitted'] = room.get('omitted', 0) + 1
            elif room.get('image'):
                room.pop('image')
            else:
                del out['rooms'][key]
                break
    return out


# ---- seed --------------------------------------------------------------------------------------------------------
def head(color, seed, form='round', look='ovals'):
    return {'v': 6, 'theme': 'shape', 'color': color, 'seed': seed, 'form': form, 'look': look, 'specs': 'none', 'hat': 'none',
            'mouth': 'none', 'blush': False, 'tile': 'none'}


ORDER = ['default', 'ivy', 'research', 'inbox', 'deploys', 'notes', 'ops', 'writer']
HEADS = {'ivy': head('butter', 3), 'research': head('teal', 11, 'hex', 'slits'), 'inbox': head('grape', 5, 'round', 'dots'),
         'notes': head('coral', 9), 'ops': head('lime', 13, 'hex'), 'writer': head('rose', 17), 'deploys': head('slate', 21)}


def entry(identifier, author, text, at, thread):
    sender = {'kind': 'user', 'name': 'You'} if author == 'user' else {'kind': 'member', 'name': author}
    return {'id': identifier, 'from': sender, 'text': text, 'at': at, 'thread': thread}


def member(name):
    return {'name': name, 'handle': gp.handle(name)}


def launch_room(now):
    one, two = 'tfixture-one', 'tfixture-two'
    minute = 60000
    return {'name': 'Launch Room', 'roomId': 'rmfixture-launch', 'holdDetection': True, 'revision': 4, 'omitted': 0,
            'members': [member('default'), member('ivy'), member('research')],
            'log': [entry('fx-1', 'user', 'Who can take the release notes?', now - 20 * minute, one),
                    entry('fx-2', 'research', 'I can check what changed since the last release.', now - 19 * minute, one),
                    entry('fx-3', 'default', 'I will draft the summary once the list is in.', now - 18 * minute, one),
                    entry('fx-4', 'user', 'Thanks. Who writes them up?', now - 4 * minute, two),
                    entry('fx-5', 'research', 'The list is ready: 14 changes.', now - 3 * minute, two),
                    entry('fx-6', 'ivy', 'I can take the notes.', now - 2 * minute, two)]}


def bots_meta(state, name):
    meta = state['profiles'][name]['ui_meta'].get(BOTS)
    return meta if isinstance(meta, dict) else {}


def write_meta(state, name, key, value):
    """One ui_meta key written as another device would: the value replaced, the key's revision + 1."""
    p = state['profiles'][name]
    if value is None:
        p['ui_meta'].pop(key, None)
    else:
        p['ui_meta'][key] = value
    p['revisions'][key] = p['revisions'].get(key, 0) + 1
    return p['revisions'][key]


def set_groups(state, name, names, bump=True):
    meta = copy.deepcopy(bots_meta(state, name))
    meta['groups'] = list(names)
    meta['group'] = names[0] if names else None
    if bump:
        write_meta(state, name, BOTS, meta)
    else:
        state['profiles'][name]['ui_meta'][BOTS] = meta


def groups_of(state, name):
    value = bots_meta(state, name).get('groups')
    return [g for g in value if isinstance(g, str)] if isinstance(value, list) else []


def join(state, name, room, bump=True):
    if name in state['profiles'] and room not in groups_of(state, name):
        set_groups(state, name, groups_of(state, name) + [room], bump)


def leave(state, name, room, bump=True):
    if name in state['profiles'] and room in groups_of(state, name):
        set_groups(state, name, [g for g in groups_of(state, name) if g != room], bump)


def envelope_of(state):
    default = state['profiles'].get('default')
    value = default['ui_meta'].get(MIRROR) if default else None
    return value


def put_envelope(state, envelope, bump=True):
    if bump:
        return write_meta(state, 'default', MIRROR, envelope)
    state['profiles']['default']['ui_meta'][MIRROR] = envelope
    return state['profiles']['default']['revisions'].get(MIRROR, 0)


def fresh_groups():
    return {'sessions': {}, 'keys': {}, 'calls': [], 'prompts': [], 'interrupts': [], 'forbidden': [], 'rejected': [],
            'modes': {}, 'fail': [], 'desktop': 0, 'rotate': 0, 'frames': None,
            'mode': {'offline': False, 'latency': 0, 'dropSocketAfter': None, 'rotateRuntime': False,
                     'noRevisions': not OPTIONS['revisions']}}


def new_profile(state, name, display, description):
    label = settings.LABEL
    state['profiles'][name] = {'display_name': f'{label} {display}' if label else display,
                               'description': f'{label} {description}' if label else description,
                               'ui_meta': {}, 'revisions': {}, 'chat': None, 'avatar': None, 'extra_chats': []}
    state['skills'][name] = settings.default_skills()
    state['mcp'][name] = settings.default_mcp()


def drop_profile(state, name):
    state['profiles'].pop(name, None)
    state['skills'].pop(name, None)
    state['mcp'].pop(name, None)


_base_seed = settings.seed


def seed():
    state = _base_seed()
    now = int(time.time())
    profiles = state['profiles']
    # No user section by default (POST /__groups/seed {"preset":"section"} adds "Work").
    for name in ('ivy', 'research'):
        meta = profiles[name]['ui_meta'].get(BOTS, {})
        meta.pop('sectionId', None)
        meta.pop('sectionName', None)
    new_profile(state, 'ops', 'Ops', 'Watches the servers')
    new_profile(state, 'writer', 'Writer', 'Drafts posts')
    count = max(2, OPTIONS['bots'])
    for extra in range(9, count + 1):
        new_profile(state, f'bot{extra:02d}', f'Bot {extra}', 'A spare bot')
    for name in ORDER[count:]:
        drop_profile(state, name)
    for name, value in HEADS.items():
        if name in profiles:
            profiles[name]['ui_meta']['dispatch-head'] = value
            profiles[name]['revisions']['dispatch-head'] = 1
    state['groups'] = fresh_groups()
    deliveries(state, now)
    # A hidden room session an older gateway lists as an ordinary one: the Sessions lists must leave it out.
    if 'ivy' in profiles:
        profiles['ivy']['extra_chats'].append({'id': '20260929_120000_aabbcc09', 'title': 'Group: rmfixture-launch · tfixture-two',
                                               'messages': [{'role': 'user', 'content': 'A room prompt.', 'timestamp': now - 120},
                                                            {'role': 'assistant', 'content': 'I can take the notes.', 'timestamp': now - 119}],
                                               'last_active': now - 119, 'started_at': now - 130})
    if OPTIONS['rooms']:
        for name in ('default', 'ivy', 'research'):
            if name in profiles:
                join(state, name, 'Launch Room', bump=False)
        put_envelope(state, {'version': 3, 'updatedAt': now * 1000 - 120000, 'rooms': {'id:rmfixture-launch': launch_room(now * 1000)},
                             'deleted': {}}, bump=False)
        profiles['default']['revisions'][MIRROR] = 4
    if OPTIONS['load']:
        preset_load(state, {'rooms': OPTIONS['load'][0], 'messages': OPTIONS['load'][1]}, bump=False)
    return state


def deliveries(state, now):
    """The default bot's chat ends with deliveries from other bots (§7.12), the last two taken in silently; Ivy's has none."""
    chat = state['profiles']['default']['chat']
    start = now - 1800
    rows = [('user', 'Message from Inbox (@inbox): Three new emails need a reply.', 0),
            ('user', 'Message from Inbox (@inbox): The invoice from Northwind is overdue.', 60),
            ('user', 'Message from Inbox (@inbox): Lunch moved to 1 pm.', 120),
            ('assistant', 'Thanks, I will reply to the three emails first.', 180),
            ('user', "[Message from agent 'research'] Findings are in the doc.", 780),
            ('assistant', '[SILENT]', 790),
            ('user', 'Message from Billing Bot: Invoice sent.', 840),
            ('assistant', '[SILENT]', 850)]
    for message in chat['messages']:
        message['timestamp'] = start - 3600 + chat['messages'].index(message) * 60
    for role, text, offset in rows:
        chat['messages'].append({'role': role, 'content': text, 'timestamp': start + offset})
    chat['last_active'] = start + 850


settings.seed = seed


# ---- presets (each rewrites state as another device would, bumping revisions) -----------------------------------
def visible(state):
    return [n for n, p in state['profiles'].items() if not bots_meta(state, n).get('hidden')]


def preset_load(state, body, bump=True):
    """N rooms with M log entries each "on the mirror's terms": every room carries its newest entries (at most 16,
    fewer when 16 of each would not fit the size cap) and says how many it leaves out."""
    rooms, messages = int(body.get('rooms', 40)), int(body.get('messages', 400))
    members, chars = max(2, min(6, int(body.get('members', 3)))), int(body.get('textChars', 60))
    names = [n for n in visible(state)]
    now = now_ms()
    current = envelope_of(state)
    base = copy.deepcopy(current) if isinstance(current, dict) and isinstance(current.get('rooms'), dict) else \
        {'version': 3, 'updatedAt': now, 'rooms': {}, 'deleted': {}}
    base['updatedAt'] = now

    def build(carried):
        envelope = copy.deepcopy(base)
        joined = {}
        for index in range(rooms):
            title = f'Load Room {index + 1:02d}'
            seats = [names[(index + k) % len(names)] for k in range(min(members, len(names)))]
            thread = f'tload-{index + 1:02d}'
            log = []
            for i in range(max(0, messages - carried), messages):
                author = 'user' if i % (len(seats) + 1) == 0 else seats[i % len(seats)]
                body_text = f'Load message {i + 1} of {messages} in {title}. ' + ('lorem ipsum ' * 40)
                log.append(entry(f'ld-{index + 1:02d}-{i + 1}', author, body_text[:max(8, chars)].strip(),
                                 now - (index + 1) * 60000 - (messages - i) * 1000, thread))
            envelope['rooms'][f'id:rmload-{index + 1:02d}'] = {
                'name': title, 'roomId': f'rmload-{index + 1:02d}', 'holdDetection': True, 'revision': 1,
                'omitted': max(0, messages - len(log)), 'members': [member(n) for n in seats], 'log': log}
            for n in seats:
                joined.setdefault(n, []).append(title)
        return envelope, joined

    carried = min(SYNC_LOG, max(1, messages))
    envelope, joined = build(carried)
    while carried > 1 and python_size(envelope) > SYNC_BYTES:
        carried -= 1
        envelope, joined = build(carried)
    for n, titles in joined.items():
        set_groups(state, n, groups_of(state, n) + [t for t in titles if t not in groups_of(state, n)], bump)
    put_envelope(state, fit(envelope), bump)


def good_room(state, now):
    """A second, well-formed room so a bad one can be seen skipped next to it."""
    for n in ('inbox', 'notes'):
        join(state, n, 'Good Room')
    return {'name': 'Good Room', 'roomId': 'rmfixture-good', 'holdDetection': True, 'revision': 1, 'omitted': 0,
            'members': [member('inbox'), member('notes')],
            'log': [entry('gd-1', 'user', 'Is this one fine?', now - 300000, 'tgood-one'),
                    entry('gd-2', 'inbox', 'Yes, this room is fine.', now - 240000, 'tgood-one')]}


def apply_preset(state, body):
    preset = body.get('preset')
    now = now_ms()
    current = envelope_of(state)
    envelope = copy.deepcopy(current) if isinstance(current, dict) else {'version': 3, 'updatedAt': now, 'rooms': {}, 'deleted': {}}
    if not isinstance(envelope.get('rooms'), dict):
        envelope['rooms'] = {}
    if not isinstance(envelope.get('deleted'), dict):
        envelope['deleted'] = {}
    envelope['updatedAt'] = now
    rooms = envelope['rooms']
    launch = rooms.get('id:rmfixture-launch')
    if preset == 'standup':
        for n in ('ivy', 'inbox'):
            join(state, n, 'Standup')
        return True
    if preset == 'full':
        seats = ['default', 'ivy', 'research', 'inbox', 'notes', 'ops']
        for n in seats:
            join(state, n, 'Full House')
        rooms['id:rmfixture-full'] = {'name': 'Full House', 'roomId': 'rmfixture-full', 'holdDetection': True, 'revision': 1,
                                      'omitted': 0, 'members': [member(n) for n in seats if n in state['profiles']],
                                      'log': [entry('fh-1', 'user', 'Everyone here?', now - 600000, 'tfull-one')]}
        put_envelope(state, envelope)
        return True
    if preset == 'other-gateway':
        if not launch:
            return False
        launch['members'].append({'name': 'remote', 'handle': 'remote', 'title': 'Remote', 'sourceScoped': True,
                                  'connectionId': 'conn-studio', 'connectionKind': 'remote', 'connectionLabel': 'Office Mac'})
        launch['revision'] = launch.get('revision', 0) + 1
        put_envelope(state, envelope)
        return True
    if preset in ('v1', 'v2'):
        old = {'updatedAt': now, 'rooms': {}, 'deleted': {}}
        if preset == 'v2':
            old['version'] = 2
        for room in rooms.values():
            body_room = {k: v for k, v in room.items() if k not in ('name', 'roomId')}
            if preset == 'v1':
                body_room.pop('revision', None)
                body_room.pop('omitted', None)
            old['rooms'][room['name']] = body_room
        old['deleted'] = {'Old Room': now - 86400000} if preset == 'v1' else {'Old Room': 2}
        put_envelope(state, old)
        return True
    if preset == 'no-id':
        if not launch:
            return False
        del rooms['id:rmfixture-launch']
        launch.pop('roomId', None)
        rooms['name:Launch Room'] = launch
        put_envelope(state, envelope)
        return True
    if preset == 'cap':
        seats = [n for n in ('default', 'ivy', 'research') if n in state['profiles']]
        for index in range(12):
            title = f'Cap Room {index + 1:02d}'
            for n in seats:
                join(state, n, title)
            filler = (f'{title} entry text. ' + 'abcdefghij ' * 120)
            rooms[f'id:rmcap-{index + 1:02d}'] = {
                'name': title, 'roomId': f'rmcap-{index + 1:02d}', 'holdDetection': True, 'revision': 1, 'omitted': 0,
                'members': [member(n) for n in seats],
                'log': [entry(f'cp-{index + 1:02d}-{i + 1}', 'user' if i % 3 == 0 else seats[i % len(seats)], f'{i + 1:02d} ' + filler[:SYNC_TEXT - 3],
                              now - (index + 1) * 600000 - (SYNC_LOG - i) * 1000, f'tcap-{index + 1:02d}') for i in range(SYNC_LOG)]}
        put_envelope(state, fit(envelope))
        return True
    if preset == 'emoji':
        seats = [n for n in ('notes', 'ops') if n in state['profiles']]
        titles = {'notes': 'メモ 📝', 'ops': '運用 🛠️'}
        for n in seats:
            meta = copy.deepcopy(bots_meta(state, n))
            meta['title'] = titles[n]
            write_meta(state, n, BOTS, meta)
            join(state, n, '🚀 発射ルーム 🎉')
        texts = ['🚀' * SYNC_TEXT, '日本語のメッセージです。' * 20, '👩‍👩‍👧‍👦 家族 👨‍👩‍👧', '🎉🎉🎉 完了しました']
        rooms['id:rmfixture-emoji'] = {
            'name': '🚀 発射ルーム 🎉', 'roomId': 'rmfixture-emoji', 'holdDetection': True, 'revision': 1, 'omitted': 0,
            'members': [member(n) for n in seats],
            'log': [entry(f'em-{i + 1}', 'user' if i % 2 == 0 else seats[i % len(seats)], compact_text(texts[i % len(texts)])[0],
                          now - (SYNC_LOG - i) * 60000, 'temoji-one') for i in range(SYNC_LOG)]}
        put_envelope(state, fit(envelope))
        return True
    if preset == 'malformed':
        case = body.get('case')
        if case == 'not-an-object':
            put_envelope(state, 'this is not a room list')
            return True
        if case == 'rooms-array':
            put_envelope(state, {'version': 3, 'updatedAt': now, 'rooms': [launch] if launch else [], 'deleted': {}})
            return True
        rooms['id:rmfixture-good'] = good_room(state, now)
        if not launch:
            return False
        if case == 'log-not-array':
            launch['log'] = 'not a list'
        elif case == 'member-missing-name':
            launch['members'] = [{'handle': 'ghost'}, 42, None] + launch['members']
        elif case == 'text-number':
            launch['log'].append({'id': 'bad-1', 'from': {'kind': 'member', 'name': 'ivy'}, 'text': 42, 'at': now - 1000, 'thread': 'tfixture-two'})
        elif case == 'at-string':
            launch['log'].append({'id': 'bad-2', 'from': {'kind': 'member', 'name': 'ivy'}, 'text': 'When was this?', 'at': 'yesterday', 'thread': 'tfixture-two'})
        elif case == 'huge-image':
            launch['image'] = 'data:image/jpeg;base64,' + 'A' * 30000
        elif case == 'unknown-keys':
            launch['futureKey'] = {'kept': True}
            launch['log'][-1]['reactions'] = ['+1']
            envelope['futureTop'] = 'kept'
        elif case == 'duplicate-ids':
            launch['log'].append(dict(launch['log'][-1]))
            launch['log'].append(dict(launch['log'][-1], text='A different text under the same id.'))
        elif case == 'tombstone-for-live-room':
            envelope['deleted']['id:rmfixture-launch'] = launch.get('revision', 0) + 1
        else:
            return False
        put_envelope(state, envelope)
        return True
    if preset == 'section':
        for n in ('ivy', 'research'):
            if n in state['profiles']:
                meta = copy.deepcopy(bots_meta(state, n))
                meta['sectionId'], meta['sectionName'] = 'sec-work', 'Work'
                write_meta(state, n, BOTS, meta)
        return True
    if preset == 'one-bot':
        for n in [n for n in state['profiles'] if n not in ('default', 'deploys')]:
            drop_profile(state, n)
        set_groups(state, 'default', [])
        for key, room in list(rooms.items()):
            envelope['deleted'][key] = room.get('revision', 0) + 1 if isinstance(room, dict) else 1
        envelope['rooms'] = {}
        put_envelope(state, envelope)
        return True
    if preset == 'load':
        preset_load(state, body)
        return True
    return False


# ---- another device's edits --------------------------------------------------------------------------------------
def find_room(envelope, name):
    """(key, room) by key, roomId or name."""
    rooms = envelope.get('rooms') if isinstance(envelope, dict) else None
    if not isinstance(rooms, dict):
        return None, None
    if name in rooms:
        return name, rooms[name]
    for key, room in rooms.items():
        if isinstance(room, dict) and name in (room.get('roomId'), room.get('name')):
            return key, room
    return None, None


def members_of(state, room_name):
    return [n for n in state['profiles'] if room_name in groups_of(state, n)]


def desktop_edit(state, body):
    op = body.get('op')
    now = now_ms()
    current = envelope_of(state)
    envelope = copy.deepcopy(current) if isinstance(current, dict) and isinstance(current.get('rooms'), dict) else \
        {'version': 3, 'updatedAt': now, 'rooms': {}, 'deleted': {}}
    envelope.setdefault('deleted', {})
    envelope['updatedAt'] = now
    g = state['groups']
    if op == 'raw':
        return {'ok': True, 'revision': put_envelope(state, body.get('value'))}
    if op == 'remove-bot':
        name = body.get('name')
        if name not in state['profiles'] or name == 'default':
            return None
        drop_profile(state, name)
        return {'ok': True}
    key, room = find_room(envelope, body.get('room'))
    name = room['name'] if room else body.get('room')
    if op == 'append':
        if room is None:
            seats = members_of(state, name)
            if not seats:
                return None
            identifier = 'rm' + secrets.token_hex(5)
            key = f'id:{identifier}'
            room = {'name': name, 'roomId': identifier, 'holdDetection': True, 'revision': 1, 'omitted': 0,
                    'members': [member(n) for n in seats], 'log': []}
            envelope['rooms'][key] = room
        g['desktop'] += 1
        thread = body.get('thread') or (room['log'][-1].get('thread') if room['log'] else None) or f'tdesktop-{g["desktop"]}'
        text, cut = compact_text(str(body.get('text', '')))
        made = entry(body.get('id') or f'dk-{g["desktop"]}-{secrets.token_hex(3)}', body.get('from') or 'user', text,
                     body.get('at') or now, thread)
        if cut:
            made['truncated'] = True
        room['log'].append(made)
        if len(room['log']) > SYNC_LOG:
            room['omitted'] = room.get('omitted', 0) + len(room['log']) - SYNC_LOG
            room['log'] = room['log'][-SYNC_LOG:]
        return {'ok': True, 'revision': put_envelope(state, fit(envelope)), 'id': made['id'], 'thread': thread}
    if room is None:
        return None
    if op == 'rename':
        to = str(body.get('to') or '').strip()[:64]
        if not to:
            return None
        for n in members_of(state, name):
            set_groups(state, n, [to if x == name else x for x in groups_of(state, n)])
        room['name'] = to
        room['revision'] = room.get('revision', 0) + 1
        if key.startswith('name:'):
            del envelope['rooms'][key]
            envelope['rooms'][f'name:{to}'] = room
            envelope['deleted'][key] = room['revision']
        return {'ok': True, 'revision': put_envelope(state, envelope)}
    if op == 'members':
        wanted = [n for n in body.get('members', []) if n in state['profiles']]
        for n in list(state['profiles']):
            if n in wanted:
                join(state, n, name)
            else:
                leave(state, n, name)
        kept = [m for m in room['members'] if isinstance(m, dict) and (m.get('sourceScoped') or m.get('name') in wanted)]
        known = {m.get('name') for m in kept}
        room['members'] = kept + [member(n) for n in wanted if n not in known]
        room['revision'] = room.get('revision', 0) + 1
        return {'ok': True, 'revision': put_envelope(state, envelope)}
    if op == 'delete':
        for n in members_of(state, name):
            leave(state, n, name)
        del envelope['rooms'][key]
        envelope['deleted'][key] = room.get('revision', 0) + 1
        return {'ok': True, 'revision': put_envelope(state, envelope)}
    if op == 'image':
        if body.get('value'):
            room['image'] = body['value']
        else:
            room.pop('image', None)
        room['revision'] = room.get('revision', 0) + 1
        return {'ok': True, 'revision': put_envelope(state, envelope)}
    return None


def other_writer(state, incoming):
    """`fail … conflict`: another writer got in first, so the revision moves before the app's write is judged."""
    name_key = None
    for key in incoming:
        if key == MIRROR:
            current = envelope_of(state)
            if isinstance(current, dict) and isinstance(current.get('rooms'), dict) and current['rooms']:
                name_key = max(current['rooms'], key=lambda k: last_at(current['rooms'][k]))
                room = current['rooms'][name_key]
                seats = [m.get('name') for m in room.get('members', []) if isinstance(m, dict) and m.get('name')]
                desktop_edit(state, {'op': 'append', 'room': name_key, 'from': seats[-1] if seats else 'user',
                                     'text': f'From the desktop ({state["groups"]["desktop"] + 1})'})
                continue
        p = state['profiles'].get('default')
        if p is not None:
            p['revisions'][key] = p['revisions'].get(key, 0) + 1


# ---- the hidden room sessions ------------------------------------------------------------------------------------
def is_room_title(title):
    return isinstance(title, str) and title.startswith('Group: ')


def runtime_of(session):
    stored = session['id']
    if session['rotation'] == 0:
        return settings.runtime_id(stored)
    return hashlib.sha256(f'{stored}#{session["rotation"]}'.encode()).hexdigest()[:8]


def room_sessions():
    return G()['sessions'].values()


def session_for(identifier):
    """(session, how): how is 'runtime', 'stale' or 'stored'."""
    if not isinstance(identifier, str):
        return None, None
    for session in room_sessions():
        if identifier == runtime_of(session):
            return session, 'runtime'
    for session in room_sessions():
        if identifier == session['id']:
            return session, 'stored'
        if identifier in session['stale']:
            return session, 'stale'
    return None, None


def session_by_title(profile, title):
    for session in room_sessions():
        if session['title'] == title and session['profile'] == profile:
            return session
    return None


def create_session(params):
    state = S()
    profile = params.get('profile') or 'default'
    if profile not in state['profiles']:
        raise RPCFailure(4064, f"profile '{profile}' not found")
    g = state['groups']
    key = params.get('idempotency_key')
    if isinstance(key, str) and key and key in g['keys']:
        session = g['sessions'][g['keys'][key]]
        session['creates'] += 1
        return created(session)
    stored = time.strftime('%Y%m%d_%H%M%S_') + secrets.token_hex(4)
    title = params.get('title')
    now = time.time()
    session = {'id': stored, 'title': title, 'messages': [], 'last_active': now, 'started_at': now, 'profile': profile,
               'rotation': 0, 'rotated': g['rotate'], 'stale': [], 'running': False, 'inflight': None, 'turn_started_at': None,
               'turn': 0, 'waiting': None, 'open': [], 'approval': None, 'creates': 1, 'gone': False,
               'hidden': params.get('hidden') is True, 'room_plumbing': params.get('room_plumbing') is True,
               'follow_profile_config': params.get('follow_profile_config') is True,
               'plumbingOk': params.get('hidden') is True and params.get('room_plumbing') is True,
               'idempotency_key': key if isinstance(key, str) else None}
    g['sessions'][stored] = session
    if isinstance(key, str) and key:
        g['keys'][key] = stored
    state['profiles'][profile]['extra_chats'].append(session)
    return created(session)


def created(session):
    return {'session_id': runtime_of(session), 'stored_session_id': session['id'], 'message_count': len(session['messages']),
            'messages': [], 'title': session['title'], 'profile': session['profile'],
            'info': {'model': 'fixture-model', 'provider': 'fixture', 'cwd': '/fixture', 'title': session['title'],
                     'profile_name': session['profile'], 'stored_session_id': session['id'], 'desktop_contract': 8}}


def resume_session(session, params, how):
    g = G()
    if how in ('stored', 'title') and g['rotate'] > session['rotated']:
        session['stale'].append(runtime_of(session))
        session['rotation'] += 1
        session['rotated'] = g['rotate']
    result = settings.resumed(session['profile'], session)
    busy = session['running']
    result['session_id'] = runtime_of(session)
    result['running'] = busy
    result['status'] = 'running' if busy else 'idle'
    result['inflight'] = copy.deepcopy(session['inflight'])
    result['info']['running'] = busy
    if session['turn_started_at']:
        result['turn_started_at'] = session['turn_started_at']
    result['open_requests'] = [copy.deepcopy(REQUESTS[i]['snapshot']) for i in session['open'] if i in REQUESTS]
    result['pending_approval'] = copy.deepcopy(session['approval'])
    if params.get('omit_messages'):
        result['messages'], result['messages_omitted'] = [], True
    else:
        result['messages'] = [{'role': m['role'], 'content': m['content'], 'timestamp': m['timestamp']} for m in session['messages']]
        result['messages_omitted'] = False
    return result


def room_part(title):
    return title[len('Group: '):].split(' · ')[0] if is_room_title(title) else ''


def seats_for(state, room):
    """The room's members as the prompt names them, from the bots' own membership (the mirror may not carry a new
    room yet) plus the mirror's members of another gateway."""
    seats = []
    for name, p in state['profiles'].items():
        if room in groups_of(state, name):
            title = bots_meta(state, name).get('title')
            seats.append(gp.seat(name, title=title if isinstance(title, str) and title.strip() else None,
                                 display_name=p['display_name'] or None))
    _, mirrored = find_room(envelope_of(state), room)
    for m in (mirrored or {}).get('members', []) if isinstance(mirrored, dict) else []:
        if isinstance(m, dict) and m.get('sourceScoped') and m.get('name'):
            seats.append(gp.seat(m['name'], title=m.get('title'), saved_handle=m.get('handle'), remote=True,
                                 remote_label=m.get('connectionLabel')))
    return seats


def prompt_ok(state, session, text):
    room = gp.room_name(text)
    if room is None:
        return False, ['no "[Group chat: …]" first line']
    seats = seats_for(state, room)
    viewer = next((s for s in seats if s['name'] == session['profile']), None)
    if viewer is None:
        return False, [f'{session["profile"]} is not a member of {room!r} on the gateway']
    return gp.check(text, room, seats, viewer)


def shown_title(state, profile):
    p = state['profiles'].get(profile)
    if p is None:
        return profile
    title = bots_meta(state, profile).get('title')
    return (title if isinstance(title, str) and title.strip() else None) or p['display_name'] or profile


def emit(session, kind, payload=None, runtime=None):
    frame = {'jsonrpc': '2.0', 'method': 'event',
             'params': {'type': kind, 'session_id': runtime or runtime_of(session), 'payload': payload or {}}}
    broadcast(frame)


def broadcast(frame):
    with LOCK:
        clients = list(settings.CLIENTS)
    for client in clients:
        try:
            client.send(frame)
        except OSError:
            pass


def finish(session, turn, text):
    """The turn ends with `text` (None: with nothing). Ignored when the turn was interrupted meanwhile."""
    with LOCK:
        if session['turn'] != turn:
            return False
        if text is not None:
            session['messages'].append({'role': 'assistant', 'content': text, 'timestamp': time.time()})
        session['running'], session['inflight'], session['waiting'] = False, None, None
        session['last_active'] = time.time()
        row = len(session['messages'])
    emit(session, 'message.complete', {'text': text or '', 'status': 'complete', 'row_id': row})
    return True


def open_request(session, turn, method, params, qids=None):
    record = {'id': 'srq-' + uuid.uuid4().hex[:12], 'method': method, 'session': session['id'], 'turn': turn, 'qids': qids,
              'locked': {}, 'event': threading.Event(), 'result': None, 'answered': False}
    frame_params = {'session_id': runtime_of(session), **params}
    record['snapshot'] = {'id': record['id'], 'method': method, 'params': frame_params}
    with LOCK:
        REQUESTS[record['id']] = record
        session['open'].append(record['id'])
        if method == 'approval':
            session['approval'] = {k: v for k, v in params.items()}
        targets = [c for c in settings.CLIENTS if getattr(c, 'advertised', False)]
    for client in targets:
        try:
            client.send({'jsonrpc': '2.0', 'id': record['id'], 'method': method, 'params': frame_params})
        except OSError:
            pass
    return record


def settle(record, result, answered=True, cancel=None):
    with LOCK:
        if REQUESTS.pop(record['id'], None) is None:
            return False
        session = G()['sessions'].get(record['session'])
        if session is not None:
            if record['id'] in session['open']:
                session['open'].remove(record['id'])
            if record['method'] == 'approval':
                session['approval'] = None
        record['result'], record['answered'] = result, answered
    if cancel and session is not None:
        emit(session, 'request.cancel', {'id': record['id'], 'method': record['method'], 'reason': cancel})
    record['event'].set()
    return True


APPROVAL = {'command': 'git push origin main', 'description': 'git push to a shared branch',
            'pattern_key': 'git push to a shared branch', 'pattern_keys': ['git push to a shared branch'],
            'allow_permanent': True, 'allow_session': True, 'smart_denied': False, 'choices': ['once', 'session', 'always', 'deny'],
            'tool_name': 'terminal'}
QUESTION = [{'qid': 'q0', 'question': 'Which city should I book?', 'choices': ['Lisbon', 'Porto'], 'multi_select': False}]


def play(session, turn, mode, text):
    state = S()
    with LOCK:
        title = shown_title(state, session['profile'])
    newest = gp.newest_user_line(text)
    answer = f'{title} here: {newest[:40]}'
    kind, _, arg = mode.partition(':')
    if kind == 'pass':
        time.sleep(0.3)
        return finish(session, turn, '(pass)')
    if kind == 'say':
        time.sleep(0.3)
        return finish(session, turn, arg)
    if kind == 'once':
        # The first turn of a thread's session answers (the text given, else the usual reply); later turns pass, so a
        # round with no mention settles instead of running to the cap.
        time.sleep(0.3)
        return finish(session, turn, (arg or answer) if turn == 1 else '(pass)')
    if kind == 'long':
        time.sleep(0.3)
        return finish(session, turn, ('This is a long reply. ' * 500)[:9000])
    if kind == 'slow':
        try:
            wait = float(arg) if arg else 8.0
        except ValueError:
            wait = 8.0
        time.sleep(wait)
        return finish(session, turn, answer)
    if kind == 'busy':
        time.sleep(3)
        return finish(session, turn, answer)
    if kind in ('hang', 'late'):
        RELEASES[session['id']].wait()
        return finish(session, turn, arg if kind == 'late' and arg else answer)
    if kind == 'error':
        time.sleep(0.3)
        with LOCK:
            if session['turn'] != turn:
                return False
            session['running'] = False
            session['inflight'] = {'status': 'error', 'error': 'model unavailable'}
        emit(session, 'error', {'message': 'model unavailable'})
        return True
    if kind == 'clarify':
        time.sleep(0.3)
        record = open_request(session, turn, 'clarify', {'questions': copy.deepcopy(QUESTION)}, qids=['q0'])
        record['event'].wait()
        if not record['answered']:
            return False
        answers = (record['result'] or {}).get('answers') or {}
        return finish(session, turn, f'Thanks: {answers.get("q0") or "no answer"}')
    if kind == 'approval':
        time.sleep(0.3)
        request_id = uuid.uuid4().hex
        record = open_request(session, turn, 'approval', dict(APPROVAL, request_id=request_id))
        record['event'].wait()
        if not record['answered']:
            return False
        choice = (record['result'] or {}).get('choice') or 'deny'
        return finish(session, turn, 'Denied, so I left it alone.' if choice == 'deny' else f'Approved ({choice}): pushed.')
    # reply
    time.sleep(0.35)
    with LOCK:
        if session['turn'] != turn:
            return False
    emit(session, 'message.start')
    time.sleep(0.1)
    emit(session, 'message.delta', {'text': answer})
    time.sleep(0.1)
    return finish(session, turn, answer)


def submit_prompt(session, how, params):
    state = S()
    g = state['groups']
    profile = session['profile']
    text = params.get('text')
    text = text if isinstance(text, str) else json.dumps(text)
    with LOCK:
        mode = g['modes'].get(profile, 'reply')
        ok, problems = prompt_ok(state, session, text)
        room = room_part(session['title'])
        inflight = [s['id'] for s in g['sessions'].values()
                    if s is not session and s['running'] and room_part(s['title']) == room]
        record = {'profile': profile, 'session_id': params.get('session_id'), 'stored': session['id'], 'title': session['title'],
                  'by': how, 'text': text, 'promptOk': ok, 'problems': problems, 'mode': mode, 'accepted': False,
                  'inFlightForRoom': len(inflight), 'at': time.time()}
        g['prompts'].append(record)
        if how != 'runtime':
            raise RPCFailure(4001, 'session not in memory')
        kind = mode.partition(':')[0]
        if kind == 'gone' and not session['gone']:
            session['gone'] = True
            raise RPCFailure(4001, 'session not in memory')
        if kind == 'fail':
            raise RPCFailure(5000, 'model unavailable')
        if kind == 'gone':
            kind, mode = 'reply', 'reply'
        record['accepted'] = True
        session['turn'] += 1
        turn = session['turn']
        session['messages'].append({'role': 'user', 'content': text, 'timestamp': time.time()})
        session['last_active'] = time.time()
        session['turn_started_at'] = time.time()
        # A `hang` / `late:` turn stays busy until it is released: the app gives up on it at its hard cap (shortened
        # with -HQGroupsTurnLimit) and collects the reply later, as it does for a real turn that outlasts the cap.
        session['running'] = True
        session['inflight'] = {'status': 'streaming'}
        session['waiting'] = kind if kind in ('hang', 'late') else None
        RELEASES[session['id']] = threading.Event()
        row = len(session['messages'])
    threading.Thread(target=play, args=(session, turn, mode, text), daemon=True).start()
    return {'status': 'queued'} if kind == 'busy' else {'status': 'streaming', 'user_row_id': row}


def interrupt_session(params):
    g = G()
    identifier = params.get('session_id')
    session, how = session_for(identifier)
    record = {'session_id': identifier, 'profile': params.get('profile'), 'by': how or 'unknown', 'status': None,
              'stored': session['id'] if session else None, 'current': runtime_of(session) if session else None, 'at': time.time()}
    g['interrupts'].append(record)
    if session is None:
        return None
    if how != 'runtime':
        record['status'] = 'error 4001'
        raise RPCFailure(4001, 'session not in memory')
    if not session['running']:
        record['status'] = 'not_interrupted'
        return {'status': 'not_interrupted', 'interrupted': False}
    session['turn'] += 1
    session['running'], session['inflight'], session['waiting'] = False, None, None
    opened = [REQUESTS[i] for i in session['open'] if i in REQUESTS]
    release = RELEASES.get(session['id'])
    record['status'] = 'interrupted'
    threading.Thread(target=after_interrupt, args=(session, opened, release), daemon=True).start()
    return {'status': 'interrupted', 'interrupted': True}


def after_interrupt(session, opened, release):
    for request in opened:
        settle(request, None, answered=False, cancel='interrupted')
    if release is not None:
        release.set()
    emit(session, 'message.complete', {'text': '', 'status': 'interrupted'})


def take(method, params):
    with LOCK:
        for item in G()['fail']:
            if item['method'] != method or item['count'] <= 0:
                continue
            if item.get('match') and item['match'] not in (params.get('profile'), params.get('name')):
                continue
            item['count'] -= 1
            return item['mode']
    return None


# ---- RPC ---------------------------------------------------------------------------------------------------------
_base_rpc = settings.rpc


def rpc(method, params):
    params = params if isinstance(params, dict) else {}
    state = S()
    g = state['groups']
    with LOCK:
        g['calls'].append(method)
        if len(g['calls']) > 20000:
            del g['calls'][:10000]
        latency = g['mode']['latency']
    if latency:
        time.sleep(latency / 1000.0)
    if method.startswith('groups.') or method.startswith('bot_relay.'):
        with LOCK:
            g['forbidden'].append({'method': method, 'params': copy.deepcopy(params), 'at': time.time()})
        raise RPCFailure(-32601, f'unknown method: {method}')
    allowed = STRICT.get(method)
    if allowed is not None:
        for key in params:
            if key not in allowed:
                with LOCK:
                    g['rejected'].append({'method': method, 'key': key, 'at': time.time()})
                raise RPCFailure(4000, f'invalid params for {method}: {key}: Extra inputs are not permitted')
    old = g['mode']['noRevisions']
    if old and method == 'profiles.configure' and 'ui_meta_expected_revisions' in params:
        with LOCK:
            g['rejected'].append({'method': method, 'key': 'ui_meta_expected_revisions', 'at': time.time()})
        raise RPCFailure(4000, 'invalid params for profiles.configure: ui_meta_expected_revisions: Extra inputs are not permitted')
    mode = take(method, params)
    if mode == 'drop':
        raise Drop()
    if mode == 'slow':
        time.sleep(35)
    elif mode == 'error':
        if method == 'profiles.configure':
            settings.record_write(method, params)
        raise RPCFailure(5000, 'fixture failure')
    elif mode == 'applied-false' and method == 'profiles.configure':
        settings.record_write(method, params)
        return {'ok': False, 'applied': {'ui_meta': False}}
    elif mode == 'conflict' and method == 'profiles.configure' and isinstance(params.get('ui_meta'), dict):
        with LOCK:
            if params.get('name') == 'default':
                other_writer(state, params['ui_meta'])
            elif params.get('name') in state['profiles']:
                p = state['profiles'][params['name']]
                for key in params['ui_meta']:
                    p['revisions'][key] = p['revisions'].get(key, 0) + 1

    if method == 'client.capabilities':
        return {'server_requests': ['approval', 'clarify'], 'declines_not_shown': True}
    if method == 'clarify.lock':
        request_id, question = str(params.get('request_id') or ''), str(params.get('question_id') or '')
        if not request_id or not question:
            raise RPCFailure(4002, 'request_id and question_id required')
        with LOCK:
            record = REQUESTS.get(request_id)
            if record is None or record['qids'] is None:
                return {'status': 'expired'}
            if question not in record['qids']:
                raise RPCFailure(4002, f'unknown question_id {question!r}')
            value = params.get('answer', '')
            record['locked'][question] = value if value is None or isinstance(value, str) else json.dumps(value, ensure_ascii=False)
            remaining = [q for q in record['qids'] if q not in record['locked']]
        if not remaining:
            settle(record, {'answers': dict(record['locked']), 'outcome': 'submitted'})
        return {'status': 'ok', 'remaining': remaining}
    if method == 'approval.respond':
        with LOCK:
            session, _ = session_for(params.get('session_id'))
            wanted = params.get('request_id')
            records = [r for r in REQUESTS.values() if r['method'] == 'approval'
                       and (session is None or r['session'] == session['id'])
                       and (not wanted or r['snapshot']['params'].get('request_id') == wanted)]
        resolved = sum(1 for r in records if settle(r, {'choice': params.get('choice') or 'deny'}, cancel='resolved'))
        return {'resolved': resolved}
    if method == 'session.create' and is_room_title(params.get('title')):
        with LOCK:
            settings.record_write(method, params)
            return create_session(params)
    if method in ('session.resume', 'session.activate'):
        identifier = params.get('session_id')
        with LOCK:
            session, how = session_for(identifier)
            if session is None and is_room_title(identifier):
                session, how = session_by_title(params.get('profile') or 'default', identifier), 'title'
                if session is None:
                    raise RPCFailure(4007, 'session not found')
            if session is not None:
                return resume_session(session, params, how)
            if settings.find_chat(identifier)[1] is None:
                raise RPCFailure(4007, 'session not found')
    if method == 'session.interrupt':
        with LOCK:
            answer = interrupt_session(params)
        if answer is not None:
            return answer
        with LOCK:
            known = settings.find_chat(params.get('session_id'))[1] is not None
            g['interrupts'][-1]['status'] = 'interrupted' if known else 'error 4001'
        if not known:
            raise RPCFailure(4001, 'session not in memory')
    result = _base_rpc(method, params)
    if old and isinstance(result, dict):
        if method == 'profiles.list':
            for row in result.get('profiles', []):
                row.pop('ui_meta_revisions', None)
        elif method == 'profiles.configure' and isinstance(result.get('applied'), dict):
            result['applied'].pop('ui_meta_revisions', None)
            result['applied'].pop('ui_meta_conflicts', None)
    return result


settings.rpc = rpc

_base_session_row = settings.session_row


def session_row(name, chat):
    row = _base_session_row(name, chat)
    if chat.get('hidden') is True:
        row['hidden'] = True
    return row


settings.session_row = session_row


# ---- WebSocket ---------------------------------------------------------------------------------------------------
class Client(settings.Client):
    def __init__(self, connection):
        super().__init__(connection)
        self.advertised = False

    def close(self):
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.connection.close()
        except OSError:
            pass

    def answer(self, frame):
        method, params = frame['method'], frame.get('params') or {}
        if method == 'client.capabilities':
            self.advertised = bool(isinstance(params, dict) and params.get('server_requests'))
        try:
            if method == 'prompt.submit' and isinstance(params, dict):
                with LOCK:
                    session, how = session_for(params.get('session_id'))
                if session is not None:
                    return self.room_prompt(frame, session, how, params)
                # An ordinary chat: the settings fixture's own answer, after the same checks every call gets.
                with LOCK:
                    G()['calls'].append(method)
                for key in params:
                    if key not in STRICT[method]:
                        return self.fail(frame, 4000, f'invalid params for {method}: {key}: Extra inputs are not permitted')
                mode = take(method, params)
                if mode == 'drop':
                    raise Drop()
                if mode == 'error':
                    return self.fail(frame, 5000, 'fixture failure')
            return super().answer(frame)
        except Drop:
            self.close()

    def fail(self, frame, code, message):
        try:
            self.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': code, 'message': message}})
        except OSError:
            pass

    def room_prompt(self, frame, session, how, params):
        with LOCK:
            g = G()
            g['calls'].append('prompt.submit')
            latency = g['mode']['latency']
        if latency:
            time.sleep(latency / 1000.0)
        for key in params:
            if key not in STRICT['prompt.submit']:
                return self.fail(frame, 4000, f'invalid params for prompt.submit: {key}: Extra inputs are not permitted')
        mode = take('prompt.submit', params)
        if mode == 'drop':
            raise Drop()
        if mode == 'slow':
            time.sleep(35)
        elif mode == 'error':
            return self.fail(frame, 5000, 'fixture failure')
        try:
            result = submit_prompt(session, how, params)
        except RPCFailure as failure:
            return self.fail(frame, failure.code, failure.message)
        try:
            self.send({'jsonrpc': '2.0', 'id': frame['id'], 'result': result})
        except OSError:
            pass


def route_response(frame):
    """The app's answer to a server request: a result settles it, an error leaves it unanswered."""
    with LOCK:
        record = REQUESTS.get(frame.get('id')) if isinstance(frame.get('id'), str) else None
    if record is None:
        return
    if isinstance(frame.get('error'), dict):
        if frame['error'].get('code') == 4404:
            return
        settle(record, None, answered=False)
        return
    result = frame.get('result') if isinstance(frame.get('result'), dict) else {}
    if record['qids'] is not None:
        merged = dict(record['locked'])
        merged.update(result.get('answers') or {})
        result = {'answers': merged, 'outcome': 'submitted' if 'answers' in result else 'cancelled'}
    settle(record, result)


def websocket(connection, key):
    """The settings fixture's loop, plus: answers to server requests, offline, and a socket that drops after n frames."""
    accept = settings.base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '
                        + accept + '\r\n\r\n').encode())
    client = Client(connection)

    def read(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data
    with LOCK:
        settings.CLIENTS.add(client)
        SOCKETS.add(client)
        offline = G()['mode']['offline']
    try:
        if offline:
            return
        client.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
            'heartbeat': True, 'change_events': True, 'replay_epoch': 'groups', 'desktop_contract': 8}}})
        fragments = bytearray()
        while True:
            first, second = read(2)
            opcode, length, final = first & 15, second & 127, bool(first & 128)
            if length == 126:
                length = struct.unpack('>H', read(2))[0]
            elif length == 127:
                length = struct.unpack('>Q', read(8))[0]
            if length > 16 * 1024 * 1024:
                raise ValueError('Oversized fixture frame')
            mask = read(4) if second & 128 else b'\0\0\0\0'
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(length)))
            if opcode == 8:
                return
            if opcode == 9:
                with client.lock:
                    connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 1:
                fragments = bytearray(payload)
            elif opcode == 0:
                fragments.extend(payload)
            else:
                continue
            if not final:
                continue
            frame = json.loads(fragments)
            fragments.clear()
            with LOCK:
                mode = G()['mode']
                if mode['dropSocketAfter'] is not None:
                    mode['dropSocketAfter'] -= 1
                    if mode['dropSocketAfter'] < 0:
                        mode['dropSocketAfter'] = None
                        return
            if 'id' in frame and 'method' not in frame:
                route_response(frame)
                continue
            if 'id' not in frame or 'method' not in frame:
                continue
            threading.Thread(target=client.answer, args=(frame,), daemon=True).start()
    except (ConnectionError, OSError, ValueError):
        return
    finally:
        with LOCK:
            settings.CLIENTS.discard(client)
            SOCKETS.discard(client)
        client.close()


voice.auth.websocket = websocket


# ---- controls ----------------------------------------------------------------------------------------------------
def snapshot():
    with LOCK:
        state = S()
        g = state['groups']
        envelope = envelope_of(state)
        rooms = {}
        if isinstance(envelope, dict) and isinstance(envelope.get('rooms'), dict):
            for key, room in envelope['rooms'].items():
                if not isinstance(room, dict):
                    rooms[key] = {'bad': True}
                    continue
                log = room.get('log') if isinstance(room.get('log'), list) else []
                rooms[key] = {'name': room.get('name'), 'roomId': room.get('roomId'), 'revision': room.get('revision'),
                              'omitted': room.get('omitted', 0), 'holdDetection': room.get('holdDetection'),
                              'members': [m.get('name') for m in room.get('members', []) if isinstance(m, dict)],
                              'memberRows': copy.deepcopy(room.get('members', [])),
                              'image': len(room['image']) if isinstance(room.get('image'), str) else 0, 'log': len(log),
                              'texts': [e.get('text') for e in log if isinstance(e, dict)],
                              'entries': copy.deepcopy(log)}
        profiles = {}
        for name in state['profiles']:
            meta = bots_meta(state, name)
            profiles[name] = {'groups': groups_of(state, name), 'group': meta.get('group'),
                              'revision': state['profiles'][name]['revisions'].get(BOTS, 0), 'title': meta.get('title'),
                              'hidden': meta.get('hidden') is True}
        sessions = [{'profile': s['profile'], 'stored': s['id'], 'runtime': runtime_of(s), 'title': s['title'], 'hidden': s['hidden'],
                     'room_plumbing': s['room_plumbing'], 'follow_profile_config': s['follow_profile_config'],
                     'plumbingOk': s['plumbingOk'], 'idempotency_key': s['idempotency_key'], 'creates': s['creates'],
                     'running': s['running'], 'waiting': s['waiting'], 'messages': len(s['messages']), 'stale': list(s['stale'])}
                    for s in g['sessions'].values()]
        default = state['profiles'].get('default')
        return {'calls': list(g['calls']), 'writes': state['writes'], 'sessions': sessions, 'prompts': g['prompts'],
                'interrupts': g['interrupts'], 'profiles': profiles, 'forbidden': g['forbidden'], 'rejected': g['rejected'],
                'mirror': {'revision': default['revisions'].get(MIRROR, 0) if default else 0,
                           'version': envelope.get('version') if isinstance(envelope, dict) else None,
                           'bytes': web_size(envelope) if envelope is not None else 0,
                           'pythonBytes': python_size(envelope) if envelope is not None else 0, 'rooms': rooms,
                           'deleted': envelope.get('deleted', {}) if isinstance(envelope, dict) else {},
                           'extra': {k: v for k, v in envelope.items() if k not in ('version', 'updatedAt', 'rooms', 'deleted')}
                           if isinstance(envelope, dict) else {}},
                'modes': dict(g['modes']), 'mode': dict(g['mode']), 'fail': list(g['fail']),
                'requests': [r['snapshot'] for r in REQUESTS.values()]}


def set_mode(body):
    with LOCK:
        g = G()
        mode = g['mode']
        closing = []
        if 'offline' in body:
            mode['offline'] = bool(body['offline'])
            if mode['offline']:
                closing = list(SOCKETS)
        if 'latency' in body:
            mode['latency'] = max(0, int(body['latency'] or 0))
        if 'dropSocketAfter' in body:
            mode['dropSocketAfter'] = None if body['dropSocketAfter'] is None else max(0, int(body['dropSocketAfter']))
        if 'rotateRuntime' in body:
            mode['rotateRuntime'] = bool(body['rotateRuntime'])
            if mode['rotateRuntime']:
                g['rotate'] += 1
        if 'noRevisions' in body:
            mode['noRevisions'] = bool(body['noRevisions'])
    for client in closing:
        client.close()
    return dict(mode)


def reset():
    with LOCK:
        for event in RELEASES.values():
            event.set()
        RELEASES.clear()
        pending = list(REQUESTS.values())
        REQUESTS.clear()
        settings.S = seed()
        MEMO_LEDGER.update({'uploads': [], 'transcribes': 0, 'downloads': 0})
        MEMO_CONTROL.update({'uploadStatus': 0})
    for record in pending:
        record['event'].set()


def control(path, body):
    """(status, answer) for one POST under /__groups/."""
    if path == '/__groups/reset':
        reset()
        return 200, {'ok': True}
    if path == '/__groups/mode':
        return 200, {'ok': True, 'mode': set_mode(body)}
    if path == '/__groups/memo':
        with LOCK:
            MEMO_CONTROL['uploadStatus'] = int(body.get('uploadStatus') or 0)
        return 200, {'ok': True, **MEMO_CONTROL}
    with LOCK:
        state = S()
        g = state['groups']
        if path == '/__groups/turn-mode':
            if not body:
                g['modes'].clear()
            for name, mode in body.items():
                if mode in (None, '', 'reply'):
                    g['modes'].pop(name, None)
                else:
                    g['modes'][name] = str(mode)
                    for session in g['sessions'].values():
                        if session['profile'] == name:
                            session['gone'] = False
            return 200, {'ok': True, 'modes': dict(g['modes'])}
        if path == '/__groups/release':
            released = 0
            for session in g['sessions'].values():
                if body.get('profile') in (None, session['profile']) and session['waiting'] and session['id'] in RELEASES:
                    RELEASES[session['id']].set()
                    released += 1
            return 200, {'ok': True, 'released': released}
        if path == '/__groups/fail':
            g['fail'].append({'method': body.get('method'), 'match': body.get('match'), 'mode': body.get('mode', 'error'),
                              'count': int(body.get('count', 1))})
            return 200, {'ok': True}
        if path == '/__groups/desktop-edit':
            answer = desktop_edit(state, body)
            return (200, answer) if answer else (400, {'detail': 'unknown op, room or bot'})
        if path == '/__groups/seed':
            return (200, {'ok': True}) if apply_preset(state, body) else (400, {'detail': 'unknown preset or case'})
    return 404, {'detail': 'unknown control'}


_base_handler = settings.handler

# ---- voice memos in a room (tester 2026-11-05): the files folder, the upload, the transcript, the download ------------
import tempfile
FILES_ROOT = pathlib.Path(tempfile.mkdtemp(prefix='hqn-groups-files-')).resolve()
MEMO_LEDGER = {'uploads': [], 'transcribes': 0, 'downloads': 0}
MEMO_CONTROL = {'uploadStatus': 0}   # POST /__groups/memo {"uploadStatus": 500} fails every upload until set back to 0
MEMO_TRANSCRIPT = 'Synthetic transcript of a group memo.'


def memo_upload(raw, content_type):
    """(status, answer) for POST /api/files/upload-stream: a multipart `path` + `file` under FILES_ROOT."""
    from email.parser import BytesParser
    from email.policy import default as email_policy
    message = BytesParser(policy=email_policy).parsebytes(('Content-Type: ' + content_type + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + raw)
    fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True) for part in message.iter_parts()}
    target = (fields.get('path') or b'').decode()
    data = fields.get('file') or b''
    resolved = pathlib.Path(target).resolve() if target else None
    if not resolved or not str(resolved).startswith(str(FILES_ROOT) + os.sep) or not data:
        return 400, {'detail': 'Invalid synthetic upload'}
    resolved.parent.mkdir(parents=True, exist_ok=True)
    resolved.write_bytes(data)
    with LOCK:
        MEMO_LEDGER['uploads'].append({'path': str(resolved), 'bytes': len(data)})
    return 200, {'ok': True, 'path': str(resolved)}


def handler(gateway):
    base = _base_handler(gateway)

    class Handler(base):
        def gate(self):
            """False when the request was answered here (offline) and must go no further."""
            path = urlparse(self.path).path
            if path.startswith('/__'):
                return True
            with LOCK:
                mode = dict(G()['mode'])
            if mode['offline']:
                self.reply(503, {'detail': 'offline'})
                return False
            if mode['latency'] and path.startswith('/api/') and path != '/api/ws':
                time.sleep(mode['latency'] / 1000.0)
            return True

        def raw_body(self):
            return self.rfile.read(int(self.headers.get('Content-Length') or 0))

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__groups/state':
                return self.reply(200, snapshot())
            if path == '/__groups/memos':
                with LOCK:
                    return self.reply(200, json.loads(json.dumps(MEMO_LEDGER)))
            if not self.gate():
                return
            if path == '/api/files':
                return self.reply(200, {'path': str(FILES_ROOT), 'parent': None, 'entries': []})
            if path == '/api/fs/download':
                from urllib.parse import parse_qs
                target = pathlib.Path((parse_qs(urlparse(self.path).query).get('path') or [''])[0]).resolve()
                if not str(target).startswith(str(FILES_ROOT) + os.sep) or not target.is_file():
                    return self.reply(404, {'detail': 'Not found'})
                data = target.read_bytes()
                with LOCK:
                    MEMO_LEDGER['downloads'] += 1
                self.send_response(200)
                self.send_header('Content-Type', 'audio/wav' if target.suffix == '.wav' else 'audio/mp4')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path.startswith('/__groups/'):
                status, answer = control(path, self.body())
                return self.reply(status, answer)
            if not self.gate():
                return
            if path == '/api/files/upload-stream':
                raw = self.raw_body()
                with LOCK:
                    failing = MEMO_CONTROL['uploadStatus']
                if failing:
                    return self.reply(failing, {'detail': 'Synthetic upload failure'})
                status, answer = memo_upload(raw, self.headers.get('Content-Type', ''))
                return self.reply(status, answer)
            if path == '/api/audio/transcribe':
                self.raw_body()
                with LOCK:
                    MEMO_LEDGER['transcribes'] += 1
                return self.reply(200, {'ok': True, 'transcript': MEMO_TRANSCRIPT})
            return super().do_POST()

        def do_PUT(self):
            if self.gate():
                return super().do_PUT()

        def do_DELETE(self):
            if self.gate():
                return super().do_DELETE()

    return Handler


# ---- self-test (no port) -----------------------------------------------------------------------------------------
def self_test():
    gp.self_test()
    settings.S = seed()

    def code(call):
        try:
            call()
        except RPCFailure as failure:
            return failure.code
        return None

    # The seed: 8 bots, Launch Room on three of them, the mirror at revision 4, deliveries on the default bot's chat.
    state = snapshot()
    assert list(S()['profiles']) == ORDER, list(S()['profiles'])
    assert [n for n, p in state['profiles'].items() if p['groups'] == ['Launch Room']] == ['default', 'ivy', 'research']
    assert state['mirror']['revision'] == 4 and state['mirror']['version'] == 3
    room = state['mirror']['rooms']['id:rmfixture-launch']
    assert room['log'] == 6 and room['texts'][-1] == 'I can take the notes.' and room['omitted'] == 0
    assert state['mirror']['pythonBytes'] == python_size(envelope_of(S())) and state['mirror']['bytes'] >= state['mirror']['pythonBytes'] - 8
    texts = [m['content'] for m in S()['profiles']['default']['chat']['messages']]
    assert texts[-2] == 'Message from Billing Bot: Invoice sent.' and texts[-4].startswith("[Message from agent 'research']")
    assert texts[-1] == texts[-3] == '[SILENT]'
    assert not any('Message from' in m['content'] for m in S()['profiles']['ivy']['chat']['messages'])
    assert 'sectionId' not in bots_meta(S(), 'ivy')

    # Compare-and-swap on the mirror key: a stale revision is a conflict, the right one lands at revision + 1.
    envelope = copy.deepcopy(envelope_of(S()))
    envelope['updatedAt'] = now_ms()
    stale = rpc('profiles.configure', {'name': 'default', 'ui_meta': {MIRROR: envelope}, 'ui_meta_expected_revisions': {MIRROR: 3}})
    assert stale['applied']['ui_meta'] is False and stale['applied']['ui_meta_conflicts'][MIRROR] == {'expected': 3, 'actual': 4}, stale
    good = rpc('profiles.configure', {'name': 'default', 'ui_meta': {MIRROR: envelope}, 'ui_meta_expected_revisions': {MIRROR: 4}})
    assert good['applied'] == {'ui_meta': True, 'ui_meta_revisions': {MIRROR: 5}}, good
    assert code(lambda: rpc('profiles.configure', {'name': 'default', 'ui_meta': {}, 'nope': 1})) == 4000
    # `fail … conflict`: another writer's entry lands first, the app's write is refused, the entry is there.
    control('/__groups/fail', {'method': 'profiles.configure', 'mode': 'conflict', 'count': 1})
    lost = rpc('profiles.configure', {'name': 'default', 'ui_meta': {MIRROR: envelope}, 'ui_meta_expected_revisions': {MIRROR: 5}})
    assert lost['applied']['ui_meta'] is False and lost['applied']['ui_meta_revisions'][MIRROR] == 6, lost
    assert snapshot()['mirror']['rooms']['id:rmfixture-launch']['texts'][-1] == 'From the desktop (1)'
    control('/__groups/fail', {'method': 'profiles.configure', 'mode': 'applied-false', 'count': 1})
    assert rpc('profiles.configure', {'name': 'default', 'ui_meta': {MIRROR: envelope}})['applied'] == {'ui_meta': False}

    # session.create: strict keys, idempotent by key, a runtime id that is not the stored id.
    title = 'Group: rmfixture-launch · tself-one'
    make = {'profile': 'ivy', 'title': title, 'hidden': True, 'room_plumbing': True, 'follow_profile_config': True, 'idempotency_key': 'k-1'}
    assert code(lambda: rpc('session.resume', {'session_id': title, 'profile': 'ivy', 'omit_messages': True})) == 4007
    first = rpc('session.create', make)
    again = rpc('session.create', make)
    other = rpc('session.create', dict(make, idempotency_key='k-2', title='Group: rmfixture-launch · tself-two'))
    assert first['session_id'] == again['session_id'] and first['stored_session_id'] == again['stored_session_id']
    assert first['stored_session_id'] != other['stored_session_id'] and first['session_id'] != first['stored_session_id']
    assert code(lambda: rpc('session.create', dict(make, room=True))) == 4000
    loose = rpc('session.create', {'profile': 'ivy', 'title': 'Group: rmfixture-launch · tself-three', 'idempotency_key': 'k-3'})
    rows = {s['stored']: s for s in snapshot()['sessions']}
    assert rows[first['stored_session_id']]['plumbingOk'] and rows[first['stored_session_id']]['creates'] == 2
    assert not rows[loose['stored_session_id']]['plumbingOk']
    stored, runtime = first['stored_session_id'], first['session_id']

    # session.resume: by stored id and by exact title; unknown is 4007; omit_messages is honoured.
    by_title = rpc('session.resume', {'session_id': title, 'profile': 'ivy', 'omit_messages': True})
    assert by_title['session_id'] == runtime and by_title['stored_session_id'] == stored and by_title['messages'] == []
    assert code(lambda: rpc('session.resume', {'session_id': title, 'profile': 'research'})) == 4007
    assert code(lambda: rpc('session.resume', {'session_id': '20990101_000000_nothere'})) == 4007
    assert code(lambda: rpc('session.resume', {'session_id': stored, 'bogus': 1})) == 4000

    # prompt.submit: the template, by runtime id only.
    session = G()['sessions'][stored]
    seats = seats_for(S(), 'Launch Room')
    assert [s['tag'] for s in seats] == ['hermes', 'ivy', 'research'], seats
    ivy = next(s for s in seats if s['name'] == 'ivy')
    prompt = gp.build('Launch Room', seats, ivy, ['You (user): Who can take the release notes for the next build please?'])
    assert code(lambda: submit_prompt(session, 'stored', {'session_id': stored, 'text': prompt})) == 4001
    control('/__groups/turn-mode', {'ivy': 'hang'})
    assert submit_prompt(session, 'runtime', {'session_id': runtime, 'text': prompt})['status'] == 'streaming'
    assert snapshot()['prompts'][-1]['promptOk'] is True and snapshot()['prompts'][-1]['inFlightForRoom'] == 0
    busy = rpc('session.resume', {'session_id': stored, 'profile': 'ivy'})
    assert busy['running'] is True and busy['inflight'] and busy['messages'][-1]['role'] == 'user'

    # session.interrupt: a stored id is refused, the runtime id stops the turn, a second one finds nothing running.
    assert code(lambda: rpc('session.interrupt', {'session_id': stored, 'profile': 'ivy'})) == 4001
    assert code(lambda: rpc('session.interrupt', {'session_id': runtime, 'profile': 'ivy', 'force': True})) == 4000
    assert rpc('session.interrupt', {'session_id': runtime, 'profile': 'ivy'})['status'] == 'interrupted'
    assert rpc('session.interrupt', {'session_id': runtime, 'profile': 'ivy'})['status'] == 'not_interrupted'
    logged = snapshot()['interrupts']
    assert [(i['by'], i['status']) for i in logged] == [('stored', 'error 4001'), ('runtime', 'interrupted'), ('runtime', 'not_interrupted')], logged
    idle = rpc('session.resume', {'session_id': stored, 'profile': 'ivy'})
    assert idle['running'] is False and idle['inflight'] is None and [m['role'] for m in idle['messages']] == ['user']

    # A reply, and a reworded prompt.
    control('/__groups/turn-mode', {})
    submit_prompt(session, 'runtime', {'session_id': runtime, 'text': prompt.replace('Passing is good', 'Passing is fine')})
    assert snapshot()['prompts'][-1]['promptOk'] is False
    deadline = time.time() + 5
    while time.time() < deadline and G()['sessions'][stored]['running']:
        time.sleep(0.05)
    done = rpc('session.resume', {'session_id': stored, 'profile': 'ivy'})
    assert done['messages'][-1] == {'role': 'assistant', 'content': 'Ivy here: Who can take the release notes for the n',
                                    'timestamp': done['messages'][-1]['timestamp']}, done['messages'][-1]

    # A reconnect: the stored id answers a new runtime id, and the old one is no longer live.
    control('/__groups/mode', {'rotateRuntime': True})
    rotated = rpc('session.resume', {'session_id': stored, 'profile': 'ivy', 'omit_messages': True})
    assert rotated['session_id'] != runtime
    assert rpc('session.resume', {'session_id': stored, 'profile': 'ivy', 'omit_messages': True})['session_id'] == rotated['session_id']
    assert code(lambda: rpc('session.interrupt', {'session_id': runtime, 'profile': 'ivy'})) == 4001

    # The app never calls the hosted-room methods.
    assert code(lambda: rpc('groups.list', {})) == -32601 and code(lambda: rpc('bot_relay.send', {})) == -32601
    assert [f['method'] for f in snapshot()['forbidden']] == ['groups.list', 'bot_relay.send']

    # An old gateway: no revisions on rows, and the expected-revisions parameter is unknown.
    control('/__groups/mode', {'noRevisions': True})
    assert all('ui_meta_revisions' not in row for row in rpc('profiles.list', {'include_sessions': False})['profiles'])
    assert code(lambda: rpc('profiles.configure', {'name': 'default', 'ui_meta': {MIRROR: envelope}, 'ui_meta_expected_revisions': {MIRROR: 1}})) == 4000
    assert rpc('profiles.configure', {'name': 'default', 'ui_meta': {MIRROR: envelope}})['applied'] == {'ui_meta': True}

    # Presets and another device's edits stay inside the size cap.
    reset()
    assert snapshot()['prompts'] == [] and snapshot()['mirror']['revision'] == 4
    for body in ({'preset': 'standup'}, {'preset': 'full'}, {'preset': 'other-gateway'}, {'preset': 'section'}, {'preset': 'cap'},
                 {'preset': 'emoji'}, {'preset': 'load', 'rooms': 40, 'messages': 400}):
        assert control('/__groups/seed', body)[0] == 200, body
        assert snapshot()['mirror']['pythonBytes'] <= SYNC_BYTES, (body, snapshot()['mirror']['pythonBytes'])
    assert snapshot()['profiles']['inbox']['groups'][0] == 'Standup'
    for case in ('not-an-object', 'rooms-array', 'log-not-array', 'member-missing-name', 'text-number', 'at-string', 'huge-image',
                 'unknown-keys', 'duplicate-ids', 'tombstone-for-live-room'):
        reset()
        assert control('/__groups/seed', {'preset': 'malformed', 'case': case})[0] == 200, case
        snapshot()
    for preset in ('v1', 'v2', 'no-id', 'one-bot'):
        reset()
        assert control('/__groups/seed', {'preset': preset})[0] == 200, preset
    assert list(S()['profiles']) == ['default', 'deploys']
    reset()
    assert control('/__groups/desktop-edit', {'op': 'append', 'room': 'Launch Room', 'from': 'research', 'text': 'x' * 2000})[0] == 200
    last = envelope_of(S())['rooms']['id:rmfixture-launch']['log'][-1]
    assert len(last['text']) == SYNC_TEXT and last['text'].endswith(TRUNCATED) and last['truncated'] is True
    assert control('/__groups/desktop-edit', {'op': 'rename', 'room': 'Launch Room', 'to': 'Release Room'})[0] == 200
    assert snapshot()['profiles']['ivy']['groups'] == ['Release Room'] and snapshot()['profiles']['ivy']['group'] == 'Release Room'
    assert control('/__groups/desktop-edit', {'op': 'members', 'room': 'Release Room', 'members': ['ivy', 'inbox']})[0] == 200
    assert snapshot()['mirror']['rooms']['id:rmfixture-launch']['members'] == ['ivy', 'inbox']
    assert snapshot()['profiles']['default']['groups'] == []
    assert control('/__groups/desktop-edit', {'op': 'delete', 'room': 'Release Room'})[0] == 200
    after = snapshot()
    assert after['mirror']['rooms'] == {} and 'id:rmfixture-launch' in after['mirror']['deleted'] and after['profiles']['ivy']['groups'] == []
    assert control('/__groups/desktop-edit', {'op': 'remove-bot', 'name': 'research'})[0] == 200 and 'research' not in S()['profiles']
    assert control('/__groups/desktop-edit', {'op': 'nothing'})[0] == 400

    # The load seed of the stress plan.
    OPTIONS['load'] = (40, 400)
    reset()
    loaded = snapshot()['mirror']
    assert len(loaded['rooms']) >= 30 and loaded['pythonBytes'] <= SYNC_BYTES, (len(loaded['rooms']), loaded['pythonBytes'])
    OPTIONS['load'] = None
    reset()

    # `once`: the first turn of a thread's session answers, the next one passes.
    control('/__groups/turn-mode', {'ops': 'once:On it.'})
    made = rpc('session.create', {'profile': 'ops', 'title': 'Group: rmfixture-launch · tself-once', 'hidden': True,
                                  'room_plumbing': True, 'follow_profile_config': True, 'idempotency_key': 'k-once'})
    once = G()['sessions'][made['stored_session_id']]
    for expected in ('On it.', '(pass)'):
        submit_prompt(once, 'runtime', {'session_id': made['session_id'], 'text': 'hello'})
        deadline = time.time() + 5
        while once['running'] and time.time() < deadline:
            time.sleep(0.05)
        assert once['messages'][-1]['content'] == expected, once['messages'][-1]
    reset()
    print('groups-gateway self-test: ok')


def port_is_free(port):
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind(('127.0.0.1', port))
        return True
    except OSError:
        return False
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--self-test', action='store_true', help='check the fixture itself; opens no port')
    parser.add_argument('--port', type=int)
    parser.add_argument('--credentials')
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--label', default='', help="prefix this gateway's bot names and descriptions")
    parser.add_argument('--hermes-cookies', action='store_true', help="Hermes' hermes_session_at/rt session, renewed on any API read")
    parser.add_argument('--access-ttl', type=int, default=12 * 60 * 60)
    parser.add_argument('--bots', type=int, default=8, help='how many seed bots')
    parser.add_argument('--no-rooms', action='store_true', help='no seeded room and no groups on any bot')
    parser.add_argument('--no-revisions', action='store_true', help='an old gateway: no ui_meta revisions, no compare-and-swap')
    parser.add_argument('--load', default=None, metavar='ROOMS,MESSAGES', help='seed that many rooms with that many log entries each')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.port is None or not args.credentials:
        parser.error('--port and --credentials are required')
    OPTIONS['bots'] = args.bots
    OPTIONS['rooms'] = not args.no_rooms
    OPTIONS['revisions'] = not args.no_revisions
    if args.load:
        rooms, _, messages = args.load.partition(',')
        OPTIONS['load'] = (int(rooms), int(messages or 16))
    if not port_is_free(args.port):
        sys.exit(f'Port {args.port} is busy: not starting.')
    settings.LABEL = args.label
    voice.LABEL = args.label
    voice.ACCEPT_PROMPTS = True
    settings.S = seed()
    username, password = 'groups-fixture', secrets.token_urlsafe(24)
    if args.keep_credentials and pathlib.Path(args.credentials).exists():
        kept = json.loads(pathlib.Path(args.credentials).read_text())
        username, password = kept['username'], kept['password']
    pathlib.Path(args.credentials).parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{args.port}'}, output)
    gateway = voice.auth.Gateway(username, password, True, None, hermes=args.hermes_cookies, access_ttl=args.access_ttl)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(gateway))
    print(f'Groups fixture on 127.0.0.1:{args.port}' + (f' ({args.label})' if args.label else ''), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
