#!/usr/bin/env python3
"""Loopback stand-in gateway for managed apps (Capabilities › Connectors, the apps reached through a bot's Nous
account). Invented data only; nothing here talks to Nous or any connector service.

DECISION: like botslist-gateway.py this loads an existing stand-in by path (capabilities-gateway.py, which loads
settings-gateway.py) so the sign-in, roster, MCP servers and the rest stay one implementation, and adds the connector
methods of tui_gateway/contracts/connectors.py and connectors_operation.py with Hermes' own refusals:

  connectors.list, connectors.catalog, connectors.tools, connectors.connect (with an account name, `alias`),
  connectors.accounts, connectors.accounts.rename, connectors.accounts.remove, connectors.operation.status, connectors.operation.wake, connection.respond,
  connectors.policy.get, connectors.policy.set

Every key outside a method's contract is refused with 4000 / INVALID_PARAMS, as Hermes does. Errors carry
`data.reason` (ConnectorErrorReason). Each bot (profile) has its own stand-in Nous account: its accounts, its member
rules and a mode. An operation moves only by `connection.update` broadcasts (owner {type: account}, no link and no
account id in them, as Hermes strips them), never by the client polling.

The sign-in link is http://127.0.0.1:<port>/__connect?op=<op>&app=<slug>. Loading it with choice=allow completes the
sign-in after --sign-in-delay ms (the account turns active, the row connected, the operation settles); choice=deny
fails it; no choice shows an Allow / Deny page.

Controls (loopback, no auth):
  GET  /__connectors                state: accounts, policies, operations, log (every connector call with its params)
  POST /__connectors {...}          reset:true | mode:{profile,mode} (ok | signed_out | unavailable | org_required |
                                    catalog_down | too_old | no_names: a Hermes from before account names, whose
                                    rows carry no alias and which knows no rename) | fail:{method,reason,count} (next calls refused with that
                                    reason) | expire:{op} (the link runs out now) | link_ttl:<seconds> |
                                    external_policy:{profile,connector,disabled_tools} (someone else saves a rule) |
                                    multi_accounts:{profile} (that bot's Gmail: work, home (expired) and one retired)
  plus everything capabilities-gateway.py offers (/__state, /__seed, /__fail ...).

  python3 scripts/fixtures/connectors-gateway.py --port 10130 --hermes-cookies --credentials build/fixtures/conn-a.json
  --multi-accounts: the default bot's Gmail has two named accounts (work, home) and one retired by a reconnect.
"""
import copy, html, importlib.util, json, pathlib, random, re, secrets, sys, threading, time
from urllib.parse import urlparse, parse_qs, urlencode

_spec = importlib.util.spec_from_file_location('capabilities_gateway', pathlib.Path(__file__).with_name('capabilities-gateway.py'))
cg = importlib.util.module_from_spec(_spec)
sys.modules['capabilities_gateway'] = cg
_spec.loader.exec_module(cg)
sg = cg.sg
LOCK = sg.LOCK

SLUG = re.compile(r'^[a-z0-9][a-z0-9_-]*$')
REVISION = re.compile(r'^[0-7][0-9A-HJKMNP-TV-Z]{25}$')
CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
CONTRACT = {
    'connectors.list': {'profile', 'owner'},
    'connectors.catalog': {'profile'},
    'connectors.accounts': {'profile', 'connector'},
    'connectors.accounts.remove': {'profile', 'connection_id'},
    'connectors.accounts.rename': {'profile', 'connection_id', 'alias'},
    'connectors.tools': {'profile', 'slug', 'refresh'},
    'connectors.connect': {'profile', 'owner', 'connectors', 'reconnect', 'alias', 'connection_id'},
    'connectors.operation.status': {'profile', 'owner', 'op_id'},
    'connectors.operation.wake': {'profile', 'owner', 'op_id'},
    'connection.respond': {'profile', 'owner', 'op_id', 'result'},
    'connectors.policy.get': {'profile'},
    'connectors.policy.set': {'profile', 'change', 'expected_revision'},
}
REQUIRED = {
    'connectors.list': {'owner'}, 'connectors.accounts.remove': {'connection_id'}, 'connectors.accounts.rename': {'connection_id', 'alias'}, 'connectors.tools': {'slug'},
    'connectors.connect': {'owner', 'connectors'}, 'connectors.operation.status': {'owner', 'op_id'},
    'connectors.operation.wake': {'owner', 'op_id'}, 'connection.respond': {'owner', 'op_id', 'result'},
    'connectors.policy.set': {'change', 'expected_revision'},
}
CODES = {'INVALID_PARAMS': 4000, 'NOT_OWNER': 4001, 'LINK_STILL_VALID': 4002, 'REISSUE_REFUSED': 4002, 'INVALID_ANSWER': 4002,
         'UNKNOWN_TARGET': 4004, 'UNKNOWN_OPERATION': 4004, 'FORBIDDEN_SCOPE': 4030, 'ORG_ACCESS_DENIED': 4030,
         'CONNECTORS_UNAVAILABLE': 4031, 'NEEDS_NOUS_AUTH': 4032, 'CONNECTOR_NOT_FOUND': 4041, 'CONNECTION_NOT_FOUND': 4041,
         'POLICY_CONFLICT': 4090, 'ALIAS_TAKEN': 4090, 'ORG_REQUIRED': 4090, 'INVALID_POLICY': 4000, 'UNSUPPORTED_RUNTIME': 5033}
