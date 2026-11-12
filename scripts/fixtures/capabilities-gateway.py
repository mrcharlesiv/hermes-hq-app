#!/usr/bin/env python3
"""Loopback stand-in gateway for the capabilities stream (docs/spec/3x-capabilities.md §13.1). Invented data only.

DECISION: instead of a copy of settings-gateway.py this loads that script by path and adds to it (its sign-in, cookies,
roster, skills, actions, profiles.configure with ui_meta, MCP list/status/enabled all stay one implementation). Added
here: skill usage switches, toolsets + usage + tool setup, MCP add/remove/test/OAuth with a stand-in consent page, the
mcp_servers map in /api/config, /api/logs, plugins.manage, per-bot env with Hermes' reveal limit, and the controls.

Controls (loopback, no auth, never under /api/):
  GET  /__state                 everything + `log` (ordered requests: t, kind, name, profile, params, inflight)
  POST /__seed  {...}           reset:true | servers:N (generated connectors) | reveal_limit:true (next reveal is 429) | mcp:{profile:[rows]} | status:{profile,name,status,tools} |
                                skills:{profile:[rows]} | roster_add:{name,display_name} | roster_remove:name |
                                oauth_auto:"allow"|"deny"|"" | install:{missing_env,warnings,restart_required} |
                                env:{profile,key,value} | plugin:{profile,name,...patch} | toolset:{profile,name,...patch} |
                                plugins_clear:profile (that bot has no plugins)
  POST /__fail  {target,mode,count}   target "rpc:<method>" | "rest:<METHOD> <path>" | "action:<name prefix>";
                                mode error | 500 | hang | exit1 | slow:<ms> | applied-false
  POST /__log   {file,line}     append a log line (file "mcp" or "agent")
  GET  /api/skills/hub/search?q=   [hub] the Skills Hub search (hermes_cli/web_routers/skills.py): HUB below, matched on
                                name/description/tags, plus the official catalog; --no-hub-search answers 404 (an older Hermes)
  GET  /__oauth/authorize?redirect_uri=&state=   Allow / Deny page (auto with oauth_auto or --oauth-auto)
  [plugin-pages] --page-plugin adds "field-notes", a page plugin (scripts/fixtures/page-plugin/): it joins every bot's
                                plugins, GET /api/dashboard/plugins lists it (after a GET /api/dashboard/plugins/rescan with
                                --page-plugin-stale), /dashboard-plugins/[@bot/]field-notes/dist/* serves its files, and
                                /api/plugins/field-notes/notes[/<id>] answers GET/POST/PATCH/DELETE; --page-routes-missing
                                answers its API with FastAPI's bare 404 (a server that hasn't mounted it: restart needed);
                                /__seed page_routes_missing:true|false switches that while running
  [plugin-pages] --memory-wiki-bundle <dist/index.js> (with --page-plugin) also lists "memory-wiki" and serves that real
                                bundle (e.g. ~/.hermes/plugins/memory-wiki/dashboard/dist/index.js), its API answered with
                                invented subjects, days and memory notes: the real plugin's page in the host, no Hermes needed

  python3 scripts/fixtures/capabilities-gateway.py --port 10010 --hermes-cookies --credentials build/fixtures/cap-a.json
"""
import argparse, copy, hashlib, html, importlib.util, io, json, os, pathlib, random, re, secrets, sys, threading, time
from http.server import ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote, urlencode, quote

_spec = importlib.util.spec_from_file_location('settings_gateway', pathlib.Path(__file__).parent / 'settings-gateway.py')
sg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sg)
RPCFailure, LOCK = sg.RPCFailure, sg.LOCK
_official_rows = sg.official_rows
# [hub] A hub skill joins the catalog only so settings-gateway's install action can run it; /official never lists it.
sg.official_rows = lambda name: [r for r in _official_rows(name) if not r.get('_hub')]

ARGS = None
X = None          # this script's own state
# [hub] Skills Hub results beyond the official catalog (`_skill_meta_to_payload`): trusted and community sources.
HUB = [
    {'name': 'pdf-forms', 'description': 'Fill in and flatten PDF forms', 'source': 'github', 'identifier': 'anthropics/skills/pdf-forms',
     'trust_level': 'trusted', 'repo': 'anthropics/skills', 'tags': ['pdf', 'documents']},
    {'name': 'pdf-redact', 'description': 'Black out names and numbers in PDFs before you share them', 'source': 'skills-sh',
     'identifier': 'skills-sh/pdf-redact', 'trust_level': 'community', 'repo': None, 'tags': ['pdf', 'privacy']},
    {'name': 'invoice-pdf', 'description': 'Turn a list of hours into an invoice PDF', 'source': 'clawhub', 'identifier': 'clawhub/invoice-pdf',
     'trust_level': 'community', 'repo': None, 'tags': ['pdf', 'finance']},
    {'name': 'recipe-scaler', 'description': 'Scale a recipe to any number of servings', 'source': 'github',
     'identifier': 'fixture-cook/skills/recipe-scaler', 'trust_level': 'community', 'repo': 'fixture-cook/skills', 'tags': ['cooking']},
]
PROFILE = {'profile'}
sg.CONTRACT.update({
    'mcp.servers.add': PROFILE | {'name', 'config', 'bearer_token', 'preset'},
    'mcp.servers.remove': PROFILE | {'name'},
    'mcp.servers.test': PROFILE | {'name'},
    'mcp.servers.oauth.start': PROFILE | {'name', 'client_redirect_uri'},
    'mcp.servers.oauth.callback': PROFILE | {'name', 'session_id', 'code', 'state', 'error', 'iss'},
    'mcp.servers.oauth.poll': PROFILE | {'name', 'session_id'},
    'mcp.servers.oauth.cancel': PROFILE | {'name', 'session_id'},
    'plugins.manage': PROFILE | {'action', 'key', 'name', 'enable', 'identifier', 'force', 'ref', 'accept_capabilities', 'values', 'catalog_name'},
})
SERVER_NAME = re.compile(r'^[A-Za-z0-9._-]{1,64}$')
FAKE_SECRET = 'ghp_FIXTURESECRET0123456789'


# ---- seeds ------------------------------------------------------------------------------------------------------
def tool_names(n, prefix='tool'):
    base = ['create_issue', 'list_issues', 'get_repo', 'search_code', 'delete_repo']
    return [{'name': base[i] if i < len(base) else f'{prefix}_{i}', 'description': f'Stand-in tool number {i + 1}.'} for i in range(n)]


CATALOG = json.loads(pathlib.Path(__file__).with_name('mcp-catalog.json').read_text())['entries']   # [directory]


def mcp_seed():
    rows = [
        {'name': 'github', 'transport': 'http', 'url': 'https://api.githubcopilot.com/mcp/', 'command': None, 'args': [], 'env': [],
         'auth': 'header', 'oauth_tokens_present': None, 'enabled': True, 'tools': None, 'source': 'config', 'plugin': None,
         '_status': 'connected', '_tools': 5, '_names': tool_names(5),
         '_entry': {'url': 'https://api.githubcopilot.com/mcp/', 'headers': {'Authorization': 'Bearer ' + FAKE_SECRET, 'Accept': 'application/json'},
                    'tools': {'exclude': ['delete_repo']}}},
        {'name': 'files', 'transport': 'stdio', 'url': None, 'command': 'npx', 'args': ['files-mcp'], 'env': ['ROOT'], 'auth': None,
         'oauth_tokens_present': None, 'enabled': False, 'tools': None, 'source': 'config', 'plugin': None, '_status': 'disabled',
         '_tools': 3, '_names': tool_names(3, 'file'), '_entry': {'command': 'npx', 'args': ['files-mcp', '--api-key', 'k-FIXTURESECRET-777'],
                                                               'env': {'ROOT': '/srv/files'}, 'enabled': False}},
        {'name': 'linear', 'transport': 'http', 'url': 'https://mcp.linear.example/mcp', 'command': None, 'args': [], 'env': [],
         'auth': 'oauth', 'oauth_tokens_present': False, 'enabled': False, 'tools': None, 'source': 'config', 'plugin': None,
         '_status': 'disabled', '_tools': 4, '_names': tool_names(4, 'linear'),
         '_entry': {'url': 'https://mcp.linear.example/mcp', 'auth': 'oauth', 'enabled': False}},
        {'name': 'browser', 'transport': 'stdio', 'url': None, 'command': 'hermes-hq-browser', 'args': [], 'env': [], 'auth': None,
         'oauth_tokens_present': None, 'enabled': True, 'tools': None, 'source': 'plugin', 'plugin': 'hermes-hq-browser',
         '_status': 'connected', '_tools': 12, '_names': tool_names(12, 'browser'), '_entry': None},
    ]
    for i in range(max(0, (ARGS.servers or 0) - len(rows))):
        n = f'server-{i + 1:03d}'
        rows.append({'name': n, 'transport': 'http', 'url': f'https://{n}.example/mcp', 'command': None, 'args': [], 'env': [], 'auth': None,
                     'oauth_tokens_present': None, 'enabled': True, 'tools': None, 'source': 'config', 'plugin': None,
                     '_status': 'connected', '_tools': 2, '_names': tool_names(2), '_entry': {'url': f'https://{n}.example/mcp'}})
    if ARGS.tools:
        rows[0]['_tools'] = ARGS.tools
        rows[0]['_names'] = tool_names(ARGS.tools)
    return rows


