# 3x · Settings, haptics and notification leftovers (m9 stream "settings")

Status: spec **revision 2** (re-audited after merging `m9/train` at bd25418, which brought in talk, share, intents, presence, screen, photoheads, groups, sessions, offline, desktoplook, a11y, ipad and capabilities). Nothing of this stream is built yet. Section 0.1 lists what the merge changed; every section below is already corrected for it. Branch `m9/settings`, worktree `/Users/me/Projects/hermes-hq-native-wt/m9-settings`.
Rows: 17 (11 ❌, 6 🟡) plus the React… item of talk's row L365. Ledger: `docs/briefs/m9/settings-rows.md`.

Paths used below:

* `REF` = `/Users/me/Projects/hermes-hq-native-ref240` (the web app at build 240, read only)
* `$V` = `REF/vendor/hermes/apps/desktop/src` (the desktop renderer the phone wraps)
* `GW` = `/Users/me/.hermes/hermes-agent/tui_gateway` (gateway contracts, read only; an unknown param answers error 4000)
* Native paths are relative to the worktree.

Rules that bind every section (from the brief, repeated because a builder reads one section at a time):

* Native Liquid Glass only. Wrapping rows 12 to 14 pt vertical padding. Tab roots inline large title, pushed pages small title (`PushedPageTitles`).
* The word "Dispatch" never appears in anything a person sees or hears. Storage keys may contain it.
* Wording is the web app's phone wording (quoted here with its source). Never show a control that does nothing.
* Swift 6, default MainActor, `withChildTasks` not `withTaskGroup`, XcodeGen with BOTH `project.yml` and `project-original.yml` building.
* A row is done only when implemented AND seen working on the builder's own simulator against a stand-in gateway the builder started.
* One feature per TestFlight build (owner: "ONE FEATURE AT A TIME"). Section 20 gives the order.

Owner notes quoted in this spec come from `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` (read only).

---

## 0. Summary table

| # | Row | Outcome proposed | Section |
|---|-----|------------------|---------|
| 1 | §25 L929 Haptics switch | build | 1 |
| 2 | §25 L928 Haptics at eight places | build the missing ones | 2 |
| 3 | §19 L785 Power saver | finish on offline's `PowerState` (heads + heat, decorative loops, 3 timers, proof) | 3 |
| 4 | §19 L767 Largest Attachment | build | 4 |
| 5 | §19 L777 Auto-archive; Default Project Folder | wire the folder, re-verify auto-archive | 5 |
| 6 | §19 L750 Text Direction | build | 6 |
| 7 | §19 L747 Intro Splash | build | 7 |
| 8 | §19 L746 Chat Font | build | 8 |
| 9 | §19 L751 Message Reactions (+ React… of L365) | build | 9 |
| 10 | §19 L752 Vibe Hearts | build | 10 |
| 11 | §19 L753 Inline Embeds | build, natively (no web view) | 11 |
| 12 | §19 L754 File Browser | build as a chat-bar shortcut | 12 |
| 13 | §19 L759 Hidden on phone | **web-shell-only** (done by absence, with a test) | 13 |
| 14 | §12 L554 Local alerts from the socket | build the list-derived fallback | 14 |
| 15 | §12 L555 Local alerts the renderer raises | build four kinds (three of their switches are dead today) | 15 |
| 16 | §12 L568 Device removal ledger | prove with a fixture, fix what the proof finds | 16 |
| 17 | §12 L575 Push add-on offer | switch to `MainBotRequest.queue`; build the two extra offers | 17 |

### 0.1 Revision 2: what the train merge changed (read this first)

| Area | What landed from another stream | Effect on this spec |
|---|---|---|
| Power | offline shipped `HermesKit/Net/PowerPolls.swift`: `PowerState.shared` (`saving`, `override`, `PowerState.changed`), `PowerPolls.period / loop / wait`, DEBUG `-HQDebugPowerSaving YES|NO`. Roster, sessions, gateway switcher, capabilities, Kanban, Jobs, activity and browser polls already go through it | Section 3 no longer builds a service. It **reuses** that one and finishes what is left: heads ignore heat, decorative motion ignores saver, three timers are unrouted, one duplicate reading |
| Fonts | desktoplook + a11y shipped `HQFont` (`App/Theme/ThemeFonts.swift`, `App/Kit/Accessibility/HQFont.swift`): one font factory with the skin's typeface, UI Scale, Bold Text; `ChatStyle` is cached per `category + ThemeTable.layoutTag + bold` (`App/Chat/ChatStyle.swift:118-130`) | Section 8 plugs the chat font into that factory and that cache key. It must not build a second resolver |
| Motion | a11y shipped `HQMotion.reduced` (`App/Kit/Accessibility/HQMotion.swift`), used at every shimmer and pulse site | Sections 3 and 10 add one sibling flag next to it instead of touching each site's logic |
| Ask the main bot | presence shipped `MainBotRequest.queue(text:title:)` (`App/Presence/MainBotRequest.swift:85`), which opens the main bot's chat, dedupes and queues with a bubble title | Section 17a is now a call to it, not a new function |
| Settings root | Appearance gained a Theme row; a Voice row exists; rows are tinted `Color.hqLabel` | Section 18 redrawn from the merged file |
| New chats | groups and sessions added `session.create` call sites (7 in all now) | Section 5 lists all seven |
| Attachments | share added a consumer of the 32 MB constant (`ShareRosterWriter` writes `limitBytes` for the Share extension) | Section 4 lists it; the Share sheet follows the setting through the roster |
| Hold menu | talk rebuilt the message menu as `MessageMenuModel` (`HermesKit/Chat/ChatActionsModel.swift:121-165`), and left React… to this stream (`docs/spec/3x-talk.md:254`) | Section 9 names the exact insertion point |
| Haptics | more call sites arrived: 293 raw generator / `.sensoryFeedback` uses in 91 files (was about 200 in 60) | Section 1 is larger but unchanged in kind. Land it first |
| Contracts (checked this revision against `GW/contracts`) | `message.react`: `row_id` is an **integer**; `author` is `"user"` or `"agent"`; `config.set` answers **4002** for a display key the gateway does not list; `process.list` entries are keyed by their own `session_id` (there is no `id`) | Sections 9 and 15 corrected; the "builder confirms" notes are gone because it is confirmed |
| Fixtures | `e2e-push.sh` accepts any port with `HQN_ANY_PORT=1` | Sections 16, 17, 19: no script edit needed |

### 0.2 How close each row is (closest first)

"Close" = how little is left between today's merged code and the row being seen working. This is the order to build in (section 20 follows it).

| Rank | Row | What already exists | What is left | Size |
|---|---|---|---|---|
| 1 | L759 Hidden on phone | Nothing to build: the native app never had these desktop controls | One absence test, then the ledger says web-shell-only | hours |
| 2 | L785 Power saver | The service and nine polls (offline) | Heads follow heat; shimmer/pulse stop in saver; 3 timers; fixture args; the proof run | half a day |
| 3 | L575 Push add-on offer (queue half) | `MainBotRequest.queue`, the weekly offer, the 15-minute watch, `pluginState()` already returning themes / restart guard | Swap one call; two more offers; one Settings row; fixture switches | 1 day |
| 4 | L568 Device removal ledger | All the code (`PushLedger`, `forget`, `remove(_:)`) | Proof on two fixtures; fix what the proof finds | half a day to 1 day |
| 5 | L747 Intro Splash | The empty-chat placeholder | One switch, one gate | hours |
| 6 | L777 Default Project Folder | The page, the storage, the hidden field, auto-archive working | Send `cwd` from 7 create sites; validate; un-hide | 1 day |
| 7 | L767 Largest Attachment | One constant with four readers | A preference, a small page, two messages | 1 day |
| 8 | L754 File Browser | The Files page and its ⋯ entry | A switch and a bar button | half a day |
| 9 | L929 Haptics switch | — | A gate file, then 293 mechanical call moves in 91 files, a scan test | 1 day, wide |
| 10 | L928 Haptics at eight places | Five of eight present | Row drag, custom pickers, sheet Save, title view, model favourite | 1 day (after 9) |
| 11 | L750 Text Direction | Text layout with cached heights | Direction in every paragraph style, composer, cache key | 1 to 2 days |
| 12 | L746 Chat Font | `HQFont` factory, config store, sparse save | Family override in the factory, the picker page, cache key | 2 days |
| 13 | L752 Vibe Hearts | — | One event, one emitter, one switch | 1 day |
| 14 | L555 Renderer alerts | Kinds, switches and copy exist | 15a and 15c small; 15b and 15d are new watchers | 3 days |
| 15 | L554 Socket alerts | Opened chats covered | The list-derived watch | 1 to 2 days |
| 16 | L751 Message Reactions + React… | Row ids on messages; the menu model | Model, decode, chips with exact heights, popover, mirror, events | 3 to 4 days |
| 17 | L753 Inline Embeds | Link handling, image fetcher | Matchers, consent, cards with fixed heights, cache, fixture pages | 4 to 5 days |

---

## 1. Haptics switch (§25 L929)

### What the web app does

* `REF/src/ui-kit/haptics.ts` is the one door for haptics. Vocabulary: `selection`, `impact.light|medium|rigid|soft`, `notification.success|warning|error`. `installHapticsMute` makes every call a no-op while the renderer's mute is on.
* The mute lives in `$V/store/haptics.ts` (key `hermes.desktop.hapticsMuted`, default false) and is installed at `REF/src/ui-kit/index.ts:13`.
* On the phone there is **no visible control** for it. `REF/src/completion-sound-pref.ts:2` says so: "no control for that on the phone, and it would silence haptics too". The desktop control is a titlebar tool, "Mute haptics" / "Unmute haptics".

### Native today

293 direct `UIImpactFeedbackGenerator` / `UISelectionFeedbackGenerator` / `UINotificationFeedbackGenerator` / `.sensoryFeedback(` uses across 91 files after the train merge (count with the grep in the acceptance list; it will have moved again by the time this is built), no gate. `PagesHaptics` (`App/Pages/PageKit.swift`) wraps the Pages ones and is used from nine files. One call in HermesKit (`HermesKit/Chat/LiveChatSession+Attachments.swift:265`, the refused-send error tap). Settings root itself calls `UISelectionFeedbackGenerator()` inline in its toggles (`App/Settings/SettingsRootView.swift:304,332`).

### Design

**DECISION 1.1** The native app gets a real switch, because the row says haptics are "muted by the renderer's Haptics switch" and the web phone gives no way to reach that switch. Hiding a setting people cannot reach is worse than showing one that works.

* Place: Settings root, the section now titled "Sounds" becomes **"Sounds & Haptics"**. New row after the Sound picker:
  * Title: **Haptics** (toggle, default On)
  * Section footer becomes: "Completion Sound plays when a bot’s reply finishes. Haptics are the small taps you feel when you pick, drag or finish something."
* Storage: `UserDefaults` key `hqn.haptics` (Bool, absent = on), on this iPhone only. Pattern: `InAppTips` in `App/Settings/AppPreferences.swift`.
* **DECISION 1.2** Unlike the web mute, the switch does not silence the completion sound. That has its own switch right above it.
* **DECISION 1.3** The system's own haptics (switches, pickers, context menus, pull to refresh) are not ours to mute and stay as iOS has them. The footer wording above is deliberately about "taps you feel when you pick, drag or finish something" and makes no promise about system controls.

New file `App/Kit/Haptics.swift` (beside `App/Kit/Accessibility/HQMotion.swift`, same shape: one enum, static, safe to call from anywhere on the main actor):

```swift
enum Haptics {
    enum Kind: Equatable, Sendable { case selection, light, medium, rigid, soft, success, warning, error }
    static var isOn: Bool            // reads hqn.haptics; cached, refreshed on UserDefaults.didChangeNotification
    static func play(_ kind: Kind)   // no-op when off; otherwise the matching system generator
    static func prepare(_ kind: Kind)
    static var sink: ((Kind) -> Void)?   // DEBUG / tests: records instead of playing
}
```