MESSAGES = {'NEEDS_NOUS_AUTH': 'Sign in to use connectors.', 'CONNECTORS_UNAVAILABLE': 'Connectors are not available.',
            'ORG_REQUIRED': 'Select an organization to manage connector rules.', 'POLICY_CONFLICT': 'Connector policy changed. Refresh and try again.',
            'LINK_STILL_VALID': 'Reopen the stored link.', 'CONNECTION_NOT_FOUND': 'Connector account not found.',
            'CONNECTOR_NOT_FOUND': 'Connector not found.', 'UNKNOWN_OPERATION': 'No open operation with that op_id.',
            'INVALID_PARAMS': 'Connector parameters are invalid.', 'ALIAS_TAKEN': 'That name is already used.'}
ALIAS = re.compile(r'^[a-z0-9][a-z0-9-]{0,31}$')

CATALOG = [
    ('github', 'GitHub', 'Issues, pull requests and repositories.', 'Developer tools'),
    ('gitlab', 'GitLab', 'Merge requests, pipelines and projects.', 'Developer tools'),
    ('linear', 'Linear', 'Plan and track issues for your team.', 'Developer tools'),
    ('jira', 'Jira', 'Issues and sprints for software teams.', 'Developer tools'),
    ('sentry', 'Sentry', 'Errors and performance from your apps.', 'Developer tools'),
    ('gmail', 'Gmail', 'Read, search and send email.', 'Communication'),
    ('slack', 'Slack', 'Messages and channels in your workspaces.', 'Communication'),
    ('outlook', 'Outlook', 'Email and calendar from Microsoft 365.', 'Communication'),
    ('zoom', 'Zoom', 'Meetings and recordings.', 'Communication'),
    ('intercom', 'Intercom', 'Conversations with your customers.', 'Support'),
    ('zendesk', 'Zendesk', 'Tickets and help-centre articles.', 'Support'),
    ('google_calendar', 'Google Calendar', 'Events, invitations and free time.', 'Productivity'),
    ('notion', 'Notion', 'Pages, databases and notes.', 'Productivity'),
    ('todoist', 'Todoist', 'Tasks and projects.', 'Productivity'),
    ('asana', 'Asana', 'Projects and tasks for teams.', 'Productivity'),
    ('trello', 'Trello', 'Boards, lists and cards.', 'Productivity'),
    ('airtable', 'Airtable', 'Bases, tables and records.', 'Productivity'),
    ('google_drive', 'Google Drive', 'Files and folders in your Drive.', 'Files'),
    ('dropbox', 'Dropbox', 'Files and shared folders.', 'Files'),
    ('onedrive', 'OneDrive', 'Files in your Microsoft account.', 'Files'),
    ('figma', 'Figma', 'Design files and comments.', 'Design'),
    ('hubspot', 'HubSpot', 'Contacts, deals and companies.', 'Sales'),
    ('salesforce', 'Salesforce', 'Accounts, leads and opportunities.', 'Sales'),
    ('stripe', 'Stripe', 'Payments, customers and invoices.', 'Finance'),
]

C = {}


def ulid():
    return '0' + ''.join(random.choice(CROCKFORD) for _ in range(25))


def now_iso(offset=0):
    return time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime(time.time() + offset))


def account(connector, status='active', label=None, reason=None, days=0, alias=None, disabled=False):
    return {'connectionId': 'conn_' + secrets.token_hex(5), 'connector': connector, 'status': status, 'statusReason': reason,
            'label': label or f'fixture-{connector}@example.com', 'alias': alias, 'active': status == 'active', 'disabled': disabled,
            'createdAt': now_iso(-days * 86400), 'updatedAt': now_iso(-days * 86400)}


def nous(profile):
    """One bot's stand-in Nous account."""
    if profile == 'default':
        accounts = [account('github', days=30, label='octo-fixture'), account('gmail', days=12, label='fixture@example.com'),
                    account('slack', status='expired', reason='Slack asked for a new sign-in.', days=60, label='fixture-team')]
        member = {'mode': 'deny', 'disabled_connectors': [], 'tools': {'github': ['github_delete_repo']}}
        if getattr(ARGS, 'multi_accounts', False):
            accounts = [a for a in accounts if a['connector'] != 'gmail'] + multi_gmail()
    else:
        accounts, member = [], {'mode': 'unrestricted'}
    return {'mode': 'ok', 'accounts': accounts, 'member': member, 'member_revision': ulid(),
            'org': {'mode': 'deny', 'disabled_connectors': ['jira'], 'tools': {'github': ['github_transfer_repo']}}, 'org_revision': ulid()}