def toolsets_seed():
    rows = [
        {'name': 'web', 'label': '🌐 Web', 'description': 'Search and read pages.', 'enabled': True, 'configured': False,
         'tools': ['web_search', 'web_extract']},
        {'name': 'terminal', 'label': 'Terminal', 'description': 'Run commands and edit files.', 'enabled': True, 'configured': True,
         'tools': ['terminal', 'read_file', 'write_file']},
        {'name': 'image_gen', 'label': 'Image Generation', 'description': 'Make pictures from a description.', 'enabled': False,
         'configured': True, 'tools': ['image_generate']},
        {'name': 'vision', 'label': 'Vision', 'description': 'Look at images.', 'enabled': True, 'configured': True, 'tools': ['vision_analyze']},
        {'name': 'browser', 'label': 'Browser', 'description': 'Browse the web with a real browser.', 'enabled': True, 'configured': True,
         'tools': ['browser_navigate', 'browser_click', 'browser_type']},
        {'name': 'computer_use', 'label': 'Computer Use', 'description': '', 'enabled': False, 'configured': True, 'tools': ['computer']},
        {'name': 'discord', 'label': 'Discord', 'description': 'Hidden on the phone.', 'enabled': True, 'configured': True, 'tools': ['discord_send']},
        {'name': 'moa', 'label': 'Mixture of Agents', 'description': 'Hidden on the phone.', 'enabled': False, 'configured': True, 'tools': ['moa']},
    ]
    for i in range(max(0, (ARGS.toolsets or 0) - len(rows))):
        rows.append({'name': f'set_{i + 1:03d}', 'label': f'Set {i + 1:03d}', 'description': 'A generated toolset for load tests.',
                     'enabled': i % 2 == 0, 'configured': True, 'tools': [f'set{i}_a', f'set{i}_b']})
    for r in rows:
        r.update({'platform': 'cli', 'platform_label': 'CLI', 'available': r['enabled']})
    return rows


def toolset_config_seed():
    return {
        'web': {'has_category': True, 'providers': [
            {'name': 'Firecrawl', 'badge': '', 'tag': 'Search and read pages', 'status': 'needs_keys', 'post_setup': None,
             'requires_nous_auth': False, 'managed_nous_feature': None, 'web_backend': 'firecrawl', 'capabilities': ['search', 'extract'],
             'env_vars': [{'key': 'FIRECRAWL_API_KEY', 'prompt': 'Firecrawl API key', 'url': 'https://firecrawl.dev', 'default': None}]},
            {'name': 'DuckDuckGo', 'badge': 'free', 'tag': 'Search only', 'status': 'needs_setup', 'post_setup': 'ddgs',
             'requires_nous_auth': False, 'managed_nous_feature': None, 'web_backend': 'ddgs', 'capabilities': ['search'], 'env_vars': []}],
            'active': 'Firecrawl', 'search': 'firecrawl', 'extract': 'firecrawl'},
        'image_gen': {'has_category': True, 'providers': [
            {'name': 'FAL', 'badge': '', 'tag': 'Fast image models', 'status': 'ready', 'post_setup': None, 'requires_nous_auth': False,
             'managed_nous_feature': None, 'env_vars': [{'key': 'FAL_KEY', 'prompt': 'FAL key', 'url': 'https://fal.ai', 'default': None}]}],
            'active': 'FAL', 'model': 'flux-schnell',
            'models': [{'id': 'flux-pro', 'display': 'FLUX Pro', 'speed': '~6s', 'strengths': 'Photoreal', 'price': '$0.05'},
                       {'id': 'flux-schnell', 'display': 'FLUX Schnell', 'speed': '~2s', 'strengths': 'Drafts', 'price': '$0.003'}]},
    }


def backends_seed():
    return {'active': 'local', 'backends': [
        {'name': 'local', 'label': 'Local', 'description': 'Run on the gateway computer.', 'status': 'ready', 'detail': ''},
        {'name': 'docker', 'label': 'Docker', 'description': 'Run inside a container.', 'status': 'needs_setup',
         'detail': 'Docker CLI not found — install Docker Desktop, docker-ce, or Podman.'},
        {'name': 'modal', 'label': 'Modal', 'description': 'Run in a cloud sandbox.', 'status': 'unavailable', 'detail': 'Modal is not installed.'}]}


def plugins_seed():
    rows = [
        {'name': 'kanban', 'key': 'bundled:kanban', 'version': '0.9.0', 'description': 'A task board.', 'source': 'bundled', 'status': 'enabled',
         'portable': True, 'has_desktop_half': True, 'servers': [{'name': 'kanban', 'state': 'connected', 'sentence': ''}],
         'catalog_name': None, 'update_available': False, 'settings_schema': []},
        {'name': 'web-clipper', 'key': 'catalog:web-clipper', 'version': '1.4.0', 'description': 'Save pages your bots can read later.',
         'source': 'catalog', 'status': 'disabled', 'portable': True, 'has_desktop_half': False, 'servers': [], 'catalog_name': 'web-clipper',
         'catalog_version': '1.5.0', 'catalog_sha': '9f2c1ab04d11', 'update_available': True,
         'settings_schema': [
             {'key': 'folder', 'type': 'string', 'label': 'Folder', 'description': 'Where clips are kept.', 'required': True, 'value': 'clips', 'default': 'clips'},
             {'key': 'max_pages', 'type': 'number', 'label': 'Max Pages', 'description': '', 'required': False, 'value': 20, 'default': 20},
             {'key': 'verbose', 'type': 'boolean', 'label': 'Verbose', 'description': 'Log every clip.', 'required': False, 'value': False, 'default': False},
             {'key': 'region', 'type': 'enum', 'label': 'Region', 'description': '', 'required': False, 'value': 'us', 'default': 'us', 'choices': ['us', 'eu', 'asia']},
             {'key': 'token', 'type': 'secret', 'label': 'Clipper Token', 'description': '', 'required': False, 'env': 'CLIPPER_TOKEN', 'has_value': True}]},
        {'name': 'my-plugin', 'key': 'git:my-plugin', 'version': '0.1.0', 'description': 'Installed from a repository.', 'source': 'git',
         'status': 'enabled', 'portable': False, 'has_desktop_half': False, 'servers': [], 'catalog_name': None, 'update_available': False,
         'settings_schema': []},
        {'name': 'local-vision', 'key': 'bundled:local-vision', 'version': '2.0.1', 'description': 'On-device image models.', 'source': 'bundled',
         'status': 'enabled', 'portable': True, 'has_desktop_half': False,
         'servers': [{'name': 'vision', 'state': 'unsupported_gpu', 'sentence': ''}, {'name': 'helper', 'state': 'app_not_running', 'sentence': 'Open the helper app on your computer.'}],
         'catalog_name': None, 'update_available': False, 'settings_schema': []},
    ]
    if ARGS.page_plugin and ARGS.memory_wiki_bundle:
        rows.insert(1, {'name': 'memory-wiki', 'key': 'git:memory-wiki', 'version': '1.1.0', 'description': 'Memory Wiki dashboard tab.',
                        'source': 'git', 'status': 'enabled', 'portable': True, 'has_desktop_half': True, 'servers': [],
                        'catalog_name': 'hermes-memory-wiki', 'update_available': False, 'settings_schema': []})
    if ARGS.page_plugin:   # [plugin-pages]
        rows.insert(1, {'name': 'field-notes', 'key': 'catalog:field-notes', 'version': '0.3.0', 'description': 'Notes your bot keeps, on a page of their own.',
                        'source': 'catalog', 'status': 'enabled', 'portable': True, 'has_desktop_half': False, 'servers': [],
                        'catalog_name': 'field-notes', 'update_available': False, 'settings_schema': []})
    if ARGS.legacy_plugins:
        for r in rows:
            r.pop('key', None)
    return rows


def logs_seed():
    return {'mcp': ["===== starting MCP server 'files' =====", '[files] booting', "===== starting MCP server 'other' =====", '[other] hello from other',
                    "===== starting MCP server 'files' =====", '[files] listening on stdio', '[files] Authorization: Bearer ' + FAKE_SECRET,
                    "===== starting MCP server 'other' =====", '[other] second section of other'],
            'agent': ['2026-10-12 09:14:02 WARNING mcp: github: 401 Unauthorized token=' + FAKE_SECRET,
                      '2026-10-12 09:14:03 INFO mcp: linear: waiting for sign-in', '2026-10-12 09:14:04 INFO mcp: github: connected, 5 tools']}


