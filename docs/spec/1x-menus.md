# 1x — Menus: Model menu, favourite models, commands sheet, chat ⋯, message hold menus

Status: implementation spec for the "menus" stream (round after milestone 1). Written 2026-10-10 from the web app at
release-build238 and the Hermes gateway source; nothing here was guessed from memory of the UI. Where the web app and
this spec differ on purpose, the line is marked **⚑ DECISION** with the reason.

Scope:

1. **Model menu** in the chat's ⋯ (model for the next reply, Reasoning, Fast), the **More Models…** sheet,
   **favourite models**, recents, per-model presets, and switching the session's model on the wire.
2. **Commands sheet** opened by the ☰ button left of the composer field, and the **slash-command dispatcher** that a
   picked or typed `/command` runs through.
3. **Chat ⋯ completeness** vs the web phone: Share (transcript), Info, Rename…, the Model submenu; every other web row
   gets a fixed slot so later streams drop in without reshuffling.
4. **Message hold menus** (Copy, Share, Select Text) on your bubbles and the bot's replies.

Out of scope here (other specs/streams): approvals, attachments/+, voice and Read Aloud, Bot Info and its New Chat,
pins/unread/archive/delete writes, Watch Browser, Find in chat, regenerate/edit/rewind, rooms, iPad.

---

## 0. Sources, notation, ground rules

| Prefix | Path |
|---|---|
| `S/` | `/Users/me/Projects/hermes-hq-native-ref238/src/` (Hermes HQ phone code, release-build238) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref238/build/` (build-time gates that rewrite vendored code) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref238/vendor/hermes/apps/desktop/src/` (vendored Hermes renderer, `02e41181`) |
| `SH/` | `/Users/me/Projects/hermes-hq-native-ref238/vendor/hermes/apps/shared/src/` |
| `H/` | `/Users/me/.hermes/hermes-agent/` (gateway source, HEAD `d94b70f675`, READ ONLY) |
| `FX/` | `/Users/me/Projects/hermes-hq-native-ref238/scripts/` (stand-in gateways) |
| `NAT/` | `/Users/me/Projects/hermes-hq-native/` |
| `MEM/` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` |

Ground rules every call in this spec obeys (from earlier specs, restated because each one bites here):

- **Params are strict.** Every JSON-RPC params model is `extra="forbid"`: one unknown key answers `4000 "invalid params
  for <method>: <key>: Extra inputs are not permitted — the client and the Hermes backend are out of sync…"`
  (`H/tui_gateway/contracts/base.py:14-17,32-36`; `H/tui_gateway/rpc_dispatch.py:27-31`;
  `H/tui_gateway/contracts/registry.py:94-110`). Each method below lists its **complete** allowed key set.
- **Always name `profile`** on session-scoped calls and `?profile=` on REST (spec 04 §1.4, native decision), using the
  chat's `LiveChatSession.profileParam` (omitted only for the "custom" launch profile, spec 04 §1.4 rule 4).
- **Runtime ids** address live sessions (`session_id` = the 8-hex runtime id from `session.resume`); stored ids address
  REST. A stale runtime id answers `4001 "session not found"` (`H/tui_gateway/server.py:1229-1245`). **Native rule for
  every RPC in this spec:** on `4001`, run `resumeNow()` once and resend once (pre-admission refusal, nothing ran).
- **`4064 Profile '<name>' does not exist.`** → `onRosterStale()`, no retry (spec 04 §1.4 rule 5).
- Native Liquid Glass only; system menus, sheets and alerts. Wrapping rows get 12–14 pt vertical padding
  (`MEM/row-padding-feedback.md`).

---

## 1. What the owner approved (and rejected) — read before designing

| Owner said / chose | When | Source | What it means here |
|---|---|---|---|
| Bar stays **Back · head + name · ⋯**; "the owner asked for the model out of the bar: the title is now head + name only… model/reasoning/Fast are a "Model" submenu in the chat's ⋯ menu" | 2026-10-02 (public 68) | `MEM/chat-status-line.md:13,23` | The model lives in ⋯ › Model. No model chip, pill or subtitle in the bar. "Don't re-propose layout overhauls of the bar." **Superseded for the composer (owner 2026-10-31/11-01):** the composer's two-row bar carries the model bubble (`ModelChip`, only the name, "in a bubble", never an ellipsis), which opens the model panel. |
| Favourite models like the new Hermes desktop: "⋯ → Model quick list (favorites ≤5 lead, then 2 recents; shows favorites from keys before the catalog is cached) and More Models… sheet (star per row, Favorites section, opens at top when favorites exist, rows stay in provider list too, scroll held on star…)" | 2026-10-03 (internal 115) | `MEM/favorite-models.md:11,17` | §4.6, §6 exactly. Stars are device-local, `provider::model` keys, no sync ("none exists upstream either"). |
| Commands button "like Telegram's hamburger menu" left of +; build 109's "just add a /" version was "buggy, not good yet" (keyboard jumps, stray /). "Owner picked Telegram behavior: a pick sends." Rebuilt as a sheet: "search, sections + Skills… the field is untouched… commands with argument_mode null → send; /model → [the Models menu]; text/options/mixed/picker/skills → "/cmd " inserted ahead of the draft with the keyboard up." | 2026-10-03 (internal 112) | `MEM/commands-button.md:11,24` | §7. Never type a "/" into the field to open anything; the field and keyboard are untouched until a pick. |
| Taptic audit: "Deliberately left silent: Send/retry, password prompts, commands/plus-menu picks" | 2026-10-07 (internal 211) | `MEM/taptic-feedback-gaps.md` | No haptic on a command pick. Copies play success. |
| "It isn't Liquid Glass" (CSS imitation) — never ship imitation glass; sweep sibling surfaces | 2026-10-02 | `MEM/liquid-glass.md` | ☰ is a system glass circle in the composer's glass container; sheets/menus are system ones. |
| Wrapping rows need 12–14 pt top/bottom padding, trailing action separated | 2026-09-29 | `MEM/row-padding-feedback.md` | Command rows (two lines), model rows with a star. |
| Telegram is the benchmark for feel; Telegram chat **colours** abandoned, shapes kept | 2026-10-06 | `MEM/telegram-look-hold.md` | No new colours; menus are system grey. |

Things the web phone ships that **this round deliberately does not build** are listed with reasons in §11.

---

## 2. The chat's model state

### 2.1 Where it comes from

`SessionLiveInfo` (`H/tui_gateway/contracts/common.py:62-100`) is the `info` field of the `session.resume` /
`session.activate` / `session.create` results and the payload of every `session.info` event. Fields this spec reads:

