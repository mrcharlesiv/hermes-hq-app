#!/usr/bin/env python3
"""Loopback stand-in gateway for the settings stream (docs/spec/1x-settings.md §12.1). Invented data only.

Loads the reference repo's action-voice fixture by absolute path (nothing there is copied or edited) for its
password sign-in, --hermes-cookies, --label and /api/ws, and adds what no committed fixture has: profiles.configure
with Hermes' per-key compare-and-swap (a line-for-line port of `_configure_ui_meta`), profile assets,
profiles.create, setup.runtime_check, Bot Chat registry/mint, prompt streaming, skills (+ official catalog,
install/uninstall actions), MCP servers and status, reload.mcp. Every method below checks its params against the
gateway's contract keys and answers 4000 for any other key, as Hermes does.

Controls (loopback, no auth, never under /api/):
  GET  /__settings/state                         writes, profiles (ui_meta, revisions, description, avatar), prompts, rest
  POST /__settings/desktop-edit {profile,key,value}  another device writes one ui_meta key (revision + 1; null deletes)
  POST /__settings/bump {profile}                new activity on that bot's chat
  POST /__settings/chats {profile,titles}        [botinfo-chats] more titled chats for that bot, older than its others
  POST /__settings/fail {method,mode,count[,synced]}  error | applied-false | no-applied | slow (35 s); REST: "PUT /api/skills/toggle";
                                                 a synced-documents-only write takes one only when armed synced: true
  POST /__settings/install-outcome {identifier,exit,lines}
  POST /__settings/runtime {ok,error}            next setup.runtime_check answer
  POST /__settings/turn {seconds}                [live] each later reply's turn runs that long (0-120 s) before it answers
  POST /__settings/reset                         back to the seed
  POST /__settings/only {profiles:[names]}       [filters-only] only those bots are left (the rest gone, as if deleted)
  POST /__settings/cwd {profile,cwd}             [m9 settings] that bot's chats report this project folder (null: none)
  POST /__settings/fs {missing:[paths]}          [m9 settings] folders that stop existing for GET /api/fs/list
GET /api/fs/list?path=… answers from a small tree under /fixture and /Users/fixture ({"entries":[],"error":…} elsewhere).

Bots extras (docs/parity-240.md §3): profiles.create with clone_from copies that profile's skills (Duplicate);
DELETE /api/profiles/<name> deletes a profile (never default; recorded as a write "DELETE /api/profiles/<name>");
GET /api/profiles/sessions?profile=…&min_messages=…&limit=… lists one profile's chats, newest first (Bot Info's recents).

  python3 scripts/fixtures/settings-gateway.py --port 9738 --hermes-cookies --credentials /tmp/x/a.json
"""
import argparse, base64, copy, hashlib, importlib.util, json, os, pathlib, re, secrets, socket, struct, threading, time
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
_spec = importlib.util.spec_from_file_location('voice_fixture', REF / 'scripts' / 'action-voice-fixture-gateway.py')
voice = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(voice)

_cspec = importlib.util.spec_from_file_location('settings_config_data', pathlib.Path(__file__).parent / 'settings_config_data.py')
cfg = importlib.util.module_from_spec(_cspec)
_cspec.loader.exec_module(cfg)

LOCK = threading.RLock()
CLIENTS = set()
LABEL = ''

# ---- contract keys (tui_gateway/contracts): anything else answers 4000 ------------------------------------------
PROFILE = {'profile'}
CONTRACT = {
    'session.create': {'profile', 'cols', 'source', 'cwd', 'cwd_explicit', 'messages', 'parent_session_id', 'title', 'model', 'hidden', 'provider',
                       'reasoning_effort', 'fast', 'service_tier', 'close_on_disconnect', 'room_plumbing', 'follow_profile_config', 'idempotency_key'},   # [m9 settings] cwd, cwd_explicit
    'profiles.list': PROFILE | {'include_sessions'},
    'profiles.create': PROFILE | {'name', 'description', 'clone_from', 'clone_all', 'clone_channels', 'no_skills', 'no_alias',
                                  'soul', 'model', 'provider', 'share_auth', 'mirror_credentials'},
    'profiles.configure': PROFILE | {'name', 'ui_meta', 'ui_meta_expected_revisions', 'soul', 'description', 'model', 'provider',
                                     'confirm_expensive_model', 'disabled_skills', 'enabled_toolsets', 'enabled_mcp_servers'},
    'profiles.set_asset': PROFILE | {'name', 'asset', 'data', 'clear'},
    'profiles.get_asset': PROFILE | {'name', 'asset'},
    'setup.runtime_check': PROFILE | {'provider'},
    'mcp.servers.list': PROFILE,
    'mcp.servers.status': PROFILE,
    'reload.mcp': {'session_id', 'confirm', 'always', 'rev'},
    'vault.list': PROFILE,
    'vault.sources': PROFILE,
    'vault.add': PROFILE | {'kind', 'label', 'origin', 'secret'},
    'vault.remove': PROFILE | {'id'},
    'vault.source.set': PROFILE | {'name', 'enabled'},
    'vault.unlock': PROFILE | {'name', 'password'},
    'vault.lock': PROFILE | {'name'},
    'billing.state': set(),
}
NAME_RE = re.compile(r'^[a-z0-9][a-z0-9_-]{0,63}$')
SESSION_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$')


class RPCFailure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


# ---- state -------------------------------------------------------------------------------------------------------
def sid(n):
    return f'20260929_120000_aabbcc0{n}'


def seed():
    now = int(time.time())
    def chat(n, count, last, preview):
        msgs = []
        for i in range(count):
            role = 'user' if i % 2 == 0 else 'assistant'
            text = f'{"Question" if role == "user" else "Answer"} {i + 1} in this synthetic chat.'
            if i == count - 1:
                text = preview
            msgs.append({'role': role, 'content': text, 'timestamp': last - (count - i) * 60})
        return {'id': sid(n), 'title': 'Bot Chat', 'messages': msgs, 'last_active': last, 'started_at': last - 86400}
    profiles = {
        'default': {'display_name': 'Hermes', 'description': 'Your main agent',
                    'ui_meta': {'hermes-bots': {'pinned': True, 'sectionId': 'hermes-hq-pinned', 'sectionName': 'Pinned', 'pinnedFrom': None},
                                'dispatch-head': {'v': 6, 'theme': 'shape', 'color': 'ink', 'seed': 7, 'form': 'round', 'look': 'ovals',
                                                  'specs': 'none', 'hat': 'none', 'mouth': 'none', 'blush': False, 'tile': 'none'}},
                    'revisions': {'hermes-bots': 3, 'dispatch-head': 2}, 'chat': chat(1, 4, now - 3600, 'All set for today.')},
        'ivy': {'display_name': 'Ivy', 'description': 'Plans trips',
                'ui_meta': {'hermes-bots': {'sectionId': 'sec-work', 'sectionName': 'Work', 'created': 1790000000001}},
                'revisions': {'hermes-bots': 1}, 'chat': chat(2, 6, now - 7200, 'Your flight is booked.')},
        'research': {'display_name': 'Research', 'description': 'Reads papers',
                     'ui_meta': {'hermes-bots': {'sectionId': 'sec-work', 'sectionName': 'Work', 'title': 'Research'},
                                 'dispatch-head': {'v': 6, 'theme': 'shape', 'color': 'lilac', 'seed': 11, 'form': 'hex', 'look': 'slits',
                                                   'specs': 'none', 'hat': 'none', 'mouth': 'none', 'blush': False, 'tile': 'none'}},
                     'revisions': {'hermes-bots': 1, 'dispatch-head': 1}, 'chat': chat(3, 3, now - 10800, 'Three papers to read.')},
        'inbox': {'display_name': 'Inbox', 'description': 'Sorts email',
                  'ui_meta': {'hermes-bots': {'pinned': True, 'sectionId': 'hermes-hq-pinned', 'sectionName': 'Pinned', 'pinnedFrom': None}},
                  'revisions': {'hermes-bots': 1}, 'chat': chat(4, 2, now - 14400, 'Inbox zero.')},
        'deploys': {'display_name': 'Deploys', 'description': 'Ships builds',
                    'ui_meta': {'hermes-bots': {'hidden': True}}, 'revisions': {'hermes-bots': 1}, 'chat': chat(5, 2, now - 18000, 'Build 3 is live.')},
        'notes': {'display_name': 'Notes', 'description': 'Keeps notes', 'ui_meta': {}, 'revisions': {}, 'chat': None},
    }
    # HQN_FIXTURE_EXTRA_BOTS=N: N more plain bots, so the Bots list is long enough to scroll (bar screenshots).
    for i in range(int(os.environ.get('HQN_FIXTURE_EXTRA_BOTS', '0') or 0)):
        profiles[f'extra{i + 1}'] = {'display_name': f'Helper {i + 1}', 'description': 'A long list for scrolling',
                                     'ui_meta': {}, 'revisions': {}, 'chat': None}
    for p in profiles.values():
        p['avatar'] = None
        p['extra_chats'] = []
        if LABEL:
            p['display_name'] = f'{LABEL} {p["display_name"]}'
            p['description'] = f'{LABEL} {p["description"]}'
    # A plain session (not a Bot Chat) so the Sessions tab lists something.
    trip = chat(6, 2, now - 5400, 'Three hotels look good.')
    trip['title'] = 'Trip ideas'
    profiles['ivy']['extra_chats'].append(trip)
    skills = {}
    for name in profiles:
        skills[name] = default_skills()
    mcp = {name: default_mcp() for name in profiles}
    return {'config': cfg.current(), 'env': cfg.env(), 'model': {'provider': 'anthropic', 'model': 'claude-opus-5.5'}, 'models': {},
            'configs': {}, 'auxes': {}, 'aux': cfg.auxiliary(), 'moa': cfg.moa(), 'vault': cfg.vault(), 'logs': [], 'reveals': 0,
            'profiles': profiles, 'skills': skills, 'mcp': mcp, 'writes': [], 'prompts': [], 'rest': [], 'fail': [],
            'install_outcomes': {}, 'actions': {}, 'runtime': None, 'sessions': {}, 'reloads': 0,
            'turn_seconds': 0, 'custom': default_custom(), 'oauth': cfg.oauth()}


