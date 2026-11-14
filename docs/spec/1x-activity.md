# 1x — Activity: subagents, goal and task chips, tool-call styles, reasoning

Stream "activity" of the parity round after milestone 1 (`N:docs/parity.md` "Subagents / goal chips", "Settings (…
tool-call styles …)"). This spec says what the native app must do so a turn's *activity* reads the way the owner
approved in the web app: the subagents shelf and card, the goal and task chips above the composer, the "Working…"
details, reasoning rows, the three Tool Call Styles and Hide-after-reply, the card tools drawn in place in the
transcript, the complete step sheet, and the small Tool Calls settings screen that holds the two tool-call
settings.

**Citation roots** (every `file:line` is relative to one of these):

| Prefix | Path |
|---|---|
| `R:` | `/Users/me/Projects/hermes-hq-native-ref238` (web app, release-build238, read-only) |
| `V:` | `R:vendor/hermes/apps/desktop/src` (vendored Hermes desktop renderer the phone runs) |
| `B:` | `R:build` (build-time gates that rewrite `V:`) |
| `H:` | `/Users/me/.hermes/hermes-agent` (Hermes source, commit `d94b70f6`, READ ONLY) |
| `N:` | `/Users/me/Projects/hermes-hq-native` (this repo) |
| `M:` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory` (owner history) |

**Precedence** (same as specs 03–06): shipped web behaviour (build 238, gates applied) unless the owner's memory notes
say something newer; where native must differ it says **DECISION** and why. **UNKNOWN** marks what could not be
settled from source. Specs 03 (history, §8 tool calls), 04 (stream events, Stop) and 06 (look, glass, motion) still
apply; this file only adds to them and names the places it supersedes them (§17 item 10).

---

## 0. TL;DR and build order

1. **One app-level `ActivityStore`** (new, `N:HermesKit/Activity/`) listens to every gateway event once, keeps per-chat
   subagents, live and previous task lists, and the goal snapshot, and makes the few reads that keep them honest
   (`subagent.list`, `subagent.tail`, `session.control.read`, `delegation.status`). Chats and the bot rows read it (§3).
2. **The shelf above the composer** (§4–§7): folded **chips** on native Liquid Glass — "1 helper ›" (owner 2026-10-28: the chip and its card say "helper", never "subagent"), "Tasks 2/5 ›",
   "Goal active · Turn 3/20 ›", "Previous tasks 3/5 ›" — centred, 44 pt, 6 pt apart, floating over the transcript;
   tap one and it opens into a **glass card** inline (never a sheet: the owner rejected a glass sheet). The subagents
   card has Steer / Stop and the child's activity; the task card lists the plan; the goal card has the goal, its
   criteria and Pause / Resume / Clear.
3. **The transcript's card tools** (§11): `delegate_task` becomes the subagent card (one row per child, live ticker),
   `image_generate` a picture frame, file edits keep their step row but their sheet shows a coloured diff (`clarify`'s
   rows belong to the questions stream). Everything else stays the M1 quiet run row.
4. **Tool Call Style** (§10): Rows (default, M1), **Bubbles** (Hermes's Telegram progress lines in a bot bubble),
   **In Header** (no steps in the chat; the status line under the name says the step running now and opens a live
   Steps sheet). **After Reply: Keep / Hide** (steps fold away when the reply is done; a failed step stays; long-press a
   reply → Show Steps). Never animate a row's height; fold = fade, one removal, slide.
5. **Reasoning** (§9): "Thinking" while live, then "Thought for 7s" / "Thought briefly" / "Thought" (history), tap to
   read; hidden when the gateway's `display.show_reasoning` is off and in In Header.
6. **Working… details** (§8): provider-wait words in the waiting capsule, the fallback-model notice line, the bot row
   says Working… while a chat's subagents run (and stops saying it when they end, even if the phone missed the end).
7. **Tool Calls settings** (§13): Tool Call Style (Rows / Bubbles / In Header) and Tool Calls After Reply (Keep /
   Hide), device-local, on a small screen the Settings stream links as Chat › Tool Calls.
8. **Fixtures** (§15): a tracked wrapper `N:scripts/fixtures/activity-gateway.py` around the reference performance
   fixture (scripted turn events, Hermes-strict params, roster, goal, tails), on **9732**; the Plaid gateway on **9733**
   for a realistic busy turn; the demo gateway on **9734** for rich history. Acceptance checks in §16.

Suggested build order (each step shippable on its own): A `ActivityStore` + event rules + unit tests → B shelf with
subagent chip/card → C tasks + previous tasks → D goal → E reasoning timing + provider wait + fallback notice →
F Tool Calls screen + Bubbles → G Hide / Show Steps → H In Header + Steps sheet → I card tools → J step sheet
completeness. Ship after each owner-visible step (`M:finish-everything-push.md`).

---

## 1. What the owner approved, asked for and rejected (binding)

| Topic | Owner's words / decision | Source |
|---|---|---|
| Opened subagents card | "the opened subagent panel above the composer should be Liquid Glass in the iOS look". **Rejected** moving it into a glass sheet: "No i don't like that option" — keep it inline. | `M:subagent-card-glass.md:8` |
| Steer row | "needs to be designed better all around" → composer-style 44 pt capsule field, round ↑ send (tint once text, fill-3 empty), round red ■ Stop; placeholder "Message this subagent…". | `M:subagent-card-glass.md:14` |
| Text on glass | "text under the Steer row hard to read" → footnote size, label / label-2 colours (tertiary greys wash out on glass). | `M:subagent-card-glass.md:17` |
| Flashing / doubled text | the opened card flashed every second on a running subagent; nested scrollers made doubled, lagging text → **one scroller**, opened card up to 60 % of the screen (not with the keyboard), goal clamped to 3 lines. "Any live-updating or scrolling content inside a native-glass control must be checked on video, not screenshots." | `M:subagent-card-glass.md:20` |
| Folded chips float | "1 subagent" / "1 background task" chips brought back a solid bar hiding the chat → chips float over the transcript, each its own material; solid bar only for an opened group, the queue, an error. | `M:icon-badge-mismatch.md:22` |
| Folded goal is a chip too | "Goal blocked · Turn 14/20 ›" floats like the other chips. | `M:subagent-card-glass.md:29` |
| Jump arrow beside chips | the scroll-to-bottom arrow comes back down beside floating chips (build 73); it must stay tappable there (build 233 fix: "only the chips and the composer row take touches"). | `M:icon-badge-mismatch.md:24`, `M:jump-arrow-under-dock.md:13-15` |
| Spinner in the chip | a faint dotted column moved through "1 subagent" (spinner frames drawn together) → the chip's spinner must show one frame at a time and the chevron must not bounce. | `M:native-glass-chip-spinner.md:8-12,20` |
| Subagent rows | titles cut at a third of the card → rows give the 44 pt action column back when they have no button; title wraps 2 lines (unlimited at large text); timer on the title line. | `M:native-glass-chip-spinner.md:20` |
| Delegate card | takes the full column (not 75 %), 8 pt from text above/below, the ticker shows **one** line, goal row one line. | `M:native-glass-chip-spinner.md:23`; `R:src/phone-fe-convo.css:235-242` |
| Tool-call looks | rejected three alternatives ("a summary row, steps inside the reply, step pills" — "the look feels wrong"); chose Hermes's real Telegram progress message: one bubble per turn, body-size lines, "💻 terminal" then a code block labelled "Shell" with `</>`. | `M:tool-calls-hide-when-done.md:11` |
| Telegram colours | "abandon the telegram chat themes… i don't like them" — colours, wallpaper, ✓✓ removed; **the tool-bubble layout stays**, in the normal iOS look (Shell block in the accent). | `M:tool-calls-hide-when-done.md:13`; `M:telegram-look-hold.md:16` |
| Ephemeral steps | "make them ephemeral just like they are in telegram", as a setting → Tool Calls After Reply: Keep / Hide; a failed step stays; long-press → Show Steps. | `M:tool-calls-hide-when-done.md:11,25`; `R:src/tool-calls-row.tsx:28` |
| Fold smoothness | 188: "No where near smooth enough. Not even close." → **never animate layout height inside the transcript**: fade in place, one removal, slide what moved. | `M:tool-calls-hide-when-done.md:36` |
| In Header | owner idea: "what if they live in the indicator under the bot name at the top? And if you clicked it it could open the whole list of tool calls for that run". Pill must keep pulsing and never be blank; width ≤ 240 pt. | `R:src/ui-chat/steps-run.tsx:1-5`; `M:tool-calls-hide-when-done.md:39-46` |
| Status line | the live status sits on its own line under the title so its length never moves anything; don't re-propose top-bar layouts. | `M:chat-status-line.md:11,23` |
| Glass | never ship CSS-imitation glass; never tint glass heavily; sweep siblings in the same build. | `M:liquid-glass.md:26`; `N:docs/spec/06-native-feel-and-design.md` §8 |
| Wrapping rows | 12–14 pt vertical padding; trailing actions visually separate. | `M:row-padding-feedback.md:15-17` |
| Stuck "Working…" | a row kept saying Working… after Hermes finished (subagent ended while the phone was away) → check process-wide lists and drop stale claims. | `M:stuck-working-row.md:13-15` |
| Shaking | the Plaid round measured "dock-height changes (subagent chip) jump 190–240 pt" and a tool status row bobbing 44 pt → chips appearing must never move what you are reading. | `M:plaid-stress-round.md:19` |

Never reintroduce anything in spec 06 §12 (Telegram colours, top-bar overhauls, tab-bar accessory, CSS glass…).

---

## 2. Wire reference

All JSON-RPC goes over the account's one `/api/ws` socket (spec 01, spec 04 §1). **Params are strict**: Hermes
rejects any unknown key with `4000` (`H:tui_gateway/contracts/base.py:13-18`). Every session-scoped call names the
bot's `profile` (spec 04 §1.4 DECISION) — allowed by `SessionParams` / `ProfileParams`
(`H:tui_gateway/contracts/common.py:224-234`). `session_id` is always the chat's **runtime** id (8 hex), never the stored
id. All events are `{"jsonrpc":"2.0","method":"event","params":{"type","session_id","payload","seq"}}` (spec 04 §1.2).

### 2.1 Events this stream consumes

| Event | Payload (contract) | Use |
|---|---|---|
| `subagent.spawn_requested`, `subagent.start`, `subagent.progress`, `subagent.thinking`, `subagent.tool`, `subagent.complete` | `SubagentEventPayload`: required `goal`, `task_count`, `task_index`; optional `subagent_id, parent_id, child_session_id, delegation_id, depth, model, tool_count, toolsets, input_tokens, output_tokens, reasoning_tokens, api_calls, files_read, files_written, output_tail[{tool,preview,is_error}], tool_name, text, status, summary, duration_seconds, tool_preview` (`H:tui_gateway/contracts/events.py:475-520`) | §4 roster |
| `todo.updated` | `{todos: [...], revision: int}` (`events.py:324-331`) — full snapshot after a todo tool (`H:tui_gateway/tool_progress.py:354-367`) | §5 |
| `tool.start` / `tool.complete` for `todo` / `todo_list` | `tool.complete` carries `todos` + `revision` merged in (`events.py:283-299`, `tool_progress.py:354-357`); `tool.start` only `args` | §5 (optimistic) |
| `tool.start` / `tool.complete` for `delegate_task` | args `{goal}` or `{tasks:[{goal,…}]}`; result `{results:[{task_index,status,summary,model,duration_seconds,…}], total_duration_seconds}` or background `{status:"dispatched", goals:[…], delegation_id, …}` (`H:tools/delegate_tool_dispatch.py:209,347-360`, `H:tools/delegate_tool_child_run.py:590-600`) | §4.6 fallback, §11.2 card |
| `session.control.update` | `{control: SessionControlSnapshot}` (`events.py:427-431`); published after goal/loop slash commands and after post-turn hooks (`H:tui_gateway/methods_session_control.py:217-231`) | §6 |
| `status.update` | `{kind, text}` (`events.py:216-223`); kinds `status, lifecycle, compacting, compacted, compressing, ready, goal, loop, heartbeat, process, fallback, …`; emitter `H:tui_gateway/server.py:855-866` | §8 |
| `thinking.delta` | `{text}` — spinner rewrites and explained provider waits (`H:tui_gateway/agent_callbacks.py:110-123`) | §8.2 |
| `reasoning.delta` / `reasoning.available` | `{text, verbose?}` (`events.py:116-129`) | §9 (already folded by M1) |
| `tool.generating` | `{name}` | §8 (M1 already) |
| `message.start`, `message.complete`, `error`, `session.info` | spec 04 §3.2 | turn boundaries for §4–§6 |

Example frames (real shapes; values illustrative):

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"subagent.start","session_id":"01965554","seq":41,"payload":{
  "goal":"Read the changelog since 2.3","task_count":2,"task_index":0,"subagent_id":"sa_3f2a91c0","parent_id":null,
  "child_session_id":"20261010_101500_9c1a2b","delegation_id":"d7e1","depth":0,"model":"claude-opus-5-5",
  "toolsets":["terminal","file"],"status":"running","text":"Read the changelog since 2.3"}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"subagent.tool","session_id":"01965554","seq":44,"payload":{
  "goal":"Read the changelog since 2.3","task_count":2,"task_index":0,"subagent_id":"sa_3f2a91c0",
  "tool_name":"read_file","tool_preview":"CHANGELOG.md","text":"CHANGELOG.md","tool_count":3,"status":"running"}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"subagent.complete","session_id":"01965554","seq":58,"payload":{
  "goal":"Read the changelog since 2.3","task_count":2,"task_index":0,"subagent_id":"sa_3f2a91c0","status":"completed",
  "summary":"14 changes since 2.3: export, faster sync, six fixes.","duration_seconds":41.7,"tool_count":9,
  "input_tokens":18200,"output_tokens":1300,"output_tail":[{"tool":"read_file","preview":"CHANGELOG.md","is_error":false}]}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"todo.updated","session_id":"01965554","seq":60,"payload":{
  "todos":[{"id":"1","content":"Read the changelog","status":"completed"},
           {"id":"2","content":"Draft the notes","status":"in_progress"},
           {"id":"3","content":"Publish","status":"pending"}],"revision":4}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"session.control.update","session_id":"01965554","seq":77,"payload":{
  "control":{"goal":{"title":"Ship 2.4","status":"active","turns_used":3,"max_turns":20,
    "contract":{"outcome":"Notes published","verification":"","constraints":"","boundaries":"","stop_when":""},
    "subgoals":["Draft notes"],"gates":[],"created_at":1791630000.0,"updated_at":1791633600.0,
    "last_verdict":"continue","last_reason":"Notes drafted; publishing next"},
    "loop":null,"heartbeat":null,"revision":"8f3c…","updated_at":1791633600.0}}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"status.update","session_id":"01965554","seq":12,"payload":{
  "kind":"fallback","text":"⚠ Model fallback: switched to gpt-5.5 (rate limited)"}}}
```

Notes:
- Subagent lifecycle survives `display.tool_progress: off` (`H:tui_gateway/tool_progress.py:497-501`); `subagent.thinking`
  arrives without `text` when reasoning is hidden (`:461-464`); `subagent.text` is never sent to the parent (`:468-471`).
- Hermes sends a subagent's events **only to the socket the chat is bound to** (`M:stuck-working-row.md:13`).

### 2.2 RPCs

