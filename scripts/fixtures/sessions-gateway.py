#!/usr/bin/env python3
"""A stateful stand-in gateway for the native Sessions tab's row actions and search (docs/parity-240.md §4).

Stdlib only. It loads the reference repo's action-voice fixture ($HQN_REF/scripts/action-voice-fixture-gateway.py)
for the password sign-in, the ws-ticket and the WebSocket JSON-RPC base, and overrides `rpc`, `websocket` and the
REST handler. Everything it serves is invented. It binds 127.0.0.1 only and has no network client.

  python3 scripts/fixtures/sessions-gateway.py --port 9820 --credentials build/fixtures/sessions.json

Served: the roster (profiles.list), the Sessions sidebar, the Archived view (GET /api/profiles/sessions?archived=only),
the session row and its messages, full-text search (GET /api/sessions/search?q=…&profile=…, all words, >>>marks<<<),
PATCH /api/sessions/{id} (pinned, archived, unread, title), DELETE /api/sessions/{id}, and the RPCs projects.tree,
projects.create, session.workspace.move, session.branch_stored, session.resume, session.title.

Test hooks (no auth):
  GET  /__fixture/state   {"rest":[{method,path,query,body}],"rpc":[{method,params}]}  (every write, in order)
  POST /__fixture/fail    {"method","path","status","detail","count"} or {"method","path","delay","count"}: the next match(es) fail/wait
                          ("prefix":true matches every path that starts with "path"); for an RPC:
                          {"rpc":"projects.create","message":"boom","code":-32001,"count":1}, {"rpc":…,"delay":5},
                          {"rpc":"prompt.submit","drop":true} (the socket closes without an answer: a lost send)
  POST /__fixture/reset   forget the logs, failures, modes and counters, re-seed every session

Filter & Sort, chips, Session Info and the reconnect probe (docs/spec/3x-sessions.md §12.1):
  POST /__fixture/rows    {"id":"s-tg","set":{…}} creates or patches a chat (any row field, "usage", "messages", "raw";
                          "user_id":"basic:fleet" stamps it with the old password sign-in, so edits answer 403
                          permission_denied as Hermes does);
                          {"id":…,"delete":true}; "event":true also broadcasts sessions.changed
  POST /__fixture/emit    {"type":"session.usage","session_id":"s-trip","payload":{…}} sends that event to every socket
                          (a stored id is mapped to its runtime id); {"request":{"method":"approval","params":{…}},
                          "session_id":"s-garden"} sends a server request ({"ok":true,"id":"srq_1"})
  POST /__fixture/mode    {"oldGateway":true} (the sidebar route 404s; projects.* and session.usage answer -32601),
                          {"badRows":true} (odd rows ride along in the sidebar), {"sidebarDelay":4},
                          {"sidebarHold":true} (every sidebar read waits, unanswered, until {"sidebarHold":false}),
                          {"projectsHold":true} (the same for projects.tree; other calls on the socket go on),
                          {"prompts":"hold"|"reply"|"reject"} (a prompt starts a turn that never ends | is answered |
                          is refused, the default), {"bots":40} (the roster grows to that many bots; 1 leaves Hermes alone),
                          {"projects":"empty"|"odd"|"null"|"many"|"long"} (projects.tree answers), {"usage":{…}} (every session.usage),
                          {"down":8} (as a stopped gateway for that many seconds: sockets close, every request is
                          cut off unanswered; the test hooks still answer)
                          {"working":["s-trip"]} (the add-on's sessions/working names those chats: a turn another
                          process runs; serve/working answers 503 as outside the serving process)
  POST /__fixture/drop    closes every WebSocket
  POST /__fixture/burst   {"count":200,"interval":0.02} sessions.changed events
  GET  /__fixture/stats   {"sidebar":{"probe":n,"top":n,"full":n,"deep":n},"burst":n}  (recents_limit 1 / 2-49 / 50 / 300),
                          "held":{"sidebar":n,"projects":n} (reads waiting on a hold right now)
  --seed big              2,000 chats over 12 bots and 40 projects, 30 pinned, 200 unread, 60 archived (fixed random seed)
"""
import argparse, base64, copy, hashlib, importlib.util, json, os, pathlib, random, socket, struct, sys, threading, time
from urllib.parse import urlparse, parse_qs, unquote

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
_spec = importlib.util.spec_from_file_location('fx', REF / 'scripts/action-voice-fixture-gateway.py')
fx = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(fx)

HOME = '/home/hermes'
lock = threading.RLock()
state = {'rest': [], 'rpc': []}
fails = []
sockets = set()
connections = set()
rpc_fails = []
stats = {'sidebar': {'probe': 0, 'top': 0, 'full': 0, 'deep': 0}, 'held': {'sidebar': 0, 'projects': 0}, 'burst': 0}

def hold(key, kind):
    """Waits while MODE[key] is on (a test releases it, or a reset does), counted in stats['held'][kind]."""
    if not MODE.get(key): return
    with lock: stats['held'][kind] += 1
    try:
        while MODE.get(key): time.sleep(0.05)
    finally:
        with lock: stats['held'][kind] -= 1
MODE = {}
# Hermes 0.22.3's revision fence on session edits (--unfenced: as 0.22.2). refused/accepted count edits.
FENCE = {'on': True, 'refused': 0, 'accepted': 0, 'receipts': {}}
SEED = 'default'
SERVER_REQUESTS = [0]
MESSAGING = {'telegram', 'discord', 'slack', 'whatsapp', 'signal', 'matrix', 'mattermost', 'email', 'sms', 'imessage', 'teams'}
DEFAULT_USAGE = {'input': 14200, 'output': 1200, 'total': 15400, 'calls': 9, 'context_used': 48200, 'context_max': 200000,
                 'context_percent': 24, 'context_estimated': False, 'cost_usd': None, 'prompt': 14200,
                 'avg_tps': 64.2, 'avg_latency_s': 1.6}
ALLOWED = {'session.usage': {'session_id', 'profile'},
           'projects.tree': {'preview_limit', 'session_limit', 'profile'},
           'projects.create': {'name', 'folders', 'slug', 'primary_path', 'description', 'icon', 'color', 'board_slug', 'use', 'profile'},
           'projects.update': {'id', 'name', 'description', 'icon', 'color', 'board_slug', 'profile'},
           'projects.delete': {'id', 'profile'},
           'session.workspace.move': {'cwd', 'session_key', 'profile'}}
ROW_KEYS = ('input_tokens', 'output_tokens', 'actual_cost_usd', 'estimated_cost_usd', 'git_branch', 'handoff_platform')


class Fault(Exception):
    """A Hermes error answer with its own code: {"error": {"code", "message"}}."""
    def __init__(self, code, message):
        super().__init__(message); self.code = code; self.message = message


class Drop(Exception):
    """Close the socket without answering."""

DEFAULT_BOTS = [('default', 'Hermes', 'Your right hand'), ('research', 'Research', 'Reading and summaries'),
                ('deploys', 'Deploys', 'Releases, builds and checks')]
MORE_BOTS = ['Atlas', 'Billing', 'Calendar', 'Design', 'Editor', 'Finance', 'Garden', 'Hiring', 'Inbox', 'Journal', 'Kitchen',
             'Legal', 'Music', 'Notes', 'Orders', 'Press', 'Quality', 'Recruit', 'Support', 'Travel', 'Updates', 'Vendors',
             'Writing', 'Yard', 'Zones', 'Audit', 'Backups', 'Clients', 'Docs', 'Events', 'Fleet', 'Grants', 'Homework',
             'Insights', 'Jobs', 'Kits', 'Leads']
BOTS = list(DEFAULT_BOTS)
BOT_NAMES = {name: title for name, title, _ in BOTS}

def set_bots(count):
    """The roster: the three default bots (fewer when `count` is 1 or 2), then invented ones up to `count`."""
    BOTS[:] = DEFAULT_BOTS[:max(1, count)] + [(name.lower(), name, f'{name} helper') for name in MORE_BOTS[:max(0, count - len(DEFAULT_BOTS))]]
    BOT_NAMES.clear(); BOT_NAMES.update({name: title for name, title, _ in BOTS})
    for name, title, _ in BOTS:
        if bot_chat_id(name) not in SESSIONS:
            add_session(bot_chat_id(name), name, 'Bot Chat', [
                {'role': 'user', 'content': 'Morning. Anything for me?'},
                {'role': 'assistant', 'content': f'Morning. {title} here: nothing urgent today.'}], int(now()) - 7200, hidden=True)
PROJECTS = {}     # profile → [project]
SESSIONS = {}     # id → session

