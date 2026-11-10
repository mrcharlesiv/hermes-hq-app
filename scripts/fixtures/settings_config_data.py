"""Invented gateway settings for the settings fixture (scripts/fixtures/settings-gateway.py): a config record shaped like
Hermes' own (`hermes_cli/config.py` DEFAULT_CONFIG, the keys the Settings pages show), its schema as `GET /api/config/schema`
serves it (a few keys deliberately left out so the app infers them from the record), the environment keys `GET /api/env`
lists, the model catalog, auxiliary tasks, Mixture of Agents, provider sign-ins, the vault and billing.

Every key, token and password here is a fake made for this fixture ("fixture-…"); none of it works anywhere.
"""
import copy

FAKE_TOKEN = 'fixture-bearer-not-real-0000'


def defaults():
    return {
        'model': {'default': 'claude-opus-5.5', 'provider': 'anthropic', 'base_url': ''},
        'model_context_length': 0,
        'fallback_providers': [],
        'toolsets': ['hermes-cli'],
        'timezone': '',
        'display': {'personality': '', 'show_reasoning': False, 'resume_last_session': True},
        'agent': {'max_turns': 90, 'image_input_mode': 'auto', 'api_max_retries': 3, 'service_tier': 'normal',
                  'tool_use_enforcement': 'auto', 'reasoning_effort': 'medium'},
        'terminal': {'cwd': '.', 'backend': 'local', 'timeout': 180, 'persistent_shell': True, 'env_passthrough': [],
                     'docker_image': 'nikolaik/python-nodejs:python3.11-nodejs20', 'singularity_image': 'docker://python:3.11',
                     'modal_image': 'python:3.11', 'daytona_image': 'python:3.11'},
        'desktop': {'repo_scan_enabled': True, 'repo_scan_roots': [], 'repo_scan_exclude_paths': []},
        'file_read_max_chars': 100000,
        'tool_output': {'max_bytes': 50000, 'max_lines': 2000, 'max_line_length': 2000},
        'code_execution': {'mode': 'project'},
        'approvals': {'mode': 'manual', 'timeout': 60, 'mcp_reload_confirm': True},
        'command_allowlist': [],
        'security': {'redact_secrets': True, 'allow_private_urls': False},
        'browser': {'use_real_profile': False, 'allow_private_urls': False, 'auto_local_for_private_urls': True},
        'checkpoints': {'enabled': True, 'max_snapshots': 50},
        'memory': {'memory_enabled': True, 'user_profile_enabled': True, 'memory_char_limit': 2200, 'user_char_limit': 1375, 'provider': ''},
        'context': {'engine': 'compressor'},
        'compression': {'enabled': True, 'threshold': 0.5, 'codex_gpt55_autoraise': True, 'target_ratio': 0.2, 'protect_last_n': 20},
        'auxiliary': {'compression': {'timeout': 120}},
        'delegation': {'model': '', 'provider': '', 'max_iterations': 50, 'max_concurrent_children': 3,
                       'child_timeout_seconds': 600, 'reasoning_effort': ''},
        'sessions': {'auto_archive': False, 'auto_archive_days': 30},
        'mcp_servers': {},
    }


def current():
    """The gateway's record now: defaults plus what this invented user changed."""
    config = defaults()
    config['fallback_providers'] = [{'provider': 'openrouter', 'model': 'deepseek/deepseek-v3.2'}]
    config['toolsets'] = ['hermes-cli', 'web', 'memory']
    config['timezone'] = 'America/New_York'
    config['display']['personality'] = 'concise'
    config['agent']['max_turns'] = 120
    config['terminal']['cwd'] = '~/work'
    config['terminal']['env_passthrough'] = ['GITHUB_TOKEN']
    config['approvals']['mode'] = 'smart'
    config['command_allowlist'] = ['ls', 'git status']
    config['memory']['memory_char_limit'] = 3000
    config['mcp_servers'] = {
        'github': {'url': 'https://api.githubcopilot.com/mcp/', 'headers': {'Authorization': f'Bearer {FAKE_TOKEN}', 'Accept': 'application/json'}},
        'files': {'command': 'npx', 'args': ['files-mcp', '--api-key', 'fixture-files-key-0000']},
    }
    config['providers'] = {'openrouter': {'api_key': 'sk-fixture-openrouter-not-real-0000'}}
    return config


