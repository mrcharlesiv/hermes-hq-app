"""More › Bot Profiles (docs/spec/3x-morepages.md §10): the profile list, Rename, Delete and each profile's SOUL.md.

Routes (shapes from hermes_cli/web_routers/profiles.py):
  GET    /api/profiles                 {"profiles":[{name,path,is_default,model,provider,has_env,skill_count,display_name,bot_title,…}]}
  PATCH  /api/profiles/<name>          {"new_name"} → {"ok","name","path"}; 400 for a bad or taken name (as Hermes answers)
  DELETE /api/profiles/<name>          → {"ok","path"}; never `default`
  GET    /api/profiles/<name>/soul     → {"content","exists"}
  PUT    /api/profiles/<name>/soul     {"content"} → {"ok":true}

The roster (`profiles.list`, the base fixture's `pages.BOTS`) is the same list: a rename or a delete here changes
`pages.BOTS` in place, so the Bots tab and this page always agree. Every reset puts the base roster back first.

Controls:
  POST /__fixture/soul-edit   {"profile","content"}            another device edits a SOUL.md (its revision moves)
  POST /__fixture/soul-edit   {"profile","exists":false}       … or removes it
  POST /__fixture/profiles    {"count":60}                     the roster grows to that many bots (stress)
                              {"soul_kb":400,"profile":"inbox"}  that profile's SOUL.md becomes about that many KB
                              {"duplicate":"inbox"}            GET /api/profiles lists that row twice (bad data)
                              {"junk":true}                    … and adds rows with missing / wrong-typed fields
                              {"rename_status":409}            the next rename answers that status ("name taken")
                              {"drop_seconds":8}               the socket drops and stays down that long (the app reads Offline)
State (GET /__fixture/state → "profiles"): {"names":[…],"souls":{name:{"revision","bytes","exists","content"}},
  "renames":[[old,new]],"deleted":[…]}; `content` is left out past 4 KB (its length and a hash stay).
"""
import hashlib, re
from urllib.parse import unquote

NAME = 'profiles'
NAME_RE = re.compile(r'^[a-z0-9][a-z0-9_-]*$')
MODELS = {'default': ('hermes-4', 'nous', 12), 'inbox': ('hermes-4', 'nous', 4), 'deploys': ('claude-sonnet-4.5', 'anthropic', 9),
          'research': ('hermes-4-mini', 'nous', 1), 'finance': ('gpt-5', 'openai', 0)}

BASE_BOTS = None
SOULS = {}
RENAMES = []
DELETED = []
KNOBS = {}

def soul_text(name, title):
    return (f'# {title}\n\nYou are {title}, one of the bots on this gateway.\n\n'
            '## Voice\n\n- Plain words, short sentences.\n- Say what you did, then what is next.\n\n'
            '## Rules\n\n1. Ask before anything that cannot be undone.\n2. Keep notes in your own folder.\n'
            f'3. Sign off as {title}.\n')

def restore_roster():
    """The base roster again, in place (other modules read pages.BOTS)."""
    global BASE_BOTS
    pages = ctx.pages
    if BASE_BOTS is None: BASE_BOTS = list(pages.BOTS)
    pages.BOTS[:] = BASE_BOTS
    pages.BOT_NAMES.clear(); pages.BOT_NAMES.update({name: title for name, title, _ in BASE_BOTS})

# The base fixture's reseed seeds its sessions from pages.BOTS first: the roster must be the base one by then.
_seed_sessions = ctx.pages.seed_sessions
def seed_sessions():
    restore_roster()
    _seed_sessions()
ctx.pages.seed_sessions = seed_sessions

def seed():
    restore_roster()
    SOULS.clear(); RENAMES.clear(); DELETED.clear(); KNOBS.clear()
    for name, title, _ in ctx.pages.BOTS:
        # Finance has no SOUL.md yet (`exists: false`).
        SOULS[name] = {'content': '' if name == 'finance' else soul_text(name, title), 'exists': name != 'finance', 'revision': 1}

