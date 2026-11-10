# 04 — Send a message, stream the reply, Stop

Status: mapping of release-build238 (web app) + Hermes gateway source, for the native Swift rebuild (M1).
Scope: `prompt.submit`, the turn's event stream, how the client folds events into the transcript, Stop
(`session.interrupt`), busy/queued sends, catch-up after a reconnect mid-stream, and replies that do not stream.
Out of scope here (other specs): connecting/auth/tickets, opening a chat (`session.resume`/`session.activate`
in full), history REST paging, attachments, approvals/clarify (server→client requests), voice.

## 0. Sources and notation

| Prefix | Path | Version |
|---|---|---|
| `H/` | `/Users/me/.hermes/hermes-agent/` (the gateway the owner runs; read-only) | git `d94b70f6`, 2026-10-08 |
| `R/` | `/Users/me/Projects/hermes-hq-native-ref238/` (web app, release-build238) | — |
| `V/` | `R/vendor/hermes/apps/desktop/src/` (vendored Hermes Desktop renderer the phone runs) | Hermes `02e41181` (`R/vendor/source.json:2`) |
| `S/` | `R/vendor/hermes/apps/shared/src/` (vendored JSON-RPC client) | same |
| `B/` | `R/build/` — build-time source gates that rewrite `V/`/`S/` text before bundling | — |
| `P/` | `R/src/` (phone-only code) | — |

**Important:** the shipped app is `V/` + `S/` *after* the `B/` gates are applied (string replacements, see
`B/shared-replay-performance.ts:118-125`, `B/ui-chat-send-gates.ts`). Where a gate changes behaviour this spec
describes the gated (shipped) behaviour and cites both.

The gateway's wire contract is generated from Pydantic models in `H/tui_gateway/contracts/` (source of truth;
`H/tui_gateway/contracts/base.py:1-19`). Fixture gateways (`R/scripts/*gateway*.py`) are simplified and disagree with
the real gateway in places — see §10.

---

## 1. Wire basics this area depends on

### 1.1 Transport

- One WebSocket per gateway: `wss://<host>/api/ws?profile=<primaryProfile>` (ticket/bearer auth is native, see the
  connection spec). The phone **never opens a second socket per bot**: every profile is routed over the primary
  socket (`P/bridge/shim.ts:72-75` returns `sharedPrimary:true`; `V/store/gateway.ts:1225-1226`).
- Each WS text message is exactly one JSON-RPC 2.0 object (`H/tui_gateway/ws.py:195-205` sends one `send_text`
  per frame; inbound is `json.loads(raw.strip())`, `ws.py:408-412`).
- Server handles a connection's requests **one at a time in arrival order** (`H/tui_gateway/ws.py:319-337`).
  `prompt.submit` and `session.interrupt` are inline handlers (not in `_LONG_HANDLERS`, `H/tui_gateway/server.py:181-205`),
  so a slow inline handler delays every later request on that socket.
- Server batches streaming tokens: `message.delta`, `reasoning.delta`, `thinking.delta` are buffered and flushed
  every 33 ms; any other frame flushes the buffer first so order is preserved (`H/tui_gateway/ws.py:82-83`,
  `ws.py:123-150`).

### 1.2 Frame shapes

Request (client→server). Ids are **numbers** in the shipped client (`V/api/client.ts:36` `createRequestId: nextId => nextId`);
heartbeats use string ids `heartbeat-N` (`S/json-rpc-channel.ts:546-558`).

```json
{"jsonrpc":"2.0","id":42,"method":"prompt.submit","params":{"session_id":"01965554","text":"Hello"}}
```

Result / error (server→client) — `H/tui_gateway/server.py:881-887`:

```json
{"jsonrpc":"2.0","id":42,"result":{"status":"streaming","user_row_id":812}}
{"jsonrpc":"2.0","id":42,"error":{"code":4009,"message":"session busy"}}
{"jsonrpc":"2.0","id":42,"error":{"code":4090,"message":"…already has a live owner…","data":{"reason":"SESSION_NOT_OWNED"}}}
```

Event notification — built by `_event_frame` (`H/tui_gateway/server.py:701-704`), then stamped with a per-session
monotonic `seq` **inside `params`** (`H/tui_gateway/event_replay.py:67-111`). `payload` is **omitted** when the
emitter passes none (e.g. `message.start`):

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"01965554","seq":5}}
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"01965554","payload":{"text":"Hel"},"seq":6}}
```

- `session_id` in an event is the **runtime** id (8 hex chars, `uuid4().hex[:8]`, `H/tui_gateway/methods_session.py:67`;
  live example `"01965554"` in `R/artifacts/stage2/test-session.json:3`), never the stored id (`20260925_120000_ab12cd`).
- Session-less broadcasts have `session_id: ""` and **no** `seq` (`event_replay.py:74-77`).
- A frame with string `id` + `method` (not `"event"`) is a server→client request (approval, clarify…;
  `S/json-rpc-channel.ts:61-62`) — out of scope, but note they can arrive mid-turn.

### 1.3 Params are strict

Every method's params are validated against its contract; **an unknown key is rejected with `4000`**
(`H/tui_gateway/contracts/registry.py:94-110`, `H/tui_gateway/rpc_dispatch.py:27-31`). Do not invent fields
(e.g. no `client_message_id` — see §2.5).

### 1.4 `profile` on session-scoped calls — DECISION: always name it

`profile` is optional on every method in this spec (`SessionParams` / `ProfileParams`,
`H/tui_gateway/contracts/common.py:224-234`; `session.archive` / `session.set_hidden` declare it too,
`H/tui_gateway/contracts/sessions.py:324-347`), so sending it never trips the strict-params `4000` (§1.3).

**Server behaviour (source of truth).**
- WS RPCs: an omitted or empty `params.profile` means the gateway's **launch profile** (the `HERMES_HOME` the process
  started under, `H/tui_gateway/server.py:56`), not any client notion of "primary": `_profile_home(None)` → `None` → the
  shared launch store (`server.py:575-578`; `_profile_db`, `server.py:497-511`). A name that resolves to the launch home
  is canonicalised back to `None` (`server.py:586-587`), so **naming the launch profile is identical to omitting it**. An
  unknown name fails closed: `4064 Profile '<name>' does not exist.` (`server.py:584-585`,
  `H/tui_gateway/rpc_dispatch.py:35-36`).
- The socket URL's `?profile=` is **ignored** by `/api/ws`: the route passes nothing profile-related to `handle_ws`
  (`H/hermes_cli/web_routers/chat_ws.py:701-719`); only `/api/console` (`:307`) and `/api/pty` (`:562`) read that query.
  The phone's `wss://…/api/ws?profile=<primary>` (`P/bridge/shim.ts:75`) scopes nothing.
- REST: an omitted `?profile=` means the serving process's own `state.db` (`H/hermes_cli/web_server_sessions.py:192-200`);
  `?profile=<name>` opens that profile's store (`H/hermes_cli/web_server_cron.py:113-124`; `default` = the root
  `~/.hermes`, `H/hermes_cli/profiles.py:426-430`); unknown → HTTP 404 `Profile '<name>' does not exist.`
  (`web_server_cron.py:122-123`).
- Where it changes the answer: methods that look up a **stored** id or create/list rows. `session.resume` reads the
  stored row only from the named profile's store (`_Resume.profile`, `H/tui_gateway/methods_session.py:630-632`) and
  reuses a live runtime only when it lives in that same profile home (`:1076-1078`), else `4007 "session not found"`
  (`:807-829`); likewise `session.create` (`:342,395`), `session.list` / `session.most_recent` (`:36-44,549-551,576-580`),
  `session.delete` (`:1193-1194`), `session.archive` / `session.set_hidden` (`:1270,1300`). Methods addressed by a
  **live runtime id** (`prompt.submit`, `session.interrupt`, `session.redirect`, `session.activate`,
  `session.events.since`) find the session by `session_id` alone (`_sess_nowait`, `server.py:1229-1245`) and use the
  session's own store; there `profile` only matters to hosted rooms (`H/tui_gateway/methods_prompt.py:291-296`) and to
  `_profile_scoped` handlers, where an explicit name wins over the session's home (`server.py:604-629`).
  `session.active_list` ignores it (`methods_session.py:1152-1163`).

**What the shipped web client does (inconsistent between WS and REST).**
- WS: omits `profile` when the session's owner equals the renderer's `g.primaryProfile` (`V/store/gateway.ts:1213-1214`
  `scopeProfile:false`, used at `:1306`; registry route `:1361-1362`) and adds it for every other bot
  (`:1225-1226`, `:1365-1366`). `g.primaryProfile` is the connection descriptor's profile
  (`V/app/gateway/hooks/use-gateway-boot.ts:695-731`), which the phone shim fills from localStorage `ios.defaultProfile`,
  default `'default'` (`P/bridge/shim.ts:52,71-75`; `P/bridge/renderer-host.ts:8-10,27`), changed only by the user's
  Default Profile setting (`renderer-host.ts:123`). It is never compared with the gateway's launch profile.
- Exception on WS: the stale-runtime recovery `session.resume` names the session row's own `profile`
  (`V/app/session/hooks/use-prompt-actions/utils.ts:123-132` via `resolveSessionProfile`,
  `V/app/session/hooks/use-session-actions/utils.ts:2211-2219`); REST rows carry the serving profile name
  (`H/hermes_cli/web_routers/sessions.py:762`).
- REST: always explicit. The API scope profile is the active gateway profile, normalised so it is never empty
  (`V/store/profile.ts:452-454`, `V/api/client.ts:64-66,75-81`); `getSessionMessages` puts it first in the query
  (`V/api/sessions.ts:463-467`), and the shim turns a request's `profile` field into `?profile=` unless the path
  already carries one (`P/bridge/shim.ts:35-44,88`; the session helpers always pass it). So the phone reads `GET /api/sessions/<id>/messages?profile=default&…` but sends
  `prompt.submit` for the same chat with no `profile`.
- The two agree only while `ios.defaultProfile` equals the launch profile (true for the owner's standard `~/.hermes`
  launch). If the gateway runs as another profile (`HERMES_HOME=~/.hermes/profiles/ivy`) or the user picks another
  Default Profile, the "primary" bot's WS calls hit the launch store while REST reads `default`'s: resume answers
  `4007 session not found`, new chats are created in the wrong profile, and history and live state disagree.

**Native decision.**
1. Send `"profile":"<bot's profile name>"` on **every** session-scoped RPC (`prompt.submit`, `session.create`,
   `session.resume`, `session.activate`, `session.interrupt`, `session.redirect`, `session.events.since`, …), the launch
   profile's bot included. Use the roster's canonical name (`/api/profiles` `name`).
2. Append `?profile=<same name>` to **every** profile-scoped REST call (session list, session, messages, …), as the
   shim does.