def default_custom():
    """[custom-providers] `providers:` entries with an address (Hermes' `_custom_endpoint_response` rows, plus the key)."""
    return [
        {'id': 'together', 'name': 'Together AI', 'base_url': 'https://api.together.ai/v1', 'model': 'deepseek-ai/DeepSeek-V4.1-Flash',
         'models': ['deepseek-ai/DeepSeek-V4.1-Flash', 'meta-llama/Llama-3.3-70B-Instruct-Turbo'], 'api_mode': 'chat_completions',
         'context_length': 1048576, 'discover_models': True, 'key': 'tok-fixture-together', 'source': 'providers'},
        {'id': 'home-server', 'name': 'Home Server', 'base_url': 'http://192.168.1.20:8080/v1', 'model': 'llama-3.3-70b',
         'models': ['llama-3.3-70b'], 'api_mode': '', 'context_length': None, 'discover_models': False, 'key': None,
         'source': 'providers'},
    ]


CUSTOM_FOUND = ['llama-3.3-70b', 'qwen3-coder-30b', 'gpt-oss-120b', 'gemma-3-27b', 'mistral-small-3.2', 'phi-5', 'deepseek-r2-distill',
                'llama-4-scout', 'qwen3-235b', 'granite-4']


def custom_slug(raw):
    return re.sub(r'[^A-Za-z0-9_-]+', '-', str(raw or '')).strip('-_').lower() or 'custom'


def custom_rows():
    current = S['model'].get('provider', '')
    rows = []
    for e in S['custom']:
        rows.append({'id': e['id'], 'name': e['name'], 'base_url': e['base_url'], 'model': e['model'], 'models': list(e['models']),
                     'api_mode': e['api_mode'], 'context_length': e['context_length'], 'discover_models': e['discover_models'],
                     'has_api_key': bool(e['key']), 'api_key_preview': '${CUSTOM_' + e['id'].upper().replace('-', '_') + '_API_KEY}' if e['key'] else None,
                     'is_current': current in (e['id'], 'custom:' + e['id']), 'source': e['source']})
    return {'endpoints': rows, 'current': {'provider': current, 'model': S['model'].get('model', ''), 'base_url': ''}}


def default_skills():
    return {
        'installed': [
            {'name': 'web-search', 'description': 'Search the web and read pages', 'category': 'research', 'enabled': True, 'usage': 30, 'provenance': 'bundled'},
            {'name': 'arxiv', 'description': 'Search and read arXiv papers', 'category': 'research', 'enabled': True, 'usage': 12, 'provenance': 'bundled'},
            {'name': 'github-pr', 'description': 'Review and open pull requests', 'category': 'dev', 'enabled': True, 'usage': 5, 'provenance': 'hub'},
            {'name': 'pdf-reader', 'description': 'Read PDF files', 'category': 'documents', 'enabled': True, 'usage': 2, 'provenance': 'hub'},
            {'name': 'notes-helper', 'description': 'A skill this bot learned', 'category': 'productivity', 'enabled': False, 'usage': 0, 'provenance': 'agent'},
            {'name': 'calendar', 'description': 'Read and add calendar events', 'category': 'productivity', 'enabled': False, 'usage': 0, 'provenance': 'bundled'},
        ],
        'official': [
            {'name': 'blender-mcp', 'description': 'Drive Blender from chat', 'identifier': 'official/creative/blender-mcp', 'category': 'creative'},
            {'name': 'duckduckgo', 'description': 'Private web search', 'identifier': 'official/research/duckduckgo', 'category': 'research'},
            {'name': 'github-pr', 'description': 'Review and open pull requests', 'identifier': 'official/dev/github-pr', 'category': 'dev'},
            {'name': 'pdf-reader', 'description': 'Read PDF files', 'identifier': 'official/documents/pdf-reader', 'category': 'documents'},
        ],
    }


def default_mcp():
    return [
        {'name': 'github', 'transport': 'http', 'url': 'https://api.githubcopilot.com/mcp/', 'command': None, 'args': [], 'env': ['GITHUB_TOKEN'],
         'auth': 'header', 'oauth_tokens_present': None, 'enabled': True, 'tools': None, 'source': 'config', 'plugin': None,
         '_status': 'connected', '_tools': 31},
        {'name': 'files', 'transport': 'stdio', 'url': None, 'command': 'npx', 'args': ['files-mcp'], 'env': [], 'auth': None,
         'oauth_tokens_present': None, 'enabled': False, 'tools': None, 'source': 'config', 'plugin': None, '_status': 'disabled', '_tools': 0},
        {'name': 'browser', 'transport': 'stdio', 'url': None, 'command': 'hermes-hq-browser', 'args': [], 'env': [], 'auth': None,
         'oauth_tokens_present': None, 'enabled': True, 'tools': None, 'source': 'plugin', 'plugin': 'hermes-hq-browser',
         '_status': 'connected', '_tools': 12},
    ]


S = None


def runtime_id(stored):
    return hashlib.sha256(stored.encode()).hexdigest()[:8]


def all_chats():
    """(profile, chat) for every Bot Chat and extra session."""
    for name, p in S['profiles'].items():
        if p['chat']:
            yield name, p['chat']
        for extra in p['extra_chats']:
            yield name, extra


def find_chat(identifier):
    for name, chat in all_chats():
        if identifier in (chat['id'], runtime_id(chat['id'])):
            return name, chat
    return None, None


def session_row(name, chat):
    msgs = chat['messages']
    preview = next((m['content'] for m in reversed(msgs) if m['role'] in ('user', 'assistant')), '')
    return {'id': chat['id'], 'title': chat['title'], 'profile': name, 'profile_name': name, 'hidden': chat['title'] == 'Bot Chat',
            'model': 'fixture-model', 'message_count': len(msgs), 'started_at': chat['started_at'],
            'last_active': chat['last_active'], 'source': 'desktop', 'preview': preview[:80], 'cwd': '/fixture'}


def model_of(name):
    """A profile's own `model` block, as `profiles.list` and `/api/model/*?profile=` read it: the default's is S['model']
    (what Settings › Model changes), every other bot's its own in S['models'] (tester batch 3)."""
    if name == 'default':
        return S['model']
    return S['models'].setdefault(name, {'provider': 'anthropic', 'model': 'claude-sonnet-5'})


# --own-profile-configs: `/api/config?profile=` reads and writes that bot's own record, as Hermes does. Off, every bot
# shares the default's (what the suites built on this fixture expect of a bot's display and voice reads).
OWN_PROFILE_CONFIGS = False


def config_of(name):
    """A profile's own config record (Hermes' `_profile_scope` on `/api/config`: each bot's own config.yaml): the
    default's is S['config'] (what Settings changes), every other bot's its own sparse record in S['configs']."""
    if name == 'default' or not OWN_PROFILE_CONFIGS:
        return S['config']
    return S['configs'].setdefault(name, {})


