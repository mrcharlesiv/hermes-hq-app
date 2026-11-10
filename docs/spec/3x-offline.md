# 3x — Offline screen, launch screen and reconnect behaviour (m9 stream `offline`)

Written 2026-10-11 by the m9 spec writer for stream `offline`. Branch `m9/offline`, worktree
`/Users/me/Projects/hermes-hq-native-wt/m9-offline`. 22 assigned rows (12 missing, 10 partial) plus one part of
another stream's row. The rows are listed verbatim in `docs/briefs/m9/offline-rows.md`.

How to read this file. Each row has its own section with the same seven headings: **Web** (what the web app does, with
file:line), **Native today**, **Design**, **Wire**, **Screen states and words**, **Owner**, **Fixture and checks**.
Decisions made without the owner are marked **DECISION**. Section 9 is the **STRESS PLAN**.

Path abbreviations:

| Abbrev | Path |
|---|---|
| `W` | `/Users/me/Projects/hermes-hq-native-ref240` (web app at build 240, read only) |
| `HA` | `/Users/me/.hermes/hermes-agent/tui_gateway/contracts` (Hermes contracts, read only) |
| `MEM` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory` (owner notes) |
| `N` | this repo |

Rules that bind every section (from the run brief and `docs/ARCHITECTURE.md`): Swift 6 with MainActor by default,
`withChildTasks` and never a task group, native Liquid Glass only (`UIGlassEffect`, `.glassEffect`, system bars and
sheets), wrapping rows get 12–14 pt vertical padding, every word the user sees is plain and says "Hermes HQ", never
"Dispatch", no control that does nothing, both `project.yml` and `project-original.yml` keep building. Hermes rejects
unknown params with error 4000, so every param below was checked against `HA`.

---

## 0. Summary of outcomes proposed

| Row | Feature | Proposed outcome |
|---|---|---|
| L107 | Launch screen: icon, late spinner, captions, actions, fade | build natively |
| L108 | Launch screen stays until a first list has content | build natively |
| L109 | Sign-in / offline follow light and dark live; pre-paint colour | live follow: verify and fix. Saved pre-paint colour: **web-shell-only** part (§3.3) |
| L110 | Stray errors fatal only while starting; storage failures shown | build natively (native analog, §3.4) |
| L205 | Slow first load says so after 15 s | build natively |
| L206 | Stale-list card | build natively |
| L207 part | "Can’t Load Bots" empty state | build natively (groups records the row) |
| L937 | Offline screen | build natively |
| L938 | Countdown and VoiceOver | build natively |
| L939 | Retry at once, Try Again, different gateway with Cancel | build natively |
| L943 | Reconnect banner | build natively |
| L944 | "Sign in again" notice | build natively |
| L945 | "Message too large" notice | build natively |
| L950 | Outage gate | build natively |
| L951 | Query retry policy | build natively |
| L954 | Tail recheck | build natively |
| L955 | Reconnect refresh share + sidebar probe | probe is already on the train; add the 3 s share, verify |
| L956 | Reconnect backstop stands down | build natively (native analog, §6.5) |
| L957 | Stale work check with `agents.list` | build the `agents.list` half; depends on a claim source (§6.6) |
| L958 | Read flight | build natively |
| L959 | Focus return | native analog built; the WebView blur itself is **web-shell-only** (§6.8) |
| L960 | Visible polls stretched and floored | build natively |
| L965 | Caches on first frame | Jobs kept: verify. Capabilities warm, tail prefetch order: build. "Page code warmed": **web-shell-only** part (§6.10) |

Nothing in this stream needs a change to the push relay, a plugin or the owner's real gateway. No file is written to
`docs/owner-todo/offline.md`. If a builder finds otherwise, the exact change goes there as a patch plus a plain note and
the app must degrade as §10 says.

---

## 1. What native has today (read before building)

* **Launch.** `App/AppDelegate.swift` `SceneDelegate.restore()` (line 140) puts `LaunchViewController` as root, reads the
  Keychain off the main thread (`SignInService.restoreState()`, `HermesKit/Net/SignInService.swift:125`) and then:
  `.signedIn(account)` → `showApp` (activates `AppModel`, builds `MainTabController`, no animation),
  `.signedOut(prefill)` → `showSignIn`, `.unavailable(failure)` → `LaunchViewController.showProblem(message)`.
  `App/Root/LaunchViewController.swift` (55 lines) is the page colour, a spinner after 0.6 s and a "Can’t Open Your
  Sign-In" problem state with Try Again. The system launch screen is a colour only
  (`App/Info.plist:49`, `UILaunchScreen` → `LaunchBackground`, #FEFEFE light, #0D1015 dark). `LaunchIcon` (96 pt) is in
  the asset catalog and already used by the sign-in screen.
* **Connection.** `HermesKit/Net/GatewayConnection.swift` (actor). States (`HermesKit/Contracts.swift:86`):
  `.connecting`, `.ready`, `.reconnecting(attempt:)`, `.offline(reason:)`, `.signedOut(reason:)`. Before the first
  `gateway.ready` a failed dial publishes `.offline(reason: <GatewayFailure code>)`; after it, `.reconnecting`. Back-off:
  `ReconnectBackoff.afterReady` (0.3 s base, 15 s cap) and `.beforeReady` (2 s base, 15 s cap), full jitter. Callers of a
  known-down connection fail at once (`waitPublished`: signed out, shut down, paused, no network path, Tailscale off).
  A frame over 64 MiB closes the socket with 1009 and yields `LocalEvent.messageTooLarge` once per streak
  (`GatewayConnection.swift:539-546`); nothing shows it.
* **Session ended.** `App/AppModel.swift:443-450`: on `.signedOut` the model tears down at once and
  `onSessionEnded(prefill)` swaps to the sign-in form.
* **Bots list.** `App/Bots/BotsViewController.swift`: five skeleton rows, `recheckSkeletonLater()` after 10 s, an offline
  empty state "Can’t Reach Hermes" whose second line shows the raw failure code (line 461: `reason.isEmpty ?
  "Hermes HQ keeps trying." : reason`, a bug this stream fixes). `HermesKit/Store/BotStore.swift` already has what the
  cards need: `loadState` (`.failed(RosterFailure{message,busy,at})`), `lastUpdated`, `phase` (`none/cache/slim/full`),
  `retryDelays [1 s, 2 s]`, a poll that is already ×3 in Low Power Mode or heat.
* **Sessions list.** `HermesKit/Store/SessionStore.swift:560-577` already probes before a full read
  (`fetchSidebar(limits: (1, 1, 1))`, fingerprint from `SidebarFingerprint.of`, `probeMaxAge` 10 min, forgotten on
  writes) and joins a read in flight (`readInFlight`).
* **Chat reconnect.** `HermesKit/Chat/LiveChatSession+Sync.swift:621-744`: `handleReady` → `reconnect(reason:)` →
  `session.activate`, then the connection's replay or `session.events.since`, else `refreshTail(force: true)` and
  `graftInflight(snapshot)`. A `sessions.changed` tick runs `scheduleChangedPass()` (line 496). Nothing re-reads a
  partial reply later.
* **Stale work.** `HermesKit/Activity/ActivityStore.swift:485-546`: `delegation.status` per profile on socket open,
  return and every 30 s. No `agents.list`; native keeps no background-process claims.
* **Warming and caches.** `HermesKit/Store/ChatWarmer.swift` (bots' chat tails, one at a time, 4 per pass, 8 on the
  first). `HermesKit/Pages/JobsStore.swift:77-90` paints Jobs from `PagesCache`. Capabilities has in-memory caches made
  when the page first opens (`App/Capabilities/CapabilitiesModel.swift:40-41`).
* **Naming.** `HermesKit/Model/GatewayNaming.swift` already ports `friendlyHostName`, `gatewayFriendlyName`,
  `gatewayHost` and `accountName` from `W/src/connection-offline.ts`.

---

## 2. Pieces this stream adds

New folders owned by this stream: `HermesKit/Offline/` (no UI) and `App/Offline/` (UI). Touch points in other folders
are named per row and kept small.

| File | What it is |
|---|---|
| `HermesKit/Offline/OfflineCopy.swift` | Every string of this stream in one place (pure): offline titles and recovery by reason, countdown, banner sentences, notices, launch captions, roster cards, startup errors |
| `HermesKit/Offline/RetryLadder.swift` | `[3, 6, 12, 24, 30]` s and the `Retry-After` rule (pure) |
| `HermesKit/Offline/LaunchGate.swift` | The launch screen's state machine (pure, injected clock) |
| `HermesKit/Offline/ReconnectBanner.swift` | `reconnectNotice(...)` and the banner's state machine (pure, injected clock) |
| `HermesKit/Offline/StartupProblems.swift` | `strayErrorIsFatal(phase:error:)` and `AccountStorage.check(_:)` |
| `HermesKit/Offline/LastGatewayHint.swift` | The last gateway's address, account name and label, kept outside the Keychain (never a secret) |
| `HermesKit/Net/OutageGate.swift` | The outage gate (pure, injected clock) |
| `HermesKit/Net/QueryRetry.swift` | The read retry rule and a `read` helper |
| `HermesKit/Net/ReadFlight.swift` | One background read at a time, none in the background, one catch-up |
| `HermesKit/Net/PowerPolls.swift` | Poll periods stretched for power, floored, re-armed on a power change |
| `HermesKit/Net/ReturnGate.swift` | Is this "became active" a return to the app or a moment inside it (pure) |
| `HermesKit/Chat/TailRecheck.swift` | The tail recheck ladder and `savedReplyCovers` (pure) plus its driver |
| `HermesKit/Activity/StaleWork.swift` | The `agents.list` half of the stale work check (pure reconcile) |
| `HermesKit/Store/PageDataWarm.swift` | Capabilities lists read ahead of the page's first open |
| `App/Offline/LaunchViewController.swift` | Moved from `App/Root/` and rebuilt (icon, late spinner, captions, actions) |
| `App/Offline/OfflineViewController.swift` | The offline screen (SwiftUI in a hosting controller, like sign-in) |
| `App/Offline/LaunchCoordinator.swift` | The hand-overs between launch, offline, sign-in and the app (taken out of `SceneDelegate`) |
| `App/Offline/ConnectionBanner.swift` | The reconnect banner: one Liquid Glass capsule under the status bar |
| `App/Offline/AppModel+Offline.swift` | Wires the banner, "Sign in again" and "Message too large" to the model |
| `App/Bots/RosterStateViews.swift` | The slow-load card, the stale card and the "Can’t Load Bots" state |
| `scripts/fixtures/offline-gateway.py` | The stand-in gateway for all of this (§7) |
| `scripts/e2e-offline.sh` | Starts the fixture on this stream's ports and runs the UI tests (§8) |
| `Tests/Offline/*.swift`, `UITests/offline/OfflineEndToEndTests.swift` | §8 |

**DECISION (one string table).** All wording lives in `OfflineCopy` so one unit test can assert that no string holds
"Dispatch" and that each matches the web text quoted in this file character for character (typographic apostrophes,
ellipsis "…", no-break space in the countdown).

`OfflineCopy.device` is `SignInCopy.device` ("iPhone" today); the web's `${DEVICE}` maps to it everywhere below.

---

## 3. Launch and offline

### 3.1 L107 — Launch screen

**Web.** `W/src/launch-screen.ts:23-45` (timings and captions), `:48-124` (machine), `W/src/launch-screen.css` (icon 96 pt
centred on the system background, a medium activity indicator 90 pt below centre, a 15 pt secondary-label caption 118 pt
below centre, max width 300, a 120 ms fade out, 100 ms with Reduce Motion), `W/src/main.ts:77` (the two buttons).
The screen is up from the first paint: icon only; the indicator after 900 ms; "Connecting to Hermes…" at 4 s
("Loading…" once the gateway is open and a list is still loading); at 12 s, if still not connected,
the stalled caption (§3.1) with **Try Again** and **Change Address or Sign In**; a failure
keeps the icon with the reason and the buttons; it fades out in 120 ms once content shows.

**DECISION (UX study 2026-10-21, #122):** native words the 12 s caption by account. Sign in with Nous and public
addresses need no Tailscale on the phone (owner, `onboarding-clarity.md`), so the caption names Tailscale only when
the gateway's address is a tailnet address or a `*.ts.net` name (`GatewayAddress.throughTailscale`); see the table
below.

**Native today.** Page colour, spinner after 0.6 s, a Keychain problem state.

**Design.**

* `UILaunchScreen` in `App/Info.plist` gains `UIImageName = LaunchIcon` and `UIImageRespectsSafeAreaInsets = false`,
  next to the existing `UIColorName = LaunchBackground`. The system then draws the 96 pt icon centred on the page
  colour before the process starts. `LaunchViewController` draws the same asset at the same size, centred in the
  window's full bounds (not the safe area), so the hand-over from the system screen is invisible. The builder compares
  a screenshot of the system launch screen (`xcrun simctl launch --wait-for-debugger`, then screenshot) with the first
  app frame; the icon must not move by a pixel on iPhone 17 Pro and on the smallest phone the SDK offers.
  **DECISION:** adding the icon to the system launch screen. The web shell's storyboard has it
  (`W/src/launch-screen.css:1-5` says so); "icon at first paint" cannot be met any other way.
  **REVISED 2026-11-02:** the icon left the system launch screen. Since Settings › App Icon (tester), that
  picture showed the Hermes head even to someone who had picked another icon, and iOS has no way to vary it. The
  system screen is the page colour alone; `LaunchViewController` draws the icon the app wears (`AppIcons.wornPicture`)
  in the same place, so the icon appears with the first app frame instead of at first paint.
* `LaunchViewController` renders a `LaunchGate.View` value: `spinner: Bool`, `status: String`, `actions: Bool`,
  `phase: shown | leaving | gone`. Layout: icon centred; `UIActivityIndicatorView(style: .medium)` 90 pt below centre,
  faded in over 0.25 s; caption 118 pt below centre, `UIFont.preferredFont(forTextStyle: .subheadline)`, secondary
  label, centred, max width 300, up to 4 lines, in a scroll view with the buttons under it so large text sizes scroll
  instead of clipping (`W/src/launch-screen.css` "dispatch-launch-foot"); the caption and buttons never move the icon.
  Buttons: "Try Again" (prominent glass) over "Change Address or Sign In" (glass), 16 pt apart, the same button
  configurations the sign-in screen uses.
* `LaunchGate` (pure) owns the timers. Constants, named as the web's: `spinner 0.9 s`, `status 4 s`, `stalled 12 s`,
  `content 5 s`, `settle 0.1 s`, `leave 0.12 s`. Inputs: `mounted()` (an account is active and the app can be shown),
  `blocker` (§3.2), `failed(message)`, `retry()` (restarts the timers: spinner stays, caption back to "Connecting to
  Hermes…", buttons hidden), `hide()` (sign-in owns the screen).
* **Try Again** at the stalled state: with an active account, `client.reconnectNow()` (cancels the dial in flight and
  dials again) and `gate.retry()`; with no account yet (the Keychain read is slow or failed), `restore()` again.
  **Change Address or Sign In**: §3.7.
* Leaving: a 120 ms cross-dissolve to the next root (100 ms with Reduce Motion), replacing today's hard cut
  (`showApp` passes `animated: false` from the launch screen) and the 300 ms dissolve used elsewhere.
  **DECISION:** the launch hand-over is always the 120 ms fade, to the app and to sign-in alike.
* VoiceOver: the icon is hidden from it; the caption is one static-text element; when the caption first appears or
  changes it is announced once (`UIAccessibility.post(.announcement)`); while only the icon shows, the screen has one
  element labelled "Hermes HQ".

**Wire.** None of its own. It watches `client.connectionStates()` and `BotStore` (see §3.2). The dial it waits on is
the existing one: `GET /api/auth/me`, `POST /api/auth/ws-ticket` → `{"ticket":"…"}`, `GET /api/ws?ticket=…` (upgrade),
then the event `{"type":"gateway.ready","payload":{"heartbeat":true,"change_events":true,"replay_epoch":"…"}}`.

**Screen states and words.**

| State | Shows |
|---|---|
| 0–0.9 s | icon only |
| from 0.9 s | icon + spinner |
| from 4 s, not connected | + `Connecting to Hermes…` |
| from 4 s, connected, first list still loading | + `Loading…` |
| from 12 s, still not connected | `Still connecting. Check that the computer running Hermes is on and awake.` (a gateway reached through Tailscale, a tailnet address or a `*.ts.net` name: `Still connecting. Check that the computer running Hermes is on and awake, and that Tailscale is on here.`) + **Try Again** + **Change Address or Sign In** |
| failed (startup error, §3.4) | icon, the reason, no spinner, **Try Again** (and **Change Address or Sign In** when a gateway address is known) |
| leaving | 120 ms fade, touches released at its start |

**Owner.** No note names the launch screen. The web behaviour shipped to the owner's phone through build 250 is the
approved one. On native feel in general, `MEM/hermes-hq-native.md:41`: "Wow. It's already SO MUCH smoother." — so a
cached launch must not get slower: see the DECISION in §3.2 (content at the first frame shows the app at once).

**Fixture and checks.** `offline-gateway.py` (§7) on port 9980.

1. `--delay-ticket 6`: launch signed in with caches wiped (`-HQDebugResetCaches YES`): icon at 0 s, spinner by 1 s,
   "Connecting to Hermes…" at 4 s, the app at ~6 s with a fade. Screenshots at 0.5, 2, 5, 7 s.
2. `POST /__fixture/mode {"mode":"blackhole","scope":"ws"}` (ticket answers, the socket never upgrades): at 12 s the
   stalled caption and both buttons. Try Again: caption returns to "Connecting to Hermes…", buttons leave.
3. Unit: `LaunchGateTests` drives every transition with a fake clock, including Try Again restarting the 12 s.
4. Pixel check of the system launch screen against the first app frame, light and dark.

### 3.2 L108 — Launch screen stays until a first list has content

**Web.** `W/src/launch-screen.ts:80-99` (`check`), `:126-148` (`launchBlocker`). The blocker is `cover` while the
gateway is not open and nothing saved is on screen, `loading` while the gateway is open and a first list is still on
its placeholder, `null` when content shows. Saved content (bot rows from the roster cache, a saved transcript) counts as
content while still connecting. Once the gateway is open a list gets 5 s (`content`) to fill; after that the app shows
with its own loading state. The page must stay ready for 100 ms (`settle`) so one placeholder handing over to the next
does not end the launch screen early.

**Native today.** The app shows as soon as the Keychain read ends, with skeleton rows when there is no cache.

**Design.** The gate reads the stores, not the views (pure and testable):

```swift
enum LaunchBlocker { case cover, loading }      // nil = content
protocol LaunchContentSource: AnyObject { var launchBlocker: LaunchBlocker? { get } }
```

`AppModel` conforms. With `bots = botStore`, `ready = (connection == .ready)`:

| Stores say | Blocker |
|---|---|
| the roster has rows (cache, slim or full), or `loadState == .ready` (an honest empty list), or `.failed` (an honest error state) | `nil` |
| no rows, not ready | `.cover` |
| no rows, ready, the first roster read still out | `.loading` |

`LaunchCoordinator` flow after the Keychain read says `.signedIn(account)`:

1. `model.activate(account)` (stores paint from disk synchronously, as today).
2. If `model.launchBlocker == nil` right away, the app is shown at once with the 120 ms fade. **DECISION:** content at
   the first frame skips the wait entirely (no settle delay, no extra icon time). The row exists so nobody looks at a
   blank screen or a placeholder; with a cache there is nothing to wait for, and the owner's "SO MUCH smoother" must
   hold.
3. Otherwise `LaunchViewController` stays root, `gate.mounted()` is called, and the coordinator re-checks the blocker on
   every `BotStore.onChange` and connection change. `.cover` → keep waiting (captions as §3.1). `.loading` → start the
   5 s content allowance once; the caption "Connecting to Hermes…" becomes "Loading…". Ready (`nil`, or `.loading`
   with the allowance spent) must hold for 100 ms, then the app shows.
4. While `.cover`: a connection that turns `.offline(reason)` hands over to the offline screen (§3.5); `.signedOut`
   hands over to the prefilled sign-in with the existing notice.

`MainTabController` is created at the hand-over, laid out off screen first (`loadViewIfNeeded()`, frame = window bounds,
`layoutIfNeeded()`), so the fade ends on drawn rows.

**Wire.** The first list is the roster: RPC `profiles.list {"include_sessions": false}` (slim) then `profiles.list {}`
(`HA/profiles_vault_complete_foreign_subagents.py:171-184`; answer `{"profiles":[…],"bot_mode_protocol":true,…}`).

**Screen states and words.** As §3.1; the only new word is `Loading…`.

**Owner.** As §3.1. `MEM/connection-speed-assessment.md:13` records that the web's "launch screen leaves on saved
content" was part of the approved launch work.

**Fixture and checks.**

1. Cached launch (signed in, caches present, fixture up): the app's rows are on screen in the first frame after the
   system launch screen; no spinner, no caption (video frame check: `xcrun simctl io <udid> recordVideo`).
2. Caches wiped, `POST /__fixture/delay {"rpc":{"profiles.list":3}}`: the launch screen holds through the 3 s with
   "Loading…" from 4 s only if still waiting; rows are drawn when it fades. No skeleton frame is ever seen.
3. Caches wiped, `{"rpc":{"profiles.list":20}}`: the app shows 5 s after the socket opened, with skeleton rows, then the
   slow-load card of §4.1 at 15 s of skeleton.
4. Unit: `LaunchGateTests` — allowance starts once per launch, settle restarts when the blocker returns, `.failed`
   and an empty roster count as content.

### 3.3 L109 — Sign-in and offline screens follow light and dark live; pre-paint colour

**Web.** `W/src/connection-offline.ts:58-92`. `savedMode` reads the saved appearance (light, dark or none = System);
`followSystemAppearance` re-applies the scheme on every system change while the saved mode is System (the page decided
only once at launch before: "a phone that turned dark behind them stayed white"); `bootBackground` paints the
background the renderer stored on its last run (`hermes-boot-background`) when it was painted in the same scheme.

**Native today.** `AppearanceSetting` (`App/Settings/AppearanceSetting.swift`, key `hqn.appearance`) sets the window's
`overrideUserInterfaceStyle`; colours are dynamic (`HQPalette`). The parity audit found no proof, so the row is open.

**Design.**

* Live follow: the launch, offline and sign-in screens use only dynamic colours (`HQPalette.page`, labels, glass).
  With the saved mode System the window override is `.unspecified`, so UIKit re-resolves them on a system change with
  no code. With a saved Light or Dark the override wins, as on the web (`followSystemAppearance` returns early when
  `savedMode` is set). The builder audits the three screens for any colour resolved once (a `cgColor` stored on a
  layer, a rendered image, a `UIColor` resolved with fixed traits) and fixes what it finds;
  `AppearanceSetting.apply(to:)` must run before the first root is set.
* Pre-paint colour. In native the pixels before the first frame belong to the system launch screen. It is a static
  asset: `LaunchBackground` has a light and a dark value equal to `HQPalette.page` (#FEFEFE / #0D1015), and iOS picks by
  the system appearance. So when the saved mode is System, or equals the system's, the colour is already right from the
  first pixel with nothing to save. **Proposed web-shell-only part:** "the colour saved from the last run". The web
  shell paints its own HTML before the renderer boots and can read a stored colour; a native app cannot change what
  iOS draws before the process starts (`UILaunchScreen` is read from the bundle; `UIUserInterfaceStyle` in Info.plist
  is fixed at build time; there is no public API to swap it). When the saved mode is forced opposite to the system's,
  the first app frame applies the saved mode at once: one colour change at the hand-over, no white flash later.
  A unit test pins `LaunchBackground`'s two values to `HQPalette.page`'s so they cannot drift.

**Wire.** None.

**Screen states and words.** None new.

**Owner.** No note. Web behaviour through build 250 is the reference.

**Fixture and checks.** No gateway needed for the first two.

1. Sign-in screen up, saved mode System: `xcrun simctl ui <udid> appearance dark`, screenshot, `… appearance light`,
   screenshot. Both flip with no relaunch. Same on the offline screen (`-HQDebugRestoreFailure keychain-locked`) and on
   the launch screen held by `--delay-ticket 30`.
2. Saved mode Dark (`defaults write` of `hqn.appearance` through `-hqn.appearance dark` launch argument), system light:
   all three screens stay dark through a system change.
3. Unit: the colour-asset test above.

**DECISION (builder, 2026-10-12): checks 1 and 2 run outside XCTest, in `scripts/offline-appearance-check.sh <udid>`.**
An app launched by a UI test kept the appearance the simulator had when the xcodebuild test session began: switching
inside a test, with `XCUIDevice.shared.appearance` and with `xcrun simctl ui` run on the Mac, changed the setting
(simctl read back "dark") while the launched app went on drawing the other appearance for as long as the test waited
(seen in the test's own screen recording and in its pixels, both directions). The same build launched with
`simctl launch` is dark at its first frame and follows a switch one to three seconds after simctl returns (the delay is
the simulator's, measured with a screenshot every second). So the script signs the app in to the stand-in, then
photographs the launch screen (held with `-HQDebugLaunchHold 40`), the offline screen (gateway answering 503) and the
sign-in screen while switching the simulator, and reads the page colour from every screenshot: thirteen checks, the
launch held by the debug hold in place of `--delay-ticket`, the offline screen by a 503 in place of the Keychain
failure, and the saved-Dark case on the offline screen. The dark screenshots of the other new states (notice, alerts,
header) come from `testO18_DarkScreens`, which `scripts/e2e-offline.sh` runs in a pass of its own with the simulator
dark before the session starts; the test checks its own pixels are dark, so a session that did not start dark fails.

### 3.4 L110 — Stray errors are fatal only while starting; storage-switch failures are shown

**Web.** `W/src/connection-startup.ts:230-234` `strayErrorIsFatal(phase, error)`: a storage error is fatal unless the
app is mounted or ready; a ResizeObserver error never is; anything else only while `booting` or `signing-in`.
`W/src/main.ts:414-431`: a fatal one shows "Hermes HQ couldn’t start. Close and reopen the app to try again." on the
launch screen (or the storage sentence), others are only logged. `W/src/main.ts:44-65`: switching the phone's saved app
data to the signed-in account can fail (`StartupStorageError`) and says so.

**Native today.** There is no global stray-error channel in Swift: a thrown error is handled where it is thrown, or
dropped by a `Task`. Per-account storage is a set of folders keyed by account; nothing checks that they can be opened,
and write failures are silent (`try?`).

**Design (native analog).**

* `StartupPhase`: `.booting` (until the restore decided), `.signingIn` (sign-in form up to the account being
  activated), `.mounted` (the app is on screen), `.offline`. `StartupProblems.isFatal(phase:error:)` ports the rule:
  `AccountStorageError` is fatal unless `.mounted`; any other unexpected error is fatal only in `.booting` and
  `.signingIn`; a `GatewayFailure`, `SignInError` or `CancellationError` is never "stray" (their own screens word them).
* Where unexpected errors can surface: `LaunchCoordinator` wraps the restore, the activation and the sign-in completion
  in one `do/catch` and routes what it catches through `isFatal`. Fatal → `gate.failed(message)` on the launch screen
  (icon, the sentence, Try Again = `restore()` again). Not fatal → `AppLog.note("stray", …)` only; the screen on show
  is never replaced.
* Storage. `AccountStorage.check(_ account:) throws(AccountStorageError)`: creates the account's folders (roster cache,
  transcript cache, pages cache, queue stash, attachment drafts; the builder lists the exact roots from `RosterDisk`,
  `TranscriptCache`, `PagesCache`, `QueueStash`, `AttachmentCenter`), writes and removes a one-byte probe file in each.
  It runs off the main thread before `model.activate(account)` at launch, after a sign-in, and before a gateway switch
  (`SignInService.switchTo`). A failure at launch or sign-in shows the storage sentence on the launch screen with Try
  Again. A failure on a switch from Settings cancels the switch (the current account stays) and shows the sentence in
  the system alert the switcher already uses for failures (`App/Kit/FailureAlert.swift`).
  **DECISION:** this check is the honest native form of "storage-switch failures are shown": native has no single
  switch step, so the check stands where the web's switch stands.

**Wire.** None.

**Screen states and words.**

* Unexpected error while starting: `Hermes HQ couldn’t start. Tap Try Again.`
* Storage: `Hermes HQ couldn’t switch this iPhone’s saved app data to this account. Your drafts are kept. If iPhone storage is almost full, free up some space, then try again.`
  (from `W/src/main.ts:44`, `${DEVICE}` → iPhone).
  **DECISION (UX study 2026-10-21, #133):** native drops the web's "Close and reopen the app": the launch screen puts
  Try Again right under the sentence, and quitting an app is not an iOS instruction.

**Owner.** No note. The web behaviour is the reference.

**Fixture and checks.** No gateway needed.

1. Unit `StartupProblemsTests`: the truth table of `isFatal` for every phase × {storage, other, gateway failure,
   cancellation}.
2. Unit `AccountStorageTests`: a root made read-only (a temp folder with `0500`) throws; a writable one passes and
   leaves no probe file behind.
3. UI: `-HQDebugStorageFailure YES` (DEBUG hook that makes `AccountStorage.check` throw) at launch shows the storage
   sentence under the icon with Try Again; the same hook during a gateway switch shows the alert and the app stays on
   the first gateway.

### 3.5 L937 — Offline screen

**Web.** `W/src/main.ts:285-388`. Shown when restoring the saved sign-in fails for a reason that is not a refusal and a
cached start is not allowed (`W/src/main.ts:464` `mayBootCached`; with a cache the app starts from it and the header
says "Offline"). Layout (`:356`): icon, title, recovery text, a card with the gateway's friendly name and
"host · account", **Try Again**, **Change Address or Sign In** (hidden when no address is known), **Sign In Again**
(only when the saved sign-in is unreadable), a status line. Copy by reason: `OFFLINE_COPY` (`:331-344`), defaults
`:376-381`. Names: `W/src/connection-offline.ts` (`gatewayFriendlyName`, `gatewayHost`), `accountName` (a Nous sign-in
reads "Nous account").

**Native today.** With a saved session the cached app always shows; with no cache the Bots list shows skeletons, then
"Can’t Reach Hermes" with a raw code under it. A Keychain failure shows "Can’t Open Your Sign-In".

**Design.** The offline screen is a root screen (`OfflineViewController`, a `UIHostingController` over a SwiftUI
`OfflineView`, built like `App/SignIn/SignInView.swift` so the icon, type and buttons match). It shows in two cases:

* **A. The saved sign-in cannot be opened** (`RestoreState.unavailable(failure)`: `keychain-locked`,
  `keychain-unavailable`, `keychain-unreadable`). Replaces `LaunchViewController.showProblem`.
* **B. Signed in, nothing saved to show, and the gateway cannot be reached**: the launch gate's blocker is `.cover`
  (§3.2) and the connection publishes `.offline(reason)` before its first ready, with a reason that is not a refusal.

With saved content the app starts from it and the header says "Offline", exactly as the web's cached start does.
**DECISION:** this is the web's own rule (offline screen only when a cached start is not possible), not a native
shortcut; the Bots list's old offline empty state is replaced by "Can’t Load Bots" (§4.3).

What it shows comes from `OfflineCopy.screen(reason:hasAddress:)`:

| Reason (`GatewayFailure.code`) | Title | Recovery |
|---|---|---|
| `tailscale-off` | `Turn On Tailscale` | `Turn on Tailscale to reach the computer running Hermes. Hermes HQ reconnects as soon as it’s on.` |
| `timeout` | `Hermes Isn’t Answering` | `The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying.` |
| `tls` | `Can’t Verify Hermes` | `iPhone doesn’t trust the HTTPS certificate of the computer running Hermes. Hermes HQ keeps trying; if this continues, sign in with a trusted address.` |
| `gateway-outdated` | `Update Hermes` | `The computer running Hermes has a version of Hermes that’s too old for Hermes HQ. Update Hermes there; Hermes HQ keeps trying.` |
| `rate-limited` | `Hermes Is Busy` | `It is limiting sign-ins right now. Hermes HQ will try again shortly.` |
| `host-rejected` | `Hermes Isn’t Accepting This Address` | `Hermes no longer accepts connections at the saved address. On the computer running Hermes, check HERMES_DASHBOARD_PUBLIC_URL in ~/.hermes/.env; Hermes HQ keeps trying.` |
| `not-hermes` | `Can’t Reach Hermes` | `The saved address answered, but not as Hermes. Hermes HQ keeps trying; check the computer running Hermes, or sign in with its current address.` |
| `keychain-locked` | `Unlock Your iPhone` | `Your saved sign-in is protected until iPhone is unlocked. Hermes HQ reconnects as soon as it is.` |
| `keychain-unavailable` | `Can’t Open Your Saved Sign-In` | `iPhone couldn’t open it just now. Hermes HQ keeps trying. Your local drafts are being kept.` |
| `keychain-unreadable` | `Can’t Read Your Saved Sign-In` | `Sign in again to continue. Drafts on this iPhone are kept aside, not moved to the account you sign in with.` |
| `network` (this phone has no network path; audit 06-10) | `You’re Offline` | `iPhone isn’t connected to the internet. Hermes HQ reconnects as soon as it is.` (status line: `Waiting for a connection…`) |
| `timeout` or anything else, a Nous agent (`*.agents.nousresearch.com`; audit 06-11) | as its row | `Your Nous agent may be stopped or still starting. If it’s stopped, start it on Nous Portal. Hermes HQ keeps trying.` |
| anything else (`unreachable`, `unavailable`, `gateway-error`, …), address known | `Can’t Reach Hermes` | `The computer running Hermes may be asleep or on another network. Hermes HQ keeps trying.` |
| anything else, no address known | `Can’t Reach Hermes` | `Tap Try Again to recover your saved connection before changing sign-in. Your local drafts are being kept.` |

The card: first line the friendly name (`GatewayNaming.title(url:label:)`: a name given on this phone wins, else the
computer's name, else "The computer running Hermes", `OfflineCopy.unnamedCard`, UX study #24); second line `host:port · account` (`GatewayNaming.host(url, port: true)` and
`GatewayNaming.accountName`, joined with " · ", empty parts left out). With no address known the second line reads
`Your saved sign-in could not be read.` and the first `The computer running Hermes`; the card is hidden when no address is known and
the reason is `keychain-unreadable` (`W/src/main.ts:378`). The card's two lines wrap; it gets 13 pt top and bottom
padding (`MEM/row-padding-feedback.md:16`: "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt
top and bottom, with line-height set.").

Case A has no account in memory, so the address comes from `LastGatewayHint`: on every successful activation the app
stores `{url, accountName, label}` in `UserDefaults` (`hqn.offline.lastGateway`), nothing secret; sign-out of the last
account clears it. **DECISION:** this hint, so the screen can name the gateway while the Keychain cannot be read, as
the web can from its saved state.

Buttons, top to bottom: **Try Again** (prominent glass), **Change Address or Sign In** (glass; hidden when no
address is known), **Sign In Again** (glass; only for `keychain-unreadable`). Under them the status line (§3.6). The
body sits in a scroll view: centred when it fits, scrolling from the top at large text sizes with Try Again reached by
scrolling (`W/src/main.ts:354-355`).

**DECISION (UX study 2026-10-21, #125, #126):** native differs from the web here. The prefilled form's button reads
**Change Address or Sign In** (it opens on the same gateway, so "a Different Gateway" promised what it did not do).
When the saved sign-in was read and other gateways are saved, one glass **Switch to <name>** button per other gateway
follows (the title menu's switch: its saved session is made current and the launch takes over; a gateway whose session
ended opens the sign-in sheet prefilled with it). With no address known, a Keychain reason hides the card (its title
and words say it already), and `keychain-unavailable` also offers **Sign In Again** (with the same confirmation) once
three Keychain reads in a row have failed.

**Sign In Again** (unreadable saved sign-in) asks first with a system alert: title `Sign in again?`, message
`Hermes HQ couldn’t read your saved sign-in. Drafts on this iPhone are kept aside and won’t move to the account you sign in with.`,
buttons **Sign In Again** and **Cancel**. On yes: the unreadable Keychain items are removed
(`SignInService`'s existing clear; if that fails the status line shows the storage sentence of §3.4 and nothing else
happens), then the sign-in form shows with the hinted address filled in. Drafts live in per-account folders, so they
are "kept aside" by construction: a new sign-in to the same address and username gets them back, any other account
never sees them.

A retry that fails again re-renders title, recovery and card from the new reason. A retry that is refused
(`.signedOut`) goes to the prefilled sign-in with the existing notice
(`SignInCopy.messages["session-ended"]`). A retry that connects shows the app with the 120 ms fade.

**Wire.** The retry is one dial of the saved session, never a password sign-in:
`GET /api/auth/me` → 200 `{"username":"…"}` or 401; `POST /api/auth/ws-ticket` → 200 `{"ticket":"…"}`, 401, 429 with
`Retry-After`; `GET /api/ws?ticket=…`. Case A's retry is the Keychain read again (`SignInService.restoreState()`), no
network.

**Screen states and words.** The table above, plus the status line of §3.6. Words on buttons: `Try Again`,
`Change Address or Sign In`, `Sign In Again`.

**Owner.** No note names the offline screen. On glass, `MEM/liquid-glass.md:26`: "It isn't Liquid Glass. So much of this
is wrong." — the buttons are system glass configurations, nothing drawn by hand.

**Fixture and checks.** `offline-gateway.py` on 9980 with control port 9981 (§7).

1. Sign in, quit, relaunch with `-HQDebugResetCaches YES` after `POST :9981/__fixture/mode {"mode":"refuse"}`: the
   offline screen with `Can’t Reach Hermes`, the default recovery, the card `The computer running Hermes` over
   `127.0.0.1:9980 · <username>`. Screenshot light and dark.
2. Each reason: `mode` `blackhole` → `Hermes Isn’t Answering`; `{"mode":"status","status":429,"retry_after":20}`
   → `Hermes Is Busy`; `{"mode":"status","status":400,"body":"Invalid Host header"}` → `Your Gateway Turned This Address Away`
   (**DECISION**, builder: the first draft of this check said status 421; Hermes answers a wrong address with 400 and
   the body "Invalid Host header", which is what `GatewayFailure.from(status:body:)` and the web recognise, so the
   stand-in answers that);
   `{"mode":"not-hermes"}` → the not-Hermes copy; `{"mode":"outdated"}` → `Update Hermes`. Keychain
   reasons through `-HQDebugRestoreFailure <code>`. `tls` and `tailscale-off` by unit test of the copy table plus a
   DEBUG state injection (`-HQDebugOfflineReason <code>`), since loopback cannot produce them.
3. With caches kept and the fixture refusing: the cached app shows, header "Offline", no offline screen.
4. A given name: rename the gateway in Settings, repeat 1: the card's first line is the given name.
5. Unit `OfflineCopyTests`: every row of the table, the card lines for Nous and password accounts, no "Dispatch".

### 3.6 L938 — Auto-retry with countdown; VoiceOver hears it once

**Web.** `W/src/main.ts:289` `OFFLINE_RETRY_S=[3,6,12,24,30]` (the last value repeats), `:313-321` the countdown: the
status line shows `retryCountdown` (`W/src/connection-offline.ts:55`: `Trying Again in N s` with a no-break space before
`s`, N = `max(1, ceil(seconds))`), re-rendered every second, no spinner; VoiceOver's text is set once to
`Trying again automatically` ("a count read later would already be wrong"). During an attempt the line reads
`Connecting…` with a spinner and the buttons are disabled (`:322-329`, `:346-350`).

**Native today.** None. The connection retries with a jittered 2 s to 15 s back-off that nobody can see.

**Design.** One clock, owned by the thing that retries:

* `RetryLadder.steps = [3, 6, 12, 24, 30]`; `wait(attempt:retryAfter:) = min(120, max(steps[min(attempt, 4)],
  retryAfter ?? 0))`. **DECISION:** a 429's `Retry-After` stretches the wait (capped at 120 s) so the countdown never
  promises a dial the gateway asked us not to make.
* Case B: `ReconnectBackoff.beforeReady` becomes the ladder (no jitter: one phone, nothing to spread), and
  `GatewayConnection` publishes when the next dial is due: `LiveGatewayClient.nextRetry: Date?` (set when a pre-ready
  retry is scheduled, nil while a dial runs or once ready), with a change callback on the main actor. The offline
  screen only draws it. The same ladder runs under the cached app; it just has no screen.
  **DECISION:** changing the pre-ready back-off to the web's ladder, so the countdown shown is the real timer and not a
  second clock that could drift from it. The after-ready back-off is untouched.
* Case A: `OfflineViewController` owns a `RetryLadder` timer that calls the Keychain read again. While the reason is
  `keychain-locked` it also retries when `UIApplication.protectedDataDidBecomeAvailableNotification` fires ("Hermes HQ
  reconnects as soon as it is").
* The status line: a label with monospaced digits showing the countdown, re-rendered each second from the due date
  (never from a decrementing counter, so a paused run loop cannot make it lie). It is hidden from VoiceOver; a sibling
  accessibility element carries the spoken text. When a countdown starts, `Trying again automatically` is announced
  once; the number is never spoken. When an attempt starts the line reads `Connecting…` beside a spinner, the spoken
  text is `Connecting…`, and the buttons are disabled until it ends.

**Wire.** As §3.5.

**Screen states and words.** `Trying Again in 3 s` … `Trying Again in 1 s` (no-break space, U+00A0), then
`Connecting…` with a spinner. Spoken: `Trying again automatically`, then `Connecting…`.

**Owner.** No note. The web behaviour is the reference.

**Fixture and checks.**

1. Fixture refusing, offline screen up: the fixture's ledger (`GET :9981/__fixture/state` → `dials` with timestamps)
   shows dials 3, 6, 12, 24, 30, 30 s apart (each ±0.5 s). The screen's number at each dial is 1 → `Connecting…`.
2. `{"mode":"status","status":429,"retry_after":20}`: the first wait is 20 s, not 3.
3. Unit `RetryLadderTests`: steps, the repeat of 30, the `Retry-After` rule and its cap; the countdown text for 2.2 s
   is `Trying Again in 3 s`, for 0.2 s `Trying Again in 1 s`, with U+00A0.
4. VoiceOver (unit test on the view model's announcements; a manual pass with the Accessibility Inspector): one
   announcement per countdown, none per second.

### 3.7 L939 — Retry at once on foreground or network; Try Again; a different gateway with Cancel

**Web.** `W/src/main.ts:366-371`: the offline screen retries on `online`, on the app's return to the foreground and
when the native layer says the network is reachable again. `:322-329`: a tapped Try Again shows `Connecting…` with the
spinner on this screen and moves focus to the status line. `:358`: **Change Address or Sign In** opens the sign-in
form; `W/src/connection-startup.ts:363-368` (`backToOffline`, `canGoBack`): Cancel on that form returns to the offline
screen, which goes on retrying.

**Native today.** `becameActive` and a restored network path already redial an established connection; nothing the
user can press exists before the first ready.

**Design.**

* Foreground and network: in case B the connection's own `.becameActive` and `.path(.restored)` commands cut a pending
  pre-ready wait and dial now (the builder checks `GatewayConnection.becameActive` and `pathChanged` do this before the
  first ready, not only after; add it where missing). In case A the screen's own timer does the same on
  `sceneDidBecomeActive`. Forced dials are spaced at least 1 s apart, so a flapping path cannot spin.
* **Try Again**: case B `client.reconnectNow()`; case A the Keychain read. The status line turns to `Connecting…`,
  the buttons disable, and VoiceOver focus moves to the status element (`UIAccessibility.post(.layoutChanged,
  argument: status)`). A manual retry does not reset the ladder position (web: only leaving the screen does).
* **Change Address or Sign In**: presents the sign-in form in a navigation controller as a full-screen sheet with
  a **Cancel** bar button, built with the flow Settings already uses to add a gateway
  (`App/Gateways/AddGatewayFlow.swift`), prefilled with the saved address and username so the common fix (a changed
  address) is an edit, not a retype. **DECISION:** prefill rather than an empty form. Cancel dismisses back to the
  offline screen; the retries never stopped underneath (the web resumes them; native simply leaves them running, and a
  connection that opens while the form is up dismisses the form and shows the app). A successful sign-in saves the new
  account as the current one and shows the app; the old account stays in the saved list, as with Add Gateway.
* The launch screen's **Change Address or Sign In** (§3.1) is the same presentation with the same Cancel.
* No loop of sign-ins: automatic retries only ever reuse the saved session. A password is sent only when the user
  submits the form.

**Wire.** As §3.5. The form's own calls are the existing sign-in ones (`GET /api/status`,
`POST /auth/password-login`).

**Screen states and words.** `Try Again`, `Connecting…`, `Change Address or Sign In`, `Cancel`.

**Owner.** No note. The web behaviour is the reference.

**Fixture and checks.** Two fixtures: A on 9980/9981, B on 9982/9983 (`--label B`).

1. Offline screen at "Trying Again in 24 s"; `POST :9981/__fixture/mode {"mode":"up"}`, then background and
   foreground the app (`xcrun simctl launch` of another app and back): the app shows within 2 s, not after 24.
2. Same, tapping Try Again instead.
3. Network: unit test with a scripted `PathWatcher` (`.lost` then `.restored`) asserting one immediate dial; the
   simulator cannot drop loopback.
4. Change Address or Sign In → Cancel: back on the offline screen, the countdown still running and correct (the
   ledger shows the ladder unbroken). Again → sign in to B with B's test credentials from `build/fixtures/offline-b.json`:
   the app shows B's bots; Settings lists both gateways.
5. A's gateway comes up while the form is open: the form dismisses and A's app shows.

---

**DECISION (review round): a Try Again that fails keeps the ladder's place, and honours the gateway's wait.** A dial
asked for with Try Again before the first ready is an extra one: when it fails, the automatic wait that follows is
the rung the ladder was on (`GatewayConnection.extraDial`), not the next one up, so three impatient taps never turn
3 s into 30 s. The retries that fire by themselves still climb, and so do the dials a return to the app or a restored
network make (only Try Again is exempt: opening the app again and again against a gateway that is down must never ask
it faster, UI `testS29`). Inside a 429
`Retry-After` window Try Again does not dial at all; the countdown the screen shows is that wait. Checks: integration
test `UnreachableGatewayTests.aFailedTryAgainDoesNotClimbTheLadder` (3 s, three manual dials each followed by 3 s,
then the automatic one by 6 s), UI `testO05` (the wait after a failed Try Again is still at most 12 s, twice) and
`testO04` (no request for 4 s after Try Again inside `Retry-After: 300`).

**[net-ready] (build 295) A dial that beat the network gets one quick do-over.** The launch's (or a return's, or a
path change's) dial that fails `unreachable` within 1 s is dialed again after 200 ms, not after the 1 s floor and the
first rung, and the screen stays on `Connecting…` meanwhile (spec 01 §13.4, `NetSettle`). It is not a rung: the
ladder above starts at the second failure, so a gateway that is really down sees one extra ticket request per launch,
return or path change, never more (a 503 or a timeout gets no do-over at all, so `testS29` is unchanged).

## 4. Bots list states

### 4.1 L205 — A slow first load says so after 15 s

**Web.** `W/src/ui-bots/roster-states.tsx:41-58`: `SLOW_LOAD_MS = 15_000`; after 15 s of skeleton a card says
`Still loading your bots… Your gateway is taking longer than usual.` with **Try Again**; the skeleton drops from 6 rows
to 3 under it; Try Again hides the card, retries and waits the full 15 s before saying so again.

**Native today.** Five skeleton rows; a 10 s recheck that ends on "Can’t Reach Hermes".

**Design.** In `BotsViewController` the 10 s recheck goes. While `showsSkeleton` a 15 s timer runs; when it fires the
list shows a card row above 3 skeleton rows (instead of 5). The card (`RosterStateViews.slowCard`) is a list cell on
`HQPalette.groupedCard` with 13 pt top and bottom padding, the sentence wrapping, and a plain tinted **Try Again**
button; no glass (it is list content, not a floating control). Try Again: hide the card, `services.refreshBots()`
(joins a roster read in flight or starts one) and, when the connection is not ready, `client.reconnectNow()`; the
15 s starts over. **DECISION:** Try Again does not cancel a read already in flight on an open socket: the web's own
notes (`W/src/rpc-flight.ts:2-6`) say an abandoned read keeps a gateway worker busy, so cancelling and re-asking a slow
gateway makes it slower. The card leaves the moment rows or an end state arrive. VoiceOver: the skeleton is one element
"Loading bots"; the card's sentence is announced once when it appears.

**Wire.** `profiles.list {"include_sessions": false}` then `profiles.list {}`.

**Screen states and words.** `Still loading your bots… Your gateway is taking longer than usual.` · `Try Again`.

**Owner.** No note. The web behaviour is the reference.

**Fixture and checks.**

1. Caches wiped, `POST /__fixture/delay {"rpc":{"profiles.list":40}}`: the launch screen leaves at 5 s (§3.2), the
   card shows 15 s after the skeleton did, 3 skeleton rows under it. Try Again: card gone, back after 15 s more. Rows
   arrive at 40 s and replace everything.
2. Unit: the timer restarts on Try Again and is cancelled when rows land.

### 4.2 L206 — Stale-list card

**Web.** `W/src/ui-bots/roster-states.tsx:66-76`: when a refresh failed and the last good list is still shown, a card
says `Waiting for your gateway. ` (gateway not connected) or `Can’t refresh bots. ` followed by
`Showing the list from 3:41 PM.` (the time of the last good draw, hour and minute in the phone's format) or
`Showing the last list.` when no time is known, with **Try Again**. Wiring: `W/build/ui-bots-gates.ts:134-176`
(`waiting={!gatewayUp}`; `noteRosterFresh()` whenever the list draws from a good answer).

**Native today.** Nothing: a failed refresh leaves the old list with no word.

**Design.** `BotStore.loadState == .failed` with rows on screen → the card as the list's first row (same cell style as
§4.1). `waiting = (connection != .ready)`. The time is `BotStore.lastUpdated` (the last good answer's time, or the
cache's own time for a cached paint), formatted with `Date.FormatStyle(date: .omitted, time: .shortened)`; nil → the
"last list" sentence. Try Again: `services.refreshBots()` plus `client.reconnectNow()` when not ready; the card stays
until a good answer redraws the list (then `lastUpdated` moves and the card leaves) and shows a small spinner in place
of the button while the retry runs.

So the card appears promptly in an outage, a roster refresh that falls due while the outage gate says the gateway is
down (§6.1) fails at once with a "waiting" `RosterFailure` instead of waiting out `readyWait` (120 s). The reconnect
then re-reads as today (`BotStore.handle` on `gateway.ready` when failed).

**Wire.** `profiles.list {}`; a failure is any RPC error, a timeout, or the gate's fast failure.

**Screen states and words.**

* `Waiting for your gateway. Showing the list from 3:41 PM.`
* `Can’t refresh bots. Showing the list from 3:41 PM.`
* `Waiting for your gateway. Showing the last list.` / `Can’t refresh bots. Showing the last list.`
* `Try Again`

**Owner.** No note. The web behaviour is the reference.

**Fixture and checks.**

1. App up with bots; `POST /__fixture/fail {"rpc":"profiles.list","code":-32000,"count":5}`; pull to refresh: the
   card reads `Can’t refresh bots. Showing the list from <time>.`; the rows stay. Clear the failure, Try Again: card
   gone.
2. `mode refuse` for 40 s: within one poll (30 s on the list) the card reads `Waiting for your gateway. Showing the
   list from <time>.`; `mode up`: the card leaves by itself after the reconnect's read.
3. Unit: sentence for each of the four cases; 24-hour locale formats `15:41`.

### 4.3 "Can’t Load Bots" (the part of groups' row L207 this stream builds)

**Web.** `W/src/ui-bots/roster-empty.tsx:12-16`, `W/src/ui-kit/unavailable.tsx:34-39`: an error state with the
`exclamationmark.circle` symbol, title `Can’t Load Bots`, a reason, and **Try Again**. The reason is
`Hermes HQ is waiting for your gateway to reconnect.` when the gateway is not connected,
`Your gateway is busy, so your bots couldn’t load in time.` when the failure was a busy gateway, else the error's own
words or `The gateway didn’t answer.`

**Native today.** "Can’t Reach Hermes" with a raw code as its second line.

**Design.** In `BotsViewController.updateEmptyState`: no rows and (`loadState == .failed` or the connection is
`.offline`) → `UIContentUnavailableConfiguration` with image `exclamationmark.circle`, the title, the reason chosen as
above (`RosterFailure.busy`, else `RosterFailure.message` if not empty, else the default), and a **Try Again** button
(same action as §4.2). This replaces the old offline empty state and its raw-code line. The raw code is never shown.
The outcome of row L207 is recorded by the groups stream; this stream notes "Can’t Load Bots: done" in its own rows
file when it lands.

**Wire.** As §4.2.

**Screen states and words.** `Can’t Load Bots` · one of the three reasons · `Try Again`.

**Owner.** No note. The web behaviour is the reference.

**Fixture and checks.** Caches wiped; `POST /__fixture/fail {"rpc":"profiles.list","code":-32000,"count":99}`: after
the roster's own retry (§6.2) the state shows with `The gateway didn’t answer.` (or the error's words). With a timeout
(`delay` beyond the roster timeout, shortened by the test's `BotStoreTiming`): the busy sentence. With the connection
dropped after ready and no rows: the waiting sentence. Screenshot each.

---

## 5. Notices

### 5.1 L943 — Reconnect banner

**Web.** `W/src/connection-startup.ts:123-207` (`reconnectNotice`, `RECONNECT_NOTICE_HOLD_MS = 4000`,
`reconnectBanner`), `W/src/native-runtime.ts:51-59,75-93` (wiring). A dropped socket starts a 4 s hold; a socket back
within it shows nothing (the header's "Reconnecting…" covers a blip). A lost network shows at once. The banner says
only `Reconnecting to the computer running Hermes…` until a reconnect attempt has actually failed, then why. A failure while the app
is in the background (`paused`) says nothing. When the header has turned to "Offline" the second sentence is
`Hermes HQ keeps trying.` It clears when the socket opens and stops for good on a sign-out.

**Native today.** Header subtitles ("Reconnecting…", "Offline") and the composer's placeholder. No banner.

**Design.**

* `ReconnectBanner` (pure machine, injected clock), a port with the same inputs: `socketError(attempt:)`,
  `failure(reason:)`, `foreground()`, `network(reachable:)`, `open(attempt:)`, `refresh()`, `stop()`, and
  `offline: () -> Bool`. Output: the sentence to show, or none.
* Mapping from native: `AppModel+Offline` feeds it from `client.connectionStates()` and `client.lastFailure`.
  `.reconnecting(attempt: n)` → `socketError(attempt: n)`; when `n ≥ 1` also `failure(reason: lastFailure.code)`;
  `.offline(reason: "network")` → `network(reachable: false)`; any other `.offline(reason)` → `failure(reason:)`;
  `reason == "paused"` is passed through and stays silent; `.ready` → `open`; `.signedOut` → `stop()`;
  `appDidBecomeActive` → `foreground()`. `offline()` reads the same thing the header reads to say "Offline" (the
  connection is `.offline`, or has been reconnecting for 120 s; the builder uses the header's existing helper so the
  two can never disagree).
* The banner never shows before the app is on screen (launch and offline screens have their own words) and never over
  the sign-in form.
* `ConnectionBanner` (UI): one capsule of system glass (`UIVisualEffectView` with `UIGlassEffect(style: .regular)`, built
  like `App/Kit/UndoPill.swift`), added to the window under the status bar in the slot `ReplyPeek` uses, max width 440,
  12 pt side insets, 13 pt top and bottom padding, text in `.subheadline`, up to 4 lines (the corners become a 22 pt
  continuous radius when it wraps past one line), a leading `wifi.exclamationmark` symbol for the network sentence and
  `arrow.triangle.2.circlepath` for the others. It is a status, not a control: no tap action; a swipe up hides it for
  the rest of this outage. A reply peek takes the slot while it shows and the banner returns after it. It fades in and
  out over 0.2 s (no slide with Reduce Motion). VoiceOver announces each new sentence once; the element is static text.
  At accessibility sizes the capsule grows with the text and stays under the status bar.
  **DECISION:** the top slot. The bottom belongs to the composer, the tab bar and the Undo pill.

**Wire.** None of its own.

**Screen states and words** (`reconnectNotice`, `W/src/connection-startup.ts:128-145`):

| When | Sentence |
|---|---|
| no network path | `Network unavailable. Check your network or VPN connection.` |
| header says Offline, no attempt failed yet | `The computer running Hermes is out of reach. Hermes HQ keeps trying.` |
| header says Offline, Tailscale off | `Turn on Tailscale to reach the computer running Hermes. Hermes HQ keeps trying.` |
| header says Offline, timeout | `The computer running Hermes is slow to answer. Hermes HQ keeps trying.` |
| header says Offline, rate limited | `The computer running Hermes is busy. Hermes HQ keeps trying.` |
| header says Offline, unreachable or no reason | `Can’t reach the computer running Hermes. Check your network or VPN connection. Hermes HQ keeps trying.` |
| header says Offline, other | `Can’t connect to the computer running Hermes right now. Hermes HQ keeps trying.` |
| held 4 s, no attempt failed yet | `Reconnecting to the computer running Hermes…` |
| Tailscale off | `Turn on Tailscale to reach the computer running Hermes. Reconnecting…` |
| timeout | `The computer running Hermes is slow to answer — still trying…` |
| rate limited | `The computer running Hermes is busy — still trying…` |
| unreachable or no reason | `Can’t reach the computer running Hermes. Check your network or VPN connection. Reconnecting…` |
| other | `Can’t connect to the computer running Hermes right now. Reconnecting…` |

**Owner.** `MEM/connection-speed-assessment.md:17` lists as the first approved option: "hold the header's
"Reconnecting…" on a foreground return so a healthy reconnect is invisible", and `:28` records the owner's device check
for that work: "background a minute → no "Reconnecting…"". The banner must keep that promise: a return to the app
whose reconnect succeeds within 4 s shows no banner.

**Fixture and checks.**

1. Blip: `POST /__fixture/drop {}` (sockets closed, gateway still up): the header may say "Reconnecting…", no banner
   ever shows (video check across 6 s).
2. Outage: `mode refuse`: nothing for 4 s, then `Can’t reach the computer running Hermes. Check your network or VPN connection.
   Reconnecting…`; after 120 s the second sentence becomes `Hermes HQ keeps trying.`; `mode up`: the banner leaves
   within a second of the socket opening.
3. Slow and busy: `mode blackhole` → the slow sentence; `{"mode":"status","status":429}` → the busy one.
4. Background: `mode refuse`, send the app to the background for 60 s (the socket closes after its 20 s grace), bring
   it back with the gateway up: no banner. Bring it back with the gateway still down: nothing for 4 s, then the banner.
5. Unit `ReconnectBannerTests`: port the web's cases (hold, show at once on a lost network, cause only after a failed
   attempt, paused is silent, refresh re-reads the header's state, stop is final).

**DECISION (review round, 2026-10-12): the notice is transient and takes no touches.** The header's subtitle
("Reconnecting…", "Offline") is the lasting sign of an outage, as Telegram keeps "Connecting…" in the title and nothing
else. A sentence stays 6 s (`ConnectionBanner.stay`) and leaves by itself, upwards; it is shown again only when it has
something new to say (the cause is named, the network is lost, "Hermes HQ keeps trying."). While it is up the capsule
has `isUserInteractionEnabled = false`: the bar buttons it lies over (Account, Search, the + on Bots; Back and the
header in a chat) work through it. The swipe up that puts it away for the rest of the outage is a pan on the window
that begins on the capsule, cancels no touch and recognises beside everything else. Checks: UI `testO11` (read from
the app's own record of what the notice put up, "debug.notice", DEBUG: nothing for a blip, the first sentence not
before the 4 s hold, each sentence gone after about 6 s while the gateway is still down and the header still says so,
no sentence twice in one outage)
and `testO21` (compose menu, Back in a chat and Search each used through the notice, which is kept up with the
DEBUG argument `-HQDebugNoticeStay`; then a swipe up puts it away).

### 5.2 L944 — "Sign in again" when the session is refused mid-session

**Web.** `W/src/native-runtime.ts:60-73`: when the gateway refuses the saved session while the app is on screen, the
banner stops and a sticky notice shows: title `Sign in again`, message
`Your gateway ended this ${DEVICE}’s session. Sign in again to reconnect; your drafts are kept.`, action
`Sign in again` (which reloads into the prefilled sign-in form). Not shown while the launch screen still covers
(`main.ts` then goes to the sign-in form itself).

**Native today.** `AppModel.connectionChanged` tears the app down and shows the sign-in form at once, with no word
that the drafts are safe.

**Design.** `.signedOut` while the app is on screen no longer tears down by itself. `AppModel+Offline` calls
`ReconnectBanner.stop()` and presents a system alert over whatever is on top:

* title `Sign in again`, message `Your gateway ended this iPhone’s session. Sign in again to reconnect; your drafts are kept.`
* **Sign in again** (preferred): flush drafts first (`AttachmentCenter.flush()`, `QueueStash.shared.flush()`, the open
  composer's draft save, `TranscriptCache.shared.flush()`), then the existing path
  (`tearDown` and `onSessionEnded(prefill)` → the prefilled form with its notice).
* **Not Now** (cancel): the app stays on its saved screens. Nothing dials (a signed-out connection fails callers at
  once). The header subtitle reads `Signed Out` (the word `GatewayNaming.row` already uses for a saved gateway without
  a session). The alert shows again when the app next becomes active and when a send fails because of the ended
  session.

**DECISION:** a system alert with a way to put it off. The web's notice is a sticky toast; a sticky banner in native
would sit on the navigation bar and block Back. An alert says the same two things (why, and that drafts are kept) and
"Not Now" keeps the web's property that the user can finish copying something out of a chat first.

While the launch or offline screen is still up the old direct route stays: straight to the prefilled form.

**Wire.** The refusal arrives as today: a 401 on `GET /api/auth/me`, `POST /api/auth/ws-ticket` or a REST read after the
session renewal failed; the connection publishes `.signedOut(reason:)`.

**Screen states and words.** `Sign in again` · `Your gateway ended this iPhone’s session. Sign in again to reconnect; your drafts are kept.` ·
`Sign in again` · `Not Now` · header `Signed Out`.

**DECISION (audit 06-14, 2026-11-06):** native names the gateway and writes the title and button in title case, as the
offline screen's button: `Sign In Again` · `<gateway name> ended this iPhone’s session. Sign in again to reconnect; your
drafts are kept.` · `Sign In Again` · `Not Now`. The unreadable sign-in's confirmation title is `Sign In Again?`.
The prefilled form that follows offers the other saved gateways that still have a session (`Switch to <name>`, audit
06-13).

**Owner.** No note names this notice. The web's wording is the reference; the drafts promise is the point of the row.

**Fixture and checks.** `offline-gateway.py --hermes-cookies` on 9980.

1. Open a chat, type a draft (do not send), `POST :9981/__fixture/revoke`: within one request the alert shows; the
   reconnect banner is not on screen. **Sign in again** → the form with address and username filled → sign in with the
   fixture's test credentials → open the same chat: the draft is in the composer.
2. Same, **Not Now**: the chat stays readable, the header says `Signed Out`, the ledger shows no further dials; send
   → the alert again; background and foreground → the alert again.
3. Revoke before launch (app quit, caches wiped): the launch screen goes straight to the prefilled form, no alert.
4. Unit: the alert is presented once per ended session, never stacked.

### 5.3 L945 — "Message too large"

**Web.** `W/src/native-runtime.ts:74`: when a socket closes with 1009 because a frame is larger than the native 64 MiB
limit, one sticky warning: title `Message too large`, message
`Your gateway sent a message larger than 64 MB, which Hermes HQ on ${DEVICE} can’t receive. It was skipped; open this chat on your computer to see it.`

**Native today.** `GatewayConnection` yields `LocalEvent.messageTooLarge` (`hq.message_too_large`) once per streak;
`AppModel.gatewayEvent` ignores it.

**Design.** `AppModel.gatewayEvent` handles `LocalEvent.messageTooLarge`: a system alert with the title, the message
and **OK**. One per streak (the connection already emits once per streak); never stacked on one still showing; held
until the app is active if it arrives in the background grace. **DECISION:** an alert, because a skipped message is
something the user must not miss and there is nothing else to do about it on the phone.

**Wire.** A WebSocket text frame over 64 MiB (`task.maximumMessageSize = 64 << 20`,
`HermesKit/Net/GatewayConnection.swift:381`); the socket closes 1009 and the connection reconnects.

**Screen states and words.** `Message too large` ·
`Your gateway sent a message larger than 64 MB, which Hermes HQ on iPhone can’t receive. It was skipped; open this chat on your computer to see it.` · `OK`.

**Owner.** No note. The web's wording is the reference.

**Fixture and checks.**

1. `POST :9981/__fixture/oversize {"bytes": 67200000}`: one alert; the app reconnects under it; the chat list still
   works after OK. A second oversize frame while the alert is up adds no second alert.
2. Unit (exists, extend): `Tests/NetRegressionTests.swift:358` asserts one event per streak; add the model test that
   one alert request follows one event.

---

## 6. Quiet network behaviour

### 6.1 L950 — Outage gate

**Web.** `W/src/connection-reachability.ts` (whole file). Reads pass one place. Once a read finds the gateway
unreachable while the socket is down (transport code `unreachable`, or HTTP 502, 503, 504, 520–526, 530), or after the
second socket dial in a row that failed before opening (`FAILED_DIALS = 2`), reads fail at once except one probe per
window (2 s doubling to 30 s: `PROBE_BASE_MS`, `PROBE_CAP_MS`). A read that timed out counts as unreachable only while
the socket is down; with the socket open, three timeouts in a row (`STALL_TIMEOUTS = 3`) start a stall held the same
way. Any answered read, or the socket opening, ends it. Returning to the app lets the next read probe at once. Writes
are never held. Held reads fail with `Can’t reach the computer running Hermes right now. Try again.` (code `unreachable`) or, in a
stall, `The computer running Hermes isn’t answering right now. Try again in a moment.` (code `timeout`).

**Native today.** Calls fail at once only for the known-down cases listed in §1. A gateway that is simply not
answering lets every poller wait out its own timeout.

**Design.** `OutageGate` (a `nonisolated final class` over the existing `Locked` box, injected clock), a line-for-line
port: `admit() -> Bool`, `reached()`, `unreachable()`, `timeout()`, `socket(open:)`, `dialFailed()`, `wake()`,
`state` (`down`, `stalled`, `probeIn`, `socketOpen`). One per `LiveGatewayClient`.

* Where reads pass: `LiveGatewayClient.send(...)` (`HermesKit/Net/LiveGatewayClient.swift:93`). For `GET` and `HEAD`
  only: `guard gate.admit() else { throw gate.heldFailure }`. After the request: an HTTP answer that is not a down
  status → `reached()`; a down status or a transport failure mapped to `.unreachable` → `unreachable()`; a timeout →
  `timeout()`. Every other method (POST, PUT, PATCH, DELETE) and uploads are never held.
* `heldFailure`: two new `GatewayFailure` values that reuse the stable codes: `.heldUnreachable` (code `unreachable`,
  message `Can’t reach the computer running Hermes right now. Try again.`) and `.heldTimeout` (code `timeout`, message
  `The computer running Hermes isn’t answering right now. Try again in a moment.`). Both answer `true` to a new
  `GatewayFailure.isHeld`, which §6.2 reads.
* Socket signals: `GatewayConnection` already knows each of these moments; it reports them through its existing
  outbound hooks: socket published → `socket(open: true)`; socket closed → `socket(open: false)`; a dial that failed
  before it opened → `dialFailed()` (counted once per dial).
* `wake()`: from `LiveGatewayClient.appDidBecomeActive()` when `ReturnGate` (§6.8) says it is a return.
* `GatewayClient` gains `var gatewayDown: Bool { get }` with a protocol-extension default of `false` (test doubles
  need no change); the live client answers `gate.state.down`. `BotStore` reads it for §4.2.
* RPC calls are not gated here (the web gates only its HTTP reads; socket calls already fail fast when not
  connected).

**Wire.** No new call. The probe is whichever read is admitted first in a window.

**Screen states and words.** The two held messages, shown wherever a read's failure is shown today (a page's error
state, a pull-to-refresh failure).

**Owner.** No note names the gate. `MEM/startup-open-chat-error.md:11` records the owner's screenshot of an error toast
"over a chat that then loaded fine", fixed by retrying quietly. The gate must not bring that back: it holds background
reads; a chat open is a user action whose first read is a probe when one is due and which retries on the reconnect
(the existing quiet retry).

**Fixture and checks.**

1. Port the web's unit cases to `OutageGateTests` with a fake clock: windows 2, 4, 8, 16, 30, 30 s; socket open
   overrides one unreachable read; stall after three timeouts with the socket open; a closed socket ends a stall;
   `wake()` zeroes the window; recovery resets the doubling.
2. Fixture: app on the Jobs tab (polling), `mode refuse` for 90 s. `GET :9981/__fixture/state` → the count of gateway
   connection attempts for REST reads in that time is at most 8 (one probe per window: 2, 4, 8, 16, 30, 30) where today
   every poll dials. Then `mode up`: the first admitted probe succeeds and the next read of every poller goes out.
3. Stall: `POST /__fixture/stall {"rest": 40}` with sockets open and the test's REST timeout shortened to 2 s: after
   three timeouts reads fail at once with the stall sentence; `{"rest": null}`: a probe clears it.
4. Writes: during 2, a pin toggle (PATCH) is sent, not held (it fails on its own with the transport's words).

### 6.2 L951 — Query retry policy

**Web.** `W/src/query-retry.ts` (whole file): a read that timed out (code `timeout`, or an RPC message
`request timed out after Ns`), or one the gateway cannot be reached for (`offline === true`, or code `unreachable`,
`unavailable`, `tailscale-off`), or an aborted one, is not asked again: the page shows its error at once and its own
Try Again asks. Any other failure gets one quick retry (1 s).

**Native today.** Mixed: `BotStore` retries twice (1 s, 2 s) unless busy; `SessionStore` never; the pages vary.

**Design.** `QueryRetry` (pure): `shouldRetry(failureCount:error:) -> Bool` = false for `GatewayFailure` codes
`timeout`, `unreachable`, `unavailable`, `tailscale-off`, `network`, `paused`, any `isHeld`, `RPCError.isTimeout`,
`isNotConnected`, `isConnectionLost`, `CancellationError`, `URLError.cancelled`; otherwise `failureCount < 1`. And
`QueryRetry.read(_ work:)`: runs `work`, on a retryable failure waits 1 s and runs it once more. **DECISION:**
"not connected" and "connection lost" count as unreachable (a retry one second later cannot do better than the
reconnect's own re-read).

Adopted by every read that loads a page or a list: `BotStore.performFull` (its `retryDelays` becomes the rule: one
retry at 1 s, none after a timeout or unreachable), `SessionStore.performRead`, `JobsStore.refresh`, the Kanban and
Artifacts reads, `CapabilitiesModel.load`, the Settings config reads. The builder greps for every retry loop and
`Task.sleep` after a `catch` under `HermesKit/` and `App/`, lists each in the stream brief with before and after, and
leaves alone anything that is not a read (sends, uploads, the socket's back-off, action polls).

**Wire.** No new call.

**Screen states and words.** None new; errors show sooner.

**Owner.** No note. The web's rule is the reference.

**Fixture and checks.**

1. Unit `QueryRetryTests`: the table of failures.
2. Fixture ledger: `POST /__fixture/fail {"method":"GET","path":"/api/cron/jobs","status":500,"count":1}` → two
   requests (the retry succeeds, the page shows no error). `"status":503,"count":1` → one request, the error shows at
   once. A REST `delay` beyond the timeout → one request.

### 6.3 L954 — Tail recheck

**Web.** `W/src/connection-tail-recheck.ts` (whole file). A reply cut off by a reconnect whose missed events are gone
(replay buffer exceeded, gateway restarted) stays cut off: the resume finds the turn no longer running and folds the
journaled partial reply onto the transcript, which the gateway had not saved yet. Now such a resume starts a series:
re-read the chat's newest rows after 2, 5, 10, 20, 30, 60, 120 s (`TAIL_RECHECK_MS`) while the chat is on screen and
the app in front; once the saved rows hold the same prompt followed by an assistant reply at least as long as the one
shown (`savedReplyCovers`), resume again so the saved reply replaces the partial. A turn that is running again ends
the series (its events carry the rest). A new reconnect or open restarts the ladder.

**Native today.** `reconnect(reason:)` grafts the snapshot's `inflight` partial (`graftInflight`) and reads the tail
once. Nothing reads again.

**Design.** `TailRecheck` in `HermesKit/Chat/`:

* Pure parts: `ladder = [2, 5, 10, 20, 30, 60, 120]`; `shown(messages) -> (prompt: String, reply: Int)` (the last user
  message's text and the summed text length of the assistant messages after it); `savedReplyCovers(rows, shown)`
  (whitespace-normalised prompt equality, then saved assistant text length ≥ shown).
* When it starts: at the end of `LiveChatSession.reconnect` and of an open, if the settled turn is not running and
  what the chat shows for its last turn is a partial the gateway has not saved: the snapshot carried a non-empty
  `inflight.assistant` with `running == false`, or the newest assistant message after the last prompt is still local
  (no stored row id) after the tail read. It does not start when the turn is running.
* Each step: if the chat is not on screen or the app not active, the series ends (`owed`). Otherwise read the newest
  rows without merging (`HistoryAPI.fetch`, limit 24, the chat's own request shape), test `savedReplyCovers`; when
  covered, call `refreshTail(force: true)` (which replaces the local partial with the saved rows) and end; when not,
  wait the next step; after the last step, end. A read that fails counts as "not covered".
* A reconnect or reopen of the same chat restarts the ladder from 2 s; the shown reply length kept is the larger of
  the old and new for the same prompt. One series per chat object; it is cancelled in `stopObserving`.

**Wire.** `GET /api/sessions/{id}/messages?profile=<p>&limit=24&order=desc&include_compacted=true` (or the performance
plugin's route with the same query when `gateway.ready` advertises it, as `HistoryAPI` already chooses). Example answer
rows: `[{"id":41,"role":"user","content":"Summarise the report"},{"id":42,"role":"assistant","content":"The report…"}]`.
The partial arrives in `session.activate` / `session.resume`'s answer:
`{"session_id":"ab12cd34","running":false,"inflight":{"user":"Summarise the report","assistant":"The rep"},…}`.

**Screen states and words.** None. The bubble grows to the full reply by itself.

**Owner.** No note names it. It comes from the web's stress round (R-07: "the bubble stayed at what had streamed
(10.5k of 113k characters for minutes)").

**Fixture and checks.**

1. `POST :9981/__fixture/turn {"session_id":"<bot chat>","chars":20000,"drop_at":3000,"save_after":8}` then send
   "go" in that chat: about 3,000 characters stream, the socket drops, the fixture restarts its replay epoch (nothing
   to replay), finishes the turn unseen and saves the reply 8 s later. The app reconnects showing the partial; the
   ledger shows tail reads at +2 s and +7 s (not covered) and +17 s (covered), then one merging read; the bubble holds
   all 20,000 characters without leaving the chat. No read after that.
2. Leave the chat at +3 s: no further reads. Reopen: the open's own read shows the full reply once saved.
3. `"save_after": 400`: reads at 2, 7, 17, 37, 67, 127, 247 s and then none.
4. Unit `TailRecheckTests`: `savedReplyCovers` (older turn's reply never passes; whitespace; shorter saved reply does
   not pass), ladder restart on a new reconnect, end on running.

**DECISION (review round): the prompt is matched leniently and a reply that stays shorter ends the series.** The saved
prompt and the shown prompt are the same when one contains the other once white space is evened out (the gateway may
save an attachment note or injected context around it). Reply lengths are counted with white space evened out on both
sides and the saved reply may be up to 2% shorter. When the gateway has a reply saved after that prompt, the turn is
not running, and two reads in a row find it shorter than the one shown, nothing longer will come: the series ends,
what is shown stays, and later resumes that settle on the same turn with no more text start no new series
(`TailRecheckSeries.concluded`). So a chat that can never match costs two reads, once, not seven per reconnect.

### 6.4 L955 — Reconnect sessions refresh shared within 3 s, plus the sidebar probe

**Web.** `W/src/reconnect-refresh.ts` (`RECONNECT_REFRESH_SHARE_MS = 3000`: two reconnect callers within 3 s for the
same connection and profile share one run; a failed run is not shared; a probe first), `W/src/sidebar-probe.ts`
(the probe is the same sidebar read with `recents_limit=1&cron_limit=1&messaging_limit=1`; the fingerprint is each
slice's newest row, its pinned rows without `is_active`, and `recents.profiles_usage`; no fingerprint for an answer
with errors; a full read at least every 10 min; any list-changing write forgets it).

**Native today.** The probe is already on the train: `SessionStore.performRead(probeFirst:)`
(`HermesKit/Store/SessionStore.swift:560-564`), `SidebarFingerprint.of` (`HermesKit/Model/RosterSessions.swift:96`),
`probeMaxAge` 10 min, `lastFingerprint = nil` on writes. A `gateway.ready` joins a read in flight. What is missing is
the 3 s window: a second `gateway.ready` just after the first read ended starts another probe.

**Design.**

* **One probe.** This stream adds no second probe. The planner's note stands: the sessions stream's row L287 and this
  row are the same mechanism; whichever lands second rebases onto the first's `performRead`. If the sessions stream has
  changed the probe when this lands, keep theirs and add only the share.
* **The share.** `SessionStore` remembers the last reconnect refresh: `(startedAt, failed)`. In `handle` for
  `gateway.ready`: if a reconnect refresh started within 3 s and did not fail, do nothing (join it if still running);
  else start one (`readTask(probeFirst: true)`) and record it. Pull to refresh, `sessions.changed` ticks and switches
  keep their own reads. A failed run is not shared.
* **Counts.** `AppLog.note("sessions", "reconnect refresh: probe skipped|full|failed in N ms")` per run, so the
  performance log shows what the probe saves.
* The builder checks `SidebarFingerprint` against `W/src/sidebar-probe.ts:50-69` case by case (pinned rows sorted and
  stripped of `is_active`, `profiles_usage` included, nil on `errors`, `profiles_failed`, storage notes or `retry`) and
  ports the web's test vectors.

**Wire.** Full read:
`GET /api/profiles/sessions/sidebar?recents_profile=all&recents_limit=50&cron_limit=50&messaging_limit=100&recents_exclude=<list>&messaging_exclude=<list>&profile=default`.
Probe: the same with `recents_limit=1&cron_limit=1&messaging_limit=1`. Answer shape:
`{"recents":{"sessions":[…],"total":n,"profiles_usage":{…}},"cron":{"sessions":[…]},"messaging":{"sessions":[…]},"errors":[]}`.

**Screen states and words.** None.

**Owner.** `MEM/connection-speed-assessment.md:32`: "Sidebar probe: src/sidebar-probe.ts, limits=1 probe compares newest
row + pinned rows (minus is_active) + profiles_usage; full read if >10 min old, any write forgets, errors → full." It
shipped to the owner in internal build 205 with the list measured at about 570 KB per read.

**Fixture and checks.**

1. `POST /__fixture/drop {}` twice, 1 s apart: the ledger shows one sidebar request (a probe, limits 1/1/1) for the
   pair, no full read.
2. `POST /__fixture/touch {"session_id":"…"}` then drop: one probe then one full read.
3. Drop, wait 4 s, drop: two probes.
4. A probe answered with `{"errors":[{"profile":"x"}]}`: a full read follows.
5. Unit: the share window, a failed run not shared, the fingerprint vectors.

**DECISION (review round): the read that covers a reconnect answers for it, whoever started it.** A `gateway.ready`
that arrives while a sidebar read is in flight is covered by that read; if the covering read fails, is cancelled or
stops, the share is handed back (`ReconnectShare.failed()`), so the next socket open inside the 3 s reads for itself.

### 6.5 L956 — Reconnect backstop stands down when the open chat re-activates

**Web.** `W/src/reconnect-tail-owner.ts`: every reconnect read the open chat's newest rows twice, milliseconds apart:
a general backstop on socket open and the chat's own re-activation. The re-activation owns the read; the backstop
waits 400 ms (`RECONNECT_RESUME_WAIT_MS`) and stands down when the chat re-activated meanwhile.

**Native today.** One owner already exists for the socket-open case (`reconnect(reason:)`). The native pair that can
double up is different: the `sessions.changed` tick a gateway broadcasts around a reconnect runs
`scheduleChangedPass()` → a second tail read (or a limit-1 probe) while or just after the reconnect's own read; and a
return to the app can run `reconnect(reason: "reopen")` and `reconnect(reason: "gateway.ready")` back to back.

**Design (native analog).** The reconnect owns the tail read:

* While `reconnectTask` is running, `scheduleChangedPass()` returns without scheduling.
* When a reconnect ends having caught up (replay, `session.events.since`, or its REST tail read), it stamps
  `lastChangedPassAt = now`, so a `sessions.changed` within the pass gap (10 s) becomes the one trailing pass, which is
  a limit-1 probe.
* A "reopen" reconnect that starts within 400 ms of a "gateway.ready" one (or the other way round) is the same
  reconnect: the later call joins the running task instead of cancelling and restarting it, unless the runtime id
  changed in between.

**Wire.** `session.activate {"session_id":"<runtime id>","cols":96,"omit_messages":true,"profile":"<p>"}`
(`HA/sessions.py:206-216`), `session.events.since {"session_id":"<runtime id>","last_seen":123,"profile":"<p>"}`
(`HA/sessions.py:723-737`, answer `{"events":[…],"latest_seq":n,"truncated":false,"count":n,"epoch":"…","open_requests":[]}`),
and the tail read of §6.3.

**Screen states and words.** None.

**Owner.** No note. The web's stability round (N6) is the source.

**Fixture and checks.**

1. Chat open, `POST /__fixture/restart {}` (new epoch, sockets dropped) with the fixture set to broadcast
   `sessions.changed` right after `gateway.ready` (`--changed-on-ready`): the ledger shows exactly one
   `session.activate` (or `session.resume` after the 4007) and exactly one `/messages` read for that chat.
2. `POST /__fixture/drop {}` (same epoch, replay possible): one `session.activate`, zero `/messages` reads, at most one
   limit-1 probe.
3. Background 30 s and return: the same counts as 1 or 2, never doubled.
4. Unit: `scheduleChangedPass` during a reconnect schedules nothing; the 400 ms join.

### 6.6 L957 — Stale work check: `delegation.status` and `agents.list`

**Web.** `W/src/stale-work-check.ts` (whole file). A Sessions row says "Working…" while its chat holds a running
subagent or a running background process. Hermes sends their end only to the socket the chat was bound to, so a phone
that was away never hears it. The check asks two process-wide lists that no chat binding gates:
`delegation.status` (every running subagent) and `agents.list` (every background process), on socket open, on return
to the app (after a 1.5 s settle) and every 30 s while a claim exists (stretched for power), with `{}` params and a
15 s timeout, one read per route however many chats claim. A claim neither list reports is dropped. A chat whose
running child is a `delegate-tool:` stand-in is skipped.

**Native today.** The subagent half exists (`ActivityStore.staleCheck`, 30 s poll, 15 s timeout, one read per
profile, stand-ins skipped). No `agents.list`, because native keeps no background-process claims at all: nothing in
native says "Working…" for a background process today.

**Design.**

* `StaleWork` (pure): `dropProcesses(claims: [ProcessClaim], running: Set<String>) -> [ProcessClaim]?` (nil when
  nothing changes): running claims the gateway no longer lists are removed, finished rows are kept.
* `ActivityStore` gains the claim side: `processClaims: [String: [ProcessClaim]]` by runtime id
  (`ProcessClaim { id: String; running: Bool }`), `setProcessClaims(runtimeId:_:)`, and `onProcessClaimsChange`. They
  count toward `refreshLiveWork()` (so a row says "Working…" for them) and toward `updateStalePoll()`.
* `staleCheck()` gains the second read: for each profile with a running process claim, one
  `agents.list` (params `{}` for the default route, `{"profile": "<p>"}` otherwise; timeout 15 s); the answer's
  `processes` with `status == "running"` give the running set by `session_id`; `StaleWork.dropProcesses` reconciles
  each claiming chat whose claims did not change while the read was out.
* `-32601` (an older Hermes without the method) is remembered until the next `gateway.ready`, as `listUnsupported` is.
* Overlap guard: `staleCheck` runs through a `ReadFlight` (§6.7) so the settle timer and the poll can never run two at
  once.

**Dependency (honest note).** The claims come from the background-task capsule, which is the composer stream's row
L461 ("1 background task ›"). If that is on the train when this is built, the builder wires its process list into
`setProcessClaims`. If it is not, this stream ships the read, the reconcile and the hook, proved by unit tests and by
the fixture ledger with claims set through `-HQDebugProcessClaim <stored id>:<process id>` (DEBUG only), and the row is
recorded as **partial: waits for composer L461** in `offline-rows.md`. It is not an owner to-do.

**Wire.** `HA/billing_delegation_pets.py:361-385`: `delegation.status` params `{profile?}`, answer
`{"active":[{"subagent_id":"sa_1","status":"running",…}],"paused":false,"max_spawn_depth":2,"max_concurrent_children":4}`.
`HA/tools_commands.py:66-83`: `agents.list` params `{profile?}`, answer
`{"processes":[{"session_id":"proc_1","command":"npm run dev","status":"running","uptime":312}]}`. No other param is
sent (4000 otherwise).

**Screen states and words.** None new: a stuck "Working…" stops.

**Owner.** `MEM/stuck-working-row.md:11`, TestFlight feedback on build 149: "a session row stayed "Working…" after
Hermes completed." The fix the owner accepted is this check (`:15`).

**Fixture and checks.**

1. Subagent half (regression): `POST /__fixture/work {"session_id":"…","subagents":["sa_1"]}`, the row says
   "Working…"; `POST /__fixture/work/end {"subagents":["sa_1"]}` (silent, no event): within 30 s the row stops saying
   it; the ledger shows one `delegation.status` per check.
2. Process half: the same with `"processes":["proc_1"]` and the claim source (L461's, or the DEBUG argument): one
   `agents.list` per check, `{}` params, the claim dropped within 30 s; with two chats claiming, still one read.
3. Return: background, end the work, foreground: the check runs 1.5 s after the return, not at the next 30 s tick.
4. Unit `StaleWorkTests`: reconcile cases; a claim that changed while the read was out is left alone; `-32601` stops
   the asking until the next ready.

### 6.7 L958 — Read flight

**Web.** `W/src/rpc-flight.ts:1-98` (`singleFlight`): a background read runs one at a time; callers during a run share
one trailing run; nothing is sent while the app is hidden, with one catch-up run when it is back; background callers
wait out a gap since the last start and a quiet time after a slow run. Used for the projects tree refresh
(`W/build/fe-native-gates.ts:404`: gap 15 s on the phone, slow 25 s, quiet 60 s). The reason
(`W/src/rpc-flight.ts:2-6`): the gateway serves reads from a small worker pool shared with opening chats, and a read
the phone gave up on keeps its worker.

**Native today.** `BotStore` (`loadTask`) and `SessionStore` (`readInFlight`, `Throttle`) already run one read at a
time and stop in the background. Others do not: `JobsStore.refresh()` starts a new read on every call and only drops
the older answer; `ActivityStore.staleCheck()` has no running guard; the Kanban and Artifacts stores and the Settings
reads vary.

**Design.** `ReadFlight` (MainActor, injected clock):

```swift
final class ReadFlight {
    init(gap: @escaping () -> Duration = { .zero }, slowAfter: Duration? = nil, quietFor: Duration = .zero,
         isActive: @escaping () -> Bool, clock: any FlightClock = .live, _ task: @escaping () async -> Void)
    func request(background: Bool = false) async     // returns when a run covering this call has finished
    func becameActive()                              // runs the one owed catch-up
    var state: (running: Bool, trailing: Bool, scheduled: Bool, owed: Bool) { get }
}
```

Rules, as the web's: not active → mark owed, return; running → join the one trailing run (a foreground joiner makes
the trailing run immediate, a background one waits out the gap); background → wait `gap` since the last start and
`quietFor` after a run that took `slowAfter` or longer; `becameActive()` runs once if owed.

Adopted by: `JobsStore.refresh` (background = `cron.changed` ticks and the backstop; foreground = pull to refresh and
the page appearing), `ActivityStore.staleCheck`, the Kanban board read, the Artifacts index read, the Settings status
reads and `PageDataWarm` (§6.10). `BotStore` and `SessionStore` keep their own machinery (they already meet the rule);
two new tests pin that they do. The builder lists every adopted read in the stream brief.

**Wire.** No new call.

**Screen states and words.** None.

**Owner.** No note. The web's round-2 finding is the source.

**Fixture and checks.**

1. Unit `ReadFlightTests`: port the web's cases (one at a time, shared trailing run, owed while inactive and one
   catch-up, gap, quiet after slow, a foreground call promoting a trailing background run).
2. Fixture: Jobs tab on screen, `POST /__fixture/delay {"rest":{"/api/cron/jobs":5}}`, then ten
   `POST /__fixture/broadcast {"type":"cron.changed"}` in two seconds: the ledger shows at most two `/api/cron/jobs`
   requests, never two overlapping (the ledger records start and end times).
3. Background: with the app in the background, ten broadcasts, zero requests; on return, exactly one.

**DECISION (review round): the rule holds on every page with a background read; three keep their own shape.** The
Kanban board's poll awaits each read before the next wait, runs only while the page is on show and the app is in
front, and reads once on return (unit `KanbanReadRulesTests.thePollReadsNothingWhileHiddenOrAwayAndOnceOnReturn`).
The Artifacts index has no background read (one pass when the page shows and the last is over a minute old, one at a
time, and a pull to refresh). Settings reads the gateway's version once per run and its config when the page shows.
Putting those behind a `ReadFlight` would change nothing they do, so they are not moved.

### 6.8 L959 — Focus return

**Web.** `W/src/focus-return.ts`: on the phone every native tab switch blurs the web view and focuses it again within
a millisecond; the renderer read a window focus as "back from another app" and refreshed five to seven requests per
switch. A focus that ends a blur shorter than 500 ms (`MOMENTARY_BLUR_MS`) is not a return.

**Native today.** There is no web view, so a tab switch fires no "return". But `sceneDidBecomeActive` fires after
every moment the app was merely inactive (Control Center, the notification shade, a system permission alert, the app
switcher peeked and dismissed), and `AppDelegate.swift:123-127` treats each as a return: `model.appDidBecomeActive()`
runs the roster's return rule, the activity store's re-read, the settings hub, the push registrar's flush.

**Design.** The blur itself is **web-shell-only** (a WKWebView focus artefact; native tab switches touch no window
focus). The behaviour behind the row, "a moment inside the app is not a return, so no refresh burst", has a native
form, built here:

* `ReturnGate` (pure): `resignedActive(at:)`, `enteredBackground()`, `becameActive(at:) -> Bool`. It answers `true`
  (a return) for the first activation after launch and for any activation after the app entered the background. For an
  activation that follows only a resign-active it answers `false`. **DECISION:** however long the app sat inactive
  without entering the background, it is not a return: the process ran throughout, its socket and timers with it, so
  nothing was missed. (The web's 500 ms test exists because a real return also fires another event there; UIKit gives
  the exact answer.)
* `SceneDelegate.sceneWillResignActive` and `sceneDidBecomeActive` feed it. On `false`, `model.appDidBecomeActive()` is
  not called; only `MainTabController.current?.noteLaunchScreen()` (cheap, local) still runs.
* A tab switch stays what it is: it tells the stores which list is visible; the roster's own "stale on return to the
  list after 30 s" rule is a list rule, not an app-return rule, and stays.

**Wire.** None.

**Screen states and words.** None.

**Owner.** No note. The web's stability round is the source.

**Fixture and checks.**

1. Fixture ledger cleared; switch tabs 20 times in 10 s (UI test): zero requests that belong to a return
   (`/api/status`, `delegation.status`, a roster re-read) beyond what one list-visibility change may ask.
2. Pull down Control Center and dismiss it five times (UI test through the system gesture, or
   `XCUIDevice.shared.press(.home)` is not used since that backgrounds): zero requests.
3. Background for 5 s and return: the return work runs once.
4. Unit `ReturnGateTests`.

**DECISION (review round): a moment still reconciles what the person did in it.** `sceneDidBecomeActive` always calls
`AppModel.appDidBecomeActive(returned:)`. With `returned == false` (Notification Center, Control Center, a permission
alert, Face ID) it runs the light half only: the badge is reconciled with the lists, saved answers and a failed push
registration are flushed and retried, and the open chat checks for questions answered elsewhere. The network refreshes
(socket wake, roster, Sessions list, chat warm-ups, activity, the offline hub) wait for a real return. Check: UI
`testO22` pulls Control Center down and closes it, sees the activation counted as a moment and not as a return
("debug.activations", DEBUG) and asserts no Sessions read, no roster read outside the roster's own 30 s poll and no
socket ticket. It then pulls Notification Center down and back. What the system does with the app under that sheet is
the system's choice: on the iOS 26 simulator the app was sent to the background in every run recorded (five); a
phone may leave it merely inactive. The first is a moment and is held to no read at all; the second is a background, so a return, and is held
to a return's budget (one look at the list at most, no new socket). `testO14` asserts the return itself: with the
socket up and change events flowing the Sessions list has missed nothing and reads nothing on a return, so the test
changes a chat while the app is away and asserts exactly one read when it comes back, and that the trip counted as
one return.

### 6.9 L960 — Visible polls stretched for power and floored on the phone

**Web.** `W/src/visible-poll.ts` (`PHONE_POLL_FLOOR_MS = 5000`: no visible poll runs faster than every 5 s on the
phone), `W/src/power-state.ts` (`SAVER_FACTOR = 3` in Low Power Mode or when the phone is hot; `powerInterval` re-arms
on a power change and runs at once when leaving saver finds the poll overdue).

**Native today.** `BotStore.pollInterval()` multiplies by 3 (`BotStore.swift:720`) and `GatewaySwitcherModel` checks
the same two flags (`:63-64`). Other polls do neither, and none re-arms when the power state changes.

**Design.** `PowerPolls` in `HermesKit/Net/`:

* `PowerState.saving`: `ProcessInfo.isLowPowerModeEnabled || thermalState >= .serious`, observed through
  `NSProcessInfoPowerStateDidChange` and `ProcessInfo.thermalStateDidChangeNotification` with block observers that hop
  to the main actor (both are posted off the main thread; `App/Heads/HeadView.swift:372` shows the safe pattern).
* `PowerPolls.period(_ base: Duration, floor: Duration = .seconds(5), cap: Duration? = nil) -> Duration` =
  `max(floor, base) × (saving ? 3 : 1)`, capped.
* `PowerPolls.loop(every base:, floor:, _ work:) -> Task` : sleeps one period, runs, repeats; on a power change it
  re-arms with the new period and, when leaving saver finds the last run older than the normal period, runs at once.
* Adopted by every poll that runs because something is merely on screen: the roster poll (replacing its own ×3), the
  gateway switcher's, the sessions fallback polls, the Jobs backstop, the activity store's stale poll and list loop,
  the Capabilities status poll (10 s), the Kanban poll, and any presence or viewer status poll the builder's grep
  finds. Exempt: a poll that follows an action the user just started (skill install progress at 1.2 s, a job trigger)
  and anything driven by events rather than time. **DECISION:** the floor applies to on-screen status polls only, as
  the web's `visiblePollInterval` does. The builder lists each poll, its base, and whether it is floored, in the brief.

**Wire.** None.

**Screen states and words.** None.

**Owner.** No note. The web's rule is the reference.

**Fixture and checks.**

1. Unit `PowerPollsTests` with an injected power state and clock: period maths, floor, cap, re-arm on change, run at
   once when overdue on leaving saver, no double run.
2. Simulator: Low Power Mode cannot be toggled by `simctl`; use the DEBUG override `-HQDebugPowerSaving YES|NO`
   (read by `PowerState`), Jobs tab on screen with the fixture's `--no-change-events` (so the 30 s backstop poll is
   live): the ledger shows `/api/cron/jobs` every 30 s, then every 90 s with the override on.
3. Grep check in CI style (a unit test over the source tree is not wanted; the brief's list is the record).

### 6.10 L965 — Caches on first frame

**Web.** Four parts.

* Jobs list kept: `W/src/jobs-list-cache.ts` (the last list per connection and profile, at most 300,000 characters,
  saved 1 s after a read, put back before the page first opens).
* Capabilities data warmed: `W/src/page-data-warm.ts` (600 ms after the bot list has drawn, or after 8 s, and not
  while a navigation is moving: skills, toolsets and the profiles list for the active profile, kept 30 min).
* Page code warmed: the same module preloads the pages' JavaScript chunks.
* Missing chat tails prefetched: `W/src/open-warm.ts` (first pass 800 ms after the lists draw, a fill 1.5 s later,
  passes at least 30 s apart, three at a time, none while hidden; priority: the last open chat, pinned bots, bots,
  the first 15 session rows, hidden bots; a finger resting on a row warms it at once).

**Native today.** Jobs: `JobsStore` paints from `PagesCache` per scope on its first frame (already kept). Tails:
`ChatWarmer` reads bots' tails newest first, one at a time, with the finger-down prefetch. Capabilities: nothing ahead
of the first open. Page code: nothing to warm.

**Design.**

* **Jobs kept.** Verify with a test that a cold launch with a saved list shows rows on the Jobs tab's first frame with
  the gateway down, and that a list over 300,000 characters of JSON is not written (add the cap to the write in
  `JobsStore.refresh`; a too-large list is simply read fresh).
* **Capabilities warmed.** `PageDataWarm` (HermesKit, MainActor): 600 ms after the roster first has rows (8 s after
  activation at the latest), not while a navigation transition runs (`transitionCoordinator != nil` on the selected
  navigation controller: retry in 250 ms), and only when the connection is ready and the app active: read
  `GET /api/skills?profile=<active>` through `CapabilitiesStore.skills`, then the toolsets list and the MCP servers
  list if the Capabilities page reads them at open (the capabilities stream is changing that page: the warm calls
  whatever `CapabilitiesModel.load()` calls first, through the same store functions, so the two cannot drift). Answers
  are kept 30 min in a small `CapabilitiesWarmCache` keyed by account and profile, which `CapabilitiesModel` seeds its
  own caches from when the page opens, then refreshes behind them as it does today. One at a time, through a
  `ReadFlight`.
* **Page code warmed: proposed web-shell-only part.** The web warms lazily loaded JavaScript chunks so a page's first
  open does not wait on a download and parse. A native binary has every screen's code loaded with the app; there is
  nothing to fetch. (`ChatViewController.prewarm()` already covers the one costly first-use native has.)
* **Tails.** `ChatWarmer.staleBots` gains the web's order: the chat the next launch would reopen
  (`LaunchChatMemory`), then pinned bots, then the other bots by newest activity, then the first 15 rows of the
  Sessions list (`SessionStore.sessions.prefix(15)`, read by stored id and owner profile), then hidden bots.
  **DECISION:** native keeps one read at a time and its pass sizes (8 on the first pass, 4 after, passes 30 s apart)
  instead of the web's three at a time: the gateway's worker pool is small (`W/src/rpc-flight.ts:2-6`) and a chat the
  user opens must never queue behind warm reads. The finger-down prefetch stays as it is.

**Wire.** `GET /api/cron/jobs?profile=<scope>`; `GET /api/skills?profile=<p>` (answer: an array of
`{"name","description","category","enabled","usage","provenance"}`); the tail read of §6.3 with `limit=24`.

**Screen states and words.** None.

**Owner.** `MEM/connection-speed-assessment.md:13` lists the cached start among what the owner's builds already had:
"cached boot (roster cache + last-chat tail paint while /api/auth/me runs…)". Native must not lose any of it.

**Fixture and checks.**

1. Jobs: open Jobs once, quit, `mode refuse`, relaunch on the Jobs tab: rows in the first frame, header "Offline".
2. Capabilities: launch, wait 2 s without touching anything: the ledger shows one `/api/skills` read. Open
   Capabilities: rows in the first frame (video frame check), one refresh behind them.
3. Tails: fresh sign-in on the fixture (5 bots, 20 listed sessions, one pinned bot, a remembered last chat): the
   ledger's `/messages` reads come in the order last chat, pinned bot, bots, sessions; never two at once; none while
   the app is in the background.
4. Unit: the order function; the Jobs size cap; `PageDataWarm` waiting for the roster, the 8 s fallback and the
   transition check.

---

## 7. Stand-in gateway: `scripts/fixtures/offline-gateway.py`

None of the existing fixtures can refuse connections, stall REST with the socket open, restart its replay epoch, end
a turn unseen, or send an oversize frame, so this stream writes one. Standard library only, loopback only, invented
data, no network client; it loads the reference action-voice fixture for sign-in, the ticket and the socket base, as
`scripts/fixtures/sessions-gateway.py` does (`HQN_REF` defaults to `/Users/me/Projects/hermes-hq-native-ref238`).

It has **two listeners**: the gateway port and a control port. The control port always answers, so a test can bring a
"refusing" gateway back.

Start commands (builder ports 9980–9984):

```
# A: the main stand-in
python3 scripts/fixtures/offline-gateway.py --port 9980 --control-port 9981 --credentials build/fixtures/offline.json
# A with Hermes' renewing cookie session (needed for /__fixture/revoke, §5.2)
python3 scripts/fixtures/offline-gateway.py --port 9980 --control-port 9981 --credentials build/fixtures/offline.json --hermes-cookies
# B: a second gateway for "Change Address or Sign In" (§3.7)
python3 scripts/fixtures/offline-gateway.py --port 9982 --control-port 9983 --credentials build/fixtures/offline-b.json --label B
```

Stress tester ports 9985–9989: A on `--port 9985 --control-port 9986`, B on `--port 9987 --control-port 9988`, 9989
spare. The script refuses any port outside 9980–9989 unless `HQN_ANY_PORT=1`, refuses a busy port, writes the
credentials file with mode 0600 and never prints it.

Flags: `--start-down` (the gateway port does not listen until told `up`), `--delay-ticket S`, `--roster-delay S`,
`--no-change-events` (`gateway.ready` says `change_events: false`), `--changed-on-ready` (broadcasts `sessions.changed`
right after each `gateway.ready`), `--label NAME`, `--hermes-cookies`, `--keep-credentials`.

Serves (all behind the session, as Hermes does):

* Sign-in and socket: inherited (`/api/status`, `/api/auth/providers`, `/auth/password-login`, `/api/auth/me`,
  `/api/auth/ws-ticket`, `/api/ws`), `gateway.ready` with `replay_epoch`.
* RPC: `profiles.list` (5 bots, one pinned; honours `include_sessions: false`), `session.list`, `session.resume`,
  `session.activate` (4007 for a runtime id from an older epoch), `session.events.since` (a replay ring by `seq`; a
  different `epoch` after a restart), `session.active_list`, `prompt.submit` (a scripted streamed reply with `seq`),
  `session.interrupt`, `delegation.status`, `agents.list`, `subagent.list`, `ping`. Unknown params on these methods
  answer error 4000; unknown methods answer -32601.
* REST: `GET /api/profiles/sessions/sidebar` (honours the three limits; 20 sessions), `GET /api/sessions/{id}/messages`
  (limit, offset, order), `GET /api/cron/jobs`, `GET /api/skills`, `GET /api/config`, `PATCH /api/sessions/{id}`.

Controls (control port; also on the gateway port while it is up; no auth, loopback):

| Call | Effect |
|---|---|
| `GET /__fixture/state` | `{"rest":[{method,path,query,start,end}],"rpc":[{method,params,start,end}],"dials":[t…],"tickets":n,"sockets":n,"probes":n,"full":n}` |
| `POST /__fixture/mode {"mode":"up"}` | normal service |
| `… {"mode":"refuse"}` | the gateway listener is closed (connection refused); open sockets are dropped |
| `… {"mode":"blackhole","scope":"all"\|"ws"\|"rest"}` | accepts and never answers (timeouts) |
| `… {"mode":"status","status":502\|503\|429\|400,"retry_after":N,"body":"raw text"}` | every gateway request answers that status (with `body` as plain text when given: 400 `Invalid Host header` is Hermes turning the address away) |
| `… {"mode":"not-hermes"}` | `/api/status` answers 200 with an HTML page |
| `… {"mode":"outdated"}` | `/api/status` reports a Hermes too old for the app |
| `POST /__fixture/stall {"rest":S\|null}` | REST answers wait S seconds; sockets unaffected |
| `POST /__fixture/delay {"rpc":{"<method>":S},"rest":{"<path>":S}}` | per-call delays |
| `POST /__fixture/fail {"rpc":"<method>","code":N,"count":N}` or `{"method","path","status","count"}` | the next matches fail |
| `POST /__fixture/drop {}` | every socket is closed now; the epoch stays (replay possible) |
| `POST /__fixture/restart {}` | sockets closed, a new `replay_epoch`, runtime ids re-minted, replay ring emptied |
| `POST /__fixture/revoke` | every session is refused from now on (401), inherited |
| `POST /__fixture/oversize {"bytes":N}` | one WebSocket text frame of N bytes to every socket |
| `POST /__fixture/turn {"session_id","chars","drop_at","save_after"}` | the next prompt in that chat streams `drop_at` characters, then the fixture restarts its epoch, finishes the turn unseen (the snapshot's `inflight` holds the partial, `running: false`) and saves the full reply `save_after` seconds later |
| `POST /__fixture/work {"session_id","subagents":[…],"processes":[…]}` | starts running work with its events |
| `POST /__fixture/work/end {"subagents":[…],"processes":[…]}` | ends it silently (no event), so only the process-wide lists know |
| `POST /__fixture/touch {"session_id"}` | moves a session's `last_active` (the sidebar fingerprint changes) |
| `POST /__fixture/broadcast {"type":"cron.changed"\|"sessions.changed"}` | to every socket |
| `POST /__fixture/reset` | forget ledgers, failures and modes; re-seed |

Rules for whoever runs it: start it yourself on your own ports, stop it when the stage ends (the e2e script traps and
kills only the pid it started), never point the app at anything else.

---

## 8. Tests and how to run them

Simulator for builders: `xcrun simctl create "HQN-m9-offline" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`
(reuse it if it exists); stress tester: `"HQN-m9-offline-s"`. Always pass the UDID. Never the default simulator.

* Unit (run with `scripts/build.sh test <udid>`), all under `Tests/Offline/`: `OfflineCopyTests`, `RetryLadderTests`,
  `LaunchGateTests`, `ReconnectBannerTests`, `StartupProblemsTests`, `AccountStorageTests`, `OutageGateTests`,
  `QueryRetryTests`, `TailRecheckTests`, `ReconnectShareTests`, `StaleWorkTests`, `ReadFlightTests`, `PowerPollsTests`,
  `ReturnGateTests`, `RosterStateCopyTests`, `WarmOrderTests`. Where the web has a test file beside the module
  (`W/src/<module>.test.ts`), port its cases first.
* End to end: `scripts/e2e-offline.sh <udid>` (modelled on `scripts/e2e-restore.sh`): starts fixture A on
  `${HQN_OFFLINE_PORT:-9980}` with its control port one above, B two above; refuses ports outside 9980–9989; passes
  `TEST_RUNNER_HQN_UI_CREDENTIALS`, `TEST_RUNNER_HQN_UI_OFFLINE=1` and `TEST_RUNNER_HQN_OFFLINE_CONTROL`
  (`http://127.0.0.1:9981`) to `UITests/offline/OfflineEndToEndTests.swift`; `HQN_OFFLINE_ONLY="testO1_…"` narrows it;
  stops what it started. The tests drive the controls of §7 over the control port.
* New DEBUG launch arguments (`App/Debug/DebugHooks.swift`, compiled out of release): `-HQDebugResetCaches YES`
  (forget local caches, keep saved sign-ins), `-HQDebugRestoreFailure <keychain code>`, `-HQDebugOfflineReason <code>`,
  `-HQDebugStorageFailure YES`, `-HQDebugPowerSaving YES|NO`, `-HQDebugProcessClaim <stored id>:<process id>`.
* UI tests can be flaky on the shared Mac: rerun before calling a failure; never loosen an assertion to pass.

A row is done only when its checks above were seen passing on the builder's simulator and the result is written in
`docs/briefs/m9/offline-rows.md`.

---

## 9. STRESS PLAN

For the stress tester, on simulator `HQN-m9-offline-s` and ports 9985–9989 (A on 9985/9986, B on 9987/9988). Each item
names what to do, what must hold, and how to measure it. Record numbers, not impressions.

**Load**

1. Big lists: seed the fixture with 60 bots and 500 sessions (`POST /__fixture/reset {"bots":60,"sessions":500}`).
   Launch cached and uncached. The launch gate must leave within 150 ms of the roster landing; the stale card, slow
   card and banner must not cost scroll frames (hitch rate while scrolling Bots with the stale card showing: no worse
   than without it, measured with `xctrace` or the app's own frame log).
2. Reconnect storm: `POST /__fixture/drop {}` 50 times, 400 ms apart, with a chat open, Sessions and Jobs visited.
   Must hold: no banner at any point (each blip is under 4 s), at most one sidebar probe per 3 s, one
   `session.activate` per socket that reached ready, zero `/messages` reads while replay covers, memory flat (±5 MB
   over the run), no task leak (the debug task count returns to its start).
3. Twenty chats with running-work claims: one `delegation.status` and one `agents.list` per check, not twenty.
4. Ten `cron.changed` per second for a minute with a 5 s Jobs read: never two reads at once, at most 13 reads.

**Speed**

5. Cached cold launch, 10 runs: time from process start to the first frame with bot rows. It must not be slower than
   the train's build before this stream by more than one frame (16.7 ms) at the median. Record both.
6. Uncached launch against a fast fixture: icon → app in under 1 s, no spinner seen (it appears at 0.9 s), no
   skeleton frame.
7. Offline to connected: with the offline screen up and the gateway brought back, Try Again → app in under 1.5 s.
8. Return after 60 s in the background: no banner, header quiet, lists refreshed with one probe.

**Bad network**

9. Refusing gateway for 10 minutes with every tab visited: REST connection attempts follow the gate (2, 4, 8, 16, 30,
   30… s), dials follow the ladder before first ready and the existing back-off after; CPU near idle; the countdown
   never shows 0 or a negative number and never disagrees with the ledger by more than 1 s.
10. Black hole (timeouts) with the socket down, then with the socket up and REST stalled: outage and stall sentences
    are the right ones; a chat opened during the stall still opens once the stall ends, without a relaunch.
11. Flapping: `refuse` 2 s, `up` 2 s, for 3 minutes: no banner flicker (it may show and clear, never more than once
    per outage longer than 4 s), no duplicate alerts, the ladder position resets only on a ready.
12. 429 with `Retry-After: 300`: the wait is capped at 120 s and the screen says so honestly.
13. 502/503 from a proxy with the gateway down: treated as down (gate holds, the busy or unreachable words show, no
    retry storms).
14. Network path lost and restored (unit-level scripted `PathWatcher`, plus on a real device if one is available to
    the tester; the simulator cannot drop loopback): the network sentence shows at once and clears at once.

**Bad data**

15. Sidebar probe answers: `{}`; `{"recents":null}`; truncated JSON; a 200 with HTML. Each leads to a full read or a
    quiet failure, never a crash and never a skipped refresh.
16. `delegation.status` and `agents.list` answers with missing keys, wrong types, 10,000 rows, or -32601: no crash, no
    claim dropped on a malformed answer, -32601 remembered.
17. Tail reads returning rows in a wrong order, an empty list, a different prompt, or a shorter reply: the partial is
    never replaced by something shorter or by another turn's reply.
18. `gateway.ready` without `replay_epoch`; `session.events.since` with `truncated: true`; an `inflight` with an empty
    assistant: one tail read, no loop.
19. Oversize frames: one at 64 MiB + 1 KiB, then three in a row: one alert per streak, reconnects back off to the cap
    after the second, the app stays usable.
20. A gateway label of 200 characters, an emoji-only label, a right-to-left label, an IPv6 address with a port: the
    offline card wraps and never clips or shows raw percent-encoding.
21. `Retry-After` as a date, a negative number, or text: ignored, the ladder is used.

**Interruption**

22. Background the app at each of: launch screen at 3 s, offline countdown at 2 s left, mid Try Again, sign-in sheet
    over the offline screen, the "Sign in again" alert up, the "Message too large" alert up, mid tail recheck. On
    return every one is in a sane state: countdown recomputed from the clock, no stuck spinner, alerts still there
    once, no dial while in the background beyond the 20 s grace.
23. A phone call banner, Control Center and the notification shade over each screen: no refresh burst (§6.8), no
    restart of the launch timers.
24. Rotate is locked to portrait; verify a split-second size change (keyboard up on the sign-in sheet over the offline
    screen) does not reset the countdown.
25. Session revoked while a send is in flight, while a voice memo uploads, while a file uploads: the alert shows once,
    drafts and the unsent items are there after signing in again.
26. Low Power Mode toggled (DEBUG override) mid-poll: polls re-arm, none doubles, the overdue one runs at once when
    saver ends.

**Relaunch**

27. Kill the app (`xcrun simctl terminate`) at each state of item 22 and relaunch: launch → the right screen again,
    the ladder starts over at 3 s, no stale countdown, no alert from the last run.
28. Kill during the storage check and during a cache write: the next launch starts; a half-written cache is ignored.
29. Relaunch 30 times in a row against a refusing gateway with caches present: every launch shows cached rows on the
    first frame; no launch shows the offline screen; dials per launch follow the ladder (no burst).
30. Relaunch after the gateway restarted with a new epoch while the app was dead: one cold resume of the reopened
    chat, one tail read.
31. Update path: caches wiped but the Keychain kept (`-HQDebugResetCaches YES`) and the gateway down: the offline
    screen, then the app when the gateway returns.

**Accessibility sizes**

32. Every screen and card of this stream at the largest accessibility text size (`xcrun simctl ui <udid>
    content_size accessibility-extra-extra-extra-large`) and at the smallest, light and dark: launch (all states),
    offline (every reason, with and without each button), slow card, stale card, "Can’t Load Bots", banner (each
    sentence), both alerts. Nothing clips, overlaps or truncates; the offline body scrolls and Try Again is reachable;
    the banner stays under the status bar and clear of the Dynamic Island; wrapping rows keep 12–14 pt padding.
33. VoiceOver pass: one announcement per countdown, the launch caption once, each banner sentence once, focus moves to
    the status line on Try Again, every button has a name, the skeleton reads "Loading bots", no element is named by a
    raw code.
34. Reduce Motion: the launch fade is 100 ms, the banner fades without sliding, no spinner is the only signal of
    anything (each has words).
35. Bold Text, Increase Contrast and Reduce Transparency on: glass falls back as the system decides; text stays
    readable on the banner and the offline buttons.
36. Word check: grep every screenshot's text and `OfflineCopy` for "Dispatch": zero hits.

---

## 10. Owner to-do and web-shell-only summary

**Owner to-do: none.** No row here needs the push relay, a plugin, or the owner's gateway changed. If an older Hermes
lacks `agents.list` or the batched sidebar route, the app already degrades: -32601 is remembered and the check is
skipped; a 404 on the sidebar falls back to the three per-slice reads (`SessionStore.fetchSidebar`).

**Proposed web-shell-only (parts of rows, each with its reason):**

| Row | Part | Why it exists only in the web shell |
|---|---|---|
| L109 | "pre-paint background colour saved from the last run" | The web shell paints its own HTML before its renderer boots. In native the pre-launch pixels are the system launch screen, a static asset iOS reads from the bundle; there is no public way to change it at run time. Native gets the same result when the saved mode is System (the asset's light and dark values equal the page colour). |
| L959 | the sub-millisecond blur and focus on a tab switch | It is a WKWebView focus artefact. Native tab switches change no window focus. The behaviour behind it (a moment inside the app is not a return) is built natively in §6.8. |
| L965 | "page code warmed" | The web preloads lazily loaded JavaScript chunks. A native binary has all its code loaded at launch. |

The rest of each of those rows is built.

---

## 11. Build order

`MEM/feedback-one-feature-at-a-time.md:8`, the owner on 2026-10-11: "I also want to do one feature at a time now". So
this stream lands in small steps, each one built, seen working against the fixture, and committed before the next:

1. The fixture (`offline-gateway.py`), `scripts/e2e-offline.sh`, the DEBUG arguments, `OfflineCopy` with its tests.
2. Quiet plumbing with unit tests only, no UI: `OutageGate` (§6.1), `QueryRetry` (§6.2), `ReadFlight` (§6.7),
   `PowerPolls` (§6.9), `ReturnGate` (§6.8).
3. Bots list states: "Can’t Load Bots" and the raw-code fix (§4.3), the stale card (§4.2), the slow card (§4.1).
4. Launch: the gate and the rebuilt launch screen (§3.1, §3.2), then appearance checks (§3.3), then startup problems
   (§3.4).
5. Offline: the screen (§3.5), the countdown (§3.6), retry and the different-gateway sheet (§3.7).
6. Notices: the banner (§5.1), "Sign in again" (§5.2), "Message too large" (§5.3).
7. Chat and lists after a reconnect: the 3 s share (§6.4), the backstop stand-down (§6.5), the tail recheck (§6.3),
   the stale work check's second half (§6.6).
8. Warm-ups (§6.10).

Steps 2 and 3 do not depend on 4–6. Step 4 changes `SceneDelegate` the most and should land before 5.

---

## 12. Risks and open points

1. **System launch icon alignment.** Adding the icon to `UILaunchScreen` only works if the in-app icon sits on the
   same pixels. If it cannot be made exact on every size, fall back to a 1-frame cross-fade and say so in the brief.
2. **Pre-ready back-off change.** Replacing the jittered 2–15 s back-off with the 3/6/12/24/30 ladder changes when a
   first connection retries everywhere, not only on the offline screen. The net unit tests that pin the old numbers
   need updating, not loosening.
3. **`SceneDelegate` is shared ground.** The onboarding stream (welcome and sign-in extras) and the ipad stream also
   touch the launch path. `LaunchCoordinator` should stay a thin, separate file to keep merges small.
4. **Sidebar probe ownership.** The sessions stream may reshape `SessionStore.performRead`. This stream must rebase
   the 3 s share onto whatever is on the train and never add a second probe.
5. **`agents.list` needs a claim source** (composer L461). Without it the row stays partial; see §6.6.
6. **"Not Now" on the sign-in alert** keeps the app alive while signed out, a state native never held before. Every
   store must fail fast and quietly in it; the stress items 22 and 25 cover it.
7. **Outage gate and the first chat open.** A held first read must not show an error the reconnect would have fixed
   (the owner's "toast over a chat that then loaded fine" report). The chat's quiet retry on reconnect must be kept and
   tested with the gate on.
8. **Loopback limits.** The simulator cannot produce `tls`, `tailscale-off` or a lost network path against a local
   fixture. Those three are covered by unit tests and DEBUG state injection, and should get one pass on a real phone
   before the rows are called done if a device run is available to the ship stage.
9. **Capabilities page is being rebuilt by another stream.** The warm-up must call that page's own first reads; if the
   page changes after this lands, the warm list needs a matching change.
10. **Oversize-frame test cost.** A 64 MiB frame on a shared Mac is slow; run that one test alone, not in the loop.

## 13. Stress round 1 repairs (2026-10-13)

Changes made after stress round 1 failed, each with its reason. Where they differ from the sections above, this
section wins.

1. **§3.1 Launch screen at large text sizes.** The icon, the spinner, the caption and the buttons now sit in one
   scroll view the size of the window. The icon is half a window down the content, so at rest it is exactly where the
   system launch screen drew it; when the words and buttons fit, nothing scrolls. When they do not fit (accessibility
   text sizes, the storage sentence), the whole screen scrolls from a touch anywhere on it, the icon moving away with
   the rest, and the scroll bar shows for a moment when the buttons appear. Before, only the strip under the icon
   scrolled, and only from a touch that began in that strip. Check: UI `testO24`.
2. **§5.2 / §5.3 Held notices never give up.** A notice that cannot show (another alert on top, a sheet mid-flight,
   the app not active) is looked at again every 0.7 s for 14 s, then every 2 s, for as long as it is owed and the app
   is on screen. Answering either of the stream's alerts looks at once. Before, the look stopped after 14 s and a
   session that ended under an alert left up longer was never said. Check: UI `testO25`.
3. **§3.6 / §3.7 DECISION: only Try Again is off during an attempt.** The web turns both buttons off while it
   connects; its attempts are short. A native dial into a host that never answers runs to its 15 s timeout, and
   "Change Address or Sign In" (and "Sign In Again") must not be out of reach that long. They stay on; Try Again
   alone is off while "Connecting…" shows. Check: UI `testO26`.
4. **§3.2 A failed list from before the reconnect is not content.** A roster load that failed while the gateway was
   away counts as "still loading" once the connection is ready, until the read that follows the reconnect has
   answered (`BotStore.failurePredatesOpen`); the launch screen covers it for at most the content allowance (5 s).
   Before, the app was shown on "Can’t Load Bots — waiting for your gateway to reconnect" for a moment when the
   gateway came back under the sign-in sheet. Check: unit `aFailureFromBeforeTheSocketOpenedIsOutOfDate`.
5. **§4.3 DECISION: the gateway's own error message is shown only when it is a sentence.** The web shows the RPC
   message as it came. Hermes writes those for logs ("session not found", an exception's text). Native shows it only
   when it passes `plain` and starts with a capital and ends with a closing mark; otherwise "Your gateway couldn’t
   load your bots." Check: unit `wordsForErrors`.
6. **§5.1 The reconnect notice is never cut.** No line limit, and its type stops growing at the first accessibility
   size (as the system's bars do), so at the largest text size it is a few lines and whole, not 259 pt and cut. It
   still sits in the bar's slot for its 6 s and takes no touches (review DECISION 6, unchanged). Check: unit
   `theNoticeIsNeverCutAndStopsGrowing`.
7. **§3.6 DECISION: `Retry-After` is capped at 120 s after the first ready too** (`RetryLater.ceiling`, was 300 s):
   the app no longer sits on "Reconnecting…" for minutes after the gateway is back.