def seed_all():
    """Everything this script adds, per profile, over a fresh settings seed."""
    global X
    sg.S = sg.seed()
    S = sg.S
    extra = max(0, (ARGS.bots or 0) - len(S['profiles']))
    for i in range(extra):
        add_profile(f'bot{i + 1:03d}', f'Bot {i + 1:03d}', seeding=True)
    if ARGS.skills:
        for skills in S['skills'].values():
            for i in range(max(0, ARGS.skills - len(skills['installed']))):
                skills['installed'].append({'name': f'skill-{i + 1:03d}', 'description': 'A generated skill for load tests.', 'category': 'load',
                                            'enabled': True, 'usage': 0 if i % 2 == 0 else i, 'provenance': 'bundled'})
    if ARGS.no_usage:
        for skills in S['skills'].values():
            for s in skills['installed']:
                s.pop('usage', None)
    S['skills']['default']['official'].append({'name': 'pdf-tools', 'description': 'Split, merge and read PDFs', 'identifier': 'official/documents/pdf-tools', 'category': 'documents'})
    names = list(S['profiles'])
    X = {'log': [], 'inflight': 0, 'fail': [], 'oauth': {}, 'oauth_auto': ARGS.oauth_auto or '', 'reveal_times': [], 'install': {},
         'mcp': {n: mcp_seed() for n in names}, 'toolsets': {n: toolsets_seed() for n in names},
         'toolcfg': {n: toolset_config_seed() for n in names}, 'backends': {n: backends_seed() for n in names},
         'usage': {'web_search': 1200, 'terminal': 12400, 'read_file': 310, 'vision_analyze': 4},
         'plugins': {n: plugins_seed() for n in names}, 'penv': {n: {} for n in names}, 'logs': logs_seed(), 'post': {},
         'notes': {}, 'rescanned': set()}
    S['mcp'] = X['mcp']   # the settings fixture's list/status/enabled handlers read these same rows


def add_profile(name, display, seeding=False):
    S = sg.S
    S['profiles'][name] = {'display_name': display, 'description': 'A generated bot', 'ui_meta': {}, 'revisions': {}, 'chat': None,
                           'avatar': None, 'extra_chats': []}
    S['skills'][name] = sg.default_skills()
    if not seeding:
        X['mcp'][name] = mcp_seed()
        X['toolsets'][name] = toolsets_seed()
        X['toolcfg'][name] = toolset_config_seed()
        X['backends'][name] = backends_seed()
        X['plugins'][name] = plugins_seed()
        X['penv'][name] = {}


# ---- failures, latency and the request log -----------------------------------------------------------------------
def take(target):
    with LOCK:
        for entry in X['fail']:
            if entry['count'] > 0 and (entry['target'] == target or (entry['target'].startswith('action:') and target.startswith(entry['target']))):
                entry['count'] -= 1
                return entry['mode']
    return None


def enter(kind, name, profile, params):
    with LOCK:
        X['inflight'] += 1
        logged = copy.deepcopy(params) if isinstance(params, dict) else {}
        X['log'].append({'t': time.time(), 'kind': kind, 'name': name, 'profile': profile, 'params': logged, 'inflight': X['inflight']})
    delay = (ARGS.latency or 0) + (random.uniform(0, ARGS.jitter) if ARGS.jitter else 0)
    if delay:
        time.sleep(delay / 1000)


def leave():
    with LOCK:
        X['inflight'] -= 1


def apply_mode(mode):
    """Sleeps for slow/hang; returns the mode for the caller to answer with when it is an error kind."""
    if not mode:
        return None
    if mode == 'hang':
        time.sleep(600)
        return 'error'
    if mode.startswith('slow:'):
        time.sleep(int(mode.split(':', 1)[1]) / 1000)
        return None
    return mode


def find_server(profile, name):
    return next((s for s in X['mcp'].get(profile, []) if s['name'] == name), None)


def summary(s):
    return {k: v for k, v in s.items() if not k.startswith('_')}