def aux_of(name):
    """A profile's own auxiliary assignments (`/api/model/auxiliary?profile=`), as `config_of` keeps its config."""
    if name == 'default':
        return S['aux']
    return S['auxes'].setdefault(name, cfg.auxiliary())


def profile_row(name, include_sessions):
    p = S['profiles'][name]
    m = model_of(name)
    row = {'name': name, 'path': f'/fixture/profiles/{name}', 'is_default': name == 'default', 'model': m['model'],
           'provider': m['provider'], 'description': p['description'], 'display_name': p['display_name'],
           'skill_count': len(S['skills'][name]['installed']), 'previous_names': []}
    if include_sessions:
        if p['chat']:
            r = session_row(name, p['chat'])
            row['canonical_session'] = r
            row['last_session'] = r
        else:
            row['canonical_session'] = None
            row['last_session'] = None
    row['ui_meta_revisions'] = dict(p['revisions'])
    if p['ui_meta']:
        row['ui_meta'] = copy.deepcopy(p['ui_meta'])
    row['has_avatar'] = p['avatar'] is not None
    return row


# [m9 settings] The folders GET /api/fs/list knows (Files in a chat; Default Project Folder's check).
FS_TREE = {
    '/fixture': [('src', True), ('docs', True), ('README.md', False), ('notes.txt', False)],
    '/fixture/src': [('main.py', False), ('util.py', False)],
    '/fixture/docs': [('plan.md', False)],
    '/Users/fixture': [('Projects', True)],
    '/Users/fixture/Projects': [('app', True)],
    '/Users/fixture/Projects/app': [('src', True), ('package.json', False)],
    '/Users/fixture/Projects/app/src': [('index.ts', False)],
}


def fs_list(where):
    where = where.rstrip('/') or '/'
    if where not in FS_TREE or where in S.get('fs_missing', ()):
        return {'entries': [], 'error': f'No such directory: {where}'}
    return {'entries': [{'name': n, 'path': f'{where}/{n}', 'isDirectory': d, 'is_dir': d, 'type': 'directory' if d else 'file',
                         'size': 0 if d else 120} for n, d in FS_TREE[where]]}


def resumed(name, chat):
    stored = chat['id']
    out = _resumed(name, chat)
    cwd = S.get('cwd', {}).get(name, '/fixture')
    if cwd is None:
        out['info'].pop('cwd', None)
    else:
        out['info']['cwd'] = cwd
    return out


def _resumed(name, chat):
    stored = chat['id']
    return {'session_id': runtime_id(stored), 'resumed': stored, 'session_key': stored, 'stored_session_id': stored,
            'messages': [], 'messages_omitted': True, 'message_count': len(chat['messages']), 'status': 'idle', 'running': False,
            'inflight': None,
            'info': {'model': 'fixture-model', 'provider': 'fixture', 'cwd': '/fixture', 'title': chat['title'], 'tools': {},
                     'skills': {}, 'mcp_servers': [], 'lazy': True, 'running': False, 'stored_session_id': stored,
                     'profile_name': name, 'desktop_contract': 8}}


# ---- Hermes' profiles.configure ui_meta (tui_gateway/methods_profiles.py:593-645), line for line -------------------
def clean_revisions(raw):
    return {str(k): max(0, int(v)) for k, v in raw.items() if isinstance(v, int) and not isinstance(v, bool)}


def configure_ui_meta(p, params, applied):
    applied['ui_meta'] = False
    try:
        incoming = params['ui_meta']
        if len(json.dumps(incoming)) > 65536:
            return
        expected = params.get('ui_meta_expected_revisions')
        if expected is not None and not isinstance(expected, dict):
            raise ValueError('ui_meta_expected_revisions must be an object')
        revisions = clean_revisions(p['revisions'])
        conflicts = {}
        for key in (incoming if isinstance(expected, dict) else ()):
            wanted, actual = expected.get(key), revisions.get(key, 0)
            if not isinstance(wanted, int) or isinstance(wanted, bool) or wanted < 0 or wanted != actual:
                conflicts[key] = {'expected': wanted, 'actual': actual}
        if conflicts:
            applied['ui_meta_conflicts'] = conflicts
            applied['ui_meta_revisions'] = {key: revisions.get(key, 0) for key in incoming}
            return
        current = copy.deepcopy(p['ui_meta']) if isinstance(p['ui_meta'], dict) else {}
        for key, value in incoming.items():
            if value is None:
                current.pop(key, None)
            else:
                current[key] = value
            revisions[key] = revisions.get(key, 0) + 1
        p['ui_meta'] = current
        p['revisions'] = revisions
        applied['ui_meta'] = True
        applied['ui_meta_revisions'] = {key: revisions[key] for key in incoming}
    except Exception:
        applied['ui_meta'] = False


MAGIC = {'png': [(0, 8, b'\x89PNG\r\n\x1a\n')], 'jpg': [(0, 3, b'\xff\xd8\xff')], 'webp': [(0, 4, b'RIFF'), (8, 12, b'WEBP')]}
MIMES = {'png': 'image/png', 'jpg': 'image/jpeg', 'webp': 'image/webp'}


def resolve(params):
    name = str(params.get('name') or '').strip()
    if not name:
        raise RPCFailure(4063, 'name required')
    if name not in S['profiles']:
        raise RPCFailure(4064, f"profile '{name}' not found")
    return name, S['profiles'][name]


def png_size(blob):
    if blob[:8] != b'\x89PNG\r\n\x1a\n' or len(blob) < 24:
        return None
    return struct.unpack('>II', blob[16:24])


# ---- failures the tests inject ------------------------------------------------------------------------------------
def synced_only(method, params):
    """[main-e2e] A write of the app's synced documents alone (GatewaySync, b5d94705: `hermes-hq-sync.*` ui_meta on the
    default bot). A failure a test arms is for the bot write it makes, not for these, unless armed with synced: true."""
    meta = params.get('ui_meta') if isinstance(params, dict) else None
    return method == 'profiles.configure' and isinstance(meta, dict) and bool(meta) \
        and all(str(k).startswith('hermes-hq-sync.') for k in meta)


def take_failure(method, params=None):
    synced = synced_only(method, params)
    with LOCK:
        for entry in S['fail']:
            if entry['method'] == method and entry['count'] > 0 and entry.get('synced', False) == synced:
                entry['count'] -= 1
                return entry['mode']
    return None


def record_write(method, params):
    logged = copy.deepcopy(params)
    if isinstance(logged.get('data'), str):
        logged['data'] = len(logged['data'])
    if isinstance(logged.get('soul'), str):
        logged['soulText'] = logged['soul']
        logged['soul'] = len(logged['soul'])
    with LOCK:
        S['writes'].append({'method': method, 'params': logged, 'at': time.time()})