def multi_gmail():
    """Gmail with two named accounts (home's access expired) and one retired by a reconnect."""
    return [account('gmail', days=12, label='fixture@example.com', alias='work'),
            account('gmail', status='expired', reason='Google asked for a new sign-in.', days=3, label='fixture.home@example.com', alias='home'),
            account('gmail', status='inactive', days=40, label='old-fixture@example.com', disabled=True)]


def reset():
    C.clear()
    C.update({'nous': {}, 'ops': {}, 'log': [], 'fail': [], 'link_ttl': 120, 'wakes': [], 'logins': {}})


def nous_for(profile):
    if profile not in C['nous']:
        C['nous'][profile] = nous(profile)
    return C['nous'][profile]


def tools_for(slug):
    nouns = {'github': ['issue', 'pull_request', 'repo', 'comment', 'branch', 'release'], 'gmail': ['message', 'draft', 'label', 'thread'],
             'slack': ['message', 'channel', 'reminder'], 'google_calendar': ['event', 'calendar']}.get(slug, ['item', 'note'])
    rows = []
    for noun in nouns:
        rows.append({'slug': f'{slug}_list_{noun}s', 'name': f'List {noun.replace("_", " ")}s', 'description': f'Lists the {noun.replace("_", " ")}s you can see.',
                     'facet': 'read', 'hints': ['readOnly'], 'categories': [noun], 'no_auth': False, 'deprecated': False})
        rows.append({'slug': f'{slug}_create_{noun}', 'name': f'Create {noun.replace("_", " ")}', 'description': f'Creates a new {noun.replace("_", " ")}.',
                     'facet': 'write', 'hints': ['create'], 'categories': [noun], 'no_auth': False, 'deprecated': False})
    if slug == 'github':
        rows.append({'slug': 'github_delete_repo', 'name': 'Delete repository', 'description': 'Deletes a repository for good.',
                     'facet': 'destructive', 'hints': ['delete', 'destructive'], 'categories': ['repo'], 'no_auth': False, 'deprecated': False})
        rows.append({'slug': 'github_transfer_repo', 'name': 'Transfer repository', 'description': 'Moves a repository to another owner.',
                     'facet': 'destructive', 'hints': ['destructive'], 'categories': ['repo'], 'no_auth': False, 'deprecated': False})
        rows.append({'slug': 'github_legacy_search', 'name': 'Legacy search', 'description': 'The old search endpoint.',
                     'facet': 'read', 'hints': ['readOnly'], 'categories': [], 'no_auth': False, 'deprecated': True})
    else:
        rows.append({'slug': f'{slug}_delete_{nouns[0]}', 'name': f'Delete {nouns[0].replace("_", " ")}', 'description': f'Removes a {nouns[0].replace("_", " ")}.',
                     'facet': 'destructive', 'hints': ['delete'], 'categories': [nouns[0]], 'no_auth': False, 'deprecated': False})
    return rows


class Refusal(Exception):
    def __init__(self, reason, message=None, code=None):
        super().__init__(reason)
        self.reason, self.code = reason, code or CODES.get(reason, 5034)
        self.message = message or MESSAGES.get(reason, 'Connector request failed. Try again explicitly.')


# ---- broadcasts ---------------------------------------------------------------------------------------------------
def broadcast(op, change=None):
    view = op_view(op, broadcast=True)
    view.update(change or {})
    view['owner'] = {'type': 'account'}
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'connection.update', 'session_id': '', 'payload': view}}
    with LOCK:
        clients = list(sg.CLIENTS)
        C['log'].append({'t': time.time(), 'kind': 'broadcast', 'op': op['op_id'], 'seq': op['seq'],
                         'states': {t['name']: t['state'] for t in op['targets']}, 'settled': op['settled_at'] is not None})
    for client in clients:
        try:
            client.send(frame)
        except OSError:
            pass


def op_view(op, broadcast=False):
    targets = []
    for t in op['targets']:
        row = {k: v for k, v in t.items() if not k.startswith('_')}
        if broadcast:
            row.pop('connect_url', None)
            row.pop('connection_id', None)
        targets.append(row)
    return {'op_id': op['op_id'], 'seq': op['seq'], 'deadline_at': op['deadline_at'], 'settled': op['settled_at'] is not None,
            'settled_at': op['settled_at'], 'settled_by': op['settled_by'], 'targets': targets}


