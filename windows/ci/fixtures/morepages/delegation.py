"""Spawn Tree (docs/spec/3x-morepages.md §16): JSON-RPC `delegation.status` with `{"profile"?}` only.

`AG/tui_gateway/contracts/billing_delegation_pets.py` (ActiveSubagent, DelegationStatusResult). Invented data only.
Seeded: 2 bots (deploys, research), 14 children, 3 levels deep, owned by chats the pages fixture lists.

`POST /__fixture/delegation {"mode": …}`:
  "seed"        the seeded tree again
  "empty"       nothing running
  "big"         400 children, 6 levels deep, long and odd goals, some duplicate ids
  "paused"      the seeded tree with `paused: true`
  "error"       every call is refused (-32000)
  "global"      every bot's call answers the whole list (a gateway that serves all bots from one process)
  "odd"         orphans, a cycle, missing and wrongly typed fields
  "missing"     -32601, as an older Hermes answers
and optionally "delay": seconds for every answer.
"""
import time

NEW = True
RPC_METHODS = {'delegation.status'}
REST_PREFIXES = ()
MODE = {'mode': 'seed', 'delay': 0}


def seed():
    MODE.clear(); MODE.update(mode='seed', delay=0)


def child(sid, parent, depth, goal, owner, age, status='running', tools=3, model='hermes-4'):
    return {'subagent_id': sid, 'parent_id': parent, 'depth': depth, 'goal': goal, 'delegation_id': 'd-' + sid.split('-')[1],
            'model': model, 'started_at': time.time() - age, 'status': status, 'tool_count': tools,
            'owner_agent_session_id': owner, 'missed_steer': False}


def seeded():
    return {
        'deploys': [
            child('sa-r1', None, 1, 'Collect every merged pull request since 2.3 and group them by area', 's-release', 130, tools=12),
            child('sa-r2', 'sa-r1', 2, 'Read the networking changes and write two sentences each', 's-release', 95, tools=7, model='claude-opus-5'),
            child('sa-r3', 'sa-r2', 3, 'Check the retry change against the incident notes', 's-release', 40, tools=1),
            child('sa-r4', 'sa-r2', 3, 'Find the pull request that renamed the config key', 's-release', 12, status='queued', tools=0),
            child('sa-r5', 'sa-r1', 2, 'Read the interface changes and write two sentences each', 's-release', 90, tools=5),
            child('sa-r6', 'sa-r5', 3, 'Take screenshots of the new settings page', 's-release', 20, status='failed', tools=2),
            child('sa-r7', None, 1, 'Draft the upgrade steps', 's-release', 3700, tools=31),
            child('sa-r8', 'sa-r7', 2, 'Try the upgrade on a clean install', 's-release', 600, status='done', tools=9),
            child('sa-p1', None, 1, 'Rebuild the 2.4 report as a one-page PDF', 's-report', 75, tools=4),
            child('sa-p2', 'sa-p1', 2, 'Redraw the latency chart', 's-report', 31, tools=2),
        ],
        'research': [
            child('sa-a1', None, 1, 'Skim this week’s planning papers', 's-reading', 200, tools=14),
            child('sa-a2', 'sa-a1', 2, 'Summarise "Open Planning" in five lines', 's-reading', 150, tools=6),
            child('sa-a3', 'sa-a1', 2, 'Summarise "Long Memory" in five lines', 's-reading', 149, tools=5),
            child('sa-a4', 'sa-a3', 3, 'Look up the benchmark it cites', 's-reading', 8, tools=0, status='queued'),
        ],
    }


def big():
    rows = []
    odd = ['مرحبا بالعالم: راجع الملفات', '🚀🚀 Ship it ' * 12, 'Zero​width​goal', '<b>HTML</b> & **Markdown** `code`',
           'Line one\nLine two\nLine three', 'L' + 'o' * 990 + 'ng']
    for index in range(400):
        depth = index % 6 + 1
        parent = None if depth == 1 else f'sa-b{index - 1}'
        goal = odd[index % len(odd)] if index % 11 == 0 else f'Helper {index + 1}: check file {index + 1} of the release'
        rows.append(child(f'sa-b{index}', parent, depth, goal, 's-release' if index < 300 else 's-report', 5 + index,
                          status=('running', 'queued', 'done', 'failed')[index % 4] if index % 3 == 0 else 'running', tools=index % 40))
    rows += [dict(rows[0]), dict(rows[7])]      # duplicate ids
    return {'deploys': rows}


def odd():
    return {'deploys': [
        child('sa-o1', 'sa-gone', 4, 'An orphan whose parent already finished', 's-release', 50),
        child('sa-o2', 'sa-o3', 2, 'One half of a cycle', 's-release', 40),
        child('sa-o3', 'sa-o2', 2, 'The other half of a cycle', 's-release', 30),
        child('sa-o4', 'sa-o4', 1, 'Its own parent', None, 20),
        {'subagent_id': 'sa-o5'},
        {'subagent_id': 9, 'goal': None, 'depth': '2', 'tool_count': '4', 'started_at': str(time.time() - 65), 'status': 7,
         'owner_agent_session_id': 's-nowhere'},
        {'goal': 'No id at all'}, 'not a record', None,
    ]}


def rpc(method, params):
    if method != 'delegation.status': return None
    ctx.keys(params, {'profile'})
    if MODE.get('delay'): time.sleep(float(MODE['delay']))
    mode = MODE['mode']
    if mode == 'missing': ctx.refuse(-32601, 'Method not found: delegation.status')
    if mode == 'error': ctx.refuse(-32000, 'The delegation registry is not available.')
    tree = {'empty': dict, 'big': big, 'odd': odd}.get(mode, seeded)()
    profile = params.get('profile') or 'default'
    if mode == 'global': active = [row for rows in tree.values() for row in rows]
    else: active = tree.get(profile, [])
    return {'active': active, 'paused': mode == 'paused', 'max_spawn_depth': 3, 'max_concurrent_children': 3}


def control(path, body):
    if path != '/__fixture/delegation': return None
    body = body or {}
    if 'mode' in body: MODE['mode'] = body['mode']
    if 'delay' in body: MODE['delay'] = body['delay']
    return {'ok': True, **MODE}


def state(): return dict(MODE)