| Field | Type | Meaning |
|---|---|---|
| `model` | string | The model the **next** reply uses. While a mid-turn switch is parked it already shows the pick (`H/tui_gateway/server.py:2380-2391`: `model = pending_model or …`). |
| `provider` | string | Its provider slug (pending pick's provider while parked, `server.py:2401`). |
| `reasoning_effort` | string | `""` = provider default, `"none"` = thinking off, else a level (`server.py:2365-2369`). |
| `fast` | bool | Fast service tier on (`server.py:2404`). |
| `yolo` | bool | Session approval bypass on (used by `/yolo`, §8.2). |
| `running` | bool | Already used by spec 04. |

Native today ignores `info` entirely: `LiveChatSession.bindRuntime` reads only `session_id`/`session_key`
(`NAT/HermesKit/Chat/LiveChatSession.swift:544-550`), and `onSessionInfo` returns early unless `running` is present and
reads nothing else (`NAT/HermesKit/Chat/LiveChatSession+Events.swift:461-462`). Add:

```swift
/// The open chat's model, reasoning and Fast as the gateway last reported them, with this phone's optimistic picks
/// applied (spec 1x §2). "" = unknown.
nonisolated struct ChatModelState: Hashable, Sendable {
    var model = ""               // model id ("claude-sonnet-5")
    var provider = ""            // provider slug ("anthropic")
    var reasoningEffort = ""     // "" provider default · "none" off · level
    var fast = false
    var yolo = false
}
```

Rules:

1. `bindRuntime(result)` copies `result["info"]` into `modelState` (each field only when present).
2. `onSessionInfo(payload)` copies the same fields **before** its `running` guard.
3. **While a model switch this phone sent is in flight for this runtime id (§5), ignore `model` and `provider` from
   `session.info`** (other fields still apply). An end-of-turn `session.info` carrying the old model otherwise blinks the
   menu back before the switch answers. **⚑ DECISION** (the web has the same race and no guard).
4. Before the first resume answers, `model` falls back to the roster's `profile.model`
   (`AppModel.chat(for:)` already sets `modelName` from it, `NAT/App/AppModel.swift:79,92`); `provider` stays `""`.
5. `modelName` (used by "Waiting for <model>", spec 06) becomes `displayModelName(modelState.model)` once known.

### 2.2 Model names (port exactly; pure functions, unit-tested)

From `V/lib/model-status-label.ts:6-234` and `S/ui-chat/title-menu.ts:17-25`:

- `modelBaseId(id)`: text after the last `/`.
- `splitTrailingTags`: repeatedly strip one variant tag `-fast|-flash|-thinking|-preview|-latest` → `Fast|Flash|
  Thinking|Preview|Latest` and one GGUF quant `-(UD-)?(Q\d…|IQ\d…|F16|BF16)$` (quant label = first `_` part,
  upper-cased; then drop a trailing `-Instruct|-Chat(-\d{4})?`) (`:144-177`).
- `modelDisplayParts`: tags = [variant, quant]; a trailing `[1m]`/`[200k]` becomes a tag `1M`; drop a trailing
  `-\d{8}` date pin; `prettifyBase` (`:112-137`): `claude-` → strip, digit-hyphen-digit → dot, hyphens → spaces,
  Title Case; `gpt-` → `GPT-`; `gemini-` → `Gemini ` + Title Case; else Title Case; then vendor casing
  (DeepSeek, GLM, MiniMax, OpenAI, ERNIE, MiMo, BGE, VL, IT, FP8, AI) and parameter counts (`8b`→`8B`, `a3b`→`A3B`).
  Empty → `"No model"`.
- `displayModelName(id)` = name + (" " + tags) (`:205-209`).
- `formatModelPillLabel(id, fastMode)` = name + (" · " + (fastMode ? "Fast" : variant)) — used only in the switch
  toasts (`:228-234`).
- `providerDisplayName(slug)`: `anthropic`→"Anthropic Account", `claude-code`→"Anthropic OAuth: Required Extra Usage
  Credits to Use Subscription", `minimax-oauth`→"MiniMax", `nous`→"Nous Portal", `openai-codex`→"ChatGPT or Codex
  Subscription", `qwen-oauth`→"Qwen Code", `xai`→"xAI", `xai-oauth`→"xAI Grok", else the slug (`:38-53`).
- `plainProviderName(name)`: remove `(…)`/`[…]` groups and the words `SDK`/`DirectSDK`, collapse spaces; empty → the
  whole name (`S/ui-chat/title-menu.ts:17-20`).
- `effortLabel(level)`: none→Off, minimal→Minimal, low→Low, medium→Medium, high→High, xhigh→Extra High, max→Max,
  ultra→Ultra, else `_`/`-`→space and Title Case (`title-menu.ts:22-25`).

Test vectors (computed by running the shipped TypeScript, 2026-10-10):

| id | `displayModelName` | `formatModelPillLabel` |
|---|---|---|
| `claude-opus-4-5-20251101` | Opus 4.5 | Opus 4.5 |
| `claude-sonnet-5[1m]` | Sonnet 5 1M | Sonnet 5 |
| `gpt-5.5-fast` | GPT-5.5 Fast | GPT-5.5 · Fast |
| `gemini-2.5-pro` | Gemini 2.5 Pro | Gemini 2.5 Pro |
| `glm-5.2` | GLM 5.2 | GLM 5.2 |
| `deepseek-v4.1-flash` | DeepSeek V4.1 Flash | DeepSeek V4.1 · Flash |
| `anthropic/claude-opus-4.5` | Opus 4.5 | Opus 4.5 |
| `qwen2.5-coder:14b` | Qwen2.5 Coder:14B | Qwen2.5 Coder:14B |
| `Qwen3-30B-A3B-Instruct-2507-UD-Q4_K_XL` | Qwen3 30B A3B Q4 | Qwen3 30B A3B |
| `moonshotai/kimi-k2-thinking` | Kimi K2 Thinking | Kimi K2 · Thinking |
| `hermes-4` | Hermes 4 | Hermes 4 |
| `""` | No model | No model |

`plainProviderName`: "Claude Subscription DirectSDK (Experimental)" → "Claude Subscription"; "Custom [local]" →
"Custom"; "(x)" → "(x)". `effortLabel("extra_deep")` → "Extra Deep".

**Native additions (2026-10-31, the composer's model panel: "guarantee this works no matter the model and provider
someone uses").** None of the vectors above carries one, so they all still read as listed.
- `modelDisplayParts` first unwraps a cloud provider's wrapping round the model's own id: a fine-tune
  `ft:<base>:…` → the base + tag "Fine-tuned"; an OpenRouter route `:free|:beta|:extended|:nitro|:floor|:online|
  :thinking|:exacto` → a tag; Bedrock's region and maker prefix (`us.anthropic.`, `amazon.`, …) and `-v1:0` version;
  Vertex's `@20240620`/`@001`/`@latest` pin; a Hugging Face pull's `:Q4_K_M` quant (read as `-Q4_K_M`). After the
  web's rules it also drops a dashed date (`-2024-08-06`) and a trailing `-GGUF`. So
  `us.anthropic.claude-3-7-sonnet-20250219-v1:0` → "3.7 Sonnet", `gpt-4o-2024-08-06` → "GPT-4o",
  `meta-llama/llama-3.3-70b-instruct:free` → "Llama 3.3 70B Instruct Free".
- `readableProviderName(slug:catalogName:)`: the catalog's name without its notes, else Hermes' own name for the slug
  (`CANONICAL_PROVIDERS`), else the slug in words. `providerDisplayName` itself is unchanged.
- `shortProviderName`: the first clause, without a trailing "Subscription"/"Account"; an address → its host.

### 2.3 Device-local stores (same keys and formats as the web app, per gateway account)

The web app snapshots its **whole** localStorage per gateway account (identity = origin+path+username;
`S/connection-storage.ts:30-42`; spec 02 §11), so all three stores below are **per account** on the phone. Native:
`UserDefaults.standard` under `"<web key>|<GatewayAccount.id>"`, JSON-encoded exactly as below, read/written on the
main actor, forgotten on Sign Out together with the account's other caches.

| Web key | Format | Rules | Source |
|---|---|---|---|
| `hermes.desktop.favorite-models` | `["anthropic::claude-sonnet-5", …]` (`provider::model`) in starred order | toggle: present → remove; absent → append at the end; dedupe; empty list → remove the key | `S/favorite-models.ts:10-36` |
| `dispatch.chat.recentModels` | `[{id,name,provider,providerName?}, …]`, newest first, **max 3** | `remember(m)`: `[m] + old.filter(not same id+provider)`, cut to 3; invalid rows dropped on read | `S/ui-chat/title-menu.ts:59-76` |
| `hermes.desktop.model-presets` | `{"provider::model": {"effort"?: "low", "fast"?: true}}` | merge-patch per key | `V/store/model-presets.ts:9-53` |

Stars never touch the gateway: "it only reorders the menu, never the gateway's catalog" (`S/favorite-models.ts:3-6`).
A star the current catalog lacks shows nothing and stays stored (`S/favorite-model-groups.ts:13-16`).

---

## 3. Wire calls (exact)

Timeouts below are native choices (the web uses its client default); `slash.exec`, `command.dispatch`, `model.options`
run on the gateway's worker pool (`H/tui_gateway/server.py:181-201` `_LONG_HANDLERS`), `config.set`,
`commands.catalog`, `session.title` run inline on the socket's reader.

### 3.1 `model.options` — the catalog

- Contract `ModelOptionsParams(ProfileParams)`: **`profile, session_id, explicit_only, include_unconfigured,
  refresh`** (`H/tui_gateway/contracts/config_free_tier_control.py:449-454`). Handler `H/tui_gateway/methods_complete.py:357-369`
  (`_profile_scoped`, errors `5033`).
- Phone sends (`V/lib/model-options.ts:146-181`, called from `S/ui-chat/title-menu.ts:143-148` with an owner-routed
  `request`, so the REST fallback at `model-options.ts:195-210` never runs on the phone): `session_id` = runtime id
  (omitted when none), `explicit_only: true`, `refresh: true` only for Refresh/Try Again, `profile`.

```json
{"jsonrpc":"2.0","id":31,"method":"model.options","params":{"session_id":"5cc537d1","explicit_only":true,"profile":"default"}}
```

Result `ModelOptionsResult {providers, model, provider}` (`config_free_tier_control.py:536-569`; shape per contract,
values from the menus fixture §12):

```json
{"model":"claude-sonnet-5","provider":"anthropic","providers":[
  {"slug":"anthropic","name":"Anthropic","models":["claude-sonnet-5","claude-opus-4-5-20251101","claude-haiku-4-5"],
   "is_current":true,"authenticated":true,
   "capabilities":{"claude-sonnet-5":{"fast":true,"reasoning":true,"can_disable_reasoning":true},
                   "claude-haiku-4-5":{"fast":false,"reasoning":false}}},
  {"slug":"openai-codex","name":"ChatGPT or Codex Subscription (Experimental)","aliases":["codex"],
   "models":["gpt-5.5","gpt-5.5-fast","gpt-5.5-mini"],
   "capabilities":{"gpt-5.5":{"fast":false,"reasoning":true,"can_disable_reasoning":false}}}]}
```

Decode only `providers[].{slug,name,models,aliases,capabilities{<id>:{fast,reasoning,can_disable_reasoning}}}`,
`model`, `provider`; ignore everything else (pricing, usage, limits…). A provider row **matches** a slug when
`slug == x || name == x || aliases ∋ x` (`V/lib/model-options.ts:10-20`).

Cache (`title-menu.ts:123-150`; `modelOptionsQueryKey`, `model-options.ts:120-129`): key `(account, profile, runtime id
or "global")`, fresh for **30 s**; Refresh/Try Again pass `refresh:true` and bypass the cache; a successful live
switch (not deferred) marks the key stale (`title-menu.ts:234`). Offline with a cached answer → use it; offline
without → error `"Offline"` (`title-menu.ts:138-142`). Native keeps it in memory only.

**⚑ DECISION (warm-up):** the web never fetches the catalog for the ⋯ menu (only More Models… does), so before the
first sheet open a fresh launch shows no recents and resolves favourites from their keys alone
(`title-menu.ts:266-272`). Native starts one background `model.options` (no UI, errors swallowed) the first time a
chat's ⋯ opens in an app run when its key isn't cached; the next ⋯ open shows the full quick list.

### 3.2 `config.set key=model` — switch the session's model

- Contract `ConfigSetParams(ProfileParams)`: **`profile, key, value, session_id, scope, confirm_expensive_model`**
  (`config_free_tier_control.py:75-84`). Handler `H/tui_gateway/methods_config_set.py:111-171`.
- `value` = `"<model id> --provider <provider slug>"`, plus `" --session"` when the slug lower-cases to `moa`
  (`S/ui-chat/title-menu.ts:217-218`). Never send `scope` for a model switch.

```json
{"jsonrpc":"2.0","id":32,"method":"config.set","params":{"key":"model","session_id":"5cc537d1","value":"claude-opus-4-5-20251101 --provider anthropic","profile":"default"}}
```

Answers (`_kv` = `{key, value, …extras}`, `methods_config_set.py:54-71`; `H/tui_gateway/model_switch.py:308-381`):

| Case | Result / error | Source |
|---|---|---|
| Switched live | `{"key":"model","value":"claude-opus-4-5-20251101","warning":"","confirm_required":false,"confirm_message":"","scope":"session"}` then a `session.info` event (if the agent is built) and a stored `user` row `display_kind:"model_switch"` (`[System: The active model for this chat has changed to <id> via provider <p>. …]`) that history folds into the centred "model changed" notice (spec 03 §6.3; `NAT/HermesKit/Chat/Hydration.swift:259-280`) | `model_switch.py:280-305,376-381`; `server.py:1807,1824-1845` |
| Parked (a turn is running, or compute host) | `{"key":"model","value":"<id>","warning":"","confirm_required":false,"confirm_message":"","scope":"session","deferred":true}`; applied at the next turn start; `session.info` already reports the pick | `methods_config_set.py:73-95,128-129` |
| Needs confirmation (expensive model, big cached context) | `{"key":"model","value":"<id>","warning":"<msg>","confirm_required":true,"confirm_message":"<msg>","scope":"session"}` (on the parked path also `"deferred":false`). Nothing changed. Resend with `"confirm_expensive_model":true`. | `model_switch.py:261-277`; `methods_config_set.py:85-90` |
| Pre-deferral gateways only | error `4009` whose message contains "session busy" and "switching models" — treat as **parked** | `V/lib/gateway-rpc.ts:48-54` |
| Failed | `5001 "<reason>"`, e.g. "Model switch to X failed (…); staying on Y." — nothing changed | `methods_config_set.py:98-105`; `model_switch.py:287-296` |
| Agent build failed / still starting | `5032 "agent initialization failed"` / the still-starting text | `methods_config_set.py:130-139` |
| No value | `4002 "model value required"` | `:113-114` |
| Stale runtime id | `4001 "session not found"` (never the global write: `_SESSION_SCOPED_KEYS`) | `:495-506` |

Timeout **45 s** (an inline handler may wait up to 30 s for a failed agent build, `methods_config_set.py:134`).
Ignore `warning` when `confirm_required` is false (the web shows nothing for it).

### 3.3 `config.set` for reasoning, fast and yolo

Same params contract; always with `session_id` (without one these keys write config.yaml / the process env for every
chat: `methods_config_set.py:275-305,317-345,495-506`).

| Key | `value` | Result `value` | Errors | Phone source |
|---|---|---|---|---|
| `reasoning` | a level (`none`, `minimal`…`ultra`) or a display word (`show`/`hide`/`full`/`clamp`) | the word sent | `4002 "unknown reasoning value: …"` | `title-menu.ts:184`; `V/lib/reasoning-slash.ts:20-41` |
| `fast` | `"fast"` / `"normal"` | `"fast"`/`"normal"` | `4002 "fast mode is not available for this model"` / `"…without a selected model"` | `title-menu.ts:185`; `methods_config_set.py:174-217` |
| `yolo` | `"1"` / `"0"` | `"1"`/`"0"` (`scope:"session"`) | — | `V/lib/yolo-session.ts:11-27`; `methods_config_set.py:275-305` |

`/reasoning … --global` / `--session` add `"scope":"global"|"session"` (`reasoning-slash.ts:9-41`); the Reasoning menu
never sends `scope`. Each emits `session.info` when the agent exists. Timeout 15 s.

### 3.4 `config.get key=reasoning` (bare `/reasoning` only)

`ConfigGetParams`: **`profile, key, cwd, session_id`** (`config_free_tier_control.py:24-31`). Result `{value, display}`
→ output `reasoning: <value or medium> · display <display or hide>` (`V/app/session/hooks/use-prompt-actions/slash.ts:848-856`).

### 3.5 `commands.catalog`

- Contract `CommandsCatalogParams`: **`session_id, profile`** (`H/tui_gateway/contracts/tools_commands.py:190-192`);
  handler `H/tui_gateway/methods_tools.py:503-531` (`5020` on failure). Phone: `{session_id}` when the chat has a
  runtime id, else `{profile}` (`S/ui-chat/commands.ts:58-63`). **Native sends both** when it has both (§0 rule).
- Result `CommandsCatalogResult` (`tools_commands.py:217-226`): `pairs` (every `[key, desc]`, skills included, aliases
  excluded), `categories` (`[{name, pairs}]` in the registry's first-appearance order: Session, Configuration, Info, Tools & Skills, Exit, then
  "TUI", "User commands", "Plugin commands"; `methods_tools.py:442-482`), `commands` (`{"/name": {argument_mode, desktop, desktop_subcommands?}}`
  for every registry name **and alias**), `canon` (lower-case key/alias → canonical), `skills`
  (`{"/skill": {usage, origin}}`), `skill_count`, `warning`, `sub`.
- `argument_mode` is the registry's explicit value or is inferred: subcommands → `options` (or `mixed` when the hint
  holds prose markers `<prompt>`, `[text`, `instructions`, `[interval]`, `<what`); any `args_hint` → `text`; else
  `null` (`H/hermes_cli/commands.py:352-371`). `desktop`: `null` offered, `"hidden"`, or a reason `terminal |
  messaging | settings | advanced | composer-voice`.
- Descriptions carry the usage hint: `"<desc> (usage: /<name> <args_hint>)"` (`H/locales/en.yaml:1559`).
- Cache **1 hour** per key (`session:<runtime>` / `profile:<p>`); Try Again bypasses it (`V/lib/slash-completion-cache.ts:16-31`).
  Timeout 30 s.

### 3.6 `slash.exec` and `command.dispatch`

| Method | Allowed params | Notes |
|---|---|---|
| `slash.exec` | **`session_id, command, profile`** (`tools_commands.py:283-286`) | `command` = the whole typed line **without the leading `/`** (`slash.ts:386-389`). Handler `methods_tools.py:1113-1191`: live shortcuts, pending-input built-ins and bundles are rerouted to `command.dispatch` and answer its directive; a recognised skill answers `4018 "skill command: use command.dispatch for /<name>"`; worker failures `5030`. Timeout 60 s (first use spawns a slash worker). |
| `command.dispatch` | **`name, arg, session_id, profile`** (`tools_commands.py:258-262`) | `name` without `/`, lower-cased; `arg` = the rest, trimmed. Timeout 60 s. |

Results (`SH/slash.ts:85-116` `parseCommandDispatch`; `tools_commands.py:265-302`):
- plain: `{"output":"…","warning"?: "…"}` (no `type`);
- `{"type":"exec"|"plugin","output":"…"}`;
- `{"type":"alias","target":"name"}`;
- `{"type":"send","message":"…","display"?: "…","notice"?: "…"}`;
- `{"type":"prefill","message":"…","notice"?: "…"}`;
- `{"type":"skill","name":"…","message":"<expanded skill body>","display"?: "/name args"}`.

### 3.7 Other RPCs the dispatcher uses

| Method | Allowed params | Result → output line | Source |
|---|---|---|---|
| `session.status` | `session_id, profile` | `{output}` → output | `H/…/contracts/sessions.py:478-487`; `utils.ts:571-574` |
| `session.save` | `session_id, profile` | `{file}` → `Saved transcript to <file>` | `sessions.py:463-475`; `utils.ts:566-569` |
| `process.stop` | `session_id, profile` | `{killed:n}` → `Stopped n background process(es).` / `No background processes to stop.` — **kills every background process on the gateway** (`kill_all`) | `tools_commands.py:54-63`; `methods_tools.py:265`; `utils.ts:559-564` |
| `session.interrupt` | per spec 04 §5.2 | — | spec 04 |

### 3.8 Rename: `session.title`, then REST `PATCH /api/sessions/{id}`

`renameSessionPreferringRpc` (`V/app/chat/sidebar/session-actions-menu.tsx:114-140`):
1. If the new title is non-empty **and** the chat has a runtime id: `session.title` — `SessionTitleParams`:
   **`session_id, profile, title`** (`sessions.py:312-321`). Result `{"pending":false,"title":"<stored title>"}` (or
   `pending:true` when the row doesn't exist yet). Errors: `4021 "title required"`, `4022 "<reason>"` (too long,
   already used), `5007` (`H/tui_gateway/methods_session.py:1226-1252`). Emits `session.info` with the title.
2. Otherwise, or on **any** error from step 1: `PATCH /api/sessions/<stored id>?profile=<p>` with body
   `{"title":"<t>","profile":"<p>"}` (`V/api/sessions.ts:722-735`; body model `H/hermes_cli/web_models.py:268-275`).
   Answer `{"ok":true,"title":"<db title>"}`; `404` unknown id; `400` with the reason (too long / in use). An empty
   title clears it (`H/hermes_cli/web_routers/sessions.py:892-918`).

### 3.9 History pages for Share (whole chat)

`getAllSessionMessages` (`V/api/sessions.ts:653-700`): `GET /api/sessions/<stored>/messages?profile=<p>&limit=500&
offset=<n>&order=oldest&include_compacted=true`, `offset += returned` until a page is short, has no `pagination`, or is
empty; stop with an error when the JSON passes **32,000,000 characters**. Fold with `Hydration.fold` (spec 03 §6).
Use `HistoryRequest` with `order = "oldest"` (`NAT/HermesKit/Chat/HistoryAPI.swift:57-70`).

### 3.10 Error codes in this area (summary)

`4000` unknown param (a client bug — never retry) · `4001` stale runtime (resume once, resend once) · `4002` bad
value · `4009` busy (old gateways' model switch → parked) · `4018` skill (→ `command.dispatch`) · `4021`/`4022` title
· `4064` unknown profile (roster stale) · `5001` switch failed · `5007` db · `5020` catalog · `5030` slash worker ·
`5032` agent build · `5033` model inventory · `-32601` method missing (rpc commands fall back to `slash.exec`).

---

## 4. The chat's ⋯ menu

### 4.1 What the web phone shows, and what native builds now

The typed phone menu (`PHONE_CHAT_MENUS` released, `S/ui-chat/flags.ts:27-42`) is `chatMenuModel`
(`S/phone-chat-menu-model.ts:37-56`) with the Model submenu spliced in at index 1 and Watch Browser appended
(`S/phone-chat-menu.tsx:253-283`). In order:

| # | Web row | Shown when | Native this round |
|---|---|---|---|
| 1 | Tiles (medium, inline): **Share** · **Find** · **Info** | Share/Find only when the chat has messages | **Share**, **Info** (Find: later, §11) |
| 2 | **Model ▸** (subtitle "Opus 4.5 · Low") | live chat, section built | **Yes** (§4.6) |
| 3 | Pin / Unpin | always (writes) | slot `pin` — later |
| 4 | Mark as Unread / Read | messages or unread | slot `unread` — later |
| 5 | **Rename…** | not a bot's own chat (writes) | **Yes** (§4.5) |
| 6 | Read Replies Aloud (toggle, keeps open) | always | slot `readAloud` — voice stream |
| 7 | More ▸ Files · Changes · Branch in New Chat · Export Chat (UX study #73: was Export JSON) | — | slot `more` — later |
| 8 | Archive · Delete Chat (destructive) | not a bot's own chat | slot `danger` — later |
| 9 | Watch Browser | always (writes) | slot `browser` — Bot Screen stream |

A **bot's own chat** ("Bot Chat") never offers Rename, Archive or Delete: "any of them would leave the bot starting over
in a new, empty chat" (`S/phone-chat-menu-model.ts:9-12,30`). Native: a chat opened from a Bots row
(`AppModel.chat(for: Bot)`) or whose title is `RosterRules.botChatTitle` is a bot chat.

Every **write** row (Pin, Unread, Rename, Model rows, Watch Browser) is disabled offline with the subtitle
**"Offline"** (`phone-chat-menu-model.ts:38-39`; `title-menu.ts:29`). Offline (native) = `connection != .ready`.
Picks play a **selection** haptic (`phone-chat-menu.tsx:201`).

### 4.2 Native construction

- Replace `ChatViewController.moreMenu: UIMenu?` (`NAT/App/Chat/ChatViewController.swift:18-19,627-637`) with a
  provider: the bar item's menu is `UIMenu(children: [UIDeferredMenuElement.uncached { completion in
  completion(provider()) }])`, so every open reads current state (offline, model, favourites, title) with no network
  wait. Keep the item's identifiers (`chat.more`, label "Chat Actions").
- Tiles: `UIMenu(title: "", options: .displayInline, preferredElementSize: .medium, children: [share, info])`
  (Share `square.and.arrow.up`, Info `info.circle`).
- Model: §4.6. Rename: `UIAction(title: "Rename…", image: UIImage(systemName: "pencil"))`.
- The slot order above is fixed; a later stream adds its row at its slot id without moving the others.
- Update `NAT/App/Chat/Debug/ChatDemo.swift:134` (it sets a placeholder "Model (later)" menu).

### 4.3 Info

Keep M1's `ChatInfoSheet` (`NAT/App/Chat/ChatSheets.swift:220-240`). Change only its Model row: value
`displayModelName(modelState.model)`, secondary note = the provider as the Models sheet and the quick list name it
(`describe(id, provider).providerName`: the cached catalog row's name, else `plainProviderName(providerDisplayName)`).
Value and note share the value cell's secondary text (no fixed-size accessory), so at accessibility sizes they wrap and
stack under the label like the other rows (review round 2, check 33). Add a **Reasoning** row
when `reasoningEffort` is non-empty or `fast`: `effortLabel(reasoningEffort)` + (" · Fast" if fast)
(`S/phone-chat-menu-model.ts:92-94`). **⚑ DECISION:** the web capitalises the raw word ("Xhigh"); native uses
`effortLabel` ("Extra High"). Bot Info for bot chats is another stream.

### 4.4 Share (the transcript)

Web: `S/phone-chat-menu.tsx:225-235`, `S/fe-convo-r1-ui.ts:87-103`, `S/fe-convo-r1.ts:347-357`.

1. **Which messages.** Use the loaded messages only when they are the whole chat: native = `!hasOlder` and the open
   has applied fresh history (`openPhase == .open`). Otherwise fetch every page (§3.9). "A long chat holds just its
   latest page until older ones are loaded, and sharing that would silently drop its start" (`phone-chat-menu.tsx:228-229`).
2. **While fetching:** a notice **"Preparing transcript…"** that stays until the share sheet opens or the fetch fails;
   a second Share tap meanwhile does nothing (`phone-chat-menu.tsx:93-109`).
3. **Text** (`transcriptText`): the title then a blank line; then for each user/assistant message (hidden rows, tool
   rows and system notices — including slash output rows, §8.4 — left out): `"You:"` or `"<Bot>:"` on its own line,
   the message's text parts joined by `\n` with 3+ newlines collapsed to 2, trimmed, then a blank line; whole text
   trimmed plus one trailing `\n`. Web vector: `transcriptText('Hey', …)` →
   `"Hey\n\nYou:\nHi there\n\nHermes:\nChecking.\n\nDone.\n"` (`S/fe-convo-r1.test.ts:260-262`).
   - **⚑ DECISION:** the web always labels the bot "Hermes" (no `assistant` option is passed); native uses the bot's
     display name (M1's `ChatTranscriptText` already does), falling back to "Hermes". Keep M1's voice-memo line for
     user memo rows.
   - M1's `ChatTranscriptText.make` (`NAT/App/Chat/ChatSheets.swift:329-348`) has the wrong layout (`"You: text"` on one
     line, no title, includes system notes): replace it with this algorithm, moved into HermesKit as a pure function.
4. **Present** `UIActivityViewController(activityItems: [text])` anchored on the ⋯ item (title for the share sheet:
   the chat title or "Chat").
5. **Empty text** → M1's notice "Nothing to share yet." **Failure** → alert **"Couldn't Share Chat"**, message = the
   reason (two lines), buttons Show Details · **Try Again** (preferred) · OK (`S/ui-kit/native-alert.ts:103-121`).
   Over the 32 M cap the reason is **"This chat is too long to share from iPhone."** (**⚑ DECISION**: the web's text
   names the desktop dashboard).

### 4.5 Rename…

Web: `S/phone-chat-menu.tsx:157-174`; prompt `S/ui-kit/native-alert.ts:64-75`.

1. Alert, style alert, title **"Rename Chat"**, one text field: text = the current title, placeholder
   **"Untitled chat"**, `autocapitalizationType = .sentences`, autocorrection on, clear button while editing
   (`phone-chat-menu.tsx:355-363`); buttons **Cancel** · **Save** (preferred). Save is disabled until the trimmed text
   differs from the current title (`requireChange` defaults to true, `native-alert.ts:72`).
2. On Save with a changed title: **optimistic** — set `LiveChatSession.title` (the bar re-renders) and the Sessions
   row's title (`SessionStore`); then §3.8. On success use the returned `title` (or the typed one). On failure roll
   both back and show alert **"Couldn't Rename Chat"** with **Try Again** (`phone-chat-menu.tsx:157-169`).
3. An emptied field saves `""` (REST clears the title; `session.title` is skipped for empty, §3.8).
4. Offline: the row is disabled ("Offline").

### 4.6 Model ▸ (the submenu)

> **Superseded 2026-11-01 (owner: "Do the weak points").** The ⋯'s Model row now opens the model panel
> (docs/spec/06-native-feel-and-design.md, Model panel) instead of this submenu: one row, title "Model", subtitle as
> rule 7 and the node's subtitle below (`ModelMenuModel.build`), image `cpu`, id `chat.more.model`. The picker,
> Reasoning, Fast and Try Again live in the panel. The rules below still describe the quick list's inputs.

Web: `modelMenuNode` / `titleMenuModel` (`S/ui-chat/title-menu.ts:27-57,288-295`), inputs from `titleMenuContext.input`
(`:263-276`), tests `S/ui-chat/title-menu.test.ts`.

```
Model                                 subtitle: "<current name> · <effort label>"  (or "Offline"; effort part only when Reasoning shows)
 ├─ [inline section titled "Model for Next Reply"]
 │    ✓ <current model>                     state on
 │      <favourite 1…5, not current>       subtitle = provider name when its provider ≠ current's
 │      <recent 1…2, not already listed>   same subtitle rule
 │      More Models…
 ├─ Reasoning ▸   (single selection)  subtitle = effort label   [Off] Minimal Low Medium High Extra High Max Ultra
 └─ Fast          (toggle, state on/off)