def schema():
    """`GET /api/config/schema`: compression.protect_last_n and checkpoints.max_snapshots are left out (inferred)."""
    fields = {
        'model_context_length': {'type': 'number', 'category': 'model', 'description': 'Context window override (tokens)'},
        'fallback_providers': {'type': 'list', 'category': 'model'},
        'toolsets': {'type': 'list', 'category': 'agent', 'description': 'Enabled toolsets'},
        'timezone': {'type': 'select', 'category': 'display', 'searchable': True, 'clearable': True,
                     'options': ['', 'America/Los_Angeles', 'America/New_York', 'Europe/London', 'Europe/Berlin', 'Asia/Tokyo']},
        'display.personality': {'type': 'string', 'category': 'display'},
        'display.show_reasoning': {'type': 'boolean', 'category': 'display'},
        'display.resume_last_session': {'type': 'boolean', 'category': 'display'},
        'agent.max_turns': {'type': 'number', 'category': 'agent'},
        'agent.image_input_mode': {'type': 'string', 'category': 'agent'},
        'agent.api_max_retries': {'type': 'number', 'category': 'agent', 'description': 'How many times to retry a failed model call'},
        'agent.service_tier': {'type': 'string', 'category': 'agent', 'description': 'Provider service tier (normal or fast)'},
        'agent.tool_use_enforcement': {'type': 'string', 'category': 'agent', 'description': 'Make models call tools instead of describing them'},
        'agent.reasoning_effort': {'type': 'string', 'category': 'agent'},
        'terminal.cwd': {'type': 'string', 'category': 'terminal'},
        'terminal.backend': {'type': 'string', 'category': 'terminal'},
        'terminal.timeout': {'type': 'number', 'category': 'terminal', 'description': 'Seconds before a command is stopped'},
        'terminal.persistent_shell': {'type': 'boolean', 'category': 'terminal'},
        'terminal.env_passthrough': {'type': 'list', 'category': 'terminal'},
        'terminal.docker_image': {'type': 'string', 'category': 'terminal'},
        'terminal.singularity_image': {'type': 'string', 'category': 'terminal'},
        'terminal.modal_image': {'type': 'string', 'category': 'terminal'},
        'terminal.daytona_image': {'type': 'string', 'category': 'terminal'},
        'desktop.repo_scan_enabled': {'type': 'boolean', 'category': 'desktop'},
        'desktop.repo_scan_roots': {'type': 'list', 'category': 'desktop'},
        'desktop.repo_scan_exclude_paths': {'type': 'list', 'category': 'desktop'},
        'file_read_max_chars': {'type': 'number', 'category': 'tools'},
        'tool_output.max_bytes': {'type': 'number', 'category': 'tools'},
        'tool_output.max_lines': {'type': 'number', 'category': 'tools'},
        'tool_output.max_line_length': {'type': 'number', 'category': 'tools'},
        'code_execution.mode': {'type': 'string', 'category': 'tools'},
        'approvals.mode': {'type': 'string', 'category': 'approvals'},
        'approvals.timeout': {'type': 'number', 'category': 'approvals'},
        'approvals.mcp_reload_confirm': {'type': 'boolean', 'category': 'approvals', 'description': 'Ask before reloading connectors'},
        'command_allowlist': {'type': 'list', 'category': 'approvals', 'description': 'Commands that never need approval'},
        'security.redact_secrets': {'type': 'boolean', 'category': 'security'},
        'security.allow_private_urls': {'type': 'boolean', 'category': 'security', 'description': 'Let web tools reach private network addresses'},
        'browser.use_real_profile': {'type': 'boolean', 'category': 'browser'},
        'browser.allow_private_urls': {'type': 'boolean', 'category': 'browser', 'description': 'Let the browser open private network addresses'},
        'browser.auto_local_for_private_urls': {'type': 'boolean', 'category': 'browser', 'description': 'Use the local browser for private addresses'},
        'checkpoints.enabled': {'type': 'boolean', 'category': 'checkpoints'},
        'memory.memory_enabled': {'type': 'boolean', 'category': 'memory'},
        'memory.user_profile_enabled': {'type': 'boolean', 'category': 'memory'},
        'memory.memory_char_limit': {'type': 'number', 'category': 'memory', 'description': 'Characters kept in MEMORY.md'},
        'memory.user_char_limit': {'type': 'number', 'category': 'memory', 'description': 'Characters kept in USER.md'},
        'memory.provider': {'type': 'select', 'category': 'memory', 'options': ['', 'honcho', 'mem0']},
        'context.engine': {'type': 'string', 'category': 'context'},
        'compression.enabled': {'type': 'boolean', 'category': 'compression'},
        'compression.threshold': {'type': 'number', 'category': 'compression', 'description': 'Share of the context window that starts compression'},
        'compression.codex_gpt55_autoraise': {'type': 'boolean', 'category': 'compression'},
        'compression.target_ratio': {'type': 'number', 'category': 'compression', 'description': 'How small compression makes older context'},
        'auxiliary.compression.timeout': {'type': 'number', 'category': 'auxiliary'},
        'delegation.model': {'type': 'string', 'category': 'delegation', 'description': 'Model for subagents (blank: the main model)'},
        'delegation.provider': {'type': 'string', 'category': 'delegation', 'description': 'Provider for subagents (blank: the main provider)'},
        'delegation.max_iterations': {'type': 'number', 'category': 'delegation'},
        'delegation.max_concurrent_children': {'type': 'number', 'category': 'delegation'},
        'delegation.child_timeout_seconds': {'type': 'number', 'category': 'delegation'},
        'delegation.reasoning_effort': {'type': 'string', 'category': 'delegation'},
        'sessions.auto_archive': {'type': 'boolean', 'category': 'sessions'},
        'sessions.auto_archive_days': {'type': 'number', 'category': 'sessions'},
    }
    return {'fields': fields, 'category_order': ['model', 'agent', 'display', 'terminal', 'tools', 'approvals', 'security', 'memory']}


