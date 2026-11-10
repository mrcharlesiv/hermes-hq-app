# 3x — Chat transcript extras (m9 stream "transcript")

Spec for the 30 rows in `docs/briefs/m9/assignment.md` § transcript (17 not started, 13 partial when the run
began; where each row stands NOW, and which are closest to finished, is §11).
Worktree `/Users/me/Projects/hermes-hq-native-wt/m9-transcript`, branch `m9/transcript`.
Ports 10020-10024 (builders), 10025-10029 (stress tester). Simulators `HQN-m9-transcript` and
`HQN-m9-transcript-s`.

Abbreviations: **WEB** = `/Users/me/Projects/hermes-hq-native-ref240` (read only). **NAT** = this
worktree. **CONTRACTS** = `/Users/me/.hermes/hermes-agent/tui_gateway/contracts` (read only; Hermes
answers an unknown param with error 4000, so every call below lists its complete param set).
Wording in "quotes" is exact, including the curly apostrophe (’) and the single-character ellipsis (…).

Nothing in this stream adds a JSON-RPC method or a param the app does not already send. The new wire
traffic is: one already-used REST read (`GET /api/fs/read-text`), the git review reads the Changes page
already makes, and the phone's own outbound https read for link titles (never through the gateway).

**Revision 2 (after merging `m9/train` at c5a3508 into `m9/transcript`, merge commit db7cfeb).** The train
now carries a11y, ipad, talk, groups, sessions, screen, offline, presence, intents, share, photoheads and
desktoplook. None of them built any of this stream's 30 rows, but several changed the code these rows
extend. §0.2 lists what changed and what each row must now build on; the per-row sections below were
corrected in place. Line numbers are those of db7cfeb. Where a line number has drifted again by the time
a builder reads this, find the symbol by name: the symbol named is what counts.

**Revision 3 (2026-10-13, spec pass after the first builder stage; `m9/train` c5a3508 is already merged,
nothing new to merge).** The builder stage committed 5 rows done and 7 partial (`docs/briefs/m9/transcript-rows.md`,
commit d63fb40), and a second "finishing pass" sits UNCOMMITTED in this worktree (23 changed files, 5 new:
`App/Chat/ChatNoticeCard.swift`, `App/Chat/Cells/LinkChipView.swift`, `App/Chat/Sheets/TableSheetController.swift`,
`Tests/Chat/Transcript/TranscriptFinishTests.swift`, UI tests T9-T15, fixture presets `table`, `links`, `long` and
`/__fixture/older`). This spec pass did not build or run it and did not touch it. The per-row sections below are
unchanged and still the design; **§11 is new**: where every row stands, ordered closest-first, with what is left
for each. DECISION: the rows file keeps its real outcomes and is not reset to "todo" (the job text asks for "todo"
on a first pass; this is a continuation, and wiping seen results would be a false report).

---

## 0. Ground rules that shape every row

1. **Value rows only.** Every new thing in the transcript is a new `ChatRow.Kind` case or a new field on an
   existing payload, with an exact height from `TextLayout`. No cell measures itself. New kinds must be
   added to the HQT3 cache coder; unknown kinds from an older cache decode to nothing (never a crash). Bump
   the cache tag to `HQT4` if any stored row shape changes (DECISION: bump, so an older cache is simply
   refetched instead of half-decoded).
2. **Pure logic lives in `HermesKit/Chat/Transcript/`** (new folder), each file a port of one web helper
   with the web's own test vectors as XCTest cases. View code goes in `App/Chat/`.
3. **Sheets** use `ChatSheet.wrap`; pushed pages get a small title (`PushedPageTitles`); every wrapping row
   has 12-14 pt vertical padding; glass is the system's (`.glassEffect`, system bars, system sheets) only.
4. **Status words live in the status pill** under the bar (`ChatChrome`), never in the bar's title stack.
   Owner note `chat-status-line.md`: status goes "on its own line/pill under the bar so its length never
   moves anything"; do not propose bar layout changes. So the web's "header subtitle" for "Waking up…"
   is the native pill (DECISION, rows L360/L361).
5. **Owner notes that bind this stream** (quoted where they apply): `cron-message-width.md`,
   `delivery-row-overflow.md`, `replies-dont-stream.md`, `smooth-chat-transitions.md`,
   `restored-code-highlight.md`, `chat-status-line.md`, `thread-top-anchor.md`, `ui-hunt-oct6.md`,
   `tool-calls-hide-when-done.md`, `row-padding-feedback`, `feedback-one-feature-at-a-time`.
6. The word "Dispatch" never reaches the screen or VoiceOver. Web type names such as `DispatchLinkFetch`
   are source names only.

### 0.1 Stand-in gateway for this stream

No existing fixture covers these rows, so the builder writes
**`scripts/fixtures/transcript-gateway.py`**, modelled on `scripts/fixtures/activity-gateway.py` (it loads
`/Users/me/Projects/hermes-hq-native-ref238/scripts/performance-fixture-gateway.py` by path, reuses
its sign-in surface, `emit`, `append`, `MESSAGES`, and the "plan" a send can carry). Loopback only, every
value invented, nothing forwarded.

Start (builder, port 10020):

```
SCR=/private/tmp/hqn-m9-transcript; mkdir -p $SCR
python3 scripts/fixtures/transcript-gateway.py --port 10020 --credentials $SCR/transcript.json &
```

Stress tester uses `--port 10025 --credentials $SCR/transcript-s.json`. Stop it with the PID you started
(`kill <pid>`), never by name.

Control surface (all `POST` JSON unless noted; `GET /__fixture/transcript` returns the call log, the
violation list and current switches):

| Path | Body | Effect |
|---|---|---|
| `/__fixture/rows` | `{profile, session_id, rows:[…]}` | Seed stored history rows (role, content, tool calls with `result`/`inline_diff`, `display_kind`, timestamps). Presets by name: `{"preset":"cron"}`, `"timeline"`, `"code"`, `"table"`, `"math"`, `"links"`, `"images"`, `"tools"`, `"diffs"`, `"errors"`, `"long"` (600 rows, 40 code blocks), `"widetable"` (2026-10-29: an Otto-like reply, a 4-column table wider than the phone and a 12-row one to search; T12b). |
| `/__fixture/event` | `{session_id, type, payload}` | Emit one event now (as activity-gateway). |
| `/__fixture/plan` | `{profile, plan}` | The next `prompt.submit` plays this plan. Keys: `events` (scripted list), `whole` (true → the reply is one `message.delta` then `message.complete`), `replyText`, `replyDelay`, `holdAfter`, `error` (`{message}` → emits `error` instead of a reply), `cutOff` (true → socket closed after the first delta). |
| `/__fixture/fail` | `{method|path, code, message, times}` | Fail a JSON-RPC method or REST path (`times` -1 = always). Used for `prompt.submit`, `session.resume`, `/api/sessions/{id}/messages`, `/api/fs/read-text`, `/api/git/review/list`. |
| `/__fixture/slow` | `{method|path, seconds}` | Delay an answer (cold bot: `session.resume` 8 s, 70 s, 130 s). |
| `/__fixture/files` | `{cwd, files:{relpath: text | {"base64":…, "type":…}}}` | Backing store for `/api/fs/read-text`, `/api/fs/download`, `/api/git/review/list` and `/api/git/review/diff`. |
| `/__fixture/unread` | `{session_id, unread}` | Sets the unread flag `session.active_list` and the sessions list report. |

Strictness: the fixture keeps the activity-gateway rule that any param outside the contract's set for a
method is answered `{"error":{"code":4000,…}}` and recorded under `violations`. Acceptance for every row
includes "`GET /__fixture/transcript` shows `violations: []`".

Link titles (rows L312/L313/L1007) can never be exercised against loopback, because the policy refuses
non-public hosts by design. They are tested through an injected `LinkFetching` protocol (unit tests) and a
DEBUG-only launch argument `-HQNLinkPreviewStub <path to json>` that maps a URL to
`{title, iconBase64, iconType}` or `{"fail":true}` (UI tests). The Release build has no such seam.

### 0.2 What the train already has, and what that changes here (read before any row)

Checked by reading the merged tree at db7cfeb. "Unverified on screen" means the code is there but this
spec writer did not run it; the builder's first step for that row is to seed the preset and look.

| Area | What is on the train now | Consequence for this stream |
|---|---|---|
| Accessibility kit (a11y) | `App/Kit/Accessibility/`: `HQFont` (scaled fonts), `HQMotion` (`reduced`, `animate`, `spring`), `HQAnnounce.say(_:priority:coalesce:)`, `HQA11yAudit`. `Tests/Accessibility/A11yLintTests.swift` scans all of `App/` and `Shared/` and now FAILS the unit run on: a fixed `.systemFont(ofSize:)` (use `HQFont.scaled(_, like:)` or mark `// a11y-font-ok: <why>`), a direct `UIAccessibility.is…` read or `UIAccessibility.post(.announcement…)` (use `HQMotion.reduced` / `HQAnnounce.say`), and an animation not routed through `HQMotion` (or marked `// motion-ok: <why>`). | Every "Reduce Motion", "announce", "caption size", "cross-dissolve" in this spec means those helpers. Wherever a section below says `UIAccessibility.isVoiceOverRunning`, `.announcement` or `UIView.animate`, write it through the kit. `scripts/e2e-a11y.sh` and `HQA11yAudit` must stay clean with every new row kind on screen. |
| a11y spec §4.5 (`docs/spec/3x-a11y.md:714-720`) | Its contract for a message: "<Bot> said: <text>" with the time as the value and the hold menu's items as custom actions; tool row "<title>, <state>" with Expanded / Collapsed; code block "Code, <language>, N lines"; table "Table, N rows, M columns". a11y left L300 and L366 to this stream and did not build the bubble's custom actions (`ChatCells.swift:291-295` still reads `copyText` and offers only "Show More"). | §1.1 and §1.2 are still wholly this stream's. Use a11y's spoken shapes for code and tables (§1.1 corrected). |
| iPad (ipad) | `RootSplitController` (two panes), `AppRoot.tabs(window)`, `PaneNavigationController` (routes pushes), `App/Root/KeyCommands.swift` (every shortcut is a menu command whose action is on the app delegate, disabled by `validate` when it cannot act), `DeviceWord.name` ("iPhone" / "iPad"). `.actionSheet` alerts crash on iPad without a popover anchor (`3x-ipad.md` §4.8). | Deep links and the link opener find the tabs through `AppRoot.tabs`, never `window.rootViewController as? MainTabController`. Device nouns come from `DeviceWord.name`. The keyboard shortcut for message actions is a `KeyCommands` entry (§1.2 corrected). Any action sheet this stream presents sets `popoverPresentationController.sourceView` to the bubble. Every sheet and card here is opened once in each layout. |
| Groups (groups) | `ChatSender` (`HermesKit/Contracts+groups.swift:7`), `ChatMessage.sender`, the byline on a run's first bubble and the 28 pt face by its last (`ChatRow.swift:80-87, 131`), `HermesKit/Groups/DeliveryMessages.swift` + `DeliverySender` (row L301: "Message from …" from another bot becomes that bot's incoming bubble; applied in `ChatViewController.swift:315` and the hold menu at `ChatMenus.swift:383`). | L302 (cron) reuses this plumbing instead of a new `Delivery` payload: a cron delivery is a message with a `ChatSender` plus a job name (§2.1 corrected). `agentDelivery` is NOT ported again; groups owns it. |
| Hydration (already there before the merge; the first revision of this spec missed it) | `HermesKit/Chat/Hydration.swift:259-296`: for stored rows with `display_kind` `model_switch` → "Model changed to <name>" (`ModelNames.displayModelName`), `auto_continue`, `personality_switch`, `async_delegation_complete`, `process_complete`, and a stored assistant `[SILENT]` → "Nothing to report — this run was silent"; such rows become `.system` → `.notice` (`:681-683`). Unverified on screen. | L303 and the silent half of L302 are partly built for HISTORY rows. What is left is listed in §2.1 / §2.2 (corrected). `TimelineNotes.swift` extends `Hydration.timelineContent`, it does not replace it. |
| Offline (offline) | `ConnectionBanner` (a transient glass capsule under the status bar saying why the link is down; 6 s per sentence), launch screen, `LiveChatSession+Offline`, the composer's placeholder reading "Reconnecting…" / "Offline" (`ChatViewController.swift:1242-1245`), a third quiet status "Can’t reach this bot" (`ChatChrome.swift:275`). | §6.4's waiting-only set gains nothing from offline, but the grace must not delay "Offline" or "Can’t reach this bot" (working words: at once). The "Couldn’t Send" card (§6.3) and the session problem card (§6.2) sit in the composer stack and must not cover the banner's slot (they cannot: it is at the top). The app's own offline sentence starts "You’re offline." (`HermesKit/Net/GatewayFailure.swift:109`, `ModelSheetViewController.swift:179`), so §6.3's "You’re offline. Your message is still in the box below." is consistent. |
| Sessions (sessions) | `HermesKit/Chat/LostSends.swift` (unconfirmed sends kept per chat so the Sessions row reads "Not Delivered: <words>"), `TailRecheck`, `SessionInfoSheet`. | §6.3 does not touch unconfirmed sends. A REFUSED send must not enter `LostSends` (it is not "maybe delivered"); assert this. |
| Talk (talk) | Read Aloud on the reply's action row (`ChatCells.swift:1058-1073`) and `ChatReadAloudHost`; `HermesKit/Voice/SpeechText.swift` turns a reply into speakable words (no markup, no emoji) for the voice. | §1.1's `spokenText` is a different thing (VoiceOver label, block-aware) but must reuse `SpeechText`'s inline clean-up for a text block instead of a second Markdown stripper. The turn duration mark (§6.6) shares the action row with Copy · Read Aloud · Regenerate · More: it goes at the trailing edge and gives way (hidden) when the row is too narrow at accessibility sizes. Reply reveal (§3.9) must not delay Talk: the model has the whole text at once, which is what Talk reads. |
| Intents (intents) | `App/Intents/IntentsRuntime.route(...)` opens chats for Siri / Shortcuts / quick actions; `IntentsNotice`. | The deep-link router (§7.1) opens a chat through the same door the notifications code uses (`AppModel.openNotifiedChat(stored:profile:)`, `AppModel+Notifications.swift:251`); it does not add a third way to open a chat. |
| Refused sends (already there before the merge; first revision described it wrongly) | `LiveChatSession.refuseSend` (`LiveChatSession.swift:1007-1025`) removes the user bubble, appends an assistant ERROR CARD `local-error-N` carrying the reason, returns the words to the draft, and `AppModel.swift:773-777` puts them in the field when it is empty. There is no toast for a refused send. | §6.3 corrected: the composer card replaces that transcript error card. |
| Transcript cache | Still `HQT3` (`HermesKit/Store/TranscriptCoding.swift:119-124`; `readableMagics` lists what may be read). | Ground rule 1 stands: bump to `HQT4`, leave `readableMagics = [HQT4]` so an HQT3 file is a miss and is refetched. |
| Line anchors that moved | `ChatCells.swift:190` → `:291`; `ChatViewController.chatCellOpen(url:)` → `:2432`; `loadOlderIfNear()` → `:2046`; `LiveChatSession+Sync.loadOlderPage(fill:)` → `:154`; `refuseSend` → `:1007`; `computeStatus()` → `:1340`; `resumeNow()` → `LiveChatSession.swift:614`; `ChatRow` system → notice → `:340-353`; link routing → `AppDelegate.swift:143-160`. | Corrected below. |

DECISION (sheet close button): `ChatSheet.wrap` (`App/Chat/ChatSheets.swift:14`) gives every chat sheet the
system close button (×, identifier `sheet.close`). The web's Table page and preview root say "Done". The
native sheets in this stream keep the system close button so all chat sheets close the same way; the word
"Done" is not added. Sections 3.4 and 8.1 read "the sheet's close button" wherever they said "Done".