```

Construction rules:

1. **Current** = `ChatModelState.{model, provider}` when both are set, else the catalog answer's `{model, provider}`,
   else whichever parts exist (`currentPickerSelection`, `V/lib/model-status-label.ts:6-32`). Described as
   `{id, name: displayModelName(id), provider: <matching catalog row's slug, else the given provider>, providerName:
   plainProviderName(row.name || providerDisplayName(provider) || provider)}` (`title-menu.ts:152-156`).
2. **Favourites:** with a cached catalog, the catalog rows for the starred keys in starred order (missing ones dropped,
   `title-menu.ts:69-73`); without one, each key `provider::model` described from the key alone
   (`title-menu.ts:269-272`). Skip the current one; at most **5** (`:35-37`).
3. **Recents:** `dispatch.chat.recentModels` rows that exist in the cached catalog (none without a catalog,
   `title-menu.ts:266`); skip ids already listed; at most **2**.
4. Row subtitle = `providerName` only when the row's provider differs from the current's (`:43-44`).
5. **Reasoning** shows unless the catalog says `capabilities[model].reasoning == false` or the current id is empty;
   levels = `minimal…ultra` (`SH/reasoning-effort.ts:4`), with `none` ("Off") first unless
   `can_disable_reasoning == false` (`title-menu.ts:48-54,273-275`). Current = `reasoningEffort`, or **"medium"** when
   empty (`SH/reasoning-effort.ts:15`; the web's profile-config default is not read, §15).
6. **Fast** shows when (`title-menu.ts:163-170`): `capabilities[model].fast` → toggles the tier; else the provider
   lists both `<base>` and `<base>-fast` → toggling switches between those ids (`restorePreset:false`) and saves
   `{fast:on}` on the base's preset (`:255-258`); else only while `fast` is currently on (so it can be turned off).
7. Offline: every row above (model rows, More Models…, levels, Fast) disabled with subtitle "Offline"; the Model
   submenu's own subtitle reads "Offline" (`title-menu.ts:29,291-293`).
8. UIKit: `UIMenu(title: "Model", subtitle: …, image: UIImage(systemName: "cpu"), children: [inline, reasoning, fast])`;
   inline = `UIMenu(title: "Model for Next Reply", options: .displayInline, …)`; reasoning = `UIMenu(title:
   "Reasoning", subtitle: …, image: "brain", options: .singleSelection, …)`; Fast = `UIAction(title: "Fast", image:
   "bolt", state: …)`.
9. **⚑ DECISION:** the web keeps the menu open on Fast (`keepsOpen`, `title-menu.ts:55`). A `UIBarButtonItem` menu
   can't redraw a row's state while it stays open, so native's Fast closes the menu like every other pick; the next
   open shows the new state.
10. Picks: a model row → §5 `switchModel(row)`; More Models… → §6; a level → §5.1; Fast → §5.2. Not offered when the
    chat isn't a `LiveChatSession` (demo, unavailable chat).

### 4.7 "New chat with this bot"

The web chat ⋯ has **no** New Chat row. New Chat lives in Bot Info › Conversations (`S/ui-bots/info-state.ts:105-108`)
and the Bots row menu (`S/ui-bots/bot-menu.ts:43`). It belongs to the Bot Info / bot-writes stream; do not add it to
the chat ⋯.

### 4.8 Usage & Limits › Pay As You Go (tester batch 3, 2026-10-25)

Tester: "A credits balance for the pay as you go providers in the same usage menu please." The page's signed-in providers
with no plan, window or rate limit to show (until now one footer line, "Pay as you go, with no limits reported: X, Y.")
are a **Pay As You Go** section: one row per provider (a name once), its balance on the right. When the chat's own
provider is one of them, its row is first ("OpenRouter · This Chat") and the section leads the page; otherwise it follows
the plans. Footer: "Balances as Hermes reports them. A provider paid by API key may not report one."

Where Hermes gives a balance (read-only, nothing invented; `HermesKit/Chat/UsageLimits.swift`):
- **/usage** (`slash.exec command=usage`, the chat's own session; H:tui_gateway/methods_slash.py `_usage_account_blocks`,
  read inside the session's profile). The chat provider's block: OpenRouter's and Codex's details say
  `Credits balance: $12.34` or `Credits balance: unlimited` under `Provider: openrouter` / `Provider: openai-codex (Plus)`
  (H:agent/account_usage.py). Signed in to Nous, its credits block follows: `Total usable: $7.50` under `Provider: nous`.
  A figure counts only on its own provider's line shape under that provider's `Provider:` line (a blank line or a
  `📈` title starts again); `$-1.23` (Python's debt) shows as `-$1.23`; `$nan`, `—` and anything else are no figure.
  Asked when the page opens (again on Check Again, a pull to refresh, or the connection coming back) with `runtime:
  .required`: a chat that hasn't started isn't asked (asking would start it).
  The Full Usage Report button's answer refreshes the balances too. These reads can overlap and land in any order, and
  /usage is fail-open (a provider whose check failed is left out, not reported as none), so the page keeps each
  answer's figures by provider: a newer answer's replace an older's, an older one landing late only fills gaps, an
  answer without a provider's figure keeps the one before, and a failure shows only when it was the newest read sent
  and none has been answered.
- **billing.state** (H:tui_gateway/billing_view.py `_serialize_billing_state`), params `{profile}` only (ProfileParams;
  `session_id` is refused). It reads the **gateway's own** Nous login whichever bot asks (the dispatcher doesn't scope
  it), so only the main bot's chats (`profile` "default") ask it, and only while the cached catalog has a signed-in Nous
  row (or no catalog yet). Fail-open: `free_tier_account` or `logged_in: false` = no balance; `error` = the portal failed.
  The figure is the credits Nous can spend, `usage.total_spendable_display` when `usage.available` (the portal's total
  usable credits, H:agent/billing_usage.py `usage_model_from_account`: the same figure /usage words "Total usable", so
  both reads give the row one number); `balance_display` (the portal's account balance, which the desktop's Billing
  page shows and which can differ) only when Hermes has no total. Its reads overlap as /usage's do; each answer is the
  whole state, so the newest answered wins, and a failure shows only from the newest read when none has answered.
- Nothing else: `model.options` usage has no balances, there is no REST route, and API-key providers (Anthropic and
  OpenAI keys, DeepSeek, …) report none, so they always read "Balance not available".

Each row takes the best any read gave (a figure, then Checking…, then Couldn’t check, then Offline, then none):
- "$12.34" (the app's money format), "Unlimited".
- "Checking…" with a spinner while a read that can fill it is out and the app is connected; never for a provider no
  read can fill (a read out or failed speaks only for the chat's own provider when /usage gives its balance, OpenRouter
  and Codex, and for Nous; a figure in an answer counts for whichever provider it names).
- "Couldn’t check" with the gateway's reason under the name, and a **Check Again** row in the section.
- "Offline": the connection is gone and no figure was read (a figure read before stays). The page follows the
  connection while it shows (every half second, as the Models sheet does): Offline comes by itself, and the rows it
  marked are read again once the connection is back.
- "Balance not available", noted "Shows in a chat that uses it" (OpenRouter, Codex: their balance is only in /usage for
  the chat's own provider) or "Shows once this chat has started" (no session yet; Nous in the main bot's chat comes
  from billing.state instead).
The value keeps its line and the name and note wrap first; at accessibility text sizes the balance goes under the name.
The ⋯ row's subtitle is unchanged (plans only).
A pay-as-you-go login that shows as a plan (an OpenRouter key with a spending limit has an "API key quota" window; a
rate-limited one has a block of notes; a single Codex login has its plan's windows) keeps its balance when it is the
chat's own provider: a **Credits balance** row under its bars, once /usage gives a figure (nothing while it is asked,
fails or is offline: the bars are the block). A pool's logins get none (/usage doesn't say which login it read), nor
does Nous: its credits lines already show under Credits (`session.usage` `credits_lines`).
Tests: `Tests/Menus/MenuExtrasTests.swift` "pay-as-you-go balances"; UI `MenusTests.test31_PayAsYouGoBalances`,
`test32_BalanceUnderAPlansBars` (and test30's OpenRouter row).

---

## 5. Switching the model (`switchModel`), Reasoning and Fast

Port of `titleMenuContext.switchModel` (`S/ui-chat/title-menu.ts:197-246`) and `requestModelSwitchWithFeedback`
(`S/model-switch-feedback.ts:22-68`). Lives in HermesKit (`ModelSwitcher`, main actor) with UI callbacks injected
(confirm, failure alert, notice).

```
switchModel(picked, restorePreset = true) -> Bool
 1. assertWritable: offline → fail "Offline"; no runtime id → fail "This chat is still loading. Try again when it is ready."
 2. if a switch is pending for this runtime id → return false (silently)            [app-wide map, survives leaving the chat]
 3. before = current(); preset = presets[picked.provider::picked.id]; caps = capabilities(picked)
    target = (restorePreset && caps?.fast != true && preset.fast == true && provider lists "<picked.id>-fast")
             ? describe("<picked.id>-fast") : picked
 4. paint(target): modelState.model/provider = target (optimistic; the menu and Info show it at once)
 5. notice "Switching to <formatModelPillLabel(target.id)>…" (spinner, stays) ; mark pending(runtime id) and
    pending(this chat) — a 4001 resume rebinds the chat under a new id mid-switch; its `info` must not repaint
 6. result = config.set model (§3.2)
      confirm_required → rollback paint; hide notice; confirm alert:
            title "Change Model?", message = confirm_message, buttons Cancel · "Change Model" (preferred)
            Cancel → return false
            then: assertWritable again; if current() != before → fail "The model changed. Choose it again."
            resend with confirm_expensive_model:true (with its own "Switching to …" notice);
            still confirm_required → fail (confirm_message or "The model switch still requires confirmation.")
            paint(target)
      deferred → notice "<label> will be used for your next message."          (5 s)
      else     → notice "Model changed to <label>."  (5 s); mark the catalog key stale
      either   → paint(target) again (review round 2: nothing that arrived meanwhile stays painted)
    error: 4009 busy-switch (old gateways) → treat as deferred (keep paint, "…will be used for your next message.")
           anything else → rollback paint; hide notice; fail(error)
    always: clear pending(runtime id) and pending(this chat)
 7. recents: remember(before); remember(target)          → newest first: target, before, …
 8. if restorePreset: if caps?.reasoning != false → setReasoning(preset.effort ?? profileDefault, target)   (see 5.1)
                      (profileDefault: `config.get reasoning` with no session_id, §15 item 8; unreadable → no write)
                      if caps?.fast == true        → setFast(preset.fast ?? false, target)
 fail(error) → alert "Couldn't Change Model", reason = error message, Show Details · OK  (+ error haptic)