def move(op, name, to, actor='backend_watcher', detail=None, settle=None):
    """One target transition (and an optional settlement), then its broadcast. Caller holds LOCK."""
    target = next(t for t in op['targets'] if t['name'] == name)
    before = target['state']
    target['state'] = to
    target['resolved'] = to in ('connected', 'failed', 'expired', 'skipped', 'not_connected')
    if detail is not None:
        target['detail'] = detail
    if to != 'initiated':
        target['connect_url'] = None
    op['seq'] += 1
    if settle:
        op['settled_at'], op['settled_by'] = time.time(), settle
    change = {'target': name, 'from': before, 'to': to, 'actor': actor}
    threading.Thread(target=broadcast, args=(copy.deepcopy(op), change), daemon=True).start()


def mint(op, name, profile, alias=None):
    """A fresh link and a pending account for one target (named `alias` when given). Caller holds LOCK."""
    n = nous_for(profile)
    pending = account(name, status='pending', label='', alias=alias)
    n['accounts'] = [a for a in n['accounts'] if not (a['connector'] == name and a['status'] == 'pending')] + [pending]
    port = ARGS.port
    target = next(t for t in op['targets'] if t['name'] == name)
    target.update({'state': 'initiated', 'resolved': False, 'detail': '', 'connection_id': pending['connectionId'], 'attempt': secrets.token_hex(3),
                   'connect_url': f'http://127.0.0.1:{port}/__connect?' + urlencode({'op': op['op_id'], 'app': name}),
                   '_minted_at': time.time(), '_profile': profile})


# ---- the methods --------------------------------------------------------------------------------------------------
def check(method, params):
    for key in params:
        if key not in CONTRACT[method]:
            raise Refusal('INVALID_PARAMS', f'invalid params for {method}: {key}: Extra inputs are not permitted')
    for key in REQUIRED.get(method, ()):
        if key not in params:
            raise Refusal('INVALID_PARAMS')
    owner = params.get('owner')
    if 'owner' in CONTRACT[method] and owner is not None and owner != {'type': 'account'}:
        raise Refusal('INVALID_PARAMS')


def connectors_rpc(method, params):
    profile = params.get('profile') or 'default'
    with LOCK:
        C['log'].append({'t': time.time(), 'kind': 'rpc', 'method': method, 'profile': profile, 'params': copy.deepcopy(params)})
        n = nous_for(profile)
        fail = next((f for f in C['fail'] if f['method'] == method and f['count'] > 0), None)
        if fail:
            fail['count'] -= 1
    delay = getattr(ARGS, 'latency', 0) or 0
    if delay:
        time.sleep(delay / 1000)
    if n['mode'] == 'too_old':
        raise sg.RPCFailure(-32601, f'unknown method: {method}')
    check(method, params)
    if fail:
        raise Refusal(fail['reason'])
    if n['mode'] == 'signed_out':
        raise Refusal('NEEDS_NOUS_AUTH')
    if n['mode'] == 'unavailable':
        if method == 'connectors.list':
            return {'available': False, 'connectors': []}
        raise Refusal('CONNECTORS_UNAVAILABLE')
    with LOCK:
        return METHODS[method](profile, n, params)


def member_allows(n, slug):
    m = n['member']
    if m['mode'] == 'deny-all':
        return False
    if m['mode'] == 'allow':
        return slug in m.get('connectors', [])
    return slug not in m.get('disabled_connectors', [])


def m_list(profile, n, params):
    rows = []
    for slug, *_ in CATALOG:
        acct = next((a for a in sorted(n['accounts'], key=lambda a: not a['active']) if a['connector'] == slug), None)
        rows.append({'connector': slug, 'enabled': member_allows(n, slug), 'connected': acct is not None,
                     'connection_status': acct['status'] if acct else None, 'status_reason': acct['statusReason'] if acct else None,
                     'gateway_disabled_tools': list(n['member'].get('tools', {}).get(slug, []))})
    return {'available': True, 'connectors': rows}


def m_catalog(profile, n, params):
    if n['mode'] == 'catalog_down':
        raise Refusal('CATALOG_UNAVAILABLE', 'Connector catalog is unavailable.', 5034)
    return {'connectors': [{'slug': s, 'name': name, 'description': d, 'category': c, 'logo_url': None} for s, name, d, c in CATALOG]}


def m_accounts(profile, n, params):
    connector = params.get('connector')
    if connector is not None and not SLUG.match(str(connector)):
        raise Refusal('INVALID_PARAMS', 'connector must be a slug.')
    return {'accounts': [row_of(a, names=n['mode'] != 'no_names') for a in n['accounts'] if connector is None or a['connector'] == connector]}


