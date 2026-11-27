"""More › Import Sessions (docs/spec/3x-morepages.md §14): invented Claude Code and Codex sessions to bring into Hermes.

JSON-RPC, shapes from tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py. Every method refuses a key it
does not list with error 4000, as Hermes does.
  session.foreign.list     {profile?, source?: "claude"|"codex", offset?, limit?}
                           → {"sessions":[{"id","source","label","title","cwd","mtime","turn_count","excerpt"}],
                              "next_offset": int|null, "host", "unreadable"}
  session.foreign.preview  {profile?, id} → {"messages":[{"role","content"}],"total","truncated","already_imported": id|null,"cwd"}
  session.foreign.import   {profile?, id} → {"session_id","already_imported": bool}

120 sessions (even = Claude Code, odd = Codex), newest first. Some have no title, an emoji title, a right-to-left title,
a very long title; fs-0005 has no turns; fs-0003 has 90 turns (its preview is shortened); fs-0002 was already imported
(as the session "imported-fs-0002", which the sessions list returns). An import adds a session to the base fixture's
list (`ctx.pages.add_session`) under the asked profile, and is recorded in GET /__fixture/state "writes".

Knobs (POST /__fixture/foreign), all cleared by /__fixture/reset:
  {"rows": 2000}                         how many sessions exist (default 120)
  {"empty": true}                        no sessions at all
  {"delay": 3, "delay_count": 1}         the next `delay_count` calls (default 1) wait that many seconds first
  {"error": "text", "error_count": 1, "error_method": "list"|"preview"|"import", "error_code": -32000}
                                         the next matching calls are refused with that text (after any delay)
  {"duplicates": true}                   every page repeats the last row of the page before it (a paging overlap)
  {"bad_rows": true}                     the first page also carries rows of the wrong shape (the app must skip them)
state(): {"imported": {foreign id: session id}, "imports": <count of real imports>, "calls": {method: count}}
"""
import time

NEW = True
RPC_METHODS = {'session.foreign.list', 'session.foreign.preview', 'session.foreign.import'}
HOST = 'Robins-Mac-mini.local'
PAGE = 50

knobs = {}
imported = {}
counts = {'imports': 0}
calls = {}

FOLDERS = ['/home/hermes/projects/site', '/home/hermes/projects/notes', '/home/hermes/app', '/home/hermes/projects/billing-service', None]
TOPICS = ['Fix the flaky login test', 'Plan the pricing page', 'Why is the build slow', 'Refactor the export queue',
          'Write release notes for 2.4', 'Debug the webhook retries', 'Sketch the onboarding flow', 'Clean up the CSS']

def row(index):
    source = 'claude' if index % 2 == 0 else 'codex'
    title = f'{TOPICS[index % len(TOPICS)]} ({index})'
    if index == 1: title = ''                                        # no title: the label names it
    if index == 4: title = '🚀 Ship the launch checklist ✅'
    if index == 6: title = 'סיכום הפגישה עם הצוות'                  # right-to-left
    if index == 8: title = 'A very long title that keeps going so the row has to wrap or cut it cleanly ' * 4
    if index == 9: title = '<b>Not HTML</b> and **not Markdown**\nwith a second line'
    turns = 0 if index == 5 else 90 if index == 3 else 4 + index % 23
    return {'id': f'fs-{index:04d}', 'source': source, 'label': 'Claude Code' if source == 'claude' else 'Codex', 'title': title.strip(),
            'cwd': FOLDERS[index % len(FOLDERS)], 'mtime': BASE - index * 5400.0, 'turn_count': turns,
            'excerpt': '' if index == 5 else f'Let’s look at {TOPICS[index % len(TOPICS)].lower()}. First I read the failing output, then the code around it. ' * 2}

BASE = time.time() - 600

def total():
    if knobs.get('empty'): return 0
    return int(knobs.get('rows') or 120)

def index_of(fid):
    try: index = int(str(fid).split('-')[1])
    except (IndexError, ValueError): return None
    return index if str(fid) == f'fs-{index:04d}' and 0 <= index < total() else None

