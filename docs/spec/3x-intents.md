# 3x — Siri, Shortcuts, Action Button and Home Screen quick actions

Status: implementation spec for the **intents** stream of run m9 (branch `m9/intents`, worktree
`/Users/me/Projects/hermes-hq-native-wt/m9-intents`). Seven rows of `docs/parity-240.md` §14 (L604–L610; listed
verbatim in `docs/briefs/m9/intents-rows.md`). Scope: the "Record Voice Note" App Intent and its App Shortcut, the two
hidden legacy intents, the durable one-minute request that opens a bot's chat and starts a hands-free memo, the saved
(older-build) voice note and its alert, Home Screen quick actions, the bot catalog the system pickers read, and the
conversation donation behind message-style alerts. **Out:** the memo recorder, its upload and its bubble (done,
`docs/spec/1x-voice.md`); live Talk (stream `m9/talk`); rooms (stream `m9/groups`); a share extension (stream
`m9/share`).

The next stages write `docs/briefs/m9/intents-report.md` and update the outcomes in `docs/briefs/m9/intents-rows.md`.
Do not edit `docs/parity-240.md` or `docs/parity.md`.

## 0. Sources, notation, ground rules

| Prefix | Path | What |
| --- | --- | --- |
| `W:` | `/Users/me/Projects/hermes-hq-native-ref240/` | Reference web app, build 240, and its Swift shell. Read only. |
| `WA:` | `/Users/me/Projects/hermes-hq-native-ref240-archive/Dispatch.xcarchive/Products/Applications/App.app/` | The shipped build-240 app. Read only. `Metadata.appintents/extract.actionsdata` is what iOS knows about its intents. |
| `HA:` | `/Users/me/.hermes/hermes-agent/` | The Hermes server. Read only. Never run it or import it. |
| `NAT:` | `/Users/me/Projects/hermes-hq-native-wt/m9-intents/` | HQ Native, this stream's worktree. |
| `MEM:` | `~/.claude/projects/-Users-me-Projects-hermes-ios/memory/` | Owner history and taste. |
| `SDK:` | Xcode 27's `AppIntents.swiftinterface` (iOS 26/27 SDK) | API facts checked for this spec. |

`<App>` below is `AppIdentity.current.displayName` (`NAT:HermesKit/Net/AppIdentity.swift:26,30`): "Hermes HQ" in the
shipping identity, "HQ Native" in the development identity. Wherever the web says "Hermes HQ" in a sentence built at
run time, native says `<App>`, as the voice spec does (1x-voice V11). `<Bot>` is the bot's display name.

Ground rules that apply to every section:

- Swift 6, default MainActor isolation; network and system-facing value types are `nonisolated` and `Sendable`.
- Only public API. Nothing App Store–risky (`MEM:hermes-hq-native.md`).
- The word "Dispatch" never reaches the user's eyes or ears. Swift type names, UserDefaults keys and quick-action
  `type` strings may contain it (they are identifiers, and §3.2 needs them unchanged).
- This feature sends **nothing new** to the gateway. Params models are `extra="forbid"` (unknown key → error 4000),
  so do not add fields to any existing call (§3.6).
- Never show a control that does nothing; every failure says what happened in words the owner can read.
- No relay, plugin or real-gateway change is needed by any row. There is **no** `docs/owner-todo/intents.md`.

### 0.1 Decisions for this round

Every place where the web's behaviour does not map onto a native app, or where this spec adds to it, is a
**DECISION** below and is marked `DECISION I<n>` where it is used.

