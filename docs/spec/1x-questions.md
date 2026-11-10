# 1x · Questions: approvals, bot questions and password prompts (stream "questions")

Implementation-ready spec for the "Approvals and password prompts" line of `NAT:docs/parity.md:22`. It turns on what
milestone 1 deliberately left off (spec 01 §0.1 **D1**, §11.6.1): HQ Native now tells the gateway it answers
server→client requests, and answers each one exactly once, with the owner's approved phone UI.

Where this spec and the reference web app disagree, the web app's behaviour wins (`NAT:docs/ARCHITECTURE.md:4-5`),
except for the rows marked **DECISION** in §0.2. Each of those says why and how to switch back.

---

## 0. Sources, notation, decisions

| Prefix | Path |
| --- | --- |
| `HA:` | `/Users/me/.hermes/hermes-agent/` (Hermes, checkout `d94b70f`, 2026-10-08). Read only, never run or imported. |
| `W:` | `/Users/me/Projects/hermes-hq-native-ref238/` (web app at release-build238, read only). |
| `V:` | `W:vendor/hermes/apps/` (vendored desktop renderer + shared transport; what runs = file + `W:build/*-gates.ts`). |
| `NAT:` | `/Users/me/Projects/hermes-hq-native/` (this repo). |
| `MEM:` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/`. |
| `PLAID` | `/Users/me/Projects/hermes-ios/.claude/worktrees/plaid-stress-testing-5e35d8/.build/stability-round/tools/memory/` (untracked). |

"srq" = a server→client JSON-RPC request (id `srq-<12 hex>`, `HA:tui_gateway/server_requests.py:67`). "Entry" = HQ
Native's local record of one open srq or one queue-backed approval (§3.2). Runtime id = the 8-hex live session id that
events and srqs carry; stored id = the `state.db` session id (spec 01 §11.4, spec 03 §1).

### 0.1 Scope

In: the capability handshake, every srq method (answered, declined, or `-32601`), `open_requests` re-delivery,
`request.cancel` and `approval.cancelled`, approval expiry, multi-client rules, and these screens:

- the approval card in the chat;
- the question dock in the composer's place, with its transcript note, the sent answers and the settled Q&A card;
- native sheets for sudo, secret, vault unlock, vault save-login and vault code, with the swipe-away chip;
- the "Waiting for your approval / reply" status in the chat header and on Bots rows.

Out: §8.

### 0.2 Decisions (DECISION = HQ Native differs from the web app on purpose)

| # | Question | Decision | § |
| --- | --- | --- | --- |
| Q1 | Advertise? | **Yes.** Send `client.capabilities {"server_requests":true}` as the first frame after every `gateway.ready`. This replaces spec 01 **D1**. | 2.1 |
| Q2 | Which socket carries an answer? | The **current** socket. `resolve_response` looks the id up in one process-wide map and ignores which transport sent it (`HA:tui_gateway/server_requests.py:265-305`; routed at `HA:tui_gateway/rpc_dispatch.py:52-58`). A request that came in on a socket that has since dropped is answered on the new one. A queue-backed approval with no srq uses `approval.respond`. `request.answer` is **not** used: the web never calls it, and one answer path is enough. | 2.3 |
| Q3 | `terminal.read`, `preview.read`, `window.read`, `preview.act`, `tour` | **DECISION:** always decline with `4404` when the backend reported `declines_not_shown:true`, and stay silent otherwise. The phone shows no pane. The web phone runs the desktop handlers: for the chat on screen it answers an empty value (terminal/preview/window) or "The user has turned guided tours off." (`V:desktop/src/app/session/hooks/use-message-stream/gateway-event/server-requests.ts:478-602`; tours off on phones, `W:build/affordance-gates.ts:22-25`). That answer wins the race against a desktop window that really shows the pane (`HA:tui_gateway/server_requests.py:24-28`). | 2.3 |
| Q4 | `setup_choose`, `display.install.sudo`, unknown methods | `-32601` at once, as the web does. The web has no `setup_choose` handler (`server-requests.ts:605-619`) and its channel answers `-32601` (`V:shared/src/json-rpc-channel.ts:407`). HQ Native never clicks Bot Screen Install, so `display.install.sudo` never targets it. | 2.3 |
| Q5 | `approval.received` | **Not sent.** The flag it sets (`HA:tools/approval.py:210-217`) is never read. The wait's clock starts at enqueue (`HA:tools/approval_gateway_wait.py:46-70`). The web's live path doesn't send it either (`server-requests.ts:353`, gateway `null`). | 2.6 |
| Q6 | Where the approval card goes | A transcript row at the newest end, like the web's inline `PendingApprovalStack` (`V:desktop/src/components/assistant-ui/tool/approval.tsx:50-77`; App Store shot `W:artifacts/app-store-screenshots/iphone-6.9/03-approval.png`). **DECISION:** no swipe-left-to-deny (web `CardStack swipeDirections={['left']}`, `approval.tsx:205-217`): an accidental swipe would deny a command, and Reject is one tap. | 4.2 |
| Q7 | Button shape on the card | **DECISION:** capsules. The owner settled "buttons are pills; fields stay rounded rects" (`MEM:chat-refinement-shapes.md`). The web card still draws small-radius rects (screenshot above). | 4.2 |
| Q8 | A long command | **DECISION:** clamp at 8 lines with "Show All", which opens the step sheet's Command block (`NAT:App/Chat/ChatSheets.swift`). The web scrolls inside a 160 px box (`approval.tsx:347`), and a scroller nested in the inverted transcript fights the chat's own scrolling. | 4.2 |
| Q9 | Sudo with an empty field | **DECISION:** Send is disabled while the field is empty. "Don’t Send" is the explicit refusal. The web enables Send and sends `""`, which refuses (`V:desktop/src/components/prompt-overlays.tsx:159`). | 4.5 |
| Q10 | Copy that points at Settings | **DECISION:** leave out "raise the limit in Settings → Safety", "Open Safety settings" and the vault footnotes that name Settings → Passwords & Logins. HQ Native has no Settings yet. Restore them with the Settings stream. | 4.2, 4.5 |
| Q11 | Header status for vault prompts | **DECISION:** "Waiting for your approval". The web header counts approval/sudo/secret only (`W:src/ui-chat/turn-state.ts:82-84`). Its Bots rows already read any non-question input as an approval (`W:src/ui-bots/asking.ts:1-3`). One rule for both places. | 4.1 |
| Q12 | The dock's surface | ~~Solid elevated, as on the web (`W:src/phone-question-dock.css:6-8`). It is a panel of text people read and pick from (spec 06 §8.5). **Not glass.**~~ **Reversed by the owner on 2026-10-30** ("more Liquid Glass"): the card is native `UIGlassEffect(.regular)`, untinted, without the drawn hairline and shadow. Measured over a busy transcript (dark, a photo behind) the question on bare glass fell to 2.7–3.3:1, so the text section sits on a solid inner card 8 pt inside the glass (radius 18) and Back is a solid capsule; the choice list and the field keep opaque fills. The Desktop Look has no glass: there the card stays the solid elevated panel below. | 4.3 |
| Q13 | Queued messages while the dock shows | The queue card stays, 8 pt above the dock. M1's rule is that a send never seems lost (`NAT:App/Chat/ChatQueueCard.swift:3-5`). | 4.3 |
| Q14 | When a password sheet appears | At once while that chat is on screen, as the web's mounted dialogs do (`prompt-overlays.tsx:581-591`). If something else is presented, the chip shows and the sheet waits. Never over another chat. | 4.5 |
| Q15 | Where typed answers live | In memory only: question drafts by request id, sheet text inside its kept view controller. Never on disk, never logged, never cached. Dropped on answer, cancel, sign-out or app exit. | 3.2 |

---

## 1. What changes, in one paragraph

From a gateway's point of view, M1 was "a client that predates server requests". If HQ Native was the only client on a
chat, every approval was withdrawn, every question came back `undelivered`, and every password prompt was skipped
(spec 01 §11.6.1 table). Now HQ Native advertises on every socket. Hermes then **waits** for the phone: approvals up to
`approvals.timeout` (default 300 s), questions up to the clarify timeout (default 3,600 s), sudo 120 s, secret 300 s,
vault 120–180 s (§2.8). With nothing attached the request still waits, and comes back as `open_requests` on the next
resume (`HA:tui_gateway/session_transports.py:38-47`). So every one of these needs a reachable, reliable UI.
**Don't ship the handshake without the UI** (§9 R1).

---

## 2. Wire protocol

All of it is JSON-RPC 2.0 over the existing `/api/ws` socket (spec 01 §9–§13). Hermes rejects **unknown params keys**
with `4000` "invalid params for <method>: <key>: Extra inputs are not permitted — the client and the Hermes backend are
out of sync…" (`HA:tui_gateway/contracts/base.py:32-35`, `HA:tui_gateway/contracts/registry.py:92-110`,
`HA:tui_gateway/rpc_dispatch.py:28-31`). Every params object below lists **all** allowed keys. Send no others.

### 2.1 Capability handshake (every socket)

Right after `gateway.ready`, as the **first** frame on that socket (before the replay's `session.events.since`, before
any chat's `session.activate`/`session.resume`):

```json
{"jsonrpc":"2.0","id":1,"method":"client.capabilities","params":{"server_requests":true}}
```
- Params contract: **only** `server_requests` (`HA:tui_gateway/contracts/liveness.py:28-32`). **No `profile`**:
  that key answers `4000`.
- Result (`HA:tui_gateway/methods_voice.py:442-450`; contract `liveness.py:35-47`):
  ```json
  {"jsonrpc":"2.0","id":1,"result":{"server_requests":["approval","clarify","display.install.sudo","preview.act","preview.read","secret","setup_choose","sudo","terminal.read","tour","vault.code","vault.save_login","vault.unlock_prompt","window.read"],"declines_not_shown":true}}
  ```
  Store `declinesNotShown = result.declines_not_shown == true` for **this socket epoch**. Reset it to `false` when the
  socket closes. `-32601` (an old backend) or a timeout: leave it `false` and carry on.
- Fire and forget (10 s timeout). **Don't** hold `publish(ready)` for the answer. Order is what matters: the server
  handles `client.capabilities` inline on its reader thread (it is not in `_LONG_HANDLERS`,
  `HA:tui_gateway/server.py:181-199`). It is therefore in effect before any later frame from this socket is processed.
- The mark belongs to the connection and is forgotten on disconnect (`HA:tui_gateway/server.py:737-743`,
  `HA:tui_gateway/server_requests.py:129-141`). Re-advertise after **every** `gateway.ready`, as the web does
  (`V:shared/src/json-rpc-channel.ts:497-518`; sent on every open, `W:src/rpc-flight.ts:174-176`).
- Native change: in `GatewayConnection.ready(_:epoch:)` (`NAT:HermesKit/Net/GatewayConnection.swift:578-591`),
  replace the `// D1: no client.capabilities` comment (`:587`) with the send. Delete D1 from spec 01 §0.1 at
  integration and point it here.

### 2.2 Server→client request frames

