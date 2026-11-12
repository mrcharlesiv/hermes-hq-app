# 3x — Presence: a bot's browser and screen use, outside the viewer

Stream `presence` of run m9. Branch `m9/presence`, worktree `/Users/me/Projects/hermes-hq-native-wt/m9-presence`.
Written 2026-10-11 by the spec writer; the owner was asleep, so every open choice is settled here and marked
**DECISION**.

Path prefixes used below:

- `R:` the web app at build 240, read only: `/Users/me/Projects/hermes-hq-native-ref240/`
- `V:` its vendored desktop source: `R:vendor/hermes/apps/desktop/src/`
- `N:` this worktree
- `H:` Hermes contracts, read only: `/Users/me/.hermes/hermes-agent/tui_gateway/contracts/`
- `MEM:` owner memory notes: `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/`

Rows (8; verbatim in `N:docs/briefs/m9/presence-rows.md`):

| Row | What | Section |
|---|---|---|
| §3 L211 | "Using its computer" row status, 90 s quiet window | §4 |
| §3 L216 | Bot Info Computer group (Watch Browser and the alert switch are ours; Screen row is a hook) | §6 |
| §10 L477 | Chat ⋯ › Watch Browser disabled "Offline" when offline | §9 |
| §10 L480 | Setup screen: "Ask Hermes to Install It" queues the request | §10 |
| §10 L485 | Viewer socket: dial at once when the network is back | §11 |
| §10 L504 | Bots row line from browser use | §5 |
| §10 L506 | "<bot> is using its browser/screen" notices with Watch | §8 |
| §10 L507 | Per-bot notice toggle, default on | §7 |

No row needs a relay, plugin or real-gateway change, so there is no `docs/owner-todo/presence.md`. Everything is
app-side: two gateway events the app already receives (`tool.start`, `message.complete`), one RPC the app already
sends (`profiles.configure`), and the browser plugin's list socket the app already opens (`/activity`).

---

## 0. TL;DR and build order

One new small centre, `PresenceCenter`, hears the account's gateway events and the browser plugin's list, and feeds
two things: a per-bot `BotPresence` on the Bots rows (L211, L504) and a glass notice with Watch (L506). The per-bot
flag behind the notice is one stored boolean, shown as one switch in Bot Info's new Computer group (L216, L507). Three
small repairs finish Watch Browser itself (L477, L480, L485).

Build in this order; each step compiles and is testable by itself:

1. Pure rules and their unit tests: `N:HermesKit/Presence/PresenceRules.swift` (§3.2).
2. `GatewayEvent.replayed` (§3.4) and its test.
3. `Bot.presence`, the roster builder, `BotStore.setPresence`, `BotList.secondLine` and the avatar badge (§4, §5).
4. `PresenceCenter` wired into `AppModel` (§3.3): rows now react to events and to the plugin's list.
5. The fixture `N:scripts/fixtures/presence-gateway.py` and `N:scripts/e2e-presence.sh` (§12).
6. Bot Info Computer group, the switch and the screen hook file (§6, §7).
7. The notice (§8).
8. L477, L480, L485 (§9–§11).
9. UI tests (§13), then both identities build: `scripts/build.sh build <UDID>` and
   `HQ_IDENTITY=original scripts/build.sh build <UDID>`.

Product rules that bind every step: native Liquid Glass only (`UIGlassEffect`, never blur plus tint); wrapping rows
get 12–14 pt of vertical padding; no control that does nothing; the word "Dispatch" never reaches the screen or
VoiceOver (storage keys and wire names such as `dispatch-browser.list.v3` are fine); Swift 6, MainActor by default;
`project.yml` and `project-original.yml` both keep building (new folders under `App/` and `HermesKit/` are picked up
by XcodeGen without editing either file).

---

## 1. What the owner approved (binding)

Quoted from the memory notes; these decide the behaviour where the web and a tidy design disagree.

- `MEM:bot-owns-signin.md`, owner 2026-10-08: "bots should own the task until they can't and just show a
  notification that they are using their browser." A bot's browser use produces a notice and a way to watch; it never
  opens a page by itself and never stops the bot.
- Same note, build 221, owner: "make the browser notice on by default and ship it". Hence
  `screenNoticeOn(meta) = meta?.screenAutoOpen !== false` (`R:src/bot-screen-phone.tsx:32`): on unless the stored flag
  is exactly `false`. The Mac's "open the screen automatically" reads the same flag raw and stays opt-in; the phone
  must not change what an absent flag means for the Mac (so the phone never writes the flag except when the switch is
  flipped).
- `MEM:browser-takeover-rebuild.md`, build 170: "one browser notice: no banner in that bot's own chat". The chat's
  browser card already says it there.
- Same note, build 171: a browser row counts as in use only while `active` (busy, or the bot touched it in the last
  90 s): "idle bot Chrome no longer 'using its browser'"; "Phone: idle rows no status/card".
- `MEM:chat-dock-browser-card.md`: the row's `active` holds 90 s so the card (and now the Bots row line) does not
  flicker between a bot's steps.
- `MEM:reply-peek.md`, owner: in-app banners must be "actual liquid glass native to apple, not something we make";
  never tint native glass heavily; the banner sits at Apple's banner spot (`safeAreaInsets.top + 2`), 64 pt tall with
  a 40 pt face.
- `MEM:ui-hunt-oct6.md`: notices must not cover the chat's "Thinking…" status line. The banner spot is above it.
- `MEM:hermes-hq-native.md`: one feature per build; "Dispatch" never user-facing.

---

## 2. Wire reference

Nothing here is new to Hermes. Hermes rejects unknown params with error 4000, so send exactly the fields shown.

### 2.1 Events consumed (JSON-RPC notifications on `/api/ws`)

`tool.start` (`H:events.py:266-280`, `ToolStartPayload`: `tool_id`, `name`, optional `context`, `args`, `args_text`,
`preview`, `labels`). Only `name` is read here.

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"tool.start","session_id":"3fa9c1d2","seq":118,
 "payload":{"tool_id":"call_7","name":"browser_navigate","args":{"url":"https://example.com"}}}}
```

`message.complete` (the reply finished; only the session id is read here):

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"3fa9c1d2","seq":131,
 "payload":{"text":"Done.","row_id":912}}}
```

`session_id` is the runtime id (8 hex). The event's own `profile`, if any, is never trusted (§3.1).

The phone hears these only for sessions its socket is attached to, which means chats opened during this app run
(Hermes streams a session's events to the socket that resumed it). The web app has the same limit. Bots the phone has
not opened this run still get the browser line (§5), which comes from the plugin's list and covers every bot.

### 2.2 The per-bot flag (JSON-RPC, existing `BotStore.writeBotMeta`, `N:HermesKit/Store/BotStore+Editing.swift:226-300`)

The flag is `screenAutoOpen` (boolean) inside `ui_meta["hermes-bots"]` (`V:plugins/hermes-bots/types.ts:84`). Hermes
replaces a `ui_meta` key whole, so the write is read–merge–write, exactly as Pin and Hide already do:

```json
→ {"jsonrpc":"2.0","id":41,"method":"profiles.list","params":{"include_sessions":false}}
← {"jsonrpc":"2.0","id":41,"result":{"profiles":[{"name":"ivy",
     "ui_meta":{"hermes-bots":{"display_name":"Ivy","pinned":true}},"ui_meta_revisions":{"hermes-bots":3}}]}}
→ {"jsonrpc":"2.0","id":42,"method":"profiles.configure","params":{"name":"ivy",
     "ui_meta":{"hermes-bots":{"display_name":"Ivy","pinned":true,"screenAutoOpen":false}}}}
← {"jsonrpc":"2.0","id":42,"result":{"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":4}}}}
```

Contract: `H:profiles_vault_complete_foreign_subagents.py:268-296` (`ProfilesConfigureParams`: `name`, `ui_meta`, …;
`ProfilesConfigureApplied`: `ui_meta: bool`, `ui_meta_revisions`, `ui_meta_conflicts`). Outcomes the app already
tells apart (`BotWriteOutcome.meta`, `BotStore+Editing.swift:88-92`): `applied.ui_meta == true` saved; `applied`
present but not true → "Your gateway didn’t save the change."; no `applied` object (an older gateway) → "This gateway
can’t save bot settings yet. Update Hermes on the computer, then try again."; transport failures say their own
words; a failed write puts the old object back, here and (best effort) on the gateway.

### 2.3 The browser plugin's list (existing `BrowserActivityChannel`, `N:HermesKit/Browser/BrowserService.swift:249-408`)

`WS /api/plugins/hermes-hq-browser/activity` (legacy base `/api/plugins/dispatch-browser`), opened with a socket
ticket like `/api/ws`. Each frame is the whole list:

```json
{"schema":"dispatch-browser.list.v3","protocol":3,"browsers":[
 {"id":"0123456789abcdef01234567","profile":"ivy","session_id":"20260929_120000_aabbcc02",
  "session_ids":["20260929_120000_aabbcc02"],"opened_at":1791700000.0,"agent_at":1791700055.2,
  "url":"https://example.test/sign-in","busy":1,"active":true,"control":"bot","ask":null}]}
```

No new REST call. `GET <plugin>/health` is already made by `BrowserService.plugin()` and reused for five minutes.

### 2.4 Queueing the install request (existing chat engine)

`LiveChatSession.send(_:display:attachments:)` (`N:HermesKit/Chat/LiveChatSession.swift:664-681`): idle chat →
`prompt.submit` now; a reply running → the local queue, drained with `queued: true` when the turn ends. No new wire
call.

---

## 3. Shared native pieces

### 3.1 Which bot an event belongs to

Web: `sessionOwner` (`R:src/bot-screen-menu.tsx:43-51`) resolves a session's durable owner and never uses the
event's `profile` ("iOS carries every profile over one gateway socket, and each event on it is stamped with the
ACTIVE profile"). `botForSessionEvent` (`:63-66`) returns the roster bot, or null → the event is ignored.

Native rule, in this order, first hit wins; no hit → ignore the event:

1. `ActivityStore` binding: every chat resumed this run is bound there by runtime id with its profile
   (`N:HermesKit/Activity/LiveChatSession+Activity.swift:107-109`). Add one read-only accessor to
   `N:HermesKit/Activity/ActivityStore.swift`:
   ```swift
   /// [presence] The bot whose chat is bound as `runtimeId` this run (spec 3x-presence §3.1).
   func owner(ofRuntime runtimeId: String) -> (profile: String, storedId: String?)? {
       chats[runtimeId].map { ($0.profile, $0.storedId) }
   }
   ```
2. `AppModel.runningChats[event.sessionId]` (`N:App/AppModel.swift:49`).
3. `focusedChat` when `focusedChat.runtimeSessionId == event.sessionId`.

Then the bot must exist: `botStore.bot(named: profile) != nil`, and the profile must not be empty (a nameless launch
home has `profile == ""`).

### 3.2 Pure rules: `N:HermesKit/Presence/PresenceRules.swift` (new, `nonisolated`, no UIKit)

```swift
/// Screen tools (V:plugins/hermes-bots/screen-autoraise.ts:34,49-51): names that start with "computer_use" or "browser_".
nonisolated enum ScreenTools {
    static let prefixes = ["computer_use", "browser_"]
    static func isScreenTool(_ name: String?) -> Bool      // case-sensitive hasPrefix, nil/"" → false
    static func isBrowserTool(_ name: String?) -> Bool     // hasPrefix("browser_")
    static let quiet: Duration = .seconds(90)              // R:src/ui-bots/computer-activity.ts:13 COMPUTER_QUIET_MS
    static let noticeCooldown: Duration = .seconds(30)     // R:src/bot-screen-phone.tsx:751 NUDGE_COOLDOWN_MS
    static let noticeSeconds: TimeInterval = 8             // R:src/bot-screen-menu.tsx:108,112 durationMs
}

/// What a bot is doing outside its chat (carried on `Bot`).
nonisolated struct BotPresence: Hashable, Sendable {
    /// "Browsing example.com", "Using its browser", "Needs you in its browser", "You’re using its browser",
    /// "Handing you its browser…" (BrowserCard.statusLine); nil when its browser is not news.
    var browserLine: String?
    /// A screen tool started in the last 90 s and its reply has not finished.
    var usingComputer = false
    var isEmpty: Bool { browserLine == nil && !usingComputer }
}

/// Port of R:src/ui-bots/computer-activity.ts: profile → when it last started a screen tool.
nonisolated struct ComputerActivity: Sendable {
    private(set) var lastAt: [String: ContinuousClock.Instant] = [:]
    mutating func toolStarted(_ profile: String, at now: ContinuousClock.Instant)
    /// message.complete: true when the profile was active (the caller republishes).
    @discardableResult mutating func replyFinished(_ profile: String) -> Bool
    /// Profiles with now - lastAt < 90 s. Also drops the expired ones.
    mutating func active(at now: ContinuousClock.Instant) -> Set<String>
    /// The earliest moment a profile's window ends, or nil when none is active.
    func nextExpiry() -> ContinuousClock.Instant?
}

/// Port of the checks in R:src/bot-screen-menu.tsx:86-112 and shouldNudge (R:src/bot-screen-phone.tsx:753-757).
nonisolated struct NoticeGate: Sendable {
    struct Input: Sendable {
        var replayed: Bool
        var toolName: String?
        var profile: String?            // nil: no bot owns the session
        var noticeOn: Bool              // the bot's switch (§7)
        var visibleChatProfile: String? // the bot of the chat on screen, nil when no chat is on screen
        var screenViewerOpen: Bool      // a Bot Screen viewer is showing (any bot)
        var watchingThisBrowser: Bool   // a Watch Browser viewer for this bot is showing
        var canWatchScreen: Bool        // the screen stream's viewer exists (BotComputerHooks.openScreen != nil)
    }
    enum Outcome: Equatable, Sendable { case none(String), browser, screen }   // none carries the reason for the log
    private(set) var last: [String: ContinuousClock.Instant] = [:]
    mutating func decide(_ input: Input, now: ContinuousClock.Instant) -> Outcome
    mutating func reset()
}
```

`NoticeGate.decide`, in the web's order (the reason strings are log words, never shown):

| # | Check | Outcome |
|---|---|---|
| 1 | `replayed`, or not a screen tool | `.none("replayed")` / `.none("not a screen tool")` |
| 2 | `profile == nil` | `.none("no owner")` |
| 3 | `!noticeOn` | `.none("off for this bot")` |
| 4 | browser tool and `visibleChatProfile == profile` | `.none("its chat is on screen")` |
| 5 | not a browser tool and `!canWatchScreen` | `.none("no screen viewer")` (native only, see DECISION D6; nothing stamped) |
| 6 | `screenViewerOpen` | `.none("screen viewer open")`, nothing stamped |
| 7 | `now - last[profile] < 30 s` | `.none("cooldown")` |
| 8 | stamp `last[profile] = now` | |
| 9 | browser tool and `watchingThisBrowser` | `.none("already watching")` (the stamp from step 8 stays, as on the web: `shouldNudge` runs before `browserWatchOpen`, `bot-screen-menu.tsx:97,107`) |
| 10 | browser tool | `.browser` |
| 11 | otherwise | `.screen` |

### 3.3 `PresenceCenter`: `N:App/Presence/PresenceCenter.swift` (new, `@MainActor final class`)

One per signed-in account, owned by `AppModel` (`private(set) var presence: PresenceCenter?`), made in `activate`
right after `registerBrowserMenu()` (`N:App/AppModel.swift:233`), shut down in `tearDown` just before
`browser?.shutdown()` (`:330`).

```swift
@MainActor final class PresenceCenter {
    struct Context {
        var owner: (String) -> String?            // §3.1: runtime id → profile
        var bots: () -> [Bot]
        var noticeOn: (String) -> Bool            // BotStore.screenNoticeOn
        var visibleChatProfile: () -> String?     // AppModel.focusedChat?.profile
        var face: (String) -> UIImage?            // AppModel.peekFace (make it internal; it is private today)
        var window: () -> UIWindow?               // MainTabController.current?.view.window
        var openBrowser: (BrowserScope) -> Void   // §8.4
        var publish: ([String: BotPresence]) -> Void   // BotStore.setPresence
    }
    init(browser: BrowserService?, context: Context)
    func handle(_ event: GatewayEvent)            // tool.start, message.complete
    func setBotsListShown(_ shown: Bool)          // subscribes to browser.activity while shown
    func shutdown()                               // timers, subscription, notice, maps
}
```

Wiring in `AppModel`:

- `gatewayEvent(_:)` (`N:App/AppModel.swift:454`): first line `presence?.handle(event)`, before any `guard`.
- `BotsViewController` gains `viewDidAppear` / `viewDidDisappear` overrides that call
  `PresenceHooks.botsListShown?(true/false)`; `AppModel` sets `PresenceHooks.botsListShown = { [weak self] in
  self?.presence?.setBotsListShown($0) }` once at launch (in `N:App/Integration/M2Wiring.swift`, or beside
  `registerBrowserMenu`). `PresenceHooks` is a two-line `@MainActor enum` in `PresenceCenter.swift`.
- `connectionChanged(_:)` (`:432`): §11.

`PresenceCenter` keeps: `computer: ComputerActivity`, `gate: NoticeGate`, `browserLines: [String: String]`,
`subscription: BrowserSubscription?`, `expiry: Task<Void, Never>?`, `coalesce: Task<Void, Never>?`.

Publishing: build `[profile: BotPresence]` from `browserLines` and `computer.active(at: .now)`, drop empty entries,
and call `context.publish`. Publishes are coalesced: at most one per 250 ms (a trailing publish always goes out), so
a noisy list cannot rebuild the roster faster than four times a second. `BotStore.setPresence` returns at once when
the map is unchanged.

### 3.4 `GatewayEvent.replayed` (contract change, one field)

Web: frames delivered by a reconnect's catch-up carry `replayed: true` (`R:build/shared-replay-performance.ts:53-97`,
both the `session.events.since` answer and the frames held while it ran), and the notice skips them
(`R:src/bot-screen-menu.tsx:87-88`: "A replayed start (a reconnect's catch-up) is old news").

