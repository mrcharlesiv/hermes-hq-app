# 03 — Opening a chat and its history

Spec for the native (Swift) rebuild of Hermes HQ. Describes what the web client (release-build238) does today when a
chat is opened: the history reads, the message model, the caches that make reopen instant, how tool calls are drawn,
markdown/code rules and what one turn looks like. Streaming events, sending, approvals and the socket itself are
specified elsewhere; they appear here only where the open path depends on them.

**Citation roots** (every `file:line` below is relative to one of these):

| Prefix | Path |
|---|---|
| `R:` | `/Users/me/Projects/hermes-hq-native-ref238` (web app, read-only reference) |
| `V:` | `R:vendor/hermes/apps/desktop/src` (the pinned Hermes desktop renderer the web app runs, upstream commit `02e41181`, `R:vendor/source.json:2`) |
| `H:` | `/Users/me/.hermes/hermes-agent` (Hermes agent/gateway source, commit `d94b70f6`; READ ONLY) |
| `P:` | `R:gateway-plugin/hermes-hq-performance` (our optional gateway plugin) |

The web app is the vendored renderer plus ~150 build-time text patches ("gates", `R:build/*-gates.ts`, applied in the
order listed in `R:build/renderer-gates.ts:315-403`). Where a gate changes vendor behaviour, the gate wins and is
cited. Later gates override earlier ones (e.g. `historyWindowGates` at `R:build/renderer-gates.ts:348` replaces the
`expandWindow` that `ltOpenGates` at `:330` had patched).

---

## 0. TL;DR for the native build (recommended flow, derived from today's behaviour)

1. **Paint from disk first.** Key: `(gatewayIdentity, connectionId="ios-direct", profile, storedSessionId)`. Paint at most
   the newest 24 backend rows' worth of cached messages (§7.2, §4.2). If the cache was saved before the chat's
   `last_active` (from the bots/sessions list), hold it up to 300 ms waiting for fresh rows before painting it (§4.3).
2. **In parallel:** `GET /api/sessions/{id}/messages?profile=P&limit=24&order=latest&include_compacted=true` (§2.1)
   and JSON-RPC `session.resume {session_id, cols:96, source:"desktop", defer_history:true, omit_messages:true, profile}`
   (§3). REST is the transcript authority; the RPC only binds the live runtime id and returns the in-flight turn.
   Native sends this **one** param set for every resume (open, 4001 recovery, pre-send rebind); never
   `inline_images` (a no-op with `omit_messages`) and never a resume without `omit_messages:true` (§3.1).
3. **Convert rows → messages** with the hydration fold (§6): one `ChatMessage` per user row, one per assistant *turn*
   (tool calls + results + prose folded together), ids `stored-row-{id}-{kind}`.
4. **Replace the cached paint wholesale** with the fresh page (it is never merged into a provisional paint); then graft
   the RPC's `inflight` turn after it; save the result back to disk (web: newest 40 messages, ≤64 KB; native M1:
   newest 40 messages, ≤256 KiB, 64 chats / 16 MiB, image bytes never in the entry — §7.2.1).
5. **After the open settles:** fetch the rest of the first 120 rows in the background (`limit = 120-24+1`,
   `offset = 23`, `order=latest`) and prepend everything older than the first page's oldest row (§5.2).
6. **Scrolling past what's in memory** switches to *history page* mode: replace (not append) with one 120-row
   `order=oldest` page; "Show newer" / "Return to latest" navigate (§5.3).
7. **Refreshes of an open chat** (on `sessions.changed`, reconnect, turn end) first probe the newest row (`limit=1`); read
   24 rows only when it changed; read 120 only when those 24 don't overlap what's on screen (§7.6). `sessions.changed`
   carries `{}` and `session_id:""`, so it says nothing about *which* chat moved: throttle it to one open-chat pass per
   10 s (none while the chat's own turn runs, the chat is off screen or the app is backgrounded) and one Sessions-list
   pass per 10 s on screen / 45 s off it (§7.7). The Bots roster is not refreshed by it.
8. If the gateway advertises the `hermes-hq-performance` plugin in `gateway.ready.performance`, send the same reads to
   `/api/plugins/hermes-hq-performance/sessions/{id}/messages` with `projection=display.v1&max_bytes=65536&tool_refs=content.v1`
   and honour `has_more/next_offset/next_cursor` (§2.3). Fall back once to the core route on 400/404/422.
9. **Images in history** are never decoded on the main thread and never stored in the transcript cache: `@image:` refs
   load lazily over `GET /api/fs/download`, inline `data:` parts are decoded off-main into a media cache (§6.6).
10. **Tool calls:** run tools fold into one quiet row per run; card tools (file edits, clarify, delegate, image
   generation, consent tools) draw their own block in place (§8.9); silent tools draw nothing unless they failed (§8.10).
11. **Markdown:** the M1 subset on swift-markdown (cmark-gfm) is fixed in §9.5, including single newline = line break.

---

## 1. Identifiers

| Name | What | Example | Source |
|---|---|---|---|
| stored session id | Durable `sessions.id` in the profile's `state.db`. What lists and REST use. | `20260929_120000_aabbcc01` | `R:scripts/action-voice-fixture-gateway.py:16` |
| runtime session id | Live gateway session minted by `session.resume`; used by RPCs/events. | `sha256(stored)[:8]` in fixtures | `R:scripts/action-voice-fixture-gateway.py:28` |
| row id | Durable `messages.id` (INTEGER AUTOINCREMENT). Unique within one profile DB. REST names it `id`; the gateway RPC projection names it `row_id`. Clients must read both. | `2` | `V:types/hermes.ts:705-714`, `V:lib/chat-messages/hydration.ts:447` |
| profile | Owning Hermes profile; every session read is routed by it (`?profile=`). | `default`, `ivy` | `H:hermes_cli/web_routers/sessions.py:147-150` |

The REST route resolves the given id with `resolve_resume_session_id` (follows the compression chain to the live tip,
then the deepest continuation with messages), so the response's `session_id` may differ from the requested one
(`H:hermes_cli/web_routers/sessions.py:735`, `H:hermes_state_messages.py:1471-1508`). The client records tail state under
both ids (`V:api/sessions.ts:549-556`, `R:src/open-page.ts:76-77`).

---

## 2. REST history endpoints

All requests go through the native HTTP client to the gateway's dashboard web server (the same base URL as `/api/ws`;
e.g. `http://100.101.102.104:9119` in `R:scripts/gateway-replay.py:73`). Auth (cookie session or Nous bearer) is specified
in the connection spec; the history reads add nothing of their own. Default request timeout 30 s
(`R:ios/App/App/HermesNative.swift:2474`); response cap 32 MiB for any `/api/` path except auth/ws-ticket (1 MiB)
(`R:ios/App/Shared/HermesTransportShared.swift:34-37`). A path must start with `/api/`, not `/api/auth/`, no `\`, CR or LF
(`R:src/bridge/shim.ts:35-44`). When a request carries a routing profile and the path has no `?profile=`, the client
appends `profile=<owner>` (`R:src/bridge/shim.ts:42`).

Identical in-flight GETs are shared (one network read) and a background "lane" waits for foreground reads
(`R:src/bridge/shim.ts:153-183`); native should coalesce identical GETs and run prefetch/backfill at lower priority.

### 2.1 Core route — `GET /api/sessions/{session_id}/messages`

Server: `H:hermes_cli/web_routers/sessions.py:723-768`.

**Query parameters**

| Param | Type | Default | Meaning |
|---|---|---|---|
| `profile` | string | serving process's own | Which profile DB to read (`:724`, `:756`). |
| `limit` | int ≥0 | *omitted* | Omitted ⇒ 500 rows, newest page ("default page"). Given ⇒ `min(limit, 500)` (`:739-740`). |
| `offset` | int ≥0 | 0 | Rows skipped. With `order=latest` it counts **back from the newest row**; with `oldest`, forward from the first (`H:hermes_state_messages.py:1397`). |
| `order` | `oldest`\|`latest` | see below | Anything else ⇒ **400** `{"detail":"order must be one of: oldest, latest"}` (`:728-729`). Omitted with no `limit` ⇒ latest; omitted with a `limit` ⇒ **oldest** (`:738-739`, `:766`). The web client always sends `order` explicitly. |
| `include_compacted` | bool | `false` | Include rows preserved by in-place compaction. **The client always sends `true`**; without it the transcript silently ends at the compaction boundary (`V:api/sessions.ts:524-527`). |
| `inline_images` | bool | `true` | `false` renders image parts as `[image]` instead of `data:` URIs (`:674-681`, `:727`, `:757`). **The web client never sends it** (images arrive inline; see §12 flag F6 and §6.6 for native's too-large fallback). |

A `latest` page is still returned in **chronological order** (oldest first) (`H:hermes_state_messages.py:1397`,
`:1417`, `:1437-1438`). Ancestors of a compression chain are included (`include_ancestors=True`,
`H:hermes_cli/web_routers/sessions.py:741-747`), so rows can carry a
`session_id` different from the top-level one (an ancestor segment).

**Response 200** (`:758-767`):

```json
{
  "session_id": "<resolved stored id>",
  "profile": "<serving profile name>",
  "messages": [ /* SessionMessage rows, §2.2 */ ],
  "pagination": { "limit": 24, "offset": 0, "order": "latest", "returned": 24 }
}
```

The core route returns **no** `has_more`, `next_offset` or `total`. The client infers "more older rows may exist" from
`returned >= limit` (`V:store/transcript-tail.ts:132-155`; patched to prefer explicit `has_more/next_offset` when present,
`R:build/data-performance-gates.ts:96-104` → `R:src/history-page.ts:3-9`). A page is adopted as a *tail* only if
`pagination.order === "latest"` is echoed; an older backend that ignores `order` returns the oldest rows, and the client
then reads the complete transcript with `order=oldest` in 500-row pages instead (`V:store/transcript-tail.ts:113-129`,
`V:api/sessions.ts:579-592`, `V:api/sessions.ts:653-698`, 32,000,000-char safety cap at `:657`).

**Errors**: 404 `{"detail":"Session not found"}` (`H:hermes_cli/web_routers/sessions.py:43`, `:752`); 400 bad `order`;
503 on a corrupt DB (`:153-161`). The client surfaces non-2xx as `gatewayError(status, body)` (`R:src/bridge/shim.ts:113`).

**Display projection applied server-side** (`H:hermes_cli/web_routers/sessions.py:655-720`):
- Adds `tool_call_labels: {callId: [ToolLabel]}` for bridged `tool_call`/`tool_search`/`tool_describe` calls (`:596-620`).
- Types failed turns: an untyped failed-turn row gets `display_kind:"failed_turn"` (`:684-687`).
- `[System: …]` user rows without a kind get `display_kind:"hidden"` (`:641-652`, `:688-692`).
- Mid-turn steer rows (`display_kind:"steer"`) get `display_content` = the user's own words (`:694-696`).
- Compaction summaries: `display_content` = display projection, or `display_kind:"hidden"` (`:697-713`).
- Codex commentary: may add `display_commentary` / `display_reasoning` (`H:agent/history_commentary.py:152-176`).
- Model-only rows are never returned (`DISPLAY_VISIBLE_SQL`, `H:hermes_state_messages.py:55-58`).

### 2.2 Row shape (`SessionMessage`)

REST rows are `SELECT *` from `messages` with JSON columns decoded (`H:hermes_state_messages.py:1319-1341`; schema
`H:hermes_state_common.py:449-482`). `display_identity` and `display_order` are dropped; `_compressed_summary` appears
only as `true`. The client type is `V:types/hermes.ts:664-721`.

| Field | Type | Notes |
|---|---|---|
| `id` | int | Durable row id (REST). RPC projection calls it `row_id` (`V:types/hermes.ts:705-714`). |
| `session_id` | string | Segment that owns the row (may be an ancestor). |
| `role` | `user`\|`assistant`\|`tool`\|`system` | |
| `content` | string \| array \| object \| null | Usually a string. Multimodal user turns are a parts list, e.g. `[{"type":"text","text":"what is this?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,…"}}]` (`H:tests/hermes_cli/test_session_messages_inline_images.py:17-21`). Tool rows: usually a JSON **string** (`{"stdout":…,"exit_code":0}`). |
| `display_content` | any | When present, replaces `content` for display (`V:lib/chat-messages/hydration.ts:419-422`). |
| `tool_calls` | array \| null | OpenAI shape: `[{"id","type":"function","function":{"name","arguments":"<JSON string>"}}]`. |
| `tool_call_id` | string \| null | On `tool` rows: the call it answers. |
| `tool_name` | string \| null | On `tool` rows. |
| `tool_call_labels` | object | Added by projection (above). |
| `reasoning`, `reasoning_content` | string \| null | Assistant thinking. `reasoning_details` (string or JSON) is the third fallback (`V:lib/chat-messages/hydration.ts:456-461`). |
| `display_reasoning` | string | Overrides the above when present (`:461`). |
| `codex_message_items`, `codex_reasoning_items`, `display_commentary` | various | Responses-API sidecars; `codex_message_items` final text is the reply when `content` is empty (`:46-107`). |
| `display_kind` | string | `hidden`, `model_switch`, `auto_continue`, `personality_switch`, `async_delegation_complete`, `process_complete`, `failed_turn`, `steer`, … (`V:types/hermes.ts:689-698`). |
| `display_metadata` | object \| JSON string | May hold `reactions`, `task_count`, `display_text`, `tool_result_metadata{inline_diff,error}`, `model` (`V:types/hermes.ts:643-655`). Older backends send it as a string — parse defensively (`V:lib/chat-messages/hydration.ts:182-194`). |
| `timestamp` | number | Unix **seconds**, REAL (fractional). Row order is by `id`, never timestamp (`H:hermes_state_messages.py:1395`). |
| `finish_reason`, `token_count`, `active`, `compacted`, `platform_message_id`, `observed`, `effect_disposition`, `message_uid`, `absorbed_message_uids`, `tool_call_uids`, `tool_call_uid`, `api_content` | various | Present on REST, unused by the display path. `api_content` is model-only (the plugin strips it, `P:history.py:199`). |

Gateway RPC projection rows (`session.resume` with messages, `session.history`) use `TranscriptMessage`: `role, text,
content, tool_call_id, timestamp, row_id, display_kind, display_metadata, name, context (80-char preview), args, labels,
reasoning` (`H:tui_gateway/contracts/common.py:158-176`). The phone does not read history through RPC (it sends
`omit_messages:true`, §3), so native only needs the REST shape.

### 2.3 Performance plugin route (optional, preferred when advertised)

The plugin (`P:`) may or may not be installed on a given gateway; the client only uses it when advertised. Its routes sit behind the dashboard's normal auth
(`P:dashboard/plugin_api.py:1`). Its README states it was "not verified against a live gateway" at the time of writing
(`P:README.md:3`) — see UNKNOWN U3.

**Advertisement.** The plugin injects into every `gateway.ready` event payload (`P:adapter.py:167-174`):

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{
  "heartbeat":true,"change_events":true,"replay_epoch":"build47","desktop_contract":8,
  "performance":{"version":1,"roster_summary":1,"history_display":1,"history_cursor":1,
                 "history_path":"hermes-hq-performance.v1","history_tool_refs":1,"history_locator":1,
                 "history_before":1,"history_tool_preview":1}}}}
```
(composed from `R:scripts/build47-fixture-gateway.py:121` and `P:adapter.py:15-16`; `media_thumbnail`/`media_waveform`
are added when their dependencies exist, `P:adapter.py:207`). The client accepts only flags equal to `1`, `version:1`,
and `history_path` matching `^(hermes-hq|dispatch)-performance\.v1$`; the route prefix is `/api/plugins/` + the name
without `.v1` (`R:src/performance-contracts.ts:18-25`, `:95`). A new `replay_epoch` clears all cursors
(`R:src/performance-contracts.ts:21`). An account change resets everything (`R:src/performance-contracts.ts:12-16`).