Shape (`HA:tui_gateway/server_requests.py:82-84`):
```json
{"jsonrpc":"2.0","id":"srq-3f9a1c2b7d4e","method":"<method>","params":{"session_id":"5cc537d1", "...":"..."}}
```
Frame rule: `id` is a string, and `method` is a string other than `"event"`. That is `RPCFrame.serverRequest`, already
parsed (`NAT:HermesKit/Net/RPCFrame.swift:14-15,30-34`). Hermes writes the frame once, to the session's transport,
which fans out to **every** attached client, advertised or not (`HA:tui_gateway/server.py:690-697`).
`_register` validates Hermes' own params against the contract, so the shapes below are exact
(`HA:tui_gateway/server_requests.py:161-172`).

| Method | Params beyond `session_id` (contract `HA:tui_gateway/contracts/server_requests.py`) | Raised by / Hermes wait | HQ Native |
| --- | --- | --- | --- |
| `approval` | `request_id` (32-hex queue id), `command` (redacted), `description`, `choices` ⊆ `once,session,always,deny`, `allow_permanent?`, `allow_session?`, `smart_denied?`, `tool_name?`, `gateway_session_id?`, plus open extras such as `pattern_key`, `pattern_keys` (`:100-130`) | dangerous command / plugin rule gate; `approvals.timeout`, default 300 s (`HA:tools/approval_context.py:256-271`) | approval card §4.2 |
| `clarify` | `questions: [{qid, question, choices: [str] \| null, multi_select}]` (1–5 questions, ≤ 4 choices, `HA:tools/clarify_tool.py:8-9`); `answers: {qid: str\|null}` **only on a reconnect replay** (`:34-55`) | clarify tool; `clarify.timeout` or `agent.clarify_timeout`, default **3,600 s**, ≤ 0 = forever (`HA:tools/clarify_gateway.py:263-282`; `HA:tui_gateway/server.py:1408-1415`) | question dock §4.3 |
| `sudo` | `command` (redacted; may be `""`) (`:140-147`) | terminal tool's sudo; 120 s (`HA:tui_gateway/agent_callbacks.py:256-257`) | sheet §4.5 |
| `secret` | `env_var`, `prompt`, `metadata?` (`:150-157`) | skill secret capture; 300 s (`agent_callbacks.py:231-254`, `_ask` default `server.py:1398`) | sheet §4.5 |
| `vault.unlock_prompt` | `backend`, `display_name` (`:160-166`) | external password manager unlock; 120 s (`agent_callbacks.py:265-266`) | sheet §4.5 |
| `vault.save_login` | `origin`, `site` (`:169-175`) | browser vault, no saved login; 180 s (`agent_callbacks.py:268-276`) | sheet §4.5 |
| `vault.code` | `site?`, `hint?` (`:178-184`) | browser vault 2FA; 180 s (`agent_callbacks.py:278-279`) | sheet §4.5 |
| `terminal.read`, `preview.read`, `window.read` | `start?`, `count?` (none for window) (`:190-200`) | desktop panes; 30 / 45 / 30 s | decline (Q3) |
| `preview.act`, `tour` | action fields (`:203-246`) | desktop panes; 10 s probe then 45 s (`server.py:1436-1467`) | decline (Q3) |
| `setup_choose` | `kind`, `question`, `options?`, `multi_select`, `preselected?` (`:59-94`) | onboarding cards; clarify timeout | `-32601` (Q4) |
| `display.install.sudo` | none (sessionless) (`HA:tui_gateway/contracts/display.py:167`) | Bot Screen Install, calling socket only | `-32601` (Q4) |

Example frames (shapes per the contracts; values illustrative):
```json
{"jsonrpc":"2.0","id":"srq-0c51a9e2b8f4","method":"approval","params":{"session_id":"5cc537d1","command":"git push --force origin main","pattern_key":"git force push (rewrites remote history)","pattern_keys":["git force push (rewrites remote history)"],"description":"git force push (rewrites remote history)","allow_permanent":true,"allow_session":true,"request_id":"9b1d6f0e2c4a4e83a1d2c3b4e5f60718","choices":["once","session","always","deny"]}}
{"jsonrpc":"2.0","id":"srq-77aa01bb22cc","method":"clarify","params":{"session_id":"5cc537d1","questions":[{"qid":"q0","question":"Which branch should I deploy?","choices":["main (Recommended)","staging"],"multi_select":false},{"qid":"q1","question":"Anything to skip?","choices":["Tests","Lint","Docs"],"multi_select":true},{"qid":"q2","question":"What should the release be called?","choices":null,"multi_select":false}]}}
{"jsonrpc":"2.0","id":"srq-1e2f3a4b5c6d","method":"vault.save_login","params":{"session_id":"5cc537d1","origin":"https://shop.example.com","site":"Example Shop"}}
```
Where the fields come from: an approval's `pattern_key` and `description` are the matched pattern's description
(`HA:tools/approval_detection.py:1548-1575`, e.g. `:447`). `request_id` is `uuid4().hex`
(`HA:tools/approval_gateway_wait.py:32`). `choices` is computed when absent: `once`, then `session` and `always` unless
smart-denied or disallowed, then `deny` (`HA:tui_gateway/server.py:765-778`). Choice labels: the first choice is
suffixed ` (Recommended)` when there are ≥ 2 (`HA:tools/clarify_tool.py:19-26`).

### 2.3 Answering: response frames (exactly once)

An answer is a JSON-RPC **response** with the srq's id, `result` or `error`, and **no** `method`
(`HA:tui_gateway/server_requests.py:370-372`). Hermes sends no reply to it. The first answer settles the request for
every client. A later one is dropped silently (`:265-305`).

| Method | Answer | Meaning |
| --- | --- | --- |
| `approval` | `{"jsonrpc":"2.0","id":"srq-…","result":{"choice":"once"}}` (also `session`, `always`, `deny`). Never send `all` (the phone never offers "approve all"; web `answerApproval(…, all = false)`, `V:desktop/src/store/prompts.ts:363-371`) | `on_result` → `resolve_gateway_approval(choice, request_id)` (`HA:tui_gateway/server.py:834-846`) |
| `clarify` | **answers go through `clarify.lock`** (§2.6). **Skip** = `{"result":{}}`: no `answers` key means cancel-all (`contracts/server_requests.py:48-52`; web `W:src/phone-question-dock.tsx:201-206`) | Hermes merges the earlier locks: `{"answers": <locked>, "outcome": "cancelled"}` (`server_requests.py:291-300`) |
| `sudo`, `secret`, `vault.unlock_prompt`, `vault.code` | `{"result":{"value":"<typed>"}}`; decline = `{"result":{"value":""}}` | `""` = skipped / refused (`contracts/server_requests.py:24-28`; `server.py:1398-1404`) |
| `vault.save_login` | `{"result":{"value":"{\"identifier\":\"me@example.com\",\"password\":\"…\"}"}}` (a JSON **string**, identifier trimmed); decline `{"value":""}` | Hermes keeps it only when it parses and has `password` (`HA:tui_gateway/agent_callbacks.py:268-276`) |
| window-owned five (Q3) | when `declinesNotShown`: `{"jsonrpc":"2.0","id":"srq-…","error":{"code":4404,"message":"This window is not showing the session."}}`; otherwise **no frame** | a decline is one client's vote. Once every advertising client has declined, Hermes answers the tool "No Hermes Desktop window is showing this chat…" (`server_requests.py:110-114,238-262`). Text as the web's (`server-requests.ts:88`) |
| `setup_choose`, `display.install.sudo`, any unknown | `{"error":{"code":-32601,"message":"no handler for server request: <method>"}}` | unanswered, so the tool fails fast (`json-rpc-channel.ts:407`) |
| handler threw | `{"error":{"code":-32603,"message":"server request handler crashed: <method>"}}` | as the web (`json-rpc-channel.ts:384-395`) |
| a request for a chat whose turn the user already Stopped (local `turn.interrupted`) | approval/sudo/secret/vault: `{"error":{"code":-32603,"message":"session interrupted"}}`; clarify: `{"result":{}}` | the web refuses rather than parking a card for a dead turn (`server-requests.ts:244-252,275-279`) |
| `clarify` with no usable question (§4.3 normalisation drops all) | `{"result":{}}` | as the web (`server-requests.ts:294-298`) |

**Exactly-once guard** (web `json-rpc-channel.ts:352-367`, `V:desktop/src/store/server-requests.ts:26-38`): the
entry's `state` goes `open → answering` before the frame is handed to the socket. A second tap, a re-delivery or a
racing cancel can't send again. On a successful hand-off the entry is removed and its id goes into
`recentlyAnswered` (128 ids, 10 min) **with the epoch of the socket the frame went out on**. A later re-delivery of that
id **on the same socket** is ignored: a resume answer built before Hermes processed ours can still list it, and Hermes
handles one socket's frames in order. A re-delivery on a **later** socket means Hermes never saw the answer (the frame
left the phone, then the socket died: a lock, a Wi-Fi to cellular switch). The id is forgotten and the request counts
as new: shown again, or its automatic answer (4404, -32601, -32603, `{}`) sent again. (Review fix: a 10-minute blanket
ignore left the bot hanging with no UI.) An answer confirmed by an RPC result (`clarify.lock`, `approval.respond`) is
ignored on every socket.

**Socket down when the user answers:** don't send. Keep the card, dock or sheet with its input, and show the offline
toast (§4.7). A sheet whose answer is on its way stays up with its text (`ValuePrompt.sending`) until the request is
removed. Nothing is queued or resent automatically. If `URLSessionWebSocketTask.send` completes with an error,
take the id back out of `recentlyAnswered` and put the entry back (`open`), so its re-delivery shows again. Toast
"Could not send your answer".

### 2.4 Re-delivery: `open_requests`, `pending_approval`

- `session.resume` (live session), `session.activate` and `session.events.since` results carry the session's
  still-open srqs, oldest first (`HA:tui_gateway/server_requests.py:349-353`, `HA:tui_gateway/server.py:781-795`):
  `"open_requests":[{"id":"srq-…","method":"clarify","params":{"session_id":"5cc537d1","questions":[…],"answers":{"q0":"main"}}}]`.
  Contract: `HA:tui_gateway/contracts/sessions.py:21-27`. Clarify snapshots add `answers` (locks already accepted,
  `server_requests.py:86-92`).
- Resume/activate payloads include `open_requests` and `pending_approval` **only when non-empty**
  (`HA:tui_gateway/server.py:3191-3196`). `session.events.since` always includes `open_requests`
  (`HA:tui_gateway/methods_session.py:2334-2348`). **So for all three methods, a missing key means "none open".**
- `pending_approval` = the oldest unresolved approval-queue entry, in the client-safe shape (redacted command,
  `choices` computed) (`server.py:808-816`). It exists alongside the srq when one was sent. It is the only copy when
  none was sent.
- **Deliver before the caller sees the result** (web `json-rpc-channel.ts:413-426,465-483`). Native: in
  `GatewayConnection.settle(_:_:)` (`NAT:HermesKit/Net/GatewayConnection.swift:221-225`), when the pending call's
  method is one of the three, yield **before** resuming the continuation:
  1. one `LocalEvent.serverRequest` per `open_requests` entry with `replayed: true`;
  2. then one `LocalEvent.openRequests` with payload
     `{"session_id": <result.session_id ?? params.session_id>, "ids": [...], "pending_approval": <obj|null>, "method": "<method>"}`.

  The connection's own replay (`replayOne`, `GatewayConnection.swift:622-650`) goes through `settle` too, so it is
  covered.