Native has no such mark. Add it:

- `N:HermesKit/Contracts.swift:95-100`: `var replayed = false` at the end of `GatewayEvent` (the memberwise
  initialiser keeps working for every existing call).
- `N:HermesKit/Net/GatewayConnection.swift`, `replayOne` (`:661-664`): set `event.replayed = true` before
  `book.accept(event)`; and where held frames are released (`book.release(session)` at `:647`, `book.releaseAll()` at
  `:640`) map them to `replayed = true` before yielding. Nothing else reads the field, so no other behaviour changes.

Test: extend `N:Tests/NetReplayTests.swift` (a replayed `tool.start` arrives with `replayed == true`, a live one with
`false`).

### 3.5 Files

New: `HermesKit/Presence/PresenceRules.swift`; `App/Presence/PresenceCenter.swift`; `App/Presence/PresenceNotice.swift`
(§8); `App/Presence/ComputerInfoSection.swift` (§6); `App/Presence/MainBotRequest.swift` (§10);
`App/BotInfo/BotComputerHooks.swift` (§6.3); `scripts/fixtures/presence-gateway.py`; `scripts/e2e-presence.sh`;
`Tests/Presence/PresenceRulesTests.swift`, `Tests/Presence/PresenceStoreTests.swift`;
`UITests/presence/PresenceEndToEndTests.swift`.

Changed (small, listed so merges are easy to check): `HermesKit/Contracts.swift` (`Bot.presence`,
`GatewayEvent.replayed`); `HermesKit/Model/RosterLayout.swift` (`Input.presence`, the row builder);
`HermesKit/Store/BotStore.swift` (`setPresence`); `HermesKit/Store/BotStore+Editing.swift` (`screenNoticeOn`,
`setScreenNotice`); `HermesKit/Activity/ActivityStore.swift` (`owner(ofRuntime:)`);
`HermesKit/Net/GatewayConnection.swift` (§3.4); `HermesKit/Browser/BrowserService.swift`,
`BrowserWatchSession.swift`, `BrowserWire.swift` (§11); `App/Bots/BotListModel.swift`, `BotRowViews.swift`,
`BotsViewController.swift`; `App/Browser/AppModel+Browser.swift`, `BrowserViewerController.swift`,
`BrowserChoiceController.swift` (the old `BrowserInfoSection` is removed); `App/AppModel.swift`;
`App/Notifications/AppModel+Notifications.swift` (`peekFace` internal), `NotificationHub.swift` (one line, §8.3).

Do not edit `docs/parity-240.md` or `docs/parity.md`.

---

## 4. Row L211 — "Using its computer" after a screen tool call

### 4.1 Web

`R:src/ui-bots/computer-activity.ts` (whole file, 40 lines): on `tool.start` whose `payload.name` is a screen tool,
the owning bot's roster key gets `Date.now()` (`:30-34`); `usingComputer` is `now - last < 90_000` (`:16`); a timer
at 90 s + 50 ms makes rows read again so the status falls back without another event (`:35-37`);
`message.complete` for that bot clears it (`:39`). It does not skip replayed starts.

Ranking, `R:src/ui-kit/bot-status.ts:41-55` (first match wins): link → waking → unreachable → approval → reply →
**computer** (`{ key: 'computer', text: 'Using its computer', tone: 'tint', glyph: 'display' }`, `:50`) → working →
idle. The avatar badge for `computer` is a tint circle with a white display glyph
(`R:src/ui-kit/bot-avatar.tsx:14-29`, `bot-avatar.css:15`), the same size as the working badge
(`clamp(14, 0.36 × head, 22)`).

### 4.2 Native design

`PresenceCenter.handle(_:)`:

- `tool.start` with `ScreenTools.isScreenTool(event.payload["name"]?.string)` and an owner (§3.1):
  `computer.toolStarted(profile, at: .now)`, publish, and re-arm `expiry`: one task that sleeps until
  `computer.nextExpiry()` + 50 ms, publishes, and re-arms while any profile is still active. Replayed starts count
  too, as on the web.
- `message.complete` with an owner: `if computer.replyFinished(profile) { publish }`.
- Nothing else ends it: an errored or stopped turn falls back when its 90 s pass (web parity).

Model (precedent: `needsInput`, added the same way by the questions stream):

- `N:HermesKit/Contracts.swift`, `struct Bot` (`:164-183`): `var presence: BotPresence? = nil` (nil when empty, so an
  idle roster hashes as before).
- `N:HermesKit/Model/RosterLayout.swift`: `Input.presence: [String: BotPresence] = [:]` beside `needsInput` (`:73`),
  and the row builder (`:156`) passes `presence: input.presence[profile.name]`.
- `N:HermesKit/Store/BotStore.swift`: `@ObservationIgnored private var presence: [String: BotPresence] = [:]` beside
  `needsInput` (`:143`); `input.presence = presence` beside `:775`; and
  ```swift
  /// [presence] What each bot is doing outside its chat (spec 3x-presence §3.3). Replaces the whole map.
  func setPresence(_ next: [String: BotPresence]) {
      guard presence != next else { return }
      presence = next
      rebuild()
  }
  ```

Row words: `N:App/Bots/BotListModel.swift`, replace `secondLine` (`:86-94`) with one status function and keep
`secondLine` as its words (so `accessibilityLabel`, which already reads `secondLine`, follows):

```swift
enum RowStatus: Sendable { case needsInput, browser, computer, working, idle }

static func rowStatus(_ bot: Bot) -> RowStatus {
    if bot.needsInput != nil { return .needsInput }                                        // approval, reply
    if bot.presence?.browserLine != nil, bot.previewPrefix != "Draft:" { return .browser } // §5
    if bot.presence?.usingComputer == true { return .computer }
    return bot.isWorking ? .working : .idle
}

static func secondLine(_ bot: Bot) -> (text: String, tone: Tone) {
    switch rowStatus(bot) {
    case .needsInput: return (bot.needsInput!.statusText, .attention)
    case .browser: return (bot.presence!.browserLine!, .tint)
    case .computer: return ("Using its computer", .tint)
    case .working: return ("Working…", .tint)
    case .idle: /* preview, role, "No messages yet": unchanged */
    }
}

enum RowBadge: Sendable { case working, computer }
/// The avatar badge (R:src/ui-kit/bot-avatar.tsx:14-20): the display for "Using its computer", the dots for a
/// running turn or browser use.
static func rowBadge(_ bot: Bot) -> RowBadge? {
    switch rowStatus(bot) {
    case .computer: return .computer
    case .browser, .working: return .working
    case .needsInput, .idle: return bot.isWorking ? .working : nil      // unchanged from today
    }
}
```

`N:App/Bots/BotRowViews.swift`, `BotAvatar` (`:10-14`): the overlay becomes
`switch BotList.rowBadge(bot) { case .working: WorkingBadge(...) case .computer: ComputerBadge(...) case nil: EmptyView() }`.
New `ComputerBadge(height:)`: a `Color.hqTint` circle of `BotAvatar.badgeSize(size)` with
`Image(systemName: "display")` in white, `font(.system(size: height * 0.5, weight: .bold))`, the same 2 pt
page-colour ring as `WorkingBadge`, `accessibilityHidden(true)`. Pinned tiles use `BotAvatar` too, so they get the
badge. The head's own `working:` animation stays tied to `bot.isWorking`.

Other streams: `botslist` adds "Waking up…" (L184) above `needsInput` in the same function; the two edits touch
different lines of `rowStatus`. The Bot Info header status (L213, `botslist`) can read `bot.presence?.usingComputer`
(the web shows the same words there, `R:src/ui-bots/info-sheet.tsx:226`); this stream does not add a status line to
Bot Info.

### 4.3 UI states and words

| State | Second line | Tone | Badge |
|---|---|---|---|
| A screen tool started under 90 s ago, reply still running, nothing ranked above | `Using its computer` | tint | display |
| Same, and the row waits for you | `Waiting for your approval` / `Waiting for your reply` | attention | as today |
| Same, and its browser is in use (§5) | the browser line | tint | dots |
| 90 s passed with no new screen tool, or the reply finished | `Working…` if still running, else the preview | | dots / none |
| The session is one the phone never opened this run | no change (no event reaches the phone) | | |

VoiceOver reads the row as "<name>. Using its computer. <time>…" (unchanged label rule, `BotListModel.swift:97-105`).

### 4.4 Fixture and acceptance

Fixture: §12, presence gateway on 9930. Drive it with

```
curl -s -X POST http://127.0.0.1:9930/__fixture/event -H 'Content-Type: application/json' \
  -d '{"profile":"ivy","type":"tool.start","payload":{"tool_id":"t1","name":"computer_use_click"}}'
curl -s -X POST http://127.0.0.1:9930/__fixture/finish -H 'Content-Type: application/json' -d '{"profile":"ivy"}'
```

Acceptance:

- A1. Open Ivy's chat once, go back to Bots. After the first `curl`, Ivy's row says "Using its computer" in the tint
  colour with the display badge within 1 s; Hermes's row does not change.
- A2. After `/__fixture/finish` the line goes back to the preview within 1 s.
- A3. Without a finish, the line goes back by itself 90 s (+ at most 1 s) after the last screen tool; a second screen
  tool at 60 s moves the end to 150 s.
- A4. `{"name":"terminal"}` changes nothing. `{"name":"browser_navigate"}` also sets the computer state (it is a
  screen tool) but with no plugin row the line reads "Using its computer"; with a plugin row §5 wins.
- A5. A `tool.start` for a runtime id nobody bound is ignored (no crash, no row change).
- A6. Sign out and into another account: no line survives.

---

## 5. Row L504 — Bots row line from browser use

### 5.1 Web

`useBotBrowserStatus` (`R:src/browser-watch/activity.tsx:60-65`): the row's line is
`statusLine(rowFor(rows, {owner: profile}))`, read from the plugin's list only while the roster is visible.
`statusLine` (`R:src/browser-watch/model.ts:232-239`): null unless the row is in use; "Needs you in its browser"
when it asks and the bot holds it; "You’re using its browser" when the person holds it; "Handing you its browser…"
while waiting; else "Browsing <host>" or "Using its browser" (no host, or "New Tab").

Precedence, `R:src/ui-bots/bot-row.tsx:213-217`: the browser line replaces the status text with key `working` and
tone `tint` unless the row is asking, has a pending draft or unconfirmed send, is opening, is unavailable, or the
status key is `link`, `approval` or `reply`. So it beats "Using its computer", "Working…" and the preview; the badge
becomes the working dots.

Channel rules: `R:src/browser-watch/activity-channel.ts` (3 s linger after the last listener, rows kept 3 min,
back-off `min(10 s, 1 s × 2^n)`), `activity-runtime.ts` (foreground and visible only; health reused 5 min).

### 5.2 Native design