def row_of(a, names=True):
    row = {'connection_id': a['connectionId'], 'connector': a['connector'], 'status': a['status'], 'status_reason': a['statusReason'],
           'label': a['label'], 'active': a['active'], 'created_at': a['createdAt'], 'updated_at': a['updatedAt']}
    if names:   # a Hermes from before account names sends neither key
        row.update({'alias': a['alias'], 'disabled': bool(a.get('disabled'))})
    return row


def m_rename(profile, n, params):
    if n['mode'] == 'no_names':
        raise sg.RPCFailure(-32601, 'unknown method: connectors.accounts.rename')
    cid, alias = str(params.get('connection_id') or ''), params.get('alias')
    if not cid or not isinstance(alias, str) or not ALIAS.match(alias):
        raise Refusal('INVALID_PARAMS', 'connection_id and a valid alias are required.')
    found = next((a for a in n['accounts'] if a['connectionId'] == cid), None)
    if not found:
        raise Refusal('CONNECTION_NOT_FOUND')
    if any(a['alias'] == alias and a['connector'] == found['connector'] and a is not found for a in n['accounts']):
        raise Refusal('ALIAS_TAKEN')
    found.update({'alias': alias, 'updatedAt': now_iso()})
    return row_of(found)


def m_remove(profile, n, params):
    cid = str(params.get('connection_id') or '')
    if not cid:
        raise Refusal('INVALID_PARAMS', 'connection_id is required.')
    found = next((a for a in n['accounts'] if a['connectionId'] == cid), None)
    if not found:
        raise Refusal('CONNECTION_NOT_FOUND')
    n['accounts'] = [a for a in n['accounts'] if a['connectionId'] != cid]
    return {'connection_id': cid, 'connector': found['connector'], 'status': 'removed'}


def m_tools(profile, n, params):
    slug = str(params.get('slug') or '')
    if not any(s == slug for s, *_ in CATALOG):
        raise Refusal('CONNECTOR_NOT_FOUND')
    if not isinstance(params.get('refresh', False), bool):
        raise Refusal('INVALID_PARAMS', 'slug and refresh are required parameters')
    return {'connector': slug, 'toolkit_version': '2026.10', 'etag': 'W/"fixture"', 'fetched_at': time.time(),
            'source': 'network' if params.get('refresh') else 'cache', 'stale': False, 'tools': tools_for(slug)}


def open_op_for(slug, profile):
    return next((op for op in C['ops'].values() if op['_profile'] == profile and op['settled_at'] is None
                 and any(t['name'] == slug for t in op['targets'])), None)


def m_connect(profile, n, params):
    names = params.get('connectors')
    if not isinstance(names, list) or not names or not all(isinstance(x, str) and SLUG.match(x) for x in names):
        raise Refusal('INVALID_PARAMS')
    if not isinstance(params.get('reconnect', False), bool):
        raise Refusal('INVALID_PARAMS')
    alias = params.get('alias')
    if alias is not None and (n['mode'] == 'no_names' or not isinstance(alias, str) or not ALIAS.match(alias) or len(names) != 1):
        raise Refusal('INVALID_PARAMS', 'invalid params for connectors.connect: alias')
    if params.get('connection_id') is not None and (not params.get('reconnect') or len(names) != 1 or alias):
        raise Refusal('INVALID_PARAMS', 'connection_id repairs one account: it needs reconnect, one connector and no alias')
    for name in names:
        if not any(s == name for s, *_ in CATALOG):
            raise Refusal('INVALID_PARAMS')
    held = open_op_for(names[0], profile)
    if held:
        targets = [t for t in held['targets'] if t['name'] in names]
        if any(t['state'] in ('failed', 'expired') for t in targets):
            for t in targets:            # a re-issue: a new link on the same operation (Try again)
                if t['state'] in ('failed', 'expired'):
                    t['state'] = 'initiated'
                    mint(held, t['name'], profile)
                    held['seq'] += 1
            threading.Thread(target=broadcast, args=(copy.deepcopy(held),), daemon=True).start()
            return op_view(held)
        if params.get('reconnect'):
            raise Refusal('LINK_STILL_VALID')
        return op_view(held)
    op = {'op_id': 'op_' + secrets.token_hex(6), 'seq': 1, 'deadline_at': time.time() + 600, 'settled_at': None, 'settled_by': None,
          '_profile': profile, 'targets': [{'name': name, 'kind': 'connector', 'action': 'reconnect' if params.get('reconnect') else 'connect',
                                            'state': 'pending', 'resolved': False} for name in names]}
    for name in names:
        mint(op, name, profile, alias=alias)
    C['ops'][op['op_id']] = op
    return {**op_view(op), 'status': 'initiated'}


def find_op(profile, params):
    op = C['ops'].get(str(params.get('op_id') or ''))
    if not op or op['_profile'] != profile or op['settled_at'] is not None and time.time() - op['settled_at'] > 30:
        raise Refusal('UNKNOWN_OPERATION')
    return op


def m_status(profile, n, params):
    return op_view(find_op(profile, params))