- **Cheap probe:** `session.events.since {"session_id":"<runtime>","last_seen":2147483647[,"profile":"<p>"]}` returns
  no events and the authoritative `open_requests`. The web uses the same trick with `MAX_SAFE_INTEGER`
  (`V:desktop/src/components/assistant-ui/clarify/use-undelivered.ts:9-53`). `2147483647` keeps the JSON an integer
  (`last_seen: int`, `contracts/sessions.py:723-724`). It is a pure read, never truncated (`is_truncated` compares
  `last_seen < evicted_through`, `HA:tui_gateway/event_replay.py:144-148`), and needs no attach.

### 2.5 Withdrawals

- `request.cancel` event `{"type":"request.cancel","session_id":"<runtime>","payload":{"id":"srq-…","method":"approval","reason":"timeout"}}`.
  Reason ∈ `timeout`, `interrupted`, `shutdown`, `resolved`, `session_closed`, or free words from `tools/approval`
  (`HA:tui_gateway/contracts/server_requests.py:252-267`). It is emitted **once** per withdrawal: timeout
  (`server_requests.py:207-208`), Stop/close (`:328-346`, `HA:tui_gateway/server.py:1534-1538`,
  `HA:tui_gateway/session_lifecycle.py:759`), an approval settled by another path (`approval.respond`, `/approve`,
  timeout: `_drop_entry` → `settle(reason)`, `HA:tools/approval_gateway_wait.py:172-197`).
  **It is not emitted when another client answers the srq by response frame**: `resolve_response` pops the id first,
  so the later `settle` finds nothing open (`server_requests.py:224-229,284`). §3.5 covers that case.
- `approval.cancelled` (broadcast, `session_id` in the payload)
  `{"session_id","stored_session_id","reason","cancelled_count","request_ids":[queue ids]}`, sent before Stop
  deny-resolves every queued approval (`HA:tui_gateway/session_lifecycle.py:484-513,760-768`; contract
  `HA:tui_gateway/contracts/events.py:407-424`).

### 2.6 Client→server RPCs this stream sends

`profile` = the chat's `profileParam`: present for every bot except the launch profile, which has no name (spec 04
§1.4, rule 2). Timeouts are client-side. The server keeps working after a client timeout.

| Method | Params (complete allowed set) | Result | Errors / notes |
| --- | --- | --- | --- |
| `client.capabilities` | `server_requests` | §2.1 | `-32601` on old backends: ignore |
| `clarify.lock` | `request_id` (the srq id), `question_id` (qid), `answer` (string, or `null` = skipped; non-strings are JSON-encoded by Hermes), `profile?` (`HA:tui_gateway/contracts/prompt_voice.py:252-273`). **No `session_id`**: it answers `4000`. | `{"status":"ok","remaining":["q2"]}`; the lock that empties `remaining` resolves the request, and **no** response frame is needed. `{"status":"expired"}` = the wait already ended, not an error (`HA:tui_gateway/methods_prompt.py:1146-1165`) | `4002` "request_id and question_id required" / "unknown question_id 'qX'". Timeout 30 s |
| `approval.respond` | `session_id` (runtime), `profile?`, `choice`, `all`, `request_id` (`prompt_voice.py:317-331`) | `{"resolved":1}` (`0` = nothing pending: already settled) | `4001` session not found (Hermes then tries a durable fallback by `request_id`, `methods_prompt.py:1204-1218,1369-…`). **Timeout 330 s, retry once on timeout only** (web `V:desktop/src/store/prompts.ts:357-407`). Used only for queue-backed approvals with no open srq |
| `approval.pending` | `session_id`, `profile?` (`prompt_voice.py:293-301`) | `{"approvals":[{request_id, command, description, pattern_key, pattern_keys, allow_permanent, allow_session, smart_denied, choices, tool_name}]}` (`HA:tui_gateway/contracts/common.py:198-211`) | 30 s |
| `session.events.since` (probe) | `session_id`, `last_seen`, `profile?` | §2.4 | 10 s |
| `GET /api/config[?profile=<p>]` (REST) | — | the profile's config; read only `approvals.timeout` (`HA:hermes_cli/web_routers/config_env.py:80-90`) | absent or non-positive → 300 (web `W:src/approval-expiry.ts:48,56-66`) |

Sequences:
```json
→ {"jsonrpc":"2.0","id":41,"method":"clarify.lock","params":{"request_id":"srq-77aa01bb22cc","question_id":"q0","answer":"main","profile":"deploys"}}
← {"jsonrpc":"2.0","id":41,"result":{"status":"ok","remaining":["q1","q2"]}}
→ {"jsonrpc":"2.0","id":42,"method":"clarify.lock","params":{"request_id":"srq-77aa01bb22cc","question_id":"q1","answer":"[\"Lint\",\"skip the changelog\"]","profile":"deploys"}}
← {"jsonrpc":"2.0","id":42,"result":{"status":"ok","remaining":["q2"]}}
→ {"jsonrpc":"2.0","id":43,"method":"clarify.lock","params":{"request_id":"srq-77aa01bb22cc","question_id":"q2","answer":null,"profile":"deploys"}}
← {"jsonrpc":"2.0","id":43,"result":{"status":"ok","remaining":[]}}
```
Multi-select answers are a JSON array **string** of bare choices plus the typed text (web `stagedAnswer`,
`W:src/phone-question-dock.tsx:40-48`). Hermes strips the label and the JSON (`HA:tools/clarify_tool.py:36-47`).

### 2.7 Multi-client rules (who sees what)

- **Answerable** = at least one live WebSocket client attached to the session advertised, **or** no client is
  attached at all, in which case the request waits for a resume (`HA:tui_gateway/session_transports.py:38-47`).
  Otherwise Hermes never writes the frame and settles at once as unanswered (`server_requests.py:149-154,184-185,218-220`).
- Every attached client gets the frame. **The first answer wins** for everyone. Any `error` other than `4404` counts
  as "unanswered" (`server_requests.py:265-305`), so **never** send `-32601`/`-32603` for a method HQ Native shows: it
  would settle the question before the desktop could answer it.
- A desktop window (also advertising) may answer first. HQ Native then gets **no event**: no `request.cancel`, no
  frame (§2.5). The phone has to notice by itself (§3.5).
- HQ Native answering first: the desktop's card is the desktop's problem. Nothing to do here.

### 2.8 Hermes-side deadlines and what the agent gets

| Method | Deadline | On timeout | Withdrawn (Stop / close) |
| --- | --- | --- | --- |
| `approval` | `approvals.timeout` (300 s default; `HA:tools/approval_context.py:256-271`) | deny "timed out without user response… Silence is not consent." + `request.cancel(timeout)` (`HA:tools/approval.py:861-863`) | deny "withdrawn before the user answered" (`approval.py:855-860`) |
| `clarify` | clarify timeout (3,600 s default) | `{"answers": <locked>, "outcome":"timed_out"}` + `request.cancel(timeout)` (`server_requests.py:205-210`) | outcome `cancelled` (`:336-339`) |
| value prompts | 120 / 300 / 180 s (§2.2) | `""` + `request.cancel(timeout)` | `""` |

Hermes also keeps a detached running turn alive only while its activity clock is under 600 s stale
(`HA:tui_gateway/session_lifecycle.py:851-875`, `HA:tui_gateway/server.py:152-154`). The approval wait stamps activity
every ~10 s (`HA:tools/approval_gateway_wait.py:46-70`). Whether a long clarify wait does is **UNKNOWN** (§9 R4).

---

## 3. Client architecture

### 3.1 Net layer (`HermesKit/Net`)

1. **RPCFrame** (`NAT:HermesKit/Net/RPCFrame.swift`): add outgoing builders
   `response(id: String, result: JSONValue) -> String` (`{"jsonrpc":"2.0","id":…,"result":…}`) and
   `errorResponse(id: String, code: Int, message: String) -> String`. Neither has a `method` key.
2. **GatewayConnection** (`NAT:HermesKit/Net/GatewayConnection.swift`):
   - `ready()`: send `client.capabilities` first (§2.1). Keep `declinesNotShown` per epoch (reset in `closeSocket`).
   - `handle(.serverRequest)` (`:491-495`): yield
     `GatewayEvent(type: LocalEvent.serverRequest, sessionId: params.session_id ?? "", seq: nil, payload: {"id","method","params","replayed":false,"epoch":socketEpoch})`.
     Replace the D1 comment.
   - `settle`: the `open_requests` interception (§2.4). `Pending` gains the call's `method`, which it already has, and
     its params' `session_id`.
   - New `respond(serverRequest id: String, result: JSONValue) async throws` and
     `fail(serverRequest id: String, code: Int, message: String) async throws`. Each sends on the **current** socket
     when `socketReady`, else throws `RPCError.notSent(.socketDead)` (`isNotConnected`). They resume after the send
     completion handler: an error throws `isConnectionLost`.
   - `LocalEvent` (`:937-946`): rewrite `serverRequest`'s doc and add `openRequests = "hq.open_requests"`.
3. **GatewayClient** (`NAT:HermesKit/Contracts.swift:116-160`, integration-owned) gains:
   ```swift
   /// Answer a server→client request on the current socket (spec 1x §2.3). Throws `isNotConnected` when no socket is
   /// up, `isConnectionLost` when the send failed.
   func respond(serverRequest id: String, result: JSONValue) async throws
   func fail(serverRequest id: String, code: Int, message: String) async throws
   /// The current socket's `client.capabilities` answer said `declines_not_shown` (spec 1x §2.1).
   var declinesNotShown: Bool { get }
   ```
   Default extensions for fakes: `respond`/`fail` do nothing, `declinesNotShown` is `false`. `LiveGatewayClient`
   forwards to the connection.

### 3.2 `ServerRequestCenter` (new, `HermesKit/Chat/ServerRequests.swift`, main actor, one per account)

`AppModel.activate` creates it with the client and tears it down on sign-out
(`NAT:App/AppModel.swift`). It subscribes to `client.events()` and owns every entry. Chats and stores read from it.

```swift
enum PromptKind: String { case approval, clarify, sudo, secret, vaultUnlock = "vault.unlock_prompt",
                          vaultSaveLogin = "vault.save_login", vaultCode = "vault.code" }
struct PromptEntry: Identifiable {
    let id: String              // srq id; a queue-only approval uses "queue:<request_id>"
    var kind: PromptKind
    var sessionId: String       // runtime id the request names
    var params: JSONValue       // latest params (a replay may add clarify `answers`)
    var srqOpen: Bool           // false for a queue-only approval (answer via approval.respond)
    var queueRequestId: String? // approval only
    var deliveredSeq: Int       // monotonic counter at delivery: pruning compares against it (§3.3)
    var epoch: Int              // socket epoch it was (re)delivered on
    var firstSeen: Date         // approval clock (kept across re-deliveries, by clock key)
    var state: State            // .open, .answering, .expiredLocally
}
```
Per-session derived view (`ChatPrompts`, §3.6): approvals (oldest first, plus the stack total), one clarify, value
prompts (oldest first), the sent-answers note, and the undelivered flag. Plus maps:
- `runtimes: [runtimeId: (profile: String?, storedId: String?)]`, fed by every `LiveChatSession.bindRuntime`
  (`NAT:HermesKit/Chat/LiveChatSession.swift:544-550`); capped at 256, least recently bound first, never a runtime a
  chat covers now or one with an open entry.
