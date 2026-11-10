# Architecture (milestone 1)

Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (everything is main-actor unless marked
`nonisolated` / `@concurrent`), iOS 26+. One app target; `HermesKit/` holds non-UI code, `App/` holds UI.
Protocol facts live in `docs/spec/*.md` — follow them exactly; when the spec and the reference web app disagree,
the web app's behaviour wins.

## Folders and ownership

```
HermesKit/
  Net/      GatewayAccount.swift (saved account model), Keychain.swift, AuthSession.swift (bearer/token/session,
            Nous refresh rotation, single-flight refresh), NousSignIn.swift (ASWebAuthenticationSession + 127.0.0.1
            loopback listener), REST.swift (URLSession JSON client, auth headers, 401 → refresh once),
            RPCSocket.swift (JSON-RPC 2.0 over URLSessionWebSocketTask, ws-ticket, reconnect with back-off,
            pending-request map, event AsyncStream), Probe.swift (/api/status → which sign-in options)
  Model/    Bot.swift, SessionSummary.swift, ChatItem.swift (one row in a chat: user / assistant / tool / system,
            stable id, text, tool name+summary+state, timestamp), Wire.swift (Codable DTOs straight from the spec)
  Store/    TranscriptCache.swift (disk: Application Support/transcripts/<account>/<session>.json, plus an in-memory
            LRU; read synchronously on the main thread in < 5 ms for 500 items; writes debounced off-main),
            BotStore.swift, SessionStore.swift (@Observable, cached to disk too so the lists draw instantly)
  Chat/     ChatSession.swift (@Observable per open chat: items, isRunning, send(text), stop(), applies stream events
            to items, merges fresh history over cache by id without reordering rows already shown)
App/
  AppDelegate.swift, AppModel.swift (current account, stores, socket lifecycle on foreground/background)
  SignIn/   SwiftUI: address field → probe → "Sign in with Nous" primary / password or token secondary
  Bots/     BotsViewController (UICollectionView list, diffable), BotCell
  Heads/    HeadView (a bot's picture everywhere), MatrixHead.swift (the default dot-matrix head: one of thirteen
            outlines drawn LED by LED on a 15 × 15 grid, with eyes, a mouth and an unread dot; outline and colour
            picked from the profile name), HeadRecord / EditHeadView (saved heads, Edit Head)
  Sessions/ SessionsViewController (basic list)
  Chat/     ChatViewController, MessageCell, ToolRowCell, ComposerView, JumpButton, Render/ (MarkdownRenderer,
            TextLayout cache)
  Root/     MainTabController (UITabBarController: Bots, Sessions; native iOS 26 glass tab bar), SceneDelegate
```

## Feel rules (non-negotiable)