def row(name, title):
    model, provider, skills = MODELS.get(name, ('hermes-4', 'nous', 3))
    return {'name': name, 'path': f'{ctx.home}/profiles/{name}' if name != 'default' else ctx.home, 'is_default': name == 'default',
            'model': model, 'provider': provider, 'has_env': name != 'finance', 'skill_count': skills, 'gateway_running': False,
            'description': '', 'description_auto': False, 'display_name': title, 'bot_title': title,
            'distribution_name': None, 'distribution_version': None, 'distribution_source': None, 'has_alias': False}

def listing():
    rows = [row(name, title) for name, title, _ in ctx.pages.BOTS]
    if KNOBS.get('duplicate'):
        rows += [dict(r) for r in rows if r['name'] == KNOBS['duplicate']]
    if KNOBS.get('junk'):
        rows += [None, 7, 'text', {}, {'name': None}, {'name': ''}, {'name': 42, 'model': None, 'skill_count': 'many'},
                 {'name': 'numbers', 'skill_count': '7', 'is_default': 'no', 'model': 5, 'provider': None, 'path': ['x']}]
    return {'profiles': rows}

def index_of(name):
    for index, (bot, _, _) in enumerate(ctx.pages.BOTS):
        if bot == name: return index
    return -1

def rename(old, new):
    pages = ctx.pages
    index = index_of(old)
    _, title, about = pages.BOTS[index]
    pages.BOTS[index] = (new, title, about)
    pages.BOT_NAMES.pop(old, None); pages.BOT_NAMES[new] = title
    SOULS[new] = SOULS.pop(old, {'content': '', 'exists': False, 'revision': 1})
    if old in MODELS: MODELS[new] = MODELS[old]
    # Its Bot Chat follows it (the roster reads the chat by the profile's name).
    session = pages.SESSIONS.get(pages.bot_chat_id(old))
    if session:
        pages.add_session(pages.bot_chat_id(new), new, 'Bot Chat', [dict(m) for m in session['messages']], session['last_active'], hidden=True)
    for session in pages.SESSIONS.values():
        if session['profile'] == old: session['profile'] = new
    RENAMES.append([old, new])

def rest(method, path, query, body, handler):
    if path == '/api/profiles' and method == 'GET':
        with ctx.lock: return 200, listing()
    if not path.startswith('/api/profiles/'): return None
    parts = [unquote(p) for p in path[len('/api/profiles/'):].split('/')]
    name = parts[0]
    # The base fixture's own routes under /api/profiles/ (sessions, sessions/sidebar) stay its own.
    if name in ('sessions', 'active', 'import'): return None
    sub = parts[1] if len(parts) > 1 else ''
    if len(parts) > 2 or sub not in ('', 'soul'): return None
    with ctx.lock:
        known = index_of(name) >= 0
        if sub == 'soul':
            if not known: return 404, {'detail': f"Profile '{name}' does not exist."}
            soul = SOULS.setdefault(name, {'content': '', 'exists': False, 'revision': 1})
            if method == 'GET':
                return 200, {'content': soul['content'] if soul['exists'] else '', 'exists': soul['exists']}
            if method == 'PUT':
                content = body.get('content') if isinstance(body, dict) else None
                if not isinstance(content, str): return 422, {'detail': 'content must be a string'}
                soul.update(content=content, exists=True, revision=soul['revision'] + 1)
                ctx.wrote(NAME, 'soul', profile=name, bytes=len(content.encode()), revision=soul['revision'])
                return 200, {'ok': True}
            return 405, {'detail': 'Method Not Allowed'}
        if method == 'PATCH':
            if not known: return 404, {'detail': f"Profile '{name}' does not exist."}
            status = KNOBS.pop('rename_status', None)
            if status: return int(status), {'detail': f"Profile '{body.get('new_name')}' already exists."}
            if set(body) - {'new_name'}: return 422, {'detail': 'unknown field'}
            new = body.get('new_name')
            if not isinstance(new, str) or not NAME_RE.match(new.strip()):
                return 400, {'detail': 'Invalid profile name. Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit.'}
            new = new.strip()
            if name == 'default':
                return 200, {'ok': True, 'name': 'default', 'display_name': new, 'path': ctx.home}
            if index_of(new) >= 0 or new == 'default': return 400, {'detail': f"Profile '{new}' already exists."}
            rename(name, new)
            ctx.wrote(NAME, 'rename', old=name, new=new)
            return 200, {'ok': True, 'name': new, 'path': f'{ctx.home}/profiles/{new}'}
        if method == 'DELETE':
            if name == 'default': return 400, {'detail': 'The default profile cannot be deleted.'}
            if not known: return 404, {'detail': f"Profile '{name}' does not exist."}
            ctx.pages.BOTS.pop(index_of(name)); ctx.pages.BOT_NAMES.pop(name, None)
            SOULS.pop(name, None); DELETED.append(name)
            ctx.wrote(NAME, 'delete', profile=name)
            return 200, {'ok': True, 'path': f'{ctx.home}/profiles/{name}'}
    return None

