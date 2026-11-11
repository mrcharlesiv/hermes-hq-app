# 3x — Sessions: Filter & Sort, bot chips, pending line, Session Info, reconnect probe

Milestone 9, stream **sessions**. Branch `m9/sessions`, worktree `/Users/me/Projects/hermes-hq-native-wt/m9-sessions`.
Rows: `docs/briefs/m9/sessions-rows.md` (13 rows of `docs/parity-240.md`: §4 L255-L262, L264, L282, L286, L287 and §5 L370).

This spec is written to be built from without reading the web app again. Every web claim cites a file and line; every
native choice that is not a straight port is marked **DECISION**.

**DECISION (2026-10-24, owner): Show › Archived adds, it does not swap.** A tester (a tester, Discord) read Show's
checks as additive and took the swap for a bug; Background Runs and Outside Chats in the same submenu do add rows. The
web swaps the pool; native now lists the archived chats with the rest, each marked (`archivebox.fill` by the time,
"Archived" read aloud), sorted, grouped, pinned and filtered like any row. Archived rows keep Show's other rules: a run
only with Background Runs (or pinned), a chat from a source the recents leave out (Telegram, cron, …) only with Outside
Chats. Archived is no longer a filter: it is not counted on the button, not named in the strip, and Clear Filters (and
the strip's tap) leave it on, as they leave Background Runs. "No Archived Chats" and "No archived chats match these
filters." are gone. The lines below that say otherwise describe the web and the first native build.

**DECISION (2026-10-25, tester batch 3): Show's subtitle names every check that is on.** The same tester (a tester)
turned on all three and read "Runs, Archived": the web's words (`S/ui-lists/filter-menu.ts:48-50`) predate Outside
Chats, which native added without naming it. Now, in the menu's order: none on, "Chats"; one on, that row's own title
("Outside Chats", "Background Runs", "Archived"); two or three, each by its first word ("Outside, Background", "Outside,
Archived", "Background, Archived", and "Outside, Background, Archived", the tester's own words). Nothing is cut: the
menu wraps a subtitle onto as many lines as it needs, so at the standard text size the longest case takes two lines
under Show ("Outside, Background," then "Archived"), on an iPhone 17 Pro (iOS 27) and an iPhone SE (iOS 26.5) alike, in
the standard look and Desktop Look. At the largest text size (Accessibility XXXL) it takes four on both ("Outside,",
"Back-", "ground,", "Archived": the menu hyphenates Background), and the menu scrolls to it. Only this subtitle changed:
the checks, what they add and the button, strip and Clear Filters rules are as above. Tests:
`Tests/Sessions/SessionFilterWordsTests.swift` (`showSubtitle`, all eight combinations;
`showSubtitleNamesAOneCheckAsItsRowAndFollowsEachToggle`) and the UI tests `test26b_ShowNamesEachCheck` and
`test26c_ShowNamesEachCheckDesktopLookAndLargestText` (`UITests/sessions/SessionsTests+Filter.swift`); screenshots in
`docs/briefs/refs/tester-batch-3-show-*.png`.

**DECISION (2026-10-25, n20-sessions F1): scheduled job runs get a "Scheduled Runs" section on the Other Apps page,
with Show › Background Runs.** A tester (a tester) compares HQ to the dashboard, which files `cron` sessions under
Automation (`~/.hermes/hermes-agent/web/src/pages/SessionsPage_sources.tsx:35-44`), and wants them visible. The desktop
gives them a "Cron jobs" sidebar section of their own (`apps/desktop/src/app/chat/sidebar/cron-jobs-section.tsx`, the
recents and messaging slices both drop `cron`); the HQ web app left them to the Jobs tab ("Cron runs keep their Jobs
tab and section", `S/session-runs.ts:16`). Native already reads the sidebar's cron slice (`cronSessions`). Least
intrusive fit with what is there: the runs are a section beside One-off Runs (`ChatSource.hasFolder`/`folderLabel`,
grey `clock.fill` mark), newest first, with the list's row menu and swipes; never among the dated rows; never unread
and never on the tab's badge (built as the platforms' rows are; spec 02 §9.3); the chip and the status filter apply; search
reaches them while shown. Off by default (Background Runs is off), so nothing changes for anyone who has not asked.
An archived run follows the same switch (it joins the page with Show › Archived and Background Runs, not Outside
Chats alone). The Show submenu's words are unchanged. The Jobs page already opens each run's chat from a job's Runs
list (`JobDetailViewController.open(_:)`), so no new Jobs control was added.

## 0. Sources, notation, ground rules

| Prefix | Root (read only) |
|---|---|
| `S/` | `/Users/me/Projects/hermes-hq-native-ref240/src/` (the phone code of build 240) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref240/build/` (build-time gates that patch the renderer) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref240/vendor/hermes/apps/desktop/src/` (the Hermes desktop renderer the web app patches) |
| `AG/` | `/Users/me/.hermes/hermes-agent/` (Hermes itself, HEAD d94b70f675; never run, never imported) |
| `NAT/` | this worktree |
| `FX/` | `/Users/me/Projects/hermes-hq-native-ref238/scripts/` (the fixtures' shared base) |

- The web Sessions list is the desktop renderer's sidebar with phone gates over it. The filter state, the sort and the
  status buckets are the renderer's (`V/store/layout.ts`, `V/store/session-dot-state.ts`, `V/store/sidebar-sort.ts`); the
  menu, the button, the strip, the chips' behaviour and the row are the phone's (`S/ui-lists/*`, `S/sessions-everything.ts`).
- Hermes rejects an unknown RPC parameter with error 4000 (`AG/tui_gateway/contracts/base.py`: every params model is
  `extra="forbid"`). Every RPC in §4 lists its full key set; send nothing else.
- Native rules that bind this work: native Liquid Glass only (system bars, menus, sheets, `.buttonStyle(.glass)`; never
  blur plus tint); a row whose words can wrap has 12-14 pt above and below; tab roots keep the inline large title; the
  original robot heads; no control that does nothing; plain words, the web's own where it has them; the word
  "Dispatch" never reaches the screen or VoiceOver (the web's internal names such as `_dispatchBotChat` stay internal).
- Swift 6, default MainActor isolation, iOS 26+ SDK, XcodeGen. `project.yml` and `project-original.yml` must both build.
- Test only against the stand-in gateway of §12 on this stream's ports (builders 9970-9974, stress 9975-9979) and this
  stream's simulators (`HQN-m9-sessions`, stress `HQN-m9-sessions-s`).

## 1. What the owner approved and rejected (read before designing)

Owner memory notes, `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/`.

**Approved, `sessions-everything.md`** (owner: Sessions "feels oddly hard to use"):
- "chips set `$sidebarProfileFilter` under All instead of selectProfile, launch opens on All, filter strip under chips
  (ui-lists/filter-strip.tsx, lazy), funnel `on`, Sessions badge = chats + bots" (the badge was later made chats only,
  build 122).
- Round 2: "bot chat rows got a short menu/hold/swipes (Pin — local-only … — Unread, Bot Info; no Archive/Delete)";
  "New Project… in Move to Project (moves the chat once the project appears) and in Filter › Project".
- Known gaps the note lists: bot rows pop in after launch; Telegram and One-off sections ignore the chip filter.

**Approved, `sessions-hide-runs.md`**:
- "Owner chose option 2: hide runs by default." "Filter menu Show › submenu (Background Runs ✓, Archived ✓) because
  validateMenu caps menus at 8 rows". "**Why:** owner wants the phone list to read like conversations, not machine runs."
- Round 2, the owner's words: "sessions should not include convos you have with your bots — that's how the hermes
  desktop app does it." Bot chat rows are no longer merged into the list ("rows still built; chips wait on
  $botChatRows"); the Sessions badge skips hidden runs.

**Rejected 2026-10-08, `sessions-tidy.md`** ("meh, don't like it"). None of these may come back, alone or together:
- the chips scrolling away with the list;
- removing the row's ⋯ button (the ⋯ was the owner's own "decision 4");
- plain date headers / hidden chevrons;
- the strip naming the chip's bot ("Deploys · Unread") and a strip tap clearing the bot too.

**Which note speaks for which row**

| Row | Owner note | The words that bind it |
|---|---|---|
| L256 (Show ›) | `sessions-hide-runs.md` | "Owner chose option 2: hide runs by default." Show › holds Background Runs and Archived |
| L259 | `sessions-everything.md`, `sessions-tidy.md` | "filter strip under chips"; never naming or clearing the chip's bot (rejected) |
| L260 | `sessions-everything.md`, `sessions-tidy.md` | "chips set `$sidebarProfileFilter` under All instead of selectProfile, launch opens on All"; never scrolling with the list (rejected) |
| L261 | `sessions-everything.md` | "New Project… in Move to Project (moves the chat once the project appears) and in Filter › Project" |
| L262 | `sessions-tidy.md`, `row-padding-feedback.md` | the row keeps its ⋯ (removing it was rejected); 12-14 pt above and below |
| L282 | `sessions-hide-runs.md` | "sessions should not include convos you have with your bots — that's how the hermes desktop app does it." |
| L255, L257, L258, L264, L286, L287, L370 | none | no owner note; the web app at build 240 is the reference, cited in each section |

**Also binding**: `row-padding-feedback.md` ("Any cell whose text can wrap gets explicit vertical padding: about
12-14pt top and bottom"), and `feedback-one-feature-at-a-time.md` (one feature per build; §15 orders the work so each
step stands alone).

## 2. The rows at a glance

| Row | What | Section | Native today | Outcome planned |
|---|---|---|---|---|
| L255 | Sort By, Group By, Row Detail | §5 | none of the three | built |
| L256 | Status ›, Project ›, All Bots ✓, Show ›, live toggles | §5 | Show › only | built |
| L257 | Clear Filters / Mark All as Read | §5.6 | neither | built |
| L258 | Filter button filled, token | §6.1 | filled; counts Background Runs (wrong) | corrected and completed |
| L259 | Filter strip, outside the scroller | §6.2 | none | built |
| L260 | Bot chips rail; chips filter All | §7 | none | built |
| L261 | New Project… in two places | §8 | Move to Project only | Filter › Project added |
| L262 | Messages-style row with Row Detail | §9 | row without Row Detail | completed |
| L264 | "Not Delivered:" then "Draft:" | §9.4 | neither on Sessions rows | built |
| L282 | Sessions-everything leftovers | §7.6 | none | the visible parts built; bot chat row menu left out by owner decision (DECISION) |
| L286 | Session Info sheet | §10 | "Info" with 5 rows | completed |
| L287 | Reconnect probe | §11 | implemented, unproven, one rule off | proven, corrected, counted |
| L370 | Session Info rows in full | §10 | 5 of 12 rows | completed |

No row needs a relay, plugin or real-gateway change; there is no `docs/owner-todo/sessions.md` (§16). No row is
proposed as web-shell-only.

## 3. Data model (HermesKit)

### 3.1 More of the stored row

`SidebarSessionRow` (`NAT/HermesKit/Model/RosterSessions.swift`) decodes these stored-row fields too. All are optional;
a missing, null, non-numeric, negative or non-finite value reads as absent. They come on every sidebar and
`/api/sessions/{id}` row (`AG/tui_gateway/contracts/common.py` `StoredSessionRow`).

| JSON key | Swift | Used by |
|---|---|---|
| `input_tokens`, `output_tokens` | `inputTokens: Int?`, `outputTokens: Int?` | Row Detail Tokens, Sort By Tokens |
| `actual_cost_usd`, `estimated_cost_usd` | `actualCostUsd: Double?`, `estimatedCostUsd: Double?` | Row Detail Cost, Sort By Cost, Session Info Cost |
| `git_branch` | `gitBranch: String?` | row metadata, Session Info Folder note |
| `handoff_platform` | `handoffPlatform: String?` | Session Info Source |

The row cache on disk (`RosterDisk`) stores the row as it is; an older cache file without these keys must still load.

`SessionSummary` (`NAT/HermesKit/Contracts.swift`) gains, each with a default so every existing initialiser compiles:

```swift
var startedAt: Date? = nil
var tokens: Int = 0                       // input + output
var cost: Double = 0                      // actual, else estimated, else 0  (V/store/sidebar-sort.ts sessionCostUsd)
var metadata: String = ""                 // §9.2
var status: SessionStatus = .idle         // §3.3
var pending: SessionPending? = nil        // §9.4
var cwd: String? = nil
```

### 3.2 What the user chose (per gateway account, on the device)

`SessionsDeviceState` (`NAT/HermesKit/Store/SessionStore.swift:37`) gains one field, `view`, decoded with
`decodeIfPresent` so an older file keeps its unread state:

```swift
nonisolated enum SessionSortBy: String, Codable, CaseIterable, Sendable { case updated, created, status, tokens, cost }
nonisolated enum SessionGroupBy: String, Codable, CaseIterable, Sendable { case date, project, status }
nonisolated enum SessionRowDetail: String, Codable, CaseIterable, Sendable { case time = "updated", preview, tokens, cost }
nonisolated enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case needsInput = "needs-input", working, unread, draft, idle        // menu order and sort rank 0…4
}
nonisolated struct SessionsViewPrefs: Codable, Hashable, Sendable {
    var sortBy: SessionSortBy = .updated
    var groupBy: SessionGroupBy = .date
    var rowDetail: Set<SessionRowDetail> = [.preview, .time]
    var statusFilter: Set<SessionStatus> = []
    var projectFilter: Set<String> = []      // project keys, §3.4
    var showArchived = false
}
```

- Defaults are the renderer's: grouping `date`, ordering `updated`, row meta `['preview','updated']`
  (`V/store/layout.ts:329`), no filters.
- The web keeps every one of these across launches (`V/store/layout.ts:53-64`, the `hermes.desktop.sidebar*` keys), which
  is why the strip exists (`S/ui-lists/filter-strip.tsx:1-4`: "a filter left on from an earlier visit emptied the list
  with no visible cause"). Native does the same: `view` is written with the rest of the device state.
- An unknown raw value (a file from a newer build) decodes to the default for that field, never a thrown error.
- The existing `showBackgroundRuns` stays where it is. The view controller's own `showArchived` moves into `view`.
- **Not stored**: the chip's bot. `SessionStore.botFilter: String?` lives in memory and starts `nil` on every launch
  (the web opens on All each launch: `S/sessions-everything.ts:166-174`).
- The renderer's Manual order (dragging rows) and Group By Bot are not offered on the phone
  (`S/ui-lists/filter-menu.ts:90-91`, C-08) and have no native case.

Derived, in one place (`SessionFilterWords`, pure):

```swift
var effectiveProjects: Set<String>   // projectFilter ∩ the keys the Project submenu lists now (C-07, filter-token.ts:15-17)
var filterCount: Int                 // statusFilter.count + effectiveProjects.count (Archived not counted since 2026-10-24)
var filtersActive: Bool              // filterCount > 0 || botFilter != nil
```

Background Runs is not a filter: it is not counted, it does not fill the button, Clear Filters leaves it
(`S/ui-lists/filter-apply.ts:22-29`, `S/ui-lists/filter-token.ts:16-17`). Native today counts it
(`NAT/App/Sessions/SessionsViewController.swift:521-526`); that is corrected.

### 3.3 A chat's status

Port of the renderer's bucket (`V/store/session-dot-state.ts:89-98`; the phone's words `S/ui-lists/row-model.ts:46-52`).
One status per chat, first match wins:

| Status | True when | Native source |
|---|---|---|
| `needsInput` | an approval, a question, a sudo or secret prompt waits | new `SessionStore.setNeedsInput(_ ids: Set<String>)`, fed by the prompt centre's `onNeedsInput(profile, storedId, kind)` (`NAT/App/AppModel.swift:238,485`); today only the Bots row hears it |
| `working` | a turn runs (the renderer's `working`, `stalled`, `background`) | `SessionSummary.isRunning` (unchanged: `setRunning`, `NAT/App/AppModel.swift` `setWorking`) |
| `unread` | either unread source says so | `SessionSummary.unread` (unchanged) |
| `draft` | words typed and not sent | §9.4 `pending` with `failed == false` |
| `idle` | none of the above | |

DECISION (Draft differs from the web on purpose): the web's `draft` bucket is an open chat that nothing was ever sent
to (`V/app/chat/session-status-dot.tsx:137`: a session with no stored id). Such a chat has no row in the phone's
Sessions list at all (the list is the gateway's stored chats), so the web's meaning would make Status › Draft always
empty here. Native therefore reads Draft as "this chat has words typed and not sent", the same thing the row's
"Draft:" line says (§9.4) and what the Bots tab already means by a draft. This is not parity; it is the nearest
meaning that can ever match a row.

Sort rank is the case order (needs input 0 … idle 4). A lost send ("Not Delivered") is not a status of its own; its
chat is whatever the rules above make it.

### 3.4 Projects, for Filter › Project and Group By Project

- Source: `SessionStore.projects(for:refresh:)` (`NAT/HermesKit/Store/SessionStore+Actions.swift`, RPC `projects.tree`,
  §4.4), the same cache Move to Project uses. Fetched for each bot that owns a listed chat the first time the Filter
  menu opens or Group By Project is on, then at most once a minute per bot, and again after a project is created.
- A chat's project is `SessionProject.owner(of: cwd, in: projects)` (the existing longest-folder match). No folder, or no
  match: no project.
- **DECISION (project identity across bots):** under All, two bots can each have a project on the same folder. A
  project's key is its folder (`root`, standardised, no trailing slash); a project without a folder uses
  `"id:" + profile + "/" + id`. One entry per key, labelled by the first bot's label in chip order. The key for "no
  project" is `"home"`, labelled **Home** (the web's word: `B/ui-lists-gates.ts:110-113`, `isNoProject → home`).
- The Project submenu lists projects only when there is more than one entry counting Home
  (`B/ui-lists-gates.ts:111`: `projects.length > 1`), sorted by label (case-insensitive, numeric), Home last.
- A gateway without projects (`projects.tree` answers `-32601`): no projects, the submenu holds only New Project…,
  Group By Project is not offered unless it is already the choice (then every chat sits under Home).

### 3.5 One pure pipeline

New `NAT/HermesKit/Model/SessionListPipeline.swift`, `nonisolated`, no UIKit, unit-tested. `SessionStore.sections()` calls
it; the view controller keeps drawing `groups` as today.

```
input : rows (already without bot chats, hidden runs, leaving rows), archived rows, prefs, botFilter,
        statuses by id, pending by id, project of each row, now/calendar/locale
1 pool    = live rows + (prefs.showArchived ? archived rows : [])   (the web swaps: V/app/chat/sidebar/index.tsx:605-680)
2 filter  = bot (botFilter) AND status (statusFilter empty or contains) AND project (effectiveProjects empty or contains)
3 pinned  = filtered rows that are pinned  → the "Pinned" group, first, as today (archived pinned rows included)
4 sort    = within each group, by prefs.sortBy (below)
5 group   = Sort By Tokens/Cost → one untitled run (index.tsx:1471,1872: rankedGlobally → 'none'; the web's Archived too)
            else Date → today's date groups (4 AM rollover, unchanged) keyed on the sort's own timestamp
            else Status → "Working" then "Done"                                (V/lib/session-date-groups.ts:159)
            else Project → one group per project, by its newest chat; Home last
```

Sort (`V/store/sidebar-sort.ts`), ties always broken by recency (newest first), then id:

| Sort By | Key |
|---|---|
| Updated | `last_active` (else `started_at`), newest first |
| Created | `started_at`, newest first |
| Status | rank of §3.3, then recency |
| Tokens | `input_tokens + output_tokens`, largest first |
| Cost | `actual_cost_usd`, else `estimated_cost_usd`, else 0; largest first |

- Group By Status: "Working" holds chats that are `working` or `needsInput` (the renderer's `hasLiveTurn`); "Done" the
  rest. An empty group has no header.
- **DECISION (date groups under Sort By Created):** the date groups use `started_at` then, so a group's rows stay
  together. Under Updated and Status they use `last_active`, as today.
- **DECISION (Group By Project):** the web shows the desktop's project tree section for this choice
  (`V/app/chat/sidebar/index.tsx:1872` passes `'date'` to the list and a separate tree renders). The phone list gets flat
  groups titled with the project's label, in the existing date-header style.
- **DECISION (2026-10-26, tester ivy): groups fold, projects cap at five.** Every titled group (Pinned, a date, a
  status, a project) folds: a tap on its header (not a project's +) closes it to the name, a right chevron and its
  count ("8 · 1 unread"); VoiceOver reads the header as a button, value "Collapsed"/"Expanded", label with the count
  while closed. The desktop folds every divider the same way (`SidebarDateDivider` toggle,
  `V/app/chat/sidebar/sessions-section.tsx:346-376`), so dates and statuses fold too, for consistency. Closed groups
  are kept on the device per gateway account and per chip (`SessionsDeviceState.collapsedGroups`, keyed by the chip's
  bot, "*" for All). Under Group By Project a project (Home too) draws its newest **5** chats, then "Show More (X)",
  which opens it in place, then "Show Less": 5 is the desktop's own lane page (`SIDEBAR_GROUP_PAGE`,
  `V/app/chat/sidebar/projects/model.ts:14`) and keeps three or four projects on one phone screen. Show More lasts
  for the launch only. A status or project filter folds and caps nothing (every match shows); search is one run
  without headers, so nothing folds there either. Step 6 of the pipeline (`SessionListPipeline.folded`).
- **DECISION (2026-11-03, owner, menu review): a header with a hold menu shows a ⋯ too** [header-menus]. A project's
  row (closed or open, Home too) ends in a small label-2 ⋯ past its time (under the time at the accessibility sizes,
  so the name keeps its room); a caption with a hold menu (a bot's under Group By Bot) has it at its end, after any +.
  Each is a 44 pt touch opening the same items as holding the header (`ProjectHeaderMenuItems`); a tap on the row
  still folds it, and VoiceOver finds the ⋯ as its own button, "Actions for <name>" (`sessions.header.menu`).
- Search results ignore steps 2-5 except the bot (§7.4).
- Budget: 5,000 rows through the whole pipeline in under 50 ms on the simulator's host (unit test with `measure`).

### 3.6 Reading deeper while a filter is on

"A filter searches the loaded page, so switching one on has to deepen the page" (`V/app/session/hooks/use-session-list-
actions.ts:528-556`; 50 rows normally, 300 while filtered: `V/store/layout.ts:41,45`).

- `SessionStore` full reads ask `recents_limit=300` while `statusFilter`, `effectiveProjects` or `botFilter` is set, else
  50. Cron and messaging limits do not change.
- Turning the first such filter on while the last full read asked for 50 starts one full read (never a probe).
  Turning the last one off starts nothing; the next regular read asks for 50 again. **DECISION:** no forced re-read on
  clear (the web re-reads; the extra rows are harmless and leave on the next read).
- The probe (§11) is unaffected: its fingerprint does not depend on the limit.

## 4. Wire calls (exact)

All REST calls go through `GatewayClient.rest`, all RPCs through `call`, as the store does today.

### 4.1 The sidebar (unchanged path, one changed number)

```
GET /api/profiles/sessions/sidebar?recents_profile=all&recents_limit=50&cron_limit=50&messaging_limit=100
    &recents_exclude=<SessionStore.recentsExclude>&messaging_exclude=<SessionStore.messagingExclude>&profile=<routing profile>
```
- `recents_limit=300` while a filter is on (§3.6). Each limit is clamped to 1…500 by Hermes
  (`AG/hermes_cli/web_routers/profiles.py:537-538`). Pinned rows always come, whatever the limit (`include_pinned=True`,
  `:554`).
- The probe is the same request with all three limits `1` (§11).
- An older gateway answers 404; the store already falls back to three `GET /api/profiles/sessions` reads
  (`NAT/HermesKit/Store/SessionStore.swift:535-556`). Nothing new there.

Row example (new keys marked):
```json
{"id":"20260101_090000_aa0003","title":"Trip to Lisbon","preview":"Three quiet picks near the river…","profile":"research",
 "source":"desktop","model":"anthropic/claude-opus-5.5","started_at":1791550000,"last_active":1791553600,"message_count":14,
 "tool_call_count":3,"is_active":false,"cwd":"/home/hermes/reading","pinned":false,"unread":true,"archived":false,
 "input_tokens":14200,"output_tokens":1200,"actual_cost_usd":null,"estimated_cost_usd":0.34,
 "git_branch":"main","handoff_platform":null}
```

### 4.2 Mark All as Read

For each listed chat whose server flag is unread (§5.6), the existing write (`SessionStore.writeUnread`):
```
PATCH /api/sessions/{id}?profile=research        body {"unread": false, "profile": "research"}        → {"ok": true}
```
At most four in flight at a time. Each write names the chat's owner (`S/ui-lists/filter-apply.ts:48-51`, D18).

### 4.3 The archived read (unchanged; its rows now join the list)

`GET /api/profiles/sessions?limit=200&offset=0&min_messages=0&archived=only&order=recent&profile=all`.

### 4.4 Projects

```
projects.tree     {"preview_limit": 3, "profile": "research"}
  → {"projects":[{"id":"p_reading","label":"Reading","path":"/home/hermes/reading","repos":[]},
                 {"id":"home","label":"Home","path":null,"isNoProject":true,"repos":[]}],"active_id":null,"scoped_session_ids":[]}
projects.create   {"name":"Site","folders":["~/Projects/site"],"use":false,"profile":"default"}
  → {"project":{"id":"p_1a2b3c","name":"Site","primary_path":"/home/hermes/Projects/site","folders":[{"path":"/home/hermes/Projects/site"}]}}
session.workspace.move   {"cwd":"/home/hermes/Projects/site","session_key":"20260101_090000_aa0003","profile":"default"}
  → {"cwd":"/home/hermes/Projects/site","branch":null,"git_repo_root":null}
```
Allowed keys (`AG/tui_gateway/contracts/projects_pets.py`): `projects.tree` {`preview_limit`, `session_limit`, `profile`};
`projects.create` {`name`, `folders`, `slug`, `primary_path`, `description`, `icon`, `color`, `board_slug`, `use`,
`profile`}. These are the calls `SessionStore+Actions` already makes; do not add keys.

### 4.5 Session Info

```
session.usage     {"session_id":"<runtime id>","profile":"research"}                (AG/tui_gateway/contracts/sessions.py:503-512)
  → {"model":"anthropic/claude-opus-5.5","input":14200,"output":1200,"total":15400,"calls":9,
     "context_used":48200,"context_max":200000,"context_percent":24,"context_estimated":false,
     "cost_usd":0.34,"cost_status":"estimated"}
GET /api/sessions/{id}?profile=research      → the stored row of §4.1 (only when the chat's row is not in a loaded list)
```
- `session.usage` takes `session_id` and `profile` only. Send it through `LiveChatSession.sessionCall` (it adds both and
  resumes once on 4001). 3 s timeout. Any error, including `-32601` on an older Hermes, is swallowed: the sheet shows
  what it already has.
- Events already on the socket, read with no new request:
  - `session.info` payload and the `session.resume` / `session.activate` result's `info` (`SessionLiveInfo`): `usage`,
    `branch`, `cwd`, `model`, `provider`, `reasoning_effort`, `fast`.
  - `message.complete` payload `usage`.
  - `session.usage` payload `{"usage": {...}}`, a mid-turn tick (`AG/tui_gateway/contracts/events.py`). Native has no
    case for it yet (`NAT/HermesKit/Chat/LiveChatSession+Events.swift`).
  - `status.update` payload `{"kind":"fallback"|…, "text":"Model fallback: …"}` for Answered By (§10.3).

## 5. The Filter & Sort menu (L255, L256, L257)

### 5.1 What the web does

`S/ui-lists/filter-menu.ts:65-100` builds it; `S/ui-lists/filter-apply.ts:99-114` presents it and applies picks.

```
Sort By        Updated  ›       arrow.up.arrow.down        one choice, closes the menu
Group By       Date     ›       rectangle.grid.1x2         one choice, closes the menu
Row Detail     Time, Preview ›  text.alignleft             checks, the menu stays open
── Filter ─────────────────
Status         Any      ›       circle.dashed              checks, stays open
Project        Any      ›       folder                     checks, stays open; then New Project…
All Bots                ✓       person.2                   check, stays open (only with a second bot)
Show           Chats    ›       eye                        Outside Chats ✓, Background Runs ✓, Archived ✓; stays open
───────────────────────────
Clear Filters                   xmark.circle               while a filter is on
Mark All as Read                envelope.open              otherwise; disabled with nothing unread
```

- Sort options: Updated, Created, Status, Tokens, Cost (`V/store/layout.ts` orderings; Title Case by `titled`,
  `filter-menu.ts:87`). Cost is offered only once some chat reports spend, or while it is the choice
  (`V/app/chat/sidebar/filter-menu.tsx:213-219`; "a cost sort would rank a list of zeroes").
- Group options: Date, Project, Status. No "Bot" unless it is already on (`filter-menu.ts:90-91`). The subtitle reads
  "None" while Sort By is Tokens or Cost (`:88-89`, C-10).
- Row Detail options: Time, Preview, Tokens, Cost (`:36-38`); Cost under the same rule as the sort
  (`B/ui-lists-gates.ts:106`). Subtitle: the picked names joined ", ", "None" for none, "N Selected" past two
  (`:41-44,56`).
- Status options: Needs Input, Working, Unread, Draft, Idle (`V/store/layout.ts` status filters; Title Case). Subtitle
  "Any", the names, or "N Selected" (`:57`).
- Project: a check per project by the name its user gave it (C-09), then New Project… in its own group; only
  New Project… when there are no projects, and then no subtitle (`:72-77`).
- Show ›: subtitle "Chats", "Runs", "Archived" or "Runs, Archived" on the web (`:48-50`). Native (DECISION
  2026-10-25 at the top): "Chats"; one check by its row's title; two or three by their first words in menu order
  ("Outside, Background, Archived").
- Eight rows at most, so Clear Filters takes Mark All as Read's place while a filter is on; "Marking every chat read
  from a filtered view would also act on rows it hides" (`:7-8`).
- Live while open: after each toggle the four subtitles are re-said and the last row is disabled once it no longer
  applies; the rows themselves do not swap (`:9-11,53-63`; `filter-apply.ts:103-110`).
- Each toggle and each pick ticks a selection haptic (`filter-apply.ts:42,80`).

### 5.2 Native construction

`SessionsViewController.filterMenu()` returns the three inline groups above as `UIMenu` elements, built from one pure
model (`SessionFilterMenuModel.nodes(state:) -> [BotMenuNode]`, so the words are unit-tested without UIKit) and turned
into `UIMenu` by the existing node builder (`NAT/App/Bots/BotListSections.swift:99` already maps `keepsOpen` to
`.keepsMenuPresented`).

- Three `UIMenu(options: .displayInline)` groups; the middle one has the title "Filter".
- Submenus use `UIMenu(title:subtitle:image:children:)`; Sort By and Group By add `.singleSelection`.
- Identifiers (UI tests): `sessions.filter.sort`, `sessions.filter.sort.updated|created|status|tokens|cost`,
  `sessions.filter.group`, `sessions.filter.group.date|project|status`, `sessions.filter.detail`,
  `sessions.filter.detail.time|preview|tokens|cost`, `sessions.filter.status`,
  `sessions.filter.status.needs-input|working|unread|draft|idle`, `sessions.filter.project`,
  `sessions.filter.project.<n>` (n = position), `sessions.filter.project.new`, `sessions.filter.allbots`, `sessions.filter.show`,
  `sessions.filter.runs`, `sessions.filter.archived` (both exist), `sessions.filter.clear`, `sessions.filter.readall`.
- The button's accessibility label becomes the web's: "Filter and Sort" (§6.1).

### 5.3 Exact words

| Place | Words |
|---|---|
| Sort By options | Updated · Created · Status · Tokens · Cost |
| Group By options | Date · Project · Status |
| Group By subtitle under Tokens/Cost | None |
| Row Detail options | Time · Preview · Tokens · Cost |
| Row Detail subtitle | names joined ", " in menu order ("Time, Preview") · "None" · "3 Selected" · "4 Selected" |
| Status options | Needs Input · Working · Unread · Draft · Idle |
| Status / Project subtitle | Any · one or two names joined ", " · "N Selected" |
| Project last item | New Project… |
| All Bots | All Bots |
| Show options | Outside Chats · Background Runs · Archived |
| Show subtitle | Chats · Outside Chats · Background Runs · Archived · Outside, Background · Outside, Archived · Background, Archived · Outside, Background, Archived |
| End row | Clear Filters · Mark All as Read |

### 5.4 Live updates while the menu is open (required)

After a toggle the menu stays open and, without closing: its checkmark flips, the list behind re-sorts or re-filters,
the strip (§6.2) and the button fill (§6.1) follow, the submenu's parent subtitle is re-said, and the end row's
disabled state follows (Mark All as Read disables once a filter is on; Clear Filters disables once none is; neither is
swapped for the other until the menu is opened again, as the web).

How, in order of preference; the builder proves the one used with a UI test and a screenshot:
1. Give the Filter control a real `UIButton` (`UIBarButtonItem(customView:)`, same symbol, 44 pt,
   `showsMenuAsPrimaryAction`) so `button.contextMenuInteraction?.updateVisibleMenu { _ in rebuilt }` is available, the
   pattern already shipping in `NAT/App/Gateways/GatewayTitleSwitcher.swift:143`. The capsule must still read as one
   glass group with Search and Compose (`PageBarCapsule` owns this; Bots must look unchanged). If a custom-view item
   cannot share the group's glass on this SDK, do not fake it: use 2.
2. Keep the bar button item's menu and flip state on the tapped `UIAction` inside its handler; subtitles then refresh
   when the user steps back to the root menu (each submenu is a `UIDeferredMenuElement.uncached`).
If neither refreshes a parent subtitle while the submenu is still open, report that sub-check as failed in the row's
outcome; do not hide it. Checkmarks, the list, the strip and the button fill must be live in every case.

### 5.5 All Bots ✓

Web: the row toggles `$showAllProfiles` (`filter-apply.ts:39`); off, the list is one bot's (the app's active profile)
and that bot's chip lights (`S/sessions-everything.ts:52-55`). It is offered only with a second bot
(`B/ui-lists-gates.ts:115`).

**DECISION:** native has no app-wide active bot, and its list always reads every bot (`SessionStore.allBots`). The row
is a second handle on the chips: checked while no chip is picked; tapping it while checked picks the home bot's chip
(the account's routing profile, "Hermes"), tapping it while unchecked clears the chip. Shown only with two or more bots.
One difference from the web follows and is accepted: a picked bot counts as a filter for the end row (Clear Filters
shows), as any chip does (§7.3).

### 5.6 Clear Filters and Mark All as Read (L257)

**Clear Filters** (`filter-apply.ts:22-29`): status filter, project filter and the chip's bot go off (the web's
Archived too; native keeps it, 2026-10-24). Sort By, Group By, Row Detail, Background Runs and Archived stay. Selection haptic. The list animates back.

**Mark All as Read** (`filter-apply.ts:52-69`): "clears both unread sources, as each row's Mark as Read does".
New `SessionStore.markAllRead() async -> [SessionWriteFailure]`:
1. On the device: every listed chat is acknowledged (`device.unread`, the finished-unseen markers and watermarks), in
   one persisted change. "Listed" is every recents row the store holds, including background runs the list hides.
2. On the gateway: every listed chat whose server flag is unread gets the PATCH of §4.2, optimistic, four at a time,
   through the existing token-guarded `writeUnread` so a late answer cannot undo a newer tap.
3. The Bots tab's dots: the web also acknowledges every bot's chat (`filter-apply.ts:58-59`,
   `acknowledgeAllKnownBotChats`). **DECISION:** native does the same, with the call the Bots row's Mark as Read makes
   (`BotStore.markRead`, device-local), so the app's icon badge reaches zero as it does on the web. Flagged in the
   risks: the owner removed bot chats from this list, and may prefer this menu to leave Bots alone.
- Enabled while either source has an unread Sessions chat (`anyUnread`, `filter-apply.ts:53`); bots alone do not enable it.
- Ignored if a filter came on after the menu opened (`filter-apply.ts:77-78`).
- Selection haptic at the tap. No confirmation, no toast.
- Failure, after every write has answered: `FailureAlert.present(title: "Couldn’t Mark All as Read", reason:, from:,
  retry:)`. Reason: the first failure's reason; with more than one, "`<n> chats: <reason>`" (e.g. "3 chats: The
  gateway is offline."). Try Again runs only the chats that failed. Chats that failed keep their unread mark.
- Read-only gateway switch (`readOnlyGateway`): device marks clear, no PATCH is sent, no alert.
- (2026-10-25, n20-sessions B3) The "badge stays after Mark All as Read" report did not reproduce on main at 379:
  test28 and test83 pass in the full suite and in repeated runs, light and dark; they fail only when the suite is run
  with `HQN_SESSIONS_SEED=big`, at their first row lookup (`s-recipes`, `s-garden` are not in that seed), before any
  badge check. The tab's badge counts the live rows only (`SessionList.unreadCount(store.sessions)`), so neither
  candidate touches it. One real gap was found and fixed: the server flag of a row's Mark as Read (or of opening it)
  was rewritten in the slices but not in the Archived view's rows, so an archived chat kept its dot until the next
  archived read. Mark All as Read still acts on the recents only (step 1), not on archived chats shown with
  Show › Archived.

### 5.7 States

| State | What shows |
|---|---|
| One bot | no All Bots row; chips rail hidden (§7) |
| No projects, or gateway without projects | Project › holds only New Project…, no subtitle; Group By has no Project |
| Projects still loading at first open | Project › shows what the cache holds (possibly only New Project…); the next open has them. Never a spinner row |
| No chat reports spend | no Cost under Sort By or Row Detail, unless already chosen |
| Nothing unread, no filter | Mark All as Read, disabled |
| Archived on | the archived chats join the list, marked; Group By applies as usual (2026-10-24) |
| Offline | every row still works (they are device state); Mark All as Read fails with the alert above |
| Filter leaves nothing | §6.3 |

### 5.8 Acceptance

- A1 (L255) Sort By Created reorders two chats whose `started_at` and `last_active` disagree; relaunch keeps it.
- A2 (L255) Sort By Tokens: the list is one run with no date headers, Pinned still first; Group By's subtitle reads "None".
- A3 (L255) Group By Status: headers "Working" and "Done"; a chat that starts working moves up without a tap.
- A4 (L255) Group By Project: one header per project, "Home" last; no "Bot" anywhere in the menu.
- A5 (L255) Row Detail: turning Tokens on shows "1.2k" on the row while the menu is still open; subtitle follows.
- A6 (L256) Status › Unread narrows the list with the menu open; the strip says "Unread"; a second status makes it
  "Working · Unread".
- A7 (L256) Project › a project narrows the list; All Bots off lights the Hermes chip; Show › Archived adds the archived chats.
- A8 (L257) With a filter on the end row is Clear Filters and it clears status, project and chip, not the sort.
- A9 (L257) With none on, Mark All as Read sends one `PATCH {"unread":false}` per server-unread chat (fixture log),
  clears the device-only dots too, zeroes the Sessions badge, and is disabled afterwards.
- A10 (L257) With two of five writes failing: the alert reads "Couldn’t Mark All as Read" / "2 chats: …"; Try Again
  sends exactly two writes.

## 6. The Filter button and the strip (L258, L259)

### 6.1 The button (L258)

Web (`S/ui-lists/filter-button.tsx:13-33`, `S/ui-lists/filter-token.ts:16-30`): icon
`line.3.horizontal.decrease.circle`, drawn filled while `filtersActive && count > 0`; accessible name "Filter and Sort",
or "Filter and Sort, 2 filters on" ("1 filter on"). The words that name the filters moved off the button to the strip
(`filter-button.tsx:20`).

Native: `PageBarCapsule.setFilterActive(_:token:)` gains a `label:` so Sessions can say the web's words (Bots keeps
"Filter").
- Filled (`.circle.fill`) while `filterCount > 0`. A chip alone does not fill it; Background Runs does not fill it.
- `accessibilityLabel`: "Filter and Sort" / "Filter and Sort, N filter(s) on".
- `accessibilityValue`: the token of `filterToken` (`filter-token.ts:21-30`): the names when every filter can be named
  and there are at most two ("Working · Unread", "Reading"; a project by its own label; never Archived since 2026-10-24), else
  "N Filters" ("1 Filter").
- The visible token is the strip.

### 6.2 The strip (L259)

Web (`S/ui-lists/filter-strip.tsx:11-41`): one capsule under the bot chips, outside the scroller, while a Filter-menu
filter narrows the list. Text (`filterStripText`): the status names in menu order (Needs Input, Working, Unread, Draft,
Idle), then "Project" for one project or "N Projects" for more (the web then adds "Archived"; native does not since
2026-10-24); one or two names joined " · ", else "N Filters" (N = the number of names, projects counting once). A tap
clears status and project with a
selection haptic; "the chip's bot stays" (`:4,28-33`). Accessible name "Showing <text>. Clear Filters".

| Filters on | Strip |
|---|---|
| Unread | Unread |
| Working, Unread | Working · Unread |
| one project | Project |
| three projects (Archived on or off) | 3 Projects |
| Working, Unread, one project | 3 Filters |
| only Archived | no strip |
| only a chip | no strip |
| only Background Runs | no strip |

Native: the existing glass token (`NAT/App/Kit/PageFilterToken.swift`, `.buttonStyle(.glass)`, text plus
`xmark.circle.fill`), given an `identifier` parameter (`sessions.filter-strip`), in the fixed header of §7.2, under the
chips, leading-aligned, 16 pt from the edge. It never scrolls with the list. It appears and leaves with a 0.2 s fade and
height change (none with Reduce Motion). Per the rejected tidy (§1) it never names the chip's bot and its tap never
clears the bot.

### 6.3 When the filters leave nothing

Web (`B/fe-lists-gates.ts:3324-3345`). Native empty state, centred in the list, the existing empty-state style:

| Case | Title | Text | Button |
|---|---|---|---|
| filters (or a chip) match nothing | No Matching Chats | No chats match these filters. | Clear Filters |
| a chip alone, that bot has no chats | No Matching Chats | No chats match these filters. | Clear Filters |

The button is a glass button (`.buttonStyle(.glass)`), identifier `sessions.empty.clear`, and does what the menu's
Clear Filters does.

### 6.4 Acceptance

- B1 (L258) Status › Unread fills the button; VoiceOver reads "Filter and Sort, 1 filter on", value "Unread". Background
  Runs alone leaves it unfilled.
- B2 (L259) The strip shows under the chips, stays put while the list scrolls a full screen, and a tap clears the
  filters but leaves a picked chip picked.
- B3 (L259) Relaunch with Status › Unread on: the strip is there before the first row paints from the cache.
- B4 A filter that matches nothing shows "No Matching Chats" and its button brings the list back.

## 7. The bot chips rail (L260) and the leftovers (L282)

### 7.1 What the web does

- The rail sits under search, above the list (`B/r21-pages-gates.ts:89`, `B/fe-lists-gates.ts:936-961`): a fixed "All"
  chip (a layers glyph, caption "All", accessible name "All Bots"), then Hermes (the default profile), then the other
  bots, each a round face with its name under it; it scrolls sideways; a hairline under it.
- A chip filters All; it never moves the app onto the bot (`B/sessions-everything-gates.ts:45-61`,
  `S/sessions-everything.ts:50-61` `pickChip`): tapping a bot narrows the list to that bot; tapping the lit chip or All
  goes back to every bot.
- The lit chip is the one the filter names (`chipActive`, `:52-55`); All is lit while none is
  (`sessions-everything-gates.ts:55-56`).
- A launch opens on All once two or more bots are known (`:166-174`).
- Compose with a chip picked starts the new chat with that bot, with no Choose a Bot step (`S/phone-header.tsx:210`,
  `chipBot`, `S/sessions-everything.ts:62-66`).

### 7.2 Native layout: a fixed header, outside the scroller

New `NAT/App/Sessions/SessionsHeaderView.swift` (SwiftUI in a `UIHostingController` child): the rail, then the strip
when there is one.

- It is pinned under the navigation bar and never scrolls with the list (owner: the chips scrolling away was rejected,
  §1). `additionalSafeAreaInsets.top` = the header's measured height; the header's bottom is pinned to
  `view.safeAreaLayoutGuide.topAnchor`. The inset is re-applied when the measured height changes by more than 0.5 pt
  (the guard `NAT/App/Pages/Kanban/KanbanTaskSheet.swift:317-323` uses). The large title still collapses on scroll, and
  the header follows the bar's bottom edge; with the search field unfolded it sits under the field ("under search").
- Glass: the header draws no blur or tint of its own. It joins the bar's scroll edge effect with
  `UIScrollEdgeElementContainerInteraction` (scroll view = the collection view, edge = top), the iOS 26 way to extend
  the system effect under a custom bar. If that interaction is not available or misdraws on this SDK, the fallback is
  an opaque band in the page colour (`HQPalette.page`) with a hairline (`HQPalette.separator`) under it. Never a
  hand-made blur.
- Rail: horizontal `ScrollView`, 16 pt leading and trailing content inset, 14 pt between chips, 8 pt above and below.
  The picked chip is scrolled into view when it changes.
- Chip: a 44 pt face (`HeadImage(size: 44, working:)`, the bot's own head; never a hat or character head) with the
  caption under it (4 pt gap; `.caption2`, one line, tail-truncated, 64 pt wide). Picked: a 2 pt tint ring 2 pt outside
  the face, caption semibold in the label colour. Not picked: caption in `hqLabel2`.
- All chip: a 44 pt circle in `hqFill3` with `square.stack.3d.up` (the web's layers glyph), caption "All".
- Order: All, then `services.bots` as Compose's chooser orders them (home bot first, then the Bots list's order,
  `NAT/App/Sessions/SessionsOrganizer.swift:221`), hidden bots left out.
- Shown only with two or more bots. With fewer the header has zero height (and the strip, if any, sits alone).
- Dynamic Type: the caption stops growing at `.accessibility1`; faces stay 44 pt; the rail scrolls. Minimum touch
  target 44 x 60.
- VoiceOver: the rail is a container labelled "Bots"; each chip is a button, label = the bot's name ("All Bots" for
  All), trait selected while picked. Identifiers `sessions.chips`, `sessions.chip.all`, `sessions.chip.<profile>`.

### 7.3 Behaviour

- Tap a bot: `store.botFilter = profile`, selection haptic, the list animates. Tap the picked chip or All:
  `botFilter = nil`.
- Nothing outside the Sessions tab changes: not the Bots tab, not the gateway's active profile, no request is sent
  except the deeper read of §3.6 the first time a filter comes on.
- A chip is a filter for: the end row (Clear Filters shows and clears it), the deeper read, the empty state. It is not
  one for: the button's fill, the count, the strip (`B/ui-lists-gates.ts:117`: "The bot chips show the profile filter:
  the token names the rest").
- The pick is not kept across launches; it survives leaving and returning to the tab, opening a chat and coming back,
  and backgrounding.
- If the picked bot leaves the roster or is hidden, the pick clears.
- Compose with a chip picked: `SessionsOrganizer.compose()` skips Choose a Bot and calls `newChat(profile: botFilter)`.
- 2026-11-10 (tester; owner: "one go-to"): Compose (the bar's button, the empty page's New Chat, ⇧⌘N) always
  opens the one New Chat sheet (`SessionsOrganizer.presentNewChat`, `NewChatSheetView`). "Bot": the bots as pills, one
  lit (the picked chip's, else the bot the sheet started with last, else Hermes); a tap only changes the bot. "Project ·
  Tap one to start the chat": No Project, each project in a fixed order, New Project… last; a tap on a row starts the
  chat there with the lit bot. The project that bot started in last carries "Last used" (`NewChatLast`, on the device).
  The sheet is as tall as its rows. Settings › Chat › New Chat Asks for a Project off (`NewChatProjectChoice`, synced):
  with a chip picked the chat starts in no project at once. ⌘N and a Home card's New Chat row never open the sheet.
  Choose a Bot (the plain list) stays for a project's New Chat with no bot picked and Filter › Project › New Project….
- 2026-11-11 (owner: "without overwhelm"): the sheet has one prominent button, Start Chat (no project, the lit bot;
  "No Project" is no longer a row), pinned at the foot of the sheet (owner picked it over the top of the sheet and
  the title bar), under "In a project (optional)". Six projects or fewer are all listed, in the
  list's order; with more, five (`NewChatLast.shown`: the ones the sheet started for the lit bot, then the ones its
  newest chats are in, then the list's order) and All Projects <count> ›, which pushes `NewChatAllProjectsView` (A to Z,
  a search field, the sheet at full height). Rows have no chevron. New Project… is a section of its own.
- **DECISION (Telegram and scheduled rows):** the owner's note lists "Telegram/One-off sections ignore the chip
  filter" as a known gap of the web. Native applies the chip to every row the list draws.

### 7.4 Search

While a query is typed: the chip still applies (hits come from that bot only: `store.search(query, profiles:
[botFilter])`, and local rows are narrowed the same way); the Filter-menu filters do not apply to hits, so the strip
is hidden until the query is cleared. **DECISION** (the web does not define this; hiding a strip that would not be
true is the honest state).

### 7.5 States

| State | Rail |
|---|---|
| launch, roster from cache | chips from the cached roster at first paint (no pop-in) |
| launch, no roster yet | no rail until two bots are known; then it fades in and the list keeps its scroll position |
| a bot is working | its face shows the working motion `HeadImage` already draws |
| 40 bots | scrolls; faces render through `HeadImageCache`; no hitch (§14) |
| offline | unchanged; chips are device state |

### 7.6 The leftovers (L282)

What `S/sessions-everything.ts` still does in build 240, and the native answer for each:

| Web piece | Lines | Visible on the web today | Native |
|---|---|---|---|
| chips filter All | `:50-61` | yes | §7.3 |
| launch opens on All | `:166-174` | yes | `botFilter` starts nil each launch |
| Compose uses the chip's bot | `:62-66`, `S/phone-header.tsx:210` | yes | §7.3 |
| Status filter knows a bot chat's unread (`botChatDot`) | `:47-48` | no (rows not in the list) | not built |
| bot chat rows built from the roster | `:68-88` | no: "the rows are still built (the chips wait on them), but `merge` is no longer registered" (`:6-7`) | not built; chips read the roster directly |
| the rows' short menu: Pin, read state, Bot Info; never Archive or Delete | `:101-113`, registered only `if (sessionsHooks.merge)` (`:139-143`) | no | not built |

**DECISION:** native builds no bot chat rows and no short menu for them. The owner took those rows out of Sessions on
2026-10-04 ("sessions should not include convos you have with your bots — that's how the hermes desktop app does it"),
and since then the web builds the rows only so the rail re-renders once its hooks load; their menu never registers
(`:139-143`), so no user can reach it. A native control for it would be a control for a row that does not exist. The
chips need no such rows: they are drawn from `BotStore`'s roster. A bot's own chat keeps Pin, Mark as Read/Unread and
Bot Info where they already are, on its Bots row (`NAT/App/Bots/BotsOrganizer.swift:70-83`). The row's outcome is
reported as "visible parts done; bot chat row menu not applicable by owner decision", not as a plain done.

### 7.7 Acceptance

- C1 (L260) Two or more bots: the rail shows All, Hermes, then the rest; one bot: no rail.
- C2 (L260) Tapping Research shows only Research's chats, lights its chip, leaves the Bots tab and the title switcher
  untouched, and sends no `profile`-switching call (fixture log holds no new RPC besides the deeper sidebar read).
- C3 (L260) Tapping the lit chip, or All, shows every bot again.
- C4 (L260) The rail stays in place while the list scrolls to its end and back.
- C5 (L282) Relaunch after picking a chip: the list opens on All.
- C6 (L282) Compose with Research picked opens a new Research chat with no chooser; with All it shows Choose a Bot.
- C7 (L282) No row for a bot's own chat appears in the list, in a search, or in Archived.

## 8. New Project… (L261)

Web: `S/ui-lists/session-work.ts` (`newProject()` opens the renderer's New Project sheet; `newProjectThenMove` waits up
to 15 s for the project, then moves the chat; HUD "Moved to <label>"; failure "Couldn’t Move Chat"). Filter › Project
offers it always: "the phone had no way to make a project" (`S/ui-lists/filter-menu.ts:72-73`,
`S/ui-lists/filter-apply.ts:75-76`). Owner: "New Project… in Move to Project (moves the chat once the project appears)
and in Filter › Project".

Native today: Move to Project › New Project… (`SessionsOrganizer.newProjectThenMove`): an alert titled "New Project",
message "A project holds the chats in its folder on the computer running Hermes.", fields "Name" and "Folder, like
~/Projects/site", button Create.

Add: Filter › Project › New Project… opens the same alert (extract `SessionsOrganizer.newProject(profile:done:)` from
`newProjectThenMove`; both entries call it).
- Which bot the project belongs to: the chip's bot when one is picked. Under All with more than one bot, Choose a Bot
  comes first (the existing `ChooseBotView` sheet, title "Choose a Bot"), then the alert. **DECISION** (the web makes
  it for the app's active profile, which native does not have).
- Wire: `projects.create` of §4.4, `use: false`.
- Success: the project list for that bot is re-read; HUD "Created <name>" (`MenusHUD`); the new project is not turned
  on as a filter (the web only creates it). The next open of Project › lists it.
- Create is disabled until both fields have text. The folder is sent as typed (Hermes expands `~`).
- Failure: `FailureAlert` titled "Couldn’t Create Project" with the gateway's reason and Try Again (which reopens the
  alert with both fields as typed). A gateway without projects: the reason is the existing
  `SessionActionText.projectsUnsupported` ("This gateway doesn’t have projects yet. Update Hermes on the computer, then
  try again."), no Try Again.
- Cancel: nothing changes.

Acceptance:
- D1 From Filter › Project › New Project…, name "Site", folder "~/Projects/site": one `projects.create` with exactly
  `{name, folders, use:false, profile}` (fixture log), HUD "Created Site", and Project › then lists Site.
- D2 Under All with three bots the chooser comes first and the call carries the chosen bot's `profile`.
- D3 A failing create shows "Couldn’t Create Project" with the reason; Try Again brings the typed words back.
- D4 Move to Project › New Project… still creates and moves (existing test stays green).

## 9. The row (L262) and its pending line (L264)

### 9.1 What the web does

`S/ui-lists/session-row.tsx:50-92`, words in `S/ui-lists/row-model.ts:46-74`.

- A 40 pt face with the unread badge on its corner; the title, semibold while unread; a colour tag after the title; the
  time at the trailing edge; under it "<Owner> · <detail>" on up to two lines; a pin glyph when pinned; the ⋯ button.
- The trailing text is Row Detail's figures then the age, joined " · " (`:62`): tokens as a compact number when above
  zero, cost as `$0.34` when at least a cent (`V/app/chat/sidebar/session-row.tsx:186-196`: "Sub-cent spend rounds to
  $0.00, which reads as a bug … below a cent the row says nothing at all"), then the time when Time is on.
- The second line, first match (`:77-85`):
  1. a search snippet, its match marked;
  2. a live status: "Needs your input" (orange) or "Working…" (tint), after the owner;
  3. the pending line: **Not Delivered:** (red) or **Draft:**, then the words (§9.4);
  4. the detail: the preview when Preview is on and the chat has its own title, else the metadata
     (`row-model.ts:55-60`).
- Metadata (`V/app/chat/sidebar/session-row-details.ts:30-47`): `git_branch · model · N messages · N tool calls`, each
  part only when it has a value; the model is the last path part of its id.
- VoiceOver, one stop (`row-model.ts:63-74`): "<Title>. <status>. <Bot>: <detail>. <time>. Unread. Pinned. Color: Red."

### 9.2 Native: Row Detail on the existing row

`SessionRowView` (`NAT/App/Sessions/SessionRowViews.swift`) keeps its shape: 40 pt `HeadImage`, 17 pt unread badge,
semibold title while unread, colour tag, ⋯ button, 13 pt vertical padding, 72 pt minimum height. It gains
`detail: Set<SessionRowDetail>` and reads the new summary fields.

Trailing text ("when"), `.subheadline`, monospaced digits, one line:

| Row Detail | Example |
|---|---|
| Time | 9:05 AM |
| Tokens, Time | 1.2k · 9:05 AM |
| Tokens, Cost, Time | 1.2k · $0.34 · Yesterday |
| Tokens, Cost (Time off) | 15.4k · $12.50 |
| none of the three | nothing (the pin glyph, when pinned, still shows) |

- Tokens (`compactNumber`): 0 → nothing; 999 → "999"; 1,000 → "1k"; 1,230 → "1.2k"; 15,400 → "15.4k"; 1,500,000 →
  "1.5M"; one decimal, a trailing ".0" dropped, lower-case k, capital M.
- Cost: below $0.01 → nothing; else `$` and two decimals, always a point, never a locale's comma ("$0.34", "$12.50").
- The title keeps layout priority; the trailing text may take at most 55% of the line and truncates at its tail beyond
  that (only absurd values reach it, §14 bad data). At accessibility sizes it moves under the second line, as the
  time does today.

Second line, in the web's order:
1. search snippet (unchanged);
2. `status == .needsInput` → "<Owner> · Needs your input" with the status words in `hqOrange`;
   `status == .working` → "<Owner> · Working…" in `hqTintText` (unchanged words);
3. `pending` → §9.4;
4. Preview on and the chat has a preview → "<Owner> · <preview>" (unchanged);
   Preview off, or no preview → "<Owner> · <metadata>"; no metadata → the owner alone.

Metadata string, built in the store (`SessionSummary.metadata`): `gitBranch`, the model's last path part, "1 message" /
"14 messages", "1 tool call" / "3 tool calls", joined " · ", empty parts dropped.

The face: `HeadImage(working:)` while working (unchanged). While `needsInput` the badge on the face's corner is orange
(`hqOrange`) in place of the tint unread badge, the same 17 pt disc (the web's `needs-you` badge).

VoiceOver label, the web's order: title · status words · "<Owner>: <detail>" · figures and time · "Unread" · "Pinned" ·
"Color: <name>" · "Deleting", joined ". ". **DECISION:** the figures are read ("1.2k tokens", "$0.34"); the web leaves
them out of the label, but the user asked for them on the row.

Row height: the row grows with Dynamic Type as today. No fixed heights are added.

### 9.3 States

| State | Row |
|---|---|
| Row Detail empty | title, owner and metadata line only |
| no title | title falls back to the preview, then "Untitled Chat" (the web says "Untitled session"; UX study 2026-10-19 #31); the detail is then the metadata |
| archived view | same row; no status words unless the chat is live |
| deleting | unchanged (dimmed, spinner in place of the trailing text) |

### 9.4 The pending line (L264)

Web (`S/ui-lists/row-pending.ts:15-29`): "a send that may never have arrived ('Not Delivered:', in red) wins over text
waiting in the composer ('Draft:')". The lost send is the first queued entry with `deliveryUnconfirmed` that is not a
hidden one; the draft is the composer's stashed text, trimmed. Drawn "<Owner> · **Not Delivered:** words"
(`S/ui-lists/session-row.tsx:82-83`); a live status wins over it.

```swift
nonisolated struct SessionPending: Hashable, Sendable { var failed: Bool; var text: String }
static func pending(lost: String?, draft: String?) -> SessionPending?     // lost first, then a non-empty trimmed draft
```

Native sources, wired in `AppModel` as the Bots row's draft already is (`NAT/App/AppModel.swift:253-262`):

- `SessionStore.pendingLine: ((_ profile: String, _ storedId: String) -> SessionPending?)?` and
  `SessionStore.refreshPending()` (a rebuild).
- **Draft**: `attachments.draft("\(accountId)|\(profile)|\(storedId)").text`, trimmed. Text only; a draft that is only
  photos says nothing (the web reads text). `attachments.onDraftChange` calls `refreshPending()` when no chat is
  focused, next to the existing `refreshDrafts()`.
- **Not Delivered**: native marks such a message in the open chat only ("Delivery unconfirmed",
  `NAT/HermesKit/Chat/LiveChatSession.swift:992-1004`) and never caches it, so nothing outlives the chat screen. New
  small store, shared with the Bots row (parity L189, stream botslist) and the queue card (L465, stream composer):

  `NAT/HermesKit/Chat/LostSends.swift`, `@MainActor final class LostSends`, one per process like `QueueStash`:
  ```swift
  struct Entry: Codable, Hashable, Sendable { var id: String; var text: String; var at: Date }   // id = the local message id
  func note(accountId: String, profile: String, chatId: String, entry: Entry)
  func clear(accountId: String, profile: String, chatId: String, id: String)
  func first(accountId: String, profile: String, chatId: String) -> Entry?
  func entries(accountId: String, profile: String, chatId: String) -> [Entry]
  func purge(accountId: String)
  var onChange: (() -> Void)?
  ```
  On disk `Application Support/lost-sends/<account key>.json`, `{"v":1,"chats":{"<profile>\u{1F}<stored id>":[…]}}`,
  written 0.3 s after a change, `completeFileProtectionUntilFirstUserAuthentication`, purged with the account (next to
  `QueueStash.purge` at `NAT/App/AppModel.swift:202` and `NAT/App/Settings/AppModel+Settings.swift:167`). At most 20
  entries per chat, 2,000 characters each.
  - Written by `markUnconfirmed` (for a visible text send with a known stored id; hidden continuations and memos are
    left out, as the web skips `displayKind: 'hidden'`).
  - Cleared when the mark clears: Check finds it (`checkDelivery`), the gateway's inflight state proves it
    (`NAT/HermesKit/Chat/LiveChatSession+Sync.swift:577`), Send Again, Delete.
  - **So the row never points at nothing:** when a chat opens and `LostSends` holds entries for it, each is put back
    as the user's bubble with the "Delivery unconfirmed" mark after the first history page lands, unless that page
    already holds a user row with the same text at or after `entry.at − 5 s` (then it was delivered: the entry is
    cleared quietly). **DECISION:** this restore is the smallest change that keeps "Not Delivered:" honest; without it
    the row would name a message the chat no longer shows.
  - If stream botslist or composer has already landed a store with this job on `m9/train`, reuse it and add only what
    is missing here. Never two stores.

Drawing: after the owner and " · ", the prefix in semibold, then a space and the words in `hqLabel2`:
- "Not Delivered:" in `hqRed`;
- "Draft:" in `hqLabel`, as the Bots row draws it (`NAT/App/Bots/BotRowViews.swift:129`).
Two lines at most, as the preview. VoiceOver reads "<Owner>: Not Delivered: <words>" / "<Owner>: Draft: <words>".

States: a chat with both shows Not Delivered. A working or needs-input chat shows its status words instead (the pending
line returns when the turn ends). A draft typed in the chat appears on its row when the user is back on the list (not
per keystroke while the chat is on screen). Sign-out removes both.

### 9.5 Acceptance

- E1 (L262) Default Row Detail: the row matches today's (title, time, owner · preview). A screenshot before and after
  shows no shift for default settings.
- E2 (L262) Tokens and Cost on: "1.2k · $0.02 · <time>" on the fixture's Garden plan; Quarterly budget (cost $0.004)
  shows tokens and no cost; Bread recipes (no tokens) shows the time alone.
- E3 (L262) Preview off: the second line reads "Hermes · main · hermes-4 · 2 messages".
- E4 (L262) Unread: semibold title and the 17 pt badge; needs input: orange badge and "Needs your input".
- E5 (L264) Type "call the plumber" in Garden plan, go back: the row reads "Hermes · Draft: call the plumber";
  Status › Draft lists it; sending or clearing the text removes the line.
- E6 (L264) Send with the fixture dropping the answer (§12 `drop`): back on the list the row reads
  "Hermes · Not Delivered: <words>" with the prefix red, ahead of any draft; relaunch keeps it; opening the chat shows
  the bubble marked "Delivery unconfirmed"; Delete removes bubble and line.
- E7 At the largest accessibility size the row wraps with 13 pt above and below and nothing clips.

## 10. Session Info (L286, L370)

### 10.1 What the web does

`S/session-info-sheet.tsx:48-75`, rows from `S/phone-chat-menu-model.ts:81-113`.

- Opened from the chat's menu › Info for any chat that is not a bot's own (a bot's own chat opens Bot Info:
  `S/phone-chat-menu.tsx:203`). Title "Session info", under it the chat's title or "This chat".
- "The model, effort and usage are the loaded runtime's, so they show only while that runtime is this chat's; the
  stored row speaks for it otherwise" (`session-info-sheet.tsx:45-47`). A chat the loaded list does not hold has its
  stored row read once by id when the sheet opens (`:28-43`).
- Rows, in order, each only when it has a value (`phone-chat-menu-model.ts:83-112`):

| Label | Value | Note under it |
|---|---|---|
| Answered By | the fallback model's name | "<primary> is unavailable on the gateway (<reason>)" |
| Model (or "Chat Model" while Answered By shows) | the model's name | the provider's name |
| Reasoning | the effort and/or "Fast", joined " · " | |
| Context | "24%" ("~24%" when estimated) | "48.2K of 200K tokens" |
| Tokens | "15.4K" | "14.2K in · 1.2K out" |
| Cost | "$0.34" (four decimals below a cent: "$0.0042") | "Estimated" when neither live usage nor the stored row has an actual cost |
| Messages | "14" | |
| Folder | the chat's folder, monospaced | the git branch |
| Bot | the bot's name | |
| Source | where the chat came from, when not this app | |
| Gateway | the gateway's host | "Connected", else "Offline" / "Signed out" / "Reconnecting…" / "Connecting…" |
| Chat ID (was Session ID, UX study #73) | the stored id, monospaced | |

- Counts (`:69`): below 1,000 as is; then one decimal with a capital K ("15.4K", "200K"); from a million with M ("1.5M").
- Context percent (`:96`): `context_percent`, else used ÷ max × 100, clamped 0…100, rounded. Only when `context_max > 0`.
- Cost (`:98-99`): live `usage.cost_usd`, else the row's actual, else its estimate; only above zero.
- Source names (`:74-80`): telegram → Telegram, discord → Discord, slack → Slack, whatsapp → WhatsApp, signal → Signal,
  imessage → iMessage, sms → SMS, email → Email, matrix → Matrix, mattermost → Mattermost, teams → Microsoft Teams,
  cron → Scheduled job, cli → Terminal, oneshot → One-off run, subagent → Subagent, webhook → Webhook, api → API,
  tool → Tool; anything else with `-`/`_` as spaces and a capital first letter; none for desktop, dispatch, tui, ios,
  app or empty. `handoff_platform` wins over `source`.
- Gateway words (`S/phone-header-state.ts:83-92`).
- Answered by (`S/phone-notices.ts:232-262`): set by the gateway's status line
  "Model fallback: X via P unavailable (reason); using Y via Q." or "Provider fallback: X unavailable; using Y for this
  response"; cleared by "Primary model restored:". It shows while the chat's model is still one of the pair
  (`phone-chat-menu-model.ts:84-86`).
- A "Copy session info" button copies every row as `Label: value (note)` lines with the raw ids: the model and
  provider ids, "Answered by: <fallback id> (<primary id> is unavailable on the gateway (<reason>))", and
  "Profile: Bike Shop (bike-shop)" (`session-info-sheet.tsx:73`, `:90-93,106`). The text of each row is
  selectable.

### 10.2 Native: complete the existing sheet

`ChatInfoSheet.make` (`NAT/App/Chat/ChatSheets.swift`) keeps its build: `ChatSheet.wrap` (✕ leading, inline title, no
grabber, opaque grouped page), an inset-grouped list under the 64 pt head, `ChatInfoNoteCell` (value and note, 12 pt
padding, stacking at accessibility sizes), Copy on each row's hold menu, a tap on Chat ID copying it.

- Title: **Session Info** (today "Info"). Under the head: the chat's title, or "This chat". **DECISION:** the web
  writes "Session info" and "Copy session info"; native sheet titles and buttons are Title Case throughout, so
  "Session Info" and "Copy Session Info". **Revised (UX study #178):** "Chat Info" and "Copy Chat Info": "session"
  elsewhere in the app means the sign-in, so the sheet about a chat says chat.
- Rows: the twelve of §10.1 in that order, from one pure function
  `SessionInfoRows.rows(_ source: SessionInfoSource, names: SessionInfoNames) -> [SessionInfoRow]` (a port of
  `sessionInfoRows`, unit-tested with the web's cases), where
  `SessionInfoRow { label, value, note, mono, copy }`.
- Kept native choices: Reasoning uses `effortLabel` ("Extra High") rather than the web's capitalised raw word
  (`docs/spec/1x-menus.md` §4.3, an existing DECISION); the Model row's provider note is the picker's name for it.
- Profile shows the bot's name (today the raw id); its copy text keeps the id.
- Gateway shows the host with the state note; the note follows the connection while the sheet is open.
- Folder: the live `cwd` when the chat has one, else the stored row's; note: the live `branch`, else the row's
  `git_branch`. Middle-truncated to two lines; the full path is what Copy gives.
- A last section holds one row, a centred tinted button **Copy Session Info** (identifier `info.copy-all`): copies the
  lines of §10.1 to the pasteboard, success haptic, HUD "Copied" (`MenusHUD`).
- Each row keeps its hold menu › Copy (copies that row's `copy` text, else `Label: value (note)`). Identifiers
  `info.row.<label in lower-case, spaces as dashes>`.
- A bot's own chat still opens Bot Info (unchanged, `NAT/App/AppModel.swift` `makeChatScreen`).

### 10.3 Where each value comes from

`ChatMenusState` (`NAT/HermesKit/Chat/LiveChatSession+Menus.swift`) gains `usage: SessionUsage?`, `branch: String?`,
`answeredBy: ModelFallback?`.

```swift
nonisolated struct SessionUsage: Hashable, Sendable {       // AG/tui_gateway/contracts/common.py Usage; every field optional
    var total, input, output, contextUsed, contextMax: Int?
    var contextPercent: Double?; var contextEstimated: Bool?; var costUsd: Double?
    static func decode(_ json: JSONValue?) -> SessionUsage?  // nil unless an object; bad numbers read as absent
}
nonisolated struct ModelFallback: Hashable, Sendable { var primary: String; var fallback: String; var reason: String? }
```

- `usage` is replaced (never merged field by field) from: `applyModelInfo` (`info.usage` of resume, activate and
  `session.info`); `message.complete` payload `usage`; the new `session.usage` event case (payload `usage`); and the
  `session.usage` RPC answer asked once when the sheet opens (§4.5). The sheet observes the model, so a tick during a
  running turn updates Context, Tokens and Cost in place.
- `branch` from `SessionLiveInfo.branch`.
- `answeredBy`: `activityStatusUpdate` (`NAT/HermesKit/Activity/LiveChatSession+Activity.swift:200`) already recognises
  the fallback line for its notice row. It now also runs `ModelFallback.parse(text)` (the two expressions of
  `S/phone-notices.ts:232-237`, ported exactly) and sets `answeredBy`; a line containing "Primary model restored:"
  clears it. It is per chat and in memory (the web keeps it per runtime for the app session).
- The stored row: `SessionStore.listedRow(id:profile:)`; when the store does not hold it (a chat opened from a
  notification, a search hit outside the page), one `GET /api/sessions/{id}?profile=` when the sheet opens. While it
  is on its way the rows that need it are absent, then appear; no spinner, no error row if it fails.
- A chat not resumed yet (no live state): Model falls back to the stored row's `model`; Reasoning, Context and Tokens
  are absent; Cost uses the stored row.

### 10.4 States

| State | Sheet |
|---|---|
| new chat, nothing sent | Model, Reasoning (when set), Profile, Gateway, Chat ID |
| after a reply | adds Context, Tokens, Cost (when above zero), Messages, Folder |
| a fallback answered | "Answered By" first, the Model row is labelled "Chat Model" |
| Telegram thread | adds Source "Telegram" |
| offline | Gateway note "Offline"; live rows keep their last values; the `session.usage` ask fails silently |
| older Hermes without `session.usage` | rows from the events and the stored row only |
| largest text size | value and note stack under the label; nothing truncates but Folder (two lines) |

### 10.5 Acceptance

- F1 (L286) In Trip to Lisbon, Chat › ⋯ › Info shows the title "Session Info", the chat's title, Model with the
  provider under it, and after the fixture's usage: Context "24%" / "48.2K of 200K tokens", Tokens "15.4K" /
  "14.2K in · 1.2K out", Cost "$0.34" / "Estimated". In Garden plan (an actual cost) Cost reads "$0.02" with no note.
- F2 (L370) Messages, Folder (with the branch under it), Profile as the bot's name, Gateway "127.0.0.1:9970" /
  "Connected", Chat ID.
- F3 (L370) An emitted `session.usage` event while the sheet is open changes Tokens without reopening it.
- F4 (L370) An emitted `status.update` fallback line adds "Answered By" and relabels Model "Chat Model"; "Primary
  model restored:" removes it.
- F5 (L370) A Telegram chat shows Source "Telegram"; an app chat has no Source row.
- F6 (L370) Copy Session Info puts the lines on the pasteboard with raw ids (unit test on the text; UI test checks
  the HUD); a row's hold menu › Copy copies that row.
- F7 The one `session.usage` request carries only `session_id` and `profile` (the fixture rejects anything else with 4000).
- F8 Stopping the fixture with the sheet open flips Gateway's note to "Offline" within the reconnect state's own delay.

## 11. The reconnect probe (L287)

### 11.1 What the web does

`S/sidebar-probe.ts`: before re-reading the sidebar after a reconnect, ask the same question with every limit at one
(`probePath`, `:41-48`). The answer still carries each section's newest row and every pinned row; its fingerprint
(`sidebarFingerprint`, `:50-66`: those rows without `is_active`, plus the usage totals) is compared with the last full
read's. Equal, and the last full read no older than ten minutes (`SIDEBAR_PROBE_MAX_AGE_MS`, `:18`): skip the full
read. A failed or partial answer has no fingerprint, so it never skips. "A write from this phone forgets the last
read" (`:13`), except a PATCH that only sets `unread` or `hidden`, the pull-requests route, and the owner backfill
(`writeChangesSessionList`, `:88-102`). Counters `{probes, skipped, full}` (`:68-71`).

### 11.2 Native: already there; prove it, fix one rule, count it

`SessionStore.performRead(probeFirst:)` (`NAT/HermesKit/Store/SessionStore.swift:560-577`) already probes with limits
`(1, 1, 1)`, compares `SidebarFingerprint` (`NAT/HermesKit/Model/RosterSessions.swift`) and honours `timing.probeMaxAge`
(600 s). `gateway.ready` reads with `probeFirst: true` (`:486-490`); the throttled `sessions.changed` pass probes only
while the list is off screen (`:495-497`). The parity row is open because none of this is counted or tested. Work:

1. **Counters.** `private(set) var probeStats = SidebarProbeStats()` (`probes`, `skipped`, `full`), bumped in
   `performRead`. Public, so the Diagnostics stream (parity L901, "sidebar-probe stats") reads it. With
   `-HQDebugTextOut` set, each change writes `probe.txt` as `probes=2 skipped=1 full=3` (`DebugHooks.recordText`).
2. **Unread-only writes keep the last read** (port of `writeChangesSessionList`). Today every write drops the
   fingerprint, including the PATCH every chat open sends to mark it read, so the reconnect after reading one chat
   always re-reads in full, the exact cost the probe exists to save. Change:
   - `writeUnread` (`:390`) no longer sets `lastFingerprint = nil`;
   - `apply` (`:593`) stores the page's fingerprint even while unread writes are in the air;
   - `updateRow` takes `forgetsRead: Bool = true`; the Mark as Read / Mark as Unread callers pass `false`; Pin passes
     `true`.
   This is safe: the store's own value is already on screen and fenced (`unreadWrites`); if the newest or a pinned row's
   flag differs on the gateway the fingerprint differs and the full read runs; if an older row's does, the list already
   shows the truth. Pin, archive, delete, rename, move, new chat and branch keep forgetting it.
3. **One probe for two rows.** Offline's row L955 uses the same mechanism. The single entry point is
   `SessionStore.refreshAfterReconnect()` (a named wrapper over `readTask(probeFirst: true)`); the offline stream's
   "shared within 3 s" rule wraps that call. Neither stream adds a second probe or a second fingerprint. Whichever
   lands second on `m9/train` adopts the other's entry point and deletes its own.
4. The deeper read of §3.6 changes the full read's limit only; the probe stays `(1, 1, 1)`.

### 11.3 States

| Case | Requests after a reconnect |
|---|---|
| nothing changed, last read under 10 min old | one sidebar read with limits 1; no full read; the list does not move |
| a newer chat, a changed title, a pin, an unread flag on the newest row | the probe, then the top page (§11.5) |
| last read over 10 min old (rows on hand) | the top page only (§11.5); the full read if the list is on screen and the last full read is over 10 min old |
| never a full read this run (first load) | the full read only |
| the probe or the top page answers partially (a profile's store failed) | the full read |
| the probe fails (network, 5xx) | the top page; it failing too shows Retry as a failed full read does |
| a pin/archive/delete/rename/move from this phone since the last read | the full read only |
| only mark-read writes since the last read | the probe; skipped when the gateway agrees |
| pull to refresh | always the full read (unchanged) |

### 11.4 Acceptance

- G1 Launch against the fixture, wait for the list, `POST /__fixture/drop` (closes the socket; the app reconnects):
  `/__fixture/stats` shows one more `probe` and no more `full`; `probe.txt` reads `skipped=1`.
- G2 Change a row's title through `/__fixture/rows` without an event, drop the socket: one more `probe`, then one more
  `full`; the row shows the new title.
- G3 Open a chat (marks it read), go back, drop the socket: a probe and no full read.
- G4 Pin a chat, drop the socket: a full read and no probe.
- G5 Unit: `probeMaxAge` of zero never skips; a `profiles_failed` probe never skips; an unread-only write leaves the
  fingerprint; a pin clears it.
- G6 `git grep -n "limits: (1, 1, 1)"` finds one call site in HermesKit.

### 11.5 The top page (build 291, "Faster returns")

Phone logs (Oct 13–15): iOS pauses the socket 25 s after the app is left, so nearly every return reconnects; the probe
misses whenever any chat changed (a busy bot moves the newest row all the time), and the full read it fell back to
(median 1.9 s, ~570 KB, up to 40 s) ran while the open chat was catching up. Native only; the web has no such step.

- **When.** A probe-first read (a reconnect, or the off-screen `sessions.changed` pass and poll) whose probe differs,
  or whose last read is over `probeMaxAge` old, reads the **top page** instead of the full list, when all hold: a full
  read was applied this run, rows are on hand, the last read's fingerprint is kept (a pin/archive/delete/rename/move from
  this phone still forces the full read), the batched route answers (the legacy three-slice route always reads in full),
  no filter is waiting on the deep page (§3.6), and not (the list is on screen and the last full read is over
  `probeMaxAge` old). A probe answer without a fingerprint (partial) goes straight to the full read.
- **Limits** `recents 20, cron 10, messaging 10` (`SessionStore.topLimits`): a phone screen shows ~10 rows, an iPad
  ~16; busy bots churn the top of the recents, the folders change slowly. About a fifth of a full answer.
- **Merge** (`SidebarTopPage.merge`, per slice; the gateway answers each slice with its newest `limit` rows by recency
  plus every pinned row past them, `_pinned_window`):
  1. A slice with fewer rows than its limit is the whole slice: it replaces the loaded rows.
  2. Otherwise the page's newest `limit` rows are the window and their oldest recency the floor. Page rows replace or
     join the loaded rows by (id, profile). A loaded row absent from the page with recency ≥ the floor is dropped (it
     moved, was archived, deleted or emptied near the top). A loaded row below the floor is kept as it was.
  3. Every pin comes back with the page, so a kept row the page left out is no longer pinned (`pinned` cleared).
  4. Our own unread writes fence the page's rows exactly as a full read's (`apply`); kept rows already carry them.
  5. The page's fingerprint and its time are kept (it compares with a probe's as a full read's does); the full read's
     time is not, and the full read becomes **owed**. Cache write, unread watermarks and `rebuild` as after a full read.
- **The owed full read** runs when the Sessions list is on screen and the last full read is over `probeMaxAge` old
  (checked when the list appears and when a read ends), on pull to refresh, or when a filter needs the deep page
  (`readInFull`). Any full read settles it.
- **Errors.** A top page that throws shows Retry as a failed full read does (the reconnect share is given back). A
  partial answer (no fingerprint), or a gateway that turned out to 404 the batched route, falls through to the full read.
- **Counters and log.** `SidebarProbeStats.top` (probe.txt `… top=n`); the phone log's line is
  `reconnect refresh: top page (N rows, M KB) in X ms`, `… full (N rows, M KB) in X ms`, `… probe skipped in X ms` or
  `… failed in X ms`; an owed full read outside a reconnect logs `owed full read (N rows, M KB) in X ms`.
- Tests: `Tests/Sessions/SessionTopPageTests.swift` (merge rules, owed read, first load, failures).

## 12. The stand-in gateway

One fixture serves every row: `NAT/scripts/fixtures/sessions-gateway.py` (stdlib; invented data; binds 127.0.0.1; rides
on `FX/action-voice-fixture-gateway.py` for sign-in and the socket). It is extended, with today's behaviour unchanged
when no new flag or hook is used, so `UITests/sessions/SessionsTests.swift` stays green.

### 12.1 Extensions to write

| Addition | Detail |
|---|---|
| row fields | `input_tokens`, `output_tokens`, `actual_cost_usd`, `estimated_cost_usd`, `git_branch`, `tool_call_count`, `handoff_platform`, `is_active`. Seed: Garden plan 1000 in / 230 out, actual $0.02, branch `main`; Trip to Lisbon 14200 / 1200, estimated $0.34; Ship the 2.4 release notes 1,400,000 / 100,000, actual $12.50; Quarterly budget 900 / 99, estimated $0.004; Bread recipes 0 / 0, no cost; Nightly index run 300 / 0 |
| sidebar | honours `recents_limit`, `cron_limit`, `messaging_limit` (newest N plus every pinned row, as Hermes), `recents_profile`; rows with `source: cron` go to the cron slice, messaging sources (telegram, …) to the messaging slice |
| `session.usage` RPC | the chat's usage (default `{"input":14200,"output":1200,"total":15400,"calls":9,"context_used":48200,"context_max":200000,"context_percent":24,"context_estimated":false,"cost_usd":null}`); the same object rides in `session.resume`'s `info.usage`, with `branch` |
| strict params | `session.usage`, `projects.tree`, `projects.create`, `session.workspace.move` answer error **4000** for any key outside §4's sets |
| `POST /__fixture/rows` | `{"id":"s-tg","set":{…}}` creates or patches a chat (any row field, `usage`, `messages`); `{"id":…,"delete":true}`; optional `"event":true` broadcasts `sessions.changed` |
| `POST /__fixture/emit` | `{"type":"session.usage","session_id":"s-trip","payload":{…}}` sends that event to every socket (the id is mapped to the runtime id) |
| `POST /__fixture/fail` | also RPCs: `{"rpc":"projects.create","message":"boom","code":-32001,"count":1}`, `{"rpc":"prompt.submit","drop":true}` (close the socket without answering: a lost send), `{"rpc":…,"delay":5}`; REST gains `"prefix":true` |
| `POST /__fixture/mode` | `{"oldGateway":true}` (sidebar route 404; `projects.*` and `session.usage` answer -32601), `{"badRows":true}` (§14), `{"sidebarDelay":4}` |
| `POST /__fixture/drop` | closes every WebSocket |
| `POST /__fixture/burst` | `{"count":200,"interval":0.02}` `sessions.changed` events |
| `GET /__fixture/stats` | `{"sidebar":{"probe":n,"full":n,"deep":n}}` (limit 1 / 50 / 300) |
| `--seed big` | 2,000 chats over 12 bots and 40 projects, 30 pinned, 200 unread, 60 archived, random tokens and costs, 20 Telegram and 20 scheduled rows; fixed random seed |

### 12.2 Start and stop (builders: 9970-9974)

```sh
cd /Users/me/Projects/hermes-hq-native-wt/m9-sessions
mkdir -p build/fixtures && chmod 700 build/fixtures
lsof -nP -iTCP:9970 -sTCP:LISTEN && { echo "9970 busy"; exit 1; }
python3 scripts/fixtures/sessions-gateway.py --port 9970 --credentials build/fixtures/sessions.json > build/fixtures/sessions.log 2>&1 &
echo $! > build/fixtures/sessions.pid
curl -s http://127.0.0.1:9970/__fixture/stats
kill $(cat build/fixtures/sessions.pid)          # stop only the one you started
```

| Port | Use | Command |
|---|---|---|
| 9970 | every row, default seed | as above |
| 9971 | load | `python3 scripts/fixtures/sessions-gateway.py --port 9971 --seed big --credentials build/fixtures/sessions-big.json &` |
| 9972 | older gateway | start on 9972, then `curl -s -X POST http://127.0.0.1:9972/__fixture/mode -d '{"oldGateway":true}'` |
| 9973, 9974 | spare (a second simulator's run, a bisect) | |

End-to-end UI tests: `HQN_SESSIONS_PORT=9970 scripts/e2e-sessions.sh <UDID>` (the script starts and stops its own
fixture on that port and refuses a busy one; stop a hand-started instance first). New tests go in
`UITests/sessions/SessionsTests+Filter.swift`, `+Chips.swift`, `+Row.swift`, `+Info.swift`, `+Probe.swift` as extensions
of `SessionsTests`, so `HQN_SESSIONS_ONLY="test20_…"` keeps working.

Simulator (reuse when it exists; never the default one):
```sh
UDID=$(xcrun simctl list devices | sed -n 's/.*HQN-m9-sessions (\([0-9A-F-]*\)).*/\1/p' | head -1)
[ -n "$UDID" ] || UDID=$(xcrun simctl create "HQN-m9-sessions" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0)
```
Shut down only that simulator when the stage ends (`xcrun simctl shutdown "$UDID"`).

### 12.3 Which fixture proves which row

| Row | Fixture | Hooks used |
|---|---|---|
| L255 | 9970 | default seed (two chats with different created/updated order via `/__fixture/rows`) |
| L256 | 9970 | `/__fixture/rows` for a working chat (`is_active`), default projects |
| L257 | 9970 | `/__fixture/state` (PATCH log), `/__fixture/fail` with `prefix` |
| L258, L259 | 9970 | none |
| L260, L282 | 9970 (three bots); 9971 (twelve bots) | `/__fixture/state` to prove no extra calls |
| L261 | 9970; 9972 for the unsupported words | `/__fixture/fail` `{"rpc":"projects.create"}` |
| L262 | 9970 | seed tokens and costs |
| L264 | 9970 | `{"rpc":"prompt.submit","drop":true}` |
| L286, L370 | 9970; 9972 without `session.usage` | `/__fixture/emit`, `/__fixture/rows` for a Telegram chat |
| L287 | 9970 | `/__fixture/drop`, `/__fixture/stats`, `/__fixture/rows` |

## 13. Tests to add (summary)

- `Tests/SessionListPipelineTests.swift`: every sort, every grouping, the filters alone and combined, pinned first,
  Tokens/Cost flat, C-07 (a project the list does not have is not counted), ties, 5,000-row timing.
- `Tests/SessionFilterWordsTests.swift`: `filterCount`, the button label and value, the strip text table of §6.2, the
  menu subtitles ("Any", "None", "N Selected", Show's eight: "Chats" to "Outside, Background, Archived"), Cost hidden
  until spend.
- `Tests/SessionRowWordsTests.swift`: compact tokens, cost, the trailing text table of §9.2, metadata, pending
  precedence (`rowPending`'s three cases from `S/stress-b.test.ts:69-74`), the VoiceOver label.
- `Tests/SessionInfoRowsTests.swift`: the row list for each state of §10.4, counts, percent clamp, cost decimals,
  source names, the fallback parser on both lines and on "restored", the copied text.
- `Tests/SessionStoreTests.swift` additions: prefs round-trip and an old file, lenient decode of the new row fields,
  `markAllRead` (both sources, failures, retry set, read-only), the deeper limit, the probe rules of §11.4 G5.
- `Tests/LostSendsTests.swift`: note, clear, first, purge, disk round-trip, caps.
- UI tests per the acceptance lists (A1-A10, B1-B4, C1-C7, D1-D4, E1-E7, F1-F8, G1-G4), each with a screenshot named
  `sessions-<check>.png` in `TEST_RUNNER_HQN_SHOTS_DIR`.

## 14. STRESS PLAN

Stress tester: ports 9975-9979 (9975 default seed, 9976 `--seed big`, 9977 older gateway, 9978 bad rows, 9979 spare),
simulator `HQN-m9-sessions-s`. Rerun a flaky UI test before calling it a failure; never loosen an assertion.

```sh
cd /Users/me/Projects/hermes-hq-native-wt/m9-sessions
mkdir -p build/fixtures && chmod 700 build/fixtures
for p in 9975 9976 9977 9978; do lsof -nP -iTCP:$p -sTCP:LISTEN && { echo "$p busy"; exit 1; }; done
python3 scripts/fixtures/sessions-gateway.py --port 9975 --credentials build/fixtures/stress.json     > build/fixtures/stress.log 2>&1 &     echo $! > build/fixtures/stress.pid
python3 scripts/fixtures/sessions-gateway.py --port 9976 --seed big --credentials build/fixtures/stress-big.json > build/fixtures/stress-big.log 2>&1 & echo $! > build/fixtures/stress-big.pid
python3 scripts/fixtures/sessions-gateway.py --port 9977 --credentials build/fixtures/stress-old.json > build/fixtures/stress-old.log 2>&1 & echo $! > build/fixtures/stress-old.pid
python3 scripts/fixtures/sessions-gateway.py --port 9978 --credentials build/fixtures/stress-bad.json > build/fixtures/stress-bad.log 2>&1 & echo $! > build/fixtures/stress-bad.pid
sleep 1
curl -s -X POST http://127.0.0.1:9977/__fixture/mode -d '{"oldGateway":true}'
curl -s -X POST http://127.0.0.1:9978/__fixture/mode -d '{"badRows":true}'
UDID=$(xcrun simctl list devices | sed -n 's/.*HQN-m9-sessions-s (\([0-9A-F-]*\)).*/\1/p' | head -1)
[ -n "$UDID" ] || UDID=$(xcrun simctl create "HQN-m9-sessions-s" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0)
HQN_SESSIONS_PORT=9979 scripts/e2e-sessions.sh "$UDID"       # the scripted suite, on the spare port
# when the stage ends: kill only your own pids, shut down only your own simulator
for f in build/fixtures/stress*.pid; do kill "$(cat "$f")" 2>/dev/null; done; xcrun simctl shutdown "$UDID"
```
One sign-in per fixture start: never restart a fixture in a loop (each restart ends the simulator's sign-in), and
never retry a failed sign-in in a loop.

**Load**
- `--seed big` (2,000 chats, 12 bots, 40 projects). First paint from the cache on relaunch under 300 ms after the tab
  shows; first network paint is the fixture's time plus one frame.
- Every menu toggle to a settled list in under 100 ms with 300 rows loaded (Instruments or `-HQDebugMotionTrace`);
  no dropped frame over 2 frames while scrolling 300 rows with Tokens and Cost on.
- Twelve chips, then `/__fixture/rows` to forty bots: the rail scrolls without a hitch; tapping chips ten times a
  second for five seconds leaves the list matching the last tap and sends at most one deeper read.
- Mark All as Read with 200 unread: at most four PATCHes in flight, the UI stays responsive, the badge reaches zero,
  the fixture log holds exactly 200 writes, none repeated.
- Session Info with a `session.usage` event every 50 ms for 20 s: the sheet stays responsive and shows the last one.

**Speed**
- `{"sidebarDelay":4}`: the cached list shows at once; filters, sort and chips answer instantly meanwhile; the late
  page lands without a jump of the scroll position and without undoing a toggle made while it was in the air.
- `projects.tree` delayed 5 s: the Filter menu opens at once without projects; it never blocks on the read.
- `session.usage` delayed 5 s: the sheet opens at once with what it has (the ask times out at 3 s, silently).

**Bad network**
- Sidebar 500, 401 and a hung read: the list keeps the cache and its existing failure states; every filter still works.
- Mark All as Read with every write failing, with half failing, and with the fixture stopped: the alert words of
  §5.6; Try Again after the fixture is back succeeds with only the failed chats.
- `projects.create` failing, timing out (`delay` 40), and answering after Cancel: no stale HUD, no crash.
- Socket dropped while the Filter menu is open, while the sheet is open, mid-Mark All as Read: the menu stays usable;
  Gateway's note changes; the probe rules of §11.3 hold (`/__fixture/stats`).
- 50 socket drops in a row, 2 s apart, with nothing changed: 50 probes, zero full reads.

**Bad data** (`{"badRows":true}` on 9978, and `/__fixture/rows`)
- Rows with: no id (dropped), null title and preview, a 300-character title, emoji and right-to-left titles, tokens as
  strings, negative, NaN, 1e15; cost negative, 1e9, a string; `last_active` 0 and one year ahead; `started_at` missing;
  an unknown `source`; a `profile` not in the roster (owner shown as the raw name, default head, no chip); the same id
  under two bots; `cwd` null and a 400-character path; `git_branch` 200 characters.
- `projects.tree` answering an empty list, a project without a path, two projects with one label, two bots with one
  folder, a null where the list should be: the menu lists what is sound and never crashes.
- `session.usage` answering `{}`, strings for numbers, `context_max` 0, percent 250 and -3, cost 0: rows that cannot
  be said are absent; percent clamps to 0…100.
- A fallback line with odd spacing, no reason, or a model id with slashes and brackets: parsed or ignored, never a
  half-filled row.
- A corrupt or newer-version device-state file: defaults, with the unread state kept when it can be read.

**Interruption**
- Background and foreground with the Filter menu open, with the New Project alert open (typed words kept), with
  Session Info open.
- `/__fixture/burst` (200 `sessions.changed` in 4 s) with the menu open, while scrolling, during Mark All as Read: one
  read per throttle window, the menu stays open, toggles are not undone.
- Open a chat from the list while Mark All as Read is in flight; leave Sessions for Bots and come back mid-read.
- A chat finishing a turn while its row is on screen under Group By Status: it moves from Working to Done once,
  animated, and the scroll position holds.
- A phone call banner and a notification over the chips rail: the header keeps its height.
- Kill the app during Mark All as Read: after relaunch the list matches the gateway (some read, some not; none stuck).

**Relaunch**
- Sort By, Group By, Row Detail, Status, Project, Archived and Background Runs come back as left; the strip is present
  at first paint; the chip is not (the list opens on All).
- A draft and a lost send both survive a kill; the lost send returns as a marked bubble when its chat opens.
- Sign out and in again: prefs are per gateway account; another account starts on defaults; lost sends and drafts of
  the signed-out account are gone.
- Launch offline: cached rows, working filters, Gateway "Offline" in the sheet, no alert on its own.
- Update over an older build's state file: unread dots and Background Runs keep their values.

**Accessibility sizes**
- At AX1, AX3 and AX5: the rows of §9 (with Tokens, Cost and Time on, and with a pending line), the chips rail, the
  strip, the empty state, the Session Info sheet and the New Project alert. Nothing clips or overlaps; wrapping rows
  keep 13 pt above and below; the strip's text truncates in its capsule rather than pushing off screen.
- VoiceOver: the Filter button's label and value, each menu item's state, the chips' selected trait, the strip's
  "Showing … Clear filters", the row's one-stop label, each Info row as "label, value, note".
- Reduce Motion: no fades on the strip and rail; list updates without animation. Reduce Transparency and Increase
  Contrast: the header and strip stay legible (the system's glass handles both; the opaque fallback is already plain).
- Dark and light, and the smallest phone the runtime offers (the rail and the trailing text are the tight spots).

## 15. Build order (one feature at a time) and files

Each step builds, passes its tests against 9970 and could ship alone.

| Step | Rows | Files |
|---|---|---|
| 1 data | (none visible) | `HermesKit/Model/RosterSessions.swift`, `HermesKit/Contracts.swift`, new `HermesKit/Model/SessionListPipeline.swift`, new `HermesKit/Model/SessionFilterWords.swift`, `HermesKit/Store/SessionStore.swift` (prefs, botFilter, statuses, deeper read), fixture extensions |
| 2 menu | L255, L256, L257, L258 | `App/Sessions/SessionsViewController.swift`, new `App/Sessions/SessionFilterMenu.swift`, `App/Kit/PageBarCapsule.swift` (label, updatable menu), `HermesKit/Store/SessionStore+Actions.swift` (`markAllRead`), `App/AppModel.swift` (needs-input ids) |
| 3 header | L259, L260, L282 | new `App/Sessions/SessionsHeaderView.swift`, `App/Kit/PageFilterToken.swift` (identifier), `App/Sessions/SessionsOrganizer.swift` (compose with a chip), empty state |
| 4 row | L262, L264 | `App/Sessions/SessionRowViews.swift`, new `HermesKit/Chat/LostSends.swift`, `HermesKit/Chat/LiveChatSession.swift` and `+Sync`, `+ChatActions` (note, clear, restore), `App/AppModel.swift` (pending wiring, purge) |
| 5 project | L261 | `App/Sessions/SessionsOrganizer.swift` |
| 6 info | L286, L370 | `App/Chat/ChatSheets.swift`, new `HermesKit/Chat/SessionInfoRows.swift`, `HermesKit/Chat/LiveChatSession+Menus.swift`, `+Events.swift`, `HermesKit/Activity/LiveChatSession+Activity.swift` |
| 7 probe | L287 | `HermesKit/Store/SessionStore.swift`, `HermesKit/Store/SessionStore+Actions.swift` |

Shared files other streams also touch (`Contracts.swift`, `AppModel.swift`, `PageBarCapsule.swift`,
`LiveChatSession*.swift`): add, do not reorder; keep each change in a marked block (`// [sessions-m9]`) so merges on
`m9/train` stay mechanical. Do not edit `docs/parity-240.md` or `docs/parity.md`.

### Chats the old password sign-in made (next-20-20 B8, 2026-10-25)

- Hermes stamps a chat with the sign-in that made it (`user_id`: `nous:<id>`, `basic:<username>` for the dashboard
  password sign-in). Only `basic:<username>` itself may change a `basic:` chat, so once the password sign-in is off no
  current sign-in can delete, archive or rename one: a bare `permission_denied`.
- The row keeps the stamp (`SidebarSessionRow.userId` → `SessionSummary.owner`, `ChatMenuState.owner`). A refused edit on
  a `basic:` chat says "Only the old password sign-in can change this chat. Update the notification add-on in Settings ›
  Notifications, then ask your bot to give these chats to you." (`SessionActionText.refusedPasswordChat`); every other
  refusal keeps `SessionActionText.refused`.
- **DECISION:** the add-on (hermes-hq-push 0.9.3, `own_chats.install_password_chats`) hands `basic:` chats only to the one
  sign-in the computer's owner names in config.yaml (`hermes_hq.password_chats_owner`), never to "whoever is signed in":
  on a shared gateway that would give them to every Nous user. Naming it is the owner's act, so the app only says what to
  ask for.
- **DECISION:** `PushPolicy.current` does not require 0.9.3's `passwordChats`: the hand-over does nothing until the owner
  names a sign-in, so an Update offer to every tester would gain most of them nothing (and fix/n20-addon-offers is
  changing `current` for 0.9.2 now). The refusal's own words point at the update for those who need it.
- The words fit the alert's 160 characters, so they are never cut.

## 16. Left out, and why

- **Bot chat rows and their short menu** (part of L282): not built, by the owner's 2026-10-04 decision (§7.6).
- **Group By Bot, Manual order, Pull Request filter, Inbox Style, Profile Rail options**: desktop-only on the web too
  (`S/ui-lists/filter-menu.ts:4-5,90`; owner Q14).
- **Load more past the first page**: not one of this stream's rows; the deeper read of §3.6 covers filtering.
- **Session Info from a Sessions row's menu**: the web opens it from the chat's menu only; unchanged.
- **Owner to-do**: none. Every call here exists in the installed Hermes (`AG/` contracts) and nothing touches the push
  relay, a plugin, or the real gateway.