3. Use the same name for a session on every call. Explicit and omitted only coincide for the launch profile.
4. Only exception: when `GET /api/profiles/active` answers `"current":"custom"` (launch `HERMES_HOME` outside the
   profiles tree; `H/hermes_cli/web_routers/profiles.py:883-899`, `H/hermes_cli/profiles.py:2098-2112`) the launch profile
   has no name, so omit `profile` / `?profile=` for that one bot. `current` is also how to tell which bot is the launch
   profile; never infer it from a local default.
5. `4064` / HTTP 404 `Profile '<name>' does not exist.` ⇒ the roster is stale: refetch `/api/profiles`, do not retry.

(03 §3.1 says the same "omit for the primary" as this section used to; this decision supersedes it.)

### 1.5 Heartbeat / liveness (relevant to "is the stream dead?")

- After `gateway.ready` with `payload.heartbeat:true` (`H/tui_gateway/ws.py:364-369`) the client sends
  `{"jsonrpc":"2.0","id":"heartbeat-N","method":"gateway.ping","params":{}}` every 15 s; the socket is failed when
  nothing at all was received for 45 s (any inbound frame counts) (`S/json-rpc-channel.ts:154-155,540-558`,
  `S/json-rpc-gateway.ts:180`). Server answers `{"result":{"ok":true}}` on the read loop even while a handler blocks
  (`H/tui_gateway/ws.py:420-423`).
- Phone extra (stream-only): while any turn is streaming on the socket, 5 s without an inbound frame triggers a
  WebSocket-level ping (7 s pong timeout); 3 consecutive misses fail the socket; a turn with no event for 180 s stops
  being watched (`P/bridge/socket.ts:146-193,320-345`). "Streaming" = last event type matches
  `message.(start|delta|interim)|(thinking|reasoning).delta|reasoning.available|tool.*`; ended by
  `message.complete|session.reclaimed|error` (`P/bridge/socket.ts:172-173`).
- After `gateway.ready` the client also calls `client.capabilities {"server_requests":true}`
  (`S/json-rpc-channel.ts:489-510`) so approvals/clarify are delivered instead of failing fast.

---

## 2. Sending: `prompt.submit`

### 2.1 Preconditions

The client needs the chat's **runtime** session id (from `session.create` / `session.resume` / `session.activate`;
see the chat-open spec). The stored id is not accepted here; a stale runtime id answers `4001 "session not found"`
(`H/tui_gateway/server.py:1229-1243`).

### 2.2 Params (contract `PromptSubmitParams`, `H/tui_gateway/contracts/prompt_voice.py:26-52`)

| Field | Type | Phone sends | Meaning (handler: `H/tui_gateway/methods_prompt.py:681-832`) |
|---|---|---|---|
| `session_id` | string, required | yes | runtime id |
| `profile` | string? | phone: non-primary bots only; **native: always** | §1.4 |
| `text` | string (JSON value) | yes | the user text; sanitized server-side (`methods_prompt.py:684-686`). With attachments the client appends attachment refs to the text (`V/…/use-prompt-actions/submit.ts:874`) — attachments out of scope |
| `queued` | bool? | `true` only when draining the client queue | forces the busy path to *queue*, never redirect/steer (`H/tui_gateway/session_auto_continue.py:410`; client `submit.ts:893-898`) |
| `display_kind` | `"hidden"`? | off-screen sends only | only `"hidden"` is honoured (`methods_prompt.py:687-689`) |
| `title_preview` | string? | large pastes | title input only (`methods_prompt.py:690-695`) |
| `interrupted` | bool? | voice barge-in only | |
| `surface` | `"hud"`/`"voice-live"`? | no (desktop HUD / voice) | |
| `voice_context`, `voice_turn` | — | no | voice |
| `truncate_before_*`, `confirm_truncate`, `confirm_empty_truncate`, `rebind_survivor_row_ids` | — | no (rewind/edit/regenerate — not M1) | a leftover truncation param without `confirm_truncate` → `4029` |

Minimal M1 request (what the phone sends for a plain text message to the primary bot; `submit.ts:878-899`):

```json
{"jsonrpc":"2.0","id":17,"method":"prompt.submit","params":{"session_id":"01965554","text":"What's on my calendar today?"}}
```

To a non-primary bot `ivy`: `{"session_id":"a1b2c3d4","text":"…","profile":"ivy"}`.

What **native** sends (§1.4 decision; `profile` always present, here the launch profile `default`):

```json
{"jsonrpc":"2.0","id":17,"method":"prompt.submit","params":{"session_id":"01965554","text":"What's on my calendar today?","profile":"default"}}
```

### 2.3 Result (contract `PromptSubmitResult`, `prompt_voice.py:55-75`)

```json
{"status":"streaming","user_row_id":812}
```

| `status` | When | Client meaning |
|---|---|---|
| `streaming` | session was idle; turn thread started (`methods_prompt.py:826-832`) | accepted; the turn runs; completion comes as events |
| `queued` | session was busy and the input was held for the next turn (`session_auto_continue.py:440-458`) | accepted (delivery confirmed), reply comes after the current turn |
| `redirected` | busy, `display.busy_input_mode=interrupt` (default) and agent supports active-turn redirect (`session_auto_continue.py:428-435`) | accepted; it became a correction of the running turn |
| `steered` | busy, `busy_input_mode=steer` | accepted; injected into the next tool result |
| *(absent)* + `voice_stopped:true` | typed stop phrase while backend voice mode is on (`methods_prompt.py:239-260`) | no turn |

- `user_row_id` (int) = durable SQLite row of this user message; present only for `streaming` and only when the
  row was persisted before the reply (`methods_prompt.py:818-821`, contract comment `prompt_voice.py:68-71`).
- `turn_isolation:true` marks a compute-host dispatch (ignore).
- **Ordering:** the turn thread starts *before* the result is written (`methods_prompt.py:825-832`), so
  `message.start` / early deltas **can arrive before the RPC result**. The web client binds `user_row_id` onto the
  optimistic bubble whenever the result lands, without resetting live state (`submit.ts:954-970`). Native must accept
  events for a turn whose submit has not been acknowledged yet.
- The result is **not** the reply. Turn completion is signalled only by events (`V/api/client.ts:19-27`).

### 2.4 Errors (exact codes/messages)

| Code | Message (source) | Client action today |
|---|---|---|
| `4000` | `invalid params for prompt.submit: <key>: …` (`rpc_dispatch.py:27-31`) | bug |
| `4001` | `session not found` (`server.py:1243`) | resume the **stored** id once (`session.resume {session_id:<stored>, source:"desktop", omit_messages:true, profile}` — the web client takes `profile` from the session row, native always sends it, §1.4), take the new runtime id, retry once (`V/…/use-prompt-actions/utils.ts:155-237`) |
| `4007` | `session no longer live; retry resume` (`H/tui_gateway/session_lifecycle.py:824`) | **resolved, §2.4.1**: phone today shows "Delivery Unconfirmed"; native treats it exactly like 4001 |
| `4009` | `session busy` (truncating submit while running, `methods_prompt.py:768`); `subagent still running — wait for it to finish` (`methods_prompt.py:657`); `session disconnect interrupt settling` (`session_lifecycle.py:826`) | web: retry every 150 ms for up to 6 s, matching the **text** `/session busy/i` only (`utils.ts:278-314`), so the other two texts are not retried and land on the phone's "Delivery Unconfirmed" path (§2.4.1); a queue drain that still gets busy stays queued silently (`submit.ts:1006-1010`). Native: match the **code** (§2.4.1) |
| `4064` | `Profile '<name>' does not exist.` (`rpc_dispatch.py:35-36`, `server.py:584-585`) | roster stale: refetch `/api/profiles`; do not retry (§1.4) |
| `4090` | active-session refusal; `data.reason` = `SESSION_NOT_OWNED` / `MAX_CONCURRENT_SESSIONS` / `SESSION_COORDINATION_UNAVAILABLE` (`methods_prompt.py:719-724`, `H/hermes_cli/active_sessions.py:104-112`) | error card; for `SESSION_NOT_OWNED` no Retry, offer new chat (`utils.ts:290-297`). Native: `SESSION_NOT_OWNED` waits for the holder ("Your message is waiting"), then "Couldn’t Send" |
| `4090` | gateway-owned turn (`methods_prompt.py` `_submit_to_ledger_owner`): `data.reason` = `SESSION_OWNER_BUSY` (its queue couldn't take the prompt; "Nothing was sent. Send it again when the current turn ends.") / `SESSION_OWNER_UNCONFIRMED` (its queue didn't confirm in time; may already hold it) | native (build 337 feedback): `SESSION_OWNER_BUSY` waits like a background task ("Waiting for the current reply…", same long window), then "Couldn’t Send" in plain words; with photos (the gateway unstages them) the send is refused at once and the photos go back to the tray. `SESSION_OWNER_UNCONFIRMED` is never resent: "Delivery unconfirmed" (§2.5) |
| `4124` | `turn author is stamped by the gateway, never by a client` | never send `_turn_author` |
| `5035` | `backend is retiring; reconnect to continue` (`rpc_dispatch.py:13`, `methods_prompt.py:652`) | reconnect |
| `5070` / `5071` / `5072` | session storage not writable / disk full; `data:{code,cause,details}` (`methods_prompt.py:558-603`) | error card; nothing was saved |
| `-32601` | `unknown method: …` | gateway too old |
| *(timeout)* | client gives up after **30 min** (`V/api/client.ts:27`, `PROMPT_SUBMIT_REQUEST_TIMEOUT_MS = 1_800_000`) | phone: mark "Delivery Unconfirmed" (§2.5). Desktop treats a timeout like 4001; **the phone turns that off** because a timed-out submit may already be committed (`B/ui-chat-send-gates.ts:103-105`) |

Turn failures that happen **after** acceptance never come back as an RPC error: they arrive as an `error` event or a
`message.complete` with `status:"error"` (§3).

#### 2.4.1 `4007` (and the other reattach refusals) — resolved

`4007` has two meanings; tell them apart by `error.message`:

| Message | Raised by | Meaning |
|---|---|---|
| `session no longer live; retry resume` | `_reattach_refusal` (`H/tui_gateway/session_lifecycle.py:819-826`), called from `prompt.submit` (`methods_prompt.py:744-746`), `session.activate` (`methods_session.py:1166-1174`) and `session.resume`'s live-reuse paths (`methods_session.py:728-730,885-888`) | the runtime record was reaped or replaced between the lookup and the resume lock — the `4001` situation, found one step later |
| `session not found` | `session.resume` → `_resume_locate` (`methods_session.py:807-829`) | the **stored** id is not in that profile's store: wrong/omitted `profile` (§1.4), deleted, or never persisted |

(`session.delete` and `session.workspace.move` also answer 4007 for a missing stored id, `methods_session.py:1116,1137,1204`.)