- **Navigation is UIKit** (`UINavigationController` inside each tab). Lists may use `UIHostingConfiguration` cells.
- **Chat list = inverted `UITableView`** (transform `scaleY: -1` on the table and each cell's contentView): row 0 is the
  newest item, so the chat starts at the bottom with no scroll-to-bottom jump, and older history appends at the far
  end with no offset correction. `estimatedRowHeight = 0`; every height comes from `TextLayout` (exact, cached by
  item id + content hash + width), so scrolling never jumps.
- **Instant open:** `ChatViewController` is built with its items *before* the push: the cache read and layout of the
  visible rows happen synchronously in `init`/`viewDidLoad`, so the first frame of the push animation already shows
  the chat. Heights for the rest are computed off the main thread (CoreText / `NSAttributedString.boundingRect`
  measure is thread-safe) and filled in progressively from the newest end; older pages load as you near the top.
- **Fresh history** arrives after the push and is merged in place (same ids keep their rows; new rows insert without
  animation at the newest end only if the user is at the bottom, else a jump button shows a count).
- **Composer** is pinned to `view.keyboardLayoutGuide.topAnchor` (`keyboardLayoutGuide.usesBottomSafeArea = false`
  handled so the bar sits 8 pt above the keyboard and at the safe area when down); the table's visual-bottom inset
  is updated in `viewDidLayoutSubviews`, so it moves in the same animation as the keyboard.
  `tableView.keyboardDismissMode = .interactive`. No notification-based keyboard math.
- **Streaming:** deltas are coalesced to at most one layout per display frame (CADisplayLink or `Task` throttle);
  only the streaming row's height is recomputed; `UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }`.
  When a reply grows taller than the screen, keep its top in place (new reply is read from its top).
- **Glass:** only system glass (`UIGlassEffect`, `.glassEffect()`, system bars). Never fake glass with blur+tint.
- Text: Dynamic Type aware (preferred fonts), Telegram-like bubbles per `docs/spec/06-native-feel-and-design.md`.

## Concurrency

- Network types are `nonisolated final class … : Sendable` or actors; they deliver results to main-actor stores.
- `RPCSocket` exposes `func call<R: Decodable>(_ method: String, _ params: some Encodable) async throws -> R` and
  `var events: AsyncStream<RPCEvent>`; one socket per account, reconnects on foreground / network change.
- Never retry a sign-in in a loop (gateway rate-limits logins per IP).

## Integration (App/AppModel.swift)

`SceneDelegate` shows `LaunchViewController` (page colour, a spinner only after 0.6 s) while `SignInService.restoreState()`
reads the Keychain off the main thread, then either `MainTabController` (lists painted from their disk caches) or the
sign-in form (`SignInServiceDriver` adapts `SignInService`). `AppModel` implements `AppServices`: one `LiveGatewayClient`
per account, `BotStore` + `SessionStore` (files under Application Support/lists, keyed per account),
`TranscriptCache.shared`, and a `ChatWarmer` that saves the newest bots' chat tails before a tap (spec 03 §4.1) so a
first open paints from disk. `chat(for:)` builds a `LiveChatSession` synchronously from cache; its app-model hooks
(`onObservingChange`, `onOpenSettled`, `onRunningChange`) drive focus, unread (`markRead` after fresh history,
`seenThrough` on leaving), "Working…" and the stores' list cadence. Sign Out (Account sheet) stops the stores, ends the
session, forgets this account's caches and routes again. DEBUG-only launch hooks: App/Debug/DebugHooks.swift.

## Verification round 2 notes

- **Launch:** nothing links AuthenticationServices. `WebAuthBrowser` `dlopen`s it and drives `ASWebAuthenticationSession`
  through the Objective-C runtime when Sign in with Nous opens its sheet; linking it loaded ~1,080 more images before
  any app code ran (1.7 s to `didFinishLaunching` on the simulator, now ~0.47 s). Keep heavy frameworks out of launch.
- **History reads:** a refresh reads back (joined pages, at most 500 rows) until it reaches the newest prompt shown, so a
  long tool-heavy turn is always folded whole; older pages are folded together with the partial turn on top
  (`LiveChatSession.headRows`), so a turn crossing a page boundary is one reply.
- **Chat warmer:** a roster change never cancels a pass that is reading; a pass that read nothing doesn't start the
  30 s gap.
- **Chat bottom edge:** the composer's soft edge reaches ~40 pt above it, so it is hidden while the list follows its
  newest end (the newest bubble rests crisp) and shown once rows run under the composer.
- **Text:** TextKit 1 adds the font's leading under each fixed-height line; `MarkdownRenderer.paragraphStyle(lineHeight:font:)`
  subtracts it (Body 17 → 23 pt pitch).
- **Code:** `SyntaxHighlighter` (native, cached, colours only) runs for settled replies (`BubbleRow.streaming` is part of
  the row's variant).

## Verification round 3 notes

- **Send lift (spec 06 §5.2):** `ChatViewController.send` flushes the session (`ChatChangeFlushing`) and applies
  synchronously, so the bubble's row lands in the frame the field clears. The lift is a stand-in `ChatBubbleCell`
  above the composer (the field's glass would blur the real row) that flies from the draft's text box
  (`ComposerView.liftSource`) to the live row over 340 ms `(.22,.8,.25,1)` while its mask opens from the text to the
  bubble; the content offset carries the rows above. A reply landing mid-lift hands the offset to the stream glide.
- **Unread:** `LiveChatSession.seenThrough` is the newest stored row any history read returned (`newestStoredAt`): a
  turn sent here keeps local ids after its end read, and a folded turn carries its first row's time. A chat left
  before its turn-end read reports the read later (`onSeenAfterLeaving` → `BotStore.noteSeenAfterLeaving`).
- **First page owed:** an open whose REST read failed while the resume answered keeps its skeleton and reads again
  (2/5/10 s and on each `gateway.ready`); only after the last try does it show the failure with Retry.
- **ws-ticket** goes on the fail-fast pool (the connection dials only with a network path; a refused gateway is an
  answer for the back-off ladder, not a 15 s wait for connectivity).
- **Bot rows** are patched from the chat (`BotStore.noteChatActivity`) when a watched turn ends off screen or a chat is
  left, until the next roster read replaces them.

## Testing

- `scripts/build.sh test [udid]`: unit tests (live fixture suites skip unless their fixture runs, see NetTestSupport).
- `scripts/e2e.sh [udid] [runs]`: end-to-end UI tests (UITests/EndToEndTests.swift, scheme HermesHQNativeUI) against
  the performance fixture it starts on 127.0.0.1:9712 (`HQN_E2E_PORT`), credentials passed to the runner as
  `TEST_RUNNER_HQN_UI_CREDENTIALS`; prints each test's result and the app's own first-content measures.

- Unit tests (Swift Testing) for: wire decoding of real fixture payloads, stream-event assembly, cache round trip,
  markdown rendering of code fences, auth header selection, refresh single-flight.
- Simulator "HQ Native" (00CC6911-5CB1-458A-AEAE-DE5A5CB4F81A) against a stand-in gateway from the web repo; then
  read-only on the owner's gateway.

## Voice memos (milestone 2, docs/spec/1x-voice.md)

- `HermesKit/Voice/`: the gesture reducer (`MemoGesture`, a port of the web's), the recorder (`MemoRecorder`, AAC mono
  24 kHz; a DEBUG simulator fixture writes WAVs), `AudioSessionCoordinator` (the only owner of AVAudioSession: active
  only while recording or playing, released with `.notifyOthersOnDeactivation`), `MemoPlayer` (one `AVAudioPlayer`
  app-wide, on local files only), `MemoUploader` (managed-files staging → `file.attach` → transcription), and the
  per-account stores (`MemoAccountStores`: drafts, waveform shapes, the playback cache; purged on sign-out; memos/ kept
  out of backups and orphaned recordings swept a day old on every sign-in).
- **Blocking audio calls never run on main.** `setCategory`/`setActive` and every `AVAudioRecorder` call (make,
  `record`, metering, `stop`) run on one serial queue (`AudioWork`, `.userInteractive`); who holds the session is
  bookkept on the main actor at once. The save of a take waits for the recorder's `stop` on that queue (its file is
  complete then). Signposts "memo start" and "memo send" (subsystem `com.charlesmcdowell.hermeshq.native`, category
  `memo`) time touch-down → recording and release → bubble on a device.
- `LiveChatSession+Memo.swift`: `sendMemo` runs through the normal send path; the watchdog arms only when
  `prompt.submit` goes out, and the send holds its chat strongly until it lands. Three VOICE hooks in
  `LiveChatSession.swift`: `stop()` → `memoStopWhileStaging()` (a memo still staging is cancelled and handed back as the
  draft at once; its own turn settles with no interrupt), `stopObserving()` → `memoQueueLeaving()` (memos still queued
  come back as drafts, with their words), and `beginSend` keeps the staging `Task` for Stop.
- `App/Chat/Voice/`: `MemoController` (one take app-wide, its chat frozen at touch-down; it also keeps every chat's
  memo notices by scope, so a notice for a chat that was left shows when it opens next), `ChatVoiceHost` (one per chat
  screen: mic, recorder rows, floating circle, draft chip, notice card, tips; a finger's move or a level tick only
  redraws the recorder, the screen lays out again only when the phase changes), and the memo bubble
  (`MemoBubbleLayout` / `MemoBubbleView`, exact heights; playing and speed never change them). The waveform's scrub
  pan is gated by its own delegate: never override `UIView.gestureRecognizerShouldBegin` in a cell's content (UIKit
  asks it about the table's pan too, and a vertical drag would stop scrolling the chat).
- Tests: `Tests/Voice/` (unit + live fixture on 9728), `UITests/voice/` via `scripts/e2e-voice.sh` (fixture on 9727),
  stand-in gateway `scripts/fixtures/voice-gateway.py`, shots `scripts/voice-shots.sh` (dev fixture on 9726).

## Milestone 2 integration (m2/integrate)

Seven streams (questions, attachments, voice, menus, activity, pages, settings) were built on their own branches and
merged here; their reports and the merge log are in `docs/m2-stream-reports.md`. What holds them together:

- **Composer row** (`ComposerView`), web phone order `[☰][+][field (mic inside its trailing end)][primary]`, bottom
  to top: the row, the voice draft chip (leading at the field, may use the whole row), the attachment tray (first tile
  at the field's leading edge, trailing margin = the screen's side margin). ☰ = `commandsButton` (menus), + =
  `leadingAccessories` (attachments); the primary is Send / Stop / disabled Send, or the recorder's Send. The mic shows
  only on an empty field with an empty tray. The question dock (questions) replaces the whole composer while a clarify
  question waits.
- **Above the composer**, bottom to top (all in `ChatViewController`): queue card → voice memo notice card (collapsed it
  is the queue card's top) → activity shelf (subagents, tasks, goal) → tucked-prompt chip → jump button. The transcript's
  bottom inset (`transcriptBottom`) is the top of the highest of these that shows; the jump button's bottom constraint
  is shared with the activity controller, which lifts it over an open card.
- **Send pipeline** (`LiveChatSession`): one `send(_:display:attachments:)`; `beginSend` takes `display` (a skill's
  invocation, menus), `attachments`, and `memo` (voice stages it first); `submit(_:draft:…)` hands the draft back on a
  refusal or Stop. `QueuedMessage` carries attachments, memo, `hidden` (a goal continuation, activity) and `display`.
- **Transcript cache format "HQT3"**: attachments' media records plus activity's tool cards; older files read as a
  miss (fresh history), never a misread.
- **Cross-stream hooks** are set once at launch in `App/Integration/M2Wiring.swift` (Tool Calls in Settings, More ›
  Settings / Capabilities, the Kanban Tab row on Settings › Appearance › Tabs, the bot row menu's Memo tile). A bot's
  own chat opens Bot Info from its title; ⋯ › Info stays the chat's info. Removing a saved gateway purges every stream's per-account data.
- **Generated images**: the attachments stream's row draws `image_generate` (media tile, viewer, "Open image" when it
  can't load); the activity card is the fallback when that row has nothing to show.
- **Integration test runs**: each `scripts/e2e*.sh` takes `HQN_DD` (derived data), a screenshot folder and its ports
  (`HQN_ANY_PORT=1` lifts the per-stream port ranges; settings: `HQN_SETTINGS_PORTS`), so suites can run in parallel on
  separate simulators. `-HQDebugResetAccounts YES` also forgets the pages' saved tab (a clean first run starts on Bots).

### Verify round 1 repairs (m2/integrate)

- **Dock priorities:** the jump button's bottom constraint is 740 and the composer, queue card and memo notice resist
  squashing at 760, so a tall shelf + queue card + keyboard pushes the (hidden) jump button against its top limit
  instead of squashing the composer row (its field had dropped under the keys while Stop stayed put).
- **Recorder rows take the whole composer row** (`ComposerView.recorderContent`): ☰ and + hide and the field's glass
  widens over them for holding, locked and review, as Telegram's attach button gives way. Review draws as many of its
  40 bars as fit (`MemoLockedRow.reviewBars`); `MemoWaveView` never draws past its own width.
- **Audio:** `CompletionCue` plays only while voice holds no session, always under `.ambient` + `.mixWithOthers`
  (voice releases the session without restoring its category).
- **Question dock vs voice:** the dock covering the composer turns a take still recording (or in review) into the chat's
  draft chip (`ChatVoiceHost.composerCovered`). The dock rises from below the screen edge and leaves the same way
  (opaque, a 0.32 s critically damped spring) instead of a cross-fade; Next focuses the new page's field before the old
  page hides, so the keyboard never dips. Its hairline follows the whole outline.
- **One header on every tab:** with two or more gateways the page tabs (Jobs, Kanban/Artifacts, More) carry the same
  `GatewayTitleSwitcher` subtitle as Bots and Sessions (the subtitle shrinks iOS 26's inline large title, so tabs
  without it read larger). A gateway switch clears the rebuilt tabs' saved-tab read (`PagesTabs.skipRestore`) and
  carries More's Settings / Gateway pages to the new More stack (`carriedMoreStack` / `adoptMoreStack`). More leads with
  the gateway card (`MoreRow.card`, M2Wiring "account").
- **Sheets:** every sheet uses the `ChatSheet.wrap` bar (✕ leading, inline title, no grabber), Settings, Kanban's How
  It Works, failure Details, Select Text and the menus' pickers included. In the iOS look a half-height sheet sits on
  Liquid Glass (`hqGlassPage()`: `GlassSheetTrait` makes `HQPalette.sheetPage` clear, rows stay on solid
  `HQPalette.sheetCard`); full height, regular width, the Mac and the Desktop Look draw the opaque grouped page. A sheet
  kept opaque at every height (`hqOpaqueGroupedPage()`) says why on that line (`solid-ok:`, spec 06 §8 rule 0).

### Verify round 2 repairs (m2/integrate)

- **Opening a chat with shelf state never slides it:** an idle chat's resume takes a finished task list straight as
  Previous tasks (`TodoState.restore`); a chat not bound yet reads the store's state by stored id
  (`ActivityStore.activity(storedIds:profile:)`), so a reopen draws its shelf in the first frame; shelf changes during
  the push land at once (`ChatViewController.shelfMayAnimate`).
- **One column above the composer:** the queue card, the memo notice and the shelf follow the composer row's side inset
  (`ComposerView.currentSideInset`, `ChatViewController.dockSideInset`, `ChatActivityController.setSideInset`). The
  shelf's height is capped at the room under the status line (`ActivityShelfView.maxHeight`): opened cards give way.
- **Composer:** the field is measured at the width its text gets (`rowGeometry` / `textWidth`), again whenever that
  width changes in `layoutSubviews`. Hidden ☰ and + keep their own frames; after the recorder closes they wait for the
  field to narrow and fade in.
- **Rows:** a deleted row's cell is hidden in the update that deletes it (UITableView keeps it until the update's
  completion, a frame later), found among the table's subviews after the batch — never by asking the table for cells
  between the `rows` change and the batch — and never one the table shows; `cellForRowAt` and `willDisplay` put a
  hidden cell's alpha back (a cell the table prepared ahead for a re-inserted row with the same id had stayed hidden). A stream glide survives a non-animated dock inset change (`streamRemaining`;
  an animated one still carries the rows in its own animation).
- **Glide headroom:** a glide, a hold glide or the send lift that starts the rows above their resting place in a chat
  shorter than the screen gets `glideHeadroom` added to the flipped table's `contentInset.bottom` for its duration
  (`ensureHeadroom` / `releaseHeadroom`); the transcript's real top inset is `topInset`. Without it UIKit pulled the
  out-of-range offset back on its next layout pass: one frame at the final place, then the motion restarting from below
  (memo sends, the flash on a send or a reply's arrival in short chats).
- **Holding the row being read:** the `.row` anchor carries the rows under the top one as fallbacks; an update that
  replaced the top row (a Tool Calls style switch rebuilds a step block under new ids) holds the first one it kept.
- **Row model:** messages that shrink without a reset leave `ChatRowModel.builtFrom` past the end; `flush` then rebuilds
  the model whole (`isStale(forMessageCount:)`) and `rebuildNewest` clamps (it trapped on a reversed range under load).
- **Open chats follow bot edits:** `AppModel.refreshOpenChatIdentities` (on every roster change) updates an open chat's
  title, owner name, head (`LiveChatSession.head` is a `var`) and placeholder (`ChatViewController.botIdentityChanged`).
- **Pages:** transport failures read as "Can’t reach your gateway…" (`PagesREST.transportReason`); one-gateway page tabs
  carry the link subtitle (`LinkSubtitle`); a page left on More's stack whose row moved to tab 3 is dropped, and page
  controllers take their store's callbacks back whenever they show (`claimStore`). New Task is on the `ChatSheet.wrap`
  bar; the Kanban "Waiting on you" callout's card is the row background.
- DEBUG: `[Scroll] insets` lines under `-HQDemoTraceScroll`, the chat title's accessibility value names its head (`hex/hearts`) for the UI tests, and
  `-HQDebugMotionTrace YES` writes every row's per-frame move to the app's tmp/motion-trace.log (a UI test's app has no
  console). Page notices wrap fully (the can't-reach words are three lines).

### Verify round 3 repairs (m2/integrate)

- **The queue outlives the screen** (`QueueStash`, `LiveChatSession+Away.swift`): the app's chats (`keepQueue()`, set by
  `AppModel.chat(for:)`; tests and previews leave it off) write their queue through to the account's stash while they own
  it (one live chat per scope; a second screen on the same chat never takes or overwrites it). `stopObserving` with
  messages still queued and not parked keeps listening (`drainingAway`: events, link, watchdog, reconnect, frames) and
  the app model holds the chat (`awayChats`) until `endAwayDrainIfDone` (queue out or parked, turn over); `chat(for:)`
  returns that chat on a reopen. A parked remainder, or everything after an app kill, comes back on the next open (the
  attachments center registers queued photos at launch so its sweep keeps them). Memos still leave as draft chips. A
  send refused off screen puts its words in the chat's draft. Sign-out and gateway removal purge the stash.
- **Park:** a fresh message unparks the queue (sent while idle it goes first; the parked ones follow its reply).
- **Glides keep their own clock** (`GlideClock`): a stream, hold or jump glide counts each frame's real length, but a gap
  over 50 ms counts as one ordinary frame, so a main-thread hitch pauses it instead of skipping its rest in one frame (the question dock's exit: the simulator's
  keyboard teardown held the main thread ~200 ms and the reply's glide jumped 24–37 pt). The motion trace
  (`-HQDebugMotionTrace`) stamps every line with its time and logs `stall N ms`, dock show/leave and inset changes.
- **Bot Info edit guard** (`EditingGuard`): the sheet holds while any page on its stack has changes; a swipe down asks on
  the page showing. Bot Info re-reads the lock when it shows again.
- **Disabled bar actions** (`UIBarButtonItem.setProminentEnabled`): Save, Add, Create and Send are the tinted capsule only
  while they can act; disabled they are plain items the system dims.
- **Bots rows** carry `Bot.previewPrefix` ("Draft:", "From Inbox:") drawn in the label colour; `BotStore.draftWords`
  reads the composer's drafts (refreshed when a chat is left or a draft changes off screen).

## Watch Browser (m5/browser)

- `HermesKit/Browser/`: `BrowserWire` (the hermes-hq-browser plugin's protocol 3: rows, state, frames, input, the
  socket address, AutoFill keyboard slots — port of the web app's src/browser-watch/model.ts), `BrowserTrackpadMath`,
  `BrowserService` (per account: plugin discovery with the dispatch-browser fallback, the shared activity socket
  `BrowserActivityChannel` with a 3 s linger and a 3 min kept list, `/bots`, the 3.6 browser choice) and
  `BrowserWatchSession` (one viewer's watch socket: hello, view, state, input with epochs, typing kept through a
  reconnect, ping/pong, a 25 s silence watchdog, 4404 = closed). `LiveGatewayClient.pluginSocket` mints a fresh ticket
  per plugin socket (not the /api/ws lane).
- Frames: parsed (JSON + base64) on the socket's receive task, decoded by `BrowserFrameDecoder` on its own queue
  (`kCGImageSourceShouldCacheImmediately`; one decoding, one waiting, replaced frames acked unseen); the main thread
  only sets a CALayer's contents. Acks are paced at 33 ms (30 fps). Measured on the simulator: p50 33 ms, p95 36 ms,
  0 main-thread decodes (UI test 1 reads it from the stage's DEBUG accessibility value).
- `App/Browser/`: `BrowserViewerController` (full screen; native glass buttons ride `keyboardLayoutGuide`),
  `BrowserStageView` (trackpad touches), `BrowserKeyField` (hidden text / username / password / one-time-code fields
  that pipe typing and AutoFill to the page), `BrowserChatCard` (a `.browser` chip on the activity shelf),
  `BrowserChoiceController` (Bot Info › Browser), `AppModel+Browser` (wiring). Nothing in it logs page text, typed text
  or addresses; `AppLog.note("browser", …)` breadcrumbs are content-free.
- Tests: `Tests/Browser/BrowserWireTests.swift`; `scripts/e2e-browser.sh <udid>` (fixture
  `scripts/fixtures/browser-gateway.py` on :9800, frames from `make-browser-frames.swift`).

## Notifications (m6/push)

- **Identity** (`HQ_IDENTITY`, project.yml): `native` (default) or `original` (`HQ_IDENTITY=original scripts/build.sh`;
  sets `HQ_ORIGINAL=YES` so xcodegen includes project-original.yml, which picks the original table and embeds the
  extension). Build settings `HQ_X = $(HQ_X_$(HQ_IDENTITY))` feed the bundle ids, Info.plist (`HQIdentity`,
  `HQKeychainService`, `HQSignedOutKey`, `HQAppGroup`, display name, URL scheme) and `App/Identity/HermesHQ-<identity>.entitlements`;
  `AppIdentity.current` reads them at run time (`AccountVault.app`, the Nous callback scheme, `canPush`). Only the
  original topic (`com.charlesmcdowell.dispatch`) can get pushes: the relay and the plugin refuse any other.
- `Shared/` (app + extension): `PushSeal` (AES-256-GCM, AAD "dispatch-push seal v1", kid, keys in Keychain
  `ai.hermes.ios.push-seal`), `PushFaces` (bot faces, `ai.hermes.ios.push-face`, INSendMessageIntent decoration),
  `PushAlertDiagnostics`, `NotificationOpener` (the extension's whole job as a function the unit tests run — `simctl push`
  never runs an extension). `NotificationService/` is the thin extension target (default isolation nonisolated).
- `HermesKit/Push/`: `PushPolicy` / `PushAnswers` / `PushLedger` (ports of build 240's rules and UserDefaults keys),
  `NotificationText` (alert words, previews, secret masking: the shared cases file), `NotificationPrefs` +
  `NotificationRules` (`hermes.notificationPrefs`, links, targets, Messages rules).
- `App/Notifications/`: `PushRegistrar` (status probe, `PUT/DELETE devices/{id}`, `POST approvals/{id}`, one
  registration at a time, saved answers), `NotificationHub` (the center's delegate, installed in `didFinishLaunching`;
  categories `DISPATCH_APPROVAL` / `_LOCAL`; local alerts; `willPresent` turns another chat's reply into the peek; taps →
  `openNotifiedChat`; badge), `ReplyPeek` (UIGlassEffect capsule), `PushSetupOffer`, `NotificationsSettingsView`,
  `AppModel+Notifications` (wiring: activate, sign-out / switch leave the gateway first with a 4 s budget, the directory
  of who each chat is from the roster and Sessions, `refreshBadge`, links).
- Local alerts come from `AppModel.gatewayEvent` (turn ends of chats in `runningChats`) and
  `ServerRequestCenter.onArrived` (approvals, questions, passwords); a kind the plugin delivers is not posted locally.
- Nothing logs alert text, tokens or keys: `AppLog.note("push"|"notify", …)` breadcrumbs only.
- Tests: `Tests/Notifications/` (ported web checks on `Tests/Fixtures/push/*.json`, extension, routing, badge, registrar
  against a fake plugin, identity, the web app's Keychain item); `scripts/e2e-push.sh <udid>` runs
  `UITests/push/` against `scripts/fixtures/push-gateway.py` (port 9810–9819; deliveries via `xcrun simctl push`).
- The notification center delegate uses the completion-handler forms and finishes them on the main thread: with the
  async forms Swift called UIKit's completion off main and UIKit raised "Call must be made on main thread" on a tap.

## Share extension (m9/share, docs/spec/3x-share.md)

- **Targets** (project.yml): `HermesHQShare` (the extension, `com.charlesmcdowell.dispatch.share`, principal class
  `ShareViewController`, five activation keys, App Group + exactly one Keychain group: the app's) is embedded by
  project-original.yml only, so the native identity carries no extension. `HQShareProbe` is a test-only host app
  (presents the real system share sheet with the items a UI test names); it is never embedded or archived.
  `scripts/check-share-target.sh <built .app>` checks the embedded extension (ids, versions, activation rule,
  entitlements, privacy manifest, no DEBUG hook in Release, no Keychain add/delete linked).
- `ShareKit/` is compiled into the app AND the extension and is self-contained (Foundation, Security, CryptoKit,
  ImageIO, AVFoundation, UniformTypeIdentifiers; no UIKit, no HermesKit; every declaration `nonisolated`):
  `ShareIdentity` (App Group, Keychain item, storage names kept as build 240 wrote them), `ShareModels` + `ShareStore`
  (roster.json, avatars/, choice.json, last-sent.json; DEBUG-only debug.json), `ShareKeychain` (reads the app's item,
  writes renewed cookies or a rotated Nous pair back only when the item is unchanged), `ShareRules` (prompt text,
  names, limits, account key: copies of HermesKit's rules, held together by parity unit tests), `ShareReach`,
  `ShareFailure` (the sentences), `ShareItems` (item providers → staged files), `ShareMedia` (JPEG ≤ 3072 px without
  metadata, drawn in strips for a baseline JPEG so a 48 MP photo stays inside an extension's memory; movies re-wrapped
  without location), `ShareMultipart`, `ShareSocket`, `ShareSender` (the whole send: §6.2's order), `ShareSheetState`.
- `ShareExtension/`: `ShareViewController` (hosts the SwiftUI sheet, completes or cancels the request),
  `ShareModel` (@Observable; phases loading / ready / sending / sent / blocked), `ShareView` (system list and bars;
  the progress card is real Liquid Glass), `SharePictures` (draws a picture that came as a `UIImage` into a bitmap;
  the one UIKit piece of the loader, handed to ShareKit as `picture:`; also compiled into the app, only so the unit
  tests reach it).
- **A photo is read in three ways**, in this order: the file behind it, its bytes, the picture itself (an app that
  shares a `UIImage` has no file). Whichever works ends as the same 3072 px JPEG without metadata. Past ten photos or
  ten files nothing more is read and the sheet says "Only the first 10 photos are sent." (on the simulator iOS
  sometimes offers the target for eleven and sometimes keeps to the activation rule, run to run).
- `App/Share/`: `ShareRosterWriter` (debounced, off the main thread; faces drawn with `HeadRenderer.picture`),
  `ShareRosterRows` (which bots, in what shape), `AppModel+Share` (`shareRosterChanged`, `shareLeaving`,
  `shareActivated`, `openSharedChatIfAny` → `openNotifiedChat`). The hooks are no-ops in a build without the App
  Group. Shared-file edits are marked `// [share]`: AppModel.swift (5 lines), AppDelegate.swift (1),
  AppModel+Notifications.swift (1: `ShareInbox.personAsked()` when the person opens a chat from an alert or a link).
- **The shared chat gives way** (`ShareInbox.step`): it is not opened over a presented sheet (nothing typed is thrown
  away) nor when the person asked for a chat themselves within 10 s; the note is taken either way, so it never opens
  later.
- **A failed share cleans up**: a share that fails after an upload and before `prompt.submit` removes its upload
  folders from the gateway (best effort, `ShareSender.discardUploads`); a cancelled read of the shared items removes
  its staging folder (`ShareItemLoader.load`). A system-cancelled request (-999) is the person's Cancel only when
  the share's own task was cancelled (`ShareFailure.transport`).
- **Never**: the extension never signs in, never creates a chat, never answers a server request (approvals stay for
  the app), never follows a redirect, never retries a prompt whose answer went missing ("not confirmed"), and sends
  nothing to a Tailscale-only gateway while Tailscale is off.
- **Tests**: `scripts/test-share.sh <udid>` (Tests/Share: units, seeded stress, and fixture tests that run while
  `scripts/fixtures/share-gateway.py --port 9911 --redirect-port 9913 …` is up), `scripts/e2e-share.sh <udid>`
  (UITests/share against the same fixture on :9910 and :9914; `HQN_SHARE_NOUS=1` adds the reference Nous fixture;
  `HQN_SHARE_DARK=1` runs the whole pass in dark, because a share sheet that is already up does not follow an
  appearance change inside a test; screenshots are named `-light` / `-dark` by what was measured).

## Siri, Shortcuts and quick actions (m9/intents)

- **Same identifiers as build 240** (spec `docs/spec/3x-intents.md`): a shortcut the owner saved names
  `RecordVoiceNoteIntent` / `DispatchMemoIntent` / `DispatchOpenBotIntent`, the parameter `bot`, the entities
  `VoiceNoteBot` / `DispatchBotEntity` and their queries. `scripts/fixture-support/compare-intents-metadata.py <App>.app`
  diffs the built `Metadata.appintents/extract.actionsdata` against the build-240 archive and fails on anything but the
  module name and the one added phrase ("Record a voice note for ${bot} in …"), or on the word "Dispatch" in anything
  the owner can read. The six UserDefaults keys (`dispatch.voice.bots|request|pending`,
  `dispatch.shortcut.catalog|account|epoch`) keep build 240's names and JSON.
- `HermesKit/Intents/` (no UIKit, all `nonisolated`, unit-tested): `VoiceBotCatalog` (the pickers' bots; ids are
  `base64(account + "\n" + key)`, matched even when the address is written another way), `VoiceNoteRequestStore` (one
  request, 60 s, acknowledged by id), `ShortcutPolicy` (sign-in epoch, the quick-action catalog and what it permits),
  `ShortcutCatalogBuilder` (bots and listed chats by activity or visit, 128 at most), `LegacyNoteFile` (a recording an
  older build saved, resolved into this install's `HermesAttachments` only), `IntentsText` (every sentence, with the
  app's own name), `LaunchClock`.
- `App/Intents/`: `VoiceNoteIntents` and `LegacyIntents` are plain structs whose `perform()` only writes the request
  (or the quick-action route) and lets the app come forward; the entity queries read UserDefaults off the main actor.
  `IntentsRuntime` is the one place that acts on a request: one delivery at a time (`busy` / `again`), a ≤ 10 s wait for
  sign-in and the roster on a cold launch, the bot's own chat on top, the chat's own recorder started locked, every
  path acknowledging the request so nothing records later. It talks to the app through `IntentsHost` / `IntentsChat`
  (`LiveIntentsHost` in the app, fakes in the tests). Nothing is pushed or recorded once the app has left the screen
  (`IntentsAway`), and a sign-out mid-delivery ends it silently (`signIns`).
- **The saved older-build note**: with a request for the same account waiting, the "Saved voice note" alert (Open chat
  / Discard and record / Cancel); otherwise the note quietly becomes its bot chat's memo draft. It is never sent.
- **Quick actions** (`QuickActions`): "New memo to <bot>", two "Open …", "Search Chats"; rebuilt 0.5 s after the lists
  or the last visit change; each item carries the sign-in epoch and is refused after a sign-out or under another
  account. An "Open …" whose chat the gateway no longer has is closed again and said (`IntentsSessionOpen.gone`).
  "Search Chats" opens the Sessions search and gives it the keyboard only once the scene is active
  (`LiveIntentsHost.focusSearch`): asked earlier, the field opens with no keyboard.
- **Parameter refreshes are rationed by iOS** (`linkd` logs "Donation quota exceeded" and drops the call), so
  `IntentsCatalogSync` writes the pickers' bots, and calls `HQAppShortcuts.updateAppShortcutParameters()`, only when
  a bot was added, removed or renamed: never for the roster's order, which follows activity.
- **Donation**: `PushFaces.donation` builds the `INSendMessageIntent` (no message text) that `NotificationHub.post`
  donates with a local alert; `scene(_:continue:)` and a cold launch route a donated conversation through
  `AppModel.continueConversation`. Sign-out deletes all donations.
- Shared-file edits are one-liners tagged `// [intents]` (`AppDelegate`, `AppModel`, `DebugHooks`, `NotificationHub`,
  `PushFaces`). Nothing logs bot names, note paths or message text: `AppLog.note("intents", …)`
  breadcrumbs carry counts only.
- DEBUG hooks (`App/Intents/IntentsDebugHooks.swift`, compiled out of Release): `-HQDebugIntent`, `-HQDebugQuickAction`,
  `-HQDebugVoiceNote`, `-HQDebugContinueChat`, `-HQDebugResetIntents`, `-HQDebugIntentsOut <folder>` (writes
  `intents-state.json`), and `<scheme>://debug-intent/<word>` on a running app. They run the real intent types and the
  real quick-action path.
- Tests: `Tests/Intents/` (14 suites); `scripts/e2e-intents.sh <udid> [runs]` runs `UITests/intents/` against
  `scripts/fixtures/intents-gateway.py` (two bots and the memo pipeline) and `scripts/fixtures/intents-pages-gateway.py`
  (five bots and listed chats; a deleted chat answers 4007), ports 9920–9929. It drives the real Shortcuts app (the
  App Shortcut tile is run by the system) and the real Home Screen menu, then repeats those in the simulator's dark
  appearance.