| # | Question | DECISION | Why / source |
|---|---|---|---|
| I1 | Do shortcuts saved under the web app keep working? | Yes, by keeping every identifier iOS stored: the Swift type names `RecordVoiceNoteIntent`, `DispatchMemoIntent`, `DispatchOpenBotIntent`, `VoiceNoteBot`, `DispatchBotEntity`, `VoiceNoteBotQuery`, `DispatchBotQuery`; the parameter name `bot`; the entity id formulas; the UserDefaults keys (§3.2). The intents stay in the **app target** (not an extension). | `WA:Metadata.appintents/extract.actionsdata` identifies actions and entities by unqualified type name; the shipping identity keeps bundle id `com.charlesmcdowell.dispatch` (`NAT:project-original.yml`). The module name changed (`App` → `HermesHQNative`) and is not part of the identifier. |
| I2 | `openAppWhenRun` is deprecated in the iOS 26 SDK. | Use `static let supportedModes: IntentModes = .foreground(.immediate)`. If the built metadata or a run shows the app does not come forward, fall back to `static let openAppWhenRun = true` and accept the deprecation warning. | `SDK:` "Please provide 'supportedModes' instead". `W:ios/App/App/VoiceNoteIntent.swift:27` set `openAppWhenRun = true`. |
| I3 | How is "parameters refreshed when bots change" observable? | Call `updateAppShortcutParameters()` whenever the stored bot catalog changes (web behaviour), **and add one parameterized phrase**: "Record a voice note for `<Bot>` in `<App>`" beside the web's phrase. Then Spotlight, the Shortcuts app and the Action Button picker list one entry per bot. If the metadata processor or the simulator's Shortcuts app rejects it, ship only the web's phrase and say so in the report. | Native addition, flagged. The web calls the refresh but has no phrase that uses the parameter (`W:ios/App/App/HermesUIPages.swift:362-366`), so nothing visibly changes. Owner: "voice memos in fewer taps" (`MEM:finish-everything-push.md:36`). |
| I4 | Which bots are offered? | The signed-in gateway's roster only, hidden bots included, at most 512, names cut to 160 characters. Nothing is written while the roster has not loaded. | `W:src/action-voice-runtime.ts:40-45` (non-ghost rows; returns early with no snapshot and no rows). The caps are new and defensive. |
| I5 | Home Screen quick actions were switched off in build 240. | **On** natively. One constant, `QuickActions.enabled = true`; when false the app sets `shortcutItems = []` as the web does. | `W:src/ui-voice/shortcuts.ts:19` (`PHONE_SHORTCUTS` false); `W:docs/app-review/review-notes.md:83`. Owner accepted "D5: memo and open-chat shortcuts now; 'Talk to' after the device check." (`MEM:round9-ui-improvements.md`), and "turn on switched-off features after live QA checks (… Siri/shortcuts)" (`MEM:finish-everything-push.md:112`). The row is assigned to this stream. |
| I6 | "Search Chats" opened the web's command palette. | Opens the **Sessions** tab with its search field focused and empty. | The palette is another stream's row; Sessions search is the native "search chats". |
| I7 | Room targets in quick actions. | Built (UX study #265): the app passes its group chats to `ShortcutCatalogBuilder`'s `extra:` as `room:` targets (by their last message) and the router opens them with `host.openRoom`. A room this gateway no longer has answers "That group chat is no longer available." | Rooms do not exist natively yet (`m9/groups`). `W:src/ui-voice/shortcuts.ts:40-44,92-94`. |
| I8 | Where do shortcut failures show? | A system alert (title + the web's sentence + **OK**), presented over whatever is on top. One at a time: a newer one replaces it; a successful start dismisses it. | The web shows an 8-second warning toast (`W:src/action-voice-runtime.ts:117`). Owner: "I get an error but I can't read what it is. The unreadable error display is itself a bug." (`MEM:finish-everything-push.md:16`). The shortcut may fail before any chat is open, so the chat's memo notice card cannot carry it. |
| I9 | The "Saved voice note" alert is unreachable in build 240. | Build it, with the web's exact words, for the one case it was written for: a shortcut asks to record while a saved voice note from an older build still waits (§8). It never shows for an ordinary memo draft chip. | `W:ios/App/App/VoiceNoteIntent.swift:112,124,139-140`: `requested` is never set, so `presentIfReady` returns before the alert at `:142-152`. The row is assigned; the saved-note recovery it belongs to is live in 240 (`W:src/action-voice-runtime.ts:83-97`). Fast path kept: "voice memos in fewer taps". |
| I10 | Where does a saved older-build note go? | Into its bot chat's composer as the native **memo draft chip** (1x-voice §3.6). It is never sent by itself. | The web attaches it to the composer draft (`W:build/action-voice-gates.ts:9-15`, `W:src/action-voice-draft.ts`). `W:docs/action-button-voice-notes.md`: "It never sends automatically." |
| I11 | Static intent text that names the app. | `IntentDescription` literals keep "Hermes HQ" (one string, on the hidden "Send a Memo to Bot" intent). Sentences built at run time use `<App>`. | Intent metadata is extracted at build time and cannot read the display name. The shipping identity is Hermes HQ. |
| I12 | "Open Bot" always failed in build 240. | It works natively: it opens the bot's chat. | `W:ios/App/App/HermesUIPages.swift:334-344` routes through the quick-action catalog, which 240 kept empty. With I5 the catalog has bots. |
| I13 | Donation of the conversation (L609). | The app donates when it posts a **local** reply or approval alert for a known chat, whether or not the build carries the Communication Notifications entitlement. The notification extension does not donate. | `W:ios/App/App/HermesPlatformExtras.swift:279-284,295-297` donates from the app only. The web gates it on the entitlement; un-gating makes it the same in both identities and checkable in the simulator, and a donation carries no message text. |
| I14 | Sign-out and gateway switch. | Sign-out clears requests, the bot catalog, the quick-action catalog, account and epoch, the Home Screen items, the saved older-build note and its file. Switching to a **different** account clears the same except the saved note (never lose audio). Activating the same account clears nothing. | `W:ios/App/App/HermesNative.swift:1967,1971,2157,2189,2212-2213,2259`. Keeping the note on a switch is native (1x-voice §3.6 "Never loses audio"); the web's own wording expects it: "Sign back in to recover it." |
| I15 | VoiceOver when a shortcut starts the recorder. | Nothing extra is spoken. | 1x-voice §3.8: "post no announcements: a spoken time would end up in the memo". The web's "Recording voice note for …" lives in the dead recorder sheet (`W:VoiceNoteIntent.swift:309`). |
| I16 | A request whose expiry is further away than one minute (edited storage). | Treated as invalid and cleared. | New, defensive. `W:VoiceNoteIntent.swift:76` always writes `now + 60 000`. |
| I17 | Can a bot's chat go on the Action Button or in Spotlight? | Yes: a **new** discoverable intent, `OpenBotChatIntent` "Open Bot Chat" (parameter `bot`, a `VoiceNoteBot` from the same catalog), with an App Shortcut: "Open a bot chat in `<App>`" and "Open `<Bot>` in `<App>`" (one entry per bot, as I3), short title Open Bot Chat, `bubble.left.fill`. It opens through Open Bot's route (`QuickActions.openBot`, this sign-in only) and fails with §5.3's sentence. `DispatchOpenBotIntent` stays hidden (I1, I12). No "Send Message to Bot". If the metadata processor rejects the per-bot phrase, ship only the first. **Amended 2026-11-08 (tester, owner said build it):** `AskBotIntent` "Ask Bot" (`App/Intents/AskBotIntent.swift`): parameters `bot`, `message`, `files`, `waitForReply` (default on); `supportedModes = .background`; sends through `ShareSender` to the bot's Bot Chat from `AskRoster` (a `ShareRoster` in the app's own defaults, both identities), waits up to 120 s for the turn end (`ShareReplyWatch`) and returns its text; a question from the bot, an error or no answer in time is a thrown, plain-words error. App Shortcut "Ask `<Bot>` in `<App>`", short title Ask Bot, `paperplane.fill`. | Native addition, flagged (UX study 2026-10-19 #146: the only App Shortcut was Record Voice Memo). Build 240 has no such action, so `compare-intents-metadata.py` lists it as an allowed addition. |

### 0.2 Rows to sections

| Row | What | Sections |
|---|---|---|
| L604 | "Record Voice Note" intent, Bot parameter, App Shortcut phrase | §5, §7 |
| L605 | Hidden legacy intents "Send a Memo to Bot" and "Open Bot" | §6 |
| L606 | "Saved voice note" alert | §8 |
| L607 | Home Screen quick actions, per-account guard | §9 |
| L608 | App Shortcut parameters refreshed when bots change | §4 |
| L609 | INSendMessageIntent donation and continuation | §10 |
| L610 | Opens the bot chat, hands-free memo, one acknowledged request, old recordings recoverable | §7, §8 |

## 1. What the owner approved (quote these, never contradict them)

- **Shortcuts are wanted.** "D5: memo and open-chat shortcuts now; "Talk to" after the device check."
  (`MEM:round9-ui-improvements.md:29`, all D1–D7 defaults accepted). No "Talk to" action in this stream.
- **Switched-off features come on after QA.** "turn on switched-off features after live QA checks (…
  Siri/shortcuts)" (`MEM:finish-everything-push.md:112`). This run's stress stage is that QA (DECISION I5).
- **Fewer taps.** The owner asked for "voice memos in fewer taps" (`MEM:finish-everything-push.md:36`).
- **A memo must never land in another bot.** "slide to cancel doesn't work; a sent memo was missing after visiting
  another bot" (`MEM:voice-memo-bugs.md:11`). The take's chat is frozen when it starts; a shortcut records only in the
  chat it named, or not at all (§7.3).
- **Readable errors.** "I get an error but I can't read what it is. The unreadable error display is itself a bug."
  (`MEM:finish-everything-push.md:16`). Hence DECISION I8.
- **One feature at a time.** "I also want to do one feature at a time now, not a ton at once"
  (`MEM:feedback-one-feature-at-a-time.md`). This stream is one feature; its seven rows ship together or are
  reported apart, row by row.
- **Nothing App Store–risky.** "We can't do something that could stop apple from approving us."
  (`MEM:native-composer.md:11`). Public App Intents, UIKit and Intents API only.
- **Never "Dispatch".** "it is "Hermes HQ", never "Dispatch" in anything user-facing"
  (`MEM:hermes-hq-native.md:98`).
- **Hermes is not ours.** "We can't make any changes to hermes agent code since we don't control it."
  (`MEM:hermes-code-not-ours.md:8`). Everything here is phone-side.
- **Native glass only, original robot heads, plain words.** Nothing in this stream draws custom chrome: the only new
  surfaces are system alerts and system pickers.

## 2. What build 240 does (the facts this port rests on)

1. **Record Voice Note.** `RecordVoiceNoteIntent` (`W:ios/App/App/VoiceNoteIntent.swift:24-37`): title "Record Voice
   Note"; description "Open your selected bot’s chat and start recording a voice note."; opens the app; one parameter
   `bot` titled "Bot" of entity `VoiceNoteBot`; summary "Record a voice note for `<bot>`". `perform()` looks the bot up
   in the stored catalog by id; missing → throws "Open Hermes HQ to refresh your bots, then choose a bot in this
   shortcut." (`:38-41`); found → writes a request (`:117-121`).
2. **App Shortcut.** `DispatchAppShortcuts` (`W:ios/App/App/HermesUIPages.swift:362-366`): one shortcut for
   `RecordVoiceNoteIntent`, phrase "Record a voice note in `<application name>`", short title "Record Voice Note",
   symbol `mic.fill`. `WA:` confirms: `isDiscoverable` true, one auto-shortcut phrase.
3. **The request.** `VoiceNoteRequestStore` (`W:VoiceNoteIntent.swift:50-83`): one JSON value at
   `dispatch.voice.request` `{id, account, key, name, expiresAt}`; `expiresAt = now + 60 000 ms`; reading an expired
   one clears it; `acknowledge(id)` clears only when the id matches (a newer request survives an old acknowledgement).
4. **The runtime** (`W:src/action-voice-runtime.ts:33-130`): one delivery at a time; a request is launched once; the
   bot's chat is opened from the Bots list; the newest request wins; recording starts through the chat's own mic
   (`startMemoIn`, `W:src/ui-voice/entry-live.ts:59-70`: waits up to 5 s for the composer) in the locked, hands-free
   state; the request is **always** acknowledged, success or failure (`:76-80`: "A failed shortcut must not
   spontaneously record on a later foreground event."). Deliveries are triggered by a new request, by the app coming
   to the foreground, and at start-up (`:124-128`).
5. **Bot catalog.** The renderer pushes `{account, bots:[{key, name}]}` on every roster change (`:40-45,126`); the
   shell stores `[VoiceNoteBot]` at `dispatch.voice.bots` with `id = base64(account + "\n" + key)` and calls
   `updateAppShortcutParameters()` (`W:VoiceNoteIntent.swift:188-198`). `account = url + "\n" + username` (`:35`);
   `key = "ios-direct::" + profile` on the phone (`W:vendor/hermes/apps/desktop/src/plugins/hermes-bots/data.ts:1286-1288`,
   `W:src/action-voice-runtime.test.ts:3,43`).
6. **Legacy intents** (`W:HermesUIPages.swift:316-361`): `DispatchMemoIntent` "Send a Memo to Bot" and
   `DispatchOpenBotIntent` "Open Bot", both `isDiscoverable = false`, parameter `bot` of `DispatchBotEntity` whose id
   is `epoch + ":bot:" + key`. The memo intent resolves that id against the voice catalog inside the same sign-in
   epoch and account (`DispatchShortcutPolicy.legacyMemoBotKey`, `:193-200`) and then uses the same request queue.
   Failure text: "Open Hermes HQ and choose the bot again. This shortcut is no longer available." (`:358-361`).
7. **Saved voice note.** Builds 26–28 recorded in a native sheet and stored `{id, bot, path}` at
   `dispatch.voice.pending` (`W:VoiceNoteIntent.swift:42-46,95-98`). Build 240 no longer shows the sheet; the
   renderer recovers such a note quietly into its bot chat's draft on a foreground with no request
   (`W:src/action-voice-runtime.ts:83-97,106-112`). The alert "Saved voice note" (`W:VoiceNoteIntent.swift:142-152`)
   is dead code (DECISION I9).
8. **Quick actions** (`W:HermesUIPages.swift:178-315`, `W:src/ui-voice/shortcuts.ts`): off in the release (DECISION I5). When
   on: a catalog of up to 128 targets (bots, listed chats that are not a bot's own chat, rooms) sorted by last
   activity or visit; items "New Voice Memo for `<first bot>`" (`mic`), "Open `<target>`" for the first two targets
   (`bubble.left`), "Search Chats" (`magnifyingglass`); each item carries `{id, epoch}`; the epoch is a UUID made when
   the signed-in account's digest changes, so items from an earlier sign-in are refused.
9. **Donation** (`W:ios/App/App/HermesPlatformExtras.swift:270-299`): when an alert is dressed as a message from the
   bot, the app also donates an `INInteraction` (incoming, the same people and conversation id, **no message text**),
   not waited for. A donated conversation that the system hands back opens that chat
   (`W:ios/App/App/HermesViewController.swift:668-677,711`). `W:ios/App/App/Info.plist:65-68` lists
   `INSendMessageIntent` under `NSUserActivityTypes`. Sign-out deletes every donation (`:299`).

Not ported, on purpose: the recorder sheet `VoiceNoteRecorder` and its strings (`W:VoiceNoteIntent.swift:223-348`,
unreachable); the `stage3` debug bridge (`:350-405`); the Capacitor plugins that carry these values to the renderer;
`W:build/action-voice-gates.ts` (it patches the vendored web composer; natively the draft store does that job).

## 3. Native architecture

### 3.1 Files (new unless marked)

```
HermesKit/Intents/
  VoiceNoteRequestStore.swift   VoiceNoteRequest, VoiceNoteRequestStore (nonisolated; UserDefaults)
  VoiceBotCatalog.swift         VoiceBotRecord, PendingVoiceNote, VoiceBotCatalog (nonisolated; UserDefaults; ids; resolve)
  ShortcutPolicy.swift          ShortcutTarget, ShortcutPolicy (accountDigest, legacyMemoBotKey, catalog, permits)
  ShortcutCatalogBuilder.swift  pure: bots + sessions + visits (+ extra) -> [ShortcutTarget]
  LegacyNoteFile.swift          pure: resolves an older-build note's path inside this app's container, or nil
  IntentsText.swift             every sentence in §5–§10, as functions of <App> / <Bot>
App/Intents/
  VoiceNoteIntents.swift        VoiceNoteBot, VoiceNoteBotQuery, RecordVoiceNoteIntent, VoiceNoteError, HQAppShortcuts
  LegacyIntents.swift           DispatchBotEntity, DispatchBotQuery, DispatchOpenBotIntent, DispatchMemoIntent, DispatchShortcutError
  IntentsRuntime.swift          the single-flight runtime (deliver / launch / open / startMemo / recover), IntentsHost protocol
  LiveIntentsHost.swift         IntentsHost over AppModel, MainTabController, MemoController
  IntentsNotice.swift           the one alert (DECISION I8) and the "Saved voice note" alert (§8)
  QuickActions.swift            Home Screen items, perform, route
  AppModel+Intents.swift        catalog sync, account/epoch, sign-out reset, visits
  IntentsDebugHooks.swift       #if DEBUG (§12.3)
Shared/PushFaces.swift          EDIT: + donation(...) builder (§10)
App/Notifications/NotificationHub.swift   EDIT: donate in post (§10)
App/AppDelegate.swift           EDIT: scene(_:continue:), windowScene(_:performActionFor:), cold-launch options (§9.4, §10.3)
App/AppModel.swift              EDIT: six one-line calls tagged `// [intents]` (§3.5)
App/Sessions/SessionsViewController.swift  EDIT: + openSearchFromShortcut() (§9.5)
scripts/fixtures/intents-gateway.py, scripts/e2e-intents.sh   (§12)
scripts/fixture-support/compare-intents-metadata.py           (A1: built metadata against the build-240 archive)
Tests/Intents/*.swift, UITests/intents/IntentsEndToEndTests.swift   (§13)
docs/ARCHITECTURE.md            EDIT: a short "Siri, Shortcuts and quick actions (m9/intents)" section at the end
```

XcodeGen picks the new folders up (`project.yml` sources `App`, `HermesKit`, `Shared`, `Tests`, `UITests`). Both
`project.yml` and `project-original.yml` must keep building: run `scripts/build.sh build <udid>` and
`HQ_IDENTITY=original scripts/build.sh build <udid>`. `Shared/` is also compiled into the notification extension:
keep `PushFaces.donation` free of UIKit and of app types.

### 3.2 Stored values (same keys, same JSON as build 240; `UserDefaults.standard`; DECISION I1)

| Key | JSON | Written by |
|---|---|---|
| `dispatch.voice.bots` | `[{"id","name","key","account"}]` | catalog sync (§4) |
| `dispatch.voice.request` | `{"id","account","key","name","expiresAt"}` (ms since 1970) | the intents (§5, §6) |
| `dispatch.voice.pending` | `{"id","bot":{"id","name","key","account"},"path"}` | builds 26–28 only; native only reads and clears it (§8) |
| `dispatch.shortcut.catalog` | `[{"id","name","kind","sessionId"?,"botKey"?,"group"?}]` | quick actions (§9) |
| `dispatch.shortcut.account` | hex SHA-256 of `url + "\u{0}" + username` | account activation (§9.1) |
| `dispatch.shortcut.epoch` | a UUID string | account activation (§9.1) |

Formulas (do not change one character):

- `account = stored.url + "\n" + stored.username` (`StoredAccount`, `NAT:HermesKit/Net/SavedAccounts.swift:78-83`;
  Nous accounts: `username` is `"nous:" + user id`).
- `key = "ios-direct::" + bot.id` (`Bot.id` is the profile name, `NAT:HermesKit/Contracts.swift:165`).
- `VoiceNoteBot.id = Data((account + "\n" + key).utf8).base64EncodedString()`.
- `DispatchBotEntity.id = epoch + ":bot:" + key`.
- Quick-action target ids: `epoch + ":" + "bot:" + key`, `epoch + ":" + "session:" + storedSessionId`.

Example (invented values): url `http://127.0.0.1:9920`, username `voice-fixture`, profile `ivy` → account
`"http://127.0.0.1:9920\nvoice-fixture"`, key `"ios-direct::ivy"`, id
`base64("http://127.0.0.1:9920\nvoice-fixture\nios-direct::ivy")`.

**Carry-over from the web app (shipping identity only).** The web app's values are already in these keys when the
native build replaces it. Two defences so a small difference in how the address is written does not orphan a saved
shortcut:

1. *Entity resolution.* `VoiceBotCatalog.resolve(id:)`: exact id match first. Otherwise decode the base64, split at
   the first and second `"\n"` into url, username and key, and match a catalog bot whose key is equal and whose
   `GatewayAddress.accountKey(url:username:)` (`NAT:HermesKit/Net/GatewayAddress.swift:55`) equals the decoded one's.
   The entity handed back to the system keeps the **requested** id (the system matches on it) with the current name.
2. *Epoch.* On activation, before deciding the account changed, compare the stored digest with the digests of the
   current url as stored, with and without a trailing "/", and with the host lower-cased. Any match keeps the stored
   digest and epoch (legacy entity ids embed the epoch).

### 3.3 App Intents under default MainActor isolation (load-bearing)

`SDK:` facts: `AppIntent`, `EntityQuery` and `AppShortcutsProvider` are `Sendable`; `AppEntity.ID` must be
`Sendable`; the system calls queries off the main thread; `openAppWhenRun` is deprecated in favour of
`supportedModes`; an intent's stored identifier defaults to its unqualified type name.

- Declare every intent, entity, query, error and provider type **`nonisolated`**. Use `static let` (never
  `static var`) for stored statics. Mark `perform()` `@MainActor`.
- Queries read `VoiceBotCatalog` (a `nonisolated enum` over `UserDefaults.standard`, which is thread-safe). They
  never touch `AppModel`.
- Do not mark app types that hold UIKit state `@unchecked Sendable` to quiet the compiler.

```swift
nonisolated struct VoiceNoteBot: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bot")
    static let defaultQuery = VoiceNoteBotQuery()
    let id: String, name: String, key: String, account: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
nonisolated struct VoiceNoteBotQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VoiceNoteBot] { identifiers.compactMap { VoiceBotCatalog.resolve(id: $0).map(VoiceNoteBot.init) } }
    func suggestedEntities() async throws -> [VoiceNoteBot] { VoiceBotCatalog.bots().map(VoiceNoteBot.init) }
}
nonisolated struct RecordVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note"
    static let description: IntentDescription? = IntentDescription("Open your selected bot’s chat and start recording a voice note.")
    static let supportedModes: IntentModes = .foreground(.immediate)          // DECISION I2
    @Parameter(title: "Bot") var bot: VoiceNoteBot
    static var parameterSummary: some ParameterSummary { Summary("Record a voice note for \(\.$bot)") }
    @MainActor func perform() async throws -> some IntentResult { … }        // §5.2
}
nonisolated struct HQAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordVoiceNoteIntent(),
                    phrases: ["Record a voice note in \(.applicationName)",
                              "Record a voice note for \(\.$bot) in \(.applicationName)"],   // DECISION I3
                    shortTitle: "Record Voice Note", systemImageName: "mic.fill")
    }
}
```

`scripts/build.sh` filters `appintentsmetadataprocessor` lines out of what it prints. Read
`build/last-build.log` for that tool's warnings and errors after every change to these types.

### 3.4 The runtime and its host

`IntentsRuntime` (main actor, one shared instance) holds only: `busy`, `again`, `latestRequestId`, `started:
Set<String>`, `foreignNoteShown: Bool`. Everything it needs from the app comes through one protocol, so the unit
tests run it with a fake (the port of `W:src/action-voice-runtime.test.ts`):

```swift
@MainActor protocol IntentsHost: AnyObject {
    var account: String? { get }                      // "url\nusername" of the signed-in account; nil when signed out
    var isActive: Bool { get }                        // UIApplication.shared.applicationState == .active
    var isReady: Bool { get }                         // signed in and the tab root is in a window
    var rosterLoaded: Bool { get }
    func bot(forKey key: String) -> Bot?
    func refreshRoster() async                        // one read; returns when it answered or failed
    func openBotChat(_ bot: Bot) async -> IntentsChat?    // nil: the chat did not come on screen within 3 s
    var takeInProgress: (key: String?, active: Bool) { get }   // MemoController: phase != .idle, and its bot key
    func now() -> Double                              // ms since 1970
    func sleep(ms: Int) async
    func show(_ notice: IntentsNoticeContent)         // DECISION I8
    func dismissNotice()
}
@MainActor protocol IntentsChat: AnyObject {
    var botKey: String? { get }                       // "ios-direct::<profile>" for a bot's own chat, else nil
    var isTop: Bool { get }                           // still the top screen of the selected tab, in a window
    var composerReady: Bool { get }                   // ChatVoiceHost.isAvailable && canSendMemo
    var scope: String { get }                         // the memo draft store's key
    func beginHandsFreeMemo()                         // ChatViewController.beginMemo(handsFree: true)
}
```

`LiveIntentsHost.openBotChat`:

1. If the top screen of the selected tab is already this bot's own chat, use it.
2. Else: `root.presentedViewController?.dismiss(animated: false)` (as `openNotifiedChat` does,
   `NAT:App/Notifications/AppModel+Notifications.swift:262`), select tab 0, pop its stack to the root without
   animation, `botsViewController.open(bot.id)` (`NAT:App/Bots/BotsViewController.swift:548`).
3. Poll every 100 ms, at most 3 s, for a `ChatViewController` on top of the Bots stack that is in a window with no
   transition running (the rule in `NAT:App/Integration/M2Wiring.swift:73-83`; that helper is private, so write this
   one in `LiveIntentsHost`, do not edit `M2Wiring`). While no chat is on top, call `open(bot.id)` again every
   300 ms: on a cold launch the list may not have applied its rows yet, and `open` ignores a call while its own push
   is waiting (`NAT:App/Bots/BotsViewController.swift:548-560`).

The quick-action router (§9.4) and the "Open Bot" intent use the same `busy` gate, so a quick action, an intent and
a foreground event can never interleave.

### 3.5 Integration points (all one-liners that call into `App/Intents/`)

| Where | Call | Why |
|---|---|---|
| `AppModel.activate(_:)` after `notificationsDidActivate` (`NAT:App/AppModel.swift:221`) | `intentsDidActivate(account)` | account digest and epoch (§9.1); clear a catalog that belongs to another account; first sync; first delivery |
| `AppModel.botsChanged()` (`:396`) | `intentsListsChanged()` | bot catalog (§4) and quick-action catalog (§9.2) |
| where `sessionStore.onChange` is handled | `intentsListsChanged()` | quick-action catalog |
| `AppModel.chatOpened(_:fresh:)` (`:553`) | `intentsVisited(chat)` | quick-action order (§9.2) |
| `AppModel.appDidBecomeActive()` (`:359`) | `IntentsRuntime.shared.deliver()` | the web's foreground trigger |
| `AppModel.finishSignOut()` (`:192`) | `intentsSignedOut()` | DECISION I14 |
| `SceneDelegate.scene(_:willConnectTo:)` (`NAT:App/AppDelegate.swift:94-99`) | add `connectionOptions.userActivities` (a valid conversation) and a pending voice request to the reasons **not** to reopen the last chat; hand `shortcutItem` and `userActivities` on | §9.4, §10.3 |
| `SceneDelegate` | `windowScene(_:performActionFor:completionHandler:)`, `scene(_:continue:)` | §9.4, §10.3 |

`AppModel.tearDown` is **not** a reset point: it also runs on every launch, and a reset there would drop the request
that launched the app.

### 3.6 Wire calls

None are added. What the feature exercises, all existing and unchanged:

| When | Call | Owner |
|---|---|---|
| The runtime refreshes the roster once for an unknown bot | `profiles.list` `{"include_sessions": false}` then `{}` (`NAT:HermesKit/Store/BotStore.swift:345,610,669`) | spec 02 |
| The bot's chat opens | the chat-open reads of spec 03 (`session.resume` and history for the bot's own chat) | spec 03 |
| The user sends the memo the shortcut started | `GET /api/config?profile=`, `GET /api/files?profile=`, `POST /api/files/upload-stream?profile=`, `file.attach {"session_id","profile","name","path"}`, `DELETE /api/files?profile=`, `POST /api/audio/transcribe?profile=`, `prompt.submit {"session_id","profile","text"}` | 1x-voice §4.2 |
| "Open `<chat>`" for a listed chat | the same open as a tapped alert (`openNotifiedChat`) | m6 notifications |

`ProfilesListParams {profile?, include_sessions?}`, `SessionResumeParams`, `PromptSubmitParams` and the rest are
`extra="forbid"` (`HA:tui_gateway/contracts`): this stream adds no key to any of them. The shortcut's account, key,
epoch and request id never leave the phone.

## 4. Row L608 — the bot catalog, and refreshing App Shortcut parameters

**Web:** §2 item 5.

**Native.** `AppModel.intentsListsChanged()`:

1. If no account, or `bots.isEmpty && !botsLoaded` → return (DECISION I4; never wipe the catalog while the roster is loading).
2. Build `[VoiceBotRecord]` from `bots` in roster order: `name` = `Bot.name` cut to 160 characters (never empty: an
   empty name falls back to "Hermes" for `default`, else the profile name), `key`, `account`, `id` per §3.2. Cap 512.
3. `VoiceBotCatalog.store(_:)` encodes and writes **only if the bytes differ** from what is stored. On a change it
   calls `HQAppShortcuts.updateAppShortcutParameters()`, at most once a second (the last change always gets its
   call), and logs `AppLog.note("intents", "shortcut bots: <n>")`.
4. Schedule the quick-action catalog (§9.2).

`intentsDidActivate`: if the stored catalog's first record has a different account (compared with
`GatewayAddress.accountKey`), empty it first (`W:HermesNative.swift:1967`).

**States.** No screen of ours. What the owner sees is in the system's pickers:

| Where | What |
|---|---|
| Shortcuts › Record Voice Note › **Bot** | every bot of the signed-in gateway, by display name; the list is right even if the app was not opened since the last roster change it saw |
| Shortcuts › `<App>` tile, Spotlight, Settings › Action Button › Shortcut › `<App>` | "Record Voice Note", and (DECISION I3) one entry per bot |
| After a rename, a new bot or a deleted bot | the pickers follow once the app has seen the new roster (it reads it on launch, on foreground and on its normal cadence) |
| Signed out | the pickers are empty; a saved shortcut answers with the sentence in §5.3 |

**Fixture:** command C1 (§12.2) for rename and removal (`/__fixture/intents`); C2 for five bots and a removal
(`/__restore/remove-bot`).

**Acceptance:** A8–A11 (§13).

## 5. Row L604 — "Record Voice Note" and its App Shortcut

### 5.1 What the system shows (exact)

| Thing | Text |
|---|---|
| Action title | Record Voice Note |
| Action description | Open your selected bot’s chat and start recording a voice note. |
| Parameter | Bot |
| Summary | Record a voice note for `<Bot>` |
| Entity type name | Bot |
| App Shortcut phrases | "Record a voice note in `<App>`"; (DECISION I3) "Record a voice note for `<Bot>` in `<App>`" |
| App Shortcut short title, symbol | Record Voice Note, `mic.fill` |

### 5.2 `perform()`

```
guard let selected = VoiceBotCatalog.resolve(id: bot.id) else { throw VoiceNoteError.unavailableBot }
VoiceNoteRequestStore(defaults: .standard).enqueue(account: selected.account, key: selected.key, name: selected.name)
IntentsRuntime.shared.requestArrived()        // → deliver(); a no-op until the app is on screen and signed in
return .result()
```

The request is durable, so it does not matter whether `perform()` runs before or after the scene connects on a cold
launch: delivery is attempted on `requestArrived`, on every `appDidBecomeActive`, and when the account activates.

### 5.3 States

| Situation | What the owner sees |
|---|---|
| Bot in the catalog, app signed in | `<App>` comes forward on the Bots tab, the bot's chat opens, and the composer shows the locked (hands-free) recorder already recording (1x-voice §3.5). From here it is the ordinary recorder: Stop, review, Send, or leave it and it becomes that chat's draft. |
| Bot not in the catalog (deleted, signed out, another gateway's shortcut after a sign-out) | The Shortcuts app or Siri shows the intent's error: "Open `<App>` to refresh your bots, then choose a bot in this shortcut." Nothing is recorded. |
| Siri phrase without a bot | Siri asks for the Bot and lists the catalog (system behaviour). |
| Anything after the request was written | §7.4. |

**Fixture:** C1. **Acceptance:** A1–A7, A12–A20.

## 6. Row L605 — the hidden legacy intents

Kept so shortcuts made with builds 26–28 keep running. Both have `static let isDiscoverable = false`, so neither
shows in the Shortcuts action list or in Spotlight; they only run from a shortcut that already contains them.

| | `DispatchMemoIntent` | `DispatchOpenBotIntent` |
|---|---|---|
| Title | Send a Memo to Bot | Open Bot |
| Description | Opens the chat and starts a voice memo. You review or send it in Hermes HQ. (DECISION I11) | none |
| Parameter | `bot`, titled "Bot", entity `DispatchBotEntity` | the same |
| Opens the app | yes (DECISION I2) | yes |
| `perform()` | `guard let selected = legacyBot(bot.id) else { throw DispatchShortcutError.unavailable }`, then the same enqueue and `requestArrived()` as §5.2 | `guard await QuickActions.route("open", id: bot.id, epoch: nil) else { throw DispatchShortcutError.unavailable }` (§9.4) |
| Error | "Open `<App>` and choose the bot again. This shortcut is no longer available." | the same |

`DispatchBotEntity {id, name}`: type name "Bot", title `name`. `DispatchBotQuery: EntityStringQuery`:
`suggestedEntities()` = for each catalog bot, `id = epoch + ":bot:" + key`, kept only if `legacyBot(id)` resolves;
`entities(for:)` filters those by id; `entities(matching:)` filters by
`name.localizedCaseInsensitiveContains(string)` (`W:HermesUIPages.swift:323-333`).

`legacyBot(id)` = the catalog bot whose `key` equals
`ShortcutPolicy.legacyMemoBotKey(id:epoch:botAccount:currentAccountDigest:)`: the id must start with the current
epoch + `":bot:"`, the bot's account must hash to the stored account digest, the key must be 1–512 characters. Never
match by display name (`W:HermesUIPages.swift:191-200`).

**States:** as §5.3 with the error sentence above. "Open Bot" on success: the bot's chat opens, nothing records
(DECISION I12: in build 240 it could only fail).

**Fixture:** C1. **Acceptance:** A21–A23.

## 7. Row L610 — one request, the bot's chat, a hands-free memo

### 7.1 `VoiceNoteRequestStore` (port exactly; `nonisolated final class`, injectable `defaults` and `now`)

- `pending`: decode; if `expiresAt <= now()` **or** `expiresAt > now() + 60_000` (DECISION I16) → `clear()` and nil.
- `enqueue(account:key:name:)`: a new UUID id, `expiresAt = now() + 60_000`, replaces any earlier request.
- `acknowledge(id)`: clears only if `pending?.id == id`.
- `clear()`.

### 7.2 `deliver(explicitRecovery: Bool = false)` (port of `W:src/action-voice-runtime.ts:98-121`)

```
guard host.isActive else { return }                              // the next appDidBecomeActive delivers
guard store.pending != nil || VoiceBotCatalog.pendingNote() != nil else { return }
if busy { again = true; if let id = store.pending?.id { latestRequestId = id }; return }
busy = true; var legacy = false
defer { busy = false; if again { again = false; Task { await deliver() } } }
// A cold launch: sign-in is being restored and the tabs are not on screen yet. Wait for them here, at most 10 s
// (100 ms steps; stop early if the app leaves the screen). Not ready → return quietly: the request stays until
// its minute passes and the next trigger tries again. (The sign-in form showing ends this way.)
guard await ready(within: 10) else { return }
do {
  if let request = store.pending {
     latestRequestId = request.id
     if let note = savedNote(sameAccountAs: request) { askAboutSavedNote(note, request); return }     // §8.2
     try await launch(request)
  } else {
     if (!started.isEmpty && !explicitRecovery) || host.takeInProgress.active { return }
     if let note = VoiceBotCatalog.pendingNote() { legacy = true; try await recover(note) }           // §8.3
  }
} catch { show the failure (§7.4; legacy: §8.4) }
```

### 7.3 `launch(request)` (port of `:59-81`)

```
if started.contains(request.id) || request.expiresAt <= host.now() { store.acknowledge(request.id); return }
defer { store.acknowledge(request.id) }                       // always: a failed shortcut never records later
if host.takeInProgress.active {
   if host.takeInProgress.key == request.key { return }      // already recording for this bot: leave it running
   throw "Finish the current voice note before starting another."
}
let chat = try await open(request)
if let id = store.pending?.id { latestRequestId = id }
guard store.pending?.id == request.id else { return }         // a newer request replaced this one
let allowed = { latestRequestId == request.id && host.isActive && host.now() < request.expiresAt
                && chat.isTop && chat.botKey == request.key }
guard allowed() else { throw "Recording was canceled because the selected chat is no longer active. Run the shortcut again." }
try await startMemo(in: chat, allowed: allowed)
started.insert(request.id); host.dismissNotice()
```

`open(destination)` (port of `:46-58`):

```
guard destination.account == host.account (compared with GatewayAddress.accountKey) else
   throw "This shortcut belongs to another account or to another computer running Hermes. Choose your bot again in Shortcuts."
var bot = host.bot(forKey: destination.key)
if bot == nil { if !host.rosterLoaded { wait for it, at most 10 s }; await host.refreshRoster(); sync the catalog; bot = host.bot(forKey:) }
guard let bot else throw "“<destination.name>” is unavailable. Reconnect to the computer running Hermes and try again."
guard let chat = await host.openBotChat(bot) else throw "Couldn’t open the selected bot’s chat. Reconnect and try again."
guard chat.botKey == destination.key else throw "The selected bot’s chat changed before recording could start."
```

`startMemo(in:allowed:)` (port of `W:src/ui-voice/entry-live.ts:59-70`): every 100 ms for at most 5 s — if
`!allowed()` throw "Recording was canceled because the selected chat is no longer active."; if `chat.composerReady`
→ `chat.beginHandsFreeMemo()` and return. After 5 s throw "The message field isn’t ready, so the voice memo didn’t
start. Wait for the chat to connect, then try again."

Rules that follow from the above and must hold (they are the row's words):

- **Only one acknowledged request.** One request is stored; a newer one replaces it; each request starts at most one
  take; it is acknowledged whether it started or failed; an acknowledgement for an older id leaves a newer request
  alone; a request older than a minute does nothing.
- **Never in another bot.** The take starts through the chat's own `beginMemo(handsFree:)`, so its target is frozen
  to that chat (1x-voice C3). If the chat on top is not the requested bot's own chat at the instant of starting, no
  take starts.
- **It never sends by itself.**
- Text already typed in that chat's field stays where it is (the recorder replaces the row's contents, not the
  draft). Text typed in another chat stays that chat's draft.
- Microphone permission and recorder failures are the recorder's own notices (1x-voice §3.7), in the chat.

### 7.4 Failure alert (DECISION I8)

Title **Couldn’t Start the Voice Note**; message = the sentence thrown, verbatim; one button **OK**. Any error that
is not one of ours shows "The voice note could not start. Run the shortcut again." A warning haptic as it shows.
`accessibilityIdentifier` `intents.notice`.

| Thrown when | Message |
|---|---|
| The request's account is not the signed-in one | This shortcut belongs to another account or to another computer running Hermes. Choose your bot again in Shortcuts. |
| The bot is not on the roster after one refresh | “`<Bot>`” is unavailable. Reconnect to the computer running Hermes and try again. |
| The chat did not come on screen in 3 s | Couldn’t open the selected bot’s chat. Reconnect and try again. |
| Another chat is on top instead | The selected bot’s chat changed before recording could start. |
| A take is running in a different chat | Finish the current voice note before starting another. |
| The chat was left, the app left the screen, or the minute passed before the start | Recording was canceled because the selected chat is no longer active. Run the shortcut again. |
| The chat was left while waiting for the field | Recording was canceled because the selected chat is no longer active. |
| The field was not ready within 5 s | The message field isn’t ready, so the voice memo didn’t start. Wait for the chat to connect, then try again. |
| Anything else | The voice note could not start. Run the shortcut again. |

Silent on purpose (web parity): an expired request; a request already started; a request superseded by a newer one;
a second press for the bot that is already recording; a request that arrives while the sign-in form shows (it
expires).

**Fixture:** C1 (two bots, the memo pipeline, `/__fixture/voice-state` for the exactly-once proof,
`/__fixture/intents` for delays, failures and roster changes). **Acceptance:** A12–A20.

## 8. Rows L606 and L610 — the saved older-build voice note and its alert

### 8.1 What can be waiting

`dispatch.voice.pending` = `{id, bot:{id,name,key,account}, path}` from builds 26–28. `LegacyNoteFile.resolve(path)`:
the path must be absolute with no `..` component; keep only what follows `/Library/Application Support/HermesAttachments/`
or `/Library/Caches/HermesAttachments/` and look for it under this install's own two folders (iOS can move the
container in an update; `W:ios/App/App/PickedFiles.swift:36-50`). The resolved file must exist, lie inside one of
those folders after resolving symlinks, and be 1 byte to 32 MiB. Anything else → nil.

A note whose file does not resolve is not recoverable: clear the key, `AppLog.note("intents", "saved note gone")`,
show nothing.

### 8.2 The alert (DECISION I9: shown only in `deliver`, when a request and a resolvable note of the **same account** both wait)

| | |
|---|---|
| Title | Saved voice note |
| Message | Your note for `<note.bot.name>` is waiting to be added to its chat. |
| **Open chat** (default) | acknowledge the request; `recover(note)` (§8.3). Nothing records. |
| **Discard and record** (destructive) | delete the note's file, clear the key, enqueue a fresh request for the requested bot (a new minute), `deliver()`. |
| **Cancel** | acknowledge the request. The note stays and is recovered quietly on a later foreground (§8.3). |

While the alert is up `busy` is released; the request is acknowledged or replaced by the chosen button. If the
minute passes with the alert still up, Discard and record still records (it enqueues a new request); that is the
owner's explicit tap. A note that belongs to another account never raises the alert: the request launches normally.

### 8.3 `recover(note)` (port of `W:src/action-voice-runtime.ts:83-97`; DECISION I10)

```
guard note.bot.account == host.account else throw "A saved voice note belongs to another account or to another computer running Hermes. Sign back in to recover it."
let chat = try await open(note.bot)                                  // §7.3 open
copy the file to MemoPaths.newRecording(accountKey, ext:) (ext m4a or wav by the file's extension)
compute (peaks, seconds) with MemoWaveform.compute off the main thread
guard chat.isTop && chat.botKey == note.bot.key else throw "Your earlier recording is saved. Open its bot chat and tap Recover recording to attach it."
MemoAccountStores.shared.drafts?.set(MemoFile(path, seconds, peaks, mime), for: chat.scope)
guard the draft store now returns that file for chat.scope else throw "Your earlier recording could not be saved to the draft. Tap Recover recording to retry."
delete the original file; clear dispatch.voice.pending; host.dismissNotice()
```

`mime`: `audio/x-m4a` for `.m4a`, `audio/wav` for `.wav`. A copy, waveform or store failure throws the "could not
be saved to the draft" sentence and leaves the original file and the key untouched. The draft chip then shows in
that chat ("Voice Memo 0:20", Play, Remove; 1x-voice §3.6), the mic is hidden and the primary is Send.

Quiet recovery runs from `deliver` when there is no request, nothing was started by a shortcut in this run of the
app (unless the owner tapped Recover recording), and no take is in progress.

### 8.4 Recovery failure alert

Title **Saved voice note**; message = the sentence thrown; buttons **Recover recording** (default; runs
`deliver(explicitRecovery: true)`), **Discard recording** (destructive; deletes the file and forgets the note, DECISION
F3) and **Cancel**. After a failure the note is not tried again by itself in that run of the app (only "Recover
recording" tries). The another-account sentence shows once per note (its id is kept under `intents.foreignNoteSaid`)
and has only **OK** (a retry cannot succeed until the owner signs back in).

**Fixture:** C1 plus the DEBUG seed hook (§12.3): no build can create such a note any more.
**Acceptance:** A24–A33.

## 9. Row L607 — Home Screen quick actions

### 9.1 Account and epoch (`AppModel.intentsDidActivate`)

`digest = ShortcutPolicy.accountDigest(url:username:)` = hex SHA-256 of `url + "\u{0}" + username` (CryptoKit). If
the stored digest differs (after the tolerance in §3.2): clear catalog, account and epoch, set
`UIApplication.shared.shortcutItems = []`, clear the voice request and the bot catalog (DECISION I14), then store the new
digest and a new UUID epoch. Same digest: change nothing.

### 9.2 The catalog (`ShortcutCatalogBuilder`, then `ShortcutPolicy.catalog`)

Inputs: `bots`, `sessions` (the Sessions list's recents), `visits: [String: Double]` (in memory; seconds),
`extra` (DECISION I7). Output order: by `at` descending, first 128.

| Target | `id` | `kind` | fields | `name` | `at` |
|---|---|---|---|---|---|
| each bot | `bot:` + key | `bot` | `botKey` | `Bot.name` cut to 160 | max(visit, `lastActive`) |
| each listed chat that is not some bot's own chat (`canonicalSessionId`) | `session:` + id | `session` | `sessionId` | title cut to 160, or "Chat" when empty | max(visit, `lastActive`) |

`intentsVisited(chat)` sets `visits["bot:"+key]` for a bot's own chat, else `visits["session:"+storedId]`, to now.

`QuickActions.schedule()` debounces 500 ms, then `update(rows)` (port of `W:HermesUIPages.swift:239-255`): return
unless an account digest and a non-empty epoch are stored; `safe = ShortcutPolicy.catalog(rows, epoch:,
validSession: NotificationRules.valid)`; encode; return if over 128 KB or equal to what is stored; store; then set
the items:

| Order | Title | Symbol | `type` | `userInfo` |
|---|---|---|---|---|
| 1, when there is a bot | New Voice Memo for `<first bot's name>` | `mic` | `dispatch.memo` | `{id, epoch}` |
| 2–3 | Open `<name>` for the first two targets | `bubble.left` | `dispatch.open` | `{id, epoch}` |
| last | Search Chats | `magnifyingglass` | `dispatch.search` | none |

An empty `safe` → `shortcutItems = []` (no lone "Search Chats"). `QuickActions.enabled == false` → always `[]`.
`ShortcutPolicy.catalog` and `permits` are copied line for line from `W:HermesUIPages.swift:201-217`.

### 9.3 States on the Home Screen (DECISION I5: on)

| Situation | Items |
|---|---|
| Signed in, roster loaded | as the table; they follow renames, new and deleted bots and chats, and the chat last opened moves to the front |
| Signed in, lists never loaded | none yet |
| Signed out | none |
| After a gateway switch | the new gateway's, after its lists load; an item captured before the switch is refused (§9.4) |

### 9.4 Performing one

`windowScene(_:performActionFor:completionHandler:)` → `completionHandler(QuickActions.perform(item))`. A cold
launch hands `connectionOptions.shortcutItem` to the same function after `restore()` (the scene already skips
reopening the last chat for it, `NAT:App/AppDelegate.swift:94-95`). `perform`: the type must start with
`dispatch.`; `ShortcutPolicy.permits(action, id:, epoch:, current:, targets:)` → false returns false with no UI;
true starts `route` and returns true.

`route(action, id, epoch)` (port of `W:src/ui-voice/shortcuts.ts:61-98`), through the runtime's `busy` gate:

1. Wait until `host.isActive && host.isReady`, at most 10 s from the start (a cold launch) → else "Open `<App>`
   to use this shortcut." In front and signed in, with the tabs never up (offline, a stalled launch): "`<App>` isn’t
   connected to the computer running Hermes yet. This shortcut runs if it connects in the next few seconds; if not,
   try again once it’s connected." The shortcut is held and runs, once, if the tabs come up within 10 s more
   (`IntentsRuntime.replayCap`; the notice goes as it runs); leaving the app drops it (UX study #264).
2. The epoch must equal the stored one → else "This shortcut belongs to a previous sign-in." The target must be in
   the stored catalog (not needed for search) → else "That chat is no longer available. Open `<App>` and choose it
   again."
3. `search` → §9.5.
4. `memo` on a target that is not a bot → "Voice memos need a bot chat."
5. Bot target: wait until the roster has the bot, at most the same 10 s → else "That bot is unavailable. Open its
   chat and try again." Then `open`: `host.openBotChat` → nil: "That chat didn’t open." `memo`: the same, then
   `startMemo` with `allowed = { chat.isTop && host.isActive }`; its two sentences are in §7.4. A take already
   running in another chat → "Finish the current voice note before starting another."; in this chat → leave it.
6. Session target: wait, inside the same 10 s, until the Sessions list holds that id; then
   `openNotifiedChat(stored: sessionId, profile: <its profile>)`
   (`NAT:App/Notifications/AppModel+Notifications.swift:238`). The list never held it, or no chat with that id is
   on top 3 s after the open → "That chat didn’t open."
7. Room target (DECISION I7): `host.openRoom(key)`; a room this gateway no longer has → "That group chat is no longer
   available."

Failures show in the DECISION I8 alert: title **Shortcut Unavailable**, message = the sentence, **OK**, an error haptic. An
error that is not one of ours shows the title **That shortcut is unavailable.** with no message.

### 9.5 Search Chats (DECISION I6)

Dismiss whatever is presented (no animation), select the Sessions tab, pop its stack to the root (no animation),
then `SessionsViewController.openSearchFromShortcut()`: the existing `search("")`
(`NAT:App/Sessions/SessionsViewController.swift:445-451`) followed by making the search field first responder on
the next run loop turn. Result: the Sessions list with its search field focused, empty, the keyboard up.

**Fixture:** C2 (five bots, listed chats, `/__restore/remove-bot`, `/__restore/delete`) for the items, Open and
Search; C1 for "New Voice Memo for". **Acceptance:** A34–A43.

## 10. Row L609 — donating the conversation, and coming back to it

What exists: `NSUserActivityTypes = [INSendMessageIntent]` (`NAT:App/Info.plist`); alerts dressed as a message from
the bot (`PushFaces.message` / `sendIntent`, `NAT:Shared/PushFaces.swift:69-87`); every donation deleted at sign-out
(`NotificationHub.clear`, `NAT:App/Notifications/NotificationHub.swift:257`). Missing, and the reason the row is
half done: nothing is ever donated, and a conversation the system hands back is ignored.

### 10.1 The builder (`Shared/PushFaces.swift`)

`static func donation(sender: String, handle: String, face: Data?, chat: String, conversation: String) ->
INInteraction?`: nil unless `sender` is non-empty and `NotificationRules.valid(conversation)`. Otherwise the intent
`sendIntent(body: nil, …)` builds (same people, same group name, same `conversationIdentifier`, **content nil**),
wrapped in `INInteraction(intent:response: nil)` with `direction = .incoming`
(`W:HermesPlatformExtras.swift:279-284`).

### 10.2 Donating (`NotificationHub.post`, after the content is built, `:228-231`; DECISION I13)

For kinds that alert about a chat (`message.complete`, `approval.request`, and the other request kinds; not
`test`), when `entry` is known: build the donation with the sanitized sender, `entry.profile`, the round face PNG if
there is one, the same chat name as the alert, and `stored`. Call `donate` and **do not wait** for it; its
completion logs `AppLog.note("notify", "donated")` or `"donation failed <code>"`. The alert is posted exactly as
before whether or not the donation works.

### 10.3 Coming back

`IntentsRouting.conversation(_ interaction: INInteraction?) -> String?`: the interaction's intent is an
`INSendMessageIntent` whose `conversationIdentifier` passes `NotificationRules.valid` → that id; else nil. The
message text an activity carries is never read and never sent (`W:HermesViewController.swift:668`: "supplied
message text never sends itself").

- `scene(_:continue:)` → `continueConversation(userActivity.interaction)`.
- Cold launch: the first of `connectionOptions.userActivities` that yields an id; it also turns off reopening the
  last chat.
- `continueConversation(id)` = `NotificationHub.shared.queueOpen(id, profile: nil)`, the path a tapped alert takes
  (it waits for the tabs and the lists on a cold launch, `openNotifiedChat`).

### 10.4 States

| Situation | What happens |
|---|---|
| A reply alert is posted locally for a known chat | the alert as today; one donation, with no message text |
| The system offers the conversation (Siri Suggestions) and the owner taps it | `<App>` opens that chat (the bot's own chat from Bots, another chat from Sessions) |
| The id is malformed or the chat is gone | nothing opens; the app shows where it was |
| Signed out | the sign-in form; nothing opens |
| Sign-out | every donation is deleted |

**Fixture:** C1 (its base streams replies, so a reply can finish in a chat that is not on screen and raise the
local alert; `scripts/fixtures/push-gateway.py` is no use here: it delivers remote pushes with `simctl push`, which
never pass through `NotificationHub.post`). C2 for opening a listed chat by id. **Acceptance:** A44–A48.

## 11. Sign-out, gateway switch, relaunch (DECISION I14)

| Event | Requests | Bot catalog | Saved note | Quick actions | Donations |
|---|---|---|---|---|---|
| Sign-out (`intentsSignedOut`) | cleared | emptied, `updateAppShortcutParameters()` | key cleared, file deleted if it resolves | catalog, account, epoch cleared; `shortcutItems = []` | deleted (existing) |
| Activate a different account | cleared | emptied, then refilled when its roster loads | kept | cleared, new digest and epoch | kept until sign-out |
| Activate the same account (every launch) | kept | kept | kept | kept | kept |
| Relaunch within the minute | the request is delivered once | — | — | — | — |
| Relaunch after the minute | nothing happens | — | — | — | — |

`started` lives in memory only; the acknowledgement in `launch`'s `defer` is what stops a second start after a
relaunch.

## 12. Stand-in gateways, simulator, launch hooks, commands

Ports for this stream: builders **9920–9924**, stress tester **9925–9929**. Simulator: builders
`HQN-m9-intents`, stress tester `HQN-m9-intents-s`. Derived data: `build/dd` inside this worktree (what
`scripts/build.sh` uses). Never another stream's simulator, port or folder; never the default simulator: always pass
the UDID.

```sh
xcrun simctl create "HQN-m9-intents" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0     # prints the UDID
```

### 12.1 `scripts/fixtures/intents-gateway.py` (new; stdlib only; loopback only; invented data)

A thin layer over `scripts/fixtures/voice-gateway.py`, loaded by path and not edited (the pattern of
`scripts/fixtures/restore-gateway.py`):

- Arguments: `--port` (9920–9929 only, unless `HQN_INTENTS_ANY_PORT=1`), `--credentials`, `--media-dir`, `--ref`
  (default `/Users/me/Projects/hermes-hq-native-ref238`), `--label` (names this gateway's bots "Beta Hermes",
  "Beta Ivy"; sets `base.voice.LABEL`).
- Before loading: `os.environ['HQN_VOICE_ANY_PORT'] = '1'` and rewrite `sys.argv` to the voice fixture's own
  arguments (it parses them at import). Refuse a busy port.
- Bots: `default` ("Hermes") and `ivy` ("Ivy"), with the voice fixture's whole memo pipeline (`/api/files`,
  upload, `file.attach`, transcription, `prompt.submit`, strict keys → 4000).
- Wrap `base.rpc` and the handler:

| Route | Behaviour |
|---|---|
| `POST /__fixture/intents` | any of: `{"names":{"ivy":"Samantha"}}` renames in every `profiles.list` answer; `{"removed":["ivy"]}` drops bots from the roster; `{"extraBots":300}` appends that many invented bots (`bot-001`…, name "Bot 001"…; they cannot be opened); `{"delay":{"profiles.list":8,"session.resume":3}}` seconds before answering; `{"fail":{"session.resume":2}}` the next n calls answer error 5000 "Synthetic failure"; `{"reset":true}` clears all of it |
| `GET /__fixture/intents-state` | `{"counts":{"<method>":n},"rpc":[the last 500 {method, params without data_url, at}],"controls":{…}}` |

`/__fixture/voice`, `/__fixture/voice-state` and `/__fixture/memo-history` are the voice fixture's, unchanged.

### 12.2 Start commands

```sh
cd /Users/me/Projects/hermes-hq-native-wt/m9-intents
mkdir -p build/fixtures && chmod 700 build/fixtures

# C1 — voice-note flows (L604, L605, L606, L608, L610): two bots and the memo pipeline, port 9920
lsof -nP -iTCP:9920 -sTCP:LISTEN && echo "9920 busy: stop here" || \
python3 scripts/fixtures/intents-gateway.py --port 9920 --credentials build/fixtures/intents-dev.json \
  --media-dir build/fixtures/intents-media-9920 --ref /Users/me/Projects/hermes-hq-native-ref238 \
  > build/fixtures/intents-9920.log 2>&1 &
echo $! > build/fixtures/intents-9920.pid

# C2 — quick actions, listed chats, roster removal (L607, L608, L609 open): five bots, port 9922
lsof -nP -iTCP:9922 -sTCP:LISTEN && echo "9922 busy: stop here" || \
python3 scripts/fixtures/restore-gateway.py --port 9922 --credentials build/fixtures/intents-pages.json \
  --files build/fixtures/intents-pages-files --tick-seconds 0 > build/fixtures/intents-9922.log 2>&1 &
echo $! > build/fixtures/intents-9922.pid

# L609 (donation) uses C1: a reply that finishes in a chat that is not on screen posts the local alert.
# Port 9923 is this stream's spare (the live unit-test suite, or scripts/e2e-voice.sh in A49).

# a second account for the "another gateway account" checks, port 9924
python3 scripts/fixtures/intents-gateway.py --port 9924 --label Beta --credentials build/fixtures/intents-beta.json \
  --media-dir build/fixtures/intents-media-9924 > build/fixtures/intents-9924.log 2>&1 &
echo $! > build/fixtures/intents-9924.pid

curl -s -X POST http://127.0.0.1:9920/__fixture/intents -H 'Content-Type: application/json' -d '{"names":{"ivy":"Samantha"}}'
curl -s http://127.0.0.1:9920/__fixture/intents-state | python3 -m json.tool
curl -s http://127.0.0.1:9920/__fixture/voice-state | python3 -m json.tool
kill "$(cat build/fixtures/intents-9920.pid)"       # stop only what you started, by the pid you wrote

# unit tests, both identities build, end to end (the script starts and stops its own fixtures)
scripts/build.sh test <HQN-m9-intents udid>
HQ_IDENTITY=original scripts/build.sh build <HQN-m9-intents udid>
HQN_INTENTS_PORT=9921 HQN_INTENTS_PAGES_PORT=9922 scripts/e2e-intents.sh <HQN-m9-intents udid> [runs]
# stress tester: HQN_INTENTS_PORT=9925 HQN_INTENTS_PAGES_PORT=9926 scripts/e2e-intents.sh <HQN-m9-intents-s udid> 3
```

`scripts/e2e-intents.sh` follows `scripts/e2e-voice.sh`: refuses a busy port and any port outside 9920–9929; writes
the invented credentials 0600 under `build/fixtures/` and never prints them; passes
`TEST_RUNNER_HQN_UI_CREDENTIALS` (C1's) and `TEST_RUNNER_HQN_UI_CREDENTIALS_PAGES` (C2's); runs only
`HermesHQNativeUITests/IntentsEndToEndTests` (`HQN_INTENTS_ONLY` narrows it); kills only the fixture pids it
started. One sign-in per test; never a sign-in loop. Never contact 100.101.102.104, any `*.ts.net` host, or a local
port this stream did not start.

### 12.3 DEBUG hooks (`App/Intents/IntentsDebugHooks.swift`, compiled out of Release)

The simulator has no Action Button and Siri there is not dependable, so the hooks run the **real** intent types.

| Trigger | Effect |
|---|---|
| launch argument `-HQDebugIntent voice-note:<profile>` | as the scene connects (before sign-in restore finishes): build `RecordVoiceNoteIntent`, set `bot` to an entity made with the §3.2 id formula for the last signed-in account and that profile (made, not looked up, so `perform()`'s own lookup is what runs), `try await perform()`; a thrown error is recorded in the state file |
| `-HQDebugIntent legacy-memo:<profile>` / `open-bot:<profile>` | the same with `DispatchMemoIntent` / `DispatchOpenBotIntent` and the entity id `epoch + ":bot:" + key` |
| `-HQDebugIntent voice-note-foreign:<profile>` | enqueue a request whose account is `"http://other.invalid\nsomeone"` |
| `-HQDebugIntent voice-note-request:<profile>` | enqueue a request for the signed-in account and that profile without consulting the catalog (a shortcut whose bot has since gone) |
| `-HQDebugQuickAction memo` / `open:<0 or 1>` / `search` / `stale` | perform the matching current Home Screen item through `QuickActions.perform` (`stale`: the first item with a wrong epoch) |
| `-HQDebugVoiceNote seed-pending:<profile>` | write a 4-second synthetic WAV to `Application Support/HermesAttachments/<uuid>/Voice note.wav` and a matching `dispatch.voice.pending` for the signed-in account; `seed-pending-foreign:<profile>` uses another account; `seed-pending-missing:<profile>` writes no file |
| `-HQDebugContinueChat <stored id>` | `continueConversation(id)` as the scene connects |
| URL only: `local-alert:<profile>` | call the real `NotificationHub.shared.post(kind: "message.complete", session: <that bot's stored chat id>, text: "Synthetic reply")` with the hub's own directory entry (the donation's path, without waiting for a streamed reply) |
| `-HQDebugResetIntents YES` | clear the six keys of §3.2 and `shortcutItems` before launch |
| `-HQDebugIntentsOut <folder>` | rewrite `<folder>/intents-state.json` on every change: `{"catalog":[{id,name,key}],"request":{…}\|null,"pendingNote":bool,"epoch":"…","quickActions":[{type,title,symbol}],"parameterRefreshes":n,"donations":[{"conversation","result"}],"events":["perform RecordVoiceNoteIntent ivy","open ivy","memo started ivy","ack <id>","notice <text>", …]}` (the pattern of `-HQDebugTextOut`) |
| URL `<scheme>://debug-intent/<same words as -HQDebugIntent / -HQDebugQuickAction / -HQDebugContinueChat>` | the same on a **running** app (UI tests use `XCUIApplication.open(_:)`; by hand `xcrun simctl openurl <udid> "hermeshq-native://debug-intent/voice-note:ivy"`). Handled in `SceneDelegate.open(_:)` under `#if DEBUG` only. |

Recording in the simulator uses the voice stream's fixture recorder: `-HQDebugMemoFixture granted`
(`NAT:App/Debug/VoiceDebugHooks.swift`).

## 13. Acceptance checks (all must pass before a row is "done"; a row is done only when seen working)

Unit tests are Swift Testing under `Tests/Intents/`; UI tests are `UITests/intents/IntentsEndToEndTests.swift`.
"State file" is `intents-state.json` (§12.3). Rerun a flaky UI test before calling it a failure; never loosen an
assertion to hide a real bug.

**Identity and metadata (L604, L605)**

- A1. Build the shipping identity (`HQ_IDENTITY=original scripts/build.sh build <udid>`). In the built app's
  `Metadata.appintents/extract.actionsdata`: actions `RecordVoiceNoteIntent`, `DispatchMemoIntent`,
  `DispatchOpenBotIntent`; entities `VoiceNoteBot`, `DispatchBotEntity`; queries `VoiceNoteBotQuery`,
  `DispatchBotQuery`; each action has one parameter named `bot`; titles, description, summary and the first phrase
  equal `WA:`'s, character for character. A script (`scripts/fixture-support/compare-intents-metadata.py`) prints the
  differences; the only ones allowed are the module name, the open-app/modes fields (DECISION I2) and the added phrase (DECISION I3).
- A2. `RecordVoiceNoteIntent` is discoverable; the two legacy intents are not (`isDiscoverable` false in the
  metadata).
- A3. The word "Dispatch" appears in no title, description, phrase, summary, parameter title or display
  representation in the metadata (identifiers excepted).
- A4. Both identities build with no new warning from the intents files other than, if DECISION I2's fallback was needed, the
  one deprecation.
- A5. Launch cost: `-HQLaunchTime` medians over 5 cold launches, before and after this stream, on the same
  simulator: the time before app code runs grows by no more than 15 ms. Report both numbers.
- A6. Unit: `VoiceBotCatalog` decodes a literal JSON value written the way build 240 writes it, and encodes records
  that 240's types would decode (same keys); ids match the §3.2 example byte for byte.
- A7. Unit: `resolve(id:)` — exact match; address written with a trailing slash or different host case still
  matches; another username, another key, or text that is not base64 → nil; the returned entity keeps the requested
  id.

**Catalog and parameter refresh (L608)**

- A8. Unit: syncing the same roster twice writes once and refreshes once; a rename, an added bot and a removed bot
  each write and refresh; an empty roster before the first load writes nothing; 600 bots store 512; a 300-character
  name stores 160.
- A9. UI (C1): sign in; the state file's catalog lists Hermes and Ivy. `POST /__fixture/intents
  {"names":{"ivy":"Samantha"}}`, bring the app to the foreground: the catalog shows Samantha and
  `parameterRefreshes` grew by one. `{"removed":["ivy"]}`: Ivy is gone and a `voice-note:ivy` trigger records the
  thrown "Open `<App>` to refresh your bots, then choose a bot in this shortcut."
- A10. Unit: `VoiceNoteBotQuery().suggestedEntities()` and `entities(for:)` run off the main actor and return the
  stored catalog (call them from a detached task).
- A11. Simulator, by hand, with a screenshot in the report: open the Shortcuts app (`xcrun simctl launch <udid>
  com.apple.shortcuts`), find `<App>`'s shortcut: "Record Voice Note" is there and (DECISION I3) the bots are listed; after a
  rename in the fixture and a foreground of the app the list follows. If the simulator's Shortcuts app shows no App
  Shortcuts at all, say so; A1, A9 and A10 then carry the row and the report lists it under device checks.

**The request and the hands-free memo (L604, L610)**

- A12. Unit: the request-store checks of `W:scripts/native-shortcuts/main.swift` (persistence across instances, a
  wrong-id acknowledgement keeps the request, replacement, expiry at exactly `expiresAt`, clear), plus DECISION I16.
- A13. Unit, with a fake `IntentsHost` (the cases of `W:src/action-voice-runtime.test.ts`): account isolation; the
  bot's own chat is opened and the memo starts in it; a superseded request neither starts nor steals the
  acknowledgement; an expired or already-started request only acknowledges; a take in progress for the same bot is
  left alone, for another bot throws; the composer becoming ready after 3 s still starts; never ready → the 5 s
  sentence; the chat changing during the wait → canceled; every path acknowledges; a second `deliver` during a
  delivery runs once more afterwards and no more.
- A14. UI, warm (C1, `-HQDebugMemoFixture granted`): signed in on the Sessions tab; open URL `voice-note:ivy` → the
  Bots tab is selected, Ivy's chat is on top, the locked recorder shows and its time advances; the state file shows
  one `memo started ivy` and `request` null.
- A15. UI, cold: launch with `-HQDebugIntent voice-note:ivy` → the same end state; the last chat is not reopened
  on top of it; measure launch to locked recorder and report it.
- A16. UI: from A14, tap Stop then Send → the memo bubble appears in Ivy's chat; `/__fixture/voice-state` shows
  exactly one upload, one `file.attach` and one `prompt.submit`, all with profile `ivy`; Hermes' chat has no new row.
- A17. UI: while Ivy's take runs, trigger `voice-note:ivy` again → the same take keeps running (its time did not
  restart), no alert. Trigger `voice-note:default` → alert "Finish the current voice note before starting another.";
  the take keeps running in Ivy's chat.
- A18. UI: `voice-note-foreign:ivy` → alert "This shortcut belongs to another account or to another computer running Hermes. Choose your bot
  again in Shortcuts."; no chat opens; `request` null.
- A19. UI: `{"removed":["ivy"]}` in the fixture, wait until the Bots list no longer shows Ivy, then
  `voice-note-request:ivy` → after one more roster read (the fixture's `profiles.list` count grows), alert "“Ivy” is
  unavailable. Reconnect to the computer running Hermes and try again."; no chat opens; `request` null.
- A20. UI: `{"fail":{"session.resume":5},"delay":{"session.resume":6}}` on a bot whose chat has no cache, then
  `voice-note:default` → either the recorder starts (the composer is usable from cache) or, after 5 s, the alert
  "The message field isn’t ready, so the voice memo didn’t start. Wait for the chat to connect, then try again.".
  Record which; in both cases `request` ends null and nothing records later when the app is foregrounded again.

**Legacy intents (L605)**

- A21. Unit: `ShortcutPolicy.legacyMemoBotKey` — the checks of `W:scripts/native-shortcuts/main.swift` (right epoch
  and account → the key; wrong epoch, wrong account, empty or 513-character key, a display name instead of a key →
  nil).
- A22. UI: `legacy-memo:ivy` → the same end state as A14. With a stale epoch → the state file records "Open `<App>`
  and choose the bot again. This shortcut is no longer available." and nothing opens.
- A23. UI: `open-bot:ivy` from the Sessions tab → Ivy's chat is on top, no recorder.

**Saved older-build note (L606, L610)**

- A24. Unit: `LegacyNoteFile.resolve` — a path under the old container's `HermesAttachments` resolves into this
  install's; `..`, a relative path, a path outside both folders, a symlink pointing out, a missing file, an empty
  file and a 33 MiB file → nil.
- A25. Unit (fake host): `recover` — the draft is stored for the bot chat's scope, the key is cleared and the
  original file deleted; another account → its sentence, nothing touched; the chat changed during the wait → "Your
  earlier recording is saved. Open its bot chat and tap Recover recording to attach it."; a copy or store failure →
  "Your earlier recording could not be saved to the draft. Tap Recover recording to retry." with the file and the
  key untouched; nothing is ever sent.
- A26. Unit: `deliver` with a request and a same-account note asks (§8.2) and does not launch; with another
  account's note it launches; with a note and no request it recovers, but not after a shortcut started a take in
  this run unless `explicitRecovery`.
- A27. Unit: the alert's three choices end as §8.2 says (request acknowledged or replaced; note kept or deleted).
- A28. UI: launch with `-HQDebugVoiceNote seed-pending:ivy` and no request → Ivy's chat opens with the draft chip
  "Voice Memo 0:04"; Play plays it; `pendingNote` false; the seeded file is gone; nothing was sent
  (`/__fixture/voice-state` prompts empty).
- A29. UI: `seed-pending:ivy` then `-HQDebugIntent voice-note:default` in the same launch → the alert: title "Saved
  voice note", message "Your note for Ivy is waiting to be added to its chat.", buttons "Open chat", "Discard and
  record", "Cancel" (screenshot, light and dark).
- A30. UI: A29 → **Open chat** → Ivy's chat with the chip; no recorder; `request` null.
- A31. UI: A29 → **Discard and record** → Hermes' chat with the locked recorder; `pendingNote` false; the seeded
  file is gone; Ivy's chat has no chip.
- A32. UI: A29 → **Cancel** → nothing opens; `request` null; `pendingNote` true; after backgrounding and returning
  the note is recovered as in A28.
- A33. UI: `seed-pending-foreign:ivy` → one alert "A saved voice note belongs to another account or to another computer running Hermes. Sign back
  in to recover it." with OK; not shown again on the next foreground in the same run; the note is still stored.
  `seed-pending-missing:ivy` → no alert, `pendingNote` false.

**Quick actions (L607)**

- A34. Unit: `ShortcutPolicy.catalog` and `permits` — the checks of `W:scripts/native-shortcuts/main.swift` (empty
  epoch, duplicate ids, over-long ids and names, bad kinds, invalid session ids, 128 cap, epoch prefix; memo only on
  a bot; search needs only a current epoch; a foreign-epoch id is refused).
- A35. Unit: `ShortcutCatalogBuilder` — bots' own chats are not listed twice; an untitled chat is "Chat"; order by
  activity, a visit moves a target to the front; 200 targets give 128.
- A36. UI (C2): after sign-in the state file's `quickActions` are, in order: "New Voice Memo for `<first bot>`" (`mic`),
  two "Open …" (`bubble.left`), "Search Chats" (`magnifyingglass`). Open another bot's chat and go back: within a
  second it is the first "Open …".
- A37. UI: press and hold the app's icon on the simulator's Home Screen (`com.apple.springboard`,
  `press(forDuration: 1.3)`) → the menu shows those titles (screenshot); tap "Search Chats" → the app opens on
  Sessions with the search field focused and the keyboard up. This is the real path: rerun on a flake; the hook path
  (A38–A41) is the gate if Springboard cannot be driven, and the report says which ran.
- A38. UI: `-HQDebugQuickAction open:0` cold, and the URL form warm → that bot's chat or listed chat is on top; the
  last chat is not reopened over it.
- A39. UI (C1): quick action `memo` → the first bot's chat with the locked recorder.
- A40. UI: `stale` → `perform` returns false, nothing opens, no alert. Sign out and in again: the epoch in the state
  file changed.
- A41. UI: delete the chat behind an "Open …" item in the fixture (`/__restore/delete`) and perform it before the
  list refreshes → alert "That chat didn’t open." or, once the catalog refreshed, "That chat is no longer available.
  Open `<App>` and choose it again."; never a blank chat.
- A42. UI: sign out → `quickActions` empty, and Springboard's menu shows none of ours.
- A43. Constant check: with `QuickActions.enabled = false` (a unit test with the flag injected) the items are `[]`.

**Donation (L609)**

- A44. Unit: `PushFaces.donation` — `direction == .incoming`; the intent's `content == nil`; `conversationIdentifier`
  is the stored id; the sender's `customIdentifier` is the profile; an empty sender or an invalid id → nil.
- A45. Unit: `IntentsRouting.conversation` — a valid interaction gives its id; an invalid id, 161 characters, or a
  different intent type → nil.
- A46. UI (C1), notifications allowed (the way `UITests/push/PushEndToEndTests.swift` allows them): with Hermes'
  chat on screen, open the URL `local-alert:ivy` → the alert for Ivy posts as before and the state file's
  `donations` gains `{conversation: <Ivy's stored chat id>, result: "ok"}`. Then the real flow once: send a message
  in Ivy's chat whose synthetic reply streams for a few seconds, go to Hermes' chat before it ends → the same two
  results when it finishes. If the simulator answers the donation with an error code, record the code in the report
  as a failure of this check, not a pass. With notifications not allowed: no alert and no donation.
- A47. UI: `-HQDebugContinueChat <stored id>` cold and warm → that chat is on top (a bot's own chat from Bots, a
  listed chat from Sessions); an invalid id → nothing opens.
- A48. UI: sign out → `INInteraction.deleteAll` ran (existing `NotificationHub.clear`); the state file's
  `donations` is empty after the next sign-in.

**Whole stream**

- A49. `scripts/build.sh test <udid>` passes (new suites included); `scripts/e2e-intents.sh <udid> 2` passes twice
  in a row; `scripts/e2e-voice.sh` still passes on this stream's simulator with `HQN_VOICE_ANY_PORT=1
  HQN_VOICE_PORT=9923` (the recorder was not disturbed).
- A50. No user-visible string in `App/Intents/` or `HermesKit/Intents/IntentsText.swift` contains "Dispatch" (a
  unit test greps the text table).

## 14. STRESS PLAN

Stress tester: ports 9925–9929, simulator `HQN-m9-intents-s`, its own fixtures. Each item names what to do and what
must be true. Record numbers, not adjectives.

**Load**

- S1. 50 `voice-note:ivy` URL triggers in 10 s (warm) → exactly one take; `request` ends null; no crash; no second
  recorder; `events` shows at most two deliveries running back to back at any moment.
- S2. Alternate `voice-note:ivy` / `voice-note:default` 20 times, 200 ms apart → one take, in the chat that was on
  top when it started; every later trigger for the other bot ends in "Finish the current voice note…" (one alert on
  screen, replaced, never stacked).
- S3. `{"extraBots":300}` → the catalog stores 302; `suggestedEntities()` answers in under 20 ms (unit timing, 500
  records); the Bots list stays at 60 fps while the catalog writes (no main-thread stall over 16 ms attributable to
  `intentsListsChanged`: time it with a signpost).
- S4. 100 roster changes in 10 s (script the fixture's `names` control and foreground reads) → at most one
  `updateAppShortcutParameters()` per second; the last name wins; UserDefaults written only when the bytes changed.
- S5. 128+ listed chats (C2 seeded or scripted) → the quick-action catalog holds 128; the encoded value is under
  128 KB; the Home Screen still shows four items.

**Speed**

- S6. Warm: trigger to locked recorder, 10 runs, median and worst. Target median ≤ 700 ms with the chat cached.
- S7. Cold: process start to locked recorder with `-HQDebugIntent voice-note:ivy`, 5 runs. Target median ≤ 2.5 s on
  the simulator. Compare with a plain cold launch to the Bots list.
- S8. A5 again on the stress simulator (launch cost of linking App Intents).
- S9. Quick action `open:0` cold: process start to first content of the chat, 5 runs.

**Bad network**

- S10. Stop the fixture, then `voice-note:ivy` with Ivy's chat cached → the chat opens from cache; either the
  recorder starts (and the memo later becomes a draft or sends when the gateway is back, per 1x-voice) or the 5 s
  sentence shows. Never a hang, never a silent nothing; `request` null either way.
- S11. Cold launch with empty caches and `{"delay":{"profiles.list":8}}` → the runtime waits for the roster and
  then records; with a delay of 70 s → nothing records when the roster finally arrives (the minute passed), and no
  alert appears out of nowhere.
- S12. `{"fail":{"session.resume":50}}` → the outcome of A20, every time, for 5 runs.
- S13. Drop the gateway while the shortcut's take is recording → the take continues; Send afterwards follows
  1x-voice §4.3 (draft chip and notice); nothing lands in another chat.
- S14. Quick action "Open …" with the gateway down → the chat opens from cache or "That chat didn’t open."; never a
  blank screen.

**Bad data**

- S15. For each of the six keys in §3.2: random bytes; valid JSON of the wrong shape; a 2 MB string; an empty
  array. Launch → no crash; the value is treated as absent; the catalog and items rebuild from the live lists.
- S16. Bot names: 200 characters, emoji, right-to-left, a newline, only spaces → pickers and the alert read sensibly;
  quick-action titles are cut at 160; nothing breaks the "New Voice Memo for …" title.
- S17. Entity ids handed to `entities(for:)`: empty, 10 000 characters, not base64, base64 of one line, another
  account → nil for each, no crash.
- S18. A request with `expiresAt` an hour away, zero, negative, or a string → cleared, nothing records.
- S19. `dispatch.voice.pending` with `path` `/etc/passwd`, `../../x`, a path into another app's container, a
  directory → never read, never deleted, key cleared, no alert.
- S20. A quick-action item with no `userInfo`, a wrong epoch, an id not in the catalog, a 600-character id → refused
  with no crash; the right sentence or nothing, per §9.4.
- S21. An activity whose conversation id has a slash, a space, or 161 characters → ignored.
- S22. Two bots with the same display name → both appear in the pickers; each shortcut opens its own profile (ids
  differ by key).

**Interruption**

- S23. Shortcut while a sheet is up (Settings, Bot Info, a prompt sheet, the media viewer, an alert) → the sheet is
  dismissed and the chat opens; no half-presented state; a draft typed in a dismissed sheet's own field is the
  sheet's business (report anything lost). A sheet holding unsaved edits (modal in presentation) asks first, as its
  own ✕ does; discarded, the chat opens; kept, it doesn't (UX study #263).
- S24. Shortcut while the keyboard is up with text typed in another chat → that text is still that chat's draft
  afterwards.
- S25. Shortcut while a reply is streaming in the target chat → the recorder starts; the memo queues behind the
  reply (1x-voice V13); the stream does not stutter.
- S26. Background the app between the trigger and the recorder (Home during the push) → nothing records in the
  background; returning within the minute starts it once; returning after it does nothing.
- S27. `-HQDebugMemoInterruptAfter 2` (a call takes the mic) on a shortcut's take → the 1x-voice "Recording Stopped"
  notice and a draft chip in that bot's chat; `request` null; a new trigger records again.
- S28. Sign out while a request waits (trigger, then sign out inside the minute) → nothing records after signing
  back in.
- S29. Switch gateways (C1 on one port, the Beta fixture on another) and run a shortcut saved for the first → the
  intent's own "Open `<App>` to refresh your bots…" (the catalog now belongs to Beta) or, for a request already
  written, the another-account alert. Never a take in a Beta chat.
- S30. Rotate through light and dark while the "Saved voice note" alert is up; trigger a second shortcut while it
  is up → one alert at a time, the newest decision wins, no orphaned request.
- S31. Microphone permission denied (`-HQDebugMemoFixture denied`) → the chat opens and shows the recorder's
  "Microphone Access Is Off" notice; `request` null.

**Relaunch**

- S32. Terminate the app right after a trigger wrote the request (before the chat opened); relaunch within 60 s →
  one take; relaunch after 60 s → none. 5 runs each.
- S33. Terminate during the take → after relaunch nothing starts by itself; the request is gone.
- S34. Relaunch with the catalog stored and the gateway down → the pickers' data (state file `catalog`) is intact
  before any network answer.
- S35. Cold launch by a quick action and by `-HQDebugContinueChat` with a remembered last chat → the asked-for chat
  is on top, the remembered one is not pushed over it, Back goes to the list.
- S36. Install the build over itself (`simctl install` again) → the six keys survive; a `voice-note:ivy` trigger
  still resolves.

**Accessibility sizes**

- S37. Dynamic Type at the largest accessibility size: every alert in §7.4, §8.2, §8.4 and §9.4 shows its whole
  sentence (it scrolls if it must) and every button; screenshots.
- S38. VoiceOver: the alerts are read title, message, buttons; after a shortcut starts the recorder, focus lands on
  the recorder's status and nothing is spoken into the take (DECISION I15); "Discard and record" is announced as destructive.
- S39. Bold Text, Increase Contrast, Reduce Motion, Reduce Transparency: the flows of A14, A29 and A37 look right
  and behave the same.
- S40. Search Chats at the largest size: the search field is focused and the first results row is not hidden.

## 15. Risks, UNKNOWNs, and what only a real iPhone can show

Risks:

- R1. **Carry-over is proven only by metadata.** A1 shows iOS will see the same identifiers; that a shortcut saved
  under build 240 really runs after the update needs a phone that has one.
- R2. **Linking App Intents costs launch time** (A5). If it is over budget, report the number; do not move the
  intents to an extension (that would break R1's identifiers' carry-over).
- R3. **Swift 6 isolation.** The intent types must be `nonisolated` with `static let`; a query that touches a
  main-actor type compiles only with hops that the system then calls off-main. Keep the queries on
  `VoiceBotCatalog`.
- R4. **`supportedModes`** (DECISION I2) is new API; the fallback is documented.
- R5. **The parameterized phrase** (DECISION I3) is a native addition; drop it if it misbehaves and say so.
- R6. **Quick actions were never on in a release** (DECISION I5): the stress stage is their first real QA.
- R7. **The "Saved voice note" alert was dead code in 240** (DECISION I9): its native meaning is this spec's decision.
- R8. **Shared files.** `AppModel.swift`, `AppDelegate.swift`, `NotificationHub.swift`, `PushFaces.swift` and
  `SessionsViewController.swift` are edited by other streams too. Keep every edit a tagged one-liner so the merge is
  mechanical.
- R9. **Cross-stream.** `m9/talk` may want a "Talk to" action later (owner: after the device check); `m9/groups` can
  feed room targets through `extra` (DECISION I7); `m9/share` may use the donated conversations for share-sheet suggestions.

UNKNOWN (check, then write the answer into the report):

- U1. Whether the native build's stored `url` is byte-identical to the web app's for the same sign-in. §3.2's two
  defences cover a trailing slash and host case; anything else changes the epoch once (legacy shortcuts would ask
  to choose the bot again, and a request waiting at that instant is dropped: press again) but not the "Record Voice
  Note" ids' fallback match.
- U2. Whether the simulator's Shortcuts app lists App Shortcuts for a development build (A11).
- U3. Whether `INInteraction.donate` succeeds in the simulator without the Communication Notifications entitlement
  (A46 records the answer).
- U4. Whether Springboard's quick-action menu can be driven reliably by XCUITest on this runtime (A37).

Only on a real iPhone (list these in the report as not done here, never as done):

- the Action Button itself, including from a locked phone;
- Siri hearing "Record a voice note in Hermes HQ" and asking which bot;
- a shortcut saved under build 240 running after the update (R1);
- the real microphone, a real call interrupting the take, a Bluetooth headset;
- Siri Suggestions offering a donated conversation and opening its chat.

## Changes made after review (finishing stage)

- DECISION F1. **A kick that finds the app in front but not yet active waits for it** (100 ms steps, 2 s at most), and
  `UIApplication.didBecomeActiveNotification` kicks as well as the scene's callback. Build 240 guarded the same
  ("Scene callbacks can precede UIApplication's aggregate active state"). In the background nothing waits.
- DECISION F2. **A cold launch the system makes for a shortcut.** Measured in the simulator: the system launches the
  app, the saved sign-in is back 0.1 s after the scene connects, and the system performs the intent only afterwards
  (7 s later on this loaded Mac). Nothing in the launch says a shortcut is coming (no activity, no source
  application), so the last chat can be on screen first. What the app guarantees: as soon as the request is seen,
  reopening the last chat is called off if it has not happened yet (`cancelLaunchRestore`), and if it has, the
  shortcut's chat takes its place with nothing left under it (Back goes to Bots). Build 240 behaved the same way
  (its web view restored the last chat before the request arrived).
- DECISION F3. **"Discard recording"** is added to the "Saved voice note" alert that offers "Recover recording". Not in
  the web app; without it a note that can never be brought in (its bot removed) had no way out short of signing out.
- DECISION F4. A saved older-build note alone no longer counts as a claimed launch (replaces the builder's B10): one
  that cannot be recovered would have switched off reopening the last chat for good.
- DECISION F5. A quick action or "Open Bot" waits up to 30 s for a delivery in flight and then says "<App> was busy.
  Try again." (title "Shortcut Unavailable") instead of doing nothing. Not a web sentence; the web had no such gate.
- DECISION F6. A shortcut's alert that finds another alert on top dismisses it first (its awaiting code is answered
  through `AlertAnswer`, now also for "Change Model?"), and a refused presentation is tried again for up to 3 s.