def now(): return time.time()
def runtime(sid): return hashlib.sha256(sid.encode()).hexdigest()[:8]
def bot_chat_id(profile): return f'20261009_090000_bc{hashlib.sha256(profile.encode()).hexdigest()[:6]}'

def add_session(sid, profile, title, messages, last_active, source='desktop', cwd=f'{HOME}/app', hidden=False,
                pinned=False, archived=False, unread=False, **more):
    for index, message in enumerate(messages):
        message.setdefault('id', index + 1)
        message.setdefault('timestamp', last_active - (len(messages) - index) * 5)
    SESSIONS[sid] = {'id': sid, 'profile': profile, 'title': title, 'messages': messages, 'last_active': last_active,
                     'started_at': last_active - 600, 'source': source, 'cwd': cwd, 'hidden': hidden, 'pinned': pinned,
                     'archived': archived, 'unread': unread, 'parent': None, **more}

def session_row(sid):
    s = SESSIONS[sid]
    last = next((m for m in reversed(s['messages']) if m['role'] == 'assistant' and isinstance(m.get('content'), str)), None)
    preview = (last['content'] if last else '').split('\n')[0][:140]
    row = {'id': sid, 'title': s['title'], 'preview': s.get('preview', preview), 'profile': s['profile'], 'profile_name': s['profile'],
           'is_default_profile': s['profile'] == 'default', 'hidden': s['hidden'], 'pinned': s['pinned'], 'unread': s['unread'],
           'archived': s['archived'], 'model': s.get('model', 'hermes-4'), 'billing_provider': 'nous', 'source': s['source'],
           'message_count': s.get('message_count', len(s['messages'])), 'started_at': s['started_at'], 'last_active': s['last_active'],
           'ended_at': None, 'is_active': bool(s.get('is_active', False)), 'cwd': s['cwd'], 'parent_session_id': s['parent'],
           'tool_call_count': s.get('tool_call_count', sum(1 for m in s['messages'] if m.get('role') == 'tool')),
           'input_tokens': s.get('input_tokens', 0), 'output_tokens': s.get('output_tokens', 0),
           'actual_cost_usd': s.get('actual_cost_usd'), 'estimated_cost_usd': s.get('estimated_cost_usd'),
           'git_branch': s.get('git_branch'), 'handoff_platform': s.get('handoff_platform'), 'user_id': s.get('user_id')}
    row.update(s.get('raw') or {})          # /__fixture/rows "raw": any key as given (bad-data checks)
    return row

def usage_of(sid):
    if 'usage' in MODE: return copy.deepcopy(MODE['usage'])
    s = SESSIONS[sid]
    return copy.deepcopy(s['usage'] if 'usage' in s else DEFAULT_USAGE)

# session.create mints a live session; its row appears with the first prompt (tui_gateway contracts/sessions.py). Until then
# it is in neither the lists nor the REST reads, and a resume answers from the live session alone.
PENDING = {}
def pending_sid(asked):
    for sid in PENDING:
        if asked in (sid, runtime(sid)): return sid
    return None

def find_session(asked):
    for sid in SESSIONS:
        if asked in (sid, runtime(sid)): return sid
    return None

def shape(color, form, seed=7):
    return {'v': 6, 'theme': 'shape', 'color': color, 'seed': seed, 'form': form, 'look': 'slits', 'specs': 'none',
            'hat': 'none', 'mouth': 'none', 'blush': False, 'tile': 'none'}

# [chats-under] The everyday list's bots as on a real phone: Shapes faces, Hermes and Inbox pinned, Work and Personal.
EVERYDAY_LOOK = {
    'default': ({'pinned': True, 'sectionId': 'hermes-hq-pinned', 'sectionName': 'Pinned', 'pinnedFrom': None}, shape('ink', 'round')),
    'inbox': ({'pinned': True, 'sectionId': 'hermes-hq-pinned', 'sectionName': 'Pinned', 'pinnedFrom': None}, shape('sky', 'blob', 1187)),
    'juno': ({'sectionId': 'sec-work', 'sectionName': 'Work'}, shape('denim', 'cloud')),
    'otto': ({'sectionId': 'sec-work', 'sectionName': 'Work'}, shape('coral', 'square')),
    'herald': ({'sectionId': 'sec-work', 'sectionName': 'Work'}, shape('grape', 'cloud', 9)),
    'app': ({'sectionId': 'sec-work', 'sectionName': 'Work'}, shape('cobalt', 'pill')),
    'finance': ({'sectionId': 'sec-personal', 'sectionName': 'Personal'}, shape('lilac', 'square', 3)),
    'home': ({'sectionId': 'sec-personal', 'sectionName': 'Personal'}, shape('peach', 'drop')),
    'research': ({'sectionId': 'sec-personal', 'sectionName': 'Personal'}, shape('grass', 'hex')),
}

# [chats-under] Generic bots for pictures that can be shared: nothing in them names a person or a business.
DEMO_LOOK = {
    'default': ({'pinned': True, 'sectionId': 'hermes-hq-pinned', 'sectionName': 'Pinned', 'pinnedFrom': None}, shape('ink', 'round')),
    'inbox': ({'pinned': True, 'sectionId': 'hermes-hq-pinned', 'sectionName': 'Pinned', 'pinnedFrom': None}, shape('sky', 'blob', 1187)),
    'research': ({'sectionId': 'sec-work', 'sectionName': 'Work'}, shape('denim', 'cloud')),
    'writer': ({'sectionId': 'sec-work', 'sectionName': 'Work'}, shape('coral', 'square')),
    'planner': ({'sectionId': 'sec-work', 'sectionName': 'Work'}, shape('grape', 'cloud', 9)),
    'travel': ({'sectionId': 'sec-personal', 'sectionName': 'Personal'}, shape('peach', 'drop')),
    'finance': ({'sectionId': 'sec-personal', 'sectionName': 'Personal'}, shape('lilac', 'square', 3)),
    'home': ({'sectionId': 'sec-personal', 'sectionName': 'Personal'}, shape('grass', 'hex')),
}

def seed_demo():
    """Generic bots and chats for screenshots to share: Hermes and Inbox pinned, Work and Personal sections."""
    BOTS[:] = [('default', 'Hermes', 'Your right hand'), ('inbox', 'Inbox', 'Mail'), ('research', 'Research', 'Reading'),
               ('writer', 'Writer', 'Drafts'), ('planner', 'Planner', 'Calendar'), ('travel', 'Travel', 'Trips'),
               ('finance', 'Finance', 'Money'), ('home', 'Home', 'The house')]
    BOT_NAMES.clear(); BOT_NAMES.update({name: title for name, title, _ in BOTS})
    for name, _, _ in BOTS:
        PROJECTS.setdefault(name, []).append({'id': 'home', 'label': 'Home', 'path': None, 'isNoProject': True, 'repos': [], 'sessionCount': 0})
    chats = [  # (bot, title, reply, hours ago, pinned, unread)
        ('research', 'Compare three note-taking apps', 'Here is a side-by-side of all three.', 0.3, False, True),
        ('writer', 'Draft the weekly newsletter', 'The draft is ready for a read.', 0.8, False, False),
        ('planner', 'Plan next week', 'Five focus blocks and two calls.', 1.2, True, False),
        ('research', 'Summarize the article I sent', 'Three key points and one open question.', 3, False, False),
        ('writer', 'Rewrite the welcome email', 'Shorter and friendlier, two versions.', 5, True, False),
        ('travel', 'Weekend trip ideas', 'Three towns within two hours.', 6, False, True),
        ('finance', 'Monthly budget check', 'You are under budget in four categories.', 9, True, False),
        ('home', 'Spring cleaning checklist', 'A room-by-room list.', 20, False, False),
        ('planner', 'Find a time for the team sync', 'Tuesday at 10 works for everyone.', 22, False, False),
        ('research', 'Best desk chairs under $400', 'Four picks with pros and cons.', 26, False, False),
        ('writer', 'Blog post outline', 'An outline with five sections.', 30, False, False),
        ('travel', 'Pack for a beach weekend', 'A short packing list.', 44, False, False),
        ('finance', 'Track subscriptions', 'Six subscriptions, two unused.', 50, False, False),
        ('home', 'Garden watering schedule', 'Every other morning until June.', 70, False, False),
        ('planner', 'Quarterly goals', 'Three goals with milestones.', 90, False, False),
        ('research', 'Learn the basics of sourdough', 'A starter guide in five steps.', 110, False, False),
        ('writer', 'Social post ideas', 'Ten short ideas.', 130, False, False),
        ('travel', 'Train vs. car for the holidays', 'The train saves two hours.', 150, False, False),
        ('finance', 'Savings goal for the summer', '$150 a week gets you there.', 170, False, False),
        ('home', 'Find a plumber', 'Three options nearby with reviews.', 200, False, False),
        ('planner', 'Review last month', 'What went well and what to change.', 230, False, False),
        ('writer', 'Proofread the about page', 'Fixed seven typos.', 260, False, False),
        ('research', 'Explain index funds simply', 'A one-page explainer.', 300, False, False),
        ('default', 'What is on my calendar Friday?', 'Two meetings and a free afternoon.', 2, False, False),
        ('default', 'Ideas for a birthday gift', 'Five ideas at different prices.', 28, True, False),
        ('inbox', 'Unsubscribe from newsletters', 'Done for 24 senders.', 4, False, False),
    ]
    base = int(now()) - 60
    for index, (bot, title, reply, hours, pinned, unread) in enumerate(chats):
        add_session(f'd-{index:02d}', bot, title, [{'role': 'user', 'content': title + '.'}, {'role': 'assistant', 'content': reply}],
                    base - int(hours * 3600), cwd=f'{HOME}/loose', pinned=pinned, unread=unread)
    lines = {'default': 'All set for today.', 'inbox': 'Nothing new that needs you.', 'research': 'The comparison is ready.',
             'writer': 'The newsletter draft is ready.', 'planner': 'Next week is planned.', 'travel': 'Found three weekend ideas.',
             'finance': 'Budget looks good this month.', 'home': 'The checklist is ready.'}
    for name, title, _ in BOTS:
        add_session(bot_chat_id(name), name, 'Bot Chat', [
            {'role': 'user', 'content': 'Anything for me?'}, {'role': 'assistant', 'content': lines[name]}], base - 7200, hidden=True)