The words already exist and are unused: `BrowserCard.statusLine(_:)` (`N:HermesKit/Browser/BrowserWire.swift:153`).
The channel already exists with the web's rules (`BrowserActivityChannel`).

`PresenceCenter.setBotsListShown(true)`: `subscription = browser.activity.subscribe { [weak self] in self?.listChanged() }`
then `listChanged()` at once. `false`: cancel the subscription (the channel lingers 3 s, so going from the list into
a chat, whose browser card subscribes, keeps one socket). `browserLines` is kept while hidden and recomputed from
`browser.activity.rows` the moment the list shows again.

`listChanged()`: for every bot in `context.bots()` (hidden ones too),
`BrowserCard.statusLine(BrowserScope(profile: bot.id, title: bot.name).row(in: browser.activity.rows))`; store the
non-nil ones in `browserLines`; publish (coalesced, §3.3).

Row precedence is `rowStatus` in §4.2. Native has no separate "opening" or "unavailable" row state yet (L184 is
`botslist`'s); when that stream adds "Waking up…" above, the browser line stays below it, as on the web.

While the socket is reconnecting the last list stays (the web keeps it too), so a line can be up to 3 minutes stale
on a dead link; rows older than that are dropped by the channel when it begins again.

No plugin on the gateway: the channel stays quiet (`BrowserService.swift:349`), no line ever shows, nothing is
offered. That is the graceful state; the setup screen (§10) is where the plugin is explained.

### 5.3 UI states and words (exact)

| Plugin row for the bot | Second line (tint, dots badge) |
|---|---|
| in use, bot holds it, page host known | `Browsing example.com` |
| in use, no host or a new tab | `Using its browser` |
| asks for the person, bot holds it | `Needs you in its browser` |
| the person holds it | `You’re using its browser` |
| handing over | `Handing you its browser…` |
| not in use (idle Chrome), or no row | nothing: the row's normal line |
| the row waits for approval or a reply | `Waiting for your approval` / `Waiting for your reply` wins |
| the row shows a draft (`Draft:` prefix) | the draft (or `Working…`) wins |

**DECISION D1:** all five lines are tint, including "Needs you in its browser", as the web sets `tone = 'tint'` for
every browser line (`bot-row.tsx:216`). The chat's card keeps its orange for the ask.

### 5.4 Fixture and acceptance

```
curl -s -X POST http://127.0.0.1:9930/__fixture/presence -H 'Content-Type: application/json' \
  -d '{"browsers":[{"profile":"ivy","active":true,"url":"https://example.test/sign-in"}]}'
```

- B1. On the Bots list, Ivy's row reads "Browsing example.test" within 1.5 s of the call (tint, dots badge); the
  default bot's row is unchanged.
- B2. `{"browsers":[{"profile":"ivy","active":true,"url":"https://example.test/","ask":"Sign in to Example"}]}` →
  "Needs you in its browser".
- B3. `{"browsers":[{"profile":"ivy","active":false,"url":"https://example.test/"}]}` → back to the normal line.
- B4. `{"browsers":[{"profile":"ivy","active":true,"url":"about:blank"}]}` → "Using its browser".
- B5. Open a chat (list hidden): `GET /__fixture/presence` shows the activity socket still open (the chat's card
  holds it); switch to Sessions: still 1 (it hears asks, D40); switch to the Jobs tab for 5 s: `activity_sockets` is 0.
  Back on Bots: 1 again and the line is right.
- B6. `{"plugin":"missing"}` on `/__fixture/browser` before launch: no line, no error, no socket retry loop
  (`activity_sockets` stays 0, `/health` asked once per subscribe).
- B7. VoiceOver reads "Ivy. Browsing example.test. …".

---

## 6. Row L216 — Bot Info Computer group

### 6.1 Web

`R:src/ui-bots/info-state.ts:98-102`:

```ts
groups.push({ id: 'computer', header: 'Computer', rows: [
  { id: 'screen', title: screenTitle(input.screen), ...(input.screenLive ? { value: 'Live' } : {}), accessory: 'chevron' },
  write({ id: 'browser', title: 'Watch Browser', subtitle: 'See its browser live, or take it over', accessory: 'chevron' }),
  write({ id: 'screen-alert', title: 'Alert When It Uses Its Computer', accessory: 'switch', on: input.screenAlert }),
] })
```

`write(...)` rows are disabled while offline; the Screen row is not. Group order: about, model, **computer**,
conversations, rooms, notifications, organize, danger. Offline footer (once, under Organize):
`'You can change this bot again once its gateway is back.'` (`:32`). Actions,
`R:src/ui-bots/info-actions.ts:140-147`: `browser` closes Info and opens Watch Browser; `screen-alert` is §7.

### 6.2 Native design

`N:App/Presence/ComputerInfoSection.swift` replaces `BrowserInfoSection`
(`N:App/Browser/BrowserChoiceController.swift:294-331`, delete it there) and is registered where that one is today
(`N:App/Browser/AppModel+Browser.swift:54-59`). Bot Info already draws hook sections between Model and
Conversations (`N:App/BotInfo/BotInfoSheet.swift:360-362`), which is the web's place for Computer.

```swift
struct ComputerInfoSection: View {
    let bot: Bot
    let service: BrowserService
    weak var host: UIViewController?
    let online: () -> Bool                     // AppModel.connection == .ready
    let alertOn: () -> Bool                    // BotStore.screenNoticeOn(bot.id)
    let setAlert: (Bool) async throws -> Void  // BotStore.setScreenNotice(name:_:)
    let open: (BrowserScope, UIViewController) -> Void
}
```

Rows, in order, in `Section("Computer")`:

1. **Screen row (hook).** `if let host, let row = BotComputerHooks.screenRow?(bot, host) { row }`. Nothing is drawn
   while the hook is nil. The screen stream supplies the whole row (its title "Watch Screen" / "View Screen" /
   "Latest Screenshots", the "Live" value, its tap and its own offline rule).
2. **Watch Browser.** Title `Watch Browser`, subtitle `See its browser live, or take it over`, a chevron; laid out
   like the Bot Chat row (`BotInfoSheet.swift:507-517`: title over a `.subheadline` secondary subtitle,
   `.padding(.vertical, 4)` inside the list row, which gives the 12–14 pt the product rule asks for). [botinfo-chats]
   Bot Chat itself has since lost its chevron and draws its title in the tint, since it leaves the sheet (owner
   2026-11-03); Watch Browser keeps its chevron and label colour, since it opens over Bot Info (D2). Tap:
   `open(BrowserScope(profile: bot.id, title: bot.name), host)`. `.disabled(!isOnline)`. Identifier
   `bot-info.browser.watch` (kept, tests use it).
3. **Profile and Window** (native only, shipped in builds 249–250, parity row L521 ✅): unchanged, shown when the
   plugin offers the choice. Identifier `bot-info.browser.choice`. Stays enabled offline as today.
4. **Alert When It Uses Its Computer.** A `Toggle`; §7. Identifier `bot-info.computer.alert`.
   `.disabled(!isOnline)`.

Offline: rows 2 and 4 dim with the rest of Bot Info's writes; Bot Info's existing footer under Organize ("You can
change this bot again once its gateway is back.") covers it, as on the web. `isOnline` is `@State`, refreshed by a
`.task` loop once a second (the cadence Bot Info's own timer uses, `BotInfoSheet.swift:292`); the same tick re-reads
`alertOn()` when no write is in flight, so a change made on another device shows.

**DECISION D2:** Watch Browser opens over Bot Info and closing it returns to Bot Info, as native has done since
build 5; the web closes Info first. The row is about the group, and the native stack is the one the owner has been
using.

**DECISION D3:** the group header is "Computer" and the old "Browser" header goes away (web wording).

### 6.3 The hook file for the screen stream: `N:App/BotInfo/BotComputerHooks.swift`

Exact text. If the screen stream's branch adds the same file, a byte-identical copy merges without conflict.

```swift
// Seams between Bot Info's Computer group, the "is using its screen" notice (presence stream) and the Bot Screen
// viewer (screen stream). Each side sets or reads these; neither imports the other. All nil until a stream sets them.

import SwiftUI
import UIKit

@MainActor enum BotComputerHooks {
    /// Bot Info › Computer, first row: the Screen row ("Watch Screen" / "View Screen" / "Latest Screenshots", value
    /// "Live"), drawn and handled by the screen stream. nil, or a nil answer: no row.
    static var screenRow: ((Bot, UIViewController) -> AnyView?)?
    /// Opens the Bot Screen viewer for a bot (the notice's Watch). nil: no "is using its screen" notice is shown.
    static var openScreen: ((Bot, UIViewController) -> Void)?
    /// A Bot Screen viewer is on screen (any bot): no notices meanwhile.
    static var screenIsOpen: (() -> Bool)?
}
```

### 6.4 Acceptance

- C1. Bot Info shows a "Computer" group between Model and Conversations with Watch Browser (with its subtitle) and
  the switch; no "Browser" group remains. With `choice_feature` on, Profile and Window sits between them.
- C2. Watch Browser opens the viewer for that bot; closing returns to Bot Info.
- C3. With the gateway down (`/__fixture/presence {"gateway":"down"}`), within 2 s Watch Browser and the switch are
  dimmed and do nothing; the footer under Organize says "You can change this bot again once its gateway is back.";
  back up, they work again without reopening the sheet.
- C4. Setting `BotComputerHooks.screenRow` in a DEBUG test hook (`-HQDebugScreenRow YES` adds a plain "Watch Screen"
  row) puts that row first in the group; without it the group has no empty gap.
- C5. `test3_BotInfoBrowserChoice` in `BrowserEndToEndTests` still passes (identifiers kept).

---

## 7. Row L507 — the per-bot notice switch, default on

### 7.1 Web

One stored flag: `ui_meta['hermes-bots'].screenAutoOpen`. The phone reads it as
`screenNoticeOn = meta => meta?.screenAutoOpen !== false` (`R:src/bot-screen-phone.tsx:32`). Two labels exist for
it: the legacy row-menu item "Notify me when it uses its screen" (`R:src/bot-screen-menu.tsx:70`, with toasts at
`:73-74`), and Bot Info's switch "Alert When It Uses Its Computer" (`R:src/ui-bots/info-state.ts:101`,
`info-sheet.tsx:235`). The released phone layout (`R:src/ui-bots/flags.ts`, `PHONE_BOTS_RELEASED = true`) uses the
new row menu (`R:src/ui-bots/bot-menu.ts`), which has no such item, so on the phone the Bot Info switch is the
control. Its action (`R:src/ui-bots/info-actions.ts:141-147`): a selection haptic, then
`attempt('Couldn’t Change the Alert', …saveBotMetaOrThrow(bot, { screenAutoOpen: !screenNoticeOn(current) },
{ screenAutoOpen: screenNoticeOn(current) }))` (the patch, and the undo for a refused write). No toast.

**DECISION D4:** one native control, the Bot Info switch, with the web's current label "Alert When It Uses Its
Computer". The row's older wording ("Notify me when it uses its screen") is the same flag under the label the
released phone UI no longer shows. No row-menu item and no toast are added.

### 7.2 Native design

`N:HermesKit/Store/BotStore+Editing.swift`, after `setHidden` (`:378-383`):

```swift
/// "Alert When It Uses Its Computer" (R:src/bot-screen-phone.tsx:32): on unless the stored flag is exactly false.
func screenNoticeOn(_ name: String) -> Bool { currentMeta(name)["screenAutoOpen"] != .bool(false) }

func setScreenNotice(name: String, _ on: Bool) async throws {
    try await writeBotMeta(name, failureTitle: "Couldn’t Change the Alert", patch: { meta in
        (meta["screenAutoOpen"] != .bool(false)) == on ? nil : ["screenAutoOpen": .bool(on)]
    }, undo: { _, _ in ["screenAutoOpen": .bool(!on)] })
}
```

Wire: §2.2 (the whole merged `hermes-bots` object, with `screenAutoOpen` added or changed and nothing else touched).

The switch (`ComputerInfoSection`): `@State alertOn` starts from `alertOn()`; a flip plays
`UISelectionFeedbackGenerator().selectionChanged()`, sets the state at once, counts a pending write and runs
`setAlert(new)`. On success, when no write is pending, state is re-read from the store. On failure the state goes
back to the store's value and `FailureAlert.present(error, fallbackTitle: "Couldn’t Change the Alert", from: host)`
shows with Try Again (which runs the same flip again). Writes for one bot are already serialised by `writeBotMeta`,
so quick flips land in order and the last tap wins.

`PresenceCenter` reads the flag through `context.noticeOn(profile)` each time an event arrives (no cache), so a
flip takes effect for the next tool call, on this phone at once and on other devices after their next roster read.

### 7.3 UI states and words

| State | What shows |
|---|---|
| Flag absent, `true`, or anything but `false` | switch on |
| Flag `false` | switch off |
| Flip, gateway saves | the switch stays where it was put; nothing else |
| Flip, gateway refuses | switch returns; alert title `Couldn’t Change the Alert`, reason from the gateway or `Your gateway didn’t save the change.`; buttons Try Again, OK |
| Flip on an older gateway | alert reason `This gateway can’t save bot settings yet. Update Hermes on the computer, then try again.` |
| Flip in a read-only build (`-HQDebugReadOnly YES`) | alert reason `Changes are turned off for this gateway in this build.` |
| Flip, link drops mid-write | switch returns; the transport's own words (for example "The connection changed before your gateway answered. Try again.") |
| Offline | switch dimmed, not tappable |

VoiceOver: "Alert When It Uses Its Computer, switch button, on/off" (SwiftUI's own).

### 7.4 Acceptance

- D1. Fresh fixture: the switch is on for every bot, and `GET /__fixture/presence` shows no `profiles.configure`
  call (reading the default writes nothing).
- D2. Flip off: one `profiles.configure` with `name` = the bot and `ui_meta["hermes-bots"]` equal to the old object
  plus `"screenAutoOpen": false` (compare in the fixture's `configure_calls`); relaunch: still off.
- D3. Flip on again: `"screenAutoOpen": true`; relaunch: on.
- D4. `{"configure":"applied-false"}`: flip → the alert with "Your gateway didn’t save the change.", switch back,
  and the fixture's stored meta unchanged. `{"configure":"old-gateway"}` → the older-gateway words.
  `{"configure":"hang"}` → after 30 s the timeout's words, switch back.
- D5. Another device: `POST /__fixture/presence {"edit":{"profile":"ivy","screenAutoOpen":false}}` while Bot Info is
  open → after the next roster read (≤ 30 s) the switch shows off without reopening.
- D6. With the switch off, §8's notice never shows for that bot; other bots still notify.

---

## 8. Row L506 — "<bot> is using its browser / screen" notices with Watch

### 8.1 Web

`startPhoneScreenNudges` (`R:src/bot-screen-menu.tsx:83-114`), on every `tool.start`:

- skip a replayed start or a non-screen tool (`:88`);
- the bot is the session's durable owner; skip when there is none or its notice is off (`:89-91`);
- a browser tool while this bot's own chat is on screen: skip, "the card above the composer already says so, with
  its own Watch" (`:93-96`);
- `shouldNudge(key, now, last, Boolean($phoneScreen.get()))` (`:97`): none while a Screen viewer is showing, and one
  per bot per 30 s (`R:src/bot-screen-phone.tsx:751-757`);
- browser tool: skip when a Watch Browser viewer for that bot is open (`:107`, `browserWatchOpen` `:77-79`); else
  `host.notify({ id: 'dispatch-screen-nudge:' + key, kind: 'info', message: `${name} is using its browser`,
  durationMs: 8000, action: { label: 'Watch', onClick: openBrowserWatch({...scope, owner: scope.profile, title: name}) } })`
  (`:108-110`);
- any other screen tool: `${name} is using its screen`, Watch → `openBotScreen(bot, meta)`, 8000 ms (`:112`).

The same notice id per bot means a newer notice for that bot replaces the older one. The web shows these as toasts:
under the header inside a chat, above the tab bar elsewhere (`R:src/phone-chat.css:77-81`).

### 8.2 Native design

`PresenceCenter.handle(_:)`, for `tool.start`, after the §4 bookkeeping:

```swift
let outcome = gate.decide(.init(
    replayed: event.replayed, toolName: name, profile: profile,
    noticeOn: profile.map(context.noticeOn) ?? false,
    visibleChatProfile: context.visibleChatProfile(),
    screenViewerOpen: BotComputerHooks.screenIsOpen?() ?? false,
    watchingThisBrowser: profile.map(BrowserViewerController.isWatching(profile:)) ?? false,
    canWatchScreen: BotComputerHooks.openScreen != nil), now: .now)
```

`.browser` → `PresenceNotice.shared.show(.init(profile:, name: bot.name, kind: .browser, face:))`; `.screen` → the
same with `.screen`. `.none(reason)` → `AppLog.note("presence", "no notice: \(reason)")` (the reason only; never a
name, an address or a tool argument).

`BrowserViewerController` (`N:App/Browser/BrowserViewerController.swift:15`) gains

```swift
/// A viewer for this bot's browser is up (a chat-only viewer counts for its bot too).
static func isWatching(profile: String) -> Bool { current.map { $0.scope.profile == profile } ?? false }
```

`visibleChatProfile` is `focusedChat?.profile`; `focusedChat` is cleared when the chat's screen stops observing
(`N:App/AppModel.swift:565-571`), which includes being covered by the full-screen viewer, hence the separate
`isWatching` check, as on the web.

Gates that do **not** apply (**DECISION D5**, web parity): the notice ignores Settings › Notifications › "Bot
Activity Banners" (that switch is for finished replies; the web's screen notice calls `host.notify` directly and
does not consult `$activityToasts`, `V:plugins/hermes-bots/roster-actions.ts:121`) and ignores the bot's Mute (a
notification mute for replies). The per-bot switch of §7 is the one control, as the owner asked ("make the browser
notice on by default").

**DECISION D6:** "is using its screen" is shown only when the screen stream's viewer exists
(`BotComputerHooks.openScreen != nil`). Until then a `computer_use…` tool shows the row status (§4) and no notice,
because a Watch that opens nothing is a control that does nothing. Nothing is stamped, so the first notice after
the hook appears is not held back.

### 8.3 The notice view: `N:App/Presence/PresenceNotice.swift`

**DECISION D7:** the notice is a Liquid Glass capsule at Apple's banner spot, built like the reply peek
(`N:App/Notifications/ReplyPeek.swift`), not a toast above the tab bar. The owner approved that spot and that
material for in-app banners (`MEM:reply-peek.md`), it never covers the chat's status line or the composer
(`MEM:ui-hunt-oct6.md`), and one banner style for "a bot did something" is easier to read than two.

- `@MainActor final class PresenceNotice` with `static let shared`, `show(_:in:onWatch:)`, `dismiss(up:)`,
  `isShowing`.
- View: a `UIVisualEffectView` with `UIGlassEffect(style: .regular)`, `isInteractive = true`,
  `cornerConfiguration = .capsule()`, untinted. Added to the app's window (`MainTabController.current?.view.window`),
  so it shows over sheets and the viewer, like the peek.
- Frame: width `min(window width − 24 − side safe areas, 440)`, top `safeAreaInsets.top + 2`, height
  `max(64, content + 24)`.
- Content, leading to trailing: the bot's face 40 pt (`context.face(profile)`, the peek's own source; a grey circle
  with the initial when there is none); the message, 15 pt semibold `.label`, up to 2 lines; the word `Watch`, 15 pt
  semibold in the tint colour, never truncated. Message and Watch scale with Dynamic Type through
  `UIFontMetrics(forTextStyle: .subheadline)` with `maximumContentSizeCategory = .accessibilityMedium`; at
  accessibility sizes the face is hidden to leave the words their room.
- The whole capsule is one button: a tap is Watch (light impact, the notice leaves, the viewer opens). A swipe up
  sends it away; a pull down gives a little and springs back; a resting finger holds it (the peek's gestures).
- Touches (**DECISION D36**, replaces D33's two recognizers after stress round 1): one recognizer
  (`PresenceNotice.TouchTracker`) follows one finger from the moment it lands to the moment it lifts and reports
  down, moved and up, in order, straight to the view; it always finishes a touch it began (also from `reset()`), and
  a newer finger takes over from one that is still down. What the touch was is decided once, at the lift, by
  `PresenceNotice.outcome(travel:rise:speed:)` from the touch's own places and times (so events delivered late,
  in a batch, after a stall give the same answer): ended more than 18 pt above where it landed → away; never got
  more than 10 pt from where it landed → tap (Watch); moved more than 10 pt and ended above with an upward speed
  over 300 pt/s → away (a flick); anything else springs back. A touch that moved is therefore never a tap, and a
  12 pt nudge is neither a tap nor a swipe.
- Who holds it is a set (`.touch`, `.voiceOver`), not a count: holding twice is holding once, a let-go is final,
  and the leave timer is on whenever the set is empty.
- It leaves by itself after 8 s (`ScreenTools.noticeSeconds`), 16 s while VoiceOver runs, and not while touched or
  VoiceOver-focused, with one limit (**DECISION D37**): a finger that has not moved for 30 s
  (`restingFingerSeconds`) no longer holds it, and the notice leaves. Nothing can keep a notice on screen for good.
  DEBUG: `-HQDebugNoticeHold YES` holds it 60 s for UI tests.
- A name too long for the two lines is shortened with "…" (`PresenceNotice.fitted`), so "is using its browser" is
  never the part cut off; VoiceOver still hears the whole name (**DECISION D38**).
- Appear and leave: the peek's motion (spring drop with the glass materialising; fade only with Reduce Motion).
- One notice at a time. A notice for the same bot refreshes the words and restarts the 8 s. A notice for another
  bot replaces the one showing with a 0.2 s cross-fade; there is no "+1" count (each bot's row says what it is
  doing). **DECISION D8.** A capsule that is being held (a finger on it, or VoiceOver's focus) stays held through a
  replacement: its 8 s starts when the hold ends, not under the finger (D33).
- One banner at the banner spot: showing a notice first calls `ReplyPeek.shared.dismiss(up: true)`; and
  `NotificationHub` dismisses the notice just before it shows a peek (one line before each
  `ReplyPeek.shared.show`, `N:App/Notifications/NotificationHub.swift:246,318`). The newer banner wins.
- Sign-out or account switch (`PresenceCenter.shutdown()`): `dismiss(up: true)`, `gate.reset()`.
- Accessibility: `isAccessibilityElement = true`, traits `.button`, label = the message, hint
  `Opens its browser` / `Opens its screen`, `accessibilityPerformEscape` dismisses, identifier `presence-notice`;
  on show, `UIAccessibility.post(notification: .announcement, argument: message)`.

### 8.4 Watch

Browser: `context.openBrowser(BrowserScope(profile: profile, title: name), gaveUp)`, which `AppModel.watchBrowser`
implements in this order (**DECISION D9, D22**):

1. Find what is on top: `AppModel.presenceTop()` walks `presentedViewController` from the window's root and says
   whether it can take a presentation now. It cannot while the top is a `UIAlertController` (the alert is the
   person's to answer) or while any page in the stack is still arriving or leaving (UIKit drops a presentation made
   then).
2. Wait first. While it cannot, look again every 0.25 s, 20 times (about 5 s, `AppModel.watchWaitTries`). Nothing is
   dismissed and nothing under the alert is closed while waiting. When the wait runs out the log says
   `watch: gave up waiting` and `gaveUp` runs: the centre shows the notice again (`notice: Watch offered again`), so
   Watch is still on offer; it is not offered again when the app is in the background, the bot is gone or its viewer
   came up some other way.
3. Close second. Only once the top can take a presentation: if a viewer for another bot is up
   (`BrowserViewerController.isUp`, not `isWatching(profile:)`), `BrowserViewerController.closeCurrent(completion:)`
   runs the same steps as its ✕ (resign typing, `session?.stop()`, which hands a held browser back, cancel the
   subscription) and dismisses the viewer **through its presenter** (`presentingViewController.dismiss`), so whatever
   was presented over the viewer goes with it. A plain `dismiss` on the viewer only took away the child presented
   over it and left the viewer on screen, closed underneath, with a dead ✕. If the viewer is still on screen when the
   dismissal ends (`viewer close did not take` in the log) its `closing` and `asking` marks are put back and it draws
   again, so ✕ works. A second `closeCurrent` while one is running waits for the same close.
4. Then steps 1–2 again (the close is a transition), and `openBrowser(scope, from: top)`
   (`N:App/Browser/AppModel+Browser.swift`).

The web's `openBrowserViewer` returns when a viewer is already open (`R:src/browser-watch/viewer.tsx:604-605`),
which would make Watch do nothing; native closes the other viewer first (D9).

With no plugin the viewer opens on its setup screen (§10), as on the web.

Screen: `BotComputerHooks.openScreen?(bot, top)` after the same steps 1–2.

### 8.5 UI states and words (exact)

| Case | Notice |
|---|---|
| A bot starts a `browser_…` tool, not skipped | `<Name> is using its browser` · `Watch` |
| A bot starts a `computer_use…` tool, screen viewer available, not skipped | `<Name> is using its screen` · `Watch` |
| Its notice is off (§7) | none |
| Browser tool and that bot's chat is on screen | none (the chat's card says it) |
| Already watching that bot's browser | none |
| A Bot Screen viewer is showing | none |
| Under 30 s since that bot's last notice | none |
| The start came from a reconnect's catch-up | none |
| App in the background | none (the socket is paused; what was missed arrives as catch-up). The app runs on for a moment after it leaves: a start that arrives then is checked before the gate, so nothing is shown to nobody, no banner is found stale on the return and no 30 s is stamped (**DECISION D32**) |

`<Name>` is the bot's display name (`Bot.name`; "Hermes" for the default profile).

### 8.6 Fixture and acceptance

Fixture §12 on 9930; UI tests launch with `-HQDebugNoticeHold YES`.

- E1. Open Ivy's chat, go back to Bots, send
  `{"profile":"ivy","type":"tool.start","payload":{"tool_id":"t1","name":"browser_navigate"}}` to `/__fixture/event`:
  within 1 s a glass capsule under the status bar reads "Ivy is using its browser" with "Watch". A screenshot shows
  real glass (content behind it refracts), no tinted blur.
- E2. Tap it: the Watch Browser viewer opens for Ivy (`browser.stage` exists; with the fixture's row for Ivy active,
  frames draw).
- E3. Send the same event again 5 s later: no second notice. 31 s after the first: a notice again.
- E4. With Ivy's chat on screen: no notice for `browser_navigate`; the chat's browser card shows instead (with a
  plugin row).
- E5. With the viewer open on Ivy: no notice for Ivy; a `browser_…` start for Hermes (after opening its chat once)
  does notify, and its Watch closes Ivy's viewer and opens Hermes's.
- E6. Switch off (§7) for Ivy: no notice for Ivy; Hermes still notifies.
- E7. `computer_use_click` with no screen hook: no notice, row says "Using its computer". With
  `-HQDebugScreenRow YES` (which also sets `openScreen` to a stub that shows an alert titled "Screen"): notice
  "Ivy is using its screen", Watch runs the stub.
- E8. Left alone, the notice leaves after 8 s (measured 7.5–9 s without the hold flag); swipe up dismisses at once.
- E9. A reply peek arriving while the notice shows replaces it, and the other way round; never two banners.
- E10. Unit: a `tool.start` delivered by replay (`replayed == true`) never notifies.
- E11. Ivy's viewer open with an alert over it; a `browser_…` start for Hermes; tap the notice: the alert and Ivy's
  viewer stay; about 5 s later the notice is back; after the alert is answered a tap opens exactly one viewer,
  "Hermes’s Browser", and its ✕ returns to the page underneath (`PresenceStressTests.test23`).
- E12. A finger resting on the notice for 11 s: it is still there; lifting the finger is the tap
  (`PresenceTimingTests.test3`).

---

## 9. Row L477 — chat ⋯ › Watch Browser, "Offline" when offline

Web: `R:src/phone-chat-menu.tsx:125` (`offline = phoneConnectionStatus(gatewayState, {state: linkStatus}) !== null`;
`R:src/phone-header-state.ts:83-92`: null only when the link is open) and `:258`:
`{kind:'action', id:'browser', title:'Watch Browser', symbol:'safari', ...(offline ? {disabled:true, subtitle:'Offline'} : {})}`.

Native: `N:App/Browser/AppModel+Browser.swift:37-45`. `ChatMenus.offline` already exists
(`N:App/Chat/Menus/ChatMenus.swift:78`, `session.connection != .ready`) and the other rows already use the same
subtitle (`N:HermesKit/Chat/ChatActionsModel.swift:38`). The menu is rebuilt on every open
(`moreMenuElements()`), so the state is fresh.

```swift
menus.slotItems[.browser] = { [weak self, weak screen, weak menus] in
    guard let self, let screen else { return [] }
    let offline = menus?.offline ?? false
    let item = UIAction(title: "Watch Browser", subtitle: offline ? "Offline" : nil,
                        image: UIImage(systemName: "safari"), attributes: offline ? .disabled : []) { … as today … }
    item.accessibilityIdentifier = "chat.more.browser"
    return [item]
}
```

Put the title/subtitle/attributes choice in a pure helper (`BrowserMenuRule.chatItem(offline:) -> (subtitle: String?, disabled: Bool)`
in `BrowserWire.swift`) so it has a unit test.

States: link ready → "Watch Browser", enabled. Connecting, reconnecting or offline → "Watch Browser" greyed with
"Offline" under it; a tap does nothing (the system does not deliver it). Wire: none.

Scope note: the Bots row menu's Watch Browser (`BotMenuHooks.providers[.watchBrowser]`) and the chat's browser card
are not this row and stay as they are.

Acceptance:

- F1. Link ready: ⋯ shows "Watch Browser" enabled; it opens the viewer (`BrowserEndToEndTests.test2` still passes).
- F2. `/__fixture/presence {"gateway":"down"}`, wait for the chat header to say it is reconnecting, open ⋯: the
  item is greyed and reads "Watch Browser, Offline" (`app.buttons["chat.more.browser"].isEnabled == false`, label
  contains "Offline"). Tapping it opens nothing.
- F3. `{"gateway":"up"}`, reopen ⋯ after the link is back: enabled, no subtitle.

---

## 10. Row L480 — "Ask Hermes to Install It" queues the request in the main bot's chat

### 10.1 Web

Setup screen, `R:src/browser-watch/viewer.tsx:516-524`: title `Update Browser Watching` or `Watch Your Bots Browse`;
the body; a button `Ask Hermes to Install It` (the main bot's own name in place of Hermes when it has another), which reads `Asking…` and is disabled while the request runs; a
problem line (`role="alert"`) under it when it fails. `installRequest` (`:497-505`) calls `askToInstall` and closes
the viewer on success. With a legacy plugin and no browser, the same request sits behind `Ask Hermes to Update It`
(`:536`).

`askToInstall`, `R:src/browser-watch/setup.ts:34-51`: the main bot of the gateway (`setupBot`); open its chat
(`openBotFromBots`); wait up to 80 × 50 ms for the chat's session; if the queue already holds a prompt with the same
text, done; else `enqueueQueuedPrompt(sessionId, {text: BROWSER_SETUP_PROMPT, displayText: QUEUE_TITLE,
attachments: []})` with `QUEUE_TITLE = 'Install the Hermes HQ browser plugin on this Hermes.'` (`:28`). The queue
sends it when the bot is free: at once when idle, after the running reply otherwise
(`V:store/composer-queue.ts:198-230`); the bubble and the queue row show the title, not the long prompt
(`V:app/session/hooks/use-prompt-actions/submit.ts:418`). Errors (`:37,38,46,49`):
`Couldn’t find the main bot on the computer running Hermes. Open Bots and try again.` ·
`Couldn’t open the bot’s chat. Try again.` · `The bot’s chat didn’t open in time. Try again.` ·
`Couldn’t send the request to the bot. Try again.`

### 10.2 Native today

`N:App/Browser/BrowserViewerController.swift:632-637` dismisses the viewer and calls
`AppModel.askMainBot(prompt)` (`N:App/Browser/AppModel+Browser.swift:71-88`), which opens the main bot's chat and
types the long prompt into the field for the person to send. `PushSetupOffer` uses the same helper for the
notification add-on (parity L575, the `settings` stream's row).

### 10.3 Native design

New `N:App/Presence/MainBotRequest.swift`:

```swift
@MainActor enum MainBotRequest {
    struct Failure: LocalizedError { let errorDescription: String? }
    static let browserTitle = "Install the Hermes HQ browser plugin on this Hermes."

    /// The gateway's main bot, or the web's words for why there is none.
    static func mainBot(_ bots: [Bot]) throws -> Bot      // PushSetupOffer.setupBot; else Failure("Couldn’t find the main bot…")

    /// Opens the main bot's chat and queues `text` there: sent at once when the bot is free, after its reply
    /// otherwise. The bubble and the queue row show `title`. Throws the web's words.
    static func queue(text: String, title: String) async throws
}
```

`queue(text:title:linkReady:)`:

1. `MainTabController.current` else throw `Couldn’t open the bot’s chat. Try again.`
2. Close what is presented over the tabs (Bot Info, or the sheet the notice's Watch opened the viewer over), as Bot
   Info's own Bot Chat row does: `root.dismiss(animated: true)`, then wait for it to be gone. Without this the chat
   opened, and the request went out, under the sheet: nothing to see, and a second tap sent it again. Two things are
   never closed (`checkCanLeave`): a sheet that refuses a swipe down because it holds unsaved edits
   (`isModalInPresentation`) throws `Save or discard what you’re editing, then try again.` (**DECISION D30**), and an
   alert on top throws `Couldn’t open the bot’s chat. Try again.` The viewer asks this first (`canAsk`), so those
   words show under its button and the viewer stays.
3. Select the Bots tab, pop to its root without animation, `bots.open("default")` (as `askMainBot` does).
4. Wait up to 4 s by the clock (the web's 80 × 50 ms; `openBudget`) for the top controller to be a
   `ChatViewController` in a window whose `session.profile == "default"`; else throw
   `The bot’s chat didn’t open in time. Try again.`
5. `guard let live = chat.session as? LiveChatSession` else throw `Couldn’t send the request to the bot. Try again.`
6. What is left of the 4 s goes to the chat's own open, whose answer says whether a reply is running (D24). With the
   gateway away (`linkReady()` false) there is no answer to wait for and the wait is skipped.
7. If `live.queuedMessages.contains { $0.text == text }`, return (already asked).
8. `LiveChatSession.sentTitles.note(text:title:)`, then `live.send(text, display: title)`.

The title and the request (`SentTitles`, **DECISION D29**): the gateway stores the whole prompt, so wherever the chat
reads its transcript (the end of a reply, its cache when it opens, older pages) a stored row that is the request
shows its title. The browser plugin's pair is noted at sign-in (`AppModel.startPresence`), so the title also shows
after a relaunch and on a phone that did not send it; the stored prompt, which names the plugin's old wire name, is
never shown. The other way round too: a refused send hands the bubble's words (the title) back to the field, and
sent again from the main bot's field the title goes out as the request it stands for (`prompt(forTitle:)`), under
the same title.

`AppModel.askMainBot` stays as it is for the notification add-on; the `settings` stream may switch L575 to
`MainBotRequest.queue` with its own title. This stream changes only the browser path.

Viewer (`BrowserViewerController`): `askToInstall` becomes `var askToInstall: ((String) async throws -> Void)?`,
plus `var canAsk: (() throws -> Void)?` for the check that needs no navigation. `install()`:

1. If already asking, return. Button title `Asking…`, disabled; the problem line clears.
2. `try canAsk?()` (`MainBotRequest.mainBot(bots)`): on failure the problem line shows the words under the button
   (new `emptyProblem` label: `.footnote`, `.systemRed`, centred, wraps, identifier `browser.empty.problem`, and
   `UIAccessibility.post(notification: .announcement, argument: text)`), the button returns to its title.
3. `session?.stop()`, then the viewer leaves through its presenter (§8.4 step 3); when it has gone run
   `try await askToInstall(BrowserSetupPrompt.text)`.
4. A failure after the viewer has gone (steps 1–3 of `queue`) shows
   `FailureAlert.present(title: "Couldn’t Ask Hermes", reason: <the web's sentence>, from: topmost)` with OK.

**DECISION D10:** the viewer closes before the chat opens (the web opens the chat underneath and closes the viewer
after queueing). A chat pushed under a full-screen modal does not start its session in UIKit, so native cannot
queue while the viewer covers it. The person sees the same thing: the viewer leaves and the main bot's chat shows
the request. The one failure the web shows inline that native shows as an alert is "didn’t open in time".

**DECISION D11:** the alert title "Couldn’t Ask Hermes" is new wording (the web has no title for an inline
problem); the reason is the web's sentence.

**DECISION D12:** the setup body keeps the shipped native wording "computer" where the web says "Mac" ("…on the
computer that runs Hermes.", "This computer has an older browser add-on…"); the build 250 audit did not flag it and
Hermes also runs on Linux. Titles and buttons match the web word for word.

`BrowserSetupPrompt.text` (`BrowserViewerController.swift:800-815`) already matches `BROWSER_SETUP_PROMPT`; do not
change it.

### 10.4 UI states and words

| Moment | What shows |
|---|---|
| No plugin | `Watch Your Bots Browse` · "See the browser a bot is using, live, and take over when it needs you to sign in or enter a code. It needs a small plugin on the computer that runs Hermes." · button `Ask Hermes to Install It` |
| Old test add-on | `Update Browser Watching` · "This computer has an older browser add-on from a test build. The new one leaves your bots’ own browser tools alone and needs no Chrome extension." · button `Ask Hermes to Install It` |
| Legacy plugin, no browser | the existing empty state with `Ask Hermes to Update It` |
| After the tap | button `Asking…`, disabled |
| No main bot in the roster | under the button: `Couldn’t find the main bot on the computer running Hermes. Open Bots and try again.` |
| Main bot idle | viewer closes; the main bot's chat opens; a sending bubble reads `Install the Hermes HQ browser plugin on this Hermes.`; the bot starts replying |
| Main bot mid-reply | viewer closes; the chat opens; the queue card above the composer lists `Install the Hermes HQ browser plugin on this Hermes.`; it sends when the reply ends |
| Asked twice while still queued | one queue row, not two |
| Chat did not open in 4 s | alert `Couldn’t Ask Hermes` · `The bot’s chat didn’t open in time. Try again.` |
| Asked from Bot Info (or from a viewer the notice opened over a sheet) | the sheet closes with the viewer; the main bot's chat shows the request |
| A sheet with unsaved edits is under the viewer | under the button: `Save or discard what you’re editing, then try again.`; the viewer stays |
| Gateway away when asked | the chat opens with the request as a sending bubble under its title ("Sending…"); when the connection is back it goes out by itself, once (the chat's send waits for the link, up to 60 s twice) |
| Still away after that | the chat's own refused-send path: an error card, and the title comes back to the field; Send sends the whole request under its title (nothing is lost, and the bare title is never sent) |

The field is left empty: nothing is typed for the person to send.

### 10.5 Acceptance

- G1. `/__fixture/browser {"plugin":"missing"}`, chat ⋯ › Watch Browser → setup screen; tap the button: within 3 s
  the main bot's chat is on screen with a user bubble "Install the Hermes HQ browser plugin on this Hermes.", the
  composer is empty, and `GET /__fixture/state` shows exactly one `prompt.submit` for `default` whose `text` starts
  with "Please install Hermes HQ's browser plugin".
- G2. With a reply running (`/__fixture/plan {"plans":[{"replyDelay":20}]}` and a first message sent), ask from the
  viewer: the queue card shows the title, no `prompt.submit` with the install text yet; after `/__fixture/finish`
  one such submit carries `queued: true`.
- G3. Ask twice while it is queued (reopen the viewer from another bot's row menu): still one queue row and, after
  the drain, one submit.
- G4. Unit: `MainBotRequest.mainBot([])` throws the web's sentence; the dedupe returns without a second send.
- G5. `test4_NoPluginExplains` still passes (the button's identifier `browser.empty.action` is kept).
- G6. Ask from Bot Info › Watch Browser: Bot Info is gone, the main bot's chat shows the bubble with the title and
  `/__fixture/state` shows exactly one install submit (`PresenceStressTests.test22`, and `test24` from a viewer the
  notice opened over Bot Info).
- G7. After the reply, kill and relaunch, open the main bot's chat: the bubble shows the title and no label on
  screen contains "dispatch" (`PresenceStressTests.test25`).

---

## 11. Row L485 — the viewer's socket dials at once when the network is back

### 11.1 Web

The socket lives only while the sheet is shown (`useShown`, `R:src/browser-watch/viewer.tsx:56-72`; effect guard
`:192-193`). Native already does that (`isShown`, `N:App/Browser/BrowserViewerController.swift:300`; `setShown`,
`N:HermesKit/Browser/BrowserWatchSession.swift:172-176`). What is missing is `:270-271`:

```ts
const resume = () => {if (!stopped && !asking && (!ws || ws.readyState === WebSocket.CLOSED)) {clearTimeout(timer); attempt = 0; void connect()}}
window.addEventListener('dispatch:network-restored', resume)
```

`dispatch:network-restored` fires when iOS reports the network reachable again (`R:src/native-runtime.ts:89-92`).
`asking` is "a dial is fetching its address"; such a dial is left alone so two sockets never race (`:197-212`).

### 11.2 Native design

The signal: `AppModel.connectionChanged(_:)` (`N:App/AppModel.swift:432`) already hears the client's states, which
follow `NWPathMonitor` through `PathWatcher` (settled 2 s, `N:HermesKit/Net/LiveGatewayClient.swift:306-340`;
`pathChanged`, `GatewayConnection.swift:869-890`). Add a pure rule to `N:HermesKit/Browser/BrowserWire.swift`:

```swift
nonisolated enum BrowserLinkRule {
    /// The gateway link came back: the path returned (the state leaves .offline) or the main socket is ready again.
    static func restored(from old: ConnectionState, to new: ConnectionState) -> Bool {
        switch new {
        case .signedOut, .offline: return false
        case .ready: return old != .ready
        case .connecting, .reconnecting: if case .offline = old { return true } else { return false }
        }
    }
}
```

and in `connectionChanged`, before `connection = state`:
`if BrowserLinkRule.restored(from: connection, to: state) { browser?.linkRestored() }`.

**DECISION D13:** the kick also fires when the main socket becomes ready after any drop (a gateway restart, a VPN
flap), not only on a network path change. It is the same repair (dial now instead of waiting out up to 10 s) and
costs one dial.

`BrowserService`:

```swift
/// The gateway link is back: sockets waiting out a back-off dial now.
func linkRestored() {
    guard !isShutDown else { return }
    for session in watchers.allObjects { session.linkRestored() }
    activity.linkRestored()
}
```

`BrowserWatchSession`:

```swift
func linkRestored() {
    // Only a socket that is waiting to retry: one that is live, or a dial already asking for its address, is left alone.
    guard shown, !stopped, !ended, socket == nil, retry != nil else { return }
    retry?.cancel(); retry = nil
    attempt = 0
    AppLog.note("browser", "watch link restored: dialing now")
    connect()
}
```

`BrowserActivityChannel` (**DECISION D14**, beyond the web, whose list socket only backs off): the same kick, so
the Bots row lines and the chat card come back with the link:

```swift
func linkRestored() {
    guard !isShutDown, foreground, !listeners.isEmpty, socket == nil else { return }
    if retry != nil {                      // backing off: dial now
        retry?.cancel(); retry = nil
        attempt = 0
        connect()
    } else if work == nil {                // quiet because the plugin was missing: look once more
        service?.forgetPlugin()
        begin()
    }
}
```

The second branch is what makes the row lines appear after the main bot installs the plugin and restarts Hermes,
without leaving the list. It costs one `/health` per link return while a listener exists.

Everything else about the socket is unchanged: open only while the viewer is on screen and the app is active;
closed in the background (a held browser stays held two minutes on the plugin's side); back-off 1, 2, 4, 8, 10 s
(`BrowserReconnect.delay`); 25 s silence watchdog.

### 11.3 UI states

No new words. While the link is down the viewer shows what it shows today ("Reconnecting…" over the last page; the
stalled state's "<Name>’s Browser Isn’t Responding" / "It may be busy or restarting. Hermes HQ keeps trying."). The
change is how soon the page moves again.

### 11.4 Acceptance

- H1. Unit (`Tests/Browser/`): a session in back-off (`retry != nil`, attempt 4) → `linkRestored()` dials at once
  (the fake socket factory's dial count goes up by one within the same run-loop turn) and `attempt == 0`; a session
  mid-dial, live, hidden, stopped or ended → no dial. The same for the channel, plus the quiet-plugin branch.
- H2. Unit: `BrowserLinkRule.restored` table: offline→connecting true; offline→reconnecting true; offline→ready
  true; reconnecting→ready true; connecting→ready true; ready→ready false; ready→reconnecting false; anything→
  offline false; anything→signedOut false.
- H3. UI: viewer live on the fixture; `/__fixture/presence {"gateway":"down"}` (closes `/api/ws` and the plugin
  sockets and refuses new ones) for 25 s, so the watch back-off sits at 8–10 s; `{"gateway":"up"}`. After the app's
  main socket is ready again (the Bots list's or chat's reconnect state clears), frames are drawn again within 2 s
  (`browser.stage`'s frame count rises). The log has "watch link restored: dialing now". Without the change the
  same run takes up to 10 s more.
- H4. The viewer covered by the app going to the background and back: one socket at a time
  (`GET /__fixture/browser` `viewers` never exceeds 1).

On a real phone the trigger is airplane mode off or Wi-Fi back; the simulator cannot switch its network, so that
part is checked through the fixture's gateway-down knob and the unit tests.

---

## 12. Stand-in gateways

Never contact the owner's gateway or any port this stream did not start. Builder ports 9930–9934; stress tester
9935–9939. Builder simulator: `xcrun simctl create "HQN-m9-presence" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`;
stress tester: `"HQN-m9-presence-s"`. Always pass the UDID; never the scripts' default simulator.

### 12.1 What exists

`N:scripts/fixtures/browser-gateway.py` (the plugin stand-in over the ref238 performance fixture): password
sign-in, `/api/ws`, two bots (`default` shown as Hermes, `ivy` shown as Ivy), streaming replies with plans
(`POST /__fixture/plan`, `/__fixture/finish`, `GET /__fixture/state` with the RPC log and prompt ledger),
`POST /__fixture/event {profile, type, payload}` (one gateway event into that bot's session), the plugin routes and
`POST /__fixture/browser {active, listed, url, ask, plugin, …}`. It covers L477 (online half), L480 and the
regression run:

```
cd /Users/me/Projects/hermes-hq-native-wt/m9-presence
HQN_BROWSER_PORT=9931 scripts/e2e-browser.sh <UDID>
```

It does not cover the rest: its plugin list has one row (the default bot's), `profiles.configure` answers `{}`
(which the app reads as an older gateway), and nothing can take the gateway down.

### 12.2 New: `N:scripts/fixtures/presence-gateway.py`

Loads `browser-gateway.py` the way that file loads the performance fixture (`importlib`, then wraps `voice.rpc` and
the handler) and adds:

- **`profiles.configure` / `profiles.list`**: per-profile `ui_meta` and `ui_meta_revisions`, with Hermes's per-key
  compare-and-swap copied from `N:scripts/fixtures/settings-gateway.py:225-262` (`configure_ui_meta`). The answer is
  `{"ok": true, "applied": {"ui_meta": true, "ui_meta_revisions": {...}}}`; `profiles.list` rows carry the stored
  `ui_meta` (starting from the base fixture's `display_name`) and revisions.
- **`POST /__fixture/presence`** (no auth, like the other controls), any of:
  - `browsers: [{profile, active?, url?, ask?, control?}]`: the plugin's list becomes one row per entry (id =
    24 hex derived from the profile; `session_id` = that bot's stored id); pushed to every `/activity` socket. The
    watch socket serves the same fake page for any listed id.
  - `configure: "ok" | "applied-false" | "old-gateway" | "refuse" | "hang"`: saved; `{"applied":{"ui_meta":false}}`;
    `{}`; a JSON-RPC error with message "Synthetic refusal"; no answer.
  - `edit: {profile, screenAutoOpen}`: another device changes the flag (revision + 1).
  - `gateway: "down" | "up"`: down closes every `/api/ws`, `/activity` and watch socket and answers new upgrades
    and REST with 503 until up.
  - `activity: "drop" | "garbage" | "huge"`: close the list sockets now; send three malformed frames (not JSON, the
    wrong schema, `browsers` not a list) then a good one; send one 300 KB frame then a good one.
  - `flood: {bots, rate, seconds}`: that many list frames per second for that long, each with `bots` rows whose
    hosts change every frame.
  - `burst: {profile, name, count, interval_ms}`: that many `tool.start` events.
- **`--bots N`**: N extra profiles (`bot-01`…) beside `default` and `ivy`, each with a chat, for load runs.
- **`GET /__fixture/presence`** → `{configure_calls: [{name, ui_meta}], ui_meta: {profile: …}, revisions,
  activity_sockets, watch_sockets, ws_clients, health_calls, gateway}`.
- **`POST /__fixture/presence/reset`** (also resets the browser fixture's state).

Everything is invented and loopback only (`127.0.0.1`); the credentials file is written 0600 and never printed.

Start it (builder):

```
cd /Users/me/Projects/hermes-hq-native-wt/m9-presence
mkdir -p build/fixtures && chmod 700 build/fixtures
[[ -s build/fixtures/browser-frames/frame-29.jpg ]] || swift scripts/fixtures/make-browser-frames.swift build/fixtures/browser-frames
lsof -nP -iTCP:9930 -sTCP:LISTEN >/dev/null 2>&1 && echo "9930 is busy: pick 9931-9934"
python3 scripts/fixtures/presence-gateway.py --port 9930 --credentials build/fixtures/e2e-presence.json \
  --frames build/fixtures/browser-frames > build/fixtures/e2e-presence.log 2>&1 &
echo $! > build/fixtures/e2e-presence.pid      # stop it with: kill "$(cat build/fixtures/e2e-presence.pid)"
```

Stress tester: the same with `--port 9935 --bots 50` and its own credentials file
(`build/fixtures/stress-presence.json`). Stop only the pid you started; never `pkill` or `killall`.

### 12.3 New: `N:scripts/e2e-presence.sh <UDID>`

A copy of `scripts/e2e-browser.sh` that: refuses to run without a UDID argument; uses
`PORT=${HQN_PRESENCE_PORT:-9930}`; starts `presence-gateway.py`; passes
`TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/build/fixtures/e2e-presence.json TEST_RUNNER_HQN_UI_PRESENCE=1`; runs
`-only-testing:HermesHQNativeUITests/PresenceEndToEndTests` (`HQN_PRESENCE_ONLY` narrows it); honours `HQN_DD`
(default `build/dd`, inside the worktree) and `HQN_SKIP_XCODEGEN`; stops the fixture on exit; writes
`build/last-e2e-presence.log`.

```
HQN_PRESENCE_PORT=9930 scripts/e2e-presence.sh <UDID>
scripts/build.sh test <UDID>                       # unit tests
HQ_IDENTITY=original scripts/build.sh build <UDID>  # the other identity still builds
```

### 12.4 Which fixture exercises which row

| Row | Fixture | Start |
|---|---|---|
| L211 | presence gateway, `/__fixture/event`, `/__fixture/finish` | §12.2 on 9930 |
| L504 | presence gateway, `/__fixture/presence {browsers}` | §12.2 on 9930 |
| L216 | presence gateway (group, offline); browser gateway (Profile and Window regression) | 9930; `HQN_BROWSER_PORT=9931 scripts/e2e-browser.sh <UDID>` |
| L507 | presence gateway, `configure` modes, `edit`, `GET /__fixture/presence` | 9930 |
| L506 | presence gateway, `/__fixture/event`, `browsers` | 9930 |
| L477 | presence gateway, `gateway: down/up` | 9930 |
| L480 | presence gateway, `/__fixture/browser {"plugin":"missing"}`, `/__fixture/plan`, `/__fixture/state` | 9930 |
| L485 | presence gateway, `gateway: down/up`, `GET /__fixture/browser` | 9930 |

---

## 13. Tests

Unit (`scripts/build.sh test <UDID>`):

`Tests/Presence/PresenceRulesTests.swift`
1. `isScreenTool`: `computer_use`, `computer_use_click`, `browser_navigate`, `browser_` true; `terminal`, ``, nil,
   `Browser_navigate`, `xbrowser_click`, `computer` false. `isBrowserTool` likewise.
2. `ComputerActivity`: active at +89.9 s, not at +90 s; a second start extends; `replyFinished` clears and says so;
   `nextExpiry` is the earliest; expired entries are dropped.
3. `NoticeGate.decide`: one case per row of the table in §3.2, plus: two bots are independent; a suppressed-by-
   watching notice still stamps the cooldown; `screenViewerOpen` and `!canWatchScreen` stamp nothing.
4. `BotList.rowStatus` / `secondLine` / `rowBadge`: needs-input over browser over computer over working over idle;
   the `Draft:` exception; tones; the VoiceOver label carries the line.
5. `RosterBuilder` puts `Input.presence[name]` on the right `Bot`, on tiles and hidden bots too.

`Tests/Presence/PresenceStoreTests.swift` (fake `GatewayClient`, as `Tests/BotStoreTests.swift` does)
6. `screenNoticeOn`: absent, `true`, `null`, `"false"` (a string) → on; `false` → off.
7. `setScreenNotice(false)`: `profiles.list` then one `profiles.configure` whose `hermes-bots` object is the old
   one plus `screenAutoOpen: false`; a no-op when already off; refused → local meta back and the undo sent.
8. `setPresence` rebuilds only when the map changes.

`Tests/Browser/` (existing fakes)
9. `BrowserLinkRule.restored` table (H2). 10. `BrowserWatchSession.linkRestored` (H1). 11. The channel's two
   branches. 12. `BrowserMenuRule.chatItem(offline:)`.

`Tests/NetReplayTests.swift`: 13. replayed frames carry `replayed == true`.

`Tests/Presence/`: 14. `MainBotRequest.mainBot([])` throws the web's words; the queue dedupe.

Added after the review (`Tests/Presence/PresenceCenterTests.swift`, `SentTitlesTests.swift`): 15. a replayed turn
that already ended never shows on the row (the replayed start publishes after the gap, the end undoes it first).
16. no notice and no cooldown while the app is in the background. 17. a Watch that could not open is offered again
(and not in the background, for a removed bot, or once its viewer is up). 18. `MainBotRequest.checkCanLeave`: a
locked sheet and an alert are never closed. 19. a held capsule stays held when another bot takes it
(`PresenceNoticeTests`). 20. `SentTitles.prompt(forTitle:)`; the browser request shows its title wherever it is read.
21. a refused request comes back as its title and goes out whole again; the cached paint shows the title; a request
put in a chat that is still opening goes out once (`TitledRequestChatTests`).

UI (`scripts/e2e-presence.sh <UDID>`), `UITests/presence/PresenceEndToEndTests.swift`, skipped unless
`HQN_UI_PRESENCE=1`; launch as `BrowserEndToEndTests.launch()` does plus `-HQDebugNoticeHold YES`; each test resets
the fixture first; screenshots attached with `attach(_:)`:

- `test1_RowSaysUsingItsComputer` (A1, A2, A4)
- `test2_RowSaysBrowsing` (B1–B4, B7)
- `test3_BotInfoComputerGroupAndSwitch` (C1–C3, D1–D4, D6)
- `test4_NoticeWatchAndSkips` (E1–E6, E9)
- `test5_ChatMenuOffline` (F1–F3)
- `test6_AskHermesQueues` (G1–G3)
- `test7_ViewerComesBackWithTheLink` (H3, H4)
- `test8_ScreenHookRowAndNotice` (C4, E7; launch with `-HQDebugScreenRow YES`)

The 90 s fall-back (A3) and the 8 s leave (E8) are timed once by hand on the simulator and recorded in
`docs/briefs/m9/presence-report.md`; the unit tests cover the arithmetic.

A row is done only when it is implemented and was seen working on the simulator against the fixture. Record each
row's outcome and evidence (test name, screenshot) in `docs/briefs/m9/presence-rows.md`.

---

## 14. STRESS PLAN

For the stress tester: simulator `HQN-m9-presence-s`, ports 9935–9939, its own derived data
(`HQN_DD=build/dd-stress`), fixture started as in §12.2 with `--port 9935 --bots 50`. Report failures as failures,
with the log lines (`scripts/hqn-logs.py`) and a screenshot.

### 14.1 Load

- S1. 52 bots, list flood: `{"flood":{"bots":50,"rate":20,"seconds":30}}` with the Bots list on screen. Pass: the
  list scrolls without hitches over 100 ms (use the app's performance log), the roster is rebuilt at most 4 times a
  second (count "roster rebuild" log lines or add a DEBUG counter), memory does not grow by more than 10 MB over the
  30 s, and when the flood stops every row shows its last line.
- S2. Tool burst: `{"burst":{"profile":"ivy","name":"browser_click","count":500,"interval_ms":10}}`. Pass: exactly
  one notice in the first 30 s, the row line steady (no flicker), no dropped touches, CPU back to idle within 2 s of
  the end.
- S3. Ten bots starting screen tools within one second (open ten chats first, then one event each). Pass: one
  capsule, ending on the last bot; ten rows say "Using its computer"; all ten fall back at their own 90 s (± 1 s).
- S4. Switch hammering: flip the Bot Info switch 20 times as fast as taps register. Pass: the final position equals
  the fixture's stored `screenAutoOpen`, the calls arrive in order, no alert, no crash.

### 14.2 Speed

- S5. Event to row: `tool.start` to "Using its computer" on screen ≤ 1 s; list frame to "Browsing …" ≤ 1.5 s
  (including the 250 ms coalescing).
- S6. Event to notice ≤ 1 s; tap on Watch to the viewer's first frame ≤ 3 s on the fixture.
- S7. Bot Info opens no slower than before (the Computer group reads the flag locally and makes no network call to
  draw; Profile and Window's read is the one that existed).
- S8. The Bots list with no browser plugin: zero extra requests per minute beyond one `/health` per subscribe
  (`health_calls`).

### 14.3 Bad network

- S9. `{"gateway":"down"}` for 60 s on the Bots list with lines showing. Pass: no crash, lines may stay (stale up to
  3 min) and never change to something wrong, the ⋯ item says Offline, Bot Info's rows dim; `{"gateway":"up"}` →
  lines correct again within 5 s of the link being ready, with no dial storm (`activity_sockets` ≤ 1,
  `watch_sockets` ≤ 1 at all times).
- S10. Flap: down 2 s / up 2 s, 20 times, with the viewer open. Pass: at most one watch socket at any time, the
  viewer ends live, no duplicate "watch link restored" dials inside one up period.
- S11. `{"activity":"drop"}` every 3 s for a minute. Pass: lines survive each drop and the socket comes back on the
  1–10 s back-off (or at once on a link return).
- S12. `{"configure":"hang"}` then flip the switch and leave Bot Info at once. Pass: after 30 s the alert shows over
  whatever is on screen (or is dropped quietly if the sheet is gone, as other Bot Info writes do), the flag is
  unchanged, the next flip works.
- S13. Ask Hermes to Install It with the gateway down. Pass: no crash; the request is in the main bot's chat under
  its title (a sending bubble, or its queue row) and the long prompt is never typed into the field; nothing is sent
  while the gateway is away; when it is back the request goes out by itself, exactly once, and the field is empty.

### 14.4 Bad data

- S14. `{"activity":"garbage"}` and `{"activity":"huge"}`. Pass: bad frames are ignored (the 256 KB cap already
  drops the huge one), the previous lines stay, the good frame that follows applies.
- S15. `tool.start` with no `name`, a numeric `name`, a 10 000-character `name`, an unknown `session_id`, an empty
  `session_id`, no payload. Pass: ignored, no crash, nothing logged but the reason.
- S16. A list row for a profile that is not in the roster, two rows for one bot (the newest `agent_at` wins), a
  `url` that is not a URL, a 5 000-character host. Pass: no crash; the line reads "Using its browser" when no host
  can be shown; a long host truncates in the row's two lines.
- S17. Stored flag as the string `"false"`, as `0`, as `null`: the switch shows on (only a real `false` is off).
- S18. A bot named with 60 characters, with an emoji, with right-to-left text. Pass: the notice keeps "Watch"
  visible and truncates the message at two lines; the row is unchanged.

### 14.5 Interruption

- S19. Background the app while a notice shows, return after 10 s. Pass: the notice is gone or leaves on time; no
  frozen capsule. Events that happened meanwhile produce no burst of notices (they arrive as catch-up).
- S20. A phone call banner, Control Centre and the app switcher over the notice and over the viewer. Pass: the
  viewer's socket follows the existing shown rule; one socket after return.
- S21. Rotate (if the build allows) and change text size while the notice shows: it stays inside the screen.
- S22. Sign out while a notice shows and while a switch write is in flight. Pass: the notice leaves, no alert from
  the old account appears after sign-in to another, no line from the old account shows.
- S23. Tap Watch while Bot Info, Settings, the model sheet or another bot's viewer is up. Pass: the viewer opens on
  top (the other viewer closes first and hands back a held browser), and closing it returns to what was there. With
  an alert over the other viewer: the alert is never answered for the person and the viewer under it is not torn
  down; Watch comes back on offer after about 5 s; once the alert is answered Watch opens exactly one viewer.
- S24. Tap "Ask Hermes to Install It" twice quickly, and tap ✕ during "Asking…". Pass: one request at most; no
  orphaned chat push.

### 14.6 Relaunch

- S25. Kill the app while a row says "Using its computer" and relaunch. Pass: the line is gone (it is not stored);
  a new tool start brings it back.
- S26. Kill and relaunch with a plugin row active. Pass: "Browsing …" is back within 3 s of the Bots list showing.
- S27. Switch off, kill, relaunch: still off; no notice. On again: notices again.
- S28. Launch straight into a reopened chat (restore): the Bots list is not on screen, so no list subscription
  until it shows; going back to Bots shows the lines.
- S29. The install request queued behind a reply, then kill and relaunch. Pass: the queue's own persistence (the
  stash) decides; the request is either still queued or was sent once, never twice.

### 14.7 Accessibility sizes

Run at Dynamic Type XS, L (default), XXXL and AX5; Bold Text; Reduce Motion; Increase Contrast; Reduce
Transparency; VoiceOver.

- S30. Bots rows at AX5: the status line wraps to two lines and is not clipped; the display badge stays inside the
  head's corner.
- S31. Bot Info Computer group at AX5: the Watch Browser subtitle wraps (row grows, 12–14 pt of padding kept), the
  switch's title wraps without pushing the switch off screen.
- S32. Notice at AX5: text capped at the accessibility-medium size, two lines, "Watch" whole, capsule within the
  safe area; at XS it is still 64 pt tall and tappable.
- S33. VoiceOver: the notice is announced once, is reachable, activates Watch on double-tap, leaves with the escape
  gesture, and waits 16 s (and while focused). The ⋯ item reads "Watch Browser, Offline, dimmed". The switch reads
  its state. The row reads its line.
- S34. Reduce Motion: the notice fades instead of dropping. Reduce Transparency: the system renders the glass as it
  does for the reply peek; the words keep contrast in light and dark.
- S35. Dark mode and both app identities (`HQ_IDENTITY=original`): tint lines and the badge use the identity's tint.

---

## 15. DECISION log

| # | Decision | Why |
|---|---|---|
| D1 | Every browser line on a Bots row is tint, "Needs you in its browser" included | Web: `bot-row.tsx:216` |
| D2 | Watch Browser from Bot Info opens over the sheet and returns to it | Shipped native behaviour since build 5; the row is about the group |
| D3 | Header "Computer" replaces "Browser" | Web wording |
| D4 | One control for the notice flag: the Bot Info switch "Alert When It Uses Its Computer"; no row-menu item, no toast | It is the one flag; the released phone UI shows only this label |
| D5 | The notice ignores "Bot Activity Banners" and Mute | Web parity; owner: "make the browser notice on by default" |
| D6 | No "is using its screen" notice until the screen viewer exists | Never a control that does nothing |
| D7 | The notice is a glass capsule at the banner spot, like the reply peek, not a toast above the tab bar | Owner-approved material and spot; never covers the status line or the composer |
| D8 | One notice at a time; another bot's notice replaces it; no count | Each row already says what its bot is doing |
| D9 | Watch while another bot's viewer is open closes that viewer first | The web's Watch does nothing there; native may not show a dead control |
| D10 | The viewer closes before the main bot's chat opens and the request is queued | UIKit does not start a chat pushed under a full-screen modal |
| D11 | Alert title "Couldn’t Ask Hermes" for a late failure | The web shows the sentence inline, without a title |
| D12 | The setup body keeps "computer" where the web says "Mac" | Shipped wording; Hermes also runs on Linux; not flagged by the audit |
| D13 | The socket kick also fires when the main socket is ready again, not only on a path change | Same repair, covers gateway restarts |
| D14 | The list socket gets the kick too, and looks for the plugin again once after a link return | Row lines and the card come back with the link, and appear after an install |
| D15 | Only `message.complete` ends "Using its computer" early; an errored turn waits out its 90 s | Web parity (`computer-activity.ts:39`) |
| D16 | Replayed `tool.start` events set the row status but never notify | Web parity (`computer-activity.ts` has no replay check; `bot-screen-menu.tsx:88` has) |
| D17 | Notices come only from `tool.start` on sessions this phone has open; the plugin's list never raises one | Web parity; the row line covers the other bots |
| D18 | (builder) A refused flip of the switch is undone to what was stored: the old value, or a null ("no value", as the web's `undoOf` writes it) when there was none. It never writes an explicit `true` | `BotStore.setScreenNotice` uses the store's default undo; a bot that never had the flag reads as it did on every device (the phone: on unless a real `false`; the Mac: off unless a real `true`) |
| D19 | (builder) The replay mark is set in `ReplayBook` (`HermesKit/Net/ConnectionSupport.swift`), so frames re-sent to repair a gap are marked as well as the reconnect replay | One place knows which frames are catch-up; a gap repair is as old as a reconnect replay |
| D20 | (builder) `PresenceHooks.botsListShown` names the list's controller | The tabs are made again on a gateway switch; the list that went away must not switch off the one that replaced it |
| D21 | (builder) The list socket's kick dials only when no dial is in flight, and a subscribe during the 3 s linger starts a dial when there is neither a socket nor a dial | Found by the unit tests: a back-off that ran out during the linger left the list quiet until the next kick |
| D22 | (builder, revised after the review) Watch tapped while an alert is on top waits for the alert, about 5 s (20 looks, 0.25 s apart), and closes nothing under it meanwhile: wait first, close another bot's viewer second. When the wait runs out the notice comes back, so Watch is still on offer, and the log says `watch: gave up waiting` | The alert is the person's to answer; dismissing it for them would lose their answer. The first build closed the other viewer before the wait, which dismissed the alert and left a frozen viewer; and it waited 20 s, by which time the tap was forgotten and nothing said it had been dropped |
| D23 | (builder) The notice leaves when the app goes to the background and when that bot's viewer opens some other way | It is old news by the return (S19), and it has nothing left to offer once the viewer is up |
| D24 | (builder) `MainBotRequest.queue` waits for the main bot's chat to finish opening for up to 4 s by the clock (the web's budget), then sends anyway. With the gateway away it does not wait: the request shows at once as a sending bubble and goes out when the link is back | The chat's own queue decides between "send now" and "queue behind the reply"; it needs to know whether a reply runs. Without a link no answer can come, and counting 50 ms sleeps stretched the 4 s to 13 s on a busy main thread (seen in S13) |
| D25 | (builder) The notice is put in whichever window is on top, not the tabs' own | Found by E5: under the full-screen viewer the tabs' view is out of the window, and the notice had "nowhere to show" |
| D26 | (builder) A "no notice" reason is written to the diagnostic log at most once in 10 s per reason | A burst of mixed tool calls wrote two lines per call |
| D27 | (builder) The fixture answers 404 for the plugin's legacy name, replaces `/api/ws`'s loop so one call can go unanswered (`configure: hang`), takes `configure` as `{mode, count}` for a one-shot failure, and adds a `rename` knob and the counters `activity_opens`, `watch_opens`, `max_activity_sockets`, `max_watch_sockets` | The base fixture answers `{}` to unknown plugin paths (the app would settle on the legacy name); the app's undo is a second configure call; S9–S11 and S18 need the counters and names |
| D28 | (builder) Dark screenshots come from a dark run (`HQN_PRESENCE_DARK=1`): the appearance is set before each launch | Switching the appearance under the running app did not take on this simulator; every "-dark" file written that way was light |
| D29 | (builder, revised after the review) The install request keeps its short title wherever the chat reads its transcript: at the end of the reply, from its cache when it opens, and when older rows load (`SentTitles`, at most 8). The browser plugin's pair is one fixed prompt and is noted at sign-in, so the title also shows after a relaunch and on a phone that did not send it. A title that came back to the main bot's field (a refused send) goes out again as the request it stands for | The web shows the title only as its own bubble until a reload (`prompt.submit` carries no display text), so the gateway stores the whole prompt. Without this the bubble turned into the long prompt when the reply ended (G1); and after a relaunch it showed the stored prompt, which names the plugin's old wire name, a word the person must never see. The pair is fixed text, so nothing has to be written to disk |
| D30 | (builder) Before the main bot's chat opens, what is presented over the tabs is closed (Bot Info, a sheet under the viewer). A sheet that refuses a swipe down because it holds unsaved edits is never closed: the viewer stays and says `Save or discard what you’re editing, then try again.` under its button; an alert on top gives `Couldn’t open the bot’s chat. Try again.` | The chat opened, and the request was sent, under the sheet: nothing was seen and a second tap sent it twice. The sentence is new wording: the web has no sheets over its chat |
| D31 | (builder) A replayed `tool.start` or `message.complete` changes the Bots row after the 250 ms coalescing gap, never at once | A reconnect replays a finished turn's start and its end in one burst; publishing the start at once made the row flash "Using its computer" for a turn that was over |
| D32 | (builder) No notice while the app is in the background, checked before the gate | The app runs on for a moment after it leaves; a banner raised then was found stale on the return, and stamping its 30 s held back the next real one |
| D33 | (builder) The notice's press and pan are recognised together and a touch that dragged is not a tap; a held capsule stays held when another bot's notice replaces it | With the press waiting for the pan to fail, a resting finger held nothing and the capsule left under it; a replacement restarted the 8 s under a finger |
| D34 | (builder) A caller that joins a `session.resume` already on its way waits until the caller that began it has bound the runtime id (`LiveChatSession.resumeNow`) | Found by S13: the request joined the open's resume, woke before the bind, found no runtime id and was refused with "Couldn’t reach this chat.", four runs in five. Any message sent while a chat is still opening took the same path |
| D35 | (builder) The alert-over-a-viewer UI test installs an interruption monitor that claims the alert and leaves it, and taps the notice by its point on screen | XCTest's own default handler answers an alert that is in the way of a tap (it taps Cancel), which made the test dismiss the very alert the app must leave alone |
| D36 | (repair after stress round 1) The notice's touches are followed by one recognizer and judged once, at the lift, from distance and speed; holds are a set, not a count | With a zero-delay press and a pan running together, `dragged` and the hold count depended on the order their callbacks arrived in. When XCUITest (or a stall) delivered a swipe's first events together, the press could end "not dragged, inside the capsule" and a swipe up opened the viewer (2 of 5 suite runs) |
| D37 | (repair) A finger that has been still on the notice for 30 s no longer holds it; a new finger on the capsule takes over from one still down | Seen with the tester's stalled-swipe trial and a touch log: when the app is stopped as the finger comes down, the lift is sometimes never delivered (the touch stays "stationary" for good). To the app that is a finger resting on the capsule, which by design held it for ever, and the next tap was ignored as a second finger. No real finger rests 30 s on a banner; the longest hold the tests use is 11 s |
| D38 | (repair) A name too long for the notice is shortened so the fixed words always show; a Bots row names a site only for an http(s) address with a host, and otherwise says "Using its browser"; the row's VoiceOver label puts no full stop after a part that already ends its sentence | The tester's three reading minors: a 90-letter name at the largest text hid "is using its browser"; `javascript:alert(1)` and "not a url at all" were repeated raw after "Browsing"; VoiceOver read "Handing you its browser…. Sep 29" |
| D39 | (repair) The 90 s UI timing test brackets the fall-back between the last look that found the line and the first that did not, with the same limits (gone after 89 s, not still there at 94 s) | One look is an accessibility query that takes seconds on a busy Mac (9.6 s seen), so the old single reading (95.3, 96.9, 99.1 s) timed the test's own polling, with the line gone by hand at 92 s |
| D40 | (UX study #135) A browser that asks for the person (`ask` set while the bot has control) raises "<bot> needs you in its browser" with Watch, once per ask, from the plugin's list while anything on screen has it open, and on Sessions and More, where the centre holds the list open itself (`PresenceCenter.setAsksHeard`; the one shared socket, closed in the background). Same gate as the start notice (D5: the bot's switch only, never Mute or Bot Activity Banners), not in the background (D32), not when that bot's chat or viewer is on screen, one notice at a time (D8). Narrows D17 for asks only. No background alert: a suspended app can't hear the list; that needs the push plugin | The owner: bots "own the task until they can't" (MEM bot-owns-signin); the "can't" moment was shown only on the bot's own row and chat card |

---

## 16. Boundaries with other streams

- `screen`: builds the Bot Info Screen row, the row-menu Screen item, the Screen tile and the viewer. It sets
  `BotComputerHooks.screenRow`, `.openScreen` and `.screenIsOpen` (§6.3). Until it does: no Screen row, no "is using
  its screen" notice (D6). L216 counts as done only when the Screen row is on the train too.
- `botslist`: "Waking up…" (L184) and the Bot Info header status (L213) rank in `BotList.rowStatus`; ours sits
  below needs-input. Its "Can’t reach this bot" row-menu state is not this stream's.
- `offline`: owns the offline screen and reconnect toasts and may also edit `GatewayConnection.swift`; our change
  there is three lines in the replay path (§3.4).
- `settings`: L575 (the notification add-on's request is typed, not queued) can adopt `MainBotRequest.queue`.
- `a11y`: owns the reply peek's VoiceOver rows; `PresenceNotice` is a separate view and follows the same rules.
- `talk`, `groups`, `photoheads`: also add to `Bot`, `BotInfoHooks` or the row; our additions are one defaulted
  field on `Bot` and one hook section.

## 17. Lock Screen progress (Live Activity)

Built on branch `feat/revisit-lock-screen`, reviving n20 item F13 (TestFlight build 400, `integrate/n20-r2`), which
needed its own App ID and never shipped. Code: `HermesKit/Live/LiveActivityRules.swift` (the rules),
`App/Live/LiveActivityCenter.swift` (wiring and the ActivityKit driver), `LiveKit/LiveActivityContent.swift` (shared
with both extensions), `TalkActivityWidget/ReplyActivityWidget.swift` (the Lock Screen and Dynamic Island views).
Jobs side: `docs/spec/3x-jobs.md` §12. Owner steps (there are none to take): `docs/owner-todo/live-activity.md`.

**DECISION D41a (revises n20's D41/D47) — one shared extension, no new build flag.** Rather than a target of its own
(`HermesHQLive`, gated by `project-live.yml`/`HQ_LIVE_ACTIVITY=YES`, needing `com.charlesmcdowell.dispatch.live`
registered), this reuses `HermesHQTalkActivity` — the extension Talk's own Live Activity already ships in
(`docs/spec/3x-talk-background.md`) — by vending a second `Widget` from its one `WidgetBundle`. It is embedded, and
`NSSupportsLiveActivities` is already set, under exactly the same condition Talk's already is: the original identity
(`HQ_IDENTITY=original`), never the Mac. `LiveActivityBuild.extensionEmbedded` checks for
`HermesHQTalkActivity.appex` (was `HermesHQLive.appex`). This needed no App ID, no profile, and no `Info.plist`
change — Talk's shipped feature already carries all three.

### 17.1 A long turn

- Each roster change (`AppModel.botsChanged`) tells the planner which bots have a turn running; it notes when it
  first saw each one.
- **DECISION D41:** when the scene resigns active (`sceneWillResignActive`), each turn that has run at least 20 s
  gets an activity: the bot's name, "Working…", a system timer from the turn's start (it moves while the app is
  suspended). iOS starts one only while the app is in front, so this is the last moment. Debug builds shorten the
  20 s with `-HQDebugLiveThreshold <s>`.
- **DECISION D42:** at most 4, the longest-running first.
- [live-chats] (a tester, 2026-11-05) Every chat counts, not only a bot's Bot Chat: a turn in one of its other
  chats (a New Chat, one opened from Sessions, a project's) gets a card of its own, "Otto · Day check" (the bot's name
  and the chat's title), subject id `<profile>/<stored id>`, opening that chat. Its steps are handed to the add-on
  under that chat's stored id, which the add-on already matches by (`LiveFeed.rows`), so no add-on change. The Bot
  Chat's card keeps the bot's profile as its id. `AppModel.liveSideChatsChanged` feeds them from
  `BotStore.busySideChats` (stored ids only: a chat not stored yet counts as the Bot Chat, as on the bot's row).
- When the roster says the turn ended (in the app, or in the socket's 20 s background grace), the activity ends
  "Done" with the time it took. **DECISION D43:** it stays 15 min when the app is away, goes at once when it is in
  front.
- Tapping it opens `<scheme>://session/<id>` (the chat), through the same path as an alert.

### 17.2 The switch

**DECISION D46:** Settings › Notifications › "Show Progress on Lock Screen" (id `notifications.live-activities`),
under Bot Activity Banners, on unless turned off (`UserDefaults` `hq.liveActivities`). Footer: "A bot's long reply,
or a job you run from Jobs, shows on the Lock Screen and in the Dynamic Island with how long it has run, until it's
done. A reply also names the step its bot is on. Your voice chat's own Lock Screen controls aren't affected." (no
"and in the Dynamic Island" on an iPad; the step sentence since §17.6) — the
last sentence is new wording, added here on purpose: this switch and Talk's Lock Screen controls are two different
Live Activities sharing one extension, and nothing about this switch should read as touching Talk. Searchable in
Settings. Off ends every activity at once. The row is hidden when the build has no extension
(`LiveActivityBuild.extensionEmbedded`) and on the Mac. When iOS has Live Activities off for the app, nothing starts
and the switch stays as set.

### 17.3 Ending

**DECISION D44:** the first activation after launch ends every activity this app run does not know (a killed app's
leftovers). Sign-out, a gateway switch (`AppModel.tearDown`) and the switch going off end all of them at once.

### 17.4 Limits, and the one thing softening them

**DECISION D45:** once suspended the app no longer hears the turn end, so the activity keeps "Working…" until the
app is opened; its stale date is 30 min after the last update, and a stale running one adds "· Open to check". This
still holds for a job's run (nothing pushes those). For a bot's turn, `NotificationService.swift` now makes a
best-effort try on the add-on's existing "reply finished" push (`turnDone`, matched by the `profile` field against
the turn's subject — a literal session id isn't in that payload, but the profile id is the same value
`LiveActivitySubject` already keys a turn by): if it can see the matching activity, it ends it Done right there,
before the app reopens. Checked against the installed SDK (`ActivityKit.swiftinterface`): no `@available` exclusion
marks `Activity`, `.activities`, `.update` or `.end` unavailable to an app extension — only the usual
macOS/macCatalyst/tvOS/watchOS platform exclusions, same as the main app. Whether iOS actually shares the activity
across processes is not written down anywhere and can't be exercised in the Simulator (`xcrun simctl push` never
runs the notification extension — `scripts/fixtures/push-gateway.py`'s own comment says so); unverified pending a
real phone. Either way the 30-minute rule is still the fallback, exactly as if the extension had never tried.
Updating a card live from the gateway while the app is fully asleep needs Live Activity pushes: built for a bot's
turn in §17.6 (hermes-hq-push 0.9.22+); a job's card still has none.

### 17.6 The card names the steps (owner, 2026-10-31)

Owner: "on the lock screen little live widget things. Right now it just shows working. And it needs to show the live
tool calls for whatever bot or session it's showing so that you can understand what's going on."

- **DECISION D48 — what a turn's card says.** Header: the bot's name, "· 7 steps" once it has taken one, the timer.
  Main line: the running step in the Bots row's words ("Running npm test…", `ToolNow.phrase` through `LiveSteps`,
  `Bot.step`); "Writing…" after steps when the app heard the reply start; "Working…" before any step (or for a turn the
  app has no step source for — see the Bots row's limits in `HermesKit/Activity/LiveSteps.swift`). Under it, the two
  steps before, small, with a tick. Over: "Done · 7 steps" and its last two steps. The Dynamic Island's expanded view
  shows the main line and one earlier step; compact and minimal are unchanged. A job's card is unchanged.
- **The app's updates.** `LiveActivityPlanner` follows each working bot's step from the turn's start
  (`LiveStepTrail`, newest first, two kept), so a card started on leaving already names the steps before; each change
  of a shown turn's step is an `.update`. These reach the card while the app runs, including the background grace.
- **DECISION D49 — pushes once the app sleeps.** A turn's activity is requested with `pushType: .token` (falling back
  to none if iOS refuses) in a build that can push (`PushRegistrar.available`). Each token goes to the add-on —
  `PUT <route>/live/<device id>/<activity id>` with the token, the bot's profile, its Bot Chat's stored id, the card's
  `startedAt` (Apple reference-date seconds, echoed back) and the trail so far — only when the add-on's status says
  `liveSteps` (0.9.22+). The card ending here sends `DELETE` for it. The add-on pushes each new step
  (`apns-push-type: liveactivity`) and ends the card Done when the turn ends.
- **DECISION D50 — the words stay sealed.** A pushed `content-state` carries only `phase`, `startedAt`, `endedAt` and
  `seal` — the trail as `{"step", "recent", "steps"}` sealed with the same per-account key, box and `kid` as a sealed
  alert (`Shared/PushSeal.swift`). The widget extension opens it (`Shared/LiveStepsSeal.swift`) with the keys it reads
  through its new keychain group (`TalkActivityWidget/HermesHQTalkActivity.entitlements`, the same group
  NotificationService reads; team profiles allow it, no portal change). The relay accepts a liveactivity push only in
  that shape, so it and Apple still see no words. A seal no key here opens falls back to "Working…".
- `NSSupportsLiveActivitiesFrequentUpdates` is on (`App/Info.plist`) for a larger budget of prompt pushed updates.
- Settings' footer gains "A reply also names the step its bot is on."

### 17.7 The card is Liquid Glass (owner, 2026-10-31)

"The lock screen live widget needs to be Liquid Glass not black." Both Lock Screen cards — a reply's or a job's and
Talk's — use `lockScreenGlass()` (TalkActivityWidget/LockScreenGlass.swift):

- **D51 — glass behind the words, not on them.** `.activityBackgroundTint(.clear)` takes the system's black away; a
  `glassEffect(.regular)` layer in `ContainerRelativeShape` sits behind the content. Glass applied to the content itself
  drew the glass and dropped the words (iOS 27 Simulator).
- **D52 — white words, a wash for bright wallpapers.** The Lock Screen draws a Live Activity in its dark style in light
  and dark mode alike, so the words are white (`.colorScheme(.dark)` pins it). The glass's own tint was ignored there
  (`.regular.tint(…)` drew exactly as `.regular`), so a 22 % black wash between glass and words carries the contrast:
  every line ≥ 4.97:1 in light, ≥ 6.31:1 in dark on the default wallpaper (scripts/glass-contrast.swift).
- The Dynamic Island is unchanged: the island itself is black hardware.
- **The island's small views always fit (owner, 2026-11-11: the timer drew "16:0…", cut, beside another app's
  activity).** The compact timer used to sit in a fixed 64 pt box (room for "0:00:00"); when the island offered less,
  the box overflowed and the digits were cut. Now nothing in the island's small views has a fixed width. A running
  timer's range ends where its next digit would appear (`LiveTimerSpan`, LiveKit: "59:59", "9:59:59", "99:59:59" —
  picked so it can't get there before the card is drawn again, by an update or by going stale), so it asks for exactly
  the room its digits take; offered less, it draws smaller (down to half size), never cut. A live timer still
  takes every point it is offered, though, and the island offers a lot: build 948 stretched the island across the
  clock and the status icons (owner: "Should this really be that large?"). So its place is sized by plain hidden
  digits it is laid over (`LiveTimer`, "00:00" / "0:00:00" from `LiveTimerSpan.widest`), and a stopped Talk clock is
  plain text: the island is as wide as the digits and no wider. A finished one says its
  time in short words ("16m", "1h 5m"). Talk's clock is the same. `scripts/island-shots.sh` photographs every shape
  (each timer length, over, Talk, and beside another app's activity — `TestSupport/IslandTwin`) from
  `-HQDebugIsland` (App/Debug/IslandDebugHook.swift): look at the sheet after any change to these views — the island's width as well as its words.

### 17.5 Builds

**DECISION D47 (revises n20's D47):** no `project-live.yml`, no `HQ_LIVE_ACTIVITY` flag. `project.yml` adds
`LiveKit` to three existing targets' sources — `HermesHQNative`, `HermesHQNotifications`, `HermesHQTalkActivity` —
and nothing else changes about how any of them are built. Availability rides entirely on whether
`HermesHQTalkActivity` is embedded, which `project-original.yml` already decides for Talk's sake. Mac Catalyst
compiles every file here (guarded with `#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)` where it
touches ActivityKit, matching `App/Chat/Voice/TalkActivity.swift`'s existing pattern) but shows no switch and starts
nothing (`LiveActivityBuild.extensionEmbedded` is `false` under `targetEnvironment(macCatalyst)`).