def redact(value):
    if isinstance(value, dict):
        return {k: redact(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, str) and re.search(r'(FIXTURESECRET|Bearer |token)', value):
        return '***'
    return value


# ---- RPC ----------------------------------------------------------------------------------------------------------
_base_rpc = sg.rpc
RPC_COUNT = [0]


def rpc(method, params):
    profile = params.get('profile') or 'default'
    enter('rpc', method, profile, params)
    try:
        mode = apply_mode(take('rpc:' + method))
        if mode == 'applied-false' and method == 'profiles.configure':
            return {'ok': False, 'applied': {'ui_meta': False}}
        if mode:
            raise RPCFailure(5024, 'disk full')
        if method not in MINE and not method.startswith('mcp.servers.oauth.'):
            return _base_rpc(method, params)
        allowed = sg.CONTRACT.get(method)
        for key in params:
            if allowed is not None and key not in allowed:
                raise RPCFailure(4000, f'invalid params for {method}: {key}: Extra inputs are not permitted')
        if ARGS.read_only and method in ('mcp.servers.add', 'mcp.servers.remove') or (ARGS.read_only and method == 'plugins.manage' and params.get('action') != 'list'):
            raise RPCFailure(4030, 'this gateway is read-only')
        with LOCK:
            return MINE[method](profile, params) if method in MINE else oauth(method, profile, params)
    finally:
        leave()


def mcp_add(profile, params):
    name, config = str(params.get('name') or ''), params.get('config')
    if not SERVER_NAME.match(name):
        raise RPCFailure(4063, 'invalid server name')
    existing = find_server(profile, name)
    if existing is not None:
        if existing['source'] == 'plugin':
            raise RPCFailure(4090, f"server '{name}' is provided by plugin '{existing['plugin']}' and cannot be modified")
        raise RPCFailure(4090, f"server '{name}' already exists")
    if not isinstance(config, dict) or not (config.get('url') or config.get('command')):
        raise RPCFailure(4063, "config must specify a 'url' (HTTP) or 'command' (stdio)")
    if any(str(a).startswith('--upload-pack') for a in config.get('args') or []):
        raise RPCFailure(4001, f"server '{name}' rejected: suspicious command/args configuration")
    entry = copy.deepcopy(config)
    if params.get('bearer_token'):
        var = 'MCP_' + re.sub(r'[^A-Z0-9]', '_', name.upper()) + '_API_KEY'
        X['penv'][profile][var] = str(params['bearer_token'])
        entry['headers'] = {**(entry.get('headers') or {}), 'Authorization': 'Bearer ${' + var + '}'}
    http = bool(entry.get('url'))
    auth = entry.get('auth') or ('header' if entry.get('headers') else None)
    enabled = entry.get('enabled') is not False
    row = {'name': name, 'transport': 'http' if http else 'stdio', 'url': entry.get('url'), 'command': entry.get('command'),
           'args': entry.get('args') or [], 'env': sorted((entry.get('env') or {}).keys()), 'auth': auth,
           'oauth_tokens_present': False if auth == 'oauth' else None, 'enabled': enabled, 'tools': None, 'source': 'config', 'plugin': None,
           '_status': 'configured' if enabled else 'disabled', '_tools': 3, '_names': tool_names(3, name), '_entry': entry}
    # A server re-added with the same address keeps what it had (the tool-rules save is remove-then-add).
    old = X.setdefault('removed', {}).pop((profile, name), None)
    if old and old.get('url') == row['url'] and old.get('command') == row['command']:
        row.update({k: old[k] for k in ('_tools', '_names', 'oauth_tokens_present')})
        if enabled:
            row['_status'] = old['_status'] if old['_status'] != 'disabled' else 'configured'
    X['mcp'][profile].append(row)
    return {'ok': True, 'name': name, 'server': summary(row)}


def mcp_remove(profile, params):
    name = str(params.get('name') or '')
    row = find_server(profile, name)
    if row is None:
        raise RPCFailure(4064, f"server '{name}' not found")
    if row['source'] == 'plugin':
        raise RPCFailure(4090, f"server '{name}' is provided by plugin '{row['plugin']}' and cannot be modified")
    X['mcp'][profile].remove(row)
    X.setdefault('removed', {})[(profile, name)] = row
    return {'ok': True, 'removed': True}


def mcp_test(profile, params):
    name = str(params.get('name') or '')
    row = find_server(profile, name)
    if row is None:
        raise RPCFailure(4064, f"server '{name}' not found")
    if row['auth'] == 'oauth' and not row['oauth_tokens_present']:
        return {'ok': False, 'tools': [], 'error': 'OAuth authentication required — no token found.', 'prompts': 0, 'resources': 0,
                'oauth_needed': True, 'oauth_tokens_present': False}
    if row['_status'] == 'failed':
        return {'ok': False, 'tools': [], 'error': 'Connection refused', 'prompts': 0, 'resources': 0, 'oauth_needed': False,
                'oauth_tokens_present': row['oauth_tokens_present']}
    if row['enabled'] and row['_status'] in ('configured', 'lazy'):
        row['_status'] = 'connected'
    return {'ok': True, 'tools': copy.deepcopy(row['_names']), 'error': None, 'prompts': 0, 'resources': 0, 'oauth_needed': False,
            'oauth_tokens_present': row['oauth_tokens_present']}


def oauth(method, profile, params):
    name = str(params.get('name') or '')
    row = find_server(profile, name)
    if row is None:
        raise RPCFailure(4064, f"server '{name}' not found")
    base = f'http://127.0.0.1:{ARGS.port}'
    if method == 'mcp.servers.oauth.start':
        if row['transport'] != 'http':
            raise RPCFailure(4001, 'stdio servers authenticate via env keys, not OAuth')
        if row['auth'] == 'header':
            raise RPCFailure(4001, 'this server uses header/API-key auth, not OAuth')
        sid, state = 'oa_' + secrets.token_hex(4), secrets.token_hex(8)
        redirect = params.get('client_redirect_uri') if not ARGS.old_oauth else None
        redirect = redirect or f'{base}/api/mcp/oauth/callback'
        query = {'redirect_uri': redirect, 'state': state, 'client_id': 'fixture'}
        X['oauth'][sid] = {'profile': profile, 'name': name, 'state': state, 'status': 'pending', 'error': '', 'cancelled': False,
                           'redirect': redirect}   # the tests read where the provider was told to return
        return {'ok': True, 'session_id': sid, 'auth_url': f'{base}/__oauth/authorize?' + urlencode(query), 'flow': 'loopback'}
    session = X['oauth'].get(str(params.get('session_id') or ''))
    if session is None:
        raise RPCFailure(4064, 'unknown OAuth session')
    if method == 'mcp.servers.oauth.callback':
        if params.get('error'):
            session['status'], session['error'] = 'error', f"The provider said: {params['error']}"
        elif params.get('code') and params.get('state') == session['state']:
            session['status'] = 'approved'
            row['oauth_tokens_present'] = True
            row['_status'] = 'connected' if row['enabled'] else 'disabled'
        else:
            session['status'], session['error'] = 'error', 'state mismatch'
        return {'ok': True}
    if method == 'mcp.servers.oauth.poll':
        tools = copy.deepcopy(row['_names']) if session['status'] == 'approved' else []
        return {'ok': True, 'status': session['status'], 'session_id': params.get('session_id'), 'error_message': session['error'],
                'auth_url': '', 'tools': tools}
    session['cancelled'] = True
    return {'ok': True}


def plugins_manage(profile, params):
    if ARGS.no_plugins_rpc:
        raise RPCFailure(-32601, 'Method not found: plugins.manage')
    action = params.get('action')
    rows = X['plugins'].setdefault(profile, [])
    by_name = lambda n: next((p for p in rows if p['name'] == n), None)
    if action == 'list':
        return {'plugins': copy.deepcopy(rows)}
    if action == 'toggle':
        row = next((p for p in rows if p.get('key') == params.get('key')), None)
        if row is None:
            raise RPCFailure(4064, 'plugin not found')
        row['status'] = 'enabled' if params.get('enable') else 'disabled'
        extra = X['install'] if row['name'] == 'web-clipper' and params.get('enable') else {}
        return {'ok': True, 'restart_required': True, 'gateway_reloaded': False, 'missing_env': list(extra.get('missing_env', [])),
                'warnings': list(extra.get('warnings', []))}
    if action == 'update':
        row = by_name(params.get('name'))
        if row is None:
            raise RPCFailure(4064, 'plugin not found')
        if row['name'] in X.get('python_deps', {}):   # [plugin-ask-bot] /__seed python_deps: Hermes's own refusal
            raise RPCFailure(4021, "The update declares new Python dependencies (%s); run `hermes plugins update %s` in a terminal to review them."
                             % (X['python_deps'][row['name']], row['name']))
        if not params.get('accept_capabilities'):
            lines = X['install'].get('delta_lines') or ['+ tool: clip_page', '+ hook: on_session_start']
            return {'ok': False, 'consent_required': True, 'sha': '9f2c1ab04d11', 'delta_lines': lines}
        row['version'], row['update_available'] = row.get('catalog_version') or row['version'], False
        return {'ok': True, 'sha': '9f2c1ab04d11', 'restart_required': True, 'gateway_reloaded': False}
    if action == 'remove':
        row = by_name(params.get('name'))
        if row is None:
            raise RPCFailure(4064, 'plugin not found')
        rows.remove(row)
        return {'ok': True, 'name': row['name']}
    if action == 'install' and params.get('catalog_name') and not params.get('identifier'):
        # [find-plugins] A Hermes catalog pick (`_plugins_install` catalog_name): the name is the catalog's, the pin its own.
        name = str(params['catalog_name']).strip()
        if ARGS.legacy_plugins:
            raise RPCFailure(4019, "plugins.install requires 'identifier' or 'repo'")
        if by_name(name) is not None or any(p.get('catalog_name') == name for p in rows):
            raise RPCFailure(4090, f"plugin '{name}' is already installed")
        opts = X['install']
        row = {'name': name, 'key': f'catalog:{name}', 'version': '1.0.0', 'description': f'From the Hermes catalog ({name}).',
               'source': 'catalog', 'status': 'enabled' if params.get('enable', True) else 'disabled', 'portable': True,
               'has_desktop_half': False, 'servers': [], 'catalog_name': name, 'catalog_tier': 'community', 'update_available': False,
               'settings_schema': [{'key': 'token', 'type': 'secret', 'label': 'Token', 'description': '', 'required': True,
                                    'env': v, 'has_value': False} for v in opts.get('missing_env', [])]}
        rows.append(row)
        return {'ok': True, 'plugin_name': name, 'name': name, 'enabled': row['status'] == 'enabled',
                'restart_required': opts.get('restart_required', True), 'gateway_reloaded': False,
                'missing_env': list(opts.get('missing_env', [])), 'warnings': list(opts.get('warnings', []))}
    if action == 'install':
        identifier = str(params.get('identifier') or '').strip()
        if not identifier or identifier.startswith('-'):
            raise RPCFailure(4063, 'identifier required')
        name = re.sub(r'\.git$', '', identifier.rstrip('/').split('/')[-1].split(':')[-1])
        if by_name(name) is not None:
            if not params.get('force'):
                raise RPCFailure(4090, f"plugin '{name}' is already installed")
            rows.remove(by_name(name))
        opts = X['install']
        row = {'name': name, 'key': f'git:{name}', 'version': '0.1.0', 'description': f'Installed from {identifier}.', 'source': 'git',
               'status': 'enabled' if params.get('enable', True) else 'disabled', 'portable': False, 'has_desktop_half': False, 'servers': [],
               'catalog_name': None, 'update_available': False, 'pinned_sha': params.get('ref'),
               'settings_schema': [{'key': 'token', 'type': 'secret', 'label': 'Token', 'description': '', 'required': True,
                                    'env': v, 'has_value': False} for v in opts.get('missing_env', [])]}
        if ARGS.legacy_plugins:
            row.pop('key')
        rows.append(row)
        return {'ok': True, 'plugin_name': name, 'name': name, 'enabled': row['status'] == 'enabled',
                'restart_required': opts.get('restart_required', True), 'gateway_reloaded': False,
                'missing_env': list(opts.get('missing_env', [])), 'warnings': list(opts.get('warnings', [])),
                'python_dependencies': [], 'known_issues': []}
    if action == 'settings':
        row = next((p for p in rows if p.get('key') == params.get('key')), None)
        if row is None or not isinstance(params.get('values'), dict):
            raise RPCFailure(4063, 'plugin and values required')
        for field in row['settings_schema']:
            if field['key'] in params['values'] and field['type'] != 'secret':
                field['value'] = params['values'][field['key']]
        return {'ok': True, 'plugin': copy.deepcopy(row)}
    raise RPCFailure(4063, f'unknown action {action}')


def reload_mcp(profile, params):
    sg.S['reloads'] += 1
    sg.record_write('reload.mcp', params)
    for servers in X['mcp'].values():
        for s in servers:
            needs_auth = s['auth'] == 'oauth' and not s['oauth_tokens_present']
            if s['enabled'] and s['_status'] in ('configured', 'disabled') and not needs_auth:
                s['_status'] = 'connected'
    return {'status': 'reloaded', 'message': None}


_answer = sg.Client.answer


def answer(self, frame):
    RPC_COUNT[0] += 1
    if ARGS.drop_every and RPC_COUNT[0] % ARGS.drop_every == 0:
        try:
            self.connection.shutdown(2)
        except OSError:
            pass
        return
    _answer(self, frame)


sg.Client.answer = answer
MINE = {'reload.mcp': reload_mcp, 'mcp.servers.add': mcp_add, 'mcp.servers.remove': mcp_remove, 'mcp.servers.test': mcp_test, 'plugins.manage': plugins_manage}
sg.rpc = rpc


# ---- REST ---------------------------------------------------------------------------------------------------------
def env_is_set(profile, key):
    row = sg.S['env'].get(key)
    return key in X['penv'].get(profile, {}) or bool(row and row.get('value') is not None)


def toolset_config(profile, name):
    c = X['toolcfg'].get(profile, {}).get(name)
    if c is None:
        return {'name': name, 'has_category': False, 'active_provider': None, 'providers': []}
    providers = []
    for p in c['providers']:
        row = copy.deepcopy(p)
        row['is_active'] = p['name'] == c['active']
        for v in row['env_vars']:
            v['is_set'] = env_is_set(profile, v['key'])
        if row['env_vars'] and all(v['is_set'] for v in row['env_vars']) and row['status'] == 'needs_keys':
            row['status'] = 'ready'
        providers.append(row)
    out = {'name': name, 'has_category': c['has_category'], 'active_provider': c['active'], 'providers': providers}
    if name == 'web':
        out.update({'active_search_backend': c['search'], 'active_extract_backend': c['extract'], 'search_via_nous': False, 'extract_via_nous': False})
    return out


def refresh_configured(profile):
    for t in X['toolsets'].get(profile, []):
        c = X['toolcfg'].get(profile, {}).get(t['name'])
        if c and t['name'] == 'web':
            active = next((p for p in toolset_config(profile, 'web')['providers'] if p['is_active']), None)
            t['configured'] = bool(active and active['status'] == 'ready')


def memory_wiki_answer(rest):
    """[plugin-pages] Invented answers in the shape memory-wiki's plugin_api.py gives (subjects, daily logs, notes)."""
    now = time.time()
    sessions = [{'id': f's{i}', 'title': t, 'source': 'cli', 'started_at': now - i * 5400, 'last_active': now - i * 5000, 'preview': p}
                for i, (t, p) in enumerate([('Lisbon trip plan', 'Flights first, then the hotel near Alfama.'),
                                            ('Weekly money summary', 'Spending is down 8% on last month.'),
                                            ('Domain renewal', 'Renewed for two years.')], 1)]
    subjects = [{'slug': slug, 'name': name, 'session_count': n, 'message_count': n * 14, 'first_seen': now - 9 * 86400, 'last_seen': now - n * 3600,
                 'keywords': kw, 'snippets': [snip], 'sessions': sessions[:n]}
                for slug, name, n, kw, snip in [('lisbon', 'Lisbon', 3, ['flights', 'hotel', 'alfama'], 'Flights first, then the hotel near Alfama.'),
                                                ('budget', 'Budget', 2, ['spending', 'summary'], 'Spending is down 8% on last month.'),
                                                ('domains', 'Domains', 1, ['renewal'], 'Renewed for two years.'),
                                                # [plugin-page-fit] one long unbroken path, as real cron prompts have: it
                                                # pushed the owner's Memory Wiki past the phone's edge (2026-11-05)
                                                ('janitor', 'every night', 1, ['/Users/ivy/.hermes/scripts/stale-lease-janitor.sh'],
                                                 'Ran /Users/ivy/.hermes/scripts/stale-lease-janitor-nightly-cleanup.sh then local-d04b7941fa69c50380b562c1e924cd179cfd22edc2c9cb063f4502c8a4b92135')]]
    days = [{'date': time.strftime('%Y-%m-%d', time.localtime(now - d * 86400)), 'session_count': 3 - d, 'message_count': 40 - d * 9,
             'started_at_min': now - d * 86400 - 3600, 'last_active_max': now - d * 86400, 'sessions': sessions[:3 - d],
             'subjects': [{'slug': s['slug'], 'name': s['name'], 'count': 3 - d} for s in subjects[:2]], 'work_items': [{'kind': 'planning', 'text': 'Planned the Lisbon trip', 'session_id': 's1', 'timestamp': now - d * 86400}]}
            for d in range(2)]
    notes = {'memory': ['Prefers short summaries.', 'Lives in Austin.'], 'user': ['Name: Ivy (invented)'], 'memory_count': 2, 'user_count': 1}
    if rest == 'overview':
        return {'subjects': subjects, 'daily_logs': days, 'recent_sessions': sessions, 'notes': notes}
    if rest.startswith('subjects/'):
        return {'subject': next((s for s in subjects if s['slug'] == rest[9:]), subjects[0])}
    if rest.startswith('subjects'):
        return {'subjects': subjects, 'query': '', 'limit': 50}
    if rest.startswith('days/'):
        return {'daily_log': next((d for d in days if d['date'] == rest[5:]), days[0])}
    return {'daily_logs': days, 'limit': 30}


def handler(gateway):
    base = sg.handler(gateway)

    class Handler(base):
        def body(self):
            if not hasattr(self, '_cached_body'):
                self._cached_body = super().body()
            return self._cached_body

        def page(self, status, text):
            data = ("<!doctype html><meta charset='utf-8'><meta name=viewport content='width=device-width'><title>Stand-in sign-in</title>"
                    "<style>body{font:17px -apple-system;padding:24px}a{display:inline-block;padding:12px 20px;border-radius:10px;"
                    "background:#0a84ff;color:#fff;text-decoration:none;margin-right:12px}#deny{background:#8e8e93}</style>" + text).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def redirect(self, location):
            self.send_response(302)
            self.send_header('Location', location)
            self.send_header('Content-Length', '0')
            self.end_headers()

        def route(self, method):
            self.__dict__.pop('_cached_body', None)   # one handler serves every request on a kept-alive connection
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            profile = (query.get('profile') or ['default'])[0]
            if path.startswith('/__'):
                return self.control(method, path, query)
            if ARGS.page_plugin and path.startswith(('/api/dashboard/plugins', '/dashboard-plugins/', '/api/plugins/')):
                return self.page_plugin(method, path, query, profile)
            watched = path.startswith(('/api/tools/', '/api/analytics/', '/api/logs', '/api/env', '/api/config', '/api/actions/tools-post-setup',
                                        '/api/skills/', '/api/mcp/')) or path == '/api/skills'
            if not watched or path.startswith('/api/auth/'):
                return False
            body = self.body() if method != 'GET' else {}   # read before any answer: an unread body corrupts a kept-alive connection
            if not self.authed(path):
                return True
            logged = {k: ('<value>' if k == 'value' else v) for k, v in body.items()} if isinstance(body, dict) else {}
            enter('rest', f'{method} {path}', profile, logged)
            try:
                mode = apply_mode(take(f'rest:{method} {path}'))
                if mode:
                    self.reply(500, {'detail': 'disk full'})
                    return True
                if ARGS.read_only and method != 'GET' and path != '/api/env/reveal':
                    self.reply(403, {'detail': 'This gateway is read-only.'})
                    return True
                with LOCK:
                    return self.mine(method, path, query, profile, body)
            finally:
                leave()

        def raw(self, status, data, kind):
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return True

        def page_plugin(self, method, path, query, profile):
            """[plugin-pages] The dashboard plugin contract (hermes-agent web_server_dashboard.py / dashboard_ui.py) for one fake page plugin."""
            body = self.body() if method not in ('GET', 'HEAD') else {}
            here = pathlib.Path(__file__).parent / 'page-plugin'
            if path in ('/api/dashboard/plugins', '/api/dashboard/plugins/rescan'):
                if path.endswith('/rescan'):
                    if not self.authed(path):
                        return True
                    X['rescanned'].add(profile)
                    enter('rest', f'{method} {path}', profile, {}); leave()
                    return self.reply(200, {'ok': True, 'count': 2}) or True
                rows = [{'name': 'hidden-helper', 'label': 'Helper', 'description': '', 'icon': 'Puzzle', 'version': '1.0.0',
                         'tab': {'path': '/helper', 'position': 'end', 'hidden': True}, 'slots': [], 'entry': 'dist/index.js', 'css': None,
                         'has_api': True, 'source': 'user'}]
                if ARGS.memory_wiki_bundle:
                    rows.insert(0, {'name': 'memory-wiki', 'label': 'Memory Wiki', 'description': 'Browsable session-history wiki with a read-only Persistent Memory audit panel',
                                    'icon': 'Database', 'version': '1.1.0', 'tab': {'path': '/memory-wiki', 'position': 'after:sessions'}, 'slots': [],
                                    'entry': 'dist/index.js', 'css': None, 'has_api': True, 'source': 'user'})
                if not ARGS.page_plugin_stale or profile in X['rescanned']:
                    rows.insert(0, {'name': 'field-notes', 'label': 'Field Notes', 'description': 'Notes your bot keeps, on a page of their own.',
                                    'icon': 'NotebookPen', 'version': '0.3.0', 'tab': {'path': '/field-notes', 'position': 'after:skills'},
                                    'slots': [], 'entry': 'dist/index.js', 'css': 'dist/style.css', 'has_api': True, 'source': 'user'})
                enter('rest', f'{method} {path}', profile, {}); leave()
                return self.reply(200, rows) or True
            if path.startswith('/dashboard-plugins/'):
                rest = path[len('/dashboard-plugins/'):]
                if rest.startswith('@'):
                    rest = rest.split('/', 1)[1] if '/' in rest else ''
                files = {'field-notes/dist/index.js': ('field-notes.js', 'application/javascript'), 'field-notes/dist/style.css': ('field-notes.css', 'text/css')}
                if rest == 'memory-wiki/dist/index.js' and ARGS.memory_wiki_bundle:
                    return self.raw(200, pathlib.Path(ARGS.memory_wiki_bundle).expanduser().read_bytes(), 'application/javascript; charset=utf-8')
                if rest not in files:
                    return self.reply(404, {'detail': 'Plugin not found'}) or True
                name, kind = files[rest]
                return self.raw(200, (here / name).read_bytes(), kind + '; charset=utf-8')
            if not self.authed(path):
                return True
            if ARGS.memory_wiki_bundle and path.startswith('/api/plugins/memory-wiki/') and not X.get('routes_missing'):
                enter('rest', f'{method} {path}', profile, {}); leave()
                return self.reply(200, memory_wiki_answer(path[len('/api/plugins/memory-wiki/'):])) or True
            prefix = '/api/plugins/field-notes'
            if ARGS.page_routes_missing or X.get('routes_missing') or not (path == prefix or path.startswith(prefix + '/')):
                return self.reply(404, {'detail': 'Not Found'}) or True
            enter('rest', f'{method} {path}', profile, body if isinstance(body, dict) else {}); leave()
            with LOCK:
                notes = X['notes'].setdefault(profile, [
                    {'id': 'n1', 'title': 'Ask about the Lisbon trip', 'body': 'Flights first, then the hotel.', 'tag': 'urgent', 'done': False},
                    {'id': 'n2', 'title': 'A weekly money summary', 'body': 'Sunday evening, short.', 'tag': 'idea', 'done': False},
                    {'id': 'n3', 'title': 'Renew the domain', 'body': 'Done on the 2nd.', 'tag': 'note', 'done': True}])
                rest = path[len(prefix):].strip('/')
                if rest == 'notes' and method == 'GET':
                    bot = sg.S['profiles'].get(profile, {}).get('display_name') or profile.title()
                    return self.reply(200, {'notes': notes, 'bot': bot, 'updated': '2026-11-05T09:00:00Z'}) or True
                if rest == 'notes' and method == 'POST':
                    note = {'id': 'n' + secrets.token_hex(3), 'title': str(body.get('title') or 'Untitled'), 'body': '', 'tag': str(body.get('tag') or 'note'), 'done': False}
                    notes.insert(0, note)
                    return self.reply(200, note) or True
                if rest.startswith('notes/'):
                    note = next((n for n in notes if n['id'] == rest[6:]), None)
                    if note is None:
                        return self.reply(404, {'detail': 'Note not found'}) or True
                    if method == 'PATCH':
                        note.update({k: v for k, v in body.items() if k in ('title', 'body', 'tag', 'done')})
                        return self.reply(200, note) or True
                    if method == 'DELETE':
                        notes.remove(note)
                        return self.reply(200, {'ok': True}) or True
            return self.reply(405, {'detail': 'Method Not Allowed'}) or True

        def mine(self, method, path, query, profile, body):
            S = sg.S
            if path == '/api/skills/hub/search' and method == 'GET':
                if ARGS.no_hub_search:
                    return self.reply(404, {'detail': 'Not Found'}) or True
                q = ((query.get('q') or [''])[0]).strip().lower()
                if not q:
                    return self.reply(200, {'results': [], 'source_counts': {}, 'timed_out': [], 'installed': {}}) or True
                official = [{'name': o['name'], 'description': o['description'], 'source': 'official', 'identifier': o['identifier'],
                             'trust_level': 'builtin', 'repo': None, 'tags': []} for o in S['skills'].get(profile, {}).get('official', [])
                            if not o.get('_hub')]
                hits = [r for r in official + HUB if q in r['name'].lower() or q in r['description'].lower() or any(q in t for t in r['tags'])]
                names = {x['name'] for x in S['skills'].get(profile, {}).get('installed', [])}
                installed = {r['identifier']: {'name': r['name'], 'trust_level': r['trust_level'], 'scan_verdict': 'safe'}
                             for r in hits if r['source'] != 'official' and r['name'] in names}
                counts = {}
                for r in hits:
                    counts[r['source']] = counts.get(r['source'], 0) + 1
                return self.reply(200, {'results': copy.deepcopy(hits[:20]), 'source_counts': counts, 'timed_out': [], 'installed': installed}) or True
            if path == '/api/skills/hub/install' and method == 'POST':
                hub = next((r for r in HUB if r['identifier'] == str(body.get('identifier') or '')), None)
                catalog = S['skills'].get(profile, {}).get('official')
                if hub and catalog is not None and not any(o['identifier'] == hub['identifier'] for o in catalog):
                    # A hub skill installs the way an official one does (settings-gateway's install action).
                    catalog.append({'name': hub['name'], 'description': hub['description'], 'identifier': hub['identifier'],
                                    'category': 'hub', '_hub': True})
                if take('action:skills-install'):
                    S['install_outcomes'][str(body.get('identifier') or '')] = {'exit': 1, 'lines': ['error: the download failed']}
                return False
            if path == '/api/tools/toolsets' and method == 'GET':
                if ARGS.no_toolsets:
                    return self.reply(404, {'detail': 'Not Found'}) or True
                return self.reply(200, copy.deepcopy(X['toolsets'].get(profile, []))) or True
            if path == '/api/analytics/usage' and method == 'GET':
                return self.reply(200, {'tools': [{'tool': k, 'count': v} for k, v in X['usage'].items()], 'days': 365}) or True
            if path == '/api/tools/terminal/backends' and method == 'GET':
                if ARGS.no_toolset_config:
                    return self.reply(404, {'detail': 'Not Found'}) or True
                b = X['backends'][profile]
                return self.reply(200, {'active': b['active'], 'backends': [{**x, 'active': x['name'] == b['active']} for x in b['backends']]}) or True
            if path == '/api/tools/terminal/backend' and method == 'PUT':
                b = X['backends'][profile]
                if not any(x['name'] == body.get('backend') for x in b['backends']):
                    return self.reply(400, {'detail': 'unknown backend'}) or True
                b['active'] = body['backend']
                return self.reply(200, {'ok': True, 'backend': b['active']}) or True
            m = re.match(r'^/api/tools/toolsets/([^/]+)(?:/(config|provider|post-setup|models|model))?$', path)
            if m:
                name, sub = unquote(m.group(1)), m.group(2)
                row = next((t for t in X['toolsets'].get(profile, []) if t['name'] == name), None)
                if row is None:
                    return self.reply(404, {'detail': f"Unknown toolset '{name}'", 'echo': name}) or True
                if sub is None and method == 'PUT':
                    row['enabled'] = row['available'] = bool(body.get('enabled'))
                    return self.reply(200, {'ok': True, 'name': name, 'platform': 'cli', 'enabled': row['enabled'], 'post_setup_started': False}) or True
                if ARGS.no_toolset_config:
                    return self.reply(404, {'detail': 'Not Found'}) or True
                c = X['toolcfg'][profile].get(name)
                if sub == 'config' and method == 'GET':
                    return self.reply(200, toolset_config(profile, name)) or True
                if sub == 'provider' and method == 'PUT':
                    p = next((p for p in (c or {}).get('providers', []) if p['name'] == body.get('provider')), None)
                    if p is None:
                        return self.reply(400, {'detail': 'unknown provider'}) or True
                    cap = body.get('capability')
                    if name == 'web' and cap in ('search', 'extract'):
                        c[cap] = p['web_backend']
                    else:
                        c['active'] = p['name']
                        if name == 'web':
                            c['search'] = p['web_backend']
                            c['extract'] = p['web_backend'] if 'extract' in p['capabilities'] else c['extract']
                    refresh_configured(profile)
                    out = {'ok': True, 'name': name, 'provider': p['name']}
                    if p.get('requires_nous_auth'):
                        out.update({'needs_nous_auth': True, 'feature': name})
                    return self.reply(200, out) or True
                if sub == 'post-setup' and method == 'POST':
                    key = str(body.get('key') or '')
                    fail = take('action:tools-post-setup')
                    X['post'] = {'key': key, 'polls': 0, 'profile': profile, 'toolset': name, 'fail': fail}
                    return self.reply(200, {'ok': True, 'name': 'tools-post-setup', 'key': key}) or True
                if sub == 'models' and method == 'GET':
                    if not c or not c.get('models'):
                        return self.reply(200, {'name': name, 'has_models': False, 'models': []}) or True
                    return self.reply(200, {'name': name, 'has_models': True, 'provider': c['active'], 'plugin': 'fal', 'current': c['model'],
                                            'default': 'flux-schnell', 'models': c['models']}) or True
                if sub == 'model' and method == 'PUT':
                    if not c or not any(x['id'] == body.get('model') for x in c.get('models', [])):
                        return self.reply(400, {'detail': 'unknown model'}) or True
                    c['model'] = body['model']
                    return self.reply(200, {'ok': True, 'model': c['model']}) or True
            if path == '/api/actions/tools-post-setup/status' and method == 'GET':
                a = X['post']
                if not a:
                    return self.reply(404, {'detail': 'Unknown action'}) or True
                a['polls'] += 1
                lines = [f"Installing {a['key']}…", 'Collecting packages token=' + FAKE_SECRET]
                if a['polls'] <= 2 or a['fail'] == 'hang':
                    return self.reply(200, {'name': 'tools-post-setup', 'running': True, 'exit_code': None, 'lines': lines}) or True
                if a['fail']:
                    return self.reply(200, {'name': 'tools-post-setup', 'running': False, 'exit_code': 1, 'lines': lines + ['error: failed']}) or True
                for p in X['toolcfg'][a['profile']].get(a['toolset'], {}).get('providers', []):
                    if p.get('post_setup') == a['key']:
                        p['status'] = 'ready'
                refresh_configured(a['profile'])
                return self.reply(200, {'name': 'tools-post-setup', 'running': False, 'exit_code': 0, 'lines': lines + ['done']}) or True
            if path == '/api/config' and method == 'GET':
                servers = {s['name']: copy.deepcopy(s['_entry']) for s in X['mcp'].get(profile, []) if s['_entry'] is not None}
                bad = X.get('bad_config')
                if bad == 'html':
                    return self.page(200, '<h1>Not JSON</h1>') or True
                if bad == 'list':
                    servers = list(servers.values())
                out = sg.cfg.deep_merge(sg.cfg.defaults(), S['config']) if (query.get('include_defaults') or [''])[0] != 'false' else copy.deepcopy(S['config'])
                out = dict(out)
                out['mcp_servers'] = redact(servers) if ARGS.redact_config else servers
                return self.reply(200, out) or True
            if path == '/api/logs' and method == 'GET':
                name = (query.get('file') or ['agent'])[0]
                if ARGS.no_logs or name not in X['logs']:
                    return self.reply(400, {'detail': 'Unknown log file'}) or True
                lines = list(X['logs'][name])
                search = (query.get('search') or [''])[0]
                if search:
                    lines = [l for l in lines if search.lower() in l.lower()]
                return self.reply(200, {'file': name, 'lines': lines[-int((query.get('lines') or ['200'])[0]):]}) or True
            if path == '/api/env' and method == 'PUT':
                key, value = str(body.get('key') or ''), str(body.get('value') or '')
                if not re.match(r'^[A-Z][A-Z0-9_]*$', key):
                    return self.reply(400, {'detail': 'invalid key'}) or True
                if '•' in value or '***' in value:
                    return self.reply(400, {'detail': 'value looks like a redacted preview'}) or True
                X['penv'].setdefault(profile, {})[key] = value
                sg.record_write('PUT /api/env', {'profile': profile, 'key': key})
                refresh_configured(profile)
                return self.reply(200, {'ok': True, 'key': key}) or True
            if path == '/api/env' and method == 'DELETE':
                key = str(body.get('key') or '')
                sg.record_write('DELETE /api/env', {'profile': profile, 'key': key})
                if key in X['penv'].get(profile, {}):
                    del X['penv'][profile][key]
                    refresh_configured(profile)
                    return self.reply(200, {'ok': True}) or True
                row = S['env'].get(key)
                if row is not None and row.get('value') is not None:
                    row['value'] = None
                    return self.reply(200, {'ok': True}) or True
                return self.reply(404, {'detail': f'{key} not found in .env'}) or True
            if path == '/api/env/reveal' and method == 'POST':
                key, now = str(body.get('key') or ''), time.time()
                X['reveal_times'] = [t for t in X['reveal_times'] if now - t < 30]
                if len(X['reveal_times']) >= 5:
                    return self.reply(429, {'detail': 'Too many reveal requests. Try again shortly.'}) or True
                X['reveal_times'].append(now)
                S['reveals'] += 1
                value = X['penv'].get(profile, {}).get(key) or (S['env'].get(key) or {}).get('value')
                if value is None:
                    return self.reply(404, {'detail': f'{key} is not set'}) or True
                return self.reply(200, {'key': key, 'value': value}) or True
            # [directory] Hermes' app catalog (a snapshot of optional-mcps/, scripts/fixtures/mcp-catalog.json).
            if path == '/api/mcp/catalog' and method == 'GET':
                if X.get('no_catalog'):
                    return self.reply(404, {'detail': 'Not Found'}) or True
                names = {s['name'] for s in X['mcp'].get(profile, [])}
                entries = [{**e, 'installed': e['name'] in names, 'enabled': e['name'] in names} for e in CATALOG]
                return self.reply(200, {'entries': entries, 'diagnostics': []}) or True
            if path == '/api/mcp/catalog/install' and method == 'POST':
                name = str(body.get('name') or '')
                entry = next((e for e in CATALOG if e['name'] == name), None)
                if entry is None:
                    return self.reply(404, {'detail': f"No catalog entry '{name}'"}) or True
                env = body.get('env') or {}
                undeclared = sorted(set(env) - {k['name'] for k in entry['required_env']})
                if undeclared:
                    return self.reply(400, {'detail': f"Catalog entry '{name}' does not declare environment variable(s): {', '.join(undeclared)}"}) or True
                sg.record_write('POST /api/mcp/catalog/install', {'profile': profile, 'name': name, 'env': sorted(env)})
                if find_server(profile, name) is None:
                    url = entry['url'] if '${' not in (entry['url'] or '') else (env.get('N8N_MCP_SERVER_URL') or 'https://n8n.example/mcp-server/http')
                    mcp_add(profile, {'name': name, 'config': {'url': url, 'auth': entry['auth_type']} if entry['auth_type'] == 'oauth' else {'url': url}})
                    for k, v in env.items():
                        X['penv'].setdefault(profile, {})[k] = v
                return self.reply(200, {'ok': True, 'name': name, 'background': False}) or True
            m = re.match(r'^/api/mcp/servers/([^/]+)/enabled$', path)
            if m and method == 'PUT':
                row = find_server(profile, unquote(m.group(1)))
                if row is not None and row['source'] != 'plugin' and isinstance(row.get('_entry'), dict):
                    row['_entry']['enabled'] = bool(body.get('enabled'))
                    if not body.get('enabled'):
                        row['_entry']['enabled'] = False
                    else:
                        row['_entry'].pop('enabled', None)
                if row is None:
                    return self.reply(404, {'detail': 'Unknown MCP server'}) or True
                if row['source'] == 'plugin':
                    return self.reply(400, {'detail': 'This server belongs to a plugin'}) or True
                row['enabled'] = bool(body.get('enabled'))
                if not row['enabled']:
                    row['_status'] = 'disabled'
                elif row['_status'] == 'disabled':
                    row['_status'] = 'configured'
                return self.reply(200, {'ok': True, 'name': row['name'], 'enabled': row['enabled']}) or True
            return False

        def control(self, method, path, query):
            global X
            if path == '/__oauth/authorize':
                redirect, state = (query.get('redirect_uri') or [''])[0], (query.get('state') or [''])[0]
                choice = (query.get('choice') or [X['oauth_auto']])[0]
                with LOCK:
                    X['log'].append({'t': time.time(), 'kind': 'page', 'name': 'authorize', 'profile': '', 'params': {'choice': choice}, 'inflight': 0})
                sep = '&' if '?' in redirect else '?'
                if choice == 'allow':
                    return self.redirect(redirect + sep + urlencode({'code': 'code_' + secrets.token_hex(4), 'state': state})) or True
                if choice == 'deny':
                    return self.redirect(redirect + sep + urlencode({'error': 'access_denied', 'state': state})) or True
                q = urlencode({'redirect_uri': redirect, 'state': state})
                return self.page(200, "<h1>Stand-in sign-in</h1><p>Let this stand-in server answer the connector?</p>"
                                      f"<p><a id='allow' href='/__oauth/authorize?{q}&choice=allow'>Allow</a>"
                                      f"<a id='deny' href='/__oauth/authorize?{q}&choice=deny'>Deny</a></p>") or True
            if path == '/__state' and method == 'GET':
                with LOCK:
                    S = sg.S
                    state = {'mcp': X['mcp'], 'toolsets': X['toolsets'], 'toolcfg': X['toolcfg'], 'backends': X['backends'], 'plugins': X['plugins'],
                             'env': {p: sorted(v) for p, v in X['penv'].items()}, 'oauth': X['oauth'], 'log': X['log'], 'writes': S['writes'],
                             'skills': S['skills'], 'reloads': S['reloads'], 'reveals': S['reveals'], 'prompts': S['prompts'],
                             'ui_meta': {n: p['ui_meta'] for n, p in S['profiles'].items()}, 'profiles': list(S['profiles']), 'aux': S.get('aux')}
                    stable = json.dumps({k: state[k] for k in ('mcp', 'toolsets', 'plugins', 'env', 'ui_meta', 'skills', 'backends')}, sort_keys=True, default=str)
                    state['hash'] = hashlib.sha256(stable.encode()).hexdigest()
                    return self.reply(200, json.loads(json.dumps(state, default=str))) or True
            if method != 'POST':
                return False
            body = self.body()
            with LOCK:
                S = sg.S
                if path == '/__fail':
                    X['fail'].append({'target': str(body.get('target')), 'mode': str(body.get('mode', 'error')), 'count': int(body.get('count', 1))})
                    return self.reply(200, {'ok': True}) or True
                if path == '/__log':
                    X['logs'].setdefault(str(body.get('file') or 'mcp'), []).append(str(body.get('line') or ''))
                    return self.reply(200, {'ok': True}) or True
                if path == '/__seed':
                    if body.get('reset'):
                        seed_all()
                    if 'page_routes_missing' in body:   # [plugin-pages] as --page-routes-missing, switched while running
                        X['routes_missing'] = bool(body['page_routes_missing'])
                    if 'python_deps' in body:   # [plugin-ask-bot] {plugin: "its new packages"}: that plugin's update is refused
                        X['python_deps'] = dict(body['python_deps'])
                    if 'clear_fail' in body:
                        X['fail'] = []
                    if 'clear_log' in body:
                        X['log'] = []
                        sg.S['writes'] = []
                    for profile, rows in (body.get('mcp') or {}).items():
                        X['mcp'][profile] = rows
                    st = body.get('status')
                    for st in ([st] if isinstance(st, dict) else st or []):
                        row = find_server(st.get('profile') or 'default', st.get('name'))
                        if row is not None:
                            row['_status'] = st.get('status', row['_status'])
                            row['_tools'] = st.get('tools', row['_tools'])
                            for k in ('enabled', 'oauth_tokens_present', 'auth'):
                                if k in st:
                                    row[k] = st[k]
                    for profile, rows in (body.get('skills') or {}).items():
                        S['skills'][profile]['installed'] = rows
                    if body.get('skill_add'):
                        a = body['skill_add']
                        S['skills'][a.get('profile') or 'default']['installed'].append(
                            {'name': a['name'], 'description': a.get('description', ''), 'category': 'general', 'enabled': True,
                             'usage': a.get('usage', 0), 'provenance': 'bundled'})
                    if body.get('roster_add'):
                        add_profile(body['roster_add']['name'], body['roster_add'].get('display_name') or body['roster_add']['name'])
                    if body.get('roster_remove') in S['profiles'] and body.get('roster_remove') != 'default':
                        for store in (S['profiles'], S['skills'], X['mcp'], X['toolsets'], X['plugins'], X['penv']):
                            store.pop(body['roster_remove'], None)
                    if 'oauth_auto' in body:
                        X['oauth_auto'] = body['oauth_auto'] or ''
                    if 'install' in body:
                        X['install'] = body['install'] or {}
                    if 'bad_config' in body:
                        X['bad_config'] = body['bad_config']
                    if body.get('env'):
                        e = body['env']
                        X['penv'].setdefault(e.get('profile') or 'default', {})[e['key']] = e['value']
                    if body.get('ui_meta'):
                        u = body['ui_meta']
                        p = S['profiles'][u.get('profile') or 'default']
                        if u.get('value') is None:
                            p['ui_meta'].pop(u['key'], None)
                        else:
                            p['ui_meta'][u['key']] = u['value']
                        p['revisions'][u['key']] = p['revisions'].get(u['key'], 0) + 1
                    if body.get('plugins_clear'):   # [find-plugins] a bot with no plugins (the Plugins tab's empty state)
                        X['plugins'][body['plugins_clear']] = []
                    for store, key in ((X['plugins'], 'plugin'), (X['toolsets'], 'toolset')):
                        patch = body.get(key)
                        if patch:
                            rows = store[patch.get('profile') or 'default']
                            row = next((r for r in rows if r['name'] == patch['name']), None)
                            if row is None:
                                rows.append({k: v for k, v in patch.items() if k != 'profile'})
                            else:
                                row.update({k: v for k, v in patch.items() if k != 'profile'})
                    if 'usage' in body:
                        X['usage'] = body['usage']
                    if body.get('servers'):          # servers:N  N generated connectors after the seeded four (load, scroll-to)
                        rows = X['mcp'].setdefault(body.get('profile') or 'default', [])
                        for i in range(int(body['servers'])):
                            n = f'server-{i + 1:03d}'
                            if not any(r['name'] == n for r in rows):
                                rows.append({'name': n, 'transport': 'http', 'url': f'https://{n}.example/mcp', 'command': None, 'args': [],
                                             'env': [], 'auth': None, 'oauth_tokens_present': None, 'enabled': True, 'tools': None,
                                             'source': 'config', 'plugin': None, '_status': 'connected', '_tools': 2,
                                             '_names': tool_names(2), '_entry': {'url': f'https://{n}.example/mcp'}})
                    if 'reveal_limit' in body:       # true: the next reveal answers 429 as Hermes does after five in thirty seconds
                        X['reveal_times'] = [time.time()] * 5 if body['reveal_limit'] else []
                    return self.reply(200, {'ok': True}) or True
            return False

        def do_GET(self):
            if not self.route('GET'):
                super().do_GET()

        def passthrough(self, name):
            """The settings stand-in answers some paths without reading the request body, which then corrupts a kept-alive
            connection (the next request reads it). The body is taken off the socket here and handed over in memory."""
            if hasattr(self, '_cached_body'):   # route() already took it; the base class gets it from body()
                return getattr(super(), name)()
            length = int(self.headers.get('Content-Length') or 0)
            data = self.rfile.read(length) if length else b''
            real, self.rfile = self.rfile, io.BytesIO(data)
            try:
                getattr(super(), name)()
            finally:
                self.rfile = real

        def do_POST(self):
            if not self.route('POST'):
                self.passthrough('do_POST')

        def do_PUT(self):
            if not self.route('PUT'):
                self.passthrough('do_PUT')

        def do_DELETE(self):
            if not self.route('DELETE'):
                self.passthrough('do_DELETE')

    return Handler


def main():
    global ARGS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', type=int, default=10010)
    parser.add_argument('--credentials', required=True)
    parser.add_argument('--keep-credentials', action='store_true')
    parser.add_argument('--label', default='')
    parser.add_argument('--hermes-cookies', action='store_true')
    parser.add_argument('--access-ttl', type=int, default=12 * 60 * 60)
    for flag in ('old-oauth', 'redact-config', 'no-logs', 'legacy-plugins', 'no-plugins-rpc', 'no-toolsets', 'no-toolset-config', 'read-only', 'no-usage',
                 'no-hub-search', 'page-plugin', 'page-plugin-stale', 'page-routes-missing'):
        parser.add_argument('--' + flag, action='store_true')
    for flag in ('bots', 'skills', 'toolsets', 'servers', 'tools', 'latency', 'jitter', 'drop-every'):
        parser.add_argument('--' + flag, type=int, default=0)
    parser.add_argument('--memory-wiki-bundle', default='')
    parser.add_argument('--oauth-auto', default='', choices=['', 'allow', 'deny'])
    ARGS = parser.parse_args()
    sg.LABEL = ARGS.label
    sg.voice.LABEL = ARGS.label
    sg.voice.ACCEPT_PROMPTS = True
    seed_all()
    username, password = 'capabilities-fixture', secrets.token_urlsafe(24)
    if ARGS.keep_credentials and pathlib.Path(ARGS.credentials).exists():
        kept = json.loads(pathlib.Path(ARGS.credentials).read_text())
        username, password = kept['username'], kept['password']
    descriptor = os.open(ARGS.credentials, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump({'username': username, 'password': password, 'url': f'http://127.0.0.1:{ARGS.port}'}, output)
    gateway = sg.voice.auth.Gateway(username, password, True, None, hermes=ARGS.hermes_cookies, access_ttl=ARGS.access_ttl)
    server = ThreadingHTTPServer(('127.0.0.1', ARGS.port), handler(gateway))
    print(f'Capabilities fixture on 127.0.0.1:{ARGS.port}' + (f' ({ARGS.label})' if ARGS.label else ''), flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