```

Notes: `rollback` restores `before` only if the same chat is still on screen; the label is computed from the id only
(no Fast flag) (`model-switch-feedback.ts:31-32`). The `4001` rule (§0) applies to every send in steps 6 and 8.

### 5.1 Reasoning (`patchOption({effort})`, `title-menu.ts:175-196`)

assertWritable → save preset `{effort}` for the current model → optimistic `reasoningEffort = level` →
`config.set {key:"reasoning", session_id, value: level, profile}` → on error restore the previous preset and value and
fail "Couldn't Change Model".

### 5.2 Fast (`setFast`, `title-menu.ts:250-262`)

Not supported → fail "Fast is unavailable for this model." Sibling variant → `switchModel(describe(on ? sibling : base),
restorePreset: false)` then preset `{fast:on}` on the base. Else: save preset `{fast}`, optimistic `fast = on`,
`config.set {key:"fast", session_id, value: on ? "fast" : "normal", profile}`, roll back on error.

### 5.3 Notices

Reuse `ChatNoticeToast` (`NAT/App/Chat/ChatChrome.swift:315-362`): add `show(_:duration:spinner:)` — `duration: nil`
keeps it until replaced (the "Switching…" state, with a small `UIActivityIndicatorView` leading); a replacement keeps
the capsule in place and swaps text. Web durations: info/success 5 s (`V/store/notifications.ts:60-66`).

---

## 6. More Models… (the Models sheet)

Web: `S/ui-chat/model-sheet.tsx:18-182`; owner's description in `MEM/favorite-models.md:17`.

**Presentation.** `UINavigationController` in a page sheet, detents `[.medium, .large]` starting medium, no
grabber, opaque grouped background (same `UIColorEffect` treatment as `ChatSheet.wrap`,
`NAT/App/Chat/ChatSheets.swift:12-35`). Bar: leading **Cancel** (system `.cancel` item — "Cancel leads, where iOS puts
it on a picker sheet (a pick closes it, so there is no Done)", `model-sheet.tsx:125`), title **"Models"**, trailing
Refresh (`arrow.clockwise`, label "Refresh Models", disabled while loading or offline). A search field under the bar
(`navigationItem.searchController`, placement stacked, never hides; placeholder **"Search Models"**, no
autocapitalisation); focusing it animates the sheet to `.large` (`model-sheet.tsx:131`). Under the search field, footnote
lines sized to their text (they wrap at the largest sizes): when offline **"You’re offline. Models can be changed when
you reconnect."** (native: the one place that says why the rows are greyed), and always the scope ([model-scope], owner
2026-11-03), **"Applies to this chat only. Change <bot>’s default in Bot Info › Brain."** (the chat's bot; with no Bot
Info for it, the first sentence alone; `ModelPanelModel.switchScope`).

**States** (`model-sheet.tsx:133-143`):
- Loading: 5 skeleton rows (Fill 3 bars, widths 55 %, 67 %, 79 %, 55 %, 67 %), VoiceOver "Loading Models".
- Error: **"Couldn't Load Models"**, then **"You’re offline."** when the error is "Offline", else **"Hermes didn’t send
  its list of models. Show Details has the reason."**; rows **Try Again** (reload with `refresh:true`) and **Show
  Details** (a details sheet with the raw error and Copy).
- Empty: **"No Results for “<query>”"** while searching, else **"No Models Available"**.

**Sections** (`modelSections`, `model-sheet.tsx:18-35`): one section per provider in catalog order, titled with the
provider's `providerName`, rows in catalog order. **Twins:** within a provider, a second row with the same id or the
same (case-insensitive, trimmed) display name is dropped — unless it is the current model, which takes the first one's
place. **Search:** split the query on whitespace; keep a row when every word is a substring of
`"<id> <name> <provider> <providerName>"` lower-cased; sections that end empty disappear.
**Favourites:** when not searching and favourites exist, a first section **"Favorites"** with the starred rows (catalog
rows in starred order), each showing its provider name on a second line; the same rows also stay in their provider's
section ("so a row starred there doesn't jump away from under the finger", `model-sheet.tsx:74-77`).

**Rows** (`model-sheet.tsx:150-161`): min height 44 pt; title = model name (Body); in Favorites a second line with the
provider (Footnote, label-2) and 12 pt vertical padding; a checkmark on the current model (`id` and `provider` equal);
a **star button** at the trailing edge — 44 × 44 pt, 6 pt from the edge, SF `star` / `star.fill`, tint when starred,
label-3 when not, VoiceOver "Favorite <name>" with the selected trait when starred. The star works **offline**
(favourites are on this phone); the row itself is disabled offline.

**Star tap:** selection haptic; toggle the key (§2.3). Hold the tapped row where it was: note its `minY` in the
window before applying the snapshot, then add the difference to `contentOffset.y` (the web does this by hand because
WebKit lacks scroll anchoring, `model-sheet.tsx:83-95`; UITableView doesn't anchor either).

**Opening position:** with favourites, the top. Without, if the current model's row isn't fully visible, scroll so its
provider section's header sits at the top of the list; nothing moves when it is visible (`model-sheet.tsx:96-108`).

**Pick:** close the sheet, then `switchModel(row)` (§5) (`model-sheet.tsx:109`).

**Entry points:** ⋯ › Model (or the composer's model bubble) › the model's name › Search All Models; the `/model [query]` command (§8.2, opens with the query in the search
field); and (later stream) the chat error banner's "Choose a model" (`S/phone-chat-menu.tsx:301-328`) — expose
`ChatViewController.presentModelSheet(query: String? = nil)`.

The desktop menu's provider-grouped Favourites (`S/favorite-model-groups.ts:18-43`, used by the vendored menu on iPad
only, `MEM/favorite-models.md:16`) is **not** used on the phone.

---

## 7. The commands sheet (☰)

### 7.1 The button

Spec 06 §4.3 already fixes the geometry: order `[☰ 40] [+ 40] [field] [primary]`, ☰ and + glass circles, glyph
`M5 7h14M5 12h14M5 17h14` stroke 2 in label-2 at 18 pt, gaps ☰↔+ 7 pt, +↔field 6 pt, all three in the composer's
`UIGlassContainerEffect` (spacing 6). Native M1's `ComposerView` has no + yet (`NAT/App/Chat/ComposerView.swift:22-80`):
put ☰ at the leading edge **6 pt** before the field, and leave the + slot between them for the attachments stream.

- 40 pt visible in a 44 pt hit box; `UIGlassEffect` with `isInteractive = true`; accessibility label **"Commands"**,
  identifier `composer.commands`.
- Shown in 1:1 chats on iPhone only (`S/ui-chat/composer.tsx:48-59`; `B/ui-chat-commands-gates.ts:1-8`).
  Disabled while signed out; offline it still opens (cached list or the error state).
- Tap: `view.endEditing(true)` (the keyboard goes down for the sheet, `S/ui-chat/commands-sheet.tsx:87`), present the
  sheet. No haptic.

### 7.2 The list

`loadCommandSections` → `filterDesktopCommandsCatalog` → `commandSections` (`S/ui-chat/commands.ts:23-64`;
`V/lib/desktop-slash-commands.ts:179-797`). Native algorithm:

1. Fetch `commands.catalog` (§3.5, 1 h cache).
2. **Resolve** each command's surface (`resolveDesktopCommand`, `desktop-slash-commands.ts:504-513`): canonical name =
   local alias table → `canon` → itself. If it is in the **local spec table** (§8.2) that table wins; otherwise the
   catalog's `commands[name]`: `desktop` ∈ reasons → *unavailable*; `"hidden"` → executable but hidden; else *exec*
   with its `argument_mode`. Unknown to both → an *extension* (skill / quick / plugin command).
   (The web also ships an offline copy of the registry, `V/lib/desktop-slash-registry.json`, for the gap before the
   catalog answers; native lists nothing until the catalog answers, so it doesn't need it — §15.)
3. **Keep** a command when (`isDesktopSlashSuggestionWithOptions`, `:600-626`): it is not an alias (local alias or a
   `canon` entry pointing elsewhere), not unavailable, not hidden — or it is an extension. Then drop the phone-hidden
   names `timestamps, ts, focus, egress, codex-runtime, codex_runtime, debug, worktree` (`S/fe-convo-r4.ts:80-85`)
   and the **native-unsupported** names of §8.2.
4. **Sections:** the catalog's `categories` in order (or one "Commands" section from `pairs` when there are none),
   each with its surviving rows in order; then **"Skills"**: the flat `pairs` not already listed that are extensions,
   ranked by `skills[name].usage` descending then A–Z, **dropping bundled skills with no usage** (`origin ==
   "bundled"` and usage 0) (`rankSkillCommands`, `:724-747`); empty sections dropped (`commands.ts:23-37`).
5. **Description** shown under each command: `slashDescription(cmd, desktopSlashDescription(cmd, catalogDesc))`:
   - `desktopSlashDescription`: the English override for the command from `V/i18n/en.ts:3845-3918` (`commandDescs`,
     copy the table verbatim into Swift), else the local spec's description, else the catalog text; when the catalog
     text ends with `" (usage: …)"`, append that suffix (`desktop-slash-commands.ts:660-674`).
   - `slashDescription` (`S/fe-convo-r5.ts:197-228`): the plain-words table (reasoning, usage, tools, rollback,
     bundles, pet, browser, pause, undo, queue, platform, prompt, clear, details, copy, quit) wins; else strip
     backticks, parentheses that hold `/x`, `--x`, "alias(es)" or "e.g.", a `": /x…"` tail, a `"; /x…"` / `"; x
     redeems|resets|resumes…"` tail, every `[…]`/`<…>` span, ` -x`/` --x` flags, `|` → space; collapse spaces, trim
     trailing `;:,.|`, capitalise the first letter.
   - Vectors (`S/fe-convo-r5.test.ts:176-188`): `/usage` → "Token usage and rate limits"; `/frob "Frob things: /frob
     [a|b] [--force]"` → "Frob things"; `"Frob the \`widget\` [--all]"` → "Frob the widget"; `"Toggle a thing (/frob,
     /frob list, /frob x)"` → "Toggle a thing"; `"start a new thing"` → "Start a new thing"; `"Pause new work; '/frob
     off' resumes"` → "Pause new work".
   - **⚑ DECISION:** `/help` reads **"Show the commands list"** (the web's says "desktop"; native's /help opens this sheet).
   - **⚑ DECISION (review round 2):** `/help` and `/commands` are **not listed** in the sheet — from inside it they only
     reopen it, a dead end (`MEM/glitch-sweep.md`: hide dead controls); typed, they still open it. In a bot's own chat
     `/title` is not listed either (it only answers "A bot's own chat keeps its name", §8.2).