---

## 1. Who said it, VoiceOver, and the hold menu

### 1.1 §5 L300 — "X said:" without raw Markdown (partial)

**Web.** Each message carries its own speaker (`src/ui-chat/chat-identity.ts:84-112`), and the bubble
leads with a screen-reader-only "{name} said: " (`src/ui-chat/bubble.tsx:84-87`) followed by rendered
text, so VoiceOver never hears `**`, backticks or `|---|`.

**Native today.** `App/Chat/Cells/ChatCells.swift:291` sets
`accessibilityLabel = "\(speaker) said: " + b.copyText` (value: "Sending" or the time), and `copyText` is
`rendered.plainText`, which `MarkdownRenderer.render` fills with the Markdown source. The a11y stream left
this as it was (§0.2).

**Design.**
- Add `spokenText: String` to the rendered payload, built once in `MarkdownRenderer` from the block list
  (not from the source):
  - text block → its attributed string's plain characters, passed through the inline clean-up
    `HermesKit/Voice/SpeechText.sanitizeForSpeech` already does for Talk (one stripper in the app, not two);
  - quote → "Quote: " + text;
  - code block → "Code, <language>, N lines" (a11y's shape, `3x-a11y.md:718`; "Code, N lines" when the
    language is unknown) + ": " + the first 300 characters;
  - table → "Table, R rows, C columns. " + header cells joined by ", " (a11y's shape; cells are reachable
    in the Table sheet, §3.4);
  - media → the image's alt text, or "Image";
  - math (§3.5) → "Formula: " + the source.
  Blocks are joined with ". " where the previous one does not already end in sentence punctuation.
- `copyText` stays the source Markdown (Copy must not change).
- Label: `"\(speaker) said: \(spokenText)"`; the user's own bubbles: `"You said: \(spokenText)"`
  (web `SaidBy` uses the sender's name; for the user's side the web says "You said:").
- A delivery row (§2.1) reads `"\(sender), scheduled job \(job): \(spokenText)"` (bubble.tsx:114-134).
- Links inside a bubble stay reachable through the Links rotor (`UITextView` already gives this); do not
  flatten the bubble into a static label.

**States.** Streaming reply: label updates at most once per second and only when VoiceOver is running
(read through the accessibility kit, `HQAccessibility` settings, not `UIAccessibility.isVoiceOverRunning`
directly: the lint in §0.2 fails a direct read), so the reader is not restarted on every delta.

**Acceptance.** Unit: `spokenText` for a message with bold, inline code, a fenced block, a table and a
link contains none of `*`, `` ` ``, `|`, `#`, `](`. UI test (accessibility inspector query on the
simulator): the first assistant bubble of preset `code` has a label beginning "Hermes said: " and no
backtick.

### 1.2 §5 L366 — "Message actions" for VoiceOver and the keyboard (not started)

**Web.** `src/ui-chat/message-menu-open.ts`: a VoiceOver-only "Message actions" button, and the keyboard's
menu key, open the same menu a hold opens, after scrolling the bubble into the upper part of the screen.