Why a retry is safe: on `prompt.submit` the refusal comes **before** the turn is admitted — before
`_lock_in_submit_turn` sets `running` and the in-flight turn (`methods_prompt.py:778-780`) and before the user row is
persisted (`:816`). Nothing was saved and nothing will run. The sibling `4009 session disconnect interrupt settling`
(`session_lifecycle.py:825-826`) and `4009 subagent still running…` (inside `_lock_in_submit_turn`, `methods_prompt.py:654-657`)
are equally pre-admission.

What the shipped phone does: the web client recovers only errors whose text matches `/session not found/i`
(`V/…/use-prompt-actions/utils.ts:52-56,169-173`), so a submit answered `4007 session no longer live; retry resume` is not
recovered. The phone then treats it like any failure after the request went out and replaces the bubble with a persisted
"Delivery Unconfirmed · Check" row (`B/ui-chat-send-gates.ts:88-97`; only busy / not-owned / provider-setup errors are
excluded). A `session.activate` 4007 fails `isSessionGoneError` (`V/…/use-session-actions/utils.ts:2492-2496`, also
text-based) and leaves the chat on a degraded warm cache that is **not re-bound** (`V/…/use-session-actions/index.ts:1847-1866`),
so live events don't arrive until the next send recovers through 4001. Neither is deliberate. Native diverges:

- `prompt.submit` → `4007 session no longer live…`: handle exactly like `4001` — `session.resume {session_id:<stored>,
  source:"desktop", omit_messages:true, profile}` once, adopt the returned runtime id, resubmit once. It is an explicit
  refusal: never show "Delivery unconfirmed" for it.
- `session.activate` → `4001` or `4007` (either text): fall back to the cold `session.resume` of the stored id (§7.2 step 4).
- `session.resume` → `4007 session no longer live; retry resume`: repeat the same resume once at once (the stale record is
  gone; the retry reuses or mints a runtime).
- `session.resume` → `4007 session not found`: terminal, never loop. If the owner profile was a guess, re-resolve it once
  (02's Bot Chat lookup); otherwise say the chat is no longer on that gateway and keep the user's text as a draft. When this
  happens inside 4001 recovery, report the original error, as the web client does (`utils.ts:204-212`).
- Any `4009` on `prompt.submit`: match the **code**, not the text; retry every 150 ms for up to 6 s; then return the text to
  the composer with the server's message (it was refused, not lost).
- Bound all of it: at most one resume and one resubmit per user action.

### 2.5 Dedupe / client message id — there is none on the wire

- `PromptSubmitParams` has no client id field and unknown keys are rejected (§1.3). The gateway does not echo any
  client identity on events (`P/ui-chat/send-state.ts:74-75`: "IDs are not echoed by this gateway").
- Gateway-side duplicate protection is limited to: at most one turn per session (busy path), and the client's own
  single-flight lock.
- Client single-flight: at most one `prompt.submit` in flight per session key (stored id, else runtime id), lock TTL
  30 s (`V/…/use-prompt-actions/utils.ts:365-402`, acquired at `submit.ts:399`).
- Phone delivery tracking (flag `PHONE_SEND_STATE`, on in Release, `P/ui-chat/flags.ts:39`):
  - Local phases `sending → sent | failed`, plus `queued` (`P/ui-chat/send-state.ts:3-21`).
  - Caption under the bubble: nothing for the first 2 s, then `Sending…`; `Queued`; `Delivery Unconfirmed · Check`
    for failed (`send-state.ts:10-28`).
  - `sent` on any `prompt.submit` result (and on `session.redirect` `redirected`/`queued`)
    (`B/ui-chat-send-gates.ts:29,85`).
  - On any failure **after the request was sent** — transport loss and timeouts, but also explicit refusals other than
    busy / not-owned / provider-setup (e.g. `4007`, `4009 session disconnect interrupt settling`) — the bubble is replaced
    by a persisted "unconfirmed" queue entry; nothing is auto-resent (`B/ui-chat-send-gates.ts:88-100`,
    `P/ui-chat/send-recovery.ts`). Native should reserve "unconfirmed" for timeouts and transport loss (§2.4.1).
  - "Check" is read-only: fetch the stored transcript and look for the message: by `user_row_id` if one was returned,
    else "a user row after the last known row id whose text equals the sent text" → present / missing / unknown
    (`P/ui-chat/send-state.ts:74-82`, `B/ui-chat-send-gates.ts:47-71`). Absence is never treated as permission to
    resend automatically (`send-state.ts:61-63`).
- **M1 recommendation:** keep a local `localId` per optimistic bubble; never auto-retry a `prompt.submit` whose request
  may have reached the gateway (timeout / socket drop after send); only retry on explicit `4001` / `4007` (after resume)
  and `4009` (§2.4.1).

### 2.6 Client-side steps around the RPC (shipped behaviour, condensed)

From `V/app/session/hooks/use-prompt-actions/submit.ts` with phone gates:

1. Acquire single-flight lock (`submit.ts:399`).
2. Optimistic user bubble `id = "user-<ms>-<rand6>"` (phone uses `user-<queueEntryId>` for queue drains,
   `B/ui-chat-send-gates.ts:47`), and arm the session: `busy=true, awaitingResponse=true, streamId=null,
   sawAssistantPayload=false, interrupted=false, turnStartedAt = existing ?? now` (`submit.ts:443-494`). Any leftover
   pending assistant bubble is sealed first (empty ones dropped) (`submit.ts:465-468`).
3. If no live runtime id: `session.resume` the stored id (single-flight per stored id) (`submit.ts:651-668`).
4. Pre-send transcript sync: `GET /api/sessions/<stored>/messages?profile=<p>&limit=120&order=latest&include_compacted=true`
   — `profile` is always present and first on the phone (§1.4; `V/api/sessions.ts:463-480`)
   (`V/lib/stale-transcript-guard.ts:120-146`, `V/api/sessions.ts:455-492,502`). Desktop refuses the send if the
   server is ahead; **the phone grafts the newer rows in and still sends once** (`B/ui-chat-send-gates.ts:147-207`).
   Optional for M1.
5. `prompt.submit` wrapped in busy-retry (§2.4) and not-found-resume (§2.4).
6. On result: bind `user_row_id` to the bubble, release the lock; `busy` stays true — the turn is now running
   (`submit.ts:954-1000`).
7. On a refused submit (explicit RPC error): drop the optimistic bubble (phone: the text goes back to the draft/queue)
   and append an assistant error bubble `id "assistant-error-<ms>"` with the error text; `busy=false`
   (`submit.ts:1001-1063`, `B/ui-chat-send-gates.ts:88-100`).

---

## 3. The turn's server events, in order

### 3.1 Lifecycle (normal streaming turn)

Emitters: `H/tui_gateway/methods_prompt.py:606-642` (wait for agent), `H/tui_gateway/prompt_turn.py:1121-1266`.

```
client  prompt.submit ───────────────▶
server  (thread) wait for agent build; if slow (>30 s) notification.show {key:"agent-build-slow"} (server.py:946-950)
server  ◀── event message.start                 (prompt_turn.py:1162; no payload)
server  ◀── result {"status":"streaming",…}     (may arrive before or after message.start)
server  ◀── event session.title ×0..n           (auto-title, any time; prompt_turn.py:805-806)
server  ◀── event thinking.delta / reasoning.delta / reasoning.available   (0..n)
server  ◀── event message.delta ×n              (prompt_turn.py:750-767)
server  ◀── event tool.generating {name}        (0..n, before a tool call)
server  ◀── event message.interim {text, already_streamed}  (text beside tool calls; seals the bubble)
server  ◀── event tool.start / tool.complete / todo.updated  (0..n, interleaved with deltas)
server  ◀── event session.usage                 (mid-turn ticks)
server  ◀── event status.update {kind,text}     (0..n: compaction, fallback model switch, goal…)
server  ◀── event message.complete {text,usage,status,…}   (prompt_turn.py:1195) — THE turn end
server  ◀── event session.info {…,"running":false}          (prompt_turn.py:1239, always, in finally)
```

- There is **no turn id / run id** on the wire for app turns. A turn = everything for one `session_id` between
  `message.start` and `message.complete`; `seq` orders events per session. (Hosted-room turns carry internal
  `turn_id`s that never reach the app — `methods_prompt.py:263-273`.)
- Backend-originated turns (server-side queue drain, goal follow-ups, crash auto-continue) emit `message.start`
  **without** any client `prompt.submit` (`prompt_turn.py:421-436`, `session_auto_continue.py:461-530`). The client
  must open a new assistant bubble on `message.start` regardless of who started the turn.
- `session.info` with `running:true` is **not** emitted at turn start; the client's "busy" comes from its own
  optimistic arm and `message.start` (§4.1). `running:true` can arrive in any `session.info` (resume, config change).
- When the run thread ends without reaching `message.complete` (crash), `_recover_turn_exception` still emits a
  terminal `message.complete` with `status:"error"` (`prompt_turn.py:1010-1039`,
  `session_auto_continue.py:563-593`), then `session.info running:false`.

Live evidence (owner's gateway, non-streaming provider, `R/docs/stage2-report.md:31-48`,
`R/artifacts/stage1/chat-verification.log`): replay counts
`{"session.info":2,"message.start":1,"session.title":2,"thinking.delta":2,"reasoning.available":1,"message.complete":1}`
with **zero** `message.delta`.

### 3.2 Event payloads (contract `H/tui_gateway/contracts/events.py`; all payload models reject unknown keys)

#### `message.start` — no payload (`events.py:113`)
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"01965554","seq":5}}
```
Note: fixture gateways send `"payload":{}` instead (`R/scripts/build47-fixture-gateway.py:41-42`); accept both.

#### `message.delta` — `{text, rendered?, verbose?}` (`events.py:116-126`; emitter `prompt_turn.py:750-767`)
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"01965554","payload":{"text":"Sure — here's"},"seq":6}}
```
- `text` is a raw chunk to append. Chunk boundaries are arbitrary (may split words, markdown, `MEDIA:` tags,
  surrogate pairs are not split by the server but treat text as opaque).
- `rendered` is a server-side terminal rendering; `H/agent/rich_output.py` does not exist in this install, so it is
  never sent (`H/tui_gateway/render.py:12-36`). Ignore it.
- In "Bot mode" sessions deltas that could still become a silence marker (`NO`→`NO_REPLY`) are held back
  (`prompt_turn.py:747-761`); the client keeps streamed text if `message.complete.text` is `""`.

#### `reasoning.delta` / `reasoning.available` / `thinking.delta` — `{text, verbose?}` (`events.py:116-129`)
- `reasoning.delta`: streamed reasoning; only when `display.show_reasoning` is on for the session
  (`H/tui_gateway/agent_callbacks.py:135-138`).