| Method | Params (strict) | Result | Errors | Contract / handler |
|---|---|---|---|---|
| `subagent.list` | `{session_id, profile}` | `{subagents:[SubagentSnapshot], delegations:[FailedDelegation]}`; snapshot keys `subagent_id, parent_id, depth, goal, delegation_id, model, started_at (epoch s), status, tool_count, last_tool, accepting_steer`; delegation `{delegation_id, task_index, status, goal, error, dispatched_at, completed_at}` | `4001` "session not found or not owned by this transport" (chat not bound on this socket) | `H:…/contracts/profiles_vault_complete_foreign_subagents.py:607-645`; `H:tui_gateway/methods_subagents.py:53-78` |
| `subagent.tail` | `{session_id, profile, subagent_id}` | `{subagent_id, available, text (last 16 KiB), truncated}` | `4000` "subagent_id required", `4001` | `…foreign_subagents.py:660-669`; `methods_subagents.py:105-128` |
| `subagent.steer` | `{session_id, profile, subagent_id, text}` | `{status:"queued"\|"rejected", subagent_id, text}` — queued ≠ delivered | `4000` "subagent_id required", `4002` "text is required" | `H:…/contracts/billing_delegation_pets.py:400-419`; `H:tui_gateway/methods_session.py:2235-2251` |
| `subagent.interrupt` | `{session_id, profile, subagent_id}` | `{found, subagent_id}` (`found:false` = already finished) | `4000`, `4001` | `…foreign_subagents.py:647-656`; `methods_subagents.py:81-102` |
| `delegation.status` | `{profile}` (**no** `session_id` — 4000) | `{active:[{subagent_id, parent_id, depth, goal, delegation_id, model, started_at, status, tool_count, owner_agent_session_id, …}], paused, max_spawn_depth, max_concurrent_children}` — process-wide | — | `billing_delegation_pets.py:361-385`; `methods_session.py:2221-2226` |
| `session.control.read` | `{session_id, profile}` | `{control: SessionControlSnapshot}` | `4001` "session has no stored key", `5031`, `-32601` on gateways without it | `H:…/contracts/config_free_tier_control.py:681-701`; `methods_session_control.py:234-248` |
| `session.control` | `{session_id, profile, action, args?}`; `args` only `{text}` (`subgoal.add`) or `{index}` (1-based, `subgoal.remove`); send `args:{}` otherwise | `{control, dispatch:{type, output, notice, message, display}}` (every dispatch key present, may be null) | `4004` "action is required" / "unknown action: X" / "gate actions are not allowed…" / "subgoal text is required" / "subgoal index must be an integer" / "subgoal index must be >= 1" / a manager error; `4001`, `5031` | `config_free_tier_control.py:704-752`; `methods_session_control.py:251-317` |

Allowed actions: `goal.pause, goal.resume, goal.clear, goal.unwait, subgoal.add, subgoal.remove, subgoal.clear`
(this round); `loop.*`, `heartbeat.*` exist but are out of scope (§14) (`config_free_tier_control.py:704-717`).
`goal.*` actions run the `/goal` slash command; `goal.resume` (and a resume from wait) answers
`dispatch:{type:"send", notice:"▶ Goal resumed: …\nContinuing now — taking the next step.", message:"<prompt to
submit>", display:"/goal resume"}` — the client must submit `message` as a **hidden** prompt
(`H:tui_gateway/methods_tools.py:887-910`; web `V:app/chat/composer/status-stack/session-control-goal.tsx:72-128`).
Other actions answer `type:"exec"` with `output`.

Examples:

```json
→ {"jsonrpc":"2.0","id":31,"method":"subagent.list","params":{"session_id":"01965554","profile":"default"}}
← {"jsonrpc":"2.0","id":31,"result":{"subagents":[{"subagent_id":"sa_3f2a91c0","parent_id":null,"depth":0,
     "goal":"Read the changelog since 2.3","delegation_id":"d7e1","model":"claude-opus-5-5","started_at":1791633520.4,
     "status":"running","tool_count":3,"last_tool":"read_file","accepting_steer":true}],"delegations":[]}}
→ {"jsonrpc":"2.0","id":32,"method":"subagent.steer","params":{"session_id":"01965554","profile":"default",
     "subagent_id":"sa_3f2a91c0","text":"Only count user-facing changes"}}
← {"jsonrpc":"2.0","id":32,"result":{"status":"queued","subagent_id":"sa_3f2a91c0","text":"Only count user-facing changes"}}
→ {"jsonrpc":"2.0","id":33,"method":"session.control","params":{"session_id":"01965554","profile":"default",
     "action":"subgoal.remove","args":{"index":2}}}
← {"jsonrpc":"2.0","id":33,"result":{"control":{…},"dispatch":{"type":"exec","output":"…","notice":null,"message":null,"display":null}}}
→ {"jsonrpc":"2.0","id":34,"method":"delegation.status","params":{"profile":"default"}}
← {"jsonrpc":"2.0","id":34,"result":{"active":[],"paused":false,"max_spawn_depth":1,"max_concurrent_children":3}}
```

Hidden prompt for a goal continuation (contract `PromptSubmitParams.display_kind`, "only 'hidden' is honoured",
`H:tui_gateway/contracts/prompt_voice.py:26-35`):
```json
{"jsonrpc":"2.0","id":35,"method":"prompt.submit","params":{"session_id":"01965554","profile":"default",
  "text":"<dispatch.message>","display_kind":"hidden"}}
```

### 2.3 REST

| Call | Use | Source |
|---|---|---|
| `GET /api/config?profile=<p>` → `{…, "display":{"show_reasoning":bool, "tool_progress": "all"\|"new"\|"verbose"\|"off"\|bool, …}, …}` | Reasoning rows on/off (§9.4); tool feed on/off (§10.6). `show_reasoning` absent ⇒ on; `false`, `"false"`, `0` ⇒ off. `tool_progress` off only for `false` or `"off"` (case-insensitive). | `H:hermes_cli/web_routers/config_env.py:80-91`; `V:store/reasoning-disclosure.ts:22-29`; `V:store/tool-activity.ts:1-20`; `V:app/session/hooks/use-hermes-config.ts:146-149` |
| `GET /api/plugins/hermes-hq-performance/sessions/<sid>/messages/<row_id>/content/preview?profile=&offset=&max_chars=20000` | step sheet output paging when the tool row has `display_payload_ref` | spec 03 §2.4 |
| `GET …/messages/<row_id>/content?profile=` (≤ 8 MiB; 413 `tool_content_too_large`) | step sheet Copy of the full output | spec 03 §2.4 |
| `GET /api/fs/download?path=&profile=&session_id=` | the generated image (§11.3) | spec 03 §6.6 |

### 2.4 Resume and history fields

- `session.resume` / `session.activate` answers carry `todo_state: {todos, revision}` when the session has one
  (`H:tui_gateway/contracts/sessions.py:51-55,98`; attached at `H:tui_gateway/methods_session.py:741,919`,
  `H:tui_gateway/server.py:3197`). Native already sends the one canonical resume (spec 03 §3.1.1); read this field
  from that same answer.
- History tool rows (spec 03 §6): `tool_calls[].function.arguments` (JSON string) for args, the `role:"tool"` row's
  `content` (JSON string) for the result, `display_metadata.tool_result_metadata.inline_diff` for file edits,
  `display_payload_ref` for big outputs; `reasoning` / `reasoning_content` / `display_reasoning` on assistant rows.
  `N:HermesKit/Chat/Hydration.swift:528-546,577-587,698-703` already reads all of these.

---

## 3. Native architecture

### 3.1 New and changed files

```
HermesKit/Activity/
  ActivityModels.swift     SubagentProgress, TodoItem, SessionControl* (Codable-free value types), ChatActivity
  SubagentRules.swift      port of V:store/subagents.ts (pure functions, §4.2)
  TodoRules.swift          port of V:store/todos.ts + V:lib/todos.ts (§5.2)
  ControlRules.swift       strict SessionControlSnapshot parse, labels (§6.2)
  ToolLine.swift           port of R:src/ui-chat/tool-line.ts (§10.3) — Bubbles, In Header, Steps sheet
  ToolCards.swift          ToolCard payload extraction from args/result (§11)
  ActivityStore.swift      @MainActor final class; one per signed-in account (§3.2)
  DisplayConfig.swift      GET /api/config display flags per profile (§2.3)
App/Chat/Activity/
  ActivityShelfView.swift  the chip/card stack above the queue card (§7)
  ShelfChip.swift, SubagentsCard.swift, TasksCard.swift, GoalCard.swift, GoalDetailsSheet.swift
  GlyphSpinner.swift       one shared 80/100 ms ticker for braille spinners (§7.4)
  StepsSheet.swift         In Header / Show Steps list (§10.4)
  ToolBubbleCell.swift     Bubbles style (§10.2)
  Cards/DelegateCardCell.swift, ImageCardCell.swift (§11)
  DiffView.swift           coloured diff for the step sheet (§12)
App/Settings/ToolCallsSettingsView.swift   (§13)
```

Changed: `N:HermesKit/Contracts.swift` (§3.4), `N:HermesKit/Chat/LiveChatSession*.swift` (bind to the store, reasoning
timing, hidden send, live step), `N:App/Chat/ChatRow.swift` (styles, cards, fold, show_reasoning), `N:App/Chat/
ChatViewController.swift` (shelf, jump button, insets, status tap), `N:App/Chat/ChatSheets.swift` (§12),
`N:App/Chat/Cells/ChatCells.swift` (Show Steps menu item), `N:App/AppModel.swift` (store wiring, Working…).

### 3.2 `ActivityStore`

```swift
@MainActor final class ActivityStore {
    init(client: any GatewayClient)                       // subscribes to client.events() once; stops on shutdown
    // Chats register the runtime id their resume bound (and again after a re-mint); a new runtime id for the same
    // stored id moves that chat's state across, then re-reads (§4.4).
    func bind(runtimeId: String, profile: String, storedId: String?)
    func unbind(runtimeId: String)
    func activity(_ runtimeId: String) -> ChatActivity    // value snapshot
    var onChange: ((_ runtimeId: String) -> Void)?        // coalesced to ≤ 1 call per runtime id per display frame
    func setVisible(runtimeId: String?, openSubagent: String?)   // gates polls (§4.4)
    func setInterrupted(runtimeId: String, _ value: Bool)  // mirrors LiveChatSession.turn.interrupted
    func stopped(runtimeId: String)                       // Stop: clear subagents + todos (§4.2, §5.2)
    func hasLiveWork(profile: String) -> Bool             // bot rows / sessions rows (§8.4)
    // actions
    func steer(runtimeId: String, subagentId: String, text: String) async -> SteerOutcome
    func interrupt(runtimeId: String, subagentId: String) async -> Bool?
    func runControl(runtimeId: String, action: String, args: [String: JSONValue]) async throws -> ControlDispatch
}

nonisolated struct ChatActivity: Hashable, Sendable {
    var subagents: [SubagentProgress] = []      // all rows incl. terminal ones kept until the next message.start
    var liveTodos: [TodoItem]? = nil            // nil = no live list (the Tasks chip is absent)
    var retainedTodos: [TodoItem] = []          // "Previous tasks" (§5)
    var control = ControlEntry()                // capability, snapshot, pendingAction, actionError
    var nativeSubagentEvents = false            // a native subagent.* event arrived this turn (§4.6)
}
```

Rules:
- The store keeps state per **runtime id** like the web (`V:store/subagents.ts:56`, `V:store/todos.ts:20-24`) and
  ignores events for runtime ids nobody bound.
- A binding lives for the app run — until sign-out, an account switch, or a re-mint that replaces it — not for the
  screen: leaving a chat keeps its children, its claim on the bot row and its event feed (Hermes keeps sending to the
  bound socket). Polls (§4.4) are what stop when the screen goes.
- Events are applied in arrival order on the main actor; deltas are not this store's business (only
  `subagent.*`, `todo.updated`, todo/delegate `tool.*`, `session.control.update`, `message.start`, `message.complete`,
  `error`, `gateway.ready`).
- While `setInterrupted(rid, true)` (Stop pressed, until the next send clears it) every `subagent.*`, `todo.updated` and
  todo/delegate `tool.*` event for that runtime id is dropped (`V:app/session/hooks/use-message-stream/gateway-event/
  tools.ts:26-30,166-180`).
- Reads run through `client.call(method, params, timeout: .seconds(15))`. A read answered after a newer event for the
  same runtime id is discarded (version counter per runtime id, the web's `before === current` check,
  `V:app/chat/composer/status-stack/use-subagent-snapshot.ts:33-47`).
- Nothing in the store is written to disk: activity is live state. (A reopen re-reads it, §4.4.)

### 3.3 Who owns what (boundaries with the other streams)

| Thing | Owner | Interface this stream provides / needs |
|---|---|---|
| Everything `clarify` draws (question dock, "N questions for you" note, sent answers, settled Q&A card), approval cards, consent (`connection.request`) cards | Questions stream (`1x-questions.md`; it parses into `ToolDetail.clarifyResponses`) | This stream treats a `clarify` part as a **card** in every style: never folded into a run, never hidden by In Header or Hide (§10, §11.4). |
| Queue card and queued sends | Queue / composer owners | Hidden goal continuation: `LiveChatSession.sendHidden(text:display:)` (§6.4) queues through the existing local queue with `hidden: true`. |
| Media loading / image viewer | Attachments stream (`1x-attachments.md` §8 and its seams table) | §11.3 uses exactly `MediaLoader.image(path: String, profile: String, sessionId: String?, maxPixel: Int) async throws -> UIImage` and `MediaViewer.present(from: UIView, items: [MediaRef], index: Int)`. If they have not landed, build the spec 03 §6.6 minimum under those names in `N:HermesKit/Media/` and hand it over. |
| Reply hold menu | Menus stream (`1x-menus.md` §9, `App/Chat/Menus/MessageMenus.swift`; it lists Show/Hide Steps as waiting on this stream) | This stream supplies `StepsMenu.item(forMessage: String, in chat: ChatViewController) -> UIAction?` (nil when the reply has no hidden/shown steps); the menus stream appends it last in the reply menu. Until that lands, append it to M1's bubble menu (`N:App/Chat/Cells/ChatCells.swift:242-250`). |
| Settings tab | Settings stream (`1x-settings.md` §3.2, §3.6) | At launch this stream sets `SettingsHooks.toolCallsScreen` (returns the §13 screen) and `SettingsHooks.toolCallsSummary` (§13); Settings shows Chat › **Tool Calls** › only when they are set. |
| Bot / session rows | Bots stream | Reads `ActivityStore.hasLiveWork(profile:)` for Working… (§8.4). |

### 3.4 Contract changes (`N:HermesKit/Contracts.swift`, integration)

1. `ToolCall` gains `var card: ToolCard? = nil` — a **bounded** extract of the result the transcript card needs
   (§11.1). Set by hydration and by `tool.complete`; part of the row fingerprint; encoded in the transcript cache.
   (`ToolCall` today has no result field, `N:HermesKit/Contracts.swift:193-202`.)
2. `ChatMessage` gains `var reasoningSeconds: [Int: Double] = [:]` (part index → measured seconds, §9.2). Memory
   only; never cached.
3. New optional protocol (the queue precedent, `Contracts.swift` `ChatQueueing`):
   ```swift
   protocol ChatActivityProviding: AnyObject {
       var activity: ChatActivity { get }
       var onActivityChange: (() -> Void)? { get set }
       var liveStep: ToolLine? { get }            // In Header (§10.4)
       var statusIsWorking: Bool { get }          // the status words are a "working" state (§10.4)
       func sendHidden(_ text: String, display: String?)
   }
   ```
   `LiveChatSession` adopts it by forwarding to the store for its bound runtime id.

---

## 4. Subagents

### 4.1 What the user sees

1. **In the transcript** — the `delegate_task` call is a card listing its children (§11.2).
2. **Above the composer** — while at least one child of this chat is `running` or `queued`, a folded glass chip
   "1 subagent" / "2 subagents" with a purple braille spinner and a chevron (`B:r21-chat-gates.ts:43-44`;
   `V:app/chat/composer/status-stack/subagent-section.tsx:66-77`). Folded by default (`V:components/chat/
   status-section.tsx:30-31`). It disappears with no linger when no child is live (`subagent-section.tsx:30-32`).
3. **Opened** (tap the chip) — the chip becomes a glass card the width of the column: the header (same words,
   chevron turned down), then one row per live child:
   - leading 16 pt purple braille spinner (`subagent-section.tsx:38-45`);
   - title = the goal, footnote, label colour, up to **2 lines** (3 when that row is selected, unlimited at
     accessibility sizes) (`R:src/phone-fe-convo.css:135-137`);
   - second line = the newest activity entry's text, else "Queued" / "Waiting for activity" (`subagent-section.tsx:57-60`),
     footnote label-2 (owner: no tertiary greys on glass);
   - trailing elapsed timer on the **title's** line, tabular digits, right-aligned in a 5-character column so it never
     re-wraps the title (`R:src/phone-fe-convo.css:138-139`): `formatElapsed` = "Ns" under a minute, else "m:ss"
     (`V:components/chat/activity-timer.ts:31-37`), from the child's `startedAt`, one shared 1 s clock
     (`R:src/ui-chat/subagent-clock.ts:1-6`);
   - no trailing action column (rows without a button give the 44 pt column back, `R:src/phone-fe-convo.css:129-132`);
   - row padding 6 + 8 pt top/bottom (≥ 14 pt), min height 44 (`R:src/phone-fe-convo.css:127-128,169`).
   Tapping a row selects it (one at a time; tap again to close) and shows its **detail** under the list.