def roster():
    rows = []
    for index, (name, title, about) in enumerate(BOTS):
        sid = bot_chat_id(name)
        canon = session_row(sid)
        short = {'id': sid, 'resolved_id': sid, 'title': 'Bot Chat', 'preview': canon['preview'], 'last_active': canon['last_active'],
                 'message_count': canon['message_count']}
        meta = {'title': title, 'description': about, 'pinned': False, 'created': 1790000000000 + index}
        ui_meta, revisions = {'hermes-bots': meta}, {'hermes-bots': 1}
        look = DEMO_LOOK if SEED == 'demo' else EVERYDAY_LOOK if SEED == 'everyday' else {}
        if name in look:
            layout, head = look[name]
            meta.update(layout)
            ui_meta['dispatch-head'] = head
            revisions['dispatch-head'] = 1
        for key, value in META_WRITES.get(name, {}).get('meta', {}).items():   # [pinned-rows]
            if value is None: ui_meta.pop(key, None)
            else: ui_meta[key] = value
            revisions[key] = META_WRITES[name]['revisions'][key]
        rows.append({'name': name, 'path': f'{HOME}/profiles/{name}', 'is_default': name == 'default', 'is_active': name == 'default',
                     'model': 'hermes-4', 'provider': 'nous', 'display_name': title, 'description': about,
                     'canonical_session': short, 'last_session': short, 'worker_session': None, 'sessions': [canon],
                     'ui_meta': ui_meta, 'ui_meta_revisions': revisions})
    return {'active': 'default', 'profiles': rows, 'bot_mode_protocol': True}

def tool(name, payload): return {'role': 'tool', 'tool_name': name, 'content': json.dumps(payload)}

# [pinned-rows] ui_meta keys the app wrote (profiles.configure: Pin, Hide, Move to Section), by profile, with their
# revisions: a written key replaces the seeded one in profiles.list until a reset.
META_WRITES = {}

def configure(params):
    name, incoming = params.get('name'), params.get('ui_meta')
    if name not in BOT_NAMES: raise Fault(4064, f"profile '{name}' not found")
    if not isinstance(incoming, dict): return {'ok': True, 'applied': {}}
    with lock:
        written = META_WRITES.setdefault(name, {'meta': {}, 'revisions': {}})
        for key, value in incoming.items():
            written['meta'][key] = value
            written['revisions'][key] = written['revisions'].get(key, 1) + 1
        return {'ok': True, 'applied': {'ui_meta': True, 'ui_meta_revisions': {k: written['revisions'][k] for k in incoming}}}

def seed():
    SESSIONS.clear(); PENDING.clear(); PROJECTS.clear(); META_WRITES.clear()
    BOTS[:] = DEFAULT_BOTS; BOT_NAMES.clear(); BOT_NAMES.update({name: title for name, title, _ in BOTS})
    if SEED == 'big': return seed_big()
    if SEED == 'everyday': return seed_everyday()
    if SEED == 'demo': return seed_demo()
    base = int(now()) - 60
    for index, (name, title, _) in enumerate(BOTS):
        add_session(bot_chat_id(name), name, 'Bot Chat', [
            {'role': 'user', 'content': 'Morning. Anything for me?'},
            {'role': 'assistant', 'content': f'Morning. {title} here: nothing urgent today.'},
        ], base - 3600 * (index + 5), hidden=True)
    add_session('s-garden', 'default', 'Garden plan', [
        {'role': 'user', 'content': 'Plan the spring garden beds.'},
        {'role': 'assistant', 'content': 'Tomatoes along the south fence, basil between them, and beans on the trellis.'},
    ], base - 120, input_tokens=1000, output_tokens=230, actual_cost_usd=0.02, git_branch='main',
        usage={'input': 1000, 'output': 230, 'total': 1230, 'calls': 2, 'context_used': 3100, 'context_max': 200000,
               'context_percent': 2, 'context_estimated': False, 'cost_usd': None})
    add_session('s-trip', 'research', 'Trip to Lisbon', [
        {'role': 'user', 'content': 'Find three quiet hotels in Lisbon near the river.'},
        {'role': 'assistant', 'content': 'Three quiet picks near the river: Casa do Rio, Alfama Loft and the Tejo House.'},
    ], base - 900, cwd=f'{HOME}/reading', input_tokens=14200, output_tokens=1200, estimated_cost_usd=0.34, git_branch='main')
    add_session('s-release', 'deploys', 'Ship the 2.4 release notes', [
        {'role': 'user', 'content': 'Ship the 2.4 release notes.'},
        tool('read_file', {'path': f'{HOME}/app/CHANGELOG.md', 'content': '24| ## Release 2.4\n25| - Faster sync for the fourwheel pipeline'}),
        {'role': 'assistant', 'content': 'Done. The notes are drafted in CHANGELOG.md.'},
    ], base - 3 * 3600, pinned=True, input_tokens=1400000, output_tokens=100000, actual_cost_usd=12.50)
    add_session('s-budget', 'default', 'Quarterly budget', [
        {'role': 'user', 'content': 'Draft the quarterly budget for four teams.'},
        {'role': 'assistant', 'content': 'The budget for the four teams is drafted; two lines are still open.'},
    ], base - 26 * 3600, unread=True, cwd=f'{HOME}/site', input_tokens=900, output_tokens=99, estimated_cost_usd=0.004)
    add_session('s-recipes', 'research', 'Bread recipes', [
        {'role': 'user', 'content': 'A sourdough recipe for a beginner, please.'},
        {'role': 'assistant', 'content': 'Start with 500 g flour, 350 g water, 100 g starter and 10 g salt.'},
    ], base - 3 * 86400)
    add_session('s-old', 'deploys', 'Old deploy checklist', [
        {'role': 'user', 'content': 'What was on the old deploy checklist?'},
        {'role': 'assistant', 'content': 'Tag, build, smoke test, then announce.'},
    ], base - 5 * 86400, archived=True)
    add_session('s-run', 'default', 'Nightly index run', [
        {'role': 'user', 'content': 'Rebuild the search index.'},
        {'role': 'assistant', 'content': 'Index rebuilt.'},
    ], base - 2 * 3600, source='tool', input_tokens=300, output_tokens=0)
    PROJECTS['default'] = [
        {'id': 'p_site', 'label': 'Website', 'path': f'{HOME}/site', 'repos': [], 'sessionCount': 0},
        {'id': 'p_app', 'label': 'App', 'path': f'{HOME}/app', 'repos': [], 'sessionCount': 0},
        {'id': 'home', 'label': 'Home', 'path': None, 'isNoProject': True, 'repos': [], 'sessionCount': 3},
    ]
    PROJECTS['research'] = [{'id': 'p_reading', 'label': 'Reading', 'path': f'{HOME}/reading', 'repos': [], 'sessionCount': 0}]
    PROJECTS['deploys'] = [{'id': 'p_app', 'label': 'App', 'path': f'{HOME}/app', 'repos': [], 'sessionCount': 0}]