# ---- RPC ----------------------------------------------------------------------------------------------------------
def rpc(method, params):
    allowed = CONTRACT.get(method)
    if allowed is not None:
        for key in params:
            if key not in allowed:
                raise RPCFailure(4000, f'invalid params for {method}: {key}: Extra inputs are not permitted')
    if method in ('profiles.configure', 'profiles.set_asset', 'profiles.create', 'reload.mcp', 'session.create', 'session.title') \
            or (method.startswith('vault.') and method not in ('vault.list', 'vault.sources')):
        record_write(method, params)
    mode = take_failure(method, params)
    if mode == 'slow':
        time.sleep(35)
    elif mode == 'error':
        raise RPCFailure(5064, 'disk full')
    elif mode == 'applied-false' and method == 'profiles.configure':
        return {'ok': False, 'applied': {'ui_meta': False}}
    elif mode == 'no-applied' and method == 'profiles.configure':
        return {'ok': True}

    with LOCK:
        if method == 'profiles.list':
            include = params.get('include_sessions', True)
            include = include if isinstance(include, bool) else str(include).lower() not in ('0', 'false', 'no', '')
            return {'profiles': [profile_row(n, include) for n in S['profiles']], 'bot_mode_protocol': True, 'install_id': 'fixture'}
        if method == 'profiles.configure':
            name, p = resolve(params)
            applied = {}
            if isinstance(params.get('ui_meta'), dict):
                configure_ui_meta(p, params, applied)
            if isinstance(params.get('soul'), str):
                applied['soul'] = True
            if isinstance(params.get('description'), str):
                p['description'] = params['description'].strip()
                applied['description'] = True
            return {'ok': all(applied.values()) if applied else True, 'applied': applied}
        if method == 'profiles.set_asset':
            asset = str(params.get('asset') or 'avatar').strip().lower()
            if not str(params.get('name') or '').strip():
                raise RPCFailure(4063, 'name required')
            if asset != 'avatar':
                raise RPCFailure(4066, f"unknown asset '{asset}' (supported: avatar)")
            name, p = resolve(params)
            if params.get('clear') in (True, 'true', '1', 1):
                removed = 1 if p['avatar'] is not None else 0
                p['avatar'] = None
                return {'ok': True, 'asset': asset, 'size': 0, 'removed': removed}
            data = str(params.get('data') or '')
            if not data:
                raise RPCFailure(4067, 'data required (data URL or base64)')
            m = re.match(r'^data:(image/(?:png|jpeg|webp));base64,(.*)$', data, re.DOTALL)
            try:
                blob = base64.b64decode(m.group(2) if m else data, validate=True)
            except Exception:
                raise RPCFailure(4068, 'data is not valid base64')
            if len(blob) > 2_000_000:
                raise RPCFailure(4069, f'asset too large ({len(blob)} bytes; max 2MB)')
            ext = next((e for e, magic in MAGIC.items() if all(blob[a:b] == mm for a, b, mm in magic)), None)
            if ext is None:
                raise RPCFailure(4070, 'unsupported image format (PNG/JPEG/WebP only)')
            p['avatar'] = (ext, blob)
            return {'ok': True, 'asset': asset, 'size': len(blob)}
        if method == 'profiles.get_asset':
            name, p = resolve(params)
            if p['avatar'] is None:
                return {'found': False}
            ext, blob = p['avatar']
            mime = MIMES[ext]
            return {'found': True, 'mime': mime, 'size': len(blob), 'data': f'data:{mime};base64,{base64.b64encode(blob).decode()}'}
        if method == 'profiles.create':
            name = str(params.get('name') or '').strip()
            if not name:
                raise RPCFailure(4061, 'name required')
            if name in S['profiles']:
                raise RPCFailure(4062, f"Profile '{name}' already exists")
            if not NAME_RE.match(name):
                raise RPCFailure(4062, f"Invalid profile name '{name}'")
            source = str(params.get('clone_from') or '').strip()
            if source and source not in S['profiles']:
                raise RPCFailure(4064, f"profile '{source}' not found")
            S['profiles'][name] = {'display_name': '', 'description': str(params.get('description') or '').strip(), 'ui_meta': {},
                                   'revisions': {}, 'chat': None, 'avatar': None, 'extra_chats': [], 'cloned_from': source or None}
            S['skills'][name] = copy.deepcopy(S['skills'][source]) if source else default_skills()
            S['mcp'][name] = copy.deepcopy(S['mcp'][source]) if source else default_mcp()
            soul = params.get('soul')
            return {'ok': True, 'name': name, 'path': f'/fixture/profiles/{name}',
                    'soul_written': isinstance(soul, str) and bool(soul.strip()), 'model_set': False,
                    'mirrored': {'env': False, 'auth': 'shared', 'model_inherited': False, 'voice': False}}
        if method == 'setup.runtime_check':
            answer = S['runtime']
            S['runtime'] = None
            if answer is not None:
                return {**answer, 'profile': params.get('profile')}
            return {'ok': True, 'provider': 'fixture', 'model': 'fixture-model', 'profile': params.get('profile')}
        if method == 'mcp.servers.list':
            name = params.get('profile') or 'default'
            return {'servers': [{k: v for k, v in s.items() if not k.startswith('_')} for s in S['mcp'].get(name, [])]}
        if method == 'mcp.servers.status':
            name = params.get('profile') or 'default'
            rows = []
            for s in S['mcp'].get(name, []):
                status = s['_status'] if s['enabled'] else 'disabled'
                rows.append({'name': s['name'], 'transport': s['transport'], 'tools': s['_tools'] if s['enabled'] else 0,
                             'connected': status == 'connected', 'disabled': not s['enabled'], 'status': status,
                             'source': s['source'], 'plugin': s['plugin']})
            return {'servers': rows, 'checked_at': int(time.time())}
        if method == 'reload.mcp':
            S['reloads'] += 1
            for servers in S['mcp'].values():
                for s in servers:
                    if s['enabled'] and s['_status'] in ('configured', 'disabled'):
                        s['_status'], s['_tools'] = 'connected', s['_tools'] or 8
            return {'status': 'reloaded', 'message': None}
        if method == 'session.list':
            name = params.get('profile') or 'default'
            title = params.get('title')
            p = S['profiles'].get(name)
            rows = []
            if p:
                chats = ([p['chat']] if p['chat'] else []) + p['extra_chats']
                rows = [session_row(name, c) for c in chats if not title or c['title'] == title]
            return {'sessions': rows, 'total': len(rows)}
        if method == 'session.create':
            name = params.get('profile') or 'default'
            if params.get('cwd') and params['cwd'].rstrip('/') in S.get('fs_missing', ()):
                raise RPCFailure(4003, f"cwd not found: {params['cwd']}")   # [m9 settings] a folder that vanished
            p = S['profiles'].get(name)
            if p is None:
                raise RPCFailure(4064, f"profile '{name}' not found")
            stored = time.strftime('%Y%m%d_%H%M%S_') + secrets.token_hex(4)
            chat = {'id': stored, 'title': params.get('title') or 'New Chat', 'messages': [], 'last_active': time.time(),
                    'started_at': time.time()}
            if chat['title'] == 'Bot Chat' and p['chat'] is None:
                p['chat'] = chat
            else:
                p['extra_chats'].append(chat)
            return {'session_id': runtime_id(stored), 'stored_session_id': stored, 'title': chat['title'], 'profile': name}
        if method == 'session.title':
            name, chat = find_chat(params.get('session_id'))
            if chat and params.get('title'):
                chat['title'] = params['title']
            return {'ok': True, 'title': params.get('title')}
        if method in ('session.resume', 'session.activate'):
            name, chat = find_chat(params.get('session_id'))
            if not chat:
                raise RPCFailure(4007, 'session not found')
            return resumed(name, chat)
        if method in ('session.info', 'session.get'):
            name, chat = find_chat(params.get('session_id'))
            if not chat:
                raise RPCFailure(4007, 'session not found')
            return resumed(name, chat)['info']
        if method == 'vault.list':
            return {'items': copy.deepcopy(S['vault']['items'])}
        if method == 'vault.sources':
            return {'sources': copy.deepcopy(S['vault']['sources'])}
        if method == 'vault.add':
            kind = params.get('kind')
            if kind not in ('login', 'payment', 'address') or not str(params.get('label') or '').strip():
                raise RPCFailure(4072, 'kind and label are required')
            secret = params.get('secret') if isinstance(params.get('secret'), dict) else {}
            item = {'id': f"v{S['vault']['next']}", 'kind': kind, 'label': params['label'], 'origin': params.get('origin'),
                    'created_at': '2026-10-11T12:00:00Z', 'backend': 'local'}
            if kind == 'login':
                item['identifier'] = secret.get('identifier')
                item['identifier_type'] = secret.get('identifier_type')
            S['vault']['next'] += 1
            S['vault']['items'].append(item)
            # Only the secret's field names are recorded, never its values.
            S['writes'][-1]['params']['secret'] = sorted(secret.keys())
            return {'id': item['id']}
        if method == 'vault.remove':
            before = len(S['vault']['items'])
            S['vault']['items'] = [i for i in S['vault']['items'] if i['id'] != params.get('id')]
            return {'removed': len(S['vault']['items']) < before}
        if method == 'vault.source.set':
            source = next((x for x in S['vault']['sources'] if x['name'] == params.get('name')), None)
            if not source:
                raise RPCFailure(4073, 'unknown source')
            source['enabled'] = bool(params.get('enabled'))
            if not source['enabled']:
                source['unlocked'] = False
            return {'enabled': source['enabled']}
        if method == 'vault.unlock':
            source = next((x for x in S['vault']['sources'] if x['name'] == params.get('name')), None)
            ok = source is not None and params.get('password') == cfg.VAULT_MASTER
            S['writes'][-1]['params']['password'] = 'ok' if ok else 'wrong'
            if not ok:
                raise RPCFailure(4074, 'Wrong master password.')
            source['unlocked'] = True
            return {'unlocked': True}
        if method == 'vault.lock':
            source = next((x for x in S['vault']['sources'] if x['name'] == params.get('name')), None)
            if source:
                source['unlocked'] = False
            return {'locked': True}
        if method == 'billing.state':
            return cfg.billing()
        if method == 'session.active_list':
            return {'sessions': []}
        if method == 'session.interrupt':
            return {'status': 'interrupted'}
        if method == 'model.options':
            # [provider-manager] The chat's model menus read the same catalog Settings does (custom endpoints as custom:<id>).
            options = cfg.model_options(S['env'])
            options['providers'] += [{'slug': 'custom:' + e['id'], 'name': e['name'], 'models': list(e['models']),
                                      'authenticated': True, 'is_user_defined': True} for e in S['custom']]
            return {**options, **model_of('default')}
    return voice.rpc(method, params)