def control(path, body):
    if path == '/__fixture/soul-edit':
        with ctx.lock:
            name = body.get('profile') or 'default'
            soul = SOULS.setdefault(name, {'content': '', 'exists': False, 'revision': 1})
            exists = body.get('exists', True)
            soul.update(content=str(body.get('content') or '') if exists else '', exists=bool(exists), revision=soul['revision'] + 1)
            return {'ok': True, 'revision': soul['revision']}
    if path == '/__fixture/profiles':
        pages = ctx.pages
        with ctx.lock:
            count = int(body.get('count') or 0)
            index = len(pages.BOTS)
            while len(pages.BOTS) < count:
                index += 1
                name, title = f'bot-{index:02d}', f'Bot {index:02d}'
                pages.BOTS.append((name, title, 'One of many')); pages.BOT_NAMES[name] = title
                pages.add_session(pages.bot_chat_id(name), name, 'Bot Chat', [
                    {'role': 'user', 'content': 'Hello?'}, {'role': 'assistant', 'content': f'{title} here.'}],
                    pages.T0 - 86400 - index * 60, hidden=True)
                SOULS[name] = {'content': soul_text(name, title), 'exists': True, 'revision': 1}
            if body.get('soul_kb'):
                name = body.get('profile') or 'inbox'
                line = 'Remember: plain words, short sentences, and say what happens next. '
                lines = []; size = 0; number = 0
                while size < int(body['soul_kb']) * 1024:
                    number += 1
                    text = f'{number:05d} {line}'
                    lines.append(text); size += len(text) + 1
                soul = SOULS.setdefault(name, {'content': '', 'exists': True, 'revision': 1})
                soul.update(content='\n'.join(lines) + '\n', exists=True, revision=soul['revision'] + 1)
            if body.get('drop_seconds'): ctx.drop_sockets(float(body['drop_seconds']))
            for key in ('duplicate', 'junk', 'rename_status'):
                if key in body: KNOBS[key] = body[key]
            return {'ok': True, 'count': len(pages.BOTS)}
    return None

def state():
    souls = {}
    for name, soul in SOULS.items():
        content = soul['content']
        entry = {'revision': soul['revision'], 'bytes': len(content.encode()), 'exists': soul['exists'],
                 'sha256': hashlib.sha256(content.encode()).hexdigest()}
        if len(content) <= 4096: entry['content'] = content
        else: entry['tail'] = content[-200:]
        souls[name] = entry
    return {'names': [name for name, _, _ in ctx.pages.BOTS], 'souls': souls, 'renames': list(RENAMES), 'deleted': list(DELETED)}