- `reasoning.available`: a completed reasoning block (non-streaming providers) (`tool_progress.py:386`). Client
  **replaces** the bubble's reasoning with it unless the bubble already has answer text (`V/…/use-message-stream/index.ts:507-540`).
- `thinking.delta`: spinner/wait text ("waiting on provider…"). **Not transcript content.** The client shows it only
  as a provider-wait label in the status row (`V/…/gateway-event/message-stream.ts:195-205`).
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"thinking.delta","session_id":"01965554","payload":{"text":"⏳ waiting on model…"},"seq":4}}
```
(text illustrative; shape per contract.)

#### `message.interim` — `{text, already_streamed}` (`events.py:132-140`; emitter `prompt_turn.py:771-776`)
Commentary the model wrote beside tool calls (or a pre-nudge final). Usually its text was already streamed as deltas
(`already_streamed:true`). Emitted only when `display.interim_assistant_messages` (default true)
(`H/tui_gateway/server.py:388-391`). Client: flush pending deltas, then **seal** the current streaming bubble with this
text (authoritative), mark it `interim`, clear `streamId` so the next delta starts a *new* bubble
(`V/…/use-message-stream/index.ts:601-706`).
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.interim","session_id":"01965554","payload":{"text":"Let me check the calendar.","already_streamed":true},"seq":12}}
```

#### `tool.generating` — `{name}` (`events.py:302-308`)
Model is emitting a tool call's arguments. Status only — never create a row from it (`V/…/gateway-event/tools.ts:34-55`).
Retired by the next `message.*`/`tool.*`/`reasoning.*`/`error` event (`V/…/gateway-event/index.ts:41-50`).

#### `tool.start` — `{tool_id, name, context?, args?, args_text?, preview?, labels?}` (`events.py:266-280`; emitter `H/tui_gateway/tool_progress.py:276-302`)
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"01965554","payload":{"tool_id":"call_8f2a","name":"terminal","context":"ls -la ~/Projects","args":{"command":"ls -la ~/Projects","timeout":30}},"seq":14}}
```
Fixture shape (no `context`): `{'name':'terminal','tool_id':call_id,'args':args}` (`R/scripts/performance-fixture-gateway.py:31-33`).

#### `tool.complete` — `{tool_id, name, args?, duration_s?, result, summary?, result_text?, inline_diff?, todos?, revision?, labels?}` (`events.py:283-299`; emitter `tool_progress.py:325-363`)
`result` is the tool's JSON-decoded output when it parses, else the raw string (`tool_progress.py:343-346`).
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"tool.complete","session_id":"01965554","payload":{"tool_id":"call_8f2a","name":"terminal","args":{"command":"ls -la ~/Projects","timeout":30},"duration_s":0.41,"result":{"output":"total 8\n…","exit_code":0},"summary":"…"},"seq":17}}
```
Fixture (copied, `performance-fixture-gateway.py:36-42`):
`{'name':'terminal','tool_id':'performance-tool-0','args':{'command':'printf synthetic-step-0','timeout':5},'result':{'stdout':'synthetic output\n…','stderr':'','exit_code':0}}`.

**Gating:** `tool.start`/`tool.complete` are emitted only when `display.tool_progress != "off"`, except for card tools
(`clarify, manage_connections, setup_mcp, image_generate, manage_catalog, delegate_task, setup_choose, start_chat,
edit_file, patch, write_file`), todo tools, connector tools, and results that need the user
(`tool_progress.py:291-292,359-362`, `server.py:2144-2156`). A turn can therefore run tools with **no tool events**.

#### `todo.updated` — `{todos, revision}` (`events.py:324-331`): full task snapshot after a todo tool.

#### `status.update` — `{kind, text}` (`events.py:216-223`; `server.py:855-866`)
`kind` ∈ `status, lifecycle, compacting, compacted, compressing, ready, goal, loop, heartbeat, process, fallback, …`.
Client cares about: `compacting`/`compressing` (show "summarizing"), `compacted`/`ready` (end it), fallback model
switch (append a system line) (`V/…/gateway-event/status.ts:47-142`). Others: ignore for M1.

#### `session.usage` — `{usage}` mid-turn; `session.title` — `{session_id: <stored key>, title}` (`events.py:226-242`).

#### `message.complete` — the turn end (`events.py:189-213`; emitter `prompt_turn.py:929-1007`)

| Field | Always? | Meaning |
|---|---|---|
| `text` | yes (may be `""`) | final reply text (string; relay paths may send a parts list — coerce: strings, `{text}`, `{output_text}` joined, `V/lib/chat-runtime.ts:72-100`) |
| `usage` | yes on normal path | `Usage` (`contracts/common.py:19-37`): `model, input, output, reasoning, prompt, completion, total, calls, context_*…` |
| `status` | yes on normal path | `complete` \| `error` \| `interrupted` (`prompt_turn.py:310-313`) |
| `persisted_turn` | when proven | `{row_ids:[int], complete:bool, user_row_id?, final_assistant_row_id?}` (`events.py:176-186`, `prompt_turn.py:882-926`) — durable row ids of this turn |
| `reasoning` | optional | last reasoning text |
| `response_previewed` | optional | text was already delivered as an interim; don't paint twice |
| `response_reused` | optional | text adds nothing new |
| `response_transformed` | optional | a hook rewrote the final after streaming; treat `text` as authoritative replacement |
| `warning` | optional | history-commit note → toast |
| `billing`, `failure_reason` | optional | billing wall |
| `error`, `recoverable`, `partial`, `error_surface` | only when `status:"error"` | `error` = message; `partial:true` ⇒ `text` is kept streamed output, not error copy; `error_surface` = `{layer, code, retryable, provider?, model?, resets_at?}` (`events.py:151-161`, `prompt_turn.py:989-997`) |
| `rendered` | never in practice | ignore |

Normal example (constructed from `_complete_turn_payload`, `prompt_turn.py:947-985`):
```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"01965554","payload":{
  "text":"Two colors: blue and yellow. …","status":"complete",
  "usage":{"model":"claude-opus-5-5","input":5120,"output":1204,"reasoning":0,"prompt":5120,"completion":1204,"total":6324,"calls":1},
  "persisted_turn":{"row_ids":[812,813],"complete":true,"user_row_id":812,"final_assistant_row_id":813}},"seq":31}}
```
Terminal error example (shape per `session_auto_continue.py:563-593`):
```json
{"type":"message.complete","session_id":"01965554","payload":{"text":"I couldn't finish this: …","usage":{},"status":"error","error":"Codex usage limit","recoverable":true,"error_surface":{"layer":"provider","code":"rate_limit","retryable":true,"provider":"codex","resets_at":1790003600.0}}}
```
(The `error_surface` values mirror the phone's own test, `R/scripts/native-platform/main.swift:329`.)
Interrupted example: `{"text":"<persisted partial or \"\">","usage":{…},"status":"interrupted"}` — the
`Operation interrupted: waiting for model response (…)` sentinel is stripped to `""` (`prompt_turn.py:327-334`).

Fixture example (copied, `R/scripts/build47-fixture-gateway.py:67`): `{'text':text,'row_id':row}` — **non-standard**
(`row_id` is not in the contract; no `status`/`usage`) — §10.

#### `session.info` (end of turn) — `SessionLiveInfo` (`contracts/common.py:63-100`)
Always emitted after the turn's `finally` with `running:false` (`prompt_turn.py:1205-1239`,
`H/tui_gateway/session_workdir.py:397-404`). Fields relevant here: `running`, `turn_started_at` (epoch s),
`stored_session_id`, `model`, `provider`, `usage`, `title`. It is also re-emitted at other times (model switch, config).
```json
{"type":"session.info","session_id":"01965554","payload":{"model":"claude-opus-5-5","provider":"…","running":false,"turn_started_at":null,"stored_session_id":"20260925_120000_ab12cd","title":"Bookshelf tips","usage":{…},"…":"…"},"seq":32}
```

#### `error` — `{message, code?}` (`events.py:92-98`)
A failure **outside** a normal terminal frame: pre-turn refusals and agent build failures. Emitters:
`"Turn cancelled before the agent was ready"` / `"Session no longer running before the agent was ready"`
(`methods_prompt.py:627-634`), ownership refusal (`prompt_turn.py:126-134`), agent init failure with
`code:"provider_not_configured"` (`server.py:1209-1217`). The phone also accepts `message` as an object
(`P/gateway-event-guards.ts:9-15`). Client: ends the turn, paints an error bubble (§4.7). The two
"…before the agent was ready" texts are followed by **no** `message.complete` or `session.info` — the `error` is the
terminal frame — and are a Stop, not a failure (§5.4).

#### Other events that can land mid-turn
`notification.show {text, level, kind, ttl_ms?, key?, id?}` / `notification.clear {key}` (toasts; slow build notice);
`session.reclaimed {session_id, stored_session_id, reason}` (broadcast, envelope `session_id:""`; the runtime is gone,
`events.py:396-404`); `approval.cancelled` (pending approvals dropped by an interrupt; `events.py:407-424`);
`subagent.*`; `reaction`; `review.summary`; `background.complete`/`btw.complete`. M1 may ignore all except
`session.reclaimed`.

### 3.3 Config switches that change what you receive

| Gateway config | Effect | Source |
|---|---|---|
| `display.tool_progress: off` | no tool events except card/todo/connector tools | `tool_progress.py:291,359` |
| `display.show_reasoning` | gates `reasoning.delta` | `agent_callbacks.py:135-138` |
| `display.interim_assistant_messages` (default true) | gates `message.interim` | `server.py:388-391` |
| `display.busy_input_mode` (`interrupt` default, `queue`, `steer`) | what a submit while busy does | `server.py:383-385` |
| provider is ACP / `external_process` | no streaming at all (§8) | `H/agent/turn_api_call.py:46-64` |

---

## 4. How the client folds events into the transcript

Per-runtime-session state used by the shipped client (`V/app/types` `ClientSessionState`; transitions cited below):
`busy`, `awaitingResponse`, `streamId` (id of the live assistant bubble), `sawAssistantPayload`,
`interimBoundaryPending`, `turnLive`, `interrupted`, `turnStartedAt`, `heartbeatSettledStreamId`.

Message model: `ChatMessage {id, role, parts[], pending?, interim?, error?, errorSurface?, rowId?, timestamp,
completedAt?}`; parts are `text`, `reasoning`, `tool-call {toolCallId, toolName, args, result?, isError?, completedAt?}`.

### 4.1 `message.start`
If `interrupted` is set, ignore (a stale start after Stop). Else: `busy=true, awaitingResponse=true,
sawAssistantPayload=false, interimBoundaryPending=false, turnLive=true, turnStartedAt ??= now`. Pending deltas: flush
if a turn was already live, else **drop** them (they belong to the previous turn)
(`V/…/gateway-event/message-stream.ts:86-168`). Haptic on the visible chat.