def m_wake(profile, n, params):
    op = find_op(profile, params)
    C['wakes'].append({'t': time.time(), 'op': op['op_id']})
    return {'status': 'ok'}


def m_respond(profile, n, params):
    op = find_op(profile, params)
    result = params.get('result')
    if not isinstance(result, dict) or set(result) - {'targets', 'settled_by'}:
        raise Refusal('INVALID_ANSWER', 'Connection answer is invalid.')
    if result.get('settled_by') == 'continue' and op['settled_at'] is None:
        op['seq'] += 1
        op['settled_at'], op['settled_by'] = time.time(), 'continue'
        threading.Thread(target=broadcast, args=(copy.deepcopy(op),), daemon=True).start()
    return {'status': 'ok', 'settled': op['settled_at'] is not None}


def layer(kind, body, revision):
    return {'kind': kind, 'revision': revision, 'body': copy.deepcopy(body)}


def m_policy_get(profile, n, params):
    if n['mode'] == 'org_required':
        raise Refusal('ORG_REQUIRED')
    effective = {'version': 1, 'revision': n['member_revision'], 'issued_at_ms': int(time.time() * 1000), **copy.deepcopy(n['member'])}
    if effective['mode'] == 'deny':
        effective['disabled_connectors'] = sorted(set(n['member'].get('disabled_connectors', [])) | set(n['org'].get('disabled_connectors', [])))
    return {'layers': [layer('org', n['org'], n['org_revision']), layer('member', n['member'], n['member_revision'])], 'effective': effective}


def m_policy_set(profile, n, params):
    if n['mode'] == 'org_required':
        raise Refusal('ORG_REQUIRED')
    change, expected = params.get('change'), params.get('expected_revision')
    if not isinstance(expected, str) or not REVISION.match(expected) or not isinstance(change, dict):
        raise Refusal('INVALID_PARAMS')
    kind = change.get('type')
    allowed = {'connector': {'type', 'connector', 'enabled'}, 'tools': {'type', 'connector', 'disabled_tools'}}.get(kind)
    if allowed is None or set(change) != allowed:
        raise Refusal('INVALID_PARAMS')
    if expected != n['member_revision']:
        raise Refusal('POLICY_CONFLICT')
    member = n['member']
    if member['mode'] in ('unrestricted', 'deny-all'):
        member = n['member'] = {'mode': 'deny', 'disabled_connectors': [], 'tools': {}}
    slug = change['connector']
    if kind == 'connector':
        if not isinstance(change['enabled'], bool):
            raise Refusal('INVALID_PARAMS')
        off = set(member.get('disabled_connectors', []))
        (off.discard if change['enabled'] else off.add)(slug)
        member['disabled_connectors'] = sorted(off)
    else:
        tools = change['disabled_tools']
        if not isinstance(tools, list) or not all(isinstance(t, str) for t in tools):
            raise Refusal('INVALID_PARAMS')
        if tools:
            member.setdefault('tools', {})[slug] = tools
        else:
            member.setdefault('tools', {}).pop(slug, None)
    n['member_revision'] = ulid()
    effective = {'version': 1, 'revision': n['member_revision'], 'issued_at_ms': int(time.time() * 1000), **copy.deepcopy(member)}
    return {'revision': n['member_revision'], 'effective': effective}


METHODS = {'connectors.list': m_list, 'connectors.catalog': m_catalog, 'connectors.accounts': m_accounts, 'connectors.accounts.remove': m_remove,
           'connectors.accounts.rename': m_rename,
           'connectors.tools': m_tools, 'connectors.connect': m_connect, 'connectors.operation.status': m_status,
           'connectors.operation.wake': m_wake, 'connection.respond': m_respond, 'connectors.policy.get': m_policy_get,
           'connectors.policy.set': m_policy_set}


# ---- the sign-in page and the link's clock ------------------------------------------------------------------------
def finish(op_id, app, choice):
    time.sleep(ARGS.sign_in_delay / 1000)
    with LOCK:
        op = C['ops'].get(op_id)
        if not op or op['settled_at'] is not None:
            return
        target = next((t for t in op['targets'] if t['name'] == app), None)
        if not target or target['state'] != 'initiated':
            return
        n = nous_for(op['_profile'])
        acct = next((a for a in n['accounts'] if a['connectionId'] == target.get('connection_id')), None)
        everyone_done = lambda: all(t['state'] in ('connected', 'failed', 'expired') or t['name'] == app for t in op['targets'])
        if choice == 'allow':
            if acct:
                label = f"fixture-{app}-{acct['alias']}@example.com" if acct.get('alias') else f'fixture-{app}@example.com'
                acct.update({'status': 'active', 'active': True, 'label': label, 'updatedAt': now_iso()})
            n['accounts'] = [a for a in n['accounts'] if not (a['connector'] == app and a is not acct and a['status'] != 'active' and not a.get('disabled'))]
            move(op, app, 'connected', settle='all_resolved' if everyone_done() else None)
        else:
            if acct:
                acct.update({'status': 'failed', 'active': False, 'statusReason': 'The sign-in was declined.', 'updatedAt': now_iso()})
            move(op, app, 'failed', detail='The sign-in was declined.', settle='all_resolved' if everyone_done() else None)