**Request rewrite** (applied to every `GET …/api/sessions/{id}/messages` the client makes,
`R:src/performance-contracts.ts:46-65`, called from `R:src/bridge/shim.ts:89`):
- path `/api/sessions/` → `/api/plugins/hermes-hq-performance/sessions/` when `history_path` advertised (`:57`);
- add `projection=display.v1&max_bytes=65536` when `history_display` (`:58`);
- add `tool_refs=content.v1` when `history_path` and `history_tool_refs` (`:59`);
- add `cursor=<next_cursor>` when `history_cursor`, no `before_offset`, and a cursor is known for exactly
  `(path, profile, order, include_compacted)` at this `offset` (`:52`, `:60-61`). A request with `offset=0` starts a new
  snapshot and forgets that key's cursors (`:54`). At most 64 keys × 64 cursors kept (`:55`, `:84-85`).

**Plugin request parameters** (`P:dashboard/plugin_api.py:36-70`): `profile`, `limit` 1–500 (omitted ⇒ 500 and latest),
`offset`, `order`, `include_compacted`, `projection` (must be `display.v1`), `max_bytes` 1024–1048576 (default 65536),
`cursor`, `tool_refs` (`content.v1`), `before_offset` (requires `order=oldest`, cannot combine with `cursor`,
`P:history.py:46-47`, `:162-163`). Invalid values ⇒ 400 `"Unsupported history projection or order"` or the cursor error.
Adapter not installed ⇒ 503.

**Plugin response** (`P:history.py:225-239`):

```json
{
  "session_id": "20260929_120000_aabbcc01",
  "profile": "default",
  "messages": [ /* rows as §2.2, minus api_content; large tool rows replaced, see below */ ],
  "pagination": {
    "limit": 24, "offset": 0, "order": "latest", "returned": 24,
    "has_more": true, "next_offset": 24,
    "cursor_schema": "history.cursor.v1", "next_cursor": "<base64url HMAC token, ≤4096 chars>",
    "oversize": true            /* only when one required row exceeded max_bytes */,
    "has_older": true, "has_newer": false   /* only with before_offset */,
    "legacy_offset": true        /* only on legacy/unindexed stores; no cursor */
  }
}
```

Rules:
- `has_more` and `next_offset` are authoritative: a byte-short page (fewer rows than `limit`) can still have more
  (`P:README.md` "History" section; `P:history.py:224-229`). The client uses `next_offset` for the next request
  (`R:src/history-page.ts:3-15`) and throws if it does not advance (`R:src/history-page.ts:14`).
- Byte budget: rows are admitted until `max_bytes` (estimated) would be exceeded; at least one row is always returned;
  a single row larger than the budget sets `oversize:true` (`P:history.py:106-118`, `:193-223`).
- **Tool refs:** a `tool` row whose stored content exceeds `min(16384, max_bytes/2)` bytes is returned with
  `content` = first 1500 chars + `"\n[Open details to load full tool output]"` and
  `display_payload_ref: {"schema":"tool.content.v1","row_id":<id>,"profile":"<p>","session_id":"<sid>","bytes":<n>}`; if
  the stored JSON signals failure, `display_metadata.tool_result_metadata.error = true` is added (`P:history.py:108`,
  `:203-214`, failure SQL `:131-147`).
- **Cursor failure:** a 400 on a request that carried a `cursor` raises `HistorySnapshotExpired`
  (`code:"history-snapshot-expired"`); the client never silently continues by raw offset
  (`R:src/bridge/shim.ts:101-103`, `R:src/performance-contracts.ts:66-72`). UI copy: "History changed while paging.
  Return to latest and try again." (`R:src/history-window.ts:95`).
- **Fallback:** if the optimized request returns 400/404/422 (without a cursor), the client retries the unchanged core
  path once; if that succeeds, it disables `history_display/cursor/path/tool_refs` for the account
  (`R:src/bridge/shim.ts:104-110`, `R:src/performance-contracts.ts:73-76`). Auth failures are never retried this way.

### 2.4 Plugin helper routes

| Route | Params | Response | Errors |
|---|---|---|---|
| `GET /api/plugins/hermes-hq-performance/sessions/{sid}/messages/locate` | `row_id` (≥1, req.), `profile` | `{"schema":"history.locator.v1","session_id","profile","row_id":<representative>,"offset":<count of display rows before>,"total":<n>}` | 404 "Display row not found"; 409 on legacy/unindexed store (`P:dashboard/plugin_api.py:103-129`, `P:history.py:241-261`) |
| `GET …/messages/{row_id}/content` | `profile` | `{"schema":"tool.content.v1","session_id","profile","row_id","content":<decoded original>}` | 404; 413 `{"code":"tool_content_too_large","total_bytes","limit_bytes":8388608,"message":…}` (`P:dashboard/plugin_api.py:34`, `:72-100`) |
| `GET …/messages/{row_id}/content/preview` | `profile`, `offset` (codepoints, default 0), `max_chars` 1–20000 | `{"schema":"tool.preview.v1","session_id","profile","row_id","content","offset","total_chars","has_more","next_offset":<int\|null>}` | 404; 422 `{"code":"tool_preview_unavailable","reason":"embedded_nul",…}` (`P:dashboard/plugin_api.py:146-178`) |

The client validates every field of these answers before use (`R:src/tool-content.ts:10-60`); offsets are server
Unicode codepoints, never local string lengths (`R:src/tool-content.ts:52`). Client page size `TOOL_PREVIEW_CHARS =
20000` (`R:src/tool-content.ts:44`).

### 2.5 Jump/timeline routes (core Hermes)

- `GET /api/sessions/{sid}/messages/around?row_id=N&limit=1..120&profile=` — a bounded display page **starting at** a
  user-prompt row (despite the name). Response `{session_id, profile, messages, pagination:{row_id, limit, returned,
  order:"oldest", offset, total, has_older, has_newer}}`; 404 `"Prompt not found"` (`H:hermes_cli/web_routers/sessions.py:807-826`,
  `H:hermes_state_timeline.py:133-138`). Exact ids only; no prefix matching (`:770-783`).
- `GET /api/sessions/{sid}/timeline?limit=1..500&after_row_id=0&profile=` — prompt metadata only:
  `{session_id, profile, entries:[{row_id, preview, timestamp}], pagination:{limit, after_row_id, returned, total,
  has_more, next_cursor}}` (`H:hermes_cli/web_routers/sessions.py:785-804`, `H:hermes_state_timeline.py:161-166`).

Example (replay fixture, `R:scripts/gateway-replay.py:378-381`):
```json
{"session_id":"20260101_000000_d15a7c0a","profile":"default",
 "entries":[{"row_id":1,"preview":"Do not use any tools. Reply with the single word OK. @image:/dispatch-replay-fixture/qa-image.png [screenshot]","timestamp":1767225600.0}],
 "pagination":{"limit":500,"after_row_id":0,"returned":1,"total":1,"has_more":false,"next_cursor":null}}
```

### 2.6 Session record — `GET /api/sessions/{id}?profile=P`

Read during the open to learn model/title/owner (`V:api/sessions.ts:438-453`, `V:app/session/hooks/use-session-actions/utils.ts:2074-2130`).
It can be large (~137 KB for a bot chat: system prompt and tools), so the phone starts the messages read and
`session.resume` **before** it when the owner is known (`R:src/open-prefetch.ts:3-6`, `R:build/r21-open-gates.ts` "A3").
Native should not block the open on it. Fixture shape: `R:scripts/gateway-replay.py:372-375`.

---

## 3. JSON-RPC used by the open (`/api/ws`)

Frames are JSON-RPC 2.0 over the gateway socket (`R:scripts/build47-fixture-gateway.py:96-142`). Full socket/event
semantics: see the streaming spec.

### 3.1 `session.resume` (cold open)

Params the phone sends (`V:app/session/hooks/use-session-actions/index.ts:1955-1975`, `R:build/r21-open-gates.ts`
parallel gate):

```json
{"jsonrpc":"2.0","id":7,"method":"session.resume","params":{
  "session_id":"20260929_120000_aabbcc01","cols":96,"source":"desktop",
  "defer_history":true,"omit_messages":true,"profile":"default"}}
```

- `session_id` = stored id; the reply's `session_id` is the runtime id (`H:tui_gateway/contracts/sessions.py:182-198`).
- `omit_messages:true`: "REST is the transcript authority" — the reply's `messages` is `[]` with `messages_omitted:true`
  (`V:…/use-session-actions/index.ts:1966-1973`, `H:tui_gateway/methods_session.py:634-635`, `:684-687`).
- `defer_history:true`: returns before the agent build (MCP discovery, prompt build) (`V:…/index.ts:1966-1972`).
- `profile`: the vendor path sends it whenever the session's owner profile is known (`V:…/index.ts:1974`); the
  phone's parallel open (r21 gate) always sends the owner's normalised profile (`R:build/r21-open-gates.ts:119-127`).
  Native: always send it.
- Timeout: a chat on another profile or a bot ("waking": its backend may be starting) gets 120 s and one quiet retry
  on an RPC timeout before an error is shown; the active profile's chats keep the renderer's default deadline of
  **30 s** (`V:api/client.ts:18`, `:44`; `R:src/runtime-error.ts:10-39`; "waking" = owner profile ≠ active profile,
  `R:build/r21-open-gates.ts:128`). The REST transcript is on screen meanwhile. See §3.1.3 for what the deferred build
  costs later.
- Concurrent resumes of one stored id are single-flighted. For a bot chat with a known owner the resume is started at
  the very start of the open (before the session record) and the open's own resume step takes that flight over when it
  is <8 s old with the same owner (`R:src/open-prefetch.ts:187-209`, `R:build/r21-open-gates.ts` parallel gate).

Result (`H:tui_gateway/contracts/sessions.py:74-99`; fixture `R:scripts/action-voice-fixture-gateway.py:26-33`):

```json
{"session_id":"5f0c2a1e","resumed":"20260929_120000_aabbcc01","session_key":"20260929_120000_aabbcc01",
 "stored_session_id":"20260929_120000_aabbcc01","messages":[],"messages_omitted":true,"message_count":1,
 "status":"idle","running":false,"inflight":null,
 "info":{"model":"fixture-model","provider":"fixture","cwd":"/fixture","title":"Bot Chat","tools":{},"skills":{},
         "mcp_servers":[],"lazy":true,"running":false,"stored_session_id":"20260929_120000_aabbcc01",
         "profile_name":"default","desktop_contract":8}}
```