### 4.2 Deltas (text and reasoning)
- Coalesce per session into a queue; consecutive deltas of the same kind join (`index.ts:428-447`).
- Flush on a timer: ≥33 ms between flushes, adaptive up to 250 ms under load (`index.ts:332-426`,
  `V/…/use-message-stream/utils.ts:109-115`). **Always flush before** applying `tool.*`, `message.interim`,
  `message.complete`, `error` (so order is preserved).
- Applying a flush (`mutateStream`, `index.ts:150-230`): if `interrupted` → drop. Target bubble = `streamId`, or a new
  assistant bubble `id "assistant-stream-<n>"` with `pending:true` appended to the end. Then `sawAssistantPayload=true,
  awaitingResponse=false`.
- Part rule (`V/lib/chat-messages/parts.ts:488-554`): if the bubble's last part is the same kind and still open
  (`completedAt` unset), append to it; otherwise close the previous open text/reasoning part and start a new part. So
  text → tool → text yields three parts in order.

### 4.3 Tool events
- `tool.start`/`tool.complete`: flush deltas, then upsert a `tool-call` part keyed by `tool_id`
  (`V/lib/chat-messages/tool-parts.ts:324-383`). The target bubble is **whichever bubble already owns that `tool_id`**
  (it may be an earlier, sealed bubble), else the live bubble (`index.ts:542-599`). A tool event closes any open text
  part first.
- `complete` sets `result`, `completedAt`, `isError` (`payload.error`), keeps args from start if omitted.
- A `running` event for a call that was sealed without a result re-opens it (`tool-parts.ts:366-377`).
- At turn end, any tool part still without completion is sealed ("Result unavailable") (`index.ts:995`).

### 4.4 `message.interim`
See §3.2. Seal the live bubble with the authoritative text (keeping tool parts), `interim:true, pending:false`,
`streamId=null`, `interimBoundaryPending=true`. If there is no live bubble, update an identical-text bubble of this
turn or append a sealed one (`index.ts:601-706`).

### 4.5 `message.complete` — settle the turn (`index.ts:708-1086`; dispatcher `message-stream.ts:331-431`)
Simplified algorithm sufficient for M1 (the web client has many more duplicate-guards; listed after):
1. Flush deltas. Clear open approvals/clarify for this session.
2. `finalText = text || rendered` (trimmed). `failure` if `status=="error"`: `{error: payload.error || finalText,
   partial, surface: error_surface}`.
3. If `interrupted` (user pressed Stop): if `status=="interrupted"` and `finalText` *extends* what the live bubble
   showed, extend that bubble; never shrink/replace; then settle flags and return (`interrupted-reply.ts:20-66`).
4. Target bubble = `streamId` (or `heartbeatSettledStreamId`) if it is after the last user message; else the last
   visible assistant bubble after the last user message if it is `pending`, or an `interim` whose text is a
   prefix/extension/high-overlap of `finalText`, or the bubble `persisted_turn.final_assistant_row_id` settles;
   else append a new bubble `id "assistant-<ms>"` (only if `finalText` non-empty or there's an error).
5. On the target: `pending=false, interim=false, completedAt=now, durationS`; text merge: if the streamed text equals
   `finalText` (whitespace-normalised) keep parts as-is; else replace only the text **after the last tool part** with
   `finalText` (strip an exact prefix equal to the pre-tool text) (`parts.ts:358-440`). Empty `finalText` never wipes
   streamed text.
6. Error: if `failure` and not `partial` → drop text parts, set `error` + `errorSurface`; if `partial` keep text and
   also set `error`.
7. Bind `persisted_turn.final_assistant_row_id` → `rowId`.
8. Session flags: `busy=false, awaitingResponse=false, streamId=null, interimBoundaryPending=false, turnLive=false,
   turnStartedAt=null, needsInput=false`. Apply `usage`.
9. If this client never saw any assistant payload for the turn (adopted/background turn) and there's no error,
   re-read stored history (`shouldHydrate`, `index.ts:1021-1072`) via the history REST path.

Edge cases the web client handles (keep in mind; cite for later milestones): duplicate interim delivery across two
sockets (`index.ts:650-700`); `response_previewed`/`response_transformed` only settle onto an interim when
`interimBoundaryPending` (`index.ts:907-952`); a complete reordered behind the `running:false` heartbeat settles onto
`heartbeatSettledStreamId` (`session-info.ts:423-437`); a bare `error` event followed by an error frame settles onto
the same card (`index.ts:903`); disk-full toast (`index.ts:1052-1059`).

### 4.6 `session.info` with `running`
(`V/…/gateway-event/session-info.ts:311-475`)
- `running:true` and not `interrupted` → `busy=true, turnLive=true, turnStartedAt ??= turn_started_at*1000 ?? now`
  (this is how a chat opened mid-turn shows "Working").
- `running:false`:
  - If the client armed a send but the backend has not reported the turn live yet (`awaitingResponse &&
    !sawAssistantPayload && !turnLive`) and the arm is younger than **15 s**, ignore it (pre-start heartbeat)
    (`utils.ts:127-130`, `session-info.ts:396-405`).
  - Otherwise settle: seal pending bubbles (drop empty ones), `busy=false…`; remember the live bubble as
    `heartbeatSettledStreamId` so a late `message.complete` lands on it; if the turn was live and no bubble survived,
    re-read stored history for the visible chat (`session-info.ts:423-473`).

### 4.7 `error` event (`V/…/gateway-event/status.ts:281-362`)
Flush deltas; clear prompts; paint/replace an assistant error bubble (`streamId` bubble or new
`"assistant-error-<ms>"`, `parts:[]`, `error:<message>`); `busy=false…` (`index.ts:1088-1180`). If the text looks like
`SESSION_NOT_OWNED` / disk full, attach `errorSurface` (`status.ts:288-300`). Provider-not-configured → onboarding.

Phone gate r3-03 (`B/fe-convo-gates.ts:374-411`) runs first: an `error` that arrives while the session has **no turn in
flight** (`!busy && !awaitingResponse && !streamId`, `P/fe-convo-r3.ts:389`) and is not provider-setup / disk-full is a
chat-level failure — no error card; a notice (phone: a banner docked above the composer, gate r5-92,
`B/fe-convo-gates.ts:668-671`) with Choose a model / Try again for the chat on screen. Both the notice and the banner show
nothing for `^(Turn cancelled|Session no longer running) before the agent was ready` (`P/fe-convo-r3.ts:393-400`,
`P/fe-convo-r5.ts:234,245-247`). See §5.4 for the Stop case.

### 4.8 Silence watchdog (lost turn end)
Any event for a session resets a 45 s timer while the turn is live (`V/store/session-states.ts:404-413,661-677`).
On expiry the client asks `session.active_list {}` (15 s timeout) and looks up its runtime id
(`session-states.ts:467-504`):

```json
{"jsonrpc":"2.0","id":88,"method":"session.active_list","params":{}}
→ {"sessions":[{"id":"01965554","status":"working","current":false,"last_active":1790363300.1,"message_count":14,"model":"…","preview":"…","session_key":"20260925_120000_ab12cd","started_at":1790363000.0,"title":"…"}]}
```
(shape: `H/tui_gateway/contracts/sessions.py:266-291`; status from `server.py:3045-3052`: `waiting` (prompt pending),
`starting` (agent building), `working` (running), `idle`.)
- `starting|waiting|working` → keep waiting, re-arm 45 s.
- absent or `idle` → settle like `running:false`, re-read history, and if there's still no reply append
  `"Hermes ended this turn without a reply."` with `errorSurface {code:"no_reply", layer:"runtime", retryable:true}`
  (`session-states.ts:523-658`).
- no answer → keep waiting.
A separate 5-minute watchdog only marks the row "stalled" (`session-states.ts:403`).

### 4.9 "Working…" (what the UI shows while a turn runs)
- Bot/session rows: `Working…` while `busy` (or a background subagent/process claim) (`P/ui-lists/row-model.ts:50`,
  `P/ui-kit/bot-status.ts:51`).
- Chat header subtitle (`P/ui-chat/turn-state.ts:30-38`): from the last message while `busy`: no assistant bubble yet
  or last part is reasoning → `Thinking…`; last part is a tool call without result → `Running a command…`; last part is
  text → `Writing…` (`bot-status.ts:29`). Precedence above it: offline/reconnecting, waking, approval, awaiting reply.
- In-thread status row extras: `tool.generating` name, `thinking.delta` provider-wait text, compaction label.

### 4.10 Phone reveal of whole replies
When a single `message.delta` ≥ 60 chars arrives ≥ 1 s after the previous delta of that session (i.e. a whole reply
landed at once), the phone draws it progressively over 280–700 ms (first ~1200 chars, the rest at the end); any touch,
app backgrounding or another delta shows everything (`P/ui-chat/reply-reveal.ts:1-138`). Purely presentational; stores
get every event immediately. Replayed events are never paced.

---

## 5. Stop

### 5.1 Client side first (optimistic) — `V/app/session/hooks/use-prompt-actions/index.ts:670-753`
1. Park the session's client queue (Stop must not roll into the next queued message) (`V/app/chat/composer/index.tsx:392-403`).
2. `markSessionRecentlyInterrupted` (3 s cooldown used by edit/rewind; `utils.ts:322-347`).
3. Seal the live bubble now: tool calls still running are marked interrupted; pending bubbles get `pending=false`,
   empty ones are removed (`rewind.ts:406-418`, `parts.ts:459-483`). Set `busy=false, awaitingResponse=false,
   streamId=null, interrupted=true, turnLive=false, turnStartedAt=null`. Clear todos, subagents, prompts.
4. Send `session.interrupt` (with the one-shot not-found resume of §2.4; `index.ts:735-747`) using the gateway default
   timeout of 30 s (`V/api/client.ts:18,44`). On error or timeout → toast "Stop failed" (`index.ts:749-752`,
   `V/i18n/en.ts:5539`); local state stays stopped. Native diverges here — see §5.6.

Because `interrupted=true`, every later `message.delta`, `tool.*`, `message.interim` and `message.start` for that
session is **dropped** (`index.ts:167-173`, `message-stream.ts:125-135`, `tools.ts:44`) until the next send clears the
flag (`submit.ts:478`).

### 5.2 RPC — contract `H/tui_gateway/contracts/sessions.py:604-621`, handler `H/tui_gateway/methods_session_interrupt.py:41-79`

```json
{"jsonrpc":"2.0","id":51,"method":"session.interrupt","params":{"session_id":"01965554"}}
→ {"jsonrpc":"2.0","id":51,"result":{"status":"interrupted"}}
```
(The phone sends no `profile` here for the primary bot; native adds `"profile":"<bot>"`, §1.4.)
- Result `status`: `interrupted` (always for app sessions, even if nothing was running), `not_interrupted` only for
  `expected_hosted_task_id` mismatches; `turn_isolation:true` on compute-host sessions.
- Errors: `4001 session not found`; `5032` agent still starting/failed (below); `5019 compute-host interrupt failed: …`.
- Also stops streaming TTS (`methods_session_interrupt.py:43`).

**During a slow agent build (resolved from source).** `session.interrupt` is an inline handler (not in
`_LONG_HANDLERS`, `server.py:181-205`). For an in-process session it calls `_sess` (`methods_session_interrupt.py:63`),
which waits up to **30 s** for the session's `agent_ready` (`server.py:939-943`) *before* `_interrupt_session_turn`
(`:66`) sets `_turn_cancel_requested`. So:
1. While it waits, every later request on that WebSocket queues behind it (one dispatcher per connection,
   `H/tui_gateway/ws.py:319-337`). Only `gateway.ping` is answered by the reader (`ws.py:420-423`), so the socket stays
   healthy but other chats' RPCs — sends included — stall for up to 30 s.
2. Build ready within 30 s → the interrupt applies, answers `{"status":"interrupted"}`, and the turn ends per §5.4.
3. Build still running at 30 s → `5032` with `"Hermes is still starting this session (loading tools), so this command
   could not run yet. Wait for the status bar to show ready and try again."` (`H/tui_gateway/user_messages.py:118-120`) and
   **nothing was cancelled**: the flag was never set, so the prompt runs as soon as the build finishes
   (`methods_prompt.py:614-634`). Build failed → `5032 <agent_error>` at once; no turn runs, and the turn thread closes it
   with `message.complete {status:"error", error_surface:{layer:"runtime", code:"agent_init_failed", retryable:true}}`
   (`methods_prompt.py:614-624`, `H/tui_gateway/session_auto_continue.py:563-589`).
4. Compute-host sessions skip the wait (`methods_session_interrupt.py:57-62`).

Shipped phone in case 3: the request times out client-side at 30 s, the same moment the server answers 5032 → "Stop
failed" toast, local state stays `interrupted:true`. The turn then runs anyway: its `message.start` and deltas are dropped
(§5.1), and its `message.complete status:"complete"` leaves the transcript untouched (`use-message-stream/index.ts:727-739`
only merges `status:"interrupted"`). The reply is invisible until the chat's history is re-read. A defect; §5.6 fixes it.

### 5.3 Server effects (`H/tui_gateway/session_lifecycle.py:687-770`)
- `_turn_cancel_requested=True`; **server-side queued prompts are discarded** (`queued_prompt=None`, generation bump)
  (`session_lifecycle.py:709-713`).
- Hard-interrupts the agent if running; stops background delegations and a post-turn background review.
- If no run thread is alive, clears `running` immediately.
- Deny-resolves every pending approval and broadcasts `approval.cancelled {reason:"interrupt"}` (`:759-768`).
- Retires the crash-recovery marker so a restart won't auto-continue the stopped turn (`methods_session_interrupt.py:67-72`).

### 5.4 Events after Stop
- Running turn: the agent unwinds, then `message.complete {status:"interrupted", text:<persisted partial or "">}` and
  `session.info {running:false}` (§3.1). Client: extend-only merge (§4.5 step 3), then settle.
- Stop **before** the agent was ready: no `message.start`; the turn thread emits a bare `error` event and returns —
  **no** `message.complete`, **no** `session.info running:false` (`methods_prompt.py:625-634`):
  ```json
  {"jsonrpc":"2.0","method":"event","params":{"type":"error","session_id":"01965554","payload":{"message":"Turn cancelled before the agent was ready"},"seq":7}}
  ```
  (variant `"Session no longer running before the agent was ready"` when `running` was cleared without the cancel flag).
  The cancel is checked once per 5 s slice of the build wait (`server.py:948,981-985`). Because `session.interrupt`
  itself waits for the build before setting the flag (§5.2), this mostly happens when the build finishes and the
  interrupt wins the race with the turn thread (both wake on `agent_ready`), or when the WS-orphan reaper interrupts
  (`session_lifecycle.py:687-770`); if the turn thread wins, the turn starts and ends `status:"interrupted"` instead.
  - **Shipped phone: suppressed (resolved).** After Stop the session has `busy=false, awaitingResponse=false,
    streamId=null` (§5.1), so gate r3-03 takes the chat-level branch (§4.7) and the `CANCELLED` regex returns nothing:
    no card, no toast, no banner (`B/fe-convo-gates.ts:378-411`, `P/fe-convo-r3.ts:389,393-400`,
    `P/fe-convo-r5.ts:234,245-247`). Upstream desktop without the gate would paint an error card and toast
    (`V/…/gateway-event/status.ts:281-359`, `index.ts:1088-1164` — no `interrupted` check).
  - **Native decision:** match `^(Turn cancelled|Session no longer running) before the agent was ready` (case-insensitive)
    and treat it as a **stop, never an error**. If the session is `interrupted` (local Stop): drop it. If the session still
    looks busy (Stop came from another device): settle the turn like a Stop — `busy=false`, seal pending bubbles, show
    the "Stopped" marker — with no error card (the phone would paint a card here; deliberate divergence). Either way this
    event is the turn's terminal frame: don't wait for `message.complete` / `session.info`.
- Not running: no further events.
- A new message right after Stop, while the old turn is still unwinding (`running` is still true server-side):
  a **truncating** submit (edit / rewind / regenerate) gets `4009 session busy` (`methods_prompt.py:761-768`) — the
  web client's 3 s "recently interrupted" mark exists for that (`V/…/use-prompt-actions/utils.ts:318-347`) and the
  busy-retry covers it (§2.4). A **plain** `prompt.submit` is not refused: it takes the busy path (§6.1) and comes back
  `redirected` (a correction of the turn being stopped) or `queued` (`H/tui_gateway/session_auto_continue.py:404-458`).
  Native recommendation: hold the next send until the stopped turn's terminal frame (`message.complete`, the
  cancelled-before-ready `error`, or `session.info running:false`) or 6 s, whichever is first; if it must go earlier, send
  it with `queued:true` so it can only run as the next turn.

