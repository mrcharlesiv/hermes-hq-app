# 3x — Composer, commands and queue extras (m9 stream "composer")

Status: implementation spec for the m9 "composer" stream, **revision 2 (2026-10-13)**. First written 2026-10-12 from
the web app at release-build240, the Hermes gateway source and the native code on `m9/train` (`beee9f7`). Revision 2
re-read it against `m9/train` at `bd25418` (merged into this branch as `e276703`), which now carries thirteen other
streams: **read §0.2 first**, it says what they already built for these rows and what changed here because of it.
§0.3 ranks the rows by how close each is to done. Nothing here was guessed from memory of the UI.
Where native differs from the web app on purpose the line is marked **⚑ DECISION** with the reason. Things that could
not be proven from source are marked **UNKNOWN** with what the builder must check first.

Rows covered (17, listed verbatim in `docs/briefs/m9/composer-rows.md`): parity-240 L385, L386, L388, L390, L391, L392,
L422, L439, L440, L441, L446, L448, L459, L461, L463, L464, L465, plus the Link… / Folder… / Prompt Snippets… / More
items of the + menu (talk's row L389).

No row in this stream needs a relay, plug-in or real-gateway change, so there is no `docs/owner-todo/composer.md`. If a
builder finds one, write that file then and keep the app behaviour graceful as described in the row's "old gateway"
state.

---

## 0. Sources, notation, ground rules

| Prefix | Path |
|---|---|
| `S/` | `/Users/me/Projects/hermes-hq-native-ref240/src/` (Hermes HQ phone code, build 240) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref240/build/` (build-time gates that rewrite vendored code) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref240/vendor/hermes/apps/desktop/src/` (vendored Hermes renderer) |
| `H/` | `/Users/me/.hermes/hermes-agent/` (gateway source, READ ONLY) |
| `NAT/` | this worktree (`/Users/me/Projects/hermes-hq-native-wt/m9-composer/`) |
| `MEM/` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` (owner notes, READ ONLY) |

Ground rules (from earlier specs; each one bites here):

- **Params are strict.** Every JSON-RPC params model is `extra="forbid"`; one unknown key answers `4000 "invalid params
  for <method>: …"`. Each call below lists its complete key set. `profile` is sent only when the chat's bot is not the
  default one, exactly as `LiveChatSession` already does for `prompt.submit`.
- **`-32601` (method not found) means an older gateway.** Each feature says what the phone shows then. It is never a
  red error.
- **Never a control that does nothing.** A button whose call cannot work in the current state is hidden, not greyed
  with no explanation (exceptions are named).
- **Wording.** Every user-facing string below is exact, including the curly apostrophe (’) and the ellipsis character
  (…). The word "Dispatch" appears nowhere a person can see or hear it. (`command.dispatch` is a wire method name and
  never shown.)
- **Glass.** New floating surfaces (drawers, chips) use the system glass the chat already uses (`.glassEffect` /
  `UIGlassEffect`, or system sheets, alerts and menus). No hand-painted blur.
- **Rows that wrap** get 12-14 pt vertical padding. Sheets pushed as pages use the small title; nothing here is a tab
  root.
- **Haptics** go through the existing `Haptics` helper; the kinds named below are the web app's (`B/haptics-gates.ts`).

### 0.1 Stand-in gateways and ports

This stream owns ports **10030-10034** (builders) and **10035-10039** (stress tester), simulators **HQN-m9-composer**
and **HQN-m9-composer-s**. Never connect to a port you did not start.

| Port | Fixture | Start command (from the worktree root) |
|---|---|---|
| 10030 | **new** `scripts/fixtures/composer-gateway.py` (§18) | `python3 scripts/fixtures/composer-gateway.py --port 10030 --credentials build/fixtures/composer.json` |
| 10031 | `scripts/fixtures/activity-gateway.py` (goal, todos, subagents shelf) | `python3 scripts/fixtures/activity-gateway.py --port 10031 --credentials build/fixtures/composer-activity.json` |
| 10032 | `scripts/fixtures/questions-gateway.py` (approval cards) | `python3 scripts/fixtures/questions-gateway.py --port 10032 --credentials build/fixtures/composer-questions.json` |
| 10033 | `scripts/fixtures/menus-gateway.py` (catalog, slash.exec, model.options) | `python3 scripts/fixtures/menus-gateway.py --port 10033 --credentials build/fixtures/composer-menus.json` |
| 10034 | second `composer-gateway.py` (relaunch and two-account checks) | `python3 scripts/fixtures/composer-gateway.py --port 10034 --credentials build/fixtures/composer-b.json` |

Stress tester uses the same scripts on 10035-10039 with `build/fixtures/composer-s*.json`. The e2e wrapper is the new
`scripts/e2e-composer.sh [SIM_UDID] [RUNS]` (env `HQN_COMPOSER_PORT`, default 10030), modelled on `scripts/e2e-menus.sh`:
it starts the fixture, passes the credentials file as `TEST_RUNNER_HQN_UI_CREDENTIALS`, runs the `ComposerUITests`
class, and stops only the process it started (by PID).

Resolved in revision 2 (was UNKNOWN): all three reused fixtures take `--port N --credentials PATH`.
`menus-gateway.py:23` and `questions-gateway.py:11` say so in their headers; `activity-gateway.py:375` ends in the
ref238 performance fixture's own `base.main()`, which parses the same two flags (`scripts/e2e-activity.sh` starts it
that way).

### 0.2 Revision 2: what the merged train already built, and what changes here

Thirteen streams landed on `m9/train` after revision 1 (photoheads, presence, share, intents, screen, talk, sessions,
groups, offline, desktoplook, ipad, a11y, capabilities). Each line below was read in the merged code, not in a report.

| Came from | What is on the train now | What it changes in this spec |
|---|---|---|
| **ipad** (`docs/spec/3x-ipad.md` §4.10, D10) | A hardware keyboard's Return sends, ⇧Return and ⌥Return add a line, Return during marked text is left to the input method, ⌘Return is the menu item **"Send"**. Code: `ComposerTextView.pressesBegan` (`NAT/App/Chat/Attachments/ComposerTextView.swift:26-39`), the pure rule `ReturnKey.decide` (`NAT/HermesKit/Layout/KeyRules.swift:37-45`), `ComposerView.hardwareSend()` and `AppDelegate.hqSend` (`NAT/App/Root/KeyCommands.swift:371-374`). Works on iPhone with a paired keyboard too. | **§1 is rewritten** as a small addition to that code. Revision 1's `keyCommands` design is withdrawn: it would have registered Return twice. |
| **ipad** | Escape (and ⌘.) is one ladder for the whole app: `EscapeAction.decide` (`KeyRules.swift:8-33`) run by `AppDelegate.hqEscape` (`KeyCommands.swift:376-410`): alert → sheet → Find → recording → list search → question waiting (nothing) → reply running (**Stop**, rigid haptic, `composer.onStop`) → field focused (lowers the keyboard). The menu item reads **"Stop or Close"**. | **§3 is rewritten**: this stream adds two rungs (drawer, queued-message edit) and the checks; it does not add a second Escape handler. |
| **ipad** D12 | ☰ (the commands button) shows on iPad as well. | The slash drawer (§9) and ☰ coexist on iPad exactly as on iPhone. Every new surface must work in the two-pane layout: the drawer and the queue card keep to the readable column (`ComposerView.columnMargin`). |
| **talk** (`3x-talk.md` §5.1, §5.4, §8) | The primary circle has two more faces, `.talk` and `.stopDictation` (`ComposerView.choosePrimary`); the + menu has Voice Memo (slot 10) and Talk with <Bot> (slot 20); `ComposerPlusMenu.Slot` already orders `link 40, folder 50, snippets 60, more 70`; `ComposerView.insertDictation` / `dictationInsert` insert at the caret; the audio preview sheet takes `.gateway(path:profile:)`. | §4-§6 register into the existing slots (no menu surgery). §6's "insert before the caret" reuses the same caret arithmetic as `dictationInsert`, minus its leading space rule. Hardware Return and Escape must do nothing new while `.stopDictation` or the voice dock is showing (§1.2, §3.2). |
| **sessions** (`3x-sessions.md` §9.4) | `LostSends` (`NAT/HermesKit/Chat/LostSends.swift`): every message marked "Delivery unconfirmed" is kept on disk per chat (≤ 20, ≤ 2,000 characters), named on its Sessions row as **"Not Delivered:"**, and put back as a marked bubble when the chat opens (`restoreLostSends`). Cleared by `clearLostSend` when Check finds it. | **§17's UNKNOWN is resolved**: the marked bubble does survive a relaunch. Send Again, Edit and Delete must each call `clearLostSend`, or the Sessions row would keep saying "Not Delivered:" for a message that is gone (§17.3). "Never two stores." |
| **offline** (`3x-offline.md` §6.6, row L957) | `ActivityStore.setProcessClaims(runtimeId:profile:storedId:_:)`, `processClaims(runtimeId:)`, `onProcessClaimsChange`, `ProcessClaim {id, running}` and the stale check that drops claims the gateway no longer lists (`NAT/HermesKit/Activity/ActivityStore.swift:81-200`, `StaleWork.swift`). Nothing real feeds it yet: only the debug switch `-HQDebugProcessClaim`. Offline's row L957 is recorded **partial, waiting for this stream's L461**. | **§14 gains a required hook**: `BackgroundTasksStore` writes its list into `setProcessClaims` after every refresh, and listens to `onProcessClaimsChange` so a claim the stale check dropped leaves the capsule too. When that is on the train L957 can close. |
| **offline** | One reconnect per drop (`joinsRunningReconnect`, `ChatReconnectState`), tail recheck. | The queue lock (§17.4) must not be held across a reconnect: `drainQueueHead` and `steerQueued` release it when the socket drops and the row stays queued. Stress 19.3 covers it. |
| **presence** | `LiveChatSession.sentTitles`: a request shown under a short title is stored as its long prompt; `send` maps a title back to its prompt. | Queue **Edit** (§15.5) and unconfirmed **Edit** / **Copy** (§17.3) use the bubble's shown words (the title); sending them again goes through `send(_:display:)` unchanged, which already restores the prompt. Do not copy the hidden prompt. |
| **groups** (`3x-groups.md` D5) | A group room's composer is text only: no +, no memo, no slash commands (`GroupRoomSession`). | Neither drawer opens in a room, and the + items of §4-§6 are not registered there. A typed `/…` in a room is sent as plain text, as today. |
| **a11y / desktoplook** | Fonts come from `HQFont.preferred(_:)`, colours from `HQPalette` / `ChatPalette`, motion checks from `HQMotion.reduced`; `scripts/check-a11y`-style greps fail raw `.preferredFont` and unguarded `UIView.animate`. Views re-colour on `ThemeGenerationTrait`. | Every new view in this spec uses those three helpers (never `.preferredFont(forTextStyle:)`, never `UIAccessibility.isReduceMotionEnabled`, never a literal system grouped colour), and registers for `ThemeGenerationTrait` where it caches a colour. |

File paths corrected from revision 1: the field is `App/Chat/Attachments/ComposerTextView.swift`; the cells are
`App/Chat/Cells/ChatCells.swift`; `chatCellCheckDelivery` is now at `ChatViewController.swift:2381`.

### 0.3 Closest first: how near each row is to done

"Close" = how little is left to build before the row can be seen working. This is also the proposed order for
shipping one feature per build (it replaces the build order of revision 1; §20 is updated to match).

| # | Row | Already on the train | Left to build | Size |
|---|---|---|---|---|
| 1 | **L385** hardware Enter sends; ⌘Enter queues | Return, ⇧/⌥Return, marked text, ⌘Return "Send"; a send while a reply runs queues (ipad, unit and UI tested there) | Empty-field Return on a waiting queue (§1.2); this stream's own proof run | hours |
| 2 | **L388** Stop, rigid haptic, Esc stops | One Stop, rigid haptic, Escape ladder with Stop and the question guard | Two rungs that depend on later rows (drawer, queue edit); proof run that Esc pauses the queue | hours |
| 3 | **L464** Queue Paused, with Resume | The queue parks after Stop and after a refusal, survives relaunch (`QueueStash`) | The header words and one Resume button (§16) | half a day |
| 4 | **L448** model list failure, tries twice | Sheet with a failure state and Try Again | The quiet second try and the exact words (§12) | half a day |
| 5 | **L386** autocorrect, fresh keyboard, empty-line cleanup | A default `UITextView` (autocorrect, capitals, spell-check on by default) | Pin the settings, the all-line-breaks cleanup, the last-word and fresh-keyboard checks (one real unknown, §2.2) | half a day |
| 6 | **L459** goal and loop load failure is quiet | Goal read is quiet and retried; `session.control.read` decoding | Loop and heartbeat chips' data, `QuietLog`, retry after a turn (§13) | 1 day |
| 7 | **L422** Jump to approval | Jump-to-latest button, approval cards (questions stream) | The capsule and the scroll target (§7) | 1 day |
| 8 | **L465** Delivery Unconfirmed actions | The mark, **Check**, `LostSends` (kept across relaunch, named on the Sessions row) | Send Again, Edit, Copy, Delete, stuck-queue notice, the shared lock (§17) | 1-2 days |
| 9 | **L463** queue row: Send Now steers, plus ⋯ | Queue card, Send Now (stop then send), Remove | Steer through `session.redirect`, ⋯ menu, Edit strip (§15) | 2 days |
| 10 | **L390** Link… | + menu slot `link`, attachment tray | The alert, `LinkText`, the `@url:` chip (§4) | 1 day |
| 11 | **L392** Prompt Snippets (and More) | + menu slot `snippets`, caret-insert arithmetic | The sheet and its data (§6) | 1 day |
| 12 | **L439** typed slash commands | `SlashRunner`, `SlashCatalog`, output rows; several commands answer "isn't available" | The per-command table of §8, `/compress`, `/btw`, `/bg` | 2 days |
| 13 | **L461** shelf folds one by one; background-task capsule | The shelf, its reserved slot, `ActivityStore` process-claim hooks | `BackgroundTasksStore`, chip, card, Stop (§14) | 2 days |
| 14 | **L446** Switch provider recovery | Error card, model sheet, `error_surface` decoding in part | `ErrorRecovery.plan`, the capsules (§11) | 2 days |
| 15 | **L391** Folder… | + menu slot `folder`, `ChatWorkspace.list` | The picker, New Folder, the `@folder:` chip (§5) | 2-3 days |
| 16 | **L440** slash drawer | Catalog and runner | The drawer surface, trigger model, `complete.slash`, keyboard handling (§9) | 3 days |
| 17 | **L441** @ drawer | Nothing beyond what L440 builds | `complete.path`, bots by name, shares the drawer (§10) | 2 days after L440 |

Rows 1 and 2 are the only ones that are plausibly "done" today; they still need this stream's own run against a
stand-in gateway before `composer-rows.md` may say so (the iPad stream's tests are evidence, not this stream's proof).

---

## 1.---

## 1. Hardware Enter sends; ⌘Enter queues (L385)

### 1.1 Web app

- `B/fe-convo-gates.ts:7,52-58` (FE-037): the on-screen Return key makes a new line (`enterKeyHint: 'enter'`). With a
  hardware keyboard and no on-screen keyboard, Enter sends. The soft-return test is "coarse pointer, no ⌘/Ctrl, and
  (on-screen keyboard open OR no hardware keyboard)".
- `V/app/chat/composer/index.tsx:979-999`: ⌘Enter / Ctrl+Enter calls `queueDraft`, which only acts while a reply is
  running (`V/app/chat/composer/hooks/use-composer-submit.ts:360-367`).
- `V/…/index.tsx:1014-1018`: plain Enter with an **empty** field while idle and a non-empty queue sends the next queued
  message. `1029-1037`: plain Enter with an empty field while busy and something queued runs Send Now on the head row.
- Shift+Enter is always a new line.

### 1.2 Native design (revision 2: an addition to what the iPad stream built)

Already on the train and **kept as is** (§0.2): `ComposerTextView.pressesBegan` reads the hardware Return (the
on-screen keyboard never produces a press with a `key`, so its Return keeps adding a line with no extra test) and asks
`ReturnKey.decide(hardware:shift:option:marked:empty:)` → `.send | .newline | .swallow | .pass`. `.send` calls
`onHardwareReturn`, which taps the primary button only while it is **Send** (never Stop, Talk or Stop Dictation).
⌘Return is the Edit-menu item **"Send"** (`KeyCommands.editItems`) → `AppDelegate.hqSend` → `composer.hardwareSend()`.

