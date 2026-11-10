# 3x — Diagnostics, performance logs and shell services (m9 stream `diagnostics`)

Branch `m9/diagnostics`, worktree `/Users/me/Projects/hermes-hq-native-wt/m9-diagnostics`.
Ports: builders 10070–10074, stress tester 10075–10079. Simulators: `HQN-m9-diagnostics` (builders),
`HQN-m9-diagnostics-s` (stress), both `iPhone 17 Pro`, runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.

Paths: `S/` = `/Users/me/Projects/hermes-hq-native-ref240/src/`, `I/` = `…-ref240/ios/App/App/`,
`V/` = `…-ref240/vendor/hermes/apps/desktop/src/`, `B/` = `…-ref240/build/`, `P/` = `…-ref240/gateway-plugin/hermes-hq-push/`,
`H/` = `/Users/me/.hermes/hermes-agent/` (read only), `MEM/` = the owner's memory folder.

The 20 rows this stream owns are in `docs/briefs/m9/diagnostics-rows.md`. Row ids below are the parity doc's line
numbers at `bd08c2c` (L901 …).

**Revision 2** (after merging `m9/train` at `bd25418` into this branch, merge commit `fda2bce`). Fourteen other streams
have landed on the train since revision 1; none of them touched `HermesKit/Diagnostics/`, `DiagnosticsView.swift` or
`AboutView.swift`, but four of them built pieces revision 1 planned to build here. §0a lists what changed and ranks
the stream's features by how close they are to done. Every section below is already corrected for it; where a section
says "(rev 2)" the design differs from revision 1.

---

## 0a. Revision 2: what the merged tree changed, and what is closest

### What other streams already built (reuse, never rebuild)

| Piece | Who | Where (merged tree) | Effect on this spec |
|---|---|---|---|
| The power service: `PowerState.shared` (`saving`, `override`, `PowerState.changed`), `PowerPolls.period / loop / wait`, DEBUG `-HQDebugPowerSaving YES\|NO` | offline | `HermesKit/Net/PowerPolls.swift`, `App/Offline/OfflineDebug.swift:13,39` | §11 no longer adds a service. Revision 1's `HermesKit/System/PowerState.swift` and `PowerTimer` are **dropped**. |
| Fourteen polls already ×3 in saver (roster, sessions, gateway switcher, capabilities ×2, Kanban ×3, Jobs ×2, activity ×3, browser viewer) | offline | `BotStore.swift:776-786`, `SessionStore.swift:757`, `GatewaySwitcherModel.swift:63`, `CapabilitiesModel.swift:415`, `ServerIssueSweep.swift:29`, `KanbanStore.swift:141`, `KanbanTaskSheet.swift:50,69`, `JobsStore.swift:160`, `JobDetailViewController.swift:156`, `ActivityStore.swift:456,519,571`, `BrowserViewerController.swift:411` | the "optional polls ×3" half of L974 is implemented and unit-tested (`PowerPolls` tests); it still has to be *seen* for this row (§15 P3). |
| Heads follow heat, decorative loops stop in saver (`HQMotion.decorativeStill`), three more timers, `hqn.power.toggle`, the `debug.power` probe | settings (branch `m9/settings`, commits `b3b1043`, `88e1112`; **not on the train yet**) | `docs/spec/3x-settings.md` §3 on that branch | the "decorative loops stop" half of L974 / L1015 arrives with that merge. §11 says exactly what this stream does in each order of arrival. |
| The reconnect probe's counters | sessions | `SidebarProbeStats {probes, skipped, full}` (`HermesKit/Contracts+sessions.swift:95`), `SessionStore.probeStats` (`SessionStore.swift:173`) | §2.2's "Session list on reconnect" row reads them; nothing to add in `SessionStore`. |
| Hardware Return sends, Shift / Option Return break the line, an IME composition is left alone | ipad | `ComposerTextView.pressesBegan` (`App/Chat/Attachments/ComposerTextView.swift:25`), `ReturnKey.decide` (`App/Root/KeyCommands.swift`), unit tests `Tests/IPad/PaneRulesTests.swift` | §13.3: nothing to build; one UI check left (D-13.3 resolved: theirs is kept). |
| One announcement helper, one font factory | a11y | `HQAnnounce` (`App/Kit/Accessibility/HQAnnounce.swift`), `Font.hq(…)` / `HQFont` | "Copied" is announced with `HQAnnounce`; every new text uses `Font.hq`, never a raw `.font(.footnote)` (the a11y scan fails the build otherwise). |
| "iPhone" / "iPad" in wording | ipad | `DeviceWord.name` | any new sentence that names the device uses it (§8.6's sentences name the gateway, not the phone: unchanged). |
| The launch and offline screens own "when is the app worth showing" | offline | `App/Offline/LaunchCoordinator.swift` (`stage = .app` `:197`, `.signIn` `:213`) | §2.3's `launch.ready` mark and §10's `Launch` interval end there, not in a view controller's `viewDidAppear`. |
| The scene delegate lives in `App/AppDelegate.swift` | — | `restore()` `:204-211` | revision 1's `SceneDelegate.swift` references are corrected. |
| A photo-face memory observer; a DEBUG memory warning | photoheads; talk | `App/Heads/BotFaces.swift:45`; `-HQDebugMemoryWarningAfter <s>` (`App/Debug/TalkDebugHooks.swift:73`) | §12 registers the first with `MemoryTrim` and reuses the second instead of a new Darwin notification. |
| Two more number fields; the Done bar moved onto the field | capabilities; talk | `App/Capabilities/PluginsSections.swift:464` (no Done), `ConfigPages.swift:269` | §13.2's table is redone. |
| Two more hard-coded signpost subsystems | talk, intents | `HermesKit/Voice/TalkCapture.swift:379`, `App/Intents/AppModel+Intents.swift:112` | §10 moves `memo` and `talk` to `Signposts.subsystem`. |

Still exactly as revision 1 found them (checked again on the merged tree): `MetricsReceiver.didReceive(_: [MXMetricPayload])`
is empty (`DiagnosticLog.swift:229`); `TranscriptCache.trimMemory()` (`:431`) has no caller; no redactor beyond the
4-rule one; no ring; no update cards; `UIBackgroundModes = [remote-notification]` (`App/Info.plist:32`; the talk stream
added no `audio` mode).

### What features are closest (least work left first)

"Closest" = how little is left before the row can be *seen working*, counting what is already on the merged tree.

| Rank | Feature (rows) | Already there | Left | Size |
|---|---|---|---|---|
| 1 | **Background modes** (L1025) | the plist entry, the settle push, five named background tasks | the plist unit test in both identities, the audit of the five tasks, the log upload's own task (arrives with rank 9) | under an hour for the test and audit |
| 2 | **Keyboard state reporting** (L1006) | hardware Return / Shift-Return / IME rule and its unit tests (ipad) | one UI test on the simulator (N2); record the bridge report as web-shell-only | under an hour |
| 3 | **Image thumbnails, fetchImage** (L1004) | every user-facing half is ✅ in the parity doc | nothing to build; record web-shell-only, the stress tester confirms B1 | none |
| 4 | **Power saver** (L974, L1015) | the service, 14 polls, DEBUG switch (offline); heads, loops, timers, live toggle (settings, on its branch) | the `power` log event, the web's `didBecomeActive` re-read, the leftover-timer audit, the seen-working proof | a few hours once settings is on the train; half a day if it is not |
| 5 | **Number pad Done** (L1005) | three of seven fields have the bar | one shared helper, four fields, one UI test | a few hours |
| 6 | **Copy Diagnostics + folded errors** (L903, L902) | the button, the fold, `errorMeta`, a UI test (`testG9`) | the 2 s "Copied" receipt, the web's text shape, kept across launches (`errors.json`), "Before the last launch" | half a day (needs rank 7's redactor first) |
| 7 | **Redaction** (L904) | a 4-rule redactor | the 11-rule port + every web vector | half a day, pure code |
| 8 | **Memory trim** (L975) | `trimMemory()` written but uncalled; text-layout, media and photo-face observers; a DEBUG warning hook | one registry, the 4 chats / 4 MB background rule, wiring | half a day |
| 9 | **Performance log** (L908, L991, L992) | uploader to the right route with back-off, device label, switch, Mark a Janky Moment, crash and MetricKit diagnostic events | the 2 MB / 3 day ring and cursor, the policy port, the moment bundle, the real-sink round trip | a day and a half |
| 10 | **The full Diagnostics page** (L901) | page shell, build rows, startup, reconnect list, probe counters | socket stats, returns to the app, startup timings by name, Stability, section order and wording | a day |
| 11 | **Signposts** (L912, L990 second half) | three ad-hoc signposters | the four categories, the launch / restore / socket intervals, the captured proof | half a day |
| 12 | **MetricKit field history** (L906, L990 first half) | the subscriber, diagnostic payloads kept | the daily summary, 7-day store, crash log text, the page sections; device-only gap stays | a day |
| 13 | **Screen-problem reports** (L907) | nothing | the reporter and about nine call sites | half a day |
| 14 | **Perf-log sources** (L909) | nothing of the five named sources | watchdog, scroll judge, prompts, motions, socket states | two days |
| 15 | **Update status cards** (L980) | the action-status reader (`CapabilitiesStore.swift:94`) | everything else: model, two cards, alert, sheet, What's New, restart handling | two to three days; the only part that can change the owner's computer, so it ships last |

§19's build order follows this ranking (with rank 7 before rank 6 because Copy needs the redactor).

---

## 0. What is already there (read before building)

| Piece | File | State |
|---|---|---|
| App log, crash capture (exception, signal, MetricKit diagnostic payloads kept as JSON) | `HermesKit/Diagnostics/DiagnosticLog.swift` | works; `MetricsReceiver.didReceive(_: [MXMetricPayload])` is **empty** |
| Recent errors, startup marks, reconnects (this run only, in memory) and a 4-rule redactor | `HermesKit/Diagnostics/DiagnosticsTimeline.swift` | partial; nothing survives a relaunch |
| Upload to the owner's computer (`outbox.jsonl` ≤ 4 MB, 30 s → 30 min back-off, 404 → 6 h) | `HermesKit/Diagnostics/LogUploader.swift` | works; no ring, no age limit, no cursor, only `note.*`, `crash.*`, `hang.mk`, `mark` events |
| Diagnostics page (This Build, Recent Errors, Startup, Gateway, Copy Diagnostics, Share Logs) | `App/Settings/DiagnosticsView.swift` | partial; "Copied" never goes back |
| About (version, gateway version, perf-log switch, Mark a Janky Moment) | `App/Settings/AboutView.swift` | works; no update cards |
| Low power / heat (rev 2) | `PowerState` + `PowerPolls` (`HermesKit/Net/PowerPolls.swift`, offline) used by 14 polls; `HeadMotionSettings` (`App/Heads/HeadView.swift:444-467`) and `ScreenPower` (`HermesKit/Screen/ScreenSession.swift:888`) still read `ProcessInfo` themselves on the train (fixed on `m9/settings`) | polls done; heads ignore heat and loops ignore saver until settings lands; nothing logs a change |
| Memory | `TextLayout` (`App/Chat/Render/TextLayout.swift:192`), `MediaStore.swift:267` and `BotFaces.swift:45` listen for the warning; `TranscriptCache.trimMemory()` (`HermesKit/Store/TranscriptCache.swift:431`) exists and **nothing calls it** | partial |
| Signposts | `MemoRecorder.signposts` (`memo`), `TalkCapture.signposts` (`talk`), `AppModel+Intents` (`intents`), `ChatPerfProbe` (DEBUG) | launch / restore / socket missing |
| Background modes | `App/Info.plist:32` `UIBackgroundModes = [remote-notification]`; silent settle push handled in `App/AppDelegate.swift` | same as the web app |
| Stand-in gateway with the `/logs` route | `scripts/fixtures/settings-gateway.py:828` (records reason, count, kinds) and `push-gateway.py:100` (drops) | no real sink, no update routes |

Architecture rules that bind this work (`docs/ARCHITECTURE.md`): non-UI code in `HermesKit/`, UI in `App/`; network types
are `nonisolated … Sendable` or actors; nothing on the launch path may link a heavy framework or read a file on the main
thread (MetricKit is already linked by `DiagnosticLog.swift`, so it costs nothing new). Logs are content-free by rule
("Nothing logs alert text, tokens or keys"); this spec keeps that rule and adds a redactor on top, as the web app does.

Owner notes that bind this work:

- `MEM/plaid-stress-round.md`: the owner said the app felt "finicky and shaky", then asked for phone logging. The
  performance log exists so that a complaint the owner cannot diagnose can be read on the Mac
  (`~/.hermes/hq-logs`, `scripts/hq-logs.py`). The first attempt at marked moments was redone "WITHOUT screenshots
  (content-free layout outline only)". **No screenshots, no text, ever, in anything this stream sends.**
- `MEM/smoothness-round.md`: "Owner can't diagnose — we own it end to end (measure → fix → ship internal …)".
- `MEM/perf-stability-assessment-oct7.md`: the gaps that round closed in the web app were "MetricKit payloads kept in
  memory only, applicationExitMetrics ignored" and "page crashes never reach Copy Diagnostics". Native has the same
  two gaps today.
- `MEM/connection-speed-assessment.md`: the owner's device check for build 203 was "background a minute → no
  'Reconnecting…'; Diagnostics › Gateway › Returns to the app". The Returns rows are something the owner was told to
  look at; they must exist and read the same.
- `MEM/hermes-code-not-ours.md`: "We can't make any changes to hermes agent code since we don't control it."
- `MEM/onboarding-clarity.md` line 101: "**Don't `hermes update` any Nous-sign-in computer until the fix lands.**"
  (see §9, DECISION D-9.3).
- `MEM/row-padding-feedback.md`: any row whose text can wrap gets 12–14 pt top and bottom padding.
- `MEM/owner-runs-no-terminal.md`: the owner cannot run Terminal commands; nothing here may end in "run this".

---

## 1. Module map (what to add)

```
HermesKit/Diagnostics/
  Redactor.swift            DiagnosticRedactor.redact(_:)            port of S/diagnostics-redact.ts            §5
  KeptErrors.swift          last 20 errors per build, on disk         port of S/diagnostics-errors.ts            §3
  ScreenFault.swift         "Screen problem in X: …" reports          port of S/renderer-crash-report.ts         §7
  StartupTimings.swift      named timings + web-style marks           I/HermesNative measured/recordTiming       §2.3
  SocketStats.swift         live / gateway / peak / opened / …        bridge/socket.ts DispatchSocketStats       §2.2
  FieldHistory.swift        7 daily MetricKit summaries on disk       I/AppDelegate.swift DispatchFieldHistory   §6
  CrashLog.swift            last 3 iOS reports per build as text      I/AppDelegate.swift DispatchCrashLog       §6
  StabilityCounts.swift     per-build counts in UserDefaults          I/AppDelegate.swift DispatchFieldMetrics   §2.4
  DiagnosticsReport.swift   sections → rows → Copy Diagnostics text   S/diagnostics-sheet.tsx (pure functions)   §2, §4
  PerfLogPolicy.swift       clean / line / template / retryDelay      I/HermesPerfLog.swift PerfLogPolicy        §8
  PerfLogRing.swift         2 MB / 3 day segment ring + cursor        I/HermesPerfLog.swift Ring                 §8
  PerfLog.swift             recorder, upload, moment, status          I/HermesPerfLog.swift HermesPerfLog        §8
  PerfMeters.swift          HangMeter, MotionMeter, ScrollJudge,      I/HermesPerfLog.swift + S/perf-log-sources §8.4
                            KeyboardMeter, PromptWatch
  Signposts.swift           OSSignposter categories + LaunchTrace     I/AppDelegate.swift DispatchSignposts      §10
HermesKit/Net/
  PowerPolls.swift          EXISTS (offline). Small additions only    I/HermesPower.swift + S/power-state.ts     §11
HermesKit/System/
  MemoryTrim.swift          one trim path (pressure / background)     S/memory-trim.ts                           §12
HermesKit/Updates/
  UpdateStatus.swift        check, verdict, dated answers, notes      S/ios-update-status.ts + V/store/updates   §9
App/Settings/
  DiagnosticsView.swift     rebuilt                                                                              §2
  UpdateCards.swift         the two cards on About + What's New + the apply sheet                                §9
App/Kit/
  NumberPadDone.swift       one Done bar for every number pad                                                    §13.2
scripts/fixtures/
  diagnostics-gateway.py    stand-in gateway for this stream                                                     §15
scripts/e2e-diagnostics.sh  UI test runner on this stream's ports                                                §15
Tests/Diagnostics/          unit tests (vectors ported from the web tests named in each section)
UITests/diagnostics/        DiagnosticsEndToEndTests
```