4. **Detail** of the selected child (`subagent-section.tsx:81-96`, phone layout `R:src/phone-fe-convo.css:143-166`):
   - **Steer row**: a 44 pt capsule text field (fill-3, radius 22, 17 pt, 16 pt side padding, placeholder
     "Message this subagent…"; the web's "Steer this subagent" — `B:audit-final-gates.ts:9`), 8 pt gap, a 44 pt round send button (↑, accent fill with white
     glyph when the trimmed text is non-empty, fill-3 with label-3 glyph when empty/disabled), a 44 pt round Stop
     button (■ in red on red 15 %). VoiceOver names: "Steer", "Stop". Return = Send.
   - **Feedback line** under it, footnote label-2: "Queued for the next checkpoint" (steer queued), "Stop requested"
     (interrupt found), "The subagent did not accept the request" (rejected / not found / error; `role` alert)
     (`V:i18n/en.ts:2719-2721`; `V:app/chat/composer/status-stack/subagent-controls.tsx:18-52`). A queued steer clears
     the field. Steer/Stop are disabled while their request runs.
   - **Stats line**, footnote label-2, joined " · ": model, duration (`Ns` / `Mm Ss`, `V:i18n/en.ts:2736-2737`), "N tools",
     "N tok" (input + output), "updated <age>" (`now`, `Ns ago`, `Nm ago`, `Nh ago`, `Nd ago`; `en.ts:2731-2735`)
     (`V:app/agents/index.tsx:355-361`). The goal itself is not repeated (`R:src/phone-fe-convo.css:145-148`).
   - **Activity**: the last 10 stream entries (`V:app/agents/index.tsx:352`), footnote, label colour, each clamped to
     2 lines, set in the text face (not monospace) (`R:src/phone-fe-convo.css:158-163`).
   - **Files** (when any): header "Files" (caption, label-2), then up to 8 lines `+ <path>` (written) / `· <path>` (read),
     monospace footnote, then "+N more files" (`V:app/agents/index.tsx:353,404-419`; `en.ts:2712-2713`).
   - **Extended transcript** (only once `subagent.tail` answered `available:true` — an empty or unavailable tail
     shows nothing, `R:src/phone-fe-convo.css:144`): header "Extended transcript" (footnote semibold), "Showing the
     latest 16 KiB" when `truncated`, then the text in monospace 12.5 pt, line height 1.4 (`R:src/phone-fe-convo.css:165`;
     `V:app/chat/composer/status-stack/subagent-transcript.tsx:66-78`).
   - The card is **one scroller** (owner, `M:subagent-card-glass.md:20`): list + detail scroll together inside the card;
     no nested scroll views. Card max height: 60 % of the chat's visible height with the keyboard down and a detail
     open, else 40 % (`R:src/phone-fe-convo.css:143-144`; `V:app/chat/composer/status-stack/index.tsx:371`).
5. **The bot row** says Working… while this chat has a live child (§8.4).

### 4.2 Roster rules (port of `V:store/subagents.ts`)

- **Id**: `subagent_id`, else `"<parent_id or 'root'>:<task_index or 0>:<goal>"` (`subagents.ts:149-150`).
- **Create** only on `subagent.spawn_requested` / `subagent.start`; other events for an unknown id are ignored
  (`subagents.ts:378-388`; `gateway-event/tools.ts:170-180`).
- **Status** (`subagents.ts:90-114`): `completed|failed|interrupted` kept; `timeout|error` → failed;
  `cancelled|canceled` → interrupted; on `subagent.complete` anything else → **failed** (fail closed); otherwise
  `queued` stays queued and anything else is running. Terminal rows are frozen: later events for them are ignored
  (`:390-394`).
- **Retired ids**: an id pruned as terminal (below) is never re-created by a late event or roster (`:58-74,265-270`).
- **Merge** per event (`subagents.ts:211-243`): goal (fallback "Subagent"), `child_session_id`, `delegation_id`, `model`,
  `task_count`/`task_index`, `duration_seconds`, token counts, `tool_count`, `files_read`/`files_written` (replace when
  non-empty), `summary` (or, for `status:"timeout"` with no summary, "Timed out after <duration_seconds>s",
  `:165-169`), `currentTool` = `tool_name` (cleared on terminal), `startedAt` = first seen (a roster's `started_at`×1000
  wins), `updatedAt` = now.
- **Activity stream** (≤ 24 entries, a repeat of the last entry is not appended; `:50,154-163,171-208`):
  for each `output_tail` entry → a tool line `formatTool(tool, preview)` or the compacted preview; `tool_name` present →
  `formatTool(tool_name, tool_preview ?? text)` (error when `payload.error`); `subagent.progress` with text → progress;
  `subagent.thinking` with text → thinking; a terminal status with a summary (or `text`, or the timeout words) →
  summary (error when failed). `compact` = whitespace collapsed, ≤ 220 characters with "…" (`:116-124`).
  `formatTool(name, preview)` = name split on `_`, each word capitalised, joined with spaces, then `("<preview ≤ 96>")`
  when there is a preview: `read_file` + "CHANGELOG.md" → `Read File("CHANGELOG.md")` (`:126-132`).
- **Turn start** (`message.start`): drop every terminal row (keep running/queued), reset `nativeSubagentEvents`
  (`gateway-event/message-stream.ts:103-106`; `subagents.ts:331-366`).
- **Stop**: drop every row for the chat (`V:app/session/hooks/use-prompt-actions/index.ts:719-720`).
- **Roster reconcile** (`subagent.list`, `subagents.ts:250-319`): keep terminal rows and rows whose id is in the
  roster; for each roster entry that is not retired and not terminal, merge it (`last_tool` seeds one activity line
  `formatTool(last_tool)` only when the row has none); each `delegations[]` failed task the store doesn't cover becomes
  a terminal failed row id `delegation:<delegation_id>:<task_index>` with its `error` as summary (shown only by the
  delegate card).
- Port the web's tests: `V:store/subagents.test.ts`, `V:store/subagent-snapshot.test.ts`,
  `V:app/chat/composer/status-stack/subagent-lifecycle.test.tsx` (the cases, not the React).

### 4.3 Steer and Stop

- Send `subagent.steer {session_id, profile, subagent_id, text: trimmed}` only when the trimmed text is non-empty;
  `status != "queued"` or an error → "The subagent did not accept the request" (`subagent-controls.tsx:24-50`).
- Stop sends `subagent.interrupt {…}`; `found:false` or an error → the same rejection words; `found:true` → "Stop
  requested". The row ends when its `subagent.complete` (`status:"interrupted"`) arrives — never remove it locally.
- Haptics: Steer success `notification.success`; Stop `impact.rigid` (spec 06 §9); a rejection `notification.error`.
- The steer draft is kept per child while the chat stays open (`subagent-section.tsx:27,86-90`).

### 4.4 Reads (when the phone asks)

| Read | When | Cadence | Stops |
|---|---|---|---|
| `subagent.list` | once after the chat's resume binds on this socket (open), after every reconnect (`gateway.ready` → the chat's `replayDone`), on app return | while the chat is on screen, the app active and ≥ 1 live child: 5 s, doubled each time the answer changes nothing up to 30 s, back to 5 s on a change (`B:long-session-gates.ts:74-80`; `R:src/subagent-poll-backoff.test.ts:16-33`); none at all while no child is live (`B:fe-convo-gates.ts:442-446`) | 3 failures in a row → stop until the next return / reconnect (`use-subagent-snapshot.ts:26-29,49-52,69-74`); `4001` → stop for this runtime id (it isn't bound) |
| `subagent.tail` | while a child's detail is open and on screen | immediately, then 2 s, doubled while the text is unchanged up to 16 s, back to 2 s on a change; skipped while the app is inactive (`B:long-session-gates.ts:96-100`; `R:src/subagent-poll-backoff.test.ts:34-52`) | detail closed / chat left |
| `delegation.status` | when any bound chat still claims a live child: 1.5 s after `gateway.ready`, 1.5 s after app return, and every 30 s while claims exist and the app is active | one read per (connection, profile) per pass (`R:src/stale-work-check.ts:36-47,80-118`) | no claims |

`delegation.status` reconcile (`R:src/stale-work-check.ts:48-64`): for each chat whose rows include a live child
**that has a gateway id** (skip `delegate-tool:` stand-ins), if the store didn't change during the read, keep only the
listed children (`subagent_id` match) — a live row the gateway no longer lists is dropped. This is what keeps a row
from saying Working… forever after the phone missed the end (`M:stuck-working-row.md:13-15`).

### 4.5 Errors and edge states

- `subagent.list` before the chat is bound, or on another socket: `4001` → no reconcile (rows stay event-fed).
- A child that outlives its turn (background delegation) keeps its chip; `message.start` of the next turn does not
  prune it (it is live).
- Chat re-minted on reconnect: the store moves the rows to the new runtime id (same stored id), then reads
  `subagent.list` (the web resets its polling latch only at real rebinds, `V:app/chat/composer/status-stack/index.tsx:160-170`).
- No list on the gateway (`-32601`): rows stay event-fed; never retry it on that connection.

### 4.6 Delegate fallback (gateways that send no `subagent.*`)

Until the first native `subagent.*` event of a turn arrives for the chat, every `delegate_task` `tool.start` /
`tool.complete` also creates rows `delegate-tool:<tool_id>:<index>` per task: goal from `args.tasks[i].goal` /
`args.goal` / `context` ("Delegated task"), status running → completed (or failed when `payload.error` or
`result.status ∈ {timeout, error, failed, failure}`), summary from `result.summary` / `payload.summary`
(`V:app/session/hooks/use-message-stream/utils.ts:194-245`; `index.ts:567-576`). The first native event removes the
stand-ins (`gateway-event/tools.ts:166-170`; `subagents.ts:368-376`).

---

## 5. Tasks (todo) chip and card

### 5.1 What the user sees

- **Live list** → a chip "Tasks <completed>/<all>" (all items count, cancelled included; `V:app/chat/composer/
  status-stack/index.tsx:86-88`; `V:i18n/en.ts:4050`) with a label-2 braille spinner after the words while an item is
  in progress (`index.tsx:95-96,281-291`). **Opened by default** (`index.tsx:293`; native: once you fold it, a new
  list in the same turn leaves it folded, and the next turn opens it again): the card lists the items in tree
  order (parents before children; dangling parents → top level; `V:lib/todos.ts:91-138`), indented 4 pt per level
  (max 4) (`R:src/phone-fe-convo.css:127-132`; `status-row.tsx:125`).
- Row glyph (16 pt): pending → a dashed ring (`circle.dashed`); in progress → the braille spinner (label-2); completed →
  a filled green check (`checkmark.circle.fill`, system green); cancelled → `circle.slash` in label-3
  (`V:app/chat/composer/status-stack/status-row.tsx:15-58`). Title footnote, wraps; completed and cancelled titles in
  label-2, others in label (`status-row.tsx:133-142`). Rows ≥ 44 pt with 14 pt vertical padding.
- **Previous tasks** → when the chat is idle, has a retained list, and no live list: a chip
  "Previous tasks <completed>/<all>", **folded** by default; opened, its rows are historical: an in-progress item shows
  the pending ring (`index.tsx:313-345`; `status-row.tsx:44-46`; `en.ts:4051`). Native: when every item is completed
  or cancelled, the opened card's ⋯ offers Hide Previous Tasks (the list leaves this chat's shelf while the app runs;
  nothing is sent). A done goal's ⋯ offers Hide Goal the same way.

### 5.2 Rules (port of `V:store/todos.ts`, `V:lib/todos.ts`)

- **Item** `{id, content, status ∈ pending|in_progress|completed|cancelled, parent?}`; parse from an array, a JSON
  string, or `{todos:[…]}` (≤ 2 levels of nesting); drop entries without a valid status or with empty trimmed
  `id`/`content`; `parent == id` is dropped (`V:lib/todos.ts:28-80`).
- **Revision watermark** per chat: a snapshot whose `revision` is lower than the watermark is ignored; an unversioned
  update (from `tool.start`) applies without moving it (`V:store/todos.ts:76-98`).
- **Apply** (`setSessionTodos`, `:112-130`): a versioned snapshot also replaces the retained list (an empty one clears
  it); the live list is replaced; when it has no pending / in-progress item it lingers **4 s** then the live list goes
  (the retained one stays) (`:72,126-129`).
- **Sources**: `todo.updated` → full snapshot; `tool.complete` of `todo`/`todo_list` with `todos` (+ `revision`) →
  full snapshot; `tool.start` of a todo tool → `args.merge == true` ? patch by id (append unknown ids with content or
  "(no description)") : `args.todos` as a full list (unversioned) (`V:lib/todos.ts:159-212`;
  `V:app/session/hooks/use-message-stream/index.ts:558-566`; `utils.ts:157-166`).
- **Resume** `todo_state`: an empty list at revision 0/absent is ignored; if the chat is running → apply; if idle →
  apply only a finished list (no pending / in-progress), otherwise drop the live list but keep the retained one
  (`V:store/todos.ts:60-69,190-216`). **Native (verify round 2):** an idle chat with no live list showing takes a
  finished list straight as the retained one (the folded Previous tasks chip); only a finished list already on screen
  keeps its 4 s linger. The web's way opened a Tasks card on every open of such a chat and folded it 4 s later, sliding
  the transcript up and back down (the owner's "bounces before settling", `M:chat-open-bounce.md`).
- **Before the resume answers** a reopened chat reads the store's state for its stored id (the store keeps a chat's
  children, lists and goal for the app run), so its shelf is drawn from the first frame; shelf changes that land while
  the chat is being pushed apply at once (no shelf animation and no glide during the push).
- **Turn end** (`message.complete`, a turn `error`): drop a still-active live list (retained stays)
  (`gateway-event/message-stream.ts:341-345`; `status.ts:310-317`).
- **Stop**: clear live, retained and the watermark (`use-prompt-actions/index.ts:719`; `todos.ts:154-158`).
- Silent todo tool rows are still never drawn in the transcript (spec 03 §8.10); a failed one draws the failed step.

---

## 6. Goal chip, card and actions

### 6.1 Capability and reads

- Per chat `ControlEntry {capability: unknown|supported|unsupported, snapshot, pendingAction, actionError}`
  (`V:store/session-control.ts:111-117`).
- Read `session.control.read` once the chat's resume binds, after each reconnect, and after every turn end **when
  supported** (`V:app/chat/composer/status-stack/index.tsx:172-178`; `V:store/session-control.ts:866-872`;
  `gateway-event/message-stream.ts:428`). A valid answer → supported. `-32601` (or "method not found") → unsupported
  for this connection: no goal chip on that gateway (DECISION, §14 item 7). Any other failure → keep the old snapshot;
  on the phone **nothing is shown** for a read failure (log it quietly) (`B:r21-chat-gates.ts:14-38`).
- `session.control.update` replaces the snapshot when its parse succeeds (`gateway-event/session-control.ts:5-19`).
- **Strict parse**: drop the whole snapshot if a required field is missing or mistyped (the web's `hasExactFields`
  discipline, `V:store/session-control.ts:150-447`): `goal` `{title:str, status ∈ active|paused|done, turns_used:int,
  max_turns:int, contract{outcome,verification,constraints,boundaries,stop_when: str}, subgoals:[str], gates:[{command,
  timeout_seconds, max_retries, attempts, last_exit_code?}], created_at?, updated_at?, paused_reason?, last_verdict? ∈
  blocked|continue|done|skipped|wait, last_reason?, wait_barrier? {type:"until", until_at, reason} | {type:"session"|"pid",
  target, reason}}` (`H:…/contracts/config_free_tier_control.py:602-651`). `loop` / `heartbeat` are kept raw (unused).

### 6.2 The chip

Shown when `snapshot.goal != nil`. Words (`V:app/chat/composer/status-stack/session-control-goal.tsx:146-185`;
`V:i18n/en.ts:4044-4048,4057-4059`):
- state: `wait_barrier` → "Goal waiting"; status paused → "Goal paused"; done → "Goal done"; else "Goal active";
  `last_verdict == "blocked"` overrides → "Goal blocked";