def seed_everyday():
    """An everyday list, for looking at the page: 9 bots, 6 projects, about 45 chats over three weeks, 3 pinned,
    5 unread, 4 Telegram threads, 2 archived. The same data every start."""
    rng = random.Random(31)
    BOTS[:] = [('default', 'Hermes', 'Your right hand'), ('app', 'App', 'Builds the app'), ('otto', 'Otto', 'Sales'),
               ('herald', 'Herald', 'Marketing'), ('inbox', 'Inbox', 'Mail'), ('finance', 'Finance', 'Money'),
               ('home', 'Home', 'The house'), ('juno', 'Juno', 'Hiring'), ('research', 'Research', 'Reading')]
    BOT_NAMES.clear(); BOT_NAMES.update({name: title for name, title, _ in BOTS})
    projects = {'site': 'Website', 'app': 'iPhone App', 'sales': 'Sales Playbook', 'radio': 'Podcast',
                'taxes': 'Taxes 2026', 'reno': 'Kitchen Remodel'}
    owners = {'site': ['default', 'herald'], 'app': ['app', 'default'], 'sales': ['otto'], 'radio': ['herald'],
              'taxes': ['finance'], 'reno': ['home']}
    for key, label in projects.items():
        for bot in owners[key]:
            PROJECTS.setdefault(bot, []).append({'id': f'p_{key}', 'label': label, 'path': f'{HOME}/{key}', 'repos': [], 'sessionCount': 0})
    for name, _, _ in BOTS:
        PROJECTS.setdefault(name, []).append({'id': 'home', 'label': 'Home', 'path': None, 'isNoProject': True, 'repos': [], 'sessionCount': 0})
    chats = [  # (bot, project or None, title, reply, hours ago)
        ('app', 'app', 'Fix the swipe-away crash', 'Fixed: the trail held a weak reference. Build 517 has it.', 0.2),
        ('otto', 'sales', 'Put together the October pipeline review', 'The review is ready: 14 deals, 3 at risk.', 0.6),
        ('default', None, 'What is on my calendar Friday?', 'Two calls and the dentist at 3.', 1.5),
        ('herald', 'radio', 'Christmas radio spot ideas', 'Five ideas, two with jingles. The sleigh one tests best.', 3),
        ('inbox', None, 'Unsubscribe from the marketing lists', 'Done for 36 senders; 4 need you to confirm.', 5),
        ('app', 'app', 'Why is the Sessions list slow?', 'The previews were read one by one. Add-on 0.9.13 batches them.', 7),
        ('finance', 'taxes', 'Q3 estimated payment', 'Q3 estimate is $4,180, due the 15th.', 20),
        ('home', 'reno', 'Compare the three countertop quotes', 'Quartz from Stoneworks is cheapest per foot.', 22),
        ('default', 'site', 'Rewrite the pricing page', 'A shorter page with two plans and a FAQ.', 26),
        ('otto', 'sales', 'Call notes from Northwind', 'Summary: they want a pilot in January.', 28),
        ('juno', None, 'Shortlist for the ops role', 'Six candidates; two stand out.', 30),
        ('app', 'app', 'Tab icon motions', 'Each tab icon moves its own way now.', 44),
        ('herald', 'site', 'Landing page headline tests', 'Variant B lifted signups 12%.', 50),
        ('research', None, 'Best espresso grinders under $500', 'Three picks: Niche Zero, DF64, Baratza Sette.', 52),
        ('default', None, 'Plan the Austin trip', 'Flights Thursday, back Sunday; hotel near Congress.', 70),
        ('home', 'reno', 'Cabinet hardware options', 'Brass pulls in two sizes, samples ordered.', 76),
        ('app', 'app', 'TestFlight notes for 527', 'Notes are in. Each bot has its own fallback models.', 80),
        ('finance', 'taxes', 'Find the 1099s', 'Found 4 of 5; Schwab posts on the 15th.', 96),
        ('otto', 'sales', 'Objection handling cheat sheet', 'Twelve objections with short answers.', 100),
        ('herald', 'radio', 'Book studio time', 'Thursday 10am at Sound Lab.', 118),
        ('default', 'site', 'Fix the broken signup link', 'The link pointed to staging. Fixed.', 140),
        ('inbox', None, 'Draft a reply to the landlord', 'Drafted; polite and short.', 150),
        ('app', 'app', 'Mac sidebar folds', 'The sidebar folds to an icon rail with Control-Command-S.', 170),
        ('research', None, 'Summarize the Fed minutes', 'Rates on hold; two members wanted a cut.', 190),
        ('home', None, 'Lawn guy schedule', 'Every other Tuesday from March.', 220),
        ('otto', 'sales', 'Territory map for 2027', 'Four territories, balanced by pipeline.', 240),
        ('app', 'app', 'Dot-matrix bot heads', 'Twenty across reads best at small sizes.', 260),
        ('finance', None, 'Cancel unused subscriptions', 'Seven found, $94 a month.', 300),
        ('herald', 'site', 'Blog post: why bots need faces', 'Draft is 900 words.', 330),
        ('default', None, 'Gift ideas for Mom', 'A pottery class, a photo book, or a garden kit.', 360),
        ('juno', None, 'Interview questions for ops', '15 questions in three groups.', 400),
        ('app', 'app', 'Composer vs keyboard corners', 'The box now follows the key corners.', 430),
        ('otto', 'sales', 'Pricing for the pilot', '$2,400 a month for three months.', 460),
        ('home', 'reno', 'Electrician quotes', 'Two quotes in; $3,100 and $3,650.', 500),
    ]
    base = int(now()) - 60
    pinned = {'Put together the October pipeline review', 'Q3 estimated payment', 'Plan the Austin trip'}
    unread = {'Fix the swipe-away crash', 'Christmas radio spot ideas', 'Unsubscribe from the marketing lists',
              'Shortlist for the ops role', 'Compare the three countertop quotes'}
    for index, (bot, project, title, reply, hours) in enumerate(chats):
        add_session(f'e-{index:02d}', bot, title, [
            {'role': 'user', 'content': title + '.'}, {'role': 'assistant', 'content': reply}],
            base - int(hours * 3600), cwd=f'{HOME}/{project}' if project else f'{HOME}/loose',
            pinned=title in pinned, unread=title in unread, input_tokens=rng.randrange(1000, 90000),
            output_tokens=rng.randrange(100, 9000), estimated_cost_usd=round(rng.random() * 2, 3))
    for index, (bot, title, reply, hours) in enumerate([
            ('default', 'Telegram: grocery list', 'Milk, eggs, coffee.', 2), ('otto', 'Telegram: Dana', 'Sent the deck.', 30),
            ('home', 'Discord: house group', 'Plumber Tuesday.', 60), ('inbox', 'Telegram: alerts', 'All quiet.', 90)]):
        add_session(f't-{index:02d}', bot, title, [{'role': 'user', 'content': title}, {'role': 'assistant', 'content': reply}],
                    base - int(hours * 3600), source='discord' if 'Discord' in title else 'telegram', cwd=f'{HOME}/loose')
    for index, (bot, title) in enumerate([('herald', 'Old campaign brief'), ('app', 'Build 400 notes')]):
        add_session(f'a-{index:02d}', bot, title, [{'role': 'user', 'content': title}, {'role': 'assistant', 'content': 'Done.'}],
                    base - (12 + index) * 86400, archived=True)
    for name, title, _ in BOTS:
        add_session(bot_chat_id(name), name, 'Bot Chat', [
            {'role': 'user', 'content': 'Morning. Anything for me?'},
            {'role': 'assistant', 'content': f'Morning. {title} here: nothing urgent today.'}], base - 7200, hidden=True)