def turns(index):
    count = row(index)['turn_count']
    out = []
    for n in range(count):
        if n % 2 == 0:
            out.append({'role': 'user', 'content': f'Step {n // 2 + 1}: can you check {TOPICS[(index + n) % len(TOPICS)].lower()}?'})
        else:
            out.append({'role': 'assistant', 'content': f'I looked at it. **Finding {n // 2 + 1}**: the cause is in the retry loop.\n\n'
                                                         f'- it retries without a pause\n- it never gives up\n\n`fix`: add a limit of 3.'})
    return out

def seed():
    knobs.clear(); imported.clear(); calls.clear(); counts['imports'] = 0
    imported['fs-0002'] = 'imported-fs-0002'
    ctx.pages.add_session('imported-fs-0002', 'default', row(2)['title'], turns(2), time.time() - 300, source='claude', cwd=row(2)['cwd'] or '')

def control(path, body):
    if path != '/__fixture/foreign': return None
    knobs.update(body or {})
    return {'ok': True, 'knobs': dict(knobs)}

def state():
    return {'imported': dict(imported), 'imports': counts['imports'], 'calls': dict(calls)}

def scripted(kind):
    """A scripted wait, then a scripted refusal, for the next call."""
    with ctx.lock:
        wait = 0
        if knobs.get('delay'):
            wait = float(knobs['delay'])
            left = int(knobs.get('delay_count', 1)) - 1
            if left <= 0: knobs.pop('delay', None); knobs.pop('delay_count', None)
            else: knobs['delay_count'] = left
    if wait: time.sleep(wait)
    with ctx.lock:
        text = knobs.get('error')
        refusal = None
        if text and knobs.get('error_method', kind) == kind:
            refusal = (int(knobs.get('error_code') or -32000), text)
            left = int(knobs.get('error_count', 1)) - 1
            if left <= 0:
                for key in ('error', 'error_count', 'error_method', 'error_code'): knobs.pop(key, None)
            else: knobs['error_count'] = left
    if refusal: ctx.refuse(*refusal)

def rpc(method, params):
    if method not in RPC_METHODS: return None
    kind = method.rsplit('.', 1)[1]
    calls[kind] = calls.get(kind, 0) + 1
    if kind == 'list':
        ctx.keys(params, {'profile', 'source', 'offset', 'limit'})
        scripted(kind)
        source = params.get('source')
        if source not in (None, 'claude', 'codex'): ctx.refuse(4000, 'source must be claude or codex')
        offset = max(0, int(params.get('offset') or 0)); limit = max(1, min(200, int(params.get('limit') or PAGE)))
        rows = [row(i) for i in range(total())]
        if source: rows = [r for r in rows if r['source'] == source]
        page = rows[offset:offset + limit]
        if knobs.get('duplicates') and offset > 0 and offset <= len(rows): page = [rows[offset - 1]] + page
        if knobs.get('bad_rows') and offset == 0:
            page = [None, 'text', {'source': 'claude'}, {'id': 7, 'title': 9, 'mtime': 'soon', 'turn_count': '12'}, []] + page
        after = offset + limit
        return {'sessions': page, 'next_offset': after if after < len(rows) else None, 'host': HOST,
                'unreadable': 3 if offset == 0 and rows else 0}
    ctx.keys(params, {'profile', 'id'})
    scripted(kind)
    index = index_of(params.get('id'))
    if index is None: ctx.refuse(-32000, 'foreign session not found')
    fid = f'fs-{index:04d}'
    item = row(index)
    if kind == 'preview':
        every = turns(index)
        return {'messages': every[-40:], 'total': len(every), 'truncated': len(every) > 40, 'already_imported': imported.get(fid), 'cwd': item['cwd']}
    if fid in imported: return {'session_id': imported[fid], 'already_imported': True}
    profile = params.get('profile') or 'default'
    sid = f'imported-{fid}'
    with ctx.lock:
        imported[fid] = sid; counts['imports'] += 1
        ctx.pages.add_session(sid, profile, item['title'] or item['label'], turns(index), time.time(), source=item['source'], cwd=item['cwd'] or '')
    ctx.wrote('foreign', 'import', id=fid, session_id=sid, profile=profile)
    return {'session_id': sid, 'already_imported': False}