Fields the open uses: `session_id` (runtime id), `session_key || resumed` (resolved stored id; if it differs from the REST
page's `session_id` the REST paint is not trusted, `V:…/index.ts:2065-2068`), `running`, `turn_started_at`,
`inflight {user, assistant, streaming, corrections, correction_offsets, display_kind, error, recoverable, status}` (the
live turn to graft after history), `queued {user}`, `pending_approval`, `open_requests`, `todo_state`, `info`
(`V:types/hermes.ts:741-814`, `H:tui_gateway/contracts/sessions.py:29-54`). When REST already painted and there is no
`inflight`/`queued`, the client keeps the REST snapshot untouched (`V:…/index.ts:2072-2109`).

#### 3.1.1 One canonical param set (native decision)

The web client builds `session.resume` params in six places, and they disagree:

| Call site | Params | Source |
|---|---|---|
| Chat open (vendor) | `{session_id, cols:96, source:"desktop", defer_history:true, omit_messages:true[, profile]}` (watch windows: `lazy:true` instead of `omit_messages`) | `V:app/session/hooks/use-session-actions/index.ts:1961-1975` |
| Chat open, phone parallel start (r21) | same, `profile` always | `R:build/r21-open-gates.ts:119-127` |
| 4001 recovery before a send | `{session_id, source:"desktop", omit_messages:true[, profile]}` (no `defer_history`, no `cols`) | `V:app/session/hooks/use-prompt-actions/utils.ts:123-132` |
| Submit to a stored chat with no runtime | same as 4001 recovery | `V:app/session/hooks/use-prompt-actions/submit.ts:664-673` |
| Resolve a targeted durable chat | `{session_id, source:"desktop"[, profile]}` — **no `omit_messages`**, so the reply carries the whole display transcript with inline images | `V:app/session/hooks/use-prompt-actions/resolve-target-session.ts:101-108` |
| Tile (bot chat in a workspace tile) | `{session_id, cols:96, omit_messages:true[, profile]}` (no `source`) | `V:app/contrib/hooks/use-session-tile-delegate.ts:380-386` |
| Fixture wire walk (05 spec) | `{session_id, profile}` — the minimum the Python fixtures read, not what any client sends | `05-fixtures-release.md` §wire walk |

The gateway accepts all of them (`SessionResumeParams`: `cols?`, `source?`, `lazy=false`, `defer_history=false`,
`omit_messages=false`, `eager_build=false`, `close_on_disconnect=false`, `inline_images=true`,
`H:tui_gateway/contracts/sessions.py:183-196`).

**Native M1 sends exactly one set everywhere** (open, warm-miss fallback, 4001/4007 recovery, pre-send rebind, tile):

```json
{"jsonrpc":"2.0","id":7,"method":"session.resume","params":{
  "session_id":"<stored id>","cols":96,"source":"desktop",
  "defer_history":true,"omit_messages":true,"profile":"<owner profile>"}}
```

- **`omit_messages:true` always.** Without it the reply projects the full display history; with
  `inline_images` defaulting to `true` that is every stored image as a `data:` URI (the resolve-target call above is a
  latent multi-MB reply). `H:tui_gateway/methods_session.py:686-687`, `H:tui_gateway/server.py:3174-3182`.
- **Do not send `inline_images`.** It only changes how `messages` is projected (`H:tui_gateway/methods_session.py:636-637`,
  `:686-687`; `H:tui_gateway/server.py:3181-3182`), and `messages` is `[]` whenever `omit_messages` is true. It has no
  effect on `inflight`, `queued` or `info`. (It *does* matter on REST, §6.6.)
- **`defer_history:true` on recovery too** (a deviation from the web's 4001 path, which omits it): the reply then never
  waits on the transcript read (`_resume_deferred`, `H:tui_gateway/methods_session.py:954-973`) instead of reading the
  whole lineage before answering (`_resume_cold`, `:975-995`). The prompt that follows waits server-side (§3.1.3),
  inside a turn the client already sees as `streaming`, so nothing is lost.
- `source:"desktop"` matters: with `omit_messages` it makes the hydration worker load model history only
  (`model_history_only = source == "desktop" and omit_messages`, `H:tui_gateway/methods_session.py:967-968`).
- Single-flight per stored id, as today (`V:…/use-prompt-actions/utils.ts:117-133`).

#### 3.1.2 Real reply shapes (the fixture's shape is not the deferred one)

The fixture reply in §3.1 is a reuse/cold shape. Real Hermes answers a **deferred** cold resume with
(`H:tui_gateway/methods_session.py:903-918`, `:954-973`):

```json
{"session_id":"<runtime id>","resumed":"<stored id>","session_key":"<stored id>",
 "message_count":<stored row count>,"messages":[],"hydrating":true,
 "info":{…},"inflight":null,"running":false,"started_at":<created_at>,"status":"resuming","todo_state":{…}?}
```

- `hydrating:true` replaces `messages_omitted` (the key is absent), and `status` is `"resuming"`, not `"idle"`.
  Native must treat `"resuming"` as **not running** (only `running` and `inflight` say a turn is live).
- No top-level `stored_session_id` (flag F8): read `session_key || resumed`.
- When the chat is already live in the gateway (reuse), the reply is the live snapshot instead:
  `messages_omitted:true`, `hydrating:<bool>`, `running`, `turn_started_at`, `status`, and optional `inflight`,
  `queued`, `pending_approval`, `open_requests`, `pending_connection` (`H:tui_gateway/methods_session.py:885-901`,
  `H:tui_gateway/server.py:3183-3196`).
- Progress events follow on the socket for the runtime id: `session.resume_progress {phase:"history",
  status:"loading"}` → `{…, status:"complete", message_count}` or `{…, status:"failed", message}` plus an `error`
  event and the runtime being discarded (`H:tui_gateway/server.py:2986-3027`). On `failed`, native drops the runtime id
  and resumes again on the next send.

#### 3.1.3 Timeouts when the build is deferred

| Stage | Who waits | Limit | What the user sees | Source |
|---|---|---|---|---|
| `session.resume` reply | client | 30 s (active profile) · 120 s ×2 (bot / other profile) | quiet; REST transcript already painted; then "The computer running Hermes didn't answer in time." / "This chat is still starting on the computer running Hermes." | `V:api/client.ts:18`; `R:src/runtime-error.ts:10-39` |
| `prompt.submit` ack | client | 1,800 s (`PROMPT_SUBMIT_REQUEST_TIMEOUT_MS`) | — (deferred submit acks `{"status":"streaming"}` at once) | `V:api/client.ts:27`; `H:tui_gateway/methods_prompt.py:822-832` |
| transcript hydration | gateway build thread | 300 s, then the build fails with "session history hydration timed out" | turn error (below) | `H:tui_gateway/server.py:1074-1083`, `:1172` |
| agent build (MCP discovery, prompt) | gateway turn thread, in 5 s slices | 600 s default, `agent.build_wait_timeout` overrides | after 30 s one keyed notice: `notification.show {key:"agent-build-slow", level:"info", kind:"agent", ttl_ms:null, text:"Still starting the agent (tool discovery / model setup) — your message will be sent as soon as it's ready."}`, cleared by `notification.clear {key:"agent-build-slow"}` | `H:tui_gateway/server.py:946-1003` |
| build failure / cap | gateway | — | terminal turn error, `error_surface {layer:"runtime", code:"agent_init_failed", retryable:true}`, message e.g. "agent initialization timed out after 600s — your message was not sent; retry once the session is ready" (JSON-RPC code 5032 internally) | `H:tui_gateway/methods_prompt.py:614-624`; `H:tui_gateway/server.py:986-993` |

Native therefore needs **no extra client timer** for the deferred build: it shows the turn as working, shows the
keyed notice when it arrives (streaming spec), and treats `agent_init_failed` as a retryable turn error. A non-prompt
RPC that needs the agent (e.g. a slash command) can still fail fast with 5032 "Hermes is still starting this session
(loading tools)…" after the gateway's flat 30 s wait (`H:tui_gateway/server.py:939-943`,
`H:tui_gateway/user_messages.py:118-120`).

### 3.2 `session.activate` (warm reopen in the same app run)

When the in-memory warm cache (§7.1) still holds the runtime id, the client paints the cached state immediately and
sends `{"session_id":"<runtime id>","cols":96,"omit_messages":true}` to rebind the event transport
(`V:…/index.ts:1458-1466`). A "session not found" error drops the warm entry and falls through to a cold resume; a
transport error keeps the warm cache on screen (`V:…/index.ts:1847-1870`). After activate, the stored tail is refreshed
(probe-first, §7.6).

---

## 4. The open sequence (what happens, in order)

### 4.1 Before the tap (warming)

- **Stale refresh pass.** When the bots list (roster) changes, at most twice a minute and ≥2 s after it settles, the app
  refreshes saved tails that are *stale* (saved more than 1 s before the chat's `canonical_session.last_active`), newest
  activity first, at most 4 per pass, one at a time, background lane (`R:src/open-warm.ts:21-41`,
  `R:src/open-prefetch.ts:222-264`). The refresh reads the newest **12** rows (`TAIL_REFRESH_ROWS`, `R:src/open-page.ts:25`)
  and splices them onto the saved tail; if they don't join, it reads 24 (`R:src/open-prefetch.ts:266-271`). Skipped while
  the app is backgrounded (`R:src/open-warm.ts:24-33`). `last_active` may be seconds or ms (`activityMs`,
  `R:src/open-prefetch.ts:284-285`).
- **Finger-down warm.** A finger resting still on a bot row for 100 ms (`PRESS_DELAY_MS`, `R:src/phone-touch.ts:412`)
  starts that chat's 24-row read; moving >10 px (`R:src/phone-touch.ts:227`), lifting, or scrolling cancels
  (`R:src/open-warm.ts:43-61`). The open takes the flight over (§4.4).

### 4.2 Provisional paint from disk

On open, the saved tail for `(scope, storedId)` is loaded (§7.2) and trimmed with `openWindow`: keep the newest messages
whose summed `serverRowSpan` ≤ 24; if that window starts mid-turn and moving its start to the first non-assistant
message still keeps ≥12 rows, start there; if nothing fits, keep only the last message
(`R:src/open-page.ts:205-216`, applied at `R:build/lt-open-gates.ts:24-25`). The paint is display-only: it is never
"history", and the authoritative page replaces it wholesale (`V:…/index.ts:1889-1903`,
`V:app/session/hooks/use-session-actions/provisional-transcript.ts:17-55`). A scope change clears it. An unknown owner
never reads an unscoped entry (`provisional-transcript.ts:41-44`).

### 4.3 Stale hold

If the saved tail is known stale (§4.1 rule), it is not painted immediately; it waits up to `STALE_HOLD_MS = 300` ms for the
fresh page (`R:src/open-prefetch.ts:35`, `R:build/r21-open-gates.ts` provisional gate). If fresh rows land first they paint
(as provisional); if the open reaches its reconcile ("seal") first, the held tail paints then rather than nothing.

### 4.4 Parallel reads

Started together when the owner is known (`R:build/r21-open-gates.ts` "A3"; `V:…/index.ts:1950-1980`):

1. **First page:** `GET /api/sessions/{id}/messages?profile=P&limit=24&order=latest&include_compacted=true`
   (`OPEN_PAGE_ROWS = 24`, `R:src/open-page.ts:23`, `:59-82`; `getSessionMessages` query order
   `V:api/sessions.ts:455-492`). Taken from the finger-down flight when that began after the chat's last activity and is
   <8 s old (or landed <1 s ago) (`R:src/open-prefetch.ts:30-34`, `:126-139`, `:172-185`).
2. **`session.resume`** (§3.1).
3. Session record (§2.6), not awaited by the paint.

**`atTurn` cut** (`R:src/open-page.ts:43-56`): when the first page came back full (`returned ≥ pagination.limit` and
≥ the requested limit), drop leading assistant/tool rows up to the first user/system row if that keeps ≥ half the page;
pagination is rewritten as if `limit` = the kept count. This keeps a turn from being split between page 1 and the older
page. Only applied when `limit < 120`.

### 4.5 Paint and reconcile

- REST lands → convert (§6) → save to disk cache immediately (`V:…/index.ts:2006-2015`) → if the view still shows the
  provisional paint or nothing, replace it (`V:…/index.ts:2025-2050`).
- Before painting, if the page starts after everything already on screen in this session (a long turn pushed every
  on-screen row off the newest page), older pages are read until they overlap (max 4 pages,
  `REFRESH_OVERLAP_PAGE_LIMIT`, `V:app/chat/transcript-backfill.ts:335-358`; `V:…/index.ts:2029-2040`), then grafted
  (§7.5).
- The socket can redial while REST is in flight; if the redial's replay is pending, the REST result is dropped so a
  replayed turn isn't appended twice (`V:…/index.ts:1997-2004`).
- Resume lands → if `inflight`/`queued`, graft the live projection after the REST transcript (dedupe the in-flight user
  prompt against a persisted copy) (`V:…/index.ts:2072-2109`). Otherwise keep the REST snapshot.
- Save the final transcript (minus any pending clarify projection) to the disk cache (`V:…/index.ts:2321-2332`;
  warm path `:1833-1843`).
- Open-in-flight bookkeeping: older-page merges are refused until the open settles, because the reconcile would drop
  them while the paging bookkeeping says they're loaded (`R:src/open-page.ts:160-187`).

### 4.6 After the open

- Background older page fills the first 120 rows (§5.2).
- Live events stream into the last assistant message (streaming spec).
- The open chat refreshes on `sessions.changed` / reconnect / turn end via the probe (§7.6). A turn's end read waits
  1200 ms so the gateway's last `sessions.changed` produces a single read; a read made since the turn ended is reused
  for 12 s (`R:src/turn-end-read.ts:3-11`).

### 4.7 Failure

If the open fails with nothing painted, the phone shows its own error state with Retry and keeps the composer
(`R:build/r21-open-gates.ts` "B-03"). With a cached paint on screen, failures are quiet. The REST read failing is
non-fatal if resume succeeds (`V:…/index.ts:1988-1996`).

### 4.8 A turn another Hermes process runs (native, 2026-10-27)

A message from another bot (`message_agent`), a Telegram or Discord message, or a job's hand-off to Bot Chat runs in the
messaging gateway (`hermes gateway run`), not in `hermes serve`. The open chat's `session.resume` then says
`running: false, inflight: null`, no turn frames come, and the only sign was a `sessions.changed` tail read every 10 s —
the chat looked idle while the bot worked for minutes (owner, 2026-10-27: "Herald messaged Hermes and I can't see that
anything is happening"). `HermesKit/Chat/ExternalTurn.swift`, `LiveChatSession+External.swift`:

- **Signal.** The gateway's durable ledger: `session_admissions` (`queued`/`started`) and `worker_executions`
  (`registered`/`running`) rows for the chat in the profile's `state.db` — the read `hermes serve` itself makes before
  refusing a typed send with `4090 SESSION_OWNER_BUSY` (`tui_gateway/session_lifecycle._canonical_ledger_refusal`).
  Hermes exposes it through no API, so the Hermes HQ add-on (0.9.6+) serves it: `GET
  /api/plugins/hermes-hq-push/sessions/working?profile=P` → `{"sessions": [{profile, id, status, kind}]}`
  (`unknown` admissions never count: they don't end by themselves). Authoritative when present.
- **Fallback (no route, 404; asked again after 10 min).** The stored rows: the gateway writes each step as it goes, so
  a newest stored message that ends on a tool step or a reasoning part (no words after) with the newest stored row under
  10 min old, or a stored prompt with no answer under 2 min old, is a turn still running. A reply, an error, a stop or a
  notice (`[SILENT]`, a failed turn) ends it. Our own unsent bubbles are skipped.
- **When it is asked.** The open settling, every tail read that applied rows (a `sessions.changed` pass, a reconnect),
  and a send refused with `SESSION_OWNER_BUSY`. Never while a turn of ours runs (its own state rules); a turn of ours
  starting ends it.
- **While it holds.** Every 3 s: a probe-first tail read (one 1-row read when nothing changed) and the ledger again.
  The header says "Working…"; the row builder draws the turn as running (the newest reply's One Line step line in the
  present tense, no action row, the waiting capsule after an unanswered prompt); the bot's and the Sessions rows say
  Working… while the chat is open. The composer keeps Send: a typed message is forwarded to the gateway's queue (or
  waits, `OwnerWait.runningReply`, whose words the header keeps; no waiting capsule then).
- **End.** The ledger no longer names the chat (or the rows end in a reply): Working… goes, and one forced tail read
  brings the reply. Leaving the chat ends the watch (off screen nothing reads the rows).

---

## 5. Paging older history

### 5.1 Tail bookkeeping (live store)

Per `(connectionId, profile, storedId)` the client keeps `{nextOffset, possiblyTruncated, profile(route)}`
(`V:store/transcript-tail.ts:20-31`), LRU 256 entries (`:42`). After a `latest` page:
`nextOffset = pagination.offset + messages.length` (or the plugin's `next_offset`), `possiblyTruncated = returned ≥ limit`
(or the plugin's `has_more`) (`V:store/transcript-tail.ts:132-155` patched by `R:build/data-performance-gates.ts:96-99`).
A transient zero-row read never clears a known-truncated tail (`:207-214`). **Offsets are counted in backend rows**,
not converted messages; `ChatMessage.serverRowSpan` says how many rows a folded message covers (§6.3).

### 5.2 Background "older page" to complete the first 120 rows

`FULL_PAGE_ROWS = 120` (`R:src/open-page.ts:27`). After the open settles (or as soon as the reader scrolls up during it),
if the tail is truncated and `nextOffset < 120`, read
`GET …/messages?profile=P&limit=(120-nextOffset)+1&offset=nextOffset-1&order=latest&include_compacted=true` in the
background lane (`R:src/open-page.ts:83-114`). The extra row is the **join**: the first page's oldest row id. Keep the
rows strictly before the join row; if the join isn't in the page (`at <= 0`), discard (a gap at the seam). Rows saved
since the first page shift the window newer; the kept-rows rule tolerates that. One older page per chat, ≤2 chats kept,
expires 120 s after landing, dropped on memory pressure/account change (`R:src/open-page.ts:115-147`, `:220-222`). It is merged with
`mergeOlderTranscriptPage` (§7.5) and is skipped if the store already holds rows older than the first page
(`olderInStore`, `R:src/open-page.ts:148-153`).

### 5.3 History-page mode (beyond the live window)

When the reader scrolls past the in-memory window, the phone does **not** grow the live store; it replaces the
transcript view with one bounded page (`R:build/history-window-gates.ts` expandWindow gate →
`R:src/history-window.ts:118-136`):

1. Take the first message with a `rowId`. If the plugin advertises `history_locator`, call `…/messages/locate?row_id=N`
   (§2.4); with `offset > 0`, read
   `GET …/messages?order=oldest&offset=max(0, offset-120)&limit=120&include_compacted=true[&before_offset=offset]`
   (`before_offset` only when `history_before` is advertised) (`R:src/history-window.ts:50-54`, `:120-123`).
2. Without the locator: find the first user row's `rowId` (or the previous prompt row via `/timeline`), read
   `/messages/around?row_id=N&limit=120`; if that page's `offset` is 0, show it; otherwise read the oldest-order page
   ending at that offset (`:124-135`).
3. Further up: `revealOlder` reads `order=oldest&offset=max(0,page.offset-120)` (`:109-112`); down: `revealNewer` reads
   `offset=page.nextOffset` (`:113-116`). Each navigation **replaces** the page (`:65`).
4. UI shows "Show newer" (when `newerAvailable`) and "Return to latest" pills; a snapshot-expired notice shows the copy
   in §2.3 (`R:build/history-window-gates.ts` list gate).

Page decode (`R:src/history-window.ts:28-38`): reject a page with more than 120 messages or a non-advancing offset;
`olderAvailable = has_older ?? offset > 0`; `newerAvailable = has_newer ?? has_more ?? (total ? next<total : returned≥120)`.

Auto-paging: only a directional upward gesture (wheel/touch drag/keys) at the top may spend one page; page arrival
consumes the gesture so momentum cannot chain pages (`R:src/history-auto-paging.ts:1-74`).

### 5.4 Bounding the live store

Rows older than the live window plus one page of slack, which have a `rowId`, are released from memory; the tail
`nextOffset` is rewound by the released **backend rows** so they can be fetched again (`V:app/chat/transcript-retention.ts:1-60`,
`V:store/transcript-tail.ts:229-277`, `R:src/bound-live-transcript.ts:15-40`). Rows without a `rowId` (pending,
locally recovered) are never released (`R:build/history-window-gates.ts` retention gate). Window budget weight 1200,
minimum 30 messages (`V:app/chat/transcript-window.ts:29`, `:36`).

---

## 6. Message model (rows → `ChatMessage`)

`toChatMessages` (`V:lib/chat-messages/hydration.ts:281-595`), with phone patches for stable ids
(`R:build/rendering-fluidity-gates.ts:4-41`) and tool metadata (`:80-95`). The phone memoizes per page object
(`R:src/normalized-transcript.ts:3-11`).

### 6.1 Output types (`V:lib/chat-messages/types.ts:8-81`)

```
ChatMessage {
  id: string                    // "stored-row-{rowId}-{kind}" (§6.2)
  role: "user" | "assistant" | "system"
  parts: Part[]
  timestamp?: number            // unix seconds; earliest of the row and its parts
  rowId?: number                // durable id of the row that created the message
  serverRowSpan?: number        // backend rows folded into this message (absent = 1)
  durableComplete?: boolean     // assistant: reached a final text row (false while tool rounds trail)
  systemNotice?: true           // machine notice (§6.5)
  asyncResult?: string; asyncResultKind?: "process"
  attachmentRefs?: string[]     // "@image:…", "@file:…" lifted out of user text
  reactions?: [{emoji, author:"agent"|"user", at}]
  pending?, error?, interim?, hidden?, recovered?   // live-only
}
Part =
  | {type:"text", text, timestamp?, sourceRowId?}
  | {type:"reasoning", text, timestamp?}
  | {type:"tool-call", toolCallId, toolName, args:object, argsText:string,
     result?: any, isError: bool, timestamp?, completedAt?,
     toolResultMetadata?: {inline_diff?, error?, display_payload_ref?},
     unpairedStoredToolResult?: true, storedResultToolName?}
```

No image/file parts are produced from history; images ride in `attachmentRefs`, inline `data:` URIs, or `MEDIA:` links.

### 6.2 Message ids

`createHistoryMessageIdentity` (`R:src/history-message-identity.ts:1-14`): `stored-row-{N}-{kind}` where `N` is the
row's `row_id ?? id` (positive int) and `kind` is the display role (`user`/`assistant`/`system`) or `tools` for a
tools-only fold (keyed by its first tool row). Rows without a durable id get `history-page-{pageSeq}-{index}-{kind}`
(page-local; never matched across pages). Upstream vendor ids were `${timestamp}-${index}-${role}`
(`V:lib/chat-messages/hydration.ts:370`, `:564`) — the phone replaced them so overlapping pages produce identical ids.
Within one message duplicate `toolCallId`s are renamed `"{id}-{messageId}-{index}"`
(`V:lib/chat-messages/tool-parts.ts:897-930`).

### 6.3 Algorithm (in row order)

State: `pendingToolParts`, `pendingToolRows`, `activeAssistantIndex`.

1. **`tool` row**
   - Todo tool result not paired with the nearest preceding assistant call → kept as an unpaired part (`:390-397`).
   - Else pair with the first *unresolved* `tool-call` part in `pendingToolParts` matching `tool_call_id` (or `tool_name`
     when the row has no id) (`:399-406`, `V:lib/chat-messages/tool-parts.ts:831-869`). Pairing sets
     `result = parseStoredToolResult(content)` (objects as-is; strings JSON-parsed when possible, else the string; blank →
     `""`), `completedAt = row.timestamp`, `toolResultMetadata`, `storedResultToolName`, and
     `isError = Boolean(display_payload_ref && metadata.error)` (phone gate, `R:build/rendering-fluidity-gates.ts:85-95`).
   - Else pair with the newest assistant message already emitted that has such an unresolved part; its
     `serverRowSpan += 1` (`:408-410`, `V:…/tool-parts.ts:809-829`).
   - Else an orphan: a `tool-call` part with `unpairedStoredToolResult:true` built from the row (`context`/`args`) (`:871-895`).
   Tool ids are not unique across turns, so only unresolved parts can take a result (`:846-848`).
2. **Other roles** — `content = display_content ?? content || text || context || name` (`:419-422`). Text extraction
   `textFromUnknown`: string as-is; arrays concatenated; objects use `text ?? output_text ?? content ?? message`, else
   `JSON.stringify` (`V:…/tool-parts.ts:715-749`).
   - User text cleanup (`:109-155`): strip the Discord triggering note; collapse a stored `/skill` expansion to its
     invocation; cut at `--- Attached Context ---` and hoist missing `@file:/@folder:/@url:/@image:/@tool:/@terminal:`
     refs; drop `--- Context Warnings ---` tail.
   - Hidden: `display_kind:"hidden"` → dropped; a legacy `[Background process … heartbeat #N` user row → dropped
     (`:157-165`).
   - Timeline wording (`:250-279`): `model_switch` → "model changed"; `auto_continue` → "resumed interrupted turn";
     `personality_switch` → "personality changed"; `async_delegation_complete` → `display_text` or "N background agent(s)
     finished"; `process_complete` → `display_text` or "background process finished".
   - Notice kinds (`model_switch, async_delegation_complete, process_complete, auto_continue, personality_switch,
     failed_turn`) are rendered with `role:"system"`, `systemNotice:true` (`:162-180`, `:430`).
   - User rows: lines matching `^@image:[^\n]*\n?` are lifted into `attachmentRefs` (and `[screenshot]` placeholder lines
     removed); a leading block of attachment-ref lines (`@file:` etc.) is lifted too (`:440-444`,
     `V:lib/embedded-images.ts:167-197`, `V:components/assistant-ui/reference-kinds.ts:188-197`).
   - Assistant parts, in order: `reasoning` part (from `display_reasoning ?? reasoning || reasoning_content ||
     reasoning_details-if-string`) (`:456-465`); public commentary texts unless equal to the reply (`:467-479`); the
     reply text (assistant text goes through `renderMediaTags`, §9.4) (`:481-485`); one `tool-call` per entry of
     `tool_calls` (`:487-493`; `toolPartFromStoredCall`, `V:…/tool-parts.ts:773-800`: id = `id || tool_call_id ||
     "stored-tool-{i}"`, name = `name || tool_name || function.name || "tool"`, args = first non-empty object of
     `function.arguments` (JSON string parsed), `arguments`, `args`, `input`, plus `hermes_tool_labels` from
     `tool_call_labels[id]`).
   - Text parts get `sourceRowId = rowId` (`:495-501`). A row with no parts and no refs is skipped (`:503-510`).
3. **Folding** (`:512-581`):
   - An assistant row whose parts are *only* tool calls goes to `pendingToolParts` (`pendingToolRows += 1`).
   - The next assistant row with prose: pending tool parts are appended to the active assistant message if any, else
     prepended to this row's parts (`serverRowSpan = absorbed + 1`).
   - If an active assistant message exists and either it or this row has tool calls, this row's parts are **appended to
     it** (same message; `serverRowSpan += 1`; `timestamp` = earliest).
   - A user/system row flushes pending tools into the active assistant (or a new `…-tools` message) and ends the turn.
   Net effect: **one assistant `ChatMessage` per turn**, parts interleaved in row order: `[reasoning?, text?, tool-call…,
   text?, tool-call…, text]`. Its `id`/`rowId` come from the turn's first assistant row.
4. Post-pass: dedupe generated-image echoes and repeated text in assistant parts; drop messages with no text, no
   non-text part and no refs; unique tool ids (`:584-595`).

### 6.4 Worked example (performance fixture rows → messages)

Rows (shape exactly as `R:scripts/performance-fixture-gateway.py:28-44` writes them; prompt text, ids and timestamps
illustrative — the fixture stamps `int(time.time())`):

```json
[
 {"role":"user","content":"Run two steps","row_id":40,"timestamp":1790852460},
 {"role":"assistant","content":"","row_id":41,"timestamp":1790852461,
  "tool_calls":[{"id":"performance-tool-0","type":"function",
                 "function":{"name":"terminal","arguments":"{\"command\": \"printf synthetic-step-0\", \"timeout\": 5}"}}]},
 {"role":"tool","content":"{\"stdout\": \"synthetic output\\nsynthetic output\\n…\", \"stderr\": \"\", \"exit_code\": 0}",
  "row_id":42,"timestamp":1790852461,"tool_call_id":"performance-tool-0"},
 {"role":"assistant","content":"Synthetic performance reply.","row_id":43,"timestamp":1790852462}
]
```

Messages:

```json
[
 {"id":"stored-row-40-user","role":"user","rowId":40,"timestamp":1790852460,
  "parts":[{"type":"text","text":"Run two steps","timestamp":1790852460,"sourceRowId":40}]},
 {"id":"stored-row-43-assistant","role":"assistant","rowId":43,"serverRowSpan":3,"durableComplete":true,"timestamp":1790852461,
  "parts":[
   {"type":"tool-call","toolCallId":"performance-tool-0","toolName":"terminal",
    "args":{"command":"printf synthetic-step-0","timeout":5},"argsText":"{\"command\":\"printf synthetic-step-0\",\"timeout\":5}",
    "timestamp":1790852461,"completedAt":1790852461,"storedResultToolName":"tool",
    "result":{"stdout":"synthetic output\n…","stderr":"","exit_code":0},"isError":false},
   {"type":"text","text":"Synthetic performance reply.","timestamp":1790852462,"sourceRowId":43}]}
]
```

(The tool-only rows 41/42 are absorbed into the message created by row 43, so its id is row 43's; `storedResultToolName`
falls back to `"tool"` because fixture tool rows carry no `tool_name`. Real Hermes rows carry `id` instead of `row_id`
and do carry `tool_name`.)

### 6.5 System rows and deliveries

- `systemNotice` rows draw as centered timeline notices, not bubbles; they never count as "authored" content
  (`V:lib/chat-messages/types.ts:73-80`).
- `asyncResult` (process/delegation completion bodies) is parsed from `[IMPORTANT: …]` / `[ASYNC DELEGATION …]`
  envelopes (`V:lib/chat-messages/hydration.ts:216-248`).
- A stored result draws as an update line; it does not say whether the bot has read it (owner, 2026-10-27: the "Not
  read yet" label was removed). A note that is another bot's message ("Message from 🤖 inbox (@inbox): …") names the
  bot on its line and opens on its words without the prefix, formatted like a reply.
- User-role rows that are really from another sender are attributed by text (`R:src/ui-chat/run.ts:36-86`):
  `Message from <Name> (@handle):` or `[Message from agent 'x']` → delivery bubble from that bot; `[Cron delivery: Job]`,
  `Cronjob Response: Job` or `[Cronjob "Job" output …]` → delivery from cron job (wrapper and footer stripped,
  `:46-53`); `[IMPORTANT:` → notice.

### 6.6 Attachments & images in history

There is no separate attachments spec; this section is the M1 contract for images that history rows carry.

**Two shapes reach history.**

1. **`@image:<path>` refs** in a user row's text (the phone's own sends, and the replay fixture:
   `"…OK.\n@image:/dispatch-replay-fixture/qa-image.png\n[screenshot]"`, `R:scripts/gateway-replay.py:361-377`).
   Hydration lifts them into `attachmentRefs` and drops the `[screenshot]` placeholder line
   (`V:lib/chat-messages/hydration.ts:432-444`, `V:lib/embedded-images.ts:167-197`). The bytes live on the gateway's disk.
2. **Multimodal parts** in `content`: `[{"type":"text","text":"what is this?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,…"}}]`
   (`H:tests/hermes_cli/test_session_messages_inline_images.py:17-21`). REST returns the full data URI unless the request
   says `inline_images=false`, which turns each image part into the text `[image]` (`H:hermes_cli/web_routers/sessions.py:674-681`, `:727`, `:757`).
   One measured conversation was **26.33 MiB per page** (`H:tests/hermes_cli/test_session_messages_inline_images.py:3-8`);
   the plugin route does not shrink images either (no image handling in `P:history.py`; a single over-budget row comes
   back alone with `oversize:true`, §2.3).

**What the web does today.**

| Shape | Fetch | Display | Failure | Source |
|---|---|---|---|---|
| `@image:` ref | `GET /api/fs/read-data-url?path=<enc>&profile=<p>` → `{"dataUrl":"data:<mime>;base64,…"}` (shim appends `profile`) | inline thumbnail row under the bubble, downscaled to ≤512 px long edge, `max-height:12rem`; tap → zoomable viewer with the full-resolution data URL | phone: a "Couldn't load photo · Tap to retry · <name>" tile that retries by itself on reconnect, on return to foreground and when scrolled back into view | `V:components/assistant-ui/directive-text.tsx:403-475`; `V:lib/desktop-fs.ts:55-57`, `:119-127`; `V:lib/image-resize.ts:25`, `:72`; gate `R:build/fe-convo-gates.ts:304-307`; `R:src/fe-convo-r2-ui.tsx:17-40` |
| inline `data:` part | none (bytes are in the page) | the part is stringified, then `data:image/…;base64,` runs of ≥64 base64 chars are cut out of the text with their `{"type":"image_url",…}` wrapper and shown as a thumbnail row (`max-height:12rem`) | — | `V:lib/embedded-images.ts:1-160`; `V:components/assistant-ui/directive-text.tsx:345-394` |
| file download / share | `GET /api/fs/download?path=&profile=&session_id=` (raw bytes, `Content-Disposition: attachment`) | — | — | `R:src/bridge/platform.ts:41-46`; `R:src/bridge/fe-pages.ts:74`, `:127` |
| Artifacts page thumbnails (not chat) | `GET /api/plugins/hermes-hq-performance/media/thumbnail?path=&session_id=&profile=&max_side=160..660` when `media_thumbnail` is advertised | — | — | `R:src/media-metadata.ts:13-22`; `P:dashboard/plugin_api.py:132-137` |

Server limits: `read-data-url` refuses files over **16 MiB** with 413 `"File too large"`
(`H:hermes_cli/web_server.py:892`, `H:hermes_cli/web_routers/files.py:907-930`); `download` streams with no size cap
(`H:hermes_cli/web_routers/files.py:933-959`); both resolve relative paths against the session's cwd when
`session_id` is given (`H:hermes_cli/web_routers/files.py:891-903`). The plugin thumbnail is JPEG (q 82) or PNG when the source has alpha, at most
660 px, ≤700,000 encoded bytes, sources ≤32 MiB / ≤24 MP, formats JPEG/PNG/WEBP/GIF/BMP/ICO only (415 otherwise)
(`P:media.py:60-87`); answer `{"schema":"media.thumbnail.v1","dataUrl":…,"width":…,"height":…}`.

**Native M1 (decision).**

- **`@image:` refs:** placeholder first (a rounded tile at the hinted size, 12 % label fill), then a lazy, cancellable
  `GET /api/fs/download?path=<path>&profile=<owner>&session_id=<stored id>` at background priority once the row is
  within one screen of the viewport. Decode with ImageIO thumbnailing (`kCGImageSourceThumbnailMaxPixelSize` =
  512 px × screen scale, off the main thread); inline it at most 192 pt tall (the web's 12rem), aspect-fit, radius 12.
  Tap → full-screen viewer that decodes the cached original. When `gateway.ready.performance.media_thumbnail` is 1 you
  may ask the plugin thumbnail (`max_side=480`) instead and fall back to `download` on 415/422/501.
  *Deviation:* the web reads `read-data-url` (base64 in JSON, +33 %, 16 MiB cap); `download` gives raw bytes and no cap
  for the same auth and path rules.
- **Failure:** the web's retry tile, same words ("Couldn't load photo", "Tap to retry", file name) and the same automatic
  retries (reconnect, foreground, scrolled back into view).
- **Inline `data:` parts:** parse the parts array directly (text parts → text, `image_url.url` → image). Decode the base64
  off the main thread straight into the media cache file, keep only `{mediaKey, width, height}` in the `ChatMessage`,
  and drop the string. A `data:` URI never enters the transcript cache, the in-memory message model's text, or the
  markdown pipeline.
- **Media cache:** Caches directory, keyed by `(gatewayIdentity, profile, path)` for refs and
  `(gatewayIdentity, profile, storedId, rowId, partIndex)` for inline parts; originals + thumbnails, LRU by bytes,
  256 MiB; purged with the transcript cache on sign-out and gateway removal (§7.2).
- **`inline_images`:** keep the REST default (`true`) in M1. Sending `false` loses the picture (`[image]`), and there is
  no route to fetch one part's bytes later. **But** a page can exceed the native 32 MiB response cap
  (`R:ios/App/Shared/HermesTransportShared.swift:34-37`; the web then fails the read with
  `response-too-large` "Gateway response exceeds 32 MB. Open a smaller page of results.",
  `R:ios/App/App/HermesNative.swift:1554-1556`, and does nothing smarter). Native M1 on `response-too-large` for a
  history page: retry the same request with `limit` halved (down to 1); if a 1-row page is still too large, read that
  page once more with `inline_images=false` and show the row's images as a "Photo too large to load" tile.

---

## 7. Caching for instant reopen

### 7.1 In-memory warm session cache

The renderer keeps each opened chat's full client state (messages, runtime id, model, …) by runtime id. Phone limits: 4
chats or 4 MB of transcript (desktop: 24 / 32 MB); the visible chat is exempt. Pruned on memory pressure (all settled,
unreferenced), and back to limits on backgrounding (`R:src/session-cache-phone.ts:1-28`, `R:build/memory-pressure-gates.ts`).
A warm hit paints instantly and sends `session.activate` (§3.2). Validity: the cached transcript's provenance must match
`(storedId, scope, lineageRoot)`; otherwise the cached prefix is held back until the refresh lands
(`V:…/index.ts:1369-1404`).

### 7.2 Durable tail cache (disk)

What the web app stores (two layers sharing one key format):

| Aspect | Value | Source |
|---|---|---|
| Key | `"hermes.transcript-tail.v2:" + JSON.stringify([connectionId, profile, storedSessionId])`; on the phone `connectionId` is `"ios-direct"`, profile trimmed or `"default"` | `V:store/transcript-tail-cache.ts:33`, `:100-125`; `R:src/cached-conversation.ts:93` |
| Owner partition | IndexedDB `dispatch-transcript-cache-v1`, store `tails` keyed `[owner, key]`, index `owner`; owner = `JSON.stringify([gatewayOrigin+path, username])` | `R:src/transcript-persistence.ts:8`, `:101-137`; `R:src/connection-storage.ts:39-42`; `R:src/main.ts:137` |
| Value | `{messages: ChatMessage[], savedAt: ms, partial?: true, stale?: true}` | `R:src/transcript-persistence.ts:5` |
| Rows per entry | newest 40 messages; if >64 KB, step down to 8, 3, 1 | `R:src/transcript-persistence.ts:225`, `:250-258` |
| Entry cap | 64 × 1024 chars of JSON | `R:src/transcript-persistence.ts:13` |
| Entries | 16, LRU (read bumps recency) | `:13`, `:293-299` |
| Total budget | 1,000,000 chars (oldest evicted first) | `:13`, `:273-277`, `:362-366` |
| Partial copy | when even 1 message won't fit: bounded display copy of the newest ≤3 messages (text/reasoning capped at 8000 chars, halved down to 250, each cut ends with `"\n\n… _Shortened offline copy. Reconnect to load the rest._"`; tool calls kept without args/result → result `"Output left out of the offline copy."`; ≤24 parts; no media). Marked `partial` and used **only** for the offline cold-launch restore | `:227-271`, `:293-299` |
| Stale keep | a newer tail that can't be admitted never deletes the older one; the older one is kept and marked `stale` | `:280-291` |
| Write path | in memory immediately; flushed to IndexedDB 100 ms later (debounced), on `pagehide` and when the app is backgrounded; serialization off the main thread (worker, 10 s first / 3 s per job deadline, exponential backoff 5 s → 300 s) | `:214-220`, `:46-99`, `:323-379` |
| Startup | open waits ≤200 ms for IndexedDB; a late open is adopted when it lands; tails written to the legacy localStorage path meanwhile are migrated (newest wins) | `:139-210` |
| Legacy path | `localStorage` with index key `hermes.transcript-tail.v2-index`, same caps (16 / 64 KB / 1M chars) | `R:src/bridge/fe-native.ts:108-144` |
| Message repair on read | rename duplicate `toolCallId`s within a message | `V:store/transcript-tail-cache.ts:250-258` |
| Vendor defaults (desktop, replaced on phone) | 40 msgs, 256 KB entry, 50 entries, localStorage | `V:store/transcript-tail-cache.ts:33-38` |

**When it is written:** after every authoritative REST page lands during an open (`V:…/index.ts:2006-2015`), after the
open's final reconcile (`:2321-2332`, warm path `:1833-1843`), after a stale refresh or warm read (spliced onto the existing tail when they join,
`R:src/open-prefetch.ts:152-163`). Only backend-truth messages are cached (pending clarify projections stripped).

**When it is read:** the open's provisional paint (§4.2), staleness checks (`transcriptTailSavedAt`,
`R:build/data-performance-gates.ts:83-86`), the cold-launch restore (§7.4).

**Invalidation** (`V:store/transcript-tail-cache.ts:262-417` + phone hooks `R:build/data-performance-gates.ts:43-86`):
- Session deleted → drop every scope's entry for that stored id (`dropTranscriptTailEverywhere`, `:299-342`).
- Failed resume / session not found → drop only that scope's entry (`:262-288`).
- Profile renamed → re-key `[connectionId, old, id]` → `[connectionId, new, id]` (local connection only, `:345-394`).
- Connection re-home / quota recovery → clear all (`:397-417`).
- Sign out → purge: mark a reset flag first, then delete the database; cached data is never admitted after re-login if
  deletion failed (`R:src/transcript-persistence.ts:395-408`). Saved gateway removed → delete that owner's rows
  (`:383-393`).
- Staleness (not deletion): `savedAt + 1000 < last_active(ms)` ⇒ refresh in background / hold on open (§4.1, §4.3).

#### 7.2.1 Native M1 sizing (decision)

The web's caps (16 entries, 64 K chars each, 1 M chars in all) are set by `localStorage`/IndexedDB quota and a JS
serialization budget, not by what a chat needs; a single image-bearing or long-tool message makes an entry fall to 8, 3,
1 or a partial copy (`R:src/transcript-persistence.ts:221-262`). The native architecture note says "per-session JSON
under Application Support, read synchronously on the main thread in < 5 ms for 500 items"
(`NAT:docs/ARCHITECTURE.md:19-21`, NAT = `/Users/me/Projects/hermes-hq-native`). **⚑ DISAGREES** on retention: 500
is a read-speed budget, not a cap anyone sets. M1 uses:

| Aspect | Native M1 | Why |
|---|---|---|
| Location | `Application Support/transcripts/<accountKey>/<profile>/<storedId>.json`, `accountKey` = hash of `(gateway origin+path, username)` (the web's owner partition, §7.2) | per-account isolation and purge |
| Messages per entry | newest **40** `ChatMessage`s (same as web) | ≥ 1.5 screens in the worst case below |
| Entry size cap | **256 KiB** of encoded JSON (the vendor desktop default, `V:store/transcript-tail-cache.ts:33-38`) | 40 typical messages fit; a 5 ms main-thread decode stays easy |
| Over the cap | the web's ladder: 40 → 8 → 3 → 1 messages, then a `partial` display copy (texts ≤8,000 chars halved to 250 with the "Shortened offline copy" note, tool calls without args/result, ≤24 parts) used only for the offline cold launch; a newer tail that cannot be admitted never deletes the older one, which is kept and marked `stale` | `R:src/transcript-persistence.ts:221-291` |
| What is stored | backend-truth messages only (no pending/clarify projections); tool results reduced to the collapsed projection (≤64 nodes / 8,192 chars, `R:src/ui-chat/tool-presentation.ts:1-27`) plus `display_payload_ref`; **no image bytes** (media keys only, §6.6) | keeps entries small; full output is re-read on tap (§8.8) |
| Entries | **64** chats | a bot roster fits; the stale-refresh pass already limits network work (§4.1) |
| Total | **16 MiB** on disk | — |
| Eviction | LRU by last read *or* write (a read touches it); evict the least recent until both the count and byte caps hold; never evict the chat on screen | web rule (`:293-299`) with bigger caps |
| In memory | decoded entries for the ≤8 most recent chats | covers the warm cache (4 chats, §7.1) + prefetch |
| Writes | debounced 100 ms, coalesced per chat, atomic file replace off the main thread; flushed on background | `R:src/transcript-persistence.ts:214-220` |
| Invalidation | exactly §7.2's list (delete, failed resume, profile rename, sign-out purge, gateway removed) | — |

**How many messages fill the first frame of a tall phone.** Tallest current iPhone viewport: 956 pt (440 × 956, Pro Max
class). The transcript runs under the glass header and composer, so the whole height must be filled. The smallest message
is a one-line bubble: 17 pt × 1.3 line height ≈ 22 pt + 6 + 6 pt padding + 2 × 1 pt border ≈ **36 pt**, plus a 2 pt gap
inside a run (`06-native-feel-and-design.md` §2.1-§2.2; `R:src/phone-ui-chat.css:23-25`, `:41`, `:72-79`). Worst case
(every message one line, default Large text): ≈ 38 pt per message, 956 / 38 ⇒ **26 messages**; at the smallest Dynamic
Type (xSmall, 14 pt body) ≈ 34 pt per message ⇒ **28**. Day separators (≥ 1800 s gaps) and any multi-line or tool row only lower the count.
So 40 cached messages always fill the first frame with ≥ 10 to spare. Note the web paints only the newest
**24 backend rows** of the cache (`openWindow`, §4.2) to match the first REST page; in the all-one-liners worst case that
is ≈ 914 pt, a few points short of a Pro Max screen, which the background older page (§5.2) fills moments later.
Native M1 keeps the 24-row window and the 24-row first page for parity (offsets, `atTurn`, splice rules all assume it).

### 7.3 Prefetch flights (memory only)

At most 32 flights / 2 MB (an open's own flight is exempt from size eviction), flight usable 8 s, a landed read usable
1 s, 256 metadata entries; dropped when the app backgrounds or on memory pressure; reset on page hide or account change
(`R:src/open-prefetch.ts:30-118`, `:299-306`).

### 7.4 Cold-launch cached conversation

If the user enabled `display.resume_last_session` (read from `/api/config` → `display.resume_last_session`, boolean
required) the app remembers the last open chat route (`R:src/cached-conversation.ts:35-46`, `:64-78`):
`localStorage["dispatch.cachedConversation.v1"] = {"version":1,"owner":"<account identity>","profile":"default","enabled":true,"path":"<route>"}`.
On a cold launch that starts from cached credentials **before** the gateway connects, the app reopens that chat
immediately from the tail cache (partial copies allowed) if all hold: not an auth rejection, no deep link, owner and
profile match, the phone's last screen was that chat, and the entry has 1–40 messages each with string `id`, role
`user|assistant|system` and a `parts` array (`R:src/cached-conversation.ts:80-101`). It is read-only presentation;
any runtime or store publication replaces it (`R:src/cached-conversation-view.ts:1-7`). The performance fixture
enables this explicitly (`R:scripts/performance-fixture-gateway.py:63-70`).

### 7.5 Merge algorithms (normative)

- **`spliceTail(saved, fresh)`** (`R:src/open-page.ts:189-202`) — saved tail + fresh newest page: find the first fresh
  message whose `rowId` exists in `saved` with the same `serverRowSpan`; result = `saved[0..<thatIndex] + fresh[join...]`.
  Refuse (null) when there's no join, when saved rows before the join cover fewer backend rows than the fresh rows before
  it, or when any kept saved message is `pending`.
- **`mergeOlderTranscriptPage(existing, older)`** (`V:app/chat/transcript-backfill.ts:44-117`) — for each older message
  find its anchor in `existing` by `rowId` then `id`; non-anchored messages are inserted before the next anchor (or after
  the last anchor / at the start). Returns `existing` unchanged (same reference) when nothing is new; never merges into
  an empty store.
- **`graftRefreshedTailOntoBackfill(fresh, previous)`** (`V:app/chat/transcript-backfill.ts:276-333`) — refreshed
  newest page onto a store that holds older rows: anchor = first fresh message with a `rowId`; if it is `previous[0]`,
  take fresh; if every `previous` row before the anchor has a smaller `rowId`, keep that prefix (minus page-local
  unstored rows the page re-emits) + fresh; if the page covers every on-screen row, take fresh; else merge by `rowId`
  ascending, fresh wins, unstored rows travel with the next stored row, trailing unstored rows last; a page sharing no
  `rowId` with the screen (compaction rewrite / different session) replaces it (`:225-274`). Finally
  `retainCompletedTurnTools` keeps finished tool parts of the last turn that a text-only refresh omitted (`:142-209`).
- **Reference preservation:** when the reconciled transcript is equivalent to what is shown, keep the old array/objects
  so nothing re-renders or re-highlights (`V:…/index.ts:1789-1801`).

### 7.6 Refresh probe for an open chat

`readChangedTail` (`R:src/transcript-tail-probe.ts:82-102`):
1. If the last refresh of this chat left exactly the messages now shown (or <5 s ago and the newest held row is the same
   row), read `limit=1&order=latest&include_compacted=true`; if `order` echoes `latest` and the newest row's signature
   (`rowId:jsonLength:FNV-1a`) equals the remembered one → **unchanged**, stop (`:12`, `:31-54`).
2. Else read `limit=24` (`SMALL_TAIL_ROWS`, `:14`); accept it if fewer than 24 rows came back (whole chat) or any row id is
   already held; else fall back to the full 120-row page (`:93-99`).
3. Memo of the last sync: ≤64 chats (`:16`, `:57-63`). Triggers: a `sessions.changed` pass (throttled to one per 10 s,
   leading edge when the last pass is ≥10 s old, else one trailing pass; §7.7), reconnect, truncated replay, turn end
   (`R:build/r2-network-gates.ts:1-70`, `R:src/turn-end-read.ts:1-11`). *(Earlier drafts said "trailing ~10 s pass";
   the scheduler fires at once when the gap has already passed, `R:src/phone-visibility.ts:112-118`.)*

### 7.7 Change broadcasts (`sessions.changed`, `cron.changed`) and refetch debouncing

**Wire.** The gateway's change watcher (one thread, 0.5 s loop) broadcasts session-less events to **every** connected
socket (`H:tui_gateway/change_watcher.py:337-351`, `H:tui_gateway/server.py:746-762`). The payload is always `{}` and
`session_id` is the empty string (`ChangeSignalPayload`, "payload is {} today", `H:tui_gateway/contracts/events.py:734-742`;
frame builder `H:tui_gateway/server.py:701-704`, called with `""` at `:757`):

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"sessions.changed","session_id":"","payload":{}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"cron.changed","session_id":"","payload":{}}}
```

| Event | Checked every | Signature | Server floor | Source |
|---|---|---|---|---|
| `sessions.changed` | 0.5 s | blake2b digest of these `sessions` columns, per state.db of the active **and every served profile**: `id, source, session_key, display_name, model, parent_session_id, started_at, ended_at, end_reason, message_count, tool_call_count, cwd, git_branch, git_repo_root, title, title_source, profile_name, archived, pinned, hidden, last_read_at, handoff_state` (not `last_activity_at`: the heartbeat restamps it) | **2.0 s**, trailing: a change inside the floor keeps the old signature and fires when the window opens | `H:tui_gateway/change_watcher.py:122-130`, `:136-192`, `:195-206`, `:288`, `:301` |
| `cron.changed` | 1.0 s | mtime of `cron/jobs.json` (moves on edits **and** every scheduler tick) | none | `H:tui_gateway/change_watcher.py:280-287` |

The first sighting of each signature is silent (no storm at boot, `H:tui_gateway/change_watcher.py:308-327`). So during a streaming turn in *any* chat
of *any* served profile, `sessions.changed` arrives about every 2 s (each appended row moves `message_count`), and it
never says which chat or profile moved. A client learns that the gateway broadcasts at all from
`gateway.ready.change_events: true` (`V:app/session/hooks/use-message-stream/gateway-event/lifecycle.ts:33-36`); the
web only applies broadcasts from its active source (`:66-93`).

**What the web phone does with each tick** (all of it gated on `change_events` and an open socket,
`V:app/contrib/hooks/use-background-sync.ts:1214`):

| Consumer | Rule on a tick | Source |
|---|---|---|
| **Open chat transcript** (main pane, and a bot chat's tile via `reconcileTileTranscripts`) | throttle: gap **10 s**; fires at once if the last pass is ≥10 s old, else one pass at `lastRun + 10 s`; ticks meanwhile collapse into it. Runs only while a conversation is on screen and the app is foreground (a missed pass runs when the chat comes back). Held while a typing burst is warm (1.5 s after the last key). Skipped while the chat's own turn runs (`$busy`); the read it owed runs **1,200 ms after the turn ends**, and a read made since the turn ended serves any request for **12 s**. Each pass is the probe-first `readChangedTail` (§7.6). | `R:src/phone-visibility.ts:100-129`, `:130-171`; `V:…/use-background-sync.ts:668`, `:970-1001`; `R:build/fe-lists-gates.ts:139-219`; `R:build/plaid-reads-gates.ts:1-60`; `R:src/turn-end-read.ts:1-11` |
| **Sessions list** (`/api/profiles/sessions/sidebar`, ~570 KB on the owner's gateway, plus messaging list, archived list when shown, `projects.tree`) | same throttle with gap **10 s while the Sessions list is on screen, 45 s off it**; never while backgrounded (a missed pass runs when the list shows, at once if its gap has passed). Off the list, a pass first asks the probe (same URL with `recents_limit=1&cron_limit=1&messaging_limit=1`, ~0.7 KB) and reads in full only when its fingerprint differs; on screen it always reads in full. `projects.tree` at most once per 15 s on the phone, one at a time. | `R:src/phone-visibility.ts:130-171`; `R:src/sidebar-probe.ts:1-80`; `R:build/r2-network-gates.ts:80-84`; `R:build/fe-native-gates.ts:394-412` |
| **Live statuses** (`session.active_list {}`) | `idleThrottle`: at most once per **5 s** while any turn runs on this device, else once per **15 s**; the last tick of a burst still lands; one request in flight (a tick during it queues one more) | `R:src/fe-convo-r3.ts:482-500`; gate `R:build/fe-convo-gates.ts:447`; `V:…/use-background-sync.ts:1150-1190` |
| **Bots roster** (`profiles.list` / `profiles.summary`) | **not refreshed by ticks at all**; it polls (02 §3 step 6) | no subscriber outside `use-background-sync.ts` (`grep $sessionsChangeTick`: only `V:…/use-background-sync.ts:23`, `:1190`, `:1279` and `V:store/live-sync.ts`) |
| **Cron list** on `cron.changed` | refetch only while Jobs (or the Sessions list's scheduled section) can show it; a tick while hidden is remembered and refetched once when it shows; backstop poll 5 min (30 s without `change_events`) | `R:build/fe-lists-gates.ts:223-250`; `R:src/phone-visibility.ts:86`; `V:…/use-background-sync.ts:638-639` |

A local write also pokes the same tick (e.g. Unarchive calls `notifySessionsChanged()`, `R:src/phone-chat-menu.tsx:247`).

**Native M1 (decision): one `ChangeSignal` hub, payload ignored.**

1. On `gateway.ready` record `change_events`. Without it, fall back to polls: open chat probe every 10 s while on
   screen, Sessions list per its 02 cadence.
2. Each `sessions.changed` marks three throttles dirty; each throttle is "leading edge if its gap has passed, else one
   trailing run at `lastRun + gap`; never stack":
   - **open chat**: gap 10 s; allowed only while the chat is on screen, the app is active and the chat is not running
     its own turn (its own stream is authoritative; the turn-end read at +1.2 s covers the end); run `readChangedTail`.
     Pause while the keyboard is mid-burst (1.5 s quiet).
   - **Sessions list**: gap 10 s on screen (full read) / 45 s off screen (probe first, full read only on a different
     fingerprint); nothing while backgrounded; catch up on show.
   - **live statuses**: gap 5 s while any turn on this device runs, else 15 s.
3. **Roster:** no tick refresh in M1 (parity). It keeps its own poll. *(Optional later: when `profiles.summary` with
   `if_version` is available, a 10 s-throttled tick refresh while the Bots list is on screen costs one `not_modified`
   frame.)*
4. **Saved tails of chats that are not open:** nothing on the tick; the stale-refresh pass driven by roster changes
   handles them (§4.1).
5. `cron.changed`: refetch the cron list only while a cron surface is visible; else set dirty and refetch on show;
   5 min backstop.
6. Coalesce identical in-flight GETs (§2) so a tick that lands during a reconnect's own refresh joins it
   (`R:src/reconnect-refresh.ts:1-37`, share window 3 s).

---

## 8. Tool calls: compact display

### 8.1 Settings (device-local)

| Setting | Values | Storage | Default |
|---|---|---|---|
| Tool Call Style | `rows` · `bubbles` · `header` ("In Header") | `localStorage["dispatch.toolCallStyle"]` (absent = rows) | rows |
| Tool Calls After Reply | `show` ("Keep") · `hide` ("Hide") | `localStorage["dispatch.toolCalls"]` (`"hide"` or absent) | show |

Sources: `R:src/ui-chat/tool-calls-setting.ts:9-33`; UI copy `R:src/tool-calls-row.tsx:11-35` ("Hide shows each step while
the bot works, then clears them when it replies, like Telegram. A step that failed stays. To see a reply's steps again,
touch and hold it and choose Show Steps."). After Reply is hidden when style = In Header.

### 8.2 Which parts are "steps"

- **Card tools** draw their own surface and are never folded into a run: `clarify, delegate_task, image_generate,
  manage_catalog, manage_connections` and file edits `edit_file, patch, write_file`
  (`V:lib/tool-render-class.ts:11-45`). What each one draws, live and from history: §8.9.
- **Silent tools** draw nothing unless they failed: `react_to_message, todo, todo_list` (`:50-55`). What a failed one
  draws (and the web's todo exception): §8.10.
- Everything else is a run tool (connector/MCP calls are cards only with onboarding on) (`R:src/ui-chat/trail.tsx:46-50`).
- Reasoning parts with text are steps too (the "Thinking/Thought" row) when reasoning display is on
  (`display.show_reasoning`, default true, `V:store/reasoning-disclosure.ts:24-33`).
- A **run** = consecutive run-tool parts; runs separated only by silent parts (empty text, hidden reasoning) chain into
  one (`R:src/ui-chat/trail-model.ts:107-130`).

### 8.3 Run summary wording (`V:components/assistant-ui/tool/run-summary.ts`)

Categories by tool name (`:68-89`): `read_file, search_files, list_files` → explore; `terminal, execute_code` → run;
`web_search, session_search_recall` → search; `web_extract` → read; `browser_navigate` → browse; other `browser_*` →
interact; `vision_analyze` → analyze; `delegate_task` → delegate; file edits → edit; else other. Copy (`:52-63`):

| Category | past / present | noun |
|---|---|---|
| edit | Edited / Editing | file(s) |
| explore | Explored / Exploring | file(s) |
| search | Searched / Searching | query/queries |
| read | Read / Reading | page(s) |
| browse | Opened / Opening | page(s) |
| interact | Performed / Performing | browser action(s) |
| analyze | Analyzed / Analyzing | image(s) |
| run | Ran / Running | command(s) |
| delegate | Delegated / Delegating | task(s) |
| other | Used / Using | tool(s) |

One clause per category in that fixed order; a single item names its target (file basename, `“query”`, host, or the
command only while live), else counts ("Ran 3 commands"); joined with ", " and lower-cased after the first; failures add
"N tool call(s) failed" (`:123-238`, `V:i18n/en.ts:5378`). The present tense applies to the category of the pending call
while live. Rows show `"{summary} · {N}s"` when a duration is known (live turns only; history has none)
(`R:src/ui-chat/trail-model.ts:3-6`). Failure detection: `isError`, `success===false`, `ok===false` or an error message in
the result, unless `success`/`ok` is true (`V:components/assistant-ui/tool/fallback-model/format.ts:110-118`).

### 8.4 Style: Rows (default)

One quiet row per run: glyph (thinking/terminal/file/explore/other) + summary + chevron; tap expands an inset listing each
call as its own row ("Ran 1 command" style for a run of one, whose row opens the step sheet directly); a failed step row
shows trailing meta **`Failed`**; running steps shimmer and are disabled. (`stepMeta` can also say `Exit N`, but the
collapsed step a row is drawn from never carries `exitCode` (`R:src/ui-chat/trail-tool.tsx:42-46`); only the details
sheet's subtitle, built from the full view, shows "Exit 1", `R:src/ui-chat/trail-details.tsx:62-70`)
(`R:src/ui-chat/trail-view.tsx:161-258`, `R:src/ui-chat/trail-model.ts:76-87`). The model also has a `+A −R` meta for
file steps, but nothing on the phone ever sets `added`/`removed` (`R:src/ui-chat/trail-tool.tsx:42-46` builds the step
without them; no other writer in `R:src`), so file rows show **no** counts today (flag F11). Reasoning uses the same row with label
"Thinking" (live), "Thought for {elapsed}", "Thought briefly" (<1 s) or "Thought" (no measured duration, i.e. history)
(`V:components/assistant-ui/thread/message-parts.tsx:228-238`, `V:i18n/en.ts:5059-5062`; gate `R:build/ui-chat-trail-gates.ts:31`).

### 8.5 Style: Bubbles (Telegram progress message)

Each run is a bot bubble with one line per call: emoji + words, a terminal command or code shown under its line in a
code block headed "Shell"/"Python" with a `</>` mark; meta as in Rows; only the latest 8 lines show with a
"⋯ N earlier steps" line to reveal the rest (`R:src/ui-chat/trail-view.tsx:132-155`, `:230-250`). Line wording
(`R:src/ui-chat/tool-line.ts:63-75`):

- `terminal` with a command → text "terminal", code = command; `execute_code` with code → "Running code", code = code.
- Tool with a verb → `"{Verb} {preview}"` (`web_search`/`search_files` use "for": "Searching the web for X"); without
  preview → the verb alone.
- Unknown tool → `name: “preview”` or `name…`.
- Preview = the tool's primary arg (`PRIMARY`, `:28-33`), first array element, single line; paths → basename; URLs → no
  scheme/www/trailing slash; `delegate_task` → the goal or "N tasks"; `skills_list, session_search, memory, todo_list`
  never preview.

Emoji and verb tables: `R:src/ui-chat/tool-line.ts:7-26` (default emoji ⚙️), mirroring Hermes's own Telegram progress
lines.

### 8.6 Style: In Header

No steps in the transcript (kept hidden for their sheets); the chat's status line under the bot name shows the current
step, and tapping it lists the run's steps (`R:src/ui-chat/trail-view.tsx:126-131`, `R:src/ui-chat/steps-run.tsx`).
Thought rows are omitted entirely (`trail-view.tsx:171-172`).

### 8.7 After Reply: Hide

`stepsState(parts, working)`: `working` while the message (or, for the latest turn, the thread) runs; else `failed` if
the last failed tool call has no non-empty text part after it; else `done` (`R:src/ui-chat/tool-calls-setting.ts:43-50`).
With Hide and `done`, the turn's step blocks are hidden unless the user chose **Show Steps** on that reply (session-only
set, `:35-41`). A failed step stays. History that was already done when loaded is hidden with no motion; steps seen
working fold out together: fade 200 ms (opacity 1→0, scale 1→0.97), then one layout commit removes them all, and
everything that moved slides from its old position over 380 ms `cubic-bezier(.3,.1,.2,1)` (`R:src/ui-chat/steps-fold.ts:1-123`,
`R:src/ui-chat/trail-view.tsx:72-110`). A hidden reply carries a marker so its long-press menu offers Show Steps.

### 8.8 Step sheet (tap a step)

Sections in order: Command (terminal) or Input (non-file, non-empty), Output / Error output (stdout/stderr) or Output /
Error (detail), Exit code (non-zero) (`R:src/ui-chat/trail-model.ts:89-103`). Large outputs: if the call has a
`display_payload_ref`, page through `…/content/preview` 20,000 codepoints at a time; Copy fetches `…/content` (8 MiB cap)
(`R:src/ui-chat/trail-tool.tsx:52-120`, §2.4). Collapsed rows never parse big payloads: only a bounded projection of
selected result keys (≤64 nodes, ≤8192 chars) and arg keys (≤32 nodes, ≤4096 chars) is read
(`R:src/ui-chat/tool-presentation.ts:5-27`).

### 8.9 Card tools (drawn in place, never in a run)

Dispatch order for every tool part (`ChainToolFallback`, `V:components/assistant-ui/thread/message-parts.tsx:118-161`):
`todo`/`todo_list` → nothing; a `terminal` call whose command is an inter-agent delivery (`hermes -p <agent> chat … -q
"Message from…"`, `V:components/assistant-ui/thread/agent-delivery.tsx:14-21`) → a compact "Messaging/Messaged <agent>"
notice (`:150-172`); `react_to_message` that succeeded → nothing; a card tool → its card (`TOOL_CARDS`, `:99-105`);
args with connector labels → connector execution row; when the gateway's `display.tool_progress` is off, any other call
that is neither a card nor a failure the user must see draws nothing (`:158-160`); otherwise the generic step (on the
phone `PhoneToolEntry`, gate `R:build/ui-chat-trail-gates.ts:8-11`). `splitRunItems` keeps the turn's order: "read, edit, read" draws a run row, the
edit, then a second run row (`V:components/assistant-ui/tool/fallback.tsx:800-823`).

"Settled without a result" (`result === undefined && completedAt !== undefined`: the turn stopped or the completion
event was lost) sends every card below to the **generic step** instead (`message-parts.tsx:43-44`), so history never
shows a dead interactive card.

| Tool | Live (turn running) | From history (settled) | Falls back to the generic step when | Source |
|---|---|---|---|---|
| **`edit_file`, `patch`, `write_file`** | a standalone step row (no run header), glyph *file*, title from the run summary of this one call: "Editing app.ts" → "Edited app.ts" (basename of `path`/`file`/`filepath`); shimmer while running | same row; tap → details sheet (below) | — (it *is* the generic step on the phone) | `R:src/ui-chat/trail-tool.tsx:32-46`; `R:src/ui-chat/trail.tsx:26-32`; `V:components/assistant-ui/tool/run-summary.ts:118-150` |
| **`clarify`** | the question card (on the phone the live question also takes the composer's place, phone question dock, streaming spec) | **answered** (`result` present) → Q&A card: per response, the question (with a "?" glyph) then the answer (with an "A" glyph); multi-select answers joined ", "; a blank answer reads *No answer* when `status:"unanswered"`, else *Skipped* (italic, tertiary) | result has no `responses` array; or no result and not running | `V:components/assistant-ui/clarify/index.tsx:18-57`; `…/clarify/settled.tsx:14-54`; `…/clarify/parse.ts:47-80`; copy `V:i18n/en.ts:5320-5321` |
| **`delegate_task`** | one row per dispatched task: status glyph (spinner while running), the task's `goal`, meta `model · duration`, live elapsed time, one ticking line of the child's latest activity (from `subagent.*` events) | rows from args + result: goals from `args.tasks[].goal` (or `args.goal`; else `"Task N"`); per `result.results[i]`: `status` `""`/`ok`/`completed` → done (green check), anything else → failed (alert); `summary` as the activity line; `model`; `duration_seconds`. A background dispatch (`result.status:"dispatched"`, `result.goals[]`) shows parked rows (a grey dot, no spinner) | `isError`, or settled without a result | `message-parts.tsx:65-78`; `V:components/assistant-ui/tool/delegate.tsx:63-166`; `…/tool/delegate-model.ts:35-101` |
| **`image_generate`** | a frame at the hinted aspect (`args.aspect_ratio`: `landscape` 16:9 default, `square`, `portrait` 9:16) with an animated placeholder, VoiceOver "Rendering image" | the image from `result.host_image` (else `result.image`), loaded as media (§6.6), fades in; tap → viewer with Save; size from `result.pixel_size` `"WxH"` when present | the result is not an object with `success !== false` and an image path (a failed generation → the failed generic step); settled without a result. A *load* failure of a good path collapses the frame to the link "Open image: <name>" | `message-parts.tsx:46-63`; `V:components/chat/generated-image-result.tsx:14-110`; `V:lib/generated-images.ts:51-80`; copy `V:i18n/en.ts:5369`, `:5585` |
| **`manage_catalog`** | consent card only while the session has an open `connection.request` that owns this call; before it arrives, "preparing" with a spinner | generic step | not live, or result present | `V:components/assistant-ui/catalog-install-tool.tsx:61-83` |
| **`manage_connections`** | MCP targets → MCP setup card; connector targets → connector offer card, only while an owning `connection.request` is open | MCP setup → settled summary of targets; connectors → generic step | not live (connectors); not running (MCP pending) | `message-parts.tsx:96-97`; `V:components/assistant-ui/connector-tool.tsx:147-166`; `V:components/assistant-ui/mcp-setup-tool.tsx:159-182` |

**File-edit details sheet** (`R:src/ui-chat/trail-details.tsx:53-70`): title = the step title ("Edited app.ts"),
subtitle = the full path when it differs from the title; body = the diff panel when the diff is ≤20,000 chars, else a
"Changes" section of plain text paged 20,000 chars at a time; then the usual sections (§8.8) except Input. Copy copies
the diff + sections.

**Where the diff comes from.**
- History: the tool row's `display_metadata.tool_result_metadata.inline_diff` → the part's
  `toolResultMetadata.inline_diff` (`R:build/rendering-fluidity-gates.ts:85-95`; persisted by the gateway's
  `_prepare_tool_result_metadata`, `H:tui_gateway/tool_progress.py:305-321`; shape asserted in
  `H:tests/agent/test_inline_edit_persistence.py:112`).
- Live: the `tool.complete` payload carries `inline_diff` at top level (`payload.update(metadata)`,
  `H:tui_gateway/tool_progress.py:338`), and the gateway emits that `tool.complete` even with tool progress off
  (`:358-362`).
- Fallback: `result.inline_diff` or `result.diff` (`V:components/assistant-ui/tool/fallback-model/index.ts:831-843`).
- Only `patch` reliably persists a diff; a `write_file` *create* often has none after a reload. The desktop hides a
  completed, diff-less, non-failed file edit (`V:components/assistant-ui/tool/fallback.tsx:558-565`); **the phone does
  not** (its `PhoneToolEntry` has no such rule) and shows the row, whose sheet then has no diff. Native M1: follow the
  phone (show the row).

**Diff text → lines** (native must do the same cleanup): strip ANSI escapes and a leading `┊ review diff` line, trim
(`fallback-model/index.ts:801-807`); drop the header zone before the first `@@` — blank lines, `diff --git`, `index `,
`--- `, `+++ `, `similarity `, `rename `, `new file`, `deleted file`, and Hermes's `a/path → b/path` arrow line
(`V:components/chat/diff-lines.tsx:96-135`); classify each line: starts with `+` but not `+++` → added, `-` but not
`---` → removed, else context; drop the one-char marker (`:69-92`). Draw added lines on a green tint, removed on a red
tint, monospace, horizontally scrollable, no wrapping. Example (illustrative; shape per
`H:tests/agent/test_model_metadata.py:93` and the strip rules above):

```json
{"id":42,"role":"tool","tool_call_id":"call_1","tool_name":"patch",
 "content":"{\"success\": true}",
 "display_metadata":{"tool_result_metadata":{"inline_diff":"┊ review diff\na/src/app.py → b/src/app.py\n@@ -1 +1 @@\n-print('before')\n+print('after')"}}}
```
→ step "Edited app.py"; sheet lines: `print('before')` (removed), `print('after')` (added).

**Native M1 (decision).** File edits, clarify (settled Q&A card) and delegate (static rows from args + result, no
live ticker beyond the subagent events the streaming spec already handles) and image_generate (frame + image) are in M1.
`manage_catalog` / `manage_connections` consent cards are **not** in M1 (hosted connectors are off on the phone):
draw them as generic steps live and in history. The inter-agent delivery notice is in M1 (it replaces a raw
`hermes -p … chat` command row).

### 8.10 Silent tools, and what a failed one shows

`react_to_message`, `todo`, `todo_list` draw nothing when they succeed (`V:lib/tool-render-class.ts:46-55`). They are
still *run tools* (not cards), so they sit inside runs and count in the run's summary ("Ran 2 commands, used 1 tool").

- **Failed `react_to_message`** → the generic step: glyph *other*, title "Used 1 tool, 1 tool call failed" (category
  *other* has no target for this tool, plus the failure clause), trailing meta **Failed**, and its sheet shows Input
  (the args) and Error (the error text)
  (`message-parts.tsx:141-143`, `:158-160`; `R:src/ui-chat/trail.tsx:26-32`; `R:src/ui-chat/trail-model.ts:82-103`;
  `V:components/assistant-ui/tool/run-summary.ts:228-232`, `V:i18n/en.ts:5378`). Alone it is its own row; inside a run
  it is one of the run's step rows and the run header gains ", 1 tool call failed".
- **Failed `todo` / `todo_list`** → **nothing in the transcript today**: `ChainToolFallback` returns `null` for todo
  names before it looks at the error (`message-parts.tsx:121-124`), contrary to the comment in
  `V:lib/tool-render-class.ts:46-49` ("Both still render when they FAIL"). Alone, the phone wraps it in a run-of-one
  whose only child renders nothing, so no row appears either. The todo panel (above the composer) is the only place the
  list shows (flag F12).
- **Web oddity:** a run made *only* of successful silent calls (e.g. a lone `todo`) still draws a run row "Used 1 tool"
  with an empty inset, because the run header counts every tool part while the children render nothing
  (`R:src/ui-chat/trail.tsx:73-77` finds 0 visible parts, so no run-of-one; `V:…/tool/fallback.tsx:881-958` counts all;
  read from code, not observed on a device).
  Failure detection for all of the above: `isError`, `success === false`, `ok === false`, or an error message in the
  result, unless `success`/`ok` is true (§8.3).

**Native M1 (decision):** drop successful silent calls from runs entirely (they neither count in the summary nor
make a row; a run left empty draws nothing). A failed silent call — **including a failed todo** — draws the failed
generic step described above. This deviates from the web in two small ways (no empty "Used 1 tool" row; failed todos
visible) and follows the stated intent of `tool-render-class.ts:46-49`.

---

## 9. Markdown & code rendering

Assistant text (and user bubbles) render through Streamdown 2.5.0 with marked GFM lexing
(`V:components/assistant-ui/markdown-text.tsx:791-810`, `R:src/markdown/pure-parser.ts:8-12`, `V:../package.json:151`).

### 9.1 Features that matter (in observed priority)

| Feature | Behaviour | Source |
|---|---|---|
| Fenced code with language | Card with language label + copy; Shiki highlighting, deferred while streaming and only for code on screen; plain monospace until highlighted. `mermaid`/`svg` fences have lazy renderers; large `html`/`svg` fences become artifact cards | `markdown-text.tsx:73-102`, `:739-757`; `R:src/visible-syntax.ts:1-30`; `V:lib/artifact-detect.ts:110-140` |
| Inline code | `code` span, always LTR | `markdown-text.tsx:676-683` |
| Paragraph line breaks | **Single newlines are hard breaks** (`remarkSoftBreaks` splits every prose `text` node on `[ \t]*\r?\n[ \t]*` into text + `break`), except inside code/inline code/math; the phone CSS also sets `white-space:pre-line` on reply paragraphs and on list items that hold no block children | `V:lib/remark-soft-breaks.ts:1-35`, `markdown-text.tsx:104`; `R:src/phone-fe-convo.css:302-306` |
| Lists (ul/ol, nested, task lists) | Normal; bubble list indent `min(1.625em, 30px)` | `markdown-text.tsx:714-726`; `R:src/phone-ui-chat.css:70` |
| Links | GFM autolinks + bare URLs (trailing `*` excluded); external links open externally; `#media:<encoded path>` links are file/media chips (§9.4); session refs link to chats | `markdown-text.tsx:675`; `V:lib/markdown-preprocess.ts:69-80` |
| Headings h1–h4 | Vendor: small, 1rem / .9375rem / .875rem / .8125rem, semibold (`markdown-text.tsx:515-520`, `:655-666`). **Phone overrides** (assistant replies, phone width): h1 **1.25em**, h2 **1.125em**, h3 and h4 **1.0625em** of the 17 pt body (≈ 21.3 / 19.1 / 18.1 pt), weight 600, line-height 1.3, letter-spacing −.01em, 1.1em above (not when first), .35em below. h5/h6 have no override (UNKNOWN U7). | `R:src/phone-fe-convo.css:318-325` |
| Tables (GFM) | Horizontally scrollable frame; when it overflows, an "Expand Table" button opens a full-screen sheet; copy as TSV | `markdown-text.tsx:728-737`; `R:src/ui-chat/table-frame.tsx:1-21`; `R:src/ui-chat/table-model.ts:1-2` |
| Blockquote | Left border, muted italic; `> [!NOTE]` etc. become GFM alert callouts | `markdown-text.tsx:697-712` |
| `---` | Quiet vertical space, not a rule | `:685` |
| Math | KaTeX, `$$…$$` and single-dollar `$x$`; `\$` is a literal dollar | `:55-67`; `V:lib/markdown-preprocess.ts:38-60` |
| Images `![]()` | Zoomable inline image | `:738` |
| Raw HTML | Allowed but nesting depth clamped | `V:lib/markdown-preprocess.ts:1001` |

### 9.2 Preprocessing (before parsing; prose only, code fences untouched)

`preprocessMarkdown` (`V:lib/markdown-preprocess.ts:980-1005`): strip `<think|thinking|reasoning|thought|reasoning_scratchpad|scratchpad|analysis>…</…>`
blocks at block boundaries (and hold back a half-arrived opening tag) (`:10-26`) — **native (audit 863,
`ReasoningTags`):** never inside a code fence or an inline code span; an unclosed opening tag hides the rest only
while the reply streams (on its own line) or, once settled, when it opens the reply; Copy, Share, Select Text, Find
and VoiceOver leave the blocks out as the bubble does, and a text part that is only thinking draws no bubble; remove preview markers; scrub
backtick noise; normalise fences and drop empty ones; per prose segment: normalise math delimiters, strip preview targets,
visible-prose fixes, clamp HTML depth, shield directive lines. Streaming text gets a tail-bounded repair of unclosed
markdown (`markdown-text.tsx:106-115`).

### 9.3 Limits / fallbacks

- Text > 200,000 chars → plain text, chunked by 200 lines, only the growing last chunk re-split
  (`markdown-text.tsx:538`, `R:src/markdown/huge-text.ts:1-36`).
- Pathological shapes → plain text: container nesting > 32, list indent > 128, > 500 emphasis delimiters or > 1000 `[`/`<`
  in a paragraph, a run of one char > 1000 (`*`/`_` > 256 outside fences) (`R:src/markdown/complexity.ts:1-79`).
- Footnotes force whole-text parsing (no block splitting) (`R:src/markdown/pure-parser.ts:13`, `:27-29`).
- Render errors fall back to plain text for that message only (`markdown-text.tsx:752-783`).

### 9.4 `MEDIA:` directives

Assistant text `MEDIA:/path/file.ext` (bare, or quoted with `` ` `` `"` `'`) on its own line or inline becomes the markdown
link `[Kind: name](#media:<encodeURIComponent(path)>)`; bare captures shed trailing `.,;:!?`; only plausible paths
(a separator, or a dot followed by content) convert (`V:lib/chat-messages/parts.ts:100-206`, `V:lib/media.ts:78-80`,
`:407-412`). Kind is derived from the extension (image/video/audio/file). A `#media:` href renders as: a Markdown
document or any non-media file → a file card with "Open preview"; image/audio/video → an inline media attachment
(`MarkdownLink`, `V:components/assistant-ui/markdown-text.tsx:284-305`, `V:lib/media.ts:287-297`). A plain filesystem
href (`/…`, `file://…`, `~/…`, `C:\…`) is treated the same way (`markdown-text.tsx:320-341`).

### 9.5 The M1 subset on swift-markdown (decision)

The web runs Streamdown 2.5.0 (remark/rehype with GFM, KaTeX, raw HTML, Shiki, mermaid). Native M1 parses with
swift-markdown (cmark-gfm). Pipeline: §9.2 preprocessing (M1 part) → `Document(parsing:options:)` with
**`.disableSmartOpts`** (cmark's smart punctuation would turn `--` into "–" and straight quotes into curly ones; the web
shows them as typed) → a renderer that walks the tree into attributed text runs + block views.

| Feature | M1 | How (native) | Web today |
|---|---|---|---|
| Single newline in prose | **in** | render every `SoftBreak` as a line break inside paragraphs, list items and blockquotes; never touch `CodeBlock`/`InlineCode` text. cmark already drops the spaces around the newline, which is what the web's split regex does | `remarkSoftBreaks` (§9.1) |
| Paragraph spacing | in | `--paragraph-gap` between blocks; none above the first / below the last | `markdown-text.tsx:535` |
| Emphasis, strong, ~~strikethrough~~ | in | GFM strikethrough extension | GFM |
| Inline code | in | monospace 0.9em, inline radius 6 pt, forced LTR | `markdown-text.tsx:676-683`; `R:src/phone-ui-chat.css:144` |
| Fenced / indented code | in | card: language label + Copy; **plain monospace, no highlighting in M1**; horizontal scroll, no wrap; empty fences dropped by preprocessing | Shiki, deferred while streaming (§9.1) |
| Headings | in | h1 1.25em, h2 1.125em, h3–h4 1.0625em of body, semibold, line height 1.3, 1.1em above (not first), .35em below; **h5/h6 = the h4 style** (decision; web has no phone rule, U7) | `R:src/phone-fe-convo.css:318-325` |
| Lists (nested, ordered with start number, task lists) | in | GFM task-list checkboxes drawn read-only; marker colour label-3 | GFM |
| Links | in | `[text](https://…)` opens externally; **bare URLs** autolinked by the web's own rule, applied to text nodes after parsing (not cmark's autolink extension, so both clients agree): `` https?://[^\s<>"'`*]+[^\s<>"'`*.,;:!?] `` — `*` never joins a URL, trailing `.,;:!?` peel off; skip text inside existing links and code. **Audit 863:** as the web's `bareUrlEnd` now does, a trailing `)` or `]` the address didn't open peels off too (`(see https://x/page)` links `…/page`); full-width punctuation (`。，、；：！？（）「」『』【】《》〈〉`) ends an address; a bare address's `_` and `~` are escaped before parsing, so `_draft_` or `~~` inside it never splits the link | `V:lib/markdown-preprocess.ts:69-76`, `:425-470` |
| Blockquote | in | leading 2 pt bar (stroke-3), secondary colour, italic | `markdown-text.tsx:697-712` |
| GFM alerts `> [!NOTE]` | **in** | a blockquote whose first text starts with `[!note\|tip\|important\|warning\|caution]` (case-insensitive) followed by optional spaces and one newline: drop the marker (and that newline), draw a rounded callout (radius 8, Fill 4 background, hairline border) with a 13 pt semibold title "Note"/"Tip"/"Important"/"Warning"/"Caution" and its glyph in blue/green/violet/amber/red | `V:components/assistant-ui/embeds/alert.tsx:6`, `:15-21`, `:23`, `:99-130` |
| Tables (GFM) | in | horizontally scrollable grid; header row muted; cells 13 pt, top-aligned, 6×10 pt padding; "Expand Table" sheet when it overflows (06 §3) | `markdown-text.tsx:728-737` |
| `---` | in | **12 pt of empty space, no rule** | `markdown-text.tsx:685` (`my-3`) |
| Images `![alt](src)` | in | `https:`/`data:` → inline image (zoomable, max 192 pt tall); file path → media fetch (§6.6); `alt` is the VoiceOver label | `markdown-text.tsx:738` |
| `MEDIA:` directives → `#media:` links; file-path links | in | §9.4 conversion in preprocessing; render: image kinds → inline image (§6.6); audio/video/other files/.md → a file chip (glyph + name) that downloads via `/api/fs/download` and opens Quick Look / share | §9.4 |
| Reasoning-tag blocks (`<think>`, `<thinking>`, `<reasoning>`, `<thought>`, `<reasoning_scratchpad>`, `<scratchpad>`, `<analysis>`) and `[Preview:…](#preview…)` markers | in (strip) | preprocessing, as §9.2 | §9.2 |
| Size / complexity limits | in | §9.3 rules (200,000-char plain fallback; pathological shapes → plain text) | §9.3 |
| Math `$$…$$`, `\[…\]`, `$…$` | **out** | a display-math block (`$$` on its own lines, or `\[`/`\]` lines) shows its TeX source in a monospace block; inline `$…$` stays literal text (no currency guessing) | KaTeX with single-dollar math (`markdown-text.tsx:67`) |
| ```` ```mermaid ```` / ```` ```svg ```` fences | **out** | ordinary code block | lazy diagram / SVG renderers |
| Artifact cards (html doc ≥160 chars, html fragment ≥1,200, svg ≥2,000, code ≥48 lines or ≥3,000 chars) | **out** | ordinary code block | `V:lib/artifact-detect.ts:28-31`, `:110-140` |
| Raw HTML | **out** | `HTMLBlock` / `InlineHTML` drawn as literal text, except `<br>`, `<br/>`, `<br />` → line break (common in table cells) | allowed, nesting depth clamped (`V:lib/markdown-preprocess.ts:1001`) |
| Footnotes `[^1]` | **out** | literal text (swift-markdown does not expose cmark's footnote extension) | supported; forces whole-text parsing (`R:src/markdown/pure-parser.ts:13`, `:27-29`) |
| Session-reference links | **out** | the link text, plain | session chips (`markdown-text.tsx:315-318`) |

User bubbles: the web renders your own text through a minimal pipeline (inline code, fences, directive chips)
(`V:components/assistant-ui/thread/user-message.tsx:378-393`); native M1 shows your text as plain text with single
newlines kept and `@file:`/`@url:` refs as chips, `@image:` refs as the thumbnail row (§6.6).

---

**DECISION (2026-10-26, tester: "inline MD rendering in chats would be nice … this might be too weird
looking"; brief `docs/briefs/agent-images-markdown.md`).** Audit: bot replies already render the full subset, finished
and while streaming (re-parsed on each delta; only syntax colouring and link chips wait for the end). Your own messages
were plain text. They now render **inline markdown and code fences only** (`UserMarkdown` in `MarkdownRenderer.swift`):
bold, italic, strikethrough, inline code (tap copies), links, bare https links, and fenced code as a code card. Every
line-level construct (headings, lists, quotes, tables, rules, HTML blocks, indented code, link definitions) stays
exactly as typed (its marker is escaped; leading spaces become no-break spaces), so a typed "- item" or "# note" is not
restyled. The web draws only code spans and fences in your bubble (`V:components/assistant-ui/thread/user-message-text.tsx:8-12`);
inline styles go one step further because the tester asked for them, and keeping the lines' shape answers the "weird
looking" worry. A message with none of `*`, `_`, `~`, backtick, `[` or `http` draws exactly as before. Copy keeps what
you typed; VoiceOver reads it as drawn. Not changed: the composer (plain while typing), tool output, thinking rows,
delivery rows and previews stay plain; `---` stays quiet space. No raw/rendered option: nothing the web renders is left raw.

## 10. What a turn looks like (phone)

Phone bubbles are on when the `PHONE_CHAT_BUBBLES` flag is on in phone layout (`R:src/ui-chat/bubble.tsx:26`).

**Day break** before a message when it is the first timed message, crosses a local date, or follows a ≥30-minute gap;
label `"Today 9:14 AM"`, `"Yesterday …"`, or `"Sep 26 9:14 AM"` (year added when not this year)
(`R:src/ui-chat/run.ts:162-170`).

**Runs**: consecutive messages from the same sender and source, each ≤300 s after the previous, form a run with positions
single/first/middle/last (`R:src/ui-chat/run.ts:25`, `:88-123`). Only you/reply/delivery messages join runs.

**Your message**: trailing bubble, width fits text up to `min(80%, 320pt)`, radius 18, padding 6×12, fill = app tint
(dark mode: tint 75% mixed with black), text auto black/white for contrast; the last bubble of a run gets a tail at the
bottom-trailing corner (8×17 pt mask, corner squared) and inner corners between run members shrink to 6 pt; long text
clamps at 10 lines with a "more" control (`R:src/phone-ui-chat.css:23-56`, `:86-117`; `R:src/phone-ios-tokens.css:51-55`,
`:116-119`). Attachments row under it.

**Bot reply** (one assistant `ChatMessage` = one turn), top to bottom in part order:
1. Thought row ("Thinking"/"Thought…") if reasoning exists and reasoning display is on (§8.4).
2. Each tool run as a Rows/Bubbles block per §8 (or nothing for In Header / hidden after reply).
3. **Each prose text part in its own bot bubble**: leading, `max-width:100%` of the column, radius 18, padding 6×12, fill
   `#e9e9eb` light / `#26282c` dark, 17 pt body (Dynamic Type scaled), line height 1.3; 6 pt above the first bubble after
   other content, 2 pt between consecutive bubbles; tail at bottom-leading corner on the last bubble of the run
   (`R:src/phone-ui-chat.css:66-125`, `R:src/phone-ios-tokens.css:47-49`). The bot's name (in its colour) leads the first
   bubble of a run only after another bot has spoken in this chat (`R:src/ui-chat/bubble.tsx:96-109`, `run.ts:108-121`).
4. The newest reply only: an action row — Copy · Read Aloud · Regenerate · More (`R:build/ui-chat-gates.ts:86-87`,
   `R:src/ui-chat/run.ts:128-137`).

**One time per run** (owner, 2026-09-30): every bubble *carries* a time element — each prose bubble is given its own
text part's `timestamp`, not the turn start (`R:build/ui-chat-gates.ts:82`; `R:src/ui-chat/bubble.tsx:96-108`) — but the
phone **hides the time and its reserved width on every bubble except the one that ends a run**: the last prose bubble
of a reply whose run position is `single`/`last`, your last message of a run, a delivery run's last bubble
(`R:src/phone-ui-chat.css:136-141`; matches 06 §2.4). *(An earlier draft of this section said "time inside every
bubble"; that is the DOM, not what is drawn.)* The shown time sits at the bottom-trailing corner (10 pt from the trailing
edge, 5 pt from the bottom), caption-2 size capped at 20 px, tabular digits, label-2, format `"9:14 AM"` per device
locale/12-24 h; only that bubble's last text line reserves its width so text never runs under it
(`R:src/ui-chat/run.ts:140-148`, `R:src/phone-ui-chat.css:28`, `:46-53`); the bubbles that hide it get 6 pt bottom
padding instead (`:139`). Menus/VoiceOver use `messageWhen`: "9:14 AM", "Yesterday 9:14 PM", "Sep 26, 9:14 PM"
(`run.ts:150-160`).

**Deliveries** (another bot or a cron job writing into this chat): incoming bubble with the sender's head (28 pt) beside
the run's last bubble, the sender name (and job name) on the first line (`R:src/ui-chat/bubble.tsx:111-134`).

**System notices** (model changed, background work finished, failed turn…): centered timeline rows, no bubble (§6.5).

**VoiceOver**: "{Bot} said:" / "You said:" before each message once per reply (`R:src/ui-chat/bubble.tsx:85-88`).

---

## 11. Fixture payloads (verbatim from code)

**F-a. Replay fixture core REST page** (`R:scripts/gateway-replay.py:361-377`):
```json
{"session_id":"20260101_000000_d15a7c0a","profile":"default","messages":[
 {"id":1,"session_id":"20260101_000000_d15a7c0a","role":"user","timestamp":1767225600.0,"active":1,"compacted":0,
  "content":"Do not use any tools. Reply with the single word OK.\n@image:/dispatch-replay-fixture/qa-image.png\n[screenshot]",
  "tool_call_id":null,"tool_calls":null,"tool_name":null,"reasoning":null,"display_kind":null,"display_metadata":null},
 {"id":2,"session_id":"20260101_000000_d15a7c0a","role":"assistant","timestamp":1767225604.0,"active":1,"compacted":0,
  "content":"OK","finish_reason":"stop",
  "tool_call_id":null,"tool_calls":null,"tool_name":null,"reasoning":null,"display_kind":null,"display_metadata":null}],
 "pagination":{"limit":120,"offset":0,"order":"latest","returned":2}}
```
→ user message text "Do not use any tools. Reply with the single word OK." with
`attachmentRefs:["@image:/dispatch-replay-fixture/qa-image.png"]` (the `[screenshot]` line removed); assistant "OK".

**F-b. Performance fixture paged read** (`R:scripts/performance-fixture-gateway.py:98-110`): request
`?profile=default&limit=24&order=latest&include_compacted=true` →
```json
{"session_id":"20260929_120000_aabbcc01","profile":"default","messages":[ /* 24 rows, chronological */ ],
 "pagination":{"limit":24,"offset":0,"order":"latest","returned":24,"has_more":true,"next_offset":24}}
```
Rows seeded by `POST /__fixture/history {"count":1000,"profile":"default","long_turn":false,"non_dense":false}`:
`{"role":"user"|"assistant","content":"Synthetic history row {i}. Readable history. …","row_id":N,"timestamp":<int s>}`
(`:111-126`; `non_dense` skips 3 ids per row to prove ids aren't dense; `long_turn` makes one user row then all assistant).

**F-c. Performance fixture `/messages/around` and `/timeline`** (`:78-96`), after seeding 1000 rows:
`GET …/messages/around?row_id=2&limit=120` →
```json
{"messages":[…120 rows…],"pagination":{"offset":0,"returned":120,"limit":120,"has_older":false,"has_newer":true,"next_offset":120,"total":1000}}
```
`GET …/timeline?limit=2` →
```json
{"entries":[{"row_id":2,"preview":"Synthetic history row 0. Readable history. …","timestamp":<int s>},
            {"row_id":4,"preview":"Synthetic history row 2. Readable history. …","timestamp":<int s>}],
 "pagination":{"has_more":true,"next_cursor":4}}
```
(The fixture omits `session_id`/`profile` and the `row_id`/`order` pagination keys real Hermes sends; previews are the
first 120 chars of the row.)

**F-d. Live tool events alongside stored rows** (`R:scripts/performance-fixture-gateway.py:25-44`):
`tool.start {"name":"terminal","tool_id":"performance-tool-0","args":{"command":"printf synthetic-step-0","timeout":5}}`,
`tool.complete {…,"result":{"stdout":"synthetic output\n…","stderr":"","exit_code":0}}`,
`message.complete {"text":"…","row_id":43}`; each wrapped as
`{"jsonrpc":"2.0","method":"event","params":{"type":"…","session_id":"<runtime id>","payload":{…}}}`
(`R:scripts/build47-fixture-gateway.py:42-47`).

**F-e. Build-47 / voice fixtures (non-paged legacy shape)** (`R:scripts/build47-fixture-gateway.py:166-168`,
`R:scripts/action-voice-fixture-gateway.py:117-119`):
```json
{"messages":[{"role":"assistant","content":"Build 47 synthetic acceptance chat.","row_id":1,"timestamp":1790852400}],"total":1,"has_more":false}
```
No `pagination`/`session_id`: the client treats it as the complete transcript (`V:store/transcript-tail.ts:136-139`).

**F-f. Smoke fixture** (`R:scripts/smoke-fixture-gateway.py`) adds no history routes; its chats come from the voice
fixture (F-e). `tools/plaid_gateway.py` does not exist (U1).

---

## 12. Disagreements and flags

- **F1 — `id` vs `row_id`.** Real Hermes REST rows carry `id`; every Python fixture writes `row_id` (F-b…F-e). The client
  reads both (`V:lib/chat-messages/hydration.ts:447`). Native must too.
- **F2 — Pagination fields.** Core Hermes returns only `{limit, offset, order, returned}`; the performance fixture also
  returns `has_more/next_offset`; the plugin adds cursors; build47/voice fixtures return no `pagination` at all. Treat
  `has_more`/`next_offset` as authoritative when present, else infer from `returned >= limit`.
- **F3 — Default `order`.** Omitting `order` with a `limit` gives the **oldest** page on core Hermes (`sessions.py:738-739`)
  and on the plugin; always send `order`.
- **F4 — "around" starts at the prompt**, it is not centered (`sessions.py:810`, fixture `:91-95`).
- **F5 — Vendor default vs phone first page.** Vendor opens with 120 rows (`V:api/sessions.ts:502`); the phone opens with
  24 and back-fills to 120 (`R:src/open-page.ts:1-10`). The renderer's 120-row read still happens as a fallback when
  the small reads don't join (§7.6, §4.1).
- **F6 — Inline images.** The phone never sends `inline_images=false`, so multimodal rows carry full `data:` URIs (a
  measured conversation was 26 MiB per page, `H:tests/hermes_cli/test_session_messages_inline_images.py:3-8`). Sending
  `false` would replace them with `[image]` and lose the picture. Decision for native: keep the default for milestone 1,
  except the one-row `response-too-large` retry in §6.6.
- **F7 — Plugin contract vs README.** README says omitted limit uses "latest order" and explicit limit "defaults to
  oldest" — matches code (`P:dashboard/plugin_api.py:51-53`). README says the plugin was never verified live (U3).
- **F8 — Stored id on resume.** `stored_session_id` is optional in the contract
  (`H:tui_gateway/contracts/sessions.py:82`); the client reads `session_key || resumed` as the resolved stored id
  (`V:…/index.ts:2065`). Fixtures send all three (`R:scripts/action-voice-fixture-gateway.py:28-29`).
- **F9 — Bubble look is flag-gated, all on in Release.** `PHONE_CHAT_BUBBLES`, `PHONE_WORK_TRAIL`,
  `PHONE_TOOL_BUBBLES` are `true` in Release; `PHONE_TRAIL_APPROVAL` and `PHONE_TURN_STATUS` are `false`
  (`R:src/ui-chat/flags.ts:24-40`). Native should build the released look only.
- **F10 — `sessions.changed` says nothing about which chat moved.** Payload `{}`, `session_id:""`, at most every 2 s
  while any served profile writes rows (§7.7). An earlier draft called the open-chat pass "trailing ~10 s"; it is a
  10 s throttle that fires at once when the gap has passed (`R:src/phone-visibility.ts:112-118`). The Bots roster does
  not listen to it at all.
- **F11 — File-edit `+A −R` counts are never shown on the phone.** `stepMeta` supports them but no code sets
  `added`/`removed` (§8.4). The desktop row shows them (`V:components/assistant-ui/tool/fallback.tsx:506-509`,
  `:619-628`). Native M1 may compute them from the diff lines (cheap) — a deliberate improvement, not parity.
- **F12 — Silent-tool rendering contradicts its own comment.** `tool-render-class.ts:46-49` says failed silent tools
  render; `ChainToolFallback` drops todo calls before checking the error (`message-parts.tsx:121-124`), and a run of
  only successful silent calls draws an empty "Used 1 tool" row. Native M1 fixes both (§8.10).
- **F13 — Resume params differ per call site, and fixtures don't show the deferred reply.** Six param sets (§3.1.1);
  one omits `omit_messages` (a full-transcript reply). Real deferred replies carry `hydrating:true`,
  `status:"resuming"` and no `messages_omitted`/`stored_session_id` (§3.1.2); the Python fixtures always answer the
  reuse shape.
- **F14 — Heading sizes.** The vendor's sizes (h1 = 1rem, smaller than the 17 pt body) are overridden on phone width
  (h1 1.25em …, `R:src/phone-fe-convo.css:318-325`). An earlier draft of §9.1 gave only the vendor sizes.
- **F15 — Timestamps (critic).** "Time inside every bubble" described the DOM; the phone draws one time per run (§10,
  06 §2.4). Round-9 decision D1 ("every bubble shows its own time") is older and overridden.
- **F16 — Transcript cache retention vs the architecture note.** `NAT:docs/ARCHITECTURE.md:19-21` budgets a 500-item
  synchronous read; the web keeps 40 messages per chat. M1 keeps 40 (§7.2.1). If the architecture wants 500 for offline
  browsing, that is a post-M1 change and must keep the image-bytes exclusion.
- **F17 — Deliberate native deviations decided in this file:** `defer_history:true` on every resume (§3.1.1);
  `/api/fs/download` instead of `read-data-url` for history images and a smaller-page / `inline_images=false` retry on
  `response-too-large` (§6.6); silent tools dropped from runs and failed todos shown (§8.10); consent cards drawn as
  generic steps (§8.9); math, mermaid/svg diagrams, artifact cards, raw HTML (except `<br>`), footnotes and
  session-ref chips out of M1 (§9.5).

## 13. UNKNOWNs

- **U1** `tools/plaid_gateway.py` is not present in the reference tree, `~/Projects/hermes-ios`, or any sibling checkout;
  `R:.build` (stuck-working/ask gateways) is also absent. No payloads from them.
- **U2** Streamdown's `defaultRemarkPlugins` list could not be read (`node_modules` absent); GFM (tables, task lists,
  strikethrough, autolinks) is inferred from `marked` `{gfm:true}` lexing and Streamdown 2.5.0 docs.
- **U3** Whether the owner's live gateway runs `hermes-hq-performance` (and which version) is not determinable from source;
  native must support both routes.
- **U4** Exact Shiki theme/language set and code-card chrome on the phone (`RichCodeBlock`, `V:components/assistant-ui/embeds`)
  were not traced.
- **U5** The full In-Header status line behaviour (`R:src/ui-chat/steps-run.tsx`) was not traced in detail.
- **U6** The resume `inflight` graft rules (correction offsets, interim bubbles) belong to the streaming spec and are only
  summarised here.
- **U7** h5/h6 styling on the phone: neither the vendor's `HEADING_SIZES` (h1–h4 only) nor the phone CSS (h1–h4) covers
  them, and the Tailwind Typography / preflight defaults that would apply could not be read (`node_modules` absent).
  §9.5 decides "same as h4".
- **U8** Which cmark-gfm extensions swift-markdown's default parse enables (tables, strikethrough and task lists are
  expected; autolink is not relied on — §9.5 autolinks bare URLs itself). Verify at implementation, with
  `.disableSmartOpts`.
- **U9** Whether the owner's gateway advertises `performance.media_thumbnail` (needs Pillow on the gateway,
  `P:adapter.py:202-207`, `P:media.py:61`). §6.6 works with or without it.
- **U10** The 956 pt "tallest phone" viewport in §7.2.1 comes from device knowledge, not from the reference source; the
  owner's phone is 402 pt wide (06 §4), height not stated in source.
- **U11** The exact Hermes text of `inline_diff` (`agent/display.py` `_summarize_rendered_diff_sections`) was not traced
  line by line; §8.9's cleanup rules are the client's, which is what native must match.