def seed_big():
    """Load: 2,000 chats over 12 bots and 40 projects, 30 pinned, 200 unread (all among the newest 280), 60 archived, 20 Telegram threads and
    20 scheduled runs, random tokens and costs. The same data every start (fixed random seed)."""
    rng = random.Random(240)
    set_bots(12)
    names = [name for name, _, _ in BOTS]
    folders = [f'{HOME}/work/p{index:02d}' for index in range(40)]
    words = ['Budget', 'Launch', 'Notes', 'Review', 'Plan', 'Draft', 'Report', 'Trip', 'Recipe', 'Checklist', 'Summary', 'Ideas']
    for index, folder in enumerate(folders):
        PROJECTS.setdefault(names[index % len(names)], []).append(
            {'id': f'p_{index:02d}', 'label': f'Project {index + 1}', 'path': folder, 'repos': [], 'sessionCount': 0})
    for name in names:
        PROJECTS.setdefault(name, []).append({'id': 'home', 'label': 'Home', 'path': None, 'isNoProject': True, 'repos': [], 'sessionCount': 0})
    base = int(now()) - 60
    listed = unread_left = 0
    unread_left = 200
    for index in range(2000):
        profile = names[index % len(names)]
        source = 'telegram' if 100 <= index < 120 else 'cron' if 120 <= index < 140 else 'desktop'
        archived = 1900 <= index < 1960
        unread = False
        if source == 'desktop' and not archived:
            listed += 1
            # Among the newest 280: Mark All as Read writes the chats the app holds (300 with a filter on), as the web's does.
            if unread_left and listed <= 280 and listed % 7 not in (0, 3): unread, unread_left = True, unread_left - 1
        cwd = rng.choice(folders) if rng.random() < 0.7 else f'{HOME}/loose'
        tokens_in, tokens_out = rng.randrange(0, 400000), rng.randrange(0, 40000)
        cost = round(rng.random() * 9, 4) if rng.random() < 0.6 else None
        add_session(f'b-{index:04d}', profile, f'{rng.choice(words)} {index + 1}', [
            {'role': 'user', 'content': f'Question {index + 1}.'},
            {'role': 'assistant', 'content': f'Answer {index + 1}: {rng.choice(words).lower()} is ready.'},
        ], base - index * 97, source=source, cwd=cwd, pinned=index % 67 == 3 and index // 67 < 30,
            unread=unread, archived=archived, input_tokens=tokens_in, output_tokens=tokens_out,
            actual_cost_usd=cost if index % 2 else None, estimated_cost_usd=cost if not index % 2 else None,
            git_branch=rng.choice(['main', 'dev', None]))

def search(query, profile):
    terms = [t.lower() for t in query.split() if t.strip()]
    results = []
    for sid, s in SESSIONS.items():
        if s['profile'] != profile: continue
        texts = [s['title']] + [m.get('content') if isinstance(m.get('content'), str) else '' for m in s['messages']]
        whole = ' '.join(texts).lower()
        if not terms or not all(t in whole for t in terms): continue
        hit = next((text for text in texts[1:] if terms[0] in text.lower()), texts[0])
        at = hit.lower().find(terms[0])
        snippet = hit
        if at >= 0: snippet = hit[:at] + '>>>' + hit[at:at + len(terms[0])] + '<<<' + hit[at + len(terms[0]):]
        results.append({'session_id': sid, 'snippet': snippet, 'title': None if s['hidden'] and False else s['title'], 'source': s['source'],
                        'model': 'hermes-4', 'role': 'assistant', 'session_started': s['started_at'], 'last_active': s['last_active'],
                        'lineage_root': sid, 'profile': profile})
    return sorted(results, key=lambda r: -r['last_active'])

def tree(profile):
    odd = MODE.get('projects')
    if odd == 'empty': return {'projects': [], 'active_id': None, 'scoped_session_ids': []}
    if odd == 'null': return {'projects': None, 'active_id': None, 'scoped_session_ids': []}
    projects = copy.deepcopy(PROJECTS.get(profile, []))
    if odd == 'odd':      # a project without a path, two with one label, a row that is not a project at all
        projects += [{'id': 'p_nopath', 'label': 'No Folder', 'path': None, 'repos': []},
                     {'id': 'p_twin_a', 'label': 'Twin', 'path': f'{HOME}/twin-a', 'repos': []},
                     {'id': 'p_twin_b', 'label': 'Twin', 'path': f'{HOME}/twin-b', 'repos': []}, None, 'nope', {'label': 'No Id'}]
    if odd == 'many':     # nine more: the New Chat sheet lists five and All Projects
        projects += [{'id': f'p_many_{n.lower()}', 'label': n, 'path': f'{HOME}/many/{n.lower()}', 'repos': []}
                     for n in ['Budget', 'Fitness', 'Garden', 'Kitchen', 'Newsletter', 'Photos', 'Recipes', 'Travel', 'Zebra']]
    if odd == 'long':     # very long names, with and without spaces, among enough projects for All Projects
        names = ['A Quarterly Marketing Strategy and Customer Outreach Plan for the Northwest Region 2027',
                 'acme-platform-monorepo-with-services-and-infrastructure-and-no-spaces-anywhere-in-the-name',
                 'Budget', 'Chez Stéphane: réaménagement de la cuisine et de la salle à manger, phase deux', 'Garden', 'Photos', 'Zebra']
        projects += [{'id': f'p_long_{i}', 'label': n, 'path': f'{HOME}/long/p{i}', 'repos': []} for i, n in enumerate(names)]
    return {'projects': projects, 'active_id': None, 'scoped_session_ids': []}

def check_params(method, params):
    allowed = ALLOWED.get(method)
    if allowed is None: return
    for key in params:
        if key not in allowed:
            raise Fault(4000, f'invalid params for {method}: {key}: Extra inputs are not permitted')

def rpc_delay(method):
    """A wait armed through /__fixture/fail {"rpc", "delay"}: seconds before this call is answered (0 = none)."""
    with lock:
        for fail in list(rpc_fails):
            if fail.get('rpc') != method or not fail.get('delay'): continue
            fail['count'] = int(fail.get('count', 1)) - 1
            if fail['count'] <= 0: rpc_fails.remove(fail)
            return float(fail['delay'])
    return 0

def rpc_failure(method):
    """A failure armed through /__fixture/fail for this RPC: raises, or closes the socket."""
    with lock:
        fail = next((f for f in rpc_fails if f.get('rpc') == method and not f.get('delay')), None)
        if fail is None: return
        fail['count'] = int(fail.get('count', 1)) - 1
        if fail['count'] <= 0: rpc_fails.remove(fail)
    if fail.get('drop'): raise Drop()
    raise Fault(int(fail.get('code', -32001)), fail.get('message', 'boom'))

def emit(kind, sid, payload):
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'session_id': runtime(sid) if sid in SESSIONS else (sid or ''), 'payload': payload or {}}}
    for send in list(sockets):
        try: send(frame)
        except OSError: pass

def run_prompt(sid, text):
    """A prompt in "hold" or "reply" mode: the user's words are kept, the turn starts, and under "reply" it ends."""
    with lock:
        s = SESSIONS[sid]
        s['messages'].append({'id': len(s['messages']) + 1, 'role': 'user', 'content': text, 'timestamp': now()})
        s['last_active'] = now()
        s['running'] = True
        row = len(s['messages'])
        mode = MODE.get('prompts')
    def turn():
        time.sleep(0.15)
        emit('message.start', sid, {})
        if mode != 'reply': return
        answer = 'Noted. That is on the list.'
        time.sleep(0.2)
        emit('message.delta', sid, {'text': answer})
        with lock:
            if sid not in SESSIONS: return
            s = SESSIONS[sid]
            s['messages'].append({'id': len(s['messages']) + 1, 'role': 'assistant', 'content': answer, 'timestamp': now()})
            s['last_active'] = now()
            s['running'] = False
            done = len(s['messages'])
        emit('message.complete', sid, {'text': answer, 'row_id': done, 'usage': usage_of(sid)})
        broadcast()
    threading.Thread(target=turn, daemon=True).start()
    return {'status': 'streaming', 'user_row_id': row}

# ---- RPC and socket ---------------------------------------------------------------------------------------
_rpc = fx.rpc
def resumed(sid):
    s = SESSIONS[sid]
    info = {'model': 'hermes-4', 'provider': 'nous', 'cwd': s['cwd'], 'title': s['title'], 'tools': {}, 'skills': {}, 'mcp_servers': [],
            'lazy': True, 'running': False, 'stored_session_id': sid, 'profile_name': s['profile'], 'desktop_contract': 8}
    if not s['hidden'] and not MODE.get('oldGateway'):      # Session Info: the chat's usage and branch ride on the resume
        info['usage'] = usage_of(sid); info['branch'] = s.get('git_branch')
    if s.get('reasoning_effort'): info['reasoning_effort'] = s['reasoning_effort']      # /__fixture/rows: Session Info › Reasoning
    if 'fast' in s: info['fast'] = bool(s['fast'])
    running = bool(s.get('running'))
    info['running'] = running
    return {'session_id': runtime(sid), 'resumed': sid, 'session_key': sid, 'stored_session_id': sid, 'messages': [],
            'messages_omitted': True, 'message_count': len(s['messages']), 'status': 'running' if running else 'idle',
            'running': running, 'inflight': None, 'info': info}