def expire(op_id):
    with LOCK:
        op = C['ops'].get(op_id)
        if not op or op['settled_at'] is not None:
            return False
        for t in op['targets']:
            if t['state'] == 'initiated':
                n = nous_for(op['_profile'])
                n['accounts'] = [a for a in n['accounts'] if a['connectionId'] != t.get('connection_id')]
                move(op, t['name'], 'expired', actor='clock', detail='')
        return True


def clock():
    while True:
        time.sleep(0.5)
        with LOCK:
            ttl = C.get('link_ttl', 120)
            due = [op['op_id'] for op in C.get('ops', {}).values() if op['settled_at'] is None
                   and any(t['state'] == 'initiated' and time.time() - t.get('_minted_at', time.time()) > ttl for t in op['targets'])]
        for op_id in due:
            expire(op_id)


# ---- wiring ---------------------------------------------------------------------------------------------------------
_answer = sg.Client.answer


def answer(self, frame):
    method = frame.get('method')
    if method not in CONTRACT:
        return _answer(self, frame)
    reply = {'jsonrpc': '2.0', 'id': frame['id']}
    try:
        reply['result'] = connectors_rpc(method, frame.get('params') or {})
    except Refusal as refusal:
        reply['error'] = {'code': refusal.code, 'message': refusal.message, 'data': {'reason': refusal.reason}}
    except sg.RPCFailure as failure:
        reply['error'] = {'code': failure.code, 'message': failure.message}
    try:
        self.send(reply)
    except OSError:
        pass


sg.Client.answer = answer
_handler = cg.handler


