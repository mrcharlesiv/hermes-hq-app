# 3x · Capabilities: Tools, Connectors (MCP), Plugins and Connect Apps

Stream `capabilities`, run m9. 20 rows (16 ❌, 4 🟡): §18 L711, L714, L715, L716, L718, L719, L720, L721, L722,
L723, L724, L725, L726, L727, L728, L729 · §22 L853, L875 · §27 L996, L997. The row list, verbatim, is in
`docs/briefs/m9/capabilities-rows.md`.

Current status is in Revision 3 just below and in §17. A row is done only when it is implemented AND seen working
on the stream's simulator against a stand-in gateway.

### Revision 3 (2026-10-13, after merging m9/train with ipad, desktoplook, offline, a11y, talk, sessions)

Status has moved on since revision 2: the builder built all 20 rows (commits `cadf577`, `8e40f02`, `2afa5ed`) and
recorded outcomes in `docs/briefs/m9/capabilities-rows.md`. This revision does not restart anything. It merges
the train, records what the merge broke or left behind, and lists the work still owed before a row may ship. The
full list is **§17**; the extra stress items are **§14.9**. Where §17 disagrees with older text, §17 wins.

What the spec writer saw in this pass (and nothing more): the merge had four conflicts
(`CapabilitiesModel.swift`, `CapabilitiesViewController.swift`, `DebugHooks.swift`, `SettingsNavigator.swift`),
resolved keeping both sides; `scripts/build.sh build` on "HQN-m9-capabilities" exits 0 for the native identity.
The original identity was **not** built, no unit or UI test was rerun, and no screen was looked at after the
merge. `docs/briefs/m9/capabilities-report.md` still says `RESULTS_PLACEHOLDER` where the test counts belong and
`build/last-e2e-capabilities.log` holds no test results, so the "done" outcomes rest on the builder's notes alone.

DECISION R3-a: the outcomes in the rows file are kept, not reset to "todo" (the stream is continued, not
restarted), but every "done" there means "seen before this merge". No row may go to Ship until the §17 gate
(17.1 to 17.3) has been run on the merged tree and the report carries real numbers.