def emit(stored, kind, payload=None):
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'session_id': runtime_id(stored), 'payload': payload or {}}}
    with LOCK:
        clients = list(CLIENTS)
    for client in clients:
        try:
            client.send(frame)
        except OSError:
            pass


# [live-steps] What a long turn does meanwhile: the Lock Screen card names each step ("Running npm test…") and the two
# before it. Spread over the turn's length, each a tool.start and its tool.complete.
LONG_TURN_STEPS = [
    ('read_file', {'path': '/Users/ivy/app/package.json'}),
    ('search_files', {'pattern': 'flaky'}),
    ('terminal', {'command': 'cd /Users/ivy/app && npm test'}),
    ('web_search', {'query': 'swift actor reentrancy'}),
    ('write_file', {'path': '/Users/ivy/app/Tests/RetryTests.swift'}),
    ('terminal', {'command': 'swift test --filter RetryTests'}),
]


def work_steps(stored, seconds):
    gap = seconds / (len(LONG_TURN_STEPS) + 1)
    for n, (name, args) in enumerate(LONG_TURN_STEPS):
        time.sleep(gap)
        emit(stored, 'tool.start', {'name': name, 'tool_id': f'call_live_{n}', 'args': args})
        time.sleep(min(0.5, gap / 2))
        emit(stored, 'tool.complete', {'name': name, 'tool_id': f'call_live_{n}', 'result': 'ok'})
    time.sleep(gap)


def stream_intro(name, chat, user_text):
    time.sleep(0.5)
    with LOCK:
        p = S['profiles'].get(name)
        shown = (p['ui_meta'].get('hermes-bots', {}).get('title') if p else None) or (p['display_name'] if p else '') \
            or re.sub(r'[-_]+', ' ', name).title()
        text = f"Hi! I'm {shown}."
    emit(chat['id'], 'message.start')
    with LOCK: long = S.get('turn_seconds') or 0
    if long:
        work_steps(chat['id'], long)   # [live] a long turn (POST /__settings/turn) is working all that time, step by step
    else:
        time.sleep(0.15)
    emit(chat['id'], 'message.delta', {'text': text})
    time.sleep(0.15)
    with LOCK:
        chat['messages'].append({'role': 'assistant', 'content': text, 'timestamp': time.time()})
        chat['last_active'] = time.time()
        row = len(chat['messages'])
    emit(chat['id'], 'message.complete', {'text': text, 'status': 'complete', 'row_id': row})


class Client:
    def __init__(self, connection):
        self.connection, self.lock = connection, threading.Lock()

    def send(self, value):
        body = json.dumps(value).encode()
        n = len(body)
        header = bytes([0x81]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('>H', n) if n < 65536 else bytes([127]) + struct.pack('>Q', n))
        with self.lock:
            self.connection.sendall(header + body)

    def answer(self, frame):
        method, params = frame['method'], frame.get('params') or {}
        reply = {'jsonrpc': '2.0', 'id': frame['id']}
        try:
            if method == 'prompt.submit':
                name, chat = find_chat(params.get('session_id'))
                if not chat:
                    raise RPCFailure(4007, 'session not found')
                with LOCK:
                    chat['messages'].append({'role': 'user', 'content': params.get('text', ''), 'timestamp': time.time()})
                    chat['last_active'] = time.time()
                    S['prompts'].append({'profile': name, 'session': chat['id'], 'text': params.get('text', '')})
                    row = len(chat['messages'])
                reply['result'] = {'status': 'streaming', 'user_row_id': row}
                self.send(reply)
                threading.Thread(target=stream_intro, args=(name, chat, params.get('text', '')), daemon=True).start()
                return
            reply['result'] = rpc(method, params)
        except RPCFailure as failure:
            reply['error'] = {'code': failure.code, 'message': failure.message}
        except ValueError as error:
            reply['error'] = {'code': -32001, 'message': str(error)}
        try:
            self.send(reply)
        except OSError:
            pass


def websocket(connection, key):
    """A copy of the reference fixture's loop that keeps a client registry (events) and answers off the reader."""
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
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
        CLIENTS.add(client)
    try:
        client.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {'heartbeat': True, 'change_events': True, 'replay_epoch': 'settings', 'desktop_contract': 8}}})
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
            if 'id' not in frame or 'method' not in frame:
                continue
            threading.Thread(target=client.answer, args=(frame,), daemon=True).start()
    except (ConnectionError, OSError, ValueError):
        return
    finally:
        with LOCK:
            CLIENTS.discard(client)


voice.auth.websocket = websocket


# ---- REST ---------------------------------------------------------------------------------------------------------
def skill_rows(name):
    return [dict(s) for s in S['skills'][name]['installed']]


def official_rows(name):
    installed = {s['name'] for s in S['skills'][name]['installed']}
    return [{**s, 'source': 'official', 'trust_level': 'builtin', 'repo': None, 'tags': [], 'installed': s['name'] in installed}
            for s in S['skills'][name]['official']]


def start_action(kind, name, identifier, skill):
    action = f"skills-{kind}-{re.sub(r'[^a-z0-9]+', '-', identifier.lower()).strip('-')}-{secrets.token_hex(4)}"
    outcome = S['install_outcomes'].pop(identifier, None) if kind == 'install' else None
    S['actions'][action] = {'polls': 0, 'kind': kind, 'profile': name, 'identifier': identifier, 'skill': skill,
                            'outcome': outcome, 'pid': 4000 + len(S['actions'])}
    return {'ok': True, 'pid': S['actions'][action]['pid'], 'name': action}


def action_status(action):
    a = S['actions'].get(action)
    if a is None:
        return None
    a['polls'] += 1
    lines = [f"Fetching {a['identifier']}…"]
    if a['polls'] <= 2:
        return {'name': action, 'running': True, 'exit_code': None, 'pid': a['pid'], 'lines': lines}
    outcome = a['outcome']
    if outcome:
        return {'name': action, 'running': False, 'exit_code': int(outcome.get('exit', 1)), 'pid': a['pid'],
                'lines': lines + list(outcome.get('lines', []))}
    if not a.get('done'):
        a['done'] = True
        skills = S['skills'][a['profile']]
        if a['kind'] == 'install':
            entry = next((s for s in skills['official'] if s['identifier'] == a['identifier']), None)
            if entry and not any(s['name'] == entry['name'] for s in skills['installed']):
                skills['installed'].append({'name': entry['name'], 'description': entry['description'], 'category': entry['category'],
                                            'enabled': True, 'usage': 0, 'provenance': 'hub'})
        else:
            skills['installed'] = [s for s in skills['installed'] if s['name'] != a['skill']]
    word = 'Installed' if a['kind'] == 'install' else 'Uninstalled'
    return {'name': action, 'running': False, 'exit_code': 0, 'pid': a['pid'], 'lines': lines + [f"{word} {a['skill']}"]}