def handler(gateway):
    base = _handler(gateway)

    class Handler(base):
        def route(self, method):
            self.__dict__.pop('_cached_body', None)
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            if path == '/__connect' and method == 'GET':
                return self.sign_in_page(query) or True
            if path == '/__connectors':
                return self.connectors_control(method) or True
            if path == '/__nous' and method == 'GET':
                return self.nous_page(query) or True
            if path.startswith('/api/providers/oauth'):
                return self.nous_login(method, path, query) or True
            return super().route(method)

        # [nous-sign-in] Hermes' Nous device-code sign-in (hermes_cli/web_routers/oauth.py): start, the Nous page
        # (allow/deny), poll, cancel. Approving signs the profile in and turns its managed apps on ('ok').
        def nous_signed_in(self, profile):
            n = nous_for(profile)
            return n.get('signed_in', n['mode'] != 'signed_out')

        def nous_login(self, method, path, query):
            profile = (query.get('profile') or ['default'])[0]
            if method == 'POST':
                self.body()
            with LOCK:
                C['log'].append({'t': time.time(), 'kind': 'rest', 'method': method, 'path': path, 'profile': profile})
                if path == '/api/providers/oauth' and method == 'GET':
                    return self.reply(200, {'providers': [{'id': 'nous', 'name': 'Nous Portal', 'flow': 'device_code',
                                                           'status': {'logged_in': self.nous_signed_in(profile)}}]})
                if path == '/api/providers/oauth/nous/start' and method == 'POST':
                    sid = secrets.token_hex(8)
                    C['logins'][sid] = {'profile': profile, 'status': 'pending'}
                    host = self.headers.get('Host') or '127.0.0.1'
                    return self.reply(200, {'session_id': sid, 'flow': 'device_code', 'user_code': 'HQ7-4KD', 'expires_in': 120,
                                            'poll_interval': 2, 'verification_url': f'http://{host}/__nous?{urlencode({"session": sid})}'})
                m = re.match(r'^/api/providers/oauth/nous/poll/([^/]+)$', path)
                if m and method == 'GET':
                    sess = C['logins'].get(m.group(1))
                    if sess is None:
                        return self.reply(404, {'detail': 'Session not found or expired'})
                    return self.reply(200, {'session_id': m.group(1), 'status': sess['status'], 'error_message': None})
                m = re.match(r'^/api/providers/oauth/sessions/([^/]+)$', path)
                if m and method == 'DELETE':
                    sess = C['logins'].pop(m.group(1), None)
                    return self.reply(200, {'ok': sess is not None})
            return self.reply(404, {'detail': 'Not Found'})

        def nous_page(self, query):
            sid, choice = (query.get('session') or [''])[0], (query.get('choice') or [''])[0]
            with LOCK:
                sess = C['logins'].get(sid)
                C['log'].append({'t': time.time(), 'kind': 'nous-page', 'session': sid, 'choice': choice})
                if sess is None or sess['status'] != 'pending':
                    return self.page(410, '<h1>This sign-in has expired</h1>')
                if choice == 'allow':
                    sess['status'] = 'approved'
                    n = nous_for(sess['profile'])
                    n['signed_in'] = True
                    if n['mode'] == 'signed_out':
                        n['mode'] = 'ok'
                    return self.page(200, '<h1>Signed in</h1>')
                if choice == 'deny':
                    sess['status'] = 'denied'
                    return self.page(200, '<h1>Not signed in</h1>')
            return self.page(200, '<h1>Sign in to Nous</h1><p>Code HQ7-4KD</p>')

        def sign_in_page(self, query):
            op_id, app = (query.get('op') or [''])[0], (query.get('app') or [''])[0]
            choice = (query.get('choice') or [''])[0]
            with LOCK:
                C['log'].append({'t': time.time(), 'kind': 'page', 'op': op_id, 'app': app, 'choice': choice})
                op = C['ops'].get(op_id)
                target = next((t for t in (op or {}).get('targets', []) if t['name'] == app), None)
                live = bool(op and op['settled_at'] is None and target and target['state'] == 'initiated')
            if not live:
                return self.page(410, '<h1>This link has expired</h1><p>Go back to Hermes and connect again.</p>')
            if choice in ('allow', 'deny'):
                threading.Thread(target=finish, args=(op_id, app, choice), daemon=True).start()
                return self.page(200, f'<h1>{"Connected" if choice == "allow" else "Not connected"}</h1><p>You can close this page.</p>')
            q = urlencode({'op': op_id, 'app': app})
            return self.page(200, f'<h1>Connect {html.escape(app)}</h1><p>Let the stand-in Nous account use {html.escape(app)}?</p>'
                                  f"<p><a id='allow' href='/__connect?{q}&choice=allow'>Allow</a><a id='deny' href='/__connect?{q}&choice=deny'>Deny</a></p>")

        def connectors_control(self, method):
            if method == 'GET':
                with LOCK:
                    state = {'nous': C['nous'], 'ops': {k: {kk: vv for kk, vv in v.items()} for k, v in C['ops'].items()},
                             'log': C['log'], 'wakes': C['wakes'], 'link_ttl': C['link_ttl']}
                    return self.reply(200, json.loads(json.dumps(state, default=str)))
            body = self.body() if method == 'POST' else {}
            body = body if isinstance(body, dict) else {}
            expired = None
            with LOCK:
                if body.get('reset'):
                    reset()
                if 'mode' in body:
                    nous_for(body['mode']['profile'])['mode'] = body['mode']['mode']
                if 'multi_accounts' in body:   # [accounts] {profile}: that bot's Gmail gets multi_gmail()
                    n = nous_for(body['multi_accounts'].get('profile', 'default'))
                    n['accounts'] = [a for a in n['accounts'] if a['connector'] != 'gmail'] + multi_gmail()
                if 'signed_in' in body:   # [nous-sign-in] {profile, value}: Hermes' Nous sign-in apart from the mode
                    nous_for(body['signed_in']['profile'])['signed_in'] = bool(body['signed_in']['value'])
                if 'fail' in body:
                    C['fail'].append({'method': body['fail']['method'], 'reason': body['fail']['reason'], 'count': int(body['fail'].get('count', 1))})
                if 'link_ttl' in body:
                    C['link_ttl'] = float(body['link_ttl'])
                if 'external_policy' in body:
                    e = body['external_policy']
                    n = nous_for(e.get('profile', 'default'))
                    if n['member']['mode'] != 'deny':
                        n['member'] = {'mode': 'deny', 'disabled_connectors': [], 'tools': {}}
                    n['member'].setdefault('tools', {})[e['connector']] = list(e['disabled_tools'])
                    n['member_revision'] = ulid()
                if 'expire' in body:
                    expired = body['expire']['op'] if isinstance(body['expire'], dict) else None
                    if not expired:
                        expired = next((op['op_id'] for op in C['ops'].values() if op['settled_at'] is None), None)
            if expired:
                expire(expired)
            return self.reply(200, {'ok': True, 'expired': expired})

    return Handler


cg.handler = handler
ARGS = None
_parse = cg.argparse.ArgumentParser.parse_args


def parse_args(self, *a, **k):
    global ARGS
    if not any(action.dest == 'sign_in_delay' for action in self._actions):
        self.add_argument('--sign-in-delay', type=int, default=1500)
        self.add_argument('--multi-accounts', action='store_true')
    ARGS = _parse(self, *a, **k)
    return ARGS


cg.argparse.ArgumentParser.parse_args = parse_args

if __name__ == '__main__':
    reset()
    threading.Thread(target=clock, daemon=True).start()
    cg.main()