- suffix: done → " · N turn(s)"; else `max_turns > 0` → " · Turn U/M"; else `turns_used > 0` → " · Turn U".
- Leading glyph colour (shown in the opened header only; the folded chip is words + chevron like the others,
  `R:src/phone-fe-convo.css:118`): blocked red, done label-2, active green, paused/waiting orange.
- Folded by default. A done goal stays until cleared (Hermes keeps it; `H:tui_gateway/methods_session_control.py:48-51`).

### 6.3 The opened card

Top to bottom (`session-control-goal.tsx:327-430`):
1. Header row: the chip's words, chevron down, and a trailing 44 pt "⋯" button (`UIButton` with a `UIMenu`) — the
   goal's actions (below). Long-press anywhere on the card opens the same menu.
2. Title row: flag glyph + `goal.title`, subheadline, label, wraps without limit (`break-words`).
3. Reason row (footnote, label-2, wraps): wait barrier → "Wait condition: <reason>" (or "Wait condition"); else
   `paused_reason`; else `last_reason`.
4. "View Details" row (tint, 44 pt) when any contract field, a wait barrier or gates exist → the Goal Details sheet.
5. Separator, then the criteria header "Criteria · N" (footnote semibold label-2) with trailing text buttons "Add
   Criterion" and, when N > 0, "Clear All Criteria" (red); then one row per criterion: pending ring, the text (wraps),
   trailing 44 pt Copy and ✕ (Remove) buttons separated from the text by 16 pt (`M:row-padding-feedback.md:17`).

**Actions menu** (`session-control-goal.tsx:225-273`): "View Details" (when details exist); "Add Criterion" (not
done); then by state: active → "Pause Goal"; paused → "Resume Goal"; waiting → "Resume Now" (`goal.unwait`) and
"Pause Goal"; always last "Clear Goal" (destructive). Every item is disabled while an action runs.

**Confirmations** (the web's: `V:i18n/en.ts:4070-4078`), as system alerts with a destructive confirm:
"Clear Goal?" / "The goal and its criteria are removed. This can’t be undone." / "Clear Goal";
"Remove Criterion N?" / "“<criterion, first 80 characters>” is removed from this goal." (or "It is removed from this
goal.") / "Remove Criterion N";
"Clear All Criteria?" / "Every criterion is removed from this goal." / "Clear All Criteria".
**Add Criterion**: an alert with one text field (placeholder "Enter criterion text…"), Cancel / Add; empty →
the Add button stays disabled. **Copy** → pasteboard + `notification.success` + VoiceOver "Criterion copied to
clipboard" (`en.ts:4136`).

**Goal Details sheet** (system sheet, medium/large, read-only; `en.ts:4081-4096`): "Objective" (the title); the
contract fields that are non-empty, labelled Outcome / Verification / Constraints / Boundaries / Stop when; "Wait
condition": "Waiting until <local date-time>" / "Waiting on session <target>" / "Waiting on process <pid>" plus the
reason; "Quality gates": per gate the command (monospace), "a/m attempts", "Ns timeout", "Exit code: N" or "Pending".

### 6.4 Running an action

- `session.control {session_id, profile, action, args}` with `args:{}` for actions without input,
  `{text}` for `subgoal.add`, `{index}` (1-based) for `subgoal.remove` (§2.2). Apply the returned `control` at once
  (the event that follows is then a no-op by `revision`).
- `dispatch.type == "send"` with a non-empty `message`: if the chat is idle → `sendHidden(message, display:
  dispatch.display)`: `prompt.submit {…, text: message, display_kind: "hidden"}` with **no user bubble** (the reply
  arrives like any turn). If a reply is running → enqueue it on the local queue as hidden (the queue card shows
  `display ?? "Continue toward goal"` in label-2) and announce "Goal resumed — continuation queued until the current
  turn finishes" to VoiceOver; if it can't be queued → the card's red row "Goal resumed — session busy, stop the
  current reply first to continue" (`V:app/session/hooks/use-prompt-actions/queue-if-busy.ts:19-45`;
  `session-control-goal.tsx:96-109`; `en.ts:4138-4140`, the web's "(Stop button or Esc)" dropped on the phone).
  A failed hidden submit → red row "Failed to submit goal continuation".
- Success → VoiceOver announcement "Action succeeded" only (`session-control.tsx:73-77`). Failure → a red row at the
  top of the card: "Action failed: <message ≤ 240 chars>" with a 44 pt ✕ to dismiss (`session-control.tsx:36-72`;
  `V:store/session-control.ts:663-673`). A read failure is never shown on the phone (§6.1).

---

## 7. The shelf (layout, glass, motion)

### 7.1 Order and composition

Top → bottom, above the composer (`V:app/chat/composer/status-stack/index.tsx:226-342`; `V:store/composer-status.ts:254`):
1. Goal (chip/card)
2. Tasks (live)
3. Subagents
4. (Background tasks — later round, §14)
5. Previous tasks
6. The existing queue card (`N:App/Chat/ChatViewController.swift:345-389`) — nearest the composer.

The shelf is a vertical stack: 8 pt side insets, 6 pt between pieces, 6 pt above the queue card / composer
(`R:src/phone-fe-convo.css:105-107`). **Native (verify round 2):** the side insets follow the composer row's (26 pt with
the keyboard down, 8 pt over the keys or beside the question dock), as the queue card's and the memo notice's do: the
docked cards and the row share one pair of edges. The whole shelf never grows past 6 pt under the status line: when the
keyboard, a tall draft and a queue card leave less room, opened cards give way first (the tallest, never below a header
and 60 pt of body; their bodies scroll) — folded chips never shrink. A **folded** piece is a chip that hugs its words and is **centred**; an
**opened** piece is a card the full stack width (screen − 16) with radius 18 (`R:src/phone-fe-convo.css:110-114`).

### 7.2 Glass

- Chips: `UIVisualEffectView(effect: UIGlassEffect(style: .regular))`, `isInteractive = true`, capsule corners,
  untinted (spec 06 §8.2–8.3). Height 44; content padding 14 pt leading / 10 pt trailing; words in Subheadline (cap 22),
  label colour; 4 pt gap; the indicator (spinner) then a chevron (SF `chevron.right`, 0.7 em, semibold, label-2,
  2 pt leading margin) turned 90° when open (`R:src/phone-fe-convo.css:116-124`).
- Opened cards: the same untinted regular glass, corner radius 18, **not** interactive as a whole (rows give their own
  press highlight: fill-4). Text on glass uses only label / label-2 at footnote size or larger (owner, §1).
- All shelf pieces live in one `UIGlassContainerEffect` with **spacing 4** (less than the 6 pt gap, so pieces never
  merge at rest but morph when a chip opens into a card or a card closes).
- **DECISION:** every opened card (subagents, tasks, goal, previous tasks) is glass. The owner asked for the subagents
  card on Liquid Glass (`M:subagent-card-glass.md:8`) and siblings get the same treatment in the same build (spec 06
  §8.7); the web kept the others on a solid fill only because its mirrored glass could not hold live text
  (`M:subagent-card-glass.md:10`), which native glass can. Under Reduce Transparency the system draws them opaque.
- **DECISION:** the Steer field keeps the glass while typing (the web went solid because its glass was a picture,
  `M:subagent-card-glass.md:10`).

### 7.3 The transcript, the jump button and touches

- **Bottom inset** = view bottom − the dock's top (the topmost of shelf, queue card, composer) + the M1 content gap
  (`N:App/Chat/ChatViewController.swift:694-695`), so a chip never covers the newest message.
- **No jump** (Plaid finding, §1): when the shelf's height changes —
  - following the newest end: the newest row stays the same distance above the dock; the inset change rides the
    shelf's own animation (0.3 s, `UISpringTimingParameters(dampingRatio: 1)`), never a separate jump;
  - scrolled up: the rows on screen must not move — compensate the content offset by the inset delta in the same
    transaction.
- **Jump button** (`R:src/phone-ui-chat.css:362-368`): when the shelf holds only folded chips and there is no queue card,
  the button's bottom sits where it would with no shelf (composer top − `jumpAboveComposer`), i.e. beside the centred
  chips; otherwise it sits above the topmost dock piece. At accessibility text sizes, or whenever the widest chip's
  trailing edge comes within 8 pt of the button's leading edge, it sits above the shelf. It moves with the shelf's
  animation.
- **Touches**: the shelf's container passes every touch that isn't on a chip or card through to the transcript and the
  jump button (`point(inside:with:)` = union of piece frames) (`M:jump-arrow-under-dock.md:13-15`).
- **DECISION:** tapping a chip does **not** dismiss the composer's keyboard. (The vendor blurs the composer on any
  touch in the stack, `V:app/chat/composer/status-stack/index.tsx:373`, which moves the chip under the finger as the
  keyboard drops; Telegram's pinned panels don't.)
- With the keyboard up the cards obey the 40 % cap; the shelf rides with the composer on the keyboard layout guide.

### 7.4 Spinners and motion

- One shared ticker drives every braille spinner on screen (a single `CADisplayLink` at ≤ 30 Hz or a 80 ms timer,
  paused when nothing is visible and when the app is inactive). Frames: braille `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` every 80 ms; breathe
  `⠀⠂⠌⡑⢕⢝⣫⣟⣿⣟⣫⢝⢕⡑⠌⠂⠀` every 100 ms (package `unicode-animations` 1.0.3, the vendor's source,
  `V:components/ui/glyph-spinner.tsx:1-44`; frames read from `/Users/me/Projects/hermes-ios/node_modules/
  unicode-animations`). Draw one glyph in a fixed-width, fixed-height label so the chip never resizes
  (`M:native-glass-chip-spinner.md:8-12`). Purple = `#9E94D5` (`V:styles.css:249`). Reduce Motion: a static `⠿`; a
  live transcript tool or thought row (no shimmer then) also shows a still 7 pt accent dot before its chevron, so it
  never reads as a finished one.
- Open / close: the chip ↔ card morph inside the glass container over 0.35 s spring (damping 1); the card's contents
  fade in over 0.15 s after the frame settles. A chip appears with a 0.2 s fade + scale 0.9→1; disappears with a 0.18 s
  fade. Never animate transcript row heights (§1).
- Live text inside glass (timers, activity lines, tail) must be verified **on video** frame by frame: no flashes, no
  doubled lines (`M:subagent-card-glass.md:20`).

### 7.5 Accessibility

- A chip is a button: label "<words>", value "collapsed"/"expanded", hint "Shows details". The spinner is hidden
  from VoiceOver; the chip's label adds ", running" when a spinner shows.
- Rows read "<title>, <status>, <elapsed>"; the timer is `updatesFrequently` but not announced each second.
- All touch targets ≥ 44 pt; at accessibility sizes text wraps (chip words included) and caps follow spec 06 §10.

---

## 8. "Working…" details

### 8.1 Header status capsule (exists, `N:HermesKit/Chat/LiveChatSession.swift:1073-1098`)

Unchanged words and precedence except: In Header replaces the working words with the live step (§10.4). Compaction:
`compacting`/`compressing` → "Summarizing…", `compacted`/`ready` → end (already in `N:…/LiveChatSession+Events.swift:84-89`).

### 8.2 Provider waits in the waiting capsule

`thinking.delta` text is kept only when it matches the vendor's explained-wait pattern
`^(?:⏳|⚠|↻|⚙)\s*(?:(?:still\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))`
(case-insensitive) (`V:store/provider-wait.ts:45-53`); other `thinking.delta` frames are ignored. While kept and no
reply is visible, the waiting capsule (spec 06 §3.4) shows that text instead of "Waiting for <model>" (the timer stays).
It clears on `error, message.complete, message.delta, message.interim, message.start, reasoning.available,
reasoning.delta, tool.complete, tool.generating, tool.start` (`V:app/session/hooks/use-message-stream/gateway-event/
index.ts:67-78,221-223`). Today native stores the raw text and never shows it (`N:…/LiveChatSession+Events.swift:72-73`).

### 8.3 Fallback model notice

`status.update` with `kind == "fallback"` and non-empty text, or any kind whose text matches
`/model fallback|provider fallback|switched to fallback|switching to fallback/i`, appends a system notice row with that
text (id `fallback-switch-<seconds>`) (`V:…/gateway-event/status.ts:24-30,120-139`). Other `status.update` kinds:
`goal`, `loop`, `heartbeat` — ignored (the structured snapshot covers the goal); `process` — ignored this round (§14).

### 8.4 Bot and session rows

A bot (and its Sessions row) says "Working…" while its chat's turn runs **or** its chat has a live child
(`R:src/ui-kit/bot-status.ts:51`; spec 02 §6.6 `background` claim). `AppModel.setWorking` becomes
`turnRunning || activity.hasLiveWork(profile)`; the store calls back when a chat's live-child set becomes empty or
non-empty. §4.4's `delegation.status` pass is what ends a claim the phone missed.

---

## 9. Reasoning

### 9.1 Row words

The quiet row (spec 06 §3.1, glyph *thinking*) says, for the reasoning part (`V:components/assistant-ui/thread/
message-parts.tsx:212-238`; `V:i18n/en.ts:5059-5062`):
- live (the part is open) → "Thinking";
- done with no measured duration (history, or reopened in a new app run) → "Thought";
- measured `< 1 s` (whole seconds = 0) → "Thought briefly";
- else "Thought for <formatElapsed(seconds)>" — "Thought for 7s", "Thought for 1:05".
Today native says only "Thinking"/"Thought" (`N:App/Chat/ChatRow.swift:376-386`).

### 9.2 Measuring

`LiveChatSession` records, per assistant message and reasoning part index, the time of the part's first chunk
(`reasoning.delta`, or `reasoning.available` arrival) and the time it closes (the next text/tool part opens, an
interim seals the bubble, the turn completes, or Stop). seconds = floor(end − start); store in
`ChatMessage.reasoningSeconds[partIndex]` (§3.4). A `reasoning.available` that replaces the reasoning (spec 04 §3.2)
keeps the first start time. Never cached: a relaunch shows "Thought".

### 9.3 Expand

Tap opens the inset card under the row with the reasoning text in Subheadline, label-2, 10 pt top/bottom (exists;
`R:src/ui-chat/trail.css:19,25`). Rows are collapsed by default on the phone, live ones included (the phone's
`PhoneTrail` ignores the desktop's live preview, `B:ui-chat-trail-gates.ts:31`). An opened live thought grows as text
arrives (height change at the newest end only, spec 06 §5.4).

### 9.4 When there are no reasoning rows

- `display.show_reasoning` off for the chat's profile (§2.3): draw no reasoning rows at all, live or history
  (`V:components/assistant-ui/thread/message-parts.tsx:337,382,413-416`). Read the flag on chat open (cached per
  account+profile for 5 minutes); until it arrives, draw them.
- Tool Call Style In Header: thought rows are omitted (`R:src/ui-chat/trail-view.tsx:172-173`).
- After Reply Hide: thought rows fold with the turn's steps (§10.5).
- Bubbles: thought rows stay quiet rows between bubbles (`R:src/ui-chat/trail-view.tsx:174`;
  `M:chat-telegram-look.md:14`).

---

## 10. Tool Call Style and After Reply

### 10.1 Settings (device-local)

| Setting | Values | Native storage | Default | Web |
|---|---|---|---|---|
| Tool Call Style | `rows` · `line` · `bubbles` · `header` ("Rows", "One Line", "Bubbles", "In Header") | `UserDefaults` `hq.chat.toolCallStyle` (absent = line) | One Line (owner, 2026-10-19; Rows before) | `R:src/ui-chat/tool-calls-setting.ts:9-20`; One Line is native only (§10.7) |
| Tool Calls After Reply | `keep` · `hide` ("Keep", "Hide") | `UserDefaults` `hq.chat.toolCallsAfterReply` (absent = keep) | keep | `:22-33`; hidden while style = In Header (`R:src/tool-calls-row.tsx:24`) |
| Fewer Timestamps (Settings › Chat switch) | on · off | `UserDefaults` `hq.chat.fewerTimestamps` (absent = on; "off" stored as false) | on (owner, 2026-10-19) | native only (§10.7) |

Changing either rebuilds the open chat's rows at once (no animation; the visible rows' top must not move — keep the
first visible row's offset). Launch arguments `-hq.chat.toolCallStyle bubbles` work for tests (UserDefaults argument
domain).

### 10.2 Bubbles (`R:src/ui-chat/trail-view.tsx:126-150,231-246`; `R:src/ui-chat/trail.css:51-84`)