6. **Search** (`filterSections`, `commands.ts:40-47`): drop a leading `/` from the query, split on whitespace; keep rows
   whose `"<command> <description>"` lower-cased contains every word; drop empty sections.

### 7.3 The sheet

Same frame as the Models sheet (§6): medium → large on search focus, no grabber, leading **Cancel**, title
**"Commands"**, search placeholder **"Search Commands"** (no autocapitalisation, no autocorrection), no Refresh
(`S/ui-chat/commands-sheet.tsx:56-84`).

- Row: the command in **Body semibold** on the first line, the description in **Subheadline label-2** below (wraps,
  no line limit), **12 pt** top and bottom padding (`commands-sheet.tsx:75-79`; `MEM/row-padding-feedback.md`).
  Section headers in Footnote label-2.
- A star per row, and a **"Favorites"** section on top: docs/spec/3x-composer.md §9.7.
- Loading: 5 skeleton rows (widths 45 %, 57 %, 69 %, 45 %, 57 %), "Loading Commands".
- Error: **"Couldn't Load Commands"** / **"The computer running Hermes didn’t send its list of commands. Show Details has
  the reason."** (offline: **"You’re offline."**; a timeout: **"The computer running Hermes didn’t answer in time."**, as
  the Models sheet, `CommandsLoad`) with **Try Again** (fresh fetch) and **Show Details**.