def env():
    """`GET /api/env` rows (values fake; the gateway answers them redacted)."""
    def row(value, description, category, password=True, url=None, provider=None, label=None, tools=None, channel=False):
        return {'value': value, 'description': description, 'category': category, 'is_password': password, 'advanced': False,
                'url': url, 'provider': provider, 'provider_label': label, 'tools': tools or [], 'channel_managed': channel}
    return {
        'ANTHROPIC_API_KEY': row('sk-ant-fixture-not-real-0000', 'Anthropic API key', 'provider', url='https://console.anthropic.com/settings/keys'),
        'OPENROUTER_API_KEY': row('sk-or-fixture-not-real-0000', 'OpenRouter API key', 'provider', url='https://openrouter.ai/keys'),
        'OPENAI_API_KEY': row(None, 'OpenAI API key', 'provider', url='https://platform.openai.com/api-keys'),
        'FIRECRAWL_API_KEY': row('fc-fixture-not-real-0000', 'Firecrawl key for web extraction', 'tool', url='https://firecrawl.dev', tools=['web_extract']),
        'BRV_API_KEY': row(None, 'ByteRover memory key', 'tool', tools=['memory']),
        'FAL_KEY': row(None, 'fal.ai key for image generation', 'tool', tools=['image_generate']),
        'PORCUPINE_ACCESS_KEY': row(None, 'Picovoice key for the wake word', 'tool'),
        'TELEGRAM_ALLOW_ALL_USERS': row(None, 'Let anyone message the bot (true/false, default: false)', 'messaging', password=False),
        'DISCORD_REQUIRE_MENTION': row('true', 'Only answer when mentioned (true/false, default: true)', 'messaging', password=False),
        'GATEWAY_PROXY_URL': row(None, 'Proxy for outgoing gateway requests', 'messaging', password=False),
        'API_SERVER_ENABLED': row(None, 'Run the OpenAI-compatible API server (default: false)', 'setting', password=False),
        'API_SERVER_PORT': row('8642', 'Port for the API server', 'setting', password=False),
        'TELEGRAM_BOT_TOKEN': row('fixture-telegram-not-real', 'Telegram bot token', 'messaging', channel=True),
    }


def redacted(row):
    value = row.get('value')
    if value is None:
        return None
    if not row.get('is_password'):
        return '«redacted:***»' if value in ('true', 'false') else '«redacted:' + value[:2] + '…»'
    return '«redacted:' + value[:4] + '...' + value[-4:] + '»'


def env_rows(state):
    out = {}
    for key, row in state.items():
        out[key] = {k: v for k, v in row.items() if k != 'value'}
        out[key]['is_set'] = row.get('value') is not None
        out[key]['redacted_value'] = redacted(row)
    return out


def model_options(env_state):
    def ready(key):
        return env_state.get(key, {}).get('value') is not None
    return {'providers': [
        {'slug': 'anthropic', 'name': 'Anthropic', 'models': ['claude-opus-5.5', 'claude-sonnet-5', 'claude-haiku-5', 'claude-opus-ultra'],
         'authenticated': ready('ANTHROPIC_API_KEY'), 'auth_type': 'api_key', 'key_env': 'ANTHROPIC_API_KEY'},
        {'slug': 'openrouter', 'name': 'OpenRouter', 'models': ['deepseek/deepseek-v3.2', 'qwen/qwen3-coder', 'x-ai/grok-5'],
         'authenticated': ready('OPENROUTER_API_KEY'), 'auth_type': 'api_key', 'key_env': 'OPENROUTER_API_KEY'},
        {'slug': 'openai', 'name': 'OpenAI', 'models': ['gpt-5.5', 'gpt-5.5-mini'] if ready('OPENAI_API_KEY') else [],
         'authenticated': ready('OPENAI_API_KEY'), 'auth_type': 'api_key', 'key_env': 'OPENAI_API_KEY'},
        {'slug': 'moa', 'name': 'Mixture of Agents', 'models': ['moa'], 'authenticated': True},
    ]}