- Each **run** of tool calls (the same grouping as Rows, spec 03 §8.2, file edits standing alone) becomes a **bot
  bubble** (the M1 bot bubble surface, corners and tail rules). Adjacent tool bubbles of the same message read as one:
  square corners where they meet, both at the full bubble max width (`trail.css:81-84`). A tool bubble joins the run
  of bot bubbles like a text bubble (tail and time only on the run's last bubble).
- Inside: padding 8 pt top/bottom, 12 pt sides; one **line per call** at the bubble's font (Body) and leading:
  `<emoji> <text>` in label colour (`trail.css:55-63`), from `ToolLine` (§10.3). Lines sit one line-height apart
  while each keeps a ≥ 44 pt tap target (overlapping targets) (`trail.css:56-59`).
- A command (`terminal`) or code (`execute_code`) is drawn under its line as a block: width fits content (max 100 %),
  4 pt above / 2 below, padding 4 10 6 12, radius 6, accent at 10 % behind, a 3 pt accent bar on the leading edge;
  head row "Shell" (terminal) / "Python" (execute_code) in Subheadline semibold accent and "</>" in monospace footnote
  accent, 24 pt apart; code in monospace 15 pt, line height 1.35, clamped to **2 lines**, wrapping at any character,
  label colour (`trail.css:70-77`; `trail-view.tsx:238-242`).
- Meta after the text (footnote, tabular): a failed call → "Failed" (and "Exit N" when known) in red; a failed line's
  text is red too (`trail.css:64-68`; `R:src/ui-chat/trail-model.ts:81-86`).
- Running call: the text (or the code when there is code) shimmers; the line is disabled (`trail-view.tsx:233-236`).
- Tap a line → the step sheet (§12); while its output loads the line reads "Opening…" (`:236`); a load failure adds
  "Couldn’t open output. Tap to retry." (footnote label-2, `:244`). Press feedback: opacity 0.5 (`trail.css:61`).
- More than 8 lines: the first line is "⋯ N earlier steps" in the accent (tap shows all; remembered while the chat is
  open), followed by the newest 7 (`trail-view.tsx:135-146`).
- Thoughts stay quiet rows (§9.4). Card tools stay cards (§11). Desktop Look does not exist natively (spec 06 §11).
- VoiceOver per line: "<text>: <code>, Failed, running" (`trail-view.tsx:234`).

### 10.3 `ToolLine` (port of `R:src/ui-chat/tool-line.ts`, Hermes's own Telegram wording)

```
EMOJI: terminal 💻, execute_code 🐍, process_manage ⚙️, read_terminal 🖥️, close_terminal 🖥️, read_file 📖,
  write_file ✍️, patch 🔧, search_files 🔎, web_search 🔍, web_extract 📄, x_search 🐦, browser_navigate 🌐,
  browser_snapshot 📸, browser_click 👆, browser_type ⌨️, browser_press ⌨️, browser_scroll 📜, browser_back ◀️,
  browser_get_images 🖼️, browser_vision 👁️, browser_console 🖥️, browser_exec 🌐, browser_cdp 🧪, browser_dialog 💬,
  image_generate 🎨, video_generate 🎬, video_analyze 🎬, vision_analyze 👁️, desktop_preview 🖼️, skill_view 📚,
  skills_list 📚, skill_manage 📝, delegate_task 🔀, cronjob_manage ⏰, clarify ❓, memory 🧠, todo_list 📋, todo 📋,
  react_to_message 💛; anything else ⚙️
VERB: web_search "Searching the web", web_extract "Reading", browser_navigate "Browsing", browser_click "Clicking",
  browser_type "Typing", read_file "Reading", write_file "Writing", patch "Editing", search_files "Searching files",
  terminal "Running", execute_code "Running code", image_generate "Generating image", video_generate "Generating video",
  text_to_speech "Generating speech", vision_analyze "Looking at the image", session_search "Searching past sessions",
  skill_view "Reading skill", skills_list "Listing skills", skill_manage "Updating skill", delegate_task "Delegating",
  cronjob_manage "Scheduling", clarify "Asking", memory "Updating memory", todo_list "Updating tasks"
PRIMARY arg: terminal command, web_search query, web_extract urls, read_file/write_file/patch path, search_files pattern,
  browser_navigate url, browser_click ref, browser_type text, image_generate prompt, text_to_speech text,
  vision_analyze question, skill_view name, skills_list category, cronjob_manage action, execute_code code,
  browser_exec code, delegate_task goal, skill_manage name; otherwise the first present of
  query, text, command, path, name, prompt, code, goal
NO_PREVIEW: skills_list, session_search, memory, todo_list.   "for" joiner: web_search, search_files.
```
Rules (`R:src/ui-chat/tool-line.ts:44-75`): strip a `functions.` prefix; args may be a JSON string (unparsable → `{}`);
`terminal`/`execute_code` with a non-empty command/code → `{text: "terminal" | "Running code", code: <trimmed>}`;
preview = the primary arg (first element of an array), objects/null → none, whitespace collapsed; paths → last
component (backslashes count); `browser_navigate`/`web_extract` → URL without scheme, `www.` and trailing `/`;
`delegate_task` with `tasks` → the one goal or "N tasks". Text: verb known → `"<verb> <preview>"` (`"<verb> for
<preview>"` for the joiner tools) or the verb alone; unknown tool → `"<name>: “<preview>”"` or `"<name>…"`.
Port the cases of `R:src/ui-chat/tool-line.test.ts:5-30` verbatim as unit tests (e.g. `browser_navigate
{url:"https://www.example.org/changelog/"}` → 🌐 "Browsing example.org/changelog"; `terminal "{\"comm"` → 💻 "Running";
`delegate_task {tasks:[{goal:"a"},{goal:"b"}]}` → 🔀 "Delegating 2 tasks").

### 10.4 In Header (`R:src/ui-chat/steps-run.tsx`; `R:src/ui-chat/trail-view.tsx:122-128,170-175,229`; `R:src/ui-chat/title-view.tsx:135,154`)

- **Transcript**: no tool rows, no file-edit rows, no thought rows (failed ones too). Card tools still draw (§11).
- **Live step** (`steps-run.tsx:37-48`): while the chat is running, take the newest assistant message; find its last
  part that is a tool call or non-empty text; if it is a tool call, the live step is `ToolLine` of it and the status
  words become `"<emoji> <code's first line or text>"` (e.g. "💻 npm test", "🔍 Searching the web for kv cache");
  otherwise (it is writing, or no step yet) the normal words stay. Applies only when the status is a *working* state
  (not Offline / Reconnecting / Waiting for your approval… — `R:src/ui-chat/title-view.tsx:135`).
- **Tap**: while working in In Header, the status capsule shows a trailing "›" (`title-view.tsx:90`) and its line
  takes taps (a ≥ 44 pt hit area hugging the capsule; the capsule itself never becomes a separate control — the
  owner's blank/frozen pill came from that, `M:tool-calls-hide-when-done.md:43`). Tap → `selection` haptic → the
  **Steps sheet** for the latest turn. VoiceOver: "<status words>. Show Steps" (`title-view.tsx:125`).
- **Steps sheet** (`steps-run.tsx:52-90`; styles `R:src/ui-chat/trail.css:86-100`): system sheet titled "Steps",
  subtitle "1 step" / "N steps"; one rounded group (elevated cell colour, radius 14, hairline separators) with a row per
  tool call of that turn in order: emoji column (1.4 em), the line's text (Body, label, wraps), the code under it in a
  3-line clamped monospace footnote block on fill-4 (radius 6, padding 4 8); trailing a 16 pt spinner (ring, label-2
  arc) while running, or "Failed" (footnote red, and the text red) when failed. Rows ≥ 44 pt, padding 11 pt top/bottom,
  14 pt sides. Empty: "No steps yet." (live) / "This reply ran no tools." (Subheadline label-2). The live sheet updates
  as calls arrive and finish. Tap a row → the step sheet **pushed inside the same sheet** (Back returns to Steps)
  (DECISION: the web stacks a second details sheet; `M:sheet-pages.md` shows the owner prefers pages in one sheet).
  Footer "Copy" copies every line (`<emoji> <text>\n<code>`).
- **Show Steps** on a reply (§10.5) opens the same sheet for that reply's turn (not live).

### 10.5 After Reply: Hide (`R:src/ui-chat/tool-calls-setting.ts:35-51`; `trail-view.tsx:47-118`; `steps-fold.ts`)

- **Step blocks** of a message = its tool-run rows, file-edit rows, thought rows and tool bubbles (not cards).
- **State** per assistant message: `working` while the message streams, or while the chat runs and the message is the
  newest assistant message after the last user message; else `failed` if the last failed tool call has no non-empty
  text part after it; else `done` (`tool-calls-setting.ts:43-51`).
- With Hide and `done`, the message's step blocks are not drawn unless the user chose **Show Steps** on it (a set of
  message ids kept while the app runs, `:35-41`). `failed` keeps them all. Messages already `done` when loaded (history,
  reopen) are hidden with no motion.
- **Fold** when a message turns from `working` to `done` while on screen (`R:src/ui-chat/steps-fold.ts:1-123`), in
  three steps — never a height animation (owner, §1):
  1. its step cells fade out where they stand: opacity 1 → 0 and scale 1 → 0.97 (anchor top-leading) over **200 ms**,
     `cubic-bezier(.4,0,1,1)`;
  2. one update removes all of them (`performWithoutAnimation` + `performBatchUpdates`, one layout pass);
  3. every visible cell that moved starts at its old position (a transform equal to old − new y, applied in the same
     transaction) and slides home over **380 ms** `cubic-bezier(.3,.1,.2,1)`.
  Anchoring in the inverted table: at the newest end the reply stays put and older rows slide down; scrolled up, the
  first visible row keeps its place (offset compensation) and only rows that really moved slide. Reduce Motion: remove
  at once, no slide. If a stream glide or the send lift is running, skip the slide (`steps-fold.ts:69-71`).
- **Show Steps / Hide Steps**: the reply's long-press menu gains "Show Steps" (`list.bullet`) when its steps are hidden
  and "Hide Steps" after they were brought back (`R:src/ui-chat/message-menu.ts:28`; `message-menus.ts:51-56,75`).
  Show inserts the blocks with a 200 ms fade-in (no height animation; the reply keeps its place); Hide runs the fold.
  In In Header the item is "Show Steps" on any reply whose turn ran tools and opens the Steps sheet (§10.4).

### 10.6 `display.tool_progress` off

When the chat's profile has `display.tool_progress` off (§2.3), run tools that neither failed nor are cards draw
nothing in any style (the gateway doesn't send them live; history still has them) (`V:components/assistant-ui/thread/
message-parts.tsx:155-160`). Cards, failed calls and file edits (they are cards to the gateway,
`H:tui_gateway/tool_progress.py:291-292,359-362`) still draw.

---

### 10.7 One Line, joined words, Fewer Timestamps (native only, owner 2026-10-19: "Grok bot is so clean")

All three change drawing only; what Hermes sends and stores is untouched.

- **One Line** (Tool Call Style `line`): a reply's thoughts and steps (run tools, file edits) gather into one tool row,
  id `<message>|line`, placed above the reply's first row. Cards (delegate, image, clarify) stay in place, and a run
  holding `clarify` stays its own row. Words: while the reply works on a step, that step in the present tense
  ("Thinking" for a thought); once it writes or is done, "Worked for 42s · 5 steps" when the time is known (this
  device's turn time, else the steps' own durations when every step has one), otherwise the run summary of all its
  steps ("Explored 2 files, ran 3 commands"); thoughts only → the thought title. Glyph: a ticked circle when done.
  Failed steps show "N Failed" in red at the trailing end. Tap opens the thought (when reasoning is shown) above every
  step; a lone step with no thought opens its step sheet directly. After Reply › Hide clears the line with the steps.
- **Joined words** (every style): a reply's text parts with only silent things between them (a silent tool such as
  `todo`, a thought, words that are only hidden thinking) are one bubble, the parts separated by a blank line. Words the
  bot wrote before going back to work (any other step between them, drawn, folded into the line or hidden) are their own
  bubble, in every style (owner 2026-11-14, kwojt: a long turn's progress notes read as one long bubble). Adjacent
  bubbles of one reply stack as a run (2 pt apart, the name on the first, tail and time on the last); the One Line line
  stays one, above the first.
- **Fewer Timestamps**: a day line only when the local date changes (no 30-minute-gap lines), and run times only on the
  bot's bubbles, not yours.

## 11. Card tools drawn in place

### 11.1 Dispatch and payload

Per tool part (`V:components/assistant-ui/thread/message-parts.tsx:118-161`): todo tools → nothing (failed → failed
step, spec 03 §8.10); successful `react_to_message` → nothing; `delegate_task`, `image_generate` → their card
(below); `clarify` → the questions stream's rows (§11.4); `manage_catalog`, `manage_connections` → the generic step (§14); file edits → the M1 step row (Rows) / its
bubble line (Bubbles) with the diff in its sheet; everything else → the style's run row/bubble.
"Settled without a result" (state not running and `card == nil` — e.g. sealed "Result unavailable" after Stop) sends
every card to the generic step (`message-parts.tsx:41-44`).

`ToolCard` (bounded; built by `ToolCards.swift` from args + result at hydration and at `tool.complete`):
```swift
nonisolated enum ToolCard: Hashable, Sendable {
    case delegate(goals: [String], results: [DelegateResult]?, dispatchedGoals: [String]?)  // ≤ 16 goals × 300 chars
    case image(path: String, aspect: String?, pixelWidth: Int?, pixelHeight: Int?)
}
nonisolated struct DelegateResult: Hashable, Sendable { var status: String; var summary: String?; var model: String?; var durationSeconds: Double? }
```
Running calls have no `card`; the cell builds the live look from args (`argsText`, already ≤ 4 KB) and the store.

### 11.2 `delegate_task` — the subagent card (`V:components/assistant-ui/tool/delegate.tsx`, `delegate-model.ts`)

- Rows (`delegate-model.ts:35-101`): goals = `args.tasks[i].goal` (else "Task N"), or `args.goal`; else the dispatched
  `result.goals`; else one "Delegated task" per result. Per index: a result entry → status `""`/`ok`/`completed` →
  done, anything else → failed; summary → its one activity line; `model`; `duration_seconds`. No result yet → running;
  a background dispatch (`result.status == "dispatched"`) → **parked**.
- **Live overlay** (`delegate-model.ts:121-158`): match the chat's live subagents to rows — first by
  `delegate-tool:<tool_id>:<index>` id, then by goal (whitespace-normalised, case-insensitive), then by task index only
  when both sides have the same count; a match takes the child's status, activity stream, model, duration, child
  session id.
- **Layout** (phone: `R:src/phone-fe-convo.css:235-242`): full message column width, 8 pt above and below; one
  rounded rect per row (radius 18, 0.5 pt separator-colour border, no fill), 12 pt side padding, 12 pt top/bottom;
  line 1: 14 pt status glyph · goal (14 pt, label, **one line**, truncated) · meta "<model> · <duration>"
  (label-2; the model id as sent — or `displayModelName` once the model-menu stream ports it,
  `V:lib/model-status-label.ts:205-209`; duration only when not live, `formatDurationSeconds`: under 1 s "Nms", under
  10 s one decimal "4.2s", under 60 s "42s", then "Xm Ys" / "Xm", "Xh Ym" / "Xh",
  `V:components/assistant-ui/tool/fallback-model/format.ts:140-167`) · live elapsed timer (trailing, tabular) ·
  a small agent glyph (`person.2.circle`, 10 pt, label-3); line 2 (20 pt indent): the newest activity line, label-2,
  one line, shimmering while live (`delegate.tsx:63-149`). Status glyph: live → breathe spinner (label-3); failed or
  interrupted → `exclamationmark.circle.fill` red; parked → a 6 pt label-3 dot; done → `checkmark.circle.fill` green.
- **Ticker**: when a new activity line arrives the old one slides up and out while the new one slides in, 0.2 s, in a
  one-line window (no height change); Reduce Motion: swap (`M:native-glass-chip-spinner.md:23` — the window must clip
  to one line).
- Failed outright (`isError`) or settled without a result → the generic step (`message-parts.tsx:65-78`).
- **DECISION:** rows are not tappable this round (the web opens the child's session in a watch window; §14 item 3).

### 11.3 `image_generate`

- Running: a frame at the hinted aspect (`args.aspect_ratio`: `landscape` 16:9 (default), `square` 1:1, `portrait` 9:16)
  at the bubble max width, radius 18, fill-4, an animated placeholder (a slow shimmer), VoiceOver "Rendering image"
  (`V:components/chat/generated-image-result.tsx:14-110`; `V:i18n/en.ts:5369`).
- Done: the image from `result.host_image` (else `result.image`) loaded with `MediaLoader` (spec 03 §6.6:
  `GET /api/fs/download?path=&profile=&session_id=`, ImageIO thumbnail at display size × scale, off the main thread,
  never in the transcript cache), fades in over 0.2 s inside the frame. At completion the frame takes the aspect of
  `result.pixel_size` "WxH" when present (one size change, no animation, like stream growth), so loading the bytes
  never changes its height afterwards (`V:lib/generated-images.ts:71-80`); tap → `MediaViewer.present` (Save there).
- Result `success == false` or no path → the failed generic step; a load failure of a good path collapses to the
  link row "Open image: <file name>" (`en.ts:5585`) that retries on tap.

### 11.4 `clarify`

Drawn entirely by the questions stream (`1x-questions.md`: the note while asked, the sent answers, then the settled
Q&A card from `result.responses`, `V:components/assistant-ui/clarify/settled.tsx:14-54`). This stream's only rules: a
`clarify` part is a card — it splits runs like the other cards (`V:components/assistant-ui/tool/fallback.tsx:800-823`),
it is never a step block (Hide never folds it, In Header never hides it, Bubbles never turns it into a line). In
the In Header Steps list it is one row like any other call ("❓ Asking").

### 11.5 File edits

Unchanged rows (spec 06 §3.2.1 — "Editing app.ts" / "Edited app.ts", no +/− counts). Their sheet shows the coloured
diff (§12). Diff source order: live `tool.complete.inline_diff` → history `display_metadata.tool_result_metadata.inline_diff`
→ `result.inline_diff` → `result.diff` (spec 03 §8.9). The demo gateway exercises the `result.inline_diff` fallback.

---

## 12. Step sheet completeness

Today: title "Step", heading = the step title, blocks Command/Input, Error, Output, Error output, Exit code, Changes
(plain text), Duration; text cut at 20,000 characters (`N:App/Chat/ChatSheets.swift:158-197`). Make it match
`R:src/ui-chat/trail-details.tsx` and `R:src/ui-chat/trail-model.ts:87-103`:

1. **Title**: "Terminal" for `terminal` / `execute_code`; else the step title ("Edited app.ts", "Searched “kv cache”",
   "Ran 1 command"…). **Subtitle**: for a file edit, the full path when it differs from the title, then " · <meta>";
   else the meta ("Exit 2", "Failed") (`trail-details.tsx:63-70`).
2. **Sections in order** (`trail-model.ts:89-103`): Command (terminal: the command, else the input) **or** Input
   (non-file, non-empty, not `{}`); then Output + Error output (stdout/stderr) **or** Output / Error (the detail; skipped
   for a file edit that has a diff); then Exit code (terminal, non-zero). Keep the native Duration block last.
3. **Diff** (file edit with a diff ≤ 20,000 characters): a coloured panel first — clean per spec 03 §8.9 "Diff text →
   lines" (strip ANSI and a leading `┊ review diff` line; drop the header zone before the first `@@`; added `+` lines
   on green 12 %, removed `-` on red 12 %, context plain; the marker character dropped), monospace footnote, no wrap,
   horizontal scroll, radius 14, elevated cell colour. Over 20,000 characters → a "Changes" section of plain text paged.
4. **Paging**: every section over 20,000 characters shows one page with "Previous", "N of M", "Next" (44 pt text
   buttons) (`trail-details.tsx:7-19`).
5. **Server output**: a step whose row carries `display_payload_ref` (plugin route) opens with the sheet at once and an
   "Output" section reading "Loading output…", then the first `content/preview` page (20,000 code points); pages
   navigate by the server's `offset`/`next_offset`; a failed page keeps the current one and says "Couldn’t load this
   page. Tap to retry."; a 404 / gone session → "Output is no longer available for this session."; no plugin →
   "Paged output is unavailable on this gateway. Copy retrieves the complete output." (`trail-details.tsx:21-48`).
   **DECISION:** open the sheet immediately with a loading block instead of the web's "Opening…" row text.
6. **Copy** (footer, as the error-details sheet): copies the diff + every section; for a `display_payload_ref` step it
   fetches `…/content` first (8 MiB cap; 413 → copy what is shown and say "Output too large to copy in full").
7. **Cache copy**: when the detail is the transcript cache's 1 KB head (`ToolDetail.isCacheCopy`,
   `N:HermesKit/Chat/ChatMeta.swift:21-25`) and no fresh page has replaced it, add a footnote "Showing the start. The
   rest loads when the chat finishes opening." and refresh the open sheet in place when the fresh detail arrives.
8. Opened from In Header's Steps sheet → pushed in that sheet (§10.4); from a row / bubble line → its own sheet.

---

## 13. Tool Calls settings screen

`App/Settings/ToolCallsSettingsView.swift`, a SwiftUI `Form` (inset grouped) in a `UIHostingController`, title
"Tool Calls" (the web keeps these two rows in Settings › Appearance › Chat Display, `R:src/tool-calls-row.tsx:13-14`).
Registered at launch through `SettingsHooks.toolCallsScreen` and `SettingsHooks.toolCallsSummary` (`1x-settings.md`
§3.6); the summary is `"<Rows|Bubbles|In Header> · <Keep|Hide>"`, or just `"In Header"` (After Reply doesn't apply).
Until the Settings tab lands, a DEBUG entry in the chat's ⋯ menu may open it.

| Row | Control | Footer text (verbatim, `R:src/tool-calls-row.tsx:21-28`) |
|---|---|---|
| Tool Call Style | checkmark list Rows · One Line · Bubbles · In Header, each option with its own line under it (`ToolCallStyle.detail`; UX study 2026-10-21 #111: each option says what it does, instead of one paragraph for all four) | "Each tool call shows as a step. Tap a line of steps to list them." |
| Tool Calls After Reply (hidden while In Header) | segmented Keep · Hide | "Hide shows each step while the bot works, then clears them when it replies, like Telegram. A step that failed stays. To see a reply’s steps again, touch and hold it and choose Show Steps." |

- Each change plays a `selection` haptic (`R:src/tool-calls-row.tsx:20,26`) and applies to open chats immediately.
- Segment labels are never truncated (`M:segmented-labels-whole.md`): if Tool Calls After Reply's labels don't fit the
  row at the current text size, show the options as a checkmark list instead (one 44 pt row each) — always at
  accessibility sizes. Tool Call Style is a checkmark list at every size.
- Footer text wraps; rows get 12–14 pt vertical padding (system Form defaults satisfy this).

---

## 14. Left out of this round (and why)

1. **Background tasks chip** ("1 background task", `process.list` / process stop / auto-dismiss 4 s / 12 s,
   `V:store/composer-status.ts:84-140`): a separate data source with its own RPCs and fixture work; the shelf leaves its
   slot (§7.1). Next round, with the stale-work check's `agents.list` half.
2. **Loop and heartbeat** sections of `session.control`: no owner request; the snapshot keeps them raw.
3. **Opening a child's session** from the card or a row (web: a watch window, `V:app/chat/composer/status-stack/
   index.tsx:206-210`; `delegate.tsx:88`): native has no watch-window screen yet.
4. **Consent cards** (`manage_catalog`, `manage_connections`): hosted connectors are gated off for the owner
   (`M:composio-connectors.md:14`) and need `connection.request` server requests (the questions stream's area).
   Generic step.
5. **Clarify** (dock, note, sent answers, settled card): the questions stream (`1x-questions.md`;
   `M:phone-question-dock.md`). This stream only keeps it a card (§11.4).
6. **Inter-agent delivery notice** ("Messaging Ivy…"/"Messaged Ivy", `V:components/assistant-ui/thread/agent-delivery.tsx`):
   it belongs with bot-to-bot messaging and group rooms (needs agent avatar lookup and reply folding). Spec 03 §8.9
   listed it for M1; it was not built; carried to that stream.
7. **Legacy goal text** (`slash.exec "goal status"` and `status.update kind:"goal"` parsing, `V:store/goals.ts`): only
   for gateways without `session.control.read`; the owner's gateway has it (`H:tui_gateway/methods_session_control.py:234`).
8. **Spawn tree / Agents page, delegation pause, MoA events, the desktop's reasoning-collapsed preference, interface
   mode (simple/advanced)** — desktop-only surfaces; the phone runs the default advanced mode where subagents show
   (`V:store/interface-mode.ts:36-44`).
9. **"+A −R" counts on file rows** — dead code in build 238 (spec 06 §3.3 DECISION 16).

---

## 15. Stand-in gateways (this stream's ports: 9732–9734)

Never contact the owner's gateway. Start only on these ports, check each is free first
(`lsof -nP -iTCP:<port> -sTCP:LISTEN`), keep the PID, stop only what you started, never loop sign-ins.

### 15.1 Activity fixture — `N:scripts/fixtures/activity-gateway.py` on 9732 (primary)

A tracked, stdlib-only wrapper that loads `R:scripts/performance-fixture-gateway.py` (which loads build47 → action-voice
→ fake gateway; sign-in, streaming, Stop, paging all inherited, spec 05 §A4–A5). The reference listing is Appendix A;
it was run on 9732 while writing this spec (every RPC answer and error code in §2.2's table, the scripted turn, the stored tool rows with `display_metadata`, `todo_state` on resume and the media download came back as described; then it was stopped).
What it adds:

| Control / RPC | Behaviour |
|---|---|
| plan key `events` on `POST /__fixture/plan` | `{"plans":[{"events":[{"after":s,"type":"<event>","payload":{…}}…],"replyText"?,"holdAfter"?,"replyDelay"?}]}`: on the next `prompt.submit` emits `message.start`, then each event after `after` seconds (default 0.05; Stop cancels), then waits `holdAfter`, stores the reply row and emits `message.complete {text, status:"complete", row_id}`. `message.delta` texts accumulate into the reply; reasoning attaches to the next stored assistant row; each `tool.complete` stores an assistant `tool_calls` row + a `tool` row (with `display_metadata.tool_result_metadata.inline_diff` when the payload had `inline_diff`); `subagent.*` keep the roster; `todo.updated` becomes the resume `todo_state`. Without `events` the performance plan engine runs. |
| `POST /__fixture/event {"profile","type","payload"}` | emits one event now (and updates roster / todo_state / control like a scripted one) |
| `POST /__fixture/rows {"profile","rows":[…]}` | appends raw history rows (`role, content, tool_calls, tool_call_id, tool_name, reasoning, display_metadata, …`); `409` while a turn runs |
| `POST /__fixture/control {"profile","control":{goal…},"emit"?:true}` | sets the goal snapshot and emits `session.control.update` |
| `POST /__fixture/subagents {"subagents":[…],"delegations":[…]}` | replaces the roster without events (stale-check tests) |
| `POST /__fixture/tail {"subagent_id","text","truncated"}` | what `subagent.tail` returns |
| `POST /__fixture/config {"profile","display":{…}}` | merged into `GET /api/config`'s `display` (e.g. `{"show_reasoning":false,"tool_progress":"off"}`) |
| `POST /__fixture/fail {"method","code","message","times"}` | the next `times` calls (−1 = all) to that method answer that JSON-RPC error |
| `POST /__fixture/todo-state {"profile","todos","revision"}` | sets the resume `todo_state` |
| `GET /__fixture/activity` | `{calls, violations, steers, subagents, control, todo_state, display}` — every call to the seven §2.2 methods and every unknown-param rejection |
| env `HQN_ACTIVITY_MEDIA=<dir>` | `GET /api/fs/download?path=<dir>/…` serves that file (Range honoured, session cookie required, paths outside `<dir>` → 404). Needed because action-voice answers every unknown `/api/` GET with `{}` before the fake gateway's download runs (`R:scripts/action-voice-fixture-gateway.py:133-165`) — spec 05 §A2's "every fixture inherits `/api/fs/download`" is wrong for build47/performance. |
| `subagent.list / tail / steer / interrupt`, `delegation.status`, `session.control.read`, `session.control` | Hermes shapes and error codes (4000 unknown param, 4000 `subagent_id required`, 4002, 4004); `subagent.interrupt` emits `subagent.complete {status:"interrupted"}` 0.3 s later |

Gotcha it fixes: build47's websocket calls its own module-level `rpc` (`R:scripts/build47-fixture-gateway.py:69,94,166`),
so the performance fixture's `subagent.list` override on `voice.rpc` (`R:scripts/performance-fixture-gateway.py:61-68`)
never reaches the socket — over WS it always answers an empty roster (`R:scripts/action-voice-fixture-gateway.py:76`),
which is why the web team's chip "dropped every few seconds" (`M:jump-arrow-under-dock.md:17`;
`M:stuck-working-row.md:17`). The wrapper replaces `base.rpc` and routes error answers through `Client.send`.

Start / stop (scratch dir 0700; credentials never printed):
```sh
SCR=<0700 scratch dir>
lsof -nP -iTCP:9732 -sTCP:LISTEN && exit 1
HQN_ACTIVITY_MEDIA=$SCR/media \
  python3 /Users/me/Projects/hermes-hq-native/scripts/fixtures/activity-gateway.py \
  --port 9732 --credentials $SCR/activity.json > $SCR/activity.log 2>&1 &
echo $! > $SCR/activity.pid          # prints "Build 47 synthetic gateway on 127.0.0.1:9732"
# … tests …
kill $(cat $SCR/activity.pid)
```
Username `build47-fixture`; the password is in `$SCR/activity.json` (`--keep-credentials` reuses it across restarts;
a restart ends the app's session). Bots `default` ("Hermes") and `ivy`; stored ids `20260929_120000_aabbcc01/02`;
runtime id = first 8 hex of sha256(stored) (`R:scripts/action-voice-fixture-gateway.py:17,31-33`) — `5cc537d1` for
`default`. Events carry no `seq` (spec 05 §A4). For UI tests: `HQN_E2E_PORT=9732` and let `scripts/e2e.sh` take the
fixture path from a new `HQN_E2E_FIXTURE` variable (default the performance fixture); its port message should read
"9711-9719 or 9732-9734".

### 15.2 Plaid gateway on 9733 (realistic busy turn; untracked, may disappear)

```sh
cd /Users/me/Projects/hermes-ios/.claude/worktrees/plaid-stress-testing-5e35d8/.build/stability-round/tools/memory
DEMO_FILES=$SCR/plaid-files PLAID_HQ_LOG_DIR=$SCR/plaid-logs PLAID_SHORT=1 \
  python3 plaid_gateway.py --port 9733 --credentials $SCR/plaid.json > $SCR/plaid.log 2>&1 &
echo $! > $SCR/plaid.pid
curl -s 'http://127.0.0.1:9733/__plaid/start?minutes=3&subagents=1&browser=0&vault=0&tools=1'   # after opening Hermes's main chat
```
A 3-minute turn on the main chat with streamed reasoning, interleaved terminal / patch (with `inline_diff`) /
read_file / skill_view calls, and one `delegate_task` running **two** children with `subagent.*` progress
(`plaid_gateway.py:11-12,399-420,440-472`), `seq` and per-socket binding (spec 05 §A9). **Limit:** its `subagent.list`
answers an empty roster (no override), so the native reconcile correctly drops the chip at the first poll (≤ 5 s):
use Plaid for the delegate card, the live ticker, Bubbles/In Header under load and the fold — not for the chip.
No `session.interrupt`.

### 15.3 Demo gateway on 9734 (rich history; untracked)

```sh
DEMO_FILES=$SCR/demo-files DEMO_TOOL_SECONDS=1 \
  python3 /Users/me/Projects/hermes-ios-release178/.build/demo/demo-gateway.py \
  --port 9734 --credentials $SCR/demo.json > $SCR/demo.log 2>&1 &
echo $! > $SCR/demo.pid
```
9 bots; the Deploys transcript has reasoning, a `write_file` whose diff is in `result.inline_diff` (fallback path),
`web_search` / `browser_navigate` / `search_files` / `terminal` runs (`demo-gateway.py:55-80`); a send streams
reasoning → `terminal npm test` → text (`:222-238`). Its `/api/config` says `display.show_reasoning: false`
(`:387-388`), so it is also the **reasoning-off** check. No Stop, no roster, one page.

---

## 16. Acceptance checks

Unit (Swift Testing, `scripts/build.sh test`):
1. `ToolLine`: every case of `R:src/ui-chat/tool-line.test.ts:5-30`.
2. Run wording unchanged (spec 06 §3.2 tests still green); `stepsState` cases of `R:src/ui-chat/tool-calls-setting.test.ts:21-33`.
3. Subagent rules: id fallback; create only on spawn_requested/start; status mapping incl. fail-closed complete; terminal
   freeze; retired ids; stream cap 24 + dedupe; `formatTool("read_file","CHANGELOG.md") == "Read File(\"CHANGELOG.md\")"`;
   compact 220; timeout summary; prune at `message.start`; clear at Stop; reconcile keeps terminal + listed, seeds
   `last_tool`, adds failed delegations; delegate fallback rows and their removal on the first native event.
4. Todo rules: parse variants; tree order with dangling/cyclic parents; watermark; merge patch; 4 s linger (injected
   clock); resume running vs idle; turn-end drop of an active list; retained list; Stop clears all.
5. Control parse: a valid snapshot; a missing contract key → nil; label strings for every state incl. blocked and
   done ("Goal done · 5 turns", "Goal active · Turn 3/20", "Goal paused · Turn 3").
6. Delegate card model: rows from args/result/dispatched; overlay by id, goal, then index with equal counts.
7. Diff cleanup: the spec 03 §8.9 example yields one removed + one added line; header zone and ANSI stripped.
8. Provider-wait filter: "⏳ waiting on provider…" kept, "(｡•́︿•̀｡) pondering…" dropped.
9. Reasoning timing: deltas at t0..t0+7.4 then a tool → "Thought for 7s"; 0.4 s → "Thought briefly"; history → "Thought".

Against the activity fixture on 9732 (UI tests or scripted simulator runs on simulator "HQ Native"
`00CC6911-5CB1-458A-AEAE-DE5A5CB4F81A`; read `GET /__fixture/activity` after each):
10. **Strict params**: after the whole suite, `violations == []`.
11. **Subagent chip**: plan with `subagent.spawn_requested` + `start` + 6 `subagent.tool` events 2 s apart: the chip
    "1 subagent" appears within one frame of the event's delivery; open it: one row with the goal, the newest activity
    line and a ticking timer; after `subagent.complete` the chip is gone. Second child → "2 subagents".
12. **Poll backoff**: one `subagent.start` event, then nothing for 60 s: ≤ 5 `subagent.list` calls in that minute
    (hydrate + polls at ~5, 15, 35 s); then add a second child with `/__fixture/subagents` (both records): the first
    poll that returns it (≤ 30 s later) is followed by the next one 5 s after (`R:src/subagent-poll-backoff.test.ts:17-33`).
    Before any child is live and after the last one ends: no polls at all.
13. **Tail backoff**: open the detail with an unchanging tail for 60 s → ≤ 8 `subagent.tail` calls; change the text →
    it shows within 17 s; close the detail → no further calls.
14. **Steer / Stop**: steer "Only open issues" → field clears, "Queued for the next checkpoint", `steers[-1].queued`;
    whitespace-only text → Send disabled, no call; Stop → "Stop requested", the row ends with `subagent.complete`
    interrupted ~0.3 s later; Stop on an unknown id (`/__fixture/subagents` emptied first) → "The subagent did not
    accept the request".
15. **Stale claim**: open Hermes's chat once (binds it), go back to Bots, start a child with `/__fixture/event`
    (`subagent.start`): the Hermes row says Working…; background the app, `/__fixture/subagents {"subagents":[]}`,
    return: about 1.5 s later one `delegation.status` call (params exactly `{"profile":"default"}`) and the row stops
    saying Working…. With the app active and the claim still standing, the same read repeats every 30 s.
16. **Tasks**: `todo.updated` rev 1 (in_progress + pending) → "Tasks 0/2" opened with spinner row and ring row; rev 3
    all completed → "Tasks 2/2", gone 4 s later, then (turn ended) "Previous tasks 2/2" folded; an older rev 2 after rev 3
    changes nothing; `/__fixture/todo-state` with an active list (rev 5) then reopen the chat while idle → no Tasks
    chip, "Previous tasks 0/2" folded.
17. **Goal**: `/__fixture/control` with an active goal → "Goal active · Turn 3/20"; open → title, reason, criteria;
    Pause → `session.control {action:"goal.pause", args:{}}` and the chip reads "Goal paused · Turn 3/20"; Resume
    while idle → a `prompt.submit` with `display_kind:"hidden"` (check `GET /__fixture/state` rpc log) and **no** user
    bubble; Add Criterion "Publish" → `args:{"text":"Publish"}`; Remove 2 → `args:{"index":2}` after the confirm;
    Clear Goal → chip gone. `/__fixture/fail` `session.control.read` −32601 on a fresh connection → no chip and no
    further reads; `/__fixture/fail` 5031 → nothing shown.
18. **No jump**: scroll 2 screens up, then make a chip appear and disappear (event + complete): the first visible row's
    y moves 0 pt (±0.5) in every frame (`ChatPerfProbe` per-frame sample). At the newest end the newest row's bottom
    stays the M1 content gap above the shelf's top in every frame of the animation. The jump button stays tappable beside the
    chips (tap scrolls to the end).
19. **Reasoning**: plan reasoning 3 s then text → live "Thinking" → "Thought for 3s"; `/__fixture/config
    {"display":{"show_reasoning":false}}` + reopen → no thought rows.
20. **Fallback notice**: `status.update {kind:"fallback", text:"⚠ Model fallback: switched to fixture-2"}` → one notice
    row with that text.
21. **Bubbles**: style Bubbles; an `events` plan with 10 `terminal` start/complete pairs and no text between them →
    one bot bubble, "⋯ 3 earlier steps" + 7 lines, Shell
    blocks with 2-line clamp; tap a line → the step sheet titled "Terminal"; a failed call line red with "Failed".
22. **Hide fold**: style Rows + Hide; an `events` plan with 4 tool calls, then reply text: steps show while running; at `message.complete` they
    fade (200 ms) and are removed in one update; no visible row changes height in any frame; the reply does not move
    at the newest end. Reopen the chat → steps hidden with no motion. Long-press → Show Steps → steps back; Hide Steps
    → fold again. A turn whose last tool failed with no text after it keeps its steps.
23. **In Header**: style In Header; during a plan with `terminal {command:"npm test"}` running for 5 s the status line
    reads "💻 npm test" with "›"; tap → Steps sheet listing the turn's calls live (spinner on the running one); tap a row
    → the step pushed in the same sheet; no tool or thought rows in the transcript; the delegate card still shows.
24. **Delegate card**: plan from Appendix B → two rows; live row's ticker shows the newest activity, one line only; after
    the result: green check row "fixture-model · 4.2s" with "Found 14 changes", red row "9.0s" with "Timed out after 9s". A
    `{"status":"dispatched","goals":[…]}` result → grey-dot rows, no spinner.
25. **File-edit diff**: tap "Edited app.py" → coloured diff panel (1 removed, 1 added line); a 25,000-character diff →
    "Changes" with "1 of 2" paging. Reopen the chat (history) → the same diff from `display_metadata`.
26. **Image card**: `/__fixture/rows` with an `image_generate` call + result `{"success":true,"host_image":"/fixture/x.png","pixel_size":"1024x1024"}`
    and no `HQN_ACTIVITY_MEDIA` → frame at 1:1, then the "Open image: x.png" link row; with the fixture started with
    `HQN_ACTIVITY_MEDIA=$SCR/media` and the result's `host_image` = `$SCR/media/x.png` → the image fades in and the
    row height never changes while it loads.
27. **Clarify stays a card**: with a history clarify call between two terminal calls, Rows shows run · card · run,
    and neither Hide (after the reply) nor In Header removes the clarify rows the questions stream draws.
28. **Tool Calls screen**: switching styles rebuilds the open chat without moving the first visible row; After Reply row
    hidden under In Header; at AX5 the options are checkmark rows; labels never truncated.

On Plaid (9733) and demo (9734), filmed on the simulator and checked frame by frame (`M:subagent-card-glass.md:20`):
29. Plaid busy turn in each style: no flashes or doubled text in the delegate card's ticker; the fold at the end is
    one fade + slide; 0 dropped frames in the probe while the ticker runs (60 Hz simulator).
30. Demo Deploys chat: Bubbles shows "📖 Reading CHANGELOG.md", "💻 terminal" + Shell "git log v2.3..HEAD --oneline",
    "✍️ Writing release-notes.md"; no thought rows (its config turns reasoning off); the write_file sheet shows the
    diff from `result.inline_diff`.

Build checks: 0 warnings; `scripts/build.sh test` green 3 runs in a row; fixtures you started are stopped
(`lsof` shows nothing on 9732–9734).

---

## 17. UNKNOWNs and DECISIONs

1. **DECISION** (§7.2): all opened shelf cards on native glass; the Steer field stays glass while typing.
2. **DECISION** (§7.3): tapping a chip keeps the keyboard up (the vendor blurs the composer).
3. **DECISION** (§10.4, §12): Steps sheet pushes the step detail inside the same sheet; the step sheet opens at once
   with a loading block instead of the "Opening…" row text.
4. **DECISION** (§11.2): delegate rows not tappable until a watch screen exists.
5. **DECISION** (§6.1, §14.7): no legacy goal-text parsing; a gateway without `session.control.read` shows no goal chip.
6. **DECISION** (§6.4): the busy-goal message drops "(Stop button or Esc)" → "stop the current reply first to continue".
7. **UNKNOWN**: whether the owner wants Previous tasks on the phone at all (it is shipped web behaviour, never
   discussed). Build it; mention it in the build note.
8. **UNKNOWN**: real-Hermes timing of `session.control.update` after a goal judge relative to `message.complete`
   (`H:tui_gateway/methods_session_control.py:219-223` says it comes after the post-turn hooks); the after-turn
   `session.control.read` covers either order.
9. **UNKNOWN**: the exact pixel look of the vendor's breathe spinner at 14 pt in SF; compare a quick render with the
   web's before shipping (owner prefers small early renders, `M:bot-head-redraw-proposal.md`).
10. Supersedes spec 06 §11 ("Tool Call Style Bubbles and In Header, and After Reply: Hide", "subagent and goal chips"
    out of scope for M1) and the M1 decisions of spec 03 §8.9 for delegate/image/clarify drawing (now specified here).
11. **Correction to spec 05 §A2**: build47/performance (and every action-voice-based fixture) answer
    `GET /api/fs/download` with `{}`; only the bare fake gateway serves files. The activity fixture serves them itself
    (§15.1, `HQN_ACTIVITY_MEDIA`).
12. **DECISION** (spec 04 §1.4 applied here): every §2.2 call names `profile`, the launch profile's bot included; the
    web omits it for its primary profile. Allowed by every contract above; the fixture records violations if not.
13. **Contract changes** (§3.4) are for integration to land: `ToolCall.card`, `ChatMessage.reasoningSeconds`,
    `ChatActivityProviding`. Until then a module may keep them in side maps, as M1 did with `MessageMeta`.
14. **DECISION** (review round, §8.3): the fallback notice's id is `local-fallback-switch-<seconds>` — the web's
    `fallback-switch-<seconds>` with M1's client-side `local-` mark (`ChatMeta.isLocal`), so history merges keep it and
    the cache drops it. A notice after the reply doesn't take Copy away: the action row stays under the reply.
15. **DECISION** (review round, §2.3, §9.4): the display flags are cached 60 s per profile (not 5 minutes, not every
    open) and marked stale on app return; the read and its parse run off the main actor.
16. **DECISION** (review round, §10.5): when a reply that was working turns done on screen, its action row (Copy) waits
    for the fold and arrives in the fold's one removal, so the reply moves once, in the slide (a separate arrival glided
    the reply up and the slide then pushed it back). The fold never runs while a stream glide or the send lift moves
    the rows; it waits for them (≤ 0.6 s).
17. **DECISION** (review round, §7.4): a chip that arrives starts at its place in the stack and rides the shelf's top
    with the rows while it fades and scales in; a chip that leaves fades where it stands on screen.
18. **Tool arguments** (review round, §11.1): `ToolCall.argsText` is the arguments with each string clipped (1,024
    characters, then less until the whole is ≤ 4 KB) and arrays capped at 16 — valid JSON that keeps every key — not
    the serialized JSON clipped at 4 KB; text cut short anyway (the cache's 512-byte copy) is read by a tolerant scan
    (`HermesKit/Activity/ToolArgs.swift`).

---

## Appendix A — `scripts/fixtures/activity-gateway.py` (reference listing; verified on 9732)

```python
#!/usr/bin/env python3
"""HQ Native activity fixture (docs/spec/1x-activity.md §15): REF's performance fixture plus what the
activity stream needs. Scripted turn events (plan key "events"), Hermes-strict params for the subagent and
session-control methods (unknown key -> 4000, as tui_gateway/contracts/base.py), a live roster behind
subagent.list / delegation.status, subagent.tail / steer / interrupt, session.control.read / session.control
with a goal, todo_state on resume, seeded tool-call history (/__fixture/rows) and /api/config display
overrides. Loopback only; every value is invented; nothing is forwarded anywhere.
"""
import importlib.util, json, os, pathlib, threading, time
from urllib.parse import urlparse, parse_qs

REF = pathlib.Path('/Users/me/Projects/hermes-hq-native-ref238/scripts')
_spec = importlib.util.spec_from_file_location('hqn_activity_perf', REF / 'performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)
base = perf.base            # the build47 module: emit, append, owner, MESSAGES, RUNNING, CANCEL, LOCK, voice
LOCK = base.LOCK

SNAPSHOT_FIELDS = ('subagent_id', 'parent_id', 'depth', 'goal', 'delegation_id', 'model', 'started_at', 'status',
                   'tool_count', 'last_tool', 'accepting_steer')
SESSION = {'session_id', 'profile'}
ALLOWED = {
    'subagent.list': SESSION, 'subagent.tail': SESSION | {'subagent_id'}, 'subagent.interrupt': SESSION | {'subagent_id'},
    'subagent.steer': SESSION | {'subagent_id', 'text'}, 'delegation.status': {'profile'},
    'session.control.read': SESSION, 'session.control': SESSION | {'action', 'args'},
}
ACTIONS = {'goal.pause', 'goal.resume', 'goal.clear', 'goal.unwait', 'loop.pause', 'loop.resume', 'loop.stop',
           'subgoal.add', 'subgoal.remove', 'subgoal.clear', 'heartbeat.pause', 'heartbeat.resume', 'heartbeat.clear'}
EMPTY_CONTROL = {'goal': None, 'loop': None, 'heartbeat': None, 'revision': '', 'updated_at': 0}

SUBAGENTS = {}      # subagent_id -> roster record (only SNAPSHOT_FIELDS go on the wire)
FAILED = []         # subagent.list "delegations"
TAILS = {}          # subagent_id -> {"text", "truncated"}
CONTROL = {p: dict(EMPTY_CONTROL) for p in base.voice.SIDS}
TODO_STATE = {}     # profile -> {"todos", "revision"} (attached to session.resume / activate answers)
DISPLAY = {}        # profile -> /api/config "display" overrides
FAIL = {}           # method -> {"code", "message", "times"} (times -1 = always)
CALLS, VIOLATIONS, STEERS = [], [], []


def err(code, message):
    return {'__error__': {'code': code, 'message': message}}


# build47 answers every RPC as {"result": …} (its websocket turns ValueError into -32001). A result carrying
# __error__ goes out as a JSON-RPC error with Hermes's own code instead.
_send = base.Client.send
def _send_with_errors(self, value):
    result = value.get('result') if isinstance(value, dict) else None
    if isinstance(result, dict) and '__error__' in result:
        value = {'jsonrpc': '2.0', 'id': value.get('id'), 'error': result['__error__']}
    return _send(self, value)
base.Client.send = _send_with_errors


def note_subagent(kind, payload):
    sid = payload.get('subagent_id')
    if not sid:
        return
    with LOCK:
        if kind == 'subagent.complete':
            SUBAGENTS.pop(sid, None)
            return
        record = SUBAGENTS.setdefault(sid, {'subagent_id': sid, 'started_at': time.time(), 'accepting_steer': True})
        for key in SNAPSHOT_FIELDS:
            if key in payload and key not in ('subagent_id', 'started_at'):
                record[key] = payload[key]
        if payload.get('tool_name'):
            record['last_tool'] = payload['tool_name']
        record['status'] = payload.get('status') or ('queued' if kind == 'subagent.spawn_requested' else 'running')


def note_event(profile, kind, payload):
    if kind.startswith('subagent.'):
        note_subagent(kind, payload)
    elif kind == 'todo.updated':
        TODO_STATE[profile] = {'todos': payload.get('todos', []), 'revision': payload.get('revision', 0)}
    elif kind == 'session.control.update' and isinstance(payload.get('control'), dict):
        CONTROL[profile] = payload['control']


def persist_tool(profile, payload, start, reasoning):
    args = payload.get('args') or (start or {}).get('args') or {}
    tool_id = payload.get('tool_id') or f'fixture-tool-{time.time_ns()}'
    result = payload.get('result')
    with LOCK:
        base.append(profile, 'assistant', '')
        row = base.MESSAGES[profile][-1]
        row['tool_calls'] = [{'id': tool_id, 'type': 'function', 'function': {'name': payload.get('name'), 'arguments': json.dumps(args)}}]
        if reasoning:
            row['reasoning'] = reasoning
        base.append(profile, 'tool', result if isinstance(result, str) else json.dumps(result))
        tool = base.MESSAGES[profile][-1]
        tool.update(tool_call_id=tool_id, tool_name=payload.get('name'))
        if payload.get('inline_diff'):
            tool['display_metadata'] = {'tool_result_metadata': {'inline_diff': payload['inline_diff']}}


_perf_stream = base.stream
def stream(profile, plan):
    events = plan.get('events')
    if not isinstance(events, list):
        return _perf_stream(profile, plan)
    cancel = base.CANCEL[profile]
    if cancel.wait(float(plan.get('replyDelay', .1))):
        return
    base.emit(profile, 'message.start')
    text, reasoning, starts = '', '', {}
    for event in events:
        if cancel.wait(float(event.get('after', .05))):
            return
        kind, payload = event['type'], dict(event.get('payload') or {})
        if kind == 'message.delta':
            text += payload.get('text', '')
        elif kind == 'reasoning.delta':
            reasoning += payload.get('text', '')
        elif kind == 'reasoning.available':
            reasoning = payload.get('text', '')
        elif kind == 'tool.start':
            starts[payload.get('tool_id')] = payload
        elif kind == 'tool.complete':
            persist_tool(profile, payload, starts.get(payload.get('tool_id')), reasoning)
            reasoning = ''
        note_event(profile, kind, payload)
        base.emit(profile, kind, payload)
    if cancel.wait(float(plan.get('holdAfter', 0))):
        return
    final = plan.get('replyText', text)
    with LOCK:
        row = base.append(profile, 'assistant', final)
        if reasoning:
            base.MESSAGES[profile][-1]['reasoning'] = reasoning
    base.RUNNING[profile] = False
    base.emit(profile, 'message.complete', {'text': final, 'status': 'complete', 'row_id': row})
base.stream = stream


def control_action(profile, params):
    action = (params.get('action') or '').strip() if isinstance(params.get('action'), str) else ''
    if not action:
        return err(4004, 'action is required')
    if action not in ACTIONS:
        return err(4004, f'unknown action: {action}')
    args = params.get('args', {})
    if not isinstance(args, dict):
        return err(4004, 'args must be an object')
    if set(args) - {'text', 'index'}:
        with LOCK:
            VIOLATIONS.append({'method': 'session.control', 'unknown': sorted(set(args) - {'text', 'index'})})
        return err(4000, 'unknown args')
    control = json.loads(json.dumps(CONTROL[profile]))
    goal = control.get('goal')
    dispatch = {'type': 'exec', 'output': None, 'notice': None, 'message': None, 'display': None}
    if not action.startswith(('goal.', 'subgoal.')):
        return err(4004, f'No active {action.split(".")[0]}')
    if not goal:
        return err(4004, 'No active goal')
    if action == 'goal.pause':
        goal.update(status='paused', paused_reason='Paused from the app')
        dispatch['output'] = '⏸ Goal paused: ' + goal['title']
    elif action == 'goal.resume':
        goal.update(status='active', paused_reason=None)
        dispatch = {'type': 'send', 'output': None, 'notice': '▶ Goal resumed: ' + goal['title'] +
                    '\nContinuing now — taking the next step.',
                    'message': '[Continue working toward the standing goal: ' + goal['title'] + ']', 'display': '/goal resume'}
    elif action == 'goal.unwait':
        goal['wait_barrier'] = None
    elif action == 'goal.clear':
        control['goal'] = None
    elif action == 'subgoal.add':
        text = args.get('text')
        if not isinstance(text, str) or not text.strip():
            return err(4004, 'subgoal text is required')
        goal['subgoals'].append(text.strip())
    elif action == 'subgoal.remove':
        index = args.get('index')
        if type(index) is not int:
            return err(4004, 'subgoal index must be an integer')
        if index < 1 or index > len(goal['subgoals']):
            return err(4004, 'subgoal index out of range')
        del goal['subgoals'][index - 1]
    elif action == 'subgoal.clear':
        goal['subgoals'] = []
    control['revision'] = f'fixture-{time.time_ns()}'
    control['updated_at'] = time.time()
    with LOCK:
        CONTROL[profile] = control
    base.emit(profile, 'session.control.update', {'control': control})
    return {'control': control, 'dispatch': dispatch}


def finish_interrupt(profile, record):
    time.sleep(.3)
    payload = {'goal': record.get('goal') or '', 'task_count': 1, 'task_index': 0, 'subagent_id': record['subagent_id'],
               'status': 'interrupted', 'summary': 'Interrupted from the app'}
    note_subagent('subagent.complete', payload)
    base.emit(profile, 'subagent.complete', payload)


_prev_rpc = base.rpc
def rpc(method, params):
    profile = base.owner(params)
    if method in ALLOWED:
        with LOCK:
            CALLS.append({'method': method, 'params': params, 'at': time.time()})
        extra = sorted(set(params) - ALLOWED[method])
        if extra:
            with LOCK:
                VIOLATIONS.append({'method': method, 'unknown': extra})
            return err(4000, 'unknown params: ' + ', '.join(extra))
        fail = FAIL.get(method)
        if fail and fail.get('times', 0) != 0:
            if fail['times'] > 0:
                fail['times'] -= 1
            return err(int(fail.get('code', 5000)), str(fail.get('message', 'fixture failure')))
        if method.startswith('subagent.') and method != 'subagent.list' and not str(params.get('subagent_id') or ''):
            return err(4000, 'subagent_id required')
    if method == 'subagent.list':
        with LOCK:
            return {'subagents': [{k: r.get(k) for k in SNAPSHOT_FIELDS} for r in SUBAGENTS.values()], 'delegations': list(FAILED)}
    if method == 'delegation.status':
        with LOCK:
            active = [{'subagent_id': r['subagent_id'], 'goal': r.get('goal'), 'status': r.get('status', 'running'),
                       'started_at': r.get('started_at'), 'owner_agent_session_id': 'fixture-agent'} for r in SUBAGENTS.values()]
        return {'active': active, 'paused': False, 'max_spawn_depth': 1, 'max_concurrent_children': 3}
    if method == 'subagent.tail':
        tail = TAILS.get(params['subagent_id'])
        return {'subagent_id': params['subagent_id'], 'available': tail is not None,
                'text': (tail or {}).get('text', ''), 'truncated': bool((tail or {}).get('truncated'))}
    if method == 'subagent.steer':
        text = (params.get('text') or '').strip()
        if not text:
            return err(4002, 'text is required')
        record = SUBAGENTS.get(params['subagent_id'])
        queued = bool(record) and record.get('accepting_steer', True) is not False
        with LOCK:
            STEERS.append({'subagent_id': params['subagent_id'], 'text': text, 'queued': queued})
        return {'status': 'queued' if queued else 'rejected', 'subagent_id': params['subagent_id'], 'text': text}
    if method == 'subagent.interrupt':
        record = SUBAGENTS.get(params['subagent_id'])
        if record:
            threading.Thread(target=finish_interrupt, args=(profile, dict(record)), daemon=True).start()
        return {'found': bool(record), 'subagent_id': params['subagent_id']}
    if method == 'session.control.read':
        return {'control': CONTROL[profile]}
    if method == 'session.control':
        return control_action(profile, params)
    answer = _prev_rpc(method, params)
    if method in ('session.resume', 'session.activate') and profile in TODO_STATE and isinstance(answer, dict):
        answer = {**answer, 'todo_state': TODO_STATE[profile]}
    return answer
base.rpc = rpc


_perf_handler = base.handler
def handler(gateway):
    # HQN_ACTIVITY_MEDIA=<dir>: /api/fs/download serves files under it (the fake gateway's --media-dir), e.g. a
    # generated image whose host_image path is <dir>/x.png.
    if os.environ.get('HQN_ACTIVITY_MEDIA'):
        gateway.media = os.environ['HQN_ACTIVITY_MEDIA']
    parent = _perf_handler(gateway)

    class Handler(parent):
        def body(self):
            raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
            return json.loads(raw or b'{}')

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == '/api/config':
                profile = parse_qs(parsed.query).get('profile', ['default'])[0]
                return self.reply(200, {'model': 'fixture-model', 'provider': 'fixture', 'stt': {'enabled': False},
                                        'display': {'resume_last_session': True, **DISPLAY.get(profile, {})}})
            # action-voice answers every other /api/ GET with {} first, so the fake gateway's download never runs.
            if parsed.path == '/api/fs/download' and gateway.media:
                return self.media() if self.session() else self.reply(401, {'detail': 'unauthorized'})
            if parsed.path == '/__fixture/activity':
                with LOCK:
                    return self.reply(200, {'calls': list(CALLS), 'violations': list(VIOLATIONS), 'steers': list(STEERS),
                                            'subagents': dict(SUBAGENTS), 'control': CONTROL, 'todo_state': TODO_STATE,
                                            'display': DISPLAY})
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path == '/__fixture/event':
                body = self.body()
                profile = body.get('profile', 'default')
                if profile not in base.MESSAGES or not isinstance(body.get('type'), str):
                    return self.reply(400, {'detail': 'profile and type'})
                payload = body.get('payload') or {}
                note_event(profile, body['type'], payload)
                base.emit(profile, body['type'], payload)
                return self.reply(200, {'ok': True})
            if path == '/__fixture/rows':
                body = self.body()
                profile = body.get('profile', 'default')
                if profile not in base.MESSAGES:
                    return self.reply(404, {'detail': 'Unknown synthetic profile'})
                with LOCK:
                    if base.RUNNING[profile]:
                        return self.reply(409, {'detail': 'Finish the synthetic turn first'})
                    ids = []
                    for raw in body.get('rows', []):
                        ids.append(base.append(profile, raw.get('role', 'assistant'), raw.get('content', '')))
                        base.MESSAGES[profile][-1].update({k: v for k, v in raw.items() if k not in ('role', 'content', 'row_id', 'timestamp')})
                return self.reply(200, {'ok': True, 'row_ids': ids})
            if path == '/__fixture/control':
                body = self.body()
                profile = body.get('profile', 'default')
                control = {**EMPTY_CONTROL, **(body.get('control') or {})}
                control['revision'] = control.get('revision') or f'fixture-{time.time_ns()}'
                with LOCK:
                    CONTROL[profile] = control
                if body.get('emit', True):
                    base.emit(profile, 'session.control.update', {'control': control})
                return self.reply(200, {'ok': True})
            if path == '/__fixture/subagents':
                body = self.body()
                with LOCK:
                    SUBAGENTS.clear()
                    for record in body.get('subagents', []):
                        SUBAGENTS[record['subagent_id']] = {'started_at': time.time(), 'status': 'running', **record}
                    FAILED[:] = body.get('delegations', [])
                return self.reply(200, {'ok': True})
            if path == '/__fixture/tail':
                body = self.body()
                TAILS[body['subagent_id']] = {'text': body.get('text', ''), 'truncated': bool(body.get('truncated'))}
                return self.reply(200, {'ok': True})
            if path == '/__fixture/config':
                body = self.body()
                DISPLAY[body.get('profile', 'default')] = body.get('display') or {}
                return self.reply(200, {'ok': True})
            if path == '/__fixture/fail':
                body = self.body()
                FAIL[body['method']] = {'code': body.get('code', 5000), 'message': body.get('message', 'fixture failure'),
                                        'times': int(body.get('times', 1))}
                return self.reply(200, {'ok': True})
            if path == '/__fixture/todo-state':
                body = self.body()
                TODO_STATE[body.get('profile', 'default')] = {'todos': body.get('todos', []), 'revision': body.get('revision', 1)}
                return self.reply(200, {'ok': True})
            return super().do_POST()
    return Handler
base.handler = handler


if __name__ == '__main__':
    base.main()
```

## Appendix B — a scripted delegation turn (for checks 11, 22–25)

```sh
curl -s -X POST http://127.0.0.1:9732/__fixture/plan -H 'Content-Type: application/json' -d '{"plans":[{"holdAfter":0.5,"events":[
 {"type":"reasoning.delta","payload":{"text":"Split the work: changelog and open issues."}},
 {"after":2.4,"type":"tool.start","payload":{"tool_id":"call_d1","name":"delegate_task","args":{"tasks":[{"goal":"Read the changelog"},{"goal":"Check open issues"}]}}},
 {"type":"subagent.spawn_requested","payload":{"goal":"Read the changelog","task_count":2,"task_index":0,"subagent_id":"sa_1","model":"fixture-model"}},
 {"type":"subagent.start","payload":{"goal":"Read the changelog","task_count":2,"task_index":0,"subagent_id":"sa_1","status":"running"}},
 {"type":"subagent.start","payload":{"goal":"Check open issues","task_count":2,"task_index":1,"subagent_id":"sa_2","status":"running"}},
 {"after":1.5,"type":"subagent.tool","payload":{"goal":"Read the changelog","task_count":2,"task_index":0,"subagent_id":"sa_1","tool_name":"read_file","tool_preview":"CHANGELOG.md","text":"CHANGELOG.md"}},
 {"after":1.5,"type":"todo.updated","payload":{"todos":[{"id":"1","content":"Read the changelog","status":"in_progress"},{"id":"2","content":"Write the notes","status":"pending"}],"revision":1}},
 {"after":1.5,"type":"tool.start","payload":{"tool_id":"call_p1","name":"patch","args":{"path":"/app/src/app.py"}}},
 {"after":0.5,"type":"tool.complete","payload":{"tool_id":"call_p1","name":"patch","args":{"path":"/app/src/app.py"},"result":{"success":true},"inline_diff":"┊ review diff\na/src/app.py → b/src/app.py\n@@ -1 +1 @@\n-print(\"before\")\n+print(\"after\")","duration_s":0.4}},
 {"after":2,"type":"subagent.complete","payload":{"goal":"Read the changelog","task_count":2,"task_index":0,"subagent_id":"sa_1","status":"completed","summary":"Found 14 changes","duration_seconds":4.2}},
 {"after":1,"type":"subagent.complete","payload":{"goal":"Check open issues","task_count":2,"task_index":1,"subagent_id":"sa_2","status":"timeout","duration_seconds":9}},
 {"type":"tool.complete","payload":{"tool_id":"call_d1","name":"delegate_task","args":{"tasks":[{"goal":"Read the changelog"},{"goal":"Check open issues"}]},"result":{"results":[{"task_index":0,"status":"completed","summary":"Found 14 changes","model":"fixture-model","duration_seconds":4.2},{"task_index":1,"status":"timeout","summary":"Timed out after 9s","duration_seconds":9}]},"duration_s":9.5}},
 {"type":"todo.updated","payload":{"todos":[{"id":"1","content":"Read the changelog","status":"completed"},{"id":"2","content":"Write the notes","status":"completed"}],"revision":2}},
 {"after":0.3,"type":"message.delta","payload":{"text":"Done: 14 changes, notes written; the issues check timed out."}}]}]}'
```
Then send any message in Hermes's chat. Expected on screen, in order: "Thinking" → "Thought for 2s"; the delegate card
with two live rows and both chips ("Tasks 0/2", "2 subagents"); "Edited app.py"; the first row turns green, the second
red; chips leave ("Tasks 2/2" lingers 4 s, then "Previous tasks 2/2" once idle); the reply.