### 5.5 Fixture disagreement
`build47-fixture-gateway.py:83-87` answers `session.interrupt` by emitting `message.complete {"text":"Stopped synthetic
reply."}` (no `status`, no `session.info`) and returns `{"status":"interrupted"}`. Real gateway: `status:"interrupted"`
with the persisted partial, then `session.info running:false`.

### 5.6 Native Stop — decisions (resolves the former UNKNOWNs on cancelled-before-ready and slow-build interrupts)

1. Seal locally and set `interrupted` exactly as §5.1; the composer goes idle at once.
2. Send `session.interrupt {"session_id":<runtime>,"profile":<bot>}` with a client timeout of **40 s** (more than the
   server's 30 s build wait, §5.2, so a `5032` is seen instead of a client timeout). Don't block the UI on it. Never
   have two in flight for one session.
3. `{"status":"interrupted"}` → done; expect §5.4's terminal frame.
4. `5032` (either text) or a timeout → the stop did **not** reach the turn. Keep `interrupted`, mark the session
   `stopPending`, show nothing yet:
   - On the next `message.start` or `session.info {running:true}` for that runtime (the agent is ready now), send
     `session.interrupt` once more; it returns at once and the turn ends `status:"interrupted"` (extend-only merge,
     §4.5 step 3). Keep dropping that turn's content events meanwhile.
   - `message.complete {status:"error", error_surface.code:"agent_init_failed"}` while `stopPending`: nothing ran;
     settle quietly.
   - If that second interrupt also fails, or a `message.complete` with any other `status` than `interrupted` arrives
     while `stopPending`, stop hiding: clear `interrupted`, paint that `message.complete` as a normal reply (or re-read
     history), and toast "Couldn't stop — Hermes finished the reply." A completed reply is never dropped silently
     (the shipped phone does drop it, §5.2).
   - Clear `stopPending` on any terminal frame: `message.complete`, the cancelled-before-ready `error` (§5.4), or
     `session.info {running:false}`.
5. `4001` / `4007`: the runtime is gone. Do what the web client does (`index.ts:735-747`): resume the stored id once;
   if the returned snapshot says `running:true` (another client's runtime for the same chat), interrupt that runtime;
   else settle as stopped. Never loop.
6. The cancelled-before-ready `error` is a stop, not an error (§5.4).
7. Accept that a Stop sent during a cold build can delay every other RPC on the gateway's socket by up to 30 s (§5.2);
   per-request timeouts elsewhere must tolerate it (the 30 min `prompt.submit` ack timeout already does).

---

## 6. Sending while a reply is running (busy) and the queue

M1 may skip queueing; documented so the native client doesn't misbehave.

### 6.1 Gateway (`H/tui_gateway/methods_prompt.py:749-777`, `H/tui_gateway/session_auto_continue.py:404-458`)
A `prompt.submit` that finds the session running is **not refused** (except truncating submits → 4009):
- `queued:true` in params ⇒ mode `queue` (always held for the next turn).
- else `display.busy_input_mode` (default `interrupt`):
  - text-only + agent supports redirect ⇒ `agent.redirect(text)` → result `{"status":"redirected"}`.
  - `steer` mode + text-only ⇒ `agent.steer(text)` → `{"status":"steered"}`.
  - otherwise (attachments, unsupported, compression in flight) ⇒ enqueue + persist the user row at accept time →
    `{"status":"queued"}`; in `interrupt` mode without attachments the live turn is also hard-interrupted
    (`session_auto_continue.py:452-458`).
- Server queue drains automatically when the turn ends (`_drain_queued_prompt`, `session_auto_continue.py:461-530`):
  a new `message.start` … `message.complete` sequence with no client RPC.
- Server queue is visible on resume as `queued: {"user": "<text>"}` (`contracts/sessions.py:47-49,92`) and is
  **cleared by Stop** (§5.3).

### 6.2 Shipped phone behaviour while busy (`V/app/chat/composer/hooks/use-composer-submit.ts:236-326`)
- Plain text, no attachments, not compacting, no approval/sudo/secret pending ⇒ **redirect**: the bubble is appended
  after the live reply (live bubble sealed as interim), then
  `session.redirect {"session_id":…, "text":…}` (`index.ts:759-847`) → result `{status, text}` with `status` ∈
  `redirected` (correction applied), `queued` (agent still building → becomes next turn), `rejected` (turn ended;
  client re-queues the text locally) (`contracts/sessions.py:623-641`; errors `4002 text is required`,
  `4010 agent does not support active-turn redirect`, `methods_session_interrupt.py:101-134`).
- Attachments, or an approval/secret pending ⇒ client-side queue (persisted in `localStorage`
  `hermes.desktop.composerQueue.v1`, `V/store/composer-queue.ts:45`).
- Slash commands run immediately.
- Client queue auto-drains when the session is idle and not parked: `prompt.submit` with `queued:true`
  (`V/app/chat/composer/hooks/use-composer-queue.ts:210-262,350-433`); max 4 attempts, backoff 750 ms × attempt, then a
  "queue stuck" toast (`composer-queue.ts:505`). "Send Now" while busy = move to head + Stop (unparked) so it drains on
  settle (`use-composer-queue.ts:274-305`). Phone card UI: flag `PHONE_QUEUE_ROW`.
- Mid-turn redirect bubbles appear on resume through `inflight.corrections` + `correction_offsets` (§7.4).

**M1 recommendation:** while busy, show Stop; either disable Send or keep a simple local FIFO queue that drains with
`queued:true` after `message.complete` + `session.info running:false`. Do not send plain `prompt.submit` while busy
without `queued:true` unless you want the default `interrupt` redirect semantics.

**Native (verify round 3):** the queue outlives the chat screen. A chat left with messages still queued keeps listening
until they are out (the web's `use-background-queue-drain.ts`); the app model holds it and a reopen returns it. What is
left (a parked queue, or everything after an app kill) waits per chat in `QueueStash` (Application Support/queues, one
file per account; memos excluded, the park never written) and comes back on the next open. A fresh message unparks the
queue (`enqueueQueuedPrompt` does); sent while idle it goes first and the parked ones follow its reply.

**Native (owner 2026-10-28, desktop parity):** plain text typed while a reply runs no longer waits in the queue: it goes
into the running reply with `session.redirect`, as the desktop's Enter does (`use-composer-submit.ts:280-307`). The
bubble shows at once under what the bot already said; the live bubble is sealed there, so the reply to the steer lands
below it (`beginSteer`; the desktop's `appendMidTurnUserMessage`), and the turn's end scopes past its own steers
(`TurnState.correctionIds`). `queued` → the bubble moves to the newest end and the reply goes on in its own bubble;
`rejected`, 4010 / -32601 or a failure → the bubble goes and the text joins the queue (sends now when idle, else the
"Couldn’t add this…" notice). Still queued: photos and files, a skill or titled request (`display`), slash commands
(they run at once anyway), an open approval / password / question, a Stop still unwinding, a send waiting on another
process, a chat whose gateway can't redirect, a message a slash command sends, and anything sent with ⌘Return (the
desktop's ⌘Enter: queue, don't steer). Several quick steers go out in typing order. A chat opened mid-turn
rebuilds the steers from `inflight.corrections` + `correction_offsets` (the reply text before each one, the steer,
then the live reply after the last); a steer Hermes already stored as its own prompt row is not taken for the turn's
prompt.

---

## 7. Reconnect mid-stream (catch-up)

### 7.1 What the gateway does while the phone is away
- Every session event is stamped (`seq`) and stored in a per-session replay ring **before** the transport write, even
  when no client is attached (`H/tui_gateway/server.py:681-698`, `event_replay.py:67-128`). Ring: 512 events and
  4 MiB per session, 64 MiB / 64 sessions per process; frames larger than 4 MiB are not retained (truncation mark).
  `seq` counters survive ring eviction (`event_replay.py:92-107`); a gateway restart changes `replay_epoch`.
- On WS close the session's transport becomes a drop sink; the session is kept for **20 s** grace
  (`HERMES_TUI_WS_ORPHAN_REAP_GRACE_S` / `dashboard.ws_orphan_reap_grace_s`, `server.py:131-146`). After grace:
  idle ⇒ reaped (`session.reclaimed`); **running with activity in the last 600 s ⇒ keeps running detached** and is
  re-checked every grace; stale running ⇒ interrupted, then reaped (`session_lifecycle.py:851-985`). Sleep time does
  not count (`session_lifecycle.py:881-916`).
- Live events **do not reach a new socket until the session is re-bound** by `session.resume`, `session.activate` or
  `prompt.submit` (`_rebind_live_transport`, `session_lifecycle.py:830-845`; `methods_session.py:877-897,1166-1178`).
- The phone's native layer closes sockets ~20 s after the app backgrounds, so every return to the app is a reconnect
  (`P/replay-budget.ts:9-12`).

### 7.2 Client reconnect sequence (shipped)
1. New socket → `gateway.ready {skin, change_events, heartbeat, replay_epoch}`. If `replay_epoch` differs from the
   one held, **all seq cursors are discarded** (backend restarted; replay impossible) (`S/json-rpc-gateway.ts:422-433,616-644`).
2. For each session cursor (`lastSeenSeq` per runtime id; the phone keeps only the 8 most recently active,
   `P/replay-budget.ts:13`, `B/shared-replay-performance.ts:34`), newest first, 2 at a time
   (`P/replay-budget.ts:2,21-33`, `B/shared-replay-performance.ts:46-50`):
   ```json
   {"jsonrpc":"2.0","id":60,"method":"session.events.since","params":{"session_id":"01965554","last_seen":31}}
   → {"events":[{"type":"message.delta","session_id":"01965554","payload":{"text":" more"},"seq":32}, …],
      "latest_seq":57,"truncated":false,"count":26,"epoch":"9f1c…","open_requests":[]}
   ```
   (contract `contracts/sessions.py:723-737`; handler `methods_session.py:2334-2348`; timeout 10 s,
   `S/json-rpc-gateway.ts:54`). Each element of `events` is the frame's `params` object (not the envelope)
   (`event_replay.py:131-141`).
   - While the replay for a session is in flight, live frames for it are **parked**, then released after the replayed
     ones; everything is dispatched through the normal handler with `replayed:true`, dropping any `seq <=` cursor
     (`S/json-rpc-gateway.ts:438-447,534-610`). Phone caps parked frames at 2048 / 4 MiB, else it drops the socket and
     retries from the untouched cursor (`B/shared-replay-performance.ts:28-31`, `P/replay-budget.ts:3-4`).
   - `epoch` in the answer differs ⇒ adopt it, drop cursors, rely on REST.
   - `truncated:true` ⇒ the gap can't be replayed: the phone still dispatches what came, deletes the cursor and asks the
     visible chat to re-read its stored transcript (`B/shared-replay-performance.ts:98-115`,
     `B/replay-truncated-gates.ts:1-56`).
   - `open_requests` are re-delivered as server→client requests (`S/json-rpc-channel.ts:413-425`).
3. Busy flags of all sessions are cleared (`reconcileBusyStatesOnReconnect`, `V/store/session-states.ts:1100-1155`,
   called from `V/app/gateway/hooks/use-gateway-boot.ts:527`); a live turn re-asserts itself via its next event /
   `running:true`. Runtime bindings are dropped so each open chat re-resumes (`use-gateway-boot.ts:503-513`).
4. The open chat re-binds and re-reads the live state:
   - warm: `session.activate {"session_id":"<runtime>","cols":96,"omit_messages":true}`
     (`V/app/session/hooks/use-session-actions/index.ts:1460-1464`; native adds `"profile"`, §1.4); `4001`/`4007` →
     the cold path (§2.4.1);
   - cold / runtime gone: `session.resume {"session_id":"<stored>","source":"desktop","omit_messages":true,"profile":"<bot>"}`
     (`V/…/use-prompt-actions/utils.ts:123-133`; the web client names the row's profile here, native always does).
     A session still live in memory **in that profile** returns the **same** runtime id and cancels the orphan reap
     (`methods_session.py:877-897,1076-1078`).
5. If the chat stays silent 45 s → §4.8 probe.
6. Native, build 292 ("Chat catches up on return"): when the re-bind answers `running:false` and this chat still holds
   a send whose turn left no frame here (`busy && awaitingResponse && !turnLive && !sawAssistantPayload`, no stream, no
   Stop pending, nothing parked for it) and the arm is at least 15 s old (§4.6's pre-start rule), the turn came and went
   while the link was paused: it is settled **before** any REST read, so the read keeps the reply instead of cutting it
   as part of a running turn. When the reconnect made no REST read (replay or `session.events.since` covered it), its
   closing look at the tail runs at once (forced when that settle happened), not 1.2 s on. A read made while a turn runs (cut after its prompt) never records its newest row as "read", so the
   turn-end probe reads again. A `message.complete` from another socket, held while the activate ran, re-reads the tail
   like one arriving after it.

### 7.3 Rebind response fields used for the live turn (`LiveSessionSnapshot`, `contracts/sessions.py:74-97`; built by `H/tui_gateway/server.py:3157-3195` `_live_session_payload`)
`running`, `turn_started_at`, `status` (`idle|starting|waiting|working|streaming|resuming`),
`inflight` (`InflightTurn`, `contracts/sessions.py:30-44`), `queued {user}`, `open_requests`, `pending_approval`.

```json
"inflight":{"user":"Write 600 words about a lighthouse keeper","assistant":"The lamp turned at dusk, as it","streaming":true}
```
- `inflight.assistant` = concatenation of every `message.delta` text so far in this turn (`_append_inflight_delta`,
  `H/tui_gateway/session_history.py:404-412`); it is text only (no tool/reasoning structure).
- Failed-but-retained turn: `{"user":…,"assistant":<partial>,"streaming":…,"error":"…","status":"error","recoverable":true,"error_surface":{…}}`
  (`session_auto_continue.py:532-561`).
- Mid-turn redirects: `corrections:["…"]`, `correction_offsets:[<assistant chars streamed when it arrived>]`.

### 7.4 Merging the snapshot (`appendLiveSessionProjection`, `V/…/use-session-actions/utils.ts:1156-1330`)
- If `inflight.user` is not already the last persisted user row, add a user bubble `id "user-inflight-<runtime>"`.
- If the chat already has a structured live bubble for this turn (tool/reasoning parts), **keep it** — don't append the
  flat `inflight.assistant` dump. Otherwise add/extend the live assistant bubble `id "assistant-stream-<runtime>"` with
  `inflight.assistant`; subsequent `message.delta`s append to it. If stored history already holds a partial assistant
  row that `inflight.assistant` extends, fold into that row instead of adding a second bubble.
- `queued.user` → a trailing user bubble `id "user-queued-<runtime>"`.
- Then `busy = running`, `turnStartedAt = turn_started_at*1000`.

**M1 simplification:** on reconnect, (1) replay via `session.events.since` from the last `seq` seen for the open chat;
(2) if replay is impossible (`truncated`, epoch change, no cursor) re-read history over REST and apply `inflight`
from `session.activate`/`session.resume`; (3) always re-bind with `session.activate` (or `session.resume`) or no
further live events arrive.

### 7.5 Cross-socket duplicate guard
If two sockets to one gateway are ever open, the same event arrives twice. The shipped client drops events whose
`(replay_epoch, session_id, seq)` was seen within 30 s (`V/app/gateway/gateway-event-dedupe.ts:1-80`). Native should
keep one socket per gateway and still dedupe on `(epoch, session_id, seq)`.

---

## 8. Replies that don't stream

- `H/agent/turn_api_call.py:46-64` `_should_stream` returns False when `agent._disable_streaming`, the base URL is
  `acp://`/`acp+tcp://`, or the provider is an **external_process** provider. The owner's bots mostly use the
  `claude-subscription-directsdk-experimental` plugin provider (`auth_type='external_process'`) — so their replies do
  not stream. The upstream fix (`ProviderProfile.supports_streaming`) is **not** in `d94b70f6` (the function has no
  such check). Not an app bug; never patch Hermes.
- What arrives instead (live, `R/docs/stage2-report.md:31-48`): `message.start`, a couple of `thinking.delta`
  wait notices, `reasoning.available` (whole reasoning), `session.title`, then `message.complete` whose `text` is the
  **entire** reply (3,903 chars in that run), then `session.info running:false` — **no `message.delta` at all**.
- Disagreement: the phone code and the memory note say the reply comes as **one** large `message.delta` before
  `message.complete` (`P/ui-chat/reply-reveal.ts:1-3`). Both shapes must work:
  - zero deltas: §4.5 step 4 appends a new bubble from `message.complete.text` (or settles the pending bubble);
  - one big delta: normal delta path; `message.complete` text equals streamed text → no change.
- The phone's progressive reveal (§4.10) only triggers on a big `message.delta`; a complete-only reply appears at
  once today. Native may apply the same reveal to a complete-only reply (presentation only).
- Liveness: during the silent seconds the phone's socket watch (§1.5) treats the turn as streaming after
  `message.start`/`thinking.delta`, and the 45 s silence probe (§4.8) asks `session.active_list` → `working` keeps it.

---

## 9. Ordering and edge-case checklist

1. `message.start` can precede the `prompt.submit` result (§2.3).
2. Late frames of a previous turn after its `message.complete` (reordered/duplicated) must not seed a bubble in the new
   turn: drop queued deltas on a `message.start` when no turn is live (`message-stream.ts:91-101`).
3. A `running:false` `session.info` can arrive **before** `message.complete` (#119569) — settle, but let the late
   complete land on the same bubble (`session-info.ts:425-437`).
4. A `running:false` `session.info` within 15 s of an optimistic send, before the backend reported the turn live, is
   ignored (§4.6).
5. Tool completions can arrive after the bubble that started them was sealed by an interim — match by `tool_id`.
6. Background turns (server queue drain, goals) produce full sequences with no client submit.
7. After Stop, ignore everything for that session until the next send, except merging an extending
   `status:"interrupted"` partial — unless the interrupt failed (`5032`/timeout): then §5.6 step 4 (re-interrupt on
   `message.start`; never drop a completed reply).
8. Unscoped events (empty `session_id`) attribute to the active chat only if it has a live turn
   (`V/…/gateway-event/index.ts:173-196`); `session.reclaimed` names its runtime in `payload.session_id`.
9. `session.reclaimed` for the open chat: drop the runtime id; next send resumes the stored id (§2.4 4001 path)
   (`V/…/gateway-event/lifecycle.ts:97-131`).
10. Seq is per runtime session id; a resume that mints a **new** runtime id starts a new cursor.

---

## 10. Fixture gateways vs the real gateway

| Topic | Fixture (`R/scripts/…`) | Real (`H/…`) |
|---|---|---|
| Event envelope | `{'type','session_id','payload': payload or {}}`, **no `seq`** (`build47-fixture-gateway.py:41-46`) | `payload` omitted when none; `seq` always on session events |
| `gateway.ready` | `{'heartbeat':True,'change_events':True,'replay_epoch':'build47','desktop_contract':8}` (`build47…:144`) | `{skin, change_events, heartbeat, replay_epoch}` (`ws.py:364-369`) |
| Turn sequence | `message.start` → `message.delta`×n (→ `tool.start`/`tool.complete`) → `message.complete {'text','row_id'}` (`build47…:54-67`, `performance-fixture-gateway.py:19-46`) | adds `session.info running:false`, `status`, `usage`, `persisted_turn`; no `row_id` |
| `prompt.submit` result | `{'status':'streaming','user_row_id':N}` (`build47…:126`, `action-voice-fixture-gateway.py:48`) | same |
| Submit test knobs | plans: `reject`+`code`, `dropAck`, `holdAck`, `ackDelay`, `disconnect`, `persist:false`, `chunks`, `chunkDelay`, `replyDelay`, `replyText` (`build47…:102-129`, `POST /__fixture/plan`) | — |
| `session.interrupt` | emits `message.complete {'text':'Stopped synthetic reply.'}`, returns `{'status':'interrupted'}` (`build47…:83-87`) | §5.4 |
| `session.active_list` | `{'sessions':[{'session_id','stored_session_id','status':'running','running':True}]}` (`build47…:81-82`) | `{'sessions':[{'id','status':'working',…}]}` — the fixture shape makes the §4.8 probe read "ended" |
| `session.events.since` | always empty, `truncated:false`, `epoch:'fixture'` (`action-voice-fixture-gateway.py:67`) | §7.2 |
| Busy submit | always accepts and restarts the stream | redirect/queue/steer (§6.1) |
| `session.redirect` | appends a user row, `{'status':'redirected','user_row_id':rid}` (`build47…:88-92`) | result has `{status,text}`, no `user_row_id` |

`R/scripts/gateway-replay.py` replays recorded real traffic (`docs/replay-gateway.md`); its synthetic
`session.events.since` answers `latest_seq = last_seen` with no events (`gateway-replay.py:117`).

---

## 11. Error-code summary for this area

| Code | Methods | Meaning |
|---|---|---|
| 4000 | all | unknown param key |
| 4001 | submit, interrupt, redirect, activate, events.since | runtime id not live → resume stored id |
| 4002 | redirect/steer | empty text |
| 4004 / 4029 | submit | malformed / unconfirmed truncation |
| 4007 | submit, resume, activate (+ delete, workspace.move) | two meanings by message (§2.4.1): `session no longer live; retry resume` = runtime reaped mid-call → like 4001; `session not found` (resume) = stored id not in that profile's store → terminal |
| 4009 | submit | session busy / subagent running / disconnect-interrupt settling — all pre-admission; retry by code (§2.4.1) |
| 4064 | any method naming `profile` | `Profile '<name>' does not exist.` → refetch the roster (§1.4) |
| 4010 | redirect/steer | not supported by agent |
| 4090 | submit | active-session refusal (`data.reason`) |
| 4091, 4120-4124, 5122 | submit | hosted rooms / groups (not M1) |
| 5019 | interrupt | compute-host interrupt failed |
| 5032 | interrupt (via `_sess`) | agent still starting (after a 30 s wait that blocks the socket) / build failed; the turn was **not** cancelled (§5.2, §5.6) |
| 5035 | all | backend retiring |
| 5070-5072 | submit | storage failure, not saved |
| -32601 / -32602 / -32700 / -32603 | all | unknown method / bad params / parse / internal |

---

## 12. UNKNOWNs and disagreements

1. **Non-streamed replies: zero vs one `message.delta`.** Live recordings show zero (`docs/stage2-report.md:46-50`);
   the phone code/memory say one big delta. The exact agent path for external_process providers was not traced to
   the end. Handle both.
2. ~~4007 handling~~ — **RESOLVED from source (§2.4.1).** The web client does not recover a submit
   `4007 session no longer live; retry resume` (text matcher) and the phone shows "Delivery Unconfirmed"; the refusal
   is pre-admission, so native resumes + resubmits once, like 4001. `4007 session not found` from `session.resume` is
   a different, terminal meaning.
3. ~~Stop before agent ready~~ — **RESOLVED (§5.4).** The shipped phone suppresses the cancelled-before-ready `error`
   (gate r3-03 + `CANCELLED` regex); native treats it as a stop and as the turn's terminal frame.
4. ~~`session.interrupt` during a slow agent build~~ — **RESOLVED from source (§5.2, §5.6).** It blocks the socket up
   to 30 s, then `5032` without cancelling; the phone drops the reply that follows. Native re-sends the interrupt on
   the turn's `message.start` and never drops a completed reply. Still not observed live (source reading only).
5. **Dedupe window comment** in `V/app/gateway/gateway-event-dedupe.ts:21-28` says seq restarts at 1 after ring
   eviction; current Hermes keeps counters (`event_replay.py:92-107`). Harmless; noted.
6. Loss/recovery **during an actively generating turn** has not been proven live (`docs/stage2-report.md:42`);
   §7 is from source.
7. `Usage` field values in examples are illustrative; field names are from the contract.
8. Whether the owner's gateway has `display.tool_progress`, `show_reasoning`, `busy_input_mode` overridden is
   unknown — the client must not assume tool or reasoning events will arrive.
9. ~~Omit `profile` for the primary bot~~ — **RESOLVED (§1.4).** Omitted means the gateway's launch profile, not the
   phone's `ios.defaultProfile`; native always names the profile on WS and REST (except a `custom` launch home).

---

## 13. M1 implementation checklist (derived)

- [ ] One WS per gateway; `params.profile` on **every** session RPC and `?profile=` on every profile-scoped REST call,
      launch bot included (omit only for a `custom` launch home) (§1.4).
- [ ] `prompt.submit {session_id, text, profile}`; 30 min ack timeout; optimistic bubble + `busy` immediately.
- [ ] Accept events before the ack; bind `user_row_id` when it arrives.
- [ ] 4009 (by code) → retry 150 ms up to 6 s; 4001 and `4007 session no longer live` → `session.resume` stored id
      once, retry once; `4007 session not found` on resume → terminal; no auto-resend after timeout or socket loss —
      show "Delivery unconfirmed" + read-only check only for those (§2.4.1).
- [ ] Event handling: `message.start`, `message.delta` (coalesce ~33 ms), `reasoning.*` (optional UI),
      `thinking.delta` (status only), `message.interim` (seal), `tool.start/complete` (by `tool_id`),
      `message.complete` (settle, errors, interrupted), `session.info.running`, `error`, `session.reclaimed`.
- [ ] Track `seq` per runtime session and the gateway's `replay_epoch`.
- [ ] Stop: local seal + `interrupted` flag → `session.interrupt` (40 s timeout); ignore later frames except an
      extending interrupted partial; clear `interrupted` on next send. On 5032/timeout → `stopPending`, re-interrupt on
      the turn's `message.start`, never drop a completed reply; the cancelled-before-ready `error` is a silent stop and
      a terminal frame (§5.4, §5.6).
- [ ] Reconnect: `session.events.since` → re-bind (`session.activate` / `session.resume`) → apply `inflight`;
      REST refetch on `truncated` / epoch change.
- [ ] 45 s silence → `session.active_list` probe.
- [ ] Non-streaming providers: render `message.complete.text` as the reply (optionally reveal progressively).