| # | What changed | Where |
|---|---|---|
| R15 | The signed-in window root is now `RootSplitController`, not `MainTabController`. Try It (`ConnectAppsChat.open`) reads `window.rootViewController as? MainTabController` and finds the chat with `navigation.topViewController`; both are wrong in two panes. | §17.2 |
| R16 | The desktoplook font and page migration has not been run over this stream's files (8 files flagged by `scripts/desktoplook-migrate.py --check`); `ThemeLintTests` will fail the unit run until it is. | §17.1 |
| R17 | The a11y source scans now fail the unit run (the soft marker is gone). This stream posts announcements directly in six places and has one unguarded animation. | §17.1 |
| R18 | User-facing strings say "iPhone" in eight places; the app now runs on iPad and must say `\(DeviceWord.name)`. | §17.1 |
| R19 | `statusTimer` is a `Task` from `PowerPolls.loop` (train's offline work); skills and connector reads already go through `QueryRetry.read`. Tools, plugins and Connect Apps reads do not. | §17.4 |
| R20 | The builder's known gaps are now work items with acceptance checks, not notes. | §17.5 |

### Revision 2 (2026-10-13, after merging m9/train at build 251)

The first draft left several facts for the builder to look up and cut three rows short. This revision read the
sources and settles them. Where the text below disagrees with an older reading, this list wins.

| # | What changed | Where |
|---|---|---|
| R1 | `mcp.servers.add` **refuses** an existing name (error 4090 `server 'X' already exists`, `H:tui_gateway/methods_tools.py:1584-1585`); it never replaces. `tools.configure` is not profile-scoped (it reads the profile from a live session only, L1338-1352), so it cannot save another bot's tool rules. The tool editor therefore saves with remove-then-add and a rollback. | §5.5 |
| R2 | `GET /api/config` returns `mcp_servers` **unredacted** (`H:hermes_cli/web_routers/config_env.py:80-90`; only keys starting `_` are dropped). The redaction guard stays as a defence, but is not expected to fire. | §5.5, §6 |
| R3 | MCP sign-in uses the app's existing `WebAuthBrowser` (`ASWebAuthenticationSession` driven through the Objective-C runtime, `N:HermesKit/Net/NousSignIn.swift:17-52`), exactly as Sign in with Nous does with the same loopback relay. Not `SFSafariViewController`: SafariServices and AuthenticationServices must not be linked (linking AuthenticationServices cost 1.3 s of launch; the note is in that file). DECISION 5.4-a is replaced. | §5.4 |
| R4 | The app's URL scheme and Keychain names depend on the identity (`AppIdentity.current`: `hermes` for the shipped "original" identity, `hermeshq-native` for the native one). Nothing in Connect Apps may hard-code `hermes://`. | §10.3, §10.8 |
| R5 | The Composio Keychain item is the **same item the web app wrote** (`com.charlesmcdowell.dispatch.composio` / `api-key`, `ref:ios/App/App/HermesComposio.swift:196-198`) when the build is the original identity. A key the owner saved in build ≤ 240 is found by the native build. The old "clear the key on first launch" decision (14.6-a) is **withdrawn**: it would have erased the owner's working key. | §10.3, §14.6 |
| R6 | `SkillInfo.usage` already exists natively but a missing number is read as `0` (`N:HermesKit/Store/CapabilitiesStore.swift:44`). "Disable Unused" on a gateway that sends no usage would then switch off **every** skill. The parse changes to `Int?`. | §3.2 |
| R7 | A toolset row's `available` is always equal to `enabled` (`H:hermes_cli/web_routers/tools.py:275`). It must not disable the switch. | §4 |
| R8 | The hidden toolsets are exactly `discord`, `discord_admin`, `yuanbao`, `context_engine`, `moa` (`V:lib/desktop-toolsets.ts:11-20`). Labels drop a leading emoji (`V:app/settings/helpers.ts:12-16`). | §4 |
| R9 | Row L716 now includes tool **setup** on the phone (provider choice, keys, one-time install, terminal backend, image model). DECISION 4-b is replaced by 4-c. | §4.3 |
| R10 | Row L722 now includes **Install from Git** and plugin **settings**. Only the embedded catalog picker (a docs web page in an iframe) is left out. DECISION 9-b is replaced by 9-c. `update` and `remove` take `name`, not `key` (`V:store/agent-plugins.ts:376, 412`). | §9 |
| R11 | Composio answer shapes corrected from `ref:src/composio/api.ts` (no-auth flag, 403 wording, account id, session user id, featured actions first) and the connect outcomes from `connect.ts`. | §10.2, §10.8 |
| R12 | `POST /api/env/reveal` is limited to 5 calls per 30 s (429 `Too many reveal requests. Try again shortly.`) and works with the app's cookie sign-in (`H:hermes_cli/web_routers/config_env.py:1085-1107`, `web_server.py:483-497`). | §10.4 |
| R13 | The web counts issues for the active profile only; native counts every bot (DECISION 8.1-b). Server names are shown in readable form ("Link Cli"), as the web does (r3-46). | §8 |
| R14 | `LoopbackRelay.listen` takes a closure: `listen(closeBrowser: @escaping @Sendable () -> Void, lifetime:)`. | §5.4 |

---

## 0. Conventions

### 0.1 Citation key

| Prefix | Root (read only) |
|---|---|
| `ref:` | `/Users/me/Projects/hermes-hq-native-ref240/` (the web app, build 240) |
| `V:` | `ref:vendor/hermes/apps/desktop/src/` |
| `H:` | `/Users/me/.hermes/hermes-agent/` (Hermes itself; read only, never run, never import) |
| `N:` | this worktree (`/Users/me/Projects/hermes-hq-native-wt/m9-capabilities/`) |
| `mem:` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` (owner's notes) |

### 0.2 Wire rules that bite in this area

1. **Unknown RPC params are refused** (error 4000). Send exactly the params listed per method in §12. In particular
   `reload.mcp` takes **no** `profile` (`H:tui_gateway/contracts/tools_mcp_plugins.py`).
2. **REST is scoped with `?profile=<bot>`**, RPC with a `profile` param. The existing `CapabilitiesService` already does
   both (`N:HermesKit/Store/CapabilitiesStore.swift`); new calls follow the same helpers and the same per-profile
   serial write queue (`serial(profile)`).
3. **Read-only gateway** (`readOnlyGateway` in `CapabilitiesStore`): every write control in this spec is hidden, not
   disabled, when it is set; the lists still load.
4. **An old Hermes** answers an unknown RPC method with a JSON-RPC "method not found" error and an unknown REST route
   with 404. Every new surface has a plain state for that (wording in each section); none shows a dead control.
5. Words: the web app's desktop copy says "this computer" / "this device" / "mcp.json on this computer". On the phone
   the config lives on the gateway. **DECISION (0.2-a):** native copy says "your gateway" wherever desktop says
   "this computer". Exact strings are given below and are the ones to ship.
6. The word "Dispatch" appears only in storage keys and wire values kept for compatibility with the web app
   (`dispatch-composio`, `dispatch-<id>` user ids). It must not reach a label, alert, accessibility label or log the
   user can open.

### 0.3 What exists already (extend, do not restart)

| Thing | Where | State |
|---|---|---|
| Capabilities page, two tabs, bot picker, search | `N:App/Capabilities/CapabilitiesViewController.swift`, `CapabilitiesModel.swift` | works |
| Skill on/off, skill page, uninstall, official "Get" | same + `SkillPageController.swift` | works; install has no confirm and no progress notice |
| MCP list + status + on/off | `CapabilitiesStore.swift` (`mcp.servers.list`, `mcp.servers.status`, `PUT /api/mcp/servers/<name>/enabled`, `reload.mcp`) | works |
| Loopback listener | `N:HermesKit/Net/LoopbackRelay.swift` (`listen(closeBrowser:lifetime:)` → `(id, redirectURI)`, `wait`, `cancel`, `cancelAll`, `liveListeners`) | works, only the Nous sign-in uses it |
| Browser sign-in sheet | `N:HermesKit/Net/NousSignIn.swift`: `NousBrowser` protocol, `WebAuthBrowser`, `WebAuthRuntime.makeSession(url:customScheme:handler:)` / `start` / `cancel` | works; the only allowed way to show a sign-in page (no linked AuthenticationServices or SafariServices) |
| App identity | `N:HermesKit/Net/AppIdentity.swift` (`AppIdentity.current.urlScheme`, `.bundleId`) | works |
| Gateway keys (env) | `N:HermesKit/Settings/GatewaySettingsAPI.swift` (`PUT/DELETE /api/env`, `POST /api/env/reveal`), `N:App/Settings/Config/KeysPages.swift` | works; reuse for tool keys and the Composio key |
| Feature flags | none natively | Connect Apps adds one constant (§10.1) |
| More registry | `N:App/Pages/PagesTabs.swift` (`MoreRow`, `MoreSection`, `registerMoreSection`), `MoreViewController.swift` | no trailing value on rows |
| Gateway card on More | `N:App/Integration/M2Wiring.swift` ("account" section), `GatewayCardView` | works (row L873, not ours) |
| Tab badges | `N:App/Root/MainTabController.swift` `updateBadges()` | Bots and Sessions only |
| Kanban Tab picker | `N:App/Settings/TabOrderPage.swift` (Settings › Appearance › Tabs; `KanbanTabOverride`, key `pages.kanbanTab.override.<account>`) | works |
| Stand-in gateway | `N:scripts/fixtures/settings-gateway.py` | skills + MCP list/status/enabled only |

---

## 1. Shape of the work

### 1.1 New and changed files

```
HermesKit/Contracts+capabilities.swift        new   wire types + protocol additions (§12)
HermesKit/Store/CapabilitiesStore.swift       edit  toolsets, MCP add/remove/test/oauth/tools/entry/logs, plugins
HermesKit/Store/McpEntryMask.swift            new   port of ref:src/mcp-entry-mask.ts (§6)
HermesKit/Store/McpToolFilter.swift           new   port of V:lib/mcp-tool-filter.ts (§5.5)
HermesKit/Store/ServerIssues.swift            new   issue model + 24 h persistence (§8)
HermesKit/Composio/ComposioClient.swift       new   REST client, route allowlist, errors (§10.2)
HermesKit/Composio/ComposioKeychain.swift     new   one Keychain item (§10.3)
HermesKit/Composio/ComposioGateway.swift      new   gateway side: record, per-bot server, key env (§10.6)
HermesKit/Composio/ComposioModel.swift        new   load / setUp / bots / reconcile / remove (§10.5–10.7)
HermesKit/Composio/ComposioCatalog.swift      new   POPULAR, CATEGORIES, TRY_IT (copy ref:src/composio/catalog.ts)
App/Capabilities/CapabilitiesModel.swift      edit  four tabs, refresh, disable unused, issues feed
App/Capabilities/CapabilitiesViewController.swift  edit  four segments, toolbar menu
App/Capabilities/ToolsetsSections.swift       new
App/Capabilities/ToolsetPageController.swift  new
App/Capabilities/ToolsetSetupSections.swift   new   providers, keys, one-time install, terminal backend, model (§4.3)
App/Capabilities/PluginPageController.swift   new   one plugin: switch, update, uninstall, settings (§9)
App/Capabilities/PluginInstallController.swift new  Install from Git (§9.4)
App/Capabilities/PluginSettingsForm.swift     new   schema-driven settings (§9.5)
HermesKit/Store/ConnectorTitle.swift          new   port of V:lib/connector-tools.ts connectorTitle (§8.1)
App/Capabilities/ConnectorPageController.swift new  one connector: status, tools editor, Advanced
App/Capabilities/AddConnectorController.swift new
App/Capabilities/ConnectorAdvancedController.swift new  entry + logs + Remove
App/Capabilities/McpSignIn.swift              new   OAuth via LoopbackRelay (§5.4)
App/Capabilities/PluginsSections.swift        new
App/ConnectApps/…                             new   sheet, setup, home, bots, app, list, actions (§10)
App/Pages/PagesTabs.swift, MoreViewController.swift  edit  MoreRow.status (§8.3)
App/Root/MainTabController.swift              edit  More tab badge (§8.4)
App/Integration/M2Wiring.swift                edit  Capabilities row status, "integrations" section
scripts/fixtures/capabilities-gateway.py      new   (§13.1)
scripts/fixtures/composio-mock.py             new   (§13.2)
scripts/e2e-capabilities.sh                   new
Tests/Capabilities/…, UITests/capabilities/…  new
```

Both `project.yml` and `project-original.yml` must list the new folders and build.

### 1.2 Architecture fit (docs/ARCHITECTURE.md)

- Wire and state live in HermesKit; screens in `App/`. Models are `@Observable`, MainActor by default (Swift 6).
  `ComposioClient` is an `actor`; it owns its `URLSession` (ephemeral, no cookies, no cache).
- Screens are `UIHostingController` pages pushed on the existing navigation stack, small titles on pushed pages
  (`PushedPageTitles`), `List` with `.insetGrouped`. Bars and sheets use the system's glass; no custom blur, no fake
  glass.
- Every row whose text can wrap has 12–14 pt top and bottom padding and a trailing control separated by 16 pt
  (`mem:row-padding-feedback.md`: "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt top and
  bottom").
- Failures use `FailureAlert` (`N:App/Kit/FailureAlert.swift`); confirms use `TextPrompt.confirm`
  (`N:App/Kit/TextPrompt.swift:48`).
- Accessibility identifiers are listed per section; UI tests rely on them.

### 1.3 Build order (each step leaves the app working)

1. Fixture `capabilities-gateway.py` (§13.1) with tests of its own shapes.
2. Four tabs + toolbar menu (L711, L715), install confirm + notices (L714).
3. Tools tab and page, then tool setup (L716; §4.3 is the last part of that row and can follow step 6).
4. Connector page: status, sign-in (L996 + L718 OAuth), tool editor, Advanced entry (L719), logs (L720), add/remove.
5. Issues: store, More row value, tab badge, open on Connectors (L721, L853, L875).
6. Plugins tab, plugin page, Kanban switch, then Install from Git and settings (L722).
7. Composio: client + Keychain (L725, L997), setup (L724), sheet + home (L723, L726), app page (L728), bots (L727),
   account menu (L729).

Steps 2–6 and step 7 touch disjoint files after step 1 and can be split between two builders.

---

## 2. Row L711 — four tabs

> **Superseded 2026-11-03 ([cap-pages]).** Owner: tabs read as "a duct tape type solution" for pages that should be
> sub-pages (menu-nav review, "one home per page"). Capabilities is now four rows, Skills, Tools, Connectors and
> Plugins (`capabilities.hub`, rows `capabilities.row.<tab>`), each opening its list as its own page titled with its
> name (`CapabilitiesViewController`, one fixed `tab`). Settings › Bots & Tools has one Capabilities row
> (`settings.capabilities`) instead of Skills, Connectors and Plugins; search and `SettingsNavigator` open a list over
> Capabilities. A connector issue (§8) shows on More's row and on the Connectors row, which then opens on the newest
> issue's bot. More › Integrations › Connectors opens the same Connectors page. No tab is remembered (A2/A3 and the
> `capabilities.tab*` IDs below are gone).

**Web.** `V:app/capabilities/index.tsx:31` modes `['skills','toolsets','connectors','plugins']`; labels at L189–194:
"Skills", "Tools" (`en.ts:2462` `tabToolsets: 'Tools'`), "Connectors", "Plugins" (`en.ts:2515`). The phone shows the
bot picker on every tab (`ref:build/audit-c-gates.ts:14`).

**Native design.** `enum CapabilitiesTab: String, CaseIterable { skills, tools, connectors, plugins }`, titles
"Skills", "Tools", "Connectors", "Plugins". `WholeLabelSegments` already sizes segments to their labels and falls
back to a Menu at accessibility sizes (`capabilities.tab`).

Owner: "the connectors tab cuts off the word… might require a more global change"
(`mem:segmented-labels-whole.md`). Four labels are wider than two, so:

- **DECISION (2-a):** measure the four labels at the current content size against the available width. If they fit
  whole in one row, one `UISegmentedControl` with `apportionsSegmentWidthsByContent = true`. If not, two rows of two
  (Skills | Tools over Connectors | Plugins), both rows acting as one control (one selection, VoiceOver reads
  "Tab, 3 of 4"). At accessibility sizes, the existing Menu. No label is ever truncated or shrunk below the system
  font size. Worst case to check: XXXL + UI Scale 110 % on iPhone SE-width (375 pt).
- Search prompt per tab: "Search Skills", "Search Tools", "Search Connectors", "Search Plugins".
- The chosen tab survives relaunch per account (`capabilities.tab.<account>` in `UserDefaults`); a deep link
  (`SettingsNavigator` "skills"/"connectors", new "tools"/"plugins") wins over the remembered tab.
- Switching tabs keeps each tab's scroll position and never refetches a tab whose cache is under 30 s old.

**Wire.** None of its own.

**States.** Per tab: skeleton (first load), list, "No Results for “q”" (existing), load error section (existing
`LoadErrorSection`, titles "Skills failed to load", "Tools failed to load", "Connectors failed to load", "Plugins
failed to load", button "Try again"), "Waiting for your gateway…" (existing) while the link is down.

**Fixture.** `capabilities-gateway.py` (§13.1).

**Acceptance.**
- A1. All four segments visible with whole words at default size, at XXXL and at AX5 (Menu), on 375 pt and 440 pt
  wide simulators, light and dark.
- A2. Pick Plugins, kill the app, reopen Capabilities from More: Plugins is selected.
- A3. Open via Settings › Connectors: Connectors is selected regardless of A2.
- IDs: `capabilities.tab`, `capabilities.tab.skills|tools|connectors|plugins`.

---

## 3. Skills rows

### 3.1 Row L714 — install an official skill with confirm and progress notices

**Web.** `ref:src/fe-pages-r6.ts:78-90`:
- confirm title `Install ${skill} for ${profile}?`, description `${profile} can use it in new sessions. The gateway
  downloads it and checks it before it is installed.`, button `Install`;
- in-progress notice title `Installing ${skill}…`, message `For ${profile}. This can take a minute.`;
- done notice title `Installed ${skill}`, message `${profile} can use it in new sessions.`

**Native today.** `CapabilitiesModel.install(_:)` runs straight away from the "Get" capsule (`skill-get-<name>`), no
confirm, no notice.

**Native design.**
1. Tap "Get" → `TextPrompt.confirm(title: "Install \(skill) for \(bot)?", message: "\(bot) can use it in new
   sessions. The gateway downloads it and checks it before it is installed.", action: "Install")`, `.alert` style,
   Cancel is the default-cancel. `\(bot)` is the bot's display name (the same name the picker shows).
2. On Install: the "Get" capsule becomes a spinner (existing), and a **progress row** appears as the first row of
   "Available from Hermes": title "Installing \(skill)…", subtitle "For \(bot). This can take a minute.", a
   `ProgressView` trailing. It stays while the action is running, including after leaving and re-entering the page
   (the model, not the view, owns the task; it is keyed `profile + identifier`).
3. On success: the row becomes "Installed \(skill)" / "\(bot) can use it in new chats." with a green
   `checkmark.circle.fill`, success haptic, the skill moves to Installed; the row dismisses after 4 s or on tap.
   VoiceOver: post an announcement with title + message for both steps.
4. On failure: existing `FailureAlert` (including the blocked-scan wording that already exists); the progress row
   goes away; "Get" returns.
5. **DECISION (3.1-a):** the notices are inline rows on the page, not a global toast: the native app has no
   cross-page toast surface and the notice is only meaningful where the skill list is. If the user is on another tab
   or page when it finishes, the success haptic still plays and the row is there when they come back (kept until
   seen for 4 s).
6. Uninstall is unchanged (already done).

**Wire** (existing): `POST /api/skills/hub/install?profile=<p>` body `{"identifier":"official/<path>"}` →
`{"ok":true,"name":"skills-install"}`-style action; poll `GET /api/actions/<name>/status?lines=200` every 1.2 s →
`{"name","running":bool,"exit_code":int|null,"lines":[…]}`.

**States.** idle · confirm · installing · installed · failed · gateway dropped mid-install (keep "Installing…" and
resume polling when the link returns; if the action is gone after reconnect, re-read `/api/skills` and decide from
whether the skill is now installed; never report a failure that did not happen).

**Acceptance.**
- A1. "Get" on `pdf-tools` → alert reads exactly "Install pdf-tools for Atlas?" with the message above.
- A2. Cancel changes nothing (fixture `/__state` shows no install request).
- A3. Install → progress row with exact wording → "Installed pdf-tools" → skill under Installed, switch on.
- A4. Fixture told to fail the action (`/__fail {"target":"action:skills-install","mode":"exit1"}`) → FailureAlert,
  no "Installed" row.
- A5. Kill the gateway fixture for 5 s mid-install: no failure shown; completes after restart.
- IDs: `skill-install-progress-<name>`.

### 3.2 Row L715 — Refresh and "Disable unused"

**Web.** `V:app/capabilities/index.tsx:82-92` refresh invalidates skills, toolsets, official skills and the tool-call
counts. `V:app/capabilities/skills/skills-tab.tsx:239-248` "Disable unused": turns off every skill with
`enabled && usage === 0`, disabled when there is none; writes run one at a time; result notice
`Updated ${count} ${count === 1 ? 'item' : 'items'} for new sessions.` (`en.ts:2498`); failure
`Failed to update ${name}` (`en.ts:2490`). Labels: `Refresh skills` (`en.ts:2467`), `Disable unused` (`en.ts:2497`).

**Native design.** A trailing `ellipsis` (plain, as the chat bar’s; UX study #171) bar button (`capabilities.more`) with a menu that depends on the tab:

| Tab | Items |
|---|---|
| Skills | "Refresh", "Disable Unused" |
| Tools | "Refresh", Sort ▸ "Most Used" / "Least Used" / "A–Z" (§4) |
| Connectors | "Refresh", "Add Your Own…" (§5.2) |
| Plugins | "Refresh" |

Pull-to-refresh on every tab does the same as "Refresh".

- **Refresh** (Skills): re-read `/api/skills`, `/api/skills/hub/official` and usage counts, bypassing caches. While
  running, the menu item is disabled and the navigation bar shows the system refresh spinner only if pull-to-refresh
  started it. Failure with a list already on screen: keep the list, show an inline row at the top "Couldn’t refresh.
  Showing the last list." with "Try Again".
- **Disable Unused**: needs usage. The gateway sends `usage` (a number) on every skill row
  (`H:hermes_cli/web_routers/skills.py:343-376`: `s["usage"] = activity_count(…)`). Natively `SkillInfo.usage`
  exists but `CapabilitiesStore.skill` reads a missing value as `0` (`RosterText.count(row["usage"]) ?? 0`).
  **That must change first:** make it `usage: Int?` (nil when the key is absent or not a number) and update its two
  readers. Otherwise an older gateway that sends no usage would make every skill look unused and this command
  would switch them all off. (The web is safe by accident: `undefined === 0` is false.)
  - Enabled only when at least one skill has `enabled && usage == 0` (a real zero).
  - **DECISION (3.2-a):** when no row carries a usage number (`usage == nil` on every row), the item is not
    shown at all (never a control that does nothing, and never a guess).
  - **DECISION (3.2-b):** the web disables without asking; on a phone a mis-tap in a menu can switch off dozens of
    skills, so native confirms once: title "Turn off \(n) unused skills for \(bot)?" (singular "1 unused skill"),
    message "These skills have never been used. You can turn any of them back on.", action "Turn Off".
  - Runs one `PUT /api/skills/toggle` at a time through `serial(profile)`. Rows flip as each write lands. A footer
    progress line under the Installed header reads "Turning off \(done) of \(n)…".
  - Stops at the first failure: `FailureAlert` title "Couldn’t Turn Off \(name)", reason from `detail(error)`;
    the ones already done stay off.
  - Done: inline notice row "Updated \(n) items for new chats." ("1 item"), 4 s.
  - Never touches skills hidden by the current search: the web acts on the whole profile, never the filter
    (`skills-tab.tsx:138-148` comment); native does the same and says the count in the confirm.

**Wire.** `PUT /api/skills/toggle?profile=<p>` `{"name":"<skill>","enabled":false}` → `{"ok":true}`.

**Acceptance.**
- A1. Fixture seed has 6 enabled skills, 3 with usage 0 → menu shows "Disable Unused"; confirm says "3 unused
  skills"; after it, `/__state` shows exactly those 3 off, in order, never two writes in flight.
- A2. Run again → item disabled (greyed) with nothing to do.
- A3. Fixture without usage → item absent.
- A4. Fail the second write → alert names that skill; first stays off, third untouched.
- A5. Refresh after the fixture adds a skill (`/__seed`) shows it without leaving the page.

---

## 4. Row L716 — Tools tab and tool page

**Web.** `V:api/toolsets.ts`, `V:app/capabilities/toolsets/toolsets-tab.tsx`, `toolset-detail.tsx`,
`V:app/capabilities/tool-calls.ts`.
- List: `GET /api/tools/toolsets` → rows `{name,label,description,platform,platform_label,enabled,available,
  configured,tools:[names]}`. Single toggle is optimistic and silent on success; on failure it reverts and says
  `Failed to update ${label}`. "All" bulk switch runs sequentially. Sort by use; row meta on the phone is
  `"${compact(calls)} uses"` or `"N tools"`. Filter matches name, label, description and tool names. Hidden toolsets:
  `isDesktopToolsetVisible`.
- Detail: title, description or "No description." (`en.ts:2474`), "Needs keys" pill when `!configured`
  (`en.ts:2476`), tool chips with `×N`, vision hint and link (`en.ts:2477-2479`), per-toolset config panels
  (computer use, browser profile, terminal backend, provider/model/key forms), footer "Changes apply to new
  sessions." (`en.ts:2509`).
- Usage: `GET /api/analytics/usage?days=365` → `{"tools":[{"tool":"web_search","count":412},…]}`, cached 10 min per
  profile.

**Native design — list (`ToolsetsSections`).**
- One section, rows sorted by the chosen sort (default "Most Used" once counts are in; "A–Z" until then and when the
  usage read fails). Sort choice is per device (`capabilities.tools.sort`).
- Row: label (headline), description (subheadline, secondary, up to 2 lines, wraps), meta line (caption):
  "\(compact) uses" when the toolset's tools have calls, else "\(n) tools" / "1 tool"; "Needs keys" in orange text
  after a " · " when `configured == false`. Trailing `Toggle` (`toolset-switch-<name>`), 16 pt from the text. The
  row (not the switch) pushes the tool page (`toolset-row-<name>`), with a disclosure indicator.
  `compact`: 999 → "999", 1 200 → "1.2K", 12 400 → "12K", 1 500 000 → "1.5M" (same as web `compact`).
- `available` is ignored: the gateway always sends it equal to `enabled` (`H:hermes_cli/web_routers/tools.py:275`),
  so it says nothing about whether a toolset can be turned on. The switch is never disabled because of it.
- Label: `label` (or `name` when empty) with any leading emoji and spaces removed
  (`stripToolsetLabel`, `V:app/settings/helpers.ts:12-16`: `/^[\p{Emoji}\p{Extended_Pictographic}\s]+/u`; if that
  leaves nothing, keep the label as sent).
- First row of the section: "All Tools" with a switch (`toolset-switch-all`), on when every visible toolset is on.
  Flipping it writes each differing toolset one at a time; rows flip as they land; on the first failure it stops
  with `FailureAlert` "Couldn’t Update \(label)". **DECISION (4-a):** turning everything **off** asks first: "Turn
  off all tools for \(bot)?", "\(bot) won’t be able to use any tools in new chats.", "Turn Off". Turning on does
  not ask.
- The "All Tools" row is hidden while a search is active (the web's rule: bulk acts on the profile, never a filter).
- Hidden toolsets (`isDesktopToolsetVisible`, `V:lib/desktop-toolsets.ts:11-24`): a row whose `name` is one of
  `discord`, `discord_admin`, `yuanbao`, `context_engine`, `moa` is not listed. Hiding a row changes nothing on
  the gateway, and "All Tools" never writes a hidden toolset.
- Footer: "Changes apply to new chats."
- Empty (gateway returned none): "No tools on this gateway."

**Native design — tool page (`ToolsetPageController`, small title = label).**
1. Header section: description (or "No description."), a "Needs keys" orange capsule when `!configured`.
2. Row "On for \(bot)" with the switch (`toolset-page-switch`).
3. Section "Tools" (header "\(n) Tools"): one row per tool name, monospaced caption style name, trailing "×\(count)"
   when it has calls. Sorted by count then name. More than 30: first 30 and a "Show All \(n)" row.
4. Setup sections (§4.3): what the tool runs on, its keys, a one-time install, and for some tools a model or the
   terminal backend. These replace the first draft's "Open Keys" row.
5. When the toolset is `vision`: the hint "Vision uses your auxiliary model configuration — the image-capable
   model is picked there, not per-provider here." (`en.ts:2477`) and a row "Choose Vision Model" that opens the
   Settings config page holding the auxiliary vision model (on another bot's Capabilities, that bot's own Auxiliary
   Models, [model-scope] 2026-11-04) (`SettingsNavigator.open(.page(key))` with the
   `ConfigCatalog` page that owns `auxiliary.vision`; if `ConfigCatalog` has no such page, the hint alone and no
   row).
6. Footer "Changes apply to new chats."

**DECISION (4-c, replaces 4-b):** tool setup is built on the phone (§4.3): the owner asked for every row to be
finished and the web's tool page shows these panels on a phone too. Two panels stay on the computer, each with a
plain sentence instead of a control: Computer Use permissions (macOS shows its permission dialogs on the gateway
computer's own screen) and "Use My Real Browser Profile" (it copies the gateway computer's browser logins; a
consent best given at that computer). Wording in §4.3.

**Wire.**
```
GET  /api/tools/toolsets?profile=atlas
     → [{"name":"web","label":"Web","description":"Search and read pages.","platform":"cli",
         "platform_label":"CLI","enabled":true,"available":true,"configured":false,
         "tools":["web_search","web_extract"]}, …]
PUT  /api/tools/toolsets/web?profile=atlas   {"enabled":false}
     → {"ok":true,"name":"web","platform":"cli","enabled":false,"post_setup_started":false}
GET  /api/analytics/usage?days=365&profile=atlas
     → {"tools":[{"tool":"web_search","count":412}]}        (other keys ignored)
```
Usage is best effort: a failure or a 404 never shows an error; the list falls back to A–Z and "N tools".

**States.** skeleton · list · search no results · load error ("Tools failed to load", "Try again") · old gateway
(404 on list): "This gateway’s Hermes is too old to list tools here. Update Hermes on your computer." · write
pending (switch shows the new value at once, disabled until the answer) · write failed (revert + alert) · read-only
gateway (no switches, rows still open the page).

**Acceptance.**
- A1. Fixture seed: 8 toolsets, 2 hidden by the visibility rule → 6 rows; order follows usage; meta shows
  "1.2K uses" for the seeded 1 200.
- A2. Toggle `web` off → one PUT with `{"enabled":false}` and `?profile=`; survives pull-to-refresh.
- A3. Fail the PUT (500 `{"detail":"disk full"}`) → switch returns, alert "Couldn’t Update Web" with "disk full".
- A4. All Tools off → confirm → N sequential PUTs (fixture log shows no overlap) → all off; All Tools on → no
  confirm.
- A5. Usage endpoint 500 → list A–Z, no error text, Sort menu shows only "A–Z" checked and the other two disabled.
- A6. Tool page for a toolset with `configured:false` shows "Needs keys" and its Keys section (§4.3).
- A7. Switch bot in the picker → list reloads for that bot; a write in flight for the old bot still lands on the
  old bot.
- A8. A fixture toolset with `"enabled":false,"available":false` has a working switch (R7).
- A9. Fixture rows named `discord` and `moa` are not listed; a label "🌐 Web" shows as "Web".

### 4.3 Tool setup on the tool page (the rest of row L716)

**Web.** `V:app/capabilities/toolsets/toolset-detail.tsx:54-92` puts these under the tool chips:
`ToolsetConfigPanel` for every toolset (`V:app/settings/toolset-config-panel.tsx`), `TerminalBackendPanel` for
`terminal`, `ComputerUsePanel` for `computer_use`, `BrowserRealProfilePanel` for `browser`. Wording
`en.ts:2350-2436`.

**Wire** (all REST, all with `?profile=<bot>`; handlers in `H:hermes_cli/web_routers/tools.py`):
```
GET  /api/tools/toolsets/web/config?profile=atlas                                   (L345)
     → {"name":"web","has_category":true,"active_provider":"Firecrawl",
        "providers":[{"name":"Firecrawl","badge":"","tag":"Search and read pages","is_active":true,
            "status":"needs_keys","post_setup":null,"requires_nous_auth":false,"managed_nous_feature":null,
            "env_vars":[{"key":"FIRECRAWL_API_KEY","prompt":"Firecrawl API key",
                         "url":"https://firecrawl.dev","default":null,"is_set":false}],
            "web_backend":"firecrawl","capabilities":["search","extract"]},
          {"name":"DuckDuckGo","badge":"free","tag":"Search only","is_active":false,"status":"needs_setup",
            "post_setup":"ddgs","requires_nous_auth":false,"env_vars":[],
            "web_backend":"ddgs","capabilities":["search"]}],
        "active_search_backend":"firecrawl","active_extract_backend":"firecrawl",
        "search_via_nous":false,"extract_via_nous":false}
PUT  /api/tools/toolsets/web/provider?profile=atlas   {"provider":"DuckDuckGo"}      (L504)
     {"provider":"DuckDuckGo","capability":"search"}   (web only: "search" | "extract")
     → {"ok":true,"name":"web","provider":"DuckDuckGo"}  (+ "needs_nous_auth":true,"feature":"web" when a
        Nous-included row was picked without a Nous sign-in)
PUT  /api/env?profile=atlas      {"key":"FIRECRAWL_API_KEY","value":"<pasted>"}      (existing GatewaySettingsAPI)
DELETE /api/env?profile=atlas    {"key":"FIRECRAWL_API_KEY"}                         (404 = already gone = fine)
POST /api/tools/toolsets/web/post-setup?profile=atlas   {"key":"ddgs"}                (L631)
     → {"ok":true,"name":"tools-post-setup","key":"ddgs"}  then poll
GET  /api/actions/tools-post-setup/status?lines=300&profile=atlas   every 1.2 s until "running":false;
     "exit_code":0 is success
GET  /api/tools/toolsets/image_gen/models?provider=<row name>&profile=atlas           (L432)
     → {"name":"image_gen","has_models":true,"provider":"FAL","plugin":"fal","current":"flux-pro",
        "default":"flux-schnell","models":[{"id":"flux-pro","display":"FLUX Pro","speed":"~6s",
        "strengths":"Photoreal","price":"$0.05"}]}        ("has_models":false → no Model section)
PUT  /api/tools/toolsets/image_gen/model?profile=atlas  {"model":"flux-pro","provider":"FAL"}   (L472)
GET  /api/tools/terminal/backends?profile=atlas                                       (L650)
     → {"active":"local","backends":[{"name":"local","label":"Local","description":"Run on the gateway
        computer.","active":true,"status":"ready","detail":""},{"name":"docker","label":"Docker",
        "description":"…","active":false,"status":"needs_setup","detail":"Docker CLI not found — install Docker
        Desktop, docker-ce, or Podman."}]}
PUT  /api/tools/terminal/backend?profile=atlas   {"backend":"docker"}  → {"ok":true,"backend":"docker"}  (L677)
```
Keys go through `PUT /api/env`, as the web panel does (`toolset-config-panel.tsx:133`), not through
`/api/tools/toolsets/<name>/env`. The gateway refuses a value that is a redacted preview with 400; never send one.

**Native design** (`ToolsetSetupSections`, sections of the tool page, loaded when the page opens; the page shows
the header and the Tools list at once and these sections arrive under a small "Loading setup…" row).

1. **"Runs On"** (only when `has_category` and `providers` is not empty). One row per provider:
   - title = `name`; second line = `tag` (wraps); a status word on the third line: `ready` "Ready" (green),
     `needs_keys` "Needs keys" (orange), `needs_setup` "Setup required" (orange), `needs_auth` "Needs sign-in"
     (orange); no `status` from an older gateway → no status word. `badge` (for example "free") as a small
     secondary capsule after the title.
   - trailing checkmark on the row with `is_active`. Tapping another row selects it: `PUT …/provider`, the
     checkmark moves at once, the row shows a spinner until the answer, failure moves it back with `FailureAlert`
     "Couldn’t Select \(name)". Success with `needs_nous_auth: true` → an inline notice under the section: "Sign in
     with your Nous account" / "\(name) is saved but will only work once you sign in with your Nous account." with
     a button "Open Gateway" that opens Settings › Gateway (where the Nous sign-in lives). After any select, re-read
     `/config` and the toolset list (so "Needs keys" on the list updates).
   - `web` only: instead of one checkmark, each row that lists the capability gets up to two buttons under its
     text, "Use for Search" and "Use for Extract" (sending `capability`); the one in use reads "Search backend" /
     "Extract backend" with a checkmark and is not a button. Header footer: "Search: \(active_search_backend ??
     "not set") · Extract: \(active_extract_backend ?? "not set")".
   - `has_category == false`: one footer line "This toolset has no provider options — enable it and it works with
     your current setup." No providers though it has a category: "No providers are available for this toolset
     right now."
2. **"Keys"** for the active provider (and for a tapped, not yet active provider when it is the only one missing
   keys; simplest rule: show the env vars of the provider whose row is expanded; the active one is expanded by
   default, tapping a row's `info` accessory expands another). No env vars → "No API key required."
   One row per env var: title = `prompt`, value "Set" (secondary) or "Not set" (orange). Tapping opens the same
   editor sheet the Keys page uses (`KeysPages.swift`: `SecureField` + Paste button + Save, and Remove when set);
   reuse that view with `profile` = the picked bot. A `url` adds a row "Get a Key" that opens it in Safari
   (`UIApplication.open`; https only, else no row). Never prefill a value; `default` is shown as placeholder text
   only when it is not a secret-looking string (`McpEntryMask.phone.text(default) == default`).
   Remove asks "Remove \(key)?" / "\(bot) loses this key." / "Remove".
3. **"One-Time Install"** when the expanded provider has `post_setup`: text "This backend needs a one-time install
   (\(post_setup)). It runs on the computer running Hermes and may take a few minutes." and a button "Run Setup" ("Run
   Setup Again" when `status == "ready"`, with the text "Installed. Run setup again only if something is
   broken."). Running: the button reads "Installing…" with a spinner, disabled; the last log line shows under it
   (caption, one line, masked with `McpEntryMask.phone.text`). Done with exit code 0: notice "Setup complete" /
   "\(post_setup) installed.", re-read `/config`. Otherwise: "Setup finished with errors" / "Setting up
   \(post_setup) did not finish. Run it again, or check Hermes on your computer." with "Run Again". The model
   owns the poll (as skill install does), so leaving the page does not lose it.
4. **"Model"** when `GET …/models` says `has_models` and the list is not empty (image and video tools). Header
   "Model" with "\(n) models" ("1 model"). One row per model: `display`, a caption line of the non-empty parts of
   `speed` · `strengths` · `price`, "default" after the name of the gateway's default, a checkmark on `current`.
   Tap = `PUT …/model` with the row's provider; success notice "\(display) applies to new chats."; failure
   "Couldn’t Select \(display)". If the provider shown is not the active one: rows are disabled with the footer
   "Select this backend first to change its model."; otherwise the footer is "Applies to \(bot) only."
   ([model-scope], owner 2026-11-03).
5. **`terminal` only: "Execution Backend"** from `/api/tools/terminal/backends`. Row: `label`, `description`
   (wraps), status word "Ready" / "Needs setup" (orange, with `detail` on the next line) / "Unavailable" (red,
   with `detail`), checkmark on the active one ("In use" for VoiceOver). Tap a ready row = `PUT …/backend`; notice
   "Terminal commands now run via \(label). Applies to new chats." Tap a row that is not ready → confirm
   "Select \(label) anyway?" / "\(detail) Sessions that start after this change will have no terminal or file tools
   until setup is finished." (no detail: "This backend isn’t set up yet. Sessions that start after this change will
   have no terminal or file tools until setup is finished.") / "Select Anyway". When the active backend is not
   ready, a red footer: "This backend is currently selected without full setup — commands will fail until setup is
   complete." and a button "Use Local" (PUT `local`; notice "Terminal commands now run locally. Applies to new
   sessions."). Load error: "Couldn’t load terminal backends" + "Try Again".
6. **`computer_use` only:** one footer line, no control: "Computer Use needs permissions granted on your gateway
   computer’s own screen. Set it up in Hermes there." (4-c).
7. **`browser` only:** one footer line, no control: "To let \(bot) browse with your saved logins, turn on Use My
   Real Browser Profile in Hermes on the computer running Hermes." (4-c).

**States.** setup loading · loaded · `/config` 404 (older Hermes): the setup sections are simply absent and, when
`!configured`, the page falls back to one row "Open Keys" → Settings › Keys (`SettingsNavigator.openRoot("keys",
…)`) · `/config` failed otherwise: row "Couldn’t load this tool’s setup." + "Try Again" · read-only gateway: all
of the above is shown but nothing is tappable except "Get a Key"; a footer says "This gateway is read-only."

**Acceptance.**
- B1. `web` page on the fixture: two provider rows with their status words; "Use for Search" on DuckDuckGo sends
  `{"provider":"DuckDuckGo","capability":"search"}`; the footer updates after the re-read.
- B2. Keys: tap "Firecrawl API key" → paste `test-token-123` → Save → fixture saw one `PUT /api/env` for the picked
  bot; the row reads "Set"; the list row loses "Needs keys"; the app log does not contain `test-token-123`.
- B3. Run Setup on `ddgs`: "Installing…" → "Setup complete"; with `/__fail action:tools-post-setup exit1` → the
  error notice and "Run Again".
- B4. `image_gen`: the model list shows, tap sets it (`{"model":…,"provider":…}`), checkmark moves.
- B5. `terminal`: selecting Docker (needs setup) asks first with the fixture's detail sentence; "Use Local" works.
- B6. `--no-toolset-config` fixture mode (404) on a `configured:false` toolset → only "Open Keys".
- B7. `computer_use` and `browser` pages show their sentence and no switch for those panels.
- IDs: `toolset-provider-<name>`, `toolset-use-search-<name>`, `toolset-use-extract-<name>`,
  `toolset-key-<KEY>`, `toolset-post-setup`, `toolset-model-<id>`, `terminal-backend-<name>`,
  `terminal-use-local`.

---

## 5. Row L718 — add and remove an MCP server, sign in, edit the tool list

### 5.1 Connector page

**Web.** A card opens a dialog with status, tools and "Advanced" (`V:app/capabilities/connectors/`, `mcp/`,
`local-slots.tsx`; phone gates `ref:src/fe-pages-gates.ts:158-164`; wording `en.ts:146-387` `connectorsPage`).
States from `V:…/mcp-status.ts`: off, probing, unknown, ok, needs-auth, error. `canAuthenticate`: URL server, no
custom headers, and (auth `oauth` with needs-auth or error) or (no auth with needs-auth).

**Native.** Today a connector row has only a switch. Now the row pushes `ConnectorPageController` (small title = the
server name), and keeps its switch.

Page layout:
1. **Status section.** One row: a status dot + words, and under it a reason line when there is one.

   | Status | Words | Reason line | Button row |
   |---|---|---|---|
   | ok | "Connected" · "\(n) tools" | — | — |
   | probing | "Connecting…" | — | — |
   | off | "Off" | "Turn it on to read the tools it brings." | — |
   | needs-auth | "Needs sign-in" | "Sign in to let this server answer." | "Sign In" |
   | error | "Couldn’t connect" | `connectorFailureDetail` (below) | "Try Again"; and "Sign In" when `canAuthenticate` |
   | unknown / lazy | "Starts when needed" | — | "Check Now" |

   **DECISION (5.1-a):** "Needs sign-in" / "Sign In" replace the desktop's "Needs authentication" /
   "Authenticate", matching the plain wording the native list already uses ("Couldn’t connect", "Starts when
   needed").

   `connectorFailureDetail` — port `ref:src/connector-failure.ts` word for word (missing URL/command, missing
   program, credentials, timeout, refused → "The server refused the connection.", generic), plus
   `BUSY_CHECK = "The gateway was too busy to check this connector — try again."`.
2. **"On for \(bot)"** switch (`connector-page-switch`), same write as the list switch.
3. **Tools section** (§5.5).
4. **"Advanced"** row, subtitle "The configuration and logs" → `ConnectorAdvancedController` (§6, §7, and Remove).
5. Plugin-provided server (`source == "plugin"`): no switch write beyond what the gateway allows, no Remove, no tool
   editor; a footer "Provided by the \(plugin) plugin." and a row "Open Plugins" that switches to the Plugins tab.
   The gateway refuses writes with 409 `Server 'X' is provided by plugin 'P' and cannot be modified`
   (`H:hermes_cli/web_routers/mcp.py`); if one slips through, show that sentence.

"Try Again" / "Check Now" call `mcp.servers.test {profile,name}` (60 s timeout), show "Checking…" on the button,
then re-read status. A test that answers `oauth_needed: true` puts the page in needs-auth.

### 5.2 Add a server

**Web.** `V:…/add-server-draft.ts`, `add-dialog.tsx`; phone hides "Edit mcp.json"
(`ref:src/fe-pages-gates.ts:164`); description "Add an MCP server to the selected profile on your gateway."

**Native.** Menu item "Add Your Own…" (Connectors tab) and, when the list is empty, a button row "Add Your Own" under
the empty text. The empty text changes from "No connectors yet. Add them in Hermes on your computer." to "No
connectors yet." with footer "Add an MCP server \(bot) can use." Opens `AddConnectorController` as a sheet (large
detent, navigation title "Add a Connector", Cancel / Add).

Form (`Form`, grouped):

| Field | Control | Rule |
|---|---|---|
| Name | text, no autocap/autocorrect | 1–64 of letters, digits, `.`, `-`, `_`; inline red "That name is already used." when taken (case-insensitive against the loaded list); inline "Names use 1-64 letters, digits, dots, dashes, or underscores." when invalid |
| Type | segmented "Web Address" / "Command" | default Web Address. **DECISION (5.2-a):** plain words for "Streamable HTTP" / "STDIO"; the footer under the control: "A service on the internet." / "A program on the computer running Hermes." (UX study #180 dropped the technical terms) |
| URL (Web Address) | URL keyboard | must parse as http/https with a host |
| Sign-In (Web Address) | picker "None" / "OAuth" / "Bearer Token" | |
| Token (Bearer) | `SecureField` with a Paste button | never logged, never echoed; see memory rule below |
| Headers (Web Address) | rows of KEY / value, "+ Add Header" | value field is secure-entry when the key matches the mask's secret-key rule (§6) |
| Command (Command) | text | required |
| Arguments | rows, "+ Add Argument" | |
| Environment Variables | rows KEY / value, "+ Add Environment Variable" | |
| Working Directory | text | optional |

"Environment variable passthrough" from the desktop form is left out. **DECISION (5.2-b):** it names variables of
the gateway computer's shell, which a phone user cannot see; a server that needs it is added on the computer.

"Add" is enabled when `isDraftComplete` (port of the web predicate: name valid and free, and URL valid or command
non-empty; every started key/value pair has a key). On Add:
1. Button becomes "Adding…", form disabled.
2. `mcp.servers.add` (§12). Bearer token goes in `bearer_token`, never inside `config`.
3. `reload.mcp {"confirm":true}` through the existing reload helper. A reload failure after a good save is not an
   error alert: the sheet closes and the list shows a notice row "Saved. Its tools load in new chats."
   (web `en.ts:5364`).
4. Sheet closes, list re-reads, the new server's page opens. If Sign-In was OAuth, the page is in needs-auth with
   "Sign In" ready (no browser opens by itself).
5. Failure: stay on the form, `FailureAlert` title "Couldn’t Add \(name)", reason `detail(error)`. The RPC's own
   errors (`H:tui_gateway/methods_tools.py:1574-1617`): 4090 `server 'X' already exists` → the inline "That name is
   already used." (no alert); 4090 `… is provided by plugin 'P' and cannot be modified` → alert with "A plugin
   already provides a connector with this name."; 4063 `config must specify a 'url' …` → "Enter a web address or a
   command."; 4001 `server 'X' rejected: suspicious command/args configuration` → "Your gateway refused this
   command because it looks unsafe. Check the command and its arguments." Tell 4090's two meanings apart by the
   words `already exists`.

Leaving the sheet with typed content asks "Discard this connector?" / "Discard" / "Keep Editing" (swipe-down is
intercepted with `isModalInPresentation`).

Memory rule (verbatim): "I must not type the owner's API keys into apps. The owner pastes them." Tests use fixture
values only (`test-token-123`).

### 5.3 Remove a server

**Web.** Confirm title `Remove ${name}?`, body "The entry leaves mcp.json on this computer. Nothing else is
deleted.", button "Remove" (`local-slots.tsx`).

**Native.** In Advanced, a destructive row "Remove \(name)" (`connector-remove`). Confirm (action sheet anchored on
the row): title "Remove \(name)?", message "\(bot) stops using it. Nothing else is deleted from the computer running Hermes.",
"Remove". Then `mcp.servers.remove`, `reload.mcp`, pop to the list, drop its issue (§8). Failure: `FailureAlert`
"Couldn’t Remove \(name)". RPC error 4064 `server 'X' not found` counts as removed. Not shown for plugin servers or on a read-only gateway.

### 5.4 Sign in with OAuth — rows L718 (OAuth) and L996 (loopback listener)

**Web.** `V:lib/mcp-dashboard-oauth.ts` with the native bridge `ref:ios/App/App/HermesPlatformExtras.swift:182-200,
950-1076` (`oauthListen` / `oauthWait` / `oauthCancel` on an `NWListener`; the browser shows "Signed in / Return to
Hermes HQ to finish connecting." and the in-app Safari sheet is closed on the redirect only). Flow: listen →
`mcp.servers.oauth.start {name, client_redirect_uri}` → check that the `redirect_uri` inside `auth_url` equals the
listener's (else "Update the Hermes backend to support Desktop MCP OAuth callbacks.") → open `auth_url` → on
callback relay `mcp.servers.oauth.callback` → poll `mcp.servers.oauth.poll` every 1 s (pending/approved/error; give
up after 3 failed polls; time out at 360 s "Timed out waiting for MCP OAuth authorization") → always cancel the
listener, and `mcp.servers.oauth.cancel` when not approved. Success notice "Authenticated" /
`${server}: ${count} tools`.

**Native.** `LoopbackRelay` is already the general listener, so L996 is wiring plus tests, not a new listener:

```swift
@MainActor final class McpSignIn {
    enum Outcome { case signedIn(tools: Int), cancelled, failed(String) }
    func run(server: String, profile: String, from: UIViewController) async -> Outcome
}
```
1. `let browser: any NousBrowser = WebAuthBrowser(anchor: view.window)` (tests inject a URLSession driver, as the
   Nous tests do), then
   `let (id, redirect) = try await LoopbackRelay.shared.listen(closeBrowser: { Task { @MainActor in browser.close() } }, lifetime: 360)`.
2. `mcp.servers.oauth.start {profile, name, client_redirect_uri: redirect}` → `{ok, session_id, auth_url, flow}`.
   The gateway refuses a server that is not a URL server (`4001 stdio servers authenticate via env keys, not
   OAuth`) or that has headers and no `auth: oauth` (`4001 this server uses header/API-key auth, not OAuth`,
   `H:tui_gateway/methods_tools.py:1672-1676`); `canAuthenticate` (§5.1) already keeps the button away from those,
   and if one slips through its sentence is shown in the alert.
3. Parse `auth_url`; it must be `https` (or loopback http in DEBUG for the fixture); its `redirect_uri` query item
   must equal `redirect` exactly. If not: cancel, outcome `.failed("This gateway’s Hermes is too old to sign in to
   connectors from your iPhone. Update Hermes on your computer, or sign in there.")`.
4. `browser.open(authURL, userCancelled: …)`. **DECISION (5.4-a, revised):** the sign-in page opens in the system
   sign-in sheet through the app's existing `WebAuthBrowser`, the same way Sign in with Nous does
   (`N:HermesKit/Net/NousSignIn.swift:17-52`): an `ASWebAuthenticationSession` created through the Objective-C
   runtime, with the app's own scheme as a callback that never fires; the provider redirects to
   `http://127.0.0.1:<port>/callback`, the relay answers "Signed in" / "Return to Hermes HQ to finish connecting."
   and its `closeBrowser` closes the sheet. Do **not** import SafariServices or AuthenticationServices (launch
   time; see the note in that file). `prefersEphemeralWebBrowserSession` stays false, so a phone already signed in
   to the provider in Safari is not asked again. `open` returning false → `.failed("Couldn’t open the sign-in
   sheet. Try again.")`.
5. Race three things: `LoopbackRelay.shared.wait(id, timeout: 360)`, the user closing the sheet (the
   `userCancelled` callback), and a poll loop every 1 s on `mcp.servers.oauth.poll`.
   - Callback arrives → `mcp.servers.oauth.callback {profile,name,session_id,code,state,error,iss}` (send `iss` only
     when present; send `error` only when present; never both `code` and `error` empty) → keep polling.
   - Poll `approved` → outcome `.signedIn(tools: tools.count)`.
   - Poll `error` → `.failed(error_message)`; empty message → "The sign-in didn’t finish. Try again."
   - Sheet closed by the user with no callback → `.cancelled` (no alert).
   - 3 consecutive poll failures → `.failed("Lost the gateway while signing in. Try again.")`.
   - 360 s → `.failed("The sign-in took too long. Try again.")`.
6. Always: `LoopbackRelay.shared.cancel(id)`; when not signed in, `mcp.servers.oauth.cancel {profile,name,session_id}`
   (best effort, errors ignored).
7. Signed in: success haptic, `reload.mcp`, status re-read, tools re-read, the status row shows "Connected ·
   \(n) tools". Clear the server's issue (§8).
8. Failed: `FailureAlert` title "Couldn’t Sign In to \(name)".
9. Only one sign-in at a time app-wide; the "Sign In" button is disabled with "Signing in…" while it runs. Leaving
   the page (pop, switching tabs, backgrounding for more than the 360 s lifetime) cancels through step 6.
10. App backgrounded while the sheet is up: the system sheet keeps the app in the foreground in the normal case
    (it is presented inside the app). If the app is suspended anyway (the user goes Home), `NWListener` stops
    accepting. On `UIApplication.didBecomeActiveNotification`, if `wait` has already settled with an error or the
    360 s lifetime passed, the flow ends as `.failed("The sign-in didn’t finish. Try again.")` rather than spinning.
    The builder checks how `NousSignIn` treats this case and follows it; if it has no such check, add this one
    here only.

`LoopbackRelay` limits stay as they are (8 listeners, 4 connections, 10 s head, 8 KiB). Add unit tests that an MCP
callback with `iss` and with `error=access_denied` both parse (`LoopbackRelay.callback(fromRequestHead:)`).

### 5.5 Tool list editor

**Web.** `V:…/tools-list.tsx`, `use-tools-editor.ts`, `V:lib/mcp-tool-filter.ts`: the server's entry carries
`tools.include` and/or `tools.exclude`; include wins; `setDisabledTools(entry, disabled, discovered)` keeps stored
names that were not discovered this time. Wording (`en.ts connectorsPage.tools`): "Tools", "Search N tools", quick
filters "Read only" / "Turn off destructive" / "Everything on", "No tool matches these filters.", "Reading the tool
list", "Tool list unavailable.", "Sign in to ${name} to read its tools.", "${name} is off." + "Turn it on with the
switch above to read the tools it brings.", "Those tool rules were not saved.", footer "${off} tools off, ${n} back
on", "Discard", "Save changes", "Saving...".

**Native.** Tools section on the connector page:
- Source of the list: `mcp.servers.test {profile,name}` → `tools:[{name,description}]`, cached per server for the
  life of the page and re-read by "Refresh Tools" in the page's `ellipsis` menu. While reading: "Reading the
  tool list" with a spinner. Failure: "Tool list unavailable." + "Try Again". Needs auth: "Sign in to \(name) to
  read its tools." Off: "\(name) is off." / "Turn it on with the switch above to read the tools it brings."
- Header "\(n) Tools"; a search field appears above the rows when `n > 8` (prompt "Search \(n) tools").
- Each tool: name (monospaced body), description (secondary, 2 lines, wraps), trailing `Toggle`
  (`mcp-tool-switch-<name>`). First row "All Tools" switch ("Turn every tool on or off" as its accessibility hint).
- **DECISION (5.5-a):** the quick filters "Read only" and "Turn off destructive" work from a per-tool `facet`
  that only Nous-hosted connectors carry (`V:app/capabilities/connectors/derive-tools.ts:158-198`); a gateway MCP
  server's probe returns `name` and `description` only (`McpProbeTool` in the contract), and the web hides the
  filter row when fewer than two facets exist (`facetChips`, L99-103). So for these servers the web shows no quick
  filters either. Native has none; "All Tools" covers "Everything on".
- Edits are a draft. While the draft differs from the saved rules, a bottom bar (system toolbar, glass) shows
  "\(off) tools off, \(backOn) back on" ("none back on" when 0) with "Discard" and "Save". Leaving with a dirty
  draft asks "Discard changes to \(name)’s tools?".
- Save: read the current entry fresh, apply `McpToolFilter.setDisabled(entry, disabled:, discovered:)`, write, then
  `reload.mcp`. Button reads "Saving…". Failure: `FailureAlert` "Couldn’t Save", reason "Those tool rules were not
  saved." plus the gateway's detail.

**Wire for the save.** The web writes the whole `mcp_servers` map (`PUT /api/mcp/servers {"servers":{…}}`), read
from `/api/config`. That is a whole-map replace and is the riskiest write in this spec, so:
- **DECISION (5.5-c, finishing pass): recovery marker.** Remove-then-add is not atomic and this Hermes has no
  update call (checked again: the `mcp.servers.*` methods are list, status, add, remove, set_api_key, test and the
  four oauth ones). Before the remove, the old entry is kept in the Keychain (`ToolRuleRecovery.swift`, this device
  only, per gateway account; the Keychain because an entry can hold header values). It is cleared once the
  connector is known to be back. Every Connectors read for that bot (`mcpServers`, so also the issue sweep after
  a relaunch) first checks: connector present → marker dropped, nothing written; missing → the old entry is added
  back and MCP reloaded; add answers 4090 → marker dropped. A marker older than 30 days is dropped unread (a
  connector missing that long was more likely removed on purpose elsewhere). Never on a read-only gateway.
- **DECISION (5.5-b, settled):** native writes only the one server and never `PUT /api/mcp/servers`.
  Checked in Hermes: `mcp.servers.add` refuses an existing name with error 4090 `server 'X' already exists`
  (`H:tui_gateway/methods_tools.py:1584-1585`), and `tools.configure` (which takes `server:tool` names) binds its
  profile from a live session only, so it would write the launch profile for any other bot (L1338-1352). So the
  save is, inside `serial(profile)`:
  1. `GET /api/config?profile=` → `old = mcp_servers[name]` (fresh, not the page's copy). Missing → stop:
     "This connector is no longer on your gateway." and pop.
  2. `new = McpToolFilter.setDisabled(old, disabled:, discovered:)`. If `new == old`, done (no write).
  3. `mcp.servers.remove {profile, name}`.
  4. `mcp.servers.add {profile, name, config: new}` (no `bearer_token`: the entry already carries its header
     template, for example `"Authorization": "Bearer ${MCP_NAME_API_KEY}"`, and the key itself stays in the bot's
     `.env`, untouched by remove).
  5. If step 4 fails: `mcp.servers.add {profile, name, config: old}` once. If that fails too, the alert is
     "Couldn’t Save" / "\(name) was taken off \(bot) while saving and could not be put back. Add it again under
     Connectors." and the masked entry stays on screen in Advanced until the page is left, so the owner can read
     what it was. (The fixture has a mode for exactly this; see STRESS I9.)
  6. `reload.mcp`, re-read list and status.
  The same sequence is what `ref:src/composio/gateway.ts` `installServer` does for the `composio` server.
  `enabled: false` on an entry survives, because `config` is the whole entry.
- The entry comes from `GET /api/config?profile=` → `mcp_servers[name]`, which Hermes returns unredacted
  (`H:hermes_cli/web_routers/config_env.py:80-90`). As a defence against a future Hermes that redacts it: if any
  string value in the entry contains `•` or `***`, or equals what `McpEntryMask` would produce for it, the editor
  is **read only** with the footer "This connector’s tool list can be changed in Hermes on your computer."
  Writing a redacted secret back would destroy the owner's credentials; this guard is not optional.
- An entry whose `tools.include` exists (even empty) is a whitelist and stays one (`isToolEnabled`,
  `V:lib/mcp-tool-filter.ts:27-37`); `McpToolFilter` ports `readToolsFilter`, `isToolEnabled` and
  `setDisabledTools` with their tests.

**Acceptance for §5.**
- A1. Add `notes` (Web Address `http://127.0.0.1:10010/__mcp/notes`, Sign-In None) → fixture state has the entry
  for the chosen profile only; list shows it "Connected · 3 tools".
- A2. Add with a taken name → inline "That name is already used.", Add disabled, no request sent.
- A3. Add with Bearer Token `test-token-123` → request has `bearer_token`, `config` has no token; app logs
  (`log stream` for the app's subsystem during the test) do not contain `test-token-123`.
- A4. Remove → confirm wording exact → gone from fixture and list; issue (if any) cleared.
- A5. OAuth happy path against the fixture's authorize page (auto-approve): Sign In → sheet opens → closes by
  itself → "Connected · 4 tools"; fixture saw `start` with a `client_redirect_uri` of `http://127.0.0.1:<port>/callback`,
  one `callback` with `code` and `state`, polls, no `cancel`.
- A6. Deny on the authorize page → alert "Couldn’t Sign In to github"; fixture saw `cancel`.
- A7. Close the sheet by hand → no alert; fixture saw `cancel`; `LoopbackRelay.shared.liveListeners == 0`.
- A8. Old-backend mode (`--old-oauth`: `auth_url` carries the gateway's own redirect) → the "too old" sentence; the
  browser never opens.
- A9. Tool editor: turn 2 of 5 off → bar "2 tools off, none back on" → Save → fixture entry has
  `tools.exclude == [a,b]`; reopen shows them off. Turn one back on → "1 tools off…" uses singular "1 tool off".
- A10. Fixture in `--redact-config` mode → editor read-only with the footer; no write requests.
- A11. Plugin server page: no Remove, no tool switches, "Provided by the hermes-hq-browser plugin.".
- IDs: `connector-row-<name>`, `connector-page-status`, `connector-signin`, `connector-retry`, `connector-advanced`,
  `add-connector.name|type|url|auth|token|command`, `add-connector.add`, `mcp-tools-save`, `mcp-tools-discard`.

---

## 6. Row L719 — Advanced: read-only configuration with credentials hidden

**Web.** `ref:src/phone-mcp-entry.tsx:5-11`: heading "Configuration"; shows
`JSON.stringify({[name]: maskMcpEntry(entry)}, null, 2)`; missing entry → "This server is not in the gateway's
mcp.json."; footer "Read-only on iPhone, with keys, tokens and passwords hidden. Edit this server's configuration on
your gateway computer." Mask: `ref:src/mcp-entry-mask.ts` (138 lines), tests `ref:src/mcp-entry-mask.test.ts`.

**Native.** `ConnectorAdvancedController` (title "Advanced"), first section header "Configuration":
- A monospaced, selectable, horizontally scrollable text block with the masked JSON, keys in the gateway's order
  (parse with `JSONSerialization` into an order-keeping representation; do **not** round-trip through `Dictionary`
  for display — decode the `/api/config` body with a small ordered JSON reader, or sort keys with `.sortedKeys` and
  accept alphabetical order. **DECISION (6-a):** `.sortedKeys` + `.prettyPrinted` + `.withoutEscapingSlashes`;
  key order is not information the user needs and an ordered parser is not worth the risk).
- Footer: "Read-only on iPhone, with keys, tokens and passwords hidden. Edit this connector’s configuration on your
  gateway computer."
- Missing entry: "This connector is not in your gateway’s configuration." (plugin servers land here; add "It comes
  from the \(plugin) plugin." when so.)
- Context menu / Copy copies the **masked** text only. The raw entry is never put on the pasteboard, in a log, in
  state restoration or in an accessibility value.
- The raw entry is held only in the page's model and dropped on pop.

**`McpEntryMask` (HermesKit) — exact port.** `MASK = "••••••"`. Port every rule with the same names so the test
file maps one to one:
`SECRET_KEY`, `SECRET_PARAM`, `SECRET_MAPS` (`headers`, `env`, `environment`: every value masked unless the header
is in `SAFE_HEADER`), `SECRET_VALUE` (`sk-…`, `gh?_…`, `xox?-…`, JWT shape), `SECRET_FLAG` and `HEADER_FLAG` (in
`args`: the value after `--token`-style flags and `-H`/`--header` values), `TOKEN_RUN` (a UUID, or 16+
alphanumerics mixing letters and digits), URL handling (userinfo masked, token-like path runs masked, secret query
params masked), `auth` method names kept. API:

```swift
public struct McpEntryMask: Sendable {
    public static let phone = McpEntryMask()                 // web's default masker; ${VAR} refs are masked too
    public func entry(_ value: JSONValue) -> JSONValue
    public func text(_ line: String) -> String               // used for logs (§7)
}
```
Regexes use `NSRegularExpression` with the web's patterns translated literally (JS `\b`, lookbehind-free). Each
pattern from the TypeScript file is copied into a comment above its Swift twin.

**Wire.** `GET /api/config?profile=<p>` → `{…,"mcp_servers":{"github":{"url":"https://api.example/mcp",
"headers":{"Authorization":"Bearer ghp_abc…"},"auth":"oauth","tools":{"exclude":["delete_repo"]}}},…}`. Only
`mcp_servers[name]` is kept; the rest of the body is discarded at once.

**States.** loading (skeleton block) · shown · missing · load error ("Couldn’t load the configuration." + "Try
Again") · read-only gateway (same; it is read-only anyway).

**Acceptance.**
- A1. Unit: every vector in `ref:src/mcp-entry-mask.test.ts` ported to `Tests/Capabilities/McpEntryMaskTests.swift`
  and passing; plus: an `Authorization` header, an `env` map, `--api-key VALUE` in `args`,
  `https://user:pass@host/path/abcd1234efgh5678?token=x&page=2`, a JWT, and a `${GITHUB_TOKEN}` reference.
- A2. UI: fixture entry seeded with `ghp_FIXTURESECRET0123456789` → the page's full accessibility tree and the
  pasteboard after Copy do not contain `FIXTURESECRET`; they contain `••••••`.
- A3. Plugin server → the "not in your gateway’s configuration" text.
- IDs: `connector-config-text`.

---

## 7. Row L720 — MCP server logs (masked)

**Web.** `V:app/capabilities/mcp/mcp-logs.tsx`: every 2000 ms `GET /api/logs?file=mcp&lines=500`, cut to the
server's section starting at the last marker `===== starting MCP server '<name>' =====`; for a server with no
stdio section, `GET /api/logs?file=agent&lines=300&search=<name>`. The phone masks every line with `maskText`.
Empty: "No output yet." (`en.ts settings.mcp.noOutput`). Card verb "Open logs".

**Native.** Second section of Advanced: a row "Logs" → `ConnectorLogsController` (title "Logs").
- Monospaced caption text, one `Text` per line in a `LazyVStack` inside a `ScrollView`, selectable, newest at the
  bottom, the view pinned to the bottom while the user is at the bottom (stops following when they scroll up; a
  "Latest" capsule returns to the bottom).
- Poll every 2 s while the page is visible and the app is active; stop on disappear and in the background; resume on
  return. At most one request in flight; a slow answer skips ticks rather than queueing.
- Section rule exactly as the web: for a `command` (stdio) server use `file=mcp` and keep lines after the **last**
  marker for this name up to the next marker for any server; for a URL server, or when the mcp file has no marker
  for this name, use `file=agent&search=<name>&lines=300`.
- Every line passes `McpEntryMask.phone.text(_:)` before it is stored in view state. Raw lines never reach state.
- Cap: keep the newest 500 lines; a line longer than 2 000 characters is cut with "…".
- Empty: "No output yet." Error with nothing shown: "Couldn’t load the logs." + "Try Again". Error with lines
  shown: keep them, small footer "Not updating. Trying again…" (retry continues every 2 s; after 5 failures in a
  row the interval becomes 10 s).
- 400 `Unknown log file` or 404: "This gateway doesn’t keep logs for connectors." and polling stops.
- Toolbar: "Copy" (copies the masked text shown) and `ShareLink` for the same masked text.
- VoiceOver: the log is one adjustable-free text container; new lines are not announced (no chatter).

**Wire.**
```
GET /api/logs?file=mcp&lines=500&profile=atlas
    → {"file":"mcp","lines":["===== starting MCP server 'files' =====","[files] listening", …]}
GET /api/logs?file=agent&lines=300&search=github&profile=atlas
    → {"file":"agent","lines":["2026-10-12 09:14:02 WARNING mcp: github: 401 Unauthorized …"]}
```

**Acceptance.**
- A1. stdio server `files`: only lines after its last marker show; lines of `other` after the next marker do not.
- A2. Fixture appends a line (`/__log {"file":"mcp","line":"…"}`) → it appears within 3 s while at the bottom.
- A3. A seeded line `Authorization: Bearer ghp_FIXTURESECRET0123456789` shows masked; Copy output is masked.
- A4. Leave the page → fixture sees no `/api/logs` request in the next 6 s.
- A5. `--no-logs` fixture mode → the "doesn’t keep logs" text, one request only.
- IDs: `connector-logs`, `connector-logs-text`, `connector-logs-latest`.

---

## 8. Rows L721, L853, L875 — issue counts on More, on the tab, and opening Connectors

One feature (planner note: "One feature with L721 and L875 (issue counts on More rows and the tab badge). The
gateway card itself is already in native (L873).").

**Web.** `ref:src/phone-notices.ts`: `$serverIssues` keyed `${profile}::${name}`, status `error` | `needs-auth`,
kept 24 h in storage; `serverIssueSummary`: one issue → "${name} needs you to sign in again" / "${name} is
unreachable", several → "${n} MCP servers need attention". `ref:src/ui-nav/more-model.ts`: `issueCount`,
`issueValue(count)` = "N Issue" / "N Issues". `ref:src/phone-tab-bar.tsx:506, 918`: the More tab badge is the issue
count; L951–1001: the Capabilities row shows the value in red, its label for VoiceOver is "${row.label},
${status.text}", and opening it with an issue goes to `/capabilities?tab=connectors`, never into one connector's
sheet. Owner (`mem:more-tab-restore-fix.md`, r3-46): a failing server opens Capabilities on Connectors, never
inside one connector's sheet.

### 8.1 `ServerIssues` (HermesKit, `@Observable`, MainActor)

```swift
public struct ServerIssue: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case error, needsAuth = "needs-auth" }
    public let profile: String, name: String, kind: Kind, seenAt: Date
}
@Observable public final class ServerIssues {
    public private(set) var issues: [ServerIssue]            // newest first, expired ones dropped
    public var count: Int
    public var summary: String?                              // wording below
    public func report(profile: String, servers: [McpServer]) // replaces that profile's issues
    public func clear(profile: String, name: String)
    public func forget(profile: String)                       // bot deleted
}
```
- A server is an issue when it is enabled and `status == "failed"` (`.error`), or enabled and `auth == "oauth"` and
  `oauth_tokens_present == false` (`.needsAuth`) — the second needs `auth` and `oauthTokensPresent` added to
  `McpServer` from `mcp.servers.list`. `connecting`, `lazy`, `configured`, `disabled` are never issues.
- Debounce: a server must be `failed` on two reads at least 10 s apart before it becomes an issue (a gateway that
  has just restarted reports everything failed for a moment). `needs-auth` needs no second read.
- Persisted per account in `UserDefaults` (`capabilities.serverIssues.<account>`), entries older than 24 h dropped
  on load and on every read. Switching gateway swaps the set. Signing out clears it.
- `summary`: 1 issue → "\(name) needs you to sign in again" or "\(name) is unreachable"; more → "\(n) connectors
  need attention". **DECISION (8.1-a):** "connectors", not "MCP servers": the native app calls them connectors
  everywhere.
- The name in the summary is the readable one: `ConnectorTitle.title(for: name)` (HermesKit, port of
  `ref:src/connector-failure.ts` `connectorTitle`: the known-titles map first, else `_` and `-` runs become a
  space, each word capitalised, `Mcp` → `MCP`). So `github` reads "GitHub is unreachable", `my_notes-mcp` reads
  "My Notes MCP needs you to sign in again". The same helper titles failing rows on the Connectors tab.
- **DECISION (8.1-b):** the web counts issues for the active bot only (its store is fed by the one profile on
  screen); native counts every bot on the gateway (the sweep in §8.2), because on the phone a failing connector on
  a bot you are not looking at is exactly the one you would miss. The count is therefore sometimes higher than
  the web's for the same gateway; that is intended.

### 8.2 Feeding it

- Every `CapabilitiesModel.reloadServers` result is reported for its profile (already polls each 10 s on the
  Connectors tab).
- A sweep (`ServerIssueSweep`, in `App/Capabilities`) on gateway link-up (a first connect, or a drop while in the
  foreground), on foreground when the last sweep is over 10 min old (the link-up after a return from the background
  follows this rule), and after any roster change: for each bot, `mcp.servers.list` + `mcp.servers.status`, two bots at a
  time, 20 s timeout each, default bot first. Errors are ignored (a failed read never creates or clears issues).
  The sweep never runs while the link is down, never on a metered-out read-only gateway differently (reads are
  fine), and is cancelled on background.
- **DECISION (8.2-a):** at most 30 bots are swept; with more, the sweep covers the default bot and the 29 most
  recently used. (Load guard for big rosters; the Connectors tab still reports any bot the user opens.)

### 8.3 More row and VoiceOver

- `MoreRow` gains `var status: (@MainActor () -> MoreRowStatus?)?` with
  `struct MoreRowStatus { text: String; isIssue: Bool; spoken: String }`. `MoreViewController` renders it as the
  cell's trailing secondary text (`UIListContentConfiguration.valueCell()` style; red `systemRed` when `isIssue`),
  before the disclosure indicator. The cell's accessibility label is "\(title), \(spoken)".
- The Capabilities row (`more-row-capabilities`) supplies `text = "1 Issue"` / "\(n) Issues",
  `spoken = summary` (so VoiceOver says "Capabilities, GitHub needs you to sign in again").
- The More list observes `ServerIssues` (Observation tracking → `reconfigureItems` for that one row; no full
  reload, no scroll jump).
- At accessibility sizes the value wraps under the title (stacked configuration), never truncated.
- Row L853's remaining gap is exactly this count; the gateway card is untouched.

### 8.4 Tab badge

`MainTabController.updateBadges()` also sets the More tab item's `badgeValue` to the issue count ("1", "2", …;
`nil` at 0). The More tab item's accessibility value is the summary. Badge colour: system default (red).
**DECISION (8.4-a):** the app-icon badge is not touched (it means unread chats).

### 8.5 Opening

Tapping the Capabilities row while `count > 0` opens Capabilities with `tab: .connectors` and
`profile:` the bot of the newest issue (so the failing connector is on screen), and scrolls its row into view.
It never pushes the connector page by itself. With `count == 0` it opens as today (remembered tab).
Failing rows in the Connectors list show their status line in red ("Couldn’t connect" / "Needs sign-in").

### 8.6 The toast

The web also shows a once-per-session toast "MCP servers need attention" with "View". It is not in any assigned
row and native has no toast surface; **DECISION (8.6-a):** not built. The badge and the row carry the message.

**Acceptance.**
- A1. Fixture seed with `github` failed on `atlas` → after two status reads, More tab badge "1", row value
  "1 Issue" in red, VoiceOver label "Capabilities, GitHub is unreachable".
- A2. Tap the row → Capabilities, Connectors selected, bot picker on Atlas, no connector page pushed.
- A3. Fix it (`/__seed` status connected) → within one poll the badge and value are gone.
- A4. Two bots with one issue each → "2 Issues", spoken "2 connectors need attention".
- A5. Relaunch with the fixture stopped → the badge is still there (persisted) until 24 h pass (unit test with an
  injected clock) or a successful read clears it.
- A6. A single `failed` read followed by `connected` never shows a badge (debounce; unit + UI).
- A7. Switch to gateway B (no issues) → badge gone at once; switch back → returns.
- IDs: `more-row-capabilities` (existing), `more-row-capabilities.status`.

---

## 9. Row L722 — Plugins tab (including the Kanban switch)

**Web.** `V:app/capabilities/plugins/plugins-tab.tsx`, `V:store/agent-plugins.ts`: RPC `plugins.manage` with
`action: list|toggle|install|update|remove|settings`; row fields `name,key,version,description,source,status,
portable,install_dir,has_desktop_half,servers:[{name,state,sentence}],catalog_name,catalog_tier,installed_sha,
catalog_sha,catalog_version,update_available,pinned_sha,settings_schema`. The switch toggles the agent half and is
disabled without a `key` ("This backend predates key-addressed plugin toggles — update Hermes to manage it here.").
Uninstall only for `source` `user` or `git`, with a confirm. Update with a consent step (`consent_required`,
`delta_lines`, retry with `accept_capabilities`). Phone gates: the desktop half is hidden except for Kanban, where
it is labelled "Show in Hermes HQ"; `ref:src/fe-pages-r4.ts:48-51` copy: "A task board your bots work from. It’s the
Kanban tab." / "A task board your bots work from. Turn it on to add a Kanban tab."

**Native — list (`PluginsSections`).** One section "Plugins for \(bot)".
- Row: name (headline) with version in secondary ("1.4.0"), description (2 lines, wraps), then small state lines:
  - one line per `servers[]` entry whose state is not `connected`: the gateway's `sentence` if present, else the
    state in words — `app_not_running` "App not running", `hermes_not_connected` "Connection missing",
    `endpoint_unavailable` "Not reachable", `no_interactive_session` "No session", `version_too_old` "Version too
    old", `missing_app` "App missing", `unsupported_gpu` "This computer’s graphics can’t run it", `unknown` (and
    any state not listed) "Status unknown";
  - "Update available" (tint colour) when `update_available`.
- Trailing switch (`plugin-switch-<key>`): on when `status == "enabled"`. No `key` → no switch; the row's caption
  reads "Update Hermes on your computer to turn this plugin on or off here."
- Tapping the row pushes the plugin page (below).
- Footer: "Plugin changes take effect after your gateway restarts."
- Empty: "No plugins for \(bot)." with footer "Add one with Install from Git."
- Last row of the section (hidden on a read-only gateway and on a gateway without the plugins RPC):
  "Install from Git" (`plugins.install`, plus symbol) → §9.4.

**Kanban.** For the plugin whose name is `kanban` (same test the web gate uses; builder copies the predicate from
`ref:src/fe-pages-r4.ts`), the row gets a second switch line under it:
"Show in Hermes HQ" (`plugin-kanban-show`; accessibility label "Show Kanban in Hermes HQ") with the caption
"A task board your bots work from. It’s the Kanban tab." when on, "A task board your bots work from. Turn it on to
add a Kanban tab." when off.
- It is the same setting as Settings › Appearance › Tabs › Kanban Tab (`KanbanTabOverride`, key
  `pages.kanbanTab.override.<account>`): on writes `.on`, off writes `.off`; when the stored value is `.auto` the
  switch shows what auto currently resolves to. Both screens stay in step (same observable).
- It is device-local, the same for every bot, so it is shown regardless of the picked bot, and it works on a
  read-only gateway.
- **DECISION (9-a):** if the gateway has no kanban plugin at all, no Kanban row is invented here; Settings keeps
  its picker.

**Native — plugin page (title = name).**
1. Description; "Version \(version)"; source in words: `bundled` "Comes with Hermes", `catalog` "From the Hermes
   catalog", `git` "Installed from Git", `user` "Installed by hand".
2. "On for \(bot)" switch.
3. "Update" row when `update_available`: label "Update to \(catalog_version ?? short sha)".
   - `plugins.manage {action:"update", profile, name}` (by `name`, not `key`; §12.4); answer `consent_required: true` → alert title "\(name) asks for more",
     message "The new version adds things the installed one does not have. Apply it only if you trust them:" +
     `delta_lines` joined by newlines (max 12 lines, then "and \(k) more"), actions "Apply Update" / "Cancel";
     Apply repeats the call with `accept_capabilities: true`.
   - Done: inline notice "\(name) updated. Restart your gateway to apply."
   - Failure: `FailureAlert` "Couldn’t Update \(name)".
4. "Uninstall" (destructive) only when `source` is `user` or `git`: confirm title "Uninstall \(name)?", message
   "This deletes the plugin’s files from \(bot) on your gateway. You can install it again later.", action
   "Uninstall"; `plugins.manage {action:"remove", profile, name}`. Done → pop, notice row "\(name) uninstalled. Restart your gateway to unload
   it." Failure: "Couldn’t Uninstall \(name)".
5. `settings_schema` not empty: a "Settings" section rendered from the schema (§9.5).
6. `has_desktop_half` and not Kanban: one caption line, no control: "Part of this plugin shows only in Hermes on
   a computer." (The web phone hides that half the same way.)

**DECISION (9-c)** (replaces 9-b of the first revision, which left install and settings to the computer): the row
says "Plugins tab", and the web phone has Install from Git and the settings form, so both are built (§9.4, §9.5).
Left out, each because it is a web embed or a desktop surface and not a phone feature: the catalog picker (an
embedded docs page, `https://hermes-agent.nousresearch.com/docs/plugins?embed=picker`, that posts messages to its
host page), the "Review repository" probe (desktop-only bridge; `probeUnavailable` on the phone web), and desktop
halves other than Kanban. Installing third-party code is guarded by the trust text and a confirm (§9.4) and is
listed for the owner in `docs/owner-todo/capabilities.md`.

### 9.4 Install from Git

**Web.** `V:i18n/en.ts:966-1022` (`installModal`), `V:store/agent-plugins.ts` (`install`): RPC
`plugins.manage {action:"install", profile, identifier, force, enable, ref}`, 120 s wait; answers `ok`, `name`,
`missing_env`, `restart_required`, `warnings`, or an error (already installed unless `force`).

**Native — `PluginInstallController`** (pushed page, small title "Install Plugin"):
1. Header text: "Install only from sources you trust. A plugin is code that runs on the computer running Hermes."
   (First sentence is the web's `securityIntro` cut at the dash; the second replaces "review the repository
   below", which needs the desktop probe.)
2. Section "Repository": one field (`plugins.install.repo`; placeholder `https://github.com/owner/repo`; URL
   keyboard, no autocorrect, no autocapitalise). Accepted: `https://…`, `git@host:owner/repo(.git)`, or
   `owner/repo` (sent as typed; Hermes expands it). Trimmed. Max 500 characters.
   - `http://`, `file:`, `ssh://` with a loopback or private host, or any other scheme: the web's warning shown as
     an orange caption, and Install stays enabled (web parity): "This URL uses an insecure or local scheme. Prefer
     https:// or git@ for production installs."
   - Whitespace or control characters inside the value, or a leading `-`: red caption "That doesn’t look like a
     repository address." and Install disabled (a leading dash would be read as a git option; never sent).
3. Section "Options":
   - switch "Turn On After Installing" (`plugins.install.enable`, default on) → `enable`;
   - switch "Replace If Already Installed" (`plugins.install.force`, default off) → `force`;
   - field "Pin to Commit (Optional)" (`plugins.install.ref`; placeholder "Full 40-character commit SHA"; footer
     "Everyone installing this SHA gets the same code; the plugin then refuses updates until re-pinned. Leave
     empty for the latest commit."). Not empty and not 40 hex characters → red caption "Must be a full
     40-character commit SHA (branches and tags are not accepted)." and Install disabled. Empty → `ref` omitted.
4. Footer of the page: "Installs for \(bot). Changes apply to new chats."
5. Primary "Install" (`plugins.install.go`). Tap → confirm alert: title "Install This Plugin?", message "Hermes
   will download \(repo) and run its code on the computer running Hermes for \(bot).", actions "Install" / "Cancel".
6. Running: the button reads "Installing…" with a spinner; fields disabled; back is allowed (the call continues
   in the model and its result lands as a notice on the Plugins tab). One install at a time per gateway.
7. Results (the page pops to the Plugins tab, the list refreshes, and one notice row shows at the top until the
   next refresh or a tap on its close button):
   - ok → "Installed “\(name)”." plus, when `restart_required` and not `gateway_reloaded`, "Restart your gateway
     to finish.";
   - ok with `missing_env` → "\(name) is installed but needs a key before it can work: \(vars joined by ", ").
     Add it now, or the plugin’s tools will fail." with a button "Set It Up" → the plugin page's Settings section
     when the plugin has a schema, else Settings › Keys (`SettingsNavigator`);
   - already installed (error text contains "already installed", or code 4090) → stay on the form, red caption
     "\(name or repo) is already installed. Turn on Replace If Already Installed to install it again.";
   - no answer in 120 s → stay on the form, orange notice: "Hermes stopped waiting for the install result, but
     the plugin may still be installing. Go back and pull to refresh Plugins before trying Install again."
     (web `installUncertain`, with "Rescan" put in the phone's words); the Install button stays disabled for
     30 s so a second clone is not started on top of the first;
   - any other failure → `FailureAlert` "Couldn’t Install Plugin" with Hermes's message (masked with the §6 rules,
     capped at 600 characters).
8. `warnings` → listed under the notice, one line each, max 5 then "and \(k) more".

**Acceptance (C).**
- C1. Fixture: install `https://github.com/example/web-clipper` → confirm wording exact → one `plugins.manage`
  install with `identifier`, `enable:true`, `force:false`, no `ref`, the picked `profile` → list shows it, notice
  "Installed “web-clipper”. Restart your gateway to finish."
- C2. Seeded `missing_env:["CLIPPER_TOKEN"]` → the needs-a-key notice with "Set It Up" opening the plugin's
  Settings section.
- C3. Same repo again → "already installed" caption; with Replace on → `force:true` and success.
- C4. `http://10.0.0.5/x.git` → orange warning, Install enabled. `--upload-pack=x` → red caption, Install disabled,
  no request.
- C5. Pin `abc123` → red caption; a 40-hex value → `ref` sent.
- C6. `/__fail rpc:plugins.manage hang` → at 120 s the uncertain notice; Install disabled 30 s; fixture saw one
  install call.
- C7. Read-only gateway and `--no-plugins-rpc`: no "Install from Git" row.
- IDs: `plugins.install`, `plugins.install.repo|enable|force|ref|go`, `plugins.notice`.

### 9.5 Plugin settings form

**Web.** `V:app/capabilities/plugins/plugin-settings-form.tsx`: fields from `settings_schema`
(`{key,type,label,description,required,value,default,choices,env,has_value}`, type `string | number | boolean |
enum | secret | json`). Save sends two things: changed non-secret values through
`plugins.manage {action:"settings", profile, key, values}`, and non-blank secrets through `PUT /api/env` keyed by
the field's `env` name. A blank secret keeps the stored one.

**Native — `PluginSettingsForm`** (a section on the plugin page; title "Settings"):
- One row per field, label = `label` (falling back to `key`), with " (optional)" appended in secondary colour
  when not `required`; `description` as the row's caption (wraps).
  - `string`: text field, current `value ?? default ?? ""`.
  - `number`: decimal-pad text field; not a number on save → inline red caption "\(label): expected a number".
  - `boolean`: switch.
  - `enum`: `UIMenu` button listing `choices` (current = `value ?? choices.first`).
  - `json`: multi-line monospaced text view (pretty-printed value; 12 lines max then scrolls); invalid JSON on
    save → "\(label): not valid JSON".
  - `secret`: `SecureField`, always empty, placeholder "•••••••• (set)" when `has_value`, else empty. Caption adds
    "Saved as a secret on the computer running Hermes. Leave blank to keep the current value." (the env name is the field’s VoiceOver hint) The
    stored value is never fetched or shown (no reveal here).
  - A `secret` field with no `env` name cannot be saved anywhere: it is shown disabled with the caption "Set this
    one in Hermes on your computer." (the web skips it silently).
  - An unknown `type` is shown as a read-only line with its current value masked by the §6 rules.
- "Save Settings" (`plugin.settings.save`), enabled only when something changed or a secret was typed. Order:
  secrets first (`PUT /api/env {key: env, value}` per secret, on the picked bot's profile, sequential), then
  `plugins.manage settings` with only the changed keys. If a secret write fails nothing else is sent.
- Done: inline notice "\(name) settings saved." and the form reloads from a fresh `list`. Failure: `FailureAlert`
  "Could not save \(name) settings" with the reason; typed secrets stay in their fields (in memory only) so the
  user need not paste again; they are dropped when the page closes.
- Leaving with unsaved changes: confirm "Discard Changes?" / "Discard" / "Keep Editing" (as the tool editor, §5.5).
- Plugin without `key` (old Hermes): the section shows the fields read-only with the caption "Update Hermes on
  your computer to change these here."
- Read-only gateway: fields read-only, no Save.
- Secrets typed here follow the §14.8 privacy rules (never logged, never in state restoration, never in the
  pasteboard).

**Acceptance (D).**
- D1. Fixture plugin `web-clipper` with five fields (string, number, boolean, enum, secret with `has_value:true`)
  → rows as specified, the secret shows "•••••••• (set)" and no value.
- D2. Change the string and the switch → one `plugins.manage settings` with exactly those two keys; no `/api/env`
  call; notice "web-clipper settings saved."
- D3. Type a secret → one `PUT /api/env {key:"CLIPPER_TOKEN"}` then no settings call (nothing else changed).
- D4. "abc" in the number field → "\(label): expected a number", no request.
- D5. `/__fail rest:PUT /api/env 500` → "Could not save web-clipper settings"; the typed secret is still in the
  field; the fixture saw no settings call.
- D6. App log and `UserDefaults` contain no typed secret (§14.8 P2/P3).
- IDs: `plugin.settings.<key>`, `plugin.settings.save`.

**Toggle.** Optimistic; `plugins.manage {action:"toggle", profile, key, enable}`; failure reverts with
`FailureAlert` "Couldn’t Turn On \(name)" / "Couldn’t Turn Off \(name)". Answer `restart_required: true` (and not
`gateway_reloaded`) → notice row "Restart your gateway to finish." `missing_env` non-empty → notice row
"\(name) needs \(list) before it can run. Add it under Settings › Keys." with a "Open Keys" button.
`warnings` → each as a caption line under the row until the next refresh.

**Wire.** §12.4.

**States.** skeleton · list · empty · load error ("Plugins failed to load" / "Try again") · old gateway (method not
found): "This gateway’s Hermes is too old to manage plugins here. Update Hermes on your computer." · read-only
gateway (no switches except Kanban's, no Update, no Uninstall, no Install from Git, settings read-only).

**Acceptance.**
- A1. Fixture seed: 4 plugins (bundled on, catalog off with update, git one, kanban) → rows and state lines exact.
- A2. Toggle `web-clipper` → one `plugins.manage` toggle with the right `key`, `profile`; notice "Restart your
  gateway to finish.".
- A3. Update with consent → alert lists the fixture's two delta lines; Apply → second call has
  `accept_capabilities:true`.
- A4. Uninstall the git plugin → confirm wording → gone; no Uninstall on bundled.
- A5. Kanban "Show in Hermes HQ" on → the Kanban tab appears without a relaunch and Settings › Appearance › Tabs › Kanban Tab reads
  "On"; off → gone and "Off".
- A6. Legacy mode (`--legacy-plugins`: rows without `key`) → no switches, the caption shown.
- A7. `--no-plugins-rpc` → the "too old" text.

---

## 10. Connect Apps (Composio, bring your own key) — rows L723–L729, L997

Owner (`mem:composio-connectors.md`), quoted:
- "Connections are **shared**: one Composio user per gateway. Bots are chosen on a Bots page with a switch each,
  plus an **All Bots** switch that includes future bots."
- "Use the **real app logos** from logos.composio.dev, never letter tiles."
- "The sheet itself is fine."
- "Add to Your Agent is opt-in and confirmed. Setup and connecting never write to the gateway."
- Pitfalls: the same `user_id` on both sides; Connect Links are single-use (never preview one); never open the
  sign-in in a WKWebView (Google blocks it).
- "Writing the MCP entry changes the gateway's config, so on the owner's gateway it's the owner's call."
- Owner tested the web build with a real key: "It works."

### 10.1 Row L723 — the sheet and its flag

**Web.** `ref:src/composio/flags.ts`: `composioOn = phoneLayout() && releaseFlag('COMPOSIO_CONNECT', true)`.
`ref:src/phone-tab-bar.tsx:927, 935`: More row "Connect Apps" (plug icon, tile #ff9f0a), shown only when on.
`ref:src/composio/sheet.tsx`: page-style sheet, title "Connect Apps", description "Connect apps your bots can use
through Composio."; views home / bots / app / category / all / tools; loading "Loading…"; failed: "Couldn’t Load
Composio" / "Check your connection, then try again." / "Try Again" with the reason as footer.

**Native.**
- There is no `Flags` type natively (checked in Revision 2). Add one constant,
  `ConnectAppsFeature.isOn` in `App/ConnectApps/` (`true`; in `#if DEBUG` the launch argument `-composioConnect NO`
  turns it off for the "row hidden" test). **DECISION (10.1-a):** a compile-time constant plus the debug override,
  nothing user-visible, no remote flag.
- More: register section `"integrations"` (already in `PagesTabs.sectionOrder`) from `M2Wiring` with one row
  `MoreRow(id: "connect-apps", title: "Connect Apps", symbol: "powerplug.fill", tile: #FF9F0A)`. Hidden when the
  flag is off. Not shown at all on a read-only gateway? It is shown: setup and connecting never write to the
  gateway; only the Bots page needs writes and says so there (§10.7).
- Tapping presents `ConnectAppsController`: a `UINavigationController` in a `.pageSheet` (large detent only, grabber
  off, system glass bars), root title "Connect Apps" (inline large title is for tab roots; this is a sheet root, so
  a standard large title that collapses), a Close button (`xmark`, `connect-apps.close`) leading, and on Home a
  trailing `ellipsis` (accessibility label "Composio account", §10.9).
- Pushed pages: "Bots", the app's name (blank title on web; **DECISION (10.1-b):** native uses the app name as the
  small title so the back stack reads properly with VoiceOver), category title, "All Apps", "\(app) Actions".
- Phases of the root: loading (centered `ProgressView` + "Loading…") → `setup` (§10.4) or `ready` (§10.5) or
  failed (a grouped section: "Couldn’t Load Composio", red caption "Check your connection, then try again.", row
  "Try Again", footer = the reason).
- The sheet survives rotation and size-class change; swipe-to-dismiss allowed except during a sign-in (§10.8) and
  while "All Bots" is being applied.
- One sheet at a time; opening More › Connect Apps twice quickly presents once.

### 10.2 `ComposioClient` (HermesKit) — rows L725, L997 (network half)

**Web/native bridge.** `ref:ios/App/App/HermesComposio.swift`: base `https://backend.composio.dev`; the key is
added natively as the `x-api-key` header (L65) and never handed to the page; a route allowlist
(`ComposioPolicy.allowed`, L150–158); Debug-only loopback override via an environment variable (L134–141); Connect
Links must be https on `composio.dev` or a subdomain (`connectLink`), or the Debug loopback base.

**Native.**
```swift
public actor ComposioClient {
    public init(keys: ComposioKeychain, session: URLSession = .composio)   // ephemeral, no cookies, 20 s timeout (web: 20 s)
    public func createSession(userID: String) async throws(ComposioError) -> ComposioSession
    public func readSession(_ id: String) async throws(ComposioError) -> ComposioSession
    public func toolkits(session: String, search: String = "", slugs: [String] = [], cursor: String = "",
                         limit: Int = 30, connectedOnly: Bool = false) async throws(ComposioError) -> ToolkitPage
    public func link(session: String, toolkit: String, callbackURL: URL?) async throws(ComposioError) -> ConnectLink
    public func account(_ id: String) async throws(ComposioError) -> ComposioAccount
    public func disconnect(_ id: String) async throws(ComposioError)
    public func tools(toolkit: String) async throws(ComposioError) -> [ComposioTool]
    public func check(key: String) async throws(ComposioError) -> ComposioSession   // setUp: uses a key not yet saved
}
```
- Base URL: `https://backend.composio.dev`. `#if DEBUG` only: environment `HQN_COMPOSIO_BASE` is honoured when it is
  a loopback http URL (`127.0.0.1`, `localhost`, `[::1]`); release builds do not contain the read.
- Requests are built only from the route table below; there is no "request any path" entry point. Header
  `x-api-key: <key>`, `Accept: application/json`, JSON bodies. The key is read from the Keychain per request inside
  the actor and never stored in a property, logged, or put in an error.
- Redirects are refused (`URLSessionTaskDelegate` returns `nil`), so the key header can never follow a redirect to
  another host.
- Responses over 2 MB are refused ("Composio had a problem. Try again.").
- Errors (`ComposioError.kind` + message, verbatim from `ref:src/composio/api.ts`):

  | Case | Kind | Message |
  |---|---|---|
  | 401 | badKey | "Composio didn’t accept this API key." |
  | 403 | badKey | Composio's own `error.message` when the body has one, else "This API key can’t use that Composio project." |
  | 404 | notFound | `error.message` when present, else "Composio couldn’t find that." |
  | 429 | rateLimited | "Composio is rate-limiting requests. Try again in a minute." |
  | ≥500, 408 | server | "Composio had a problem. Try again." |
  | other 4xx | rejected | `error.message` when present, else "Composio refused the request (\(status))." |
  | no key saved | noKey | "Add your Composio API key first." |
  | offline (`URLError.notConnectedToInternet`, `.dataNotAllowed`) | network | "This phone is offline" |
  | timed out (20 s) | network | "Composio took too long to answer" |
  | other transport | network | "Couldn’t reach Composio" |

  (Checked against `ref:src/composio/api.ts` and `ref:ios/App/App/HermesComposio.swift` in Revision 2: 403 is a
  bad-key case on the web, so setup shows "Key Not Accepted" for it too. A Composio `error.message` is shown capped
  at 300 characters, with anything matching the key's shape masked.)

- Route table (the only requests the client can make):
```
POST   /api/v3.1/tool_router/session                     {"user_id":"dispatch-ab12cd34ef56","manage_connections":{"enable":true},
                                                           "multi_account":{"enable":true,"max_accounts_per_toolkit":5,"require_explicit_selection":false}}   (§10.11)
         → {"session_id":"trs_…","mcp":{"url":"https://backend.composio.dev/tool_router/trs_…/mcp"},…}
GET    /api/v3.1/tool_router/session/<id>
GET    /api/v3.1/tool_router/session/<id>/toolkits?limit=30&search=&toolkits=gmail,slack&cursor=&is_connected=true
         → {"items":[{"slug":"gmail","name":"Gmail","meta":{"logo":"https://logos.composio.dev/api/gmail",
            "description":"…"},"no_auth":false,"connected_account":{"id":"ca_…","status":"ACTIVE",
            "created_at":"2026-09-29T14:02:11Z","status_reason":null}}],"next_cursor":"30"}
POST   /api/v3/tool_router/session/<id>/link             {"toolkit":"gmail","callback_url":"<app scheme>://composio/callback"}   (§10.8)
         → {"redirect_url":"https://connect.composio.dev/link/lk_…","connected_account_id":"ca_…"}
GET    /api/v3/connected_accounts/<id>                   → {"id":"ca_…","status":"ACTIVE|INITIATED|EXPIRED|INACTIVE|FAILED",…}
DELETE /api/v3/connected_accounts/<id>
POST   /api/v3.1/tool_router/session/<id>/link           {"toolkit":"googledrive","alias":"work","callback_url":"…"}   another account (§10.11)
GET    /api/v3.1/connected_accounts?user_ids=<user>&toolkit_slugs=<slug>&order_by=created_at&order_direction=asc&limit=50
         → {"items":[{"id":"ca_…","status":"ACTIVE","alias":"work"|null,"word_id":"googledrive_ab12","created_at":"…"}]}
PATCH  /api/v3.1/connected_accounts/<id>                 {"alias":"home"}   ("" clears it)
GET    /api/v3/tools?toolkit_slug=gmail&limit=50&important=true
         → {"items":[{"slug":"GMAIL_SEND_EMAIL","name":"Send Email","description":"…"}]}
POST   /api/v3/tools/execute/<WHO-AM-I TOOL>             {"connected_account_id":"ca_…","user_id":"<user>","arguments":{…}}   (§10.12; table tools only)
         → {"successful":true,"data":{"user":{"displayName":"…","emailAddress":"…"}}}
GET    /api/v3/toolkits?limit=1000[&cursor=…]            → {"items":[{"slug","auth_schemes","composio_managed_auth_schemes","no_auth"}],"next_cursor"}   (§10.13)
GET    /api/v3/auth_configs?limit=200                    → {"items":[{"toolkit":{"slug"},"status":"ENABLED|DISABLED"}]}   (§10.13)
```
  Field mapping (from `ref:src/composio/api.ts`, each "a or b" tried in that order): session id `session_id` or
  `id`; MCP URL `mcp.url`; user id `config.user_id` or `user_id`; toolkit no-auth `is_no_auth` or `meta.isNoAuth`
  (the `no_auth` in the sample above is illustrative only); account id `id` or `nanoid`; reason `status_reason` or
  `statusReason`; date `created_at` or `createdAt`; link `redirect_url` and `connected_account_id`. Tools are read
  with `important=true` first and, when that answer is empty, once more without it. `sessionIdFromMcpUrl` uses the
  web's pattern `/tool_router/(v<n>/)?<id>/mcp`. Copy the web's decoding tests. Decoding is lenient: unknown keys ignored, a missing
  optional field never fails the page, an item without a `slug` is skipped.
- `wasConnected`: status ACTIVE, EXPIRED or INACTIVE. `needsSignIn`: EXPIRED or INACTIVE.
- Logos: `ComposioLogoStore` — https only, host `logos.composio.dev` or the host in the toolkit's logo URL if it is
  https; max 64 KB; image types only; in-memory cache of 64; no key header on logo requests; on any failure a
  monogram tile (first letter on the app's tint) — the monogram is a failure fallback only, real logos are the
  rule (owner note above).

### 10.3 `ComposioKeychain` — rows L725, L997 (key half)

**Web bridge.** `keyStatus` → `{saved, hint}` where hint is the last 4 characters (`HermesComposio.swift:22`);
`saveKey`; `clearKey`; Keychain service `…composio`, account `api-key` (L197).

**Native.**
```swift
public struct ComposioKeychain: Sendable {
    public func status() -> (saved: Bool, hint: String)     // hint = last 4 characters
    public func save(_ key: String) throws
    public func clear()
    func read() -> String?                                   // internal to HermesKit; only ComposioClient and
}                                                            // ComposioGateway.saveKey call it
```
- `kSecClassGenericPassword`, service `"\(AppIdentity.current.bundleId).composio"`, account `api-key`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (the web bridge's class, `HermesComposio.swift`), not
  synchronizable (never iCloud Keychain). The reconciler (§10.7) therefore only runs while the phone is unlocked,
  which is when the app is on screen anyway.
- **Carry-over.** In the original-identity build (`project-original.yml`) that service string is the very one the
  web app used, so a key the owner saved in the old app is found by the new one and Connect Apps opens straight on
  Home. That is wanted (the owner set it up once and said "It works."), and it means nothing may ever clear this
  item on first launch or on upgrade. The native-identity build has its own service and starts at setup.
- `plausibleKey` (web `HermesComposio.swift`): 8 to 256 characters of `[A-Za-z0-9_.-]`. `save` refuses anything
  else; the setup screen says "That doesn’t look like a Composio key." before any request is made.
- One key per device, not per gateway account (web parity). Removing Composio (§10.9) or "Erase/Sign out of all
  gateways" clears it; signing out of one gateway of several does not.
- The key is sent only to (a) Composio through `ComposioClient`, and (b) the user's own gateway, once per bot, when
  the user turns that bot on (§10.7) — that is the web's behaviour (`ref:src/composio/gateway.ts` `saveKey`:
  `PUT /api/env {key:"COMPOSIO_API_KEY", value}`), and the setup screen says so: "Nothing changes on your gateway
  until you turn on a bot."
- Never in `UserDefaults`, logs, crash breadcrumbs, state restoration, the pasteboard, screenshots of the field
  (it is a `SecureField`), or analytics.

### 10.4 Row L724 — key setup

**Web.** `ref:src/composio/views-home.tsx:20-86`.

**Native — `ConnectAppsSetupView`** (scrolls; all text wraps):
1. Hero: five logos in a row (gmail, googlecalendar, github, slack, notion; 48 pt, decorative, hidden from
   VoiceOver), title "Let your bots use your apps", body "Connect Gmail, Calendar, GitHub and hundreds more through
   your own free Composio account. Then choose which bots can use them."
2. Step 1 row: number badge "1", title "Get a free Composio key", subtitle "Sign up, then copy a key from
   Settings › API Keys.", trailing capsule button "Open" (`connect-apps.open-composio`) → opens
   `https://platform.composio.dev` in Safari (`UIApplication.open`, outside the app, so the user's Safari sign-in
   is used).
3. Step 2 row: badge "2", title "Paste it here", a `SecureField` (placeholder and accessibility label "Composio API
   key", no autocorrect/autocapitalise, return key "Go", `connect-apps.key`) and a "Paste" button
   (`connect-apps.paste`).
   - Paste uses `UIPasteControl`-free plain `UIPasteboard.general.string` on tap (the system shows its paste
     notice). Empty → inline info notice "Nothing to Paste" / "Copy your key in Composio first, then tap Paste."
     Failure → "Couldn’t Paste" / "Tap the field and paste the key there instead."
   - Pasted text is trimmed. Return in the field with text = Continue.
4. Primary button "Continue" (`connect-apps.continue`; prominent, full width), disabled when the field is empty or
   something is running; while checking it shows a spinner with accessibility label "Checking your key".
5. Caption with a lock glyph: "Your key stays in this iPhone’s Keychain. Nothing changes on your gateway until you
   turn on a bot."
6. Only when the gateway holds a key (`page.gatewayKey`): a prominent full-width button "Use the Key on Your Gateway"
   (`connect-apps.use-gateway-key`), "Setting Up…" while running, with the footer "Your gateway already has a
   Composio key. To use a different one, follow the steps below." It sits first, between the hero and step 1
   (UX study #104); the steps keep their order below it.

Continue / Use the Key on Your Gateway (`ComposioModel.setUp(key)`):
- value = field text, or for the gateway path `POST /api/env/reveal {"key":"COMPOSIO_API_KEY"}` on the bot that has
  the `composio` server. No value → error "No bot on your gateway holds a Composio key now. Paste yours instead."
  Hermes allows 5 reveals per 30 s; a 429 → "Your gateway is busy. Wait half a minute, then try again." (one
  request per tap, never retried automatically).
- A value that fails `plausibleKey` (§10.3) → "Key Not Accepted" / "That doesn’t look like a Composio key."; no
  request.
- `ComposioClient.check(key:)` creates (or re-reads) the session with the gateway record's `userId` when a record
  exists, else a new id (§10.6). On success save the key to the Keychain, success haptic, go to Home.
- On failure nothing is saved (a key saved earlier in this attempt is cleared on `badKey`), error haptic, inline
  error notice above the hero: title "Key Not Accepted" for `badKey`, else "Couldn’t Set Up Composio"; message =
  the error message. The field keeps its text.
- Setup never writes to the gateway (`reveal` is a read).

**DECISION (10.4-a):** the reveal call returns the owner's secret from the gateway to the phone. It is the web
app's shipped behaviour and happens only on an explicit tap of a button that says what it does; keep it, hold the
value only in memory until it is saved to the Keychain, and never show it.

**Acceptance.**
- A1. Mock on 10012; paste `ak_mock_dispatch` (the mock's test key) → Continue → Home. Keychain has the item;
  `UserDefaults` dump and app log contain no `ak_mock`.
- A2. Wrong key `ak_wrong` → "Key Not Accepted" / "Composio didn’t accept this API key."; Keychain empty.
- A3. Mock stopped → "Couldn’t Set Up Composio" / "Couldn’t reach Composio."
- A4. Empty pasteboard → "Nothing to Paste" notice.
- A5. Gateway fixture seeded with `COMPOSIO_API_KEY` on a bot + a `composio` server → the extra button shows; it
  sets up without typing; fixture saw one `/api/env/reveal`, no writes.
- A6. Gateway fixture state is byte-identical before and after A1 (`/__state` hash) — setup writes nothing.

### 10.5 Row L726 — Home

**Web.** `ref:src/composio/views-home.tsx:88-195`, `catalog.ts`, `connected.ts`.

**Native — `ConnectAppsHomeView`** (a `List`, `.insetGrouped`, `.searchable` with prompt "Search apps"):
1. Header:
   - connected unknown yet: a skeleton line;
   - none: title "Connect your first app", body "Tap an app below to sign in to it. Then choose which bots can use
     it.";
   - some: up to 3 logos (34 pt) and "\(n) apps connected" ("1 app connected").
2. Bots row (`connect-apps.bots-row`) → Bots page. Title / subtitle:

   | State | Title | Subtitle |
   |---|---|---|
   | loading | "Checking bots…" | — |
   | all bots | "Used by all bots" | "\(total) bots, including new ones" ("1 bot, including new ones") |
   | some | "Used by \(nameList)" | "\(on) of \(total) bots" |
   | none | "No bots use your apps yet" | "Choose Bots" (tint colour) |

   Leading: up to 3 bot faces (the ORIGINAL robot heads, via the app's existing face view; no hats) or a plus
   glyph when none. `nameList`: "A", "A and B", "A, B and C", "A, B and 2 more" (port `ref:src/composio/words.ts`
   with its tests).
3. Error notice when the connected read failed: "Couldn’t Load Your Apps" / reason / "Try Again".
4. "Connected" section (skeleton 2 rows while loading; hidden when empty): each app row = logo, name, subtitle
   "Connected \(Sep 29)" (or "Connected" with no date), or red "Needs a new sign-in" when `needsSignIn`. Sorted by
   name. Reads **every** page (limit 50, up to 10 pages; web D10).
5. "Popular" section: a grid of tiles (logo + name, 4 per row at default size, 3 at XL–XXXL, 2 at accessibility
   sizes; each tile a button) for the first 8 of the 16 `POPULAR` slugs that are not connected. While loading: 8
   skeleton tiles. All popular ones connected: a row "You’ve connected every popular app" / "Find more under
   Browse."
6. "Browse" section: the 6 categories (tile with SF Symbol and colour from the catalog, title, chevron) and
   "All Apps" (grid symbol on #636366).
7. Searching (non-empty, trimmed, debounced 300 ms): the sections above are replaced by "Results": skeleton 3 rows →
   rows, or "Couldn’t Search" + reason, or "No Results for “\(q)”". A row (`ListRow`): logo, name, one-line
   description (or red "Needs a new sign-in"), trailing "Connected" when connected and fine. An answer for an older
   query is dropped (generation counter).
8. Category page: `.searchable` "Search \(title)" (local filter by name), footer "Tap an app to see what your bots
   can do with it, then connect it."
9. All Apps page: `.searchable` "Search apps" (server search, 300 ms debounce), 30 per page, a "Show More" row
   while `next_cursor` is non-empty (spinner row "Loading more" while a page loads; a second tap while loading does
   nothing; duplicates by slug dropped; a new search starts over and drops late answers — web D8). Error: "Couldn’t
   Load Apps" + reason + "Try Again". Empty: "No Apps" or "No Results for “\(q)”".
   **DECISION (10.5-a):** "Show More" is an explicit row as on the web (no infinite scroll), so VoiceOver and
   Switch Control users choose when more loads.

**Acceptance.**
- A1. Fresh mock → "Connect your first app", Popular shows 8 tiles with real logos (mock serves a logo route; the
  simulator test stubs `logos.composio.dev` via the DEBUG base), Browse shows 6 categories + All Apps.
- A2. Mock seeded with 2 ACTIVE + 1 EXPIRED → "3 apps connected", Connected lists three, the expired one reads
  "Needs a new sign-in" in red.
- A3. Mock seeded with 120 connected → all 120 listed (3 pages read).
- A4. Search "git" → GitHub row; clear → sections return; type "zzzz" → "No Results for “zzzz”".
- A5. All Apps: 30 rows, Show More → 60, no duplicates; type fast "s","sl","sla" with the mock delaying the first
  answer 2 s → final list is for "sla" only.
- A6. Mock returns 429 on toolkits → the notice with "Composio is rate-limiting requests. Try again in a minute."
- IDs: `connect-apps.home`, `connect-app-row-<slug>`, `connect-app-tile-<slug>`, `connect-category-<id>`,
  `connect-apps.all`, `connect-apps.show-more`.

### 10.6 Gateway side (`ComposioGateway`) — shared record, per-bot server

**Web.** `ref:src/composio/port.ts`, `gateway.ts`, `model.ts`.
- Shared record: default profile's `ui_meta["dispatch-composio"] = {"userId","sessionId","allBots"}`. Read via
  `profiles.list {"include_sessions":false}` (default row's `ui_meta`). Write via
  `profiles.configure {"name":"default","ui_meta":{"dispatch-composio":{…}}}`; the answer must have
  `applied.ui_meta === true`, else "This gateway couldn’t save the Connect Apps setting."
- Per bot: MCP server named `composio`: `mcp.servers.add {profile, name:"composio", config:{"url":"<session mcp
  url>","headers":{"x-api-key":"${COMPOSIO_API_KEY}"}}}` after removing an existing one; the key itself goes to
  that bot's env: `PUT /api/env?profile=<p> {"key":"COMPOSIO_API_KEY","value":"<key>"}`; then
  `reload.mcp {"confirm":true}`. Off: `mcp.servers.remove` + `DELETE /api/env {"key":"COMPOSIO_API_KEY"}`.
- Find: `mcp.servers.list {profile}` → the `composio` row; its URL gives the session id
  (`sessionIdFromMcpUrl`).
- New user id: `dispatch-<12 random hex>`.

**Native.** Same calls, same record key and same id shape. **DECISION (10.6-a):** keep `dispatch-composio` and the
`dispatch-` id prefix unchanged: a gateway already set up from the web app must be recognised by the native app and
the other way round (one Composio user per gateway is the owner's rule). Neither string is shown to the user in the
app. The native roster already reads `ui_meta` (`N:HermesKit/Model/RosterWire.swift`); reuse that read rather than a
second `profiles.list` when the roster is fresh, and do a direct read before any write.
- Local cache of the session (`connectapps.session.<account>` in `UserDefaults`: `{userId, sessionId}`; no key in
  it) so the sheet opens without a gateway round trip; the gateway record wins when both exist and differ.
- `sessionFor`: record's session if Composio still has it (`readSession`), else create one for the record's
  `userId` (never a new user id while a record exists).

### 10.7 Row L727 — Bots page

**Web.** `ref:src/composio/views-home.tsx:199-261`, `model.ts` (`readBots` 3 at a time, `setBot`, `setAllBots`),
`reconcile.ts` (watch the roster's default row record; 2 s debounce; verified list; retry 30 s doubling, 6 tries;
retry on foreground).

**Native — `ConnectAppsBotsView`.**
1. First section, one row: tile (bots symbol on tint), "All Bots", subtitle "Includes bots you create later",
   trailing switch (`connect-apps.all-bots`; accessibility label "All bots can use your apps"), a spinner in its
   place ("Updating bots") while applying. Disabled until bot states are loaded.
   Footer when on: "Every bot can use your apps. When you add a bot, Hermes HQ gives it your apps too; a bot made
   on another computer gets them the next time Hermes HQ opens." Footer when off: "Or choose bots one by one. A bot
   that’s on can use every app you connect."
2. Second section, header "\(n) bots" ("1 bot"), one row per bot (default first, then by name): face, name, and
   when it failed a red caption "Couldn’t turn on: \(reason)" / "Couldn’t turn off: \(reason)" with a "Try Again"
   button (`connect-bot-retry-<profile>`) on its own line under the text (16 pt clear of the switch; caption wraps
   under the button at XXXL per `mem:skills-caption-stack.md`). Trailing: spinner while that bot is updating; a
   checkmark (accessibility label "On") when All Bots is on and the bot is on; else a switch
   (`connect-bot-switch-<profile>`, label "\(name) can use your apps").
   Footer: "Turning a bot on adds Composio to it on your gateway. Turning it off takes Composio away again; your
   connected apps stay."
   Skeleton rows (min(count, 5), or 3) while loading.
3. Turning a bot on (`setBot`): save the key to that bot's env, install the server, reload; then if there is no
   record yet write `{userId, sessionId, allBots:false}`. Each bot is independent; a failure is shown on that row
   only. The key comes from memory (`freshKey`, the one just pasted) or the Keychain.
4. All Bots on (`setAllBots`): write the record with `allBots:true`, then every bot not yet on, 3 at a time. Bots
   that fail: warning notice "\(k) Bots Not Updated Yet" ("1 Bot Not Updated Yet") / "Hermes HQ tries them again
   the next time it opens. Each one says why below." Total failure before anything changed: error notice "Couldn’t
   Change All Bots" + reason, switch returns. All Bots off: record `allBots:false`; bots keep their own state (the
   switches come back). If All Bots is turned off elsewhere mid-apply: the pending ones stop with "All Bots was
   turned off."
5. Haptics: selection per bot, success/warning for All Bots, error on failure.
6. **Read-only gateway:** no switches; one row "This gateway is read-only. Turn bots on from a gateway you can
   change." (No dead controls.)

**Reconcile (`ComposioReconciler`, app lifetime, started by `M2Wiring` when the flag is on and a key is saved).**
- Watches the roster. When the record says `allBots` and a bot exists without a verified `composio` server, it
  turns that bot on (2 s debounce after roster changes; verified set in
  `connectapps.verified.<account>`; retry after 30 s, doubling, 6 tries; retried on foreground).
- When the record disappears or `allBots` becomes false, it stops; it never removes anything by itself.
- Runs only with a live gateway link, never on a read-only gateway, at most 2 bots at a time, and never while the
  Bots page is itself applying.
- **DECISION (10.7-b, finishing pass):** a bot that leaves the roster is dropped from the verified set (only when
  the roster is loaded and not empty), so a bot made again under the same id is checked afresh. A bot the owner
  turns off by hand on the Bots page is *added* to the verified set: with All Bots on, the background pass must not
  switch it straight back on. (The web keys its verified mark on the whole bot list, so there a hand-turned-off
  bot stays off until the list next changes and then comes back on; native keeps the owner's choice until they
  turn All Bots off and on again, which applies to every bot directly.)
- **DECISION (10.7-a):** on a gateway the native app has never set up Connect Apps on, and with no key in the
  Keychain, the reconciler does nothing even if a record exists (the web app on another device owns it). It needs
  the key to write a bot's env; it never fetches the key from the gateway by itself.

**Acceptance.**
- A1. Turn on `atlas` → fixture: `PUT /api/env` on atlas with `COMPOSIO_API_KEY`, `mcp.servers.add` composio with
  the mock's MCP URL and the `${COMPOSIO_API_KEY}` header (the literal reference, not the key), `reload.mcp`, then
  `profiles.configure` with the record. Other bots untouched.
- A2. Fail `mcp.servers.add` for `nova` → its row "Couldn’t turn on: …" + Try Again; Try Again with the failure
  cleared → on.
- A3. All Bots on with 9 bots → never more than 3 in flight (fixture concurrency log); all on; Home says "Used by
  all bots" / "9 bots, including new ones".
- A4. With All Bots on, fixture adds a bot (`/__seed` roster) → within ~5 s it gets the server without the sheet
  open.
- A5. Fixture answers `profiles.configure` with `applied.ui_meta:false` → "This gateway couldn’t save the Connect
  Apps setting."; no bot changed.
- A6. Turn a bot off → `mcp.servers.remove` composio + `DELETE /api/env`; connected apps on the mock unchanged.
- A7. Read-only gateway → the read-only row, no switches.

### 10.8 Row L728 — App page, connecting, Try It, actions, Disconnect

**Web.** `ref:src/composio/views-app.tsx:32-161`, `connect.ts`, `port.ts` (`askBot`), `catalog.ts` (`tryIt`).

**Native — `ConnectAppView(slug)`.**
1. Header: logo 88 pt with a corner badge (green check when connected, orange warning when it needs sign-in), the
   name, then:
   - connected: "Connected" and "All your bots can use it now." / "\(nameList) can use it now." / "No bots use your
     apps yet.";
   - needs sign-in: "Needs a new sign-in" and the account's reason, or "Your bots can’t use \(name) until you sign
     in again.";
   - otherwise the description.
2. Not connected (or needs sign-in), and the app needs auth: prominent button "Connect \(name)" / "Sign In to
   \(name) Again" (`connect-app.connect`). While running it is disabled and reads the phase: "Opening…",
   "Signing in…", "Checking…". Under it, either the outcome line or the caption with a lock: "You sign in to
   \(name) in a secure Safari sheet. Composio keeps the sign-in; Hermes HQ never sees your password."
   `no_auth` app, not connected: "No sign-in needed. Bots that use your apps can use \(name) already."
3. "Try It" (only when connected, fine, and at least one bot is on): the catalog's prompts for this app (fallback
   "What can you do with \(name)?"), each a row "“\(text)”" with trailing "Ask \(firstBot)" (spinner "Opening
   chat" on the tapped one; others disabled). Tap: dismiss the sheet, open that bot's chat, put the text in the
   composer **without sending**. Failure: `FailureAlert` "Couldn’t Open \(bot)" with "Couldn’t open \(bot)’s
   chat." or "Couldn’t put the message in \(bot)’s chat." There is no "open this bot's chat with composer text" entry point
   natively yet (checked): the builder adds one, `ChatNavigator.openChat(profile:prefill:)` (name to match what
   the chat stream has by then; ask nobody, look), which selects the Chats tab, opens the bot's newest chat or a
   new one, and hands the text to the composer's draft. An existing draft in that chat is not overwritten:
   **DECISION (10.8-a):** if the composer already has text, append the prompt on a new line.
4. "What Your Bots Can Do": skeleton 3 → first 3 action names with a checkmark → "See All Actions" with the count
   and a chevron when more than 3 (pushes "\(name) Actions": every action, name + description, local search) — or
   "Composio lists no actions for this app yet". A failed read shows the empty text (web parity).
5. Not connected: "Bots That Will Use It": the bots that are on (face + name) with footer "These are the bots you
   turned on. Change them under Bots on the Connect Apps page."; none → a row "No bots use your apps yet" /
   "Choose Bots" → Bots page; skeleton while loading.
6. Connected: "Account" section with "Connected" and the date as value ("Sep 29, 2026", `connectedDate`, user's
   locale); then a destructive row "Disconnect \(name)" (`connect-app.disconnect`) with footer "Your bots lose
   access to this account. You can connect it again anytime." Confirm (action sheet from the row): "Disconnect
   \(name)?" / "Your bots lose access to this \(name) account. You can connect it again anytime." / "Disconnect".
   Then `DELETE /api/v3/connected_accounts/<id>`, success haptic, refresh. Failure line: "Couldn’t disconnect:
   \(reason)".
7. Unknown slug: "Couldn’t Load This App" + "Composio doesn’t list this app any more." (or the error).

**Connecting (`ComposioConnect`, port of `connect.ts`).**
1. Phase `link`: `POST …/link {"toolkit": slug, "callback_url": callback}` where
   `callback = "\(AppIdentity.current.urlScheme)://composio/callback"` (`hermes://…` in the original build,
   `hermeshq-native://…` in the native-identity build; never a literal). If Composio rejects the callback URL
   (error kind `rejected` and a message containing "callback", any case), retry once without `callback_url`.
2. Validate `redirect_url`: https on `composio.dev` or a subdomain, no userinfo (DEBUG: or the loopback base).
   Anything else → "Composio had a problem. Try again." The link is opened exactly once and never prefetched or
   previewed (single-use).
3. Phase `sign-in`: `WebAuthRuntime.makeSession(url:customScheme:handler:)` with
   `customScheme = AppIdentity.current.urlScheme` — the app's existing runtime-built `ASWebAuthenticationSession`
   (`WebAuthBrowser`), non-ephemeral so the user's Safari Google/GitHub session is there (web L118), anchored on
   the sheet's window. Do **not** `import AuthenticationServices` or `SafariServices` anywhere (linking either
   costs about 1.3 s of launch; that is why the runtime wrapper exists). The handler's `NSURL?` is the callback;
   read `status` and `connected_account_id` from its query. Never a `WKWebView`.
   **DECISION (10.8-b, revised):** the scheme is the app's own registered one, so the auth session takes its
   callback while it is up; `AppDelegate.open(_:)` (via `NotificationRules.link`) must return "not handled" for
   host `composio` so a stray callback after the session ended does nothing visible. Unit test both schemes.
4. Phase `checking`: poll `GET /api/v3/connected_accounts/<connected_account_id>` every 1 s:
   - callback returned: up to 20 s (`CALLBACK_WAIT`);
   - user cancelled the sheet: up to 4 s (`CANCEL_WAIT`) — the provider may have finished anyway;
   - the account id polled is the callback's `connected_account_id` when present, else the link answer's; none at
     all → failed: "Composio lost this sign-in. Try again.";
   - callback `status` says failed/error (and the account is not ACTIVE) → failed: the account's reason, else "The
     sign-in was declined.";
   - ACTIVE → connected (success haptic, refresh Connected);
   - FAILED or EXPIRED → failed: the account's reason, else "The sign-in didn’t finish. Try again.";
   - 404 on the account → failed: "Composio lost this sign-in. Try again.";
   - deadline reached after a cancel (no callback) → unfinished: info line "Sign-in not finished. Tap Connect to
     try again." (no error haptic);
   - deadline reached after a callback → failed: "Composio is still finishing this sign-in. Check again in a
     moment.";
   - a failed poll read (network) does not end the wait; it is retried on the next 1 s tick until the deadline.
5. One connect at a time; the sheet cannot be swiped away during `sign-in`; popping the page cancels the auth
   session and ends as unfinished without an alert.

**Acceptance.**
- A1. Connect GitHub on the mock (consent page → Allow) → phases shown in order → header "Connected", Home counts
  it. Mock saw exactly one link request and one GET of the link page.
- A2. Deny on the consent page → "The sign-in was declined."
- A3. Cancel the auth sheet → "Sign-in not finished. Tap Connect to try again." within ~4 s.
- A4. Mock in `--slow-activate 30` mode → "Composio is still finishing this sign-in. Check again in a moment."
- A5. Try It → sheet closes, the bot's chat opens with the prompt in the composer, nothing sent (gateway fixture
  saw no prompt submit).
- A6. See All Actions shows the mock's count; search filters.
- A7. Disconnect → confirm wording → mock account gone; page returns to "Connect GitHub".
- A8. EXPIRED account → "Needs a new sign-in", button "Sign In to GitHub Again"; after re-auth it is fine.
- A9. A link answer with `redirect_url: "http://evil.example/…"` (mock `/__mock/next-link`) → no browser, "Composio
  had a problem. Try again."

### 10.9 Row L729 — account menu

**Web.** `ref:src/composio/sheet.tsx:176-192`.

**Native.** The Home page's trailing `ellipsis` (`connect-apps.account`, label "Composio account") shows a
`UIMenu`:
- "Composio Key" with subtitle "•••• \(hint)" (or "Saved on this iPhone" with no hint), key symbol, disabled (it is
  information; UIMenu renders a disabled action with its subtitle — the one sanctioned non-acting item, as on the
  web);
- "Open Composio" (safari symbol) → `https://platform.composio.dev` in Safari;
- divider, "Remove Composio" (trash, destructive).

Remove: confirm (action sheet from the button) "Remove Composio?" / "Your bots lose these apps, and this iPhone
forgets the key. Connected accounts stay in your Composio project." / "Remove". Then (`ComposioModel.remove`): for
every bot with the server, remove it and its env key (3 at a time); clear the record (`ui_meta` key set to null);
clear the Keychain, the session cache and the verified list; stop the reconciler; back to the setup screen.
- All good → success haptic, setup screen.
- Gateway part failed for any bot → warning haptic; the phone side is still cleared; setup screen shows a warning
  notice "Removed From This iPhone Only" / "Hermes HQ couldn’t update every bot (\(reason)). If Capabilities ›
  Connectors still lists “composio” on a bot, remove it there." (That is now possible natively through §5.3.)
- Read-only gateway: the phone side is cleared and the same warning is shown.

**Acceptance.**
- A1. Menu shows "•••• atch" for `ak_mock_dispatch` — the last four characters only; the full key is nowhere in the
  view hierarchy.
- A2. Remove with 2 bots on → both lose the server and env key, record gone, Keychain empty, setup screen shown,
  More row still present.
- A3. Fail `mcp.servers.remove` for one bot → the "Removed From This iPhone Only" notice with the reason.

### 10.10 Row L997 — the native pieces, summed up

The web needed a Capacitor plugin (`keyStatus` / `saveKey` / `clearKey` / `request` / `authorize`). Natively these
are `ComposioKeychain` (§10.3), `ComposioClient` (§10.2) and the `WebAuthRuntime` sign-in step in §10.8. L725
and L997 are done together and are done when: the key round-trips through the Keychain across a relaunch; the key
is sent to no host but Composio's base (and, on an explicit bot switch, the user's gateway env); and a connect
completes through the system sign-in sheet (`WebAuthRuntime`).

Unit test for "sent only to Composio": a `URLProtocol` stub records every request the `ComposioClient` session
makes during the whole Connect Apps UI-less model test; every host equals the base host; a 302 to another host is
not followed and the second host never sees a request.

### 10.11 A second account of an app (2026-10-27)

The owner wants a work ("Work") Google Drive beside the personal one.

**Composio's rule** (docs.composio.dev "Managing multiple connected accounts"): a tool router session uses one
account per app unless multi-account is on, and the newest account becomes the one used. The docs say multi-account
is set when the session is made, but a PATCH on the session turns it on in place (checked live 2026-10-27). So:
1. **New sessions are multi-account**: the create body carries
   `"multi_account":{"enable":true,"max_accounts_per_toolkit":5,"require_explicit_selection":false}` (a call that
   names no account gets the default one, so single-account bots keep working; with several, bots name the account
   by alias or id). Hermes's `tools.connectors.composio_migrate` turns an older session multi-account in place with
   the same config (PATCH), and GET session then carries it, so the app sees it as multi-account and makes no new one. `ComposioSession.multiAccount` is `config.multi_account.enable` when the
   answer carries it. When it doesn't, a session this app made counts as multi-account
   (`connectapps.multi.<account>` in `UserDefaults`, ids only); any other session counts as not.
2. **Moving an older session** (`ComposioModel.multiAccountSession`), run only by Add Another Account:
   a. read the gateway record; refuse on a read-only gateway when a record exists;
   b. a new session for the **same** `userId` (accounts belong to the user, so every account carries over), kept
      aside in `connectapps.moving.<account>` until step d; a later try reuses it if Composio still has it;
   c. every bot (hidden ones too) whose `composio` server names another session gets the new MCP URL (the Bots
      page's turn-on path: env key, server, reload), three at a time; a failure stops here with "N bots couldn’t be
      updated (reason). Try again." and the record is left alone;
   d. the record's `sessionId` becomes the new session (`profiles.configure`); the app then uses it.
   The reconciler waits while this runs (`ComposioBotsGate`). Bots move before the record changes, so a stop at
   any point leaves a state the next try finishes. The Hermes add-on does the same move server-side (same
   `multi_account` config, same user id, same record).
3. **The app's page** (connected): section "Account"/"Accounts" lists every account from
   `GET /api/v3.1/connected_accounts` (connected at some point; oldest first): the alias shown as words
   ("work-drive" → "Work Drive"), else the account's address (§10.12), else "Account <n>" (`word_id` is shown only
   in small text on the account's own page), with
   "Connected <date>" or "Needs a new sign-in". Each row's ⋯ menu (`connect-app.account-menu-<n>`): "Name This
   Account" / "Rename" (PATCH alias), and with several accounts "Disconnect" (confirm "Disconnect “<name>”?").
   With one account the "Disconnect <app>" row stays as in §10.8. Then "Add Another Account"
   (`connect-app.add-account`): an alert "Add Another <app> Account" / "Give it a short name, like “work”. Your
   bots use the name to pick the account." (field `connect-app.alias`, Continue). The name is made Composio's
   shape (lowercase letters, digits, "-"; "Work" → "work", at most 32); a name already used for this app says
   so. Then the phases "Getting ready…" (the move, when needed), "Opening…", "Signing in…", "Checking…"; the
   outcome shows under the section. Footer: "Your bots pick an account by its name." (several) or "Add a second
   <app> account, like a work one, under its own name." (one).

**Acceptance** (`testD2_ConnectAppsSecondAccount`, stand-in `{"single_account":true}` for the older session; unit
tests in `Tests/Capabilities/ComposioAccountsTests.swift`, `ComposioIdentityTests.swift`): the first account is titled
by its address; the second is listed as "Work" with its address under it; Composio saw a new multi-account session
for the same user; Ivy's server names it; the gateway record names it; naming the first account offers "personal" and
shows "Home"; its own page shows the address, the person and the code, and a rename there shows on the app page.

### 10.12 Which account is which (2026-10-27)

Owner: Google Drive showed "Account 1" and "Account 2", with no way to tell them apart, and the rows did nothing.
Composio's account rows carry no address or name, so the app asks the app itself: one read-only "who am I" tool per
app (`ComposioWhoAmI.table`, HermesKit/Composio/ComposioIdentity.swift), run against that one account with
`POST /api/v3/tools/execute/<tool>`. The client can run only the tools in the table.

| App | Tool (arguments) | Address / name in `data` | Checked |
|---|---|---|---|
| googledrive | GOOGLEDRIVE_GET_ABOUT (`fields: user`) | `user.emailAddress` / `user.displayName` | live, both owner accounts |
| notion | NOTION_GET_ABOUT_ME | `response_data.bot.owner.user.person.email` / `….user.name` (the top `name` is the integration's) | live |
| clickup | CLICKUP_GET_AUTHORIZED_USER | `user.email` / `user.username` | live |
| salesforce | SALESFORCE_GET_USER_INFO | `response_data.email` / `response_data.name` | live |
| gmail | GMAIL_GET_PROFILE (`user_id: me`) | `response_data.emailAddress` | schema only (not connected) |
| googlecalendar | GOOGLECALENDAR_GET_CALENDAR (`calendar_id: primary`) | `calendar_data.id` | schema only |
| linear | LINEAR_GET_CURRENT_USER | `user.email` / `user.name` | schema only |
| outlook | OUTLOOK_OUTLOOK_GET_PROFILE (`user_id: me`) | `response_data.mail`, `userPrincipalName` / `displayName` | schema only |
| github | GITHUB_GET_THE_AUTHENTICATED_USER | `email` / `name`, `login` | schema only |

An address counts only when it looks like one; when the listed paths give none, the answer is searched a few levels
deep for a key named like one (`emailAddress`, `email`, `mail`, `userPrincipalName`). Names are never searched for.
Other apps (Sheets, Docs, Slack…) show no address. Accounts that need a new sign-in are not asked (Composio answers
410). The model asks for every account of the page at once, once per account per launch (a failure is asked again
next time), and keeps the answers on the device (`connectapps.identities.<account>`, dropped when the account goes or
the key is removed), so a page opens with the addresses it showed last. Logs carry the account's `AppLog.tag` and the
error kind only: never an address, name or key.

- **Row**: title = alias as words, else the address, else "Account <n>"; under a named row, its address; then
  "Connected <date>" / "Needs a new sign-in". The ⋯ menu stays; tapping the row (or its chevron) opens the account's page.
- **Account page** (`ConnectAccountController`, pushed, title "Account"): logo, the row's title, state ("Connected" or
  "Needs a new sign-in" with Composio's reason, then "Sign In Again", the app page's connect flow); then Name (with
  "Name This Account" / "Rename"), Email, "Name in <app>", Connected (date); footer "Your bots pick an account by its
  name." and "Composio code: <word_id>" in small text; then "Disconnect This Account" (the same confirm; the page
  closes after). A rename here shows on the app page too (the list lives on `ComposioModel.appAccounts`).
- **Name prompt** for an unnamed account starts with a name from its address, selected so typing replaces it:
  the company ("c…@work.com" → "work", "a@mail.acme.co.uk" → "acme"), "personal" for a mail service (gmail.com,
  outlook.com, icloud.com…), the address's own name when that is taken by another account of the app.
- Known limit: "Sign In Again" on an account that isn't the app's default makes a new connection (Composio's link
  has no "re-sign this account" form the app uses); the expired one stays listed until disconnected.

### 10.13 Apps the owner can't connect (2026-10-27)

Owner, after Connect on Twitter answered "Composio does not manage auth for toolkit twitter…": "then X shouldn't
show". Some apps sign in only by OAuth and Composio provides no OAuth app for them (about 100 of 1,700 on
2026-10-27: twitter, shopify, snowflake, docusign, xero…). An app is left out of Popular, search, All Apps and the
category pages when its catalog row (`GET /api/v3/toolkits`) has no `composio_managed_auth_schemes`, isn't
`no_auth`, and has only OAUTH1/OAUTH2 in `auth_schemes` (an app with API_KEY, BEARER_TOKEN, BASIC… is kept: the owner
types those on Composio's page), unless it is connected (any state), its session row says managed, or the owner has
an auth config for it (`GET /api/v3/auth_configs`, not DISABLED). The catalog answer (two pages of up to 1,000) is
reduced to the slugs and kept on the device for a day (`connectapps.needs-own-app`); auth configs are read on each
home load (at most every 10 minutes). Any failed read shows every app, as before.
If a link still fails that way, the outcome is "Composio doesn’t provide a sign-in for <app>. To connect it, add your
own <app> developer app as an auth config in your Composio dashboard, then try again." with "Open Composio Dashboard"
(https://platform.composio.dev). Tests: `Tests/Capabilities/ComposioSignInTests.swift`.

---

## 11. Owner-approved behaviour, in one place

| Note | Quote | Where honoured |
|---|---|---|
| `mem:segmented-labels-whole.md` | "the connectors tab cuts off the word… might require a more global change" | §2 DECISION 2-a |
| `mem:row-padding-feedback.md` | "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt top and bottom" | every list here |
| `mem:skills-caption-stack.md` | caption must wrap under the button at XXXL | §3.1 progress row, §10.7 retry row |
| `mem:more-tab-restore-fix.md` | a failing server opens Capabilities on Connectors, never inside one connector's sheet | §8.5 |
| `mem:composio-connectors.md` | "Connections are **shared**: one Composio user per gateway. Bots are chosen on a Bots page with a switch each, plus an **All Bots** switch that includes future bots." | §10.6, §10.7 |
| same | "Use the **real app logos** from logos.composio.dev, never letter tiles." | §10.2 logos |
| same | "Add to Your Agent is opt-in and confirmed. Setup and connecting never write to the gateway." | §10.4 A6, §10.7 |
| same | "Writing the MCP entry changes the gateway's config, so on the owner's gateway it's the owner's call." | never done by agents; `docs/owner-todo/capabilities.md` |
| glitch sweep | never show a control that does nothing | 3.2-a, 4-c, 5.5-a, 9-c, read-only states |
| API keys | "I must not type the owner's API keys into apps. The owner pastes them." | tests use `ak_mock_dispatch` / `test-token-123` only |

---

## 12. Wire reference (everything new)

Types in `HermesKit/Contracts+capabilities.swift`; methods added to `CapabilitiesService` and implemented in
`CapabilitiesStore`. All writes go through `serial(profile)`.

### 12.1 Tools
`GET /api/tools/toolsets?profile=` · `PUT /api/tools/toolsets/<name>?profile=` `{"enabled":Bool}` ·
`GET /api/analytics/usage?days=365&profile=` (examples in §4).

### 12.2 Connectors (JSON-RPC; contract `H:tui_gateway/contracts/tools_mcp_plugins.py`)
```
mcp.servers.list   {"profile":"atlas"}
  → {"servers":[{"name":"github","transport":"http","url":"https://api.example/mcp","command":null,"args":[],
     "env":["GH_HOST"],"auth":"oauth","oauth_tokens_present":false,"enabled":true,"tools":0,
     "source":"config","plugin":null}]}
mcp.servers.status {"profile":"atlas"}
  → {"servers":[{"name":"github","transport":"http","tools":0,"connected":false,"disabled":false,
     "status":"failed","source":"config","plugin":null}],"checked_at":1791800000}
mcp.servers.add    {"profile":"atlas","name":"notes","config":{"url":"https://notes.example/mcp","auth":"oauth"}}
                   {"profile":"atlas","name":"files","config":{"command":"npx","args":["-y","@x/files"],
                    "env":{"ROOT":"/srv"},"cwd":"/srv"}}
                   {"profile":"atlas","name":"api","config":{"url":"https://api.example/mcp"},
                    "bearer_token":"test-token-123"}
  → {"ok":true,"name":"notes","server":{…summary…}}
mcp.servers.remove {"profile":"atlas","name":"notes"}            → {"ok":true,"removed":true}
mcp.servers.test   {"profile":"atlas","name":"github"}            (timeout 60 s)
  → {"ok":false,"tools":[],"error":"OAuth authentication required — no token found.","prompts":0,
     "resources":0,"oauth_needed":true,"oauth_tokens_present":false}
  → {"ok":true,"tools":[{"name":"create_issue","description":"Open an issue."}],"error":null,…}
mcp.servers.oauth.start    {"profile":"atlas","name":"github","client_redirect_uri":"http://127.0.0.1:53124/callback"}
  → {"ok":true,"session_id":"oa_1","auth_url":"https://github.example/authorize?…&redirect_uri=http%3A%2F%2F127.0.0.1%3A53124%2Fcallback&state=xyz","flow":"loopback"}
mcp.servers.oauth.callback {"profile":"atlas","name":"github","session_id":"oa_1","code":"abc","state":"xyz"}
mcp.servers.oauth.poll     {"profile":"atlas","name":"github","session_id":"oa_1"}
  → {"ok":true,"status":"pending|approved|error","session_id":"oa_1","error_message":"","auth_url":"…","tools":[…]}
mcp.servers.oauth.cancel   {"profile":"atlas","name":"github","session_id":"oa_1"}
reload.mcp                 {"confirm":true}                        (no profile; existing helper)
```
REST kept from today: `PUT /api/mcp/servers/<name>/enabled?profile=` `{"enabled":Bool}`.
New reads: `GET /api/config?profile=` (only `mcp_servers` used) · `GET /api/logs?file=&lines=&search=&profile=`.
Errors to map. RPC (`mcp.servers.*`): 4090 `server 'X' already exists`; 4090 `server 'X' is provided by plugin
'P' and cannot be modified`; 4064 `server 'X' not found`; 4063 bad config or unknown preset; 4001 `… rejected:
suspicious command/args configuration`, `stdio servers authenticate via env keys, not OAuth`, `this server uses
header/API-key auth, not OAuth`; 5024 anything the handler raised. REST: 409 `Server 'X' is provided by plugin 'P'
and cannot be modified` (the enabled route), 404 `… not found`, 400 `Unknown log file`.

**Checked (Revision 2):** `config` is saved as given (`server_config = dict(raw_cfg)`), so its keys are the
mcp.json entry's own: `url` or `command` (one is required), `args`, `env`, `headers`, `auth`, `cwd`, `tools`,
`enabled`. `bearer_token` is stored in the bot's `.env` and replaces `headers` with a template that names the
variable. `add` on an existing name **refuses** (4090); see §5.5-b for what that means for saving tool rules.
`mcp.servers.set_api_key {profile, name, value, env_var?}` also exists (stores a credential and points the entry
at it); this spec does not use it.

### 12.3 Reload rule
Reuse the existing `CapabilitiesStore` reload path unchanged (it already runs after `setMcp`). The web's phone gate
skips the reload when the picked bot is not the active one (`ref:src/…/connector-gates.ts:16`); if the existing
native helper already has an equivalent rule keep it, and if it has none, **DECISION (12.3-a):** add nothing —
"Changes apply to new chats." is the promise on screen, and a reload failure is never an error alert.

### 12.4 Plugins
```
plugins.manage {"action":"list","profile":"atlas"}
  → {"plugins":[{"name":"kanban","key":"bundled:kanban","version":"0.9.0","description":"A task board.",
     "source":"bundled","status":"enabled","portable":true,"has_desktop_half":true,
     "servers":[{"name":"kanban","state":"connected","sentence":""}],"catalog_name":null,
     "update_available":false,"settings_schema":[]}]}
plugins.manage {"action":"toggle","profile":"atlas","key":"catalog:web-clipper","enable":true}
  → {"ok":true,"restart_required":true,"gateway_reloaded":false,"missing_env":[],"warnings":[]}
plugins.manage {"action":"update","profile":"atlas","name":"web-clipper"}
  → {"ok":false,"consent_required":true,"sha":"9f2c1ab04d…","delta_lines":["+ tool: clip_page","+ hook: on_session_start"]}
plugins.manage {"action":"update","profile":"atlas","name":"web-clipper","accept_capabilities":true}
  → {"ok":true,"sha":"9f2c1ab04d…","restart_required":true,"gateway_reloaded":false}
plugins.manage {"action":"remove","profile":"atlas","name":"my-plugin"}  → {"ok":true,"name":"my-plugin"}
plugins.manage {"action":"install","profile":"atlas","identifier":"https://github.com/owner/repo","force":false,
                "enable":true}                    (optional "ref":"v1.2.0"; timeout 120 s)
  → {"ok":true,"plugin_name":"repo","enabled":true,"restart_required":true,"gateway_reloaded":false,
     "missing_env":["CLIPPER_KEY"],"warnings":[],"python_dependencies":[],"known_issues":[],
     "activation":{"name":"repo","key":"git:repo","live_now":{"mcp_servers":[{"name":"clipper",
       "connected":true,"tools":["clip_page"]}],"skills":[]},"activated_now":{},"deferred":{"tools":["clip"]}}}
plugins.manage {"action":"settings","profile":"atlas","key":"git:repo","values":{"region":"eu","verbose":true}}
  → {"ok":true,"plugin":{…the refreshed row, with settings_schema…}}
```
Which param each action takes is fixed by the web's calls (`V:store/agent-plugins.ts:158, 207, 306, 376, 412,
466`): `toggle` = `key` + `enable`; `update` = `name` (+ `accept_capabilities`); `remove` = `name`; `install` =
`identifier` + `force` + `enable` (+ `ref`); `settings` = `key` + `values`. Encode that in one `enum PluginAction`
so a wrong combination cannot be built; never send a param outside the contract's list.

### 12.5 Connect Apps, gateway side
```
profiles.list      {"include_sessions":false}            → default row: {"name":"default","ui_meta":{"dispatch-composio":{"userId":"dispatch-ab12cd34ef56","sessionId":"trs_1","allBots":true}}}
profiles.configure {"name":"default","ui_meta":{"dispatch-composio":{…}}}   → {"applied":{"ui_meta":true}}
PUT    /api/env?profile=atlas        {"key":"COMPOSIO_API_KEY","value":"<key>"}
POST   /api/env/reveal?profile=atlas {"key":"COMPOSIO_API_KEY"}             → {"value":"<key>"}
DELETE /api/env?profile=atlas        {"key":"COMPOSIO_API_KEY"}
mcp.servers.add    {"profile":"atlas","name":"composio","config":{"url":"https://backend.composio.dev/tool_router/trs_1/mcp","headers":{"x-api-key":"${COMPOSIO_API_KEY}"}}}
mcp.servers.remove {"profile":"atlas","name":"composio"}
reload.mcp         {"confirm":true}
```
Composio's own routes are in §10.2.

---

## 13. Fixtures

Ports: builders 10010–10014, stress tester 10015–10019. Simulators: "HQN-m9-capabilities" (builders),
"HQN-m9-capabilities-s" (stress), each created by its user with
`xcrun simctl create "HQN-m9-capabilities" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
Never the default simulator, never a port you did not start, never the owner's gateway. Stop fixtures and shut
down your own simulators when the stage ends (kill by the PID you recorded, never by name).

### 13.1 `scripts/fixtures/capabilities-gateway.py` (new)

Start from a copy of `scripts/fixtures/settings-gateway.py` (sign-in, cookies, roster, skills, actions, MCP
list/status/enabled, `/__settings/state`, `/__settings/fail`, per-method param allowlists) and add:

| Area | Adds |
|---|---|
| Skills | `usage` per skill; `--no-usage` |
| Tools | `GET /api/tools/toolsets`, `PUT /api/tools/toolsets/<name>`, `GET /api/analytics/usage` (8 toolsets, 2 hidden by the visibility rule, one `configured:false`, one `available:false`) |
| Tool setup (§4.3) | `GET /api/tools/toolsets/<name>/config`, `PUT …/provider`, `POST …/post-setup` + `GET /api/actions/tools-post-setup/status`, `GET …/models`, `PUT …/model`, `GET /api/tools/terminal/backends`, `PUT /api/tools/terminal/backend`, `GET/PUT/DELETE /api/env`; seeds: a toolset with two providers and one missing key, one with a one-time install, one with models, `terminal` with three backends |
| MCP | `mcp.servers.add/remove/test`, `mcp.servers.oauth.start/poll/callback/cancel`, `GET /api/config` (with `mcp_servers`, one entry seeded with fake secrets), `GET /api/logs` (mcp file with two stdio sections; agent file), plugin-provided server answering 409 on writes |
| OAuth provider | `GET /__oauth/authorize?redirect_uri=&state=` page with Allow / Deny (and `?auto=allow|deny` set by a flag), redirecting to `redirect_uri?code=…&state=…` or `?error=access_denied&state=…` |
| Plugins | `plugins.manage` list/toggle/update (consent, by `name`)/remove (by `name`)/install (`identifier`,`force`,`enable`,`ref`; "already installed" unless `force`; seedable `missing_env`, `restart_required`, `warnings`)/settings (`key`,`values`); 4 plugins incl. `kanban`, and `web-clipper` with a five-field `settings_schema`; one server state `unsupported_gpu` |
| Connect Apps | `profiles.configure` with `ui_meta` (+ `applied`), `PUT/DELETE /api/env` (DELETE of an absent key → 404, as Hermes), `POST /api/env/reveal` (6th call inside 30 s → 429, as Hermes), roster `ui_meta` on the default row |
| Control | `POST /__seed {…}` (replace any seed part: roster, statuses, skills), `POST /__fail {"target":"rpc:<method>"|"rest:<METHOD> <path>"|"action:<name>","mode":"error|500|hang|exit1|slow:<ms>","count":N}`, `POST /__log {"file","line"}`, `GET /__state` (full state + ordered request log with timestamps and in-flight counts) |
| Strictness | unknown RPC params → error 4000 (as today); unknown method → -32601 |
| Flags | `--old-oauth` (ignores `client_redirect_uri`), `--redact-config`, `--no-logs`, `--legacy-plugins`, `--no-plugins-rpc`, `--no-toolsets`, `--no-toolset-config` (404 on the §4.3 routes: old Hermes), `--read-only`, `--bots N` (roster size), `--skills N`, `--toolsets N`, `--servers N`, `--latency MS`, `--jitter MS`, `--drop-every N` (drops the socket every N RPCs) |

Start commands (builders), from the worktree root:
```
python3 scripts/fixtures/capabilities-gateway.py --port 10010 --hermes-cookies \
    --credentials build/fixtures/cap-a.json > build/fixtures/cap-a.log 2>&1 &  echo $! > build/fixtures/cap-a.pid
python3 scripts/fixtures/capabilities-gateway.py --port 10011 --label Beta --old-oauth --legacy-plugins --no-logs --no-toolset-config \
    --credentials build/fixtures/cap-b.json > build/fixtures/cap-b.log 2>&1 &  echo $! > build/fixtures/cap-b.pid
```
Tool-rules save with rollback (§5.5-b) is exercised with
`POST /__fail {"target":"rpc:mcp.servers.add","mode":"error","count":1}` sent after the editor is open: the remove
succeeds, the add fails once, the rollback add must succeed, and `/__state` must show the original entry intact.
With `"count":2` both adds fail and the app must show the "connector was removed" recovery sentence of §5.5.

10011 is the "old Hermes" gateway (second account; also proves issues swap per gateway, §8 A7).
Stop: `kill "$(cat build/fixtures/cap-a.pid)"` (and `cap-b.pid`).

### 13.2 `scripts/fixtures/composio-mock.py` (new, in this worktree)

Start from `ref:scripts/composio-mock.py` (read it; copy it into the worktree, do not edit the ref snapshot). It
already serves sessions, toolkits (search, cursor, `is_connected`), link, connected accounts, the consent page. Add:
`GET /api/v3/tools` if missing; a logo route; seeding (`POST /__mock/seed {"connected":[{"slug","status"}],
"count":N}`); failure injection (`POST /__mock/fail {"route","status","count"}`); `POST /__mock/next-link {"redirect_url"}`;
`--slow-activate S`; `--latency MS`; (§10.11) `multi_account` echoed in the session's config, the v3.1 named link,
the account list and PATCH alias, and `POST /__seed {"single_account":true}` for sessions made before multi-account; `GET /__mock/state` (request log, so tests can assert the key header reached
only this host and that a link was fetched once). Its docstring must not put "Dispatch" in anything the app shows
(it shows nothing of the mock's own text except the consent page; title that page "Stand-in sign-in").
The accepted test key stays `ak_mock_dispatch` (a fixture constant, not user-visible product text).

```
python3 scripts/fixtures/composio-mock.py --port 10012 > build/fixtures/composio.log 2>&1 &  echo $! > build/fixtures/composio.pid
```
App launch for Connect Apps tests (Debug build only):
```
SIMCTL_CHILD_HQN_COMPOSIO_BASE=http://127.0.0.1:10012 xcrun simctl launch <YOUR-UDID> <bundle id>
```
In XCUITest: `app.launchEnvironment["HQN_COMPOSIO_BASE"] = "http://127.0.0.1:10012"`.

### 13.3 `scripts/e2e-capabilities.sh [SIM_UDID] [CONFIG]`

Same shape as `scripts/e2e-settings.sh`: requires the UDID argument (no default), reads ports from
`HQN_CAP_PORTS="10010 10011 10012"`, starts the three fixtures, records PIDs, runs `UITests/capabilities`, prints
the summary with `scripts/e2e-summary.py`, and stops only the PIDs it started (trap on EXIT).

### 13.4 Which fixture exercises which row

| Rows | Fixture(s) |
|---|---|
| L711, L714, L715, L716 | capabilities-gateway 10010 |
| L718, L719, L720, L996 | capabilities-gateway 10010 (+ 10011 for old-OAuth, no-logs) |
| L721, L853, L875 | capabilities-gateway 10010 + 10011 |
| L722 | capabilities-gateway 10010 (+ 10011 legacy) |
| L723–L729, L997 | composio-mock 10012 + capabilities-gateway 10010 |

---

## 14. STRESS PLAN

Stress tester: simulator "HQN-m9-capabilities-s", ports 10015 (gateway), 10016 (old gateway), 10017 (Composio
mock), 10018–10019 spare. Same start commands as §13 with those ports and `build/fixtures/cap-s-*.{json,log,pid}`.
Record for each item: pass/fail, what was seen, a screenshot or log line. Anything that fails is a bug for the
builder, not a note.

### 14.1 Load
- L1. `--skills 600 --toolsets 120 --servers 80 --bots 40`: each tab scrolls at 120 Hz without hitches over 2
  frames (Instruments › Animation Hitches, or the on-device hitch counter), search stays responsive while typing.
- L2. A connector with 400 tools: the editor opens under 1 s after the `test` answer, toggling "All Tools" does not
  freeze, Save sends one write.
- L3. Logs: 500 lines of 2 000 characters each, polled for 5 minutes: memory flat (± 5 MB), no growth in line
  count beyond 500, CPU idle between polls.
- L4. All Bots on with 40 bots: never more than 3 writes in flight; the page stays scrollable; finishing shows the
  right counts.
- L5. Issue sweep with 40 bots (30 swept): done under 30 s on the latency-free fixture; UI never blocked; badge
  correct for the swept ones.
- L6. Composio: 120 connected apps, All Apps paged to 600 rows via Show More: memory stays under 60 MB over the
  baseline, logos cache holds at 64.
- L7. Disable Unused with 300 unused skills: sequential, cancellable by leaving the page? No — it continues in the
  model; verify it finishes and the count notice is right, and that the app remains usable meanwhile.

### 14.2 Speed
- S1. Capabilities opens with cached lists in under 300 ms from the More row tap (cached profile), skeleton never
  flashes for a cached tab.
- S2. Tab switch among four tabs: under 100 ms to first frame, no refetch within 30 s.
- S3. Connect Apps sheet: first frame of Home under 500 ms with the session cache present.
- S4. Tapping a switch reflects at once (optimistic) on every switch in this spec.
- S5. The More list does not reload or jump when the issue count changes (only that row reconfigures).

### 14.3 Bad network
- N1. `--latency 3000 --jitter 2000`: every screen shows its loading state, then content; no duplicate writes from
  repeated taps (switches are disabled while pending).
- N2. `--drop-every 5`: lists recover via the existing link retry; a write whose socket dropped is reported as
  failed once (no silent loss, no double write — check `/__state`).
- N3. Airplane mode (simulator: Network Link Conditioner 100 % loss, or stop the fixture): "Waiting for your
  gateway…" on each tab; Connect Apps: "Couldn’t reach Composio." states; nothing spins forever (every spinner has
  a 60 s ceiling).
- N4. `/__fail` `hang` on `mcp.servers.test`: the page gives up at 60 s with `BUSY_CHECK`; leaving earlier cancels.
- N5. OAuth with the gateway dropping between `start` and `poll`: ends with "Lost the gateway while signing in. Try
  again."; listener count returns to 0.
- N6. Composio 429 / 500 / 408 on each route: the mapped sentence shows; Try Again works after the failure count
  runs out.
- N7. Mock latency 5 s on `link`: the Connect button shows "Opening…" and cannot be double-tapped (one link request
  in the mock log).

### 14.4 Bad data
- D1. Toolsets/plugins/servers rows missing optional fields, with nulls, with unknown extra keys, with an unknown
  `status` string: rows still show; unknown status reads "Not started"/"Status unknown"; no crash.
- D2. Names with emoji, RTL text, 200-character names, names with `/`, `?`, `#`, spaces and `%`: correct
  percent-encoding in REST paths (fixture echoes the decoded name), layout wraps, no truncation of controls.
- D3. `GET /api/config` returning HTML, an empty body, a 5 MB body, `mcp_servers` as a list: "Couldn’t load the
  configuration."; no crash; nothing written.
- D4. Mask fuzz: 10 000 random entries generated around the secret shapes (unit test with a fixed seed): the output
  never contains a seeded secret substring of 8+ characters.
- D5. Logs with 50 KB single lines, NUL bytes, ANSI colour codes, invalid UTF-8 replaced by the server: shown cut
  and masked, ANSI stripped.
- D6. OAuth `auth_url` that is `javascript:…`, `http://` non-loopback, has a different `redirect_uri`, or is
  missing: never opened; the right sentence.
- D7. Loopback callback with a 9 KiB head, no `code` and no `error`, a wrong path, two callbacks in a row, a
  callback after cancel: handled by `LoopbackRelay` limits; the flow ends cleanly.
- D8. Composio: `items` missing, `next_cursor` repeating the same value forever (stop after 10 pages / on a
  repeated cursor), a toolkit without slug, a 3 MB answer, a logo that is SVG/HTML/1 MB (monogram fallback),
  `redirect_url` on another host.
- D9. `ui_meta["dispatch-composio"]` malformed (string, missing `userId`, `allBots:"yes"`): treated as no record;
  never overwritten without the user acting.
- D10. Plugin `delta_lines` of 500 lines, each 1 000 characters: the alert shows 12 and "and 488 more".
- D12. Plugin `settings_schema` with 60 fields, a field of unknown type, an enum with no choices, a secret
  without `env`, a 200 KB `json` value: the form scrolls, unknown types are read-only and masked, nothing crashes.
- D13. Install from Git with a 500-character address, an address with spaces, `--upload-pack=…`, `file:///etc`,
  a `ref` of 39 and 41 hex characters: each handled as §9.4 says; no request for the refused ones.
- D14. Tool setup (§4.3): `config` missing `providers`, a provider with no `env_vars`, 40 models, a backend list
  that is empty, `post-setup` status that never leaves `running` (gives up with its sentence at the ceiling).
- D11. Usage counts negative, huge (1e12), or as strings: clamped/ignored; `compact` never shows "NaN".

### 14.5 Interruption
- I1. Background the app during: skill install, Disable Unused, All Tools, tool-rules Save, add connector, OAuth
  (Safari up), Composio connect (auth session up), All Bots apply, Remove Composio. On return each is either
  finished, resumed, or reported once with its sentence; no stuck spinner; `/__state` shows no half-applied pair
  that the UI claims succeeded.
- I2. Incoming call banner / Control Center / notification over the auth session: the session survives.
- I3. Rotate and split-screen-size change (iPad not targeted; rotate on iPhone) on every new page, including with
  a sheet and an alert up.
- I4. Switch gateway (title switcher) while Capabilities, a connector page, the logs page and the Connect Apps
  sheet are open: pages for the old gateway close or reload for the new one; no write for the old gateway lands on
  the new one (check both fixtures' logs); issues swap.
- I5. Delete the picked bot from another device (fixture `/__seed` roster) while its Capabilities are open: the
  picker falls back to the default bot; its issues are forgotten.
- I6. Pop a page mid-write: the write completes or reverts in the model; the list is right when revisited.
- I7. Low Power Mode and Reduce Motion on: polling still works at its interval; no custom animation remains.
- I9. Tool-rules Save where the re-add fails after the remove (fixture recipe in §13.1): one failure → rolled back,
  original entry byte-identical in `/__state`, sentence shown once; two failures → the recovery sentence, the
  connector is listed as missing, and Add with the same values works. Also kill the app between the remove and
  the add (breakpoint or `slow:5000` on add): relaunch must not claim the connector exists.
- I10. Background the app during a plugin install and during a one-time tool install (§4.3): on return the notice
  or status is right; nothing was started twice.
- I8. Memory warning (simulator Debug › Simulate Memory Warning) with the logs page and All Apps open: no crash,
  logo cache emptied.

### 14.6 Relaunch
- R1. Kill during skill install → relaunch: no phantom "Installing…"; the list reflects the gateway.
- R2. Kill during OAuth: relaunch shows needs-auth with "Sign In"; no listener left (fresh process), the gateway
  session is abandoned (fixture expires it).
- R3. Kill during All Bots apply: relaunch → the reconciler finishes the rest (record says `allBots`), the Bots
  page shows the truth.
- R4. Kill during Composio connect: relaunch → the app page shows the real state from Composio (connected if the
  provider finished).
- R5. Kill during Remove Composio after the Keychain was cleared but before all bots were cleaned: relaunch shows
  setup; **check** the gateway still lists `composio` on the unfinished bots and that Capabilities › Connectors can
  remove them (the warning's promise).
- R6. State restoration: relaunch from More with Capabilities › Plugins open restores More properly
  (`mem:more-tab-restore-fix.md`) and the remembered tab; never restores into a connector page, an alert, the add
  form with a typed token, or the auth session.
- R7. Issues persist across relaunch and expire at 24 h (device clock moved forward on the simulator).
- R8. Delete and reinstall the app: the Composio Keychain item survives (iOS keeps Keychain items), exactly as it
  did for the web app. Decision 14.6-a of the first revision (clear it on first launch) is **withdrawn**: in the
  original-identity build it would erase the key the owner saved in the old app (§10.3 carry-over). Verify instead
  that after a reinstall Connect Apps opens on Home with the old key and that Remove Composio (§10.9) is what
  clears it.
- R9. Upgrade test for the carry-over: on the stress simulator, write a Keychain item with the service string of
  the original build and the mock key (a tiny debug-only test hook, or an XCUITest that saves through setup,
  then installs a fresh build over it) → first open of Connect Apps lands on Home, no setup screen, no gateway
  write (`/__state` unchanged) until a bot is switched on. With "All Bots" already on in the record, the
  reconciler adds the server to bots that lack it — confirm that this is what the fixture sees and nothing more.

### 14.7 Accessibility sizes and assistive tech
- X1. Every new screen at XS, L (default), XXXL, AX3 and AX5, on 375 pt and 440 pt widths, light and dark, and
  with UI Scale 110 % if the app's setting exists: no truncated control label, no overlapping text, switches and
  capsules keep a 44 pt target, wrapped rows keep 12–14 pt padding, trailing buttons drop under the text at large
  sizes.
- X2. The four-tab control: whole words in every case (one row, two rows, or Menu).
- X3. VoiceOver pass on every new screen: each row reads name, state and hint in a sensible order; switches read
  "\(name), on/off"; status changes are announced (install done, sign-in done, connect phases via
  `AccessibilityNotification.Announcement`); the masked config reads as "hidden" for mask runs (set the accessibility
  label of mask runs to "hidden" rather than six bullets).
- X4. Voice Control: every control has a speakable name ("Tap Sign In", "Tap All Bots").
- X5. Dynamic Type in the Connect Apps Popular grid: 4 → 3 → 2 columns, names never clipped (two lines allowed).
- X6. Increase Contrast, Reduce Transparency, Bold Text, Differentiate Without Colour: the red "N Issues" also has
  the words; status dots are paired with words everywhere; glass bars remain legible (system handles it — verify,
  do not replace with custom backgrounds).
- X7. Switch Control / Full Keyboard Access: the add form, the tool editor's Save/Discard bar and the consent alert
  are reachable and operable in order.
- X8. Right-to-left pseudo-language: layouts mirror; monospaced config and logs stay left-to-right.

### 14.8 Privacy and safety sweep (must all pass before any row is called done)
- P1. Grep the built app's strings and every screenshot for "Dispatch": none user-visible.
- P2. With the mock key and the fixture secrets in play, capture the unified log for the app's process over the
  whole e2e run: no `ak_mock_dispatch`, no `FIXTURESECRET`, no `test-token-123`.
- P3. `UserDefaults` plist and the app container (excluding the Keychain) contain none of those strings.
- P4. Pasteboard after every Copy in this spec contains masked text only.
- P5. Network capture (fixture/mock request logs are the capture): the Composio key header is seen only by the
  mock; the gateway fixture sees the key only in `PUT /api/env` bodies after a bot switch.
- P6. No request ever goes to a host other than the fixtures during tests (run with the simulator offline apart
  from loopback).

---

### 14.9 Added in revision 3 (after the train merge)

Run these on the merged tree, in addition to 14.1 to 14.8. The items the builder's report lists as "Not run"
(load L1 to L6, killing the gateway mid-install A5, relaunch mid-flow, text sizes and VoiceOver, key carry-over
R8/R9) are still owed and come first.

- M1. iPad, two panes ("iPad Pro 13-inch" simulator of your own, name "HQN-m9-capabilities-s-ipad"): More ›
  Capabilities and More › Connect Apps open in the right pane; every pushed page keeps the small title on the bar
  row; every confirm ("Disable Unused Skills", Remove, Uninstall, Disconnect, Remove Composio) is anchored to
  its row or button and does not crash (an unanchored action sheet throws on iPad).
- M2. iPad, Try It: with a chat already on show in the right pane, and with none; in both the bot's chat opens
  with the prompt in the composer, not sent, and one Back (phone layout, 420 pt window) returns to the app page.
- M3. iPad turned through all four orientations and dragged to a 420 pt wide window while: the tool editor has
  unsaved changes, a skill is installing, the Connect Apps sign-in is waiting. Nothing is lost, no duplicate
  write is sent (check the stand-in's state file).
- M4. Wording: on the iPad no string says "iPhone" (walk Advanced, the too-old-gateway sign-in notice, Connect
  Apps setup, the account menu, Remove Composio); on the iPhone none says "iPad".
- M5. Skins: pick each theme skin and the Desktop Look, then High Contrast, in light and dark: all four tabs, a
  tool page, a connector page, Advanced, Logs, a plugin page and the five Connect Apps pages follow the skin
  (page colour and fonts); no white or system-grey page is left behind. UI Scale at its largest and smallest: no
  clipped switch labels, rows still at least 44 pt.
- M6. Outage during every kind of read: stop the stand-in gateway, open each of the four tabs and Connect Apps
  Bots: each shows the last list with "Couldn’t refresh. Showing the last list." or its waiting state, never an
  empty page and never a spinner that does not end; start the gateway again: each fills in within 15 s without
  a tap. The reconnect notice never covers the tab's segmented control for more than 6 s.
- M7. Outage during every kind of write (tool switch, connector switch, tool-rule Save, add connector, plugin
  switch, plugin update, Install from Git, All Bots on): the control goes back, the reason is said once, and
  nothing is sent twice when the link returns (count calls in the stand-in log).
- M8. Low Power Mode on (`-HQDebugPowerSaving YES`): the connector status poll and the issue sweep slow down as
  the other polls do, and still clear an issue within two polls of recovery.
- M9. Reduce Motion on: Logs "Latest" jumps without an animated scroll. VoiceOver on: every notice this stream
  posts (install progress, refused switch, plugin result, Connect Apps result) is spoken exactly once.
- M10. Issue sweep with the gateway going away and back ten times in a minute: the More badge never flickers on
  for a connector that is healthy, and never shows a count for the account that was signed out.
- M11. Both identities: every UI test in `scripts/e2e-capabilities.sh` passes on a build made with
  `HQ_IDENTITY=original` as well as the native one (the sign-in callback scheme and the Keychain names differ).

## 15. Decisions index

0.2-a gateway wording · 2-a two-row segmented fallback · 3.1-a inline notices · 3.2-a hide Disable Unused without
usage (and `usage` becomes optional) · 3.2-b confirm Disable Unused · 4-a confirm All Tools off · 4-c tool setup
is built; only the computer-use and real-browser-profile panels stay on the computer (replaces 4-b) · 5.1-a "Sign
In" wording · 5.2-a plain type names · 5.2-b no env passthrough · 5.4-a the app's `WebAuthBrowser` for MCP OAuth
(revised; no SafariServices) · 5.5-a no quick filters · 5.5-b tool rules saved as remove-then-add with rollback,
redaction guard (settled) · 6-a sorted keys · 8.1-a "connectors need attention" · 8.1-b issues counted for every
bot · 8.2-a sweep cap 30 · 8.4-a app-icon badge untouched · 8.6-a no toast · 9-a no invented Kanban row · 9-c
Install from Git and plugin settings are built; the embedded catalog picker and repository probe are not
(replaces 9-b) · 10.1-a flag as a compile-time constant · 10.1-b app name as page title · 10.4-a keep gateway-key
reveal on explicit tap · 10.5-a explicit Show More · 10.6-a keep record key and id shape · 10.7-a reconciler needs
a local key · 10.8-a append to an existing draft · 10.8-b callback on the app's own scheme from `AppIdentity`
(revised) · 12.3-a reload rule unchanged · 14.6-a withdrawn (the Keychain item is never cleared on first launch).

## 16. Honest scope notes for the Ship agent

- L716 is specified whole (tab, tool page, setup: §4.3) except two panels that only make sense at the computer:
  computer-use permissions and picking a real browser profile; each is one plain sentence on the tool page (4-c).
- L722 is specified whole for the phone (list, on/off, update, uninstall, Install from Git, settings, Kanban
  switch). Not built: the embedded catalog picker and the repository probe (9-c), both web/desktop embeds.
- L718 ships without the two quick filters (5.5-a) and without env passthrough (5.2-b); the tool-rule save is a
  remove-then-add (5.5-b), the one place where a mid-write failure can leave the gateway without the connector;
  the app says so and offers the way back. If parity must be literal on the filters, that part stays 🟡.
- This is a large stream (20 rows, about 30 new files). If it cannot all be seen working, the honest order to cut
  is: §4.3 Execution Backend and Model sections, then §9.5, then §9.4. A cut row stays 🟡 with the gap named.
- No row here is proposed web-shell-only: none exists only because of the WebView.
- No row needs a relay, plugin or real-gateway change. What needs the owner is verification on real services; see
  `docs/owner-todo/capabilities.md`.

## 17. Revision 3 work list (after the train merge)

Order matters: 17.1 and 17.2 first (the unit run cannot pass without them), then 17.3, then the rest. Fixture
and port recipes are unchanged from §13: gateway on 10010, Composio stand-in on 10012, simulator
"HQN-m9-capabilities" (UDID `5D27782D-5FEF-4EDC-81F7-BCF355D17619` on this Mac), all through
`scripts/e2e-capabilities.sh <UDID>`.

### 17.1 Train conventions this stream's files must adopt (all rows)

| # | Work | Files | Check |
|---|---|---|---|
| a | Run `python3 scripts/desktoplook-migrate.py`, then build. It rewrites `.font(.body)` to `.font(Font.hq(.body))` and the like, and adds `.hqGroupedPage()` after every List / Form. Read the diff: a hand-written `Font.system(size:)` it cannot rewrite becomes `Font.hqSystem(size:)` by hand. | `App/Capabilities/` AddConnectorController, CapabilitiesViewController, ConnectorAdvancedController, ConnectorPageController, PluginsSections, ToolsetSetupSections, ToolsetsSections; `App/ConnectApps/ConnectAppsViews.swift` | `python3 scripts/desktoplook-migrate.py --check` prints nothing; `ThemeLintTests` pass |
| b | Announcements go through `HQAnnounce.say(_:)`, never `UIAccessibility.post(notification: .announcement…)`. | `CapabilitiesModel.swift:287, 338`, `CapabilitiesModel+More.swift:79`, `PluginsSections.swift:274`, `ToolsetsSections.swift:292`, `ComposioModel.swift:172` | `A11yLintTests` pass |
| c | The Logs "Latest" button scrolls without animation when `HQMotion.reduced`. | `ConnectorAdvancedController.swift:259` | `A11yLintTests` pass; stress M9 |
| d | "iPhone" in a string becomes `\(DeviceWord.name)`. The eight strings, with the wording kept otherwise: "Read-only on \(DeviceWord.name), with keys, tokens and passwords hidden. Edit this connector’s configuration on the computer running Hermes." · "This gateway’s Hermes is too old to sign in to connectors from your \(DeviceWord.name). Update Hermes on your computer, or sign in there." · "This \(DeviceWord.name) couldn’t save the key." (twice; the one in `HermesKit/Composio/ComposioClient.swift:42` takes the word as a parameter from the app side if `DeviceWord` is not visible to HermesKit: check `Shared/DeviceWord.swift`'s targets) · "Removed From This \(DeviceWord.name) Only" · "Saved on this \(DeviceWord.name)" · "Your bots lose these apps, and this \(DeviceWord.name) forgets the key. Connected accounts stay in your Composio project." · "Your key stays in this \(DeviceWord.name)’s Keychain. Nothing changes on your gateway until you turn on a bot." | as listed by `scripts/check-ipad.py` | `python3 scripts/check-ipad.py` prints `check-ipad: ok`; UI tests that match these strings read the word from the device |
| e | Every action sheet and share sheet this stream presents has an anchor (source view or bar button). `check-ipad.py` found none missing today; keep it so when adding Share to Logs (17.5 d). | all | `check-ipad: ok` |

### 17.2 Try It in two panes (row L728) — a real bug after the merge

`ref:src/composio/views-app.tsx` opens the bot's chat with the prompt typed in and not sent; that stays.
`N:App/ConnectApps/ConnectAppsViews.swift:960` finds the tabs with
`host?.view.window?.rootViewController as? MainTabController`, which is now always nil (the root is
`RootSplitController`), and falls back to `host?.tabBarController`; line 984 waits for the chat with
`navigation.topViewController as? ChatViewController`, which is never true in two panes (the chat is in the right
pane). Design, following `docs/briefs/m9/ipad-report.md` "Hooks for other streams" 1 to 4:

- Tabs: `MainTabController.current` (or `AppRoot.tabs`).
- Open: the same call the Bots list uses to open a bot's newest chat, so the phone layout brings Sessions to the
  front and two panes put the chat on the right.
- Find the chat to prefill: `MainTabController.current?.chatOnShow`, polled as today (0.1 s, same attempt cap).
- Failure wording unchanged: title "Couldn’t Open \(bot.name)", reason "Couldn’t open \(bot.name)’s chat."

Acceptance: UI C9's Try It step passes on the iPhone simulator and on an iPad simulator in two panes and in a
420 pt window; screenshot `connect-try-it-chat` looked at in each. No wire change.

### 17.3 The gate before any row is called done again

1. `scripts/build.sh build <UDID>` and `HQ_IDENTITY=original scripts/build.sh build <UDID>` both exit 0.
2. `scripts/build.sh test <UDID>`: all unit tests pass, including `ThemeLintTests`, `A11yLintTests`,
   `Tests/Capabilities/*`, `Tests/IPad/*`. (If the run hangs after the tests with `-quiet`, rerun without it:
   the ipad stream saw that once.)
3. `scripts/e2e-capabilities.sh <UDID>` (config A) and `… <UDID> S` (slow network): 14 of 14 each. A test that
   fails is rerun once before it is called a failure; an assertion is never loosened.
4. Replace `RESULTS_PLACEHOLDER` in the report with the real counts, date and simulator.
5. Open, do not just produce, one light and one dark screenshot of every page named in the rows file.

### 17.4 Quiet-network behaviour for the reads the offline stream did not reach (rows L711, L716, L722, L726, L727)

The train routes the skills and connector list reads through `QueryRetry.read` and the connector status poll
through `PowerPolls.loop` (`N:App/Capabilities/CapabilitiesModel.swift:205, 384, 405`). Do the same for:
the toolsets read and usage read (`GET /api/tools/toolsets`, `GET /api/analytics/usage`), the plugins read, the
issue sweep's per-bot reads (`ServerIssueSweep`: its timer becomes a `PowerPolls.loop` so Low Power Mode slows
it), and the Connect Apps gateway reads (the gateway record and bot list). Composio's own reads are not gateway
reads and keep their own error wording (§10.2). Rule from the offline stream, unchanged: "not connected" and
"connection lost" are unreachable and are not retried; the page keeps its last list and shows the existing
line "Couldn’t refresh. Showing the last list." with "Try Again". Writes are never retried automatically.
Acceptance: stress M6, M7, M8; one unit test per store that a transient failure is retried once and an
unreachable one is not.

### 17.5 Gaps from the builder's report, now owed

| # | Row | Gap | What to build | Acceptance |
|---|---|---|---|---|
| a | L716 | Execution Backend and image Model sections not driven by a UI test (C13 covers the backend; the model picker has none) | No new code expected. Add a UI test: open the image tool, pick another model, see `PUT /api/tools/toolsets/<name>/model` in the stand-in state, relaunch, the choice is still shown. Same for the one-time install: tap it, see the progress row, see it finish. | new UI tests pass; row 4 loses its "partial" note |
| b | L724 | "Use the Key on Your Gateway" not driven | UI test with the stand-in gateway holding `COMPOSIO_API_KEY`: tap the button, the key is revealed once (`POST /api/env/reveal`), saved to the Keychain, Home opens. Second case: the stand-in answers 429: the notice is the gateway's own sentence "Too many reveal requests. Try again shortly." and no key is saved. | passes |
| c | L727 | Per-bot Retry not driven | UI test: the stand-in fails one bot's write once; that bot's row shows its retry; tapping it sends exactly one more write and the row settles. | passes |
| d | L720 | Logs has Copy only, no Share | The web's logs page has neither copy nor share (`ref:vendor/hermes/apps/desktop/src/app/capabilities/mcp/mcp-logs.tsx`: no such control in the file). DECISION R3-b: native keeps Copy (already built, masked text only) and adds no Share: a share sheet would hand logs to any app in one tap and nothing in the web asks for it. Not a gap. | nothing | none |
| e | L721 | Opening Connectors from an issue lands on the tab but does not scroll to the failing connector | The web's issue carries the failing server's name when there is exactly one (`ref:src/ui-nav/more-model.ts:22-25`, `ref:src/connector-failure.ts:37-38`). Native: after the list loads, scroll the first connector with an issue into view (no animation under Reduce Motion) and give it VoiceOver focus; list order unchanged. DECISION R3-c. | UI C7 extended: with 30 connectors and the failing one last, it is hittable right after the tap on "1 Issue" |
| f | L718 | Leaving a connector page with unsaved tool changes does not ask | Back (button, edge swipe, Command-[ on a keyboard, Escape) with unsaved changes asks: title "Discard Changes?", message "Your changes to \(name)’s tools haven’t been saved.", buttons "Discard Changes" (destructive) and "Keep Editing". The same wording the app already uses for an unsaved form elsewhere wins if it differs: grep `Discard Changes` first. While a Save is in flight, Back waits for it. | new UI test: change a tool, Back, Keep Editing keeps the change, Discard drops it and the stand-in saw no write |
| g | L716 | Vision shows the hint only, no way to the model | The web shows the hint and a link "Choose vision model in Settings → Models" that opens Settings › Models at the auxiliary vision row (`ref:vendor/hermes/apps/desktop/src/app/capabilities/toolsets/toolset-detail.tsx:54-72`, wording `…/i18n/en.ts:2477-2479`). Native has that page: `AuxiliaryModelsView` / `AuxiliaryTaskView` (`N:App/Settings/Config/ModelPages.swift:422, 483`). Build: under the existing hint (wording already the web's), a navigation row titled "Choose Vision Model" (DECISION R3-d: Title Case row label instead of the web's sentence with an arrow, as native rows are) that pushes the auxiliary task page for `vision` on the same stack, through a hook in `SettingsHooks` / `SettingsScreens` so Capabilities does not import the page directly. On a read-only gateway the row still opens the page, which is already read-only there. If the gateway's auxiliary list has no `vision` task, the row is not shown (never a control that does nothing). No new wire call: the page uses `POST /api/model/set` with `scope: "auxiliary"`, `task: "vision"` as it does today. | UI test: Tools › Vision › Choose Vision Model opens the page titled for the vision task; pick a model; the stand-in saw one `POST /api/model/set` with scope auxiliary and task vision (add the route to `scripts/fixtures/capabilities-gateway.py` if it is not there); screenshot looked at |
| h | L725, L997 | The real system sign-in sheet is never opened by automation | Cannot be automated without the owner's accounts. Stays in `docs/owner-todo/capabilities.md` items 1 and 3. Add one thing that can be seen here: a DEBUG launch with `HQN_CAP_AUTH` unset against the stand-in opens the real `ASWebAuthenticationSession` sheet on the simulator; take a screenshot of the sheet showing the stand-in's sign-in page, cancel it, and see "sign-in closed" handled (the same notice C5 checks). | screenshot looked at; rows 5, 12, 19, 20 say "real sheet seen opening on the simulator against the stand-in; a real provider is the owner's check" |
| i | L726 | SVG logos fall back to a letter tile | Acceptable: the web shows the image the catalog gives; native has no SVG decoder without a third-party library or a web view. DECISION R3-e: letter tile stays for SVG; PNG and JPEG logos load. Make sure the stand-in serves at least one of each. | screenshot of Home with one PNG logo and one letter tile looked at |
| j | L996 | Row asks for an NWListener loopback; native returns through the app's own link | No change (5.4-a as revised by R3). The row is proposed to Ship as **done by a different route**, not web-shell-only: the feature (finishing a connector sign-in on the phone) exists; only the plumbing differs. If a provider refuses a custom-scheme return and insists on `http://127.0.0.1`, the existing `LoopbackRelay` is the fallback and must be covered: stand-in flag `--oauth-loopback-only` (add it to `scripts/fixtures/capabilities-gateway.py`), UI test C4b. | C4b passes |

### 17.6 iPad pass for every page (all rows)

Not a new feature; a check that this stream's pages obey the two-pane rules. Layout reads the view's own
bounds, never the screen (grep this stream's files for `UIScreen.main` and `.window?.bounds`: none allowed).
The four-tab segmented control uses its two-row fallback (DECISION 2-a) by measured width, so a 420 pt window
and a 320 pt slide-over both fit. The Capabilities list adopts `KeySearchable` so Command-F opens its search.
Pointer hover: rows that push get the standard highlight (`App/Kit/PointerEffects.swift`). Acceptance: stress
M1 to M4; screenshots `ipad-capabilities-right` (exists from the ipad stream) plus new `ipad-connect-home`,
`ipad-connector-page`, `ipad-tool-page`, each looked at.

### 17.7 Decisions added in revision 3

R3-a outcomes kept, gated by §17.3 · R3-b Logs keeps Copy and gets no Share · R3-c issue tap scrolls to the failing connector · R3-d "Choose Vision Model" row opens the auxiliary vision model page · R3-e SVG logos stay letter tiles · L996 proposed as
done by a different route, with a loopback-only stand-in case to prove the fallback.

### 17.8 Rows, restated for Ship after this revision

No row is proposed web-shell-only. No row needs a relay, plugin or real-gateway change; nothing new goes to
`docs/owner-todo/capabilities.md` (items 1 to 8 there stand). Rows that cannot ship until a named item lands:
L728 (17.2), L716 (17.5 a, g), L724 (17.5 b), L727 (17.5 c), L721/L853/L875 (17.5 e), L718 (17.5 f, j via L996),
L725/L997 (17.5 h). Every row waits on 17.1 and 17.3.