- Empty: **"No Results for “<query>”"** / **"No Commands Available"** (`command` symbol) with **"Hermes sent no commands
  or skills for this chat. Skills added on the computer running Hermes show up here."** and **Check Again** (fresh fetch)
  (2026-10-28, Mac stress round 2 #48: the title alone gave no reason or next step; Check Again since stress test
  2026-10-31, nothing failed; the Models sheet's empty list says Check Again too).

### 7.4 What a pick does

`pickAction` (`S/ui-chat/commands.ts:52-56`) and the sheet's `pick` (`commands-sheet.tsx:45-52`); the sheet closes
first in every case, and **no haptic** (`MEM/taptic-feedback-gaps.md`).

| Row | Action | Native |
|---|---|---|
| a skill (Skills section) | **insert** | — |
| `/model` (picker `model`) | **models** | open the Models sheet (§6). In practice `/model` never lists: the registry marks it `desktop:"hidden"` (`H/hermes_cli/commands.py:191-193`) — `MEM/commands-button.md:24` "/model is hidden by the desktop filter anyway". |
| a picker (`/resume`) or any `argument_mode` (`options`/`text`/`mixed`) | **insert** | composer text becomes `"/cmd " + draft` (a draft that already starts with a command, `^/[^\s/]*(\s|$)`, has that command replaced: `/goal x` → `/compress x`), caret right after `"/cmd "`, field becomes first responder (in the sheet's dismissal completion), so the keyboard rises (`commands.ts:66-78`) |
| otherwise (`argument_mode == null`, not a picker) | **send** | run the dispatcher (§8) with `"/cmd"`; **the composer's draft is untouched** |

`argument_mode` for the decision = the local spec's mode if it has one, else the catalog's `commands[name].argument_mode`
(`desktopSlashCommandArgumentMode`, `desktop-slash-commands.ts:676-678`). Against the gateway source at `H/` HEAD, the
commands that **send** are `/retry /stop /agents /initiate-setup /status /yolo /whoami /palette /subscription /topup
/version /bundles` (and `/profile`, native-unsupported); everything else in the list inserts — `/usage` included,
because its hint `[reset [--force]]` makes it `text` (computed from `H/hermes_cli/commands.py:83-347`; the build-112
note that `/usage` sends came from a synthetic catalog without `commands` metadata).

---

## 8. Slash commands on send (the dispatcher)

The web routes **any** sent text that is a slash command through its dispatcher instead of `prompt.submit`
(`V/app/session/hooks/use-prompt-actions/index.ts:625-638`). Native today sends `/usage` to the model as a user
message — this round fixes that, and the sheet's "send" uses the same path.

### 8.1 When

- Detection: `^/[^\s/]*(\s|$)` on the trimmed text (`SH/slash.ts:9-11`) — `/usage` and `/plan do it` are commands;
  `/usr/local/bin` and `run /x` are prose. Not when the send carries attachments (later stream).
- Parse: name = first whitespace-separated token after the leading slashes, lower-cased; arg = the rest with only the
  outer whitespace trimmed (newlines inside are kept) (`SH/slash.ts:24-39`). Empty name (`"/"`, `"/ words"`): put the
  text back into the field when anything follows the slash, and add the output line **"empty slash command"**
  (`slash.ts:1280-1295`; `V/i18n/en.ts:5523`).
- Runs **at once even while a reply is running** (never queued; `V/app/chat/composer/hooks/use-composer-submit.ts:280-292`).
- **No user bubble** and no send lift: the composer clears (typed path) and the output line appears (§8.4).
- Route in `ChatViewController.send` (`NAT/App/Chat/ChatViewController.swift:1712-1722`) before `session.send`:
  `if let runner = session as? ChatSlashRunning, SlashCommand.matches(text) { composer clears; runner.runSlash(text); return }`.
- Needs a runtime id: when there is none, `resumeNow()` first; failure → output `error: Couldn’t reach this chat.`

### 8.2 Resolution and native handling

Local spec table (from `DESKTOP_COMMAND_SPECS`, `V/lib/desktop-slash-commands.ts:179-304`; aliases in brackets) and
what native does with each:

| Command | Web surface | Native this round |
|---|---|---|
| `/model` | picker `model` (hidden) | open the Models sheet; `arg` pre-fills its search |
| `/help` [`/commands`] | action: prints the catalog | **⚑ DECISION:** open the Commands sheet |
| `/stop` | action | the Stop button's own path (`session.stop()`), then `process.stop {session_id, profile}`; one output row: `"Stopped the active turn."` (or `"Could not stop the active turn: <msg>"`) + newline + the process line (or `"Could not stop background processes: <msg>"`) (`slash.ts:512-551`) |
| `/title` | action | with an arg: `session.title` (§3.8 step 1) → `"Session title set: <t>"` (+ `" (queued while session initializes)"` when `pending`); apply the title like Rename; error → `"error: <msg>"`. Bare `/title` → exec path (`slash.ts:1045-1083`) |
| `/reasoning` | action | parse flags (`--global`/`-g`/`global` → scope global; `--session`/`-s`/`session` → scope session); no value → `config.get` (§3.4); else `config.set` → `"reasoning: <value>"`; a level updates `modelState.reasoningEffort`; `-32601` → exec path (`slash.ts:838-871`) |
| `/yolo` | action | `next = !modelState.yolo`; `config.set {key:"yolo", session_id, value: next ? "1":"0", profile}` → output **"YOLO on for this session"** / **"YOLO off for this session"** from the answer; failure → alert "YOLO" / "Could not toggle YOLO" (`slash.ts:877-897`; `en.ts:5527-5531`) |
| `/status` | rpc `session.status` | §3.7; `-32601` → exec path (`slash.ts:455-494`) |
| `/save` | rpc `session.save` | §3.7; same fallback |
| `/new` [`/reset` `/clear`] | desktop action | **Built 2026-10-27** (3x-composer §8.2): a new chat with this chat's bot opens in this one's place, the words after the command in its field; no output row. Listed in the drawer and the sheet ("Start a new chat"). |
| `/compress` [`/compact`] | desktop action (`session.compress`) | **Built 2026-10-27** (3x-composer §8.3): `session.compress {session_id, focus_topic?}` with a 660 s wait, "Compressing context…" running row, the summary's headline / token line / note as the result; `-32601` → exec path. Listed in the drawer and the sheet. |
| `/branch` [`/fork`], `/btw`, `/bg` [`/background`], `/resume` [`/sessions` `/switch`], `/profile`, `/skin`, `/wake`, `/handoff`, `/browser`, `/journey` [`/learning` `/memory-graph`], `/pet`, `/hatch` [`/generate-pet`] | desktop actions / pickers | **native-unsupported**: hidden from the sheet; typed → output **"/<name> isn't available in HQ Native yet."** Never sent to `slash.exec` (the web keeps them off it on purpose, e.g. `/compress` times out there, `slash.ts:652-660`; `/new` would run in a throwaway CLI). |
| catalog `desktop` reason | unavailable | output the web's line (`desktop-slash-commands.ts:475-482`): terminal → "/x is only available in the terminal interface."; messaging → "/x is only used from messaging platforms."; settings → "/x is managed from the desktop sidebar."; advanced → "/x is not shown in the desktop slash palette. Use the relevant desktop control or terminal interface instead."; composer-voice → "Voice chat lives in the composer here: …" (verbatim) |
| everything else (registry `exec`, skills, quick, plugin) | exec | §8.3 |

### 8.3 The exec path (`runExec`, `slash.ts:259-447`)

```
slash.exec {session_id, command: text without leading "/", profile}
  ok, result has "type"  → handle directive
  ok, plain             → output = result.output || "/<name>: no output"; prefix "warning: <w>\n" when warning
  error E               → command.dispatch {session_id, name, arg, profile}
                              ok   → handle directive (null/unknown shape → "error: invalid response: command.dispatch")
                              error D → D.message matches /not a quick\/plugin\/(?:bundle\/)?skill command/i
                                        ? "error: /<name> failed: <E.message>" : "error: <D.message>"
directive:
  exec | plugin → output = output ?? "(no output)"
  alias         → run "/<target> <arg>" again (no second "recorded" header: its output line has no command prefix)
  send | prefill with a non-empty notice → output the notice first
  prefill       → put message into the composer (replacing the draft) and focus it
  send | skill  → message empty → "/<name>: empty message" | "/<name>: skill payload missing message"
                  display = directive.display, else Hydration.skillInvocationText(message)   (NAT Hydration.swift:204)
                  busy → add to the chat's queue (QueuedMessage gains `display`) and output
                         "session busy — message queued to send when the current turn finishes"
                  idle → session.send(message, display: display)  — the bubble shows `display`, the wire carries `message`
```

`LiveChatSession.send(_ text:)` gains `display: String? = nil`: the optimistic bubble's text is `display ?? text`,
`prompt.submit.text` is `text` (contract has no display field, `H/tui_gateway/contracts/prompt_voice.py:26-52`); the
fresh history read later folds the stored skill expansion back to its invocation (spec 03 §6.3).

### 8.4 Output rows ("slash output")

Web: `appendSessionTextMessage(sid, 'system', "slash:/<name>\n<output>")` (`slash.ts:242-248`; `utils.ts:500-502`),
drawn by `system-message.tsx:133-163` and the phone CSS (`S/phone-fe-convo.css:510-511`).

- A **local** message (`role .system`, id `local-slash-<n>`, `MessageMeta.slashCommand = "/<name>"`), never written to
  the transcript cache, kept while the chat screen lives (re-inserted after its anchor message across history merges),
  gone after the chat is closed. Excluded from Share (§4.4) and from unread/preview logic.
- Visual: centred, max **85 %** of the content width, Footnote (13 pt min, capped as other notices), label-2. One-line
  output: `"<command in monospaced Footnote> · <output>"`, centred. Multi-line output: the command on its own line, the
  output below **left-aligned** in the same monospaced Footnote, whitespace preserved (columns line up best left-aligned
  and monospaced, `system-message.tsx:137-153`); long lines wrap.
  Links (explicit URLs only) are tappable. No hold menu (system rows have none, `S/ui-chat/message-menu.ts:12`).
- **⚑ DECISION (feel):** the row appears immediately as `"<command> · Running…"` and its text is replaced in place
  when the answer arrives (a first `slash.exec` can take seconds while the gateway starts a slash worker,
  `H/tui_gateway/methods_tools.py:1155-1171`); the web shows nothing until then.
- Rows from an `alias` re-run carry no command prefix (`recordInput:false`, `slash.ts:242-248`).

---

## 9. Message hold menus

Web: `S/ui-chat/message-menu.ts:11-44`, `S/ui-chat/message-menus.ts:32-79`, `S/ui-chat/message-actions.ts:11-71`,
`S/ui-chat/select-text-sheet.tsx:8-39`; flag `PHONE_MESSAGE_MENUS` released (`S/ui-chat/flags.ts:32`).

### 9.1 Items

| Kind | Web items (in order) | Native this round |
|---|---|---|
| you (your bubble) | tiles [Copy, Edit*] · Select Text · React…* · Rewind to Here* (destructive) | tiles [**Copy**] · **Select Text** |
| reply (the chat's bot) | tiles [Copy, Read Aloud, Share] · Select Text · Regenerate (latest only) · Branch in New Chat · Show/Hide Steps* | tiles [**Copy**, **Share**] · **Select Text** |
| delivery (another bot's / job's message) | tiles [Copy, Share] · Select Text | tiles [**Copy**, **Share**] · **Select Text** |
| system, notice, error | none | none (the error card keeps its own "Copy Details", `NAT/App/Chat/Cells/ChatCells.swift:698-705`) |

\* conditional in the web. Tiles = `UIMenu(options: .displayInline, preferredElementSize: .medium)`; Select Text is a
plain row (`text.cursor`); Copy `doc.on.doc`, Share `square.and.arrow.up`.

While the message is streaming, everything except Copy and Select Text is **disabled with the subtitle "Still
Replying"** (`message-menu.ts:13-16`; test `S/ui-chat/message-menu.test.ts:30-37`).

**Menu title** (`messageMenuTitle`, `message-menu.ts:40-44`): `"<sender> · <when>"` — "You" / the bot's name / the
delivering bot's name; `<when>` is the bubble's long time form (spec 06 §2.4: "9:14 AM", "Yesterday 9:14 PM",
"Sep 26, 9:14 PM"). Web vectors: `Hermes · 9:14 AM`, `You · 9:14 AM`, `Scout` (no time) (`message-menu.test.ts:43-50`).
The web also inserts the model when the reply came from a different one; native may add it later (not an acceptance
check).

The menu belongs to the **whole message** (all of a reply's bubbles), lifting the bubble that was pressed
(`message-menus.ts:63-68`); keep M1's targeted preview (`ChatCells.swift:242-262`).

### 9.2 What each does

- **Copy:** the message's text parts joined with `\n` **as Markdown** ("Copy keeps Markdown", `message-actions.ts:9-10`;
  `messageText`, `S/ui-chat/run.ts:55-61`) → `UIPasteboard.general.string`; HUD **"Copied"** with a checkmark, 1.5 s, top centre
  (`S/ui-kit/hud.ts:1-30`); success haptic (`message-actions.ts:26`). There is no separate "Copy as Markdown": Copy is
  Markdown.
- **Share:** `readableText(markdown)` in `UIActivityViewController`, anchored on the bubble (`message-actions.ts:47-50`).
- **Select Text:** a medium sheet titled **"Select Text"** with **Done** (trailing), the `readableText` in a
  non-editable, selectable `UITextView` (Body), and a bottom **"Copy All"** button that copies that text (HUD
  "Copied"); a copy failure shows **"Couldn’t copy this message."** inline (`select-text-sheet.tsx:8-26`).
- Failures of an action: alert **"Couldn’t Complete Action"** with the reason (`message-actions.ts:67-70`).

`readableText` (`message-actions.ts:11-21`), per line outside code fences (fence lines themselves dropped, fenced lines
kept verbatim): list marker (and `[ ]`/`[x]`) → `"• "`; drop heading `#`s and quote `>`; images → alt text; links →
`words (url)` (or just `url` when equal); remove `**`/`__`/`*`/`_`/`~~` emphasis and backticks around inline code.
Vector (`S/stress-b.test.ts:51-55`): ``"- **Brandy:** you told her\n## Next\nSee [the doc](https://x.test) and `npm i`\n```\nconst a = **b**\n```"`` →
`"• Brandy: you told her\nNext\nSee the doc (https://x.test) and npm i\nconst a = **b**"`.

### 9.3 "Retry"

1:1 messages have no Retry in the web hold menu: "Send Again"/"Delete" exist only for undelivered **room** lines
(`message-menu.ts:32`; `message-bindings.ts:12-13`). A failed reply's recovery is the error card's Retry and an
uncertain send's "Delivery Unconfirmed · Check" (both M1). Regenerate is out (§11).

---

## 10. Feel, glass, haptics, accessibility (summary)

- Menus, sheets, alerts, share sheets: system UIKit only (glass on iOS 26). ☰: `UIGlassEffect` circle inside the
  composer's `UIGlassContainerEffect` (spec 06 §4.3, §8). No custom blur/tint anywhere.
- Haptics: ⋯ picks selection; star selection; copy success; failures error (alert); command picks none; model picks
  none beyond the menu's own.
- Dynamic Type: every label uses text styles; command and model rows wrap; the bar's title items cap per spec 06.
- VoiceOver: ☰ "Commands"; stars "Favorite <name>" + selected; skeletons announce "Loading Models"/"Loading Commands";
  notices are announced (`ChatNoticeToast` already posts announcements); slash output rows read "<command>, <output>".
- Reduce Motion: sheet detent changes without animation.
- Dark mode: system colours only; check every new surface in both (`MEM/liquid-glass.md`: sweep sibling surfaces).

---

## 11. Left out of this round, and why

| Item (web has it) | Why not now | Where it goes |
|---|---|---|
| ⋯ Find (tile) | needs find-in-chat (search bar over the transcript, hit highlighting) | Find stream |
| ⋯ Pin, Mark Unread/Read, Archive, Delete | bot chats write `ui_meta` pins; unread is the device-local model of spec 02 §6.7; archive/delete leave the chat | bot/session writes stream (slots fixed in §4.1) |
| ⋯ Read Replies Aloud; hold-menu Read Aloud | TTS | voice stream |
| ⋯ More ▸ Files, Changes, Branch in New Chat, Export Chat | file browser/diff panes; `session.branch` + navigation; Export would be a lone row in More | later |
| ⋯ Watch Browser | Bot Screen | Bot Screen stream |
| Bot Info (⋯ Info for bot chats) and its **New Chat** | separate page with many writes | Bot Info stream (§4.7) |
| Hold menu: Regenerate, Edit, Rewind to Here | truncating resubmit: `prompt.submit` `truncate_before_*` + `confirm_truncate`, survivor row-id rebinding, `4018/4004/4029/4030` (`V/app/session/hooks/use-prompt-actions/rewind.ts:267-340`) — a send-area change | send round |
| Hold menu: Branch in New Chat, React…, Show/Hide Steps, room Reply/Mention/Screen/Send Again/Delete | branch flow; reactions opt-in; tool-call Hide/In Header styles not built; rooms not built | later |
| Slash: `/new`, `/branch`, `/compress`, `/btw`, `/bg`, `/resume`, `/profile`, `/skin`, `/wake`, `/handoff`, `/browser`, `/journey`, `/pet`, `/hatch` | each is a desktop action with its own RPC flow, progress events (`btw.complete`, `background.complete`, compress notices) or a desktop overlay; hiding beats a dead row (`MEM/glitch-sweep.md`) | per feature |
| Chat error banner "Choose a model" | part of the open/start-failure UI (`S/phone-chat-menu.tsx:301-328`) | errors stream (calls `presentModelSheet`) |
| Provider-grouped Favourites (`favorite-model-groups.ts`) | iPad's vendored menu only | iPad |
| Info: Answered by / Context / Tokens / Cost rows | needs `session.usage` and fallback attribution | later |
| Shared-metrics `shared_metrics.slash_command` ping the web sends per typed command (`slash.ts:1301-1307`) | telemetry, not behaviour | not planned |

---

## 12. Stand-in gateways

### 12.1 What the existing fixtures do for these calls (captured 2026-10-10 on port 9729, then stopped)

The build47/performance family (`FX/action-voice-fixture-gateway.py:40-84`) answers `model.options` with one model
(`fixture-model`), `commands.catalog` with `{"commands":[]}` (wrong type: `commands` should be an object — native must
not crash on it), and **every other method with `{}`** (`config.set`, `session.title`, `slash.exec` included); its socket
loop maps any exception to `-32001` (`FX/build47-fixture-gateway.py:166-168`), so no Hermes error code can be produced,
and the Sessions sidebar is empty (`action-voice:162`). The demo gateway (spec 05 §A8) has a 4-section catalog without
`commands` metadata and one model. **None can exercise this spec**, so the builder adds one fixture.

### 12.2 New fixture: `NAT/scripts/fixtures/menus-gateway.py`

Built on the performance fixture without copying it (a prototype of exactly this structure ran on 9729 on 2026-10-10:
strict-params `4000`, coded errors and the state endpoint all worked):

```python
REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238')) / 'scripts'
spec = importlib.util.spec_from_file_location('perf', REF / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(spec); spec.loader.exec_module(perf)   # __main__ guard: does not start
b47 = perf.base            # build47 module; its websocket() looks up rpc() in these globals at call time
class Fault(Exception):    # code-carrying error → {"error":{"code","message","data"?}}
    def __init__(self, code, message, data=None): ...
_prev_rpc = b47.rpc;      b47.rpc = menus_rpc            # wraps, falls through to _prev_rpc
b47.resumed = menus_resumed                               # info.{model,provider,reasoning_effort,fast,yolo} from MODEL_STATE
b47.voice.auth.websocket = menus_websocket                # build47's loop + `except Fault` before `except ValueError`
_prev_handler = b47.handler; b47.handler = menus_handler  # adds REST + /__menus/* (subclass of the previous handler)
if __name__ == '__main__': b47.main()                     # same flags: --port --credentials --keep-credentials
```

Behaviour (all state in memory; credentials 0600 via build47's `main`, username `build47-fixture`):

1. **Strict params** for every method in this spec, with Hermes' wording `invalid params for <m>: <key>: Extra inputs
   are not permitted — the client and the Hermes backend are out of sync (different versions); run `hermes update`
   and restart both` (`4000`). Allowed sets = §3 (and `prompt.submit` = `PromptSubmitParams`,
   `H/tui_gateway/contracts/prompt_voice.py:26-48`). Record every call in `STATE['calls']`.
2. **`MODEL_STATE`**: `default` → `claude-sonnet-5`/`anthropic`, `ivy` → `gpt-5.5`/`openai-codex`; effort `""`, fast
   false, yolo false.
3. **`model.options`**: three providers — `anthropic` ("Anthropic": `claude-sonnet-5`, `claude-opus-4-5-20251101`,
   `claude-haiku-4-5`; caps sonnet fast+reasoning+can-disable, haiku `reasoning:false`), `openai-codex` ("ChatGPT or
   Codex Subscription (Experimental)", aliases `["codex"]`: `gpt-5.5`, `gpt-5.5-fast`, `gpt-5.5-mini`, `openai/gpt-5.5-mini`
   (a display-name twin); caps gpt-5.5 `can_disable_reasoning:false`), `openrouter` ("OpenRouter": 30 ids incl.
   `deepseek/deepseek-v4.1-flash`, `moonshotai/kimi-k2-thinking`, `qwen/qwen2.5-coder:14b`, `broken-model`); `model`/
   `provider` = the session's state. `refresh:true` bumps `STATE['optionsRefreshes']`.
4. **`config.set key=model`** (§3.2 semantics): `broken-model` → `5001 "Model switch to broken-model failed (fixture
   provider refused); staying on <current>."`; `claude-opus-4-5-20251101` without `confirm_expensive_model` →
   `confirm_required` with message `"Opus 4.5 costs about 5× more per token than Sonnet 5.\n\nSwitch anyway?"`; a turn
   running for that profile (`b47.RUNNING`) → `deferred:true`, stash, `session.info` shows the pick, applied when the next
   `prompt.submit` for the profile starts; else apply, emit `session.info` (full info incl. `running`), append the
   `model_switch` user row to `b47.MESSAGES[profile]` (role user, `display_kind:"model_switch"`, the §3.2 marker text).
   Missing/empty value → `4002`. Mode `oldGateway` (below): while running answer `4009 "session busy — finish or stop
   the current turn before switching models"` instead of deferring.
5. **`config.set` reasoning/fast/yolo** per §3.3 (fast on `claude-haiku-4-5` → `4002 "fast mode is not available for
   this model"`); emit `session.info`. **`config.get key=reasoning`** → `{"value": effort or "medium", "display":"hide"}`.
6. **`commands.catalog`** — the test catalog in §12.5, fixed.
7. **`slash.exec`** — outputs: `usage` → `"Usage: 12 calls · 48,210 in / 3,904 out · 52,114 total\nContext: 31% of
   200K tokens"`, then (tester batch 3) a blank line and the chat provider's account block as Hermes words it
   (OpenRouter's `Credits balance: $12.34`, mode `routerBalance`; Codex's `$5.00`), and with mode `balances` the Nous
   credits block (`Total usable: $7.50`); mode `usageFail` → `5030`; `version` → `"Hermes Agent v0.9.0 (fixture)"`;
   `whoami` → `"admin (fixture)"`; `agents` → `"No active agents."`; `bundles` → `"No skill bundles."`; bare `title` →
   `"Title: <current>"`; `retry` → `{"type":"send","message":"<last user text>"}`; `undo` → `{"type":"prefill",
   "message":"<last user text>"}`; `plan <t>` → `{"type":"send","message":"[plan] <t>","display":"/plan <t>"}`; `goal
   <t>` → `{"type":"send","message":"<t>","notice":"⊙ Goal set: <t>"}`; skills (`release-notes`, `gif-search`) → `4018
   "skill command: use command.dispatch for /<name>"`; `fail` → `5030 "slash worker crashed (fixture)"`; anything else →
   `{"output":"(no output)"}`. Mode `slowExec` adds that many seconds.
   **`billing.state`** (tester batch 3; params `{profile}`): signed out, or with mode `balances` signed in with
   `usage.total_spendable_display` `$7.50` and an account balance (`balance_display`) of `$3.40`;
   mode `billingFail` → Hermes' fail-open `error` answer. `balances` also adds a signed-in Nous Portal and DeepSeek to
   the catalog; `routerQuota` gives OpenRouter's key a spending limit (an "API key quota" window, 25% used, in the
   catalog and in /usage). `POST /__menus/model {profile, model, provider}` sets a bot chat's model before it opens.
8. **`command.dispatch`** — `release-notes` → `{"type":"skill","name":"release-notes","message":"[IMPORTANT: The user
   has invoked the \"release-notes\" skill. The full skill content is loaded below.]\n\n…\n\nThe user has provided the
   following instruction alongside the skill invocation: <arg>\n\n[Runtime note: fixture]","display":"/release-notes
   <arg>"}`; `gif-search` → the same shape **without `display`** (exercises `skillInvocationText`); `fail` → `5001 "not a
   quick/plugin/bundle/skill command: fail"`; others → `4018 "not a quick/plugin/bundle/skill command: <name>"`.
9. **`session.status`** → `{"output":"Session 5cc537d1 · idle · claude-sonnet-5"}`; **`session.save`** → `{"file":
   "/fixture/sessions/<stored>.json"}`; **`process.stop`** → `{"killed":0}`; mode `oldGateway` → `session.status` /
   `session.save` answer `-32601 "unknown method: session.status — …"`.
10. **A third chat that is not a bot chat** (for Rename): stored id `20261005_090000_menus001`, runtime =
    `sha256(stored)[:8]`, title "Trip planning", profile `default`, 6 text rows. Served by `session.resume`/`activate`
    (its own ids; info = default's `MODEL_STATE`), `GET /api/sessions/<it>/messages` (paging like the performance
    handler), and `GET /api/profiles/sessions/sidebar` (`recents.sessions` = this row only; spec 02 §9.1 shape). Sends
    in it land in bot `default`'s transcript (build47's `owner()`), acceptable here.
11. **`session.title`** (§3.8 rules: empty → `4021`; title `"Taken"` → `4022 "Title 'Taken' is already in use"`); updates
    the row title and emits `session.info`. **`PATCH /api/sessions/<id>`** → `{"ok":true,"title":…}` (404 unknown id,
    400 for "Taken"); records the request (path, query, body) in `STATE['rest']`.
12. Controls (no auth, loopback): `GET /__menus/state` → `{calls, rest, modelState, titles, optionsRefreshes}`;
    `POST /__menus/mode {"staleRuntime":n, "optionsFail":bool, "optionsDelay":s, "catalogFail":bool, "slowExec":s,
    "oldGateway":bool}` (`staleRuntime:n` → the next n session-scoped calls answer `4001 "session not found"`);
    `POST /__menus/reset`. Existing `POST /__fixture/plan` / `/__fixture/finish` keep working (a long plan holds a turn
    running for the deferred-switch tests).

### 12.3 Start / stop (this stream's ports: 9729–9731)

```sh
cd /Users/me/Projects/hermes-hq-native
mkdir -p build/fixtures && chmod 700 build/fixtures
lsof -nP -iTCP:9729 -sTCP:LISTEN && { echo "9729 busy"; exit 1; }
python3 scripts/fixtures/menus-gateway.py --port 9729 --credentials build/fixtures/menus.json > build/fixtures/menus.log 2>&1 &
echo $! > build/fixtures/menus.pid
# hold a turn running (deferred switch, busy slash send):
curl -s -X POST http://127.0.0.1:9729/__fixture/plan -H 'Content-Type: application/json' \
  -d '{"plans":[{"chunks":["word "],"chunkDelay":0.5}]}'
curl -s http://127.0.0.1:9729/__menus/state | python3 -m json.tool | head -40
kill $(cat build/fixtures/menus.pid)            # stop only the one you started
```

- **9730** — a second menus instance in old-gateway mode for the compat checks:
  `python3 scripts/fixtures/menus-gateway.py --port 9730 --credentials build/fixtures/menus-old.json &` then
  `curl -s -X POST http://127.0.0.1:9730/__menus/mode -d '{"oldGateway":true}'`.
- **9731** — optional, the demo gateway (rich bot list, a 4-section catalog **without** `commands` metadata, one
  model), run in place (spec 05 §A8): `DEMO_FILES=$PWD/build/fixtures/demo-files DEMO_TOOL_SECONDS=1 python3
  /Users/me/Projects/hermes-ios-release178/.build/demo/demo-gateway.py --port 9731 --credentials
  build/fixtures/demo.json`. Use it to see the sheet and menu on realistic bots and to prove a catalog without metadata
  still lists and picks (its rows have no `argument_mode`, so most send).
- Never contact the owner's gateway; never restart a fixture in a loop (each restart ends the sim's sign-in).
- An e2e wrapper `NAT/scripts/e2e-menus.sh` = `scripts/e2e.sh` with this fixture, default port 9729, scheme
  `HermesHQNativeUI`, `-only-testing:HermesHQNativeUITests/MenusTests` (`NAT/scripts/e2e.sh:1-50` is the pattern).