- `clarifyDrafts: [requestId: (page: Int, stages: [qid: Stage])]` (web `drafts`, `phone-question-dock.tsx:92`).
- `approvalSeen: [clockKey: Date]`, capped at 64 (web `approvalSeenAt`, `W:src/approval-expiry.ts:8-16`). The clock
  key is the queue `request_id`, else `rpc:<srq id>` (`:21`).
- `recentlyAnswered` (§2.3) and `stackSize: [session: Int]`, which grows by one per new approval and resets when the
  session's queue empties (web `$approvalStackSizes`, `V:desktop/src/store/prompts.ts:148-203`).

### 3.3 State rules

1. **Delivery** (`hq.server_request`):
   - An id in `recentlyAnswered` → ignore.
   - A method in the window-owned five → `4404` if `declinesNotShown`, else nothing.
   - `setup_choose`, `display.install.sudo`, unknown → `-32601`.
   - The named session's chat has `turn.interrupted` **and** its stopped turn is still unwinding
     (`turn.stopTerminalPending`) → §2.3 row "already Stopped". Once the terminal frame came, a later turn's requests
     (another client, cron, a chained goal) show normally.
   - Otherwise upsert by id. An existing id keeps its UI state (draft, sheet, tuck) and takes the new params and
     epoch. A replay is quiet: no haptic, no sheet re-presentation if it is tucked.
   - Approval with a queue `request_id` that matches an existing queue-only entry → replace that entry with the
     srq-backed one (the web never lets a restored copy clobber a live one, `prompts.ts:238-250`).
2. **Authoritative set** (`hq.open_requests` for session S, from resume/activate/events.since):
   - drop every srq-backed entry of S that is not in `ids` **and** was delivered before this event (by `deliveredSeq`:
     events reach the centre in socket order, so a request that arrives after the answer is never pruned by it);
   - if `pending_approval` is present and no entry has its `request_id`, add a queue-only approval;
   - for resume/activate with no `pending_approval`, drop S's queue-only approvals.
3. **`approval.pending` replay** (web `prompts.ts:272-338`, triggers `V:desktop/src/lib/gateway-events.ts:104-123`,
   `V:desktop/src/app/session/hooks/use-session-actions/index.ts:452`). Run it for S:
   - on `gateway.ready`, for the chat on screen;
   - on `session.info` for S;
   - after answering one of S's approvals;
   - when the chat opens.

   Drop approval entries whose queue `request_id` isn't listed. Add listed ones that are missing, as queue-only.
   Discard the answer if S's approvals changed while it was in flight (the web's revision check).
4. **`request.cancel {id}`**: remove that entry, whatever its session (the web matches by id,
   `V:desktop/src/app/session/hooks/use-message-stream/gateway-event/input-requests.ts:99-187`). Dismiss its sheet
   without a chip, drop its draft, and clear a tucked chip.
   - Approval with `reason == "timeout"`: add the local system notice (§4.2 "timed out").
   - Clarify: its transcript note goes, and the tool row waits for `tool.complete`'s settled card.