* Every raw generator call in `App/` moves to `Haptics.play`. `PagesHaptics` becomes a thin forwarder or is deleted. The two `.sensoryFeedback` modifiers become `.onChange { Haptics.play(.selection) }`.
* HermesKit cannot import the app: the one call there becomes a closure hook `LiveChatSession.haptic: (@MainActor (HapticCue) -> Void)?` set by the app at start (or the call moves to the app side; builder's choice, same result).
* Guard test `HapticsGateTests`: scans the Swift sources under `App/` and `HermesKit/` and fails if `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator`, `UINotificationFeedbackGenerator` or `.sensoryFeedback(` appears outside `App/Kit/Haptics.swift`. This is what keeps the switch honest as code is added.

Owner notes that bound which haptics exist at all (do not add to the silent list while moving calls): taptic-feedback-gaps.md records that the owner asked "where should we add taptic feedback, then add it", and that these stay silent on purpose: Send and retry, password prompts, commands and plus-menu picks, archive (the Undo pill is the feedback), the cron switch. Opening a bot or session keeps its "soft Taptic on opening a new bot or session". The same note: haptics cannot be felt in Simulator, so verification is by test.

### Wire

None.

### States and wording

| State | What shows |
|---|---|
| On (default) | Toggle on. Every `Haptics.play` reaches the system. |
| Off | Toggle off. No app haptic anywhere, including long-press menus we trigger ourselves and drag thresholds. |
| Settings search | Entry "Haptics" under "Sounds & Haptics" (`HermesKit/Settings/SettingsSearch.swift`). |

### Stand-in

Any. `scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json`.

### Acceptance

1. `HapticsGateTests` passes (no raw generator outside the gate). The same check by hand: `grep -rn --include='*.swift' 'FeedbackGenerator\|sensoryFeedback(' App HermesKit Shared ShareExtension | grep -v App/Kit/Haptics.swift` prints nothing. (The Share extension is a separate process: if it has haptics, it gets its own three-line gate reading the same key from the app group defaults, or keeps none.)
2. Unit: with `Haptics.sink` set and the switch on, `Haptics.play(.selection)` records one cue; with the switch off it records none.
3. UI test: Settings › Sounds & Haptics shows "Haptics" on by default; turn it off, relaunch, still off.
4. UI test with launch arg `--haptics-probe` (DEBUG only; the sink appends to an accessibility-readable counter label on a debug overlay): with the switch off, dragging a pinned head and changing the Sessions filter leaves the counter at 0; with it on the counter rises.
5. Both project files build.

---

## 2. Haptics at eight places (§25 L928)

### What the web app does, and what native has

| Place | Web (file:line → cue) | Native today | To do |
|---|---|---|---|
| Pinned drag | `REF/src/ui-bots/pinned-drag.ts:63` selection per slot crossed; `:75` impact.light on drop | Present: `App/Bots/BotsViewController.swift:654,667,677` | Route through `Haptics`; confirm one cue per slot, not per frame |
| Row drag | `REF/src/ui-bots/row-drag.ts:96` selection when the highlighted section changes | Missing | Add `selection` when the drop target section changes during a row drag |
| Picker | `REF/src/ui-kit/picker.tsx:90`, `REF/src/ui-pages/page-picker.tsx:97,107`, `REF/src/ui-pages/scope.tsx:42` selection on a pick | System `Picker` and `UIMenu` tick by themselves; our custom pickers (page picker, scope strip) do not | Add `selection` to the custom ones only. Never double up on a system control |
| Filter strip | `REF/src/ui-lists/filter-strip.tsx:33`, `filter-apply.ts:42,80`, `REF/src/ui-bots/roster-bar.tsx:49,54` selection | Sessions filter present (`App/Sessions/SessionsViewController.swift:490,498`); Bots bar and Pages filter strips to check | Add where missing; one cue per change |
| Sheet bar | `REF/src/ui-kit/sheet-bar.tsx:41` notification.success when Save succeeds; `:45` notification.error when it fails | Mixed: some sheets do it, most do not | One helper `SheetSaveFeedback.finished(_ ok: Bool)`, called by every sheet with a Save/Done bar that does work (kanban task, new task, cron job, profile editor, model picker, config pages that save) |
| Kanban | `REF/src/ui-kanban/task-sheet.tsx:102,105,121,138,160,264`; `new-task-sheet.tsx:69,80,93`; `board-page.tsx:101,106,132,214,270` | Present through `PagesHaptics` | Route through `Haptics`; compare each web call site and add any missing |
| Title view | `REF/src/ui-chat/title-view.tsx:46` impact.medium when the hold registers; `:124` selection on a subtitle tap | Gateway title present (`App/Gateway/GatewayTitleSwitcher.swift:135`); chat title view to check | Chat title: `medium` when the hold opens its menu, `selection` on the subtitle tap |
| Model sheet | `REF/src/ui-chat/model-sheet.tsx:94` selection on favourite toggle; `REF/src/ui-pages/main-model.tsx:77` error | Pick present (`App/Chat/ModelSheetViewController.swift:288`) | Add `selection` on favourite toggle and `error` when setting the model fails |

Two rules from the web file apply to all of them: a long-press haptic fires only when the menu actually shows (`MENU_WAIT_MS 700`), and a threshold haptic fires once per crossing (`thresholdHaptic`), never per frame.

**DECISION 2.1** Where iOS already gives the cue (system `Picker`, `UIMenu`, `UIContextMenuInteraction`, `UISwitch`), the app adds nothing. Two taps for one action feels broken.

### Wire

None.

### Stand-in

`scripts/fixtures/settings-gateway.py --port 10060 …` for Bots, Sessions, chat title and model sheet. `scripts/pages-fixture-gateway.py --port 10064 --credentials build/m9-settings/pages.json --files build/m9-settings/files` for Kanban.

### Acceptance

For each of the eight places, a test that drives the gesture with `Haptics.sink` recording and asserts the cue list exactly. Unit tests where the logic is reachable without UI (drag slot maths, sheet save helper), UI tests with `--haptics-probe` for the rest. The row moves to done only when all eight have a passing test and the builder has run each gesture once by hand on the simulator to see the visual half works.

---

## 3. Power saver (§19 L785)

### What the web app does

* `REF/src/power-state.ts`: saver = Low Power Mode on, OR thermal state serious or critical. `SAVER_FACTOR = 3`. `powerInterval` re-arms timers when the state changes and runs at once when leaving saver if a run is overdue.
* `REF/src/power-saver.css`: decorative loops stop (robot heads that are not speaking, skeleton shimmer, marquee, progress slide, the streaming code-card effect). Typing dots and spinners keep running. Voice surfaces and approval cards are untouched. Glass keeps its blur and drops saturation.
* `REF/ios/App/App/HermesPower.swift`: observes `NSProcessInfoPowerStateDidChange`, `ProcessInfo.thermalStateDidChangeNotification`, `didBecomeActive`. DEBUG simulator fixtures: launch args `--low-power-fixture`, `--thermal-fixture=serious`, defaults key `dispatch.lowPowerFixture`.
* Consumers: `visible-poll.ts:21`, `gateway-switcher.ts:170`, `bot-screen-setup-view.tsx:32`, `stale-work-check.ts:116`, `bot-screen-mac.ts:31`, `bot-activity.tsx:80`, `ui-bots/work-status.ts:88`, `ui-chat/turn-status-view.tsx:51`, `ui-kit/tip.tsx:45`, `ui-heads/motion.ts:36`, `ui-heads/bot-head.tsx:36`.
* There is no switch and no wording. It is automatic.

### Native today (after the train merge)

The offline stream shipped the service this row needs (`docs/spec/3x-offline.md` §6.9), and the planner note says whichever stream lands second reuses it. That is this stream.

* `HermesKit/Net/PowerPolls.swift`:
  * `PowerState.shared`: `saving` = Low Power Mode OR thermal serious/critical; block observers hopping to the main actor; `override: Bool?` for tests; posts `PowerState.changed`.
  * `PowerPolls.saverFactor = 3`, `period(_:floor:cap:saving:)`, `loop(every:floor:cap:)`, `wait(_:floor:cap:)`.
  * DEBUG launch argument `-HQDebugPowerSaving YES|NO` (`App/Offline/OfflineDebug.swift:13,39`).
* Already routed: roster (`BotStore.swift:776-786`), sessions (`SessionStore.swift:757`), gateway switcher (`GatewaySwitcherModel.swift:63`), capabilities (`CapabilitiesModel.swift:415`, `ServerIssueSweep.swift:29`), Kanban board and task sheet (`KanbanStore.swift:141`, `KanbanTaskSheet.swift:50,69`), Jobs (`JobsStore.swift:160`, `JobDetailViewController.swift:156`), activity (`ActivityStore.swift:456,519,571`), browser viewer (`BrowserViewerController.swift:411`).
* **Not** done, which is why the row is still open:
  1. Heads keep still for Low Power only: `App/Heads/HeadView.swift:466` reads `ProcessInfo.processInfo.isLowPowerModeEnabled` itself and never looks at heat.
  2. Decorative motion ignores saver. Every shimmer and pulse is gated on `HQMotion.reduced` (Reduce Motion) alone: `BotRowViews.swift:293`, `ChatChrome.swift:306`, `ChatPlaceholderView.swift:208`, `ChatCells.swift:87,615,1039,1126`, `MediaTileView.swift:300`, `PageKit.swift:299`.
  3. Unrouted repeating waits: `PushRegistrar.swift:144` (15 s), `PushSetupOffer.swift:120` (the 20 s plugin watch), `Presence/ComputerInfoSection.swift:100` and `Capabilities/ConnectorPageController.swift:240` (1 s clocks). Check each: route it if it repeats for as long as a screen is up and nobody is waiting on that exact tick.
  4. A second reading of the same thing: `HermesKit/Screen/ScreenSession.swift:891`.
  5. The web's fixture names (`--low-power-fixture`, `--thermal-fixture=`) do not exist natively; the native name is `-HQDebugPowerSaving`.
  6. Nobody has measured the 3× on a simulator for this row.

### Design

**DECISION 3.0** No new service and no rename. `PowerState` / `PowerPolls` stay exactly as offline wrote them (other streams call them). This stream adds to them and to `HQMotion`, nothing else.

1. **One motion flag.** In `App/Kit/Accessibility/HQMotion.swift`, beside `reduced`:

   ```swift
   /// Decorative loops (shimmer, pulse, idle heads, hearts) stop under Reduce Motion and while saving power.
   @MainActor static var decorativeStill: Bool { reduced || PowerState.shared.saving }
   ```

   The sites in item 2 above change `HQMotion.reduced` to `HQMotion.decorativeStill` **only where the guarded thing is a loop** (shimmer, pulse, idle motion). Exception (owner, build 294): the working arc round a busy bot (`WorkingArc.swift`) is status, not decoration, and keeps travelling in saver; only Reduce Motion stills it. Guards on one-shot transitions (`ChatChrome.swift:72,84`, `MediaTileView.swift:184`, springs through `HQMotion.spring`) stay on `reduced`: saver does not remove transitions (web `power-saver.css` stops loops, not transitions).
2. **Loops restart.** Each loop site observes `PowerState.changed` (block observer on `.main`) and starts or removes its animation, as it already does for Reduce Motion. A site that only checks at start time would stay still for ever after saver ends.
3. **Heads.** `HeadMotionSettings.readStill()` becomes `HQMotion.reduced || PowerState.shared.saving` and its observer list gains `PowerState.changed` (keep the block-observer form: the comment at `HeadView.swift:441` records the Swift 6 crash a selector observer caused). A head that is **speaking** keeps moving in saver (web: `ui-heads/bot-head.tsx:36`): only the idle loop stops.
4. **Timers** of item 3: wrap in `PowerPolls.wait(_, floor: .zero)` where they qualify. The push plugin watch (20 s for 15 min) qualifies; while it stretches, the 15 minutes stay wall-clock.
5. **ScreenSession** reads `PowerState.shared.saving` where it is on the main actor, or keeps `PowerState.read()` (the nonisolated static) off it. One source either way.
6. **Fixtures.** Keep `-HQDebugPowerSaving YES|NO`. Add, DEBUG only, in `OfflineDebug` next to it: a Darwin notification `hqn.power.toggle` that flips `PowerState.shared.override`, so a test can change state while the app runs (`xcrun simctl spawn <UDID> notifyutil -p hqn.power.toggle`). **DECISION 3.3**: the web's `--low-power-fixture` / `--thermal-fixture` names are not ported; one native switch covers both because saver is one boolean. Thermal is proven in the unit test instead (acceptance 1).

Never stretched: anything the person is waiting on (send, stream, stop, approval answers, pull to refresh, sign-in, voice, the Screen viewer's frames).

Keeps running in saver: `GlyphSpinner`, typing dots, a head that is speaking, voice surfaces (`TalkVisualView`, memo recorder), approval cards, every navigation and sheet transition. Glass is the system's and is left alone (iOS already adapts it in Low Power).

**DECISION 3.1** No wording, no banner, no switch: the web has none ("no switch"), and iOS already shows the yellow battery.

**DECISION 3.2** Saver stops the same decorative loops Reduce Motion does, and nothing more.

### Wire

None new. The effect is fewer calls of existing reads.

### Stand-in and commands

```
python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Power A"
```

Add a `"hits": {"<path or method>": [timestamps]}` map to `GET /__settings/state` (it has `calls` counts today; the timestamps are new), so a test can measure the gap between polls.

### Acceptance

1. Unit (`PowerPolls` tests exist from offline; add): `HQMotion.decorativeStill` is true for each of Reduce Motion, `PowerState.shared.override = true`; `PowerState.read()` logic for thermal is covered by a pure helper `PowerState.saving(lowPower:thermal:)` extracted from `read()` (serious → true, critical → true, fair → false).
2. Unit: `HeadMotionSettings` goes still when `override` flips to true and moves again when it flips back.
3. Simulator, `-HQDebugPowerSaving YES`: the fixture's roster hits are ≥ 3× farther apart than with `NO` (measure over 2 minutes each).
4. Simulator, saver on: an idle head is still and a skeleton does not pulse (two screenshots two seconds apart are pixel-identical in those regions); a streaming reply still shows moving typing dots; a speaking head still moves.
5. `notifyutil -p hqn.power.toggle` twice while a chat placeholder shimmers: it stops, then starts again, without reopening the screen.
6. `grep -rn 'isLowPowerModeEnabled\|thermalState' App HermesKit` shows `PowerPolls.swift` only (plus `ScreenSession` if it kept the static).

---

## 4. Largest Attachment (§19 L767)

### What the web app does

* Shared renderer: `REF/vendor/hermes/apps/shared/src/data-url-read-max.ts:15-27` default 16 MB, min 1, max 4096.
* The phone overrides both the cap and the default: `REF/src/bridge/platform.ts:117` and `REF/ios/App/App/HermesPlatform.swift:1334-1337` clamp to 1…32, key `hermes.attachmentLimitMb`; `REF/ios/App/App/PickedFiles.swift:30` default **32**.
* Control: `$V/app/settings/config-settings.tsx:521-590` `AttachmentSizeSetting`: a number field, empty = default, commits on blur or Enter, selection haptic on success.
* Phone wording (`REF/build/fe-platform-gates.ts`): title "Largest Attachment"; description "The largest file Hermes HQ attaches or previews, in MB. Up to 32, which is the default. Set on this device only, whichever profile it applies to."; unit "MB".

**DECISION 4.1** Default is **32 MB**, not the row's 16. 16 is the desktop renderer's number; the phone's own code and its own wording say 32.

### Native today

Hard-coded: `HermesKit/Attachments/AttachmentStaging.swift:13` `static let maxItemBytes: Int64 = 32 * 1024 * 1024`, read by `App/Chat/Attachments/ChatAttachmentsController.swift:302`, `HermesKit/Attachments/PhotoNormalizer.swift:44,73` and `App/Share/ShareRosterWriter.swift:212` (which writes it as `limitBytes` into the roster the Share extension reads). In `AttachmentStaging` the message "“\(name)” is larger than 32 MB, the most HQ Native can send." (wrong on the original identity: it names the app in a fixed string). `HermesKit/Media/MediaLoader.swift` has a 32 MB image ceiling and 512 MB for file previews.

### Design

* `HermesKit/Attachments/AttachmentLimit.swift`: `enum AttachmentLimit { static let range = 1...32; static let defaultMB = 32; static var megabytes: Int { get set }; static var bytes: Int }`, key `hqn.attachmentLimitMb` in `UserDefaults.standard`, absent = 32, values clamped on read.
* Settings root, section "Chat": a row **Largest Attachment** with the value on the right ("32 MB"). It pushes a small page (small title "Largest Attachment") with a `Stepper`-backed row "Size" showing "N MB" (1…32, step 1) and a "Use Default" button shown only when N ≠ 32. Footer: "The largest file Hermes HQ attaches or previews, in MB. Up to 32, which is the default. Set on this device only, whichever profile it applies to." The app name in that footer comes from `AppIdentity.displayName`, never a literal.
* **DECISION 4.2** A stepper, not a free number field: the range is 32 values, a stepper cannot hold an invalid value, and it needs no keyboard.
* Consumers:
  * `AttachmentStaging`: `maxItemBytes` reads `AttachmentLimit.bytes`. Message becomes "“<name>” is larger than <N> MB, the largest attachment this iPhone is set to send. You can change it in Settings › Largest Attachment." when N < 32, and "“<name>” is larger than 32 MB, the most <app name> can send." when N = 32.
  * `MediaLoader` inline image decode ceiling: `min(32 MB, AttachmentLimit.bytes)`. An image over the limit shows the existing file tile with its size and "Tap to open" instead of decoding inline (the web's "previews" half of the sentence).
  * The 512 MB Quick Look file preview is a download-to-disk path, not an in-memory read, and is left alone.
  * `PhotoNormalizer` and `ChatAttachmentsController` read the same value (they already read `maxItemBytes`; make that a computed `static var` backed by `AttachmentLimit.bytes` so no call site changes).
  * Share extension: `ShareRosterWriter` already rewrites the roster when `limitBytes` differs, so a change in Settings reaches the Share sheet at the next roster write. Trigger that write when the preference changes (observe the key). The extension itself needs no change.
  * Bot photo picker (`App/BotInfo/BotPhotoPicker.swift:36`, "That picture is too big. Choose one under 32 MB.") is a different limit (a head picture, not an attachment) and is left alone.

### Wire

None (device-local, as on the web phone).

### States and wording

| State | Shows |
|---|---|
| Default | Row value "32 MB"; page shows 32, no "Use Default" |
| Changed | Row value "N MB"; page shows "Use Default" |
| Attach over the limit | Staging refuses the item with the message above; other picked items still attach |
| Inline image over the limit | File tile, not an inline decode |

### Stand-in

`settings-gateway.py --port 10060` (any chat to attach into). Test files made by the test itself (`dd if=/dev/zero bs=1m count=3`) and pushed to the simulator's Files with `simctl addmedia` or the app's DEBUG `--stage-file=<path>` hook if one exists; else unit-level only for the picker half.

### Acceptance

1. Unit: clamp (0 → 1, 99 → 32, absent → 32); `bytes` maths.
2. Unit: `AttachmentStaging` with limit 2 refuses a 3 MB item with the exact message, accepts a 1 MB item in the same batch.
3. Unit: neither message contains a hard-coded product name (assert it contains `AppIdentity.displayName` on both identities).
4. UI: Settings › Largest Attachment, step down to 5, back out, row reads "5 MB"; relaunch, still 5; "Use Default" returns to 32 and hides itself.
5. Settings search finds "Largest Attachment".
6. Unit: after setting the limit to 5, `ShareRosterWriter` writes a roster whose `limitBytes` is 5 × 1024 × 1024.

---

## 5. Sessions: Auto-Archive Stale Chats; Default Project Folder (§19 L777)

### What the web app does

* `$V/app/settings/sessions-settings.tsx:209-313`: auto-archive writes `{sessions: {auto_archive: bool, auto_archive_days: int}}` to the gateway config. Wording: "Auto-Archive Stale Chats", "Archive after", "days of inactivity", failure "Could not update auto-archive".
* Default folder, `:330-432`, through `settings.getDefaultProjectDir / setDefaultProjectDir`. The phone's implementation is `REF/src/bridge/renderer-host.ts:70-111`:
  * stored per profile in localStorage `ios.directory.<profile>` (on the phone, not on the gateway);
  * validated with `GET /api/fs/list?path=<p>&profile=<owner>`; an error or a body with no `entries` array → "Gateway directory unavailable";
  * the default label is "the gateway’s workspace", with the resolved path in parentheses when known; the fallback path comes from `GET /api/config?profile=<p>` → `terminal.cwd`, ignoring `.`, `auto`, `cwd`.
* Wording: title "Default Project Folder"; description "New sessions start in this folder unless you pick another. Leave it unset to use your home directory."; "Defaults to <label>."; buttons "Change" / "Choose" / "Clear"; "Not set"; success "Default project directory updated — start a new chat (Ctrl/⌘+N) for it to take effect"; errors "Could not update default directory", "Could not clear default directory".
* Gateway contract: `session.create` accepts `cwd: str | None` and `cwd_explicit: bool | None` (`GW/contracts/sessions.py:119-140`). There is also `session.cwd.set {session_id, cwd}`.

### Native today

`App/Settings/Config/VaultBillingPages.swift:470-575`: `SessionsSettingsView` has "Auto-Archive Stale Chats" and "Archive After … days" (working, saved through `GatewayConfigStore`), and a Default Project Folder text field that is shown only when `SettingsHooks.defaultProjectFolderWired` is true (`App/Settings/SettingsScreens.swift:9-23`; it is false). `DefaultProjectFolder` stores under `hqn.defaultProjectFolder.<account>.<profile>`. Nothing reads the value.

### Design

1. **Use it.** Every place that creates a chat adds the folder when one is set for that account and profile:
   * The seven call sites after the train merge: `HermesKit/Store/BotStore.swift:536` (the bot's own chat), `HermesKit/Store/BotStore+Editing.swift:776` (a new bot's first chat), `App/AppModel.swift:171`, `HermesKit/Chat/LiveChatSession+ChatActions.swift:152` (New Chat in a chat), `HermesKit/Store/SessionStore+Actions.swift:372` (Sessions “+”, sends `follow_profile_config: true`), `HermesKit/Groups/GroupTurn.swift:232,235` (a group room's per-bot plumbing sessions).
   * **DECISION 5.3** Group plumbing sessions (`GroupTurn`, created with `room_plumbing`/hidden) do **not** get the folder: they are not chats the person started, and the web sends the default only from its new-chat path. The helper takes `kind: .chat | .plumbing` and adds `cwd` for `.chat` only. The scan test allows `GroupTurn.swift` by name with that reason.
   * `follow_profile_config: true` and `cwd` together are allowed by the contract (`GW/contracts/sessions.py:119-140`); `cwd_explicit: true` is what makes the folder win over the profile's `terminal.cwd` (the contract's own comment, #52589).
   * One helper so no site is missed: `SessionCreateParams.make(profile:title:…)` in HermesKit reads an injected `defaultFolder: (String /*profile*/) -> String?` and adds `"cwd": <path>, "cwd_explicit": true`. With no folder set it adds neither key (never `null`: keep the request identical to today's).
   * Guard test: a source scan that fails if `"session.create"` is called anywhere without going through the helper.
2. **Validate on save.** `GET /api/fs/list?path=<p>&profile=<profile>` (the reader exists: `HermesKit/Chat/ChatWorkspace.swift:65`). OK = a body with an `entries` array and no `error`.
3. **Page.** In `SessionsSettingsView`, section "Default Project Folder":
   * Row "Folder": value is the path (middle-truncated, monospaced digits not needed) or "Not set".
   * Tapping it pushes "Default Project Folder" (small title): a text field with placeholder "/Users/you/Projects/app", autocapitalisation and autocorrection off, keyboard `.URL`; a "Save" bar button (disabled while empty or unchanged); a "Clear" destructive row shown when a folder is set.
   * Footer: "New chats start in this folder on your gateway computer unless you pick another. Leave it empty to use the gateway’s workspace. Kept on this iPhone." (the string already in the file), followed, when the gateway's own default is known, by "Defaults to the gateway’s workspace (<terminal.cwd>)."
   * **DECISION 5.1** A typed path, not a folder browser. The web phone opens its gateway folder picker here; the native app's folder browser belongs to the workspace stream. If `WorkspacePage` gains a "choose a folder" mode before this ships, add a "Browse…" row that uses it; otherwise typed path only. The validation call makes a typed path safe.
4. `SettingsHooks.defaultProjectFolderWired = true` and delete the conditional once the tests pass.

### Wire

```
GET /api/fs/list?path=%2FUsers%2Fme%2FProjects%2Fapp&profile=default
→ 200 {"entries":[{"name":"src","path":"/Users/me/Projects/app/src","isDirectory":true}]}
→ 200 {"entries":[],"error":"No such directory"}        (treated as unavailable)
→ 404 / 500 / no entries array                           (treated as unavailable)

GET /api/config?profile=default → {"config":{"terminal":{"cwd":"/Users/me"}}}   (label only)

→ {"jsonrpc":"2.0","id":7,"method":"session.create",
   "params":{"profile":"default","title":"…","cwd":"/Users/me/Projects/app","cwd_explicit":true}}

PUT /api/config {"config":{"sessions":{"auto_archive":true,"auto_archive_days":14}}}
```

### States and wording

| State | Shows |
|---|---|
| Not set | "Folder — Not set" |
| Checking | Save bar button becomes a spinner; field disabled |
| Saved | Page pops; row shows the path; a notice "Default project folder updated. New chats start there." (**DECISION 5.2**: the web's "(Ctrl/⌘+N)" is desktop keyboard talk and is dropped) |
| Folder not found | Inline under the field: "Couldn’t open the folder." (UX study #180; the web says "Gateway directory unavailable"). Field keeps its text; nothing is stored |
| Offline / gateway unreachable | Inline: "Could not update default directory" |
| Clear | Row returns to "Not set"; failure (cannot happen locally, kept for parity of code path): "Could not clear default directory" |
| Folder vanishes later | `session.create` fails or the gateway ignores it. The app retries once **without** `cwd`, creates the chat, and shows the notice "The default project folder isn’t available. This chat started in the gateway’s workspace." It does not clear the setting |
| Auto-archive save fails | Existing: toggle rolls back, "Could not update auto-archive" |

### Stand-in

Extend `scripts/fixtures/settings-gateway.py`:

* `GET /api/fs/list`: answers from a small in-memory tree (`/Users/fixture`, `/Users/fixture/Projects/app`, …); any other path → `{"entries":[],"error":"No such directory"}`. Copy the shape from `scripts/fixtures/menus-gateway.py:751-760`.
* `session.create`: accept `cwd` and `cwd_explicit` (add them to the contract-key list so they do not answer 4000) and record them in `/__settings/state` under `"created": [{"profile","cwd","cwd_explicit"}]`.
* `POST /__settings/fs {"missing": ["/Users/fixture/Projects/app"]}` to make a folder disappear later.

```
python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Settings A"
HQN_SETTINGS_PORTS="10060 10061 10062" scripts/e2e-settings.sh <UDID>
```

### Acceptance

1. Unit: `SessionCreateParams` with and without a folder (keys present / absent, never null).
2. Source-scan test: no `session.create` outside the helper.
3. UI on the fixture: set `/Users/fixture/Projects/app` → row shows it; start a new chat from each entry point (Bots tap on a bot with no chat, Sessions "+", New Chat in the chat menu, a newly created bot) → fixture state shows `cwd` and `cwd_explicit: true` on each `session.create`. A group room turn on the groups fixture shows none.
4. Set `/nope` → "Couldn’t open the folder.", nothing stored, next new chat has no `cwd`.
5. Fixture `missing` then new chat → chat opens, the notice shows, state shows a second `session.create` without `cwd`.
6. Two profiles: the folder set for `default` is not sent for `coder`.
7. Auto-archive: toggle and days round-trip through `/__settings/state`; `/__settings/fail` on PUT shows "Could not update auto-archive" and rolls back. Re-run because the row is 🟡 as a whole.

---

## 6. Text Direction (§19 L750)

### What the web app does

* `$V/store/text-direction.ts:16-45`: `auto | ltr | rtl`, key `hermes.desktop.textDirection`, auto stored as absence.
* Applied to the composer (`composer/index.tsx:201`), your messages (`user-message-text.tsx:152`), the edit composer (`user-edit-composer.tsx:97`), bot prose (`markdown-text.tsx:857`, `message-parts.tsx:414`). Code blocks and KaTeX stay left to right.
* Phone wording: title "Text Direction" (`REF/build/fe-platform-gates.ts:367`); options "Auto", "Right to Left", "Left to Right" (`REF/build/ui-pages-gates.ts:195-196`); description "How chat messages and the composer choose their direction. Auto follows the first letter of each paragraph; pick a direction when mixed text lines up the wrong way. Code always stays left-to-right."
* Owner note (glitch-sweep.md): "Verified working, kept: Intro Splash, Text Direction." It is a control the owner has confirmed is real, so it must exist natively.

### Design

* `App/Settings/AppPreferences.swift`: `enum ChatTextDirection: String { case auto, ltr, rtl }`, key `hqn.textDirection`, absent = auto. Posts `ChatTextDirection.didChange`.
* Settings root, section "Chat": `Picker` row **Text Direction** with "Auto", "Right to Left", "Left to Right" (menu style). Section footer gains the web description verbatim.
* Applying it:
  * `App/Chat/Render/TextLayout.swift` and `ChatTextViews.swift`: every prose paragraph style gets `baseWritingDirection` = `.natural` (auto; TextKit resolves per paragraph from the first strong character, which is exactly "follows the first letter of each paragraph"), `.leftToRight` or `.rightToLeft`. `alignment` stays `.natural` so a right-to-left paragraph aligns right.
  * Code blocks, inline code, tables of code, maths: always `.leftToRight` with `.left` alignment, whatever the setting.
  * Lists and quotes: marker and indent follow the paragraph's resolved direction (head indent on the leading side).
  * Composer (`UITextView`): auto = leave `baseWritingDirection` natural per paragraph; forced = `typingAttributes` paragraph style plus `makeTextWritingDirectionRightToLeft/LeftToRight` on the whole range when the setting changes. Same for the edit composer.
  * Bubble side does not flip (your bubble stays trailing, as in Messages).
* The direction is part of the `TextLayout` cache key. On change: clear the height cache and reload the visible table without animation, keeping the scroll anchor.

### Wire

None.

### States

Auto / Right to Left / Left to Right; mixed transcript (English, Arabic, Hebrew, code) renders per the table above in each.

### Stand-in

Extend `settings-gateway.py` with a seeded chat "Directions" whose transcript has: an English paragraph, an Arabic paragraph, a Hebrew paragraph beginning with an English word, a mixed list, a fenced code block, an inline-code sentence in Arabic. Start: `python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json`.

### Acceptance

1. Unit (`TextLayout`): for each setting, the resolved writing direction of each seeded paragraph is as specified; code is always LTR.
2. Unit: heights are recomputed after a change (cache key differs).
3. UI: open "Directions"; Auto → Arabic paragraph is right-aligned, English left; Right to Left → English paragraph right-aligned; code block unchanged in all three (compare the code block's frame and first glyph x).
4. UI: composer with Right to Left: typed Latin text starts at the right edge.
5. Relaunch keeps the choice. Settings search finds "Text Direction".

---

## 7. Intro Splash (§19 L747)

### What the web app does

* `$V/store/intro-splash.ts:7-16`: key `hermes.desktop.intro-splash.v1`, default true.
* `$V/app/chat/index.tsx:561,635-644`: on an empty chat, when on, shows the wordmark and a prompt; when off, the empty chat is blank above the composer.
* Wording: "Intro Splash" / "The wordmark and prompt shown on an empty chat."
* Owner note (glitch-sweep.md): "Verified working, kept: Intro Splash, Text Direction."

### Native today

`App/Chat/ChatPlaceholderView.swift` `.empty(name:head:profile:)` draws an 80 pt head, the bot's name and one line. That is the native intro. No switch.

### Design

* Key `hqn.introSplash` (Bool, absent = on). Settings root, section "Chat": toggle **Intro Splash**. Footer sentence: "Intro Splash is the bot’s face and greeting on an empty chat."
  **DECISION 7.1** The web description says "wordmark and prompt"; the native empty chat has a head and a greeting, not a wordmark, so the sentence describes what the person will actually see disappear.
* Off: `.empty` renders nothing (the transcript area is blank; the composer and its placeholder are unchanged). The loading, error and "couldn’t load" placeholders are not the intro and are unaffected.
* VoiceOver when off: the transcript container keeps an accessibility label "No messages yet" so the screen is not silent.
* Change applies to open chats at once (observe the key).

### Wire

None.

### Stand-in

`settings-gateway.py --port 10060` (its seeded bot with no messages).

### Acceptance

1. UI: new empty chat shows head + name (on). Turn off → same chat shows neither; composer present; VoiceOver label "No messages yet" exists.
2. Send a message then delete the chat and open a new one: still no intro. Turn on: intro returns without relaunch.
3. A chat that fails to load still shows its error placeholder with the switch off.

---

## 8. Chat Font (§19 L746)

### What the web app does

* `$V/app/settings/chat-font-setting.tsx:23-24,35-163`: config path `desktop.font_family` on the gateway (per profile). Autosave 550 ms after the last keystroke with a sparse write `saveHermesConfig(setNested({}, 'desktop.font_family', value), writeScope)`; on failure the field rolls back and shows the error. A combobox with suggestions, a "Use theme font" reset, a live preview.
* Suggestions (`$V/themes/chat-font.ts:4-14`): OpenDyslexic, Atkinson Hyperlegible, Lexend, Inter, IBM Plex Sans, Source Sans 3, Noto Sans, Segoe UI, SF Pro Text. `resolveChatFontFamily` puts the chosen family ahead of the theme's stack, so a font the device lacks silently falls through to the theme font.
* Phone wording: title "Chat Font"; description (`REF/build/fe-platform-gates.ts:61`) "Choose a font for chat and the rest of the app, or leave it blank for the theme's font. It's saved with this profile's settings on your gateway."; placeholder "Font name"; "Preview"; sample "The quick brown fox jumps over the lazy dog. 0123456789"; reset "Use theme font". `REF/build/stress-d-gates.ts:87-97` adds an inline save failure to the row.

### Design

**DECISION 8.1** Native scope is **chat text** (bubbles, composer, bot prose). The app's own chrome (navigation bars, lists, Settings) stays the system font: system bars and Liquid Glass controls are drawn by iOS, and restyling them would fight the "native only" rule. The description is reworded to match what happens (below).

**DECISION 8.2** A list of fonts this iPhone actually has, not a free text field. A free field invites names that do nothing, and "never show a control that does nothing" applies to values too.

* Page "Chat Font" (pushed from Settings root, section "Chat", row value = current family or "System"):
  * Row "System" (check mark when `desktop.font_family` is empty). Wording for the web's "Use theme font".
  * Section "Easier to Read": those web suggestions that are present on the device (checked with `UIFont(name:)` / `UIFontDescriptor` family lookup; on a stock iPhone this is usually none unless the person installed fonts, in which case the section is omitted).
  * Section "On This iPhone": `UIFont.familyNames` sorted, minus symbol and emoji families (filter: the family's regular face must have glyphs for "Aa0"), plus fonts installed through iOS font apps (`CTFontManagerCopyRegisteredFontDescriptors(.persistent, true)`). Each row is drawn in its own face. A search field (`.searchable`) filters by name.
  * Section "Preview": "The quick brown fox jumps over the lazy dog. 0123456789" in the chosen face at body size.
  * Footer: "Choose a font for chat, or pick System. It’s saved with this profile’s settings on your gateway."
  * If the gateway holds a family this iPhone lacks (set from the desktop): a first row "<Name> — not on this iPhone", checked, and footer line "<Name> was chosen on another device. This iPhone doesn’t have it, so chat uses the system font here." Picking anything else replaces it; leaving the page changes nothing.
* Saving: `GatewayConfigStore.set("desktop.font_family", value)` then `flush()` on pick (no debounce needed for a tap). Sparse `PUT /api/config`. Optimistic check mark; on failure roll back and show under the list: "Couldn’t save the chat font. <server message or “Check your connection and try again.”>"
* Applying, **through the font factory that already exists** (`App/Theme/ThemeFonts.swift`; do not add a second resolver):
  * `ChatStyle` builds every font with `HQFont.preferred(_:compatibleWith:)` and `HQFont.face(ofSize:weight:)` (`App/Chat/ChatStyle.swift:53-76`). Those end in `HQFont.face(size:weight:family:)` (`ThemeFonts.swift:43-50`), which already does the right thing for a family: descriptor by family name, bold trait for semibold and up, and **falls back to the system font when the device lacks the family**.
  * `ChatStyle.make(category:bold:)` gains `chatFamily: String?`. Inside the initialiser the two local helpers (`font(_:)`, `capped`) pass a family: `chatFamily ?? (the skin's sansFamily when the Desktop Look is on) ?? nil`. That is the web's order exactly (`resolveChatFontFamily` puts the chosen family ahead of the theme's stack). Add an overload `HQFont.face(ofSize:weight:chatFamily:)` for this so the look-off path, which returns the plain system font today, can still take a chat family.
  * Sizes are untouched: they still come from `HQFont.preferred(style).pointSize`, so Dynamic Type, UI Scale and the Desktop Look sizes all keep working with a custom family.
  * Monospaced code keeps `HQFont.mono` (the web also keeps code in its mono stack). Italic: `withTraits` already asks the descriptor (`ChatStyle.swift:74-76`) and returns the upright face when the family has no italic; never a synthetic slant.
  * Bold Text (`HQFont.drawn`) keeps stepping weights as today.
* Cache: `ChatStyleCache.style(for:)` keys on `category + ThemeTable.layoutTag + bold` (`ChatStyle.swift:118-130`). Add `"|font:" + family` to that key. `TextLayout` heights are keyed by the style, so they follow. On change (local pick, or a config refresh that brings a new value from the desktop): the same path a theme change takes today (find what observes `ThemeTable` layout changes in `ChatViewController` and post through it), reloading the visible table with the anchor kept.
* The value is per profile: a chat uses its own profile's family. `ChatStyleCache.style(for:)` therefore takes the family as a parameter from the chat screen (which knows its profile's config), not from a global.
* The composer (`UITextView`) and the edit composer take `style.body`.
* **DECISION 8.3** With the Desktop Look on and a chat font set, the chat font wins in chat text and the skin's typeface stays everywhere else, as on the web.

### Wire

```
GET /api/config?profile=default → {"config":{"desktop":{"font_family":"Georgia"}, …}}
PUT /api/config?profile=default {"config":{"desktop":{"font_family":"Georgia"}}}   → 200 {"ok":true}
PUT … {"config":{"desktop":{"font_family":""}}}                                      (System)
```

Exact query/body shape as `HermesKit/Settings/GatewaySettingsAPI.swift:31-33` already sends.

### States and wording

| State | Shows |
|---|---|
| Loading config | Existing settings skeleton |
| System | "System" checked; root row value "System" |
| A family | That row checked; root row value is the family; chat redraws |
| Family not on this iPhone | The extra row and footer line above |
| Save failed | Roll back, inline error above |
| Config unavailable (older gateway without `desktop`) | Page works; the key is simply created on first save |
| Offline | Rows disabled, existing "Not connected" settings banner |

### Stand-in

`settings-gateway.py` already serves `/api/config`. Add: `desktop.font_family` to its defaults/schema; `POST /__settings/desktop-edit {"path":"desktop.font_family","value":"Zapfino"}` already exists as a generic control (use it for the "changed on the desktop" and "not on this iPhone" cases with `"Segoe UI"`); `POST /__settings/fail {"method":"PUT","path":"/api/config","times":1}` for the failure.

```
python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Settings A"
```

### Acceptance

1. Unit: resolver returns the system font for "", a missing family, and a symbol font; returns the family (scaled) otherwise; code font unchanged.
2. Unit: Dynamic Type: resolved point size at AX5 > at Large for a custom family.
3. UI: pick "Georgia" → fixture state shows the sparse PUT with only `desktop.font_family`; open a chat → a bubble label's font family is Georgia (assert through the accessibility/debug font dump, plus a screenshot).
4. Fixture desktop-edit to "Segoe UI" → page shows the "not on this iPhone" row and footer; chat uses the system font.
5. Fixture failure → check mark returns to the previous row and the inline error shows.
6. Two profiles with different fonts: each chat uses its own.
6a. Desktop Look on with a skin that has its own typeface, chat font Georgia: bubbles are Georgia at the Desktop Look's sizes; the navigation title is the skin's face. Chat font cleared: bubbles return to the skin's face.
6b. Bold Text on (`-HQA11yBoldText YES` or the a11y debug flag the project uses): bold weights still step with a custom family.
7. Long transcript (2,000 messages): changing the font does not hitch more than one frame budget on reload of the visible rows (see STRESS PLAN).

---

## 9. Message Reactions (§19 L751) and the React… hold-menu item (talk's L365)

### What the web app does

* Switch: `$V/store/reactions-enabled.ts:20-35`, key `hermes.desktop.reactions.v1` ('on' / 'off'), default **off**. It mirrors to the gateway through `mirrorDisplayToggle('display.message_reactions', …)`; `$V/store/display-toggles.ts:38-49` sends JSON-RPC `config.set {key: "display.message_reactions", value: "true" | "false"}` routed to the active profile on change (contract `ConfigSetParams`: `key`, `value`, `session_id?`, `profile?`; the gateway lists exactly three display keys, `server.py:1891`, and answers **4002** for any other), and again on connect **only if the person has touched the switch** (so a default never overwrites the gateway).
* Tapbacks: `$V/store/reactions.ts:9` `QUICK_REACTIONS = ['❤️','👍','👎','😂','‼️','❓']`. One reaction per author per message; tapping your current one retracts it. Optimistic, then the server's list wins; on failure it rolls back and says "Could not react".
* Call: `message.react {session_id, profile?, row_id | newest_role, emoji (null clears), author}` → `{row_id, reactions: [{emoji, author, at, seen}]}`. Contract (`GW/contracts/billing_delegation_pets.py:467-491`, `common.py:214-221`): `row_id` is an **integer** (`messages.id`); `author` is the enum `"user" | "agent"`; "`emoji` null clears; the same emoji again retracts". The web sends `author: 'user'` and either `row_id` or `newest_role: <the message's role>` (`$V/store/reactions.ts:55,89-97`).
* Event: `message.reaction {row_id, reactions, role}` when the bot reacts to your message.
* Transcript rows carry `reactions` and `row_id`.
* Picker: the quick row plus "More emoji" (+) opening a full picker (`$V/components/assistant-ui/thread/message-reactions.tsx`, `use-message-reactions.ts`). Double-click = the first tapback. **Reactions already in the data still render when the switch is off.**
* Phone hold menu: `REF/src/ui-chat/message-menu.ts:23-24`: `if (kind === 'you' && ctx.canReact) items.push(action('react', 'React…', 'face.smiling'))`: on **your own** bubbles only, after Select Text. `REF/src/touch-user-bubble.tsx:47,118`.
* Wording: "Message Reactions" / "iMessage-style emoji tapbacks — react to messages, and Hermes can react to yours."
* Owner note (glitch-sweep.md) lists Reactions under "Not exercised": it was never confirmed working on the phone. Build it to the contract and prove it on the fixture.

### Design

* Settings root, section "Chat": toggle **Message Reactions** (default Off). Footer sentence: "Message Reactions are iMessage-style emoji tapbacks: react to messages, and Hermes can react to yours."
  * Keys: `hqn.reactions` (Bool) and `hqn.reactions.touched` (Bool).
  * On change: `config.set` for **every profile of the current gateway** that has a live connection scope (the web sends the active profile; the native app shows all bots at once, so each bot must agree with the switch). Failure does not roll the switch back (it is a device preference); it retries at the next connect, exactly like the web's on-connect mirror.
  * On connect: if touched, send once per profile.
* Model: `ChatMessage` gains `reactions: [Reaction]` (`struct Reaction { emoji: String; author: String; at: Double?; seen: Bool? }`; `author` is kept as a string so an unknown author still renders, and `isMine` is `author == "user"`), decoded leniently from transcript rows (missing or malformed → empty; unknown keys ignored). `rowId: Int?` exists (`HermesKit/Contracts.swift:248`).
* Rendering: a chip row under the bubble, hugging the bubble's side: one capsule per distinct emoji with a count when > 1 ("❤️ 2"), yours tinted. Height is part of the row's `TextLayout` height (exact heights; no self-sizing). Rendered whenever the data has reactions, **whether the switch is on or off** (web behaviour).
* Reacting (switch on, connected, message has a row id or is the newest of its role):
  * **As built (b22e8492, 2026-10-24; this list is the original design):** the hold menu has a **React** submenu right after Select Text, on your bubbles **and the bot's** (`ChatMenus.reactMenu`): the six quick Tapbacks as rows, yours ticked, picking it again takes it off. There is no popover and no "+" emoji field. A failure alerts "Couldn’t React" (an older Hermes: "Reactions Aren’t Available").
  * Hold menu: on your own bubbles, after "Select Text": **React…** with `face.smiling`. The menu is `MessageMenuModel` (`HermesKit/Chat/ChatActionsModel.swift:121-165`): add `MessageMenuItemID.react`, `MessageMenuContext.canReact`, and in `rows(_:_:)` under `case .you:` append `row(.react, "React…", "face.smiling", writes: true, ctx)` right after the Select Text row (talk's spec `3x-talk.md:254` reserved exactly this place). `writes: true` gives it the model's existing offline/read-only disabling; on top of that the row is **omitted**, not greyed, when `canReact` is false. Not shown when the switch is off or the chat is read-only/offline (never a dead item).
  * Tapping React… opens a small glass popover anchored to the bubble (`UIPopoverPresentationController`, system glass): the six quick emoji in a row, your current one highlighted, then a "+" button. "+" focuses a hidden one-character `UITextField` subclass whose `textInputMode` override returns the emoji input mode (public API: pick the entry of `UITextInputMode.activeInputModes` whose `primaryLanguage` is "emoji"). When the person has no emoji keyboard enabled, the "+" is omitted (never a dead control). The first grapheme typed is the reaction; the field resigns.
  * **DECISION 9.1** No double-tap shortcut in v1. Double-tap on a bubble already has meaning in the native chat (text selection / link taps nearby) and the web's double-click is a pointer idiom. The hold menu is the phone's own route (`message-menu.ts`).
  * **DECISION 9.2** (superseded: the built menu offers React on the bot's messages too) React… appears on your own bubbles only, as the web phone does. Reacting to bot messages is the desktop's hover bar; adding it natively is a product change to raise with the owner, not parity.
  * Tapping one of your own chips retracts it (same call with `emoji: null`). Tapping a bot's chip does nothing and is not a button (no button trait).
* Optimistic: apply `applyReaction` locally (replace your previous one, or remove if the same), send, then replace with the server's list. Failure: restore the previous list and show the notice "Could not react".
* `message.reaction` events for any resumed chat update the row in place (find by `row_id`; if not loaded, ignore). When the chat is on screen the chip pops in with the standard add animation (none under Reduce Motion).
* Haptic: `Haptics.play(.selection)` when you pick; `.error` on failure.

### Wire

```
→ {"method":"config.set","params":{"key":"display.message_reactions","value":"true","profile":"default"}}
← {"result":{"key":"display.message_reactions","value":true}}
← {"error":{"code":4002,"message":"…"}}                         (a gateway that does not list the key: see states)

→ {"method":"message.react","params":{"session_id":"s1","row_id":42,"emoji":"❤️","author":"user"}}
← {"result":{"row_id":42,"reactions":[{"emoji":"❤️","author":"user","at":1760000000.1,"seen":false}]}}

→ {"method":"message.react","params":{"session_id":"s1","newest_role":"user","emoji":null,"author":"user"}}
← {"result":{"row_id":42,"reactions":[]}}

← event {"type":"message.reaction","session_id":"s1","payload":{"row_id":42,"role":"user",
         "reactions":[{"emoji":"👍","author":"agent","at":1760000001.0,"seen":false}]}}
```

Checked against `GW/contracts` in revision 2. Send **only** these keys: an extra param answers 4000. `row_id` goes out as a JSON number, never a string. Retracting: the app sends `emoji: null` (clear); it never relies on "same emoji again retracts", so a double send cannot flip the state back.

### States and wording

| State | Shows |
|---|---|
| Switch off, no reactions in data | No chips, no React… item |
| Switch off, reactions in data | Chips render; no React… item; chips are not tappable |
| Switch on | React… on your bubbles; your chips tappable |
| Sending | Chip shows at once |
| Failed | Chip reverts; notice "Could not react" |
| Gateway too old (`message.react` method not found; or `config.set` answers 4002 for the key) | First failure: notice "This Hermes doesn’t support reactions yet." and React… is hidden for that gateway for the rest of the run |
| Offline | React… hidden |
| Message with no row id that is not the newest of its role | React… hidden |

### Stand-in

Extend `settings-gateway.py`:

* seeded chat "Reactions" whose rows carry an integer `row_id` and two of them `reactions` (one from `agent`, one from `user`);
* `message.react` (one per author, null clears, same emoji again retracts as the real gateway does, returns the list; stores per row; **rejects unknown params with 4000 and a string `row_id` with a validation error**, so a wrong client fails the test);
* `config.set` recording `{key, value, profile}` in state;
* `POST /__settings/emit {"type":"message.reaction","session_id":…,"payload":{…}}` to push an event to connected sockets resumed on that session;
* `POST /__settings/fail {"method":"message.react","times":1}`; `{"method":"message.react","code":-32601}` for the old-gateway case.

```
python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Settings A"
```

### Acceptance

1. Unit: `applyReaction` (add, replace, retract; other authors untouched). Lenient decode (missing, null, wrong type, 500 reactions on one row).
2. Unit: row height includes the chip row; with 30 distinct emoji the chips wrap and the height matches the drawn frame.
3. UI: switch off → open "Reactions": the two seeded chips show; hold your bubble: no React…. Switch on → fixture state shows `config.set … "true"` for each profile; hold: React… after Select Text; pick ❤️ → chip appears, fixture row has it; tap the chip → gone, fixture row empty.
4. Fixture emit `message.reaction` → a 👍 chip appears on the open chat without a reload.
5. Fixture fail once → chip reverts, "Could not react".
6. Old-gateway case → the notice once, React… gone.
7. Relaunch with the switch untouched on a fresh install: no `config.set` is sent (state proves it).

---

## 10. Vibe Hearts (§19 L752)

### What the web app does

* `$V/store/vibe-hearts-enabled.ts:16-30`: key `hermes.desktop.vibeHearts.v1`, default **on**.
* `$V/components/chat/vibe-hearts.tsx`: on the gateway event `reaction {kind}` (`GW/events.py:246-251`, raised from `agent_callbacks.py:164`), 12 pink (#ff9ec4) pixel hearts rise from the composer, each lasting 320 to 700 ms.
* Wording: "Vibe Hearts" / "Floating hearts when you say thanks, ily, good bot, or send a heart. Separate from Message Reactions above."
* Owner note (glitch-sweep.md) lists it under "Not exercised".

### Design

* Key `hqn.vibeHearts` (Bool, absent = on). Settings root, section "Chat", directly under Message Reactions: toggle **Vibe Hearts**. Footer sentence: "Vibe Hearts are floating hearts when you say thanks, ily, good bot, or send a heart. Separate from Message Reactions."
* `LiveChatSession` surfaces the `reaction` event as `onVibe(kind: String)`. The chat screen, only when it is the visible chat and the app is active, runs `VibeHeartsView.burst()`:
  * a `CAEmitterLayer` above the transcript and below the composer glass, emitter line along the composer's top edge;
  * 12 hearts per burst, colour #FF9EC4, the `heart.fill` symbol rendered once to a small image (crisp at scale; **DECISION 10.1**: a system heart, not a hand-drawn pixel sprite; it is decoration, and the symbol follows the "native" rule);
  * rise 80 to 140 pt, slight sideways drift, lifetime 0.32 to 0.70 s, fade out; the layer removes itself after 1 s;
  * no interaction (`isUserInteractionEnabled = false`), hidden from accessibility.
* Not shown when: the switch is off, Reduce Motion is on, power saver is on (`HQMotion.decorativeStill`, section 3), the chat is not on screen, or a burst is already running (drop, do not queue: at most one burst at a time).
* **DECISION 10.2** Any `kind` triggers the same hearts; the web does the same today. Unknown payloads are ignored safely.

### Wire

```
← event {"type":"reaction","session_id":"s1","payload":{"kind":"heart"}}
```

### Stand-in

`settings-gateway.py` + `POST /__settings/emit {"type":"reaction","session_id":"<id>","payload":{"kind":"heart"}}`. Optionally the fixture's echo turn emits it when the sent text matches `thanks|ily|good bot|❤️`, so the whole flow can be driven by typing.

### Acceptance

1. Unit: the gate (`shouldBurst`) for each suppressing condition.
2. UI: open a chat, emit → a debug counter `vibeBursts` (accessibility label on the DEBUG overlay) goes 0 → 1 and a screenshot taken 150 ms later contains pink pixels above the composer; switch off → emit → counter unchanged.
3. `-HQDebugPowerSaving YES` → emit → unchanged. Reduce Motion on (the a11y stream's DEBUG flag `-HQA11yReduceMotion YES`) → unchanged.
4. 50 emits in one second → at most one burst alive at a time, no dropped frames (STRESS PLAN).

---

## 11. Inline Embeds (§19 L753)

### What the web app does

* `$V/store/embed-consent.ts:8-37`: mode `always | ask | off` (key `hermes.desktop.embed-mode`, default **ask**) and a list of allowed providers (key `hermes.desktop.embed-allowed`).
* `$V/components/assistant-ui/embeds/url-embed.tsx:46-88` and `embed-consent.tsx:15-55`: a recognised link standing alone becomes, in Ask mode, a placeholder with a primary button "Load <label>", a second "Always allow <label>", and the host as a caption (twitter shows "x.com"). Nothing is fetched from the third party before consent. Always loads at once; Off leaves a plain link.
* Providers (`$V/components/assistant-ui/embeds/providers/index.ts:14`): youtube, vimeo, instagram, pinterest, tiktok, twitter, spotify, maps (Google Maps / OpenStreetMap). YouTube embeds `https://www.youtube-nocookie.com/embed/<id>`.
* Wording: "Inline Embeds" / "Rich previews load from third-party sites (YouTube, X, …). Ask shows a placeholder until you allow each one; Always loads them automatically; Off keeps plain links."; options "Ask" / "Always" / "Off"; reset button "Reset N allowed service(s)".
* Owner note (glitch-sweep.md): "Not exercised".

### Design

**DECISION 11.1** No web view. The architecture rule D-P8 is "no WKWebView in the app", and the reason people came to the native build is the owner's "Wow. It's already SO MUCH smoother." An iframe player in a transcript row is the opposite of that. The native embed is a **rich link card**: thumbnail, title, site, drawn natively from the page's public link metadata (LinkPresentation's `LPMetadataProvider`, which fetches metadata only and shows no web content). Tapping it opens the link the way links already open in the app (in-app Safari view). The privacy contract is the web's exactly: in Ask mode **no request leaves the phone for that site until the person taps Load**.

* Settings root, section "Chat": `Picker` **Inline Embeds** with "Ask", "Always", "Off" (default Ask). Footer sentence: "Rich previews load from third-party sites (YouTube, X, …). Ask shows a placeholder until you allow each one; Always loads them automatically; Off keeps plain links." Below it, only when the allowed list is not empty, a button row **Reset 1 Allowed Service** / **Reset N Allowed Services** (plain, not destructive).
* Keys: `hqn.embedMode` (`ask|always|off`), `hqn.embedAllowed` ([String] provider ids).
* `HermesKit/Chat/EmbedProviders.swift`: a port of the web matchers, pure functions, one per provider: `match(_ url: URL) -> EmbedMatch?` with `{provider, label, host, canonicalURL}`. Labels: "YouTube", "Vimeo", "Instagram", "Pinterest", "TikTok", "X", "Spotify", "Google Maps", "OpenStreetMap". Port the regular expressions from `$V/components/assistant-ui/embeds/providers/*.ts` one for one, with the web's own test vectors where the vendor tree has them.
* Which links: only a recognised link that is **alone in its paragraph** in a bot message (the web's rule). Links inside sentences stay links. Your own messages: same rule.
* Card states, all fixed heights so `TextLayout` can size rows without self-sizing:
  * **Placeholder (Ask, provider not allowed)**: 96 pt card; provider glyph (SF Symbol: `play.rectangle`, `music.note`, `map`, `photo`, `bubble.left`), primary button "Load YouTube", secondary "Always Allow YouTube", caption "youtube.com". Tapping the caption or the card body outside the buttons opens the link.
  * **Loading**: 96 pt card with a `GlyphSpinner` and the host.
  * **Loaded**: 232 pt card when there is an image (16:9 thumbnail at card width, capped 180 pt, then title up to 2 lines and the host), 72 pt without one (title + host). The thumbnail is fetched through `RemoteImageFetcher` with the image size ceiling of section 4.
  * **Failed / no metadata**: collapses to the plain link, silently (the link still works). No retry button; a pull-to-refresh of the chat tries again.
  * **Off**: plain link, no card.
* Metadata cache: memory + disk (`Caches/embeds/<sha256(url)>.json` + thumbnail), 7 days, 200 entries, so scrolling back never refetches and offline shows what was loaded before.
* Timeouts: `LPMetadataProvider.timeout = 8`. At most 2 fetches in flight per chat; cells off screen cancel theirs.
* "Always Allow <label>" adds the provider id and loads every placeholder of that provider in the open chat. Reset clears the list; loaded cards on screen stay until the chat reloads (the web does the same).
* Maps: **DECISION 11.2** Google Maps and OpenStreetMap links get the same link card (title + host, usually no image). A live `MKMapView` per row is out of scope: it is heavy in a table and adds a second data source the person did not consent to.
* VoiceOver: placeholder reads "YouTube preview. Not loaded. Buttons: Load YouTube, Always Allow YouTube." Loaded reads "<title>, youtube.com, link".

### Wire

No gateway calls. Third-party: one metadata GET to the link's own URL and one image GET, only after consent (Ask) or in Always. Nothing in Off.

### States and wording

Covered above. Wording list for the string table: "Load <label>", "Always Allow <label>", "Reset 1 Allowed Service", "Reset N Allowed Services", options "Ask" / "Always" / "Off".

### Stand-in

The gateway side is just a transcript. Extend `settings-gateway.py`:

* seeded chat "Embeds" with: a YouTube link alone, an X link alone, a Spotify link alone, a YouTube link inside a sentence, an unknown-site link alone, and 40 YouTube links in one message (stress).
* For tests that must not touch the real internet: the fixture serves fake provider pages itself at `http://127.0.0.1:10060/__embed/<provider>/<id>` (HTML with `og:title` and `og:image` pointing at a fixture PNG), `…/__embed/slow/<id>` (sleeps 20 s), `…/__embed/broken/<id>` (500), and counts hits in `/__settings/state` under `"embedHits"`. The app has a DEBUG launch arg `--embed-host-map=youtube.com=127.0.0.1:10060/__embed/youtube` that rewrites the fetch URL after matching, so the real matchers run and no third party is contacted.

```
python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Settings A"
```

### Acceptance

1. Unit: each matcher against the web's vectors (watch, youtu.be, shorts, playlists that should not match, x.com and twitter.com status links, Spotify track/album/playlist, maps).
2. Unit: "alone in its paragraph" detection; row heights for the four card states.
3. UI, Ask: open "Embeds": three placeholders, the in-sentence link is a link, the unknown site is a link; fixture `embedHits` is **0**. Tap "Load YouTube" → card with title and thumbnail; hits 1 (page) + 1 (image).
4. "Always Allow X" → the X placeholder loads; Settings shows "Reset 1 Allowed Service"; reset → button disappears; reopen the chat → X is a placeholder again.
5. Always: reopen → all three load without taps. Off: reopen → three plain links, hits unchanged.
6. Slow provider → spinner, then plain link after 8 s; broken → plain link; the transcript does not jump when a card collapses (row height change is animated once, anchor kept).
7. Offline after a load: card still shows from cache.
8. Scan test: no `import WebKit` under `App/` or `HermesKit/`.

---

## 12. File Browser (§19 L754)

### What the web app does

* `$V/store/layout.ts:95-100,585-597` `$fileBrowserOpen`: on the desktop the switch shows a file browser pane beside the chat when the chat has a workspace. `REF/build/renderer-gates.ts:196` makes the narrow (phone) layout reveal that pane.
* Wording: "File Browser" / "Show the file browser beside the chat when a workspace is open. The titlebar toggle changes this too."

### Native today

Files exist: `App/Chat/Menus/WorkspacePages.swift` `WorkspacePage(kind: .files | .changes, workspace:, directory:)`, reached from the chat's ⋯ menu › More › Files.

### Design

A phone has no "beside". **DECISION 12.1** The switch decides whether Files is **one tap away in the chat bar** or stays in the ⋯ menu:

* Key `hqn.fileBrowser` (Bool, absent = off). Settings root, section "Chat": toggle **File Browser**. Footer sentence: "File Browser puts a Files button at the top of chats that have a project folder."
* On, and the open chat has a workspace (the same condition the ⋯ › More › Files item uses): a `folder` bar button in the chat's navigation bar, leading the existing trailing items (system bar button, system glass). Tap opens the existing Files sheet at the chat's folder. Accessibility label "Files".
* On, chat without a workspace: no button (never a dead control).
* Off (default): no button; Files stays under ⋯ › More.
* The ⋯ › More › Files item remains in both states.
* The bar updates live when the chat's folder changes (`session.cwd.set` result / session info refresh) and when the switch changes.
* Title-width check: with the folder button, the chat title view must still fit a 3-item trailing bar on the smallest width; if the bar would exceed three trailing items, Files replaces nothing and the least-used existing item moves under ⋯ (builder picks by reading the current bar; record which in the commit message).

### Wire

None new (the sheet uses `GET /api/fs/list` as today).

### Stand-in

`scripts/fixtures/menus-gateway.py` serves chats with and without a workspace and `/api/fs/list` (`menus-gateway.py:751`). Check its flags with `--help`; start it on this stream's port:

```
python3 scripts/fixtures/menus-gateway.py --port 10061 --credentials build/m9-settings/menus.json
```

(If it has no `--port` flag, add one in the same style as `settings-gateway.py`; do not use its default port.)

### Acceptance

1. UI: switch off → workspace chat has no folder button. On → the button appears without reopening the chat; tap → Files sheet lists the fixture's entries.
2. Chat without a workspace → no button in either state.
3. Largest accessibility size and the smallest phone width: bar items do not overlap the title (screenshot).
4. Relaunch keeps the choice; Settings search finds "File Browser".

---

## 13. Hidden on phone (§19 L759) — proposed web-shell-only

### What the web app does

`REF/src/bridge/phone-capabilities.ts:17-19` `phoneOnlySettings` hides, on iPhone, the desktop renderer's: tours, session density, user bubble, tool view, hide code diffs, reasoning collapsed, model pricing. The row's default column is "n/a" and its value "(Off)".

Owner note (glitch-sweep.md): the owner reported dead Settings controls; the fix was to hide "user-bubble, session-density, tool-view, hide-code-diffs, reasoning-collapsed" on iPhone because they did nothing there.

### Proposal

**DECISION 13.1 — web-shell-only.** This row is not a feature: it is a list of desktop controls the web shell had to hide because the embedded desktop renderer would otherwise show them. The native app has no desktop renderer, so there is nothing to hide; the native equivalents that do something already exist under their own rows (Tool Calls page, In-App Tips). Justification, item by item:

| Web control | Why it has no native row |
|---|---|
| Tours | The desktop's guided tours. Native has "In-App Tips" (its own row, built). |
| Session density | Desktop sidebar row density. Native lists use system metrics and Dynamic Type. |
| User bubble | Desktop choice of bubble vs flat user messages. Native chat is bubbles by design. |
| Tool view | Desktop tool-call rendering mode. Native has the Tool Calls settings page (own row, built). |
| Hide code diffs | Desktop diff panes. Covered natively by Tool Calls options where applicable. |
| Reasoning collapsed | Same: Tool Calls / reasoning display, own rows. |
| Model pricing | Desktop model list price column, off on the phone. |

What "done" means for a done-by-absence row, so it is still seen working:

* Test `SettingsAbsenceTests`: the Settings search index (`HermesKit/Settings/SettingsSearch.swift`) and the root's row titles contain none of: "Tours", "Session Density", "User Bubble", "Tool View", "Hide Code Diffs", "Reasoning Collapsed", "Model Pricing".
* The ledger outcome becomes `web-shell-only` with this section as its reason. A Ship agent, not this stream, edits the parity file.

---

## 14. Local alerts straight from the gateway socket (§12 L554)

### What the web app does

* `REF/docs/notifications.md:58-67` and `REF/ios/App/App/HermesPlatform.swift:557-588`: the native shell watches **every** frame on the gateway socket (`observe(frame:)`) for `message.complete` and `approval`, and raises a local alert for any chat but the one on screen, following Messages' rules (no alert for what you are looking at).
* Wording table in `REF/docs/notifications.md`: finished reply = the bot's name as title and the reply's first line; failed = "Couldn’t finish: …", or with previews off "<Bot> couldn’t finish a reply".

### Native today

`App/AppModel.swift:453-480` `gatewayEvent` → `NotificationHub.observeTurnEnd / observeRequest`: finished and failed replies of chats **this run opened** (`runningChats[event.sessionId]`), and every approval, question or password request the app holds. `PushRegistrar.shared.delivers(kind)` suppresses the local alert when the push plugin delivers that kind, so there are no doubles.

Gap in the row: "not yet replies of chats it never opened (the push plugin covers those)".

### Why the gap exists

The gateway sends turn events only to transports that resumed the session. The web shell has the same limit; it merely resumes more sessions because the renderer keeps them warm. A chat started from the desktop, a cron job or another phone never reaches this phone's socket. Only the global broadcasts do (`sessions.changed`, `session.reclaimed`, `approval.cancelled`).

### Design

**DECISION 14.1** Close the gap with **list-derived alerts**, without resuming sessions the person did not open (resuming every chat would take over transports and cost the gateway memory; the owner's Hermes is one Mac).

* Source: the roster / sessions list the app already refreshes (on `sessions.changed`, on foreground, on its poll, which already goes through `PowerPolls`).
* `NotificationWatch` (HermesKit, pure): keeps, per session id, the last seen `{working: Bool, lastActivity: Double, unread: Bool}`. On each refresh, for every session:
  * transition `working: true → false` with `lastActivity` newer than the stored one, **and**
  * the session is not on screen, not one of `runningChats` (the socket path owns those), not muted (`BotMuteCenter`), and
  * `PushRegistrar.shared.delivers("message.complete")` is false for this gateway,
  * → raise one finished-reply alert: title = bot name (the same directory `refreshNotificationDirectory` builds), body = the row's preview line (previews on) or "<Bot> finished a reply" (previews off; the string `NotificationText` already has for turnDone).
* First refresh after launch or after a gateway switch only records a baseline; it never alerts (no burst of stale alerts).
* A session first seen already idle with unread = true after the baseline counts as finished (a turn that began and ended between two refreshes).
* Failed replies cannot be told from finished ones from the list. **DECISION 14.2**: list-derived alerts are always the "finished" kind; the row's failed half stays covered for opened chats (socket) and by the push plugin.
* De-dupe id: `"list:<sessionId>:<lastActivity>"` through the existing `post(… id:)`; the socket path's id for the same turn wins if both fire.
* Honest limit (state it in the row's note when closing): iOS suspends the app shortly after it leaves the foreground, so local alerts of any kind arrive only while the app is active or in its background grace. Alerts while the phone is in a pocket are the push plugin's job. That is equally true of the web shell.

### Wire

Existing: `sessions.changed` broadcast; the roster/sessions list read the app already makes. No new call. (Field names for working/last activity/unread/preview: use what `BotStore` already decodes; no contract change.)

### Stand-in

`scripts/fixtures/push-gateway.py` (it models plugin present/absent) or `settings-gateway.py`. Add to whichever is used a control to simulate a turn on a session **no client resumed**:

```
POST /__settings/ghost-turn {"session_id":"ghost1","profile":"coder","preview":"Done. 3 files changed.","seconds":2}
```

which flips the row to working, broadcasts `sessions.changed`, then after N seconds sets it idle with a newer activity time, unread true and the preview, and broadcasts again.

```
python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Settings A"
```

### Acceptance

1. Unit (`NotificationWatch`): baseline never alerts; working→idle alerts once; same state twice alerts once; on-screen, muted, opened-by-this-run and push-delivered sessions never alert; a gateway switch resets the baseline.
2. Simulator, notifications allowed (`xcrun simctl privacy <UDID> grant notifications <bundle>` is not available for notifications; use the app's own first-run prompt once, tapping Allow in the UI test): on the Bots tab, `ghost-turn` → a banner with the bot's name and "Done. 3 files changed." Read delivered alerts through the DEBUG hook the existing notification tests use (`UNUserNotificationCenter.getDeliveredNotifications` dumped to an accessibility label) since a UI test cannot read banners reliably.
3. Same with the ghost chat open on screen → no alert.
4. With the push fixture reporting the plugin as delivering turnDone → no local alert.
5. 30 ghost turns in 5 seconds across 30 sessions → 30 alerts at most, none duplicated, UI stays responsive (STRESS PLAN).

---

## 15. Local alerts the renderer raises (§12 L555)

### What the web app does

`$V/store/native-notifications.ts` (kinds, `shouldFire` rules, 1 s throttle, `dispatchPluginNativeNotification`). Sources:

| Kind | Source | Title / body |
|---|---|---|
| Pre-turn error | event `error {message}` (`GW/events.py:92-98`), handled at `$V/app/session/hooks/use-message-stream/gateway-event/status.ts` (~280-330) | Title "Turn failed"; body = the server's own message, or a plain card for `SESSION_NOT_OWNED` and `disk_full` |
| Background task finished | `$V/store/composer-status.ts:296-352`: polls `process.list {session_id, profile}`; an entry going `running → exited` | Title "Background task finished", or "Background task failed" when `exit_code != 0`; body = first line of `command` (or "background process" when empty), plus " (exit N)" whenever `exit_code` is a number (also for 0), plus the last 3 lines of `output_tail`. The entry's identity is its own `session_id` (the process id in the registry), not the chat's |
| Credits | event `notification.show {text, level, kind, ttl_ms, key, id}` (`status.ts:259`, `$V/store/agent-notices.ts:180-206`); only keys `credits.depleted` and `credits.restored` raise an OS alert; `notification.clear {key}` removes the in-app notice | Title "Credits"; body = `text` |
| Plugin alerts | Only the Kanban plugin: `$V/plugins/kanban/completion-notify.ts`. Terminal event kinds `completed`, `blocked`, `block_loop_detected`, `gave_up`, `crashed`, `timed_out` from the WebSocket `/api/plugins/kanban/events?since=<id>&board=<slug>` (rows `{id, task_id, run_id, kind, payload, created_at}`); baseline = `GET /board` → `latest_event_id`. Fires as an OS alert only while the person is away | Titles (`$V/plugins/kanban/i18n.ts:440-449`): "Task completed"; "Task blocked — needs your input"; "Task routed to triage — needs a decision"; "Task stopped" with body "Hermes couldn’t finish this task. Open Kanban to see why and reassign it."; "Task hit a problem — Hermes will retry it automatically"; "Task took too long — Hermes will retry it automatically". Body otherwise = the event's summary or reason |
| Questions, Settings test | — | Already native |

Previews-off wording (`REF/docs/notifications.md`): background task "A background task finished"; credits "Your credit balance changed"; plugin: the title only, with the generic body "Open Hermes HQ to see what’s new" (the web source says the old product name there; native uses `AppIdentity.displayName`). Relevance scores in the same file: 1.0 / 0.9 / 0.8 / 0.6 / 0.4 by kind.

### Native today

`HermesKit/Push/NotificationPrefs.swift` already has the kinds (`turnError`, `backgroundDone`, `credits`, `plugin`) with their Settings labels "Turn Failed", "Background Task Finished", "Credit Alerts", "Plugin Notifications", and `HermesKit/Push/NotificationText.swift:63-102` already has copy for them. Nothing raises them: the app does not handle `process.list`, `notification.show` or Kanban events, and a pre-turn `error` is treated as a failed turn for opened chats only when not focused.

**Checked in revision 2:** all seven switches are shown today (`NotificationPrefs.kinds`, `HermesKit/Push/NotificationPrefs.swift:9`, drawn by the `ForEach` at `App/Notifications/NotificationsSettingsView.swift:193`). "Turn Failed" works for opened chats; "Background Task Finished", "Credit Alerts" and "Plugin Notifications" switch nothing: three dead controls in the shipped build, which the owner's rule forbids. So this section is not optional polish. If the builder ships this section in parts, each part's switch is shown only when its source is wired (`NotificationKind.isWired`).

### Design

All four go through `NotificationHub.post(kind:…)`, so mute, previews, per-kind switches, the epoch guard and `PushRegistrar.delivers` apply unchanged. Throttle: at most one alert per (kind, session) per second, as the web.

**15a. Pre-turn errors.** In `AppModel.gatewayEvent` for `error`:

* chat not on screen → alert (today's behaviour, keep);
* chat on screen and the app **not active** (background grace, or the screen locked with the chat open) → alert too. Today the focused chat never alerts; Messages' rule is about what you are looking at, and you are not looking at a locked phone;
* chat on screen and app active → no alert (the transcript shows the error).
* Title "Turn failed". Body: the server's message, first line, trimmed to 180 characters. Codes: `SESSION_NOT_OWNED` → "Another device took over this chat."; `disk_full` → "The gateway computer’s disk is full." (builder copies the two exact card strings from `status.ts` when porting; if they differ, the web's wording wins). Previews off: "<Bot> couldn’t finish a reply".

**15b. Background task finished.** `BackgroundTaskWatch` (HermesKit):

* For each session with a live transport in this run (`runningChats`) whose last known process list was non-empty, or which is on screen: `process.list {session_id, profile}` every 5 s with `PowerPolls.wait(.seconds(5), floor: .zero)` (15 s in saver). Stop polling a session after two consecutive empty lists; start again when a turn ends in that session (a turn is what starts background processes).
* Keep `[entry.session_id: status]` per chat session (contract `ProcessEntry`, `GW/contracts/tools_commands.py:86-116`: `session_id`, `command`, `status` default "running", `exit_code: int?`, `output_tail: str?`, `output_preview`, `pid`, `exited_at`; there is no `id` field). Entries without a `session_id` are skipped, as the web does. `running → exited` → post kind `backgroundDone`: title "Background task finished" / "Background task failed"; body as the web (first line of command, " (exit N)" when `exit_code` is a number, then up to 3 last lines of `output_tail`, total ≤ 240 characters); "failed" title when `exit_code` is a non-zero number. Previews off: "A background task finished".
* An entry first seen already exited is baseline, not an alert.
* Alert rule: fire when the chat is not on screen **or** the app is not active.
* Method missing / error on an older gateway → stop polling that gateway for the run, silently.

**15c. Credits.** `LiveChatSession` (and the gateway-level event stream, whichever carries it: check with the fixture and `GW/events.py`) surfaces `notification.show`. For keys `credits.depleted` / `credits.restored` only: post kind `credits`, title "Credits", body `text` (previews off: "Your credit balance changed"), de-dupe id = `key + ":" + id`. Fire regardless of which chat is on screen, but only when the app is not active (when it is active the in-app notice is enough; if the native app has no in-app notice surface for `notification.show`, show the existing transient notice banner with `text` so the event is not lost). Other keys: not an OS alert.

**15d. Plugin alerts (Kanban).** **DECISION 15.1** No extra WebSocket. `KanbanStore` already polls the board every 30 s while shown and the board carries `latest_event_id` (`HermesKit/Pages/PagesWire.swift:370`).

* `KanbanAlertWatch`: per (gateway, board): baseline `latest_event_id` on first read. While the app is running and the gateway has the Kanban plugin, poll `GET /api/plugins/kanban/board?board=<slug>` with `PowerPolls.wait(.seconds(60), floor: .zero)` when the Kanban page is not shown (the page's own 30 s poll feeds the watch when it is shown).
* When `latest_event_id` rises: for tasks whose status changed since the last board (compare ids and status columns), `GET /api/plugins/kanban/tasks/<id>?board=<slug>` (`KanbanAPI.task(_:board:)`, detail includes events), take events with `id >` baseline and a terminal kind, post kind `plugin` with the web's title for that kind and body = `payload.summary ?? payload.reason ?? task title` (first line, ≤ 180 characters). Previews off: title only, body "Open <app name> to see what’s new".
* At most 5 task detail reads per rise; if more tasks changed, post one summary alert "N tasks changed" and skip the rest.
* Alert rule (the web's "while away"): only when the Kanban page is not on screen or the app is not active.
* Tapping the alert opens Kanban at that task (existing route).
* Plugin absent (404 on the board) → the watch stays off; re-check when capabilities refresh.

Honest limit, same as section 14: all four arrive only while the app is active or in its background grace. Delivery while suspended needs the push plugin to send these kinds, which it does not today; see `docs/owner-todo/settings.md`. The app is complete without it.

### Wire

```
← event {"type":"error","session_id":"s1","payload":{"message":"Model not available"}}      (contract ErrorPayload: `message` only)

→ {"method":"process.list","params":{"session_id":"s1","profile":"default"}}
← {"result":{"processes":[{"session_id":"proc_ab12","command":"npm test\n","status":"exited",
     "exit_code":1,"output_tail":"…\n2 failed\n","pid":4242}]}}

← event {"type":"notification.show","payload":{"key":"credits.depleted","id":"n7","level":"warn",
     "kind":"sticky","text":"You’re out of credits. Add more to keep going.","ttl_ms":0}}
← event {"type":"notification.clear","payload":{"key":"credits.depleted"}}

GET /api/plugins/kanban/board?board=main → {"latest_event_id":41, "columns":[…]}
GET /api/plugins/kanban/tasks/t9?board=main → {"task":{…},"events":[{"id":42,"task_id":"t9","run_id":"r1",
     "kind":"completed","payload":{"summary":"Wrote the README"},"created_at":1760000000}]}
```

Checked in revision 2: the result key is `processes` (`ProcessListResult`), params are exactly `session_id` and `profile`. `notification.show` payload is `{text, level: info|warn|error|success, kind: sticky|ttl|agent, ttl_ms?, key?, id?}` (`GW/contracts/events.py:337-354`); `key` and `id` can both be absent, so the de-dupe id falls back to the text's hash.

### States and wording

| Kind | Previews on | Previews off |
|---|---|---|
| turnError | "Turn failed" / server message | "<Bot> couldn’t finish a reply" |
| backgroundDone | "Background task finished" or "Background task failed" / command + tail | "A background task finished" |
| credits | "Credits" / text | "Your credit balance changed" |
| plugin | the six Kanban titles / summary | title / "Open <app name> to see what’s new" |

Each respects its own switch in Settings › Notifications and bot mute.

### Stand-in

* `settings-gateway.py` (port 10060): `process.list` backed by `POST /__settings/process {"chat":"<chat session id>","session_id":"proc_p1","command":"npm test","status":"running"}` and a later `…"status":"exited","exit_code":1,"output_tail":"…"`; `POST /__settings/emit` for `error` and `notification.show` / `notification.clear`.
* `scripts/pages-fixture-gateway.py` (port 10064) for Kanban: add `POST /__pages/kanban-event {"board":"main","task_id":"t9","kind":"completed","payload":{"summary":"…"}}` which appends the event, moves the task's status and bumps `latest_event_id`.

```
python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Settings A"
python3 scripts/pages-fixture-gateway.py --port 10064 --credentials build/m9-settings/pages.json --files build/m9-settings/files
```

### Acceptance

1. Unit: `BackgroundTaskWatch` (baseline; running→exited once; failed title; body trimming; stop after two empty lists). `KanbanAlertWatch` (baseline; each kind → title; cap of 5; plugin absent). Credits filter (only the two keys; de-dupe).
2. Simulator, each kind: drive the fixture control with the app on another tab → the delivered-notifications dump shows the exact title and body. Then with previews off → the off wording.
3. Each kind's switch off → no alert. Bot muted → no alert for turnError/backgroundDone of that bot.
4. Chat on screen and app active → no turnError/backgroundDone alert.
5. Old gateway (`/__settings/fail {"method":"process.list","code":-32601}`) → one attempt, then no more `process.list` hits in state.
6. No user-visible string contains "Dispatch" (string-table scan test, already in the project if present; else add `NoForbiddenWordsTests` for the new strings).

---

## 16. Device removal ledger (§12 L568)

### What the web app does

`REF/ios/App/App/HermesPlatform.swift`: on sign-out or notifications off, `DELETE` the device from the gateway's push plugin; if it fails, remember it in `hermes.push.ledger` (at most 4 accounts, names hashed) and retry at the next sign-in to that account. The route used is remembered per account in `hermes.push.routes`.

### Native today

`HermesKit/Push/PushPolicy.swift:105-156` `PushLedger` (owed ≤ 4), `App/Notifications/PushRegistrar.swift:220-270` (`unregister`, `forget(account, call:)`, `removeDevice(from:call:)`). The row's stated gap: "a non-current gateway removed from the phone drops its key and answers but its owed DELETE is not sent".

`App/Settings/AppModel+Settings.swift:141-153` `remove(_:)` now calls `notificationsForget` with the stored account's own session before sign-out (commit c5a45f9). So the gap looks coded but nobody has seen it work, and the failure path (that gateway is unreachable at removal time) is unproven.

### Design

No new behaviour; **prove and harden**:

1. Removing a non-current gateway while it is reachable: the app builds a one-shot client from that account's stored credentials, sends the `DELETE`, then drops the key. Order matters: DELETE first, key second.
2. Removing it while it is **unreachable**: the DELETE fails (timeout 8 s, one attempt, never a retry loop); the account goes into `PushLedger` as owed, with the minimum needed to try again. **DECISION 16.1**: because the credentials are being deleted from the phone, an owed removal for a removed gateway can only be retried if that gateway is added again (sign-in to the same account), exactly the web's "retried at the next sign-in". The ledger keeps the hashed account name and the device token id, not credentials.
3. At sign-in, `PushRegistrar` checks the ledger for that account hash and sends the owed DELETE before registering afresh (already the design; verify).
4. Fifth owed account evicts the oldest (≤ 4), as the web.
5. Wording: none on success. On failure at removal nothing is shown either (the person asked to remove a gateway; the removal itself succeeded). The existing Notifications page line for an owed removal, if any, stays as is.

### Wire

As `PushRegistrar.removeDevice` sends today (`DELETE` on the plugin's device route; the builder reads the exact path from that function and from `scripts/fixtures/push-gateway.py`, and writes it into this section when closing the row).

### Stand-in

Two push fixtures, A current and B to be removed. `e2e-push.sh` restricts `HQN_PUSH_PORT` to 9810–9819 unless `HQN_ANY_PORT=1` is set (`scripts/e2e-push.sh:16`): set it, do not edit the script.

```
python3 scripts/fixtures/push-gateway.py --port 10062 --credentials build/m9-settings/push-a.json --sim <UDID> --bundle <bundle id>
python3 scripts/fixtures/push-gateway.py --port 10063 --credentials build/m9-settings/push-b.json --sim <UDID> --bundle <bundle id>
HQN_ANY_PORT=1 HQN_PUSH_PORT=10062 scripts/e2e-push.sh <UDID>
```

Fixture control needed: `POST /__fixture/push {"deleteFails": true}` (answer 503 to DELETE) and state listing received DELETEs. To make B unreachable: stop B's process (the builder started it; it may stop it).

Reminder from the owner's push-for-everyone.md: `simctl push` never runs notification service extensions, and unsigned simulator builds get no APNs token. The fixture's `--sim` path injects a token; this row's tests are about the REST calls, not about delivery.

### Acceptance

1. Unit: `PushLedger` add, evict at 5, hashed names (no plain account name in the stored blob), clear on success.
2. Simulator: signed in to A and B, registered on both. Remove B (not current) → B's fixture state shows one DELETE **before** the sign-out call; ledger empty.
3. Stop B, remove B → no hang beyond 8 s, B gone from the list, ledger has one owed entry. Start B, add B again → B's state shows the owed DELETE then a fresh registration; ledger empty.
4. `deleteFails` on A, turn notifications off → owed; turn on again → DELETE retried once, then registered.
5. Exactly one DELETE attempt per trigger (no loop) in fixture state.

---

## 17. Push add-on offer (§12 L575)

### What the web app does

`REF/src/push-setup.ts` (whole file):

* Missing or old plugin → an alert offering "Ask <bot>". Accepting opens the main bot's chat and **queues** the install prompt: `enqueueQueuedPrompt(sessionId, {text: PUSH_SETUP_PROMPT, displayText: QUEUE_TITLE, attachments: []})`, with `QUEUE_TITLE = 'Install the Hermes HQ notification plugin on this Hermes.'`. If the same prompt is already queued it is not queued twice. The transcript shows the short title, not the long prompt.
* Errors: "Couldn’t open the bot’s chat. Try again from Settings › Notifications." / "The bot’s chat didn’t open in time. Try again from Settings › Notifications." / "Couldn’t send the request to the bot. Try again from Settings › Notifications."
* Then it polls the plugin every 20 s for 15 minutes and registers when it appears. Done notices: "Notifications are on. <name> installed the plugin." or "<name> installed the plugin. Allow notifications for Hermes HQ in iOS Settings to get alerts."
* "Not Now" is kept a week per account. "Update Notifications?" for an old plugin.
* Two further, separate offers, each once per account:
  * Themes (`shouldOfferThemesUpdate`: plugin ready and `themes === false`; key `dispatch.pushThemes.asked`). Title "Update Hermes HQ’s Add-on?". Message: "A newer version adds Hermes HQ themes to the Hermes desktop app: this app’s look, and Nous with High Contrast. Your notifications keep working either way. <name> can update it for you; Hermes restarts for a moment." Buttons "Not Now" / "Ask <name>". Done notice (8 s): "<name> updated the add-on. In the Hermes desktop app, pick Hermes HQ or Nous High Contrast in Settings › Appearance › Theme."
  * Restart guard (`shouldOfferGuardUpdate`: ready, `themes === true`, `restartGuard === false`; key `dispatch.pushGuard.asked`). Same title. Message: "A newer version stops a bot’s restart of Hermes from repeating, which can keep Hermes down and lock this app out. Your notifications keep working either way. <name> can update it for you; Hermes restarts for a moment." Done notice (6 s): "<name> updated the add-on."
* All offers are skipped while voice is busy.

Owner notes: restart-guard-plugin.md (push plugin 0.7.0 carries the restart guard) and desktop-hq-theme.md (push plugin 0.6 writes the themes) are why these two offers exist. hermes-hq-native.md: push relay and plugin changes need the owner's OK, so the app only **asks the person's own bot** to update; it never installs anything itself.

### Native today

`App/Notifications/PushSetupOffer.swift`: the weekly Turn On / "Update Notifications?" offer at launch and from Settings; `AppModel.askMainBot(Self.prompt)` (`App/Browser/AppModel+Browser.swift:79-97`) **types the prompt into the composer** for the person to send (its own comment says the push offer is its last user); `watchForPlugin` 20 s × 15 min; key `hermes.pushSetup.asked`. `PushRegistrar.pluginState()` already returns `(state, themes, restartGuard)`. No themes or guard offers.

### Design

**17a. Queue instead of type.** The queueing function exists since the presence stream: `MainBotRequest.queue(text:title:linkReady:)` (`App/Presence/MainBotRequest.swift:85`). It opens the main bot's chat (closing what is over the root, refusing while something is being edited), answers `.alreadyQueued` when the same text is waiting (`step(queued:text:)`), sends at once on an idle bot and queues behind a running reply, and the bubble shows the title (`LiveChatSession.sentTitles`). Watch Browser uses it (`App/Browser/AppModel+Browser.swift:28`).

1. `PushSetupOffer` calls `MainBotRequest.queue(text: Self.prompt, title: Self.queueTitle)` where it calls `AppModel.askMainBot(Self.prompt)` today. `queueTitle = "Install the Hermes HQ notification plugin on this Hermes."` (the web's `QUEUE_TITLE`; the product name comes from `AppIdentity.displayName`, as `MainBotRequest.browserTitle` should too: check it on the HQ Native identity).
2. Register the title for bubbles restored later, as presence does for its own (`LiveChatSession.sentTitles.note(text:title:)`, `App/Presence/AppModel+Presence.swift:15`).
3. `AppModel.askMainBot` then has no caller: delete it (and its comment at `AppModel+Browser.swift:77-78`).
4. Errors. `MainBotRequest` throws its own words ("Couldn’t open the bot’s chat. Try again.", "The bot’s chat didn’t open in time. Try again.", "Couldn’t send the request to the bot. Try again.", "Couldn’t find the main bot on the computer running Hermes. Open Bots and try again.", "Save or discard what you’re editing, then try again."). For the push offer the web's endings apply: map the first three to "… Try again from Settings › Notifications." by giving `queue` a `retryHint: String = "Try again."` parameter that the three strings end with; the push offer passes "Try again from Settings › Notifications.". Shown as the standard alert with "OK".

**DECISION 17.1** One queueing path for every "ask the main bot" request (Watch Browser already moved to it), so the two behave alike. The display title for the update variants: "Update the Hermes HQ notification plugin on this Hermes."

**17b. Themes and restart-guard offers.** In `PushSetupOffer`, after the plugin state is known and is `ready`:

* `themes == false` and not yet asked for this account (key `hermes.pushThemes.asked.<account hash>`) → the themes alert, wording above with the main bot's name.
* else `themes == true && restartGuard == false` and not yet asked (key `hermes.pushGuard.asked.<account hash>`) → the guard alert.
* At most one offer per launch, never while voice is busy, never over another alert or sheet (wait for the root to be idle, as the existing offer does), never during onboarding.
* "Not Now" → mark asked (once per account, for good, as the web). "Ask <name>" → mark asked, `MainBotRequest.queue` with the matching update prompt (port `PUSH_SETUP_PROMPT`'s update variants from `push-setup.ts` verbatim), then watch: poll `pluginState()` every 20 s for 15 min through `PowerPolls.wait(.seconds(20), floor: .zero)` until the flag flips; then the done notice for 8 s (themes) or 6 s (guard) using the existing notice banner.
* A working plugin whose status answer has **no** `desktopThemes` key is exactly the plugin that predates 0.6, and one with no `restartGuard` key predates 0.7 (`REF/src/push-setup.ts:5-7`; `REF/ios/App/App/HermesPlatform.swift:46-49` reads a missing key as false). So a missing key means false and **does** raise the offer. `PushPolicy.desktopThemes/restartGuard` (`HermesKit/Push/PushPolicy.swift:42-43`) already read it that way: keep them. No offer when the plugin state itself is not `ready` (missing, outdated, unknown, or the status read failed).
* From Settings (17c) the once-per-account "asked" mark is ignored, as the web's `fromSettings` does (`push-setup.ts:69,75`).

**17c. Settings.** Settings › Notifications already has the Turn On / Update row. When `themes == false` or `restartGuard == false`, show one extra row **"Update Add-on"** with the footer being the matching message above (themes first), which runs the same ask. It disappears when both flags are true. This gives a way back after "Not Now", as the three error strings promise ("Try again from Settings › Notifications").

### Wire

* Plugin status read: as `PushRegistrar.pluginState()` today (fields `desktopThemes`, `restartGuard` in the status body; the push fixture already returns both as `True`).
* Queue: the chat's existing send path (`prompt.submit` or what `beginSend` uses) when the queue drains; no new method.

### States and wording

All quoted above. Buttons: "Not Now" / "Ask <name>". Alert title for the two extra offers: "Update Hermes HQ’s Add-on?" with the app name from `AppIdentity.displayName`.

### Stand-in

`scripts/fixtures/push-gateway.py` (its status answer has `desktopThemes: True` and `restartGuard: True` fixed at lines 46-47, and `POST /__fixture/push {plugin?}` today): add controls

```
POST /__fixture/push {"plugin":"missing"|"old"|"ready","desktopThemes":true|false,"restartGuard":true|false}
```

and record submitted prompts (full text and the display title if the wire carries it) in its state.

```
python3 scripts/fixtures/push-gateway.py --port 10062 --credentials build/m9-settings/push-a.json --sim <UDID> --bundle <bundle id>
HQN_ANY_PORT=1 HQN_PUSH_PORT=10062 scripts/e2e-push.sh <UDID>
```

### Acceptance

1. Unit: `shouldOfferThemes` / `shouldOfferGuard` truth tables (port of `push-setup.ts:68-76`): state not ready, themes false, themes true + guard false, already asked, from Settings; one offer per launch; skipped while voice is busy.
2. Simulator, plugin missing: launch → the Turn On offer; "Ask <name>" → the main bot's chat opens, your bubble reads "Install the Hermes HQ notification plugin on this Hermes.", fixture state holds the full prompt text exactly once. Tap the Settings row again while it is still queued → still once.
3. Bot busy (fixture long turn) → the bubble shows as queued and sends when the turn ends.
4. Flip the fixture to ready within the watch → "Notifications are on. <name> installed the plugin." (or the Allow variant when iOS permission is denied).
5. `desktopThemes:false` → themes alert with the exact message; "Not Now" → relaunch → no alert; Settings shows "Update Add-on"; use it → queued; flip the flag → the 8 s notice.
6. `desktopThemes:true, restartGuard:false` → the guard alert; same checks; 6 s notice.
7. Fixture refuses `session.create` → "Couldn’t open the bot’s chat. Try again from Settings › Notifications."
8. No string shown contains "Dispatch" (the storage keys of the web did; ours do not need to).

---

## 18. Settings layout after this stream

Settings root (inline large title "Settings") as it is after the train merge (`App/Settings/SettingsRootView.swift:287-460`), with this stream's additions marked by their section number:

```
(gateway row)

Appearance
  Appearance              System  ⌄
  Theme                    <skin> >        (desktoplook; untouched)

  Notifications                   >        (17c adds a row inside that page)

Chat
  Tool Calls                      >
  Chat Font               System  >        (8)
  Text Direction            Auto  ⌄        (6)
  Largest Attachment      32 MB   >        (4)
  Reopen Last Chat on Launch      ●
  In-App Tips                     ●

Chat Extras                                (new section, DECISION 18.1)
  Intro Splash                    ●        (7)
  Message Reactions               ○        (9)
  Vibe Hearts                     ●        (10)
  Inline Embeds              Ask  ⌄        (11)
  [Reset N Allowed Services]               (11, only when N > 0)
  File Browser                    ○        (12)

Sounds & Haptics                           (was "Sounds"; shown when SettingsHooks.completionCueWired)
  Completion Sound                ●
  Sound                           >
  Haptics                         ●        (1)

Hermes … Accounts & Keys … Voice … Bots & Tools … (unchanged)
```

Notes from the merged file that bind the builder:

* Row titles are `Text(…).foregroundStyle(Color.hqLabel)` (desktoplook's skin text colour). New rows do the same, or they will be the wrong colour under a skin.
* The Sounds section is inside `if SettingsHooks.completionCueWired`. The Haptics row must **not** depend on that flag: if the cue is not wired, the section is titled "Haptics" and holds the one row.
* Default Project Folder is not on the root: it is in Hermes › Sessions (`VaultBillingPages.swift`, section 5).
* The toggles here call `UISelectionFeedbackGenerator()` inline (`:304,332`); they move to `Haptics.play(.selection)` with section 1. **DECISION 18.2**: a SwiftUI `Toggle` already ticks by itself on iOS, so after the move check on a device-like run that a switch gives one tap, not two; if the system tick is there, drop ours (DECISION 2.1).

**DECISION 18.1** Twelve rows with twelve footer sentences would be a wall of grey text. The "Chat" section is split in two so each footer stays short and each sentence sits under its own rows:

* **Chat**: Tool Calls, Chat Font, Text Direction, Largest Attachment, Reopen Last Chat on Launch, In-App Tips. Footer: the existing sentence ("Reopen Last Chat on Launch is saved on the computer running Hermes. In-App Tips are small hints the first time you use something."), then "Text Direction: Auto follows the first letter of each paragraph. Code always stays left-to-right."
* **Chat Extras**: Intro Splash, Message Reactions, Vibe Hearts, Inline Embeds (+ reset), File Browser. Footer: the five sentences given in sections 7, 9, 10, 11 and 12, each starting with its row's name.

Each row is added to `HermesKit/Settings/SettingsSearch.swift` with its title and two or three search words (font, typeface; rtl, arabic, hebrew; emoji, tapback; youtube, preview, link; files, folder; vibration, taptic; megabytes, size).

All pushed pages use the small title. Rows that wrap get 12 to 14 pt vertical padding.

---

## 19. Fixtures: what exists, what to add, exact commands

Ports for builders of this stream: **10060–10064**. Stress tester: **10065–10069**. Never any other port, never a port the agent did not start.

Simulators (create your own; never the scripts' default):

```
xcrun simctl create "HQN-m9-settings"   "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0     # builders
xcrun simctl create "HQN-m9-settings-s" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0     # stress tester
scripts/build.sh <UDID>            # build + install;  scripts/build.sh test <UDID> for unit tests
```

Use this worktree's own `build/` (derived data `build/dd`). Shut the simulator down and stop every fixture you started when your stage ends (by PID you recorded, never by name).

| Port | Fixture | Used by sections |
|---|---|---|
| 10060 | `python3 scripts/fixtures/settings-gateway.py --port 10060 --credentials build/m9-settings/a.json --label "Settings A"` | 1–11, 14, 15a–c |
| 10061 | `python3 scripts/fixtures/menus-gateway.py --port 10061 --credentials build/m9-settings/menus.json` (second settings gateway for `e2e-settings.sh` when menus is not needed) | 12, 5 (two gateways) |
| 10062 | `python3 scripts/fixtures/push-gateway.py --port 10062 --credentials build/m9-settings/push-a.json --sim <UDID> --bundle <bundle id>` | 16, 17 |
| 10063 | same script, `--port 10063 --credentials build/m9-settings/push-b.json` | 16 (the gateway to remove) |
| 10064 | `python3 scripts/pages-fixture-gateway.py --port 10064 --credentials build/m9-settings/pages.json --files build/m9-settings/files` | 2 (kanban haptics), 15d |

Existing end-to-end runners: `HQN_SETTINGS_PORTS="10060 10061 10062" scripts/e2e-settings.sh <UDID>`; `HQN_ANY_PORT=1 HQN_PUSH_PORT=10062 scripts/e2e-push.sh <UDID>` (the script's own escape from its 9810–9819 guard).

Additions to `scripts/fixtures/settings-gateway.py` (one commit per feature that needs them; keep its contract-key checking, add the new keys to it):

| Addition | For |
|---|---|
| `hits` timestamps per path/method in `/__settings/state` | 3 |
| `GET /api/fs/list` + `POST /__settings/fs {"missing":[…]}` | 5 |
| `session.create` accepts and records `cwd`, `cwd_explicit` | 5 |
| `desktop.font_family` in defaults/schema | 8 |
| Seeded chats "Directions", "Reactions", "Embeds" | 6, 9, 11 |
| `message.react`, `config.set` (recorded) | 9 |
| `POST /__settings/emit {type, session_id?, payload}` to connected sockets | 9, 10, 15 |
| `GET /__embed/<provider>/<id>`, `/__embed/slow/…`, `/__embed/broken/…`, a fixture PNG, `embedHits` | 11 |
| `POST /__settings/ghost-turn` | 14 |
| `process.list` + `POST /__settings/process` | 15b |
| `POST /__settings/fail` accepting a JSON-RPC `code` | 9, 15 |

Additions to `scripts/fixtures/push-gateway.py`: `plugin`, `desktopThemes`, `restartGuard`, `deleteFails` controls; DELETE log; submitted-prompt log. To `scripts/pages-fixture-gateway.py`: `POST /__pages/kanban-event`.

Fixture rules: bind `127.0.0.1` only; print one line with the port and credentials path at start; exit cleanly on SIGTERM; new fixture code has no dependency beyond the standard library (match the existing scripts).

---

## 20. Ship order (one feature per build)

Closest first (section 0.2), with one exception: the haptics gate goes early although it is wide, because every later feature adds haptic calls and should add them through the gate. Each line is its own commit set and its own TestFlight build; each is stress tested (STRESS PLAN) before it may ship.

1. Row 13 (Hidden on phone): the absence test. No build of its own: it rides with build 2.
2. Power saver (3).
3. Haptics gate + switch (1). Merge `m9/train` immediately before starting and immediately before handing over: the gate touches 91 files that other streams are still editing, and the scan test will catch whatever they add.
4. Push add-on offer, queue half (17a), then the two extra offers and the Settings row (17b, 17c).
5. Device removal ledger proof (16).
6. Intro Splash (7).
7. Default Project Folder (5).
8. Largest Attachment (4).
9. File Browser (12).
10. The missing haptics (2).
11. Text Direction (6).
12. Chat Font (8).
13. Vibe Hearts (10).
14. Notification leftovers: 15a, 15c (small), then 15b, then 14, then 15d. (15b–15d remove three dead switches, so they outrank the two big chat features.)
15. Message Reactions + React… (9).
16. Inline Embeds (11).

---

## STRESS PLAN

The stress tester uses its own simulator ("HQN-m9-settings-s") and ports 10065–10069, starting its own copies of the fixtures above on those ports. Every item says what to do and what "pass" is. Record numbers in the test output, not in a new report file.

### Load

| # | Do | Pass |
|---|---|---|
| L1 | Chat Font: 2,000-message transcript (fixture seeds it), change font five times in ten seconds | No crash; visible rows redraw within 300 ms of each pick; scroll position anchor unchanged; memory returns to within 10% of the start after the last change |
| L2 | Text Direction: same transcript, flip Auto → RTL → LTR ten times | Same as L1; code blocks never move |
| L3 | Reactions: a row with 500 reactions and 60 distinct emoji; a transcript where every one of 2,000 rows has 3 reactions | Decodes; chips wrap; scrolling stays at the frame rate of the same transcript without reactions (within 5% hitches measured by the project's scroll test) |
| L4 | Embeds: the 40-link message in Always mode | At most 2 fetches in flight (fixture hit timestamps); all 40 cards resolve; scrolling during loading does not hitch; memory stable after scrolling away and back |
| L5 | Vibe Hearts: 50 `reaction` events in one second, three times | One burst alive at a time; emitter layers all removed 2 s after the last event (layer count in the DEBUG dump is 0) |
| L6 | List-derived alerts: 30 ghost turns in 5 s over 30 sessions; then 300 sessions in the list with 30 changing | ≤ 30 alerts, no duplicates; the watch's per-refresh work is O(n) and under 5 ms for 300 sessions (measure in the unit test) |
| L7 | Background tasks: 40 processes in one session, 10 finishing in the same poll | 10 alerts coalesced by the 1 s throttle into at most the first plus one "N background tasks finished" (builder's choice of coalescing wording is fixed here: "N background tasks finished"); no alert storm |
| L8 | Kanban: 25 tasks reach a terminal state between two polls | 5 detail reads at most, one summary alert "25 tasks changed" |
| L9 | Chat Font page: a device with 300 font families (the simulator has about 80; add a unit test with a synthetic list of 1,000 names) | List scrolls smoothly; search filters within one frame per keystroke |
| L10 | Haptics: 200 `Haptics.play(.selection)` in one second with the switch off, then on | Off: zero generator objects created (sink count 0). On: no main-thread stall over 8 ms |
| L11 | Default folder: 20 new chats in 10 s from Sessions “+” with a folder set, then with the folder made missing | Every `session.create` carries `cwd` + `cwd_explicit`; with the folder missing each chat still opens after exactly one retry without `cwd`, and the notice shows once, not 20 times |
| L12 | Push offer: tap “Ask <name>” 10 times quickly (Settings row), with the bot idle and with it busy | The fixture holds the prompt once; one bubble; no second chat opened |

### Speed

| # | Do | Pass |
|---|---|---|
| S1 | Settings root open time before and after this stream (cold, fixture on localhost) | Within 30 ms of before |
| S2 | Chat open time for the 2,000-message transcript with a custom font, RTL forced, reactions and embeds present | Within 10% of the same chat with none of them |
| S3 | Text layout cost per message with a custom font vs system (unit micro-benchmark, 500 messages) | ≤ 1.3× system |
| S4 | Power saver off → on → off (`notifyutil -p hqn.power.toggle`): time until each routed poll re-arms and each decorative loop stops / restarts | Under 1 s for all; overdue polls fire at once on leaving saver |
| S5 | React…: hold → menu → pick → chip visible | Chip appears in the same frame as the popover dismissal (optimistic), server reconcile causes no flicker when the lists match |

### Bad network

Use the fixture's fail controls and, for latency/drops, the fixture's own `--delay`/`fail` options (add a `delay_ms` field to `/__settings/fail` if missing). Never use system-wide network conditioning: the Mac is shared.

| # | Do | Pass |
|---|---|---|
| N1 | Chat Font save with a 10 s delayed PUT, then a 500 | Optimistic check stays during the delay, rolls back on 500 with the inline error; a second pick during the delay wins in order (last pick is what the gateway holds) |
| N2 | Default Project Folder validate with a 15 s hang | Save shows the spinner, gives up at the app's standard REST timeout with "Could not update default directory"; the field is usable again |
| N3 | `message.react` times out; socket drops between send and reply | Chip reverts with "Could not react"; after reconnect the transcript reload shows the gateway's truth (if the gateway did apply it, the chip is there and nothing doubles) |
| N4 | `config.set` for reactions fails at toggle time | Switch stays where the person put it; one resend at next connect (fixture shows exactly one) |
| N5 | Embeds: metadata 20 s slow; broken; image 404; airplane mode mid-load | Spinner ≤ 8 s then plain link; plain link; card without image (72 pt); no crash and no stuck spinner |
| N6 | Socket flaps every 2 s for a minute with background-task and Kanban watches running | No duplicate alerts, no growth in timers (poll task count constant), baselines survive reconnects |
| N7 | Push: DELETE hangs 30 s on gateway removal | Removal completes for the person within 8 s; one owed ledger entry; no retry loop |
| N8 | Push offer: `session.create` fails, then chat readiness never arrives, then send fails | The three exact error strings, in that order of cases |
| N10 | `config.set display.message_reactions` answers 4002 (gateway does not list the key) | The switch stays; the app does not resend on every connect for that gateway in this run; React… is hidden for that gateway with the one notice |
| N9 | Gateway switch while a font save, a react and a folder validation are in flight | Each result is dropped if it belongs to the old gateway (epoch guard); nothing is written to the new gateway; no alert for the old one |

### Bad data

| # | Do | Pass |
|---|---|---|
| D1 | `desktop.font_family` = 10,000 characters; an emoji; `null`; a number; "  Georgia  "; a symbol font | System font (trimmed "Georgia" resolves to Georgia); page shows a sensible truncated "not on this iPhone" row; no crash |
| D2 | Transcript `reactions`: a string, a dict, entries with missing `emoji`, an emoji of 200 code points, an `author` that is null | Bad entries dropped; the row still renders |
| D3 | `message.reaction` for an unknown `row_id`; for a session not on screen; with no payload | Ignored quietly |
| D4 | `reaction` event with no `kind`, with a 1 MB payload | Hearts (or nothing); no crash |
| D5 | `process.list` returns a bare array, `null`, entries without `status`, `exit_code` as a string, a 5 MB `output_tail` | Tolerated; body trimmed to 240 characters; unknown shapes mean "no processes" |
| D6 | `notification.show` with key `credits.depleted` and no `text`; unknown keys; the same id 100 times | Body falls back to "Your credit balance changed"; unknown keys no OS alert; one alert for the repeated id |
| D7 | Kanban: `latest_event_id` goes backwards (board reset); event kinds the app does not know; payload not a dict | Re-baseline without alerting; unknown kinds ignored |
| D8 | `/api/fs/list` returns HTML, `{"entries": "nope"}`, a 50,000-entry list | "Couldn’t open the folder." for the first two; the third validates quickly (only the presence of the array matters; do not decode all entries for validation) |
| D9 | Folder path with spaces, unicode, a trailing slash, `~`, 4,000 characters, a newline | Sent percent-encoded; trimmed; newline rejected locally ("Couldn’t open the folder." without a call is acceptable); no crash |
| D10 | Embed links: `youtube.com/watch?v=` with no id, a look-alike host `youtube.com.evil.example`, a `javascript:` URL, a 5,000-character URL, an IP literal | Only true provider hosts match (exact host or dot-suffix match); never fetch non-http(s); everything else stays a plain link |
| D11 | Embed metadata: a 3 MB title, an `og:image` of 200 MB, an image that is really HTML, a redirect loop | Title cut to 2 lines; image refused above the section 4 limit (card without image); no memory spike |
| D12 | Stored prefs corrupted: `hqn.attachmentLimitMb = "abc"`, `hqn.embedMode = "sometimes"`, `hqn.textDirection = 7` | Each reads as its default |
| D13 | Plugin status body without `desktopThemes` / `restartGuard` (a plugin older than 0.6 / 0.7), with strings instead of booleans, or a status read that fails / is not JSON | Missing or non-boolean key = false → the matching offer (themes first); failed or unreadable status = state not ready → no offer at all |
| D15 | `message.react` result with `row_id` as a string, or a different row than asked; transcript rows whose `row_id` is a string or a float | Decode leniently (accept an integral number or a numeric string, else nil); a result for another row updates that row, not the one tapped |
| D16 | Chat font family equal to the skin's own family; a family with only one weight; a variable font | No double work, bold falls back to the regular face (never crashes in `withSymbolicTraits`), heights still exact |
| D14 | RTL: a paragraph of only digits and punctuation; a 20,000-character Arabic paragraph; mixed-direction inline code | Auto resolves to the interface direction for neutral-only text; layout time within S3's bound; inline code LTR |

### Interruption

| # | Do | Pass |
|---|---|---|
| I1 | Background the app during: a font save; a folder validation; a react; an embed load; a hearts burst; the push offer's 15-minute watch | On return: saves either landed or rolled back with their error (never a stuck spinner); the burst is gone; the watch resumes for the remainder of its 15 minutes measured in wall time, not restarted |
| I2 | Incoming call / Siri / Control Centre over the React… popover and over the offer alert | Popover dismisses cleanly; the alert is still there or re-presents once, never twice |
| I3 | Start voice mode with an offer due | No offer until voice ends (web rule) |
| I4 | Rotate (if the app supports it) and change Dynamic Type while the Chat Font page, the embeds chat and the reactions popover are open | Layout follows; heights recomputed; no clipped chips or cards |
| I10 | A theme / Desktop Look change while the Chat Font page is open and while a chat with a custom font is on screen | One reflow, the chat font still wins in chat text, no stale cached style (the cache key has both) |
| I5 | Low Power Mode toggled 20 times in 10 s (`notifyutil -p hqn.power.toggle`) | Timers re-arm without leaking tasks; animations settle in the state of the last toggle |
| I6 | Lock the phone with a chat on screen, then fire an `error` event and a background-task exit within the grace window | Alerts post (app not active), per 15a/15b |
| I7 | Sign out / switch gateway while the Kanban watch, background-task watch and list watch are running | All three stop for the old gateway at once (no call to it after the switch in its fixture log), restart with fresh baselines for the new one |
| I8 | Remove a gateway while its owed DELETE is in flight, then kill the app | Next launch: ledger is consistent (owed or cleared, never half-written) |
| I9 | Memory warning with 40 embed thumbnails in memory | Memory cache drops; cards reload from disk without refetching (fixture hits unchanged) |

### Relaunch

| # | Do | Pass |
|---|---|---|
| R1 | Set every new preference to a non-default value, force-quit, relaunch | All kept: Haptics, Largest Attachment, Text Direction, Intro Splash, Reactions (+touched), Vibe Hearts, Embed mode and allowed list, File Browser, Default Project Folder (per account+profile) |
| R2 | Chat Font is on the gateway: relaunch offline | Chat uses the last known family from the config cache if the app caches config; else system font until config loads, then one reflow with the anchor kept (no visible jump of the reading position) |
| R3 | Relaunch with "Reopen Last Chat on Launch" into a chat with a default folder set | The reopened chat is not re-created; no stray `session.create` |
| R4 | Kill the app 5 minutes into the push watch; relaunch | No second offer alert (asked is recorded); the Settings row still offers the way back; registration happens at next status read if the plugin is now ready |
| R5 | Relaunch after "Not Now" on themes and guard offers | Never offered again for that account; offered for a different account |
| R6 | Relaunch after list-derived alerts | Baseline is rebuilt silently: no alerts for chats that finished while the app was dead |
| R7 | Delete and reinstall | Device-local preferences are back to defaults; the font (gateway) is still the person's; no `config.set` is sent for reactions (untouched) |
| R8 | Upgrade path: install the build before this stream, attach a 30 MB file successfully, upgrade | Limit reads 32; behaviour unchanged |

### Accessibility sizes

Run at Large (default), AX3 and AX5 (`xcrun simctl ui <UDID> content_size accessibility-extra-extra-extra-large`), in light and dark, with Bold Text on for one pass.

| # | Do | Pass |
|---|---|---|
| A1 | Settings root with all new rows | No truncated titles (rows wrap; value moves under the title at AX sizes as the existing rows do); 12 to 14 pt vertical padding on wrapped rows; footers readable |
| A2 | Chat Font page with a custom family | Rows drawn in their face scale with Dynamic Type; preview wraps; a script face (Zapfino) does not clip ascenders in the row |
| A3 | Chat with a custom font at AX5 | Bubble heights exact (no clipped last line, no extra gap): compare `TextLayout` height with the drawn text's bounding box in a unit test for 50 sample messages × 5 fonts × 3 sizes |
| A4 | Reaction chips at AX5; popover at AX5 | Chips wrap to more lines, each at least 44 pt tall for tappable ones; the six quick emoji wrap to two rows rather than shrinking |
| A5 | Embed placeholder and loaded card at AX5 | Buttons wrap to two lines or stack; card height table has an AX variant (heights are computed from font metrics, not constants, at AX sizes); nothing overlaps |
| A6 | Default Project Folder page at AX5 with a long path | Path wraps (no middle truncation at AX sizes) |
| A7 | VoiceOver pass over every new control | Each has a label, value and trait: switches say on/off; pickers say their value; React… reads "React"; chips read "heart, 2, your reaction, double-tap to remove" / bot chips read without a button trait; embed placeholder and card as specified; the Files bar button reads "Files"; hearts and chips decoration hidden where specified |
| A8 | Reduce Motion on | No hearts, no chip pop animation, no shimmer; everything else works |
| A9 | Increase Contrast and Reduce Transparency on | Chips and cards keep 4.5:1 text contrast; system glass falls back as iOS decides (we draw none ourselves) |
| A10 | RTL interface language (launch with `-AppleLanguages (ar) -AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`) with Text Direction = Auto, then LTR | Settings mirrors correctly; chat prose follows the setting; code stays LTR |
| A12 | iPad two-pane layout (the ipad stream's root): every new Settings row, the React… popover (anchored to the bubble in the detail pane), embeds cards at the wide width, the Files bar button | Nothing assumes phone width; popover arrow points at the bubble; cards cap at a readable width (≤ 420 pt) instead of stretching |
| A13 | Each skin + Desktop Look on, light and dark | New rows use `Color.hqLabel`; chips, cards and the popover take the skin's colours through the existing palette, with Increase Contrast inside them |
| A11 | Smallest supported phone width at AX5 with the File Browser button on | Chat bar items do not overlap; title truncates before buttons collide |

---

## Open items for the owner (none block the app)

See `docs/owner-todo/settings.md`. In short: local alerts of every kind stop when iOS suspends the app; getting failed-turn, background-task, credits and Kanban alerts on a locked phone would need the push plugin to send those kinds. The app works fully without that and shows no control that depends on it.

## DECISION index

1.1 real Haptics switch · 1.2 does not mute the completion sound · 1.3 system haptics untouched · 2.1 never double a system cue · 3.0 reuse offline's PowerState, no new service · 3.1 no wording for power saver · 3.2 saver stops the Reduce Motion loops · 3.3 one native power switch for tests · 4.1 default 32 MB · 4.2 stepper · 5.1 typed path, validated · 5.2 success wording without the desktop shortcut · 5.3 group plumbing sessions do not get the folder · 7.1 footer describes the native intro · 8.1 chat text only · 8.2 pick from installed fonts · 8.3 chat font wins over the skin's typeface in chat text only · 9.1 no double-tap · 9.2 your own bubbles only · 10.1 system heart symbol · 10.2 any kind → hearts · 11.1 native link cards, no web view · 11.2 maps as link cards · 12.1 File Browser = chat-bar Files button · 13.1 row L759 web-shell-only · 14.1 list-derived alerts · 14.2 list-derived are "finished" only · 15.1 Kanban by polling · 16.1 owed removal retried at re-add · 17.1 one queueing path (MainBotRequest.queue) for push and Watch Browser · 18.1 split "Chat" into "Chat" and "Chat Extras" · 18.2 no doubled tick on system switches.