def rpc(method, params):
    with lock: state['rpc'].append({'method': method, 'params': params})
    profile = params.get('profile') or 'default'
    rpc_failure(method)
    check_params(method, params)
    if MODE.get('oldGateway') and (method.startswith('projects.') or method == 'session.usage'):
        raise Fault(-32601, f'Method not found: {method}')
    if method == 'session.usage':
        sid = find_session(params.get('session_id'))
        if not sid: raise Fault(4001, 'session not found')
        with lock: return usage_of(sid)
    if method == 'profiles.list': return roster()
    if method == 'profiles.configure': return configure(params)   # [pinned-rows]
    if method == 'session.list':
        rows = [session_row(sid) for sid, s in SESSIONS.items() if s['profile'] == profile and (not params.get('title') or s['title'] == params['title'])]
        return {'sessions': rows, 'total': len(rows)}
    if method in ('session.resume', 'session.activate'):
        live = pending_sid(params.get('session_id'))
        if live:
            with lock:
                add_session(live, PENDING[live], None, [], now())
                try: return resumed(live)
                finally: SESSIONS.pop(live, None)
        sid = find_session(params.get('session_id')) or bot_chat_id(profile if profile in BOT_NAMES else 'default')
        return resumed(sid)
    if method in ('session.info', 'session.get'):
        sid = find_session(params.get('session_id')) or bot_chat_id('default')
        return resumed(sid)['info']
    if method == 'session.active_list': return {'sessions': []}
    if method == 'projects.tree':
        with lock: return tree(profile)
    if method == 'projects.create':
        folders = params.get('folders') or []
        if not params.get('name') or not folders: raise ValueError('A project needs a name and a folder')
        pid = 'p_' + hashlib.sha256(params['name'].encode()).hexdigest()[:6]
        project = {'id': pid, 'label': params['name'], 'path': folders[0], 'repos': [], 'sessionCount': 0}
        with lock: PROJECTS.setdefault(profile, []).append(project)
        return {'project': {'id': pid, 'name': params['name'], 'primary_path': folders[0], 'folders': [{'path': f} for f in folders]}}
    if method == 'projects.update':       # Rename Project…: the name, as Hermes (5062 for an id it doesn't have)
        with lock:
            project = next((p for p in PROJECTS.get(profile, []) if p.get('id') == params.get('id') and not p.get('isNoProject')), None)
            if project is None: raise Fault(5062, 'no such project')
            if params.get('name') is not None:
                if not str(params['name']).strip(): raise ValueError('project name must not be empty')
                project['label'] = str(params['name']).strip()
            return {'project': {'id': project['id'], 'name': project['label'], 'primary_path': project['path']}}
    if method == 'projects.delete':       # Delete Project…: gone from the bot's list; its chats fall to Home here
        with lock:
            before = PROJECTS.get(profile, [])
            kept = [p for p in before if p.get('isNoProject') or p.get('id') != params.get('id')]
            if len(kept) == len(before): raise Fault(5062, 'no such project')
            PROJECTS[profile] = kept
            return {'projects': [{'id': p['id'], 'name': p['label']} for p in kept if not p.get('isNoProject')], 'active_id': None}
    if method == 'session.workspace.move':
        with lock:
            sid = find_session(params.get('session_key'))
            if not sid: raise ValueError('Session not found')
            SESSIONS[sid]['cwd'] = params.get('cwd')
        return {'cwd': params.get('cwd'), 'branch': None, 'git_repo_root': None}
    if method == 'session.branch_stored':
        with lock:
            parent = find_session(params.get('parent_session_id'))
            if not parent: raise ValueError('Session not found')
            p = SESSIONS[parent]
            sid = f'{parent}-branch-{sum(1 for s in SESSIONS.values() if s["parent"] == parent) + 1}'
            add_session(sid, p['profile'], f'{p["title"]} (branch)', copy.deepcopy(p['messages']), now(), cwd=params.get('cwd') or p['cwd'])
            SESSIONS[sid]['parent'] = parent
        return {'session_id': runtime(sid), 'stored_session_id': sid, 'message_count': len(p['messages'])}
    if method == 'session.create':
        with lock:
            sid = f's-new-{sum(1 for k in SESSIONS if k.startswith("s-new-")) + len(PENDING) + 1}'
            PENDING[sid] = profile
        return {'session_id': runtime(sid), 'stored_session_id': sid, 'message_count': 0}
    if method == 'session.title':
        # Hermes (tui_gateway methods_session.py): a title given before the first prompt writes the row at once.
        title = (params.get('title') or '').strip()
        if not title: raise Fault(4021, 'title required')
        with lock:
            live = pending_sid(params.get('session_id'))
            if live: add_session(live, PENDING.pop(live), title, [], now())
            sid = find_session(params.get('session_id'))
            if not sid: raise Fault(4001, 'session not found')
            SESSIONS[sid]['title'] = title
        return {'pending': False, 'title': title}
    if method == 'prompt.submit':
        live = pending_sid(params.get('session_id'))
        if live:
            with lock: add_session(live, PENDING.pop(live), None, [], now())
        sid = find_session(params.get('session_id'))
        if MODE.get('prompts') in ('hold', 'reply') and sid: return run_prompt(sid, params.get('text') or '')
        raise ValueError('The sessions fixture does not run prompts')
    return _rpc(method, params)
fx.rpc = rpc

def websocket(connection: socket.socket, key: str):
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    wlock = threading.Lock()
    def read(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk: raise ConnectionError()
            data += chunk
        return data
    def send(value):
        body = json.dumps(value).encode(); size = len(body)
        header = bytes([0x81]) + (bytes([size]) if size < 126 else bytes([126]) + struct.pack('>H', size) if size < 65536 else bytes([127]) + struct.pack('>Q', size))
        with wlock: connection.sendall(header + body)
    sockets.add(send)
    connections.add(connection)
    try:
        send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {'heartbeat': True, 'change_events': True, 'replay_epoch': 'sessions', 'desktop_contract': 8}}})
        fragments = bytearray()
        while True:
            first, second = read(2); opcode, length, final = first & 15, second & 127, bool(first & 128)
            if length == 126: length = struct.unpack('>H', read(2))[0]
            elif length == 127: length = struct.unpack('>Q', read(8))[0]
            mask = read(4) if second & 128 else b'\0\0\0\0'
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(length)))
            if opcode == 8: return
            if opcode == 9:
                with wlock: connection.sendall(bytes([0x8A, len(payload)]) + payload)
                continue
            if opcode == 1: fragments = bytearray(payload)
            elif opcode == 0: fragments.extend(payload)
            else: continue
            if not final: continue
            frame = json.loads(fragments); fragments.clear()
            if 'id' not in frame or 'method' not in frame: continue
            def answered(frame):
                answer = {'jsonrpc': '2.0', 'id': frame['id']}
                try: answer['result'] = rpc(frame['method'], frame.get('params') or {})
                except Fault as fault: answer['error'] = {'code': fault.code, 'message': fault.message}
                except ValueError as error: answer['error'] = {'code': -32001, 'message': str(error)}
                return answer
            if frame['method'] == 'projects.tree' and MODE.get('projectsHold'):
                def held(frame=frame):      # answered once the test lets go, off this socket's read loop
                    hold('projectsHold', 'projects')
                    try: send(answered(frame))
                    except (Drop, OSError): pass
                threading.Thread(target=held, daemon=True).start()
                continue
            wait = rpc_delay(frame['method'])
            if wait:          # answered late, off this socket's read loop (other calls go on meanwhile)
                def late(frame=frame, wait=wait):
                    time.sleep(wait)
                    try: send(answered(frame))
                    except (Drop, OSError): pass
                threading.Thread(target=late, daemon=True).start()
                continue
            try: answer = answered(frame)
            except Drop:
                try: connection.shutdown(socket.SHUT_RDWR)
                except OSError: pass
                return
            send(answer)
    except (ConnectionError, OSError, ValueError): return
    finally:
        sockets.discard(send); connections.discard(connection)
fx.auth.websocket = websocket

def broadcast(kind='sessions.changed'):
    for send in list(sockets):
        try: send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'payload': {}}})
        except OSError: pass