5. **`approval.cancelled`**: remove approvals whose queue `request_id` is in `request_ids`.
6. **Turn end** for S (web `message-stream.ts:331-341`, `status.ts:308-316`), on `message.complete`, `error`, and
   `session.info {running:false}` when the chat knew the turn was live:
   - drop S's **queue-only** approvals and run `approval.pending` for S (rule 3);
   - **keep** every srq-backed entry (approval, clarify, value prompt) and confirm it with a probe (§3.5): rule 2 prunes
     from Hermes' authoritative `open_requests`. DECISION (review fix, differs from the web): the connection's replay
     yields the re-delivered requests first and the missed ring after them, so an older turn's `message.complete`
     would drop a newer turn's request; and Hermes emits `error` frames that end nothing (another client's refused
     submit `prompt_turn.py:133`, `model_switch.py:495`, `compute_host_bridge.py:354`). A finished turn has no open
     srq unless its `request.cancel` was missed, so the probe costs one round trip. A reconnect can also replay a
     pre-clarify `running:false` while the bridge is still parked (#83319, web `status.ts:310-315`).
7. **Socket change.** On `gateway.ready` with a new epoch, older-epoch entries stay on screen (no flicker). They are
   confirmed or pruned by rule 2 when the chat's `session.activate`/`resume` or the connection's replay answers. Any
   that neither path names within **15 s** of ready are dropped: no attached chat covers them, and they come back on
   that chat's next resume.
8. **Runtime rotation.** When a chat binds a new runtime id for the same stored id, drop entries under the old runtime
   id. Hermes keys open requests by the runtime that raised them (`server_requests.py:349-353`).
9. **Sign-out / account switch**: drop everything, including drafts and kept sheets. Kept sheets live in the account's
   `PromptSheetStore` (App, beside the centre); the centre's `onRemoved` drops a sheet and clears its text whenever
   its request goes, and a chat screen that closes only tucks the sheet it shows.

### 3.4 Answer paths (what each button does)

| UI action | Wire | After |
| --- | --- | --- |
| Approval Run / Allow for This Chat / Always Allow (confirmed) / Reject | srq open → `respond(id, {"choice":…})`; queue-only → `approval.respond {session_id, profile?, choice, all:false, request_id}` | remove the entry, then run `approval.pending` for S (web `approval.tsx:169-188`) |
| Approval Dismiss (expired card) | the same `deny` answer, best effort, errors ignored. The card goes at once (web `W:build/fe-convo-gates.ts:481`) | — |
| Dock Send | `clarify.lock` per question **in order**, the null ones too. The last lock resolves the wait, so every earlier one must already be in (`phone-question-dock.tsx:185-191`) | remove the entry, keep the sent rows (§4.4), drop the draft. `expired` on any lock counts as done (web parity) |
| Dock Skip | `respond(id, {})` | sent rows all "Skipped" |
| Sheet primary | `respond(id, {"value": …})` | dismiss the sheet, clear its text |
| Sheet decline (red) | `respond(id, {"value": ""})` | the same |
| Sheet ✕ / swipe down / tap outside | **nothing on the wire**: tuck (§4.5) | the chip shows |

Failures: a dock lock that throws an RPC error → toast "Could not send clarify response". The dock stays with its
answers, and Send is enabled again (`phone-question-dock.tsx:195-198`).

### 3.5 Noticing an answer given elsewhere (no event arrives, §2.5)

The **probe** (§2.4) runs for S, debounced 750 ms, at most one in flight per session, when an srq-backed entry of S is
open and one of these happens:
- a `tool.complete`, `message.start` or `message.complete` for S arrives after the entry was delivered (the agent moved
  on);
- the chat comes on screen, or the app returns to the foreground with it open;
- the turn ends (rule 6).

Approvals also get `approval.pending` (§3.3 rule 3). Rule 2 prunes from the result. The card, dock or sheet then
leaves quietly, with no toast: the user answered it somewhere else.

**Undelivered question** (web `use-undelivered.ts:9-53`, copy `V:desktop/src/i18n/en.ts:5324-5325`): a live `clarify`
tool part is running and no clarify entry exists for S **4 s** after its `tool.start` → probe. Still none → the
transcript note reads "This question didn't reach the app, so it can't be answered here. Press Stop to end the turn,
then reply in chat."

**Shared questions on a gateway-hosted Hermes** (added 2026-11-08, tester report: "Asking" with no options). A gateway
whose `gateway.ready` says `session_authority: true` doesn't send a `clarify` srq for a turn whose viewer didn't
declare `clarify_batch`. It asks one question per `clarify.request` **event** {`prompt_id`, `execution_generation`,
`question`, `choices`, `multi_select`, `timeout_s`} and closes it with `clarify.settled {prompt_id}`
(`HA:gateway/session_pending_controls.py:40-51`). A resume snapshot lists the ones still open under `prompts`. Hermes
Desktop shows these as its normal question card (`HA:apps/desktop/src/api/client.ts` `deliverCanonicalPrompt`). HQ does
the same: the centre makes a one-question clarify entry with id = `prompt_id` (`Entry.prompt`, no srq). Send and Skip
call `clarify.respond {session_id, execution_generation, prompt_id, answer, profile?}`, where `""` is a skip. The entry
goes on `clarify.settled`, on `message.complete`, or when a resume's `prompts` no longer names it. A probe can't prune
it, because `session.events.since` carries no `prompts`. Approvals there still come from `approval.pending`.

### 3.6 Chat integration

- New optional protocol beside `ChatQueueing` (`NAT:HermesKit/Contracts.swift:253`), integration-owned:
  ```swift
  struct ChatPrompts: Equatable {
      var approvals: [ApprovalPrompt]; var approvalStackTotal: Int
      var clarify: ClarifyPrompt?; var sentClarify: SentClarify?; var clarifyUndelivered: Bool
      var values: [ValuePrompt]
  }
  protocol ChatPrompting: AnyObject {
      var prompts: ChatPrompts { get }
      var onPromptsChange: (() -> Void)? { get set }
      func answerApproval(_ id: String, _ choice: ApprovalChoice) async throws
      func dismissExpiredApproval(_ id: String)
      func approvalTimeout() async -> TimeInterval              // §4.2 expiry
      func clarifyDraft(_ requestId: String) -> ClarifyDraft?
      func saveClarifyDraft(_ requestId: String, _ draft: ClarifyDraft)
      func sendClarify(_ requestId: String, answers: [(qid: String, answer: String?)]) async throws
      func skipClarify(_ requestId: String) async throws
      func answerValue(_ requestId: String, _ value: String) async throws   // "" declines
  }
  ```
  `LiveChatSession` adopts it by filtering the centre to its runtime id, plus its retired runtime id while a resume is
  in flight. The fakes (`NAT:App/Chat/Debug/FakeChatSession.swift`) get a scripted version for previews and
  screenshots.
- Status (`LiveChatSession.computeStatus`, `NAT:HermesKit/Chat/LiveChatSession.swift:1073-1096`), after the link
  states and before `guard turn.busy`:
  - any approval or value prompt → "Waiting for your approval";
  - a clarify → "Waiting for your reply".

  `ChatStatusView.set` already paints "Waiting for your…" orange with no dots (`NAT:App/Chat/ChatChrome.swift:263-276`).
- The chat's watchdog already counts Hermes' `"waiting"` status as alive (`NAT:HermesKit/Chat/LiveChatSession+Sync.swift:750`;
  Hermes reports `waiting` while an srq is open, `HA:tui_gateway/server.py:3039-3053`). No change.
- Sending while a prompt is open: unchanged M1 behaviour. A send while busy queues locally (spec 04 §6.2 M1), which is
  what the web does when an approval, sudo or secret is pending (spec 04 `:796`).
- **Bots row** (spec 02 §6.5 rows 5–6): `Bot` (`NAT:HermesKit/Contracts.swift:163`) gains
  `var needsInput: NeedsInput?` (`enum NeedsInput { case approval, reply }`). The centre maps an entry's runtime id
  through `runtimes` to `(profile, storedId)`. If `storedId == bot.canonicalSessionId` it calls
  `BotStore.setNeedsInput(profile, kind)`, beside `setWorking` (`NAT:HermesKit/Store/BotStore.swift:318`). The row's
  second line is "Waiting for your approval" / "Waiting for your reply" in orange. It ranks above "Working…" and below
  link/waking (`W:src/ui-kit/bot-status.ts:41-50`). It never shows a command summary: the web rows pass none
  (`W:src/ui-bots/row-status.ts:24`).

---

## 4. UI

All text uses Dynamic Type with the caps in spec 06 §10. Every touch target is ≥ 44 pt. Wrapping rows get 12–14 pt of
vertical padding (`MEM:row-padding-feedback.md`). Glass only where spec 06 §8 allows it.

### 4.1 Header status and Bots rows

The words, tone and ranking are §3.6. The status capsule's space is always reserved (spec 06 §4.1), so the words
appearing moves nothing.

### 4.2 The approval card (a transcript row at the newest end)

Reference: `V:desktop/src/components/assistant-ui/tool/approval.tsx:238-423` + phone gates
`W:build/fe-convo-gates.ts:113-123,334-341,472-483,585-596` + `W:src/phone-fe-convo.css:185-187,357-362,427-437,534-536`
+ `W:src/approval-expiry.ts`. Picture: `W:artifacts/app-store-screenshots/iphone-6.9/03-approval.png`.

**Rows** (new `ChatRow` kinds, exact heights from the layout code like every other row, `NAT:docs/ARCHITECTURE.md`):

1. `approvalHeader`: "Approval needed", or "Approval expired" when every approval in the stack has expired
   (`fe-convo-gates.ts:592`). Subheadline, label-2, leading-aligned, 16 pt side inset, 8 pt above the card. Not
   tappable (§8).
2. `approval`: the card for `approvals[0]` (the oldest). It sits after the latest reply's rows, at the newest end of
   the inverted table.

**Card:**
- 16 pt side insets. Radius 14 (spec 06 `--ios-r-card`). Page-colour fill with a hairline border in
  `ChatPalette.separator`. Solid, **not glass** (spec 06 §8.5). Padding 10 top, 12 sides, 12 bottom.
- **Header line:** an SF Symbol `apple.terminal` at 14 pt, label-2. Then "Command", or "Command details" when it shows
  the description (below). Footnote, label-2. Trailing: the expiry label in Footnote, label-3, tabular digits. Before
  it, "1 / 2" when the stack total is > 1 (`approval.tsx:337-345`).
- **What shows:** `showsDescription = command.trim().isEmpty || command matches ^<[^>]+> \(` (a plugin rule's synthetic
  label, `approval.tsx:285-295`).
  - Not `showsDescription`: the **command**, monospaced Footnote (`UIFontMetrics(forTextStyle: .footnote)` scaling
    `UIFont.monospacedSystemFont`), label, wrapping at any character, at most 8 lines (Q8). Then "Show All" in tint,
    Footnote: it opens `ChatSheet.wrap` with a `ChatBlocksViewController` block "Command", copyable.
  - `showsDescription`: the **description** in the same block.
  - **Reason line** (only when the command shows and `description` isn't empty): the description, Footnote, label-2,
    4 pt below (`fe-convo-gates.ts:121`).
- **Expired line** (expired state only): "This request expired. Ask <bot> to try again." (the chat's bot, or in a room the member whose turn asked; else "the bot") Footnote, label-2
  (`W:src/fe-convo-r2.ts:71`).
- **Actions:** one trailing-aligned row, 12 pt above the card's bottom, 8 pt gaps. **Capsules (Q7)**, min height 44,
  14 pt horizontal padding, Subheadline semibold capped at 22:
  - **Reject**: plain, label-2 text, no fill. In the expired state it reads **"Dismiss"**
    (`W:src/approval-expiry.ts:47`).
  - **More…**: `ChatPalette.fill2` with label text and a chevron.down glyph. Shown when both "session" and "always" are
    allowed. It opens a `UIMenu` with "Allow for This Chat" and "Always Allow…", and **no Reject** on touch
    (`fe-convo-gates.ts:483`). When exactly one extra is allowed, that one is a direct capsule instead:
    "Allow for This Chat" or "Always Allow…" (`fe-convo-gates.ts:595`). Hidden when expired.
  - **Run**: tint fill, white text, no ↵ glyph (`fe-convo-gates.ts:123`). Hidden when expired (`phone-fe-convo.css:430`).
  - Which extras are allowed (`approval.tsx:279-284`): `choices = params.choices ?? (smart_denied ? ["once","deny"] : nil)`;
    `allowSession = choices?.contains("session") ?? true`; `allowAlways = choices?.contains("always") ?? (allow_permanent != false)`.
  - **Accessibility sizes** (AX1 and up): the buttons stack full width inside the card, **Run first**, then the extra,
    then Reject (`phone-fe-convo.css:534-536`).
- **Always Allow… confirm:** a `UIAlertController(.alert)`, title "Always Allow This Command?", message:
  `<Bot> won’t ask again before running commands that match “<description>” — in this chat or any other, from now on.`,
  then two newlines and the command (the web's wording: `V:desktop/src/i18n/en.ts:5305-5310`). Actions "Cancel" and
  "Always Allow" (`.destructive`) (`approval.tsx:391-420`).
- **While answering:** the tapped button shows a small spinner in place of its label. Every button is disabled
  (`approval.tsx:248-249,297-325`). On success the row leaves with a 200 ms fade. If the user is at the newest end, the
  table closes the gap in the same animation and nothing jumps. The next queued approval takes its place.
- **Expiry** (`W:src/approval-expiry.ts:4-144`):
  - Count from `approvalSeen[clockKey]`, the time the approval first reached the phone; a replay keeps that time.
  - Run the timeout through `approvalTimeout()`: `GET /api/config` of the chat's profile, cached 5 min per profile,
    300 when absent.
  - Label: "Expires within N min" when more than 90 s are left (`ceil(left/60)`). Otherwise "Expires within m:ss".
    More than 99 minutes left (a long `approvals.timeout`): "Expires within N h" (`ceil(left/3600)`), so the label
    fits the space measured for "Expires within 99 min".
    At ≤ 0 it reads "Expired".
  - When the count runs out on a timeout that was read before it was due, read the config again (fresh) and show
    "Expires within 0:00" until that read lands. Only then call it Expired.
  - **Update the label in place once a second.** Never reload or re-measure the row for a tick. Only the switch to the
    expired state reloads the row, because its height changes.
  - Expired: Run and More… hidden, the expired line shown, Reject → Dismiss.
- **Timed out** (`request.cancel` with reason `timeout`): the card goes. A local system notice (centred, no bubble,
  `MessageMeta.systemNotice`, never cached) is added at the newest end: "Approval timed out — the command was not run.
  Ask Hermes to try again." (Q10 drops the Settings clause of `en.ts:5296-5297`). Play no toast: the web's toast only
  carried the Settings action.
- **Jump button:** while an approval is open and the card's action row is not fully visible above the composer, the
  jump button scrolls so the action row's bottom sits **16 pt above the composer's top** (`W:src/fe-convo-r5.ts:11-42`,
  `phone-fe-convo.css:435-437`). Use the same glide as spec 06 §4.4.
- **Haptics** (`MEM:taptic-feedback-gaps.md`): Run, Allow for This Chat and Always Allow → `notification.success`.
  Reject and Dismiss are silent.
- **VoiceOver:** the card reads "Approval needed. Command: <command>. <reason>. Expires within 4 min". The buttons are
  separate elements. Only the first card is in the transcript, so the order needs nothing extra.

### 4.3 The question dock (clarify, phone)

Owner history: answering a bot's questions was "VERY finicky… jumps all over the place" (2026-10-07,
`MEM:phone-question-dock.md`). The fix: one page per question, in the message field's place. Then a grey band under
the card (`MEM:question-dock-shadow-band.md`), and "can that sit closer to the bottom now?". The result is a
sheet-style bottom. **The transcript must not move while paging, and the dock must not move with Next or Back.**

Reference: `W:src/phone-question-dock.tsx` (logic `:32-84`, layout `:141-321`), `W:src/phone-question-dock.css`,
gates `W:build/phone-question-dock-gates.ts`, normalisation `V:desktop/src/store/clarify.ts:29-102`.

**Normalisation** (`clarify.ts:52-102`):
- Keep questions with a non-blank `qid` and `question`, both trimmed.
- Choices: non-blank strings whose bare text is ≤ 8,000 characters. Bare = minus a trailing `(Recommended)`.
- No surviving choices → `choices: nil`, an open question.
- `multi_select` only counts alongside choices.
- Nothing usable → answer `{}` (§2.3).

**Placement:**
- When S has a clarify entry, the dock **replaces the composer** (the composer's draft is kept, hidden). It is pinned
  like the composer to `view.keyboardLayoutGuide` (`NAT:App/Chat/ChatViewController.swift:357-389`), with its own gaps:
  - keyboard **down**: the card's bottom **8 pt** above the screen's bottom edge (`question-dock-shadow-band.md`: card
    bottom 866 of 874 pt);
  - keyboard **up**: **4 pt** above the keys (`phone-question-dock.css:11`);
  - sides **8 pt** from the screen edges.
- The table's bottom inset follows the dock's top in the same animation (M1's `viewDidLayoutSubviews` path).
- The queue card (Q13) and the jump button sit above the dock.
- Swapping composer ↔ dock: a 200 ms cross-fade. Inset changes ride the same animation. A chat resting at its newest
  end stays there.
- **Max height:** the chat's height above the keyboard, minus the top bar and status line, minus 30 pt
  (`phone-question-dock.css:4-5`). Beyond that a page's choice list scrolls inside the dock.

**Card:**
- iOS look (Q12, 2026-10-30): a native Liquid Glass panel; inside it the step line, Skip and the page sit on a solid
  `secondarySystemGroupedBackground` card inset 8 pt (radius 18), and the foot (Back as a solid capsule, Next/Send)
  sits on the glass. The fill, hairline and shadow below are the Desktop Look's.
- Fill `secondarySystemGroupedBackground`: white in light, `#2C2C2E`-class elevated in dark (spec 06 §1.2 "Elevated
  cell").
- Top corners 26 pt. Bottom corners, keyboard down: concentric with the screen
  (`UICornerConfiguration.corners(topLeftRadius: .fixed(26), topRightRadius: .fixed(26), bottomLeftRadius: .containerConcentric(minimum: 26), bottomRightRadius: .containerConcentric(minimum: 26))`).
  Fallback `max(26, safeAreaBottom × 1.35)`. Keyboard up: 26 all round.
- Padding 6 top, 16 sides. Bottom 12 with the keyboard up; `max(12, safeAreaBottom − 8)` with it down, so Back and
  Next clear the home indicator (`phone-question-dock.css:12-15`).
- A hairline edge in separator colour, and a shadow cast **upward only**: offset (0, −8), radius 12, opacity 0.16,
  path inset by 10 pt. Nothing may spill below the card (`MEM:question-dock-shadow-band.md`: the downward shadow was
  cut into a grey band).

**Inside, top to bottom:**
- **Head** (44 pt): "Question 2 of 3", or "Question" for one, in Footnote semibold label-2. Trailing: **Skip** in tint,
  Body.
- **Pages:** every page is laid out in one container, and the container's height is the **shown** page's. Only the
  current page is visible and interactive; the others are hidden with `accessibilityElementsHidden`. Next and Back
  move the dock's top to the new page's height in one 0.32 s spring (no bounce; at once with Reduce Motion), and the
  transcript's inset rides the same animation; the dock's bottom never moves. (Owner 2026-10-30 replaced the web's
  tallest-page container, `phone-question-dock.tsx:224-226`: a short question sat over a band of empty card.)
  - The question: Headline, wraps at any character, newlines kept.
  - Multi-select: "Choose any that apply." in Footnote label-2, 4 pt below; the choices then sit 14 pt under it.
  - **Choices:** an inset list 14 pt below the question (owner 2026-10-30: at 8 pt the list crowded it). Radius 12, `ChatPalette.fill4`, at most 50 % of the screen's
    height, then it scrolls inside.
    - Rows are ≥ 48 pt with 12/14 padding and a 12 pt gap, Body text. Hairline separators start 50 pt from the left.
    - The mark: a 24 pt circle (single) or a radius-7 rounded square (multi) with a 1.5 pt label-3 border. Picked =
      tint fill with a white check at 14 pt, stroke 3.
    - A trailing `(Recommended)` is removed from the label. Instead, "Recommended" sits under the text in Footnote
      label-2. The sent answer is the bare choice (`clarify.ts:31-32`).
    - Tap → `selection` haptic. Single-select replaces the pick (and closes "Something else"). Multi toggles
      (`phone-question-dock.tsx:50-55`). No row is pre-highlighted (`fe-convo-gates.ts:113-114`).
    - The last row is **"Something else…"** in label-2. Tapping it turns the row into an inline field (placeholder
      "Something else") and focuses it in the same frame, so the keyboard rises once. Single-select drops the picked
      choice; multi keeps it (`:57-60`).
  - **Open question (no choices):** a field 14 pt below. `ChatPalette.fill4`, radius 12, 44–132 pt tall, padding 11/14,
    Body, placeholder "Type your answer…" (`en.ts:5318`), capitalisation `.sentences`. It grows with its text, then
    scrolls.
- **Foot** (16 pt above): Back with chevron.left in tint, Body, only from page 2 on. Trailing, the primary capsule:
  tint fill, white Headline, min 96×44, padding 22.
  - "**Next**" before the last page.
  - "**Send**" on the last page. It is disabled until at least one question has an answer. While sending it reads
    "**Sending…**".
  - Skip and Back are disabled while sending.
- **Return key:** `.next` on earlier pages, `.send` on the last. Return goes to the next page, or sends on the last
  page when an answer exists (`:209-215`). Moving from a field to a page that is only a field keeps the keyboard up:
  focus the new field in the same layout pass (`:160-177`).
- **Draft:** page and picks are saved to the centre on every change, by request id. They survive leaving and reopening
  the chat (`:92,159`). A reconnect replay's `answers` pre-fill picks the user hasn't touched
  (`replayStage`, `:62-75`; local picks win, `:148-155`).
- **What each page sends** (`stagedAnswer`, `:40-48`):
  - multi: a JSON array string of bare picks plus the trimmed text, or `null` when empty;
  - single: the bare pick, else the trimmed text, else `null`;
  - open: the trimmed text or `null`.
- **Haptics:** choice taps → `selection`. Send and Skip are silent (`MEM:taptic-feedback-gaps.md`).
- **VoiceOver:** the dock is a container labelled "Questions, 2 of 3" or "Question" (`:217`). Choices are buttons with
  the selected trait, and the multi ones add the hint "Choose any that apply.".
- Phone layout only. iPad comes later and keeps the web's card (§8).

### 4.4 The clarify row in the transcript

It renders in place of the newest **running** `clarify` tool part of S, or as a standalone row at the newest end when
the live turn has none (for example after a reopen). Today that part is a generic standalone tool row
(`NAT:App/Chat/ChatRow.swift:391-399`, `ToolPresentation.cardTools`). There are three states (web
`usePhoneQuestionNote`, `phone-question-dock.tsx:339-380`; settled card
`V:desktop/src/components/assistant-ui/clarify/settled.tsx:14-54`, parser `…/clarify/parse.ts:47-80`):

Every state is one card (owner 2026-10-30: the grey answers box "looks half-assed"): the approval card's shell,
`ChatPalette.page` fill, a hairline edge in separator colour, radius 14, padding 12/14, 6 pt above and below. It
starts with a **header line**: a glyph (15–24 pt, label-2, semibold) and 6 pt after it the title in Footnote semibold
label-2, capped at 24 pt. The content starts 8 pt under it.

1. **Asked** (a clarify entry is open):
   - header `questionmark.bubble`, "A question for you" or "N questions for you";
   - the first question in Subheadline label, at most 2 lines.
   - Undelivered (§3.5): header `exclamationmark.bubble`, "A question for you", the not-delivered text in Subheadline
     label-2, every line.
2. **Sent** (after Send or Skip, until `tool.complete` for that part):
   - header `checkmark.bubble`, "Your answer" / "Your answers"; when no question got an answer, `minus.circle`,
     "Question skipped" / "N questions skipped";
   - each question in Subheadline label-2, then 6 pt under it the answer in Body semibold label, 8 pt after the dock's
     picked mark (`checkmark.circle.fill`: tint disc, white check; 18–28 pt, centred on the answer's first line).
     Multi-select answers are joined with ", ".
   - A blank answer reads "Skipped" (sent `""`, or Skip) or "No answer" (`null`), italic Body, label-3, beside a
     label-3 `minus.circle` (`en.ts:5320-5321`).
   - A hairline between questions, inset 14 on both sides, 12 pt above and below.
   - VoiceOver reads the header, then "question: answer" for each.
   - Kept in the centre per session, keyed by request id, never cached.
3. **Settled** (`tool.complete` result, or history): the same card, from `result.responses[]`
   (`HA:tools/clarify_tool.py:95-108`):
   - `user_response`: a string, or an array joined with ", ";
   - blank + `status == "unanswered"` → "No answer"; any other blank → "Skipped";
   - no `responses` array → the generic tool row.

   Parse the result once, at fold or hydration, into a new `ToolDetail.clarifyResponses: [(question, answer, unanswered)]`
   (`NAT:HermesKit/Chat/ChatMeta.swift:8-22`). That keeps it out of the 8,192-character `detail` cap. History rows:
   the `tool` row's `content` is the same JSON text. Live: `tool.complete.payload.result` is the parsed object
   (`HA:tui_gateway/tool_progress.py:343-346`).

### 4.5 Password, secret and vault sheets

Owner history:
- "swiping away a bot's password request lost it for good" (2026-10-02) → the chip;
- "center the chip" (build 84);
- "tapped the X and saw no bubble" (build 85): **every** close tucks, and declining is its own red button
  (`MEM:password-request-chip.md`).

Bots sign in themselves through these vault prompts: "it should have just asked for my password and done it"
(`MEM:bot-owns-signin.md`). So these sheets are the phone's sign-in moment. They must be fast and AutoFill-friendly.

**Frame:** `ChatSheet.wrap` (`NAT:App/Chat/ChatSheets.swift:9-34`), the same frame as every other sheet (the owner
expects one sheet design, `MEM:chat-visibility-alignment.md`). That gives:
- a system sheet (glass on iOS 26) with `[.medium(), .large()]` detents and an opaque grouped page;
- the system **✕** at the leading edge;
- the **primary verb** at the trailing edge as `UIBarButtonItem(style: .prominent)` (tinted glass, spec 06 §8.2/§8.4),
  disabled until valid.

The body is a grouped form.

| Kind | Title | Text | Fields (all `autocorrectionType = .no`, `autocapitalizationType = .none`, `smartQuotesType = .no`) | Primary | Red decline |
| --- | --- | --- | --- | --- | --- |
| `sudo` | "Administrator Password" | "Review the command before entering your sudo password. Your password is sent to <bot> to run it and kept for this session." Then the **Command** block (monospaced Footnote, copyable, ≤ 8 lines + Show All), or, with no command, "<Bot> didn’t say which command. Choose Don’t Send if you can’t check it in the conversation." in Footnote label-2 (`en.ts:5476-5480`; wording gate `W:build/prompt-tuck-gates.ts:31`) | secure field, placeholder "sudo password", `textContentType = .password` | "Send" (Q9: disabled while empty) | "Don’t Send" |
| `secret` | "<Bot> Needs a Key" | `prompt`, else "<Bot> needs a key to continue."; `env_var` shown as a monospaced line under the text | secure field, placeholder `env_var` or "secret value", `textContentType = .password` | "Send" (needs text) | "Don’t Send" |
| `vault.unlock_prompt` | "Unlock <display_name or backend, else Password Manager>" | "<Bot> wants to sign into a site with a login saved in <name>. Enter your master password to unlock it for this session — it goes straight to <name> on this machine and is never stored or shown to <bot>." | secure field "Master password", `textContentType = .password` | "Unlock" (needs text) | "Keep Locked" |
| `vault.save_login` | "Save Your <site or origin, else Site> Login?" | "<Bot> reached a sign-in page at <origin> and has no login for it. Enter it once here; it is encrypted on this machine and filled into the page without <bot> ever seeing the password." (footnote dropped, Q10) | "Email or username" (`.username`, placeholder "you@example.com", `.emailAddress` keyboard) and "Password" (secure, `.password`) | "Save and Sign In" (identifier trimmed non-empty **and** a password) | "Don’t Save" |
| `vault.code` | "Verification Code for <site, else This Site>" | "<site> is asking for a one-time code (text message, email or authenticator app). Enter it here and it’s typed into the page; <bot> never sees it." (tip dropped, Q10) | visible field "Code", placeholder "123 456", `textContentType = .oneTimeCode` (iOS offers SMS and email codes), `.numberPad`; spaces and dashes are stripped before sending | "Enter Code" (needs text) | "Skip" |

<Bot> is the chat's bot ("the bot" / "The bot" / "Your Bot" when it has no name). The web's copy is
`V:desktop/src/i18n/en.ts:5470-5511`. Field and validity rules are `prompt-overlays.tsx:52-579`.
- The first field takes focus when the sheet appears. Return moves to the next field, and on the last field sends when
  the sheet is valid.
- The red decline is a plain button **under the fields**: Body, `ChatPalette.red`, centred, min 44 pt
  (`W:src/prompt-tuck.css:4-6`). It sends `""`.
- Every send dismisses the sheet and **clears the field text**.
- Haptics: none (password prompts are deliberately silent, `MEM:taptic-feedback-gaps.md`).
- **Presentation (Q14):** when the chat is on screen and nothing else is presented, present the oldest untucked value
  prompt for S. Otherwise show its chip. Only one sheet at a time. When one is answered, the next untucked one
  presents after the dismissal ends.
- **Tuck** (`W:src/prompt-tuck.tsx:11-43`, `W:build/prompt-tuck-gates.ts:10-29`): the ✕, a swipe down
  (`presentationControllerDidDismiss`) and a tap outside the medium detent all **tuck**. Nothing is sent. The view
  controller is **kept** (by request id, in memory) so the typed text survives. Reopening re-presents the same
  instance.
- **The chip** (`prompt-tuck.tsx:59-89`, `prompt-tuck.css:1-3`, picture `W:artifacts/password-chip/chip-over-composer.png`):
  - a capsule of **untinted interactive `UIGlassEffect`**, centred horizontally, 8 pt above the composer (or the queue
    card), max width 256;
  - a `lock.fill` glyph at 12 pt, a 6 pt gap, then one truncating line in Subheadline label;
  - the label for the oldest tucked prompt of S: "Password requested" (sudo), "<ENV> requested" or "Secret requested",
    "Unlock <name>" or "Unlock password manager", "Save login for <site>?" or "Save login?", "Code for <site>
    requested" or "Code requested";
  - tap → re-present. VoiceOver label: "<label>. Opens the request.";
  - it lives exactly as long as its request (answered, cancelled, timed out or turn ended), and never covers the jump
    button.
- `request.cancel` while presented: dismiss without a chip, clear the text, no toast (web parity: the dialog simply
  unmounts).
- **Never** log, cache, persist, copy to the pasteboard, or include in diagnostics any value typed here. Secure fields
  keep their text out of app-switcher snapshots by default; don't defeat that.

### 4.6 Motion, accessibility

- Reduce Motion: the card fade and the dock cross-fade become instant. The jump scrolls without the glide.
- Dynamic Type: the dock list scrolls inside its max height. The card stacks its buttons at AX1+.
- Dark mode: system colours plus `ChatPalette`. Check every surface in both modes (owner habit, spec 06 §12).

### 4.7 Offline and error copy

| When | Copy (toast; entry kept) | Source |
| --- | --- | --- |
| Approval tapped with no socket | "Hermes is offline right now. The command is still waiting for your answer (until the approval timeout). Reconnect, then send it again." | `en.ts:5292-5293` |
| Approval answer failed | "Could not send your answer" | `en.ts:5294` |
| Dock Send/Skip with no socket | "Hermes is offline right now. Reconnect, then send it again." | `en.ts:5314` |
| A dock lock failed | "Could not send clarify response" | `en.ts:5315` |
| Sheet primary or decline with no socket | "Hermes is offline right now. Reconnect, then send it again." | `en.ts:5471` |
| Sheet send failed | sudo "Could not send sudo password"; secret "Could not send secret"; unlock "Could not send master password"; save "Could not save the login"; code "Could not send the code" | `en.ts:5473-5503` |

Use M1's existing toast surface. The web's "Reconnect" action maps to `client.reconnectNow()`.

---

## 5. Owner-approved behaviour (from memory) to preserve

- **Dock:** one page per question in the composer's place; 48 pt rows; circle vs rounded-square marks; "Something
  else…" opens an inline field; Return = Next/Send; Next from a field to a text page keeps the keyboard; the transcript
  shows a one-line note, then the sent answers, then the settled card (`MEM:phone-question-dock.md`, shipped 208).
- **Dock bottom:** shadow only upward; the card sits 8 pt from the screen bottom with screen-following corners when the
  keyboard is down (`MEM:question-dock-shadow-band.md`, shipped 216).
- **Password sheets:** every close tucks into a centred chip; a red decline button under the fields; the typed text is
  kept (`MEM:password-request-chip.md`, public 84/85).
- **Vault prompts are how bots sign in.** Make them quick, with AutoFill (`MEM:bot-owns-signin.md`; the QuickType
  "Passwords" bar was verified in the web build, `MEM:browser-copy-paste-autofill.md`).
- **Haptics:** approval allow → success; password prompts silent (`MEM:taptic-feedback-gaps.md`).
- **Glass:** native only, never imitation; chip and sheet chrome glass, panels of text solid (`MEM:liquid-glass.md`,
  spec 06 §8).
- **The plain approval card, not the trail restyle:** `PHONE_TRAIL_APPROVAL` is off in Release
  (`MEM:chat-refinement-shapes.md`; spec 03 `:1374`).

---

## 6. Fixtures (ports 9720–9722 only)

### 6.1 What exists, and what is missing

- The memory's ask fixture `.build/ask-gateway.py` (`MEM:phone-question-dock.md`) is **gone**. Its worktree
  `setup-flow-new-users-881351` was removed. A search of `~/Projects` to depth 6, `mdfind`, and every
  `hermes-ios-release2*` worktree found no copy.
- No committed REF fixture sends server→client requests. The build47 family drops every client frame without a
  `method`, so it can't receive answers (`W:scripts/build47-fixture-gateway.py:162`). It answers unknown RPCs `{}`
  (spec 05 §A3).
- `test-stage3-prompts.py` / `features-r2-fixtures.py` inject frames into the **web** shell with an old one-question
  clarify shape. They don't apply to native.
- `PLAID` has one real srq (`vault.save_login`): a wait, a timeout that emits `request.cancel`, `open_requests` on
  `events.since`, session-bound fan-out, and `/__plaid/kick` (`PLAID/plaid_gateway.py:9-13,132-169,251-270,422-436`).
  It is good for reconnect and vault soak, not for the full matrix.

**So the builder writes one fixture**: `NAT:scripts/fixtures/questions-gateway.py`, stdlib only, loopback only, built
on the REF performance fixture the same way that fixture builds on build47
(`W:scripts/performance-fixture-gateway.py:13-16`):
```python
REF = pathlib.Path(os.environ.get('HQN_REF', '/Users/me/Projects/hermes-hq-native-ref238'))
spec = importlib.util.spec_from_file_location('perf', REF / 'scripts/performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(spec); spec.loader.exec_module(perf)
base = perf.base; voice = base.voice     # build47 module / action-voice module
```
It replaces `voice.auth.websocket` with a copy of build47's loop (`build47-fixture-gateway.py:131-171`) that adds:

1. **Response routing.** A frame with `id`, no `method` and `result`/`error` is routed to `OPEN[id]` with Hermes'
   semantics (§2.3, §2.7):
   - a result answers; the first one wins and later ones are recorded as `dropped`;
   - `4404` is a decline, and settles with the NOT_SHOWN value once every advertised client has declined;
   - any other error = unanswered.
2. **`client.capabilities`:** per-socket `advertised`. The result is §2.1's. `/__fixture/config` can set
   `declines_not_shown:false` or answer `-32601` to mimic old backends.
3. **Answerability:** a request is "unanswerable" when ≥ 1 socket is connected and none has advertised. It then
   settles unanswered at once, never written, ledger outcome `unanswerable`. With no socket connected it waits, as
   Hermes does.
4. **Strict params (`4000`, Hermes' message format)** for exactly the methods this stream sends: `client.capabilities`
   {`server_requests`}, `clarify.lock` {`request_id`,`question_id`,`answer`,`profile`}, `approval.respond`
   {`session_id`,`profile`,`choice`,`all`,`request_id`}, `approval.pending` {`session_id`,`profile`},
   `approval.received` {`session_id`,`profile`,`request_id`}, `session.events.since`
   {`session_id`,`profile`,`last_seen`}, `request.answer` {`id`,`result`,`profile`}.
5. **Hermes behaviours:**
   - `clarify.lock` (ok/remaining/expired/4002);
   - `approval.respond`/`approval.pending` over a queue keyed by `request_id` (32 hex). Answering through
     `approval.respond` while the srq is open emits `request.cancel{reason:"resolved"}`; answering the srq emits
     nothing (§2.5);
   - `session.resume`/`activate` add `open_requests` and `pending_approval` when non-empty, and `events.since` always
     adds `open_requests` (§2.4);
   - `session.active_list` reports `status:"waiting"` while one is open;
   - `session.interrupt` cancels the profile's open requests (`request.cancel{reason:"interrupted"}`), broadcasts
     `approval.cancelled`, then does build47's stop;
   - timeouts emit `request.cancel{reason:"timeout"}`;
   - `/api/config` returns `{"approvals":{"timeout":N}}` when set.
6. **Turns that ask.** A `prompt.submit` whose text contains a keyword starts a running turn: `message.start`, a
   `tool.start`, then the request. Once it settles, `tool.complete` with a Hermes-shaped result, a short streamed reply,
   `message.complete`. The assistant `tool_calls` row and the `tool` row are persisted into `base.MESSAGES` so history
   reloads show the settled card. Keywords (a superset of the old ask fixture's `ask/one/text/long/approve`):

   | Keyword | Request |
   | --- | --- |
   | `approve` | `approval` for `git push --force origin main` (pattern above, all four choices) |
   | `approve-once` | `smart_denied` approval (choices `once,deny`) |
   | `approve-rule` | plugin-rule approval (command `<browser_exec> (plugin approval rule)`, real text in the description) |
   | `ask` | `clarify` with 3 questions: single with `(Recommended)`, multi of 3, open |
   | `one` | 1 single-select |
   | `text` | 1 open question |
   | `long` | 5 questions, 4 choices each, multi-line choices of ~600 characters |
   | `sudo` | `sudo` with command `apt-get install -y ffmpeg` |
   | `sudo-blank` | `sudo` with `command:""` |
   | `secret` | `secret` (`env_var:"OPENWEATHER_API_KEY"`, `prompt:"Paste your OpenWeather API key"`) |
   | `unlock` | `vault.unlock_prompt` (`backend:"bitwarden"`, `display_name:"Bitwarden"`) |
   | `login` | `vault.save_login` (`origin:"https://shop.example.com"`, `site:"Example Shop"`) |
   | `code` | `vault.code` (`site:"Example Shop"`, `hint:"Text message to •••• 42"`) |
   | `setup` | `setup_choose` |
   | `terminal` | `terminal.read` |
   | `tour` | `tour` |
   | `two-approvals` | two approvals back to back |

   Never echo a value prompt's answer in the reply: say "Received N characters."
7. **Controls** (no auth, loopback):
   - `GET /__fixture/ask?kind=<keyword>[&profile=default]`: ask in the last prompted chat (the old fixture's recipe),
     starting a running turn if none is running.
   - `POST /__fixture/ask {profile, kind}` or `{profile, method, params, timeout}`.
   - `POST /__fixture/answer {id, result}`: "another client answered first". Settles silently with **no**
     `request.cancel`, like `resolve_response` from another transport.
   - `POST /__fixture/cancel {id, reason}`.
   - `POST /__fixture/kick`: close every `/api/ws` socket abruptly.
   - `POST /__fixture/config {approvals_timeout, declines_not_shown, capabilities: "ok"|"-32601"}`.
   - `GET /__fixture/requests`: the ledger. One entry per request: `{id, method, profile, delivered:[socket n],
     answers:[{socket, at, kind:"result"|"error", code?, result}], outcome, settled_by}`. Value-prompt results are
     **redacted** to `{"value":"<N chars>"}`. Every RPC this stream sends is logged with its params under `rpc`
     (base `voice.state['rpc']`), with `clarify.lock` answers kept and `value`s redacted.

Credentials: as build47 (`--credentials <file>` written 0600, user `build47-fixture`, random password, never printed;
`build47-fixture-gateway.py:208-216`).

### 6.2 Start and stop (only your own PIDs)

```sh
cd /Users/me/Projects/hermes-hq-native
mkdir -p build/fixtures && chmod 700 build/fixtures
lsof -nP -iTCP:9720 -sTCP:LISTEN && echo "9720 busy: stop" && exit 1
python3 scripts/fixtures/questions-gateway.py --port 9720 --credentials build/fixtures/questions.json \
  > build/fixtures/questions.log 2>&1 & echo $! > build/fixtures/questions.pid
curl -s http://127.0.0.1:9720/api/status        # {"version":"1.0.0",…}
curl -s 'http://127.0.0.1:9720/__fixture/ask?kind=approve'
curl -s http://127.0.0.1:9720/__fixture/requests | python3 -m json.tool
kill "$(cat build/fixtures/questions.pid)" && rm build/fixtures/questions.pid
```
- **9720:** the manual/simulator fixture, and the one the live unit suite looks for. `NetTestSupport` gains
  `questionsPort: UInt16 = 9720` and `questionsAvailable` (pattern `NAT:Tests/NetTestSupport.swift:6-35`).
- **9721:** the UI end-to-end run. Extend `scripts/e2e.sh` with `HQN_E2E_FIXTURE=questions`, which starts
  `scripts/fixtures/questions-gateway.py` instead of the performance fixture
  (`NAT:scripts/e2e.sh:12-31`): `HQN_E2E_FIXTURE=questions HQN_E2E_PORT=9721 scripts/e2e.sh <udid>`.
- **9722:** `PLAID` reconnect and vault soak (optional):
  ```sh
  cd /Users/me/Projects/hermes-ios/.claude/worktrees/plaid-stress-testing-5e35d8/.build/stability-round/tools/memory
  DEMO_FILES=<scratch>/plaid-files PLAID_HQ_LOG_DIR=<scratch>/plaid-hq-logs PLAID_SHORT=1 \
    python3 plaid_gateway.py --port 9722 --credentials /Users/me/Projects/hermes-hq-native/build/fixtures/plaid-9722.json &
  curl 'http://127.0.0.1:9722/__plaid/start?minutes=3&subagents=0&browser=0&vault=1&tools=1&vault_wait=90'
  curl http://127.0.0.1:9722/__plaid/kick        # mid-prompt: the sheet must survive and re-arm from open_requests
  ```
  Recipe from spec 05 §A9 (`NAT:docs/spec/05-fixtures-release.md:331-341`). Never use that folder's `creds.json`.
- Simulator: clone your own (`HQN-questions`). Never use the integration sim "HQ Native" or another stream's sim.
- **DEBUG hooks** (`NAT:App/Debug/DebugHooks.swift`): the existing `-HQDebugOpenBot default -HQDebugSend "please approve"`
  drives a prompt with no typing. Add `-HQDebugTuckPrompts YES` (open sheets start tucked, for chip screenshots).
- Never point anything at the owner's gateway (100.101.102.104, `*.ts.net`). Never retry sign-ins in a loop.

---

## 7. Acceptance checks (the builder must pass all)

### 7.1 Unit (Swift Testing, `scripts/build.sh test <udid>`)

1. `RPCFrame`: `response`/`errorResponse` produce exactly the §2.3 JSON, with no `method` key and the string id
   preserved. The srq parse round-trips every §2.2 example.
2. Handshake: `client.capabilities` is the first frame written after `gateway.ready`, on every epoch, with params
   exactly `{"server_requests":true}`. `declines_not_shown` is stored per epoch and reset on close. A fake transport
   proves the ordering.
3. Interception: a `session.activate` result with `open_requests` yields the `serverRequest` events (replayed) and then
   `openRequests`, all **before** the caller resumes. A missing key yields `ids: []`.
4. Centre rules §3.3: upsert keeps the draft; `recentlyAnswered` ignores a re-delivery; prune spares requests delivered
   after the snapshot; `request.cancel` by id across sessions; `approval.cancelled`; turn end keeps the clarify; the
   epoch-change 15 s drop; runtime rotation.
5. Answer table §2.3: every method → its exact frame; the window-owned five → `4404` only with `declinesNotShown`;
   `-32601` for `setup_choose`/`display.install.sudo`/unknown; an interrupted session → `-32603 "session interrupted"`
   / clarify `{}`; never a second frame for one id under concurrent taps.
6. Dock logic: `stagedAnswer`, `toggleStage`, `openOther`, `replayStage`, `sentRows`. Port the web's tests'
   expectations (`W:src/phone-question-dock.test.ts`). Locks are sent in question order, the nulls included.
7. Expiry: `approvalExpiryLabel` boundaries (91 s → "Expires within 2 min", 90 s → "Expires within 1:30", 0 →
   "Expired"); the stale-read rule; the clock survives a replay (`W:src/approval-expiry.test.ts`).
8. Settled clarify parse from a live `tool.complete` object and from a history `tool` row string, including
   `unanswered` vs skipped.

### 7.2 Live against the questions fixture on :9720 (skip when the port is closed)

9. Sign in, open Hermes, send "please approve" → the ledger shows the request delivered to our socket and the socket
   `advertised`. Answer Run → the ledger shows **one** answer `{"choice":"once"}`, then `approval.pending` with
   `{session_id[,profile]}` only.
10. "ask" → three `clarify.lock` calls in order, with no `session_id` in their params; outcome `submitted`; the reply
    streams; the transcript shows the settled card after reloading history.
11. `/__fixture/kick` with an open clarify that has one locked answer and a draft → after reconnect the dock is back
    with the same page and picks, and the ledger shows no second answer.
12. `/__fixture/answer` (another client) on an open approval → the card leaves within 2 s of the next `tool.complete`,
    or within one probe when the chat is reopened. No toast.
13. `POST /__fixture/config {"approvals_timeout":20}` → the card shows "Expires within 0:20". At timeout the fixture's
    `request.cancel` removes the card and adds the timed-out notice.
14. With the fixture's capabilities set to `-32601` and `declines_not_shown:false`: "terminal" gets **no** answer
    frame; with defaults it gets one `4404`. "setup" gets one `-32601`.
15. **No `4000` anywhere** in the fixture's ledger after the whole suite (strict params, §6.1 item 4).

### 7.3 UI end to end (`HQN_E2E_FIXTURE=questions HQN_E2E_PORT=9721 scripts/e2e.sh <udid>`)

16. Approval: Reject → `deny`; Run → `once`; More… → Allow for This Chat → `session`; Always Allow… → confirm →
    `always`. Each answered exactly once (ledger). The "Waiting for your approval" status shows while open and goes
    after.
17. Dock: "ask" → the dock replaces the composer. Next fits page 2 (taller, same bottom); the first visible row keeps
    its distance to the dock's top; Back returns to page 1's exact frame. "Something
    else…" opens a field and the keyboard rises once. Send → the sent rows, then the settled card. Skip → `{}` and
    "Skipped" rows.
18. Sudo: the sheet appears. Type `x`, swipe down → the chip "Password requested" is centred above the composer. Tap
    the chip → the sheet returns with the field still holding 1 character. "Don’t Send" → `{"value":""}`. A new sudo →
    Send → `{"value":"<1 chars>"}` in the redacted ledger.
19. Login: both fields carry `textContentType` username/password (XCUI element check). "Save and Sign In" stays
    disabled until both are filled. The answer is a JSON string with both keys.
20. `request.cancel` while a sheet is open (`/__fixture/cancel`) → the sheet dismisses with no chip.
21. Bots tab while an approval is open in Hermes' chat → the Hermes row reads "Waiting for your approval" in orange.
    "ask" → "Waiting for your reply".

### 7.4 Simulator look (screenshots light + dark + AX3; send them to the owner with before → now captions)

22. The approval card next to `W:artifacts/app-store-screenshots/iphone-6.9/03-approval.png`: same order of parts,
    capsule buttons, expiry at the trailing end.
23. Dock, keyboard down: the card's bottom is 8 pt above the screen bottom, its corners follow the screen, no band
    below. Keyboard up: 4 pt above the keys. A 5-question `long` set scrolls inside the dock, and Next is never off
    screen.
24. The chip next to `W:artifacts/password-chip/chip-over-composer.png`.
25. All existing M1 e2e tests still pass on the performance fixture (`scripts/e2e.sh`).
26. Read-only check on the owner's gateway: **not** in this stream (owner's real bots; §9 R1).

---

## 8. Left out this round, and why

| Left out | Why |
| --- | --- |
| Lock-screen and notification approvals, approve from a banner | Push is a later stream (`NAT:docs/parity.md:37`). It needs the relay and APNs topic work |
| In-app banner for a prompt in another chat (reply peek) | Later milestone (spec 06 §8.10). Bots row status covers it for now |
| `setup_choose` cards (onboarding) | The web has no handler either (Q4). Onboarding/setup is its own stream |
| `display.install.sudo` (Bot Screen packages) | Bot Screen / Watch Browser is a later batch. HQ Native never triggers it |
| Desktop pane bridges (terminal/preview/window/act/tour) | No panes on the phone (Q3) |
| `connection.request` / `manage_connections` / `manage_catalog` consent cards | They are events, not srqs. Hosted connectors are off on the phone (`MEM:composio-connectors.md`). Connectors are their own stream (spec 03 `:1120-1123`) |
| `request.answer`, `approval.received`, `all:true` | Q2, Q5. The phone never offers approve-all |
| Swipe-to-deny on the approval card | Q6 |
| "Approval needed" header opening the approval's tool rows (web r4-97 reveal) | Polish. The header is a plain caption this round |
| Countdown on sudo/secret/vault sheets, and on questions | The web shows none |
| Settings links in copy | Q10. No Settings screen yet |
| iPad / desktop-style clarify card, group rooms | iPad and rooms are later batches. The dock is phone-only on the web too (`phone-question-dock.tsx:94-96`) |
| Sessions-list rows showing "Waiting…" | The spec 02 ranking is for Bots rows. The Sessions list is basic in M1 |

---

## 9. Risks and UNKNOWNs

- **R1. Behaviour change on real gateways.** Once HQ Native advertises, a bot whose only attached client is the phone
  **waits** for it, instead of failing fast:
  - approvals up to `approvals.timeout`;
  - questions up to an hour (3,600 s default);
  - sudo/vault up to 2–3 min.

  A half-built UI would stall real bots. Ship the handshake only together with every surface in §4. Keep a DEBUG/env
  kill switch `HQNNoServerRequests` that skips the handshake (M1 behaviour) for diagnosis.
- **R2. Silent answers elsewhere.** No event is emitted when the desktop answers first (§2.5). Pruning depends on the
  probe triggers in §3.5. A stale card could linger until the next tool event. Check 12 guards it.
- **R3. Re-delivery races.** A resume answer built before our response may re-list an id we already answered.
  `recentlyAnswered` is the guard. Check 11 and unit check 4.
- **R4. Long questions on a closed phone (UNKNOWN).** A detached running turn is interrupted once its activity clock
  is 600 s stale (`HA:tui_gateway/session_lifecycle.py:851-875`). The approval wait stamps activity
  (`HA:tools/approval_gateway_wait.py:46-70`). It is not established that the clarify wait
  (`server_requests.send` → `event.wait`) does. If not, a question left > 10 min with the phone as the only, now
  closed, client may end in `cancelled`. Hermes code is not ours (`MEM:hermes-code-not-ours.md`). Document it; don't
  patch.
- **R5. The ask fixture was lost.** The new fixture reproduces Hermes semantics from source. Where it and real Hermes
  differ, Hermes wins: re-check the ledger shapes against §2 before trusting a green run.
- **R6. Password handling.** Kept view controllers hold typed secrets in memory while tucked. Clear them on answer,
  cancel, sign-out and when the app is terminated. No logging (`os_log` privacy), no transcript, no cache, no
  diagnostics.
- **R7. `approval.respond` on an older gateway** has no request-id fallback. The queue-only path then answers the
  oldest approval. It's rare: the srq path is the norm on every v7+ gateway.