AUX_TASKS = ['vision', 'compression', 'skills_hub', 'approval', 'mcp', 'title_generation', 'review', 'triage_specifier',
             'kanban_decomposer', 'profile_describer', 'curator']


def auxiliary():
    tasks = {name: {'task': name, 'provider': 'auto', 'model': '', 'base_url': ''} for name in AUX_TASKS}
    tasks['title_generation'] = {'task': 'title_generation', 'provider': 'openrouter', 'model': 'qwen/qwen3-coder', 'base_url': ''}
    return tasks


def moa():
    preset = {'aggregator': {'provider': 'anthropic', 'model': 'claude-opus-5.5'}, 'aggregator_temperature': 0.4,
              'degraded_reference_policy': 'loud', 'enabled': False,
              'reference_models': [{'provider': 'openrouter', 'model': 'deepseek/deepseek-v3.2'},
                                   {'provider': 'anthropic', 'model': 'claude-sonnet-5'}],
              'reference_temperature': 0.7, 'reference_timeout': None}
    fast = copy.deepcopy(preset)
    fast['reference_models'] = [{'provider': 'anthropic', 'model': 'claude-haiku-5'}]
    record = {'default_preset': 'balanced', 'active_preset': 'balanced', 'presets': {'balanced': preset, 'fast': fast}}
    record.update(copy.deepcopy(preset))
    return record


def oauth():
    return {'providers': [
        {'id': 'nous', 'name': 'Nous Portal', 'logged_in': True, 'account': 'fixture@example.invalid', 'disconnectable': True},
        {'id': 'openai-codex', 'name': 'ChatGPT (Codex)', 'logged_in': False, 'disconnectable': True},
        # [provider-add] A sign-in another app owns: Hermes can't sign it out (no Sign Out offered).
        {'id': 'claude-code', 'name': 'Claude Code', 'logged_in': True, 'disconnectable': False},
    ]}


def vault():
    return {
        'items': [
            {'id': 'v1', 'kind': 'login', 'label': 'Fixture Bank', 'origin': 'https://bank.example.invalid', 'identifier': 'ivy@example.invalid',
             'identifier_type': 'email', 'created_at': '2026-10-01T12:00:00Z', 'backend': 'local'},
            {'id': 'v2', 'kind': 'payment', 'label': 'Travel Card', 'origin': 'https://shop.example.invalid', 'created_at': '2026-10-02T12:00:00Z',
             'backend': 'local'},
        ],
        'sources': [
            {'name': 'local', 'display_name': 'Hermes Vault', 'enabled': True, 'needs_unlock': False, 'unlocked': True, 'installed': True},
            {'name': 'bitwarden', 'display_name': 'Bitwarden', 'enabled': False, 'needs_unlock': True, 'unlocked': False, 'installed': True},
        ],
        'next': 3,
    }


VAULT_MASTER = 'fixture-master-password'


def billing():
    return {'ok': True, 'logged_in': True, 'org_name': 'Fixture Labs', 'balance_display': '$1000', 'balance_usd': '1000',
            'card': {'brand': 'visa', 'last4': '4242', 'masked': '····4242', 'display': 'Visa ····4242'},
            'auto_reload': {'enabled': True, 'reload_to_display': '$50', 'threshold_display': '$5', 'card': {'kind': 'canonical'}},
            'can_charge': True, 'charge_presets': [], 'charge_presets_display': [], 'cli_billing_enabled': True, 'is_admin': True,
            'max_usd': None, 'min_usd': None, 'monthly_cap': None, 'portal_url': 'https://portal.nousresearch.com/billing', 'role': 'owner',
            'usage': {'available': True, 'plan_name': 'Plus', 'renews_display': 'Nov 1', 'total_spendable_display': '$1012.5',
                      'plan_bar': {'kind': 'plan', 'remaining_display': '$12.5', 'total_display': '$20', 'spent_display': '$7.5',
                                   'pct_used': 37.5, 'fill_fraction': 0.375}, 'topup_bar': None}}


def deep_merge(base, patch):
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = copy.deepcopy(value)
    return base