def handler(gateway):
    base = voice.handler(gateway)

    class Handler(base):
        def body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try:
                return json.loads(raw or b'{}')
            except ValueError:
                return {}

        def authed(self, path):
            if path.startswith('/api/') and path not in ('/api/status',) and not path.startswith('/api/auth/'):
                if not self.session():
                    self.reply(401, {'error': 'session_expired', 'detail': 'Unauthorized'})
                    return False
            return True

        def rest_failure(self, method, path):
            mode = take_failure(f'{method} {path}')
            if mode:
                self.reply(500, {'detail': 'disk full'})
                return True
            return False

        def log_rest(self, method):
            with LOCK:
                S['rest'].append({'method': method, 'path': self.path, 'at': time.time()})

        def do_GET(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            profile = (query.get('profile') or ['default'])[0]
            if path == '/__settings/state':
                with LOCK:
                    profiles = {n: {'ui_meta': p['ui_meta'], 'revisions': p['revisions'], 'description': p['description'],
                                    'has_avatar': p['avatar'] is not None, 'avatar_size': len(p['avatar'][1]) if p['avatar'] else 0,
                                    'avatar_png': png_size(p['avatar'][1]) if p['avatar'] else None,
                                    'chat': p['chat']['id'] if p['chat'] else None,
                                    'cloned_from': p.get('cloned_from'),
                                    'chats': [c['title'] for c in p['extra_chats']],
                                    'messages': [m['content'] for m in p['chat']['messages']] if p['chat'] else []}
                                for n, p in S['profiles'].items()}
                    return self.reply(200, {'writes': S['writes'], 'profiles': profiles, 'prompts': S['prompts'], 'rest': S['rest'],
                                            'skills': S['skills'], 'mcp': S['mcp'], 'reloads': S['reloads'], 'fail': S['fail'],
                                            'config': S['config'], 'env_set': {k: v.get('value') is not None for k, v in S['env'].items()},
                                            'model': S['model'], 'models': S['models'], 'aux': S['aux'], 'moa': S['moa'],
                                            'configs': S['configs'], 'auxes': S['auxes'],
                                            'vault': S['vault']['items'],
                                            'vault_sources': S['vault']['sources'], 'logs': S['logs'], 'reveals': S['reveals']})
            if path.startswith('/__'):
                return super().do_GET()
            if path.startswith('/api/auth/') or path == '/api/ws':
                return super().do_GET()
            if path == '/api/status':
                return self.reply(200, {'version': '0.21.5', 'release_date': '2026.10.01', 'auth_required': True, 'desktop_contract': 8})
            if not self.authed(path):
                return
            self.log_rest('GET')
            if self.rest_failure('GET', path):
                return
            with LOCK:
                if path == '/api/profiles/sessions':
                    p = S['profiles'].get(profile)
                    if p is None:
                        return self.reply(404, {'detail': 'Unknown profile'})
                    least = int((query.get('min_messages') or ['0'])[0])
                    limit = max(1, int((query.get('limit') or ['50'])[0]))
                    chats = ([p['chat']] if p['chat'] else []) + p['extra_chats']
                    rows = sorted((session_row(profile, c) for c in chats if len(c['messages']) >= least), key=lambda r: -r['last_active'])
                    return self.reply(200, {'sessions': rows[:limit], 'total': len(rows)})
                if path == '/api/profiles/sessions/sidebar':
                    rows = sorted((session_row(n, c) for n, c in all_chats()), key=lambda r: -r['last_active'])
                    return self.reply(200, {'recents': {'sessions': rows, 'total': len(rows)}, 'cron': {'sessions': [], 'total': 0},
                                            'messaging': {'sessions': [], 'total': 0}})
                m = re.match(r'^/api/sessions/([^/]+)(/messages)?$', path)
                if m:
                    identifier = unquote(m.group(1))
                    if not SESSION_RE.match(identifier):
                        return self.reply(400, {'detail': 'bad session id'})
                    name, chat = find_chat(identifier)
                    if not chat:
                        return self.reply(404, {'detail': 'Session not found'})
                    if not m.group(2):
                        return self.reply(200, session_row(name, chat))
                    messages = [{**msg, 'row_id': i + 1, 'id': i + 1} for i, msg in enumerate(chat['messages'])]
                    offset = max(0, int((query.get('offset') or ['0'])[0]))
                    limit = min(500, max(1, int((query.get('limit') or ['500'])[0])))
                    order = (query.get('order') or ['latest'])[0]
                    page = list(reversed(messages))[offset:offset + limit][::-1] if order == 'latest' else messages[offset:offset + limit]
                    more = offset + len(page) < len(messages)
                    return self.reply(200, {'session_id': chat['id'], 'profile': name, 'messages': page,
                                            'pagination': {'limit': limit, 'offset': offset, 'order': order, 'returned': len(page),
                                                           'has_more': more, 'next_offset': offset + len(page), 'total': len(messages)}})
                if path == '/api/fs/list':
                    with LOCK:
                        return self.reply(200, fs_list((query.get('path') or ['/fixture'])[0]))
                if path == '/api/config':
                    if OWN_PROFILE_CONFIGS and profile not in S['profiles']:
                        return self.reply(404, {'detail': f"Profile '{profile}' does not exist."})
                    if (query.get('include_defaults') or [''])[0] == 'false':
                        return self.reply(200, copy.deepcopy(config_of(profile)))
                    return self.reply(200, cfg.deep_merge(cfg.defaults(), copy.deepcopy(config_of(profile))))
                if path == '/api/config/schema':
                    return self.reply(200, cfg.schema())
                if path == '/api/config/defaults':
                    return self.reply(200, cfg.defaults())
                if path == '/api/env':
                    return self.reply(200, cfg.env_rows(S['env']))
                if path in ('/api/model/info', '/api/model/options', '/api/model/auxiliary') and profile not in S['profiles']:
                    return self.reply(404, {'detail': f"Profile '{profile}' does not exist."})
                if path == '/api/model/info':
                    # [context-window] As Hermes answers: the model's own window, the override, and the one in force.
                    pinned = int((config_of(profile) or {}).get('model_context_length') or 0)
                    return self.reply(200, {**model_of(profile), 'auto_context_length': 1000000, 'config_context_length': pinned,
                                            'effective_context_length': pinned or 1000000})
                if path == '/api/model/options':
                    options = cfg.model_options(S['env'])
                    options['providers'] += [{'slug': 'custom:' + e['id'], 'name': e['name'], 'models': list(e['models']),
                                              'authenticated': True, 'is_user_defined': True} for e in S['custom']]
                    return self.reply(200, {**options, **model_of(profile)})
                if path == '/api/model/auxiliary':
                    return self.reply(200, {'main': model_of(profile), 'tasks': list(aux_of(profile).values())})
                if path == '/api/model/moa':
                    return self.reply(200, S['moa'])
                if path == '/api/providers/oauth':
                    return self.reply(200, copy.deepcopy(S['oauth']))
                if path == '/api/providers/custom-endpoints':
                    return self.reply(200, custom_rows())
                if path == '/api/skills':
                    if profile not in S['skills']:
                        return self.reply(404, {'detail': 'Unknown profile'})
                    return self.reply(200, skill_rows(profile))
                if path == '/api/skills/hub/official':
                    if profile not in S['skills']:
                        return self.reply(404, {'detail': 'Unknown profile'})
                    return self.reply(200, {'skills': official_rows(profile)})
                if path == '/api/skills/content':
                    name = (query.get('name') or [''])[0]
                    skill = next((s for s in S['skills'].get(profile, {}).get('installed', []) if s['name'] == name), None)
                    if not skill:
                        return self.reply(404, {'detail': f"Skill '{name}' not found."})
                    content = (f"---\nname: {name}\ndescription: {skill['description']}\n---\n\n# {name}\n\n{skill['description']}.\n\n"
                               "## When to use\n\n- When the user asks for it.\n- When a task needs it.\n\n```sh\nhermes skills list\n```\n")
                    return self.reply(200, {'name': name, 'content': content, 'path': f'/fixture/skills/{name}/SKILL.md'})
                m = re.match(r'^/api/actions/([^/]+)/status$', path)
                if m:
                    status = action_status(unquote(m.group(1)))
                    return self.reply(200, status) if status else self.reply(404, {'detail': 'Unknown action'})
            return super().do_GET()

        def do_POST(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            profile = (query.get('profile') or ['default'])[0]
            if path.startswith('/__settings/'):
                return self.control(path, self.body())
            if path.startswith('/auth/') or path.startswith('/api/auth/') or path.startswith('/__'):
                return super().do_POST()
            if not self.authed(path):
                return
            self.log_rest('POST')
            if self.rest_failure('POST', path):
                return
            body = self.body()
            with LOCK:
                if path == '/api/plugins/hermes-hq-push/logs':
                    lines = body.get('lines') if isinstance(body.get('lines'), list) else []
                    kinds = []
                    for line in lines:
                        try:
                            kinds.append(json.loads(line).get('k'))
                        except (ValueError, AttributeError):
                            kinds.append(None)
                    S['logs'].append({'reason': body.get('reason'), 'count': len(lines), 'kinds': kinds})
                    return self.reply(200, {'ok': True, 'written': len(lines)})
                if path == '/api/env/reveal':
                    key = str(body.get('key') or '')
                    record_write('POST ' + path, {'key': key})
                    S['reveals'] += 1
                    row = S['env'].get(key)
                    if not row or row.get('value') is None:
                        return self.reply(404, {'detail': f'{key} is not set'})
                    return self.reply(200, {'key': key, 'value': row['value']})
                if path == '/api/model/set':
                    # Hermes' `_profile_scope(body.profile or profile)`: the bot whose model this is (default: the gateway's own).
                    target = str(body.get('profile') or '') or profile
                    record_write('POST ' + path, {**body, **({'query_profile': profile} if 'profile' in query else {})})
                    scope, provider, model = body.get('scope'), str(body.get('provider') or ''), str(body.get('model') or '')
                    if target not in S['profiles']:
                        return self.reply(404, {'detail': f"Profile '{target}' does not exist."})
                    if scope == 'main':
                        if 'ultra' in model and not body.get('confirm_expensive_model'):
                            return self.reply(200, {'ok': False, 'confirm_required': True,
                                                    'confirm_message': 'Claude Opus Ultra costs about 5× more per message than your current model.'})
                        if target == 'default':
                            S['model'] = {'provider': provider, 'model': model}
                            S['config']['model'] = {**S['config'].get('model', {}), 'default': model, 'provider': provider}
                        else:
                            S['models'][target] = {'provider': provider, 'model': model}
                        return self.reply(200, {'ok': True, 'scope': 'main', 'provider': provider, 'model': model})
                    if scope == 'auxiliary':
                        task = body.get('task')
                        tasks = aux_of(target)
                        if task == '__reset__':
                            for t in tasks.values():
                                t['provider'], t['model'] = 'auto', ''
                        elif task in tasks:
                            main = model_of(target)
                            follows = provider == main['provider'] and model == main['model']
                            tasks[task].update({'provider': 'auto' if follows else provider, 'model': '' if follows else model})
                        else:
                            return self.reply(400, {'detail': f'unknown task {task}'})
                        return self.reply(200, {'ok': True, 'scope': 'auxiliary', 'tasks': [task]})
                    return self.reply(400, {'detail': 'scope must be main or auxiliary'})
                if path == '/api/providers/custom-endpoints/validate':
                    record_write('POST ' + path, {k: v for k, v in body.items() if k != 'api_key'})
                    base = str(body.get('base_url') or '').strip().rstrip('/')
                    if not base:
                        return self.reply(200, {'ok': False, 'reachable': True, 'message': 'Enter an endpoint URL first.', 'models': []})
                    if 'unreachable' in base:
                        return self.reply(200, {'ok': False, 'reachable': False, 'message': f'Could not reach {base}/models.', 'models': []})
                    resolved = base if base.endswith('/v1') else base + '/v1'
                    return self.reply(200, {'ok': True, 'reachable': True, 'message': '', 'models': CUSTOM_FOUND,
                                            'model_details': [{'id': m} for m in CUSTOM_FOUND], 'transport_checked': 'chat_completions',
                                            'resolved_base_url': resolved})
                if path == '/api/providers/custom-endpoints':
                    record_write('POST ' + path, {**{k: v for k, v in body.items() if k != 'api_key'},
                                                  'api_key': None if 'api_key' not in body else ('' if body['api_key'] == '' else '<typed>')})
                    name, base, model = (str(body.get(k) or '').strip() for k in ('name', 'base_url', 'model'))
                    if not name:
                        return self.reply(400, {'detail': 'name required'})
                    if not base:
                        return self.reply(400, {'detail': 'base_url required'})
                    if not model:
                        return self.reply(400, {'detail': 'model required'})
                    key = str(body.get('id') or '') or custom_slug(name)
                    entry = next((e for e in S['custom'] if e['id'] == key), None)
                    if entry is None:
                        entry = {'id': custom_slug(key), 'models': [], 'key': None, 'context_length': None, 'source': 'providers'}
                        S['custom'].append(entry)
                    entry.update({'name': name, 'base_url': base.rstrip('/'), 'model': model,
                                  'discover_models': bool(body.get('discover_models', True))})
                    if body.get('api_mode') is not None:
                        entry['api_mode'] = body['api_mode']
                    if model not in entry['models']:
                        entry['models'].insert(0, model)
                    # [provider-manager] Hermes adds the posted `models` to the saved ones (it never drops one).
                    for extra in body.get('models') or []:
                        extra = str(extra).strip()
                        if extra and extra not in entry['models']:
                            entry['models'].append(extra)
                    if body.get('context_length'):
                        entry['context_length'] = int(body['context_length'])
                    if 'api_key' in body:
                        entry['key'] = body['api_key'] or None
                    return self.reply(200, {**custom_rows(), 'ok': True, 'id': entry['id']})
                m = re.match(r'^/api/providers/custom-endpoints/([^/]+)/activate$', path)
                if m:
                    key = unquote(m.group(1))
                    record_write('POST ' + path, {'id': key})
                    entry = next((e for e in S['custom'] if e['id'] == key), None)
                    if entry is None:
                        return self.reply(404, {'detail': 'custom endpoint not found'})
                    S['model'] = {'provider': key, 'model': entry['model']}
                    return self.reply(200, {'ok': True, 'provider': key, 'model': entry['model']})
                if path == '/api/skills/hub/install':
                    identifier = str(body.get('identifier') or '')
                    entry = next((s for s in S['skills'].get(profile, {}).get('official', []) if s['identifier'] == identifier), None)
                    if not entry:
                        return self.reply(400, {'detail': 'identifier is required'})
                    record_write('POST ' + path, {'profile': profile, **body})
                    return self.reply(200, start_action('install', profile, identifier, entry['name']))
                if path == '/api/skills/hub/uninstall':
                    name = str(body.get('name') or '')
                    if not name:
                        return self.reply(400, {'detail': 'name is required'})
                    record_write('POST ' + path, {'profile': profile, **body})
                    return self.reply(200, start_action('uninstall', profile, name, name))
            return self.reply(404, {'detail': 'not in this fixture'})

        def do_PUT(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            profile = (query.get('profile') or ['default'])[0]
            if not self.authed(path):
                return
            self.log_rest('PUT')
            body = self.body()
            record_write('PUT ' + path, {'profile': profile, **body})
            if self.rest_failure('PUT', path):
                return
            with LOCK:
                if path == '/api/config':
                    patch = body.get('config')
                    if not isinstance(patch, dict):
                        return self.reply(422, {'detail': 'config must be an object'})
                    target = str(body.get('profile') or '') or profile
                    if OWN_PROFILE_CONFIGS and target not in S['profiles']:
                        return self.reply(404, {'detail': f"Profile '{target}' does not exist."})
                    cfg.deep_merge(config_of(target), patch)
                    return self.reply(200, {'ok': True})
                if path == '/api/env':
                    key = str(body.get('key') or '')
                    if not re.match(r'^[A-Z][A-Z0-9_]*$', key):
                        return self.reply(400, {'detail': 'invalid key'})
                    row = S['env'].setdefault(key, {'description': '', 'category': 'setting', 'is_password': True, 'advanced': False,
                                                    'url': None, 'provider': None, 'provider_label': None, 'tools': [], 'channel_managed': False})
                    row['value'] = str(body.get('value') or '')
                    return self.reply(200, {'ok': True, 'key': key})
                if path == '/api/model/moa':
                    presets = body.get('presets') if isinstance(body.get('presets'), dict) else {}
                    for preset in presets.values():
                        refs = preset.get('reference_models') or []
                        slots = refs + [preset.get('aggregator') or {}]
                        if not refs or any(not str(x.get('provider') or '').strip() or not str(x.get('model') or '').strip() for x in slots):
                            return self.reply(422, {'detail': 'every Mixture of Agents slot needs a provider and a model'})
                    S['moa'] = copy.deepcopy(body)
                    return self.reply(200, {**S['moa'], 'ok': True})
                if path == '/api/skills/toggle':
                    skill = next((s for s in S['skills'].get(profile, {}).get('installed', []) if s['name'] == body.get('name')), None)
                    if skill:
                        skill['enabled'] = bool(body.get('enabled'))
                    return self.reply(200, {'ok': True, 'name': body.get('name'), 'enabled': bool(body.get('enabled'))})
                m = re.match(r'^/api/mcp/servers/([^/]+)/enabled$', path)
                if m:
                    name = unquote(m.group(1))
                    server = next((s for s in S['mcp'].get(profile, []) if s['name'] == name), None)
                    if server is None:
                        return self.reply(404, {'detail': f"Server '{name}' not found"})
                    if server['source'] == 'plugin':
                        return self.reply(409, {'detail': f"Server '{name}' is provided by plugin '{server['plugin']}' and cannot be modified"})
                    server['enabled'] = bool(body.get('enabled'))
                    server['_status'] = 'configured' if server['enabled'] else 'disabled'
                    return self.reply(200, {'ok': True, 'name': name, 'enabled': server['enabled']})
            return self.reply(404, {'detail': 'not in this fixture'})

        def do_DELETE(self):
            parsed = urlparse(self.path)
            path = parsed.path
            # [provider-add] Sign out of a provider (Hermes' DELETE /api/providers/oauth/{id}): 400 when Hermes can't.
            m = re.match(r'^/api/providers/oauth/([^/]+)$', path)
            if m:
                if not self.authed(path):
                    return
                self.log_rest('DELETE')
                key = unquote(m.group(1))
                record_write('DELETE ' + path, {'id': key})
                if self.rest_failure('DELETE', path):
                    return
                with LOCK:
                    row = next((p for p in S['oauth']['providers'] if p['id'] == key), None)
                    if row is None or not row.get('disconnectable'):
                        return self.reply(400, {'detail': f'{key} cannot be disconnected automatically.'})
                    if not row.get('logged_in'):
                        return self.reply(409, {'detail': f"No stored credentials were removed for {row['name']}."})
                    row['logged_in'] = False
                    row.pop('account', None)
                    return self.reply(200, {'ok': True, 'provider': key})
            m = re.match(r'^/api/providers/custom-endpoints/([^/]+)$', path)
            if m:
                if not self.authed(path):
                    return
                self.log_rest('DELETE')
                key = unquote(m.group(1))
                record_write('DELETE ' + path, {'id': key})
                if self.rest_failure('DELETE', path):
                    return
                with LOCK:
                    entry = next((e for e in S['custom'] if e['id'] == key), None)
                    if entry is None:
                        return self.reply(404, {'detail': 'custom endpoint not found'})
                    S['custom'].remove(entry)
                    if S['model'].get('provider') in (key, 'custom:' + key):
                        S['model'] = {'provider': '', 'model': S['model'].get('model', '')}
                    return self.reply(200, {**custom_rows(), 'ok': True})
            if path == '/api/env':
                if not self.authed(path):
                    return
                self.log_rest('DELETE')
                body = self.body()
                record_write('DELETE ' + path, body)
                if self.rest_failure('DELETE', path):
                    return
                with LOCK:
                    row = S['env'].get(str(body.get('key') or ''))
                    if row is not None:
                        row['value'] = None
                return self.reply(200, {'ok': True})
            m = re.match(r'^/api/profiles/([^/]+)$', path)
            if not m:
                return super().do_DELETE()
            if not self.authed(path):
                return
            self.log_rest('DELETE')
            name = unquote(m.group(1))
            record_write('DELETE ' + path, {'name': name})
            if self.rest_failure('DELETE', path):
                return
            with LOCK:
                if name == 'default':
                    return self.reply(400, {'detail': 'The default profile cannot be deleted.'})
                if name not in S['profiles']:
                    return self.reply(404, {'detail': f"Profile '{name}' not found"})
                del S['profiles'][name]
                S['skills'].pop(name, None)
                S['mcp'].pop(name, None)
                return self.reply(200, {'ok': True, 'path': f'/fixture/profiles/{name}'})

        def control(self, path, body):
            global S
            with LOCK:
                if path == '/__settings/reset':
                    S = seed()
                    return self.reply(200, {'ok': True})
                if path == '/__settings/only':
                    keep = set(body.get('profiles') or [])
                    if not keep or not keep <= set(S['profiles']):
                        return self.reply(400, {'detail': 'profiles: names from the seed'})
                    for name in set(S['profiles']) - keep:
                        del S['profiles'][name]
                        S['skills'].pop(name, None)
                        S['mcp'].pop(name, None)
                    return self.reply(200, {'ok': True, 'profiles': sorted(S['profiles'])})
                if path == '/__settings/cwd':
                    S.setdefault('cwd', {})[body.get('profile') or 'default'] = body.get('cwd')
                    return self.reply(200, {'ok': True})
                if path == '/__settings/fs':
                    S['fs_missing'] = set(body.get('missing') or [])
                    return self.reply(200, {'ok': True})
                if path == '/__settings/desktop-edit':
                    p = S['profiles'].get(body.get('profile'))
                    if not p or not body.get('key'):
                        return self.reply(400, {'detail': 'profile and key'})
                    key = body['key']
                    if body.get('value') is None:
                        p['ui_meta'].pop(key, None)
                    else:
                        p['ui_meta'][key] = body['value']
                    p['revisions'][key] = p['revisions'].get(key, 0) + 1
                    return self.reply(200, {'ok': True, 'revision': p['revisions'][key]})
                if path == '/__settings/bump':
                    p = S['profiles'].get(body.get('profile'))
                    if not p or not p['chat']:
                        return self.reply(400, {'detail': 'a profile with a chat'})
                    now = time.time()
                    p['chat']['messages'].append({'role': 'user', 'content': 'A new question from elsewhere.', 'timestamp': now - 1})
                    p['chat']['messages'].append({'role': 'assistant', 'content': 'A fresh answer is waiting.', 'timestamp': now})
                    p['chat']['last_active'] = now
                    return self.reply(200, {'ok': True, 'last_active': now, 'message_count': len(p['chat']['messages'])})
                if path == '/__settings/chats':
                    # [botinfo-chats] Enough of a bot's own chats for Bot Info's "All Chats with" row (it shows at three).
                    p = S['profiles'].get(body.get('profile'))
                    titles = body.get('titles') or []
                    if not p or not titles or not all(isinstance(t, str) and t for t in titles):
                        return self.reply(400, {'detail': 'profile and titles'})
                    oldest = min([c['last_active'] for c in p['extra_chats']] + [time.time() - 5400])
                    for i, title in enumerate(titles):
                        last = oldest - (i + 1) * 3600
                        stored = f'20261104_0900{len(p["extra_chats"]):02d}_ddeeff{len(p["extra_chats"]):02d}'
                        p['extra_chats'].append({'id': stored, 'title': title, 'last_active': last, 'started_at': last - 86400,
                                                 'messages': [{'role': 'user', 'content': f'About {title}?', 'timestamp': last - 60},
                                                              {'role': 'assistant', 'content': f'Here is {title}.', 'timestamp': last}]})
                    return self.reply(200, {'ok': True, 'chats': [c['title'] for c in p['extra_chats']]})
                if path == '/__settings/fail':
                    S['fail'].append({'method': body.get('method'), 'mode': body.get('mode', 'error'), 'count': int(body.get('count', 1)),
                                      'synced': bool(body.get('synced', False))})
                    return self.reply(200, {'ok': True})
                if path == '/__settings/install-outcome':
                    S['install_outcomes'][body.get('identifier')] = {'exit': body.get('exit', 1), 'lines': body.get('lines', [])}
                    return self.reply(200, {'ok': True})
                if path == '/__settings/turn':
                    seconds = body.get('seconds')
                    if set(body) != {'seconds'} or not isinstance(seconds, (int, float)) or isinstance(seconds, bool) \
                            or not 0 <= seconds <= 120:
                        return self.reply(400, {'detail': 'seconds: a number from 0 to 120, and nothing else'})
                    with LOCK: S['turn_seconds'] = float(seconds)
                    return self.reply(200, {'ok': True})
                if path == '/__settings/runtime':
                    S['runtime'] = {'ok': bool(body.get('ok', False)), 'error': body.get('error')}
                    return self.reply(200, {'ok': True})
            return self.reply(404, {'detail': 'unknown control'})

    return Handler


def main():
    global LABEL, S, OWN_PROFILE_CONFIGS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=9738)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--label', default='', help="prefix this gateway's bot names and descriptions")
    parser.add_argument('--hermes-cookies', action='store_true', help="Hermes' hermes_session_at/rt session, renewed on any API read")
    parser.add_argument('--access-ttl', type=int, default=12 * 60 * 60)
    parser.add_argument('--own-profile-configs', action='store_true', help="each bot's /api/config?profile= is its own")
    args = parser.parse_args()
    LABEL = args.label
    OWN_PROFILE_CONFIGS = args.own_profile_configs
    voice.LABEL = args.label
    voice.ACCEPT_PROMPTS = True
    S = seed()
    username, password = 'settings-fixture', secrets.token_urlsafe(24)
    if args.keep_credentials and pathlib.Path(args.credentials).exists():
        kept = json.loads(pathlib.Path(args.credentials).read_text())
        username, password = kept['username'], kept['password']
    descriptor = os.open(args.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{args.port}'}, output)
    gateway = voice.auth.Gateway(username, password, True, None, hermes=args.hermes_cookies, access_ttl=args.access_ttl)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(gateway))
    print(f'Settings fixture on 127.0.0.1:{args.port}' + (f' ({LABEL})' if LABEL else ''), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