### 12.4 Which fixture exercises what

| Piece | Fixture |
|---|---|
| Model menu, More Models…, favourites, recents, presets, confirm, failure, offline | menus 9729 |
| Deferred switch (running turn) | menus 9729 + `/__fixture/plan` |
| Old-gateway `4009` switch, `-32601` rpc → exec fallback | menus 9730 (`oldGateway`) |
| Stale runtime `4001` → resume + resend once | menus 9729 `staleRuntime` |
| Commands sheet sections, search, skills ranking, send/insert | menus 9729 |
| Dispatcher: exec output, send/prefill/skill directives, 4018 → dispatch, errors | menus 9729 |
| Rename (RPC and REST fallback) | menus 9729 (Trip planning chat; `staleRuntime` / disconnect for the REST path) |
| Share whole chat (paging) | menus 9729 after `POST /__fixture/history {"profile":"default","count":1200}` |
| Hold menus | any (menus 9729) |
| Realistic look; catalog without metadata | demo 9731 |

### 12.5 The fixture's catalog and the expected sheet

`categories` (each pair `[command, description]`, descriptions as Hermes builds them with the usage suffix):

| Category | Commands (registry `argument_mode`, `desktop`) |
|---|---|
| Session | `/new` (text) · `/retry` (null) · `/title` (text) · `/compress` (text) · `/stop` (null) · `/status` (null) · `/plan` (text) · `/goal` (mixed) · `/undo` (text) · `/queue` (mixed) · `/agents` (null) · `/resume` (mixed) |
| Configuration | `/model` (null, `hidden`) · `/reasoning` (options) · `/yolo` (null) · `/personality` (options) · `/fast` (options, `advanced`) · `/voice` (options, `composer-voice`) · `/config` (null, `terminal`) |
| Info | `/usage` (text) · `/help` (text) · `/version` (null) · `/whoami` (null) · `/debug` (text) |
| Tools & Skills | `/tools` (options) · `/bundles` (null) |

`pairs` = all of the above plus skills `/release-notes`, `/gif-search`, `/changelog`; `skills` = `{"/release-notes":
{"usage":5,"origin":"local"}, "/gif-search":{"usage":2,"origin":"hub"}, "/changelog":{"usage":0,"origin":"bundled"}}`;
`commands` holds every registry entry's `{argument_mode, desktop}`; `canon` lower-case → canonical (plus
`"/reset":"/new"`, `"/q":"/queue"`).

Expected sheet (rows in order; S = send, I = insert):

- **Session:** /new I · /retry S · /title I · /compress I · /stop S · /status S · /plan I · /goal I · /undo I · /queue I · /agents S
  (/resume: native-unsupported; /new and /compress built 2026-10-27)
- **Configuration:** /reasoning I · /yolo S · /personality I (/model hidden; /fast, /voice, /config unavailable)
- **Info:** /usage I · /version S · /whoami S (/debug phone-hidden; /help not listed, §7.2 review round 2)
- **Tools & Skills:** /tools I · /bundles S
- **Skills:** /release-notes I · /gif-search I (/changelog pruned: bundled, never used)

Descriptions shown (computed from the web functions): /retry "Retry the last message (resend to agent)" · /title
"Rename the current session" · /stop "Stop the active turn and background processes" · /status "Show current session
status" · /plan "Write a markdown implementation plan to .hermes/plans/ without executing anything" · /goal "Set a
standing goal Hermes works on across turns until achieved" · /undo "Go back and re-prompt" · /queue "Queue a prompt for
the next turn" · /agents "Show active agents and running tasks" · /reasoning "Reasoning effort, or show or hide the
reasoning" · /yolo "Toggle YOLO — auto-approve dangerous commands" · /personality "Set a predefined personality" ·
/usage "Token usage and rate limits" · /help "Show the commands list" (⚑) · /version "Show Hermes Agent version" ·
/whoami "Show your slash command access (admin / user)" · /tools "Turn tools on or off" · /bundles "List skill bundles"
· skills: their catalog text.

---

## 13. Native implementation plan

### 13.1 Files