# ---- REST -------------------------------------------------------------------------------------------------
_handler = fx.handler
def handler(gateway):
    base = _handler(gateway)
    class Handler(base):
        def body_json(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try: return json.loads(raw or b'{}')
            except ValueError: return {}

        def logged(self, method, body=None):
            url = urlparse(self.path)
            query = {k: v[0] if len(v) == 1 else v for k, v in parse_qs(url.query).items()}
            with lock: state['rest'].append({'method': method, 'path': url.path, 'query': query, 'body': body})
            for fail in list(fails):
                if 'rpc' in fail: continue
                if fail.get('method', method) == method and (url.path.startswith(fail.get('path') or '\0') if fail.get('prefix') else fail.get('path') == url.path):
                    if fail.get('delay'):
                        with lock:                                  # "count": how many matches wait (1 unless given)
                            fail['count'] = int(fail.get('count', 1)) - 1
                            if fail['count'] <= 0 and fail in fails: fails.remove(fail)
                        time.sleep(float(fail['delay']))
                        return None
                    with lock:
                        fail['count'] = int(fail.get('count', 1)) - 1
                        if fail['count'] <= 0: fails.remove(fail)
                    return int(fail.get('status', 500)), {'detail': fail.get('detail', 'boom')}
            return None

        def route(self, method, body):
            url = urlparse(self.path); path, query = url.path, parse_qs(url.query)
            one = lambda key: (query.get(key) or [''])[0]
            if path == '/api/files/mkdir' and method == 'POST':     # New Project with no folder typed: ~ is HOME
                made = str((body or {}).get('path') or '')
                if not made: return 400, {'detail': 'path is required'}
                return 200, {'ok': True, 'path': HOME + made[1:] if made.startswith('~') else made}
            if path == '/api/plugins/hermes-hq-push/sessions/working' and method == 'GET':   # [working-ledger]
                with lock: ids = list(MODE.get('working') or [])
                return 200, {'sessions': [{'id': i, 'profile': 'default', 'status': 'started', 'kind': 'admission'} for i in ids]}
            if path == '/api/plugins/hermes-hq-push/serve/working' and method == 'GET':
                return 503, {'detail': "this process isn't serving chats"}
            if path == '/api/profiles/sessions/sidebar' and method == 'GET':
                if MODE.get('oldGateway'): return 404, {'detail': 'Not Found'}
                def limit(key, default):
                    try: return max(1, min(500, int(one(key) or default)))
                    except ValueError: return default
                recents_limit, cron_limit, messaging_limit = limit('recents_limit', 50), limit('cron_limit', 50), limit('messaging_limit', 100)
                with lock: stats['sidebar']['probe' if recents_limit == 1 else 'deep' if recents_limit >= 300 else 'top' if recents_limit < 50 else 'full'] += 1
                if MODE.get('sidebarDelay'): time.sleep(float(MODE['sidebarDelay']))
                hold('sidebarHold', 'sidebar')
                def recent(row):
                    value = row.get('last_active')
                    return -value if isinstance(value, (int, float)) and value == value else 0
                def cut(rows, count):      # the newest N plus every pinned row, as Hermes
                    return rows[:count] + [row for row in rows[count:] if isinstance(row, dict) and row.get('pinned') is True]
                only = one('recents_profile') or 'all'
                with lock:
                    rows = sorted((session_row(sid) for sid, s in SESSIONS.items() if not s['hidden'] and not s['archived'] and s['messages']), key=recent)
                    # One-off runs ride in the messaging slice and never in the recents, as Hermes with the app's excludes.
                    recents = [r for r in rows if r.get('source') not in ('cron', 'oneshot') and r.get('source') not in MESSAGING and (only == 'all' or r.get('profile') == only)]
                    cron = [r for r in rows if r.get('source') == 'cron']
                    messaging = [r for r in rows if r.get('source') in MESSAGING or r.get('source') == 'oneshot']
                    if MODE.get('badRows'): recents = bad_rows() + recents
                return 200, {'recents': {'sessions': cut(recents, recents_limit), 'total': len(recents)},
                             'cron': {'sessions': cut(cron, cron_limit), 'total': len(cron)},
                             'messaging': {'sessions': cut(messaging, messaging_limit), 'total': len(messaging)}}
            if path in ('/api/profiles/sessions', '/api/sessions') and method == 'GET':
                archived = one('archived') or 'exclude'
                source, excluded = one('source'), set(filter(None, one('exclude_sources').split(',')))
                with lock:
                    rows = [session_row(sid) for sid, s in SESSIONS.items() if not s['hidden']
                            and (archived == 'include' or (archived == 'only') == s['archived'])
                            and (not source or s['source'] == source) and s['source'] not in excluded]
                rows.sort(key=lambda r: -r['last_active'] if isinstance(r.get('last_active'), (int, float)) else 0)
                return 200, {'sessions': rows, 'total': len(rows), 'limit': int(one('limit') or 50), 'offset': 0}
            if path == '/api/sessions/search' and method == 'GET':
                with lock: return 200, {'results': search(one('q'), one('profile') or 'default')}
            if path.startswith('/api/sessions/'):
                sid = unquote(path[len('/api/sessions/'):].split('/')[0])
                with lock:
                    sid = find_session(sid)
                    s = SESSIONS.get(sid) if sid else None
                    if not s: return 404, {'detail': 'Session not found'}
                    if method == 'GET' and path.endswith('/messages'):
                        # `order=latest` counts back from the newest row and still answers oldest first (as Hermes does).
                        rows = s['messages']
                        limit = int(one('limit') or 100); offset = int(one('offset') or 0)
                        page = list(reversed(rows))[offset:offset + limit][::-1] if one('order') == 'latest' else rows[offset:offset + limit]
                        return 200, {'session_id': sid, 'profile': s['profile'], 'messages': page,
                                     'pagination': {'limit': limit, 'offset': offset, 'order': one('order') or 'oldest', 'returned': len(page)}}
                    if method == 'GET' and path.endswith('/mutation-snapshot') and FENCE['on']:
                        return 200, {'session_id': sid, 'exists': True, 'runtime_revision': s.get('revision', 0),
                                     'runtime_generation': 1}
                    if method == 'GET': return 200, session_row(sid)
                    if method in ('PATCH', 'DELETE') and str(s.get('user_id') or '').startswith('basic:'):
                        # Made with the old password sign-in: Hermes lets only that sign-in change it, and this
                        # fixture's sign-in is another one (hermes_state_mutation_binding.authorize_history).
                        return 403, {'detail': 'permission_denied'}
                    if method in ('PATCH', 'DELETE') and FENCE['on']:
                        # Hermes 0.22.3+: no identity → client_upgrade_required; a stale one → revision_conflict.
                        ident = body if method == 'PATCH' else {k: one(k) or None for k in ('request_id', 'expected_revision', 'expected_generation')}
                        rid = ident.get('request_id')
                        if rid is None and ident.get('expected_revision') is None:
                            FENCE['refused'] += 1
                            return 409, {'detail': 'client_upgrade_required: this app is out of sync (different versions) '
                                                   'with the Hermes backend; update the app to edit sessions'}
                        if rid in FENCE['receipts']: return 200, FENCE['receipts'][rid]
                        if str(ident.get('expected_revision')) != str(s.get('revision', 0)) or str(ident.get('expected_generation')) != '1':
                            return 409, {'detail': 'revision_conflict'}
                        s['revision'] = s.get('revision', 0) + 1
                        FENCE['accepted'] += 1
                    if method == 'PATCH':
                        for field in ('pinned', 'archived', 'unread'):
                            if field in body: s[field] = bool(body[field])
                        if 'title' in body: s['title'] = body['title'] or None
                        answer = {'ok': True}
                        if 'title' in body: answer['title'] = s['title'] or ''
                    elif method == 'DELETE':
                        del SESSIONS[sid]
                        answer = {'ok': True}
                    else:
                        return 405, {'detail': 'Method Not Allowed'}
                    if FENCE['on'] and isinstance(body, dict) and (body.get('request_id') or one('request_id')):
                        FENCE['receipts'][body.get('request_id') or one('request_id')] = answer
                broadcast()
                return 200, answer
            if path == '/api/profiles' and method == 'GET':
                return 200, {'profiles': [{'name': n, 'display_name': t, 'is_default': n == 'default', 'path': f'{HOME}/profiles/{n}',
                                           'model': 'hermes-4', 'provider': 'nous'} for n, t, _ in BOTS]}
            return None

        def down(self):
            """{"down": seconds} is on: the request is cut off unanswered, as a gateway that is not there."""
            with lock: until = MODE.get('down_until') or 0
            if until <= now(): return False
            self.close_connection = True
            try: self.connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            return True

        def handle_api(self, method):
            if self.down(): return
            body = self.body_json() if method in ('POST', 'PATCH', 'PUT', 'DELETE') else None
            failed = self.logged(method, body)
            if failed: return self.reply(*failed)
            result = self.route(method, body or {})
            if result is None:
                return super().do_GET() if method == 'GET' else self.reply(404, {'detail': 'Not Found'})
            return self.reply(*result)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == '/__fixture/state':
                with lock: return self.reply(200, {'rest': state['rest'], 'rpc': state['rpc']})
            if path == '/__fixture/stats':
                with lock: return self.reply(200, {**copy.deepcopy(stats), 'fence': {k: FENCE[k] for k in ('on', 'refused', 'accepted')}})
            if self.down(): return
            if path.startswith('/api/auth/') or path == '/api/ws' or path.startswith('/__fixture/') or path == '/api/status':
                return super().do_GET()
            return self.handle_api('GET')

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/fail':
                fail = self.body_json()
                with lock: (rpc_fails if 'rpc' in fail else fails).append(fail)
                return self.reply(200, {'ok': True})
            if path == '/__fixture/rows':
                body = self.body_json()
                with lock: answer = patch_row(body)
                if body.get('event'): broadcast()
                return self.reply(200, answer)
            if path == '/__fixture/emit':
                body = self.body_json()
                if 'request' in body:
                    request = body['request'] or {}
                    with lock:
                        SERVER_REQUESTS[0] += 1
                        rid = f'srq_{SERVER_REQUESTS[0]}'
                    sid = find_session(body.get('session_id')) or body.get('session_id') or ''
                    frame = {'jsonrpc': '2.0', 'id': rid, 'method': request.get('method', 'approval'),
                             'params': {'session_id': runtime(sid) if sid in SESSIONS else sid, **(request.get('params') or {})}}
                    for send in list(sockets):
                        try: send(frame)
                        except OSError: pass
                    return self.reply(200, {'ok': True, 'id': rid})
                sid = find_session(body.get('session_id')) or body.get('session_id') or ''
                kind = body.get('type') or 'session.info'
                if kind in ('message.complete', 'error') and sid in SESSIONS:
                    with lock: SESSIONS[sid]['running'] = False
                emit(kind, sid, body.get('payload') or {})
                return self.reply(200, {'ok': True})
            if path == '/__fixture/mode':
                body = self.body_json()
                with lock:
                    for key, value in body.items():
                        if value in (None, False, ''): MODE.pop(key, None)
                        else: MODE[key] = value
                    if 'bots' in body: set_bots(int(body['bots'] or len(DEFAULT_BOTS)))
                    if 'down' in body: MODE['down_until'] = now() + float(body['down'] or 0)
                    answer = dict(MODE)
                if body.get('down'):
                    for connection in list(connections):
                        try: connection.shutdown(socket.SHUT_RDWR)
                        except OSError: pass
                return self.reply(200, answer)
            if path == '/__fixture/drop':
                self.body_json()
                dropped = 0
                for connection in list(connections):
                    try: connection.shutdown(socket.SHUT_RDWR); dropped += 1
                    except OSError: pass
                return self.reply(200, {'ok': True, 'dropped': dropped})
            if path == '/__fixture/burst':
                body = self.body_json()
                count, interval = int(body.get('count', 200)), float(body.get('interval', 0.02))
                with lock: stats['burst'] = stats.get('burst', 0) + count
                def run():
                    started = time.time()
                    for _ in range(count):
                        broadcast(); time.sleep(interval)
                        with lock: stats['burst'] -= 1
                    print(f'burst of {count} took {time.time() - started:.1f} s', flush=True)
                threading.Thread(target=run, daemon=True).start()
                return self.reply(200, {'ok': True, 'count': count})
            if path == '/__fixture/reset':
                self.body_json()
                reseed()
                return self.reply(200, {'ok': True})
            if self.down(): return
            if path.startswith('/auth/') or path.startswith('/api/auth/') or path.startswith('/__fixture/'):
                return super().do_POST()
            return self.handle_api('POST')

        def do_PATCH(self): return self.handle_api('PATCH')
        def do_DELETE(self): return self.handle_api('DELETE')
        def do_PUT(self): return self.handle_api('PUT')
    return Handler
fx.handler = handler

def patch_row(body):
    """/__fixture/rows: create, patch or delete one chat."""
    sid = body.get('id')
    if not sid: return {'ok': False, 'detail': 'id is required'}
    if body.get('delete'):
        SESSIONS.pop(sid, None)
        return {'ok': True, 'deleted': sid}
    fields = dict(body.get('set') or {})
    if sid not in SESSIONS:
        add_session(sid, fields.get('profile', 'default'), fields.get('title', sid), fields.pop('messages', None) or [
            {'role': 'user', 'content': 'A question.'}, {'role': 'assistant', 'content': 'An answer.'}],
            fields.get('last_active', now()))
    s = SESSIONS[sid]
    if 'messages' in fields:
        messages = fields.pop('messages') or []
        for index, message in enumerate(messages):
            message.setdefault('id', index + 1); message.setdefault('timestamp', s['last_active'] - (len(messages) - index) * 5)
        s['messages'] = messages
    s.update(fields)
    return {'ok': True, 'row': session_row(sid)}

def bad_rows():
    """Rows a careless gateway could send (docs/spec/3x-sessions.md §14 "Bad data")."""
    t = int(now())
    long_path = HOME + '/' + '/'.join(['deeply-nested-folder'] * 20)
    base = {'profile': 'default', 'source': 'desktop', 'message_count': 2, 'pinned': False, 'unread': False, 'archived': False,
            'hidden': False, 'model': 'hermes-4', 'cwd': f'{HOME}/app', 'started_at': t - 5000, 'last_active': t - 4000}
    return [
        {**base, 'title': 'A row without an id'},
        {**base, 'id': 'bad-null', 'title': None, 'preview': None},
        {**base, 'id': 'bad-long', 'title': 'Long title ' + 'word ' * 60, 'preview': 'p' * 400},
        {**base, 'id': 'bad-emoji', 'title': '\U0001F9D1\u200d\U0001F680 Launch \U0001F680\U0001F525 plan'},
        {**base, 'id': 'bad-rtl', 'title': '\u0645\u0631\u062d\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645', 'preview': '\u05e9\u05dc\u05d5\u05dd'},
        {**base, 'id': 'bad-tokens-text', 'title': 'Tokens as text', 'input_tokens': '1200', 'output_tokens': 'many'},
        {**base, 'id': 'bad-tokens-negative', 'title': 'Negative tokens', 'input_tokens': -500, 'output_tokens': -1},
        {**base, 'id': 'bad-tokens-huge', 'title': 'Huge tokens', 'input_tokens': 1e15, 'output_tokens': 1e15, 'actual_cost_usd': 1e9},
        {**base, 'id': 'bad-cost-negative', 'title': 'Negative cost', 'actual_cost_usd': -4, 'estimated_cost_usd': 'free'},
        {**base, 'id': 'bad-time-zero', 'title': 'No time', 'last_active': 0, 'started_at': None},
        {**base, 'id': 'bad-time-ahead', 'title': 'A year ahead', 'last_active': t + 365 * 86400},
        {**base, 'id': 'bad-source', 'title': 'Unknown source', 'source': 'carrier-pigeon'},
        {**base, 'id': 'bad-owner', 'title': 'Nobody’s chat', 'profile': 'ghost-bot'},
        {**base, 'id': 's-garden', 'title': 'Garden plan twin', 'profile': 'research'},
        {**base, 'id': 'bad-cwd', 'title': 'Deep folder', 'cwd': long_path, 'git_branch': 'b' * 200},
        {**base, 'id': 'bad-cwd-null', 'title': 'No folder', 'cwd': None},
        'not a row', None, 42,
    ]

def reseed():
    with lock:
        state['rest'].clear(); state['rpc'].clear()
        fails.clear(); rpc_fails.clear(); MODE.clear()
        for key in stats['sidebar']: stats['sidebar'][key] = 0
        seed()

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=9820)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--unfenced', action='store_true', help='session edits as Hermes 0.22.2 (no revision fence)')
    parser.add_argument('--seed', choices=['default', 'big', 'everyday', 'demo'], default='default', help='big: 2,000 chats over 12 bots (load); demo: generic bots and chats for pictures to share')
    args = parser.parse_args()
    global SEED
    SEED = args.seed
    FENCE['on'] = not args.unfenced
    reseed()
    sys.argv = [sys.argv[0], '--port', str(args.port), '--credentials', args.credentials] + (['--keep-credentials'] if args.keep_credentials else [])
    print(f'Sessions fixture listening on 127.0.0.1:{args.port}', flush=True)
    fx.main()

if __name__ == '__main__': main()
