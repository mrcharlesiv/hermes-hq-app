#!/usr/bin/env python3
"""Loopback-only stand-in gateway for the menus stream (docs/spec/1x-menus.md §12.2). Invented state; no upstream.

Built on the reference performance fixture (REF/scripts/performance-fixture-gateway.py), loaded as a module and
patched rather than copied: build47's socket loop gains Hermes' strict params (4000 with Hermes' wording), coded
errors, a three-provider model catalog with model switching (live, parked while a turn runs, confirm, failure),
reasoning/fast/yolo, a fixed commands catalog, slash.exec / command.dispatch outputs and directives, session.status /
save, process.stop, session.title, and a non-bot "Trip planning" chat for Rename (RPC and the REST PATCH fallback).

Chat actions (parity 240 §5, §8): rewinds (`prompt.submit` with `confirm_truncate` and `truncate_before_row_id`: the
bot chat's rows from that one on go, the kept rows are re-inserted under new ids, `survivor_row_id_map` answers),
`session.branch_stored` / `session.branch` / `session.create` (a new stored chat that opens), `session.close`, the
session row's PATCH {pinned, unread, archived} and DELETE, and the chat folder's REST reads (`/api/fs/list`,
`/api/fs/read-text`, `/api/git/review/list`, `/api/git/review/diff`).

Controls (no auth, loopback):
  GET  /__menus/state   {calls, rest, modelState, titles, optionsRefreshes, mode, rows, branches, deleted, botMessages}
  POST /__menus/mode    {"staleRuntime":n, "optionsFail":bool, "optionsDelay":s, "catalogFail":bool, "slowExec":s,
                         "oldGateway":bool, "profileReasoning":"high"|null (config.get reasoning without a session),
                         "usageNoContext":bool (session.usage without context: session.context_breakdown estimates it),
                         "processes":[{session_id, command, status, uptime_seconds, output_tail}] (process.list; process.kill
                         ends one), "seedReactions":bool (the bot's 👍 on Trip planning's second message, row 9003),
                         "balances":bool (tester batch 3: the catalog adds a signed-in Nous Portal and DeepSeek, and
                         billing.state answers signed in: $7.50 to spend, an account balance of $3.40), "routerBalance":"$12.34"|null (the Credits balance line
                         /usage gives a chat on OpenRouter), "usageFail":bool (slash.exec usage answers 5030),
                         "billingFail":bool (billing.state answers Hermes' fail-open error form), "routerQuota":bool
                         (OpenRouter's key has a spending limit: an "API key quota" window, so it shows as a plan)}
  Tester batch 3: slash.exec usage answers as Hermes words it (`_format_live_usage_output`): the session's tokens, a blank
  line, then the chat provider's account block (`render_account_usage_lines`): OpenRouter's and Codex's carry "Credits
  balance: $…"; with "balances" the Nous credits block follows ("Total usable: $7.50"). billing.state takes only
  `profile` (ProfileParams; anything else is 4000).
  POST /__menus/model   {"profile":"default", "model":…, "provider":…}: the chat's model as it opens (a chat on OpenRouter)
  Polish 2026-10-24: session.context_breakdown, process.list, process.kill and message.react (Tapbacks on Trip planning's
  rows and the bot chat's, one per author, null clears, the same emoji again retracts; a string row_id answers 4000).
  oldGateway answers -32601 for all four.
  POST /__menus/reset   model state, titles, call log, modes and the default transcript back to the start
  plus the performance fixture's /__fixture/plan, /__fixture/finish, /__fixture/history, /__fixture/state.

  python3 scripts/fixtures/menus-gateway.py --port 9729 --credentials build/fixtures/menus.json
"""
import base64, copy, hashlib, importlib.util, json, os, pathlib, struct, threading, time
from urllib.parse import urlparse, parse_qs

REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238')) / 'scripts'
_spec = importlib.util.spec_from_file_location('menus_perf', REF / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)          # its __main__ guard keeps it from starting
b47 = perf.base                         # the build47 module; its websocket()/main() look names up at call time
voice = b47.voice

LOCK = threading.RLock()


class Fault(Exception):
    """A Hermes error answer: {"error": {"code", "message"}}."""
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


def runtime_of(stored):
    return hashlib.sha256(stored.encode()).hexdigest()[:8]


TRIP = '20261005_090000_menus001'
TRIP_RT = runtime_of(TRIP)
TRIP_ROWS_TEXT = [
    ('user', 'Can you help me plan a long weekend in Lisbon?'),
    ('assistant', 'Of course. When are you going, and what do you enjoy most when you travel?'),
    ('user', 'Late October. Food, walking, a little history.'),
    # A path written out, not in backticks, opens in Files too (MenusTests test23c; Otto's "Files:" list, 2026-10-30).
    ('assistant', 'Then base yourself in Baixa or Chiado: flat-ish streets, trams, and good food within a few blocks.\n\n'
                  'Files:\n- /fixture/notes/packing.md'),
    ('user', 'Any day trips worth it?'),
    # The path in backticks opens in Files (MenusTests test23b); long, as a bot's report path is, so it wraps.
    ('assistant', 'Sintra for the palaces and Cascais for the coast. Both are under an hour by train.\n\n'
                  'Full detail: `/fixture/notes/day-trips-from-lisbon-sintra-and-cascais-2026-10-28.md`'),
]

DEFAULT_STATE = {
    'default': {'model': 'claude-sonnet-5', 'provider': 'anthropic', 'reasoning_effort': '', 'fast': False, 'yolo': False, 'pending': None,
                'approval_mode': 'smart'},
    'ivy': {'model': 'gpt-5.5', 'provider': 'openai-codex', 'reasoning_effort': '', 'fast': False, 'yolo': False, 'pending': None,
            'approval_mode': 'smart'},
}
MODEL_STATE = copy.deepcopy(DEFAULT_STATE)
DEFAULT_MODE = {'staleRuntime': 0, 'optionsFail': False, 'optionsDelay': 0, 'catalogFail': False, 'slowExec': 0, 'oldGateway': False,
                'offline': False, 'profileReasoning': None, 'writeFail': False,
                'usageNoContext': False, 'processes': [], 'seedReactions': False,
                'balances': False, 'routerBalance': '$12.34', 'usageFail': False, 'billingFail': False, 'routerQuota': False}
MODE = dict(DEFAULT_MODE)
STATE = {'calls': [], 'rest': [], 'optionsRefreshes': 0, 'rejected': []}
TITLES = {TRIP: 'Trip planning'}
TRIP_MESSAGES = []
# Chat actions: the session row's flags, deleted chats, and chats made by Branch ({stored id: {messages, parent, profile}}).
ROW_FLAGS = {}
DELETED = set()
BRANCHES = {}


def reset_trip():
    TRIP_MESSAGES.clear()
    for i, (role, text) in enumerate(TRIP_ROWS_TEXT):
        TRIP_MESSAGES.append({'role': role, 'content': text, 'row_id': 9001 + i, 'timestamp': 1791190800 + i * 60})


reset_trip()

