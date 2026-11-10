# 1x · Pages: Jobs, Kanban, Artifacts (and the tabs that reach them)

Implementation spec for the "pages" stream of the parity round after build 2: native Jobs (cron), Kanban and Artifacts
pages, plus the tab structure that reaches them. Mapped from the web app at release-build238 and the live Hermes source.
Where the spec and the web app disagree, the web app wins (`NAT/docs/ARCHITECTURE.md:5-6`), except where a DECISION
below says why the native app does it differently.

Everything in §9 was read from source and, for the demo gateway, re-run on this Mac on 2026-10-10 on port 9736
(payloads marked "(captured)" are copied from that run; the gateway was stopped afterwards).

## 0. Conventions

### 0.1 Citation key

| Prefix | Path |
| --- | --- |
| `S/` | `/Users/me/Projects/hermes-hq-native-ref238/src/` (Hermes HQ phone code) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref238/build/` (build-time "gates": exact-string patches over the vendored renderer; they are what the phone runs) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref238/vendor/hermes/apps/desktop/src/` (vendored Hermes desktop renderer, commit `02e41181`) |
| `AG/` | `/Users/me/.hermes/hermes-agent/` (gateway source, HEAD `d94b70f`; read only, never run or imported) |
| `FX/` | `/Users/me/Projects/hermes-hq-native-ref238/scripts/` (committed fixture gateways) |
| `REF/` | `/Users/me/Projects/hermes-hq-native-ref238/` (the reference web app's repo root, for its iOS shell) |
| `DEMO` | `/Users/me/Projects/hermes-ios-release178/.build/demo/demo-gateway.py` (untracked demo gateway, the one in `MEM/cron-message-width.md` and spec 05 §A8) |
| `HO/` | `/Users/me/Projects/dispatch-handoff/design/` (`DESIGN.md`, `OWNER-DECISIONS.md`) |
| `MEM/` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` |
| `NAT/` | `/Users/me/Projects/hermes-hq-native/` (this repo) |

`file:N` is a line, `file:N-M` a range. **[gate]** marks phone behaviour that exists only because a `B/` gate rewrote
vendored code.

### 0.2 Scope of this stream

In: Jobs list + detail (schedule words, Run Now, Pause/Resume, Delete with confirmation, run history and opening a run);
Kanban (board picker, status chips, task list, task sheet, New Task, move/assign/edit/comment/archive/delete); Artifacts
(index, filters, image grid, file and link rows, open/preview, share/copy/show in chat); the tab bar entries and a
minimal More root that reach them. Out: see §8.

### 0.3 TL;DR for the builder

1. **No JSON-RPC calls.** All three pages are REST (`V/api/cron.ts`, `V/plugins/kanban/api.ts`, `V/api/sessions.ts`,
   `/api/fs/*`). The only socket traffic used is the `cron.changed` broadcast and `gateway.ready.change_events`
   (`AG/tui_gateway/contracts/events.py:741`). If anyone reaches for `cron.manage`, its params are exactly
   `action,name,include_disabled,schedule,prompt,repeat,continuity,deliver,profile`
   (`AG/tui_gateway/contracts/tools_commands.py:424-433`); Hermes rejects any other key with code 4000 (spec 04 §1.3). Don't use it;
   the web doesn't.
2. Tabs become **Bots · Sessions · Jobs · Kanban-or-Artifacts · More** (5, never 6) (`S/phone-nav.ts:87-91`).
3. Every list paints from a disk cache on its first frame, then refreshes (same rule as Bots/Sessions,
   `NAT/docs/ARCHITECTURE.md:21`).
4. Writes are optimistic where the web's are (Kanban), confirmed where the web confirms (Run Now, Delete), and refused
   with a notice when `AppModel.readOnlyGateway` is on (`NAT/App/AppModel.swift:11-13`).
5. Test only against stand-ins on ports **9735–9737** (§9). The new stateful fixture `NAT/scripts/pages-fixture-gateway.py`
   (§9.3) is part of this stream's work; the demo gateway is read-only and its `GET /api/cron/jobs/<id>` is broken
   (answers `{"runs": []}`, captured), so it can't exercise the Jobs detail.

### 0.4 Decisions taken in this spec (owner can't be asked mid-build; each has a default)

| # | Decision | Why |
|---|---|---|
| D-P1 | Five tabs in the web's order; Kanban takes Artifacts' slot when it is on, and Artifacts becomes More › Workspace › Artifacts | `S/phone-nav.ts:87-91`, `S/phone-tab-bar.tsx:898-928`; owner chose "Replace Artifacts tab" (`MEM/kanban-phone.md`) |
| D-P2 | Kanban is **on** when the gateway's Kanban API answers and any board holds a task (rule §4.2), not by a Capabilities switch | the web's switch is a device-local opt-in (`V/plugins/kanban/plugin.tsx:85` `defaultEnabled: false`; `V/contrib/plugins-store.ts:34-66`) on a page this round doesn't build; the owner's switch is on and they have 9 boards (`MEM/kanban-phone.md`). A device-local override key is reserved for the Settings stream |
| D-P3 | No "Simple mode": Jobs and the Artifacts/Kanban tab always show | Simple hides them (`S/phone-nav.ts:88-90`); the default is Advanced (`V/store/interface-mode.ts:42`); Settings is another stream |
| D-P4 | One device-local **scope** (All Bots or one bot) per account, shared by Jobs and Artifacts; default All Bots | the web's pages follow the app's one profile scope (`S/phone-profile-scope.tsx:43-57`) |
| D-P5 | **New Job / Edit Job are not built this round**, and no control for them is shown | not in this round's scope; dead controls are hidden, never shown disabled (`MEM/glitch-sweep.md`) |
| D-P6 | Run Now gives up waiting after **120 s** and says it is still running; it is never reported as failed for that | the gateway answers only when the job finishes (`V/api/cron.ts:19-23`); `NAT` REST caps a request at 120 s (`NAT/HermesKit/Net/LiveGatewayClient.swift:81-85`); the run continues server-side (threadpool, `AG/hermes_cli/web_server_cron.py:225-233`) |
| D-P7 | Kanban refreshes by polling (30 s on screen) plus a read after each write; no `/events` socket | the web phone never opened that socket either: its native bridge allows only browser-plugin sockets (`REF/ios/App/Shared/HermesTransportShared.swift:10-14`), so it relied on refetch timers (`S/ui-kanban/board-page.tsx:59`, `S/ui-kanban/task-sheet.tsx:74`) |
| D-P8 | HTML files open in Quick Look (Preview) with the source in the native text viewer (Source); no `WKWebView` | Quick Look renders HTML out of process; linking WebKit would cost launch time (`NAT/docs/ARCHITECTURE.md:78-80`) |
| D-P9 | Files over 32 MiB say "too large to open on your phone" | `NAT` REST ceiling (`NAT/HermesKit/Net/GatewayAddress.swift:185-188`); a streaming download API is a contract change for a later round |
| D-P10 | Job rows get 12 pt vertical padding (web: 6 pt + 56 pt minimum) | owner rule for wrapping rows (`MEM/row-padding-feedback.md`); same call spec 06 §6.4 made for Sessions |
| D-P11 | Page search is the bar's magnifier (iOS 26 `searchBarPlacement = .integratedButton`), on all three pages | owner: the search box "takes up so much space" (`MEM/search-magnifier.md`); owner 2026-10-10: the header already sits too low. The web kept Kanban's field in its board row (`MEM/search-magnifier.md`, "Left alone on purpose"), which costs a row here |
| D-P12 | No ×N repeat badge on artifact rows | unreachable on the web: `uniqueArtifacts` (`S/ui-pages/artifacts-model.ts:4-11`, applied at `B/r22-nav-gates.ts:62-63`) removes every duplicate `collapseRepeats` (`S/ui-pages/artifact-list.tsx:35-43`) would count |

---

## 1. Navigation

### 1.1 Tabs

| Index | Tab | Title | Icon (native) | Web |
|---|---|---|---|---|
| 0 | Bots | Bots | existing `TabIcons.bot` | `S/phone-tab-bar.tsx:76` |
| 1 | Sessions | Sessions | `bubble.left.and.bubble.right` (existing) | `:76` |
| 2 | **Jobs** | Jobs | SF `calendar.badge.clock` (lucide `CalendarClock`) | `:76` |
| 3 | **Kanban** or **Artifacts** | Kanban / Artifacts | Kanban: lucide `square-kanban` drawn as a template image the way `TabIcons.bot` is (`NAT/App/Root/MainTabController.swift:86-104`): `rect 3,3 18×18 rx 2`, `M8 7v7`, `M12 7v4`, `M16 7v9`. Artifacts: SF `photo.on.rectangle` (lucide `Images`) | `:77` |
| 4 | **More** | More | SF `ellipsis` (lucide `Ellipsis`) | `:77` |

- At most five view controllers, so UIKit never adds its own "More" overflow (four while More has no rows, §1.2).
- No badges on Jobs, Kanban, Artifacts (the web badges only Bots and Sessions, `S/phone-tab-bar.tsx:465-468`).
- `MainTabController` edits stay additive (coordination rule from the task). The only lines that change:
  ```swift
  // init, after `sessions` is built:
  pages = PagesTabs(services: services, makeChat: makeChat, host: self)   // new stored property
  viewControllers = [bots, sessions] + pages.tabs                           // was [bots, sessions]
  ```
  `reportShownTab()` keeps `selectedIndex == 1` (Sessions stays index 1); `updateBadges()` keeps indices 0 and 1.
  `PagesTabs` (new file `App/Pages/PagesTabs.swift`) owns tabs 2–4, the Kanban/Artifacts swap (§4.2) and the More root.
  It calls `host.setViewControllers(_:animated: false)` itself when tab 3 swaps.
- Each tab is its own `UINavigationController` (same `navigation(_:)` helper settings as Bots/Sessions:
  `prefersLargeTitles = true`, root `largeTitleDisplayMode = .inline`, `ListBarAppearance.apply`)
  (`NAT/App/Root/MainTabController.swift:48-52`, `NAT/App/Sessions/SessionsViewController.swift:33-35,48`).
- **Header position (owner, 2026-10-10: "The header (where it says Bots) is too far from the top of the screen…
  on both pages").** The pages must use whatever title treatment the Bots/Sessions fix lands with (another stream owns
  that fix). Don't invent a third header: share one helper. Acceptance check P-NAV-5 compares title positions.

### 1.2 More root (minimal, this round)

The web's More is a grouped list (`S/ui-nav/more-model.ts:10-19`): Settings alone, then Bots (Bot Profiles,
Capabilities, Messaging), Workspace (Files, Review, plugin pages, Artifacts), Insights, Integrations; the gateway card
sits on top (`S/ui-nav/more-account.tsx`). This round builds only the rows that work natively, in that order:

- **Gateway card** and **Settings** (own group): push the screens the Settings stream exposes,
  `SettingsScreens.makeSettings(services:)` (`docs/spec/1x-settings.md` §3.1, which plans for "a More tab (if another
  stream adds one…)"). That stream also turns the Bots bar's Account button into Settings and retires
  `AccountViewController`; don't duplicate its rows here. If `SettingsScreens` hasn't landed when this ships, show the
  Settings row only once it exists (no dead row, `MEM/glitch-sweep.md`).
- **Bots › Capabilities**: push `SettingsScreens.makeCapabilities(services:profile:tab:)` when present (same rule).
- **Workspace › Artifacts** (icon tile `#ff375f` with `photo.on.rectangle`, `S/phone-tab-bar.tsx:899`) while Kanban
  holds tab 3.
- **Workspace › Kanban** (tile `#ff9f0a`, `square-kanban` glyph, `S/phone-tab-bar.tsx:927`) only in the "API present,
  no tasks yet" case of §4.2 (the web lists contributed plugin pages there, `S/phone-tab-bar.tsx:924-928`).
- Rows: `UICollectionView` `.insetGrouped`, 29 pt rounded-square icon tile, Body title, chevron; Title Case labels
  (`S/ui-nav/more-model.ts:3-4,31-32`). Pushed pages keep the tab bar (§1.3.1).
- Expose `PagesTabs.registerMoreSection(_:)` (id, header, rows) so the Settings/Capabilities streams (and later Files,
  Messaging, Status & Maintenance…) add rows without editing this file. Section order follows `moreSections`
  (`S/ui-nav/more-model.ts:12-17`). The More tab is added only when it has at least one row (an empty tab is a dead
  control); with Settings landing in the same round it is normally always there, and with Kanban on it always has
  Artifacts.

### 1.3 Tab behaviour rules (owner-approved history)

1. **Tapping a tab shows that tab's own stack, with the tab bar visible.** Re-tapping the selected tab pops to its root
   (UIKit default). Never present a More page over another tab's stack. This is the bug the owner hit on the web:
   "going to the More page takes me to the capabilities page… back goes to the bots page. i cannot access the settings
   pages" (`MEM/more-tab-restore-fix.md`).
2. A chat opened from Jobs (a run), Artifacts (Show in Chat) or Kanban is pushed on **that tab's** navigation stack with
   the same `makeChat` the lists use; Back returns to the page. (The web treats Jobs/Artifacts/Kanban as tab roots a
   conversation returns to, `S/phone-nav.ts:85`, `S/phone-tab-bar.tsx:573`.)
3. Cold launch restores the last selected tab among 0–4 (device-local, per account). The web restores Jobs/Artifacts
   (`S/phone-tab-bar.tsx:630-633`) but not Kanban, a gap the owner's notes list ("cold start doesn't reopen the Kanban
   tab", `MEM/kanban-phone.md`); native closes it. If the saved tab is 3 and the tab's kind changed (Kanban ↔ Artifacts),
   open tab 3 as it now is.
4. Never use `UITabBarController.bottomAccessory` (owner rejected the accessory bubble: it "covered the list",
   `MEM/liquid-glass-more.md`). Keep `tabBarMinimizeBehavior = .never` (`NAT/App/Root/MainTabController.swift:29-30`).

---

## 2. Shared infrastructure

### 2.1 Contract addition (integration)

Pages need the signed-in client. Add, in a new file `App/Pages/PagesServices.swift` (not `Contracts.swift`, which
changes only in integration; integration may move it there):

```swift
/// What the pages (Jobs, Kanban, Artifacts) need from the app. AppModel adopts it; tests use fakes.
protocol PagesServices: AnyObject {
    var account: GatewayAccount? { get }
    var gateway: (any GatewayClient)? { get }      // AppModel: `client`
    var bots: [Bot] { get }                         // scope pill, faces, profile names
    var readOnlyGateway: Bool { get }
    func chat(for session: SessionSummary) -> ChatSessionModel   // opening a run or an artifact's chat
    /// Called by `signOut()` before caches are forgotten.
    var onSignOutPages: (() -> Void)? { get set }
}
```

`MainTabController` passes `services as? PagesServices`; when nil (previews/tests) the pages show their empty state.
Sign-out must also delete the pages' caches (§2.5) next to `bots?.removeCachedData()` (`NAT/App/AppModel.swift:117-127`).

### 2.2 REST conventions for these pages

- Use `GatewayClient.rest(method, path, query:, body:)` (`NAT/HermesKit/Contracts.swift:118-121`). JSON bodies are
  `JSONEncoder` output with `Content-Type: application/json` (already set, `LiveGatewayClient.swift:88`).
- The web shim adds `?profile=<owner>` to every `/api/…` path without one (spec 02 §0.3); here every call names its
  `profile` explicitly where §3–§5 say so, and never otherwise.
- Errors: `HTTPError(status, body)` for non-2xx; read FastAPI's `{"detail": "…"}` from `body` for the user-facing reason
  (the web's `errText`, `V/plugins/kanban/ui.tsx:61-74`). A `detail` that is an object (cron 424 envelope,
  `AG/hermes_cli/web_server_cron.py:236-241`) shows its `message` key, else "The gateway couldn't do that."
  Transport failures (`GatewayFailure`) show their own `LocalizedError` text; a raw URLSession error (the gateway's
  computer asleep, Tailscale off) maps through `GatewayFailure.transport` ("Can’t reach your gateway. …"), never the
  refusal line (verify round 2). With one saved gateway the page tabs carry the link's "Offline" / "Reconnecting…"
  under their titles as Bots and Sessions do (with two or more the gateway switcher's subtitle leads with it).
- Decode leniently with `JSONValue` (unknown keys ignored, every documented key optional) as spec 02 §0.2 requires.

### 2.3 Scope pill (Jobs, Artifacts)

- Shown only with ≥ 2 bots (`S/phone-profile-scope.tsx:15-19,49`). A capsule button in the page's subtitle row:
  "All Bots ⌄" or the bot's name ⌄; tapping opens a `UIMenu` (single selection): All Bots, then bots with the default
  first, then roster order (`S/phone-profile-scope.tsx:40-41`).
- Subtitle row = pill + " · " + count ("31 Jobs", "71 Items"; while searching "3 of 31 Jobs") (`B/ui-pages-gates.ts:192`,
  `B/stress-c-gates.ts:100`). A count not loaded yet keeps its width (`S/ui-pages/list-states.tsx:61-64`).
- Value persisted per account (`UserDefaults` key `pages.scope.<account.id>`), `"all"` or a profile name; a name that
  left the roster reads as All.

### 2.4 Page states (one look for all three pages)

From `S/ui-pages/list-states.tsx:1-64` **[gate]** `B/r21-pages-gates.ts:9-41,121-127`:

| State | Look |
|---|---|
| Loading with nothing cached | nothing for **400 ms**, then skeleton rows shaped like the page's rows (title bar + shorter subtitle bar; a leading tile on Artifacts) |
| Load failed, nothing cached | `UIContentUnavailableConfiguration`: title "Couldn't Load Jobs" / "Couldn't Load Artifacts" / "Couldn't Load the Board", the reason in words, buttons **Try Again** and **Copy Details** (copies title + reason; strip tokens/cookies) |
| Load failed with a cache | keep the cached rows; one glass notice under the bar for 3 s ("Couldn't refresh. Showing what was saved.") |
| Empty | content-unavailable with an SF symbol, a Title Case title and one sentence (texts in §3.6, §4.9, §5.7) |
| Search miss | "No Results for “<words>”" + "Check the spelling, or try another word." |

### 2.5 Caches (instant paint)

`Application Support/pages/<account key>/`:
- `jobs-<scope>.json`: last list answer + `at` (ms).
- `kanban-boards.json`, `kanban-board-<slug or _current>.json`: last snapshot.
- `artifacts-index.json`: §5.3.
Writes debounced off-main (like `TranscriptCache`). All removed on sign-out (§2.1).

### 2.6 Notices, alerts, haptics

- **HUD** for a result out of sight ("Run Started"): a native-glass capsule (`UIGlassEffect`, like `ChatNoticeToast`,
  `NAT/App/Chat/ChatChrome.swift:313-360`), centred above the tab bar, 1.5 s. The web: `jobDone` → HUD
  (`S/ui-pages/page-notices.ts:6-9`; `B/r21-pages-gates.ts:44-48`).
- **Undo pill** for an archive (§4.5): same glass capsule with an "Undo" button, 4 s (8 s at accessibility sizes)
  (`S/ui-pages/page-notices.ts:11-14`). Never a tab-bar accessory (§1.3.4).
- **Alerts** for a failed job action: title "Couldn't Pause Job" / "Couldn't Resume Job" / "Couldn't Run Job" /
  "Couldn't Delete Job", message = reason, buttons **Try Again** and OK (`S/ui-pages/jobs.ts:35-45`). Try Again on a run
  asks "Run … Now?" again (`S/ui-pages/jobs.ts:41-45`).
- **Haptics** (`MEM/taptic-feedback-gaps.md`): selection on a chip, scope or board pick; success after a confirmed write
  (Kanban move/assign/delete, job pause/resume/delete); error on a failed write (`S/ui-kanban/board-page.tsx:101,106`).
  Archive stays silent (its Undo pill is the feedback, `MEM/taptic-feedback-gaps.md`).

### 2.7 Read-only gateway

When `readOnlyGateway` is true every write in this spec is refused before any request with the glass notice
"Changes are off for this gateway." (same switch the stores honour, `NAT/App/AppModel.swift:11-13`).

### 2.8 Glass and rows

Only system glass: bar items, `UIButton.Configuration.glass()` for the Jobs detail tiles and the Kanban empty-state
button, system sheets and menus (`NAT/docs/ARCHITECTURE.md:54`; owner on the CSS fake: "It isn't Liquid Glass. So much
of this is wrong." `MEM/liquid-glass.md`). List rows, chips and cards are ordinary filled surfaces, not glass.
Rows that can wrap get 12–14 pt vertical padding (`MEM/row-padding-feedback.md`). Trailing row actions use the
horizontal "⋯" (SF `ellipsis`) in a 44 pt button (owner decision 4, `HO/OWNER-DECISIONS.md:10`; glyph per spec 06 §6.1).

---

## 3. Jobs

### 3.1 Wire

All routes from `AG/hermes_cli/web_routers/cron.py:668-736`; client shapes `V/api/cron.ts:30-136`. Per-job calls name
the job's **owner** profile (`job.profile`): the server treats `profile` as a hint and falls back to a search
(`AG/hermes_cli/web_routers/cron.py:79-105`), so the owner avoids a cross-profile scan.

| Purpose | Request | Answer |
|---|---|---|
| List | `GET /api/cron/jobs?profile=all` (scope All) or `?profile=<name>`; timeout 60 s (`V/api/client.ts:17`, `V/api/cron.ts:30-39`) | JSON **array** of jobs. "all" de-duplicates by id, preferring the default profile's copy (`cron.py:114-154`) |
| One job | `GET /api/cron/jobs/<id>?profile=<owner>` | job, or 404 `{"detail":"Job not found"}` (`cron.py:48-49,157-158`) |
| Runs | `GET /api/cron/jobs/<id>/runs?limit=20&profile=<owner>` (`V/api/cron.ts:49-54`; limit clamped 1–100, `cron.py:530-533`) | `{"runs":[…],"limit":20}` newest first (`cron.py:553`) |
| Pause | `POST /api/cron/jobs/<id>/pause?profile=<owner>`, no body | the job (`cron.py:621-622,719-721`) |
| Resume | `POST /api/cron/jobs/<id>/resume?profile=<owner>`, no body | the job (`cron.py:625-626,724-726`) |
| Run now | `POST /api/cron/jobs/<id>/trigger?profile=<owner>`, no body; **answers when the run finishes** (`V/api/cron.ts:19-23,119-127`) | the refreshed job; `409 {"detail":"Job is already running or was claimed by another scheduler"}`; a finished one-shot that removed itself answers `{…job,"enabled":false,"state":"completed"}` (`cron.py:629-648`) |
| Delete | `DELETE /api/cron/jobs/<id>?profile=<owner>` | `{"ok":true}`; 404 when gone; 400 with a reason (`cron.py:651-659`) |

Out this round (D-P5): `POST /api/cron/jobs`, `PUT /api/cron/jobs/<id>` (body `{"updates":{…}}`, `V/api/cron.ts:91-99`),
`GET /api/cron/delivery-targets`, `GET /api/cron/blueprints`, `POST /api/cron/blueprints/instantiate`.

**Job record** (normalised by `AG/cron/jobs.py:507-528`, annotated by `AG/hermes_cli/web_server_cron.py:127-139`):

```json
{"id":"a1b2c3","name":"alex-midday-filtered-alert","prompt":"…","skills":[],"script":null,"no_agent":false,
 "schedule":{"kind":"cron","expr":"0 13 * * 1-5","display":"0 13 * * 1-5"},
 "schedule_display":"0 13 * * 1-5","enabled":true,"state":"scheduled",
 "next_run_at":"2026-10-12T13:00:00-05:00","last_run_at":"2026-10-09T13:00:04-05:00",
 "last_status":"ok","last_error":null,"deliver":"origin",
 "origin":{"platform":"telegram","chat_id":"100000001","chat_name":"Alex Rivera","thread_id":null},
 "model":null,"provider":null,
 "profile":"inbox","profile_name":"inbox","hermes_home":"/Users/x/.hermes/profiles/inbox",
 "is_default_profile":false,"scheduler_heartbeat_age_s":12.4}
```

- `schedule.kind` ∈ `cron` (`expr`, `display`), `interval` (`minutes`, `display:"every 30m"`), `once` (`run_at` ISO,
  `display:"once at 2026-09-30 09:00"` or `"once in 2h"`) (`AG/cron/jobs.py:780-849`).
- `state` is derived from `enabled`: `completed`/`error` kept; disabled → `paused` (or the stored word); enabled never
  reads `paused` (`AG/cron/jobs.py:542-555`). Treat a missing `state` as the web does: `enabled == false` → `disabled`,
  else `scheduled` (`V/app/cron/job-state.ts:16-20`).
- Captured from the demo (fields it lacks — `origin`, `hermes_home`, `profile_name` — must be optional):
  ```json
  {"id":"j1","name":"Morning inbox triage","prompt":"Morning inbox triage","profile":"inbox","enabled":true,
   "state":"scheduled","schedule":{"kind":"cron","expr":"0 8 * * 1-5","display":"0 8 * * 1-5"},
   "schedule_display":"0 8 * * 1-5","next_run_at":"2026-10-12T08:00:00-05:00",
   "last_run_at":"2026-10-08T08:00:00-05:00","last_status":"ok","last_error":null,"deliver":"local",
   "model":"hermes-4","provider":"nous"}
  ```

**Run rows** (`AG/hermes_cli/web_routers/cron.py:502-581`):
- Agent runs are session rows, id `cron_<jobid>_<YYYYmmdd_HHMMSS>` (`:447`), `source:"cron"`, with `title`, `preview`,
  `message_count`, `started_at`, `last_active`, `ended_at`, `is_active` (open and active in the last 300 s),
  `scheduler_owned`, `profile` (`:542-549`).
- Script-only runs are output-document rows, `source:"cron_output"`, id `cron_output:<job>:<file stem>` (a document),
  `cron_output:<job>:exec:<n>` (a ledger attempt with no document) or `cron_output:<job>:latest`; `title` like
  `"COMPLETED · <first 180 chars>"` or `"FAILED · <error>"` (`:262-278,337-343,396-422,441-444`).

### 3.2 Identity, busy state, cache

- A job is keyed by **`<profile>|<id>`** everywhere on the phone (rows, busy map, caches). "all" de-duplicates ids
  across profiles (`AG/hermes_cli/web_routers/cron.py:119-154`) but a single profile's list and a copied `jobs.json`
  can still hold the same id twice (`:82-89`); never key by `id` alone.
- `busy: [String: Token]` per job key: a write sets its own token and only that token clears it, so a slow pause can't
  re-enable a button another action set (`V/app/cron/index.tsx:445-465`).
- The list for each scope is cached (`jobs-<scope>.json`, §2.5) and painted first; a scope switch paints that scope's
  cache (or the skeleton) and reads.
- A refresh answer for a scope that is no longer shown is dropped (`V/app/cron/cron-actions.ts:21-45`).

### 3.3 Words (port exactly; en-US formatting like `NAT/App/Root/ListTime.swift`)

Port these pure functions to `HermesKit/Pages/JobWords.swift` with their web tests as Swift Testing cases:

| Function | Source | Test oracle |
|---|---|---|
| `describeCron`, `describeSchedule`, `onceOn` | `S/audit-c-format.ts:6-86` | `S/audit-c-format.test.ts:5-24` |
| `localCronSchedule`, `jobScheduleWords` (phone's time zone vs the scheduler's) | `S/audit-c-format.ts:88-117` | `S/job-schedule-words.test.ts:14-44` |
| `jobNextWords` (+ `nextCronFire`, `skippedRuns`, `writtenOffset`, `CRON_OVERDUE_GRACE_MS = 15 min`) | `S/list-time.ts:60-173` | `S/list-time-next.test.ts:41-81` |
| `humanJobTitle`, `knownWordCasing` | `S/audit-c-format.ts:478-506` | `S/audit-c-format.test.ts:210-223` |
| `humanDeliver`, `humanDeliverTarget`, `knownChatNames`, `readableTargetName` | `S/audit-c-format.ts:197-239,323-342` | `S/audit-c-format.test.ts:44-68,123-136` |
| `runNowCopy` | `S/audit-c-format.ts:418-435` | `S/audit-c-format.test.ts:186-192` |
| `cronRunLabel`, `runPreview` | `S/audit-c-format.ts:119-162` | `S/audit-c-format.test.ts:25-34` |
| `relativeDateTime` | `S/audit-c-format.ts:306-321` | `S/audit-c-format.test.ts:111-122` |
| `jobState`, `jobTitle`, `nextRunOverdueMs` | `V/app/cron/job-state.ts:16-57` | — |
| `jobIsScriptOnly`, `jobDescription`, `lastErrorSummary` | `V/app/cron/cron-job-model.ts:6-13,105-127` | `V/app/cron/cron-job-model.test.ts` |
| `lastRunFailed` | `S/fe-pages-r4.ts:41-46` | — |
| `lastRunNote` ("Last ran today at 9:05 AM · OK") | `S/fe-lists-r3.ts:170-176`, formatter `B/ui-pages-gates.ts:191` | — |
| `jobSection` | `S/ui-pages/job-sections-model.ts:1-10` | — |

Key strings, verbatim:
- Schedules: "Weekdays at 8:15 AM", "Every 15 minutes", "Mon, Wed and Fri at 10:00 AM", "Once on Wed, Sep 30 at 9:00 AM".
- Next: "Next: Tomorrow", "Next: 11:11 PM", "in 12 min", "Due now" (inside 15 min grace), "Overdue", "Skipped until
  Mon, Oct 5"; nothing for paused/completed/disabled/one-off jobs.
- Delivery labels: `local` → "Keep in Hermes (no message)"; `origin` → "Where it was created · Telegram · Alex Rivera".
- Run Now: title `Run “<title>” Now?` (`S/ui-pages/jobs.ts:6-7`), message e.g. "It delivers to Alex Rivera on
  Telegram. Its schedule does not change." / "Its result is saved in Hermes. Its schedule does not change."

### 3.4 Jobs list

**Data.** `JobsStore` (`HermesKit/Pages/JobsStore.swift`, `@Observable`, main actor):
- Paint from `jobs-<scope>.json` at once; then `GET` (§3.1).
- Sort by title (`localeCompare` of `jobTitle`, `V/app/cron/index.tsx:401-404`) — use `localizedStandardCompare` on the
  human title.
- Search matches title, human title, prompt, schedule display, schedule expr, deliver (`V/app/cron/index.tsx:284-294`
  **[gate]** `B/r21-pages-gates.ts:70-71`), case-insensitive.

**Refresh** (spec 03 §7.7 row "Cron list", `B/fe-lists-gates.ts:223-250`):
- On `cron.changed` while Jobs (list or detail) is on screen and the app active: a `ChangeThrottle`
  (`NAT/HermesKit/Store/SessionStore.swift:52+`) with a 2 s gap (the event fires on every scheduler tick: mtime of
  `jobs.json`, spec 03 §7.7 table). Off screen: mark dirty; read once on show.
- Backstop: every 5 min on screen (30 s if `gateway.ready.change_events` is false).
- On reconnect (`gateway.ready`) when the page is on screen; on foreground; pull to refresh (`UIRefreshControl`).
- A minute clock re-renders the rows at the top of each minute ("in 12 min" → "in 11 min"), one shared timer
  (`S/ui-pages/list-states.tsx:66-94`).

**Sections** (`S/ui-pages/job-sections-model.ts:1-10`, `S/ui-pages/job-sections.tsx:13-44`):

| Order | Section | Rule (`jobSection(state, overdueMs, lastRunFailed)`) | Header |
|---|---|---|---|
| 1 | Needs Attention | `state == error` or `lastRunFailed` or `nextRunOverdueMs != nil` | red `exclamationmark.triangle.fill` + "Needs Attention" + count |
| 2 | Running | `state == running`, or a scheduled job with a run out: `latest_execution.status` is `claimed` or `running` and `last_run_at` is older than its `claimed_at` (Hermes never stores a `running` state; `H/cron/jobs.py` `list_jobs`, `H/cron/executions.py`); or a bot is still working on what the latest run handed it: the job is in the Hermes HQ add-on's `GET /api/plugins/hermes-hq-push/cron/working` (0.9.2+, read with every list read; 404 = older add-on, not asked again until a reconnect; one failed read keeps the last answer, a second clears it; the 30 s backstop runs while any job is working) | 12 pt `UIActivityIndicatorView` + "Running" + count |
| 3 | Scheduled | otherwise | "Scheduled" + count |
| 4 | Paused | `paused` or `disabled` | "Paused" + count; rows at 55 % opacity text (DESIGN "Paused (dimmed)", `HO/DESIGN.md:1137`) |
| 5 | Completed | `completed` | **folded**: a row "Show N Completed ⌄" (tint); opened, the header gets a trailing "Hide". Searching opens it. |

Classify in this precedence: completed → paused/disabled → running → needs attention → scheduled ("Explicit inactive
states win over stale next dates and errors from older runs", `S/ui-pages/job-sections-model.ts:3-9`); within a section
keep the list's title order.
`nextRunOverdueMs` uses the 15-min grace and is re-evaluated with the minute clock (`B/r21-pages-gates.ts:19`). Empty
sections are omitted. Header style: Subheadline semibold label-2, count trailing tabular, 20 pt top gap between sections
(`S/phone-ui-pages-routed.css:388-393`).

**Row** (`B/fe-pages-gates.ts:126-130` + `B/r21-pages-gates.ts:56-71`):
- Title: `humanJobTitle(jobTitle(job), knownWordCasing(all titles))`, Callout-size (16 pt) label, up to 2 lines
  (4 at accessibility sizes) (`S/phone-fe-pages-routed.css:80-85`).
- Subtitle: Footnote (13) label-2, one line (wraps at accessibility sizes):
  `[“Last run failed · ” in red when lastRunFailed] + jobScheduleWords(expr, display, run_at, next_run_at) +
  [" · " + jobNextWords(...) when non-empty]`.
- No leading dot, no trailing state word (`B/r21-pages-gates.ts:64-65`). Trailing 44 pt ⋯ button (D: owner decision 4).
- 20 pt leading inset, **12 pt** top/bottom padding (D-P10), hairline from the text's leading edge.
- Tap → push Job detail. VoiceOver label "<title>, <subtitle>", ⋯ is "Actions for <title>" (`B/r21-pages-gates.ts:68-69`).

**Row actions** (`S/ui-pages/jobs.ts:26-33`, `S/ui-pages/panel-rows.tsx:60-91`):
- Menu (⋯ and long-press `UIContextMenuConfiguration`, preview = the row): **Run Now** (`bolt`, disabled while busy),
  **Pause** (`pause`) / **Resume** (`play`), then a separate section with **Delete Job** (`trash`, destructive). No
  "Edit Job…" this round (D-P5).
- Swipes: leading **Pause/Resume** (orange, full swipe) then **Run** (tint); trailing **Delete** (red; a full swipe opens
  the confirmation and never deletes by itself) (`S/ui-pages/panel-rows.tsx:80-91`).

**Bar.** Title "Jobs"; integrated search magnifier (D-P11). No + (D-P5).

### 3.5 Job detail

Pushed page, `UICollectionView` `.insetGrouped` on the grouped background, `largeTitleDisplayMode = .never`, navigation
title empty at rest and set to the human title once the header's title scrolls under the bar. Layout from
`HO/DESIGN.md:1135-1142` and the phone gates (`B/ui-pages-gates.ts:188-193`, `B/r21-pages-gates.ts:72-74`):

1. **Header** (no group background): 28 pt bold human title (wraps); if it differs from the raw name, the raw name below
   in Footnote label-3, selectable (`B/r21-pages-gates.ts:72-74`); a status line in Subheadline: "Scheduled", "Running",
   "Paused", "Completed", "Off" (disabled), or "Last run failed" (red) (`B/fe-pages-gates.ts:127-128` vocabulary); a
   "Script" capsule when `jobIsScriptOnly`.
2. **Tiles**: two equal `UIButton.Configuration.glass()` buttons, 56 pt tall, symbol over label: **Run Now** (`bolt`),
   **Pause** (`pause`) / **Resume** (`play`). Disabled (with a small spinner in place of the symbol) while that action
   runs.
3. **Last error card** when `last_error` is set (`S/phone-fe-pages-routed.css:248-257`): rounded 14 pt, red 10 % fill, red
   text, `exclamationmark.triangle.fill`, "Last run failed: <lastErrorSummary>"; a chevron expands the full text in a
   monospaced 12 pt block; one action **Run Again** (asks like Run Now). (Edit Job is out, D-P5.)
4. **Schedule** group: "Repeats" = `jobScheduleWords`; "Next Run" = `relativeDateTime(next_run_at)` — reads **"Paused"**
   when paused (`HO/DESIGN.md:1141`), is omitted for completed/disabled (`B/fe-pages-gates.ts:124`), and is labelled
   "Overdue Since" when `nextRunOverdueMs != nil` (`V/app/cron/index.tsx:834-837`); "Last Run" = `relativeDateTime(
   last_run_at)` + " · OK/Failed"; "Model" only when the job overrides one (`V/app/cron/index.tsx:839`).
5. **Delivery** group: "Delivers To" = `humanDeliver(deliver, origin, labels, knownChatNames(all jobs))`, wrapping.
6. **Prompt** group (header "Script" when script-only with no prompt, `V/app/cron/index.tsx:863-867`): the text, at most
   6 lines with **Show All** expanding in place (`HO/DESIGN.md:1141`). Render it as Markdown with `<…>` and `&` kept
   literally (a prompt is a template: "<cwd> <title>" are placeholders, not HTML, `S/fe-pages-r6.ts:4-11`).
7. **Run History · N** group: header "Run History · N" (N = rows shown), header subtitle = `lastRunNote` with today/
   yesterday lowercased (`B/ui-pages-gates.ts:191`). Rows (§3.7). Empty: "No saved runs yet" (`B/page-gates.ts:10`);
   loading: a small spinner row.
8. **Delete Job**: its own single-row group, red Body text, leading aligned, 24 pt above (`S/phone-ui-pages-routed.css:348`,
   `B/ui-pages-gates.ts:191`).

A job that disappears (404 on refresh, or deleted elsewhere) pops the detail with the HUD "Job Removed".

### 3.6 Actions (exact sequences)

**Run Now** (`S/ui-pages/jobs.ts:10-14`, `S/cron-run-once.ts:7-57`, `V/app/cron/cron-actions.ts:84-97`):
1. Ask (`UIAlertController` `.alert`): title `Run “<human title>” Now?`, message `runNowCopy(...).description`,
   buttons Cancel and **Run** (`S/ui-pages/jobs.ts:11`). Cancel sends nothing.
2. Mark the job busy (row ⋯ Run disabled, tile spinner, row subtitle prefix "Running…" in tint).
3. `GET /api/cron/jobs/<id>?profile=<owner>` → `before`. `paused = before.enabled == false || before.state == "paused"`.
   If this GET fails, stop and report (`S/cron-run-once.test.ts:38-45`: no run when the state can't be read).
4. `POST …/trigger?profile=<owner>` with **timeout 120 s** (D-P6). Concurrently, **only if paused**: every 250 ms
   `GET …/<id>` (timeout 2 s); as soon as it reads `enabled == true && state != "paused"`, `POST …/pause` once and stop
   polling (the trigger force-resumes a paused job; pausing after its claim keeps the run but restores the pause).
   Read failures in this loop are ignored.
5. When the trigger settles and the job was paused: `POST …/pause` again; a 404 there is fine (a one-shot removed
   itself); any other failure → alert "Couldn't Restore Pause" with "Could not restore the job's paused state after
   running. Check its schedule." (`S/cron-run-once.ts:44-54`).
6. Outcome:
   - 2xx → HUD **"Run Started"** (`B/r21-pages-gates.ts:47-48`), success haptic; refresh list + runs.
   - `GatewayFailure.timeout`, HTTP 502/504/524 → HUD "Still Running on Your Gateway"; re-read the job 5 s later; the
     row keeps "Running…" until a refresh says otherwise. Not an error.
   - 409 → alert "Couldn't Run Job" with the gateway's detail ("Job is already running or was claimed by another
     scheduler").
   - other → alert "Couldn't Run Job" + Try Again (asks again, `S/ui-pages/jobs.ts:43-45`).
7. One run at a time per job (the web's trigger controller keys by `<profile>:<job id>`, `V/app/cron/index.tsx:497-539`).

**Pause / Resume** (`V/app/cron/index.tsx:467-495`): `POST …/pause` or `…/resume` (no confirmation); busy while in flight;
on success replace the job with the answer, re-section the row without a reload flash (diffable snapshot by job id),
success haptic, then refresh the list. Failure → alert "Couldn't Pause Job"/"Couldn't Resume Job"
(`B/ui-pages-gates.ts:47`) + Try Again.

**Delete** (`V/app/cron/index.tsx:541-557`, copy **[gate]** `B/chat-gates.ts:112`): action sheet anchored to the
control (alert on the detail page): title **"Delete Job?"**, message "This will remove “<human title>” permanently. It
will stop firing immediately." (`V/i18n/en.ts` `deleteDescPrefix/Suffix`), buttons **Delete Job** (destructive) and
Cancel. Delete → `DELETE`; on success remove the row (animated), pop the detail if open, success haptic; failure →
alert "Couldn't Delete Job".

**Empty texts.** No jobs: symbol `clock.arrow.circlepath`, "No Jobs", "Jobs run a prompt[ for <Bot>] on a schedule."
(the web's "Tap + to make one…" clause is dropped with the +, D-P5) (`B/r21-pages-gates.ts:40`).

### 3.7 Runs and opening a run

- Load on detail open; again on `cron.changed` when the job's `last_run_at` changed, on foreground, and every 60 s while
  the detail shows (8 s if no change events) (`V/app/cron/index.tsx:896-951`). One read per job at a time; a caller
  during a read either joins it (≤ 250 ms after it started) or gets one trailing read (`S/cron-run-once.ts:59-79`).
- Row: title = `cronRunLabel(run).title` ("Fri, Oct 3, 1:00 PM" en-US short weekday/month/day/time), detail =
  `cronRunLabel(run).detail` ("Running" / "4 messages · Weekly review sent" / "Completed" / "Failed · <reason>")
  (`S/audit-c-format.ts:144-162`). Body title, Footnote detail, 12 pt padding, chevron when it opens.
- Open:
  - `source != "cron_output"` → build `SessionSummary(id: run.id, profile: run.profile ?? job.profile, title: <human
    job title>, lastActive: run.last_active, source: "cron")` and push `makeChat(services.chat(for:))` on the Jobs stack.
  - `cron_output:<job>:<stem>` → the text viewer (§5.6) read-only on
    `<job.hermes_home or the profile's path>/cron/output/<job>/<stem>.md`, read with
    `GET /api/fs/download?path=<that path>&profile=<job.profile>` (no `session_id`; the profile is validated,
    `AG/hermes_cli/web_routers/files.py:891-904`), Back reading "<human title>" (`S/stress-c.tsx:50-68`); the text is reordered so "## Response" / "## Error" / "## Script Error" sections come
    first (`S/stress-c.tsx:25-35`).
  - `cron_output:<job>:exec:<n>` → not tappable (`S/stress-c.tsx:52,59`). `cron_output:<job>:latest` → not tappable
    either (the web's pattern would try `latest.md`, which the gateway never writes: that row is metadata only,
    `AG/hermes_cli/web_routers/cron.py:428-444`).
- **Deliveries** (`MEM/cron-message-width.md`, `MEM/delivery-row-overflow.md`). A job that delivers to a chat lands there
  as a user-role delivery bubble (spec 03 §6.5). The owner's two approved fixes apply to those bubbles wherever this
  page leads: "a bot's cron message is narrower than every other message; it should at least reach the right edge"
  (long deliveries end at the same x as bot replies) and no delivery text may run past the right edge. The chat stream
  owns the bubble; this stream's acceptance check P-JOB-12 opens a run's chat and the delivering bot's chat from Jobs
  and checks both.

---

## 4. Kanban

### 4.1 Wire

Plugin router mounted at `/api/plugins/kanban/` (`AG/plugins/kanban/dashboard/plugin_api.py:1-8`); client calls
`V/plugins/kanban/api.ts:354-518`. Every task-level call carries `?board=<slug>` when a board other than the server's
current one is selected; `''` (no param) means the server's current board (`V/plugins/kanban/api.ts:53-54,358-370`).
Each write names the board it **started** on, even if the user switches boards before it returns
(`S/ui-kanban/board-page.tsx:89-94`).

| Purpose | Request | Answer / errors |
|---|---|---|
| Boards | `GET /api/plugins/kanban/boards` | `{"boards":[{slug,name,description,is_current,total,counts:{status:n},default_workdir,default_workspace_kind,project_id,project_name}],"current":"<slug>"}` (`plugin_api.py:1411-1427`) |
| Board | `GET /api/plugins/kanban/board[?board=<slug>]` | `{"columns":[{"name":"triage","tasks":[…]},…],"tenants":[],"assignees":[…],"latest_event_id":42,"now":1791636398}`; columns in workflow order triage, todo, scheduled, ready, running, blocked, review, done (`plugin_api.py:176,289-348,359-370`; `AG/hermes_cli/kanban_workflow.py:114-124`). Done is newest-completed first (`:336-340`) |
| Task | `GET /api/plugins/kanban/tasks/<id>[?board=]` | `{"task":{…+diagnostics},"comments":[{id,author,body,created_at}],"events":[{id,kind,payload,created_at}],"attachments":[{id,task_id,filename,content_type,size,uploaded_by,stored_path,created_at}],"links":{"parents":[],"children":[]},"link_tasks":[{id,title,status}],"child_results":[…],"runs":[{id,profile,status,outcome,summary,error,started_at,ended_at}]}` (`plugin_api.py:379-411`) |
| Worker log | `GET /api/plugins/kanban/tasks/<id>/log?tail=16384[&board=]` | `{"task_id","path","exists","size_bytes","content","truncated"}` (`plugin_api.py:1255-1266`; `V/plugins/kanban/api.ts:399`) |
| Bots | `GET /api/plugins/kanban/profiles` | `{"profiles":[{name,is_default,model,provider,description,description_auto,skill_count}]}` (`plugin_api.py:1553-1563`) |
| Default bot | `GET /api/plugins/kanban/orchestration` | `{…,"default_assignee":"","resolved_default_assignee":"default",…}` (`plugin_api.py:1633-1659`); the board's fallback is `default_assignee` trimmed, `''` when unset (`V/plugins/kanban/ui.tsx:44-46`); New Task preselects `resolved_default_assignee` (`S/ui-kanban/new-task-sheet.tsx:29`) |
| Create | `POST /api/plugins/kanban/tasks[?board=]` body `{"title","body"?,"assignee"?,"priority","skills"?,"triage","goal_mode"}` (`S/ui-kanban/new-task-sheet.tsx:44-47`; model `plugin_api.py:414-432`) | `{"task":{…}\|null,"warning"?:"<dispatcher not running…>"}` (`:435-460`) |
| Move / edit | `PATCH /api/plugins/kanban/tasks/<id>[?board=]` body one of `{"status":"ready"}`, `{"status":"archived"}`, `{"priority":3}`, `{"body":"…"}`, `{"title":"…"}` (`UpdateTaskBody`, `plugin_api.py:533-551`) | `{"task":{…}}`; **400** `running` ("Cannot set status to 'running' directly; use the dispatcher/claim path", `:576,606-614`) or "unknown status: x"; **409** refused transition, e.g. `"Cannot move to 'ready': blocked by parent(s) not done — 'Cut the 2.4 branch' (t_x, status=running)"` (`:638-655`); 400 empty title (`:676-677`) |
| Delete | `DELETE /api/plugins/kanban/tasks/<id>[?board=]` | `{"deleted":true,"task_id":…}`; 404 (`:719-724`) |
| Comment | `POST …/tasks/<id>/comments[?board=]` body `{"author":"desktop","body":"…"}` (`V/plugins/kanban/api.ts:459-460`) | `{"ok":true}`; 400 empty body (`:802-809`) |
| Reassign | `POST …/tasks/<id>/reassign[?board=]` body `{"profile":"<name>","reclaim_first":true}` (`V/plugins/kanban/api.ts:462-463`) | `{"ok":true,"task_id","assignee"}`; 409 (`:1033-1063`) |
| Reclaim | `POST …/tasks/<id>/reclaim[?board=]` body `{}` | `{"ok":true}`; 409 "cannot reclaim … not in a claimable state" (`:1004-1015`) |
| Estimate | `POST …/tasks/<id>/estimate[?board=]` body `{}` (makes a model call; only on an explicit tap) | `{"ok":true,"est_tokens":42000,"complexity":"M",…}` or `{"ok":false,"reason":"…"}` (`:1077+`; `S/ui-kanban/task-sheet.tsx:191-195`) |
| Attachment | `GET /api/plugins/kanban/attachments/<attachment id>[?board=]` | the file (`FileResponse`), 404s (`:505-520`) → Quick Look |
| Nudge | `POST /api/plugins/kanban/dispatch[?board=]` body `{}`, **debounced 400 ms after any successful write** (create, patch, delete, reassign, reclaim), fire-and-forget (`V/plugins/kanban/api.ts:412-437,506`; `plugin_api.py:1269-1277`) | `{"spawned":[…],…}`; failures ignored |

Captured (demo, :9736): a blocked card on `/board`:
```json
{"id":"t_516abdd2","title":"Approve the 2.4 release notes","status":"blocked","assignee":"deploys","priority":1,
 "created_at":1791625598,"comment_count":2,"link_counts":{"parents":0,"children":0},"progress":null,
 "body":"The notes are drafted. Needs a yes, or a list of changes, before the tag goes out.","created_by":"default",
 "latest_summary":null,"result":null,"workspace_path":null,"model_override":null,"consecutive_failures":0,
 "block_kind":"needs_input","warnings":{"count":1,"highest_severity":"warning"}}
```
and its detail's diagnostics: `[{"kind":"needs_input","severity":"warning","title":"Waiting on you","detail":"The worker
asked a question it cannot answer itself.","actions":[{"kind":"unblock","label":"Unblock"}],"count":1,
"last_seen_at":1791629201,"data":{}}]`. Real cards also carry `age`, `current_run_started_at` (`plugin_api.py:181-194`),
`started_at`, `completed_at`, `workspace_kind`, `reasoning_effort`, `last_failure_error`.

Not used: the `/events` WebSocket (D-P7), boards create/rename/archive/export/import, links, bulk, specify, decompose,
orchestration writes, attachment upload, model overrides (§8).

### 4.2 Is Kanban on? (tab 3 rule, D-P2)

`KanbanAvailability` probe: `GET /api/plugins/kanban/boards` (timeout 10 s):
- 2xx and `Σ boards[].total > 0` → **on**: tab 3 = Kanban; More › Workspace › Artifacts.
- 2xx and every `total == 0` → **present, unused**: tab 3 = Artifacts; More › Workspace › Kanban.
- 404/403 (route absent or plugin gated; the hot-mount fallback answers a plain 404,
  `AG/hermes_cli/web_server_dashboard.py:937-955`) → **absent**: tab 3 = Artifacts; no Kanban anywhere.
- Transport failure → keep the last decision.

Rules: decide at launch from the cached decision (`UserDefaults` `pages.kanbanTab.<account>`), probe after sign-in /
activation and on foreground when the last probe is > 10 min old. Apply a changed decision at once if tab 3 is not
selected, else when the user leaves tab 3 (never swap the tab under the user's finger). Reserve the override key
`pages.kanbanTab.override.<account>` (`auto|on|off`) for the Settings stream (the web's switch,
`S/fe-pages-r4.ts:48-51`).

### 4.3 Board page layout (`S/ui-kanban/board-page.tsx`, `S/ui-kanban/kanban.css`)

Grouped background, 20 pt gutters (`kanban.css:3-5`):
1. **Bar**: title "Kanban"; trailing items `info.circle` ("How Kanban Works") and `plus` ("New Task")
   (`board-page.tsx:201-206`); integrated search magnifier (D-P11).
2. **Board button**: Title 3 text = `boardTitle(meta)` + tint `chevron.down` 18 pt, 44 pt tall, leading aligned
   (`kanban.css:8-12`). Disabled until boards loaded. Tap → `UIMenu` "Boards" single-select, each row title +
   subtitle "N tasks" (`board-page.tsx:208-226`); more than 8 boards → a pushed searchable list (search over 12).
   Picking the server's current board stores `''` (`board-page.tsx:215`); picking clears the search; selection haptic.
3. **Status chips**: one horizontal scroller, edge to edge, 8 pt gaps, chips 36 pt tall, 14 pt side padding,
   capsule, cell background, Subheadline semibold label, an 8 pt dot in the status tone, count in regular label-2
   tabular (`kanban.css:16-30`). Empty status: regular label-2. **Blocked** with tasks, not selected: red text and count.
   Selected: tint at 16 % fill, tint text. Order: blocked, triage, todo, scheduled, ready, running, review, done, then
   unknown statuses in server order, never `archived` (`S/ui-kanban/model.ts:21-44`). Tones (`model.ts:35-38`):
   blocked `systemRed`, triage label-3, todo label-2, scheduled `#AF52DE`, ready `systemBlue`, running `systemGreen`,
   review `systemOrange`, done label-3. Labels from `V/plugins/kanban/i18n.ts:232-242` ("Triage", "Todo", …).
4. **Task list** of the chosen status (§4.4) as an inset group (radius 26, `kanban.css:34-37`). Section header
   (Footnote label-2, 16 pt inset): "N Tasks · <help>" (`board-page.tsx:287`), except Done, which groups by when it
   finished: Today, Yesterday, This Week, then month names ("September", "June 2025") (`model.ts:72-96`).

**Chosen status**: the user's pick for this board (memory only, per board slug, survives tab switches,
`board-page.tsx:49-50,74-77`); otherwise `defaultStatus`: the first chip with tasks other than Done, then Done, then the
first chip (`model.ts:50-53`). A search that empties the picked chip drops the pick (`board-page.tsx:78`). Changing
chip or board scrolls to top (`:79`).

**Search** filters title, body and id, case-insensitive, all statuses (chip counts follow the filter)
(`model.ts:55-70`).

**How Kanban Works** sheet (`board-page.tsx:298-305`): medium detent; "You don’t run the tasks; your bots do. Put a
task in Ready with someone assigned and that bot picks it up within a minute."; each status with its dot and
`STATUS_HELP` line (`model.ts:24-33`); "Hold a task for Move To, Assign To and Delete, or swipe it."

### 4.4 Task row (`board-page.tsx:228-254`, `kanban.css:38-54`)

- 13 pt top/bottom, 16 pt sides, 14 pt gap. Leading: the assignee's head at 32 pt (the original robot heads,
  `HeadView`); none → a 32 pt dashed rounded square (1.5 pt, label-3) (`kanban.css:45`). For a Ready task with no
  assignee the board's fallback bot's head shows.
- Title: Body, up to 3 lines. Meta: Footnote label-2, bits joined by " · " (a bit that wraps starts its line without
  the dot): assignee name (or fallback for Ready, or "No One"); Blocked → `blockReason(block_kind)` red semibold
  ("Needs your input", "Waiting on another task", "Missing a tool or skill", "Will try again", "Needs you");
  Ready with no assignee and no fallback → "No one assigned, won’t run" red semibold; Running → "Running 12m";
  else the age ("4m", "3h", "2d", "5w", "4mo", "1y"; Done counts from `completed_at`); "N comments"
  (`model.ts:98-120`). Hairline from x = 62.
- Tap → task sheet (§4.6). VoiceOver: "<title>. <bits joined by commas>".
- **Hold** (`UIContextMenuConfiguration`, `board-page.tsx:151-178`): [quick move: "Unblock" (`play`) for blocked,
  "Ready" (`arrow.clockwise`) for triage/todo, "Reopen" for done — omitted when its target is locked]; **Move To ›**
  every column except its own, `archived` and the locked ones (running, review, scheduled,
  `V/plugins/kanban/ui.tsx:48-55`); **Assign To ›** every bot from `/profiles`, checkmark on the current one;
  inline section: **Archive** (done only), **Delete** (destructive).
- **Swipes** (`board-page.tsx:181-197`): leading = the quick move (green "Unblock" / blue "Ready" / "Reopen"), full swipe
  allowed; trailing = **More** (gray, opens the hold menu), **Archive** (indigo, done only), **Delete** (red, asks).

### 4.5 Writes on the board (optimistic, `board-page.tsx:86-141`)

All writes: cancel the board's in-flight read, apply the edit to the cached snapshot at once, send, then re-read the
board and the boards list whatever happens; nudge on success (§4.1).
- **Move** (`moveCard`, `model.ts:130-136`): the card leaves its column and goes to the **top** of the target.
  `PATCH {"status":to}`. Target locked → no request; notice with the locked reason
  ("Running is set by the dispatcher when a worker claims the card." etc., `V/plugins/kanban/i18n.ts:243-247`).
- **Assign**: set `assignee` on the card; `POST …/reassign {"profile":p,"reclaim_first":true}`.
- **Archive** (`board-page.tsx:127-137`): remove the card; `PATCH {"status":"archived"}`; on success the Undo pill
  "Archived" with the hint "Archived tasks are on the desktop board."; Undo → `PATCH {"status":<previous status>}` on
  the board it left.
- **Delete**: action sheet "Delete This Task?" / "“<title>” is deleted for every bot and device. This can’t be undone." /
  **Delete Task** (destructive) / Cancel (`board-page.tsx:138-141`); then remove the card; `DELETE`.
- **Failure** (R21, `model.ts:149-160`): put back **only this task**, and only if it is still exactly what this write
  left (a newer write or refresh owns it otherwise); error haptic; glass notice with the gateway's `detail`.
- Success haptic for move/assign/delete (`board-page.tsx:101`).

### 4.6 Task sheet (`S/ui-kanban/task-sheet.tsx`)

Page sheet (`UISheetPresentationController`, large detent, system glass). Bar: ✕ (close) · "Task" · ⋯
(`ellipsis`) (`task-sheet.tsx:309-319`). Reads: task (every 30 s while open), log (only to know it exists every
30 s; every 3 s while its Log tab shows and the task runs, 15 s otherwise) (`:74,81`). Missing lists in an older
plugin's answer read as empty (`:50-55`).

Content, top to bottom (`:213-306`):
1. **Status button**: a 32 pt capsule on the cell colour, 8 pt dot + label + `chevron.down` (`S/ui-kanban/kanban.css:107-110`);
   menu "Move To", single-select over the columns except `archived`; locked ones disabled unless current (`:124-129`).
   Then the title in **Title 2**, selectable (`kanban.css:111`), and a help line (`blockReason` + "." for blocked, else
   `STATUS_HELP`).
2. **Primary action** when a quick move exists and isn't locked: "Unblock" / "Mark Ready" / "Reopen" filled button
   ("Moving…" while busy); a note above it for a Ready task nobody will run: "No one is assigned and this board has
   no default bot, so this task won’t run. Assign it to a bot." (`:197-225`).
3. **Diagnostics** callouts (`:227-228,333-349`): title (+ " ×N"), detail folded at 180 chars with Show More/Less;
   actions `reclaim` → reclaim, `unblock` → move to ready, `cli_hint` → copies `payload.command` ("Copies <code>").
4. **Facts** group: "Assigned To" (pull-down, bot face 24 pt; > 8 bots → list sheet; value "<Bot> (default)" when
   unassigned with a fallback, else "No One"); "Priority" (pull-down: None, 1, 2, 3, 5, 10, the current, "Other
   Number…" → prompt; header "Priority · Higher Goes First"); "Running For" (running); "Finished" (done);
   "Created"; "Created By"; "Failed Runs in a Row" when > 0 (`:130-158,229-240`).
5. **Waiting On** / **Holding Up** groups listing linked task titles; tap opens that task in the same sheet (`:242-245`).
6. **Description**: card with the body (Markdown via the chat's renderer, folded at ~12 lines with Show More/Less,
   `:361-382`) or "No description."; **Edit** → editor (8 rows), Cancel / **Save** → `PATCH {"body":…}` (`:247-256`).
7. **Result**, **Latest Update** (unless it equals the result or matches `^status changed to \w+ \(dashboard/direct\)$`),
   **Last Error** (monospaced) (`:57-58,258-260`).
8. **History** tabs (segmented, shown only when > 1 exists): "Comments N", "Activity", "Runs", "Log" (`:201-206,262-289`).
   - Comments: author ("You" for `desktop`, else bot name) + "3h ago"; composer (placeholder "Add a comment", or
     "Message the bot working on this" while running) with an arrow button; hint "Comments are part of what the bot
     reads when it picks this up." / "The bot reads new comments while it works."; while running, **Post and Start
     Over** = comment then reclaim, notice "Note posted. The task starts again with it." (`:183-190,265-277`).
   - Activity: newest first; `activityLine` words ("Progress update" + note; "Comment from you/<bot>"), else the
     plugin's event wording (`V/plugins/kanban/drawer.tsx` `eventText`; `model.ts:172-180`).
   - Runs: newest first; outcome words, bot, error (red) or summary, age (`:283-287`).
   - Log: monospaced worker log (`:288`).
   Long feeds render lazily (collection view; they can hold thousands of heartbeat events, `:350-359`).
9. **Attachments** group (when the answer has the key): each file → download via the attachment route, Quick Look;
   "Files you add here go to the bot with the task." footer. **Add Attachment** is out this round (§8).
10. **Effort/meta** group: "Estimate Effort" (→ "Estimating…" → "About 42K tokens · M"; footer "Asks a model for a rough
    size of the work."); "Workspace" (path subtitle, tap copies); "Model" ("The bot’s own" or the override, read-only)
    (`:302-306`).

⋯ menu (`:163-181`): Copy Title, Copy Task ID; Archive (closes the sheet), Delete (asks as §4.5, closes).
Writes here use the same "one write per key at a time" rule (`:84-113`), refresh task + board after each.
Loading: centred spinner + "Loading…"; failure: "Couldn’t Load This Task" + reason.

### 4.7 New Task (`S/ui-kanban/new-task-sheet.tsx`)

Form sheet (medium + large detents). Bar: **✕** · "New Task" · **Add** (disabled until the title has text;
spinner while saving) (`:56`; native: the one `ChatSheet.wrap` bar every sheet has, verify round 2 — ✕ does nothing
while saving). Fields (`kanban.css` `.ios-kb-form…`):
- Inset group: "What needs doing?" (Body, autofocus, return = next) and "Details (optional)" (3+ lines).
- **WHO DOES IT**: horizontal row of 76 pt options: bot head 44 pt + name; first the resolved default, then every bot;
  last "No One Yet" (dashed 44 pt square) with hint "The task waits until you assign it." (`:39,65-75`).
- **START IN**: segmented Triage | Ready (default Ready when the board shows Ready, else Triage,
  `board-page.tsx:292`) with the status help line under it (`:76-83`).
- **More Options** disclosure: Priority (number 0–10), Skills (comma list, no autocorrect), Goal Mode (switch, selection
  haptic); note "The task uses this board’s workspace and the bot’s own model. Change those on the desktop board."
  (`:84-95`).
Add (`:40-52`): `POST /tasks` with `title` trimmed, `body` trimmed or omitted, `assignee` or omitted, `priority`,
`skills` or omitted, `triage: start == triage`, `goal_mode`, on the board Add was tapped on; if the answer's
`task.status != start`, `PATCH {"status":start}` (failure ignored); a `warning` shows as a notice; then close, select the
Start In chip, re-read board + boards; nudge. Failure keeps the sheet open with the reason under the bar
("Couldn’t Add the Task", `:38`). Swipe-down is blocked while saving.

### 4.8 Refresh (D-P7)

Board: on show, every **30 s** while the Kanban tab is on screen and the app active, after each write, on foreground,
on board change, pull to refresh. Boards list: on show if > 30 s old (`board-page.tsx:60` `staleTime`), after writes.
Profiles and orchestration: on show if > 60 s old (`:61`). Nothing polls off screen.

### 4.9 States

- Loading with no snapshot: centred spinner + "Loading…" (`board-page.tsx:279`).
- Load failed with no snapshot: inset group "Couldn’t Load the Board" / "Check your connection, then try again." +
  **Try Again** ("Trying…" while busy), footer = gateway detail (`:275-278`).
- Empty chip (`:280-285`): `square-kanban` glyph 34 pt label-3, **"Nothing in <Status>"** (headline), the status help,
  and a filled tint **New Task** button except for locked statuses and Done. Searching: "No Results for “<words>”" /
  "Try another word, or another status."
- Owner's lesson (`MEM/kanban-css-preload.md`: "wtf happened to the theming on the kanban board"): the board must be
  fully styled on its first frame in light and dark; nothing may load its look late.

---

## 5. Artifacts

### 5.1 What an artifact is

The web has **no server index**: it reads recent transcripts and collects files, images and links the bots produced
(`V/app/artifacts/artifact-utils.ts:497-587`, plus the phone's collector fixes `S/artifact-collect.ts`, wired at
`B/fe-pages-gates.ts:24-25,329`). Record (`artifact-utils.ts:9-19`):

```swift
nonisolated struct ArtifactRecord: Codable, Sendable, Hashable, Identifiable {
    var id: String            // "<profile>\u{1F}<sessionId>:<value>" (profile "default" when unset: session ids can
                              // repeat across profiles, and the page's diffable snapshot needs each id once)
    var kind: Kind            // image | file | link
    var value: String         // the path or URL as found (normalised)
    var href: String          // http(s)/data as is; file paths → file URL form (artifactHref, :237-247)
    var label: String         // last path component / URL file name (urlFileLabel, S/artifact-collect.ts:53-62),
                              // else urlSlugTitleLabel (V/lib/external-link.tsx:93-120) for links
    var sessionId: String
    var profile: String?
    var sessionTitle: String  // title, else preview, else "Untitled session" (:115-117)
    var timestamp: Double     // ms; message.timestamp → session.last_active → started_at → now (:272-289)
}
```

### 5.2 Wire

| Purpose | Request | Notes |
|---|---|---|
| Recent sessions of one profile | `GET /api/profiles/sessions?limit=30&offset=0&min_messages=1&archived=exclude&order=recent&profile=<name>`, timeout 60 s (`V/api/sessions.ts:136-162`; route `AG/hermes_cli/web_routers/profiles.py:452-480`) | scope All with ≥ 2 bots: one call **per profile**, 3 at a time, merged newest first by `max(last_active, started_at)`, deduped by `profile::id`; rows the gateway left unstamped get the listed profile (`S/fe-pages-r6.ts:13-48`, **[gate]** `B/fe-pages-gates.ts:905-917`). Failed profiles keep their cached rows and show the notice "Couldn’t list <names>’s chats, so their artifacts are missing." (`B/fe-pages-gates.ts:919`) |
| A transcript page | `GET /api/sessions/<id>/messages?profile=<p>&limit=100&offset=<n>&order=oldest&include_compacted=true` (`V/app/artifacts/index.tsx:139-147`, `V/api/sessions.ts:455-493`) | answer `{"session_id","profile","messages":[…],"pagination":{"limit","offset","order","returned"}}` (`AG/hermes_cli/web_routers/sessions.py:757-766`). Next page while `messages.count == pagination.limit`; stop when `pagination` is absent (older gateways, and the demo) or the page is short (`artifact-utils.ts:571-577`). A page over 32,000,000 JSON characters fails that session with "safe-load limit" (`:31-32,558-564`) |
| Image bytes | `GET /api/fs/read-data-url?path=<value>&session_id=<sessionId>&profile=<p>` (`S/artifact-preview.ts:14-23`) | `{"dataUrl":"data:image/png;base64,…"}`; 413 over 16 MiB (`AG/hermes_cli/web_server.py:892`; `AG/hermes_cli/web_routers/files.py:908-931`); 404 `{"detail":"File not found"}` (captured) |
| File bytes | `GET /api/fs/download?path=<value>&profile=<p>&session_id=<sessionId>` (`S/bridge/platform.ts:41-46`) | the file; the session's `cwd` resolves relative paths and the session is checked even for absolute paths (`files.py:891-904`); 400 "Session working directory is unavailable" for a relative path in a session without cwd |
| Optional thumbnail | `GET /api/plugins/hermes-hq-performance/media/thumbnail?…` (`S/media-metadata.ts:13-21`) | **not this round**; native makes thumbnails with ImageIO |

### 5.3 The index (`S/artifact-index.ts`, port to `HermesKit/Pages/ArtifactIndex.swift`)

- Per account, per collector version (`"native-4"` since a shell's output names no web addresses at all and junk is
  dropped (§5.4); `"native-3"` since a shell's output names no web pictures or pages; `"native-2"` since ids carry the profile; bump when the collector changes,
  `artifact-index.ts:43-45`), one
  entry per `[profile, sessionId]`: `stamp = "<message_count>|<last_active>|<title>"` (none when both counts are
  missing → never cached), `at = last_active`, `artifacts`, optional `failedAt` (`:31-36`).
- A listed session whose stamp is unchanged uses its cached artifacts; a "safe-load limit" failure is kept until
  `message_count` grows; any other failure keeps the previous artifacts and the old stamp so the next pass retries
  (`:174-194`).
- Read stale sessions newest first, **3 slots**, a session with `message_count ≥ 1000` takes all 3 (`:124-141`).
- Show results as they land, at most once a second; save the index after the first landed read, then at most every
  5 s, and on backgrounding (`:198-219,92-101`).
- Sessions that left a **successfully** listed profile's window are dropped; a failed profile's sessions are kept, up to
  **300** outside the window (`:164-172`; `B/fe-pages-gates.ts:918` `{ retain: 300 }`).
- Disk: `Application Support/pages/<account>/artifacts-index.json`, ≤ 4 MB (drop oldest sessions past it).
- When an index pass reads a session again, that session's image previews are dropped from the memory cache
  (`S/artifact-preview.ts:40-58`).

**When to read**: on the first show of the Artifacts page after launch; on later shows if the last pass is > 60 s old;
pull to refresh (also clears preview failures, `S/artifact-preview.ts:80-87`). Never at app launch or off screen: a
scope change made elsewhere (the Jobs pill) only repaints from the index; the pass starts when the page shows. The kept
index itself is read when the page's view loads (in that frame up to 512 KB, else off the main thread behind the
skeleton), not when the app builds its tabs (P-NAV-6).

### 5.4 The collector (port `V/app/artifacts/artifact-utils.ts` + `S/artifact-collect.ts` exactly)

Per message, roles `assistant` and `tool` only (`artifact-utils.ts:501-504`). Text = `content` (string) → `text` →
`context` (`:291-305`).
- **Assistant text** (`:333-369`): `MEDIA:` tags (explicit; `V/lib/chat-messages/parts.ts:90-158,192-206`), Markdown
  images `![…](x)`, Markdown links `[…](x)` (not preceded by `!`; `#media:<encoded path>` hrefs decoded,
  `V/lib/media.ts:287-297`), bare `https?://…` URLs (drop ones cut off — ending in `…`/`..`, elided, or with an
  impossible TLD — `S/artifact-collect.ts:64-98` **[gate]** `B/fe-pages-gates.ts:329`, then strip trailing
  `.,;:!?*_~\``), absolute/home/relative paths (`PATH_RE`, `WINDOWS_PATH_RE`, `:37-38`).
- **Tool messages** (`:416-495`): name = `tool_name ?? name`, lowercased. Producer tools match
  `(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)` or start with
  `bfl_flux3_`; `terminal` is the shell tool. Producer/terminal tools: scan the text as prose. `browser_vision`:
  "Screenshot path: …". Parse JSON payloads (whole text, or inside `<untrusted_tool_result …>…</…>` after the first
  blank line) and structured `content` (`_multimodal` → `meta`); walk every string with its key path (numeric segments
  dropped): terminal + key `output|stdout|path` → scan as prose; else only strong keys (`artifact_file`,
  `files_created`, `generated_image`, `output_path`, `saved_to`, `screenshot_path`, …, `:49-50`) or, for producer
  tools, producer keys (`path`, `file_path`, `image_url`, `attachments`, …, `:52-53`) → candidate.
- **Accept** (`:91-113`): never pip traffic (`.whl`, `.whl.metadata`, pip cache dirs, package-index dists) unless
  explicit; `http(s)://` and `data:image/` always; else must look like a path (`isArtifactFilePath`:
  `^(?:file:|/|[~.][\\/]|\.\.[\\/]|[a-z]:[\\/]|\\\\)`, `V/lib/media.ts:104-106`) and (explicit, or an image/file
  extension from `IMAGE_EXT_RE`/`FILE_EXT_RE`, `:39-42`).
- **Phone fixes** (`S/artifact-collect.ts:1-51`): split values joined by literal `\n`/`\r`/`\t` or newlines; split on
  spaces only when every word is a path/URL; `//host.tld/x` → `https://host.tld/x`; drop relative paths when the session
  row has `cwd` present and empty.
- **Normalise** (`:119-135`): strip up to 3 layers of matching quotes, trailing `` ` ``/`*`, trailing `),.;`.
- **Shell output** (owner 2026-11-02, "a TON of artifacts saved from email footers"): from `terminal` (and its
  `output|stdout|path` keys) only paths on the machine and explicit `MEDIA:` / `::preview` tags count; never an
  `http(s)`/`data:` address, picture or download. Links come from the bot's own words and producer tools' keys.
- **Junk** (`ArtifactCollector.isJunk`, every role, explicit too): social profiles, pages and share buttons
  (tiktok, instagram, facebook, linkedin, x/twitter, youtube channels/`@handles`; one post or `watch?v=` video is kept),
  unsubscribe / email-preference / manage-subscription addresses, mail click trackers and list hosts (list-manage,
  mailchi.mp, beehiiv mail, sendgrid, klaviyo, hubspotlinks, mandrill, mailgun, spark), mail image hosts (cdninstagram,
  fbcdn, Gmail's googleusercontent `/meips/`/`/proxy/`), and tracking pixels (`/open`, `/track/click`, `pixel.gif`,
  `1x1.gif`, …). A small table in the collector.
- Kind: `data:image/` or image extension → image; a file path → file; else link (`:225-235`).
- First occurrence per `<session>:<value>` wins within a session (`:513-517`); across sessions keep one per
  `[profile, sessionId, kind, value, href]`, newest timestamp first (`S/ui-pages/artifacts-model.ts:4-11`).

Tests: port the cases of `V/app/artifacts/index.test.ts:34-655`, `S/artifact-collect.test.ts:4-45`,
`S/artifact-index.test.ts`, `S/ui-pages/artifact-list.test.ts:8-36` as Swift Testing.

### 5.5 Page layout

Tab root (or More page) on the page colour; bar title "Artifacts", integrated search magnifier (D-P11).
- Subtitle row: scope pill + "71 Items" (`B/stress-c-gates.ts:100`).
- **Segmented control** All · Images · Files · Links (`ARTIFACT_FILTERS`, `artifact-utils.ts:6-7`) under it; labels never
  truncate: segments size to their labels, and a 2×2 layout at accessibility sizes (`MEM/segmented-labels-whole.md`).
  The chosen segment is remembered per account (the web keeps it in the route, `V/app/artifacts/index.tsx:121`).
- **Images** (Images segment, and the top of All): edge-to-edge 3-column square grid, 2 pt gutters (`HO/DESIGN.md:1151`).
  Tiles show an ImageIO thumbnail sized to the tile's pixels; until it arrives, the fill-3 colour; a tile whose preview
  failed shows a symbol and opens the viewer with the reason. All shows the newest **24** images (the web's page size,
  `V/app/artifacts/index.tsx:233-236`) then a row "Show All N Images ›" that selects the Images segment.
- **Files and Links** (Files/Links segments, and All under the images): rows grouped by day with **sticky** headers on
  the page colour ("Today", "Yesterday", weekday within a week, "September 10", "September 10, 2025",
  `S/ui-pages/artifact-list.tsx:22-31,45-54`). Row 64 pt (`HO/DESIGN.md:1150`): a 44 pt rounded tile (fill 3) with a
  type glyph (`link` for links; `doc.text` md/txt/json/code; `doc.richtext` pdf; `tablecells` csv/xlsx; `music.note`;
  `film`; `doc.zipper`; `doc` otherwise); name in Body one line, middle-truncated; subtitle Footnote label-2
  "<chat title> · 6:20 PM" (time within a week, else the list date; a run title's own " · Sep 28 06:01" stamp removed,
  `artifact-list.tsx:55-63`); trailing ⋯ 44 pt. At accessibility sizes the name and subtitle wrap and the row gets
  12 pt padding.
- Files+links show the first 100 rows, then more as the list nears the end (the web's 100-row page,
  `V/app/artifacts/index.tsx:238-241`).
- **Unavailable (N)**: files and images the gateway can't find or place (404, a relative path, no folder, a bad path)
  collect at the end behind a collapsed row "Unavailable (N)"; opened, they list with no Share
  (`S/artifact-preview.ts:283-286`; **[gate]** `B/stress-c-gates.ts:120-132`). A successful open moves one back.
  Remember the set in memory per account; Refresh clears it.

**Row and tile actions** (`S/ui-pages/artifact-list.tsx:76-88`): ⋯ and long-press menu: **Show in Chat**
(`bubble.left`), **Share…** (`square.and.arrow.up`, not for unavailable files), **Copy Path** / **Copy Link**
(`doc.on.doc`; HUD "Copied"). Show in Chat pushes the session's chat (§1.3.2) using
`SessionSummary(id: sessionId, profile: profile ?? "default", title: sessionTitle)`.
**Remove** (`trash`, destructive, last; also a pin's menu, and a trailing swipe on file/link rows and pinned rows):
hides it from Artifacts, Bot Info › Artifacts and Pinned (a pinned one is unpinned), in every chat that names it — the
key is the pin's (`profile` + value). Kept on the device per account, `Application Support/pages/hidden/<account
hash>.json` (`HermesKit/Pages/ArtifactHidden.swift`); nothing on the bot's computer changes; no undo.

### 5.6 Opening

| Kind / extension | Opens | Read |
|---|---|---|
| link (`http(s)`) | the default browser via `UIApplication.open` (the web opens links externally, `V/app/artifacts/index.tsx:275-302`); the ⋯ menu still has Copy Link and Share | — |
| image | full-screen viewer: black background, page across the current filter's images, pinch and double-tap zoom, swipe down to close; toolbar Share, Show in Chat, Info (name, chat, time, path, Copy Path) (`HO/DESIGN.md:1152-1155`) | `read-data-url` (§5.2), keep decoded previews in an LRU (≈ 8 M chars of data URL, entries ≤ 2 M, `S/artifact-preview.ts:25-33`); `https` images are fetched without gateway credentials, images only, from public hosts (`S/artifact-preview.ts:106-122`; native: `HermesKit/Net/RemoteImageFetch.swift` + `PublicHostPolicy.swift`, the reference's r1-10 policy: https only, every resolved address public, ≤ 5 redirects each re-checked, ephemeral session, 16 MiB streamed ceiling); an `http` image or a refused one shows a globe tile and the viewer says "This image is on another site and couldn’t be shown here. Tap Open to view it." with **Open** |
| text: `md markdown mdx txt text log json jsonl yaml yml toml ini cfg conf xml py js mjs cjs ts tsx jsx sh zsh bash swift rb go rs java kt c h cc cpp hpp css scss sql` (`S/bridge/fe-pages.ts:26-29`) | pushed **text viewer** on the tab's stack: title = file name, Share in the bar; Markdown → bottom toolbar segmented **Preview | Source** (Preview uses the chat's `MarkdownRenderer`; front matter shown as a facts table, `S/audit-c-format.ts:373-385`); code/text → monospaced 13 pt with the chat's `SyntaxHighlighter`, wrapping lines | `fs/download` ≤ **2 MiB** (`S/bridge/fe-pages.ts:135-149`); bigger → Quick Look |
| html, htm | Quick Look (Preview) with Source in the text viewer (D-P8) | `fs/download` |
| everything else (pdf, office, csv, audio, video, zip…) | `QLPreviewController` (Share comes with it) | `fs/download` to `Caches/pages/preview/<hash>/<file name>`, ≤ 32 MiB (D-P9) |

- Opening shows a spinner on the row; after **0.5 s** a glass notice "Downloading <name>…" with **Cancel** (the
  download may finish, but is not presented); a newer tap supersedes the old (`S/artifact-open.tsx:25-55`).
- Failure words (`S/audit-c-format.ts:389-397`, `S/artifact-preview.ts:271-306`): 404 → "This file is no longer on your
  gateway computer. It may have been moved or deleted." (and → Unavailable); 403 → "Your gateway computer does not allow
  reading this file."; 413 → "This image is too large to preview. Use Save to download it." / files: D-P9 text;
  400 + "working directory is unavailable" → "From an older session whose folder is unknown."; 400 → "The gateway
  can't open this file path."; timeout/50x → "The computer running Hermes took too long to answer. Try again in a moment.";
  401 after renewal → the app's signed-out path. A text that can't be read offers **Open in Quick Look** unless missing
  (`S/artifact-text-sheet.tsx:150-155`).
- Share: a gateway file is downloaded then shared as a file; a link is shared as its URL (`S/artifact-open.tsx:57-75`).
- The text viewer never edits (the web's spot editor writes files; §8).
- Run-output documents from Jobs use the same viewer, read-only, Back named for the job (§3.7).

### 5.7 States

- Loading (no index yet): skeleton rows with a leading tile, after 400 ms (`B/r21-pages-gates.ts:127`).
- Error with nothing cached: "Couldn’t Load Artifacts" + reason + Try Again.
- Partial: a pass that skipped sessions shows a notice for 10 s: "Skipped N of M recent sessions while indexing
  artifacts." (`V/app/artifacts/index.tsx:149-174`).
- Empty (`S/fe-pages-r6.ts:63-76`): title "No <Kind> in <Bot>’s Recent Chats" / "No <Kind> in Recent Chats" (Kind =
  Artifacts/Images/Files/Links), description "<what> appear here. Artifacts looks through <Bot>’s 30 most recent chats"
  / "…the 30 most recent chats of each bot." (`what` = "Images your bots make or share" etc.). Symbol
  `photo.on.rectangle`.
- `artifactsView` rule: found artifacts win; with none, a pass in flight is loading (also on retry), a failed pass is the
  error, only a pass that worked and found nothing is empty (`S/artifact-index.ts:234-243`).

---

## 6. Module layout (suggested)

```
HermesKit/Pages/   PagesWire.swift (decoders), JobWords.swift, JobsStore.swift, JobRuns.swift (shared reads),
                   KanbanAPI.swift (calls + nudge), KanbanModel.swift (port of S/ui-kanban/model.ts), KanbanStore.swift,
                   ArtifactCollector.swift, ArtifactIndex.swift, ArtifactFiles.swift (download, previews, missing set)
App/Pages/         PagesServices.swift, PagesTabs.swift (tabs 2–4, Kanban rule, More root), ScopePill.swift,
                   PageStates.swift, PageNotices.swift (HUD, Undo pill)
App/Pages/Jobs/    JobsViewController.swift, JobRowView.swift, JobDetailViewController.swift
App/Pages/Kanban/  KanbanViewController.swift, KanbanRowView.swift, KanbanTaskSheet.swift, NewTaskSheet.swift
App/Pages/Artifacts/ ArtifactsViewController.swift, ArtifactImageViewer.swift, ArtifactTextViewer.swift, QuickLookPresenter.swift
Tests/Pages/       JobWordsTests, JobSectionsTests, RunOnceTests (fake client), KanbanModelTests, KanbanStoreTests,
                   ArtifactCollectorTests, ArtifactIndexTests
UITests/PagesTests.swift, scripts/e2e-pages.sh, scripts/pages-fixture-gateway.py
```

Lists: `UICollectionView` + diffable data source keyed by stable ids (job id, task id, artifact id) +
`UIHostingConfiguration` rows, like Bots/Sessions (`NAT/docs/ARCHITECTURE.md:36`). Formatters cached
(`NAT/App/Root/ListTime.swift:8-31`). QuickLook: if linking it moves `didFinishLaunching` by more than 5 %, load it with
`dlopen` + `NSClassFromString` as `WebAuthBrowser` does (`NAT/docs/ARCHITECTURE.md:78-80`).

---

## 7. Owner's approved behaviour this stream must keep (from memory)

| Memory | What the owner said or approved | Where it applies |
|---|---|---|
| `kanban-phone.md` | Kanban "needs a TON of work"; chose **A (status list)** "as more native" and "Replace Artifacts tab"; known gaps: "cold start doesn't reopen the Kanban tab", "model override not editable on the phone" | §1.1, §1.3.3, §4 |
| `kanban-css-preload.md` | "wtf happened to the theming on the kanban board" — a board drawn without its look | §4.9, P-KB-11 |
| `more-tab-restore-fix.md` | "going to the More page takes me to the capabilities page… back goes to the bots page. i cannot access the settings pages." | §1.3.1, P-NAV-2 |
| `sessions-everything.md` | lists that silently filter to one bot read as broken; launch on **All** | D-P4 (scope defaults to All Bots, always visible as a pill) |
| `cron-message-width.md` | "a bot's cron message is narrower than every other message; it should at least reach the right edge." | §3.7, P-JOB-12 |
| `delivery-row-overflow.md` | Inbox chat text "cut off at the right edge" (deliveries overflowed) | §3.7, P-JOB-12 |
| `row-padding-feedback.md` | "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt top and bottom" | D-P10, §4.4, §5.5 |
| `search-magnifier.md` | top search box "takes up so much space" → magnifier in the bar | D-P11 |
| `liquid-glass.md`, `liquid-glass-more.md` | "It isn't Liquid Glass. So much of this is wrong." (CSS fake); tab accessory bubble rejected ("covered the list") | §2.8, §1.3.4 |
| `taptic-feedback-gaps.md` | haptics on copies, writes, picks; archive silent (Undo pill) | §2.6 |
| `glitch-sweep.md` | dead controls hidden, not shown | D-P5 |
| `OWNER-DECISIONS.md` #4 | "Keep the ⋮ button on list rows (Sessions, Bots, Jobs). Swipe actions and touch-and-hold menus are ADDED" | §3.4, §5.5 |
| Owner 2026-10-10 (this round's request) | "The header (where it says Bots) is too far from the top… Looks that way on both pages." | §1.1 header rule, P-NAV-5 |

---

## 8. Left out of this round, and why

| Left out | Why | Wire for later |
|---|---|---|
| New Job, Edit Job, job templates ("Start From" blueprints), delivery-target checklist, model override | outside this round's scope (D-P5); the form is large (presets, time wheel, cron editor, `HO/DESIGN.md:1143-1146`); no dead buttons meanwhile | `POST /api/cron/jobs` `{prompt,schedule,name?,deliver?,model?,provider?}` (`V/api/cron.ts:81-89`, `V/types/hermes.ts` `CronJobCreatePayload`); `PUT /api/cron/jobs/<id>` `{"updates":{…}}` (`:91-99`; normaliser `AG/hermes_cli/web_routers/cron.py:52-76`); `GET /api/cron/delivery-targets`, `GET /api/cron/blueprints` |
| Kanban `/events` socket | the web phone never opened it (D-P7); a second ticketed socket needs its own reconnect | `ws(s)://…/api/plugins/kanban/events?board=&since=<cursor>&ticket=<ws ticket>`, frames `{"events":[…],"cursor":N}` (`AG/plugins/kanban/dashboard/plugin_api.py:1802-1847`) |
| Kanban boards create/rename/archive/import/export, links, bulk select, specify/decompose, orchestration settings, profile descriptions | desktop-board work; the phone board never offered them (`S/ui-kanban/board-page.tsx:1-5`) | `V/plugins/kanban/api.ts:470-518` |
| Kanban attachment **upload**, model/reasoning override edits | multipart upload is not in `GatewayClient`; the phone never edited overrides (`MEM/kanban-phone.md`) | `POST …/tasks/<id>/attachments` multipart; `PATCH {model_override, clear_model_override…}` |
| Text file editing (the web's spot editor) | writes the user's files; needs its own review | `POST /api/fs/write-text` (`AG/hermes_cli/web_routers/files.py:834-890`) |
| Save to Photos, artifact Delete in the image Info | P3 in DESIGN; needs a photo-library permission string; there is no artifact delete API | — |
| HQ performance plugin thumbnails | optional; ImageIO thumbnails are enough | `S/media-metadata.ts:13-21` |
| Files over 32 MiB | REST ceiling (D-P9) | needs a download API on `LiveGatewayClient` |
| Simple mode, Desktop Look variants, iPad two-pane | Settings/iPad streams | — |
| Global search (Jobs in results) | its own feature (`HO/DESIGN.md:1121-1124`) | — |

---

## 9. Stand-in gateways (ports 9735–9737 only)

Check a port before use (`lsof -nP -iTCP:<port> -sTCP:LISTEN`); start your own processes only, keep their PIDs, stop
them when done; never touch other listeners (spec 05 §A11). Never the owner's gateway (100.101.102.104, `*.ts.net`).
All fixtures bind 127.0.0.1, so the Simulator reaches them and a phone does not.

### 9.1 Which stand-in exercises what

| Piece | :9735 pages fixture (new, §9.3) | :9736 demo gateway (`DEMO`) | :9737 pages fixture `--no-kanban` / `--empty-kanban` |
|---|---|---|---|
| Jobs list, sections, words | yes (every state seeded) | 5 jobs, read only | — |
| Job detail, runs, open run chat / output doc | yes | **no** (`GET /api/cron/jobs/<id>` answers `{"runs": []}`, captured) | — |
| Run Now (incl. paused dance, 409, slow run > 120 s) | yes | no (POST → 403 "Synthetic voice test refuses changes", captured) | — |
| Pause/Resume/Delete + `cron.changed` | yes | no | — |
| Kanban tab present, board, chips, task sheet | yes, stateful | yes, read only (writes answer `{"ok":true}` and change nothing, `DEMO`:404-407) | — |
| Kanban tab absent / present-unused | — | — | yes (`--no-kanban` → 404; `--empty-kanban` → totals 0) |
| Artifacts: collector cases, image/text/pdf/html/missing, per-profile scope | yes | partial: summary.md, results.png, links, `write_file` path (`DEMO`:65-93,425-434) | Artifacts as tab 3 |
| Visual parity with the owner's demo screenshots/videos | — | yes (same invented data the web demo films used) | — |

### 9.2 Demo gateway on 9736 (read-only visuals)

Verified 2026-10-10 (started, walked, stopped):
```sh
SCR=<a 0700 scratch dir>
cd /Users/me/Projects/hermes-ios-release178
DEMO_FILES=$SCR/files nohup python3 .build/demo/demo-gateway.py --port 9736 \
  --credentials $SCR/creds.json --keep-credentials > $SCR/gateway.log 2>&1 &
echo $! > $SCR/pid          # log line: "Synthetic voice fixture listening on 127.0.0.1:9736"
# sign in with creds.json's username/password (password flow, spec 05 §A2)
kill $(cat $SCR/pid)
```
The file is untracked in another session's worktree and can disappear (spec 05 §A13.3); nothing in this stream's
acceptance depends on it.

### 9.3 New: `NAT/scripts/pages-fixture-gateway.py` (part of this stream's work)

Stdlib only. Loads `$HQN_REF/scripts/action-voice-fixture-gateway.py` (default
`HQN_REF=/Users/me/Projects/hermes-hq-native-ref238`) the way `DEMO` does (`DEMO`:11-15) for password sign-in,
ws-ticket and the WebSocket JSON-RPC base, and overrides `rpc`, `websocket` and `handler`. Invented data only.

Start / stop:
```sh
SCR=<a 0700 scratch dir>
python3 scripts/pages-fixture-gateway.py --port 9735 --credentials $SCR/pages.json --files $SCR/files &   # main
python3 scripts/pages-fixture-gateway.py --port 9737 --credentials $SCR/pages-nok.json --files $SCR/files2 --no-kanban &
# or --empty-kanban on 9737 for the "present, unused" case
```
Flags: `--no-kanban` (every `/api/plugins/kanban/*` → 404 `{"detail":"Not Found"}`), `--empty-kanban`,
`--trigger-seconds N` (default 3; a trigger blocks N s), `--hermes-cookies` (inherited gating).
Prints `Pages fixture listening on 127.0.0.1:<port>`.

**Roster** (`profiles.list`, `/api/profiles`): `default` ("Hermes"), `inbox`, `deploys`, `research`, `finance`, each with
a `path` (`/home/hermes/profiles/<name>`), default Shapes heads (no `dispatch-head` needed).

**Socket**: copy the action-voice `websocket` loop (`FX/action-voice-fixture-gateway.py:85-121`) and keep each open
socket's `send` in a set; `broadcast(type)` sends `{"jsonrpc":"2.0","method":"event","params":{"type":"cron.changed",
"session_id":"","payload":{}}}` to all. `gateway.ready` includes `"change_events": true`.

**Cron** (times relative to start `T0`, rounded to the minute, ISO with the Mac's offset). Seed:

| id | name | profile | schedule | state / flags | expected section · subtitle shape |
|---|---|---|---|---|---|
| `j-triage` | Morning inbox triage | inbox | cron `0 8 * * 1-5`, next = next weekday 08:00 | scheduled, deliver `origin`, origin telegram "Alex Rivera" | Scheduled · "Weekdays at 8:00 AM · Next: …" |
| `j-watch` | release-watch | deploys | interval 30 min, next = T0+12 min | running | Running · "Every 30 minutes" (a running row drops its next-run words, UX study 2026-10-19); title "Release watch" |
| `j-once` | Pay the venue deposit | inbox | once, run_at = T0+2 d 09:00 | scheduled | Scheduled · "Once on <day> at 9:00 AM" |
| `j-paused` | Nightly finance report | finance | cron `0 2 * * *` | enabled false, state paused | Paused (dimmed) · "Every day at 2:00 AM" |
| `j-fail` | gbrain-daily-update-check-local | research | cron `0 6 * * *` | scheduled, last_status error, last_error "RuntimeError: Cron job 'x' has no model configured (job.model=None). Set a per-job model via `hermes cron edit`." | Needs Attention · red "Last run failed · " prefix; title "Gbrain daily update check local" |
| `j-late` | Weekly reading list | research | cron `0 7 * * 1`, next = T0−20 min | scheduled | Needs Attention · "… · Overdue" |
| `j-done` | One-off backup | default | once, past | completed, enabled false | Completed (folded) |
| `j-script` | Disk space check | deploys | cron `*/15 * * * *` | `no_agent: true`, `script: "check_disk.sh"`, prompt "" | Scheduled; detail header "Script" |
| `j-zone` | Weekly health check | default | cron `0 6 * * 1`, `next_run_at` written at 06:00 in a zone 5 h east of the Mac | scheduled | "Every Monday at 1:00 AM"-style local words (`S/job-schedule-words.test.ts:21-26`) |

Every job carries `profile`, `profile_name`, `hermes_home` (`/home/hermes/profiles/<p>`), `schedule_display`, `deliver`
(default `local`). Routes (shapes = §3.1): list (with `profile` filter, array), get, runs, pause, resume, trigger,
delete; unknown id → 404 `{"detail":"Job not found"}`.
- `trigger`: if paused, set enabled/scheduled at once (so the client's poll sees activation), sleep
  `--trigger-seconds`, append a run, set `last_run_at`, return the job (still enabled — the client re-pauses);
  a second trigger while one runs → 409 with the real detail.
- Runs: `j-triage` has 3 agent runs `cron_j-triage_<YYYYmmdd_HHMMSS>` (`source:"cron"`, `message_count` 4, title
  "Morning inbox triage · Oct 9 08:00", preview "Drafted 3 replies") whose `/messages` hold a user row
  "[IMPORTANT: You are running as a scheduled cron job. …]\n\nTriage the inbox" and an assistant row naming
  `/home/hermes/inbox/triage.md`; `j-watch` has one `is_active` run; `j-script` has a document row
  `cron_output:j-script:2026-10-09_08-00-00` (title "COMPLETED · Disk 71% used") and an `exec` row ("FAILED ·
  Permission denied"). The document is served at `/home/hermes/profiles/deploys/cron/output/j-script/2026-10-09_08-00-00.md`
  with a "## Prompt" section before "## Response" (to test the reorder).
- Every cron write broadcasts `cron.changed`; so does a background ticker every 60 s (as the real scheduler's mtime does).

**Kanban**: two boards, `release-2-4` (current, the demo's 11 tasks, `DEMO`:289-316, plus: a Todo task whose parent is
the Running task — moving it to Ready → 409 with the real "Cannot move to 'ready': blocked by parent(s) not done — …"
text; a Ready task with no assignee; one attachment with a small text file; a Done task finished 40 days ago) and
`home` (3 tasks). Orchestration `default_assignee: ""`, `resolved_default_assignee: "default"`. Stateful routes per
§4.1 with the real errors: `PATCH {"status":"running"}` → 400 "Cannot set status to 'running' directly; use the
dispatcher/claim path" (`AG/plugins/kanban/dashboard/plugin_api.py:576`); `scheduled`/`review` → 409 "status transition
to '<s>' not valid from current state" (`:655`); unknown status → 400 "unknown status: x"; empty title → 400 "title
cannot be empty"; reclaim on a non-running task → 409; every write appends an event and bumps `latest_event_id`; `/dispatch` →
`{"spawned":[]}` and counts calls in `/__fixture/state`.

**Artifacts**: sessions per profile (≥ 35 for `research`, so the 30-row window matters) with `cwd` `/home/hermes/app`
except one cron run session with `cwd: ""`. Transcripts that must index to exactly these records (and nothing else):

| Message | Must yield | Must not yield |
|---|---|---|
| assistant: "I put a one-page summary in /home/hermes/reading/summary.md and the chart in /home/hermes/reading/results.png. Sources: https://example.org/papers/open-planning and https://example.org/papers/long-memory" | file summary.md, image results.png, 2 links | — |
| assistant: "MEDIA:/home/hermes/out/report.pdf" | file report.pdf (explicit) | — |
| assistant: "Open [the page](#media:%2Fhome%2Fhermes%2Fsite%2Findex.html)" | file index.html | — |
| tool `write_file` `{"path":"/home/hermes/app/release-notes.md"}` | file release-notes.md | — |
| tool `terminal` `{"output":"Saved /home/hermes/data/export.csv\nDownloading https://files.pythonhosted.org/packages/x/y/pkg-1.0-py3-none-any.whl"}` | file export.csv | the `.whl` |
| tool `read_file` `{"path":"/home/hermes/app/CHANGELOG.md"}` | — | CHANGELOG.md (not a producer) |
| assistant: "see https://telnyx.po…" | — | the cut URL |
| assistant in the `cwd:""` session: "wrote ./out/summary.md" | — | the relative path |
| assistant: "/home/hermes/gone/old.png" (file absent) | image old.png → 404 → Unavailable (1) | — |
| assistant: "/home/hermes/big/log.txt" (3 MiB) | file log.txt → Quick Look (over 2 MiB) | — |
| assistant: "/home/hermes/app/Sources/App.swift" | file App.swift → monospaced viewer | — |

`/api/fs/download` and `/api/fs/read-data-url` serve files from `--files` by basename, honour `session_id` (404
`{"detail":"Session not found"}` for an unknown one; 400 `{"detail":"Session working directory is unavailable"}` for a
relative path in a `cwd:""` session), 413 over 16 MiB for data URLs. Make a real PNG (like `DEMO`:416-434), a 1-page
PDF, a CSV, an HTML file whose body includes `<img src="http://127.0.0.1:9735/__fixture/beacon">` (Quick Look must never
fetch it: `/__fixture/state.beacon` stays 0), a 3 MiB text file. `/messages` honours `limit/offset/order` and answers
`pagination` (§5.2).

**Test hooks**: `GET /__fixture/state` → `{"rest":[{method,path,query,body}],"rpc":[…],"dispatch":n,"beacon":n}`
(inherited `state`, `FX/action-voice-fixture-gateway.py:18,132`, extended with query and body);
`POST /__fixture/fail {"method":"POST","path":"/api/cron/jobs/j-triage/pause","status":500,"detail":"boom","count":1}`
(the next matching request fails that way); `POST /__fixture/fail {"method":"POST","path":"/api/cron/jobs/j-triage/trigger","delay":130}`
(answer after 130 s, past the client's 120 s); `POST /__fixture/reset`.

### 9.4 E2E runner

`scripts/e2e-pages.sh [SIM_UDID]`, a copy of `NAT/scripts/e2e.sh:1-56` that starts the pages fixture on
`${HQN_PAGES_PORT:-9735}` (refusing a busy port), passes its credentials as `TEST_RUNNER_HQN_UI_CREDENTIALS`, runs
`-only-testing:HermesHQNativeUITests/PagesTests`, and stops the fixture it started. Use a clone of the "HQ Native"
simulator, never one signed in to a real gateway.

---

## 10. Acceptance checks

### 10.1 Unit (Swift Testing, `scripts/build.sh test`)

- **P-U1 Words**: every expectation in `S/audit-c-format.test.ts:5-24,25-34,44-68,93-108,111-136,186-192,210-223`,
  `S/job-schedule-words.test.ts:14-44` and `S/list-time-next.test.ts:41-81`, ported with the same inputs and the test's
  time zone (America/Chicago), passes.
- **P-U2 Sections**: `jobSection` puts completed > paused/disabled > running > (error|failed|overdue) > scheduled exactly
  as `S/ui-pages/job-sections-model.ts:4-10`.
- **P-U3 Run once**: the five cases of `S/cron-run-once.test.ts:4-52` (re-pause on observed activation, owner kept,
  restore after a failed trigger, no run when the state can't be read, 404 on restore tolerated) and the shared-read
  cases `:54-89`, against a fake `GatewayClient`.
- **P-U4 Kanban model**: `S/ui-kanban/kanban.test.ts:49-134` (chip order, default status, search, move/remove, Done
  groups, ages/reasons/quick moves, board titles, activity words, R21 restore).
- **P-U5 Collector**: every case of `V/app/artifacts/index.test.ts:34-655` that doesn't need a DOM, plus
  `S/artifact-collect.test.ts:4-45`; and the §9.3 artifacts table end to end on the fixture transcripts.
- **P-U6 Index**: stamps reuse unchanged sessions (no `/messages` read), a changed `message_count` re-reads one session,
  a safe-limit failure is kept until the count grows, a failed profile's sessions are retained (≤ 300), the disk file
  round-trips; ports of `S/artifact-index.test.ts`.
- **P-U7 Rows**: `S/ui-pages/artifact-list.test.ts:8-36` day headers and subtitles.

### 10.2 UI / E2E (`scripts/e2e-pages.sh`, fixture :9735 unless noted)

Navigation
- **P-NAV-1** Tabs read Bots, Sessions, Jobs, Kanban, More on :9735; Bots, Sessions, Jobs, Artifacts, More on :9737
  `--no-kanban` (no Kanban row in More); `--empty-kanban` adds More › Workspace › Kanban.
- **P-NAV-2** From Bots, tap More: More root shows with the tab bar; tap Artifacts, then Bots, then More: More's stack is
  as left, tab bar visible, Back from Artifacts goes to More root (the `MEM/more-tab-restore-fix.md` bug can't happen).
- **P-NAV-3** Kill and relaunch while on Kanban: the app opens on Kanban (and on Jobs when left on Jobs).
- **P-NAV-4** A chat opened from a run or from Show in Chat pushes inside that tab; Back returns to the page.
- **P-NAV-5** On the same simulator, the large-title text frames of Jobs, Kanban, Artifacts and Bots share one y (±1 pt),
  matching the Bots/Sessions header after the owner's 2026-10-10 fix.
- **P-NAV-6** Launch time (`didFinishLaunching`, the app's own measure) within 5 % of build 2's on the same sim.

Jobs
- **P-JOB-1** Second launch: Jobs rows are on screen in the tab's first frame (from cache), no skeleton.
- **P-JOB-2** Sections and order match the §9.3 table; Completed shows "Show 1 Completed"; searching "backup" opens it.
- **P-JOB-3** Subtitles: `j-fail` starts with red "Last run failed · ", `j-late` ends with "Overdue", `j-watch` reads
  "Running" with no next-run words; paused and resumed (so it is scheduled, next still T0+12 min) it reads "Next in N min"
  and changes at the next minute without a refresh.
- **P-JOB-4** Run Now on `j-triage`: alert title `Run “Morning inbox triage” Now?` with "It delivers to Alex Rivera
  on Telegram. Its schedule does not change."; Cancel → `/__fixture/state` shows no POST; Run → exactly
  `GET …/j-triage?profile=inbox` then `POST …/j-triage/trigger?profile=inbox`; HUD "Run Started"; a new run row appears.
- **P-JOB-5** Run Now on `j-paused`: the request log shows GET, POST trigger, GET polls, POST pause (once on activation)
  and the final POST pause; the job ends paused.
- **P-JOB-6** With `/__fixture/fail` delay 130 s on trigger: after 120 s the HUD says "Still Running on Your Gateway", no
  error alert.
- **P-JOB-7** Pause then Resume from the swipe: row moves Scheduled → Paused → Scheduled without a flash; injected 500 →
  alert "Couldn't Pause Job" with "boom" and Try Again.
- **P-JOB-8** Delete from the detail: "Delete Job?" sheet; Cancel sends nothing; Delete sends
  `DELETE …/j-once?profile=inbox`, pops to the list, the row is gone.
- **P-JOB-9** `cron.changed` while Jobs shows → one list GET within 3 s; while on Bots → none until Jobs shows, then one.
- **P-JOB-10** Detail of `j-script`: Script section, run history with a tappable document row (opens the read-only viewer
  with "## Response" first) and a non-tappable exec row.
- **P-JOB-11** Read-only mode (`readOnlyGateway`): Run/Pause/Delete show "Changes are off for this gateway." and send
  nothing.
- **P-JOB-12** Open a `j-triage` run's chat from Run History and the Inbox bot's chat: delivery bubbles end at the same
  x as bot replies, no text past the right edge (`MEM/cron-message-width.md`, `MEM/delivery-row-overflow.md`).

Kanban
- **P-KB-1** Opens on Blocked (2) with Blocked's chip red; chip counts match `/board`.
- **P-KB-2** Swipe "Unblock" on a blocked task: card leaves at once; request `PATCH /api/plugins/kanban/tasks/<id>` with
  `{"status":"ready"}` (no `board` param on the current board); then `/dispatch` once within ~0.5 s.
- **P-KB-3** Move the Todo-with-parent to Ready: card moves, the 409 returns it to its place, error notice shows the
  gateway's text, error haptic event fired.
- **P-KB-4** Move To never lists Running, Review, Scheduled or Archived.
- **P-KB-5** New Task "Write the release post", No One Yet, Ready: Add disabled until typed; request body
  `{"title":"Write the release post","priority":0,"triage":false,"goal_mode":false}` (no assignee/body/skills keys);
  the Ready chip is selected afterwards and shows the task.
- **P-KB-6** Archive a Done task → Undo pill "Archived"; Undo → `PATCH {"status":"done"}`; the task is back.
- **P-KB-7** Delete asks "Delete This Task?"; Cancel sends nothing.
- **P-KB-8** Task sheet: comment → `POST …/comments {"author":"desktop","body":…}` and "You" in the list; on the Running
  task "Post and Start Over" sends the comment then `POST …/reclaim {}`.
- **P-KB-9** Switch to board "Home": request carries `?board=home`; relaunch keeps Home; switching back to the current
  board drops the param.
- **P-KB-10** Assign To Research → `POST …/reassign {"profile":"research","reclaim_first":true}`; the row's head changes
  at once.
- **P-KB-11** First open in light and in dark: screenshots show the styled board (chips, grouped list) in the first
  frame after the push (no unstyled frame).

Artifacts
- **P-ART-1** All shows exactly the §9.3 "must yield" set; Images/Files/Links counts match; none of the "must not" items.
- **P-ART-2** Second visit within 60 s sends no `/messages`; after the fixture appends a message to one session, the
  next visit (> 60 s or pull) reads only that session.
- **P-ART-3** Scope "Research": `/api/profiles/sessions` only with `profile=research`; empty Links text
  "No Links in Research’s Recent Chats".
- **P-ART-4** results.png tile → viewer; pinch zoom; swipe down closes; request was
  `read-data-url?path=…&session_id=…&profile=research`.
- **P-ART-5** summary.md → text viewer, Preview | Source; App.swift → monospaced; log.txt (3 MiB) → Quick Look;
  report.pdf → Quick Look; index.html → Quick Look and `/__fixture/state.beacon == 0`.
- **P-ART-6** old.png → "This file is no longer on the computer running Hermes. It may have been moved or deleted." and
  "Unavailable (1)"; pull to refresh brings it back to the list (still missing on open).
- **P-ART-7** Row ⋯: Show in Chat opens the session; Copy Path puts the path on the pasteboard and shows "Copied";
  Share presents the share sheet with the file.

### 10.3 Look and feel review (screenshots to the owner's standard)

Light, dark, default text size and AX3 for: Jobs list, Job detail (with the error card), Kanban board, task sheet,
New Task, Artifacts All/Images/Files, image viewer, text viewer. Check: 12–14 pt padding on wrapping rows; ⋯ is
horizontal; only system glass; no truncated segment labels; no row under a clear bar showing through (use
`ListBarAppearance`); 120 Hz scrolling of a 300-row Jobs/Artifacts list with no hitch in Instruments' animation hitches.

---

## 11. UNKNOWNs and risks

1. **Kanban availability heuristic (D-P2)** guesses what the owner's device-local web switch says. If the owner's real
   boards are all empty, Kanban would show as a More row instead of a tab. The override key exists for Settings to fix
   it; flag in the build notes.
2. **Run Now over the Nous edge**: an edge/relay may cut a long request earlier than 120 s (a 524 or a reset). D-P6 treats
   502/504/524 as "still running", but a reset (`GatewayFailure.unreachable`) is indistinguishable from a failed send;
   the spec reports it as "Couldn't Run Job" with Try Again (which asks again). Unverified against the real edge.
3. **`.integratedButton` search placement** is assumed from the iOS 26 SDK; if unavailable, use a magnifier bar item
   that activates the search controller (same look).
4. **Quick Look and launch time**: unmeasured; P-NAV-6 decides whether to `dlopen` it.
5. **Artifact read cost on the owner's gateway**: the web measured 26 MB / 35 s for 158 transcripts on first index
   (`S/artifact-index.ts:7-10`). Native caches across launches, but the first visit is still heavy; it must never run at
   launch or off screen (§5.3).
6. **Cron run chats** (`source:"cron"`, possibly `scheduler_owned`): sending into a run's chat while the scheduler owns it
   is the chat stream's call; this stream only opens it.
7. The demo gateway lives in another worktree and may vanish; only §9.3's fixture is load-bearing.