| File | Holds |
|---|---|
| `HermesKit/Model/ModelNames.swift` | §2.2 pure functions |
| `HermesKit/Store/ModelPrefs.swift` | favourites, recents, presets per account (§2.3) |
| `HermesKit/Chat/ModelCatalog.swift` | `ModelOptions` decode, provider matching, capabilities, 30 s cache, `sections(query:current:)` (§6) |
| `HermesKit/Chat/ModelMenuModel.swift` | the quick-list builder as plain data (`[MenuNode]`-like structs), unit-testable like `title-menu.test.ts` |
| `HermesKit/Chat/ModelSwitcher.swift` | §5 (pending map app-wide by runtime id; injected `confirm`, `fail`, `notice`) |
| `HermesKit/Chat/SlashCatalog.swift` | catalog decode, resolution, filters, sections, `pickAction`, descriptions (incl. the copied `commandDescs` table) |
| `HermesKit/Chat/SlashRunner.swift` | §8 dispatcher (RPCs, directives, output rows) |
| `HermesKit/Chat/TranscriptText.swift` | §4.4 text + whole-chat fetch |
| `App/Chat/Menus/ChatMoreMenu.swift` | ⋯ provider (§4) |
| `App/Chat/Menus/ModelSheetViewController.swift`, `CommandsSheetViewController.swift`, `SelectTextViewController.swift`, `MessageMenus.swift` | §6, §7, §9 |
| `UITests/MenusTests.swift`, `scripts/fixtures/menus-gateway.py`, `scripts/e2e-menus.sh` | §12, §14 |

### 13.2 Changes to existing code

- `LiveChatSession`: `modelState` (§2.1); `send(_:display:)`; `QueuedMessage.display`; local slash output rows kept
  across merges; `title` settable for rename; `isBotChat`; `profileParam` exposed to the helpers.
- `ChatViewController`: menu provider instead of `moreMenu`; slash routing in `send`; `presentModelSheet(query:)`;
  `presentCommandsSheet()`; `ChatNoticeToast.show(_:duration:spinner:)` and a "Copied" HUD style.
- `ComposerView`: ☰ button + `onCommands` callback; `insertCommand(_:)` (prefix + caret + focus).
- `ChatBubbleCell` hold menu (`ChatCells.swift:242-250`) → §9 items; it needs the message kind, streaming flag, the
  whole message's text, the menu title and a delegate for Share/Select Text.
- `ChatInfoSheet` Model/Reasoning rows (§4.3); `ChatTranscriptText` replaced (§4.4); `SessionStore.applyTitle(id:title:)`.

### 13.3 Proposed contract additions (integration applies them to `HermesKit/Contracts.swift`)

```swift
nonisolated struct ChatModelState: Hashable, Sendable { … }                 // §2.1

/// Model, Reasoning and Fast for the open chat (spec 1x §4.6, §5). The live session adopts it.
protocol ChatModelControlling: AnyObject {
    var modelState: ChatModelState { get }
    var runtimeSessionId: String? { get }
    var profileParam: String? { get }
    var client: any GatewayClient { get }
}

/// Runs a sent "/command" through the slash dispatcher instead of prompt.submit (spec 1x §8).
protocol ChatSlashRunning: AnyObject {
    func runSlash(_ text: String)
    /// A `prefill` directive's text for the composer (replaces the draft) — set by the chat screen.
    var onPrefill: ((String) -> Void)? { get set }
}

/// Rename and Share for the ⋯ (spec 1x §4.4–4.5).
protocol ChatSessionActions: AnyObject {
    var isBotChat: Bool { get }
    func rename(to title: String) async throws
    func transcriptText() async throws -> String
}
```

---

## 14. Acceptance checks (the builder must pass all)

### 14.1 Unit (Swift Testing, no network)

1. §2.2 vectors (every row of the table, plus `plainProviderName`, `effortLabel`).
2. Quick list (port of `S/ui-chat/title-menu.test.ts:34-90`): order `[current ✓, favs ≤5, recents ≤2, More Models…]`;
   recents capped at two, duplicates and current removed; subtitle only for other providers; Reasoning with Off first,
   single selection, subtitle = label; no Off when `can_disable_reasoning == false`; no Reasoning when
   `reasoning == false`; Fast present only per §4.6 rule 6; offline disables every row with "Offline".
3. Favourites before a catalog: keys `["openrouter::moonshotai/kimi-k2-thinking"]` → a row "Kimi K2 Thinking" with
   subtitle "openrouter" (providerDisplayName falls back to the slug); recents hidden without a catalog.
4. Stores: toggling appends in order and removes; recents newest-first, max 3, dedupe by id+provider; per-account
   isolation (two account ids don't see each other's stars).
5. `modelSections`: provider order kept; twin `openai/gpt-5.5-mini` dropped beside `gpt-5.5-mini`, unless it is current
   (then it takes the slot); search "kimi think" finds one row; "zzz" finds none.
6. `switchModel` against a fake client: params exactly `{key,session_id,value,profile}`; `moa` adds ` --session`;
   `-fast` sibling chosen when the preset says fast; confirm path resends with `confirm_expensive_model:true` only
   after "Change Model"; Cancel leaves state untouched; `deferred` keeps the paint; `4009` busy-switch treated as
   deferred; `5001` rolls back and reports; a second pick while pending returns false and sends nothing; `4001` →
   one resume + one resend; `session.info` with the old model during the call doesn't repaint.
7. Commands: the §12.5 catalog → exactly the expected sheet (sections, order, S/I, descriptions); `slashDescription`
   vectors of §7.2; search "usage", "/new" (its row), "/branch" (none: native-unsupported), "nothing like it".
8. Slash regex/parse: `/usage` ✓, `/plan a\n b` ✓ (arg keeps the inner newline), `/usr/local` ✗, `run /x` ✗, `/` ✓ empty
   name, `/ words` ✓ empty name.
9. Dispatcher with a fake client: each row of §8.2 and every directive branch of §8.3, exact output strings
   (`renderRpcResult` vectors: `{killed:0}` → "No background processes to stop.", `{killed:1}` → "Stopped 1 background
   process.", `{file:"/x"}` → "Saved transcript to /x").
10. `transcriptText` web vector (with "Hermes" as the bot name) and a bot-named variant; system and slash rows excluded.
11. `readableText` vector (§9.2).

### 14.2 Wire (against menus 9729; read `/__menus/state`)

12. No call in this spec ever answers `4000` (the fixture is strict): exercise every flow, then assert no `4000` in the
    app log and every recorded `params` key set ⊆ §3's.
13. Every session-scoped call carries `profile`; REST rename carries `?profile=` and `"profile"` in the body.
14. Opening ⋯ twice: no `model.options` before the first open; exactly one background `model.options` after it (§3.1
    warm-up); none on later opens within 30 s.

### 14.3 UI (XCUITest `MenusTests`, sim "HQ Native", signed in to 9729)

15. ⋯ shows tiles Share + Info, then Model with subtitle "Sonnet 5", then (Trip planning chat only) Rename…; a bot chat
    has no Rename.
16. ⋯ › Model › More Models… → sheet "Models" (medium), current row checked, Anthropic section first; star "GPT-5.5" →
    a Favorites section appears at the top and the starred row did not move on screen (frame minY equal ±1 pt); reopen ⋯ ›
    Model → GPT-5.5 listed under the current one with subtitle "ChatGPT or Codex Subscription".
17. Pick GPT-5.5 → notice "Switching to GPT-5.5…" then "Model changed to GPT-5.5."; ⋯ › Model subtitle starts with
    "GPT-5.5"; `__menus/state.modelState.default.model == "gpt-5.5"`; the transcript gains the "model changed" notice
    after the next history read; reopening ⋯ shows Sonnet 5 under Recents.
18. Pick Opus 4.5 → alert "Change Model?" with the fixture text; Cancel → nothing sent twice, model unchanged; again →
    "Change Model" → switched.
19. Pick broken-model (search "broken") → alert "Couldn't Change Model" with the fixture reason; model unchanged.
20. With a turn running (plan with `chunkDelay 0.5`): pick Haiku 4.5 → notice "Haiku 4.5 will be used for your next
    message."; Reasoning hidden for Haiku after the switch applies.
21. Reasoning ▸ High → `config.set reasoning high` recorded, subtitle "… · High"; Fast on Sonnet → `config.set fast fast`.
22. Airplane-equivalent (stop the fixture): ⋯ › Model rows disabled with "Offline"; Rename disabled; stars still toggle
    in the sheet (when cached); restart the fixture and sign in once.
23. ☰ → "Commands" sheet; the field keeps its draft and the keyboard went down; sections and rows as §12.5; search
    "usage" → one row.
24. Tap /status (send) → sheet closes, draft untouched, a row "/status · Session 5cc537d1 · idle · claude-sonnet-5"
    appears (first as "Running…" when `slowExec` is set), no user bubble.
25. Tap /title (insert) → field reads "/title " + the old draft, caret after the space, keyboard up.
26. Type "/usage" and send → multi-line output row, left-aligned; type "/release-notes v2" → a user bubble "/release-notes
    v2" and a streaming reply; "/gif-search cats" → bubble "/gif-search cats"; "/undo" → the last message is back in
    the field; "/branch" → "/branch isn't available in HQ Native yet."; "/new" → a new chat with the bot opens; "/config" → "/config is only available in the terminal
    interface."; "/yolo" → "YOLO on for this session".
27. While a reply streams, "/status" runs at once (not queued); "/plan x" queues with "session busy — message queued…".
28. Trip planning chat → ⋯ › Rename… → alert prefilled "Trip planning", Save disabled until changed → "Trip to Lisbon"
    → bar title and Sessions row update at once; `session.title` recorded. With `staleRuntime` > 1 the REST PATCH is
    recorded instead and the title still sticks. "Taken" → "Couldn't Rename Chat" with Try Again, title rolled back.
29. Bot chat with 1,200 seeded rows → ⋯ › Share → "Preparing transcript…" then the share sheet; recorded REST pages use
    `order=oldest&limit=500` with offsets 0, 500, 1000; the shared text starts with the title line and contains the
    first seeded row.
30. Hold a reply → tiles Copy, Share and a Select Text row, menu title "Hermes · <time>"; Copy → pasteboard holds the
    Markdown, HUD "Copied"; Select Text → sheet with readable text and Copy All. Hold your bubble → Copy + Select Text
    only. Hold a streaming reply → Share disabled with "Still Replying".
31. Old gateway (9730): deferred pick while running answers 4009 → shown as "will be used for your next message";
    `/status` falls back to `slash.exec` and still prints output.

### 14.4 Feel (owner-facing, before shipping)

32. ⋯ opens instantly (no network wait) in a cold chat; More Models… shows rows from cache instantly on the second open.
33. Light, dark, AX3: sheets, rows (12 pt padding on wrapping rows), ☰ glass circle matching + / field; no clipped
    text; screenshots of each new surface in both appearances attached to the build note.
34. Nothing in the chat's top bar changed (Back · head + name · ⋯), per `MEM/chat-status-line.md:23`.

---

## 15. UNKNOWNs, DECISIONs and disagreements

1. **⚑ DECISION** Fast closes the menu (web keeps it open) — UIKit bar menus can't redraw an open row (§4.6.9).
2. **⚑ DECISION** background `model.options` warm-up on the first ⋯ open (§3.1).
3. **⚑ DECISION** `session.info` model/provider ignored while this phone's switch is in flight (§2.1.3).
4. **⚑ DECISION** "Running…" placeholder for slash output (§8.4).
5. **⚑ DECISION** `/help` opens the Commands sheet; its description "Show the commands list" (§7.2, §8.2).
6. **⚑ DECISION** fourteen desktop-only slash actions hidden and answered "isn't available in HQ Native yet" (§8.2).
7. **⚑ DECISION** transcript speaker = bot's name, not always "Hermes"; Info Reasoning uses `effortLabel`;
   too-long share message in plain words (§4.3, §4.4).
8. **Resolved (review round 2)** the profile's configured default reasoning effort (`$defaultReasoningEffort`): read
   once per account and profile with `config.get {key:"reasoning", profile}` and **no** `session_id` (the getter then
   answers config.yaml's `agent.reasoning_effort`, `H/tui_gateway/methods_config.py:206-225`), cached next to the
   catalog (fresh 5 min; the ⋯ warm-up reads it). A switch to a model with no saved preset sends
   `preset.effort ?? profileDefault`; when the default can't be read the switch sends **no** reasoning write (never
   Hermes' medium over the owner's config). The Reasoning check mark falls back to it the same way.
9. **UNKNOWN** a real gateway's `model.options` payload for the owner's providers was not captured (the owner's gateway is
   off limits); the fixture follows the contract. Check the sheet once on the owner's phone (read-only).
10. **Risk** `/stop` from the sheet is one tap and calls `process.stop`, which kills **every** background process on the
    gateway (`kill_all`, `H/tui_gateway/methods_tools.py:265`) — same as the web. Its description says so. Revisit if
    the owner's bots run long background jobs.
11. **Risk** `/yolo` is one tap and turns off approvals for the session while native can't show approval prompts yet;
    same as the web.
12. Native lists commands only after the catalog answers (no offline registry copy). A typed command before any catalog
    resolves with the local table only; registry commands then go to `slash.exec`, which applies the gateway's own
    rules — acceptable, but unavailable-reason wording only appears once a catalog was cached.
13. Spec 06 §11 lists "the commands sheet's contents, the model menu" as out of M1 scope; this spec supersedes that line
    for this round. Spec 06 §4.1 "⋯ … holds a "Model" submenu (later milestone)" is now this spec's §4.6.