**Design.** The native bubble already has `UIContextMenuInteraction` (find `UIContextMenuInteraction` in
`ChatCells.swift`); its only custom action today is "Show More" (`ChatCells.swift:293-295`), which stays.
- Each item of the hold menu becomes a `UIAccessibilityCustomAction` on the bubble with the same name and
  the same handler (Copy, Read Aloud, Select Text, Regenerate, Branch in New Chat, …: whatever the menu
  holds for that row, in the menu's order). This is the platform's own "Actions" rotor, and it is what
  `3x-a11y.md:714-716` asks of a message. A bubble that is split into elements for its photos and files
  (`ChatCells.swift:296-300`) carries the actions on its words element and on each media element.
- Plus one custom action named **"Message actions"**, first in the list, that scrolls the row into the
  upper third and presents the same `UIMenu` as an action sheet (`UIAlertController` built from the menu's
  children, with `popoverPresentationController.sourceView` = the bubble and `sourceRect` = its bounds:
  an unanchored action sheet crashes on iPad, §0.2). DECISION: both, because the rotor covers power users
  and the named action matches the web wording word for word.
- Hardware keyboard: one more entry in `App/Root/KeyCommands.swift`, in the Edit menu after "Send":
  **"Message Actions"**, Control-Return, action `AppDelegate.hqMessageActions(_:)`, enabled by `validate`
  only while a chat is on show, no sheet is up and the chat has at least one message (the ipad stream's
  rule: a command that cannot act is disabled, never dead). It acts on the bubble that has keyboard or
  VoiceOver focus, else on the newest message. The **Menu** key (`UIKeyboardHIDUsage.keyboardApplication`,
  read in the chat controller's `pressesBegan`, since `UIKeyCommand` has no public input for it) does the
  same. Both present the same anchored sheet. iPhone with no keyboard: nothing new is drawn.
- `accessibilityHint` on a bubble: "Double tap and hold, or use the Actions rotor, for message actions."

**Acceptance.** UI test launched with the a11y kit's `-HQA11yVoiceOver YES` (it switches on the app's
own VoiceOver-dependent behaviour; `HQAccessibility.swift:27-40`) and `HQA11yAudit` clean: bubble exposes custom
action "Message actions" and one per menu item; invoking "Copy" puts the Markdown on the pasteboard.

---

## 2. Rows that are not ordinary messages

### 2.1 §5 L302 — Cron delivery rows and the silent run (not started)

**Web.**
- `src/ui-chat/run.ts`:
  `CRON_RE = /^(?:\[Cron delivery: ([^\]\n]{1,160})\]|Cronjob Response: ([^\n]{1,160})|\[Cronjob "([^"\n]{1,160})" output\b[^\]\n]*\])[ \t]*(?:\n|$)/`
  and
  `CRON_FOOTER_RE = /\n+(?:To stop or manage this job, send me a new message[^\n]*|Note: The agent cannot see this message[^\n]*)\s*$/`.
  `cronDelivery(text)` (run.ts:36-52) returns `{job, body}` after dropping a leading `(job_id: …)` line and
  a `---` rule. `DELIVERY_RE` covers "Message from …" and "[Message from agent '…']". `senderOf`
  (run.ts:71-85) names the sender.
- `src/ui-chat/chat-identity.ts:84-96` `cronJobBot(job, roster)`: the longest roster name the job name
  starts with; `deliveryIdentity` (100-112) falls back to the chat's own bot.
- `src/ui-chat/bubble.tsx:114-134` `PhoneDelivery`: a bot-side bubble with a byline of the sender's name
  and the job name, the sender's face (28 pt) on the last bubble of the run, never "Inbox → Hermes".
- `src/fe-convo-r6.ts:143-146`: `SILENT_RUN_TEXT = 'Nothing to report — this run was silent'`;
  `silentRun` is `content.trim() === '[SILENT]'`; it is shown as a system note and never swallows the
  turn's tool calls (`build/fe-convo-gates.ts:716-720`).

**Native today (db7cfeb).**
- A cron delivery stored as a user or assistant message shows its wrapper text as typed. Nothing parses
  `[Cron delivery: …]`, `Cronjob Response: …` or `[Cronjob "…" output]` (grep finds none).
- Silent run, history: `Hydration.swift:261-266, 294, 681-683` already turns a stored assistant `[SILENT]`
  into a `.system` row reading "Nothing to report — this run was silent" → `.notice`
  (`ChatRow.swift:340-353`). Unverified on screen; the live path (`message.complete` with `[SILENT]`) is
  not covered.
- Deliveries from another BOT (row L301) are built by groups: `DeliveryMessages.resolve` gives the message
  a `ChatSender`, and the row builder draws the byline, the 28 pt face and the freed face column.

**Design.**
- `HermesKit/Chat/Transcript/Deliveries.swift`: `cronDelivery(_:) -> (job: String, body: String)?`,
  `cronJobBot(job:roster:)`. Same regexes (NSRegularExpression, anchored), same 160-character bounds.
  `isSilentRun` stays in `Hydration`; "Message from …" stays in `DeliveryMessages` (groups). One
  resolver pass: extend the call at `ChatViewController.swift:315` so the same pass that resolves bot
  deliveries also resolves cron deliveries (`CronDeliveries.resolve(messages, roster: DeliveryRoster.seats,
  own: <the chat's bot>)`), run after `DeliveryMessages.resolve` and never on a message that already has
  a `sender`. The hold menu's delivery branch (`ChatMenus.swift:383`) gets the same treatment so Copy
  copies the body, not the wrapper.
- A resolved cron message gets `sender = ChatSender(key: "cron:<profile>", name:, head:, profile:,
  colorHex:)` (the bot `cronJobBot` finds, else the chat's own bot) and a new optional field
  `ChatMessage.job: String?` (the job's name). Its role for drawing is incoming, whatever role it was
  stored with. The row builder then emits a normal **bot-side bubble** through the groups plumbing
  (`BubbleRow.sender`, `senderInset`), with the byline extended by the job:
  - byline above the first bubble of the run: `"<sender> · <job>"`, footnote size, secondary colour, one
    line, tail-truncated on the job (owner note `delivery-row-overflow.md`: the byline must never push the
    row wider than the screen);
  - the sender's ORIGINAL robot head (28 pt) on the last bubble of the run, as for any bot reply;
  - the body rendered as Markdown with the footer and job id removed;
  - width rule identical to a bot reply. Owner note `cron-message-width.md`: cron bubbles "must reach the
    right edge like bot replies". Reuse the reply bubble's max-width constant; do not define another.
- A chat that has only cron deliveries from its own bot still shows the byline (the job name is the
  news); the groups rule "the chat's own bot is named once another sender has spoken" is not changed for
  ordinary replies.
- Silent run: body `[SILENT]` → `.notice("Nothing to report — this run was silent")`, centred like other
  timeline notes; tool rows of that turn still draw before it. History already does this (above): prove
  it with the preset, then add the live path: a `message.complete` whose text trims to `[SILENT]` is
  folded by the same `Hydration.isSilentRun` test at the point the live reply settles, so the bubble never
  shows "[SILENT]" even for a frame (the streaming bubble for a text that is a prefix of "[SILENT]" is
  held back until it is longer than 8 characters or completes).
- A cron wrapper around a silent body (`[Cron delivery: x]\n[SILENT]`) → the silent notice, prefixed by
  the job: "<job>: Nothing to report — this run was silent" (DECISION: the web shows the bare sentence;
  with several jobs in one chat the job name is what tells them apart).
- `[IMPORTANT: …]` process notes (run.ts `PROCESS_RE`) → `.notice` with the text inside the brackets,
  capped at 3 lines with "Show more" (existing notice expand, if any; otherwise truncate with the full
  text in the bubble's Details sheet).
- The gateway's own process titles ("Background Process Finished: npm test", "2 Background Processes Finished") show
  in the app's words ("Background task finished: npm test", "2 background tasks finished"), as the timeline's notes
  and the alerts say it (`BackgroundResults.plainTitle`).
- Runs join when same sender and within 300 s (run.ts:113), as the native run grouping already does for
  bot replies; a delivery from a different sender starts a new run.

**Wire.** None new. Rows arrive through `GET /api/sessions/{id}/messages` and the live `message.complete`.

**Fixture.** `POST /__fixture/rows {"preset":"cron"}` seeds: the three wrapper shapes, one with a footer,
one with `(job_id: abc)` + `---`, one `[SILENT]` after two tool calls, one job named after another bot in
the roster ("Scout morning brief"), one 160-character job name.

**Acceptance.** Screenshot: no bracketed wrapper text on screen; byline "Hermes · Morning brief"; the
"Scout…" job shows Scout's head; silent run reads exactly "Nothing to report — this run was silent" and
its two tool rows are present; widest cron bubble's right edge equals a bot reply's right edge (assert
frames in the UI test).

### 2.2 §5 L303 — Timeline notes in words (not started)

**Web.** `src/fe-convo-r6.ts:129-139`:
`MODEL_SWITCH = /^\[System: The active model for this chat has changed to (\S+?)(?: via provider (\S+?))?\. From this point/`,
`modelSwitchLabel` → "Model changed to <display name>" or "Model changed" when the name is unknown.
`failedTurnNote` matches `/^(?:Your request was not processed\.|This turn did not complete\.)/` and is
dropped from the timeline when an error card already covers that turn.

**Native today (db7cfeb).** `Hydration.timelineContent(kind:role:content:rawContent:metadata:)`
(`Hydration.swift:268-296`) already words stored rows by their `display_kind`: `model_switch` →
"Model changed to <name>" (`ModelNames.displayModelName(id)`, the id when it has no name, "Model changed"
when the text does not match), `auto_continue` → "resumed interrupted turn", `personality_switch` →
"personality changed", `async_delegation_complete` → `display_text` or "N background agents finished",
`process_complete` → `display_text` or "background process finished". Rows of the kinds in `noticeKinds`
(which includes `failed_turn`) become `.system` → `.notice`. Unverified on screen: the parity audit
recorded this row as not started, so the builder's FIRST step is preset `timeline` and a screenshot.

What is missing, and is this row's work:
1. Rows with NO `display_kind` whose text is the `[System: The active model … has changed to …` sentence
   (older gateways, and the live system message): they fall to the `default` branch and show raw.
2. `failed_turn` notes are shown even when an error card covers the same turn (web drops them).
3. Any other `[System: …]` text shows with its brackets.
DECISION: the other fixed strings stay exactly as the web has them, lower case included
("resumed interrupted turn", "personality changed", "background process finished":
`vendor/hermes/apps/desktop/src/lib/chat-messages/hydration.ts:256-275`). The owner's wording rule is
"match the web app wherever it has the words"; do not recapitalise them.

**Design.** `HermesKit/Chat/Transcript/TimelineNotes.swift`:
`timelineNote(_ text: String, kind: String?, modelName: (String) -> String?) -> TimelineNote` where the
result is `.words(String)`, `.hidden` or `.raw(String)`. `Hydration.timelineContent` calls it for the
text-shaped cases (1-3) and keeps its `display_kind` switch; the model-switch regex lives in one place
(move `modelSwitchLabel` here, `Hydration` calls it).
- Model switch → `.words("Model changed to \(display)")`. Display name: `ModelNames.displayModelName`
  (what the model switch toast uses); unknown id → the id as given; empty → "Model changed". No trailing
  full stop (web has none).
- Failed-turn note directly followed or preceded by an error row for the same turn → `.hidden`.
- Any other `[System: …]` text → `.words` of the inside with the "[System: " and "]" removed.
- Everything else → `.raw` (today's behaviour).
The row builder (`ChatRow.swift:340-353`, the `.system` case) asks it once more for the live path, so a
system message that arrives while the chat is open reads the same as after a reopen; `.hidden` emits no
row. The failed-turn rule needs the neighbouring rows, so it is applied in the row builder (it can see
whether the turn has an `.error` row), not in `Hydration`.

**Acceptance.** Preset `timeline`: "Model changed to Opus 5.5" visible; the string "[System:" appears
nowhere on screen; a failed-turn note next to its error card is absent; VoiceOver reads the note as static
text.

---

## 3. Rendering

### 3.1 §5 L306 — Code colour only once visible, never a plain-then-coloured flash (not started)

**Web.** `src/visible-syntax.ts`: one observer with a 160 px margin; a chat that is sliding in counts as on
screen; once coloured a block keeps its colours while parked; colours are never re-applied under an active
text selection. Owner note `restored-code-highlight.md`: in a reopened chat "code stayed plain".
Owner note `smooth-chat-transitions.md` applies to the slide-in.

**Native today.** `SyntaxHighlighter` runs only for settled replies, as part of row rendering.

**Design.**
- Colouring becomes a per-code-block step, separate from layout, because colours never change a height
  (same font, same metrics; assert this in a unit test).
- `CodeColourStore` (actor, `App/Chat/Render/`): LRU keyed by `hash(language + code)`, 300 entries or
  2,000,000 characters, cleared on memory warning. Value = the coloured `NSAttributedString`.
- When a cell is configured (`willDisplay`, which the table calls for rows within its prefetch window; set
  the lookahead to 160 pt beyond the viewport to match the web) the code view asks the store:
  - hit → coloured text is set **before the first frame**, so nothing flashes;
  - miss → the plain text is shown and a colouring task starts off the main actor; on completion the cell
    cross-dissolves colours in over 120 ms (no dissolve under Reduce Motion), and only if the cell still
    shows the same block and the text view has no selection (`selectedRange.length == 0`); with a
    selection, the swap waits for `textViewDidChangeSelection` to report an empty range.
- **Opening a chat:** before the push animation starts, `ChatViewController` colours the blocks of the
  rows that will be on screen in the first viewport plus 160 pt, with a budget of 60 ms on a background
  task joined at `viewWillAppear`. Whatever finishes is drawn coloured from the first frame; the rest
  dissolve in. This is the "sliding in counts as on screen" rule.
- Restored chats (cache HQT4) follow the same path, which fixes the reopened-chat-stays-plain bug by
  construction: colouring no longer depends on the "settled live reply" path.
- Streaming replies stay plain until `message.complete`, as today.

**Acceptance.** Preset `code`. Screen recording at 60 fps of opening the chat: no frame shows a code
block on screen in plain colours followed by colours (check by sampling a known keyword's pixel colour on
frames 1-20). Relaunch, open the same chat from cache: coloured. Select text in a block, scroll it off
and on: selection survives and colours are unchanged.

### 3.2 §5 L307 — Inline code keeps a CLI flag on one line (partial)

**Web.** `src/fe-convo-r6-ui.ts:36-41` `keepFlagsTogether`: an inline-code piece that contains "-", has no
whitespace and is at most 32 characters does not break; copied text is unchanged.

**Design.** In `MarkdownRenderer` InlineCode (about line 525): when the piece qualifies, replace each "-"
with U+2011 (non-breaking hyphen) and insert U+2060 (word joiner) between every pair of characters whose
boundary TextKit would otherwise treat as a break opportunity ("/", "=", ".", "_", ":"). Display string
only: the bubble's `copyText` and the selection-copy path map back (store the original in a custom
attribute `.hqnOriginal` on the run and have `ChatTextViews` copy substitute it; DECISION: needed because
a pasted U+2011 breaks a shell command).

**Acceptance.** Unit: `--user`, `--dry-run=true`, `-rf` unbreakable; a 33-character piece and a piece with
a space unchanged. UI: at the narrowest width (iPhone SE-class simulator width via Display Zoom, or AX5
text) a sentence ending in `--user` wraps the whole flag to the next line. Copy of the bubble and copy of
a selection both contain ASCII "-" (0x2D) only.

### 3.3 (number not used)

### 3.4 §5 L309 — Table sheet and "Copy as Text" (not started)

**Web.** `src/ui-chat/table-sheet.tsx:1-14`: an expand button on a table opens a full-screen page titled
"Table" with "Done"; description for screen readers "Scroll across the table or copy its rows as
tab-separated text."; the scroll area is labelled "Table contents"; footer button "Copy as Text" turns to
"Copied"; failure text "Couldn’t copy. Select the table text and try again."; success/error haptics.
`src/ui-chat/table-model.ts` `tableText`: each cell has `[\t\r\n]+` replaced by one space and is trimmed,
cells joined by a tab, rows by a newline.

**Native today.** Inline table block with a TSV in `MarkdownTable.plain`
(`MarkdownRenderer.swift:455-504`); `ChatTextViews.swift:185` copies it. No full-screen view.

**Design.**
- Inline table gets a trailing **expand button** on its header row (no strip above saying "Table"; the last
  column keeps 36 pt for it, UX study 2026-10-19): SF Symbol
  `arrow.up.left.and.arrow.down.right`, 44×44 pt hit area, accessibility label "Expand table".
  Shown for every table (DECISION: always, not only when it overflows, so the control never appears and
  disappears as the phone rotates).
- `TableSheetController` (`App/Chat/Sheets/`), presented with `ChatSheet.wrap`, large detent only,
  navigation title **"Table"**, closed by the sheet's own close button (§0.2 DECISION; not "Done").
  On iPad in a regular-width window it is the system's centred form sheet; give it
  `preferredContentSize` of the table's natural size capped at 900×900 pt so a 3×4 table is not shown in
  an empty page.
  - Body: a two-axis scroll view (`UICollectionView` with a compositional grid; columns sized to the
    widest cell up to 320 pt, cells wrap inside that; header row pinned on vertical scroll, first column
    pinned on horizontal scroll when there are 3 or more columns). `accessibilityLabel` "Table contents";
    each cell reads "<column header>, <cell>" (row 1 col 1 additionally "Row 1").
  - Cell text is selectable (hold → Copy on a cell).
  - Bottom bar (system toolbar, glass by the system): **"Copy as Text"** (prominent). On tap: pasteboard
    gets `tableText`, the title changes to **"Copied"** for 2 s, success haptic.
    `UIPasteboard` writes do not fail in practice; the failure wording
    "Couldn’t copy. Select the table text and try again." is shown as a footer line with an error haptic
    only if the table is empty or the string cannot be built (kept for parity, covered by a unit test).
  - Alignment follows the Markdown column alignment; numbers are not reformatted.
- `MarkdownTable.plain` is regenerated by the ported `tableText` so inline Copy and the sheet agree.
- Dynamic Type: cells grow; the 320 pt column cap becomes 480 pt at accessibility sizes.

**2026-10-29 rebuild** (owner, on an Otto reply: the expand glyph "meshed together with the text … looks like
we're not even trying", and the expanded page "just needs to be a lot better"). Replaces the header-row button above:
- **Card.** The grid sits on a rounded card with a header band; numbers read right-aligned (a column whose filled cells
  are all numbers, a bracketed note allowed: "14.3% (9 booked)"; `TableData.numericColumns`). Under the grid, a footer
  row the card's width: "7 rows · 4 columns" (just "7 rows", or nothing, when narrow) and "⤢ Expand" in the accent;
  the whole row is the button (`TableFooterControl`, label "Expand table", value "7 rows, 4 columns",
  `chat.table.expand`). A tap on the cells opens the page too. A wide table scrolls inside the card with soft fades at
  the edges that hide columns; no system scroll bar over the last row.
- **Page.** Titled by the words that introduce the table ("Rep by rep (minimum 40 orders):" → "Rep by rep", the
  bracket and "7 rows · 4 columns" as the subtitle; a heading above it counts too), else "Table". Header row pinned on
  vertical scroll. A tap on a header sorts (ascending, descending, back to the reply's order; numbers by value, words
  as Finder sorts names, empty cells last); a tap on a row marks it; hold a cell for Copy cell / row / column and Sort.
  Search from 8 rows ("2 of 12 rows" in the subtitle, matches highlighted). ⋯: Fit to Screen (when the columns can
  share the width), Original Order, Sort By. Share: Copy as Markdown, Copy as CSV, Share CSV File…; "Copy as Text"
  stays the prominent button. Opens fitted to the screen (wrapping) unless that breaks more than a quarter of the short
  cells onto more lines and the first column can stay pinned: then it scrolls sideways with the first column pinned
  (`TableData.squeezeBreaksShortCells`). Numbers never wrap; headers don't break at hyphens. On the Mac the sheet
  takes the table's width up to 900 pt (`MacSheetFit` keeps a page's wider ask).

**Acceptance.** Preset `table` (3×4, 12×40, a cell with a tab and a newline, a 600-character cell). Tap
expand → sheet titled "Table"; "Copy as Text" → "Copied"; pasteboard string has exactly `rows-1` newlines
and `cols-1` tabs per line; pasted into Numbers on the simulator (or asserted by string) it lands in
cells. 12×40 table scrolls at 60 fps (no hitch over 16 ms in Instruments' Animation Hitches for a 5 s
two-axis scroll).

### 3.5 §5 L310 — Math (not started)

**Web.** `src/startup-math.ts`: `containsMath = /\$|\\\(|\\\[/`; KaTeX is loaded lazily (retries at
1000/3000/8000 ms) and until it loads the formula shows as its source. The chat's math plugin runs with
`singleDollarTextMath: true` (`src/startup-deferred.test.ts:28`).

**Native constraint.** KaTeX is JavaScript and CSS for a web view. The native transcript has no web view
and must keep exact pre-measured heights. A full TeX layout engine is out of proportion for this stream.

**DECISION.** Native renders math in two tiers, both measured by `TextLayout` like any text:
1. **Readable formula (always).** `HermesKit/Chat/Transcript/MathText.swift` converts a bounded TeX subset
   to Unicode text: Greek letters, `\times \cdot \pm \leq \geq \neq \approx \infty \to \rightarrow
   \leftarrow \sum \prod \int \partial \nabla \sqrt{x}` → "√(x)", `\frac{a}{b}` → "a⁄b" for single
   tokens and "(a)/(b)" otherwise, `^` and `_` with digits, +, -, =, (, ), n, i → Unicode super/subscripts
   (anything else stays as `^{…}`), `\text{…}` → its content, `\left`/`\right` dropped, `\\` → newline in
   block math. Drawn in the system serif italic for letters (New York), upright for digits and operators.
   Inline math sits in the line; block math (`$$…$$`, `\[…\]`) is its own centred block with 8 pt above
   and below and horizontal scrolling when wider than the bubble.
2. **Source fallback.** If the converter meets a command it does not know, the whole formula is shown as
   its TeX source in the monospaced font (exactly the web's "shows as source" state), never a
   half-converted mix.
- Detection (stricter than the web's cheap gate, to protect prices): `\(…\)`, `\[…\]` and `$$…$$` always;
  single `$…$` only when the opening `$` is not followed by whitespace, the closing `$` is not preceded by
  whitespace and not followed by a digit, the content is at most 200 characters on one line and contains
  at least one of `\ ^ _ = { }`. "It costs $5 and $10" stays text.
- Never inside code spans or code blocks.
- Hold menu on a formula: "Copy Formula" (TeX source without delimiters). Bubble Copy keeps the source
  with delimiters. VoiceOver: "Formula: " + source (§1.1).
- Streaming: an unclosed delimiter is drawn as text until it closes.
- Proposed follow-up, not this stream: true typeset math (owner-todo is not needed; this is app-only).

**Acceptance.** Preset `math`: `$E = mc^2$` shows "E = mc²" in serif italic; `$$\frac{a}{b}$$` centred;
`\begin{aligned}…` shows as source in monospace; "$5 and $10" unchanged; heights match (no clipped or
overlapping rows: assert each row's laid-out height equals the cell's content height).

### 3.6 §5 L311 and §27 L982 — Links open inside the app; loopback pages say why not (partial)

**Web.** `src/ios-links.ts:1-25` `webPreviewRoute`: non-http(s) → ignored; host matching
`/^(localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1?\])$/i` or ending `.localhost` → an info notice for
5 s: "This page runs on the computer running Hermes, so it can’t open on your phone."; otherwise the native
side opens it. `ios/App/App/HermesPlatform.swift:1259-1270` `openExternal`: `mailto`/`tel`/`sms` go to
`UIApplication.open`; http/https with a host, no user or password, and nothing already presented →
`SFSafariViewController(url:)`.

**Native today (db7cfeb).** `ChatViewController.chatCellOpen(url:)` (`:2432-2436`) first gives `#media:`
links to the attachments code (`openMediaLink`, which stays first), then lets only http, https, mailto
and tel through to `UIApplication.shared.open`; every other scheme is dropped silently. No
`SFSafariViewController` anywhere in the app (grep finds none). The router's presenter is found from the
chat's own view controller (`presentedViewController` chain), which is right in both the phone layout and
the iPad's two panes; it never reaches for the window's root.

**Design.** One router, `App/Shared/LinkOpener.swift`, used by the chat and by every other place in the
app that opens a link from content (grep for `UIApplication.shared.open(` and convert the content-link
call sites in this stream's files; list the others in the hand-off note for their owners):

| URL | Behaviour |
|---|---|
| `hermes://…` | hand to the deep-link router (§7) |
| `mailto:` `tel:` `sms:` `facetime:` | `UIApplication.shared.open` |
| http/https, loopback host (the regex above, plus `.localhost`) | notice, 5 s: "This page runs on the computer running Hermes, so it can’t open on your phone." No Safari view. |
| http/https with user or password in the URL | notice: "This link can’t be opened here." and offer nothing else (DECISION: the web silently ignores it; a silent dead tap breaks the "no control that does nothing" rule) |
| other http/https | `SFSafariViewController(url:)`, `dismissButtonStyle = .close`, `preferredControlTintColor` = app tint, presented from the top-most presented controller (DECISION: the web refuses when something is already presented; native presents over the sheet, which UIKit supports, so a link inside the Table sheet or a step sheet still works) |
| any other scheme | notice: "This link can’t be opened here." |

- Universal links: SFSafariViewController does not hand off to other apps. That is the web app's
  behaviour and is kept. The link's hold menu (system `UITextView` link preview menu) keeps "Open in
  Safari", "Copy Link", "Share…".
- Owner note `ui-hunt-oct6.md`: links in your own bubble "take bubble text colour, underlined"; toasts
  "must not cover the status line". The notice uses the existing `showNotice` toast, which sits above the
  composer.

**Acceptance.** Preset `links`: tapping `https://example.com` shows a Safari view inside the app with a
Close button (app stays foreground: assert `XCUIApplication().state == .runningForeground` and the
Safari view's "Close"/"Done" button exists; DECISION: the UI test stubs the load with a public URL only
if the simulator has network, otherwise asserts the controller's presence only); tapping
`http://localhost:3000/` and `http://127.0.0.1:8080/x` shows the gateway-computer notice and no Safari
view; `mailto:` leaves the app.

### 3.7 §5 L312, L313 and §27 L1007 — Link titles and site icons (not started)

**Web.**
- `src/fe-convo-r3.ts:517-527` `bareLinkLabel`: a bare URL with a known title shows the title alone if the
  title already contains the hostname, else "Title · host"; with no title it shows `host + path` with "…"
  in place of a query or fragment. A link the author gave text to keeps that text.
- `src/link-preview.ts:1-158`: title cap 240; unusable titles rejected (`UNUSABLE_TITLE`: "Just a
  moment…", "Access denied", "Sign in", "404", empty and the like; `SIGN_IN_ARRIVAL` rejects a title when
  the final URL is a sign-in page); `titleFromHtml` reads the first 256 KiB, `<title>` first, then
  `og:title`, then `twitter:title`; `iconCandidates` ranks `<link rel="icon">` entries and well-known
  paths, top 5, https only; `imageMime` sniffs magic bytes and needs at least 48 bytes; at most 3 reads in
  flight; page cache 64 entries LRU; icon cache per host 128 entries / 2 Mi characters.
- `ios/App/App/HermesPlatformExtras.swift:1091-1151`: ephemeral session, no cookies, no cache, 5 s
  timeouts, 2 connections per host, limits 256 KiB (HTML) and 64 KiB (image; larger is refused, not
  truncated), `publicHTTPS` (a dotted host, not `.local`, `.localhost`, `.internal`, `.home.arpa`,
  `.ts.net`; a numeric host must be a public dotted quad), `resolvesPublic(host)` before connecting,
  every redirect re-checked, and the connected peer address verified public from task metrics.

**Native today.** `HermesKit/Net/PublicHostPolicy.swift` already has `publicHTTPS`, `publicAddress`,
`allowed`, `resolvesPublic`; `HermesKit/Net/RemoteImageFetch.swift` and
`HermesKit/Media/RemoteImageFetcher.swift` already do bounded public image reads. No title read.

**Design.**
- `HermesKit/Net/LinkPreviewFetcher.swift` (actor) behind `protocol LinkFetching`:
  - `URLSessionConfiguration.ephemeral`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`,
    `urlCache = nil`, `urlCredentialStorage = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`,
    `timeoutIntervalForRequest = 5`, `timeoutIntervalForResource = 5`,
    `httpMaximumConnectionsPerHost = 2`, `waitsForConnectivity = false`.
  - Request headers: `Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.1` for the page and
    `Accept: image/*` for the icon; no `Referer`, no `Authorization`, no custom `User-Agent` beyond the
    system default. Nothing about the gateway, the bot or the user is sent.
  - Guards, all reused from `PublicHostPolicy`: `publicHTTPS(url)` → `resolvesPublic(host)` → delegate
    `willPerformHTTPRedirection` re-runs both and refuses a downgrade to http →
    `didFinishCollecting metrics` checks the remote address is public; a failed guard discards the body.
  - Streaming read with a hard stop at 262,144 bytes (HTML; the task is cancelled, what arrived is
    parsed) and 65,536 bytes (image; over the limit → refused).
  - `titleFromHTML` (regex over the decoded head; charset from the header, then `<meta charset>`, then
    UTF-8, then Latin-1), entity decoding, whitespace collapsed, cap 240, `UNUSABLE_TITLE` and
    `SIGN_IN_ARRIVAL` ported with the web's vectors.
  - `iconCandidates` ported; the first candidate whose bytes sniff as PNG, JPEG, GIF, WebP or ICO and
    decode with ImageIO wins. SVG icons are skipped (DECISION: no SVG rasteriser in the app).
  - At most 3 page reads in flight (async semaphore); the same URL is single-flight.
  - Caches: in memory, 64 pages LRU and 128 icons per-host LRU capped at 1.5 MB decoded; nothing is
    written to disk (DECISION: matches "cookieless, cacheless"; titles reappear after a relaunch with one
    more read when the row is next on screen).
  - One read per URL per app run. A failure is remembered for the run (no retry storm).
- **Privacy switch.** Reads start only for links in rows that are on screen, never for a chat that is not
  open, and never while Low Data Mode is on (`NWPathMonitor.currentPath.isConstrained`).
  DECISION: no new Settings toggle in this stream (one feature at a time; the web has none).
- **Display.**
  - Bare URL (autolink, `MarkdownRenderer.swift:584`) with no title yet → `host + path`, query/fragment
    shown as "…" (immediately, before any read).
  - Title arrives → the link's text becomes "Title · host" (or the title alone when it contains the
    host). Because this changes text length it can change the bubble's height: the row is re-measured and
    reloaded **without animation, only if the row is not currently being touched and the height delta is
    absorbed above the viewport anchor** (the inverted table keeps the bottom fixed). If the user is
    reading that row (it is the top-most visible row and the title would add a line), the title is applied
    the next time the row scrolls off screen. Owner note `thread-top-anchor.md` applies: nothing the
    reader is looking at may jump.
  - **Link chip.** A message whose whole text is one bare URL, or a bare URL alone on its own paragraph,
    is drawn as a chip under the paragraph: 16 pt site icon (rounded 4 pt; a `globe` symbol until/unless
    an icon loads), title (2 lines max, body), host (footnote, secondary). Fixed height reserved from the
    start (56 pt at default text size, scaled with Dynamic Type) so a late title or icon never moves the
    transcript. Tap → §3.6 router. Hold → the system link menu.
  - Authored links (`[text](url)`) keep their text and get no chip.
  - Copy always yields the original URL.
- VoiceOver for a chip: "Link, <title>, <host>".

**Wire.** `GET https://<public host>/<path>` from the phone, one page read and at most 5 icon tries per
host. Never through the gateway; never to a private, loopback, `.ts.net` or link-local address.

**Acceptance.** Unit (stubbed `URLProtocol`): cookie header never sent and `Set-Cookie` never stored;
257 KiB page parsed from its first 256 KiB; 65 KiB icon refused; redirect to `http://` and to
`https://10.0.0.5/` refused; host `gateway.tail1234.ts.net`, `printer.local`, `127.0.0.1`, `[::1]`,
`169.254.1.1` never connected (assert zero requests); title vectors from `link-preview.ts`. UI
(`-HQNLinkPreviewStub`): bare URL shows "Example Domain · example.com"; chip shows icon, title, host; a
failing URL keeps `host + path`; the row below the chip does not move when the title lands (compare
frames before and after).

### 3.8 §5 L317 — Relative image paths and blocked images that say why (not started)

**Web.** `src/fe-convo-r6.ts:63-74` `relativeImageSrc(src, base)` resolves `./plot.png`, `plot.png`,
`../out/a.png` against the chat's folder; `src/fe-convo-r6-ui.ts:19-23` `imageFolder()` is the session's
working folder. `blockedImageText` (fe-convo-r6.ts:103-109):
- "Couldn’t show “<alt>”: its path is relative, and this chat has no folder to find it in."
- "Couldn’t show “<alt>”: an image embedded in a reply can’t be shown here." (`data:` images)
- "Couldn’t show <name>." (anything else blocked; the name is “<alt>” in quotes, or "this image" when
  there is no alt).

**Design.**
- `HermesKit/Chat/Transcript/ImageSources.swift`: `resolve(src:folder:) -> ImageSource` with cases
  `.remote(URL)` (public https, existing `RemoteImageFetcher`), `.gateway(path)` (absolute path or a
  relative path joined to the folder and normalised; a path that climbs above the folder with `..` is
  still joined, as on the web, and the gateway decides whether it may be read), `.blocked(reason)`.
- Folder = the session's `cwd` the app already holds for the Files/Changes sheet
  (`HermesKit/Chat/ChatWorkspace.swift`).
- Gateway images load through the existing media path (`HermesKit/Media/MediaLoader.swift`, the same
  download route attachments use: `GET /api/fs/download?path=<abs>` with the chat's profile). No new
  route.
- Blocked or failed images draw a one-paragraph caption row in the image's place, secondary colour, with
  the exact strings above. Additional native-only failure (the read itself failed):
  "Couldn’t show “<alt>”: your gateway didn’t send it." (DECISION: the web shows a broken image there;
  a sentence is better and follows the same pattern.) `http://` images: "Couldn’t show “<alt>”." (blocked
  by the same public-https policy).
- Height: images reserve their box from Markdown dimensions when given, else a 4:3 placeholder at bubble
  width that settles once to the real aspect ratio on load, using the existing media block rule.

**Wire.** `GET /api/fs/download?path=<abs path>&profile=<profile>` (existing).

**Fixture.** `POST /__fixture/files {"cwd":"/work/demo","files":{"plot.png":{"base64":…,"type":"image/png"}}}`;
preset `images` has `![Plot](plot.png)`, `![Plot](./out/missing.png)`, `![Inline](data:image/png;base64,…)`,
`![](http://insecure.example/x.png)`, and one chat with no folder.

**Acceptance.** Relative image renders in the chat with a folder; in the chat without a folder the row
reads exactly "Couldn’t show “Plot”: its path is relative, and this chat has no folder to find it in.";
the data image reads "…an image embedded in a reply can’t be shown here."; the alt-less one reads
"Couldn’t show this image."; fixture log shows one download per image.

### 3.9 §5 L321 — Reply reveal for replies that arrive whole (not started)

**Web.** `src/ui-chat/reply-reveal.ts`: `WHOLE_REPLY_CHARS 60`, `REVEAL_CHARS 1200`, `REVEAL_MIN_MS 280`,
`REVEAL_MAX_MS 700`, `STREAM_GAP_MS 1000`, `CLAIM_MS 1500`, `STEP_MS 33`, `CHARS_PER_MS 1.6`;
`revealPieces` cuts at spaces and never inside a surrogate pair. Only drawing is paced; events are never
held back. Skipped for replayed frames, when deltas arrive less than 1 s apart (a real stream), with
Reduce Motion, on iPad, when the reader has scrolled up, and when the app is not visible. A touch or
going to the background shows everything at once.

**Owner.** `replies-dont-stream.md`: the owner's bots use `claude-subscription-directsdk-experimental`
(an external process), so "the whole reply arrives as one message.delta". This row is what makes those
replies feel alive.

**Design.** `HermesKit/Chat/Transcript/ReplyReveal.swift` (pure: `plan(text:now:lastDeltaAt:) -> [Piece]`
with the constants above) and `App/Chat/ReplyRevealDriver.swift` (a `CADisplayLink` at 30 Hz).
- Trigger: a `message.delta` of at least 60 characters arriving for a turn with no earlier delta, or more
  than 1000 ms after the previous one, and not from `session.events.since` replay.
- The session model is updated at once with the full text (state, cache, Copy, VoiceOver, notifications
  all see the whole reply immediately). Only the cell's drawn text is paced: the row carries
  `revealLimit: Int?` (a character count); the cell draws `prefix(revealLimit)` cut at a word boundary.
- **Height.** The row's height is the height of the drawn prefix, growing as an ordinary streaming reply
  grows, so the existing streaming scroll rules apply unchanged (owner note `thread-top-anchor.md`: the
  sent message stays at the bottom and the reply is read from its top; no send-to-top). DECISION: grow,
  do not pre-reserve the final height, because a pre-reserved 40-line blank bubble would throw the
  reader's message off screen at once.
- Only the first 1200 characters are paced; the remainder appears with the last step. Total time is
  `clamp(chars / 1.6 ms, 280, 700)` ms.
- Markdown is rendered with the streaming renderer during the reveal (plain code, no colours) and swapped
  to the settled render at the end (same as stream end).
- Skip (show everything at once) when: Reduce Motion is on; the table is not at the bottom
  (reader scrolled up); the scene is not `foregroundActive`; the chat is not the visible one; an
  accessibility text size is in effect and VoiceOver is running (VoiceOver gets the whole text in one
  announcement); iPad (web skips on iPad; DECISION: skip when the chat is drawn in the two-pane layout,
  that is when `RootSplitController` is the root and is not collapsed; an iPad in a narrow Split View or
  Slide Over window draws the phone layout and reveals like a phone). A group room (`GroupRoomSession`)
  never reveals: its messages arrive whole by design and several can land together.
  Reduce Motion is read through `HQMotion.reduced`.
- Finish instantly on: any touch in the transcript, scroll begin, app resigning active, Stop, a second
  delta, or `message.complete` arriving more than 1500 ms (`CLAIM_MS`) late.
- Haptics: none.

**Fixture.** `POST /__fixture/plan {"plan":{"whole":true,"replyText":"<900 chars>"}}`.

**Acceptance.** Recording: a whole 900-character reply is drawn in 5 or more visibly distinct steps over
280-700 ms (count distinct bubble heights or text lengths across frames); with Reduce Motion one step; a
tap mid-reveal completes it within one frame; a normally streamed reply (plan with 120 chunks) is
unaffected (no added delay: time from last delta to full text under 50 ms); Copy pressed mid-reveal
copies the full reply.

---

## 4. Position and paging

### 4.1 §5 L329 — Reopening a chat with unread replies lands on them (not started)

**Web.** `src/fe-convo-r5.ts:129-185` (r5-86): the newest message id the reader has seen is saved per chat
(120 chats kept). `reopenScrollTarget`: when the chat is unread (or was marked read within the last
15 s), or its newest id differs from the saved one, open at the end; otherwise restore the saved offset.

**Design.**
- `HermesKit/Chat/Transcript/SeenStore.swift`: `[chatKey: SeenMark{newestID, firstUnseenID?, at}]` in
  `UserDefaults` (suite of the account), 120 entries LRU. `chatKey` = connection + profile + stored
  session id.
- On leaving a chat (and on backgrounding) save the newest row id and the scroll anchor (top visible row
  id + offset), as the existing position restore does.
- On opening:
  1. no mark → bottom (today's behaviour);
  2. the newest id equals the mark and the chat is not unread → restore the saved anchor;
  3. otherwise → there are replies the reader has not seen. DECISION (native refinement of "lands on
     them"): scroll so the **top of the first unseen reply** is at the top of the viewport when the
     unseen content is taller than one screen, else to the bottom. This is the owner's reading rule
     (`thread-top-anchor.md`: "reply read from its top"); the web's plain "open at end" would drop the
     reader at the end of a long reply they have not read.
  - A thin "New" divider row (`.notice` styled as a hairline with the word "New", accessibility label
    "New messages") is drawn above the first unseen reply for this visit only (not cached).
     DECISION: add it; without it the landing position is unexplained.
- The landing is applied before the first frame (no visible scroll), using cached rows; if the cache is
  behind (the unseen reply is not in it yet), land at the bottom of the cache and re-apply once after
  the first `session.resume`/history merge, but only if the reader has not touched the transcript.
- The jump-to-bottom button shows as usual when the landing is not the bottom.

**Wire.** None new (`unread` from the sessions list / `session.active_list` the app already reads).

**Acceptance.** Fixture: read chat A to the end, leave; `POST /__fixture/rows` appends one 3-screen reply
and `/__fixture/unread` sets unread; reopen → the reply's first line is at the top, "New" above it, no
scroll animation on the first frames. With no new messages, a mid-history position is restored exactly
(±1 pt). With a one-line new reply → bottom.

### 4.2 §5 L331 — "Show earlier messages": spinner, failure, Try again (partial)

**Web.** `src/fe-convo-r1-ui.tsx:11-45` `EarlierButton`: on touch devices it loads by itself when it
comes into view after a drag (240 px margin), one page at a time; label "Show earlier messages"; loading
"Loading earlier messages…" with a spinner; failure
`'Couldn’t load earlier messages — your gateway didn’t answer.'` with "Try again". Gate r1-34: paging
against a tail that was replaced re-pages once.

**Native today (db7cfeb).** `ChatViewController.loadOlderIfNear()` (`:2046-2056`) pages within 6 screens
of the top when `session.hasOlder && !session.isLoadingOlder`; `LiveChatSession+Sync.loadOlderPage(fill:)`
(`:154`) returns silently on failure. No row, no error. `olderState` is added to the `ChatSessionModel`
protocol with a default of `.none`, so `GroupRoomSession`, the debug `FakeChatSession`
(`App/Chat/Debug/FakeChatSession.swift:24, 69`) and the placeholder model (`AppModel.swift:807-819`) keep
compiling; the fake gains a way to fail a page for the UI test.

**Design.**
- `LiveChatSession` gains `olderState: OlderState` = `.none` (no older pages), `.idle`, `.loading`,
  `.failed`. `loadOlderPage` sets `.failed` on a thrown fetch or a non-2xx answer and stops auto-paging
  until the user acts.
- A new row kind `.earlier(OlderState)` is the top-most row whenever `hasOlder`:
  - `.idle` → a centred glass capsule button **"Show earlier messages"** (rarely seen, because auto-paging
    starts 6 screens early; it is what VoiceOver and Switch Control users activate, and what shows when
    auto-paging is paused);
  - `.loading` → spinner + **"Loading earlier messages…"** (not a button; `accessibilityTraits
    .updatesFrequently`);
  - `.failed` → two lines: **"Couldn’t load earlier messages from the computer running Hermes."** (while the chat is
    offline: **"Couldn’t load earlier messages while you’re offline."**; the computer may have answered with an error,
    so never "didn’t answer") and a
    button **"Try Again"** (native Title Case, a deliberate departure from the web's "Try again"). Error haptic once per failure, not per appearance.
  - Fixed height per state at a given text size (the three states share one height: the tallest), so a
    state change never moves the transcript.
- Auto-paging keeps the 6-screen lookahead. After a failure, auto-paging resumes only after "Try Again"
  succeeds. When the phone comes back online (`NWPathMonitor` satisfied) a failed row retries once by
  itself.
- r1-34: if the page cursor is rejected because the tail was replaced (history resync), page again once
  from the new oldest row before reporting failure.
- VoiceOver: when a page lands, `HQAnnounce.say("Earlier messages loaded")` only if focus was on the
  earlier row.

**Wire.** `GET /api/sessions/{id}/messages` with the paging params the app already sends (unchanged).

**Fixture.** Preset `long`; `POST /__fixture/fail {"path":"/api/sessions/*/messages","code":503,"times":2}`
and `/__fixture/slow {"path":"/api/sessions/*/messages","seconds":3}`.

**Acceptance.** Scroll to the top with a 3 s delay: spinner row "Loading earlier messages…" visible;
with two failures: the failure text and "Try Again"; tap → loads, scroll position holds (top visible row
frame unchanged ±1 pt); no automatic request loop while failed (fixture log shows exactly 2 failed calls
before the tap).

---

## 5. Tools and file changes

Owner note `tool-calls-hide-when-done.md` (Tool Call Style Rows/Bubbles; After Reply Keep/Hide; Telegram
colours abandoned) stays in force: nothing here changes which rows are kept or hidden, only their words
and what opens from them.

### 5.1 §5 L344 — Tool row wording (partial)

**Web sources.** `src/fe-convo-r1.ts:264-280` `byteCountLabel` / `toolCountNoun`;
`src/fe-convo-r5.ts:303-330` `plainToolLabel`; `src/fe-convo-r4.ts:160-171` `toolErrorBody`,
`failedToolTitle`; `src/fe-convo-r6.ts:148-175` `collapseHeredocs`, `setupSegment`, `INTERPRETERS`;
gates r1-47, r5-98, r5-99, r4-94, r6-13 in `build/fe-convo-gates.ts`.

**Native today.** `HermesKit/Activity/ToolLine.swift`: emoji + verb + preview; terminal shows the command
as code.

**Design.** Extend `ToolLine` (pure) with ported helpers in `HermesKit/Chat/Transcript/ToolWords.swift`:

| Rule | Wording |
|---|---|
| Output size (r1-47) | `byteCountLabel`: 1000-based, "850 B output", "10 KB output", "1.2 MB output"; stderr-only → "10 KB error output". Shown as the row's trailing detail when the tool returned text and the row is collapsed. |
| `tool_describe` (r5-98) | one tool → "Checked how to use <tool words>" (snake/camel case to words, e.g. `web_search` → "web search"); several → "Checked how to use N tools"; none named → "Checked how to use a tool". (Was "Looked up …", which read as if the tool ran; UX study 2026-10-19.) |
| Background process tool | by action: "Started a background process", "Checked a background process’s log", "Stopped a background process", "Sent input to a background process", "Listed background processes"; default "Managed a background process". (Copy the full action map from `fe-convo-r5.ts:303-330`.) |
| One-line shell output (r5-99) | when a terminal call's output is a single line of at most 120 characters, the opened row / step sheet shows it directly under the command without an "Output" disclosure. |
| Failed tool (r4-94) | title "Failed: <title>"; the body is `toolErrorBody`: the error text with lines that are only status keys (`status: error`, `success: false`, `exit_code: 1` as a lone key/value line) removed; if nothing is left: "This step didn’t finish." (DECISION for the empty case; the web shows the bare title). |
| Heredoc scripts (r6-13) | `collapseHeredocs`: `python3 - <<'EOF' … EOF` → "Ran python3 script"; interpreter set = the web's `INTERPRETERS`; a leading `cd x && ` / `source venv && ` setup segment is dropped from the title and kept in the sheet. |

- Emoji stay as the native ToolLine has them (DECISION: the row says "wording"; glyphs are not in scope).
- All strings in one table with the web vectors as tests.

**Fixture.** Preset `tools`: one call per rule, including a failed one whose result is
`{"status":"error","error":"No such file"}` and a 10,240-byte output.

**Acceptance.** Screenshot of preset `tools` shows each exact string; "status: error" appears nowhere;
VoiceOver reads "Failed: Read notes.txt. No such file".

### 5.2 §5 L346 — Inline diffs from edit tools (partial)

**Web.** `src/tool-diffs.ts`: the diff an edit tool returns is kept in an LRU (200 diffs or 1,048,576
characters, the newest always kept, released with the transcript, cleared on memory pressure) and shown
inline under the tool row; a reopened chat reads the stored result's diff.
CONTRACTS `events.py:289-293`: `tool.complete` carries `duration_s` and `inline_diff`.

**Native today.** `App/Chat/Activity/StepSheets.swift` shows a "Changes" `DiffPanel` from
`detail?.inlineDiff` (at most 20,000 characters) inside the step sheet only.

**Design.**
- `ToolDiffStore` (actor in `HermesKit/Chat/Transcript/`): the web's bounds exactly; keyed by tool call
  id; cleared on `UIApplication.didReceiveMemoryWarningNotification`; a chat leaving memory releases its
  entries. Hydration (`HermesKit/Chat/Hydration.swift:856`) fills it from a stored result's `inline_diff`
  (or a `diff` key in the JSON result, as the web's `inlineDiffFromResult` reads).
- **In the transcript**, under an edit tool's row (Tool Call Style = Rows) or inside its bubble (Bubbles):
  a compact diff preview: file name line (`basename`, then "+A −R" in green/red with the words spoken as
  "A added, R removed"), then the first **8** changed lines with one line of context, monospaced caption
  size, added lines tinted green, removed red (system colours, also marked with a leading "+" / "−" so
  colour is never the only signal), horizontal scroll off (lines truncate), and a footer button
  **"Show all changes"** when more lines exist → opens the existing step sheet scrolled to "Changes".
  Tapping the file name → §5.3.
- Fixed, pre-measured height: `min(changedLines+context, 8)` lines + header + optional footer.
- Evicted diff (LRU) → the row shows the header and "Show all changes", which refetches through the
  step sheet's existing detail read; if the gateway no longer has it: "These changes are no longer
  available." in the sheet.
- "After Reply: Hide" still hides the tool rows; the diff then lives on the changed-files card (§5.4).
- Diffs over 20,000 characters: preview from the first 8 lines; the sheet keeps its existing cap and
  says "Showing the first part of a large change." (existing wording if present; otherwise add).

**Fixture.** Preset `diffs`: three `write_file`/`patch` calls with `inline_diff`, one 3,000-line diff, one
stored-only (history) diff, and 250 small diffs in one chat to exercise the LRU.

**Acceptance.** Inline preview visible under the edit row live and after relaunch from history; "Show all
changes" opens the sheet at Changes; after the 250-diff chat, memory for the store is at most 1,048,576
characters (unit test on the store) and the newest diff is still inline.

### 5.3 §5 L347 — Changed-file preview (not started)

**Web.** `src/changed-file-preview.ts`: `openFile(path)` is single-flight and is cancelled when the chat
or route changes; it reads through the phone bridge (`iosReadGatewayText({path, profile, sessionId})`);
errors: "This file belongs to another connection." / "This file cannot be shown in this preview." (images,
PDF) / "Could not open file: <path>"; the failure notice is titled "File preview unavailable". It shows
the file's current contents, so it works even when the change is already committed and no longer in the
uncommitted diff.

**Native today.** `HermesKit/Chat/ChatWorkspace.swift:83` already reads
`GET /api/fs/read-text?path=<file>` → `{path, text, binary?, truncated?, byteSize?}` for the Files sheet;
`App/Chat/Viewer/FilePreviewPresenter.swift` previews files.

**Design.**
- Tapping a file name on an inline diff (§5.2) or a card row (§5.4) calls
  `ChangedFilePreview.open(path:)` (`App/Chat/Activity/`), single-flight per chat; a second tap on
  another file cancels the first; leaving the chat cancels.
- Path resolution: absolute as given; relative → joined to the chat's `cwd`.
- While loading: the tapped row shows a small spinner in place of its chevron (no blocking overlay); a
  read under 150 ms shows nothing.
- Success → push/present the existing text preview page (the Files sheet's file page from
  `App/Chat/Menus/WorkspacePages.swift`), small title = file name, with its existing Copy and Share. If
  the diff for that file is known, a segmented control **"File" | "Changes"** at the top switches between
  the contents and that file's diff (DECISION: the web opens contents only; the native page already has
  both views in the Files sheet, so reuse it).
- `truncated: true` → footer "Showing the first part of this file."
- `binary: true`, or an image/PDF extension → for images and PDFs hand to `FilePreviewPresenter`
  (Quick Look through the existing download path) instead of refusing (DECISION: native can show them);
  any other binary → notice titled **"File preview unavailable"** with
  "This file cannot be shown in this preview."
- Read failure → notice **"File preview unavailable"** / "Could not open file: <path>" (path
  middle-truncated to 60 characters).
- The chat's connection is no longer the active one → "File preview unavailable" /
  "This file belongs to another connection."

**Wire.** `GET /api/fs/read-text?path=<abs path>` with the chat's profile scoping exactly as
`ChatWorkspace` sends it today. Response `{ "path": "/work/demo/src/app.py", "text": "…",
"truncated": false, "byteSize": 1832 }`.

**Fixture.** `/__fixture/files` + `/__fixture/fail {"path":"/api/fs/read-text","code":404,"times":1}`.

**Acceptance.** Tap a file on the card → its contents open, title = basename; with the file absent from
`/api/git/review/list` (committed) it still opens; the 404 case shows the notice with both exact strings;
double-tapping two files quickly opens only the second (fixture log: second read answered, first
cancelled or ignored; one page on the stack).

### 5.4 §5 L348 — "N files changed" card (not started)

**Web.** `vendor/hermes/apps/desktop/src/components/assistant-ui/thread/changed-files-card.tsx:1-76` and
`changed-files.ts` `deriveChangedFiles`: closing the newest assistant turn, one row per file the turn
edited (first-touched order, +/− summed over every edit to that file; only landed edits that returned a
diff count), title `'1 file changed'` / `'${count} files changed'` (`i18n/en.ts:5267`), action
`'Review'` (5268), about 5 rows visible then the list scrolls. `src/fe-convo-r5.ts` r5-85: on the phone
Review (tinted) opens the Changes page; `matchChangedFile` maps a card row to the Changes list.

**Design.**
- `HermesKit/Chat/Transcript/ChangedFiles.swift`: `derive(calls:) -> [ChangedFile{path,name,added,removed}]`
  from a turn's edit-tool calls (`write_file`, `patch`, `edit_file`, `str_replace_editor`,
  `apply_patch`: take the exact set from the web's `isFileEditTool`) that are `.done` and have a diff in
  `ToolDiffStore` or their stored result. `countDiffLineStats`: lines starting "+" (not "+++") and "-"
  (not "---").
- New row kind `.changedFiles(ChangedFilesRow)` placed after the turn's last assistant bubble and before
  its action row, for **every settled turn that has changed files** while it is the newest turn, and for
  older turns too (DECISION: the web shows it on the newest turn only because its right rail holds the
  rest; on the phone the card is the only way back to a turn's changes, and it is stable in history).
  Not shown while the turn is still running.
- Card (one filled card, as an opened One Line card: `contentCardFill`, hairline rules between rows, no fake
  glass):
  - header: "1 file changed" / "N files changed" (body, primary) and a trailing tinted text button
    **"Review"**;
  - up to **5** file rows: file-type symbol, basename (truncating middle), "+A" green and "−R" red
    (zero sides omitted), led by "N edits" when the file was edited more than once (a step's own preview
    shows one edit's counts, so the sum needs saying); each row at least 44 pt tall with 12 pt vertical
    padding;
  - more than 5 → a last row **"Show All N Files"** which opens the card in place to every file
    (DECISION 2026-10-31, n20 revisit: a few more rows are not nested scrolling, and the files are what
    the owner came for; Review stays the way to the diffs).
  - Row tap → §5.3 for that file. Hold → "Copy Path".
- **Review** → presents the existing Files/Changes sheet (`App/Chat/Menus/WorkspacePages.swift`) on its
  **Changes** page. If a card row was the trigger ("Show All" is not), the matching file is scrolled to
  and highlighted (`matchChangedFile`: exact path, then repo-relative suffix match).
  - Changes page states (existing page; confirm each has wording): loading spinner; empty →
    "No uncommitted changes" plus, when opened from a card, a line
    "These changes may already be committed. Tap a file on the card to see it." ; failure →
    "Couldn’t load changes — your gateway didn’t answer." with "Try again"; no folder →
    "This chat has no folder."
- VoiceOver: card is a container labelled "N files changed"; rows read "<name>, A added, R removed".
- "After Reply: Hide" hides tool rows but keeps the card.

**Wire.** Existing: `GET /api/git/review/list?path=<cwd>&scope=uncommitted` and
`GET /api/git/review/diff?path=<cwd>&file=<rel>&scope=uncommitted&staged=<bool>`.

**Acceptance.** Preset `diffs`: card reads "3 files changed" with summed counts (a file edited twice is
one row); 7-file turn shows 5 rows + "Show All 7 Files", which opens to all 7; Review opens Changes; card present after
relaunch; a turn whose only edit failed has no card.

---

## 6. Errors, sending, and status

### 6.1 §5 L352 — Error card wording (partial)

**Web.** `src/phone-notices.ts:127-203` `turnErrorCopy` (kinds below), `errorDetailText`,
`limitDetailText`, `noticeDetailClosed`, `turnErrorPlan`; `src/fe-convo-r6.ts:6-33` `withoutRetryWords`;
`src/fe-convo-r1.ts:208-221` `withoutDuplicateTurnErrors`; `detailRepeatsBody`, `withoutRetryHint`,
`ownTurnPlan` (Retry only for turns this device sent). Gates r4-93, r5-95, r6-01, r1-37.

**Native today.** `ChatRow.swift`: `ErrorRow(title: "\(name) couldn’t finish this reply", reason,
details, retry)`; `errorReason` already drops retry words when there is no Retry.

**Design.** `HermesKit/Chat/Transcript/TurnErrorCopy.swift` ports `turnErrorCopy` with the web's regexes
(`LIMIT`, `OWNED`, `START`, `BUSY`, `WAIT`) and vectors. Result
`{kind, title, body, detail?, detailsClosed, primary: .retry | .chooseModel | .newChat | none}`:

| Kind | Title | Body | Button |
|---|---|---|---|
| usage limit | "<Provider> usage limit reached" or "<Provider> usage limit reached until <time>" | "Choose another model, or wait until then." (with a time) / "Choose another model, or try again later." | "Choose a Model" |
| open elsewhere | "This chat is open somewhere else" | "The computer running Hermes, or another window, has this chat open, so it can’t answer here. Start a new chat, or close it there and try again." | "New Chat" (DECISION: the web gives none here; the body names the action, so offer it) |
| model can’t start | "This chat’s model couldn’t start" | "Hermes couldn’t start this chat’s model on the computer running Hermes. Choose another model, or check the model’s provider there." | "Choose a Model" |
| gateway busy | "The computer running Hermes is busy" | "It didn’t answer in time while it checked its model. Try again in a moment." | "Try Again" (own turns) |
| cut off | "The reply was cut off" | "The connection dropped before the reply finished. Tap Try Again to send it again." (own turn) / "The connection dropped before the reply finished." (not this device's turn: `withoutRetryHint`) | "Try Again" (own turns) |
| anything else | "<Bot> couldn’t finish this reply" (existing) | the short reason (existing `errorReason`) | "Try Again" (own turns) |

- **Details.** "Copy Details" stays. A "Details" disclosure shows the raw provider text; it starts
  **closed** for usage-limit and model-start (`noticeDetailClosed`) and is **omitted** when the detail
  only repeats the body (`detailRepeatsBody`).
- **No retry words without Retry** (r6-01): when the card has no Retry button, `withoutRetryWords` removes
  sentences such as "Please try again." / "Retry to send it again." from body and detail.
- **Retry only for own turns** (`ownTurnPlan`): a turn sent from another device shows no Retry.
- **One card per failed turn** (r1-37): `withoutDuplicateTurnErrors`: consecutive error rows for one turn
  (the live `error` event, the stored failed-turn note, the stored assistant error) collapse to the most
  specific one (known kind beats generic; newest wins among equals).
- "Choose a Model" opens the model picker the menus stream owns (existing entry point used by the header
  menu). "New Chat" starts a new chat with the same bot.

**Fixture.** Preset `errors` + `/__fixture/plan {"plan":{"error":{"message":"…"}}}` with one message per
kind (copy the test strings from `src/phone-notices.ts` tests), and `{"plan":{"cutOff":true}}`.

**Acceptance.** Each kind shows its exact title/body/button; a usage-limit card's Details is closed; a
cut-off turn from history (not sent by this device) has no Retry and no sentence containing "Retry" or
"try again"; a turn that produced an `error` event and a stored failed-turn note shows exactly one card.

### 6.2 §5 L353 — Model-can’t-start banner (not started)

**Web.** `src/fe-convo-r5.ts:230-269` and `src/phone-chat-menu.tsx:304-326` (r5-92): an `error` event
with **no turn in flight** is a session-level error (`sessionLevelError`); it ignores
`/^(?:Turn cancelled|Session no longer running) before the agent was ready/i`; title = the known kind's
title, else "Couldn’t reopen this chat" when the text matches `/could not reopen that session/i`, else
"Hermes reported a problem"; buttons "Choose a Model" (usage limit, model start) / "Try Again" / "Copy" /
dismiss ×; cleared on a send, on a model change, on dismiss; docked above the composer.

**Design.**
- `LiveChatSession` gains `sessionProblem: SessionProblem?` set by `+Events` when an `error` arrives
  while no turn is running (and by a failed `session.resume` after its quiet retry, §6.5), cleared by
  `send`, a successful model switch, a successful resume, or dismiss.
- `SessionProblemCard` joins the above-composer stack at the **top priority** (order becomes: problem
  card → queue card → memo notice → activity shelf → tucked chip → jump button), system material card
  like the memo notice card (`App/Chat/Voice/MemoNoticeCard.swift` is the layout model):
  - title (headline, 2 lines), body (subheadline, up to 4 lines, then "More" opens the Details sheet);
  - buttons, left to right: **"Choose a Model"** (prominent; only for usage-limit and model-start) or
    **"Try Again"** (prominent; every other kind: re-runs `resumeNow()`), **"Copy"** (copies title, body
    and raw detail), and a trailing close button (accessibility label "Dismiss").
- What else lives above the composer on the train now, and must be opened together with this card once:
  the Talk tip card (about 110 pt, `3x-talk.md` §10.5, takes no touch), the Talk dock, the dictation row,
  the question dock (it takes the composer's place: the cards then sit above the dock), the reply-to /
  group-room chrome. Rule: the problem card and the "Couldn’t Send" card are the two top-most items of the
  stack; the transcript's bottom inset is the sum of everything showing; when the sum would exceed 45% of
  the transcript's height (accessibility sizes, keyboard up), the problem card collapses to its title and
  one prominent button, with "More" opening the rest in a sheet.
- A group room (`GroupRoomSession`) has no single model to choose: there the card offers "Try Again" and
  "Copy" only, never "Choose a Model".
- Bot name: "Hermes reported a problem" uses the bot's own name when the chat's bot is not Hermes
  ("<Bot> reported a problem"). DECISION: the web says "Hermes" as the product; a named bot reads better
  and matches the native error card's "<Bot> couldn’t finish this reply".
- VoiceOver: said once through `HQAnnounce.say` when it appears; the card is the first element above the
  composer.
- The composer stays usable: the user can type and send (which clears the card).

**Fixture.** `/__fixture/event {"session_id":…,"type":"error","payload":{"message":"<model start text>"}}`
with no turn running; also the "could not reopen that session" text; also the ignored
"Turn cancelled before the agent was ready".

**Acceptance.** Banner with "This chat’s model couldn’t start" and "Choose a Model" above the composer;
choosing a model clears it; the ignored message shows nothing; sending clears it; it never covers the
status pill or the last message (the transcript's bottom inset grows by the card's height).

### 6.3 §5 L354 — "Couldn’t Send" at the composer (partial)

**Web.** `src/ui-chat/send-failure.tsx`: title "Couldn’t Send"; text on a timeout "Your gateway didn’t
answer in time. Your message is still in the box below."; otherwise "Your message is still in the box
below. <raw reason>"; action "Try Again" resends the draft; dismissed on a chat change or the next send;
error haptic.

**Native today (db7cfeb; the first revision of this spec had this wrong).** `LiveChatSession.refuseSend`
(`LiveChatSession.swift:1007-1025`): removes the user's bubble, parks the queue, appends an assistant
**error card in the transcript** (`local-error-N`, text = the reason, or "Your message wasn't sent."),
returns attachments or words to the draft, then calls `onDraftReturned(text, reason)`.
`AppModel.swift:773-777` puts the words in the field when it is empty and shows a toast only when the
reason is NOT already on the last error card (the "Stopped before sending" case, `:930`). A refused
rewind takes its own path (`rewindRefused`) and is not part of this row. Unconfirmed sends show
"Delivery Unconfirmed · Check" and are remembered by `LostSends` (sessions stream).

**Design.**
- DECISION: for a refused send the transcript error card is replaced by the composer card. One failure,
  one place: the web shows it at the composer only, and a card in the transcript plus a card at the
  composer would be two reports of one thing. `refuseSend` stops appending `local-error-N` and instead
  sets `LiveChatSession.sendFailure: SendFailure?` (`{reason, timedOut, offline, at}`), which the chat
  screen draws as a `SendFailureCard` in the above-composer stack (directly under the session problem
  card, above the queue card). Because the state is on the session, a send refused while the chat was
  off screen (a queue that drained away) shows its card when the chat is next opened in this run.
- "Stopped before sending" (`:930`) keeps its toast and gets no card: the user did that themselves.
- A refused send is never written to `LostSends` (it did not leave; the Sessions row must not read
  "Not Delivered"). Unit test.
- The card:
  - title **"Couldn’t Send"**;
  - body: timeout → **"The computer running Hermes didn’t answer in time. Your message is still in the box below."**;
    offline → **"You’re offline. Your message is still in the box below."** (DECISION: clearer than the
    raw `NSURLError` text the else-branch would show); otherwise
    **"Your message is still in the box below. <reason>"** where the reason is the gateway's message,
    one sentence, capped at 160 characters;
  - **"Try Again"** (prominent) sends the composer's current text and attachments; disabled while the
    composer is empty; a close button ("Dismiss").
- The draft, its attachments and the cursor are restored to the composer (existing `onDraftReturned`);
  if the user had already typed something new, the returned text is put **before** it separated by a
  newline (never overwrite typing).
- Dismissed on: Try Again, any successful send, chat change, the close button.
- Error haptic once.
- "Delivery Unconfirmed · Check" is unchanged: that is a send the gateway may have received; this card is
  only for a send that was refused or never left.

**Wire.** `prompt.submit` (unchanged params).

**Fixture.** `/__fixture/fail {"method":"prompt.submit","code":4009,"message":"session busy","times":1}`
and `/__fixture/slow {"method":"prompt.submit","seconds":40}` for the timeout.

**Acceptance.** Refused send → card with "Couldn’t Send" and the reason; composer holds the text; "Try
Again" sends and the card goes; timeout wording exact; no user bubble is left in a failed state for a
refused send, and the transcript holds NO error card for it (assert no `local-error-` row); the Sessions
row for that chat does not read "Not Delivered"; leave the chat and come back: the card is still there;
"Stopped before sending" still shows only its toast.

### 6.4 §5 L360 — Waiting-only statuses after a grace period (partial)

**Web.** `src/status-grace.ts`: `STATUS_GRACE_MS = 1000`; the waiting-only statuses ("Waking up…",
"Connecting…", "Reconnecting…") appear only after 1 s; they clear at once; a status that is already
showing and only changes its words changes at once.

**Native today (db7cfeb).** `LiveChatSession.computeStatus()` (`LiveChatSession.swift:1340-1364`) →
"Offline", "Reconnecting…" (also for `.connecting` once `everReady`), "Waiting for your approval / reply"
(questions), "Summarizing…", the running step (activity), "Thinking…", "Writing…", or the tool title,
with no delay. A first connect (`.connecting`, `everReady == false`) returns nil. The pill
(`ChatChrome.swift:268-285`) treats "Offline", "Reconnecting…" and "Can’t reach this bot" as quiet words.
The composer's placeholder also reads "Reconnecting…" / "Offline" (`ChatViewController.swift:1242-1245`);
DECISION: the placeholder follows the graced status too (it reads the same graced value), so the field
does not flash "Reconnecting…" on a 400 ms blip while the pill stays quiet. The offline stream's
`ConnectionBanner` is separate and is not graced here (it has its own timing).

**Design.** `HermesKit/Chat/Transcript/StatusGrace.swift` (pure, clock injected):
`mutating func next(raw: String?, now: ContinuousClock.Instant) -> (shown: String?, recheckAfter: Duration?)`.
- Waiting-only set: "Waking up…", "Connecting…", "Reconnecting…".
- Raw becomes a waiting-only word while nothing is shown → show nothing, re-check in 1000 ms; still
  waiting then → show.
- Raw is nil → clear at once. Raw is any other word ("Thinking…", "Writing…", a tool title,
  "Summarizing…", "Offline", "Can’t reach this bot", "Waiting for your approval", "Waiting for your
  reply") → show at once. Add "Waking up…", "Still waking up…" and "Connecting…" to the pill's quiet set
  (`ChatChrome.swift:275`) so they are drawn in the secondary colour without the working dots.
- Something is shown and raw changes to a waiting-only word → change at once (no blank gap).
- Applied in `LiveChatSession` between `computeStatus()` and `statusText`, so every reader (pill, Live
  Activity, VoiceOver) gets the same thing. "Connecting…" is added to `computeStatus` for the first
  connect of a chat (today it shows nothing or "Reconnecting…": verify and use "Connecting…" when the
  socket has never been up in this app run).

**Acceptance.** Unit: the web's timeline vectors. UI: a 400 ms reconnect (fixture closes and reopens the
socket) never shows "Reconnecting…" (record frames; none contains it); a 3 s one shows it from about
1.0 s and removes it within one frame of the reconnect.

### 6.5 §5 L361 — "Waking up…" while a cold bot starts (not started)

**Web.** `src/ui-chat/waking.ts` and gate FE-041: while `session.resume` for a cold bot is pending, the
header subtitle reads "Waking up…" (after the grace). `src/runtime-error.ts`: `RESUME_TIMEOUT_MS =
120000`, one quiet retry, then "This chat is still starting on the computer running Hermes." or
"The computer running Hermes didn’t answer in time."; title "Couldn’t reopen this chat".
CONTRACTS `events.py`: `session.resume_progress` exists (the app already knows the event).

**Native today (db7cfeb).** `resumeTimeout = .seconds(120)` (`LiveChatSession.swift:165`) and
`resumeNow()` (`:614`) with one quiet retry exist; no status word while waiting. "Waking up…" goes into
`computeStatus()` after the link-state cases and after `promptStatusText` (a waiting approval or question
outranks it), before the turn's working words.

**Design.**
- `computeStatus()` returns **"Waking up…"** while a resume is in flight and the socket is connected.
  Through §6.4 it appears only after 1 s, so a warm bot never flashes it.
- Shown in the **status pill** under the bar (ground rule 4; owner note `chat-status-line.md`), not in
  the bar's subtitle. DECISION.
- After 20 s the pill reads **"Still waking up…"** (DECISION: a two-minute unchanged status reads as
  frozen; the web keeps one string). If `session.resume_progress` carries a human message, it is not
  shown (DECISION: its strings are internal; revisit when they are documented).
- The composer stays enabled; a message sent while waking is queued by the existing queue card and goes
  when the resume lands.
- Cached transcript stays visible and scrollable throughout.
- Both attempts time out or fail → session problem card (§6.2) titled **"Couldn’t reopen this chat"**,
  body **"This chat is still starting on the computer running Hermes."** when the gateway said the session is
  starting, else **"The computer running Hermes didn’t answer in time."**, with **"Try again"**.
- VoiceOver: "Waking up…" announced once (pill is a live region already; confirm).

**Wire.** `session.resume` (unchanged params; do not add any). Events: `session.resume_progress`
(ignored for wording).

**Fixture.** `/__fixture/slow {"method":"session.resume","seconds":8}`; 70; and 130 twice (both attempts)
→ card.

**Acceptance.** 8 s: pill shows "Waking up…" from about 1 s to 8 s then clears; nothing in the nav bar
changes size; 0.3 s resume shows nothing; 130 s × 2 → "Couldn’t reopen this chat" card with "Try again"
(run with a debug launch argument `-HQNResumeTimeout 6` so the test does not take four minutes; the
argument exists only in DEBUG).

### 6.6 §5 L363 — Turn duration mark (partial)

**Web.** `src/fe-convo-r3.ts:118-353` and gate r4-105: each finished turn carries its duration
(`durationS`) or "Stopped"; marks are remembered per `TurnScope {stored, profile?, connection?}`, 200
kept, and re-applied to transcript reads **only for the same chat**, so a resync does not lose them and
another chat with the same message ids does not get them. CONTRACTS: `message.complete` carries no
duration, so the client measures it.

**Native today.** Tool calls have `durationSeconds` (step sheet "Duration"). Turns have none; "Stopped" /
"Stopped before <name> replied" rows exist.

**Design.**
- `HermesKit/Chat/Transcript/TurnMarks.swift`: `TurnMarkStore` keyed by
  `TurnScope(connection, profile, storedSessionID)` + the turn's final assistant message id (or user
  message id for a stopped turn with no reply): `{seconds: Double?, stopped: Bool}`; 200 marks LRU across
  all chats, persisted in the account's `UserDefaults` suite (DECISION: persisted, so the mark survives a
  relaunch as well as a resync).
- Measured from the moment `prompt.submit` is acknowledged (or the first event of a turn this device did
  not send) to `message.complete`, on the monotonic clock. Turns that were only replayed from history get
  no mark (unknown is shown as nothing, never as a guess).
- Shown in the reply's **action row** (`ChatRow.Kind.actions`; it now holds Copy · Read Aloud ·
  Regenerate · More in 48 pt steps, `ChatCells.swift:1058-1160`), at the trailing edge, `HQFont.scaled`
  caption size, secondary colour; when the row is too narrow for the buttons plus the mark (accessibility
  sizes, a narrow iPad pane) the mark is left out of the row and stays in VoiceOver's value for the reply:
  "4s", "1m 12s", "1h 3m" (under 1 s → nothing). VoiceOver: "Took 1 minute 12 seconds".
  Stopped turns keep their existing "Stopped" row; no duration is added to it.
- Re-applied when rows are rebuilt from a history read or the cache, by scope + message id only.
- If the action row is hidden by a setting, the mark is not shown elsewhere.

**Acceptance.** A 6 s scripted turn shows "6s" (±1); force a resync (`session.events.since` gap → history
read): mark still there; relaunch: still there; a second chat seeded with the same message ids shows no
mark; 201st mark evicts the oldest (unit).

---

## 7. Deep links, clipboard

### 7.1 §27 L981 — hermes:// deep links (not started for kinds other than session/connect)

**Web / old shell.** `ios/App/App/HermesPlatform.swift:1418-1456` `HermesLinks.open`: `connect`;
`session` (id `^[A-Za-z0-9_-]+$`, at most 160, no query or fragment); every other kind is validated
(at most 32,768 bytes; kind `^[a-z0-9][a-z0-9-]{0,63}$`; name at most 1,024; at most 32 params; key at
most 64; value at most 16,384; no control characters) and passed to the renderer as `{kind, name,
params}`; the last 4 are kept for a cold start. Renderer routing (`src/fe-platform.ts:46-60, 203-226`;
`vendor/…/use-desktop-integrations.ts:380-470`; `deeplink-routes.ts`): `mcp/install`, `plugin/install`,
`skill/install?identifier=`, `blueprint/<name>` (puts "/blueprint name k=v" in the composer),
`connections/done`, `open/<path>`, plugin routes, shortcuts. Unroutable → notice
`That isn’t available on ${noun} yet.` with noun "iPhone" / "iPad" (`src/unavailable-notice.ts`). r6-22:
a session link arriving while on another tab opens through Sessions.

**Native today (db7cfeb).** `HermesKit/Push/NotificationPrefs.swift:110-135` `NotificationRules.Link {
session, connect }` and `NotificationRules.link(_:scheme:)`; `App/AppDelegate.swift:143-160`
(`scene(_:openURLContexts:)` → `open(_:)` → `model.handleLink`) and
`App/Notifications/AppModel+Notifications.swift:249-300` (`openNotifiedChat(stored:profile:)`,
`handleLink`) route those two; any other kind returns nil and nothing happens. The scheme is
`AppIdentity.current.urlScheme` (it differs between the two project identities: test with the scheme of
the build under test, and keep both `project.yml` and `project-original.yml` registering theirs).
The tabs are reached through `AppRoot.tabs(window)` (iPad's two-pane root wraps them); the Siri /
Shortcuts door (`IntentsRuntime.route`) is not used for links.

**Design.** `HermesKit/Links/DeepLink.swift` (pure parser with the bounds above; replaces the two-case
enum, keeping its existing cases source-compatible) and `App/Links/DeepLinkRouter.swift`.

| Link | Native behaviour |
|---|---|
| `hermes://connect…` | unchanged |
| `hermes://session/<id>` | unchanged; additionally (r6-22) when another tab is showing or a sheet is up: dismiss sheets that are safe to dismiss (not a sheet with unsaved input: then show the notice "Finish what you’re doing, then open the link again."), switch to the chat's tab, open the chat. Unknown id → notice "That chat isn’t on this gateway." |
| `hermes://blueprint/<name>?k=v…` | opens the current (or most recent) chat and puts `/blueprint <name> k=v …` in the composer, not sent. Keys sorted as given; values with spaces are quoted. If the composer has text, the command is put on a new line after it. |
| `hermes://skill/install?identifier=<id>` | routes to the Skills page's install flow if the pages stream exposes one (`App/Pages/…`: look for an install entry point); otherwise the unsupported notice. |
| `hermes://mcp/install…`, `hermes://plugin/install…` | routes to the matching page's install flow if one exists in native today; otherwise the unsupported notice. Never installs without the page's own confirmation step. |
| `hermes://connections/done` | dismisses an in-app Safari view the app opened for a connection sign-in (if one is up) and refreshes the Connections page; otherwise ignored silently (it is a callback, not a user action). |
| `hermes://open/<path>` | opens the path in the file preview (§5.3) for the active chat's connection. |
| anything else valid | notice (5 s): **"That isn’t available on iPhone yet."** ("iPad" on iPad: build the sentence with `DeviceWord.name`) |
| invalid (fails the bounds) | ignored silently, logged at debug level (never a notice: a malformed link is not user intent worth explaining; the web does the same) |

- Cold start: links received before sign-in/first sync completes are queued (last 4) and replayed once
  the bot list is loaded.
- Entry points: `scene(_:openURLContexts:)`, launch options, and `LinkOpener` (§3.6) for a `hermes://`
  link tapped inside a chat.
- A link never sends a message, never changes settings, never installs anything by itself.
- DECISION: each "routes to … if one exists" row is implemented only where the destination already exists
  on `m9/train` at build time; otherwise it takes the unsupported notice, and the builder lists which
  kinds got which treatment in the hand-off note. No dead control is created either way.

**Test.** `xcrun simctl openurl "HQN-m9-transcript" "hermes://session/<id>"` etc. against the fixture
signed-in app.

**Acceptance.** Session link from the Settings tab opens the chat; `hermes://blueprint/weekly?team=core`
leaves "/blueprint weekly team=core" in the composer unsent; `hermes://nonsense/x` shows
"That isn’t available on iPhone yet."; a 40,000-byte link and `hermes://Bad_Kind/x` do nothing; a link
opened while signed out is replayed after sign-in.

### 7.2 §27 L1003 — Copy an image (partial)

**Web / old shell.** `ios/App/App/HermesPlatformExtras.swift:164-174`: PNG and JPEG keep their original
bytes (`setData(_:forPasteboardType:)`), other types go through `UIPasteboard.general.image`.

**Native today.** `App/Chat/Viewer/MediaActions.swift:59-68` already copies the original bytes with the
bytes' own type from the media viewer's menu ("Copy"). The assignment's "no copy-image found" is out of
date for the viewer; it is still missing from the transcript itself.

**Design.**
- Add **"Copy Image"** to the hold menu of an image in a bubble (inline Markdown image, attachment image,
  generated image), calling the same `MediaActions.copy`.
- `MediaActions.copy`: keep bytes for PNG, JPEG, GIF, HEIC, WebP; additionally set a PNG representation
  when the type is one many apps cannot paste (WebP, HEIC) by writing a multi-representation item
  (`UIPasteboard.general.setItems([[type: data, UTType.png.identifier: pngData]])`). DECISION: improves
  paste into Notes/Messages without changing the original bytes.
- If the original is not on the phone yet, the menu action downloads it first (spinner on the image);
  failure → notice "Couldn’t copy this image." with an error haptic. Success haptic as today.
- Rename the viewer's "Copy" to "Copy Image" for the same wording in both places (DECISION).

**Acceptance.** Hold an image in a reply → "Copy Image"; `UIPasteboard.general.hasImages` is true and
the first item's type equals the file's type (PNG stays PNG, byte-for-byte equal to the fixture file);
failing download shows the notice.

---

## 8. Preview stack

### 8.1 §5 L319 — Preview sheets stack; Back names the screen underneath (not started)

**Web.** `src/phone-file-preview-state.ts`: previews are a trail (stack); opening a note from a note
pushes; Back is labelled with the title of the screen underneath (or "Back"); re-opening a note that is
already in the trail moves it to the top instead of duplicating it; a stale close is ignored.

**Why this is mostly free in native.** The web shell had to build a navigation stack by hand. UIKit has
one. DECISION: the hand-built trail is **web-shell-only**; the native obligation is the behaviour.

**Design.**
- Every preview opened from the chat (file text, Markdown note, changed file, image/PDF via Quick Look
  where it can be pushed) is hosted in **one** `UINavigationController` inside one `ChatSheet.wrap` sheet
  (`PreviewStack`, `App/Chat/Viewer/`). `FilePreviewPresenter` gains `open(_:from:)` that pushes onto the
  stack when a preview sheet is already up, and presents it otherwise.
- Links inside a preview that point to another file (relative Markdown links, `hermes://open/…`) push.
- The root page has the sheet's close button (§0.2 DECISION); pushed pages get the system back button, whose title is
  the previous page's title automatically (long titles: the system falls back to "Back").
- Re-opening a file already in the stack: `popToViewController` if it is below, no-op if it is on top
  (the web moves it to the top; DECISION: popping back to it is the UIKit-natural equivalent and keeps
  Back truthful).
- Each page is identified by `(connection, profile, absolute path)`.
- A load that finishes after its page was popped is discarded (stale close/late answer ignored).
- Depth cap 12; at the cap the oldest non-root page is dropped from the stack silently.

**Acceptance.** Fixture note A links to note B which links to A: open A → tap B's link → back button reads
A's title → tap the link to A inside B → the stack pops to A (two pages never show the same file); the
close button closes everything; swipe-back works; the same on the iPad simulator in two panes (the stack
lives in the sheet, never in the right pane's navigation stack, so `PaneNavigationController` does not
reroute its pushes: assert the chat is still the right pane's top screen after closing).

---

## 9. Row index

| Row | Section | Kind of work |
|---|---|---|
| §5 L300 | 1.1 | native |
| §5 L302 | 2.1 | native |
| §5 L303 | 2.2 | native |
| §5 L306 | 3.1 | native |
| §5 L307 | 3.2 | native |
| §5 L309 | 3.4 | native |
| §5 L310 | 3.5 | native, DECISION: Unicode formula tier + source fallback instead of KaTeX |
| §5 L311 | 3.6 | native |
| §5 L312 | 3.7 | native |
| §5 L313 | 3.7 | native |
| §5 L317 | 3.8 | native |
| §5 L319 | 8.1 | native behaviour; hand-built trail proposed web-shell-only |
| §5 L321 | 3.9 | native |
| §5 L329 | 4.1 | native |
| §5 L331 | 4.2 | native |
| §5 L344 | 5.1 | native |
| §5 L346 | 5.2 | native |
| §5 L347 | 5.3 | native |
| §5 L348 | 5.4 | native |
| §5 L352 | 6.1 | native |
| §5 L353 | 6.2 | native |
| §5 L354 | 6.3 | native |
| §5 L360 | 6.4 | native |
| §5 L361 | 6.5 | native |
| §5 L363 | 6.6 | native |
| §5 L366 | 1.2 | native |
| §27 L981 | 7.1 | native; some kinds fall to the unsupported notice until their page exists |
| §27 L982 | 3.6 | native |
| §27 L1003 | 7.2 | native |
| §27 L1007 | 3.7 | native |

No row needs a relay, plugin or real-gateway change, so there is no `docs/owner-todo/transcript.md`.
If a builder finds that `/api/fs/read-text` or `/api/fs/download` refuses a path the web could read (the
web used a scoped bridge read with `sessionId`), the app shows the "File preview unavailable" notice and
the builder then opens `docs/owner-todo/transcript.md` with the request/response pair from the fixture's
model of the real route; do not invent a new route.

## 10. Build order (one feature per build; owner note `feedback-one-feature-at-a-time`)

Suggested slices, each independently shippable and each ending in its own acceptance run:

1. Fixture `transcript-gateway.py` + presets (unblocks everything).
2. Pure ports with tests: Deliveries, TimelineNotes, ToolWords, TurnErrorCopy, StatusGrace, ReplyReveal
   plan, ChangedFiles, DeepLink parser, tableText, MathText, link title/icon parsing.
3. Rows: cron/silent/timeline (2.1, 2.2); error card + duplicate collapse (6.1).
4. Status grace + waking + session problem card + Couldn’t Send card (6.2-6.5).
5. Earlier-messages row (4.2); unread landing (4.1); turn marks (6.6).
6. Tool wording, inline diffs, changed-files card, changed-file preview, preview stack (5.x, 8.1).
7. Link opener + loopback notice; link titles and chips (3.6, 3.7); deep links (7.1).
8. Table sheet; inline-code flags; math; relative/blocked images; copy image (3.2, 3.4, 3.5, 3.8, 7.2).
9. Visible code colour (3.1); reply reveal (3.9).
10. VoiceOver spoken text and Message actions (1.1, 1.2), last, so they cover every new row kind.

Both `project.yml` and `project-original.yml` must build after each slice (`scripts/build.sh`).

After each slice also run, in this order: the unit tests (the a11y source scans in
`Tests/Accessibility/A11yLintTests.swift` now fail the run, §0.2), `scripts/check-ipad.py`, and the UI
tests of the streams whose files the slice touched (groups for §2.1, offline and sessions for §6.3-§6.5,
talk for §6.6 and §3.9, ipad for §1.2 and §7.1), each on this stream's own simulator and ports. New unit
tests go in `Tests/Chat/Transcript/`, new UI tests in `UITests/transcript/`, both added to BOTH project
files.

Slice 3 starts with a look, not with code: seed presets `cron` and `timeline` and screenshot them on the
unchanged train build, because §0.2 found history-path code for the silent run and the model switch that
nobody has seen working. What already reads right is recorded as seen and kept; only the gaps in §2.1 and
§2.2 are built.

---

## 11. Where each row stands, closest first (revision 3)

"Closest" means the least work between now and an honest "done" (implemented AND seen working). Evidence is
what is in git at d63fb40 plus what is in the uncommitted working tree; the working-tree code was read, not run,
in this pass, so nothing in tier B counts as done until its test is seen passing and it is committed.

Run to close anything below (own simulator `HQN-m9-transcript`, UDID `1171A6D2-BE5B-4DA1-BC25-236EEFE4EA14`):

```
scripts/build.sh build <udid> && HQ_IDENTITY=original scripts/build.sh build <udid>
scripts/transcript-unit.sh <udid>                       # includes "Transcript finishing pass" suites
HQN_TRANSCRIPT_ONLY=testT9_CouldntSendCard,... scripts/e2e-transcript.sh <udid> 10020
python3 scripts/check-ipad.py
```

### Tier A: done and seen (5 rows). Nothing left but the stress plan.

L300 (VoiceOver without Markdown), L302 (cron deliveries), L303 (timeline notes), L311 and L982 (in-app Safari,
loopback notice). Left over, small: a cron bubble's hold menu still shows your-own-message items (§2.1); the
finishing pass moves the loopback and deep-link notices from system alerts to the app's notice card.

### Tier B: built in the working tree with tests written; needs one green run, a look at the screenshot, a commit (12 rows)

Ordered by how little is left.

| # | Row | What exists uncommitted | Left to call it done |
|---|---|---|---|
| 1 | L354 Couldn’t Send | `ChatNoticeCard` send card, `LiveChatSession.sendFailure`, draft put back without overwriting typing (`AppModel`), unit `aRefusedSendIsTheComposerCardAndNotATranscriptCard`, UI T9 | T9 green light+dark, look at the shot; add fixture `/__fixture/fail` for `prompt.submit` if T9 uses another path |
| 2 | L353 model can’t start | problem card with "Choose a model", `SessionProblem`, unit `anErrorWithNoTurnRunningIsTheProblemCard`, UI T11 | T11 green; check the button really opens the model list |
| 3 | L363 turn duration | `ChatTurnMarks`, mark on the action row, units `aTurnThisDeviceSaw…`, `theActionRowCarriesTheDuration`, UI T10 | T10 green; relaunch check (mark survives resync, §6.6) is in the unit test only |
| 4 | L331 Show earlier messages | `olderFailed` / `retryOlder`, fixture `/__fixture/older`, preset `long`, unit, UI T15 | T15 green; the spinner state needs its own screenshot |
| 5 | L309 Table sheet | `TableSheetController` ("Copy as Text" / "Copied"), strip + expand button, 2 units, UI T12 | T12 green; paste check is the unit test (tab-separated) |
| 6 | L313 + L312 + L1007 link chips, bare URL label, bounded read | `LinkChipView` with fixed height, `bareLinkLabel` used in the app, `LinkPreviews`, units, UI T13 with `.invalid` host | T13 green; a chip WITH a title and icon needs the `-HQNLinkPreviewStub` seam (§0.1) to be seen, otherwise L313/L1007 stay partial (title-less chip only) |
| 7 | L361 Waking up | `resumeTimeout`, `-HQNResumeTimeout`, "Couldn’t reopen this chat", units for waking / still waking / twice timed out, UI T14 | T14 green |
| 8 | L360 status grace | grace per session (`statusGraceDelay`, on in the app, off by default in tests), unit for the short-reconnect negative case | unit green is enough for the negative case; composer placeholder still not graced (say so or do it) |
| 9 | L307 flag on one line | measured unit `aLongLineWrapsBeforeTheFlagNotInsideIt`, Find sees past joiners | unit green closes it |
| 10 | L366 Message actions | Control-Return key command (`KeyCommands.messageActions`), action on photo bubbles too, unit | unit green + one hand pass with VoiceOver on in the simulator (Accessibility Inspector) or stay partial with that reason |

### Tier C: one focused change each, on code that is already there (4 rows)

| Row | Left |
|---|---|
| L352 error card | Wording, no-retry rule and one-card-per-turn are done by unit test. Left: primary button by kind ("Choose a model" / "New chat" instead of Retry, §6.1), Details as an in-card disclosure that starts closed, a fixture `errors` preset and one UI test with a screenshot. Reuses tier B's problem card action. |
| L344 tool wording | `ToolWords` sizes-in-words, one-line shell output and failed-tool-as-prose exist and are unit tested; wire the three into `ChatRunSummary` / the step row and extend T4. |
| L1003 copy image | The train already copies an image's own bytes from the viewer. Left: "Copy Image" on the bubble's hold menu, the viewer item renamed to match, one UI or unit test reading `UIPasteboard` (§7.2). |
| L981 deep links | Session, connect and the unsupported notice work. Left: the queue for a link that arrives before sign-in, and routing for the kinds that have a native page (§7.1); every other kind keeps the notice. |

### Tier D: pure logic ported and unit tested, nothing on screen yet (6 rows)

Ordered by size of the remaining UI work, smallest first.

| Row | Have | Left |
|---|---|---|
| L329 land on unread | `SeenStore` + landing rule | call it on open in `ChatViewController`, fixture `/__fixture/unread`, UI test (§4.1) |
| L348 N files changed card | `ChangedFiles.derive/title` | new row kind + card, Review opens the existing Changes page (§5.4) |
| L346 inline diffs | `ToolDiffStore`, preview maths | diff block under the edit step in the transcript (§5.2) |
| L321 reply reveal | `ReplyReveal` plan with the web's vectors | the driver in the chat; must respect Reduce Motion and owner note `replies-dont-stream.md` (§3.9) |
| L317 relative / blocked images | `ImageSources` | resolve through `GET /api/fs/download`, the "why blocked" tile (§3.8) |
| L310 math | `MathText` | renderer use (DECISION in §3.5: Unicode tier with source fallback, no KaTeX) |

### Tier E: farthest, nothing written (3 rows)

| Row | Left |
|---|---|
| L347 changed-file preview | whole of §5.3 (depends on L348's card and `GET /api/fs/read-text`) |
| L319 preview sheets stack | whole of §8.1 (depends on L347) |
| L306 code colour once visible | whole of §3.1 (`CodeColourStore`; the hardest to see: needs a frame-by-frame capture of a chat sliding in) |

### Finishing order (replaces §10 for what is left; still one feature per build)

1. Tier B rows 1-10 in the table's order: run, fix, screenshot, commit one row (or one tied group) at a time so each
   can ship as its own build. FIRST action: commit the working tree as it is on `m9/transcript` once both identities
   build, so the pass is not lost.
2. Tier C: L352, L344, L1003, L981.
3. Tier D in table order, then tier E as L348 -> L347 -> L319, L306 last.
4. STRESS PLAN on every row as it closes, on `HQN-m9-transcript-s` and ports 10025-10029.

Count if tier B goes green as written: 5 done now -> up to 17 done (L313/L1007 only with the stub seam), 4 one change
away, 9 with real building left.

---

## STRESS PLAN

Stress tester: simulator `HQN-m9-transcript-s`, fixture on 10025
(`python3 scripts/fixtures/transcript-gateway.py --port 10025 --credentials $SCR/transcript-s.json &`),
own derived data. Each item states what to do and what counts as a pass. A failure is reported as a
failure with its recording or log; no assertion is loosened.

### S1. Load
- **Long chat.** Preset `long` (600 rows, 40 code blocks, 10 tables, 30 link chips, 50 edit tools with
  diffs, 20 cron deliveries). Open, fling to the top and back three times. Pass: no hitch over 33 ms in
  Animation Hitches after the first second; memory growth under 60 MB over the chat's cached baseline;
  `ToolDiffStore` and `CodeColourStore` stay within their bounds (debug counters).
- **Huge single items.** A 3,000-line diff; a 200×30 table; a 50,000-character code block; a 20,000
  character whole reply (reveal paces only the first 1,200); a message with 200 bare URLs (at most 3
  reads in flight, at most one per URL; rows off screen start none).
- **Many files.** A turn that edits 120 files: card shows 5 + "Show all 120 files"; Review list scrolls.
- **Paging.** 40 earlier pages loaded in a row: position holds each time; no duplicate rows (assert
  unique row ids).

### S2. Speed
- Chat open (cache warm) to first frame under 150 ms with preset `code`, coloured on the first frame for
  the visible blocks.
- Title lands for a chip: no visible row moves (frame diff).
- Status pill: a 400 ms reconnect shows no waiting word.
- Reveal: total 280-700 ms; a real 120-chunk stream gets zero added latency.
- Table sheet opens under 300 ms for 12×40.

### S3. Bad network
(Fixture `/__fixture/slow` and `/__fixture/fail`, plus Network Link Conditioner profiles "Very Bad
Network" and "100% Loss" on the simulator host only if the tester owns that setting for its own
simulator; otherwise fixture delays only.)
- Earlier messages: 3 s delay → spinner row; two 503s → failure row and exactly two requests; airplane
  mode on then off → one automatic retry.
- Send: refused → "Couldn’t Send" with reason; 40 s no answer → timeout wording; socket dropped
  mid-reply → "The reply was cut off" with Retry; Retry while still offline → one card, not two.
- Resume: 8 s, 70 s, and 130 s twice (use `-HQNResumeTimeout 6` for the last) → "Waking up…", "Still
  waking up…", then the "Couldn’t reopen this chat" card; "Try again" works after the fixture is made
  fast again.
- File preview: 404, 30 s stall then leave the chat (no late page appears), connection switched mid-read.
- Link titles: stubbed timeout, redirect loop (5 hops), redirect to a private address, 10 MB page
  (stopped at 256 KiB), TLS failure: all leave `host + path` and never retry within the run.
- Changes page from Review with the gateway down: failure wording and "Try again".

### S4. Bad data
- Cron wrappers: unterminated "[Cron delivery: x" (stays a normal message), 161-character job name
  (no match), a job name containing "]" or a newline, a body that is only a footer, `[SILENT]` with
  trailing spaces, `[silent]` lowercase (not silent), wrapper inside a code block (not unwrapped).
- Model switch note with no model, with a provider only, with an id of 300 characters.
- Tables: ragged rows, zero body rows, cells with tabs/newlines/pipes/emoji/RTL text, 1 column.
- Math: unclosed `$`, `$` prices, nested `$$` in code, `\frac` with missing braces, a 10,000-character
  formula (falls back to source, scrolls, does not hang: converter has a 5 ms budget and a 2,000
  character cap).
- Diffs: no trailing newline, binary marker, CRLF, a diff with only a header, non-UTF-8 bytes replaced.
- Tool results: `duration_s` negative or NaN, `inline_diff` a number, result not JSON, 5 MB output
  ("5 MB output" label; body capped by the existing step sheet rule).
- Errors: empty message, 10,000-character message, message that matches two kinds (the web's precedence:
  LIMIT, OWNED, START, BUSY), HTML in the message (shown as text).
- Links: `javascript:`, `file:`, `data:`, `hermes://` with 33 params, a URL with user:password, IDN and
  punycode hosts (shown in punycode when mixed-script), a URL of 8,000 characters, titles with RTL
  override characters (stripped), a 1×1 or corrupt icon (globe shown).
- Images: `../../etc/passwd` as a relative image (the gateway refuses; caption shown), a 60 MB image
  (existing media cap), zero-byte file, wrong extension.
- Deep links: every bound at limit and limit+1; control characters; percent-encoded slashes in the id.
- Unknown `ChatRow.Kind` in an old cache (HQT3 → HQT4): refetch, no crash.

### S5. Interruption
- During a reveal: lock the phone, take a call banner, pull Control Centre, rotate, switch chats, press
  Stop, receive a second message: the reply is complete and correct afterwards, never duplicated.
- During "Waking up…": background for 30 s and return (resume continues or restarts once; the pill is
  right within 1 s); switch to another chat and back; send a message (queued, then sent once).
- During a file read or link read: leave the chat (cancelled; nothing presents later).
- While the Table sheet, a preview stack three deep, or the Safari view is up: a `hermes://session/…`
  link arrives; a push notification is tapped; the socket drops and reconnects. No orphaned sheet, no
  two sheets fighting ("Attempt to present … whose view is not in the window hierarchy" must not appear
  in the log).
- "Couldn’t Send" showing, then the keyboard is dismissed, the app is backgrounded, the phone is rotated:
  the card and the draft survive.
- Memory warning (`xcrun simctl spawn <udid> notifyutil -p com.apple.system.memorystatus…` or the
  simulator's Debug → Simulate Memory Warning) with a diff-heavy chat open: stores empty, rows redraw
  their header-only state, nothing crashes.

### S6. Relaunch
- Kill and relaunch with: an error card, a changed-files card, inline diffs, cron rows, a duration mark,
  a mid-history scroll position, an unread reply waiting. After relaunch from cache (fixture stopped, so
  offline): all of those are drawn from HQT4 exactly as before, code is coloured, the duration mark is
  present, and the unread landing rule applies once the fixture is back.
- Kill during a reveal and during a send that then fails: after relaunch the reply is whole; the draft is
  in the composer (existing draft persistence) and no stale "Couldn’t Send" card is shown (DECISION: the
  card is not persisted; the draft is).
- Kill with a preview stack up: relaunch shows the chat, no sheet.
- Cold-start deep link (`simctl openurl` on a terminated app) for session, blueprint and an unsupported
  kind.
- Upgrade path: launch a build that writes HQT3, then this build: chats reload without a crash.

### S8. Together with the rest of the train (added in revision 2)
- **iPad.** Run presets `cron`, `diffs`, `errors`, `table`, `links` on an iPad simulator of this
  stream's own (`xcrun simctl create "HQN-m9-transcript-s-pad" "iPad Pro 13-inch (M5)"
  com.apple.CoreSimulator.SimRuntime.iOS-27-0`; pick the nearest iPad type from `xcrun simctl list
  devicetypes` if that one is missing) in two panes, in a narrow Split View width, and through a rotation
  with each sheet up (Table, preview stack three deep, Safari view, message-actions sheet). Pass: no crash
  (an unanchored action sheet is the known way to crash), no sheet lost on rotation, the chat still the
  right pane's top screen after every close, the unsupported deep-link notice says "iPad", Control-Return
  opens message actions and is greyed in the menu when no chat is open, reply reveal is skipped in two
  panes and runs in the narrow width.
- **Group room.** Open a room from the groups fixture (`scripts/fixtures/groups-gateway.py` on a port in
  10025-10029): no reveal, no "Choose a model" on a problem card, cron/timeline parsing does not touch a
  member's message that merely begins with "[Cron delivery:" inside a quoted block, the earlier-messages
  row works or is absent (never a dead button).
- **A delivery from another bot next to a cron delivery** in one chat: two different bylines and faces,
  runs do not join, Copy from the hold menu gives each body without its wrapper.
- **Talk and Read Aloud.** With Talk on, a whole reply is spoken from its first word while the reveal is
  still drawing; Read Aloud on a revealing reply reads all of it; the duration mark does not push Read
  Aloud off the action row at any text size.
- **Offline.** Fixture stopped mid-chat: the `ConnectionBanner` shows at the top, the pill follows the
  grace, a send made now gives "Couldn’t Send" with the offline sentence (one card), the Sessions row
  does not read "Not Delivered" for it, and the launch screen path (relaunch offline) still opens the
  cached chat with cron rows, cards and marks drawn.
- **Cards piled up.** Force all at once: session problem card, "Couldn’t Send", a queued message, the
  Talk tip, the keyboard up, AX3 text. Pass: the newest message is still visible or reachable by one
  scroll, nothing overlaps, every button is hittable.
- **Source scans.** `A11yLintTests` and `scripts/check-ipad.py` pass with this stream's files in place; a
  `// motion-ok` or `// a11y-font-ok` mark added by this stream is listed in the report with its reason.

### S7. Accessibility sizes and modes
Run presets `cron`, `tools`, `diffs`, `errors`, `table`, `links` at Dynamic Type XS, default, XXXL and
AX5, in light and dark, with Bold Text, Increase Contrast, Reduce Motion, Reduce Transparency, and
Button Shapes each on once.
- Pass: no clipped or overlapping text; every wrapping row keeps 12-14 pt vertical padding; cards
  (changed files, session problem, Couldn’t Send, link chip, earlier row) grow in height and stack their
  buttons vertically at AX sizes rather than truncating button titles; hit targets at least 44×44 pt.
- VoiceOver pass over each preset: every row is reachable in order; labels match §1.1; no raw Markdown,
  no "[Cron delivery", no "[System:"; "Message actions" works on user, bot, cron and error rows; the
  earlier-messages row, card buttons, table cells and chips all have labels and the right traits; status
  changes are announced once, not on every tick.
- Reduce Motion: no reveal, no colour dissolve, no animated landing.
- Diff colours also carry "+"/"−"; link chips and the "New" divider pass 4.5:1 contrast in both
  appearances (Increase Contrast on and off).
- Switch Control / Full Keyboard Access: "Show earlier messages", "Try again", "Review", "Choose a
  model", "Try Again", "Copy as Text" reachable and operable; Control-Return opens message actions.
- Right-to-left (pseudo-language launch argument `-AppleLanguages (ar)` is not needed; use
  `-UIViewLayoutDirection RightToLeft` if supported by the scheme, else the Arabic simulator language):
  bylines, chips and the card mirror; code and diffs stay left-to-right.

## 12. n20 revisit — decisions

Items shipped once on `integrate/n20-r2` (TestFlight build 400) but never reached `main`, rebuilt one at a time in
their own worktrees against today's renderer. Each item keeps its own numbered subsection, matching
`docs/briefs/n20-transcript-report.md`.

### 12.3 F17 — formulas drawn as maths (L310)

- DECISION: no KaTeX, no web view, no new dependency. A formula is converted to readable Unicode (`MathText.readable`:
  Greek, operators, super/subscripts, `a⁄b`, `√(…)`) and drawn in the system serif (New York) at the text's own size,
  letters italic as variables, `sin`/`lim`-style names and longer words upright (`App/Chat/Render/MathStyle.swift`).
  It follows Dynamic Type and uses the text's dynamic colour, so dark mode and Extra Large text need nothing extra.
- DECISION: formulas are taken out before Markdown parses the reply (`MathText.extract`, private-use tokens), so
  `_` and `\` inside a formula never become emphasis or escapes; code spans and fenced code are left alone; `$5 and
  $10` stays text (the opening `$` is not followed by a space; the closing one is not after a space or before a digit).
- DECISION: `$$…$$` / `\[…\]` on their own lines is a display formula: its own paragraph, centred, with 8 pt above
  and below. Inside a sentence it is drawn inline.
- DECISION: anything outside the subset shows as its TeX source, never a half-converted mix: inline in monospace
  with its delimiters, a display formula as the same card type fenced code uses (`appendCodeText` builds the exact
  `.code` block `appendCode` does), so it scrolls sideways like any other wide code instead of clipping — the 2026-10-25
  screenshot of the first build of this item showed `\end{aligned` cut off; that card was its own one-off box, not
  this shared one. The web shows source until KaTeX loads; native shows source only for what it cannot draw.
- DECISION: a big operator's limit (`\sum_{i=1}^{n}`, `\lim_{n\to\infty}`) is drawn as real characters at a reduced
  size (0.72×) with a true baseline offset — not squeezed through the single-character `superscripts`/`subscripts`
  tables, which read as a cramped smear next to a tall glyph like ∑ (the same 2026-10-25 screenshot: "the Σ limits
  were tiny and cramped"). `MathText.limitBelowOpen`/`limitAboveOpen` mark the argument; `MathStyle` renders it and
  tags the run with `.mathLimitOffset` (a delta), which `MarkdownRenderer.appendParagraph` adds on top of the
  paragraph's own line-centring baseline offset — that call sets `.baselineOffset` across the whole paragraph, which
  would otherwise overwrite a per-run offset set directly.
- DECISION: a formula's rendered text carries `.mathFormula`, so `linkBarePaths` (bot-written file paths, 2026-10-29)
  never treats a readable fraction or a `\text{/Users/me}` argument as a path to open.
- DECISION: VoiceOver reads "Formula: " and the TeX source; a tap-and-copy of the formula and the reply's Copy give
  the source as written. User bubbles (`renderUser`) are unchanged: no math reading, per spec (owner, your own words
  stay words).