# MARK: - Strict params (H:tui_gateway/contracts/registry.py:94-110)

SESSION = {'session_id', 'profile'}
ALLOWED = {
    'model.options': {'profile', 'session_id', 'explicit_only', 'include_unconfigured', 'refresh'},
    'config.set': {'profile', 'key', 'value', 'session_id', 'scope', 'confirm_expensive_model'},
    'config.get': {'profile', 'key', 'cwd', 'session_id'},
    'commands.catalog': {'session_id', 'profile'},
    'slash.exec': {'session_id', 'command', 'profile'},
    'command.dispatch': {'name', 'arg', 'session_id', 'profile'},
    'session.status': SESSION, 'session.save': SESSION, 'process.stop': SESSION,
    'session.title': {'session_id', 'profile', 'title'},
    'session.branch': {'session_id', 'profile', 'count'},
    'session.branch_stored': {'profile', 'cols', 'source', 'cwd', 'parent_session_id'},
    'session.close': SESSION,
    'session.interrupt': SESSION,
    'session.usage': SESSION,
    'billing.state': {'profile'},
    'session.context_breakdown': SESSION,
    'process.list': SESSION,
    'process.kill': SESSION | {'process_id'},
    'message.react': SESSION | {'row_id', 'newest_role', 'emoji', 'author'},
    'prompt.submit': {'session_id', 'profile', 'text', 'display_kind', 'interrupted', 'queued', 'surface', 'voice_context',
                      'voice_turn', 'title_preview', 'truncate_before_user_ordinal', 'truncate_before_row_id',
                      'truncate_before_message_id', 'confirm_truncate', 'confirm_empty_truncate', 'rebind_survivor_row_ids'},
}
# Calls `staleRuntime` refuses with 4001 (session-scoped writes and reads of this spec; never resume/submit).
STALE_ABLE = {'model.options', 'config.set', 'config.get', 'commands.catalog', 'slash.exec', 'command.dispatch',
              'session.status', 'session.save', 'process.stop', 'session.title'}
LONG = {'slash.exec', 'command.dispatch', 'model.options', 'billing.state'}


def check_params(method, params):
    allowed = ALLOWED.get(method)
    if allowed is None:
        return
    for key in params:
        if key not in allowed:
            raise Fault(4000, f'invalid params for {method}: {key}: Extra inputs are not permitted — the client and the Hermes '
                              'backend are out of sync (different versions); run `hermes update` and restart both')


def record(method, params):
    with LOCK:
        STATE['calls'].append({'method': method, 'params': {k: v for k, v in params.items() if k != 'data_url'}, 'at': time.time()})


def maybe_stale(method, params):
    if method in STALE_ABLE and params.get('session_id'):
        with LOCK:
            if MODE.get('staleRuntime', 0) > 0:
                MODE['staleRuntime'] -= 1
                raise Fault(4001, 'session not found')


# MARK: - Identity

def profile_of(params):
    sid = params.get('session_id')
    if sid in (TRIP, TRIP_RT):
        return 'default'
    return b47.owner(params)


def is_trip(params):
    return params.get('session_id') in (TRIP, TRIP_RT)


def info_for(profile, trip=False):
    s = MODEL_STATE[profile]
    pending = s.get('pending')
    info = {'model': (pending or {}).get('model') or s['model'], 'provider': (pending or {}).get('provider') or s['provider'],
            'reasoning_effort': s['reasoning_effort'], 'fast': s['fast'], 'yolo': s['yolo'], 'running': b47.RUNNING[profile],
            'approval_mode': s['approval_mode']}
    if trip:
        info['title'] = TITLES.get(TRIP, '')
    return info


_b47_resumed = b47.resumed


def menus_resumed(profile):
    answer = _b47_resumed(profile)
    answer['info'].update(info_for(profile))
    return answer


b47.resumed = menus_resumed
voice.resumed = menus_resumed


def trip_resumed():
    running = b47.RUNNING['default']
    info = {'cwd': '/fixture', 'tools': {}, 'skills': {}, 'mcp_servers': [], 'lazy': True, 'stored_session_id': TRIP,
            'profile_name': 'default', 'desktop_contract': 8, **info_for('default', trip=True)}
    return {'session_id': TRIP_RT, 'resumed': TRIP, 'session_key': TRIP, 'stored_session_id': TRIP, 'messages': [],
            'messages_omitted': True, 'message_count': len(TRIP_MESSAGES), 'status': 'running' if running else 'idle',
            'running': running, 'inflight': None, 'info': info}


def emit_runtime(runtime, kind, payload):
    frame = {'jsonrpc': '2.0', 'method': 'event', 'params': {'type': kind, 'session_id': runtime, 'payload': payload or {}}}
    with b47.LOCK:
        clients = list(b47.CLIENTS)
    for client in clients:
        try:
            client.send(frame)
        except OSError:
            pass


def emit_info(profile):
    emit_runtime(menus_resumed(profile)['session_id'], 'session.info', info_for(profile))
    if profile == 'default':
        emit_runtime(TRIP_RT, 'session.info', info_for('default', trip=True))


# MARK: - The model catalog

OPENROUTER = ['deepseek/deepseek-v4.1-flash', 'moonshotai/kimi-k2-thinking', 'qwen/qwen2.5-coder:14b', 'broken-model',
              'google/gemini-2.5-pro', 'google/gemini-2.5-flash', 'z-ai/glm-5.2', 'minimax/minimax-m2', 'x-ai/grok-4',
              'mistralai/mistral-large-2', 'meta-llama/llama-4-maverick', 'meta-llama/llama-4-scout', 'qwen/qwen3-235b-a22b',
              'qwen/qwen3-30b-a3b', 'deepseek/deepseek-r2', 'cohere/command-r-plus', 'nvidia/nemotron-ultra-253b',
              'microsoft/phi-4', 'amazon/nova-pro', 'baidu/ernie-4.5', 'xiaomi/mimo-7b', 'nousresearch/hermes-4-405b',
              'nousresearch/hermes-4-70b', 'perplexity/sonar-pro', 'ai21/jamba-1.7', 'inception/mercury',
              'openai/gpt-oss-120b', 'openai/gpt-oss-20b', 'thudm/glm-4.1v-9b', 'bytedance/seed-oss-36b']

PROVIDERS = [
    {'slug': 'anthropic', 'name': 'Anthropic', 'models': ['claude-sonnet-5', 'claude-opus-4-5-20251101', 'claude-haiku-4-5'],
     'is_current': True, 'authenticated': True,
     'capabilities': {'claude-sonnet-5': {'fast': True, 'reasoning': True, 'can_disable_reasoning': True},
                      'claude-opus-4-5-20251101': {'fast': False, 'reasoning': True, 'can_disable_reasoning': True},
                      'claude-haiku-4-5': {'fast': False, 'reasoning': False}}},
    {'slug': 'openai-codex', 'name': 'ChatGPT or Codex Subscription (Experimental)', 'aliases': ['codex'], 'authenticated': True,
     'models': ['gpt-5.5', 'gpt-5.5-fast', 'gpt-5.5-mini', 'openai/gpt-5.5-mini'],
     'capabilities': {'gpt-5.5': {'fast': False, 'reasoning': True, 'can_disable_reasoning': False}}},
    {'slug': 'openrouter', 'name': 'OpenRouter', 'authenticated': True, 'models': OPENROUTER},
]