`LogUploader` stays as a thin name for one release (`LogUploader.shared` forwards to `PerfLog.shared`) so the other
streams' call sites keep compiling; `DiagnosticsTimeline` keeps `record(category:message:at:)` as the feed from
`DiagnosticLog.note` and delegates to the new stores.

---

## 2. L901 — the Diagnostics page

**Web** (`S/diagnostics-sheet.tsx:270-358`): a sheet titled "Diagnostics" with Done, an intro paragraph, five sections
(App, Gateway with a "Recent reconnects" list, Startup, "Stability, this build", "Field metrics, from iOS" with a "Kept
daily reports" list), then "Recent errors" (+ "Before the last reload"), then "Reports from iOS" when there are any, and
one footer button "Copy Diagnostics".

**Native**: the page stays where it is (Settings › About › Diagnostics, pushed, small title "Diagnostics" on the bar row).
DECISION D-2.1: it is a pushed page inside the Settings sheet, not a second sheet over a sheet; the sheet's ✕ closes it,
so there is no "Done". SwiftUI `List` with `.settingsList()` as today. Every row that can wrap (errors, reconnects, kept
days, reports, the intro) gets 12 pt top and bottom padding; single-line `LabeledContent` rows keep the system height.
Values that do not fit wrap under the label (use the existing settings label/value row that stacks at accessibility sizes;
never truncate a value with "…").

Order and exact wording (titles are section headers; the web's sentence-case titles are kept, the system upper-cases
headers itself):

| # | Section header | Content |
|---|---|---|
| 0 | (no header, first row, footnote style, secondary colour) | "Copy this and send it with a bug report. Passwords, tokens, cookies and web-address details are removed, but error text is included, so read it before you share it." (`:328`) |
| 1 | App | §2.1 |
| 2 | Gateway | §2.2, then sub-header "Recent reconnects" |
| 3 | Startup | §2.3 |
| 4 | Stability, this build | §2.4 |
| 5 | Field metrics, from iOS | §6, then sub-header "Kept daily reports" |
| 6 | Recent errors | §3 |
| 7 | Reports from iOS | §6.3; the whole section is absent when there are none |
| 8 | (buttons) | "Copy Diagnostics" (§4), "Share Logs" (native extra, kept: it sends the zip of `Documents/Logs`), footer = `LogSharing.summary()` as today |

A sub-header is a plain row in footnote weight semibold, secondary colour (the web's `<h4>`), not a new section, so the
list it titles stays visually inside its section.

Data is collected once when the page appears and again on pull-to-refresh (`.refreshable`) and when the app becomes
active while the page shows. Collection reads two small JSON files and UserDefaults; do it off the main thread
(`Task.detached`) and show the page with the in-memory sections at once; file-backed sections (Field metrics, Reports
from iOS, "Before the last launch") fill in within a frame or two. No spinner: until they arrive those sections show
their empty wording.

All row building is pure and lives in `DiagnosticsReport.swift` as
`struct Row { label, value, raw: String? }`, `struct Section { title, rows, list: (title, rows, empty)? }`, so the page and
Copy Diagnostics share one source (as `collect()` and `reportText` do on the web) and the unit tests can port
`S/diagnostics-sheet.test.ts` case by case.

### 2.1 App (`:283`)

| Label | Value | Source |
|---|---|---|
| Version | `1.0 (251)` or "Unknown" | `AboutView.appVersion` |
| iOS | `27.0` or "Unknown" | `UIDevice.current.systemVersion` |
| Network | "Online" / "Offline" | `NWPathMonitor` status the app already keeps for the connection (`.satisfied` = Online) |

### 2.2 Gateway (`:285`, `:48-58`, `:123-159`)

| Label | Value | Raw name (copied text only) |
|---|---|---|
| Address | the signed-in gateway's host (`host:port` when it has a port), "Unknown" when signed out | — |
| Open connections | `SocketStats.live` | `live` |
| Gateway connections | `SocketStats.gateway` | `gateway` |
| Most open at once | `SocketStats.peak` | `peak` |
| Opened since launch | `SocketStats.opened` | `opened` |
| Reconnects since launch | `SocketStats.reconnects` | `reconnects` |
| Connection attempts | `SocketStats.attempts` | `attempts` |
| Messages too large to receive | `SocketStats.tooBig` | `tooBig` |
| Returns to the app | `"<n> · connected again in <m> ms (median of <k>) · <j> kept the connection"` (middle and last part only when non-zero) | `app.foreground` |
| Last return | "Connected in <n> ms" / "Connection kept" / "Not connected yet" | `app.foreground → socket.open` |
| Session list on reconnect | `"<skipped> of <skipped+full> unchanged, not re-read · <probes> checked"`; row absent until a reconnect has refreshed the list | `sidebar-probe` |
| Update check | the redacted message of a failed gateway update check, or "Failed"; row absent when the last check did not fail | `check-failed` |
| Logs waiting to send | byte count (native extra, kept) | `pendingBytes` |
| Logs last sent | "Never" / time + ` · HTTP <status>` when the last upload failed (native extra) | `lastUploadAt` |

DECISION D-2.2: the web's `listeners` count ("Event listeners") is a page-side JavaScript listener count; native has no
equivalent and the row is left out. The two "Logs …" rows are native extras that the web shows on About's status line
(`perfLogStatus`), moved here so About stays short.

`SocketStats` (`nonisolated final class`, a `Mutex` around seven integers, `static let shared`): `attempt()` when a
ticket is asked for; `opened(kind:)` when a WebSocket's handshake completes (`live += 1`, `opened += 1`,
`peak = max(peak, live)`, `gateway += 1` when kind is the `/api/ws` lane); `closed(kind:)`; `reconnected()` when the
`/api/ws` lane opens again after having been open once in this run; `tooBig()` where a frame over the receive limit is
refused. Call sites: `GatewayConnection` / `LiveGatewayClient` for the RPC lane, `LiveGatewayClient.pluginSocket` for
plugin sockets (browser watch, activity, bot screen). Kinds for the perf log (§8.4): `gateway`, `browser`, `activity`,
`screen`, `other`.

**Recent reconnects** (`:99-121`): newest first, at most 12; each row is the outcome on the first line and the time
(`h:mm:ss a`, "Time unknown" if absent) on the second, secondary colour. Empty: "None since launch." Outcomes, exactly:

- "Connected in <n> ms" (ticket + handshake), with " (ticket asked early)" when the ticket was pre-minted
- "Failed: no connection ticket after <s.s> s" (+ " (cancelled)")
- "Failed: handshake <outcome> after <s.s> s"
- "Got a ticket; the connection didn’t open"
- "Handshake in <n> ms"

They are derived from `StartupTimings` entries named `socket.ticket` and `socket.handshake` (each
`{name, offsetMs, durationMs, outcome}`; outcome `ok`, `early`, `cancelled`, or the failure's short code such as
`timeout`, `refused`, `401`, `closed-1006`). The launch's own connection (the first ticket and the handshake after it) is
not a reconnect (`splitConnections`, `:70-76`). Port `reconnects()` as a pure function over the entries; native stamps
each entry with wall-clock time as well, so "Time unknown" only appears for an entry restored without one.

**Returns to the app** (`:127-149`): marks `app.foreground` (scene became active after a background), `socket.open`,
`socket.close`, `socket.error` in `StartupTimings.marks` (bounded to the last 256, launch marks kept apart so a flaky
connection never pushes them out, `withLaunchTrace` `:264`). A return is `connected` (first `socket.open` before the next
return; ms = open − return), `kept` (no close within 2 s before the return or after it and no open), or `reconnecting`.
The median is the lower median, `connected[(count-1)/2]`.

**Session list on reconnect** (rev 2): the sessions stream landed the counters, public for exactly this row
(`docs/spec/3x-sessions.md` §11.2 "Public, so the Diagnostics stream … reads it"): `SessionStore.probeStats` is a
`SidebarProbeStats {probes, skipped, full}` (`HermesKit/Contracts+sessions.swift:95`). Read it from the active account's
`SessionStore`; add nothing to the store. The row is absent while `skipped + full == 0`.

### 2.3 Startup (`:60-92`)

`StartupTimings` (`nonisolated`, `Mutex`, `static let shared`): `mark(_ name:)` (ms since process start, the kernel's
`p_starttime` that `DiagnosticsTimeline.processStartDate()` already reads) and
`measure(_ name:, outcome:) { … }` / `record(name:offsetMs:durationMs:outcome:)`.

| Label | Value | Raw | Recorded where |
|---|---|---|---|
| App ready | `<n> ms` | `launch.ready` | (rev 2) where offline's `LaunchCoordinator` hands the window over: `stage = .app` (`App/Offline/LaunchCoordinator.swift:197`), `stage = .signIn` (`:213`) or the offline screen being shown, whichever comes first this launch; recorded once. This is the web's `launch.hidden` (the launch screen let go) |
| App launch | `<n> ms` | `native native.loaded` | process start → end of `didFinishLaunching` |
| Saved sign-in restore | `<n> ms` (+ " (failed)" style note via outcome) | `native native.restore` | around `launch.restoreState()` in the scene delegate's `restore()` (`App/AppDelegate.swift:209`) |
| Sign-in, total / Sign-in options / Saved sign-in check / Password sign-in / Sign-in check | `<n> ms` | `native auth.total` / `auth.providers` / `auth.resume` / `auth.login` / `auth.verify` | `SignInService` where each step already runs; a step that did not run this launch has no row |
| Connection ticket | `<n> ms`, " (asked early)" when outcome `early`, " (<outcome>)" for any other non-ok outcome | `native socket.ticket` | the launch's first ticket |
| Connection handshake | `<n> ms` | `native socket.handshake` | the handshake after it |
| Session setup | `<n> ms` | `native session` | handshake complete → first `gateway.ready` |

Empty: one row "Startup" / "Not recorded". The footer "Time from tapping the app icon." is dropped (the web has none;
rows now mix offsets and durations as the web's do). DECISION D-2.3: the web rows "Sign-in restore" (page-side) and
"Interface load" (`renderer.import`) are the page's own steps; native has neither and shows only the native names.

### 2.4 Stability, this build (`:165-186`)

Per-build counts in UserDefaults key `hqn.stability` (`{build, <name>: n, <name>LastAt: ms}`; another build's counts
read as none), `StabilityCounts.count(_ name:, by:)`.

| Label | Value | Raw | Shown |
|---|---|---|---|
| Crashes reported by iOS | `<n>` + ` · last <MMM d, h:mm a>` when n > 0 | `crashes` | always |
| Crashes caught by Hermes HQ | same form | `caughtCrashes` | when > 0 (exception / signal records of this build, native extra) |
| Hermes HQ stopped responding | same form | `mainHangs` | when > 0 (main-thread watchdog, a wait ≥ 2 s; §8.4) |
| Longest unresponsive stretch | `<s> s` | `mainHangLongestSeconds` | when > 0 |
| CPU limit reports | same form | `cpuExceptions` | when > 0 |
| Disk write reports | same form | `diskWriteExceptions` | when > 0 |
| Alerts opened / Alerts opened without the bot’s face / Alerts unread: phone not yet unlocked / Alerts unread: no key on this phone / Alerts unread: damaged / Alerts unread: iOS’s time ran out | same form | `alerts.opened` / `.noFace` / `.locked` / `.noKey` / `.unreadable` / `.expired` | when > 0, from `Shared/PushAlertDiagnostics` (already counted by the extension) |
| Hangs, last iOS daily report | `<n>` | `hangCount` | when a daily summary for this build is kept |
| Peak memory, last iOS daily report | `<n> MB` | `peakMemoryBytes` | same |

DECISION D-2.4: "Web view reloads", "Reloads into a safe start", "Reload loops stopped" and "Web view stopped
responding" count WebKit content-process events; a native app has no such process (parity row "WebContent termination
loop breaker … (web-shell only)" is already marked —). The native stand-ins for "the app broke but kept running" are
"Crashes caught by Hermes HQ" and "Hermes HQ stopped responding".

---

## 3. L902 — recent errors, folded, kept across launches

**Web**: `recentErrors` (`S/diagnostics-sheet.tsx:29-41`) takes the last 100 entries newest first, redacts, collapses
whitespace, cuts to 300 characters, folds equal messages (count, latest time), shows the first 20.
`errorMeta` (`:44`) = `"×5 · last 4:03 AM"` (either part only when it applies). `S/diagnostics-errors.ts`: the last 20
errors of the installed build are kept in storage (`dispatch.runtimeErrors`), each redacted (≤ 1000 characters), with its
time, its route (query cut, ≤ 120 characters) and the page load it came from; another build's are dropped; the earlier
loads' show under "Before the last reload", each as `"<message> · on <route>"`.

**Native**:

- `KeptErrors` (`nonisolated`, writes on the diagnostics queue): file
  `Application Support/Diagnostics/errors.json` = `{build, entries:[{message, at, route?, run}]}`, last 20, `run` = a
  random id made once per process. `keep(message:at:route:)` is called by `DiagnosticsTimeline.record` for category
  `error` (and by `ScreenFault`, §7); `earlier(run:)` returns the other runs' entries oldest first with
  `" · on <route>"` appended. A different `build` → the file is replaced. Write failures only lose the copy.
- `route` = the screen name of the newest `AppLog.note("screen", …)` line (already logged on every push), ≤ 120
  characters, redacted.
- This run's list stays in memory (last 100) as today, but is redacted with the full redactor (§5) when stored.
- Page: section "Recent errors". Each row: the message in footnote monospaced (selectable, wraps, 12 pt padding), the
  meta line under it in caption, secondary colour. Empty: "None since launch." Then, when there are any, the sub-header
  and the earlier rows.

DECISION D-3.1: the sub-header reads **"Before the last launch"**. The web's "Before the last reload" names a web-view
reload, which a native app does not have; what the list holds on native is what happened before the app was last
started (a crash, a force-quit, an iOS termination). Copy Diagnostics uses the same words.

DECISION D-3.2: the empty wording changes from native's "No errors since Hermes HQ started." to the web's
"None since launch." (and "  None since launch" in the copied text).

Acceptance: `AppLog.error` the same message five times → one row "×5 · last <time>"; kill the app, relaunch → the row is
under "Before the last launch" with " · on <screen>"; a build-number change (unit test with an injected build) drops them.

---

## 4. L903 — Copy Diagnostics

**Web** (`:245-260`, `:308-319`, `:353`): plain text, redacted line by line, put on the clipboard; the button reads
"Copied" for 2 s then "Copy Diagnostics" again; success haptic.

**Native** `DiagnosticsReport.text(sections:errors:earlier:reports:now:)`, exactly this shape:

```
Hermes HQ diagnostics
2026-10-12T09:14:03.120Z

App
  Version: 1.0 (251)
  iOS: 27.0
  Network: Online

Gateway
  Address: studio.example:9119
  Open connections [live]: 2
  …
  Returns to the app [app.foreground]: 3 · connected again in 412 ms (median of 2) · 1 kept the connection
  Recent reconnects:
    2026-10-12T09:02:11.000Z: Connected in 388 ms
    (or)    None since launch

Startup
  App ready [launch.ready]: 612 ms
  App launch [native native.loaded]: 141 ms
  …

Stability, this build
  Crashes reported by iOS [crashes]: 0

Field metrics, from iOS
  Report day: 2026-10-11
  Peak memory [peakMemoryBytes]: 212 MB
  Kept daily reports:
    2026-10-11 build 251: peak 212 MB · 0 hangs · hitches 1.2 ms/s

Recent errors (5)
  roster read: timed out (×5 · last 2026-10-12T09:03:00.000Z)
  (or)  None since launch

Before the last launch (2)
  …

iOS report: Crash, 2026-10-11T22:10:00.000Z
  build: 251
  …
```

Rules (all from `reportText`): a row is `"  <label> [<raw>]: <value>"`, the bracket only when a raw name exists and
differs from the label; list rows are `"    <raw ?? label>: <value>"`; times are ISO 8601 UTC with milliseconds; the
error count in a heading is the sum of the folded counts; every line goes through `DiagnosticRedactor.redact` on its
own ("a stray quote … in one error must not swallow the lines after it").

Button: `Label("Copy Diagnostics", systemImage: "doc.on.doc")`; on tap `UIPasteboard.general.string = text`,
`.success` notification haptic, the label becomes "Copied" with a checkmark for exactly 2 s (a cancellable `Task`; a
second tap restarts the 2 s), then goes back. VoiceOver: `HQAnnounce.say("Copied")` (the a11y stream's helper). DECISION D-4.1: the web's
"Couldn’t copy — try again" state is not built: `UIPasteboard.general.string =` cannot fail, and a state that can never
show is dead code.

Acceptance: UI test taps the button, reads `UIPasteboard` in the test runner (or the DEBUG accessibility value
`diagnostics.copy` carries the text length), asserts the first line and the section titles in order, asserts "Copied"
shows and "Copy Diagnostics" is back after 2.5 s; unit tests port `S/diagnostics-sheet.test.ts` `reportText` cases.

---

## 5. L904 — redaction (stored, shown, exported)

**Web** `S/diagnostics-redact.ts` (80 lines), applied in three places: when an error is stored
(`diagnostics-errors.ts:30`), when it is shown (`diagnostics-sheet.tsx:33`), and line by line on export (`:259`). Every
perf-log string also goes through it (`S/perf-log.ts:50`).

**Native** `DiagnosticRedactor.redact(_ text: String) -> String` in `HermesKit/Diagnostics/Redactor.swift`, a faithful
port. `MASK = "[redacted]"`, `LIMIT = 64 * 1024` characters (cut first), up to 4 passes of `redactOnce` until stable,
then `openQuote`. `redactOnce` order (do not reorder):

1. PEM private keys `-----BEGIN … PRIVATE KEY-----` to the END line or the end of text → mask.
2. Quoted runs (`"…"`, `'…'`, `“…”`, `‘…’`, `` `…` ``, `\"…\"`; a backslash-escaped quote never opens one) longer than 80
   characters inside → the quotes kept, the inside masked.
3. Content keys: `"text"|"content"|"body"|"prompt"|"transcript"|"delta"|"input"|"output"|"arguments"` followed by `:` and a
   quoted value → masked; followed by `[` or `{` → masked to the matching bracket (strings inside skipped) or the end.
4. Header lines `Authorization|Proxy-Authorization|Cookie|Set-Cookie: …` → the value masked to the end of the line.
5. URL user-info `scheme://user:pass@` → `scheme://[redacted]@`.
6. A URL's or a `/path`'s query and fragment → `?[redacted]` / `#[redacted]`; the path stays.
7. Assignments: any name ending in
   `password|passwd|pwd|passphrase|secret|token|api key|x-api-key|private_key|credential(s)|signature|sig|ticket|otp|session|sessionid|sid|authorization|cookie`
   followed by `:` or `=` → the value (quoted, unclosed-quoted or bare) masked.
8. `Bearer <value>` → `Bearer [redacted]`.
9. `Basic|Token <12+ chars>` → masked only when the value has a digit, ends in `=`, or mixes case.
10. Provider keys: `sk-…`, `rk_/sk_live|test_…`, `xai-`, `gsk_`, `pplx-`, `r8_`, `hf_`, `ghp_/gho_/ghu_/ghs_/ghr_`,
    `github_pat_`, `glpat-`, `xox[abprs]-`, `AIza…`, `AKIA|ASIA…`, JWTs (`eyJ….….…`).
11. UUIDs, and any run of 24+ letters/digits that mixes letters and digits or is 32+ hex → mask.

`openQuote`: the first opening quote after the last closing one, with 80+ characters after it, is masked to the end (a
lone `'` counts only when the text was cut at `LIMIT`).

Implementation notes: use `NSRegularExpression` (ICU). ICU look-behind must be bounded, so rule 6's variable-length
look-behind (`QUERY`, `:14`) cannot be copied; implement rule 6 as a hand scan (find `?` or `#`; accept it when the
characters before it, back to a stop character, start with `/` that is itself at the start or follows a character
that is neither a word character nor `/`; mask up to the next stop character or `)`). Rules 3 and `openQuote` are hand
scans on the web too (`bracketEnd`, `openQuote`). Work on `String.UnicodeScalarView` or UTF-16 offsets consistently; the
result must be the same for the web's vectors. The function must be linear: a 64 KB line of `"` characters finishes in
well under 50 ms (the web test "a regex from every opening mark was quadratic").

Where it runs: `KeptErrors.keep` (stored), `DiagnosticsReport` rows built from error text and update-check messages
(shown), `DiagnosticsReport.text` per line (exported), `PerfLogPolicy.short` (every perf-log string), `ScreenFault`.
`DiagnosticsTimeline.redact` (the 4-rule version) is deleted and its callers moved. Idempotent: `redact(redact(x)) ==
redact(x)` for every vector.

DECISION D-5.1: the app log file (`Documents/Logs/app.log`, sent by Share Logs) is **not** rewritten through the
redactor line by line: it is content-free by construction (the architecture rule), running 11 regex rules on every
log line on the hot path would cost more than the log itself, and the web app has no such file. What leaves the phone
through Copy Diagnostics and the performance log is redacted. The existing footer under Share Logs ("No messages or
passwords are in the log.") stays true by the logging rule; a unit test greps the app's `AppLog.note` call sites for
interpolations of message text, URLs with queries or tokens (a static check: no `AppLog.note` argument may interpolate a
symbol named `text`, `prompt`, `token`, `password`, `cookie`, `query` or a `URL` without `.host`).

One cheap pass does run on every written line (and in `AppLog.scrub`): `AppLog.tagHosts` writes every
`scheme://host[:port]` as `scheme://#tag` (the tag of the host, as gateway lines tag it; the port is dropped), next to
`tagIds`. A failed request's `URLError` description quotes the whole failing URL twice, so before build 410 the
gateway's address reached the log on every failed read (owner's phone, build 409: 23 lines in a day). Guarded by a
`"://"` check, so lines without a URL cost one scan.

Acceptance: `Tests/Diagnostics/RedactorTests.swift` ports every vector of `S/diagnostics-redact.test.ts` (read the file;
port all of them, not a sample) plus idempotence and the 64 KB timing test.

---

## 6. L906, L990 (first half) — MetricKit field history and iOS reports

**Web** (`I/AppDelegate.swift:140-413`): `DispatchFieldMetrics` subscribes to `MXMetricManager`; each daily
`MXMetricPayload` is folded to numbers (`summary`, `:158-193`) and kept on disk by day and build
(`DispatchFieldHistory`, 7 entries, `field-metrics.json`); diagnostic payloads add `diag.*` counts for the day and keep
the last 3 reports of this build as short text with symbolicatable frames (`DispatchCrashLog`, `diagnostics.json`,
40 frames, 8 KB each). The page shows them (`S/diagnostics-sheet.tsx:188-243`).

**Native**:

### 6.1 `FieldHistory` (Foundation only, pure, unit-tested)

Port of `DispatchFieldHistory` verbatim: `Entry {day, build, at, values:[String: Double]}`, `kept = 7`, file
`Application Support/Diagnostics/field-metrics.json`, `day(_:)` = `yyyy-MM-dd` UTC, `record(values, day, build, at)` (same
day and build: a repeated summary replaces its figures, `diag.` keys add up), `saved()`, `latest(build:)` (newest entry
with `windowSeconds`), `launchBuckets(prefix, buckets)` with the five bands
`under500ms, 500to1000ms, 1000to2000ms, 2000to4000ms, over4000ms` (a bucket counts where its midpoint falls). Written
atomically with `.completeFileProtectionUntilFirstUserAuthentication`, on the diagnostics queue.

Value keys (exactly the web's, so `scripts/hq-logs.py` and the page functions port unchanged): `windowSeconds`,
`cpuSeconds`, `peakMemoryBytes`, `suspendedMemoryBytes`, `hangCount`, `hangSeconds`,
`exits.foreground.{memoryLimit,watchdog,abnormal,badAccess,illegalInstruction,normal}`,
`exits.background.{memoryLimit,memoryPressure,watchdog,abnormal,badAccess,illegalInstruction,taskTimeout,lockedFile,normal}`,
`launch.firstDraw.<band>`, `launch.resume.<band>`, `launch.extended.<band>`, `scrollHitchMsPerSecond`,
`diag.{crashes,hangs,hangSeconds,cpuExceptions,diskWriteExceptions}`.

### 6.2 `MetricsReceiver` (the adapter)

`didReceive(_ payloads: [MXMetricPayload])`: for each payload `values = FieldSummary.make(payload)` (the typed-property
reads of `summary`, `:158-193`, copied), `build = payload.metaData?.applicationBuildVersion ?? thisBuild`,
`FieldHistory.record(values, day: day(payload.timeStampEnd), build:, at: now)`, and
`PerfLog.shared.metricKitDaily(values, build:)` → event `mk.daily` (fields: `build`, `fg.*`/`bg.*` exit counts that are
> 0, `hangCount`, `hangSeconds`, `scrollHitchMsPerSecond`, `cpuSeconds`, `peakMB`).

`didReceive(_ payloads: [MXDiagnosticPayload])` keeps today's behaviour (JSON record file, log lines) and adds, for
diagnostics whose `metaData.applicationBuildVersion` is this build: `StabilityCounts.count("crashes" | "cpuExceptions" |
"diskWriteExceptions")`, `CrashLog.keep(…)`, `FieldHistory.record(["diag.crashes": …, "diag.hangs": …,
"diag.hangSeconds": …, "diag.cpuExceptions": …, "diag.diskWriteExceptions": …], day: today, …)`, and perf-log events
`mk.crash {exc, signal, why}`, `mk.hang {sec}`, `mk.limits {cpu, disk}`.

MetricKit calls on a background queue; everything it touches is `nonisolated` and lock- or queue-protected. On iOS 27
`MXMetricManager` still delivers; if Xcode 27 deprecates it in favour of `MetricManager` keep `MXMetricManager` behind an
`#available` exactly as the web shell does for `makeLogHandle` (`I/AppDelegate.swift:108-111`).

### 6.3 `CrashLog` (Foundation only, pure)

Port of `DispatchCrashLog`: `kept = 3`, `frames = 40`, `limit = 8 * 1024`, file
`Application Support/Diagnostics/diagnostics.json` = `{build, entries:[{kind, at, text}]}`; `summary(kind:json:at:)` builds
the text (kind line, then the metadata lines `build`, `CPU time`, `device`, `exception code`, `exception type`, `hang`,
`iOS`, `sampled`, `signal`, `termination`, `writes` in the web's sorted-key order, then "  Thread:" or
"  Thread (attributed of N):" and frames `"    <i> <binary> +0x<offset>"` following the heaviest path). Kinds: "Crash",
"Hang", "CPU limit", "Disk writes".

### 6.4 The page

"Field metrics, from iOS" (`fieldRows`, `:219-238`): no summary kept → one row "Daily summary" / "Not received yet".
Otherwise, for the newest summary of this build (or the newest kept):

| Label | Value | Raw |
|---|---|---|
| Report day | `2026-10-11` + ` (build 250)` when it is another build's | — |
| Peak memory | `<n> MB` | `peakMemoryBytes` |
| Memory while suspended, average | `<n> MB` | `suspendedMemoryBytes` |
| Hangs | `<n>` + ` · <s.s> s in all` | `hangCount` |
| Scroll hitches | `<n.n> ms per second of scrolling` | `scrollHitchMsPerSecond` |
| CPU time | `<n> s` | `cpuSeconds` |
| Launches, time to first draw | `3 under 0.5 s · 1 over 4 s` (bands: under 0.5 s, 0.5–1 s, 1–2 s, 2–4 s, over 4 s; zero bands left out) | `launch.firstDraw` |
| Launches, until usable | same form | `launch.extended` |
| Returns from background, time to resume | same form | `launch.resume` |
| one row per non-zero exit reason, in this order and wording: "Closed by iOS for memory, in use", "Closed by iOS for memory, in background", "Closed by iOS under memory pressure", "Closed by iOS for not responding (watchdog)", "Closed by iOS for not responding, in background", "Abnormal exits, in use", "Abnormal exits, in background", "Crashes (bad memory access), in use", "Crashes (bad memory access), in background", "Crashes (illegal instruction), in use", "Crashes (illegal instruction), in background", "Background task ran out of time", "Suspended with a locked file" | count | the `exits.*` key |
| Normal exits | foreground + background | `exits.normal` |

Sub-header "Kept daily reports", newest first, each row `"<day> · build <build>"` with `fieldSummary` under it:
`"peak 212 MB · 1 hang · 2 forced exits · 1 crash report · hitches 1.2 ms/s"` (parts only when present; plural "s" by
count; forced exits = all EXITS rows except task timeout and locked file; nothing to say → "diagnostics only"). Empty:
"None yet: iOS sends the first summary about a day after install."

"Reports from iOS" (`:240-243`, `:347-350`): the last 3 of this build, newest first; each row is lines 2–4 of the text
trimmed and joined with " · " (or the kind when there are none), and under it `"<kind> · <MMM d, h:mm a>"`.

### 6.5 Seeing it work

The simulator never delivers MetricKit payloads. DEBUG-only launch argument `-HQDebugFieldFixture week` writes seven
invented entries (two builds, every key at least once, one diagnostics-only day) and three invented reports through
`FieldHistory.record` / `CrashLog.keep` before the first frame, so the page and Copy Diagnostics can be seen and
screenshotted. The pure pipeline is unit-tested with the web's vectors (`scripts/test-native-recovery.sh` cases in ref240
exercise `DispatchFieldHistory` and `DispatchCrashLog`: read them and port every assertion). **Known limit, to be
written in the report as a gap, not hidden:** the typed `MXMetricPayload` reads in `FieldSummary.make` can only run on a
device (Xcode › Debug › Simulate MetricKit Payloads, or a day of real use); on the simulator they are compiled, not
executed. The row is reported done only for what was seen (the store, the page, the copy text), with that gap named.

---

## 7. L907 — reports of screens that failed ("Page crash" equivalent)

**Web** (`S/renderer-crash-report.ts`): a React error boundary that catches a render failure reports
`"Page crash in <boundary>: <message> · at <A › B › C>"` (boundary ≤ 60 characters or "unlabeled", message ≤ 400, at most
6 component names, no URLs or line numbers, redacted); the same error from the boundary and from React within 5 s is one
entry (key = the entry without its "Page crash in X: " prefix; the map is pruned past 50 keys); it lands in Recent errors
(and so in the kept errors and Copy Diagnostics) and in the perf log as `page.crash {what}`.

**Native** has no error boundaries: a failure inside a render is a real crash, which CrashCapture already records. What
native does have, all over, is the same *situation* the boundary covers: something failed to build or decode, the user
sees a fallback ("Something went wrong", a Retry notice, plain text instead of rich text), and today nothing records it.

DECISION D-7.1: the native equivalent is `ScreenFault.report(screen:message:path:)`, called wherever the app catches a
failure and shows a fallback instead of the real content. Entry text:
**`"Screen problem in <screen>: <message> · at <A › B>"`** ("Page" is a web word; a phone screen is a "screen").
`screen` ≤ 60 characters or "unlabeled"; `message` whitespace-collapsed, ≤ 400, "Unknown error" when empty; `path` = up
to 6 type names, outermost last, joined with " › " (the call site passes them; `String(describing: type(of:))`, never a
title or any user text); the whole entry redacted. Deduplicated within `REPEAT_MS = 5 s` on the entry minus its
"Screen problem in X: " prefix, map pruned past 50 keys. A new report: (1) `DiagnosticsTimeline.record("error", entry)`
(so it folds, is kept across launches and is copied), (2) `PerfLog.record("page.crash", ["what": entry])` (the kind
`page.crash` is kept so `scripts/hq-logs.py` counts it without a change), (3) `StabilityCounts` is **not** touched.
Never throws, never blocks: a failure to log must not break the fallback.

Required call sites (the builder greps for more; every `catch` that ends in a user-visible fallback and is not a plain
"can't reach your gateway" transport failure qualifies):

| Screen name | Where | When |
|---|---|---|
| `chat` | `TranscriptCache` load | a cache file is present but cannot be decoded (not a version miss) |
| `chat` | `ChatRowModel.flush` | the stale-model rebuild guard fires (`isStale(forMessageCount:)`) |
| `chat.markdown` | `MarkdownRenderer` | a reply falls back to plain text |
| `jobs`, `kanban`, `artifacts`, `capabilities`, `settings.<page>` | each page's load | the gateway answered 2xx but the body did not decode (`DecodingError`): message = the coding path's key names and the error kind, never values |
| `bots`, `sessions` | `BotStore` / `SessionStore` | a 2xx roster or sidebar body does not decode |
| `media` | image / file preview | a downloaded file cannot be decoded and the tile shows "Open image" |
| `questions` | `ServerRequestCenter` | a server request of a known kind cannot be decoded and is answered with an error |

Transport failures (offline, timeout, 5xx) are not screen faults; they are already `AppLog.error` lines.

DEBUG hook for tests: `-HQDebugScreenFault "<screen>|<message>|<A,B>"` reports that fault once the main tabs show, and
again 1 s later (to prove the 5 s fold). (`App/Debug/DebugHooks.swift` is the one place launch hooks are applied
from; add a `DiagnosticsDebug.applyBeforeLaunch()` call there next to the other streams', and keep every hook of this
stream in `App/Debug/DiagnosticsDebug.swift`, `#if DEBUG`.)

Acceptance: unit tests port `S/renderer-crash-report.test.ts` (`componentPath` → path join, bounds, redaction, the 5 s
repeat, the 50-key prune). UI test: launch with the hook → Diagnostics shows exactly one row
"Screen problem in jobs: … · at JobsViewController › JobRowView" and the fixture's log sink holds one `page.crash`. A
second UI case feeds a real undecodable body from the fixture (`POST /__diag/fail {"route":"GET /api/cron/jobs",
"mode":"bad-json"}`), opens Jobs, sees the page's own failure state, then finds the row in Diagnostics.

---

## 8. L908, L909, L991, L992 — the performance log

### 8.1 What the web app does

Native half `I/HermesPerfLog.swift` (786 lines), page half `S/perf-log.ts` and `S/perf-log-sources.ts`, sink
`P/perf_logs.py` behind `POST /api/plugins/hermes-hq-push/logs` and `/logs/moment` (`P/dashboard/plugin_api.py:96-121`,
plugin 0.8.0). An event is `{t: epoch ms, k: kind, s: "n"|"j", …fields}`; kinds match `^[a-z][a-z0-9_.-]{0,39}$`; field
names match `^[A-Za-z][A-Za-z0-9_.]{0,31}$` and are not in the blocked set; at most 16 fields; values are flags, finite
numbers rounded to 0.1, or strings made one line, query cut, redacted, ≤ 120 characters. The phone keeps a ring (2 MB,
3 days, 256 KB segments named by their first event's time), a cursor (segment + byte offset of the next unsent line),
and uploads batches of whole lines ≤ 96 KB. Failures back off 30 s doubling to 30 min; 404 → 6 h; 401/403 → 30 min.
The switch off deletes the ring and the cursor.

### 8.2 Wire (unchanged, the plugin already installed on the owner's Mac accepts it)

```
POST /api/plugins/hermes-hq-push/logs          (the gateway's normal sign-in headers, like every REST call)
{"device":"HQN_iPhone17_1-3f9a0c2e","app":"HQN 1.0 (251)","reason":"timer","lost":false,
 "lines":["{\"k\":\"sock.opened\",\"kind\":\"gateway\",\"ms\":212.4,\"s\":\"n\",\"t\":1760260443120}", …]}
→ 200 {"ok":true,"lines":37,"dropped":0}
→ 400 {"detail":"Invalid device."}   413 {"detail":"Too many lines in one upload."}   409 {"detail":"Too many devices are logging to this computer."}
→ 404 (no plugin, or one older than 0.7)   401 (not signed in)

POST /api/plugins/hermes-hq-push/logs/moment
{"device":"HQN_iPhone17_1-3f9a0c2e","marker":"0123456789ab","app":"HQN 1.0 (251)",
 "bundle":{"frames":[{"at":1760260443,"n":58,"max":41.7,"over":2}],
           "outline":[{"tag":"uiview","slot":"ChatBubbleCell","d":4,"x":0,"y":120,"w":402,"h":64,"o":1,"z":3}],
           "ctx":{"screen":"chat","net":"up:wifi"},"outlineMs":3.1}}
→ 200 {"ok":true,"frames":1,"nodes":1}
```

Sink limits to stay inside (`P/perf_logs.py:26-42`, `:142-152`): device `[A-Za-z0-9_]{1,24}-[0-9a-f]{8}`; ≤ 4000 lines
per upload; a line ≤ 2048 bytes; marker `[0-9a-f]{8,16}`; outline node `tag` `[a-z][a-z0-9-]{0,15}`, `slot`
`[A-Za-z0-9_-]{1,48}`, `role` `[a-z]{1,24}`, numbers only from `d,x,y,w,h,o,z,tx,ty,sx`; frame numbers only from
`at,n,max,over`; ≤ 120 frames, ≤ 600 nodes, ≤ 256 KB. `reason` values the app sends: `timer`, `background`,
`foreground`, `signed-in`, `enabled`, `mark`.

REST only; no JSON-RPC method is involved, so Hermes' "unknown params → 4000" rule does not apply here. Nothing in
`H/tui_gateway/contracts` is touched by this stream.

### 8.3 Native design

`PerfLogPolicy` (pure): `blocked` = the web's 34 names (`text, content, body, prompt, message, messages, delta, output,
input, arguments, args, url, href, query, search, token, password, passwd, secret, ticket, cookie, authorization, auth,
bearer, key, apikey, title, name, username, email, transcript, answer, value, data`), `validKind`, `validKey`, `short`,
`clean`, `line(at:kind:source:fields:)` (sorted keys, `s` = `"n"`), `template(path)` (query cut; any segment that is not a
route word becomes `:id`; route words as `I/HermesPerfLog.swift:86-90`, read and copy the set), `socketKind(path)`,
`closeReason(data)` (≤ 40 characters of `[A-Za-z0-9 _.:-]`, else `len:<n>`), `retryDelay(status:failures:)`,
`momentMarker`, `momentBody` (≤ 200 000 bytes), `deviceLabel`. Unit tests port `scripts/test-native-perflog.sh`'s cases
if that script exists in ref240 (it compiles the `PERFLOG-POLICY` block), else the cases in `S/perf-log.test.ts`.

`PerfLogRing` (pure, on its own serial queue): directory `Application Support/Diagnostics/perflog/`, segments
`%015.0f.jsonl`, `append(lines, now)`, `prune(now)` (over 2 000 000 bytes or a segment whose last write is older than
3 days: oldest first), `read(from: cursor, maxBytes: 96_000) -> Batch {lines, next, lost, more}` (`lost` when the cursor's
segment is gone), `pending(after:)`, `clear()`. Cursor in UserDefaults `hqn.perflog.cursor`.

`PerfLog` (`nonisolated final class`, `static let shared`):

- `record(_ kind: String, _ fields: [String: Any] = [:])`: callable from any thread; costs a lock, a dictionary and an
  append to an in-memory buffer; the buffer is written to the ring every 5 s, at 100 events, and when the app leaves the
  screen. Off → returns at once.
- `isEnabled` / `setEnabled(_:)`: key stays `hqn.perfLog.enabled` (default on). Off: timers and meters stop, buffer,
  ring and cursor are deleted, nothing is recorded. On: `record("log.on")`, meters start.
- `status() async -> Status {enabled, device, pendingBytes, lastUploadAt, lastStatus}`.
- `upload(reason:background:force:)`: one upload at a time (`uploading` holds until the upload itself ends, the web's
  "crashes #12" fix); up to 6 batches foreground, 2 in the background; moves the cursor only after a 200; a failure sets
  `nextAttempt` by `retryDelay`; `force` (a mark) skips the wait once. Triggers: a 300 s timer (30 s tolerance) while
  active; `appDidEnterBackground` (inside a `beginBackgroundTask` named "Hermes HQ performance log", ended by the upload
  or by iOS, whose expiry only stops the loop after the batch in flight); 4 s after returning to the foreground;
  sign-in (`setSender`); the switch turning on; a mark.
- `markMoment(by:) -> String`: 12 hex digits; records `mark {by, id}`, flushes, `upload(reason: "mark", force: true)`,
  and sends the bundle (§8.5).
- `setSender(_:)`: the app gives it a closure `(path, body) async -> Int` (status; 0 or −1 for a transport error) built
  on the account's `LiveGatewayClient.rest`, nil while signed out. The log never builds a URL or reads a credential.
- The device label stays `"HQN_<machine>-<8 hex>"` (`hqn.log.device`), so native logs sit beside the web app's on the Mac
  under their own folder.

Migration: on first launch of this build, lines waiting in `Documents/Logs/outbox.jsonl` and `sending.jsonl` are appended
to the ring and the two files removed. `note.<category>` (the app log's lines, split into `m`, `m2`, … of 120
characters), `crash.exc`, `crash.sig`, `crash.img`, `crash.frame`, `crash.mk`, `crash.mk.frame`, `hang.mk` keep being
produced exactly as today, now through `PerfLog.record` / a raw-line append for the pre-built crash lines.

### 8.4 Sources (L909)

Everything below is off while the switch is off, and none of it carries text.

| Kind | Fields | When (native) | Web reference |
|---|---|---|---|
| `app.launch` | `build`, `os` | `PerfLog.start()` in `didFinishLaunching` | `I/…PerfLog:592` |
| `app.bg` / `app.fg` | `appMB`, `availMB` / `awayS` | scene background / active | `:619-632` |
| `app.terminate` | — | `willTerminate` (buffer written synchronously) | `:590` |
| `mem` | `appMB`, `availMB`, `quickHttp` | every 60 s while active | `:606-611` |
| `mem.warning` | `appMB`, `availMB` | `didReceiveMemoryWarningNotification` | `:587` |
| `mem.pressure` | `level` (`normal`/`warning`/`critical`), `screen`, `appMB`, `availMB` | `DispatchSource.makeMemoryPressureSource` | `:560-572` |
| `mem.trim` | `why` (`pressure`/`background`), `chats`, `mb` | §12 | new |
| `power` | `lowPower`, `thermal` | `PowerState` change and once at launch | `:551-558` |
| `net` | `path` (`up:wifi`, `up:cell`, `down:`) | `NWPathMonitor` change | `setNetwork` |
| **`main.hang`** | `ms`, `screen`, `ongoing`, `did`, `ctx` | the watchdog: a utility-queue timer pings main every 0.1 s; an answer more than 0.25 s late is a hang that long; a ping still unanswered after 2 s is reported once with `ongoing: true` (and counts `mainHangs`, §2.4). Runs only while the app is active. Build 292: `did` = the named main-thread spans (`MainTrail`, also os_signpost intervals, category `Main`: `chat.load`, `chat.flush`, `chat.apply`, `chat.relayout`, `chat.merge`, `chat.deliver`, `chat.cache`, `browser.frame`, `browser.keyboard`, `app.active`, `app.foreground`) that overlapped the stall, summed by name, longest first, `open` when still running, or `nothing traced`; `ctx` = facts the app keeps current (`chatRows`, `catchUp running/done/gave up` with its age, `return was`, `browserLink`). Fixed words and numbers only. MetricKit hang reports (`hang.mk`, now with `bld`) keep their attributed thread's heaviest path as up to 24 `hang.mk.frame` lines (`rec`, `i` innermost first, `b` binary, `o` offset, `u` UUID prefix, `s` system symbol via `dladdr`; the app's own frames are named by `scripts/hqn-logs.py` with atos). | `HangMeter`, `:205-234`. This is the **stall** source: the page's 250 ms sampler (`S/perf-log-sources.ts:26-36`) exists because WebKit has no long-task observer; native measures the main thread itself. |
| **`scroll.jump`** / `scroll.shrink` / `scroll.kb` | `dy`, `dh`, `off`, `top`, `height`, `client`, `hint` | the chat table's `scrollViewDidScroll`: a content-offset change over 40 pt with no finger behind it (`isTracking`, `isDragging`, `isDecelerating` all false and not within 180 ms of one) that was not simply following the newest end (gap ≤ 2 pt before and after). `scroll.shrink`: it followed, but the content got more than 40 pt shorter. `scroll.kb`: within 400 ms of the keyboard settling, a move as large as the visible height's change and opposite to it (`off` = what is left over). `hint` = up to 4 distinct other kinds recorded in the last 1.5 s (`sock.*`, `gw.conn`, `prompt`, `dock`, `resync.sessions`…), newest last, never the scroll/stall/mem/motion kinds themselves. Because the table is inverted, feed the judge the *visual* numbers (top = distance from the oldest end) so `dy` has the web's sign. The jump button's own glide and the send lift set a flag and are not jumps. | `judgeScroll`, `:45-58`; port it as the pure `ScrollJudge` with `S/perf-log.test.ts` / sources vectors |
| `dock` | `h`, `dh` | the above-composer stack's height changes by more than 8 pt | Plaid round ("dock-height changes … jump 190–240 pt") |
| **`prompt`** | `kind` (`approval`, `sudo`, `secret`, `vault-unlock`, `vault-save`, `vault-code`, `clarify`), `ev` (`shown`/`gone`), `ms` (on gone), `vis` | `ServerRequestCenter` arrival and resolution, keyed by request id | `watchPrompts`, `:166-173` |
| **`motion.native`** | `mo`, `ms`, `n`, `hitch`, `max`, `hz` | `PerfLog.motion(begin:)` / `end(name:)` around: chat open (`chat.open`, push start → transition end), back (`chat.back`), keyboard (`kb.up` / `kb.down`, from `keyboardWillShow` to the layout guide settling), sheets (`sheet.open` / `sheet.close`), tab switch (`tab`). One `CADisplayLink` runs only while a motion is open, capped at 2 s; a frame is a hitch when its gap exceeds 1.5 × the link's interval; `max` in ms to 0.1, `hz` from the median interval. | `MotionMeter`, `:261-291`; names: read `S/perf-motion.ts` and reuse its `mo` strings where a motion matches |
| **`sock.open`** / `sock.opened` / `sock.end` | `id` (8 chars of a per-socket UUID), `kind`; `ms` (dial → open); `how` (`closed`, `dropped`, `cancelled`, `asked`), `code`, `reason`, `error`, `lifeS` | every WebSocket: RPC lane and plugin sockets | `:415-441` |
| **`gw.conn`** | `state` (`connecting`, `ready`, `reconnecting`, `offline`, `signed-out`), `attempt` | `AppModel` where it already logs `connection <state>` | `S/perf-log-sources.ts:122-125` |
| `http` | `path` (template), `method`, `status`, `bytes`, `ms` | REST calls slower than 250 ms, larger than 16 KB, failed, or on a `/messages` path; quick ones only counted into `mem.quickHttp` | `:445-449` |
| `resync.sessions` | `probe`, `full`, `ms` | each reconnect's session-list refresh | `:120` |
| `kb` | `what` (`background`, `full`, `tall`, `flap`, `restore`) | `KeyboardMeter` on keyboard frame changes | `:236-259` |
| `page.crash` | `what` | §7 | `:126-129` |
| `page.error` | `kind`, `what` | every `AppLog.error` (the first 120 redacted characters) | `:130-133` |
| `mk.daily`, `mk.crash`, `mk.hang`, `mk.limits` | §6.2 | MetricKit | `:451-461` |
| `mark`, `moment.sent` | `by`, `id` / `status` | Mark a Janky Moment, shake | `S/perf-log.ts:126-136` |
| `log.on`, `log.dropped` | — / `n` | switch on; buffer overflow (over 500 unsaved events drops the oldest and counts) | `:73`, `:89` |

`screen` = the newest `AppLog.note("screen", …)` name (a fixed identifier such as `chat`, `bots`, `jobs`; never a title).

The five sources the row names (stalls, scroll jumps, prompts, motions, socket states) are the bold kinds; each needs
its own acceptance check in §15. The others come with the port of the native half (L908 / L991) and are checked by one
test that reads the fixture's sink and asserts the kinds present after a scripted session.

### 8.5 Marked moments

`PerfLog.markMoment` builds, on the main thread in under 8 ms (measure it; send `outlineMs`), a bundle:
`frames` = the per-second frame records the motion meter and the watchdog produced in the last 60 s
(`{at: epoch s, n: frames, max: worst gap ms, over: frames past 1.5×}`; seconds with no motion have no record),
`outline` = the key window's view tree, depth-first, at most 600 nodes, visible views only: `tag` = the class name
lowercased with non `[a-z0-9-]` removed, cut to 16; `slot` = `accessibilityIdentifier` when set, else the Swift type
name, filtered to `[A-Za-z0-9_-]`, cut to 48; `d` depth; `x,y,w,h` in window points; `o` alpha; `z` sibling index.
**No `accessibilityLabel`, no text, no image, no screenshot** (`MEM/plaid-stress-round.md`). `ctx` = `{screen, net,
lowPower, thermal}` (cleaned like an event). Sent to `/logs/moment`; the answer's status is recorded as `moment.sent`.
DECISION D-8.1: frames are sampled only during motions (no always-on display link, which would wake the CPU 120 times a
second for a log); the web samples every frame only while its self-checks run.

### 8.6 L992 — the sink (client side only)

The sink is the plugin's (`P/perf_logs.py`, 0.8.0), and `MEM/plaid-stress-round.md` records it installed on the owner's
Mac and published ("Push 0.8.0 … PUBLISHED hermes-hq-plugins 6cdeb08"). **No plugin change is needed**: native's events
already pass its cleaner (source `"n"`, kinds and field names inside its patterns, device label inside `DEVICE`). So
nothing for this row goes to the owner's to-do as a required change; `docs/owner-todo/diagnostics.md` carries one
optional note (hq-logs.py reading native kinds) and the caution in §9.

What the client must do for the row to count: (a) every line native produces survives the real cleaner unchanged
(proved by running the ref240 `perf_logs.py` itself inside the stand-in gateway, §15.1, and diffing sent vs written);
(b) the app degrades plainly when the sink is missing: a 404 sets the 6 h wait and Diagnostics › Gateway shows a plain sentence in the "Logs last sent" row. DECISION D-8.2, exact words: on 404
**"Not sent: this gateway’s Hermes HQ plugin is missing or too old to keep logs."**, on 401/403
**"Not sent: sign in to your gateway again."**, on 409 **"Not sent: too many devices are logging to this computer."**,
on any other failure **"Not sent yet: Hermes HQ will try again."**; these replace the bare HTTP status in the
"Logs last sent" row (the raw status stays in the copied text as `lastStatus`). No alert, no banner: the log is
background plumbing.

Acceptance for L992: a UI or integration test signs in to `diagnostics-gateway.py`, generates events, forces an upload,
and asserts files `build/fixtures/hq-logs/<device>/<UTC day>.jsonl` exist, begin with the sink's own
`{"k":"upload","s":"g",…}` line, and contain every sent kind with `dropped == 0`; then
`python3 /Users/me/Projects/hermes-hq-native-ref240/scripts/hq-logs.py` (read its `--help`; point it at that
folder) summarises them without an error.

---

## 9. L980 — update status cards

### 9.1 What the web app does

Settings › About shows two cards (`V/app/settings/about-settings.tsx:59-61`, `V/components/update-status.tsx`):

- **Client** (`S/ios-update-status.ts:1-70`): how far the build's pinned Hermes renderer trails upstream, from GitHub's
  compare API, cached 6 h (`ios.hermesDrift`); it can never update itself, so it is one line with no buttons:
  "Hermes HQ gets newer Hermes features in app updates." (no data), "Hermes HQ includes the latest Hermes." (0 behind),
  "Newer Hermes features will arrive in a future Hermes HQ update." (behind).
- **Gateway**: `GET /api/hermes/update/check[?force=true]` → verdict line, "Last checked …" line, buttons
  "Check for Updates", and when an update is ready "Update Now…" and "What's New".

Phone-specific behaviour (`S/ios-update-status.ts`): opening the page forces one check unless one ran in the last
30 minutes (`freshBackendCheck`, `:159-172`); until a dated answer arrives the card shows it checking, not the cached
verdict (`backendVerdictPending`); an undated answer reads "Checked by your gateway within the last day"
(`backendCheckedLine`, `:182-185`); a failed check says "Tried <when>", never "Last checked"; failures are put in plain
words (`updateCheckFailure`, `:94-106`); while the gateway link is down the card says
"Connect to your gateway to check for or install updates." and its buttons wait; a failed check that never reached the
gateway is run again when the gateway is back (`onGatewayReturn`, `unreachedCheck`, `recheckFailedBackend`); the
relative time redraws every 30 s; "Update Now…" asks first (`confirmGatewayUpdate`, `:75-89`); "What's New" lists the
gateway's commits without developer chores (`releaseNoteCommits`, `:111-116`) and is offered only when a note is left
(`hasReleaseNotes`); a count is claimed only beside the notes it counts (`updateReadyLine`).

### 9.2 Wire (real Hermes: `H/hermes_cli/web_routers/actions.py:240-425`)

```
GET /api/hermes/update/check            (optional ?force=true ; the route also takes an optional `profile`, which
                                         the web never sends and native must not send either)
→ 200 {"install_method":"git","current_version":"0.23.1","behind":12,"update_available":true,"can_apply":true,
       "update_command":"hermes update","message":null,
       "commits":[{"sha":"1a2b3c4","summary":"feat(voice): faster first word","author":"…","at":1760200000}, …≤20]}
   behind: 0 = up to date · -1 = an update exists, count unknown · null = the check could not run (message says why)
   can_apply false (docker, apt, nix, desktop-app, managed-runtime): message is the guidance; no Update button
   optional "checked_at" (seconds or ms) when a gateway dates its answer

POST /api/hermes/update                 (no body)
→ 200 {"ok":true,"pid":123,"name":"hermes-update","action_id":"<32 hex>"}            (or "already_running":true)
→ 200 {"ok":false,"pid":null,"name":"hermes-update","error":"<code>","message":"…","update_command":"hermes update"|""}

GET /api/actions/hermes-update/status?lines=2000
→ 200 {"name":"hermes-update","running":true|false,"exit_code":null|0|1,"pid":123,"lines":["…"],
       "action_id":"…"?, "receipt":{"action_id":"…","outcome":"success"|"partial"|"failed"|"refused",…}?}
→ 404 unknown action
```

All three are plain REST with the account's sign-in. `HermesKit/Store/CapabilitiesStore.swift:94` (and
`CapabilitiesStore+More.swift:114`) already read `/api/actions/<name>/status`; reuse that decoding. Signatures checked
against `H/hermes_cli/web_routers/actions.py` on this Mac: `update_hermes()` `:240` (no body),
`check_hermes_update(force: bool = False, profile: Optional[str] = None)` `:283`, action status `:366`. REST, so the
JSON-RPC "unknown params → 4000" rule does not come into it.

### 9.3 Native design

`HermesKit/Updates/UpdateStatus.swift` (pure logic + an `@Observable` per-account `GatewayUpdateModel`):
`GatewayUpdateStatus {supported, error: String?, message: String?, updateAvailable, behind: Int?, currentVersion,
commits, fetchedAt, dated: Bool}`; `map(_ response)` = `mapBackendCheck` (`V/store/updates.ts:491-522`:
`supported = can_apply`; `error = "check-failed"` when `can_apply && behind == nil`; `behind` nil when null or
negative); `check(force:)` bound to the account that started it (a slower answer for an account since left is
dropped); one check at a time, a second request while one runs waits for it; `freshCheck()` (30 min rule, a failed
check does not count); `datedAnswer` / `gatewayCheckedAt`; `updateCheckFailure`; `releaseNoteCommits`; `hasReleaseNotes`;
`updateReadyLine`; `unreachedCheck`; `recheckIfUnreached()` on `gateway.ready` and on the app becoming active (run once
per burst, 250 ms later); `confirmHost(baseURL)` (the host name, or nil when it is an IP address or contains ":").
Unit tests port **every** case of `S/ios-update-status.test.ts`.

**About page** (`App/Settings/AboutView.swift`), two changes:

1. First section: footer becomes two lines: the existing credit line, then the client line.
   DECISION D-9.1: native has no pinned renderer (parity row "About: pinned Hermes renderer commit row (web-only)" is
   —), so there is nothing to compare with upstream and **no call to api.github.com is made**; the client line is the
   web's no-data sentence, always: **"Hermes HQ gets newer Hermes features in app updates."** The 6 h drift cache is
   web-shell-only for that reason. (No word of TestFlight, as the web comment says: the same text ships to the App
   Store.)
2. A new section, header **"Hermes on Your Gateway"**, between the version section and the links. The existing
   "Hermes on Your Gateway" value row moves into it as its first row, labelled "Version". Then the card rows:

| State | Line (body, primary colour; `available` tinted) | Second line (footnote, secondary) | Buttons (plain rows, tint colour) |
|---|---|---|---|
| link down (connection not `.ready`) | last verdict if any, else nothing | "Connect to your gateway to check for or install updates." | "Check for Updates" disabled (plain dimmed row) |
| first open, check running, no dated answer | "Looking for updates…" with a small `ProgressView` | — | "Checking…" disabled |
| up to date | ✓ "Your gateway is running the latest Hermes." | "Last checked just now" / "Last checked 3 min ago" / "2h ago" / "4d ago"; undated: "Checked by your gateway within the last day" | "Check for Updates" |
| update ready, count known and notes present | "A new update is ready (12 changes included)." (count with the locale's grouping; "1 change") | as above | "Check for Updates", "Update Now…", "What's New" |
| update ready, count unknown or no notes | "A new update is ready." | as above | "Check for Updates", "Update Now…" ("What's New" only when `hasReleaseNotes`) |
| cannot update from the app (`can_apply` false) | the gateway's `message`, or "This version of Hermes can’t update itself from inside the app." | — | none |
| check failed: gateway's own fetch failed (`github`, `git fetch/pull/ls-remote`, `update server`, `could not resolve host`, `pypi`) | "We couldn't reach the update server." | the readable message (≤ 200 characters, no `{}<>`), then "Tried just now" | "Check for Updates" |
| check failed: timed out (`took too long`, `timed out`, `timeout`, `-1001`) | "Your gateway didn’t answer in time" | "It may be busy. Check again in a moment." then "Tried …" | "Check for Updates" |
| check failed: unreachable (`can't reach`, `could not connect`, `not connected`, `offline`, `network`, `socket`, `-1003/-1004/-1005/-1009`) | "Hermes HQ couldn’t reach your gateway" | "Check your connection, then check again." then "Tried …" | "Check for Updates" |
| check failed: anything else | "Couldn’t check for updates" | the readable message if any, then "Tried …" | "Check for Updates" |
| update running | "An update is currently installing." | the stage line (below) | none |

The raw code (`check-failed`) never shows here; it is Diagnostics › Gateway › "Update check" (§2.2). Rows that wrap get
12 pt vertical padding. The relative time redraws every 30 s while the page shows (`TimelineView(.periodic(…, by: 30))`).
The gateway-old-contract alert that already exists (the scene delegate's compatibility check in
`App/AppDelegate.swift`) is unchanged. On an iPad the Settings sheet is wider: the card rows are ordinary list rows and
need nothing special, and the apply sheet is a form sheet there (`ChatSheet.wrap` already decides).

**Update Now…** → a system alert (`UIAlertController`, `.alert`):
title **"Update Hermes on <host>?"**, or **"Update Hermes on your gateway computer?"** when the host is an address;
message **"The gateway runs the update and restarts, and running chats pause until it’s back. Hermes HQ reconnects on
its own."**; actions **"Update Gateway"** and **"Not Now"** (cancel). Nothing is sent until "Update Gateway".

Then a sheet (`ChatSheet.wrap`, ✕ leading, inline title "Gateway update available" → becomes the stage title), body:
"Your gateway computer is installing the update and will restart. Hermes HQ reconnects on its own when it’s back.", a
progress row with the stage line: "Updating the gateway…" (after `POST`), "The gateway is updating…" (polling, running),
"The gateway is restarting to load the update…" (status polls fail: the gateway is restarting), then
"Update complete" with a "Done" button, or the failure: title "Update didn’t finish", body
"No worries — nothing was lost. You can try again now." with the line "The gateway update failed." or
"The gateway didn’t come back online. The update may not have finished; check the gateway computer.", buttons
"Try again" and "Done". When `POST` answers `ok:false`: title "Can't update from here", body = the gateway's `message` (or
"No update is available for this gateway."), and when `update_command` is non-empty the line
"The Hermes backend is managed outside this app. Run this on the server that hosts it:" → DECISION D-9.2: reword on
the phone to **"Hermes on your gateway computer is managed outside Hermes HQ. Update it there with:"** followed by the
command in a monospaced, selectable row with a "Copy" button (→ "Copied" 2 s) — "backend" and "server" are not words
this app uses (the web gates already replace "backend" with "gateway" in every other update string,
`B/fe-platform-gates.ts:50-53`).

Polling (`V/store/updates.ts:746-748`, `:888-965`): every 1.5 s `GET /api/actions/hermes-update/status?lines=2000`,
for at most 6 minutes; the first failed poll switches to the restart stage and gives the gateway 4 minutes to come
back; success = `exit_code == 0`, or `exit_code == null` with a `receipt` for this `action_id` (or one started after the
update began) whose `outcome` is `success`; `partial`/`failed` → failure; a non-null non-zero `exit_code` → failure. On
success force a check (the card then reads up to date and the version row refreshes via `SettingsHub`). The sheet may
be closed while it runs; the card keeps "An update is currently installing." and the poll continues in the model; the
app going to the background pauses the poll and it resumes on return (the deadline counts only foreground time).

**What's New** → a pushed page titled "What's New": the commits after `releaseNoteCommits` (drop chores by the `CHORE`
pattern, strip backticks and a trailing `(#123)`), grouped as the web's changelog builder does
(`V/lib/commit-changelog.ts`: `feat|feature` → "What's new", `fix|bugfix|hotfix|revert` → "Fixed",
`perf|performance` → "Faster", `refactor|a11y|ui|ux` → "Improved", other non-hidden → "Other improvements"; hidden types
`build, chore, ci, dep, deps, doc, docs, lint, release, style, test, tests, wip`; subjects tidied and capitalised; read
the file for the per-group and total caps and "+ N more changes included."). Wrapping rows, 12 pt padding.

DECISION D-9.3 (the owner's Mac): `MEM/onboarding-clarity.md` says not to run `hermes update` on a Nous-sign-in
computer until Hermes fixes issue #134128. The web app (build 240, on the owner's phone today) already has this same
button behind this same confirm, so native matching it changes nothing about that risk; adding a native-only warning
would be wording the owner never approved. The card is built to parity, **every test of the apply path runs only
against the stand-in gateway, never the owner's gateway**, and the caution is written in plain words in
`docs/owner-todo/diagnostics.md` so the release notes for this build can repeat it.

DECISION D-9.4: the web's "update available" toast and the contract-skew toasts (`V/store/updates.ts:179-241`) are not
part of this row (the row is the cards); native already has the outdated-gateway alert at sign-in.

Acceptance: §15 U1–U9.

---

## 10. L912, L990 (second half) — signposts

**Web** (`I/AppDelegate.swift:88-138`): `OSSignposter`s, subsystem = the bundle id, categories Launch (interval
"Launch" from `didFinishLaunching` to the launch screen's release, event "FirstNavigation", interval "PageLoad"),
Session (the restore and each measured step), Socket (ticket, handshake), Bridge, WebContent; a `Logger` category
Stability; and the launch interval mirrored with `mxSignpost` on MetricKit's own log handle (category "Launch") so the
daily payload attributes launch time to the app.

**Native** `HermesKit/Diagnostics/Signposts.swift`:

```swift
nonisolated enum Signposts {
    static let subsystem = Bundle.main.bundleIdentifier ?? "ai.hermes.hqnative"
    static let launch  = OSSignposter(subsystem: subsystem, category: "Launch")
    static let session = OSSignposter(subsystem: subsystem, category: "Session")
    static let socket  = OSSignposter(subsystem: subsystem, category: "Socket")
    static let chat    = OSSignposter(subsystem: subsystem, category: "Chat")
    static let stability = Logger(subsystem: subsystem, category: "Stability")
    static let metricKit: OSLog = MXMetricManager.makeLogHandle(category: "Launch")   // #available switch as the web's
}
```

| Category | Name | Begin → end | Message (public, content-free) |
|---|---|---|---|
| Launch | interval `Launch` (+ `mxSignpost(.begin/.end, name: "Launch")`) | first line of `didFinishLaunching` → the same point as the `launch.ready` mark (§2.3: the launch coordinator's hand-over) | end: `tabs`, `sign-in` or `offline` |
| Launch | event `FirstFrame` | `LaunchViewController`'s first `viewDidAppear` | — |
| Session | interval `Restore` | around `launch.restoreState()` (`App/AppDelegate.swift:209`) | end: the state's `logLabel` |
| Session | interval `Step` | each `StartupTimings.measure` (auth.*) | begin: the step's name |
| Socket | interval `Ticket`, interval `Handshake` | per connection attempt | begin: the socket kind; end: the outcome code |
| Chat | interval `ChatOpen` | tap on a bot row → the chat's first frame (in the two-pane iPad layout: the row tap → the detail pane's first frame; begin it in `PaneRouter`'s open path so both layouts share one site) | — |

DECISION D-10.1: the web's Bridge and WebContent categories time the WebView bridge and WebKit's content process;
neither exists natively. The native fourth category is `Chat` (the open the owner judges by feel,
`MEM/smoothness-round.md`). `MemoRecorder.signposts` (category `memo`, `HermesKit/Voice/MemoRecorder.swift:64`) and
`TalkCapture.signposts` (category `talk`, `HermesKit/Voice/TalkCapture.swift:379`) move to this subsystem value: both
hard-code `com.charlesmcdowell.hermeshq.native` today, which is wrong for the shipped identity (the build the owner
runs), so Instruments filtered by the app's bundle id never shows them. `AppModel+Intents.swift:112` already uses the
bundle id and is left alone. Change the one string in each; do not touch what they time.

`StartupTimings.measure` begins and ends the matching interval itself, so the timing rows (§2.3) and the signposts
cannot drift apart. Signposts cost nothing measurable when nobody records; no string is formatted ahead of the call.
`Signposts.stability.info(…)` lines: MetricKit payload counts (§6.2), a watchdog hang ≥ 2 s, a memory trim.

Seeing it work (acceptance): boot the stream's simulator, start
`xcrun simctl spawn <udid> log stream --style compact --type signpost --predicate 'subsystem == "<bundle id>"'`
(bundle id of the build under test), launch the app signed in to the stand-in gateway, and read in the output a
begin/end pair for `Launch`, `Restore`, `Ticket`, `Handshake`, then tap a bot and read `ChatOpen`. Save the captured
text under `docs/briefs/m9/evidence/diagnostics-signposts.txt`. (If `log stream --type signpost` prints nothing on
this runtime, record with `xcrun xctrace record --template 'Logging' --device <udid> --attach <pid> --time-limit 20s`
and export the signpost table; report which one was used.)

---

## 11. L974, L1015 — power saver (rev 2: finish on offline's service, beside settings' L785)

**Web** (`I/HermesPower.swift`, `S/power-state.ts`, `S/power-saver.css`): saver is on while Low Power Mode is on **or**
the thermal state is serious or critical. Then decoration that loops for as long as it is on screen stops (bot heads
that are not speaking, skeleton shimmer, marquees, progress slides, arc borders, the streaming code card's animation);
"Typing dots and spinners keep their smooth timing on purpose"; "The reply's text, every voice surface (a head speaking
aloud, recording dots, the voice dock, Read aloud) and approval cards are not touched"; glass keeps its blur. Optional
polls run 3× less often (`saverInterval`, `powerInterval`: re-armed when the state changes, and leaving power saving runs
the poll at once if the slower schedule left it overdue). The native side re-reads on
`NSProcessInfoPowerStateDidChange`, `thermalStateDidChangeNotification` **and `didBecomeActive`**, and publishes only
when the state changed. There is no switch and no wording.

**Who owns what.** Three rows describe one behaviour (the planner's note: L974, L1015 here, L785 in settings), and
revision 1 planned a new service. Two streams got there first:

| Part | Owner | State |
|---|---|---|
| The service and the poll rule (`PowerState`, `PowerPolls`) | offline (`docs/spec/3x-offline.md` §6.9) | on the train, unit-tested |
| 14 polls routed through it | offline | on the train |
| Heads follow heat; `HQMotion.decorativeStill`; shimmer / pulse loops stop and restart; three more timers; `ScreenPower` on the one reading; `hqn.power.toggle`; the `debug.power` probe | settings (`3x-settings.md` §3 on `m9/settings`, DECISION 3.0 "No new service and no rename") | built on `m9/settings` (`b3b1043`, `88e1112`), **not on the train yet** |
| The log event, the `didBecomeActive` re-read, the leftover audit, and the proof for L974 / L1015 | **this stream** | to do |

DECISION D-11.2: no second service, no `PowerTimer`, no rename, no new DEBUG names. Everything here is an addition to
`HermesKit/Net/PowerPolls.swift` or a call into it.

### 11.1 What this stream builds

1. **The `power` log event** (§8.4). `PowerState` gains the detail the event needs, next to `read()`:

   ```swift
   nonisolated struct PowerDetail: Sendable, Equatable { var lowPower: Bool; var thermal: String }   // nominal|fair|serious|critical
   nonisolated static func detail() -> PowerDetail
   ```

   `PerfLog.start()` records `power {lowPower, thermal}` once at launch and again from one observer of the two system
   notifications **when the detail changed** (fair → serious is a change even though `saving` stays false → true only
   once; the web logs both fields, `I/HermesPerfLog.swift:551-558`). The observer hops to the diagnostics queue, never
   to the main thread. It also writes one `AppLog.note("power", "saver on|off")` when `saving` flips.
2. **Re-read on becoming active.** `PowerState.init(observing:)` observes two notifications; the web shell observes
   three. iOS does not always post the power notification to an app that was suspended when Low Power Mode changed
   (it turns itself off at 80 % charge), so add `UIApplication.didBecomeActiveNotification` to the list (the file imports Foundation only today; add
   `import UIKit` as `HermesKit/Net/LiveGatewayClient.swift` does for its background task: observing a notification is
   not UI code). `publish()` already drops a re-read that changed nothing.
3. **A pure helper for tests**: `nonisolated static func saving(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool`
   with `read()` calling it. The settings spec asks for the same helper under the same name; whichever branch reaches
   the train second keeps the other's copy (identical signature on purpose, so the merge is a no-op).
4. **The leftover audit**, run on the tree *after* `m9/settings` is merged (or after item 6 below): 
   `grep -rn "Task.sleep\|Timer.scheduledTimer\|Timer(timeInterval\|repeatForever\|CADisplayLink\|CABasicAnimation.*repeatCount" App HermesKit`.
   Classify every hit in the report as *optional poll* (must go through `PowerPolls`), *decoration* (must check
   `HQMotion.decorativeStill` and restart on `PowerState.changed`), or *asked for / live* (untouched: send, stream,
   stop, approvals, pull to refresh, sign-in, voice, Screen and browser frames, typing dots, `GlyphSpinner`, a
   speaking head, transitions). Wire any optional poll or decoration that neither stream caught. Known candidates the
   two specs do not name: the chat status line's "Working… 12s" tick (web stretches it to 3 s,
   `S/ui-chat/turn-status-view.tsx:51`), `PresenceCenter`'s loops (`App/Presence/PresenceCenter.swift:173,230`), the groups sync and rounds loops
   (`HermesKit/Groups/GroupSync.swift:94`, `GroupRounds.swift:488`: stretch only if they are polls nobody is waiting on;
   a round in progress is live), the Talk empty-state visual when nobody is speaking, marquee titles, the
   indeterminate progress slide in `PageKit`.
5. **`grep -rn "isLowPowerModeEnabled\|thermalState" App HermesKit` shows `PowerPolls.swift` only** when this stream is
   done (the settings acceptance check 6, repeated here because L1015 is exactly "native checks … in the heads and
   stores only").
6. **If `m9/settings` is not on the train when the builder reaches this feature** (check
   `git merge-base --is-ancestor b3b1043 m9/train`): do not merge that branch (only Ship agents move work between
   streams) and do not wait. Build the decorative half here exactly as `3x-settings.md` §3 "Design" items 1–3 and 5–6
   specify on that branch (read it with `git show m9/settings:docs/spec/3x-settings.md`), with the **same names**
   (`HQMotion.decorativeStill`, `HeadMotionSettings.readStill()` reading it, observer on `PowerState.changed`,
   `hqn.power.toggle`, the `debug.power` probe), so that when the two branches meet, the Ship agent resolves every
   conflict by taking either side. Say in the report which path was taken. §19 puts power late in this stream's order
   to make the first path the likely one.

### 11.2 What must be true at the end (both rows)

| What | In saver |
|---|---|
| Optional polls (the 14 + any the audit adds) | period ×3; leaving saver with a poll overdue runs it once, at once |
| "Working… 12s" tick | every 3 s |
| Idle bot heads, skeleton shimmer and pulse, marquees, indeterminate progress slides, the streaming code block's pulse | still (skeletons draw as a flat fill, marquees rest at the start) and start again by themselves when saver ends, without reopening the screen |
| Typing dots, spinners, stream glides, send lift, a head that is speaking, voice surfaces, approval cards, every transition, the reply itself | **untouched** |
| Glass | untouched (system glass adapts by itself; never swap it for a blur) |
| The log | one `power` event per real change |

DEBUG (the simulator has neither state): `-HQDebugPowerSaving YES|NO` at launch (offline);
`xcrun simctl spawn <udid> notifyutil -p hqn.power.toggle` while running and the `debug.power` accessibility probe
(`-HQDebugExposeStatus YES`) to read it (settings). Thermal alone cannot be forced on a simulator: it is covered by the
pure helper's unit test (serious → true, critical → true, fair → false, nominal → false) and by a unit test that
`detail()` maps the four `ProcessInfo.ThermalState` cases to the four strings.

DECISION D-11.1: no user-facing switch or banner (the web has none; iOS shows the yellow battery itself). Same as
settings' DECISION 3.1.

Acceptance: §15 P1–P4.

---

## 12. L975 — memory trim

**Web** (`S/memory-trim.ts`, `S/session-cache-phone.ts`): one path for giving memory back. A memory warning empties
what can be rebuilt (every settled transcript not on screen, the query cache, prefetch, pages, previews); going to the
background trims to what a return needs (the warm transcript cache held to **4 chats or 4 MB**; "the chat on show and
its tiles are outside both").

**Native** `HermesKit/System/MemoryTrim.swift`:

```swift
nonisolated enum MemoryTrim {
    enum Reason: String, Sendable { case pressure, background }
    static func register(_ name: String, _ trim: @escaping @Sendable (Reason) -> Void)
    @MainActor static func install()     // observes the warning, the pressure source (.warning/.critical) and scene background
    static func run(_ reason: Reason)    // every registered trim, each in its own do/catch-equivalent; one failing never stops the rest
}
```

| Cache | On `pressure` | On `background` |
|---|---|---|
| `TranscriptCache` decoded entries (≤ 8 in memory today) | `trimMemory()` (drop all but visible and pending) — **wire it; today nothing calls it** | keep the 4 most recently used, or 4 MiB of decoded size, whichever is smaller; visible and pending always kept (new `trimMemory(keeping: 4, bytes: 4 << 20)`; estimate size by the stored file's byte count ×3 as the web note says parsed objects are two to four times their JSON) |
| `TextLayout.layouts` / `.markdown` | clear to the visible chat's rows | `trim(to: 2_000)` / `trim(to: 1_000)` as today (`trimForBackground`) |
| `MediaStore` decoded images, attachment thumbnails, artifact grid thumbnails, link-preview images, head images rendered at size, decoded photo faces (`BotFaces.dropDecoded()`, photoheads) | empty the in-memory layer (disk untouched) | keep what the visible screen shows |
| `ChatWarmer` | cancel the pass; skip the next one | pause (already does: `appActive = false`) |
| Pages' in-memory lists (Jobs, Kanban, Artifacts) not on screen, `HistoryFlights` | drop | drop `HistoryFlights` (already) |
| `SyntaxHighlighter` cache | empty | halve |
| Browser / bot-screen frame decoder | drop the waiting frame | — |

Each owner registers its own trim (`MemoryTrim.register("transcripts") { … }`), replacing the three private
`didReceiveMemoryWarning` observers in `TextLayout.swift:192`, `MediaStore.swift:267` and `BotFaces.swift:45`
(`PhotoFramerController.didReceiveMemoryWarning` `:152` is a view controller's own override and stays). The groups,
screen, presence and share streams added caches since revision 1: the builder greps
`grep -rn "NSCache\|\[String: UIImage\]\|\[URL: UIImage\]" App HermesKit` and registers each in-memory image or
decoded-data cache it finds, listing them in the report. A trim runs off the main
thread unless its cache is main-actor state. After a run, `PerfLog.record("mem.trim", ["why": …, "chats": dropped,
"mb": freedEstimate])` and one `AppLog.note("mem", "trim <reason>")`.

Nothing the user is looking at may change: the chat on screen keeps its rows, heights and images, and returning from
the background to a chat that was trimmed paints from disk exactly as a cold open does (no flash, no jump; the instant-
open rule of the architecture).

DEBUG (rev 2): the talk stream already has `-HQDebugMemoryWarningAfter <seconds>`
(`App/Debug/TalkDebugHooks.swift:73`), which posts `UIApplication.didReceiveMemoryWarningNotification` (a public name);
use it. For a warning *while running* (M2 opens eight chats first) add one Darwin notification next to settings'
`hqn.power.toggle` in `OfflineDebug`: `hqn.memory.warn` posts the same public notification. The Bots list's DEBUG
accessibility value gains `warm=<n>` (decoded transcripts in memory).

Acceptance: §15 M1–M4.

---

## 13. Bridge-only rows (L1004, L1005, L1006)

These three rows are calls the web page makes into its native shell. For each: what the *user* gets from it, whether
native already gives that, and what is left.

### 13.1 L1004 — image thumbnails and fetchImage / cancelImage → **web-shell-only**

`I/HermesUIPages.swift:18-39` (`imageThumbnail`): the Artifacts grid hands a data: URL across the bridge to be
downsampled off the main thread. `I/HermesPicker.swift:31-67` (`fetchImage`, `cancelImage`): the page cannot fetch a
remote https image itself (its CSP keeps `img-src` to `blob:` and `data:`), so native fetches it cookieless and hands
back base64. Both exist only because a web page cannot decode or fetch these itself. What the user gets is already
native and already ✅ in the parity doc: "Remote https images fetched natively, shown downsampled; originals fetched
only for the viewer or Save" (parity L314, `HermesKit/Net/RemoteImageFetch.swift`), "Image grid with native thumbnails
(memory-bounded cache)" (L686), and the public-host-only policy (L988, `PublicHostPolicy.swift`). There is no page to
call a bridge. **Proposed outcome: web-shell-only (—).** The stress tester still confirms the user-facing halves hold
(§16, B1).

### 13.2 L1005 — number pad accessory → **native equivalent, small build**

`I/HermesUIPages.swift:11-16`, `I/HermesViewController.swift:36-47`, `S/ui-pages/number-field.tsx`: a number field
focused in the page shows a bar over the keyboard with one "Done" button, because the number pad has no Return key
and the page could not otherwise dismiss it. The bridge call is web-shell-only; the *behaviour* is not: native has seven
number-pad fields of its own (rev 2 count, on the merged tree) and only three have a Done bar.

| Field | File (merged tree) | Done bar today |
|---|---|---|
| Config number values | `App/Settings/Config/ConfigPages.swift:263` (bar at `:269`, on the field since the talk stream's fix; second site `:295`) | yes |
| Vault "days" | `App/Settings/Config/VaultBillingPages.swift:525` (bar at `:554`) | yes |
| Card Number, Security Code | `App/Settings/Config/VaultBillingPages.swift:279,282` | **no** |
| Plugin settings, a `number` field | `App/Capabilities/PluginsSections.swift:464` (`.decimalPad`, capabilities stream) | **no** |
| Kanban task sheet number field | `App/Pages/Kanban/KanbanTaskSheet.swift:225` (UIKit) | **no** |
| Prompt sheet numeric answer | `App/Questions/PromptSheets.swift:242` (UIKit) | **no** |
| New Task priority | `App/Pages/Kanban/NewTaskSheet.swift:212` | **no** |
| The remote browser's key field | `App/Browser/BrowserKeyField.swift:60,62` (`.phonePad` / `.decimalPad` mirror the remote page's field type) | not applicable: the viewer's own bar already has "Hide Keyboard" (`BrowserViewerController.swift:575`); leave it |

The talk stream's lesson is binding (`docs/briefs/m9/talk-report.md` "Two Done buttons over the number pad"): the
keyboard toolbar goes **on the field**, never on the `Section` (a section hands its modifiers to its footer too and
the bar then shows twice). The shared modifier must be applied to the `TextField` itself, and N1 asserts exactly one
"Done" over the keyboard for every field, including after a refused value has written a footer.

Build `App/Kit/NumberPadDone.swift` (rev 2: `App/Kit/` is where shared UI helpers live now; `App/Support/` does not
exist): a SwiftUI modifier `.numberPadDone(focused:onDone:)` (the existing
`ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") … }`, one copy) and a UIKit helper
`UITextField.addNumberPadDone(target:action:)` (a system `UIToolbar` as `inputAccessoryView`, flexible space + a
`.done`-style "Done" item, sized by the system; on iOS 26 a toolbar over the keyboard takes the system's own glass, so
no custom background). Apply to every `.numberPad` / `.decimalPad` / `.phonePad` field in the app (the builder greps
again after merging the train: other m9 streams, the jobs editor in particular, add number fields). "Done" commits the
field the way leaving it does and resigns first responder. On iPad with a hardware keyboard the bar is the system's
shortcut bar; nothing custom is added there.

Outcome: the bridge method is web-shell-only; the row is reported **done** when every number pad in the app has the
Done bar and a UI test has dismissed one with it (§15 N1).

### 13.3 L1006 — keyboard state reporting → **web-shell-only for the report; one behaviour check**

`I/HermesPicker.swift:67-83`, `S/bridge/fe-convo.ts:29-49`, `B/fe-convo-gates.ts:4-7`: the page cannot tell whether a
Return keypress came from a hardware keyboard, so native reports `GCKeyboard.coalesced != nil` and the page sets a CSS
class; the composer then treats Return as "new line" from the on-screen keyboard and as "send" from a hardware one
(⌘/⌃-Return always sends). A native app needs no report: UIKit tells a `UITextView` which is which
(`pressesBegan` carries a `UIKey` only for hardware keys; `UIKeyCommand` fires only for hardware keys). **The report is
web-shell-only (—).**

The behaviour it serves must hold natively, and since the ipad stream landed it does (rev 2; revision 1 found no
hardware-key handling and planned to build it): `ComposerTextView.pressesBegan`
(`App/Chat/Attachments/ComposerTextView.swift:25-39`) reads the hardware key and asks `ReturnKey.decide(hardware:shift:
option:marked:empty:)` (`App/Root/KeyCommands.swift`, `docs/spec/3x-ipad.md` §4.10): Return sends what the Send button
would, Shift- or Option-Return breaks the line, an IME composition in progress is passed through (Return confirms the
composition), an empty field with nothing attached swallows the key. The same rule serves the Find field and the
question dock. The on-screen keyboard never produces a `UIPress` with a key, so parity L384 ("On-screen Return inserts a
line break; Send is the button") is untouched. Unit tests exist (`Tests/IPad/PaneRulesTests.swift`); no UI test drives
it yet.

DECISION D-13.3 (resolved): the ipad stream's implementation is kept; this stream builds no key handling.

What is left for this row: **N2**, a UI test on the stream's iPhone simulator (a hardware keyboard is "attached" to a
simulator whenever XCUITest types with `typeKey`): type a word, `typeKey(.return, modifierFlags: [])` → the bubble
appears and the field is empty; type two words with `typeKey(.return, modifierFlags: .shift)` between them → one field
with two lines and nothing sent; tap the on-screen Return (`app.keyboards.buttons["Return"]`) → a line break, nothing sent. If the software keyboard
does not show on the simulator, **do not** change Simulator's "Connect Hardware Keyboard" preference (it is one
setting for every simulator on this shared Mac): assert the on-screen half through the existing L384 coverage instead
and say so in the report.

Outcome: bridge report web-shell-only; the row is recorded **done** when N2 passes, else **partial** with the reason.

---

## 14. L1025 — background modes

**Web** (`I/Info.plist:69-72`): `UIBackgroundModes = [remote-notification]`; no `BGTaskScheduler`, no background
fetch. Background time is used three ways: the silent "settled" push (`I/AppDelegate.swift:36-49`), the socket grace
after leaving the app (background task "Hermes active turn"), and the perf-log upload on backgrounding
(`I/HermesPerfLog.swift:725-737`).

**Native today**: `App/Info.plist:32` has the same single mode (the file is shared by both identities:
`project.yml:72`); the silent settle push is handled (`App/AppDelegate.swift`); background tasks exist for the socket
grace ("Hermes HQ socket grace"), the cache flush ("Hermes HQ cache flush"), pages cache and attachments. The only
piece missing is the log upload's background task (§8.3 adds it: "Hermes HQ performance log").

DECISION D-14.1: nothing else is added. No `BGTaskScheduler`, no `fetch`, no `processing`, no `audio` mode from this
stream (the talk stream owns whether live voice needs `audio`; App Review rejects declared modes an app does not use).
`BGTaskSchedulerPermittedIdentifiers` must stay absent.

Rules every background task in the app must meet (the builder audits the five that exist plus the new one and fixes
any that do not): named; ended exactly once, by its owner or in the expiration handler; the expiration handler stops
the work and ends the task itself; nothing started in the background outlives it; total wall time under 25 s.

Acceptance: a unit test loads the built app's `Info.plist` (both identities: run it under `scripts/build.sh test` and
`HQ_IDENTITY=original scripts/build.sh test`) and asserts `UIBackgroundModes == ["audio", "remote-notification"]` (`audio` since 2026-10-27, for a live voice
conversation: 3x-talk-background.md) and no
`BGTaskSchedulerPermittedIdentifiers`; a UI test backgrounds the app with events pending and asserts the stand-in
gateway received an upload with `reason == "background"` within 10 s; the app log shows no
"Background Task … was created over 30 seconds ago" line after a 60 s background.

---

## 15. Stand-in gateway, commands and acceptance checks

### 15.1 `scripts/fixtures/diagnostics-gateway.py` (new; the builder writes it)

Loads `scripts/fixtures/settings-gateway.py` by path the way that file loads the reference voice fixture (sign-in,
`--hermes-cookies`, `/api/ws`, roster, sessions, prompts, jobs…), and adds:

- **The real sink**: imports `/Users/me/Projects/hermes-hq-native-ref240/gateway-plugin/hermes-hq-push/perf_logs.py`
  by path (read only; with `--log-dir` given it never touches Hermes: `log_dir()` is not called, `write(root, …)` is
  called with the folder directly) and serves `POST /api/plugins/hermes-hq-push/logs` and `/logs/moment` with it, plus
  `GET /api/plugins/hermes-hq-push/status` answering `{"version":"0.8.0","logs":true,"moments":true}` merged over what the
  settings fixture answers.
- **Updates**: `GET /api/hermes/update/check` (rejects any query key other than `force` with 422, to catch a stray
  param), `POST /api/hermes/update`, `GET /api/actions/hermes-update/status`, driven by state.
- **Controls** (loopback, no auth, never under `/api/`):
  - `GET  /__diag/state` → uploads (reason, lines, kinds, dropped), moments, update calls, socket opens/closes
  - `POST /__diag/logs {"mode":"ok"|"404"|"401"|"409"|"500"|"slow"|"hang"|"reset", "count":n, "seconds":s}`
  - `POST /__diag/update {"behind":12|0|-1|null,"can_apply":true,"message":null,"install_method":"git","commits":[…],"checked_at":null,"fail":"timeout"|"500"|null}`
  - `POST /__diag/update-run {"outcome":"success"|"failed"|"refused"|"partial","seconds":6,"restart_after":3,"down_for":5,"never_returns":false,"update_command":"hermes update"}`
    (`restart_after`: the fixture closes its listening socket and every WebSocket for `down_for` seconds, then listens
    again on the same port, to play the gateway restarting)
  - `GET /__diag/state` also carries `"hits": {"<METHOD path>": [epoch seconds, …]}` (the last 200 per route) so a test
    can measure the gap between polls (P2); the settings stream adds the same map to its own fixture under
    `/__settings/state`, which this fixture inherits when that branch is on the train: then expose that one and add
    nothing
  - `POST /__diag/drop-socket {"code":1012,"count":1,"every":0}` · `POST /__diag/refuse-tickets {"count":n}`
  - `POST /__diag/fail {"route":"GET /api/cron/jobs","mode":"bad-json"|"500"|"slow","count":1}`
  - `POST /__diag/prompt {"kind":"approval"|"clarify"|"sudo"|"secret","hold":3}` (raise a server request, resolve it after `hold` s)
  - `POST /__diag/reset`

Start (builders; A on 10070, a second gateway B on 10071 when a test needs two):

```
cd /Users/me/Projects/hermes-hq-native-wt/m9-diagnostics
mkdir -p build/fixtures && chmod 700 build/fixtures
python3 scripts/fixtures/diagnostics-gateway.py --port 10070 --hermes-cookies \
  --credentials build/fixtures/diag-a.json --log-dir build/fixtures/hq-logs-a > build/fixtures/diag-a.log 2>&1 &
```

Stress tester: the same with `--port 10075` (and 10076…), `build/fixtures/diag-s.json`, `--log-dir build/fixtures/hq-logs-s`.
Before starting, check the port is free (`lsof -nP -iTCP:<port> -sTCP:LISTEN`) and never connect to a port you did not
start. Stop the fixture by its own pid when the stage ends.

### 15.2 Simulator and runs

```
xcrun simctl list devices | grep -q "HQN-m9-diagnostics (" || \
  xcrun simctl create "HQN-m9-diagnostics" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0
UDID=$(xcrun simctl list devices | grep "HQN-m9-diagnostics (" | grep -oE '[0-9A-F-]{36}' | head -1)
scripts/build.sh test $UDID                                         # unit tests (native identity)
HQ_IDENTITY=original scripts/build.sh test $UDID                    # and the shipped identity
HQN_DIAG_PORTS="10070 10071" HQN_DD=build/dd scripts/e2e-diagnostics.sh $UDID   # UITests/diagnostics
xcrun simctl shutdown $UDID                                         # when the stage ends
```

`scripts/e2e-diagnostics.sh` follows `scripts/e2e-settings.sh` (ports from `HQN_DIAG_PORTS`, credentials to the runner
as `TEST_RUNNER_HQN_DIAG_A`, shots to `TEST_RUNNER_HQN_SHOTS`, `-parallel-testing-enabled NO`, summary through
`scripts/e2e-summary.py`). The existing `testG9_ResumeSessionsDiagnosticsAndJankyMark`
(`UITests/settings/SettingsPagesEndToEndTests.swift:326`) must keep passing; update its expectations where wording
changed (D-3.2) rather than loosening them.

### 15.3 Acceptance checks (each is a test or a looked-at screenshot; ids are used in the rows file and the report)

**Diagnostics page**
- D1 All sections in order with the headers of §2; screenshot at default size, light and dark.
- D2 Gateway: address is the fixture's host:port; after `drop-socket` ×2 "Reconnects since launch" is 2 and Recent
  reconnects has two rows "Connected in N ms" with times; after `refuse-tickets {count:1}` a row
  "Failed: no connection ticket after …".
- D3 Background 5 s and return twice → "Returns to the app" starts "2"; "Last return" is "Connection kept" (within the
  grace) or "Connected in N ms" (after a drop while away).
- D4 Startup shows App ready, App launch, Saved sign-in restore, Connection ticket, Connection handshake with numbers.
- D5 `-HQDebugFieldFixture week` → Field metrics rows, seven kept days, three reports; unit tests for every row
  function with the web's vectors.
- D6 Errors: ×5 fold, time, "Before the last launch" after a relaunch with " · on <screen>" (§3).
- D7 Copy: text shape, "Copied" 2 s, back to "Copy Diagnostics" (§4); the copied text contains none of the planted
  secrets (a planted error `"POST https://x.example/a?ticket=abc123DEF456ghi789JKL012 Authorization: Bearer sk-live-…"`
  is stored, shown and copied as redacted).
- D8 Redactor vectors + idempotence + linear time (§5).
- D9 Screen fault row and `page.crash` in the sink (§7), real bad-json case included.

**Performance log**
- L1 Ring unit tests: 2 MB cap drops the oldest segment; a 3-day-old segment goes; the cursor survives a relaunch; a
  cursor whose segment is gone reads `lost == true`; batches are whole lines ≤ 96 KB.
- L2 Policy unit tests: blocked names dropped, 16-field cap, 120-character strings, queries cut, numbers to 0.1, bad
  kinds refused, templates (`/api/sessions/20261008_x/messages?limit=1` → `/api/sessions/:id/messages`), retry delays
  (30 s, 60 s … 1800 s; 404 → 21600 s; 401/403 → 1800 s).
- L3 Sink round trip (§8.6): sent lines == written lines, `dropped == 0`, `hq-logs.py` reads the folder.
- L4 Sources, one check each: `main.hang` (DEBUG `-HQDebugBlockMain 600` blocks main 600 ms once → an event with
  `ms` between 350 and 900); `scroll.jump` (DEBUG hook moves the chat's offset by 300 pt with no touch → one event with
  `dy` ≈ ±300 and a `hint`; a finger scroll of the same distance → none; following the bottom while a reply streams →
  none); `prompt` shown/gone with `ms` ≈ the fixture's `hold`; `motion.native` for `chat.open` and a sheet with `n > 0`
  and `hz` ≥ 50; `sock.open`/`sock.opened`/`sock.end` with `how: "closed"`, `code: 1012` after `drop-socket`; `gw.conn`
  states in order.
- L5 Switch off: no file under `perflog/`, no upload for 10 s of activity, meters stopped (no display link, no watchdog
  timer: assert through a DEBUG counter); on again → `log.on` is the first event.
- L6 Failures: `logs 404` → "Not sent: this gateway’s Hermes HQ plugin is missing or too old to keep logs." and no retry
  for 6 h (inject the clock in a unit test); `500` ×3 → 30/60/120 s; `hang` → the upload times out and nothing is lost
  (pending bytes unchanged, next upload sends the same lines once); no duplicate lines after background + foreground
  uploads race (the web's crashes #12).
- L7 Mark a Janky Moment → `mark` event uploaded with `reason: "mark"` within 3 s and a moment file with `nodes > 0`,
  `frames` allowed empty, and **no string in the bundle that is not a class or identifier name** (the test seeds a chat
  with a known sentence and greps the bundle for any word of it).

**Updates**
- U1 Opening About forces one check (`force=true` seen once); reopening within 30 min sends none; a failed check does
  not count.
- U2 `behind 0` → "Your gateway is running the latest Hermes." + "Last checked just now".
- U3 `behind 12` + commits → "A new update is ready (12 changes included)." + three buttons; What's New lists the
  filtered, grouped notes; chores are absent.
- U4 `behind -1`, no commits → "A new update is ready." and no "What's New".
- U5 `can_apply false` + message → the message, no buttons.
- U6 Failures: each of the four families shows its line and detail; Diagnostics shows "Update check"; an unreached
  check runs again by itself when the gateway returns.
- U7 Link down → "Connect to your gateway to check for or install updates.", buttons disabled.
- U8 Update Now… → the alert with the host in the title (and the generic title for `127.0.0.1`), "Not Now" sends
  nothing (fixture saw no POST), "Update Gateway" → stages through a played restart → "Update complete" → card up to
  date. `failed`, `refused` (with and without a command) and `never_returns` each end in their own wording.
- U9 Unit tests: every case of `S/ios-update-status.test.ts`.

**Signposts**: S1 the captured `log stream` text shows the intervals of §10.

**Power** (rev 2): P1 unit tests: `PowerState.saving(lowPower:thermal:)` over all eight combinations; `detail()`'s four
thermal strings; the `power` event is recorded once per change of detail and not at all for a republish with nothing
changed (drive a test instance through `override` and an injected detail reader); offline's `PowerPolls` tests still
pass untouched. P2 `-HQDebugPowerSaving YES` against the fixture: the gaps between roster reads in
`GET /__diag/state` are ≥ 3× those with `NO` (2 minutes each); an idle head is still and a skeleton does not pulse (two
screenshots 2 s apart are pixel-identical in those regions, looked at); typing dots and a spinner still move (two
screenshots differ there). P3 `notifyutil -p hqn.power.toggle` while the Bots list shows: `debug.power` flips, the
cadence changes without a relaunch, loops stop and start again by themselves, the sink holds exactly one `power`
event per flip. P4 the two greps of §11.1 items 4 and 5: no direct `ProcessInfo` power read outside `PowerPolls.swift`,
and every repeating timer classified in the report.

**Memory**: M1 unit test: `TranscriptCache.trimMemory(keeping:bytes:)` keeps visible + pending + newest 4 / 4 MiB.
M2 open 8 chats, send the DEBUG memory warning → `warm` drops to the visible one (or 0 on the list), a `mem.trim`
event is logged, the chat on screen did not move (motion trace shows no row movement). M3 background → `warm ≤ 4`.
M4 reopen a trimmed chat → paints from disk in the first frame (the existing first-content measure stays within its
budget).

**Shell**: N1 every number-pad field shows "Done" and it dismisses the keyboard and commits. N2 hardware Return sends,
Shift-Return breaks the line, on-screen Return still breaks the line. G1 Info.plist test (both identities) and the
background upload (§14).

---

## 16. STRESS PLAN

The stress tester works on `HQN-m9-diagnostics-s`, ports 10075–10079, its own derived data, and must leave the
fixtures stopped and the simulator shut down. For each item: what to do, what must hold. A failure is reported as a
failure with the evidence (screenshot, log excerpt, sink file).

**Load**
1. Log flood: a DEBUG hook records 200 000 events in 20 s (10 k/s) while scrolling a 500-row chat. Must hold: no
   dropped frames attributable to the log (the motion meter's own `hitch` counts with and without the flood differ by
   ≤ 1 per motion), the ring never exceeds 2 MB + one segment on disk, memory does not grow by more than 5 MB,
   `log.dropped` reports the overflow honestly.
2. Error flood: 10 000 `AppLog.error` calls with 300 distinct messages. Diagnostics opens in under 300 ms, shows 20
   folded rows, `errors.json` holds 20 entries, the page scrolls at full rate.
3. Redactor on hostile text: 64 KB of quotes, 64 KB of `a=` pairs, 10 000 nested brackets, emoji and RTL text, lone
   surrogates in a JSON-escaped string. Each returns in < 50 ms, never crashes, is idempotent.
4. Reconnect storm: `drop-socket {"every": 2, "count": 100}`. Recent reconnects stays at 12 rows, counters are exact
   (compare with the fixture's own count), the marks buffer stays bounded, the chat on screen does not jump
   (`scroll.jump` count 0), no upload is lost or duplicated (line counts in the sink equal lines recorded minus
   `log.dropped`).
5. A week of field history ×100 payloads in one delivery (unit level): seven entries kept, file under 16 KB.
6. 50 marks in 10 s: one upload at a time, every mark present once in the sink, the button never sticks on "Marked".

**Speed**
7. Launch: with the log on and a full ring (2 MB) the time to `launch.ready` is within 20 ms of the log off (10 runs
   each, median). Nothing in §1 reads a file on the main thread before the first frame (check with the main-thread
   file-I/O signpost or a DEBUG assertion).
8. Opening Diagnostics with full stores: first frame < 100 ms after the push starts; pull-to-refresh ×20 quickly: no
   duplicate sections, no flicker.
9. Copy with the largest possible report (20 + 20 errors of 300 characters, 12 reconnects, 7 days, 3 reports of 8 KB):
   under 150 ms, the main thread never blocked over 100 ms (the watchdog itself says so).
10. The watchdog costs: CPU while idle on the Bots list with the log on vs off differs by < 0.5 % (Instruments or
    `top -pid` over 60 s on the simulator; note the simulator caveat in the report).

**Bad network**
11. Sink answers 404, 401, 409, 413, 500, a 200 with garbage, a 200 after 40 s, a reset mid-body, and never answers:
    the right wait each time, no lost lines, no duplicate lines, the Diagnostics row reads the right sentence, the app
    never shows an alert.
12. Gateway offline for the whole session (fixture stopped): the ring fills to 2 MB and holds; back online → uploads
    resume in 96 KB batches, `lost: true` exactly when the oldest unsent segment was dropped.
13. Update check: timeout, 500, HTML body, `behind: "many"`, `commits` with a 10 000-character summary, a summary that is
    only backticks, 500 commits, `message` with braces and a token in it (must be redacted in Diagnostics and not shown
    on the card), a 200 with `{}`. The card always lands in one of the states of §9.3.
14. Update apply: the gateway never returns (4 min → the no-return wording, in a shortened test clock); returns but the
    status says `running` forever (6 min cap); `exit_code 1`; the POST itself times out; the user backgrounds the app
    mid-update and returns after the restart; the user switches gateway mid-update (the sheet closes, the other
    gateway's card is untouched, nothing is posted to it); double-tap on "Update Gateway" sends one POST.
15. Airplane mode while the About page is open (simulate by stopping the fixture and
    `POST /__diag/refuse-tickets`): the card goes to the link-down wording, and comes back by itself.

**Bad data**
16. Corrupt each store on disk (truncated JSON, a 5 MB file of zeros, a directory where the file should be,
    wrong types, a future build number): `errors.json`, `field-metrics.json`, `diagnostics.json`, a ring segment with
    a half line, the cursor pointing past the end, `hqn.stability` holding strings. The app launches, Diagnostics
    opens, the bad store reads as empty and is replaced on the next write, nothing crashes.
17. A MetricKit diagnostic JSON with no `callStackTree`, with 10 000 frames, with a recursive-looking tree depth of
    5 000 (the walk must be iterative or bounded, the web's is `while`): the report text stays ≤ 8 KB and 40 frames.
18. A screen fault whose message is 100 KB, contains newlines, a JWT and an email: one bounded, redacted line.
19. Perf-log fields: NaN, infinity, nested dictionaries, a 1 MB string, a key named `message`, a key with a space, a
    kind in capitals: cleaned or refused, never sent raw (assert against the sink's own `dropped` being 0, which
    proves the phone cleaned first).
20. A view tree of 20 000 views for a moment: 600 nodes, under the 8 ms budget or cut short with `truncated`, bundle
    under 200 KB.

**Interruption**
21. Kill the app (`simctl terminate`) at: mid-upload, mid-ring-write, mid-`errors.json` write, during the update
    sheet's restart stage, between `mark` and its upload. After relaunch: stores readable, no duplicate upload of the
    acknowledged batch, unsent lines sent once, the update card shows a truthful state (it re-checks; it never claims
    "installing" forever).
22. Background during an upload, at a batch boundary and mid-batch; iOS-style expiry (DEBUG hook ends the background
    task early): the cursor moves only for acknowledged batches.
23. Toggle the perf-log switch 30 times in 5 s while events are recorded from three threads: ends in the last state,
    no file left when off, no crash (run under Thread Sanitizer once).
24. Flip saver 50 times in 10 s (`notifyutil -p hqn.power.toggle` in a loop): timers end at the right period, each
    overdue poll runs once (not 50 times), heads and skeletons end in the right state, no observer leak (the count of
    `PowerState.changed` observers is the same before and after: DEBUG counter), and the sink holds one `power` event
    per real change, never a burst of duplicates. Background the app, toggle, return: the state is right on return
    (the `didBecomeActive` re-read).
25. 20 memory warnings in 5 s while a reply streams in the open chat and a memo is recording: the reply keeps
    streaming, the recording is intact, the visible rows do not move, images on screen stay.
26. iPad (the two-pane layout is on the train now; create `HQN-m9-diagnostics-s-ipad` from an iPad device type, the
    tester's own): Diagnostics, About's update section, What's New and the update sheet in both orientations, in
    Split View at the narrowest width and in Stage Manager resize, with a chat open in the detail pane behind the
    Settings sheet. Nothing clips, the copied text is the same, `ChatOpen` signposts and `motion.native chat.open`
    fire once per open in the two-pane layout (not twice, list and detail), and a hardware Return in the composer
    sends once. On the phone: a call banner while the Diagnostics page and the update sheet are open.

**Relaunch**
27. Errors, field history, reports, stability counts, the ring, the cursor and the last dated update check all
    survive a relaunch as specified; a build-number bump (install a second build with a higher number over the first)
    drops the per-build ones (errors, reports, stability) and keeps the field history ("so a tester's history
    survives an update").
28. Sign out and into the second gateway: the log goes to the new gateway only from then on (nothing queued for A is
    sent to B? — it is the same owner's phone and the web sends the ring to whichever gateway is signed in; keep that,
    and assert no credential or host of A appears in what B receives), the update card shows B's verdict, never A's.
29. First launch after upgrading from a build with `outbox.jsonl`: its lines arrive once through the ring.

**Accessibility sizes and modes**
30. Diagnostics, About's update section, What's New and the update sheet at `UICTContentSizeCategoryAccessibilityXXXL`
    and at XS: no truncated value, no overlapping label/value, every wrapping row keeps 12 pt padding, buttons stay
    ≥ 44 pt, nothing scrolls sideways. Screenshots of each, light and dark.
31. VoiceOver: every row reads "label, value"; sub-headers are headers; "Copied" is announced; the relative time is read
    in words ("3 minutes ago"), the reconnect time after its outcome; the update alert's buttons are reachable.
32. Bold Text, Increase Contrast, Reduce Transparency, Reduce Motion (heads still regardless of power), Smart Invert:
    no fake glass appears, tinted "available" text keeps 4.5:1 contrast.
33. Right-to-left pseudo-language and a 24-hour locale: times and counts format with the locale; the copied text stays
    English/ISO (it is for the developer).

**Privacy sweep (blocking)**
34. Seed chats, bot names, a file name, a search, a Wi-Fi name-like host and a token with unique canary strings, use
    every feature for five minutes with the log on, mark three moments, cause an error containing a canary, copy
    diagnostics. Then grep the sink folder (`hq-logs-s`), the moments, the copied text, `errors.json` and
    `diagnostics.json` for every canary: **zero hits**, except the gateway host in "Address" on the page and in the
    copied text (the web shows it too). Any hit blocks the build.

**Bridge-row checks**
- B1 Remote image in a chat and the Artifacts grid with 200 images: thumbnails appear, memory stays bounded, a LAN /
  loopback image URL is refused (confirms L1004's user-facing halves still hold).
- B2 Number pads: every field of §13.2 at XXXL text and with a hardware keyboard attached; exactly one "Done" each,
  also after a refused value wrote a footer under the field (the talk stream's double-Done bug must not come back).
- B3 Hardware Return while the send button is disabled, while a memo records, with marked text (IME composition:
  Return must confirm the composition, not send), held down (key repeat must send once), and in the Find field and
  the question dock (same rule, must not send the composer's draft).

**Merged-tree checks (rev 2)**
- X1 After every stage, run the train's own gates on this branch with the tester's own simulator:
  `scripts/release-check.sh <UDID>` (Release configuration, both identities: code that only exists inside
  `#if DEBUG`, such as this stream's hooks, breaks here and nowhere else), `scripts/check-ipad.py`, and the a11y
  stream's source scans (run by `scripts/e2e-a11y.sh`; read it for the unit-only entry point). New text must use
  `Font.hq`, new motion must be marked the way the scan expects, or the scan fails.
- X2 The other streams' suites that this stream's edits can break, rerun on this stream's simulator and ports only:
  offline's `PowerPolls` unit tests and `scripts/e2e-offline.sh` (the power file changes), `scripts/e2e-settings.sh`
  `testG9` (Diagnostics wording), `Tests/IPad/PaneRulesTests` (Return rule), talk's unit run `scripts/talk-unit.sh`
  (signpost subsystem string, memory warning hook), `scripts/e2e-sessions.sh` test81 (reconnect probe counters are
  read, never written, by this stream). Each script takes its ports from the environment or an argument (`HQN_SETTINGS_PORTS="10075 10076 10077"`,
  `HQN_ANY_PORT=1 HQN_OFFLINE_PORT=10075`, `scripts/e2e-sessions.sh <UDID> 10075`): use only 10075–10079, one suite
  at a time.
- X3 Siri / Share: start a chat from the Share extension and from a Siri phrase with the log on: the extension and
  intents processes write nothing into the ring (the ring belongs to the app process; assert no `perflog/` folder in
  the extension's container) and the app's log shows no canary from the shared text.

---

## 17. DECISION list (owner asleep; each can be reversed cheaply)

| Id | Decision |
|---|---|
| D-2.1 | Diagnostics stays a pushed page inside the Settings sheet (no second sheet, no "Done"). |
| D-2.2 | "Event listeners" row dropped (a web-page count); "Logs waiting to send" / "Logs last sent" kept as native rows. |
| D-2.3 | Startup shows native timings only; no "Interface load" / page-side "Sign-in restore". |
| D-2.4 | Web-view rows of Stability replaced by "Crashes caught by Hermes HQ" and "Hermes HQ stopped responding". |
| D-3.1 | "Before the last reload" reads "Before the last launch" on native. |
| D-3.2 | Empty errors wording is the web's "None since launch." |
| D-4.1 | No "Couldn’t copy — try again" state (the copy cannot fail natively). |
| D-5.1 | The on-phone app.log is not rewritten through the redactor; a static test guards the logging rule instead. |
| D-7.1 | "Page crash in X" becomes "Screen problem in <screen>: … · at A › B", reported where the app shows a fallback; perf-log kind stays `page.crash`. |
| D-8.1 | Frame times are sampled only during motions; no always-on display link. |
| D-8.2 | Upload failures are worded in the "Logs last sent" row; never an alert. |
| D-9.1 | Client card is one fixed sentence; no GitHub drift call (native has no pinned renderer). |
| D-9.2 | Manual-update line reworded to say "gateway computer", not "backend" / "server". |
| D-9.3 | The gateway update is built to parity with the web's confirm; tested only on the stand-in gateway; the Nous caution goes to the owner note. |
| D-9.4 | Update toasts and contract-skew toasts are out of this row. |
| D-10.1 | Signpost categories Launch, Session, Socket, Chat (Chat replaces the web-only Bridge / WebContent). |
| D-11.1 | Power saver stays silent (no switch, no banner). |
| D-11.2 | (rev 2) No second power service: offline's `PowerState` / `PowerPolls` are extended, settings' names are reused; revision 1's `HermesKit/System/PowerState.swift` and `PowerTimer` are dropped. |
| D-12.1 | (rev 2) The memory-warning test hooks are talk's `-HQDebugMemoryWarningAfter` plus one Darwin notification `hqn.memory.warn`; no new bundle-id-named notification. |
| D-13.3 | (rev 2, resolved) Hardware Return = send came with the ipad stream and is kept; this stream adds only the UI check. |
| D-14.1 | No new background mode, no BGTaskScheduler. |

## 18. Proposed row outcomes (for the Ship agent; this stream does not edit the parity doc)

| Row | Proposed end state | Condition |
|---|---|---|
| L901, L902, L903, L904, L906, L907 | ✅ | checks D1–D9 seen; L906 carries the device-only gap note (§6.5) |
| L908, L909, L991 | ✅ | L1–L7 |
| L992 | ✅ (client side) | L3; no plugin change needed |
| L912, L990 | ✅ | S1 + D5 |
| L974, L1015 | ✅ | P1–P4; the decorative half must be on this branch (from settings via the train, or built here under the same names, §11.1 item 6) and *seen* here, not assumed from settings' report |
| L975 | ✅ | M1–M4 |
| L980 | ✅ | U1–U9; drift fetch recorded as web-shell-only inside the row's note (D-9.1) |
| L1004 | — web-shell-only | §13.1; B1 confirms the native halves |
| L1005 | ✅ | N1 (bridge call itself web-shell-only) |
| L1006 | ✅ or 🟡 | N2 (report itself web-shell-only; the behaviour is the ipad stream's code, this stream supplies the seen-working proof) |
| L1025 | ✅ | G1 |

## 19. Build order (rev 2: closest first, one feature per TestFlight build)

The order follows §0a's ranking, adjusted for two dependencies (Copy needs the redactor; the sources need the ring).

1. **Shell rows**: the Info.plist test and background-task audit (L1025), the hardware-Return UI check (L1006), L1004
   recorded web-shell-only, number-pad Done everywhere (L1005). Small, independent, no new subsystem.
2. **Redactor, kept errors, Copy Diagnostics** (L904, L902, L903) on the existing page.
3. **Memory trim** (L975).
4. **Power saver** (L974, L1015): by now `m9/settings` is likely on the train (merge `m9/train` first and check, §11.1
   item 6).
5. **The performance log**: ring, policy, moment bundle, sink round trip (L908, L991, L992).
6. **The full Diagnostics page** (L901): timings, socket stats, returns, reconnects, stability, with the
   **signposts** (L912, L990 second half), which share `StartupTimings.measure`.
7. **MetricKit field history and iOS reports** (L906, L990 first half).
8. **Screen-problem reports** (L907), then the **perf-log sources** (L909).
9. **Update status cards** (L980): last, because it is the largest and the only feature that can change the owner's
   computer.

Before each step: `git merge m9/train` into this branch and rerun the greps this spec names (number pads, timers,
caches, power reads), because other streams keep landing.

Each step is independently shippable and leaves both `project.yml` and `project-original.yml` building
(`xcodegen generate` picks new files up by folder; no project file edits are needed unless a new framework is linked,
and none is).

---

## 20. Build pass 1: what was built and what was decided differently

The state of every row, the decisions taken while building and the test results are in
`docs/briefs/m9/diagnostics-report.md`; the per-row evidence is in `docs/briefs/m9/diagnostics-rows.md`. Where this
spec and that report differ, the report describes the code: the performance log still uses `LogUploader` (no
`PerfLog` / `PerfLogRing` / `PerfLogPolicy` yet), `Signposts` has the Launch, Session and Socket categories only,
`ScreenFault` has one real call site, the update cards (§9) are not built, and the power saver's decorative half
(§11.1 item 6) was left to the settings stream as the review asked.