| Key | Today | After this row |
|---|---|---|
| Return, text or attachments in the field | sends; while a reply runs the send joins the queue | same (2026-10-28: plain text while a reply runs goes into it, `04 §6.2` Native) |
| ⇧Return, ⌥Return | new line | same |
| Return during marked text | the input method takes it | same |
| ⌘Return | same as Return (title "Send") | same (2026-10-28: while a reply runs it queues instead, the desktop's ⌘Enter) |
| Return, **empty** field | swallowed (nothing) | the empty-field rule below |
| Return with a drawer row highlighted | (no drawer yet) | picks the row (§9.5); wired when the drawer lands |

**⚑ DECISION (kept from the iPad stream's D10, and the same call revision 1 made)**: on the web ⌘Enter queues only
while a reply is running and does nothing while idle. Native ⌘Return does what Return does: while a reply runs that
**is** "queue" (a send while busy joins the queue), and while idle it sends, because a key that silently does nothing
reads as broken. The menu title stays "Send" (one item cannot be titled two ways, and "Send" is true in both states).

**The empty-field rule** (web `V/…/index.tsx:1014-1018, 1029-1037`). New pure function beside `ReturnKey`:

```swift
nonisolated enum EmptyReturn: Equatable, Sendable {
    case nothing, sendNext, sendNowHead
    /// `waiting`: visible queue rows. `paused`: the queue is parked (§16). `canAct`: the queue lock is free (§17.4)
    /// and the primary circle is not Talk-in-progress / Stop Dictation / hidden by a memo.
    static func decide(running: Bool, waiting: Int, paused: Bool, canAct: Bool) -> EmptyReturn {
        guard canAct, waiting > 0, !paused else { return .nothing }
        return running ? .sendNowHead : .sendNext
    }
}
```

`ComposerTextView` gains `var onHardwareReturnEmpty: (() -> Void)?`, called from the existing `.swallow` branch (the
key is still swallowed). `ChatViewController` sets it: `.sendNext` → `session.drainQueueHead()`; `.sendNowHead` → the
head row's **Send Now** action (§15.3: steer when it can, else stop and send); `.nothing` → nothing, no beep, no
haptic. A paused queue never drains from the keyboard: it needs Resume (§16), as on the web.

Until §15 lands, `.sendNowHead` calls today's `sendQueuedNow(head.id)` (stop, then send); §15 swaps the call. This lets
L385 ship first.

Not on a room (`GroupRoomSession` has no queue; `waiting` is 0). Not while the voice dock stands in the composer's
place (the field is not first responder then, so no Return reaches it).

### 1.3 Wire

None new. Send is `prompt.submit` (`docs/spec/04-send-stream-stop.md`); the queue is local.

### 1.4 States and wording

No new visible text. The menu titles are the iPad stream's: **"Send"** (⌘Return) and **"Stop or Close"** (Escape,
⌘.). Send haptic and Stop haptic are unchanged.

### 1.5 Fixture

`composer-gateway.py` on 10030, mode `slow` (`curl -s localhost:10030/__composer/mode -d '{"reply":"slow"}'`) to hold a
reply open for the busy cases.

### 1.6 Acceptance

Simulator with **I/O › Keyboard › Connect Hardware Keyboard** on. Finding recorded by the iPad stream
(`3x-ipad.md:767-769`): XCUITest delivers a hardware Return only as `typeKey("\n", modifierFlags:)`;
`XCUIKeyboardKey.return` / `.enter` / `.escape` do not arrive as those keys. Press `"\n"` for Return and ⌘. for
Escape. Unit: `EmptyReturnTests` (every combination of the four inputs); the existing `ReturnKey` tests stay green.

1. Type "hello", press Return → bubble "hello" appears, field empty. No line break was inserted.
2. Type "a", ⇧Return, "b", Return → one bubble with two lines.
3. During a slow reply: type "next", ⌘Return → queue card shows "next"; field empty; no second bubble yet.
4. During a slow reply with "next" queued and an empty field: Return → "next" is steered or sent per §15.3 (before
   §15 lands: the reply stops and "next" sends; the fixture sees one `session.interrupt` then one `prompt.submit`).
4a. Idle with "next" queued (queue not paused; reach it by queueing during a reply that then ends while the fixture
   holds the drain with `submit=refuse` once, or by relaunching with a stashed, un-paused queue) and an empty field:
   Return → "next" is sent once.
5. Idle, queue paused with one row, empty field: Return → nothing (paused queue needs Resume, §16).
6. On-screen keyboard (hardware keyboard disconnected): Return inserts a line break and never sends.
7. Japanese Romaji keyboard, hardware: Return while a candidate is underlined confirms the candidate and does not send.

---

## 2. Autocorrect, spell-check, capitalisation; fresh keyboard after a send; empty-line cleanup (L386)

### 2.1 Web app

- `B/autocorrect-gates.ts:1-13`: the field has autocorrect, sentence capitalisation and spell-check on; Return goes
  through the keyboard so the pending correction is applied and the next line starts with a capital.
- `S/phone-focus.ts:76-98` `refreshPhoneKeyboard`: after a send the focus hops through a stand-in field and back two
  frames later, so the keyboard starts fresh (shift armed, new suggestions) without lowering.
- Empty-line cleanup: a field holding only one leftover line break counts as blank (`MEM/return-line-break`).
- `MEM/autocorrect-composer`: on the web the last word before tapping Send is not corrected and that could not be
  fixed there. The owner banned private keyboard API (`UIKeyboardImpl`).

### 2.2 Native design

In `ComposerView` set, explicitly (so a later refactor cannot drop them):

```swift
textView.autocorrectionType = .yes
textView.spellCheckingType = .yes
textView.autocapitalizationType = .sentences
textView.smartQuotesType = .default
textView.smartDashesType = .default
textView.smartInsertDeleteType = .default
textView.inlinePredictionType = .default
textView.keyboardType = .default
textView.returnKeyType = .default      // reads "return"
```

**Last word before Send.** In `submit()`, before reading `textView.text`, ask the keyboard to commit a pending
correction using public API only:

```swift
textView.inputDelegate?.selectionWillChange(textView)
textView.inputDelegate?.selectionDidChange(textView)
```

**UNKNOWN**: whether this commits the pending correction on iOS 26/27. The builder checks with acceptance 2 below. If
it does not, try `textView.unmarkText()` then the pair above; if neither works, leave it (the web does not correct the
last word either) and record that in the rows file. Never resign first responder to force it (the keyboard would
drop) and never use private API.

**Fresh keyboard after a send.** After clearing the field (`textView.text = ""`), the shift key must be armed and the
suggestion bar must not show completions of the sent text. If setting `text` alone does not do it, wrap the clear in
`inputDelegate?.textWillChange(textView)` / `textDidChange(textView)`; last resort `textView.reloadInputViews()` (which
may flicker the bar, so only if the first two fail). The keyboard must not lower at any point.

**Empty-line cleanup.**

- A field holding only spaces, tabs and line breaks is blank: the placeholder shows, Send is disabled, the height is
  one line. Implemented in `textChanged()`: if `text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` and
  `text.contains("\n")` → set `text = ""` (this is the "one leftover Return" case; plain spaces are left so typing a
  space does not fight the user).
- On send, trailing whitespace and line breaks are trimmed; leading line breaks are trimmed; inner blank lines stay.

**⚑ DECISION**: the web only blanks exactly one leftover `"\n"`; native blanks any all-line-break field, because on
native the Return key is the keyboard's own and several stray Returns are as meaningless as one.

### 2.3 Wire

None.

### 2.4 Acceptance

1. Type "teh " → becomes "the " (autocorrect on). Type "hello. how" → "How" is capitalised.
2. Type "helo" (no trailing space) and tap Send → the bubble reads "hello" if the UNKNOWN above resolves, else "helo";
   record which.
3. Send a message → shift is armed (next typed letter is a capital) and the keyboard never lowered (the composer's
   bottom edge did not move more than the field's own height change).
4. Tap Return three times in an empty field → field is empty, placeholder shows, Send disabled.
5. Type "a", Return, Return, send → bubble is "a" with no trailing blank lines.
6. A misspelt word gets the red dotted underline (spell-check on).

Fixture: any (10030).

---

## 3. Stop: one Stop in the composer, rigid haptic; Esc stops (L388)

### 3.1 Web app

- `B/haptics-gates.ts:16-25`: Stop plays `impact.rigid`; "Esc on a keyboard is the same Stop".
- `V/app/chat/composer/index.tsx:1046-1062`: Esc while editing a queued message cancels the edit; otherwise, if a
  reply is running and the chat is not waiting for an answer, Stop (which pauses the queue).
- `V/app/chat/composer/hooks/use-composer-esc-cancel.ts`: Esc with the chat (not a text field) focused also stops; not
  while an approval / question / password card is waiting, and not while an overlay is open.

### 3.2 Native design (revision 2: two rungs added to the iPad stream's ladder)

Already on the train and **kept as is** (§0.2): one Stop in the composer with the rigid haptic; Escape and ⌘. run
`EscapeAction.decide(state)` from the app delegate, so they work whatever has focus (field focused or not), and they
do not auto-repeat. Its order today: alert → presented sheet → Find → recording → list search → question waiting
(nothing) → reply running (Stop) → field focused (lower the keyboard) → nothing. A second Escape for the same reply
within 2 s does not interrupt twice.

This stream adds two rungs and two state fields (defaults `false`, so the iPad stream's unit tests are untouched):

```swift
// EscapeAction: new cases
case closeDrawer        // the slash or @ drawer is open: close it, the text stays (§9, §10)
case cancelQueueEdit    // a queued message is being edited in the field: Cancel (§15.5)
// State: new fields
var drawer = false, editingQueued = false
// decide(): after `find`, before `recording`
if state.drawer { return .closeDrawer }
if state.editingQueued { return .cancelQueueEdit }
```

`KeyCommands.escapeState` fills them from the chat on show (`chat.drawer?.isOpen`, `chat.composer.isEditingQueued`);
`hqEscape` gains the two cases. Each lands with the row that owns the surface (the drawer rung with L440, the edit
rung with L463); L388 itself does not wait for them.

What Escape → Stop must do, checked here because the queue rows depend on it: it calls `composer.onStop`, the same
closure as the Stop button, so the queue parks and reads "Queue Paused" (§16) and the fixture sees exactly one
`session.interrupt`.

**⚑ DECISION (revision 2)**: revision 1 said "Esc never dismisses the keyboard". The iPad stream decided the last
rung lowers the keyboard when nothing else applies (its `.resignField`), as Messages on iPad does; that ships and is
kept. Escape still never clears the draft and never answers or dismisses a question.

While a dictation is recording the circle is Stop Dictation and `state.running` may be false: Escape then falls to the
field rung. Dictation's own cancel is its ✕ (talk stream); this stream does not add an Escape rung for it.

### 3.3 Wire

`session.interrupt {session_id}` (existing).

### 3.4 Acceptance

1. Slow reply running, hardware Esc (⌘. in a UI test, §1.6) with the field focused → reply stops, one
   `session.interrupt` at the fixture, queue (if any) reads "Queue Paused" once §16 is in (before that: the queue
   card's paused header of today).
2. Same with the field not focused (tap the transcript first) → stops.
3. Approval card waiting: Esc does nothing (the reply is not stopped, the card stays).
4. Drawer open and a reply running: first Esc closes the drawer (text kept), second Esc stops. (With L440.)
5. Editing a queued message while a reply runs: first Esc cancels the edit (the row is back in the queue with its old
   words), second Esc stops. (With L463.)
6. Idle, field focused: Esc lowers the keyboard, the draft is kept. Idle, field not focused: nothing.
7. Unit: `EscapeAction.decide` for the two new rungs in every position relative to their neighbours (a sheet over an
   open drawer closes the sheet; Find open with a drawer closes Find first).

Fixture: 10030 mode `slow`; approval case on 10032.

---

## 4. Link… dialog (L390)

### 4.1 Web app

- + menu item **Link…**, symbol `link` (`S/ui-chat/plus-menu.ts:15-40`).
- Dialog: title **"Add Link"**, description **"The page is fetched and included with your next message."**
  (`B/stress-b-gates.ts:84-89`), placeholder `https://example.com/post`, hint "Include the full URL, e.g. https://…"
  when the text is not a link, buttons Cancel / Attach (Attach off until the text is a link)
  (`V/app/chat/composer/url-dialog.tsx`, `hooks/use-composer-url-dialog.ts`).
- Phone gates: the field is focused and its text selected on open (`B/fe-convo-gates.ts:269-271`, r1-48); **no
  `https://` needed** and the Return key reads **Go** (`B/fe-convo-gates.ts:460-465`, r3-14, `typedUrl` in
  `S/fe-convo-r3.ts:533-538`).
- Attach → `addContextRefAttachment('@url:' + formatRefValue(url), url)` (`V/app/chat/session-tile.tsx:336-339`,
  `V/app/chat/composer/hooks/use-composer-actions.ts:440-457`): a draft attachment of kind url, label = the URL.
  Success haptic.
- On send the ref lines go first: `[refs joined by "\n", text].filter(Boolean).join("\n\n")`
  (`V/app/session/hooks/use-prompt-actions/submit.ts:196-209`).
- `formatRefValue` (`V/components/assistant-ui/directive-text.tsx:151-167`): quote only when the value contains
  whitespace or one of ``()[]{}<>"'` ``; prefer backticks, else double quotes, else single quotes.

### 4.2 Native design

`ComposerPlusMenu.register(.link) { … }` adds **Link…** (`UIImage(systemName: "link")`). It presents a
`UIAlertController(.alert)`:

- title **"Add Link"**, message **"The page is fetched and included with your next message."**
- one text field: placeholder `https://example.com/post`, `keyboardType = .URL`, `returnKeyType = .go`,
  `autocapitalizationType = .none`, `autocorrectionType = .no`, `textContentType = .URL`,
  `clearButtonMode = .whileEditing`, accessibility id `link.field`.
- actions **Cancel** (`.cancel`) and **Attach** (preferred, id `link.attach`), Attach disabled until
  `LinkText.normalised(text)` is a link.
- When the field is non-empty and not a link, the alert's message changes to
  **"Include the full URL, e.g. https://…"**; it changes back when the text becomes a link or empty.
- Return (**Go**) with a valid link does Attach; with an invalid one does nothing.
- If the pasteboard has a URL (`UIPasteboard.general.hasURLs`, which does not trigger the paste banner) nothing is
  pre-filled. **⚑ DECISION**: reading the pasteboard to pre-fill would show the system "pasted from" banner; the
  field's own Paste is one tap.

`LinkText` (new, `HermesKit/Chat/LinkText.swift`, pure and unit-tested) ports `typedUrl` exactly:

```
t = text trimmed
if t is empty, or contains whitespace, or matches ^[a-z][a-z\d+.-]*://  (case-insensitive),
   or starts with mailto: tel: data: blob: file:           → return t
host = t up to the first of / ? #
if host matches ^(?:[a-z\d](?:[a-z\d-]*[a-z\d])?\.)+[a-z]{2,}(?::\d{1,5})?$   (case-insensitive)
   or is an IPv4 address with optional :port               → return "https://" + t
return t
isLink(x) = x matches ^https?://   (case-insensitive) and has at least one character after the slashes
```

Attach:

1. `DraftAttachment.Kind` gains `.link` and `.folder` (§5). A link draft has `name = url`, `localFile = ""`,
   `byteSize = 0`, `typeIdentifier = "public.url"`, upload state `.uploaded(path: url, folder: "")` (nothing to
   upload), and a new stored `refText: String?` = `"@url:" + RefValue.format(url)`.
   `RefValue.format` (new, pure) ports `formatRefValue`.
2. The same URL twice is one chip (id derived from the ref text, like the web's content-derived id).
3. The tray chip: `link` symbol, one line, middle-truncated URL without the scheme, ✕ to remove. VoiceOver label
   **"Link, <url>"**, remove button **"Remove link"**.
4. Success haptic (`notification.success`); focus returns to the composer field with the keyboard up.
5. `AttachmentSender` puts ref-text attachments first, one per line, then a blank line, then the typed text — the same
   join the web uses. A message can be links only (no typed text).
6. Queued and restored drafts keep link chips (`DraftAttachment` is `Codable`; the new field is optional so old
   stashes decode).

History: `Hydration` (`NAT/HermesKit/Chat/Hydration.swift:244-250`) treats leading `@file:` / `@folder:` lines as
attachments. Extend the same block to `@url:` lines → a link row (`link` symbol, the URL, tappable: opens in the
in-app Safari sheet the transcript already uses for links). Your own bubble shows the row above the text, never the
raw `@url:` line.

### 4.3 Wire

No call of its own. The ref rides `prompt.submit`:

```json
{"jsonrpc":"2.0","id":41,"method":"prompt.submit",
 "params":{"session_id":"s-1","text":"@url:https://example.com/post\n\nSummarise this"}}
```

### 4.4 States

| State | What shows |
|---|---|
| Open | alert, field focused, keyboard `.URL` with **Go**, Attach disabled |
| Typing "example.com/a" | Attach enabled (will attach `https://example.com/a`) |
| Typing "hello world" | message reads "Include the full URL, e.g. https://…", Attach disabled |
| Attached | chip in the tray, field focused |
| 9 attachments already | Link… still works (links are not uploads and do not count toward the upload cap) |
| Offline | works (nothing is fetched by the phone); the send itself follows the normal offline path |

### 4.5 Acceptance

1. + › Link… → alert titled "Add Link"; the keyboard's Return reads "go".
2. Type `example.com/post`, Go → chip "example.com/post"; send with text "hi" → fixture's last `prompt.submit` text is
   exactly `@url:https://example.com/post\n\nhi` (`GET /__composer/state` → `last_submit.text`).
3. Type `http://10.0.0.1:8080/x` → attached unchanged. Type `not a link` → Attach disabled, hint shown.
4. A URL containing `(`: ref is `` @url:`https://e.com/a(b)` `` (backticks).
5. Unit tests for `LinkText` and `RefValue` covering every branch above (at least 14 cases).
6. Reopen the chat: the sent bubble shows a link row and "hi", not the raw ref line.

Fixture: 10030.

---

## 5. Folder… attach from the gateway computer (L391)

### 5.1 Web app

- + menu item **Folder…**, subtitle **"From your computer"**, symbol `folder` (`S/ui-chat/plus-menu.ts:29`).
- `pickContextPaths('folder')` (`V/app/chat/composer/hooks/use-composer-actions.ts:459-485`) opens the remote folder
  picker titled **"Add Folder"** (`B/stress-b-gates.ts` B-14) starting at the chat's own folder (`chatOwnCwd`, r5-88:
  never another chat's folder); with none, the gateway default from `GET /api/fs/default-cwd`.
- Picker (`V/app/right-sidebar/files/remote-picker.tsx`): lists only folders of the current path via
  `GET /api/fs/list`; a ".." row goes up (disabled at `/`); footer **Show Hidden** / **Hide Hidden** (dot-folders
  hidden by default); **New folder** with a "Folder name" field, **Create folder**, errors "Enter a single folder name,
  without slashes." and "Could not create the folder (…)." (`V/i18n/en.ts:4811-4818`); **Select folder** picks the
  folder being shown. New folder calls `POST /api/files/mkdir {path}` (`V/lib/desktop-fs.ts:113-117`).
- The picked path becomes a draft attachment: kind folder, label = last path component, detail = the path relative to
  the chat folder (strip the `cwd/` prefix), ref text `@folder:<formatRefValue(rel)>`.

### 5.2 Native design

`ComposerPlusMenu.register(.folder) { … }` adds **Folder…** with subtitle **"From your computer"** (`folder` symbol).
Hidden in rooms' DMs? No: shown wherever the web shows it (all chats). It presents `FolderPickerViewController` in a
navigation controller as a sheet (`ChatSheet.wrap`, large detent, leading ✕, title **"Add Folder"**).

Layout (a plain inset-grouped `UITableView`, one level at a time, pushing a new page per folder so the system back
swipe and back button work):

- Navigation title: the current folder's name (small title); the root page shows **"Add Folder"**. A one-line
  secondary header under the bar shows the full path, middle-truncated, monospaced digits off, selectable.
- Rows: folders only, `folder` symbol, name, chevron. 12 pt vertical padding (names wrap to two lines, then truncate
  in the middle).
- First row when not at `/`: **"Enclosing Folder"** (`arrow.up` symbol) → pushes the parent (so the user can leave the
  chat folder upward; the back button only returns to pages already visited).
  **⚑ DECISION**: the web's ".." is not plain language; "Enclosing Folder" is Finder's own wording.
- Bottom toolbar (system, glass): left **Show Hidden** / **Hide Hidden** (toggles dot-folders; default hidden;
  remembered for the life of the sheet only); right **Select Folder** (prominent). Select Folder picks the folder
  whose page is showing.
- Trailing bar button `folder.badge.plus`, label **"New Folder"** → alert title **"New Folder"**, field placeholder
  **"Folder name"**, actions Cancel / **Create**. Invalid name (empty, `.`, `..`, contains `/` or `\`) → alert message
  **"Enter a single folder name, without slashes."** and Create stays disabled. On success push the new folder's page.
  On failure alert **"Couldn’t Create Folder"** with the gateway's reason in words (HTTP `detail`, ≤ 160 characters) or
  "Your gateway didn’t answer." and one **OK**.
  If the gateway answers 404/405 to `POST /api/files/mkdir` (older gateway), the New Folder button is removed for the
  rest of the sheet's life and the alert reads **"Couldn’t Create Folder"** / "This gateway can’t make folders from
  the phone."

States per page:

| State | What shows |
|---|---|
| Loading | centred spinner, **"Loading…"**; Select Folder enabled only after the first answer |
| Empty | **"No Folders Here"** secondary line "You can still choose this folder." |
| `error: "ENOENT"` / `"ENOTDIR"` | **"This Folder Isn’t There Any More"** + **Try Again**; Select Folder disabled |
| `error: "EACCES"` or HTTP 403 | **"Your Gateway Can’t Open This Folder"** + **Try Again**; Select Folder disabled |
| Transport failure / timeout (15 s) | **"Couldn’t Load This Folder"** secondary "The computer running Hermes didn’t answer in time." + **Try Again** |
| Other error text | **"Couldn’t Load This Folder"** secondary = the text (≤ 160 chars) + **Try Again** |
| Start folder missing (chat folder gone) | the picker opens at the gateway default folder instead, with no alert |

Start folder: the chat's own folder (the same value `WorkspacePage` uses; never another chat's). None → `GET
/api/fs/default-cwd`; if that fails → `/`.

Select Folder → dismiss, add a draft attachment `.folder`: `name` = last path component (or `/`), detail = the
relative path, `refText = "@folder:" + RefValue.format(rel)` where `rel` = the path with the chat folder prefix and
its slash stripped when it is inside the chat folder, else the absolute path; a path equal to the chat folder is `.`.
Chip: `folder` symbol, the name, ✕; VoiceOver **"Folder, <name>"**. Selection haptic on pick, success haptic on attach.
Same folder twice is one chip. Sending follows §4.2 step 5. History already draws `@folder:` rows
(`docs/spec/1x-attachments.md` §7.4).

### 5.3 Wire

```
GET /api/fs/default-cwd[?profile=<name>]            → {"cwd":"/Users/me/proj","branch":"main"}
GET /api/fs/list?path=<abs path>[&profile=<name>]    → {"entries":[{"name":"src","path":"/Users/me/proj/src","isDirectory":true}, …]}
                                                      or {"entries":[],"error":"ENOENT"|"ENOTDIR"|"EACCES"|"<text>"}
POST /api/files/mkdir   {"path":"/Users/me/proj/new"} → {"path":"/Users/me/proj/new", …}   (409 when a file is there)
```

(`H/hermes_cli/web_routers/files.py:721-728,762-789,981-992`.) The list hides a fixed set of noise names and
sensitive paths server-side; the phone additionally hides names starting with "." unless Show Hidden is on. The phone
filters `isDirectory == true`. All three use the signed-in session's auth exactly as `ChatWorkspace.list` does today
(reuse `ChatWorkspace`; add `defaultFolder()` and `makeFolder(path:)`).

Resolved in revision 2 (was UNKNOWN): the body model is `ManagedDirectoryCreate {path: str}`
(`H/hermes_cli/web_models.py:98-99`), one key only. The handler resolves the path through `_resolve_managed_path(…,
for_write=True)` (`files.py:721-728`): on an ordinary self-run gateway there is no locked root and any absolute path
the gateway's user can write is accepted (`mkdir(parents=True, exist_ok=True)`, so creating a folder that exists is a
success); a gateway run with a locked files root refuses a path outside it with an HTTP error; `409` "A file already
exists at that path". The picker treats any non-2xx as the failure alert above, showing the answer's `detail` text
when it has one. The fixture models both: it accepts paths under its fake home and answers 400
`{"detail":"Path is outside the allowed folder"}` elsewhere.

### 5.4 Acceptance

1. + › Folder… → sheet "Add Folder" opens at the chat's folder (fixture `/home/fx/proj`), folders only.
2. Open `src`, Select Folder, send "look" → `last_submit.text` is `@folder:src\n\nlook`.
3. Enclosing Folder twice then pick `/home` → ref is `@folder:/home` (absolute, outside the chat folder).
4. A folder named `my docs` → ref `` @folder:`my docs` ``.
5. Show Hidden reveals `.config`; Hide Hidden hides it.
6. New Folder "x/y" → Create disabled with the slashes message; "notes" → page "notes" pushed; mode `mkdir=fail` →
   "Couldn’t Create Folder".
7. Mode `fs=eacces` → "Your Gateway Can’t Open This Folder" with Try Again; switch mode back, Try Again → list.
8. Mode `fs=hang` → after 15 s "Couldn’t Load This Folder"; the sheet stays responsive and ✕ closes it at once.
9. 2,000 folders in one directory (mode `fs=huge`) → the list scrolls at full frame rate; first paint < 500 ms after
   the answer.

Fixture: 10030.

---

## 6. Prompt Snippets sheet, and the More item (L392, part of L389)

### 6.1 Web app

- + menu item **Prompt Snippets…**, symbol `text.bubble` (`S/ui-chat/plus-menu.ts:31-40`); directly in the menu when
  there are no plug-in providers or the chat is a room, otherwise inside a **More** submenu (`ellipsis.circle`) next
  to the plug-in providers.
- Sheet titled **"Prompt Snippets"** with ✕ (`B/stress-b-gates.ts:107-117`).
- Three snippets (`V/i18n/en.ts:4020-4036`):

| Title | Subtitle | Inserted text |
|---|---|---|
| Code review | Audit the current change for regressions, dropped edge cases, and missing tests. | Please review this for bugs, regressions, and missing tests. |
| Implementation plan | Outline an approach before touching code so the diff stays focused. | Please make a concise implementation plan before changing code. |
| Explain this | Walk through how the selected code works and link to the key files. | Please explain how this works and point me to the key files. |

- r1-48 (`B/fe-convo-gates.ts:269-271`): no row looks chosen when the sheet opens. r2-41: after a pick the composer is
  focused with the caret right after the snippet. Parity row: "inserts before the caret".

### 6.2 Native design

`ComposerPlusMenu.register(.snippets) { … }` adds **Prompt Snippets…** (`text.bubble`). It presents
`SnippetsSheetViewController` via `ChatSheet.wrap(root, title: "Prompt Snippets", detents: [.medium(), .large()])`.

- Inset-grouped table, three rows, title (body, semibold) over subtitle (subheadline, secondary, wraps freely),
  13 pt vertical padding. No checkmark, no selected background on open, no row focused for VoiceOver other than the
  natural first element.
- Tap → selection haptic, dismiss, then `ComposerView.insertSnippet(text)`:
  - the caret position (or selection start) at the moment the + menu opened is remembered by `ComposerView`
    (`pendingInsertRange`), because presenting a sheet can drop first responder;
  - the snippet is inserted **at that position**, replacing a selection if there was one; a single space is added
    before it when the previous character is not whitespace/line start, and after it when the next character exists
    and is not whitespace;
  - the field becomes first responder with the caret immediately after the snippet (so the text that was after the
    caret is still after the snippet — this is "inserts before the caret");
  - if the field was empty the result is just the snippet.
- Insertion goes through `textView.replace(_:withText:)` so Undo (shake / ⌘Z) removes it.

### 6.3 Wire

None.

### 6.4 More

**⚑ DECISION**: native shows no **More** item. On the web, More only exists to hold plug-in attach providers; native
has none, and a submenu holding one row (or nothing) breaks "never show a control that does nothing". Prompt
Snippets… is the last row of the + menu, exactly as the web shows it when no providers exist. `ComposerPlusMenu.Slot.more`
stays reserved; if a later stream adds providers they register there and Prompt Snippets… moves inside it.

Resulting + menu order (unchanged slots): Camera / Photos / Files, Voice Memo, Talk with <bot>, Paste Image, **Link…**,
**Folder…** ("From your computer"), **Prompt Snippets…**.

### 6.5 Acceptance

1. + menu ends with Link…, Folder…, Prompt Snippets… and has no More.
2. Open the sheet → three rows with the exact titles and subtitles; none highlighted.
3. Empty field, pick "Code review" → field reads the snippet; keyboard up; caret at the end.
4. Field "before| after" (caret at |), pick "Explain this" → "before Please explain how this works and point me to the
   key files. after", caret right after "files.".
5. ⌘Z removes the snippet.
6. At the largest accessibility text size every subtitle is fully readable (rows grow; nothing truncates).

Fixture: any (10030).

---

## 7. "Jump to approval" lands Run / Reject above the composer (L422)

### 7.1 Web app

`V/app/chat/scroll-to-bottom-button.tsx`, r5-83 (`B/fe-convo-gates.ts:625-630`, `S/fe-convo-r5.ts:11-41`): when an
approval is waiting and you have scrolled away, the jump button reads **"Approval needed"** (`V/i18n/en.ts:5305`) and
is tinted. Tapping it (selection haptic) scrolls so the bottom of the approval's actions sits **16 pt above the top of
the composer** (`approvalScrollDelta = stackBottom − (composerTop − 16)`), not to the true bottom. The button hides
once the actions row is wholly between the transcript's top and the composer (`rowAboveComposer`).

### 7.2 Native design

The approval card is a transcript row (`NAT/App/Questions/ChatPromptCell.swift`, id `approval.card`) at the newest end
of the inverted table. `ChatViewController.updateJumpButton()` (~line 1878) gains an approval mode:

- `approvalWaiting` = the session has a pending approval prompt (the same state that draws the card).
- `actionsFrame` = the card cell's actions row (Run / Reject buttons; expose `ChatPromptCell.actionsFrame(in:)`)
  converted to the view controller's view; `nil` when the cell is not loaded.
- `actionsVisible` = `actionsFrame` lies wholly between the transcript's visible top (below the nav bar) and
  `composer.frame.minY`.
- Approval mode is on when `approvalWaiting && !actionsVisible`. Then the jump button becomes a glass capsule with the
  label **"Approval needed"**, tinted with the app tint (the system prominent glass style, same capsule metrics as the
  existing "New messages" style if one exists; otherwise icon `chevron.down` + label). Accessibility label
  **"Approval needed"**, hint **"Scrolls to the request."**, id `jump.approval`.
- Tap: selection haptic; scroll so `actionsFrame.maxY == composer.frame.minY − 16`. With the inverted table this is
  `scrollToRow(at: approvalIndexPath, at: .top, animated: true)` followed by a content-offset correction to the exact
  16 pt (compute after `layoutIfNeeded`); when Reduce Motion is on the scroll is not animated.
- If text keeps streaming under the card, or the keyboard rises, the card's actions stay where the user left them; the
  button returns if they are covered again.
- When the approval is answered or expires, the button returns to its normal form on the next `updateJumpButton()`.
- Approval mode wins over the normal "jump to newest" form while both would apply.

**⚑ DECISION**: the web label is sentence case "Approval needed"; kept verbatim (it is a status, not a command).

### 7.3 Wire

None new; the card comes from the existing `approval.request` event (`docs/spec/1x-questions.md`).

### 7.4 Acceptance (questions-gateway on 10032, plus 10030 mode `approval=long`)

1. Long transcript, approval arrives, scroll up two screens → capsule "Approval needed" (tinted).
2. Tap → Run and Reject are both fully visible, the bottom of the row 16 pt (± 1) above the composer; capsule gone.
3. With the keyboard up and a 5-line draft: same result (measured against the taller composer).
4. Approval with a 60-line command preview (card taller than the screen): after the tap the actions are visible and
   the top of the card is off-screen above.
5. Answer the approval → capsule returns to the normal jump form or hides.
6. VoiceOver reads "Approval needed, button".

---

## 8. Typed slash commands with output rows (L439)

### 8.1 Web app

`B/ui-chat-commands-gates.ts`, `V/app/session/hooks/use-prompt-actions/slash.ts`. A typed `/command` is run locally
when the app owns it, else sent through `slash.exec` / `command.dispatch`, and its answer is drawn as an output row in
the transcript. Native's dispatcher (`docs/spec/1x-menus.md` §3.5-3.7, §8; `NAT/HermesKit/Chat/SlashRunner.swift`)
already does the exec path, output rows and error wording; what is missing is the set in
`SlashCatalog.nativeUnsupported`, which today answers "/<name> isn't available in HQ Native yet."
(`SlashRunner.swift:101,124`).

### 8.2 Native design: what each command does now

Remove a name from `nativeUnsupported` only when its row below is implemented. Output rows use the existing local
"slash output" system row. Line references are to `slash.ts`.

| Command (aliases) | Native behaviour | Wire |
|---|---|---|
| `/new` (`/reset`, `/clear`) | **Built (2026-10-27).** Opens a fresh chat with the same bot, exactly as the Bots row's / Bot Info "New Chat" does (`AppModel.newChat(for:)`), in this chat's place on the navigation stack (as `/resume` and Branch open theirs; Back returns to the list it came from); the composer's remaining text (anything after the command) is carried as the draft. No output row. A bot the app doesn't know → output row **"Couldn’t start a new chat with this bot."** Hook: `ChatSlashHooks.newChat` → `ChatMenuHosting.openNewChat(like:draft:replacing:)`. (501-504) | none until the first send |
| `/branch [name]` (`/fork`) | Runs the existing branch action (`LiveChatSession+ChatActions.swift:115-142`); on success opens the new chat. Output row in the old chat: **"Branched to a new chat."** Failure → the existing branch error wording. | `session.branch` |
| `/compress [topic]` (`/compact`) | §8.3 | `session.compress` |
| `/btw <question>` | §8.4 | `prompt.btw` |
| `/bg <prompt>` (`/background`) | §8.4 | `prompt.background` |
| `/resume [words]` (`/sessions`, `/switch`) | No words → pops to the bot's chat list (the native session picker). Words → first chat of this bot whose id equals, title contains, or preview contains the words (case-insensitive, in that order) is opened; none → output row **"No chat matches “<words>”."** (1229-1272) | none (uses the loaded list; if the list is not loaded, loads it first) |
| `/profile [name]` | Bare → output row **"This chat is with <Bot name>."** Named → **"To talk to another bot, pick it from Bots."** **⚑ DECISION**: on the web a named profile changes which bot new chats use; natively the Bots tab is that control and a hidden mode switch would surprise. (1000-1040) | none |
| `/skin` | Output row **"Themes are in Settings › Appearance."** **⚑ DECISION**: the web runs a theme command; native themes live in Settings. | none |
| `/wake` | Output row **"The wake word isn’t available on this device. Tap the waveform button to talk."** (FE-048 wording) | none |
| `/voice` (composer voice) | Output row **"Tap the waveform button to start a voice conversation."** (only if not already handled by the voice stream; do not double-handle) | none |
| `/handoff <platform>` | Passed to the gateway through the normal exec path (it is a gateway command). If the gateway answers `-32601` or "unknown command" → **"/handoff isn’t available on this gateway."** | `slash.exec` |
| `/browser [connect\|disconnect\|status]` | Output row **"/browser manages a Chromium-family browser on the gateway host — only available when connected to a local gateway."** (the web's own text for a remote connection) | none |
| `/journey`, `/learning`, `/memory-graph` | Output row **"<command> isn’t available on iPhone or iPad."** | none |
| `/pet`, `/hatch`, `/generate-pet` | Output row **"<command> isn’t available on iPhone or iPad."** (FE-048: these are "advanced" on iOS) | none |
| `/battery`, `/palette` | same line | none |
| `/help` | unchanged (existing) | — |

`<command>` in those lines is the command as typed, with its slash, lower-cased (e.g. "/pet isn’t available on iPhone
or iPad."). After this stream **no command answers "isn’t available in HQ Native yet."**; that string is deleted.

Every locally-answered command still shows the typed command as the user's own row first (existing behaviour), then
the output row, and never calls the gateway.

### 8.3 `/compress`

Web (652-830): notice "compressing context..." (or "compressing context for: <topic>"), one call per session at a time,
long timeout; the answer may replace the transcript.

**Built (2026-10-27)**: `SlashRunner.slashCompress` (HermesKit/Chat/SlashRunner.swift), strings and answer mapping in
`SlashResults.compressText` / `compressError`. Gateway side, read from Hermes source (`H:tui_gateway/methods_session.py`
`@method("session.compress")`, `_compress_live`, `_compress_via_compute_host`): a client RPC for any live session; it
pins the session's status to `compressing` while it runs (`status.update`, which the working line already reads),
answers `{status, removed, before_messages, after_messages, before_tokens, after_tokens, summary, usage, info,
messages}`, `{status:"pending", message}` when a compute host is still compressing after the gateway's wait, or
`{compressed:false, lock_held:true, message}` when another compression holds the lock (shown as its `message`).
`slash.exec "compress"` also works on the gateway (`methods_slash.py` `_LIVE_SLASH_OUTPUT`), but the desktop keeps
/compress off it (its pipe times out on big chats, #44456); native does the same and uses it only on `-32601`.

1. If a reply is running → output row **"Wait for this reply to finish, then compress."** and stop.
   **⚑ DECISION**: the gateway would answer busy (4009); saying it first avoids a round trip.
2. If a compress is already running for this chat → ignore (no second row).
3. Output row **"Compressing context…"** or **"Compressing context for: <topic>…"** (the existing slash row in its
   "Running…" place, 250 ms after the send).
4. Call with a 660 s timeout (**⚑ DECISION**, was 300 s: the gateway itself waits up to 630 s for a compute host before
   answering `pending`; the desktop's `SESSION_COMPRESS_TIMEOUT_MS` is 660 000 for that reason).
5. Answer handling (the running row is replaced by the result row):
   - `status == "pending"` → **"Compression is still running in the background."**
   - `status == "aborted"` or `summary.aborted` → `summary.headline` if present, else **"Compression was stopped."**
   - `summary.noop` or `removed == 0` → `summary.headline` if present, else **"Nothing to compress."**
   - otherwise the lines `summary.headline`, `summary.token_line`, `summary.note` (those present, one per line); if
     none: `host_ack.output` if present, else **"Compressed <removed> messages."** ("1 message").
   - `messages` present → **⚑ DECISION (2026-10-27)**: the transcript on screen is left as it is. The rows before the
     summary are still the chat's (history is read with `include_compacted=true`, 03 §2.1) and the desktop keeps them on
     screen too (it prepends the old segment to `messages`, #105256); rebuilding from `messages` alone would hide them.
     The result row is appended.
   - `info.usage` (else `usage`) → Session Info's usage; the context estimate is dropped so the meter reads it again.
6. Errors: `4001` (session gone) → resume the session once and retry once; `4009` busy → the line in step 1; transport
   failure / timeout → **"Couldn’t compress: your gateway didn’t answer in time."**; `-32601` → fall back to the exec
   path (`slash.exec {command:"compress <topic>"}`); other → **"Couldn’t compress: <message, ≤ 160 chars>"**.

```json
→ {"jsonrpc":"2.0","id":51,"method":"session.compress","params":{"session_id":"s-1","focus_topic":"the login bug"}}
← {"jsonrpc":"2.0","id":51,"result":{"status":"compressed","removed":42,
     "summary":{"headline":"Compressed 42 messages","token_line":"48.2k → 9.1k tokens","note":"","aborted":false,"noop":false},
     "messages":[…],"usage":{…}}}
```

Allowed keys: `session_id`, `profile?`, `focus_topic?` (`H/tui_gateway/contracts`, `SessionCompressParams`).

### 8.4 `/btw` and `/bg`

| | `/btw <question>` | `/bg <prompt>` / `/background` |
|---|---|---|
| No argument | **"Type a question after /btw. It's answered from this chat so far, without interrupting it."** | **"Type a task after /bg. It runs in a separate session, and the result shows here when it's done."** |
| Call | `prompt.btw {session_id, text}` | `prompt.background {session_id, text}` |
| Answer | `{task_id}` | `{task_id}` |
| Output row on start | **"Asking on the side… the answer will show here."** | **"Started in the background. Keep chatting; the result will show here when it's done."** |
| Result event | `btw.complete {task_id, text, question?}` | `background.complete {task_id, text}` |
| Result row | one line **"By the way: <question>"** that opens on the answer as markdown; it lands opened | one line **"Background task finished: <prompt>"** that opens on the result; it lands closed |
| Failure (`text` is `"error: <reason>"`) | **"Couldn’t answer: <question>"**, opening on the reason | **"Background task failed: <prompt>"**, opening on the reason |
| `-32601` | exec path | exec path |
| Other error | **"Couldn’t ask: <message>"** | **"Couldn’t start the background task: <message>"** |

**⚑ DECISION**: no task ids are shown (the desktop prints them; here they mean nothing to the reader). The
start line goes when the result lands, and the result is the same one-line row a finished subagent or a cron run draws
(`BackgroundResultRow`, a speech-bubble mark for /btw). A result empty after trimming reads **"No answer came back."**
Both work while a reply is running (that is their point): they must **not** be queued behind the reply. A typed
command already runs at once (`ChatViewController.send` → `runCommand`), so nothing joins the queue.

Allowed keys for both: `session_id`, `profile?`, `text` (`SideAgentParams` → `TaskIdResult`).

`LiveChatSession+Events` hands `btw.complete` and `background.complete` to `sideTaskFinished` (SideTasks.swift). Every
chat hears every frame; a chat takes a frame for a task it asked, or one on its own runtime id (an earlier screen of
the same chat asked it), and a replay of one already shown adds nothing. Results are local rows (they are not in
gateway history): they are kept per chat for the launch (`SideResultStash`, newest 50) and come back where they landed
when the chat opens again; sign-out clears them.
**⚑ DECISION**: a chat left with a task out keeps listening off screen (as one sending its queue does) until the
result lands or an hour passes. After a cold relaunch results are gone, as on the desktop, because the gateway does
not store them. A new replay epoch (Hermes restarted) ends the wait: the start line reads **"Hermes restarted before
this finished."**

### 8.5 Acceptance (10030; exec-path regressions on 10033)

1. `/new hello` → a fresh chat opens with "hello" in the field.
2. `/branch` → new chat opens; old chat has "Branched to a new chat."
3. `/compress` → "Compressing context…" then "Compressed 42 messages" / token line; transcript shrinks to the fixture's
   `messages`. `/compress login` → topic line. Mode `compress=pending`, `noop`, `aborted`, `error`, `hang`, `old`
   (-32601 → exec) each show the exact line above.
4. `/compress` during a reply → "Wait for this reply to finish, then compress." and no RPC (fixture call count 0).
5. `/btw what's the port?` during a slow reply → start row at once, the reply keeps streaming, the "By the way" row
   arrives ~1 s later. `/btw` alone → usage line.
6. `/bg run the tests` → start row, then "Background task …" result row.
7. `/resume` → chat list. `/resume zebra` (a title in the fixture) → that chat. `/resume qqqq` → "No chat matches
   “qqqq”."
8. `/pet` → "/pet isn’t available on iPhone or iPad." `/wake`, `/skin`, `/browser`, `/profile` → exact lines.
9. `grep -rn "available in HQ Native yet" App HermesKit` → no hits.
10. Fixture strict params: no call was answered 4000 during the whole run (`/__composer/state` → `param_errors == 0`).

---

## 9. Slash drawer as you type (L440)

### 9.1 Web app

- `V/hooks/use-slash-completions.ts`: empty query → `commands.catalog` categories as sections plus leftover skills
  under "Skills"; with a query → `complete.slash {text:"/"+query, session_id | profile}` → `{items:[{text, display,
  meta, kind?}], replace_from?}`. `replace_from > 1` means argument completion (group "Options"). Group order
  Commands, Skills, Options. 60 ms debounce, cached. `/resume <q>` completes recent chats on the client.
- Triggers (`V/lib/text-utils.ts:65-67`): the whole field matches `^(\/)((?:[a-zA-Z][\w-]*(?:\s+\S*)*)?)$`; mid-text
  `[\s](\/)([a-zA-Z][\w-]*)?$` offers skills only.
- Phone gates: FE-048 / `phoneSlashItems` (`S/fe-convo-r4.ts:80-100`) hides desktop-only commands
  {timestamps, ts, focus, egress, codex-runtime, codex_runtime, debug, worktree} unless the row is a skill or the
  query contains whitespace; r4-90 no row pre-chosen; r5-90 `slashDescription` plain words; empty → "No matches."
- Picking inserts the command; if the command takes an argument the drawer moves to the argument stage.
- `MEM/commands-button`: the owner rejected the earlier "/"-inserting button as buggy — "keyboard jumps, stray /" —
  and chose Telegram's behaviour for the ☰ sheet (a pick sends; argument commands insert "/cmd " ahead of the draft).
  The drawer must therefore never move the keyboard and never leave a stray "/".

### 9.2 Native design

New `ComposerDrawer` (`NAT/App/Chat/ComposerDrawer.swift`): a glass panel that sits directly above the composer field,
same horizontal insets as the field, corner radius 18, max height = min(5.5 rows, space between the nav bar and the
composer − 8). It is a subview of the chat view pinned to the composer's top (so it rides the keyboard with it); it is
not a popover, sheet or input accessory, so the keyboard never moves and focus never leaves the field. It hosts a
plain `UITableView`.

`ComposerDrawerModel` (HermesKit, pure, unit-tested) decides what to show from `(text, caretOffset)`:

- **Slash, whole field**: text up to the caret matches the first regex and the caret is at the end of the text.
- **Slash, inline (skills only)**: text up to the caret matches the inline regex.
- **@** (§10): text up to the caret matches `(?:^|[\s])(@)([^\s@]*)$`.
- Otherwise closed.

Rows for the slash drawer:

- Empty query (just "/"): the same sections the Commands sheet shows (`SlashCatalog.sections`, from the cached
  catalog; if the catalog is not loaded, load it and show the loading row meanwhile).
- With a query, no whitespace: local filter of the catalog by prefix first then contains (`SlashCommand.matches`),
  shown at once; in parallel `complete.slash` (60 ms debounce, one in flight, later answers for an older query are
  dropped) and its items replace the local ones when they arrive, de-duplicated by command name. Groups in order
  **Commands**, **Skills**.
- With whitespace (argument stage): only `complete.slash` items; group header **Options**; `replace_from` gives the
  offset from which the picked `text` replaces the field.
- `/resume <q>`, `/sessions <q>`, `/switch <q>`: client-side, the bot's recent chats whose title contains `<q>` (max
  8), plus a last row **"Browse all chats…"** that runs bare `/resume`.
- `SlashCatalog.phoneHidden` applies to command rows (not skills, not when the query has whitespace).
- Commands whose native answer is only "isn’t available on iPhone or iPad." (§8.2: pet, hatch, generate-pet, journey,
  learning, memory-graph, battery, palette) are **not listed** in the drawer or the sheet. Typing them by hand still
  gets the plain answer. (FE-048 does the same on the web.)

Row: command in semibold Body in the app's face (`/compress`, the Commands sheet's row title; the skin's typeface in the
Desktop Look), description in secondary subheadline (`SlashCatalog.plainDescription`),
one row height 44 pt minimum, description wraps to two lines then truncates; 12 pt vertical padding when wrapped.
Section headers use the small uppercase-free secondary style the Commands sheet uses. No row is highlighted on open.
**⚑ DECISION (owner 2026-10-27, "the font size of all / commands in the pop up are oddly large")**: commands were set in
the monospaced system face at Body's point size, whose wide, tall letters outsize every other list at the same text
size (and ignored the Desktop Look's skin face). Commands now read as the sheet's rows do; only @ refs (paths, folders,
`@kind:`) stay monospaced. `ComposerDrawerModel.titleFace(_:)` decides (command / ref / plain).

Pick (tap):

- selection haptic;
- a command with no argument → the field becomes `/<name>` and is **sent at once** (same as the ☰ sheet's pick), the
  drawer closes. **⚑ DECISION**: the web inserts and waits for Send; the owner chose "a pick sends" for the sheet and
  the drawer follows the same rule so the two never disagree.
- a command that takes an argument (`SlashCatalog.pickAction` says insert) → the field becomes `/<name> ` (trailing
  space), caret at the end, the drawer moves to the argument stage (or closes if `complete.slash` has no options).
- an Options row → the field becomes `text[..<replace_from] + item.text`; if the item ends a complete command
  (no further options), the drawer closes and nothing is sent (the user presses Send).
- an inline skill row → replaces just the `/word` before the caret with `/<skill> `; never sends.
- a recent-chat row → opens that chat; the field is cleared.

Closing: the trigger no longer matches; Esc; tapping the transcript; sending. Deleting the "/" closes it and leaves
nothing behind.

States:

| State | Row shown |
|---|---|
| Catalog loading (first time) | one row, spinner + **"Loading commands…"** |
| No matches | one non-tappable row **"No matches."** |
| Catalog failed and nothing cached | the drawer does not open (the typed command still runs on Send); the failure is logged to Diagnostics as "Commands didn’t load: <reason>" |
| `complete.slash` fails / `-32601` | local filter stays; no error row; no retry until the next keystroke (a failed query is asked again when typed again after 5 s; `-32601` never) |
| Offline | local filter of the cached catalog only |

Accessibility: the panel is `accessibilityContainerType = .list`, label **"Commands"**; each row's label is
"<command>, <description>", trait button. When the drawer opens VoiceOver is not moved (focus stays in the field); a
`UIAccessibility.post(.announcement, "<n> commands")` is made once per opening, not per keystroke.

### 9.3 Wire

```json
→ {"jsonrpc":"2.0","id":61,"method":"complete.slash","params":{"text":"/mod","session_id":"s-1"}}
← {"jsonrpc":"2.0","id":61,"result":{"items":[{"text":"/model","display":"/model","meta":"Switch model","kind":"command"}]}}

→ {"jsonrpc":"2.0","id":62,"method":"complete.slash","params":{"text":"/reasoning h","session_id":"s-1"}}
← {"jsonrpc":"2.0","id":62,"result":{"items":[{"text":"high","display":"high","meta":""}],"replace_from":11}}
```

Allowed keys: `text?`, `session_id?`, `profile?` (send `session_id` when the chat has one, else `profile` for a
non-default bot, else neither). `commands.catalog` is the existing call (1 h cache).

### 9.4 Keyboard behaviour (the owner's complaint)

- Opening, updating and closing the drawer never calls `resignFirstResponder`, `becomeFirstResponder` or
  `reloadInputViews`, and never changes `inputAccessoryView`.
- The composer's frame does not change when the drawer opens (the drawer overlays the transcript).
- A pick that sends clears the field through the normal send path (§2 fresh keyboard).

### 9.5 Hardware keys

With the drawer open: ↓ / ↑ move a highlight (none at first; ↓ highlights the first row), Return picks the highlighted
row (with none highlighted Return follows §1), Tab picks the first row when none is highlighted, Esc closes.

Wiring (revision 2, on top of the iPad stream's keys, §0.2):

- **Return**: `ComposerTextView.pressesBegan` asks a new `onHardwareReturnPick: (() -> Bool)?` first, before
  `ReturnKey.decide`; it answers `true` (and picks) only when the drawer is open with a highlighted row and no marked
  text. Otherwise the existing rule runs unchanged.
- **↑ / ↓ / Tab**: `ComposerTextView.keyCommands` today returns the chat-walk commands only while the field is empty
  (⌘↑ / ⌘↓). An open drawer means the field is not empty, so the two never meet: while the drawer is open it returns
  plain ↑, ↓ and Tab commands with `wantsPriorityOverSystemBehavior = true`; closed, the caret keeps the arrows.
- **Esc**: the `closeDrawer` rung of the app's one Escape ladder (§3.2). No Escape command on the text view.

### 9.6 Acceptance (10030; catalog regressions on 10033)

1. Type "/" → drawer with sections; no row highlighted; the keyboard did not move (composer frame identical before
   and after, asserted in the UI test).
2. Type "/mo" → `/model` row with its plain description; no `/debug`, `/worktree`, `/pet` anywhere.
3. Type "/zzz" → "No matches."
4. Tap `/help` → sent at once; field empty; no stray "/".
5. Tap `/reasoning` → field "/reasoning " and Options rows (low, medium, high…); tap "high" → field "/reasoning high";
   Send runs it.
6. Type "please /" mid-text → skills only. Pick one → only the "/…" word is replaced.
7. Type "/" then backspace → drawer closes; field empty.
8. Mode `complete=hang` → local rows still appear within one frame of each keystroke; mode `complete=old` (-32601) →
   same.
9. Type 30 characters quickly → at most one `complete.slash` in flight at a time and the final rows match the final
   text (fixture records the order; a deliberately slow answer for an older query does not overwrite a newer one).
10. Largest accessibility size: rows grow, the drawer height cap still leaves the field and at least 44 pt of
    transcript visible.

---

### 9.7 Favourite commands

No web or desktop source: the owner asked (2026-10-24) for commands you use often to sit at the top of the list. It
follows the Models sheet's favourite models (spec 1x §6), so the two read alike.

- **Commands sheet** (☰, and /help): each row has a 44 pt star button 6 pt from the trailing edge (`star` /
  `star.fill`, Body-sized, label-3 / tint), VoiceOver **"Favorite /status"**, Selected when starred. Tapping it never
  picks the row. A section **"Favorites"** leads the sheet with the starred commands in the order they were starred.
  They also stay in their own sections. The tapped row holds still on screen while Favorites grows or shrinks above
  it. While searching, Favorites steps aside (the search finds the rows in their own sections).
- **Slash drawer**: a bare "/" opens on the same **"Favorites"** section. Typed, in each section the starred commands
  whose names start with the words go first, in starred order, and the rest keep their order (the gateway's answer
  too). Skills typed mid-text (`/word` after a space) are not reordered.
  **Starring from the drawer (owner 2026-10-27: "the same way sessions are pinned")**: each whole-command row (not an
  option, a ref, a bot, a "/resume" chat or a note: `ComposerDrawerModel.favoriteCommand`) has a hold menu with one
  item, **"Favorite"** / **"Unfavorite"** (`star` / `star.slash`), and a leading swipe with the same words
  (`star.fill` / `star.slash.fill`, yellow; a full swipe runs it), as Sessions' Pin / Unpin. Both write the store the
  sheet's star writes (`ComposerDrawerHost.toggleFavoriteCommand`), and the drawer redraws at once, so its Favorites
  section follows. This replaces the earlier decision that the drawer has no way to star.
  **⚑ DECISION**: the hold menu is an edit menu (`UIEditMenuInteraction`, the callout over the row, which shows the
  title only), not a context menu as Sessions uses: a context menu took the keyboard off screen while it was up
  (measured: keyboard top 590 → 918 pt, back after), the jump §9.4 rules out; under the edit menu it stays at 590 pt.
  `ComposerUITests.test24` logs the keyboard's frame before, under and after the menu.
- A starred command a chat doesn't list (hidden on the phone, missing from this profile) isn't shown. It stays
  starred.
- **Store**: `CommandFavorites` (HermesKit/Store), UserDefaults `hq.favorite-commands|<account id>`, an array of
  "/name" in lower case. It keeps the newest 50. It is per gateway account, like favourite models, and goes on Sign
  Out and on a DEBUG reset. It is not synced between devices.

Acceptance: `Tests/Menus/CommandFavoritesTests.swift`; UI `ComposerUITests.test26` (sheet star, the row holding still,
Favorites hidden while searching, the drawer's order for "/" and typed, unstarring).

## 10. @ drawer (L441)

### 10.1 Web app

- `V/hooks/use-at-completions.ts`: `complete.path {word:"@"+query, session_id?, cwd?}` → `{items}`. With an empty
  query the starters are file, folder, url, image, tool, git. Items look like `@file:src/x.ts`, `@folder:apps/`,
  `@diff`, `@staged`, `@<handle>` (meta "agent profile" / "agent profile (primary)").
- r4-99 `atDescription` (`S/fe-convo-r4.ts:103-109`) rewrites the meta in plain words; dotfiles are hidden unless the
  typed segment starts with "."; when the chat's folder is missing the drawer says **"This chat’s folder isn’t
  available on your gateway computer."** (readability check cached 30 s).
- r5-88: `cwd` is the chat's own folder only (`chatOwnCwd`). r5-96 `phoneAtProfiles`: your own bot is not offered;
  other bots show their display name; the primary one reads "Your main bot".

### 10.2 Native design

Same `ComposerDrawer`, @ mode, when the text before the caret matches the @ trigger.

Starters (empty query), in this order, each a row that inserts its prefix and keeps the drawer open:

| Row | Description | Inserts |
|---|---|---|
| `@file:` | Attach a file from the chat’s folder | `@file:` |
| `@folder:` | Attach a folder from the chat’s folder | `@folder:` |
| `@url:` | Attach a web page | `@url:` |
| `@diff` | Changes not yet committed | `@diff ` |
| `@staged` | Changes staged for commit | `@staged ` |

followed by a section **Bots** with the other bots (below). **⚑ DECISION**: the web's `@image:` and `@tool:` starters
are left out: images go through the + menu (Photos, Paste Image) on the phone and `@tool:` has no plain-language
meaning for a phone user; typing them by hand still completes through the gateway.

With a query: `complete.path` items (60 ms debounce, one in flight, stale answers dropped), with meta mapped:

| Gateway meta | Shown |
|---|---|
| `git diff` | Changes not yet committed |
| `staged diff` | Changes staged for commit |
| `attach file` | Attach a file from the chat’s folder |
| `attach folder` | Attach a folder from the chat’s folder |
| `fetch url` | Attach a web page |
| `git log` | Recent commits |
| `agent profile` | the bot's display name from the Bots list (fallback **"Another bot"**) |
| `agent profile (primary)` | **"Your main bot"** |
| `dir` | Folder |
| anything else | shown as sent |

Filters: an item whose last path segment starts with "." is hidden unless the typed last segment starts with "."; the
chat's own bot (its profile name, or `default` when it is the default bot) is not offered.

Bots section (empty query, and when the query is a plain word with no ":"): from the app's loaded Bots list, all bots
except this chat's, name-prefix filtered, each row `@<handle>` + the bot's display name, with the bot's own robot head
at 24 pt as the leading image. This is local and needs no call; `complete.path` profile items are merged and
de-duplicated by handle.

Row label: the item's `display` if present else its `text`, monospaced; for file and folder items the part after the
last "/" is emphasised and the parent path is secondary.

Pick: replaces the `@…` word before the caret with `item.text`; adds a trailing space unless the item ends in ":" or
"/" (a folder to keep drilling into, in which case the drawer stays open with the new query). Never sends. Selection
haptic.

Folder for the call: the chat's own folder (same source as §5). No folder → `cwd` is omitted and only non-file items
are useful; for `@file:` / `@folder:` queries with no chat folder, or when a list of the chat folder answers
`ENOENT` / `EACCES` (checked through `GET /api/fs/list`, result cached 30 s per chat), the drawer shows one
non-tappable row **"This chat’s folder isn’t on the computer running Hermes."**

States:

| State | Row shown |
|---|---|
| Waiting for the first answer of a query | previous rows stay; if none, spinner + **"Looking…"** |
| No items | **"No matches."** |
| Chat folder missing (file/folder query) | **"This chat’s folder isn’t on the computer running Hermes."** |
| Call fails / `-32601` / offline | starters and Bots still work locally; for other queries **"No matches."**; logged to Diagnostics once per minute as "Mentions didn’t load: <reason>"; a failed query is asked again when typed again after 5 s, and an answer is asked again after 30 s (files the bot made meanwhile show), the old rows showing until it comes |

How refs typed this way are sent: they stay inline in the text exactly as typed (the gateway expands them). The
transcript draws an inline `@file:…` in your bubble as plain text (the leading-block rule of `Hydration` only applies
to refs on their own lines at the top). `@<handle>` for another bot is plain text to the phone.

### 10.3 Wire

```json
→ {"jsonrpc":"2.0","id":71,"method":"complete.path","params":{"word":"@file:src/","session_id":"s-1","cwd":"/home/fx/proj"}}
← {"jsonrpc":"2.0","id":71,"result":{"items":[
     {"text":"@file:src/main.py","display":"src/main.py","meta":"attach file"},
     {"text":"@folder:src/util/","display":"src/util/","meta":"dir"}]}}
```

Allowed keys: `word?`, `cwd?`, `session_id?`, `profile?`.

### 10.4 Acceptance (10030)

1. Type "@" → the five starters then Bots listing the fixture's other bots by display name; this chat's bot absent.
2. Tap `@file:` → field "@file:" and the chat folder's files; `.env` not shown; type "." → `.env` appears.
3. Tap `@folder:src/util/` → field keeps the trailing "/" and the drawer lists inside it.
4. Tap `@file:src/main.py` → field "@file:src/main.py " (trailing space), drawer closed; Send → `last_submit.text`
   contains it verbatim.
5. "@cla" → the bot whose handle starts "cla", description = its display name; the primary bot reads "Your main bot".
6. Mode `fs=enoent` then "@file:" → "This chat’s folder isn’t on the computer running Hermes."
7. "hello@" (no space before) → no drawer (e-mail addresses must not trigger it).
8. Mode `complete=hang` → starters and Bots still appear at once.
9. The fixture saw `cwd` equal to this chat's folder only, never another chat's (open two chats with different
   folders and compare `/__composer/state` → `complete_path_cwds`).

---

## 11. Switch provider recovery from a failed turn (L446)

### 11.1 Web app

`S/switch-provider.tsx`: the error card of a failed turn gets an action **"Switch provider"**
(`V/i18n/en.ts` `errorSwitchProvider`) with a selection haptic; it opens the chat's model menu anchored to the button
(or Settings › Model when there is no menu). Shown when the error's layer is one of auth, billing, endpoint, provider
(`V/lib/error-surface.ts:262,295`). The data rides `message.complete.error_surface {layer, code, retryable,
provider?, model?, resets_at?}` (`H/tui_gateway/contracts/events.py:151-161,208`). Code plans: `model_not_found` →
choose a model and no retry; `context_overflow` / `payload_too_large` → compress or start a new chat.

### 11.2 Native design

`LiveChatSession+Events` already reads `error_surface.code` for one case (`:367`). Parse the whole object into

```swift
nonisolated struct ErrorSurface: Sendable, Hashable, Codable {
    var layer: String?; var code: String?; var retryable: Bool?
    var provider: String?; var model: String?; var resetsAt: Date?
}
```

and store it on the failed message's error state. `ErrorRecovery.plan(for:)` (HermesKit, pure, unit-tested):

| Condition | Capsules on the error card, in order |
|---|---|
| `layer` ∈ {auth, billing, endpoint, provider} | **Switch Provider**, then **Retry** if `retryable != false` |
| `code == "model_not_found"` | **Choose Model** (no Retry) |
| `code` ∈ {context_overflow, payload_too_large} | **Compress**, **New Chat** (no Retry) |
| anything else / no surface | today's capsules (Retry, Details) unchanged |

Details and ✕ stay as they are. **⚑ DECISION**: capsule labels are Title Case ("Switch Provider") to match the other
native capsules; the web's is sentence case.

- **Switch Provider** / **Choose Model**: selection haptic, then present the existing More Models sheet
  (`ModelSheetViewController`) for this chat. If `error_surface.provider` is set, the sheet scrolls so the first
  section of a **different** provider is at the top (the failing provider's section is not hidden). After the user
  picks a model the sheet closes and the card gains nothing new; the user taps Retry or sends again.
  **⚑ DECISION**: no automatic retry after the pick — a retry spends money on a provider the user has just chosen,
  and the web does not auto-retry either.
- **Compress**: runs §8.3 (same rows). **New Chat**: same as `/new`.
- `resets_at` in the future, layer billing: the card's secondary line gains **"Resets <relative time>."** using
  `RelativeDateTimeFormatter` (e.g. "Resets in 2 hours."). Past or missing → nothing.
- A restored chat (history reload) has no `error_surface` (it is only on the live event) → today's card. The surface
  is kept for the life of the launch only. **⚑ DECISION**: not persisted; a stale "Switch Provider" after relaunch
  would point at an error that may no longer be true.

### 11.3 Wire

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"s-1","payload":{
  "text":"","error":"Anthropic rejected the API key (401).",
  "error_surface":{"layer":"auth","code":"invalid_api_key","retryable":false,"provider":"anthropic","model":"claude-sonnet-4-5"}}}}
```

(Envelope as the existing event decoder expects; the fixture sends exactly what `performance-fixture-gateway.py` sends
for `message.complete`, plus the two fields.) The model switch itself is the existing call from
`docs/spec/1x-menus.md` §1.

### 11.4 Acceptance (10030 modes `fail=auth|billing|model_not_found|context_overflow|plain`)

1. `fail=auth` → error card with **Switch Provider** and no Retry (retryable false). Tap → More Models sheet opens,
   first visible section is not Anthropic. Pick a model → sheet closes; the ⋯ model row shows the new model.
2. `fail=billing` with `resets_at` two hours ahead and `retryable:true` → Switch Provider + Retry + "Resets in 2 hours."
3. `fail=model_not_found` → **Choose Model**, no Retry.
4. `fail=context_overflow` → **Compress**, **New Chat**. Compress runs and shows §8.3 rows.
5. `fail=plain` (no surface) → card unchanged from today.
6. Unknown layer "weather" → card unchanged (no crash, no empty capsule).
7. VoiceOver: capsules read "Switch Provider, button".

---

## 12. Model list load failure in words, with Try again; tries twice (L448)

### 12.1 Web app

r1-33 `modelLoadError` (`S/fe-convo-r1.ts:178-182`): a transport failure reads **"Couldn’t load models — your gateway
didn’t answer in time."**; otherwise **"Couldn’t load models: <text, ≤ 120 characters…>"** or **"Couldn’t load
models."** Rows **Try again** (reads "Loading models…" while fetching) and **Copy details**. r2-60
(`B/fe-convo-gates.ts`): `retry: 1` — the load is tried twice, each up to 30 s, before the failure shows.

### 12.2 Native design

`ModelSheetViewController` (`:176-192`) today shows "Couldn't Load Models" with "You’re offline." / "Hermes didn’t send
its list of models. Show Details has the reason." and **Try Again** / **Show Details**, with no automatic second try.

Changes:

1. **Two tries.** `ModelCatalog.load` (wherever `model.options` is called for the sheet and the ⋯ model submenu) runs
   the call, and on failure runs it once more immediately — except when the device is offline (no path) or the error
   is a params error (4000) or `-32601`, which a second try cannot fix. Each try has a 30 s timeout. The spinner
   shows **"Loading models…"** throughout; the failure state only appears after the second failure.
2. **Words.** The empty-state secondary line becomes:
   - offline → **"You’re offline."** (kept)
   - transport failure or timeout → **"The computer running Hermes didn’t answer in time."**
   - gateway error with a message → **"<message, trimmed, ≤ 120 characters, then …>"**
   - no message → nothing (title only)
   
   Title stays **"Couldn’t Load Models"** (with the curly apostrophe; fix the straight one).
   **⚑ DECISION**: native keeps its title + secondary layout instead of the web's single sentence; the words after the
   dash/colon are the web's.
3. Buttons: **Try Again** (runs the two-try load again; while it runs the state is the spinner with "Loading models…")
   and **Show Details** (kept; its page has the existing Copy). **⚑ DECISION**: the web's "Copy details" row is the
   Copy inside Show Details natively — one fewer button on the failure state, nothing lost.
4. With rows already shown, a failed refresh keeps the rows and shows nothing (existing behaviour, keep). The failure
   is logged to Diagnostics as "Models didn’t refresh: <reason>".
5. The model panel's Switch Model menu (it was the ⋯ › Model submenu until 2026-11-01), when its list failed: its
   last rows read **"Couldn’t load models"** (disabled) above **"Try Again"**; choosing Try Again starts the two-try
   load and the menu shows the result next time it opens (a `UIDeferredMenuElement.uncached` so it is live).

### 12.3 Wire

`model.options {session_id?, profile?}` (existing; `docs/spec/1x-menus.md` §1).

### 12.4 Acceptance (10030 or 10033 with mode `models=fail_once|fail_twice|hang|error_text|ok`)

1. `fail_once` → the sheet shows the list with no failure state ever visible; the fixture counted 2 calls.
2. `fail_twice` → "Couldn’t Load Models" + the gateway's message; fixture counted exactly 2 calls (not 3+).
3. Try Again with mode back to `ok` → "Loading models…" then the list.
4. `hang` → failure after ~60 s (2 × 30 s) with "The computer running Hermes didn’t answer in time."; the ✕ works the whole time.
   (UI test shortens the timeout with launch argument `-HQNModelTimeout 2`.)
5. `error_text` with a 400-character message → shown cut at 120 characters with "…".
6. Airplane-style offline (fixture stopped by the test that started it) → "You’re offline." and one attempt only.

---

## 13. Goal and loop failing to load is quiet, logged, and retried after a turn (L459)

### 13.1 Web app

- r21 B-06 (`B/r21-chat-gates.ts`) + `S/ui-chat/quiet-log.ts`: when `session.control.read` fails the phone shows
  nothing and logs **"Chat goal and loop didn’t load: <reason>"** to Diagnostics (secrets redacted; the same line
  within 60 s is collapsed; at most 20 kept).
- r2-57 (`B/fe-convo-gates.ts:354-357`): the read is tried again after a turn that worked, when the last read failed
  and the gateway did not say "unsupported"; and once when the gateway connection reopens. Never in a loop.
- Loop section of the status stack (`V/app/chat/status-stack/session-control-loop.tsx`, `V/i18n/en.ts:4097-4119`):
  header "<Loop active | Loop paused | Loop deferred | Loop finished>[ · Awaiting response] · <Run c/t | N run(s)>
  [ · next <time>]"; actions Pause loop, Resume loop, Stop loop (confirm "Stop loop?" / "Are you sure you want to stop
  this loop?"), Dismiss loop when finished; fields Prompt, Cadence ("every Ns/m/h", "self-paced"), Until condition;
  "An active goal currently controls the session." when deferred by a goal. Heartbeat is similar.

### 13.2 Native design

**Quiet failure (the row's main point).** In `ActivityStore.readControlNow` (`NAT/HermesKit/…/ActivityStore.swift:576-605`):

- On any failure other than "unsupported" (`-32601`, which sets `capability = .unsupported` as today): keep the old
  snapshot, show nothing, set `controlReadFailed = true`, and call
  `DiagnosticLog.note("chat", "Chat goal and loop didn’t load: \(reason)")` through a small `QuietLog` helper
  (HermesKit) that (a) redacts with the existing diagnostic redactor, (b) drops a line identical to one logged in the
  last 60 s for the same chat, (c) is capped at 20 lines per launch.
- Retry rules: after a `message.complete` without error, re-read when `capability == .supported` **or**
  `controlReadFailed` (today only the first, `:345`); and once when the session's connection comes back
  (`LiveChatSession` reconnect hook). A failed retry does not schedule another; the next successful turn does.
- `capability == .unknown` after a failure stays unknown (so the retry can still discover support).

**Loop and heartbeat chips ("loop control partial").** `ControlRules` (`:44-47`) keeps loop and heartbeat raw today.
Add two shelf groups to the activity shelf (`docs/spec/1x-activity.md` §7.1), after Goal and before Todos, using the
same folded-chip / opened-card pattern:

Loop chip (folded): **"Loop active"**, **"Loop paused"**, **"Loop deferred"**, **"Loop finished"**; with
`awaiting_response` → " · Awaiting response". Opened card:

- header line as the chip plus " · Run <ticks_fired>/<max_ticks>" when `max_ticks > 0`, else " · <n> run" / "runs";
  plus " · next <time>" when `next_due_at` is in the future (time as "in 4 min" via the relative formatter).
- rows (label over value, value wraps, 12 pt padding): **Prompt** (up to 6 lines then "Show More"), **Cadence**
  ("every 30s" / "every 5m" / "every 2h" from `interval_seconds`; `mode == "self"`/no interval → "self-paced"),
  **Until condition** (only when `until` is non-empty).
- `deferred_by_goal` → a secondary line **"An active goal currently controls the session."**
- capsules: active → **Pause Loop**, **Stop Loop**; paused → **Resume Loop**, **Stop Loop**; finished → **Dismiss**.
  Stop Loop asks first: alert **"Stop loop?"** / **"Are you sure you want to stop this loop?"** with **Cancel** and
  destructive **Stop Loop**.

Heartbeat chip: **"Heartbeat active"** / **"Heartbeat paused"**; card rows **Prompt**, **Cadence**, " · <fire_count>
run(s)"; capsules **Pause Heartbeat** / **Resume Heartbeat**, **Clear** (no confirm; it is not destructive to work in
progress).

**⚑ DECISION**: capsule labels are Title Case natively ("Pause Loop"); the web's are sentence case ("Pause loop").
The alert keeps the web's exact sentence.

Action failures: the capsule returns to its previous state and a one-line notice under the card reads **"Couldn’t
change the loop. Try again."** (or "heartbeat"); `4004` (unknown action, older gateway) → the capsules are removed for
this chat for the launch and the card becomes read-only; `4001` → re-open the session once and retry once.

Status mapping, resolved in revision 2 (was UNKNOWN). `LoopSnapshot.status` is one of **`active`**, **`paused`**,
**`done`** (`H/hermes_cli/loops.py:180`: `active | paused | done | cleared`; a `cleared` loop is never sent, the
snapshot is `null`, `H/tui_gateway/methods_session_control.py:97-100`). `active` → active; `paused` → paused (the
reason, when present, is `paused_reason`); `done` → finished (the reason is `last_stop_reason`); `deferred_by_goal ==
true` → deferred, whatever the status. `HeartbeatSnapshot.status` is `active` or `paused`
(`H/hermes_cli/heartbeat.py:70`; `cleared` is sent as `null`). Any other word shows as active and the raw word is
logged to Diagnostics once.

### 13.3 Wire

```json
→ {"jsonrpc":"2.0","id":81,"method":"session.control.read","params":{"session_id":"s-1"}}
← {"jsonrpc":"2.0","id":81,"result":{"control":{"goal":null,
     "loop":{"prompt":"Check CI and fix failures","status":"active","mode":"interval","interval_seconds":300,
             "current_delay":300,"times":0,"until":"CI is green","max_ticks":10,"ticks_fired":3,
             "created_at":1791800000,"last_fired_at":1791800900,"next_due_at":1791801200,
             "awaiting_response":false,"deferred_by_goal":false,"paused_reason":null,"last_stop_reason":null},
     "heartbeat":null,"revision":7,"updated_at":1791800900}}}

→ {"jsonrpc":"2.0","id":82,"method":"session.control","params":{"session_id":"s-1","action":"loop.pause"}}
← {"jsonrpc":"2.0","id":82,"result":{"control":{…},"dispatch":{"type":"control","output":"","notice":"Loop paused","message":"","display":""}}}
```

Actions used here: `loop.pause`, `loop.resume`, `loop.stop`, `heartbeat.pause`, `heartbeat.resume`, `heartbeat.clear`.
Allowed keys: read `session_id`, `profile?`; control `session_id`, `action`, `args?{text?, index?}`, `profile?`.
"Dismiss" of a finished loop is local (hide the chip until the snapshot's `revision` changes).

### 13.4 Acceptance (10030 modes `control=ok|error|hang|old|loop|heartbeat`)

1. `control=error` on open → no banner, no chip, no alert; Diagnostics shows one line "Chat goal and loop didn’t
   load: …". Open the chat three times within a minute → still one line.
2. Switch to `control=loop`, send a message, reply completes → the read is retried and the Loop chip appears with no
   user action. The fixture counted exactly one extra read for that turn.
3. `control=old` (-32601) → no retry after turns (count stays), no log line after the first.
4. Loop chip → card shows Prompt, Cadence "every 5m", Until condition, "Run 3/10", "next in …". Pause Loop → "Loop
   paused" + Resume Loop. Stop Loop → alert with the exact sentence; confirm → chip "Loop finished" + Dismiss.
5. `control=hang` → the chat is fully usable; the read gives up after its timeout and logs once.
6. Fixture `control_action=fail` → capsule reverts and the notice shows.
7. Reconnect (fixture `/__composer/mode {"drop":true}` closes the socket once) → exactly one re-read after reconnect.

Goal regressions: run the existing activity e2e against 10031 unchanged.

---

## 14. Status stack groups fold one by one; background-task capsule (L461)

### 14.1 Web app

- r21 B-02 (`B/r21-chat-gates.ts`): on the phone the stack is always open and each group folds on its own; labels
  **"N background task(s)"**, **"N subagent(s)"**, each with a chevron.
- `V/store/composer-status.ts`: background tasks come from `process.list {session_id}` →
  `{processes:[{session_id (the process id), command, cwd?, pid?, status "running"|"exited", output_preview,
  output_tail?, exit_code?, uptime_seconds?, started_at?}]}`. Title = first line of `command` or "background process";
  state running / done (exit 0) / failed (non-zero); body = `output_tail`. Refresh on chat open, on `tool.complete`
  for tools named `terminal` or `process`, on `status.update` with `kind:"process"`, and every 5 s while any is
  running and the chat is visible. Stop = `process.kill {session_id, process_id}`; the row is dismissed only on a
  confirmed kill; failure "Could not stop the process". Dismissed ids stay gone. Finished rows leave on their own.
  `4001` (session gone) stops the polling. Group order: goal, todo, subagent, background.

### 14.2 Native design

The native shelf (`docs/spec/1x-activity.md` §7.1) reserved slot 4 for background tasks, between Subagents and
Previous tasks. Fill it, and make every group fold independently (verify Subagents and Todos already do; the fold
state is per chat, per group, kept for the launch).

`BackgroundTasksStore` (HermesKit, owned by `ActivityStore`):

- `refresh()` → `process.list`; coalesced (one in flight; a request during a flight schedules exactly one follow-up).
- Triggers: chat opened / resumed from background; `tool.complete` whose tool name is `terminal` or `process`;
  `status.update` with `kind == "process"`; a 5 s timer that runs only while (a) at least one task is running, (b) the
  chat is on screen, (c) the app is active. The timer is cancelled on leaving the chat and on backgrounding.
- `-32601` → capability off for the launch: no chip, no polling. `4001` → stop polling until the session is reopened.
  Other failures → keep the last list, log "Background tasks didn’t load: <reason>" through `QuietLog`, no UI.
- Item: `id` = process id; `title` = first non-empty line of `command` trimmed to 80 characters, or **"Background
  process"**; `state` = running | done | failed; `detail` = last 12 lines of `output_tail` (or `output_preview`).
- **Process claims (revision 2, required; closes offline's row L957).** After every successful `refresh()` the store
  calls `activityStore.setProcessClaims(runtimeId:profile:storedId:_:)` with one `ProcessClaim(id:running:)` per
  listed process (`running` = `status == "running"`), and with `[]` when the list is empty, the capability is off
  (`-32601`) or the session is gone (`4001`). It also listens to `onProcessClaimsChange`: when the stale check
  (offline §6.6) drops a running claim the gateway no longer lists, the matching item leaves the capsule at once (no
  "Done" flash: nobody saw it finish). The debug switch `-HQDebugProcessClaim` stays for offline's own tests. With
  this in, a Sessions row says "Working…" for a chat whose only live work is a background process, and stops saying
  it when the process ends, without the chat being open.
- Finished items leave on their own: done after 4 s, failed after 12 s (as §14 of 1x-activity for other groups),
  unless the card is open on that item, in which case when it is folded. Dismissed ids are remembered for the launch.

Chip (folded, centred like the other groups): **"1 background task"** / **"N background tasks"** + chevron; a small
spinner replaces the leading symbol (`terminal`) while any is running; a red dot when any failed.

Card (opened, full width, radius 18, glass): one row per task, 12 pt vertical padding:

- title (monospaced footnote, 2 lines max), state word on the right: **Running** (with elapsed time "2m 14s" from
  `uptime_seconds` / `started_at`, updated each second locally), **Done**, **Failed (exit 2)**.
- tap a row → expands its output (monospaced caption, selectable, up to 12 lines; "No output yet." when empty).
- running rows have a **Stop** capsule. Tap → capsule becomes a spinner; `process.kill`; on `status` that confirms the
  kill the row leaves at once (warning haptic `notification.warning` is not used; use the rigid impact, as Stop
  elsewhere). On failure the capsule returns and the row shows **"Couldn’t stop this task."** in red footnote for 6 s.
  **⚑ DECISION**: "Couldn’t stop this task." instead of the web's "Could not stop the process" — the chip calls them
  tasks, and the app's failure lines all start "Couldn’t".
- No confirm before Stop (the web has none; the task can be started again by the bot).

Order of groups on the shelf: Goal, Loop, Heartbeat (§13), Todos, Subagents, **Background tasks**, Previous tasks.

### 14.3 Wire

```json
→ {"jsonrpc":"2.0","id":91,"method":"process.list","params":{"session_id":"s-1"}}
← {"jsonrpc":"2.0","id":91,"result":{"processes":[
     {"session_id":"proc_ab12","command":"npm run dev\n","cwd":"/home/fx/proj","pid":4211,"status":"running",
      "output_preview":"ready on :3000","output_tail":"…\nready on :3000","exit_code":null,"uptime_seconds":134,"started_at":"2026-10-13T02:14:26"}]}}

→ {"jsonrpc":"2.0","id":92,"method":"process.kill","params":{"session_id":"s-1","process_id":"proc_ab12"}}
← {"jsonrpc":"2.0","id":92,"result":{"status":"killed","session_id":"proc_ab12","exit_code":-15}}
                                       // or {"status":"not_found"} / {"status":"error","error":"…"}
```

Allowed keys: list `session_id`, `profile?`; kill `session_id`, `process_id`, `profile?`.
Resolved in revision 2 (was UNKNOWN), from `H/tui_gateway/contracts/tools_commands.py:86-149`:

- `process.kill` answers `status` ∈ **`killed`**, **`already_exited`**, **`not_found`**, **`error`** (`error` text
  rides on the failures). `killed` and `already_exited` are a confirmed stop: the row leaves at once. `not_found`:
  the process is gone from the gateway's list, so the row leaves too, without the failure line (telling the owner
  "Couldn’t stop" about something that is no longer running would be wrong). `error`, any other word, an RPC error or
  a timeout (15 s): **"Couldn’t stop this task."**
- `ProcessEntry.started_at` is a **string** (ISO date-time), not a number; `uptime_seconds` is an integer. Elapsed
  time is taken from `uptime_seconds` at the moment of the read and counted on locally; `started_at` is only a
  fallback (parse ISO 8601, with and without a time zone; unparseable → no elapsed time shown, never "0s").
- Other entry fields exist and are ignored (`owner_task_id`, `session_scoped`, `watch_patterns`, `watch_hit`,
  `notify_on_complete`, `exited_at`, `completion_reason`, `detached`); the model is open, so new ones must not fail
  the decode. `status` is `"running"` or `"exited"`; anything else is treated as exited.

### 14.4 Acceptance (10030 modes `procs=0|1|3|fail_kill|old|hang`; subagents on 10031)

1. `procs=1` → chip "1 background task"; `procs=3` → "3 background tasks". Tap → card with three rows.
2. With subagents also present (fixture combines both in mode `shelf=full`): folding Background tasks leaves Subagents
   open and the other way round; fold states survive leaving and re-entering the chat.
3. Running row shows a ticking elapsed time; the fixture sees a `process.list` about every 5 s while the chat is open
   and none within 12 s after leaving the chat or backgrounding the app.
4. Stop → row leaves; fixture got one `process.kill` with the right id. `fail_kill` → "Couldn’t stop this task." and
   the row stays. Fixture answer `not_found` (mode `procs=gone_kill`) → the row leaves with no failure line.
4a. Process claims: with `procs=1` the fixture's chat row on Sessions reads "Working…" after leaving the chat; when the
   process exits (the fixture's 8 s one) the row stops saying it within one stale-check period (30 s) with the chat
   closed. `ActivityStore.processClaims(runtimeId:)` equals the listed processes after each refresh (unit test with
   a fake transport), and is empty after `-32601`.
5. A task that exits 0 → "Done" then gone after ~4 s; exit 2 → "Failed (exit 2)" for ~12 s.
6. `old` → no chip and exactly one `process.list` for the launch. `hang` → the chat is unaffected.
7. `tool.complete` for `terminal` triggers one refresh (count check).

---

## 15. Queue row: Send Now (steers when it can) plus ⋯ (L463)

### 15.1 Web app

`S/ui-chat/queue-model.ts`, `S/ui-chat/queue-view.tsx`.

- Header (`queueHeader`): parked → **"Queue Paused"** / **"Queue Paused · N Messages"**; else **"Queued"** /
  **"N Queued"**, plus while a reply runs **" · Sends After This Reply"** (one) / **" · Send After This Reply"**
  (several). With nothing waiting: **"Sending…"** or **"Delivery Unconfirmed"**.
- Row text: the message; a hidden one reads **"Setup Note"**; attachment-only reads the attachment's label or
  **"N attachments"**; nothing at all **"Empty Message"**. Caption under it when relevant: **"Sending…"**,
  **"Delivery Unconfirmed"**, **"Editing"**, **"N attachment(s)"**.
- One primary button **Send Now**: idle → sends; busy and steerable → steers into the running reply; busy and not
  steerable → not offered. Steerable = non-empty text, no attachments, not a slash command (`^\/[^\s/]*(?:\s|$)`).
- ⋯ menu: **Send Now**, **Stop and Send** (`stop.fill`, only while a reply runs), **Edit** (`pencil`), **Delete**
  (`trash`, destructive, off while that row is sending). Tapping the message opens the same menu.
- Queue taps keep the keyboard up. Edit strip **"Editing Queued Message"** with **Cancel** / **Save**.
- Steer (`V/app/chat/composer/hooks/use-composer-queue.ts:312-343`,
  `V/app/session/hooks/use-prompt-actions/index.ts:770-850`): `session.redirect {session_id, text}` →
  `{status:"redirected"|"queued"|"rejected", text}`. The user bubble is added after the running reply before the
  call; redirected/queued → the queue entry is removed and the queue un-pauses (queued → the bubble moves to the
  tail); rejected or error → the bubble is discarded and the entry stays queued. A stale runtime is resumed and the
  call retried once. Gateway (`H/tui_gateway/methods_session_interrupt.py:84-143`): `4002` "text is required", `4010`
  "agent does not support active-turn redirect", `5000` "redirect failed: …".
- Owner (`MEM/phone-queue-row`): the old row was "clunky as hell"; approved: always open, message full width, one
  "Send Now" (steers into the running turn), a ⋯ native menu (Send Now / Stop and Send / Edit / Delete), queue taps
  keep the keyboard up, edit strip "Editing Queued Message" with Cancel / Save; a refused queued send must still
  retry; a continued truncated reply counts as the same bubble.

### 15.2 Native: what exists

`ChatQueueCard` (`NAT/App/Chat/ChatQueueCard.swift`) with headers "Queued · paused after Stop" etc., icon buttons
"Send Now" and "Remove from Queue", "and N more", hidden rows "Continue toward goal", memo rows. `LiveChatSession`:
`sendQueuedNow` (stop + drain, `:901-917`), `removeQueued` (`:920-929`), `parkQueue` / `unparkQueue`,
`drainQueueHead`, `QueueStash` persistence.

### 15.3 Native design

Rewrite the card's rows and header; keep its place (above the composer), its glass and its persistence.

**Header** — the web strings exactly:

| Queue state | Header |
|---|---|
| paused, 1 waiting | **Queue Paused** |
| paused, N waiting | **Queue Paused · N Messages** |
| idle or sending the head, 1 | **Queued** |
| N | **N Queued** |
| reply running, 1 | **Queued · Sends After This Reply** |
| reply running, N | **N Queued · Send After This Reply** |

Trailing header control: **Resume** when paused (§16).

**Row** (every queued message is listed; the card scrolls inside itself past 4 rows, max height 40% of the space above
the composer; "and N more" is removed — **⚑ DECISION**: the owner approved "always open, message full width", and a
hidden tail hides the very rows the ⋯ acts on):

- Message text, full width, body size, up to 3 lines then truncated at the end; 13 pt vertical padding.
  Hidden → **"Setup Note"** (**⚑ DECISION**: replaces native's "Continue toward goal" with the web's word).
  Voice memo rows keep the existing "Voice Memo 0:12" label. Attachment-only → the attachment's name, or
  **"N attachments"**. Nothing → **"Empty Message"**.
- Caption (footnote, secondary) when relevant: **"Sending…"**, **"Editing"**, **"1 attachment"** / **"N attachments"**
  (when there is also text).
- Trailing: a **Send Now** text capsule (not an icon; glass capsule, tinted label) when offered, then a ⋯ button
  (`ellipsis`, 44 × 44 hit area, `showsMenuAsPrimaryAction`).
- Tapping the row body opens the same menu (the row is a `UIButton`-backed view with the same `UIMenu`).
- Nothing in the card takes first responder; all controls are plain `UIControl`s, so the keyboard stays up and the
  draft is untouched. Presenting a `UIMenu` does not lower the keyboard.

**Send Now** offered when: idle (and the row is not sending) → sends it now (promote to head, un-pause, drain);
busy and steerable → steer; busy and not steerable → no capsule (the ⋯ still has Stop and Send).

`QueuedMessage.steerable`: `!hidden`, text non-empty after trimming, no attachments, no memo, and the text does not
match `^\/[^\s/]*(?:\s|$)`.

**⋯ menu** (in order; the system adds the destructive tint):

| Item | Symbol | Shown when | Does |
|---|---|---|---|
| Send Now | `arrow.up` | Send Now is offered and no row is being edited | same as the capsule |
| Stop and Send | `stop.fill` | a reply is running, no row being edited | existing `sendQueuedNow` (promote, un-pause, interrupt, drain when the stop settles); rigid haptic |
| Edit | `pencil` | text-only, not hidden, not sending; disabled while another row is being edited | §15.5 |
| Delete | `trash` (destructive) | always; disabled while this row is sending | removes the row, no confirm, light impact |

**⚑ DECISION**: native's "Remove from Queue" (which put the text back in the field) is replaced by the web's two
separate actions, Edit (get the words back) and Delete (throw them away), per the owner-approved menu.

**As built (audit 863):** the card lists three rows, then **Show N More** / **Show Less**, which opens the rest in place
in a capped, scrolling list (UX study fixes, 2026-10-19/22: every row can still be sent, edited or deleted), rather than
every row with no toggle. A hidden row still reads **"Continue toward goal"** (1x-activity §6.4 asks for it; "Setup
Note" here is a wording the owner hasn't picked between). A row with nothing at all reads **"Empty Message"**; the
captions are **"Sending…"** (while Send Now steers it), **"Editing"**, and the attachments' words ("2 Photos") beside
typed words. Tapping a row's words opens the ⋯ menu. ⋯ reads "More, <the row's opening words>" to VoiceOver. Delete
throws the row away with its photos, files and memo (a memo asks first, "Delete this 0:12 voice memo?", as deleting a
memo does everywhere else). Edit is offered for typed words only (no photo, file, memo or skill send; those have
Delete).

### 15.4 Steering

`LiveChatSession.steerQueued(_ id:) async`:

1. Take the shared queue lock (§17.4); if it is held, do nothing (the capsule is disabled while held).
2. If no reply is running any more → fall through to a normal send-now.
3. Mark the row "Sending…"; add an optimistic user bubble directly after the running reply's current position (in the
   inverted table: the reply keeps streaming above/after it exactly as the web orders them — the bubble is placed
   after the active reply; when the reply continues after the redirect it is the **same** bubble continuing, per the
   owner's "truncated-reply continuation counts as same bubble").
4. Call `session.redirect`.
5. `redirected` → remove the queue row, un-pause the queue, selection haptic. `queued` (the gateway will take it at
   the next safe point) → same, and the bubble is moved to the newest end. `rejected`, `4010`, `5000`, transport
   failure → remove the optimistic bubble, the row returns to plain queued (it will send after the reply), and a
   transient notice reads **"Couldn’t add this to the running reply. It’ll send after this reply."** If `4010`,
   remember "no redirect" for this chat for the launch: Send Now is not offered while busy from then on.
   `-32601` → same as `4010`.
6. `4001` (stale session) → resume once, retry once, then treat as failure.
7. Release the lock.

```json
→ {"jsonrpc":"2.0","id":101,"method":"session.redirect","params":{"session_id":"s-1","text":"also update the README"}}
← {"jsonrpc":"2.0","id":101,"result":{"status":"redirected","text":"also update the README"}}
```

Allowed keys, resolved in revision 2 (was UNKNOWN): exactly `session_id`, `text` and optional `profile`
(`SessionCorrectionParams(SessionParams)`, `H/tui_gateway/contracts/sessions.py:623-641`, `common.py:224-228`). There
is no idempotency key, so the phone's own lock (§17.4) is the only guard against a double steer. The answer is
`{status, text}` with `status` ∈ **`redirected`**, **`queued`**, **`rejected`**, as step 5 assumes. (`session.steer`
shares the same params and result; this stream does not call it.)

### 15.5 Edit

Edit puts the composer into "editing a queued message" mode:

- a strip above the field (inside the composer's glass, 32 pt tall): **"Editing Queued Message"** on the left,
  **Cancel** and **Save** (tinted, semibold) on the right; Save is disabled when the field is blank;
- the current draft is set aside and restored afterwards (never lost); the field shows the queued text with the caret
  at the end; the field takes focus (keyboard rises if it was down);
- the row's caption reads **"Editing"**; other rows' Edit is disabled; the queue does not send the row being edited
  (if it reaches the head while a reply ends, the drain waits for Save or Cancel, with the rows behind it also
  waiting);
- **Save** → the row's text is replaced in place (same position, same id), strip closes, the set-aside draft returns;
- **Cancel** or Esc → nothing changes; strip closes; draft returns;
- the primary button while editing is Save (Return on a hardware keyboard = Save); Stop remains available through
  Esc? No: while editing, Esc cancels the edit (§3.2 step 2); the Stop button is hidden behind Save for that moment.
  **⚑ DECISION**: to stop a reply while editing, Cancel first; the web has the same order.
- leaving the chat while editing = Cancel.

**As built (audit 863):** the strip is the composer's edit banner (the glass capsule Edit Message and Reply use, above
the row) with **Cancel** and **Save** in words; the mic hides while editing; Return in an empty field keeps editing. A
message edit or a reply started meanwhile cancels the queued edit first. Esc does not cancel it yet (the Escape ladder
has no rung for it).

### 15.6 Acceptance (10030 modes `redirect=ok|queued|rejected|4010|hang|old`, reply `slow`)

1. Queue two messages during a slow reply → header "2 Queued · Send After This Reply"; both rows fully listed.
2. Tap Send Now on the first → fixture got `session.redirect` with its text; row gone; header "Queued · Sends After
   This Reply"; a user bubble with that text is in the transcript; the reply keeps streaming.
3. `rejected` → the bubble is not left behind; the row is still queued; the notice shows; when the reply ends the row
   sends normally (fixture got `prompt.submit`).
4. `4010` → after one failure, Send Now is no longer offered while busy; ⋯ still has Stop and Send.
5. A queued message with a photo, and one that is `/help`: no Send Now capsule while busy; idle → capsule present.
6. ⋯ › Stop and Send → reply stops, the message is sent, the rest of the queue follows (queue not left paused).
7. ⋯ › Edit → strip "Editing Queued Message"; change the text; Save → row shows the new text in the same position;
   the draft that was in the field before is back. Cancel leaves it unchanged.
8. ⋯ › Delete → row gone; nothing in the field.
9. Every queue tap with the keyboard up leaves it up (assert the keyboard frame before/after each tap).
10. Idle + paused queue: Send Now on row 2 → it sends first, the queue un-pauses and the rest follow.
11. Relaunch with 3 queued → the same 3 rows (QueueStash), header "Queue Paused · 3 Messages" (see §16.2).

---

## 16. Queue Paused after Stop, with Resume (L464)

### 16.1 Web app

`S/ui-chat/queue-view.tsx`: after Stop the queue is parked; the header reads **"Queue Paused"** / **"Queue Paused · N
Messages"** and a **Resume** button shows when something is waiting. Resume un-parks; the queue then sends (now if
idle, after the reply if one is running).

### 16.2 Native design

Native already parks after Stop (`LiveChatSession.stop()` → `parkQueue`). Add:

- Header strings per §15.3 (replacing "Queued · paused after Stop").
- **Resume**: a text capsule at the header's trailing edge (glass, tinted label, 44 pt hit height), shown only when
  paused and at least one row waits. Tap → selection haptic, `unparkQueue()`, and if idle `drainQueueHead()`.
  Accessibility label **"Resume queue"**; id `queue.resume`.
- Sending a new message from the composer while paused un-pauses (existing rule, `send` `:655-680`) — the new message
  goes to the tail and the queue drains in order.
- Pause is also the state after: a refused send (`refuseSend`), delivery unconfirmed (§17), and a cold relaunch with
  rows in `QueueStash`. **⚑ DECISION**: after a relaunch the restored queue starts paused (with Resume) rather than
  sending by itself — the web's rule "an uncertain send is never auto-resent after a cold launch" extended to the
  whole queue, so nothing is sent that the person did not just ask for. `QueueStash` does not need to store the flag.
- Paused + a reply running (the user sent something new by other means, e.g. a steer): header stays "Queue Paused…";
  Resume un-pauses and the header becomes "…Send After This Reply".

### 16.3 Acceptance (10030, reply `slow`)

1. Queue two, tap Stop → header "Queue Paused · 2 Messages" with Resume; nothing is sent (fixture count unchanged for
   10 s).
2. Resume → first sends at once, the second after its reply; header follows §15.3 at each step.
3. Paused with one row → "Queue Paused".
4. Paused, type a new message and Send → queue un-pauses, order is old rows first then the new one.
5. Force-quit and relaunch with two queued → "Queue Paused · 2 Messages"; nothing sent until Resume or Send Now.
6. VoiceOver: header read as "Queue paused, 2 messages", then "Resume queue, button".

---

## 17. Stuck queue / Delivery Unconfirmed (L465)

### 17.1 Web app

`S/ui-chat/queue-recover.ts`, `B/queue-row-gates.ts:100-118`, `B/fix161-owners-gates.ts`.

- An uncertain send (the phone did not get the gateway's answer) is marked **Delivery Unconfirmed**. Its ⋯ menu:
  **Check Delivery** (`arrow.clockwise`), **Send Again** (`arrow.up`), **Edit** (`pencil`), **Copy** (`doc.on.doc`),
  **Delete**; Edit and Copy only for text-only, non-hidden messages. The primary button reads **Check** ("Checking…"
  while it runs).
- Send Again: the row goes back to ordinary queued (sends now when idle, after the reply when busy), shows progress
  for at least 800 ms, then toast **"Sent"**, or an alert titled **"Couldn’t Send"** with the reason (default **"Your
  gateway didn’t take the message."**) and **Try Again**.
- Edit puts the text back in the composer then deletes the row; if that fails: **"Couldn’t put this message back in
  the composer. Copy it instead."** Copy → toast **"Copied"** / **"Couldn’t copy this message"**.
- Stuck queue: an exception while draining marks the row unconfirmed, pauses the queue and shows a notice titled
  **"Queued message not sent"**: **"A queued turn kept failing to send. It is still in the queue — try sending it
  again."**
- Drain retries and steering share one lock. An uncertain send is never re-sent by itself after a cold launch.

### 17.2 Native: what exists

`markUnconfirmed` puts the error "Delivery unconfirmed" on the **transcript bubble** and parks the queue;
`checkDelivery(messageId) async -> Bool?` (`LiveChatSession.swift:1045-1068`) reads the last 24 history rows;
`ChatViewController.chatCellCheckDelivery` (`:2381`) with notices "The computer running Hermes doesn’t have this message yet." /
"Couldn’t check right now. Try again in a moment." Only **Check** is offered.

Added by the sessions stream since revision 1 (§0.2): `LostSends` keeps each marked text message on disk
(`noteLostSend` in `markUnconfirmed`, `clearLostSend` when Check finds it), the Sessions row reads "Not Delivered:
<words>", and `restoreLostSends()` puts the marked bubble back when the chat opens after a relaunch, unless the first
history page already holds the same words past `entry.after` (then it arrived and the entry is cleared quietly).
Memos and hidden continuations are not kept there.

### 17.3 Native design

**⚑ DECISION**: the unconfirmed message stays where native already shows it — as your bubble in the transcript, in
the place it was sent — instead of moving into the queue card as on the web. A message that may well have arrived
belongs in the conversation; the queue card stays "things not sent yet". All of the web's actions are offered on that
bubble.

Under the bubble: the status line **"Delivery Unconfirmed"** (footnote, warning colour; fix the casing from "Delivery
unconfirmed") with a **Check** capsule (existing) and a ⋯ button; holding the bubble shows the same items at the top
of its hold menu.

| Item | Symbol | Shown | Does |
|---|---|---|---|
| Check Delivery | `arrow.clockwise` | always | runs `checkDelivery`; capsule reads **"Checking…"** meanwhile. Found → the status line disappears (it is a normal sent bubble), queue un-pauses if nothing else is unconfirmed, success haptic. Not found → notice **"The computer running Hermes doesn’t have this message yet."** Could not check → **"Couldn’t check right now. Try again in a moment."** |
| Send Again | `arrow.up` | always | below |
| Edit | `pencil` | text-only, not hidden | puts the text into the composer (appending after an existing draft with a blank line between, caret at the end, keyboard up), then removes the bubble. If the composer cannot take it (editing a queued message at that moment) → notice **"Couldn’t put this message back in the composer. Copy it instead."** and the bubble stays. |
| Copy | `doc.on.doc` | text-only, not hidden | copies; notice **"Copied"**; on failure **"Couldn’t copy this message"** |
| Delete | `trash` (destructive) | always | removes the bubble locally (no confirm); if nothing else is unconfirmed the queue stays paused with Resume |

**Send Again**: first a silent `checkDelivery` (so a message that did arrive is not doubled): found → treat as Check
Delivery "found" and stop. Otherwise the bubble is removed and its message is put at the **head** of the queue as an
ordinary row, and the queue is un-paused: idle → it sends now; busy → after this reply. The row (or, when it sends at
once, the new bubble) shows **"Sending…"** for at least 800 ms. Accepted → notice **"Sent"**. Refused or failed again
→ alert **"Couldn’t Send"**, message = the reason in words or **"Your gateway didn’t take the message."**, actions
**Try Again** (repeats Send Again) and **Cancel**; the message stays as an unconfirmed bubble.

**Stuck queue.** In `drainQueueHead`, if sending the head throws or is refused **twice in a row** for the same row
(the first failure retries once after 2 s; "a refused queued send must still retry" — `MEM/phone-queue-row`):
the row stays in the queue with the caption **"Delivery Unconfirmed"** only if the phone cannot tell whether the
gateway got it (lost answer), else plain; the queue pauses; a notice banner (the existing chat notice style) shows
title **"Queued message not sent"** and body **"A queued turn kept failing to send. It is still in the queue — try
sending it again."** The row's ⋯ then offers Check Delivery, Send Again, Edit, Copy, Delete as in the table (Send
Again on a queue row = un-pause and drain from that row). The header reads "Queue Paused…" with Resume.

**After a cold launch** nothing unconfirmed is ever re-sent by itself. Resolved in revision 2 (was UNKNOWN): the
marked bubble **does** come back after a relaunch, through the sessions stream's `LostSends` (§17.2), with a new local
id (`rekey`). This stream therefore builds no second store and no "restore as a paused queue row" fallback. What it
must do instead:

- The status line, **Check** and ⋯ are drawn from the bubble's error mark alone, so a restored bubble gets the full
  menu with no extra code; verify it (acceptance 9).
- **Send Again**, **Edit** and **Delete** each call `clearLostSend(messageId)` at the moment the bubble is removed
  (Send Again: when the bubble is taken out to become the queue head; if that send is itself lost it is marked and
  noted again by `markUnconfirmed`). Otherwise the Sessions row would go on saying "Not Delivered:" about a message
  that is gone. **Copy** and a **Check** that does not find it leave the entry alone.
- A memo's unconfirmed bubble is not in `LostSends` (it is never re-sent; its file went to the cache): its menu offers
  **Check Delivery** and **Delete** only, as "text-only" already implies.
- A titled request (presence stream's `sentTitles`): Edit and Copy use the shown title; Send Again sends through
  `send(_:display:)`, which maps the title back to its prompt. `checkDelivery` already compares the stored prompt.
- The 20-per-chat cap of `LostSends` means a 21st marked message is on screen but not kept across a relaunch. That
  is the sessions stream's limit and is left alone; stress R10 records what happens (the words must still be on
  screen until the chat is closed).

### 17.4 One lock for drain and steer

`LiveChatSession` gains a single `queueBusy` flag (MainActor; an `async` critical section, not a thread lock):

- taken by: `drainQueueHead` (from idle-after-reply, Resume, Send Now, Stop and Send, the 2 s retry), `steerQueued`,
  `Send Again`;
- while held: Send Now capsules, Resume and the menu's send items are disabled (visibly: 40% opacity) and a second
  request is ignored, not queued;
- released on every exit path (`defer`), including cancellation when the chat closes;
- the 2 s retry timer checks the row id is still the head and still unsent before sending (it may have been steered,
  edited or deleted meanwhile).

This is what stops a row being sent twice when a reply ends at the same moment the user taps Send Now.

### 17.5 Wire

`prompt.submit` (send), `session.redirect` (steer), history read used by `checkDelivery` (existing). No new method.

### 17.6 Acceptance (10030 modes `submit=lost_once|lost_always|refuse|ok`, `history=has|hasnt|fail`)

1. `submit=lost_once` (the fixture takes the message but never answers and drops the socket) → bubble with "Delivery
   Unconfirmed", Check and ⋯; queue (if any) paused.
2. Check Delivery with `history=has` → status line gone. With `hasnt` → "The computer running Hermes doesn’t have this message yet."
   With `fail` → "Couldn’t check right now. Try again in a moment."
3. Send Again with `history=has` → not re-sent (fixture `prompt.submit` count unchanged), status cleared.
4. Send Again with `hasnt`, `submit=ok` → exactly one new `prompt.submit`; "Sending…" visible ≥ 800 ms; "Sent".
5. Send Again with `submit=refuse` → alert "Couldn’t Send" / "Your gateway didn’t take the message." with Try Again.
6. Edit → the text is in the composer, the bubble is gone; Copy → pasteboard holds the text, "Copied".
7. Queue of two, `submit=lost_always`, let the reply end → after one retry the banner "Queued message not sent" with
   the exact body; header "Queue Paused · 2 Messages"; the fixture saw at most 2 `prompt.submit` for that row.
8. Race: 50 runs of "reply ends within the same 50 ms as a Send Now tap" (fixture mode `race=1` ends the reply when it
   receives a control ping the UI test sends right before tapping) → the message is sent exactly once in all 50
   (fixture counts `prompt.submit` + `session.redirect` per text; total is 1).
9. Force-quit with an unconfirmed bubble and two queued → relaunch: zero sends in 15 s; the bubble is back with
   "Delivery Unconfirmed", Check and ⋯ (all five items work on the restored bubble); the queue is paused with Resume.
10. Sessions row: with an unconfirmed bubble the chat's row reads "Not Delivered: <words>". After **Delete** → the row
   no longer says it. After **Edit** → it says "Draft: <words>" instead. After **Send Again** accepted → neither.
11. A reconnect while the lock is held (fixture `drop=true` during a slow `session.redirect`): the lock is released,
   the row is plain queued, Send Now is enabled again within 1 s of the socket returning.

---

## 18. New fixture: `scripts/fixtures/composer-gateway.py`

Same construction as `scripts/fixtures/menus-gateway.py`: loads ref238 `performance-fixture-gateway.py` as a module
and layers on it. Strict params (unknown key → 4000, counted in `param_errors`). Flags `--port N --credentials PATH`
(writes the sign-in URL/token file the UI tests read). Binds `127.0.0.1` only.

Control endpoints (plain HTTP on the same port):

- `GET /__composer/state` → JSON: `last_submit {session_id,text}`, per-method call counts and ordered log
  (`calls: [{method, params, t}]`), `param_errors`, `complete_path_cwds`, `process_kills`, `redirects`.
- `POST /__composer/mode` with any subset of the keys below → sets modes; answers the full mode map.
- `POST /__composer/reset` → default modes, cleared counters, original seed data.
- `POST /__composer/event` `{type, session_id, payload}` → pushes an event to connected sockets (used for
  `tool.complete`, `status.update`, `approval.request`, ending a slow reply for the race test).

Modes (default first):

| Key | Values | Effect |
|---|---|---|
| `reply` | `fast`, `slow`, `very_slow` | reply streams in 0.3 s / 12 s / 120 s |
| `fail` | `none`, `auth`, `billing`, `model_not_found`, `context_overflow`, `plain`, `weird_layer` | `message.complete` with `error` + the matching `error_surface` |
| `submit` | `ok`, `lost_once`, `lost_always`, `refuse` | lost = take the message into history per `history`, never answer, close the socket; refuse = error 4009 |
| `history` | `has`, `hasnt`, `fail` | whether a lost message appears in the history read; `fail` = history read errors |
| `redirect` | `ok`, `queued`, `rejected`, `4010`, `hang`, `old` | `session.redirect` answers |
| `complete` | `ok`, `hang`, `old`, `slow_stale` | `complete.slash` / `complete.path`; `slow_stale` delays answers for short queries by 1.5 s |
| `compress` | `ok`, `pending`, `noop`, `aborted`, `error`, `hang`, `old` | `session.compress` |
| `side` | `ok`, `old`, `error` | `prompt.btw` / `prompt.background`; `ok` emits the `*.complete` event after 1 s |
| `control` | `ok`, `error`, `hang`, `old`, `loop`, `heartbeat` | `session.control.read`; `ok` = all null |
| `control_action` | `ok`, `fail`, `4004` | `session.control` |
| `procs` | `0`, `1`, `3`, `fail_kill`, `gone_kill`, `old`, `hang` | `process.list` / `process.kill`; one of the three exits 0 after 8 s, one exits 2 after 15 s |
| `shelf` | `plain`, `full` | `full` adds two subagents alongside `procs` |
| `models` | `ok`, `fail_once`, `fail_twice`, `hang`, `error_text` | `model.options` (fail counters reset by `/reset`) |
| `fs` | `ok`, `enoent`, `eacces`, `hang`, `huge`, `http500` | `/api/fs/list`; `huge` = 2,000 folders |
| `mkdir` | `ok`, `fail`, `old` | `POST /api/files/mkdir`; `old` = 404 |
| `approval` | `none`, `short`, `long` | on the next submit, emit `approval.request` (long = 60-line command) after a 40-message seeded transcript |
| `drop` | `false`, `true` | `true` closes the socket once, then resets itself |
| `race` | `0`, `1` | `1`: `POST /__composer/event {"type":"__end_reply"}` ends the slow reply immediately |
| `garbage` | `none`, `types`, `huge`, `nulls` | bad-data mode for §19.4: wrong JSON types, 200 KB strings, nulls in every optional and several required fields of the answers above |

Seed data: three bots (`default` "Scout" primary, `claude` "Claude", `ops` "Ops Bot"); chats with folders
`/home/fx/proj` and `/home/fx/other`; a fake tree under `/home/fx` including `.config`, `.env`, `src/main.py`,
`src/util/`, `my docs/`; a catalog with `/help /new /model /reasoning /compress /btw /background /resume /debug
/worktree /pet` and two skills; `complete.slash` options for `/reasoning` (low, medium, high) and `/model`.

`scripts/e2e-composer.sh [SIM_UDID] [RUNS]`: builds once (`scripts/build.sh test <udid>` conventions), starts the
fixture on `${HQN_COMPOSER_PORT:-10030}`, runs `ComposerUITests` RUNS times, prints per-run pass/fail, and stops the
fixture by the PID it recorded. It refuses to start if the port is already in use (never talk to a port it did not
open).

Unit tests (no simulator needed, `HermesKitTests`): `LinkText`, `RefValue`, `ComposerDrawerModel` (trigger regexes,
40+ cases incl. e-mail addresses, CJK, emoji, caret mid-text), `ErrorRecovery.plan`, `QueuedMessage.steerable`, queue
header strings (every row of §15.3's table), `QuietLog` (collapse and cap), loop header/cadence formatting,
`BackgroundTasksStore` state mapping, the two-try model load (fake transport).

---

## 19. STRESS PLAN

The stress tester uses simulator **HQN-m9-composer-s** and ports **10035-10039** with the same scripts. Every check
names the pass line. A check that cannot be run says so in the report; it is never counted as passed.

### 19.1 Load

| # | Check | Pass |
|---|---|---|
| L1 | 200 queued messages (script the UI test to send 200 during `reply=very_slow`) | card scrolls at ≥ 55 fps on the simulator's frame counter; typing in the field stays under 16 ms per keystroke (signpost in `textChanged`); memory growth < 30 MB |
| L2 | Catalog of 1,500 commands + 500 skills (fixture seed override `--big-catalog`) and type "/a…" 40 keystrokes | each keystroke's drawer update < 8 ms main-thread (local filter); no dropped keystrokes; one `complete.slash` in flight at most |
| L3 | `fs=huge` in the folder picker and "@folder:" in the drawer | list appears < 500 ms after the answer; scroll smooth; drawer shows the first 50 and filters as typed |
| L4 | `procs` overridden to 60 tasks with 12-line tails | card opens < 200 ms; polling every 5 s does not hitch scrolling of the transcript (no frame > 33 ms attributable to the refresh) |
| L5 | 40 link chips + 10 folder chips on one draft | tray scrolls; Send builds the ref block in order; `last_submit.text` has 50 ref lines |
| L6 | Transcript of 3,000 messages with an approval at the newest end, jump from the top | "Approval needed" tap lands within ± 1 pt of 16 pt in < 600 ms |
| L7 | `/compress` answering with 2,000 `messages` | transcript rebuild < 1.5 s, no blank flash longer than one frame |

### 19.2 Speed

- Drawer open on "/" → first rows on screen within 1 frame when the catalog is cached; ≤ 150 ms with a cold catalog
  on a fast fixture.
- Send Now (steer) tap → optimistic bubble in ≤ 100 ms regardless of the RPC time (`redirect=hang` proves it).
- Link alert opens ≤ 300 ms after the menu tap; snippets sheet ≤ 300 ms.
- Hardware Return → bubble in the same frame budget as the Send button (compare signposts; difference < 5 ms).
- No main-thread JSON work > 4 ms for any single answer in §9, §10, §14 (decode off the main actor where the answer
  can be large: `process.list`, `complete.path`, `fs/list`).

### 19.3 Bad network

For each of: `complete=hang`, `redirect=hang`, `compress=hang`, `control=hang`, `procs=hang`, `models=hang`,
`fs=hang`, and `drop=true` fired mid-call:

- the composer keeps typing and sending normally; nothing spins forever (each call has a timeout: completions 5 s,
  redirect 15 s, compress 300 s with the row saying so, control read 15 s, process list 10 s, models 30 s × 2, fs 15 s);
- after the timeout the state is the one named in the row's spec (not a generic error);
- `drop=true` during `session.redirect`: the outcome is unknown, so the optimistic bubble is kept and marked
  "Delivery Unconfirmed" with the §17 actions (**⚑ DECISION**: a steer whose answer was lost is treated like a send
  whose answer was lost — never silently re-sent, never silently dropped). The queue row is removed only when Check
  Delivery finds it or the user chooses; pass = the text appears in history at most once.
- `drop=true` during `process.kill`: the row stays with Stop available again after reconnect; no "Couldn’t stop"
  until a real answer says so.
- Network Link Conditioner "Very Bad Network" profile on the Mac is **not** to be used (shared machine); slow modes of
  the fixture stand in for it.
- Reconnect storm: `drop=true` 20 times at 1 s intervals → exactly one `session.control.read` and one `process.list`
  per successful reconnect, no overlapping duplicates, no sign-in attempts in a loop (count auth calls: ≤ 1 per
  reconnect).

### 19.4 Bad data

`garbage=types|huge|nulls` across every new call, plus hand-made cases:

- `complete.slash` items missing `text`, `text` not a string, `replace_from` negative / beyond the text / a string →
  item skipped; out-of-range `replace_from` treated as "replace the whole argument"; never an index crash.
- `complete.path` items with newlines, right-to-left override characters, 5,000-character paths, emoji and combining
  marks → shown on one line (control characters stripped), middle-truncated; inserted text is the raw `text` with
  control characters removed.
- `process.list` with `status` unknown, `exit_code` a string, `command` null or 1 MB, `output_tail` with ANSI colour
  codes and NULs → unknown status shown as Running with no elapsed time; command cut to 80 chars; ANSI and control
  characters stripped from output.
- `session.redirect` answering `{}` or `status:"maybe"` → treated as rejected.
- `session.compress` with `removed:"many"`, `summary: null`, `messages: {}` → result line falls back in the order of
  §8.3 step 5; a `messages` that is not an array is ignored (transcript untouched).
- `error_surface` a string, an array, with `layer` 300 characters long, `resets_at` in 1970 or year 9999 or a string →
  no capsule from a malformed surface; absurd dates ignored.
- `session.control.read` with `loop.interval_seconds` 0, negative, 10^12; `next_due_at` in the past; `prompt` 100 KB →
  cadence "self-paced" for ≤ 0; huge intervals render in hours without overflow; prompt cut with Show More.
- `/api/fs/list` entries missing `path` or `name`, duplicate names, a name of "/" or "..", `isDirectory` as "true" →
  skipped or coerced safely; the picker can never navigate above `/` or to an empty path.
- Link field: 10,000-character paste, a `javascript:` URL, `https://` alone, a URL with spaces, an IDN host
  (`bücher.de`), an IPv6 literal (`[::1]:8080`) → no crash; `javascript:` never attaches (not http/https);
  `https://` alone is not a link; IDN and IPv6 without a scheme are left as typed (Attach disabled, hint shown), and
  with `https://` typed they attach.
- A queued message whose text is only a zero-width space, or 200 KB → "Empty Message" for the first; the second shows
  3 lines and steers/sends without freezing the card.
- Gateway text containing the banned word is not rewritten (it is the gateway's text), but none of the app's own
  strings contain it: `grep -rni "dispatch" App HermesKit --include="*.swift" | grep -v "command.dispatch\|DispatchQueue\|dispatch\b.*//"`
  must show no user-visible string literal (review by hand).

Pass for the whole section: zero crashes, zero hangs > 250 ms, and `param_errors == 0`.

### 19.5 Interruption

- Incoming call banner / Control Centre / Notification Centre pulled over: (a) the open drawer, (b) the Link alert
  with text typed, (c) the folder picker mid-load, (d) the edit strip, (e) a steer in flight → on return each is as
  it was; the typed link text is still there; the steer's outcome is applied.
- App backgrounded for 30 s and 5 min during: a slow reply with 3 queued; `/compress` running; a `/bg` task pending;
  background-task polling → on return: no polling happened while in the background (fixture log), the queue is
  intact, `/compress` either finished (result row) or shows the timeout line, the `/bg` result row appears if the
  event arrived after reconnect (else nothing — and no stuck spinner row: a "Running…" row older than its timeout
  becomes its failure line).
- Rotate (iPhone landscape) and iPad split-view resize with the drawer open and with the queue card showing 6 rows →
  layouts re-flow; the drawer stays glued to the composer; no clipped capsule.
- Keyboard switches (emoji, dictation, a third-party keyboard, hardware keyboard connect/disconnect) with the drawer
  open → the drawer follows the composer; no keyboard jump caused by the drawer itself.
- Dictation into the composer while a "/" drawer would trigger (dictating "slash help") → no crash; drawer follows
  the text.
- Stop tapped during a steer in flight; Delete tapped on a row during its steer; chat closed during a steer → the
  lock is released; the text is sent at most once; reopening the chat shows a consistent queue.
- Low Power Mode and Reduce Motion on → jump-to-approval is not animated; spinners still spin; nothing depends on an
  animation's completion to change state.

### 19.6 Relaunch

Force-quit (from the app switcher via `simctl terminate` on this stream's simulator only) and relaunch at each of
these moments; pass = the state named:

| Moment | After relaunch |
|---|---|
| 3 queued, reply running | 3 rows, "Queue Paused · 3 Messages", nothing sent until Resume |
| editing a queued message | the row has its **old** text; the composer shows the draft that was set aside (not the half-edited text) — **⚑ DECISION**: an unsaved edit is discarded, the set-aside draft wins |
| draft with 2 link chips + 1 folder chip + text | the same draft, chips included |
| unconfirmed bubble | still there with its menu; zero sends |
| steer in flight | the text is either in history once (found by the automatic history load) or back as a paused queue row; never both, never neither |
| folder picker / link alert / snippets sheet open | closed; the chat is shown; no orphaned chip |
| `/compress` running | no "Compressing…" row left spinning (local running rows are not restored) |
| Loop chip folded/opened | chip present after the control read; fold state reset to folded |
| background tasks chip with a dismissed finished task | the dismissed task may reappear once if the gateway still lists it as exited; it then leaves on its timer (accepted; dismissed ids are per launch) |

Also: sign out and into a second stand-in (10039) → no queue rows, drafts, link chips or unconfirmed bubbles from the
first account appear (QueueStash is per account/scope).

### 19.7 Accessibility sizes

At Dynamic Type **AX5** (largest accessibility size), and again at the smallest size, in light and dark, with Bold
Text on, and with Button Shapes on:

- Queue card: message text wraps (3 lines), Send Now and ⋯ stay ≥ 44 pt and never overlap the text (at AX sizes the
  capsule drops to its own line under the text); header + Resume fit (Resume wraps under the header if needed).
- Drawer: rows grow; at AX5 at least 2 rows are visible above the keyboard on the smallest supported iPhone; the
  field itself stays visible.
- Link alert, New Folder alert: system-managed, check nothing is clipped.
- Folder picker and Snippets sheet: all text wraps; no truncation of snippet subtitles.
- Error-card capsules (Switch Provider, Retry, Compress, New Chat): wrap to a second line rather than shrink below
  the body size; each ≥ 44 pt tall.
- Loop / heartbeat / background-task cards: label-over-value rows wrap; capsules wrap.
- "Approval needed" capsule: grows with the text and stays within the side margins.
- Edit strip: "Editing Queued Message" may truncate at the tail only after Cancel and Save are fully shown.

VoiceOver pass over every new control (labels as given in each section; no unlabeled buttons — run the Accessibility
Inspector audit on each new screen and attach the result). Switch Control / Full Keyboard Access: every new control
is reachable and has a visible focus ring; the drawer's rows are reachable with Tab/arrows without leaving the field
unusable. Voice Control: "Tap Send Now", "Tap Resume", "Tap Switch Provider" work (labels match what is shown).
Reduce Transparency on: glass surfaces fall back to the system's opaque material and text contrast stays ≥ 4.5:1.

### 19.8 Added in revision 2 (what the merged train makes possible to break)

| # | Check | Pass |
|---|---|---|
| R1 | iPad, two panes (simulator "HQN-m9-composer-s-pad", an iPad the stress tester creates itself): every acceptance check of §1, §3, §9, §15-§17 again | Same results; the drawer and the queue card keep to the readable column and never spill under the left pane |
| R2 | iPad: drag the window from two panes to the phone layout and back, six times, with a drawer open, then with the Edit strip up, then with a paused queue | Draft, caret, drawer query, edit state and queue kept each time; the composer sits on the keyboard (the iPad stream's dead-keyboard-guide repair must still hold) |
| R3 | Hardware Return pressed 30 times quickly on an empty field with 30 queued rows, idle | 30 sends in queue order, none doubled, none lost (fixture ledger) |
| R4 | Hardware Return on an empty field in the same 50 ms as the running reply ends (fixture `race=1`), 50 runs | The head row is sent exactly once in all 50 |
| R5 | Escape hammered 50 times with a drawer open over a running reply | The drawer closes on the first, exactly one `session.interrupt` after it, the draft is kept |
| R6 | Talk: start a voice conversation with a paused queue and an unconfirmed bubble; end it | Queue still paused with Resume, bubble still marked; no row was sent by the conversation's own sends |
| R7 | Dictation: dictate into the field while the slash drawer is open (text begins "/mo") | The words go in at the caret, the drawer follows the new text or closes; no crash, no stuck Stop Dictation |
| R8 | Voice Memo recording with a hardware keyboard: Return and Escape | Return does nothing; Escape is the recorder's Delete (the iPad stream's rung), never Stop of the reply behind it |
| R9 | Group room: type "/", type "@", open + | No drawer; + is absent (rooms are text only); "/help" sends as plain text |
| R10 | Sessions row truth: 25 unconfirmed messages in one chat, relaunch | The 20 kept ones come back marked; the row says "Not Delivered:" until every kept one is checked, sent again, edited or deleted, then stops |
| R11 | Background process claims: start 3 processes, leave the chat, end one from the fixture side, wait 35 s | The Sessions row still says "Working…" (two running); after the last one exits it stops within 30 s |
| R12 | Theme switch (desktoplook) and Increase Contrast (a11y) while the drawer, the background-task card and an error card with capsules are on screen | Everything re-colours at once; no view keeps the old theme's colour; text contrast ≥ 4.5:1 (≥ 7:1 with Increase Contrast) |
| R13 | Share extension / Siri / Action Button send into a chat whose queue is paused | The incoming send follows today's rule (a fresh send un-parks the queue, `LiveChatSession.send`); nothing is sent twice; the header returns to "Queued" |
| R14 | Offline for 60 s with 5 queued rows and Send Now tapped on each | Nothing is lost or doubled when the socket returns; the lock is free; rows that could not steer read plain queued |
| R15 | `scripts/release-check.sh` plus the iPad and accessibility source checks over the stream's diff | Clean: no raw `.preferredFont`, no unguarded animation, no optional popover anchor, no new target outside device family "1,2" |

---

## 20. Build order and file map

Order (revision 2): **closest first, one row per build**, exactly the table in §0.3. Each row lands with its unit
tests, its UI test in `UITests/composer/` and its fixture modes; a later row never blocks an earlier one being marked
done.

0. Fixture + e2e script (§18), with only the modes the first rows need (`reply`, `submit`, `history`, `models`,
   `drop`); every later row adds its own modes. Nothing can be "seen working" without it.
1. L385 (§1) → 2. L388 (§3) → 3. L464 (§16) → 4. L448 (§12) → 5. L386 (§2) → 6. L459 (§13) → 7. L422 (§7) →
   8. L465 (§17, brings the lock) → 9. L463 (§15, brings the Edit strip and the Escape edit rung) → 10. L390 (§4) →
   11. L392 + More (§6) → 12. L439 (§8) → 13. L461 (§14, closes offline's L957) → 14. L446 (§11) → 15. L391 (§5) →
   16. L440 (§9, brings the Escape drawer rung and Return-picks-row) → 17. L441 (§10).

Dependencies that the order respects: §17's lock before §15's steer; §15.5's edit strip before the Escape edit rung;
§9's drawer before §10 and before §8's argument completions; `LinkText`/`RefValue` (§4) before §5.

| New / changed file | For |
|---|---|
| `scripts/fixtures/composer-gateway.py`, `scripts/e2e-composer.sh` | §18 |
| `HermesKit/Chat/LinkText.swift`, `RefValue.swift` | §4, §5 |
| `HermesKit/Attachments/AttachmentModels.swift` (`Kind.link`, `.folder`, `refText`), `AttachmentSender`, `Hydration` (`@url:`) | §4, §5 |
| `App/Chat/Attachments/ComposerTextView.swift` (`onHardwareReturnEmpty`), `App/Chat/ComposerView.swift` (text settings, snippet insert, edit strip), `HermesKit/Layout/KeyRules.swift` (`EmptyReturn`, two `EscapeAction` rungs), `App/Root/KeyCommands.swift` (`escapeState`, `hqEscape`) | §1-§3, §6, §15.5 |
| `App/Chat/Attachments/ComposerPlusMenu.swift` registrations; `App/Chat/Attachments/FolderPickerViewController.swift`; `App/Chat/SnippetsSheetViewController.swift` | §4-§6 |
| `HermesKit/Chat/ChatWorkspace` (`defaultFolder`, `makeFolder`) | §5 |
| `App/Chat/ComposerDrawer.swift`, `HermesKit/Chat/ComposerDrawerModel.swift`, `HermesKit/Chat/Completions.swift` (`complete.slash`, `complete.path`) | §9, §10 |
| `HermesKit/Chat/SlashCatalog.swift`, `SlashRunner.swift`, `LiveChatSession+SideTasks.swift` (compress, btw, bg), `LiveChatSession+Events.swift` | §8 |
| `HermesKit/Chat/ErrorSurface.swift`, `ErrorRecovery.swift`; `App/Chat/Cells/ChatCells.swift` (error card capsules) | §11 |
| `App/Chat/Menus/ModelSheetViewController.swift`, model load helper | §12 |
| `HermesKit/Diagnostics/QuietLog.swift`; `ActivityStore.swift`, `ControlRules.swift`; shelf views for Loop / Heartbeat / Background tasks; `BackgroundTasksStore.swift` (feeds `ActivityStore.setProcessClaims`) | §13, §14 |
| `App/Chat/ChatQueueCard.swift`, `LiveChatSession.swift` (+ `LiveChatSession+Queue.swift`: steer, lock, send again; calls `clearLostSend` from `HermesKit/Chat/LostSends.swift`, which is not otherwise changed) | §15-§17 |
| `App/Chat/ChatViewController.swift` (`updateJumpButton`, key commands, drawer hosting), `App/Questions/ChatPromptCell.swift` (`actionsFrame`) | §3, §7, §9 |
| `project.yml` and `project-original.yml` | pick up new files; **both must build** |

All new types follow Swift 6 with default MainActor isolation; pure models are `nonisolated` and `Sendable`.

## 21. Open items in one place

Still open (one, needs a simulator run, not the owner):

1. Whether the public `inputDelegate` selection calls commit a pending autocorrection on iOS 26/27 (§2.2). If they do
   not, the last word before a tap on Send stays uncorrected, as on the web; the row is still done on its other
   points and the rows file says which way it went.

Resolved in revision 2 by reading source (each section now states the answer):

2. `POST /api/files/mkdir`: one key `path`; any writable absolute path on a self-run gateway, refused outside a
   locked root (§5.3).
3. `LoopSnapshot.status` = `active | paused | done`, heartbeat `active | paused` (§13.2); `process.kill` statuses =
   `killed | already_exited | not_found | error`, and `started_at` is a string (§14.3).
4. `session.redirect` takes only `session_id`, `text`, `profile?` (§15.4).
5. An unconfirmed bubble does survive a relaunch, through the sessions stream's `LostSends` (§17.3).
6. The three reused fixtures take `--port` and `--credentials` (§0.1).

Each is resolved by reading source or one fixture run; none needs the owner.