def catalog_providers():
    """PROVIDERS with what ⋯ › Usage & Limits and Model Prices read (`pricing`, `usage`, `limit`), the reset times from
    now. Anthropic is priced here (the real gateway leaves it to models.dev) so the pages never reach the network."""
    from datetime import datetime, timedelta, timezone
    def at(hours):
        return (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat()
    rows = copy.deepcopy(PROVIDERS)
    anthropic, codex, router = rows
    anthropic['pricing'] = {'claude-sonnet-5': {'input': '$3.00', 'output': '$15.00', 'cache': '$0.30', 'free': False},
                            'claude-opus-4-5-20251101': {'input': '$5.00', 'output': '$25.00', 'cache': '$0.50', 'free': False},
                            'claude-haiku-4-5': {'input': '$1.00', 'output': '$5.00', 'cache': '$0.10', 'free': False}}
    anthropic['usage'] = {'windows': [
        {'label': 'Session', 'used_percent': 38, 'resets_at': at(3.4), 'scope': 'account'},
        {'label': 'Weekly', 'used_percent': 71, 'resets_at': at(4 * 24 + 5), 'scope': 'account'},
        {'label': 'Opus weekly', 'used_percent': 94, 'resets_at': at(4 * 24 + 5), 'scope': 'model'}]}
    codex['usage'] = {'windows': [], 'accounts': [
        {'id': 'codex:work', 'label': 'work', 'state': 'ready',
         'windows': [{'label': 'Weekly', 'used_percent': 14, 'resets_at': at(6 * 24 + 3), 'scope': 'account'}]},
        {'id': 'codex:home', 'label': 'home', 'state': 'limited', 'resets_at': at(26), 'windows': []}]}
    prices = [('$0.10', '$0.40'), ('$0.60', '$2.50'), ('free', 'free'), ('', '')]
    router['pricing'] = {}
    for i, model in enumerate(OPENROUTER):
        inp, out = prices[i % len(prices)]
        if inp:
            router['pricing'][model] = {'input': inp, 'output': out, 'cache': None, 'free': inp == 'free'}
    if MODE.get('routerQuota'):
        # Tester batch 3: a key with a spending limit (H:agent/account_usage.py "API key quota", no reset time).
        router['usage'] = {'windows': [{'label': 'API key quota', 'used_percent': 25, 'resets_at': None, 'scope': 'account'}]}
    if MODE.get('balances'):
        # Tester batch 3: two more pay-as-you-go logins, neither with a plan or a window (a Nous credits account, a key).
        rows.append({'slug': 'nous', 'name': 'Nous Portal', 'authenticated': True, 'models': ['hermes-4-405b']})
        rows.append({'slug': 'deepseek', 'name': 'DeepSeek', 'authenticated': True, 'models': ['deepseek-v4']})
    return rows


def usage_report(provider):
    """`/usage` as Hermes answers slash.exec (H:tui_gateway/methods_slash.py `_format_live_usage_output`): the session's
    tokens, a blank line, then the chat provider's account block (H:agent/account_usage.py `render_account_usage_lines`;
    OpenRouter's and Codex's details carry "Credits balance: $…") and, signed in to Nous, its credits block ("Total
    usable: $…"). Other providers have no block here."""
    tokens = 'Usage: 12 calls · 48,210 in / 3,904 out · 52,114 total\nContext: 31% of 200K tokens'
    blocks = {
        'anthropic': ['📈 Account limits', 'Provider: anthropic', 'Current session: 62% remaining (38% used) • resets in 3h 24m'],
        'openai-codex': ['📈 Account limits', 'Provider: openai-codex (Plus)',
                         'Session: 90% remaining (10% used) • resets in 2h 3m', 'Credits balance: $5.00'],
        'openrouter': ['📈 Account limits', 'Provider: openrouter']
                      + (['API key quota: 75% remaining (25% used) • $15.00 of $20.00 remaining'] if MODE.get('routerQuota') else [])
                      + ([f"Credits balance: {MODE['routerBalance']}"] if MODE.get('routerBalance') else [])
                      + ['API key usage: $5.00 total • $1.25 today'],
    }
    lines = blocks.get(provider, [])
    if MODE.get('balances'):
        # Signed in to Nous: Hermes adds its credits block to every chat's /usage (`nous_credits_lines`), straight after.
        lines = lines + ['📈 Nous credits', 'Provider: nous', 'Subscription credits: $0.00', 'Top-up credits: $7.50',
                         'Total usable: $7.50', 'Top up: https://portal.example.invalid/billing', '(or run /topup)']
    return tokens + ('\n\n' + '\n'.join(lines) if lines else '')


def billing_state():
    """`billing.state` (H:tui_gateway/methods_session.py, `_serialize_billing_state`): fail-open, so a portal failure is an
    ok answer with `error`; not signed in is `logged_in: false` alone."""
    if MODE.get('billingFail'):
        return {'ok': True, 'logged_in': False, 'free_tier_account': False, 'error': 'could not load billing state'}
    if not MODE.get('balances'):
        return {'ok': True, 'logged_in': False, 'free_tier_account': False, 'free_tier_model': None}
    # The account balance (`balance_display`, the portal's balanceUsd) is not the credits Nous can spend: those are
    # `usage.total_spendable_display` (H:agent/billing_usage.py `usage_model_from_account`, /usage's "Total usable").
    # They differ here so a test that sees $7.50 from billing.state alone proves which one the app shows.
    return {'ok': True, 'logged_in': True, 'free_tier_account': False, 'free_tier_model': None, 'org_name': 'Fixture Org',
            'balance_usd': '3.4', 'balance_display': '$3.40', 'portal_url': 'https://portal.example.invalid/billing',
            'usage': {'ok': True, 'available': True, 'status': 'healthy', 'plan_name': None,
                      'subscription_remaining_display': '$0.00', 'topup_remaining_display': '$7.50',
                      'total_spendable_display': '$7.50', 'has_topup': True}}


NAMES = {'claude-sonnet-5': 'Sonnet 5', 'claude-opus-4-5-20251101': 'Opus 4.5', 'claude-haiku-4-5': 'Haiku 4.5'}
LEVELS = {'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'}
DISPLAY_WORDS = {'show', 'hide', 'full', 'clamp'}
MARKER = '[System: The active model for this chat has changed to '


def apply_switch(profile, model, provider):
    s = MODEL_STATE[profile]
    s['model'], s['provider'], s['pending'] = model, provider, None
    with b47.LOCK:
        rid = b47.append(profile, 'user', f'{MARKER}{model} via provider {provider}. From this point forward, use this runtime '
                                          'metadata when answering questions about what model/provider is active.]')
        b47.MESSAGES[profile][-1]['display_kind'] = 'model_switch'
    emit_info(profile)
    return rid


def config_set(params):
    profile = profile_of(params)
    key, value = params.get('key'), params.get('value')
    s = MODEL_STATE[profile]
    if key == 'model':
        if not value or not str(value).strip():
            raise Fault(4002, 'model value required')
        parts = str(value).split()
        model = parts[0]
        provider = parts[parts.index('--provider') + 1] if '--provider' in parts and parts.index('--provider') + 1 < len(parts) else s['provider']
        if model == 'broken-model':
            raise Fault(5001, f"Model switch to broken-model failed (fixture provider refused); staying on {s['model']}.")
        base = {'key': 'model', 'value': model, 'warning': '', 'confirm_required': False, 'confirm_message': '', 'scope': 'session'}
        if model == 'claude-opus-4-5-20251101' and not params.get('confirm_expensive_model'):
            message = 'Opus 4.5 costs about 5× more per token than Sonnet 5.\n\nSwitch anyway?'
            return {**base, 'warning': message, 'confirm_required': True, 'confirm_message': message,
                    **({'deferred': False} if b47.RUNNING[profile] else {})}
        if b47.RUNNING[profile]:
            if MODE.get('oldGateway'):
                raise Fault(4009, 'session busy — finish or stop the current turn before switching models')
            s['pending'] = {'model': model, 'provider': provider}
            emit_info(profile)
            return {**base, 'deferred': True}
        apply_switch(profile, model, provider)
        return base
    if key == 'reasoning':
        word = str(value or '').strip().lower()
        if word not in LEVELS and word not in DISPLAY_WORDS:
            raise Fault(4002, f'unknown reasoning value: {value}')
        if word in LEVELS:
            s['reasoning_effort'] = word
        emit_info(profile)
        return {'key': 'reasoning', 'value': word, **({'scope': params['scope']} if params.get('scope') else {})}
    if key == 'fast':
        if s['model'] == 'claude-haiku-4-5':
            raise Fault(4002, 'fast mode is not available for this model')
        s['fast'] = value == 'fast'
        emit_info(profile)
        return {'key': 'fast', 'value': 'fast' if s['fast'] else 'normal'}
    if key == 'yolo':
        s['yolo'] = value == '1'
        emit_info(profile)
        return {'key': 'yolo', 'value': '1' if s['yolo'] else '0', 'scope': 'session'}
    if key == 'approvals.mode':
        # The profile's config.yaml `approvals.mode`: every chat with the bot (Hermes repaints each one's session.info).
        word = str(value or '').strip().lower()
        if word not in ('manual', 'smart', 'off'):
            raise Fault(4002, f'unknown approval mode: {value}; pick one of manual|smart|off')
        s['approval_mode'] = word
        emit_info(profile)
        return {'key': 'approvals.mode', 'value': word}
    raise Fault(4002, f'unknown config key: {key}')


# MARK: - The commands catalog (spec 1x §12.5)

def _usage(desc, name, hint):
    return f'{desc} (usage: /{name} {hint})' if hint else desc


CATEGORIES = [
    ('Session', [
        ('/new', 'text', None, _usage('Start a new session (fresh session ID + history)', 'new', '[name]')),
        ('/retry', None, None, 'Retry the last message (resend to agent)'),
        ('/title', 'text', None, _usage('Set a title for the current session', 'title', '[name]')),
        ('/compress', 'text', None, _usage('Manually compress conversation context', 'compress', '[focus topic]')),
        ('/stop', None, None, 'Kill all running background processes'),
        ('/status', None, None, 'Show session info'),
        ('/plan', 'text', None, _usage('Write an implementation plan', 'plan', '[request]')),
        ('/goal', 'mixed', None, _usage('Set a standing goal', 'goal', '[text | pause | resume | clear | status]')),
        ('/undo', 'text', None, _usage('Back up N user turns and re-prompt', 'undo', '[N]')),
        ('/queue', 'mixed', None, _usage('Queue a prompt for the next turn', 'queue', '<prompt>')),
        ('/agents', None, None, 'Show active agents and running tasks'),
        ('/resume', 'mixed', None, _usage('Resume a previously-named session', 'resume', '[name]')),
    ]),
    ('Configuration', [
        ('/model', None, 'hidden', _usage('Switch model for this session', 'model', '[model] [--global]')),
        ('/reasoning', 'options', None, _usage('Manage reasoning effort and display', 'reasoning', '[level|show|hide]')),
        ('/yolo', None, None, 'Toggle YOLO mode (skip all dangerous command approvals)'),
        ('/personality', 'options', None, _usage('Set a predefined personality', 'personality', '[name]')),
        ('/fast', 'options', 'advanced', _usage('Toggle fast mode', 'fast', '[normal|fast|status]')),
        ('/voice', 'options', 'composer-voice', _usage('Toggle voice mode', 'voice', '[on|off|tts|status]')),
        ('/config', None, 'terminal', 'Show current configuration'),
    ]),
    ('Info', [
        ('/usage', 'text', None, _usage('Show token usage and rate limits', 'usage', '[reset [--force]]')),
        ('/help', 'text', None, _usage('Show available commands', 'help', '[command]')),
        ('/version', None, None, 'Show Hermes Agent version'),
        ('/whoami', None, None, 'Show your slash command access'),
        ('/debug', 'text', None, _usage('Upload debug report (system info + logs)', 'debug', '[note]')),
    ]),
    ('Tools & Skills', [
        ('/tools', 'options', None, _usage('Manage tools', 'tools', '[list|disable|enable] [name...]')),
        ('/bundles', None, None, 'List skill bundles'),
    ]),
]
SKILLS = [('/release-notes', 'Draft release notes from the changelog'), ('/gif-search', 'Find a GIF for anything'),
          ('/changelog', 'Summarise recent commits')]


def commands_catalog():
    categories = [{'name': name, 'pairs': [[c, d] for c, _, _, d in rows]} for name, rows in CATEGORIES]
    pairs = [[c, d] for _, rows in CATEGORIES for c, _, _, d in rows] + [[c, d] for c, d in SKILLS]
    commands = {c: {'argument_mode': mode, 'desktop': desktop} for _, rows in CATEGORIES for c, mode, desktop, _ in rows}
    commands['/reset'] = {'argument_mode': 'text', 'desktop': None}
    commands['/q'] = {'argument_mode': 'mixed', 'desktop': None}
    canon = {c: c for c in commands}
    canon['/reset'] = '/new'
    canon['/q'] = '/queue'
    return {'pairs': pairs, 'categories': categories, 'commands': commands, 'canon': canon,
            'skills': {'/release-notes': {'usage': 5, 'origin': 'local'}, '/gif-search': {'usage': 2, 'origin': 'hub'},
                       '/changelog': {'usage': 0, 'origin': 'bundled'}},
            'skill_count': 3, 'warning': '', 'sub': {}}


# MARK: - Slash

def last_user_text(profile):
    with b47.LOCK:
        for row in reversed(b47.MESSAGES[profile]):
            if row.get('role') == 'user' and not row.get('display_kind'):
                return row.get('content') or ''
    return ''


def slash_exec(params):
    if MODE.get('slowExec'):
        time.sleep(float(MODE['slowExec']))
    line = str(params.get('command') or '').strip()
    name, _, arg = line.partition(' ')
    name, arg = name.lower(), arg.strip()
    profile = profile_of(params)
    if name == 'usage':
        if MODE.get('usageFail'):
            raise Fault(5030, 'usage report failed (fixture)')
        return {'output': usage_report(info_for(profile)['provider'])}
    if name == 'version':
        return {'output': 'Hermes Agent v0.9.0 (fixture)'}
    if name == 'whoami':
        return {'output': 'admin (fixture)'}
    if name == 'agents':
        return {'output': 'No active agents.'}
    if name == 'bundles':
        return {'output': 'No skill bundles.'}
    if name == 'title' and not arg:
        stored = TRIP if is_trip(params) else voice.SIDS[profile]
        return {'output': f"Title: {TITLES.get(stored, 'Bot Chat')}"}
    if name == 'retry':
        return {'type': 'send', 'message': last_user_text(profile)}
    if name == 'undo':
        return {'type': 'prefill', 'message': last_user_text(profile)}
    if name == 'plan':
        return {'type': 'send', 'message': f'[plan] {arg}', 'display': f'/plan {arg}'}
    if name == 'goal':
        return {'type': 'send', 'message': arg, 'notice': f'⊙ Goal set: {arg}'}
    if name in ('release-notes', 'gif-search'):
        raise Fault(4018, f'skill command: use command.dispatch for /{name}')
    if name == 'fail':
        raise Fault(5030, 'slash worker crashed (fixture)')
    return {'output': '(no output)'}


def skill_body(name, arg):
    return (f'[IMPORTANT: The user has invoked the "{name}" skill. The full skill content is loaded below.]\n\n'
            f'# {name}\nFixture skill body: follow the steps.\n\n'
            f'The user has provided the following instruction alongside the skill invocation: {arg}\n\n[Runtime note: fixture]')


def command_dispatch(params):
    name, arg = str(params.get('name') or '').lower(), str(params.get('arg') or '')
    if name == 'release-notes':
        return {'type': 'skill', 'name': 'release-notes', 'message': skill_body('release-notes', arg),
                'display': f'/release-notes {arg}'.strip()}
    if name == 'gif-search':
        return {'type': 'skill', 'name': 'gif-search', 'message': skill_body('gif-search', arg)}
    if name == 'fail':
        raise Fault(5001, 'not a quick/plugin/bundle/skill command: fail')
    raise Fault(4018, f'not a quick/plugin/bundle/skill command: {name}')


def missing(method):
    raise Fault(-32601, f'unknown method: {method} — the client and the Hermes backend are out of sync (different versions)')


# MARK: - Dispatch

# MARK: - Chat actions

def branch_resumed(stored):
    branch = BRANCHES[stored]
    info = {'cwd': '/fixture', 'tools': {}, 'skills': {}, 'mcp_servers': [], 'lazy': True, 'stored_session_id': stored,
            'profile_name': branch['profile'], 'desktop_contract': 8, **info_for(branch['profile'])}
    info['running'] = False
    return {'session_id': runtime_of(stored), 'resumed': stored, 'session_key': stored, 'stored_session_id': stored,
            'messages': [], 'messages_omitted': True, 'message_count': len(branch['messages']), 'status': 'idle',
            'running': False, 'inflight': None, 'info': info}


def branch_of(params):
    sid = params.get('session_id')
    return next((stored for stored in BRANCHES if sid in (stored, runtime_of(stored))), None)


def make_branch(profile, parent, messages):
    stored = f'20261011_120000_branch{len(BRANCHES) + 1:02d}'
    rows = [{**m, 'row_id': 20001 + len(BRANCHES) * 100 + i} for i, m in enumerate(copy.deepcopy(messages))]
    BRANCHES[stored] = {'messages': rows, 'parent': parent, 'profile': profile}
    return {'session_id': runtime_of(stored), 'stored_session_id': stored, 'message_count': len(rows)}


def stored_messages(profile, sid):
    """The rows of the chat a session id names (the trip chat, a branch, or a bot's chat)."""
    if sid in (TRIP, TRIP_RT):
        return TRIP_MESSAGES
    branch = branch_of({'session_id': sid})
    if branch:
        return BRANCHES[branch]['messages']
    return b47.MESSAGES[profile]


def truncate_for_rewind(params):
    """A rewind's prompt.submit: the rows from the named user row on go, the kept rows come back under new ids."""
    profile = profile_of(params)
    target = params.get('truncate_before_row_id')
    with b47.LOCK:
        rows = b47.MESSAGES[profile]
        index = next((i for i, row in enumerate(rows) if row.get('row_id') == target and row.get('role') == 'user'), None)
        if index is None:
            raise Fault(4018, 'message no longer in session history')
        kept, mapping = [], {}
        for row in rows[:index]:
            fresh = {**row, 'row_id': b47.NEXT_ROW}
            mapping[str(row['row_id'])] = b47.NEXT_ROW
            b47.NEXT_ROW += 1
            kept.append(fresh)
        for old in params.get('rebind_survivor_row_ids') or []:
            mapping.setdefault(str(old), None)
        b47.MESSAGES[profile] = kept
    return {'survivor_row_id_map': mapping}


def seed_reactions():
    """`seedReactions`: the bot's 👍 on Trip planning's row 9003 ("Late October…"), once per reset."""
    if MODE.get('seedReactions'):
        for m in TRIP_MESSAGES:
            if m['row_id'] == 9003 and 'display_metadata' not in m:
                m['display_metadata'] = {'reactions': [{'emoji': '👍', 'author': 'agent', 'at': 1791191000.0, 'seen': True}]}


def message_react(profile, params):
    """H:tui_gateway/methods_session.py:1312 — one per author; the same emoji again retracts; null clears."""
    row_id, newest = params.get('row_id'), params.get('newest_role')
    if row_id is not None and (isinstance(row_id, bool) or not isinstance(row_id, int)):
        raise Fault(4000, 'invalid params for message.react: row_id: Input should be a valid integer')
    if row_id is None and newest not in ('user', 'assistant'):
        raise Fault(4023, 'row_id or newest_role required')
    emoji = params.get('emoji')
    if emoji is not None and not (isinstance(emoji, str) and emoji.strip()):
        raise Fault(4024, 'emoji must be a non-empty string or null')
    author = params.get('author') or 'user'
    if author not in ('user', 'agent'):
        raise Fault(4025, "author must be 'user' or 'agent'")
    rows = TRIP_MESSAGES if is_trip(params) else b47.MESSAGES.get(profile, [])
    with LOCK:
        seed_reactions()
        if row_id is None:
            row = next((m for m in reversed(rows) if m.get('role') == newest and m.get('row_id') is not None), None)
            if row is None:
                raise Fault(4040, 'no message to react to yet')
        else:
            row = next((m for m in rows if m.get('row_id') == row_id), None)
            if row is None:
                raise Fault(4040, 'message not found in this session')
        meta = row.setdefault('display_metadata', {})
        current = list(meta.get('reactions') or [])
        previous = next((r for r in current if r.get('author') == author), None)
        current = [r for r in current if r.get('author') != author]
        if emoji is not None and not (previous and previous.get('emoji') == emoji.strip()):
            current.append({'emoji': emoji.strip(), 'author': author, 'at': time.time(), 'seen': False})
        meta['reactions'] = current
        return {'row_id': row['row_id'], 'reactions': copy.deepcopy(current)}


def menus_rpc(method, params):
    profile = profile_of(params)
    if method in ('session.resume', 'session.activate') and is_trip(params):
        return trip_resumed()
    if method in ('session.resume', 'session.activate') and branch_of(params):
        return branch_resumed(branch_of(params))
    if method == 'session.branch_stored':
        parent = params.get('parent_session_id')
        if MODE.get('oldGateway'):
            missing(method)
        source = TRIP_MESSAGES if parent == TRIP else BRANCHES.get(parent, {}).get('messages') or b47.MESSAGES[profile]
        return make_branch(params.get('profile') or 'default', parent, source)
    if method == 'session.branch':
        count = int(params.get('count') or 0)
        rows = [m for m in stored_messages(profile, params.get('session_id')) if m.get('role') in ('user', 'assistant') and m.get('content')]
        if count <= 0 or count > len(rows):
            raise Fault(4002, f'count out of range: {count}')
        return make_branch(profile, params.get('session_id'), rows[:count])
    if method == 'session.create' and params.get('messages'):
        rows = [{'role': m.get('role'), 'content': m.get('content'), 'timestamp': int(time.time())} for m in params['messages']]
        return make_branch(params.get('profile') or 'default', params.get('parent_session_id'), rows)
    if method == 'session.close':
        return {'ok': True}
    if method == 'model.options':
        if MODE.get('optionsDelay'):
            time.sleep(float(MODE['optionsDelay']))
        if MODE.get('optionsFail'):
            raise Fault(5033, 'model inventory failed (fixture)')
        if params.get('refresh'):
            with LOCK:
                STATE['optionsRefreshes'] += 1
        info = info_for(profile)
        return {'providers': catalog_providers(), 'model': info['model'], 'provider': info['provider']}
    if method in ('session.context_breakdown', 'process.list', 'process.kill', 'message.react') and MODE.get('oldGateway'):
        missing(method)
    if method == 'session.usage' and MODE.get('usageNoContext'):
        return {'calls': 0, 'input': 0, 'output': 0, 'total': 0, 'cost_usd': 0}
    if method == 'session.context_breakdown':
        return {'categories': [{'id': 'system_prompt', 'tokens': 9000}, {'id': 'messages', 'tokens': 32000}],
                'context_files': [], 'context_max': 200000, 'context_used': 41000, 'context_percent': 21,
                'context_source': 'local_estimate', 'context_estimated': True, 'estimated_total': 41000,
                'model': info_for(profile)['model']}
    if method == 'process.list':
        with LOCK:
            return {'processes': [dict(p) for p in MODE.get('processes') or []]}
    if method == 'process.kill':
        with LOCK:
            proc = next((p for p in MODE.get('processes') or [] if p.get('session_id') == params.get('process_id')), None)
            if proc is None:
                raise Fault(4044, f"no such process: {params.get('process_id')}")
            MODE['processes'] = [p for p in MODE['processes'] if p is not proc]
        return {'status': 'killed', 'session_id': proc['session_id']}
    if method == 'message.react':
        return message_react(profile, params)
    if method == 'billing.state':
        return billing_state()
    if method == 'session.usage':
        return {'calls': 12, 'input': 48210, 'output': 3904, 'total': 52114, 'context_used': 62000, 'context_max': 200000,
                'context_percent': 31, 'cost_usd': 0.42, 'credits_lines': ['Nous credits: $4.20 left', 'Top-up pays past the plan: on']}
    if method == 'config.set':
        return config_set(params)
    if method == 'config.get':
        if params.get('key') == 'reasoning':
            if not params.get('session_id'):
                # No session: the profile's config.yaml `agent.reasoning_effort` (Hermes answers "medium" when unset).
                return {'value': MODE.get('profileReasoning') or 'medium', 'display': 'hide'}
            return {'value': MODEL_STATE[profile]['reasoning_effort'] or 'medium', 'display': 'hide'}
        if params.get('key') == 'approvals.mode':
            return {'value': MODEL_STATE[profile]['approval_mode']}
        return {'value': None}
    if method == 'commands.catalog':
        if MODE.get('catalogFail'):
            raise Fault(5020, 'commands catalog failed (fixture)')
        return commands_catalog()
    if method == 'slash.exec':
        return slash_exec(params)
    if method == 'command.dispatch':
        return command_dispatch(params)
    if method == 'session.status':
        if MODE.get('oldGateway'):
            missing(method)
        state = 'running' if b47.RUNNING[profile] else 'idle'
        return {'output': f"Session 5cc537d1 · {state} · {info_for(profile)['model']}"}
    if method == 'session.save':
        if MODE.get('oldGateway'):
            missing(method)
        stored = TRIP if is_trip(params) else voice.SIDS[profile]
        return {'file': f'/fixture/sessions/{stored}.json'}
    if method == 'process.stop':
        return {'killed': 0}
    if method == 'session.title':
        title = str(params.get('title') or '').strip()
        if not title:
            raise Fault(4021, 'title required')
        if title == 'Taken':
            raise Fault(4022, "Title 'Taken' is already in use")
        stored = TRIP if is_trip(params) else voice.SIDS[profile]
        TITLES[stored] = title
        if is_trip(params):
            emit_runtime(TRIP_RT, 'session.info', info_for('default', trip=True))
        return {'pending': False, 'title': title}
    return _prev_rpc(method, params)


_prev_rpc = b47.rpc
b47.rpc = menus_rpc


def apply_pending(profile):
    pending = MODEL_STATE[profile].get('pending')
    if pending:
        apply_switch(profile, pending['model'], pending['provider'])


class MenusClient(b47.Client):
    """build47's client; a prompt.submit answer can carry extra keys (a rewind's `survivor_row_id_map`)."""
    def __init__(self, connection):
        super().__init__(connection)
        self.extra = {}

    def send(self, value):
        if isinstance(value, dict) and 'result' in value and value.get('id') in self.extra:
            value = {**value, 'result': {**value['result'], **self.extra.pop(value['id'])}}
        super().send(value)


def menus_websocket(connection, key):
    """build47's socket loop, plus strict params, the call log, `staleRuntime`, coded errors and worker threads."""
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    connection.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '
                        + accept + '\r\n\r\n').encode())
    client = MenusClient(connection)

    def read(n):
        data = b''
        while len(data) < n:
            chunk = connection.recv(n - len(data))
            if not chunk:
                raise ConnectionError()
            data += chunk
        return data

    def answer(frame):
        method, params = frame['method'], frame.get('params') or {}
        reply = {'jsonrpc': '2.0', 'id': frame['id']}
        try:
            reply['result'] = b47.rpc(method, params)
        except Fault as fault:
            reply['error'] = {'code': fault.code, 'message': fault.message, **({'data': fault.data} if fault.data is not None else {})}
        except ValueError as error:
            reply['error'] = {'code': -32001, 'message': str(error)}
        try:
            client.send(reply)
        except OSError:
            pass

    with b47.LOCK:
        b47.CLIENTS.add(client)
    try:
        client.send({'jsonrpc': '2.0', 'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {
            'heartbeat': True, 'change_events': True, 'replay_epoch': 'menus', 'desktop_contract': 8}}})
        fragments = bytearray()
        while True:
            first, second = read(2)
            opcode, n, final = first & 15, second & 127, bool(first & 128)
            if n == 126:
                n = struct.unpack('>H', read(2))[0]
            elif n == 127:
                n = struct.unpack('>Q', read(8))[0]
            if n > 16 * 1024 * 1024:
                raise ValueError('Oversized fixture frame')
            mask = read(4) if second & 128 else b'\0' * 4
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read(n)))
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
            method, params = frame['method'], frame.get('params') or {}
            record(method, params)
            try:
                check_params(method, params)
                maybe_stale(method, params)
            except Fault as fault:
                if fault.code == 4000:
                    with LOCK:
                        STATE['rejected'].append({'method': method, 'params': params, 'message': fault.message})
                client.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': fault.code, 'message': fault.message}})
                continue
            if method == 'prompt.submit':
                if params.get('confirm_truncate') and params.get('truncate_before_row_id') is not None:
                    try:
                        client.extra[frame['id']] = truncate_for_rewind(params)
                    except Fault as fault:
                        client.send({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': fault.code, 'message': fault.message}})
                        continue
                apply_pending(profile_of(params))
                threading.Thread(target=client.prompt, args=(frame,), daemon=True).start()
                continue
            if method in LONG:
                threading.Thread(target=answer, args=(frame,), daemon=True).start()
                continue
            answer(frame)
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        with b47.LOCK:
            b47.CLIENTS.discard(client)


voice.auth.websocket = menus_websocket


# MARK: - REST

def trip_row():
    last = TRIP_MESSAGES[-1] if TRIP_MESSAGES else None
    flags = ROW_FLAGS.get(TRIP, {})
    return {'id': TRIP, 'title': TITLES.get(TRIP), 'preview': (last or {}).get('content', ''), 'source': 'desktop', 'profile': 'default',
            'profile_name': 'default', 'started_at': 1791190800, 'last_active': (last or {}).get('timestamp', 1791190800),
            'message_count': len(TRIP_MESSAGES), 'model': MODEL_STATE['default']['model'], 'unread': flags.get('unread', False),
            'pinned': flags.get('pinned', False), 'archived': flags.get('archived', False), 'cwd': '/fixture'}


def branch_row(stored):
    branch = BRANCHES[stored]
    last = branch['messages'][-1] if branch['messages'] else None
    flags = ROW_FLAGS.get(stored, {})
    return {'id': stored, 'title': TITLES.get(stored), 'preview': (last or {}).get('content', ''), 'source': 'desktop',
            'profile': branch['profile'], 'profile_name': branch['profile'], 'started_at': 1791190900,
            'last_active': int(time.time()), 'message_count': len(branch['messages']), 'unread': flags.get('unread', False),
            'pinned': flags.get('pinned', False), 'parent_session_id': branch['parent']}


def listed_rows():
    rows = [] if TRIP in DELETED or ROW_FLAGS.get(TRIP, {}).get('archived') else [trip_row()]
    rows += [branch_row(s) for s in BRANCHES if s not in DELETED and not ROW_FLAGS.get(s, {}).get('archived')]
    return rows


FILES = {'/fixture': [{'name': 'notes', 'isDirectory': True}, {'name': 'README.md', 'isDirectory': False},
                      {'name': 'itinerary.txt', 'isDirectory': False}],
         '/fixture/notes': [{'name': 'day-trips-from-lisbon-sintra-and-cascais-2026-10-28.md', 'isDirectory': False}, {'name': 'packing.md', 'isDirectory': False}]}
TEXTS = {'/fixture/README.md': '# Trip planning\n\nA long weekend in Lisbon.\n', '/fixture/itinerary.txt': 'Day 1: Baixa\nDay 2: Sintra\n',
         '/fixture/notes/packing.md': '- walking shoes\n- rain jacket\n',
         '/fixture/notes/day-trips-from-lisbon-sintra-and-cascais-2026-10-28.md': '# Day trips\n\n**Sintra** for the palaces: the train from Rossio takes 40 minutes.\n\n'
                                        '- Pena Palace\n- Quinta da Regaleira\n\n**Cascais** for the coast, from Cais do Sodré. Pay with a `Navegante` card.\n\n'
                                        '```\nRossio → Sintra          40 min\nCais do Sodré → Cascais  33 min\n```\n'}
CHANGES = [{'path': 'itinerary.txt', 'added': 2, 'removed': 1, 'status': 'M', 'staged': False},
           {'path': 'notes/packing.md', 'added': 2, 'removed': 0, 'status': 'A', 'staged': False},
           {'path': 'node_modules/left-pad/index.js', 'added': 9, 'removed': 0, 'status': 'A', 'staged': False}]
DIFF = 'diff --git a/itinerary.txt b/itinerary.txt\n--- a/itinerary.txt\n+++ b/itinerary.txt\n@@ -1,2 +1,3 @@\n Day 1: Baixa\n-Day 2: Belém\n+Day 2: Sintra\n+Day 3: Cascais\n'



_prev_handler = b47.handler


def menus_handler(gateway):
    parent = _prev_handler(gateway)

    class Handler(parent):
        def _body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            try:
                return json.loads(raw or b'{}')
            except ValueError:
                return {}

        def do_GET(self):
            parsed = urlparse(self.path)
            path = parsed.path
            if path == '/__menus/state':
                with b47.LOCK:
                    bot_messages = copy.deepcopy(b47.MESSAGES.get('default', []))
                with LOCK:
                    return self.reply(200, {'calls': list(STATE['calls']), 'rest': list(STATE['rest']), 'modelState': MODEL_STATE,
                                        'titles': TITLES, 'optionsRefreshes': STATE['optionsRefreshes'], 'mode': MODE,
                                        'rejected': list(STATE['rejected']), 'rows': ROW_FLAGS, 'deleted': sorted(DELETED),
                                        'branches': {k: {'parent': v['parent'], 'count': len(v['messages'])} for k, v in BRANCHES.items()},
                                        'botMessages': bot_messages})
            if path == '/api/ws' and MODE.get('offline'):
                # "Airplane mode" for the UI checks (spec 1x §14.3 check 22): the socket can't come up.
                return self.reply(503, {'detail': 'offline (fixture)'})
            if path.startswith('/api/') and not path.startswith('/api/auth/'):
                with LOCK:
                    STATE['rest'].append({'method': 'GET', 'path': path, 'query': parsed.query})
            if path == '/api/profiles/sessions/sidebar':
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                rows = listed_rows()
                return self.reply(200, {'recents': {'sessions': rows, 'total': len(rows)}, 'cron': {'sessions': [], 'total': 0},
                                        'messaging': {'sessions': [], 'total': 0}})
            branch = next((b for b in BRANCHES if path.startswith(f'/api/sessions/{b}')), None)
            if branch and path.endswith('/messages'):
                params = parse_qs(parsed.query)
                offset = max(0, int(params.get('offset', ['0'])[0]))
                limit = min(500, max(1, int(params.get('limit', ['500'])[0])))
                order = params.get('order', ['latest'])[0]
                rows = list(BRANCHES[branch]['messages'])
                page = list(reversed(rows))[offset:offset + limit][::-1] if order == 'latest' else rows[offset:offset + limit]
                return self.reply(200, {'session_id': branch, 'profile': BRANCHES[branch]['profile'], 'messages': page,
                                        'pagination': {'limit': limit, 'offset': offset, 'order': order, 'returned': len(page),
                                                       'has_more': offset + len(page) < len(rows), 'next_offset': offset + len(page)}})
            if path in ('/api/fs/list', '/api/fs/read-text', '/api/git/review/list', '/api/git/review/diff'):
                if not self.session():
                    return self.reply(401, {'detail': 'unauthorized'})
                params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
                where = params.get('path', '')
                if path == '/api/fs/list':
                    if where not in FILES:
                        return self.reply(200, {'entries': [], 'error': f'No such folder: {where}'})
                    return self.reply(200, {'entries': [{**e, 'path': f"{where}/{e['name']}"} for e in FILES[where]]})
                if path == '/api/fs/read-text':
                    if where not in TEXTS:
                        return self.reply(404, {'detail': 'not found'})
                    return self.reply(200, {'path': where, 'text': TEXTS[where], 'binary': False, 'truncated': False})
                if path == '/api/git/review/list':
                    return self.reply(200, {'files': CHANGES, 'base': None})
                return self.reply(200, {'diff': DIFF if params.get('file') == 'itinerary.txt' else ''})
            if path.startswith(f'/api/sessions/{TRIP}') and path.endswith('/messages'):
                params = parse_qs(parsed.query)
                offset = max(0, int(params.get('offset', ['0'])[0]))
                limit = min(500, max(1, int(params.get('limit', ['500'])[0])))
                order = params.get('order', ['latest'])[0]
                with LOCK:
                    seed_reactions()
                    rows = copy.deepcopy(TRIP_MESSAGES)
                page = list(reversed(rows))[offset:offset + limit][::-1] if order == 'latest' else rows[offset:offset + limit]
                more = offset + len(page) < len(rows)
                return self.reply(200, {'session_id': TRIP, 'profile': 'default', 'messages': page,
                                        'pagination': {'limit': limit, 'offset': offset, 'order': order, 'returned': len(page),
                                                       'has_more': more, 'next_offset': offset + len(page)}})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__menus/mode':
                body = self._body()
                with LOCK:
                    MODE.update({k: v for k, v in body.items() if k in DEFAULT_MODE})
                if body.get('offline'):
                    with b47.LOCK:
                        clients = list(b47.CLIENTS)
                    for client in clients:
                        try:
                            client.connection.shutdown(2)
                        except OSError:
                            pass
                return self.reply(200, {'ok': True, 'mode': MODE})
            if path == '/__menus/model':
                body = self._body()
                with LOCK:
                    MODEL_STATE[body.get('profile') or 'default'].update(model=body['model'], provider=body['provider'], pending=None)
                return self.reply(200, {'ok': True, 'modelState': MODEL_STATE})
            if path == '/__menus/reset':
                self._body()
                with LOCK:
                    MODEL_STATE.clear()
                    MODEL_STATE.update(copy.deepcopy(DEFAULT_STATE))
                    MODE.clear()
                    MODE.update(DEFAULT_MODE)
                    STATE['calls'].clear()
                    STATE['rest'].clear()
                    STATE['optionsRefreshes'] = 0
                    STATE['rejected'].clear()
                    TITLES.clear()
                    TITLES[TRIP] = 'Trip planning'
                    reset_trip()
                    ROW_FLAGS.clear()
                    DELETED.clear()
                    BRANCHES.clear()
                with b47.LOCK:
                    for p in list(b47.MESSAGES):
                        b47.CANCEL[p].set()
                        b47.RUNNING[p] = False
                        b47.MESSAGES[p] = [{'role': 'assistant', 'content': 'Menus fixture chat. Ask me anything.', 'row_id': 1,
                                            'timestamp': int(time.time()) - 60}]
                    b47.PLANS.clear()
                return self.reply(200, {'ok': True})
            return super().do_POST()

        def do_PATCH(self):
            parsed = urlparse(self.path)
            body = self._body()
            with LOCK:
                STATE['rest'].append({'method': 'PATCH', 'path': parsed.path, 'query': parsed.query, 'body': body})
            if not self.session():
                return self.reply(401, {'detail': 'unauthorized'})
            prefix = '/api/sessions/'
            if not parsed.path.startswith(prefix):
                return self.reply(404, {'detail': 'not found'})
            stored = parsed.path[len(prefix):]
            known = {TRIP, *voice.SIDS.values(), *BRANCHES} - DELETED
            if stored not in known:
                return self.reply(404, {'detail': f'Session {stored} not found'})
            flags = {k: bool(body[k]) for k in ('pinned', 'unread', 'archived') if k in body}
            if flags:
                if MODE.get('writeFail'):
                    return self.reply(500, {'detail': 'session write failed (fixture)'})
                ROW_FLAGS.setdefault(stored, {}).update(flags)
                if 'title' not in body:
                    return self.reply(200, {'ok': True})
            if 'title' in body:
                title = str(body.get('title') or '').strip()
                if title == 'Taken':
                    return self.reply(400, {'detail': "Title 'Taken' is already in use"})
                if len(title) > 100:
                    return self.reply(400, {'detail': 'Title is too long (100 characters at most)'})
                if title:
                    TITLES[stored] = title
                else:
                    TITLES.pop(stored, None)
                return self.reply(200, {'ok': True, 'title': title or None})
            return self.reply(200, {'ok': True})

        def do_DELETE(self):
            parsed = urlparse(self.path)
            with LOCK:
                STATE['rest'].append({'method': 'DELETE', 'path': parsed.path, 'query': parsed.query})
            if not self.session():
                return self.reply(401, {'detail': 'unauthorized'})
            prefix = '/api/sessions/'
            stored = parsed.path[len(prefix):] if parsed.path.startswith(prefix) else ''
            if not parse_qs(parsed.query).get('profile'):
                return self.reply(400, {'detail': 'profile required'})
            if stored in DELETED:
                return self.reply(200, {'ok': True, 'already_absent': True})
            if stored not in {TRIP, *BRANCHES}:
                return self.reply(404, {'detail': f'Session {stored} not found'})
            DELETED.add(stored)
            return self.reply(200, {'ok': True})

    return Handler


b47.handler = menus_handler

if __name__ == '__main__':
    b47.main()
