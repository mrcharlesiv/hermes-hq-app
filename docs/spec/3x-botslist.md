# 3x · Bots list leftovers (run m9, stream `botslist`)

Branch `m9/botslist` · worktree `/Users/me/Projects/hermes-hq-native-wt/m9-botslist` · ports 10040–10044 (builders),
10045–10049 (stress tester) · simulators `HQN-m9-botslist` and `HQN-m9-botslist-s`.

Rows: the 17 in `docs/briefs/m9/botslist-rows.md` (parity-240 lines L128, L147, L152, L154, L161, L173, L174, L184, L185,
L186, L189, L210, L213, L215, L227, L237, L240), plus the Gateway › "All Gateways" part of L196 that the planner hung on
L240.

Conventions in this file: `S/` is the web app at `/Users/me/Projects/hermes-hq-native-ref240/src/` (read only),
`V/` is `/Users/me/Projects/hermes-hq-native-ref240/vendor/hermes/apps/desktop/src/` (read only), `C/` is
`/Users/me/.hermes/hermes-agent/tui_gateway/contracts/` (read only; never import it, never run it). Native paths
are relative to the worktree. **DECISION** marks a choice made here without the owner (asleep); each has its reason.

Nothing in this stream needs a relay, plugin or real-gateway change, so there is no `docs/owner-todo/botslist.md`.
If a builder finds one, write that file then and make the app behave as the row's "old gateway" state says.

**Revision 2 (2026-10-13).** The first version of this spec was written before talk, groups, screen, presence,
photoheads, offline, sessions, ipad, a11y, desktoplook, intents, share and capabilities landed on `m9/train`. The
branch now holds `m9/train` at `bd25418` (merge `6bee239`), and those streams built several things this spec had
planned to build itself. §0A lists every place where the merged code changes the plan; where §0A and a later section
disagree, **§0A wins**. Parity line numbers moved by +4 in `docs/parity-240.md` on the train (L128 is now line 132,
L147 → 151, … L240 → 244); the row ids in this file and in the rows file keep the assignment's numbers. All 17 rows
are still open there (same marks as assigned). Native line numbers quoted in §2–§17 are from the pre-merge tree unless
§0 or §0A restates them; find the symbol by name.

---

## 0. What is already true on `m9/train` (do not rebuild; verify and tick)

| Row | State found in code | What is left |
|---|---|---|
| L152 delete asks first | `App/Bots/BotsOrganizer.swift:282-290` already confirms when the section holds bots, same words as web (`TextPrompt.confirm`) | A UI test, the popover anchor on the section's ⋯, VoiceOver check |
| L154 drag auto-scroll | The list uses UICollectionView drag and drop (`BotsOrganizer`); UIKit scrolls a drop session near the edges | Prove it with a long list; fix only if it does not scroll |
| L227 sheets with no Bots page | `App/Root/MainTabController.swift:34,54` builds `BotsViewController` with the tabs, so the controller always exists; its `organizer` is still made in `viewDidLoad` (`BotsViewController.swift:116`) | The cases in §15 where `open(_:)` drops a pick (`botsByID` empty, roster not in yet), and the organizer's lifetime |
| L184 "Waking up…" | The rule exists (`HermesKit/Model/RosterRules.swift:120-123`, `BotStore.secondLine(for:opening:)` at `BotStore.swift:380-384`), nothing calls it with a real `opening` | Wire it per bot with the 1 s grace |
| L210 Recent Activity | `BotStore.recentChats(name:limit:)` (`HermesKit/Store/BotStore+Extras.swift:130-160`) and Bot Info's list exist; talk added the intro's role, description and Talk / Bot Info capsules (`App/Chat/ChatPlaceholderView.swift`) | The empty Bot Chat does not show the list |
| L189 "Not Delivered:" | sessions built the store: `HermesKit/Chat/LostSends.swift` (persisted per account, purged on sign-out), fed by `LiveChatSession.markUnconfirmed` → `noteLostSend`, and `SessionPending` (`HermesKit/Contracts+sessions.swift:63-75`) gives the prefix | Only the Bots row: read the same store for the bot's Bot Chat |
| L161 swipe peek | sessions built it for the Sessions list (`App/Sessions/SessionsViewController.swift:823-890`, key `hqn.sessions.swipePeek`, debug args `-HQDebugNoSwipePeek`, `-HQDebugResetSwipePeek`, `-HQDebugPeekHold`) | The same on the Bots list, sharing the code |
| L237 Undo pill | talk built the away pill and the hook: `TalkAwayPill.isShowing`, `TalkAwayPill.changed` (`hq.talk.pill.changed`), `TalkAwayPill.frameInWindow` (`App/Chat/Voice/TalkAwayPill.swift`) | The Undo pill does not read them yet; its clock restarts in full after a hold instead of resuming |
| L128 switcher label | `GatewayTitleSwitcher.swift:94` already says "<page>, on <gateway>, N new on other gateways" | Switching and offline wording, the double "Bots" reading |

## 0A. What the merge changed in this plan (binding)

1. **§1.1 row status.** presence already added `BotList.RowStatus` (an enum: `needsInput, browser, computer, working,
   idle`), `BotList.rowStatus(_:)`, `secondLine(_:)` and `rowBadge(_:)` in `App/Bots/BotListModel.swift:88-125`. Do
   **not** add a second type called `RowStatus` in HermesKit. Extend the existing enum in place with `attention` and
   `waking`, keep `browser` (presence's rank: after waiting-for-you, before "Using its computer"; a pending draft keeps
   its line and so does a pending "Not Delivered:"), and move the pure ranking into
   `HermesKit/Model/RowRank.swift` only if a unit test target needs it without the app. Final order, first match
   wins: link down (title subtitle, not the row — offline owns that wording and it stays where offline put it,
   `BotsViewController.swift:675-710`) → attention (orange, when not opening) → waking → waiting for approval / reply
   → browser line → "Using its computer" → "Working…" → idle (`Not Delivered:` → `Draft:` → preview → role → "No
   messages yet"). "Can’t reach this bot" is not a row status in the merged app (talk uses those words for its own
   alert); leave it out.
2. **§6 swipe peek (L161).** Lift the Sessions code into `App/Kit/SwipePeek.swift`
   (`SwipePeek.play(in:collectionView:host:key:markerId:revealColor:symbol:)`), call it from both lists, and delete the
   copy in `SessionsViewController`. Bots key: `hqn.bots.swipePeek`. Marker id `bots.peek`. The same three debug
   arguments drive both (reset clears both keys). Timing follows the merged Sessions peek (0.7 s after the rows show,
   60 pt, 0.35 s out, 0.45 s hold, 0.35 s back), **DECISION:** not the 900 ms / 56 pt first written here; reason:
   two lists in one app must peek alike, and the owner has already been shipped the Sessions one. The reveal strip
   takes the Bots row's first trailing action (its colour and symbol), not Sessions' grey "More".
   `test01_SwipePeekPlaysOnce` in `UITests/sessions` must stay green after the lift.
3. **§11 "Not Delivered:" (L189).** Do not write `UnconfirmedSends`. Use `LostSends.shared.first(accountId:profile:chatId:)`
   with the bot's `canonicalSessionId`, through `SessionPending.pending(lost:draft:)`, in the place `BotStore` already
   asks `draftWords` (`BotStore.swift:835-842`): add `lostWords: ((_ profile: String, _ chatId: String?) -> String?)?`
   beside it, set in `AppModel` next to `draftWords` (`App/AppModel.swift:299`). `LostSends.onChange` must also refresh
   the Bots rows (it refreshes Sessions today; chain, do not replace). The prefix is drawn red on the Bots row exactly
   as the Sessions row draws it (reuse its colour constant). Clearing is already done by sessions (Check found it,
   Send Again, Delete, transcript settle); only verify the Bots row follows.
4. **§12 Recent Activity (L210).** The capsule row is real now (`capsules` stack, `chat.intro.talk`, `chat.intro.info`).
   The list goes **under** the capsules in the same stack (`stack.setCustomSpacing(18, after: capsules)` is where it
   attaches); `ChatPlaceholderView.Intro` gains `recent: [SidebarSessionRow]` (the type `recentChats` returns today, not
   `SessionSummary`). The placeholder lets touches through except on Retry and the capsules
   (`ChatPlaceholderView.swift:232`): add the recent rows to that hit-test allow list. At accessibility sizes the
   capsules already stack vertically; the list follows them and the whole placeholder scrolls.
5. **§13 Bot Info header (L213).** The header now carries a photo or robot head through `HeadImage` (80 pt) and a tile
   row Talk · Memo · Screen · Mute (`BotInfoTiles`, `BotInfoSheet.swift:509`). Order after this stream: head (96 pt) →
   name → role → **status line** → tiles. "more" today is lower case and shows only past 160 characters with no way
   back (`:404`); §13's "More" / "Less" replaces it. The " · Watch" slot: presence and screen are merged, so this
   stream wires it — when `bot.presence?.usingComputer == true` the status line ends " · Watch" as a tint button that
   runs `model.screen()` (the Screen tile's action); it is hidden whenever the Screen tile is hidden.
6. **§7 and §15 (L173, L174, L227): iPad.** The signed-in root can be `RootSplitController` (two panes). Every "push"
   in §7 and §15 goes through the tab stack's `PaneNavigationController`, which already routes a chat to the right pane;
   never call `splitViewController` APIs or assume `MainTabController` is the window root — reach it with
   `AppRoot.tabs(window)` / `MainTabController.current`. "The chat is the top page" means: phone layout, top of the
   Bots stack; two panes, the detail pane shows that chat and the list pane still shows Bots with that row marked
   (`markOnShow`). `BotExtras.botsList()` (`App/Bots/BotExtras.swift:153-159`) is the function to grow into
   `openChat(bot:from:)`. A group row's pick goes through groups' open (`BotsViewController.swift:812-818`) under the
   same "newest pick wins" rule. Acceptance for L174 and L227 runs on the phone simulator and once on an iPad simulator
   (`UITests/ipad` shows how to launch two panes; create "HQN-m9-botslist-pad" only for that run, shut it down after).
7. **§16 Undo pill (L237).** No `BottomAccessoryArbiter`, no stand-in view, no `-HQDebugAwayPill`. `UndoPill` reads
   `TalkAwayPill.isShowing` and observes `TalkAwayPill.changed`. Everything else in §16 stands (pending while the away
   pill shows, fade and keep the remainder if it appears, resume not restart after a hold — `restartTimer()` at
   `UndoPill.swift:150-158` restarts in full today, which is the bug to fix). groups' `showsUndo: false` notice
   ("“Launch Room” was deleted.") follows the same rules. The test drives the real pill: start a Talk conversation
   against the voice stand-in the way `UITests/talk` `testE10_AwayPill` does, go to the Bots list, hide a bot. When the
   pill is absent the Undo pill sits 8 pt above the tab bar; never draw both at once.
8. **§17 Gateway filter (L240, L196).** groups added Show › (All, Bots, Group Chats) at the head of the menu and
   `clearFilters()` now resets kind and activity (`BotsViewController.swift:879-930`); that is already the behaviour
   §17 asks for. Left for this stream: the face and the "N New" subtitle on each Gateway item, items disabled while
   switching, filters kept per gateway, and the test. L196's remaining gap is then only "All Gateways", closed by
   §17's DECISION.
9. **§2 switcher label (L128).** a11y is merged and did not change the label; this stream finishes it as written.
10. **§10 background work (L186).** offline added process claims to `ActivityStore` (`setProcessClaims`,
    `agents.list` in the 30 s stale check, `hasLiveWork` already ORs them, `ActivityStore.swift:79-100,168-176,613-630`).
    So do **not** add a separate `BackgroundWork` class: add the list-visible poll to `ActivityStore` itself —
    `setRosterVisible(_:)` and a 5 s (15 s when `PowerState.shared.saving`) `ReadFlight` that, for each profile with
    live work and no running turn, reads `subagent.list` (existing reader) and `process.list` (new reader beside it,
    same 4001 / -32601 / three-failures rules the `subagent.list` reader has at `:51`). What is new: `process.list`,
    the 5 s cadence while the Bots list is on screen, and a claim that starts from `tool.complete` (terminal /
    process) when no composer capsule has fed `setProcessClaims` (the composer stream's L461 is not on the train).
11. **§1.2 fixture.** Keep the plan, but start from the shapes the merged fixtures already have rather than inventing
    new ones: `/__fixture/subagents` as in `scripts/fixtures/activity-gateway.py`, lost sends as
    `scripts/fixtures/sessions-gateway.py` drops them, two labelled gateways as `settings-gateway.py`. The script and
    test names in §1.2 stand. Port map unchanged (10040–10044 builders, 10045–10049 stress).
12. **Fonts and colours.** desktoplook and a11y moved the app to `Font.hq(…)` / `HQFont` and `Color.hqLabel`,
    `hqLabel2`, `HQPalette`. Every new label in this stream uses them (no raw `.font(.footnote)`, no `UIColor.label`),
    or the desktoplook and a11y suites will flag it.

## 0B. Closest first

How near each row is to done on the merged tree, nearest first. "Done" still needs the test or screenshot.

| Rank | Row | Why it is close | Work left |
|---|---|---|---|
| 1 | L152 delete-section asks | Built, web wording | Anchor check, one UI test |
| 2 | L154 drag auto-scroll | System behaviour, probably already true | One long-list UI test; fallback scroller only if it fails |
| 3 | L189 "Not Delivered:" | Store, prefix and clearing exist (sessions) | One closure in `BotStore`, red prefix on the row, test |
| 4 | L161 swipe peek | Working code on Sessions | Lift to `App/Kit`, call from Bots, test |
| 5 | L237 Undo pill rules | Pill and away pill both exist with the hook | Read the hook, resume-not-restart, tests |
| 6 | L128 switcher label | Label mostly right | Switching / offline words, single element |
| 7 | L240 (+L196) Gateway filter | Menu exists; DECISION closes "All Gateways" | Face and "N New" on items, test |
| 8 | L184 "Waking up…" | Rule and words exist | Per-bot `openingSince`, 1 s grace, spinner |
| 9 | L173 preview tap | One delegate method | Method, test |
| 10 | L213 Bot Info header / About | Sheet exists | Status line, 96 pt head, More / Less, Watch |
| 11 | L210 Recent Activity | Read and filter exist | List under the capsules, cache, tap |
| 12 | L174 picks close the list | `botsList()` half does it | One open path, every caller moved, iPad |
| 13 | L227 no Bots page | Controller exists from launch | Organizer lifetime, wait-for-roster open |
| 14 | L147 pinned reconcile | Patch rules ported | New reconcile pass, retry minute, fixture `meta` |
| 15 | L185 standing failure | Nothing yet | Classifier, store, orange rank, tile dot |
| 16 | L215 Instructions editor | Model rows exist | New page, describe / configure, guards |
| 17 | L186 background work | Claims and stale check exist | `process.list`, 5 s list poll, fixture |

**DECISION:** build in this order instead of §18's, shipping the first seven as the quick wins. Reason: the owner
asked for one feature per build and judges by feel; the nearest rows give the most finished rows per day and none of
them blocks a later one. The fixture (§1.2) is still step zero, built up row by row (its first version needs only the
roster, sections and two gateways).

---

## 1. Shared pieces this stream adds

### 1.1 Row status, one function (L184, L185, L186, L189)

> Revision 2: read §0A item 1 first. The type below is **not** added under that name; the existing
> `BotList.RowStatus` is extended. The ranks, tones, prefix rule and tests described here still apply.

Web ranks a row's second line in one place (`S/ui-bots/row-status.ts:19-29`, `S/ui-kit/bot-status.ts:41-55`). Native has
two half copies (`App/Bots/BotListModel.swift:86-94`, `RosterRules.secondLine`). Replace both with one pure function
in `HermesKit/Model/RowStatus.swift`:

```swift
nonisolated struct RowStatus: Equatable, Sendable {
    enum Key { case offline, waking, unreachable, attention, approval, reply, computer, working, idle }
    enum Tone { case secondary, tint, orange, red }
    var key: Key; var text: String; var tone: Tone; var spinner: Bool
    /// Words drawn before the text in their own colour ("Not Delivered:" red, "Draft:" label colour), or nil.
    var prefix: String?; var prefixTone: Tone
}
static func rowStatus(link: LinkState, available: Bool, opening: Bool, attention: String?, needsInput: NeedsInput?,
                      usingComputer: Bool, working: Bool, pending: RowPending?, preview: String?, role: String?) -> RowStatus
```

Order, first match wins (web order, cited above):

1. link down: "Offline" / "Reconnecting…" (secondary)
2. `available && !opening && attention != nil`: the attention words, **orange** (L185)
3. `opening`: "Waking up…", secondary, spinner (L184)
4. not available: "Can’t reach this bot" (secondary)
5. waiting for approval: "Waiting for your approval" (orange); waiting for a reply: "Waiting for your reply" (orange)
6. using its computer: "Using its computer" (tint)
7. working (own turn, or background work per §8): "Working…" (tint)
8. idle: `pending` (L189) → preview → role → "No messages yet"

`BotList.secondLine(bot)` becomes a thin call to it. `Bot` (`HermesKit/Contracts.swift:164-183`) gains three display-only
fields, none persisted: `opening: Bool`, `attention: String?`, `notDelivered: String?`. `BotStore` fills them when it
builds rows; tests assert the table above row by row (`Tests/RowStatusTests.swift`, one test per rank plus every
adjacent pair in conflict).

VoiceOver: the row label is `name, status text, N unread` (web `rowLabel`, `S/ui-bots/row-status.ts:52-53`); the prefix is
read as part of the text ("Not Delivered: see you at nine"). `BotList.accessibilityLabel` takes the `RowStatus`.

### 1.2 A new stand-in gateway: `scripts/fixtures/botslist-gateway.py`

No committed fixture has slow opens, standing provider failures, background processes and desktop-side meta edits in
one place. Builders write `scripts/fixtures/botslist-gateway.py`. It loads `scripts/fixtures/settings-gateway.py` with
`importlib` (the way that file loads the voice fixture, `settings-gateway.py:31-36`) so it keeps password sign-in,
`--hermes-cookies`, `--label`, `/api/ws`, the roster and `profiles.configure` with per-key compare-and-swap, and adds:

Roster (seeded, overridable by `/__fixture/roster`): 14 bots — `hermes` (default), `ada`, `basil` … so the list is
longer than one screen at every text size; two sections "Work" (3 bots) and "Home" (1 bot); one bot pinned by the
phone's rule (`sectionId: "hermes-hq-pinned"`, `pinnedFrom: {id, name}`); one hidden.

RPC it answers beyond the settings fixture (params exactly as the contract; an unknown key answers error 4000, as
Hermes' `extra="forbid"` does, `C/base.py:16,32-35`):

| Method | Params | Result |
|---|---|---|
| `profiles.list` | `{profile?, include_sessions?}` | `{profiles, bot_mode_protocol: true, install_id}` |
| `profiles.describe` | `{name}` | `{name, description, soul, model:{provider, default}, skills, toolsets, toolsets_pinned, mcp_servers}` |
| `profiles.configure` | `{name, soul?}` plus the settings fixture's keys | `{ok: true, applied: {soul: true}}` |
| `subagent.list` | `{session_id, profile?}` | `{subagents: [...], delegations: []}`; 4001 when the session is not bound on this socket |
| `process.list` | `{session_id, profile?}` | `{processes: [{session_id, command, status: "running", exit_code: null}]}` |
| `delegation.status` | `{profile?}` | `{active: [], paused: false, max_spawn_depth: 2, max_concurrent_children: 3}` |
| `agents.list` | `{profile?}` | `{processes: []}` |

REST: `GET /api/profiles/sessions?limit=&offset=&min_messages=&archived=&order=&profile=` → `{sessions: [...]}` from a
seeded table (per bot: 6 person chats, 1 cron run, 2 `tool`, 1 `subagent`, 1 `kanban`, 1 `oneshot`).

Side channels (HTTP POST with a JSON body, same origin, fixture credentials; each answers `{ok: true}`):

| Path | Body | Effect |
|---|---|---|
| `/__fixture/roster` | `{bots: N}` or full rows | replaces the roster; `N` up to 500 for load |
| `/__fixture/meta` | `{name, patch}` | edits `ui_meta['hermes-bots']` as a desktop would (bumps the key revisions), e.g. `{"name":"ada","patch":{"pinned":true}}` |
| `/__fixture/configure-fail` | `{name, times}` | the next `times` `profiles.configure` calls for that bot fail with 5000 |
| `/__fixture/open-delay` | `{name, ms}` | `session.resume` / `session.create` for that bot answers after `ms` |
| `/__fixture/turn-error` | `{name, message, reason?}` | the bot's next turn ends in an `error` event with that message |
| `/__fixture/subagents` | `{name, rows}` | what `subagent.list` returns for the bot's bound session |
| `/__fixture/procs` | `{name, rows}` | what `process.list` returns |
| `/__fixture/silent-finish` | `{name}` | the running turn ends with no `message.complete` reaching a socket that is not bound |
| `/__fixture/drop-send` | `{name}` | closes the socket after reading the next `prompt.submit`, before answering (delivery unconfirmed) |
| `/__fixture/recent` | `{name, rows}` | the bot's `/api/profiles/sessions` rows |
| `/__fixture/latency` | `{ms, jitter?, fail_every?}` | delays every answer; every Nth request is dropped |
| `/__fixture/no-method` | `{methods: [...]}` | those methods answer -32601 (an older gateway) |
| `/__fixture/state` (GET) | | `{writes: [...], calls: {method: count}}` for assertions |

Start commands (builders; never a port outside the stream's range, and refuse a busy port as the other scripts do):

```sh
cd /Users/me/Projects/hermes-hq-native-wt/m9-botslist && mkdir -p build/fixtures && chmod 700 build/fixtures
python3 scripts/fixtures/botslist-gateway.py --port 10040 --hermes-cookies --credentials build/fixtures/botslist-a.json > build/fixtures/botslist-a.log 2>&1 &
python3 scripts/fixtures/botslist-gateway.py --port 10041 --label Beta --credentials build/fixtures/botslist-b.json > build/fixtures/botslist-b.log 2>&1 &
```

Stress tester: the same two lines on `10045` and `10046` with `botslist-sa.json` / `botslist-sb.json`.

`scripts/e2e-botslist.sh [SIM_UDID]` copies `scripts/e2e-settings.sh` (ports from `HQN_BOTSLIST_PORTS`, default
`"10040 10041"`; credentials reach the runner as `TEST_RUNNER_HQN_BOTSLIST_A` / `_B`; stops only the fixtures it
started; derived data in `build/dd-botslist`). UI tests live in `UITests/botslist/BotsListEndToEndTests.swift`
(`testL1_…` numbering below). Existing suites that must stay green on this stream's ports:

```sh
HQN_SETTINGS_PORTS="10042 10043 10044" HQN_DD=build/dd-botslist scripts/e2e-settings.sh <HQN-m9-botslist UDID>
```

Simulator: `xcrun simctl create "HQN-m9-botslist" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`; boot only
that UDID; shut down that UDID (never `shutdown all`) and kill only the fixture PIDs you started at the end of a stage.

---

## 2. L128 · VoiceOver label for the switcher title

**Web.** `S/gateway-title.tsx:39-43` builds one label: page title, then `on <gateway>`, then `<N> new on other
gateways`, joined by ", ". The element is a button with a menu (`:73-75`), disabled while a switch runs; the visible
subtitle reads "Switching to X…" then (`:86`).

**Native today.** `App/Gateways/GatewayTitleSwitcher.swift` labels the subtitle button `"<title>, on <gateway>, N new on
other gateways"`, hint "Shows your gateways.", id `gateway-switcher`. The large title "Bots" is a separate element, so
VoiceOver reads "Bots" twice, and the label does not change while switching or offline.

**Design.**
- One element. With more than one gateway the large title's own accessibility element is hidden
  (`accessibilityElementsHidden` on the title label through the switcher's host view; if the system large title cannot
  be hidden without private API, keep it and drop the page title from the button's label instead — never both). The
  switcher element has traits `.button` + `.header`.
- Label, exactly: `"<page>, on <gateway>"`, plus `", <N> new on other gateways"` when N > 0 (N is the count the
  subtitle shows; "9+" is spoken as "more than 9").
- While switching: label `"<page>, switching to <gateway>"`, trait `.notEnabled` added; when the switch lands, post
  `.announcement` "Now on <gateway>".
- Offline: `"<page>, on <gateway>, offline"`.
- Hint stays "Shows your gateways." With one gateway there is no switcher and nothing changes.
- **DECISION:** a11y stream also named this row; botslist owns the label, a11y only audits it. Reason: planner note.

**Wire.** None.

**Fixture.** Two gateways: the two §1.2 start lines (10040, 10041). `/__fixture/latency {"ms":3000}` on B holds the
switching state long enough to read it.

**Acceptance.** `testL1_switcherLabel`: sign in to A and B; the element `gateway-switcher` has label "Bots, on
<A title>"; make a bot on B unread (`/__fixture/meta` is not needed: start a turn on B via `/__fixture/turn`, already
in the settings fixture) → label ends ", 1 new on other gateways"; pick B → label "Bots, switching to Beta…" then
"Bots, on Beta". No second element with label "Bots" exists in the navigation bar. Same on Sessions and More.

---

## 3. L147 · Pinned reconcile on every roster change

**Web.** `S/ui-bots/pinned-section.ts:23-46`: after every roster change, for each bot that is not a ghost, compute
`pinnedSectionPatch` (`S/ui-bots/pinned-section-model.ts:47-63`); if there is one, write it. A `writing` set allows one
write per bot at a time; a failed write (`serverOutcome === 'failed'` or a throw) is not tried again for
`RETRY_MS = 60_000`. Then the Pinned section is moved to index 0 on this device. `shownSections` (`:49-53`) hides
Pinned unless a row uses it.

**Owner.** memory `pinned-section.md`: "The owner picked 'auto Pinned section, include desktop pins too'." Limits the
owner was told and accepted: desktop puts an adopted Pinned folder at the bottom; an empty Pinned stays on desktop;
group chats are not included.

**Native today.** `HermesKit/Model/PinnedSection.swift` is a line-for-line port of the patch rules, used when the phone
pins, unpins or moves (`BotStore+Editing.swift:371-395`). A desktop edit is only *displayed* right
(`HermesKit/Model/RosterWire.swift:190`); nothing writes the agreeing meta back, so the desktop keeps a bot it pinned
in its old folder and a bot unpinned on the desktop stays in the desktop's Pinned folder.

**Design.** `HermesKit/Store/BotStore+PinnedReconcile.swift`:

```swift
/// Called at the end of every roster apply (poll, push refresh, after any meta write lands).
func reconcilePinned(now: Date = .now)
```
- Skips: read-only gateway (`isReadOnly`), ghosts/optimistic rows, a bot with a meta write in flight
  (`editing.inFlight[name] != nil`), a bot in `pinnedWriting`, a bot whose `pinnedRetryAt[name] > now`.
- For each remaining bot: `PinnedSection.pinnedSectionPatch(meta) { sectionName($0) }`; nil → nothing. Otherwise add to
  `pinnedWriting`, send through the existing `writeMeta(name:patch:undo:)` path (it already does compare-and-swap,
  local apply and undo on refusal), and on any failure set `pinnedRetryAt[name] = now + 60 s`. Always remove from
  `pinnedWriting` at the end.
- No error is shown: this is housekeeping the owner did not ask for by a tap. The display rule in `RosterWire` keeps
  the list right meanwhile.
- The state is per account and cleared on a gateway switch and sign-out.
- A retry is driven by the next roster apply after the minute (the poll runs every 30 s on the list, 120 s off it,
  `BotStore.pollInterval`); no extra timer.

**Wire.** One call per bot:

```json
{"method":"profiles.configure","params":{"name":"ada",
  "ui_meta":{"hermes-bots":{"sectionId":"hermes-hq-pinned","sectionName":"Pinned","pinnedFrom":{"id":"sec-work","name":"Work"}}},
  "ui_meta_expected_revisions":{"hermes-bots":7}}}
```
→ `{"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":8}}}`. A conflict
(`applied.ui_meta_conflicts`) is handled by `writeMeta` as today (re-read, re-patch once); a second conflict counts as
a failure (waits a minute). Desktop unpin: `{"sectionId":"sec-work","sectionName":"Work","pinnedFrom":false}`; home
deleted: `{"sectionId":null,"sectionName":null,"pinnedFrom":false}`.

**UI states.** None new. A desktop pin: the bot's tile appears and its row leaves its section on the next roster
apply (already so, by the display rule). Read-only gateway: no writes.

**Fixture.** §1.2 on 10040. `/__fixture/meta {"name":"ada","patch":{"pinned":true}}` is the desktop pin;
`{"pinned":false}` the unpin; `/__fixture/configure-fail {"name":"ada","times":1}` the failed write.

**Acceptance.**
- Unit (`Tests/PinnedReconcileTests.swift`, a fake client): one write per bot per apply even when the roster applies
  three times before the answer; a failed write is not repeated for 60 s and is at 61 s; a bot with a write in flight
  is skipped; read-only writes nothing; every branch of `pinnedSectionPatch` yields the expected wire body.
- `testL2_desktopPin`: desktop-pin `ada` → within 35 s the tile `bot-tile-ada` exists and `/__fixture/state` shows
  exactly one `profiles.configure` for `ada` carrying `sectionId: "hermes-hq-pinned"` and `pinnedFrom.id` = its old
  section. Desktop-unpin → the row `bot-row-ada` is back under "Work" and one write carries `pinnedFrom: false`.
- With `configure-fail` 1: one failed call, no second call inside 60 s, one more after.

---

## 4. L152 · Deleting a section that holds bots asks first

**Web.** `S/ui-bots/section-delete.ts:4-9`: title `Delete “<name>”?`, message `Its bot moves to Unassigned.` /
`Its <N> bots move to Unassigned.`, button `Delete Section` (destructive), anchored at the section's ⋯.

**Native today.** Done in `BotsOrganizer.deleteSection` (`App/Bots/BotsOrganizer.swift:273-281`) with those words, then
the Undo pill for 8 s. An empty section deletes at once with the Undo pill.

**DECISION:** keep both the question and the Undo pill. Reason: the web asks; the native pill was the owner-approved
native way back; having both costs one tap and loses nothing.

**Left to do.** (1) The confirmation is an action sheet anchored on the section header's ⋯ button
(`popoverPresentationController.sourceItem`), not a centred alert — check, fix if centred. (2) Cancel is the default
VoiceOver escape (two-finger scrub). (3) Tests.

**Wire.** On confirm, per member, in order: `profiles.configure {name, ui_meta:{"hermes-bots":{"sectionId":null,
"sectionName":null}}, ui_meta_expected_revisions}` (existing `finishDeleteSection`).

**Acceptance.** `testL3_deleteSectionAsks`: "Work" (3 bots) → ⋯ → Delete Section → a sheet titled `Delete “Work”?`
with `Its 3 bots move to Unassigned.` and buttons `Delete Section`, `Cancel`. Cancel: nothing changed, zero writes.
Confirm: header gone, three writes, the pill "Section deleted" with Undo; Undo brings header and members back. A
one-bot section says `Its bot moves to Unassigned.` An empty section shows no question.

---

## 5. L154 · The list scrolls when a dragged row nears an edge

**Web.** `S/ui-bots/row-drop-model.ts:13-18`: within 72 pt of the top or bottom edge the list scrolls, faster nearer
the edge, up to 14 pt a frame.

**Owner.** memory `row-drag-sections.md`: asked 2026-10-01 to drag bots between sections; "hold a row until its menu
shows, then move"; a row is draggable only when a section exists.

**Native.** The drag is a UIKit drag session; UICollectionView scrolls itself during a drop session when the finger is
near an edge of its *visible, unobscured* bounds.

**DECISION:** use the system's scrolling and its speed; do not port the 72 pt / 14 pt numbers. Reason: it is the
native behaviour every iOS list has, and a second scroller would fight it.

**Left to do.** Prove it, and fix what stops it:
- The bottom edge is under the floating tab bar and the top under the large title. If the system zone sits under the
  bars so that a finger above the tab bar does not trigger it, add a fallback in `BotsOrganizer`'s
  `dropSessionDidUpdate`: when the session location is within 72 pt of `collectionView.bounds` inset by
  `adjustedContentInset`, drive `contentOffset` with a `CADisplayLink` at up to 14 pt a frame, clamped to the scroll
  range, stopped on `dropSessionDidEnd` / `dropSessionDidExit`. Only add it if the test below fails without it.
- The pinned tiles grid must not swallow the scroll (it is one section of the same collection view; check).

**Wire.** None while dragging; the drop writes as today.

**Fixture.** §1.2 on 10040 (14 bots, two sections) and `/__fixture/roster {"bots":60}` for a long list.

**Acceptance.** `testL4_dragScrolls` (launch without `-HQDebugNoDrag`): hold the first unassigned row (touch path:
first point repeated twice with 450 ms, the recipe in `row-drag-sections.md`), drag to 40 pt above the tab bar and
hold 2 s → the last section's header becomes hittable; release on it → the bot is filed there (one write). Same
upward from the bottom of a 60-bot list to the top. At accessibility size AX3 too.

---

## 6. L161 · One-time swipe peek on the first row

**Web.** `S/ui-bots/bot-row.tsx:141-153, 311, 364-368`: 900 ms after the list first shows, the first row (not hidden,
not parked) slides to hint at its swipe actions, once per install; the flag (`dispatch.bots.swipePeeked`) is set only
if the peek actually ran.

> Revision 2: §0A item 2 replaces the file, key, timing and debug-argument details below (shared `App/Kit/SwipePeek.swift`,
> key `hqn.bots.swipePeek`, the Sessions timings, `-HQDebugResetSwipePeek`). The conditions and DECISIONs stand.

**Native design.** `App/Bots/SwipePeek.swift`, called from `BotsViewController.viewDidAppear`:
- Conditions, all required: `UserDefaults` key `hq.bots.swipePeeked` is false; the list has at least one ordinary row
  (not a tile, not hidden) and it is on screen; the list is not being scrolled, dragged, searched or edited; no sheet,
  menu or alert is up; Reduce Motion is off; VoiceOver and Switch Control are off; the app is active.
- 900 ms after `viewDidAppear` (re-checked then): the first row's content slides 56 pt toward the leading edge showing
  the first trailing action's colour and symbol behind it (the real action view from the row's trailing swipe
  configuration), holds 350 ms, springs back (total ≈ 1.1 s). Any touch cancels it at once and snaps back.
- Implementation without private API: the list's swipe actions come from `UICollectionLayoutListConfiguration`
  providers (`BotsViewController.swift:213-236`), which cannot be opened by code. So the peek animates the cell's
  `contentView.transform` and shows a strip behind it built from that same `UIContextualAction` (its `backgroundColor`
  and `image`). The strip is decoration only (`isAccessibilityElement = false`, no touches); it is removed when the
  animation ends.
- The flag is set when the animation *starts* running, not when conditions fail.
- **DECISION:** with Reduce Motion or VoiceOver on, no peek and the flag stays unset (it may run later if they are
  turned off). Reason: the peek is only a motion hint; VoiceOver already lists the row's actions.
- **DECISION:** the key is device-wide, not per gateway. Reason: "once per install" on web.
- Debug: `-HQDebugResetPeek YES` clears the key at launch (tests only).

**Wire.** None.

**Acceptance.** `testL5_swipePeek`: fresh install → within 3 s of the list showing, the first row's frame minX has
been < its resting value (sample its frame every 100 ms) and is back at rest by 3 s; relaunch → never moves in 4 s.
With `-UIAccessibilityReduceMotionEnabled YES` (or the debug flag `-HQDebugReduceMotion YES` if the system flag is not
honoured) on a fresh install → never moves and a later normal launch does peek. A tap during the peek opens the chat
normally.

---

## 7. L173 and L174 · Picks that open a chat leave no list or sheet behind

**Web.** `S/ui-bots/bot-row.tsx:354-362`: tapping the hold-menu's preview opens the chat (`openBotFromBots`) and closes
the list. `S/ui-bots/list-close.ts:16-42`: any pick that opens a chat or room closes the Bots list, but only once the
chat that is now open is the one asked for; a room is marked read, opened, then the list closes.

**Native mapping.** There is no "list over the chat" on the phone; the same promise is: after a pick that opens a
chat, the chat is the top page, with no sheet, menu, search or old chat left over it or under it in a surprising
place.

**L173 design.** `BotsViewController` implements
`collectionView(_:willPerformPreviewActionForMenuWith:animator:)`: `animator.preferredCommitStyle = .pop`;
`animator.addCompletion { self.open(id) }` (for a tile or a row; for a group row, the groups stream's open).
The preview itself (`liftedPreview`, `:770`) stays the lifted row; **DECISION:** no chat-transcript preview controller
is built. Reason: web's preview is the row too; a transcript preview would open a session just to peek.

**L174 design.** One entry point, `BotExtras.openChat(bot:from:)` (in `App/Bots/BotExtras.swift`, replacing the
ad-hoc `closeThen` + `botsList()` + `open` chains in `App/BotInfo/BotInfoSheet.swift:171-190`):
1. If the bot's chat is already the top page of the selected tab's stack: dismiss any presented sheet; done (no pop,
   no push; the transcript does not reload).
2. Otherwise: dismiss every presented controller (one `dismiss` on the root's presenter, animated), end search and
   editing on the list, select the Bots tab, `popToRootViewController(animated: false)` if anything is pushed, then
   `open(id)` — a single push animation is all the user sees.
3. The Bots list scroll position and filter are untouched.
Every pick routes through it: Bot Info › Message / a Recent Activity row (opens that session, same rules) / New Chat;
the row menu's New Chat; the hold-menu preview; Search results; a notification tap (already its own path — only
check it leaves no sheet); New Bot's finish; Duplicate's "open the copy".

**Wire.** The chat's own open (`session.resume` / `session.create`); nothing new.

**States.** A pick made while another open is in flight replaces it (the newest pick wins; the older push is
dropped before it lands — `opening` in `BotsViewController.open` becomes "the id being opened", not a Bool lock).

**Acceptance.** `testL6_previewTapOpens`: hold `bot-row-ada` until the menu shows, tap the lifted preview → the chat
titled "Ada" is on screen, the menu is gone, Back returns to the list. `testL7_picksCloseEverything`: from a chat
with `basil`, open Bot Info for… (a) Sessions tab › a session's Bot Info › Message → Bots tab selected, stack is
`[Bots, chat]`, no sheet; (b) Bot Info opened from inside the chat with that same bot › Message → sheet closes, the
same chat stays (the transcript's first row identity unchanged, no flash); (c) Search "ad" › tap result → search bar
gone when coming Back; (d) two fast picks → only the second chat is pushed.

---

## 8. L184 · "Waking up…" on the row

**Web.** `S/ui-bots/bot-row.tsx:198` + `S/status-grace.ts:7,28-39`: once a bot's open has been pending for 1000 ms the row
says "Waking up…" (secondary, small spinner); it clears the moment the open ends, with no minimum time.

**Native design.**
- `BotStore` gains `openingSince: [String: Date]` (bot id → start). `AppModel` sets it when a bot chat's open begins
  (`ChatOpenPhase` leaving idle: resume/create sent) and clears it on bound, failed or cancelled (leaving the chat
  before it binds cancels). This replaces the unkeyed `noteChatOpening(_:)` Bool (`BotStore.swift:262`); keep the Bool's
  one reader working by deriving it.
- `bot.opening = now - openingSince[id] >= 1 s`. A single `Task.sleep(1 s)` per open flips it (no ticking timer).
- The row shows rank 3 of §1.1: "Waking up…" in secondary with a 12 pt `ProgressView` before the words; tiles show the
  same spinner in the status-badge slot and say "Waking up…" in the VoiceOver label.
- Transcript's header line "Waking up…" (L361) belongs to the transcript stream; expose `BotStore.isWaking(id)` for it.

**Wire.** None new.

**Fixture.** §1.2: `/__fixture/open-delay {"name":"ada","ms":4000}`.

**Acceptance.** Unit: 0.9 s open never shows it; 1.1 s shows; clears at once on bind and on failure; attention beats
it only when not opening (§1.1). `testL8_wakingUp`: with a 4 s delay, tap `ada`, go Back at once → inside 2 s the row
reads "Waking up…"; after the open ends it shows its preview again. A 300 ms open never shows it (sample 10×).

---

## 9. L185 · Standing failure in orange

**Web.** A bot with a standing provider problem shows it as the row status, orange, ahead of everything except
link-down and opening (`S/ui-bots/row-status.ts:19-29`). The reason comes from the desktop plugin's `$botAttention`
(`V/plugins/hermes-bots/data.ts:54-166`): classes `provider_auth_or_access`, `provider_quota_limit`,
`missing_config`, `agent_blocked`; transient errors (rate limit, 429, 5xx, overloaded, timeout) are *not* attention.
It is display-only, never saved; the latest failure wins; the bot's next good turn clears it. Web sets it from a
failed relay delivery (`error.data.reason`) and group turns. Words (`i18n.ts:644-648`): "Sign in again for this
profile", "Quota or balance exhausted", "Provider not configured — run hermes model", "Bot is blocked — see its last
message", fallback "Needs attention".

**Native design.** Native runs no relay, so:
- **DECISION:** the source is the bot's own turns: when a turn in a bot's chat ends in an error (the `error` event or
  a failed `prompt.submit`, both already reach `AppModel.gatewayEvent` for off-screen chats and `LiveChatSession` for
  the open one), classify the message with `Attention.reason(from:)` and store it; when a turn for that bot completes
  with a reply, clear it. Reason: it is the only signal the phone has, and it is the same text the desktop classifies.
  When the groups stream sends group turns it calls the same `BotStore.noteTurnFailed(bot:message:reason:)`.
- `HermesKit/Model/Attention.swift` (pure, ported regexes, case-insensitive, checked in this order):
  1. `error.data.reason` if it is one of the four classes → that class.
  2. transient → nil: `rate.?limit|too many requests|\b429\b|\b5\d\d\b|server error|overloaded|timed?.?out|timeout|temporar`
  3. missing_config: `no llm provider|no access token|not configured|no api key|missing api key`
  4. provider_auth_or_access: `\b401\b|\b403\b|unauthorized|forbidden|authentication|invalid.?api.?key|credentials? (are )?(invalid|expired)`
  5. provider_quota_limit: `quota|out of funds|insufficient (credits?|funds|balance)|payment required|\b402\b|billing`
  6. agent_blocked: `\bblocked\b`
  7. else nil.
- Words on the row (orange, `Color.hqOrange`, no spinner):

  | Class | Row text |
  |---|---|
  | provider_auth_or_access | Sign in again for this bot |
  | provider_quota_limit | Quota or balance exhausted |
  | missing_config | Provider not set up |
  | agent_blocked | Bot is blocked — see its last message |

  **DECISION:** "profile" → "bot" and "Provider not configured — run hermes model" → "Provider not set up". Reason:
  memory `owner-runs-no-terminal.md` (the owner cannot run Terminal commands) and the plain-language rule; the chat's
  own error message already says what failed.
- Held in memory only, per account, in `BotStore.attention: [String: String]`; cleared on a good turn, on gateway
  switch, on sign-out, and on relaunch (web never persists it either).
- Tiles: an orange dot in the status-badge slot; VoiceOver label carries the words.
- Tapping the row opens the chat as usual; no extra control is added (nothing that does nothing).

**Wire.** None new. Example event that sets it:
`{"type":"error","session_id":"…","payload":{"message":"HTTP 401: invalid api key"}}`.

**Fixture.** §1.2: `/__fixture/turn-error {"name":"ada","message":"HTTP 401: invalid api key"}`, then send in Ada's chat.

**Acceptance.** Unit: 30 sample messages → expected class (each regex, transient ones nil, `data.reason` wins);
ranking with waking/working/offline. `testL9_attention`: set the error, send "hi" to Ada, go Back → row reads
"Sign in again for this bot" and its text colour is orange (assert via the element's value string
`status=attention` set as `accessibilityValue` in debug builds, plus a screenshot); with message "429 rate limit" the
row shows its normal preview; after a good turn the row is back to the reply preview; relaunch clears it.

---

## 10. L186 · Background work keeps the typing badge

**Web.** `S/ui-bots/work-status.ts`: a bot whose own turn has ended but whose delegated children or background
processes still run keeps "Working…" on the roster. Every `BOT_WORK_POLL_MS = 5_000` while the roster is visible, for
each bot in that "background" state with a bound session, it reads `subagent.list` (when it believed subagents were
active) and `process.list` (when it believed a process was running), 10 s timeout, never two reads for one bot at
once. A method the gateway lacks is marked unsupported until the list is shown again or the socket reconnects. A
failed read proves nothing (state kept). An answer is applied only if nothing changed meanwhile. On Low Power or a
hot phone the interval stretches ×3.

**Owner.** memory `stuck-working-row.md`: a row stuck on "Working…" was a real complaint; the fix reads
`delegation.status` / `agents.list` on socket open, on return to the app and every 30 s while claims exist.

**Native today.** `ActivityStore` polls `subagent.list` only for the chat on screen
(`HermesKit/Activity/ActivityStore.swift:386-409`) and runs the 30 s stale check (`:485-540`);
`AppModel.setWorking` (`App/AppModel.swift:491`) ORs `activityStore.hasLiveWork(profile:)`. Background processes are
tracked nowhere.

> Revision 2: §0A item 10 — the poll lives in `ActivityStore` (which already holds subagent rosters and offline's
> process claims), not in a new class. Read the API below as the behaviour to add there; the wire, error rules,
> cadence and acceptance stand. Unit tests go in the activity test file's style (`scripts/e2e-activity.sh` must stay green).

**Design.** `HermesKit/Activity/BackgroundWork.swift`, `@MainActor @Observable final class BackgroundWork`, owned by
`AppModel`:
```swift
struct Claim: Equatable { var subagents: Int; var processes: Int }   // > 0 means "still working in the background"
private(set) var claims: [String: Claim]                              // by profile
func noteTurnEnded(profile: String, sessionId: String, hadSubagents: Bool, startedProcess: Bool)
func noteEvent(profile: String, _ event: GatewayEvent)   // subagent.spawned/complete, tool.complete name terminal|process, status.update kind process
func setListVisible(_ visible: Bool)
func hasWork(profile: String) -> Bool
```
- A claim starts from events the app already sees (subagent spawn events; `tool.complete` with name `terminal` or
  `process`; `status.update` kind `process` — the triggers web uses, `V/…/gateway-event/tools.ts:122-125`,
  `status.ts:116-119`) and, on socket open, from one `delegation.status` + `agents.list` read (the existing stale
  check; share its answer, do not read twice).
- The poll: every 5 s while the Bots list is the visible page and the app is active (15 s when
  `BotStore.lowPower`, `HermesKit/Store/BotStore.swift:719`); off the list it falls back to the existing 30 s stale
  check. For each claimed profile whose own turn is not running and which has a session bound on this socket:
  `subagent.list` if `subagents > 0`, `process.list` if `processes > 0`. One in-flight read per profile; 10 s timeout.
- Applying: running subagents = rows whose `status` is not a finished one (`completed`, `failed`, `cancelled`,
  `interrupted`); running processes = rows with `status == "running"`. Both zero → the claim is dropped and
  `setWorking(profile, false)` is re-evaluated. Applied only if the claim's generation is unchanged since the request
  went out.
- Error 4001 (session not bound here) or no bound session: do not poll that bot from the list; its claim then lives
  and dies by the 30 s `delegation.status` / `agents.list` check (a profile absent from `active` and from
  `processes` is dropped). -32601 / "method not found" / 4000 "unknown": mark that method unsupported until the list
  next appears or the socket reconnects. Timeouts and transport errors: keep the claim, try next tick.
- A claim never outlives: sign-out, gateway switch, the bot's deletion, or a new turn starting (the turn takes over).
- `AppModel.setWorking` ORs `backgroundWork.hasWork(profile:)`; the row shows rank 7 "Working…" and the tile its
  typing badge. The words do not change ("Working…"), as on web.
- The composer stream's background-task capsule (L461) reads `BackgroundWork.claims`; do not build its UI here.

**Wire.**
```json
{"method":"subagent.list","params":{"session_id":"rt_9f2…"}}
→ {"subagents":[{"subagent_id":"sa1","parent_id":null,"depth":1,"goal":"Check the logs","status":"running","tool_count":3,"last_tool":"terminal","accepting_steer":true}],"delegations":[]}
{"method":"process.list","params":{"session_id":"rt_9f2…"}}
→ {"processes":[{"session_id":"proc_1","command":"npm run build","status":"running","exit_code":null}]}
{"method":"delegation.status","params":{}}          // no session_id: the contract forbids it (C/billing_delegation_pets.py:361-384)
→ {"active":[],"paused":false,"max_spawn_depth":2,"max_concurrent_children":3}
{"method":"agents.list","params":{}}  → {"processes":[]}
```
Never send `profile` together with an unknown key; never add keys (4000).

**Fixture.** §1.2 on 10040: `/__fixture/subagents`, `/__fixture/procs`, `/__fixture/silent-finish`, `/__fixture/no-method`.
(`scripts/fixtures/activity-gateway.py` already has `/__fixture/subagents` for the in-chat case and stays the fixture
for the activity suite.)

**Acceptance.** Unit (`Tests/BackgroundWorkTests.swift`, fake clock and client): claim → polls at 5 s; ×3 on low
power; no poll when the list is hidden; one in-flight read; a failed read keeps the claim; an answer after a newer
event is ignored; unsupported method is not called again until `setListVisible(true)`; 4001 stops list polling for
that bot. `testL10_backgroundWork`: Ada's turn spawns a subagent and ends (`silent-finish`), leave the chat → the row
keeps "Working…" for 20 s (sample); `/__fixture/subagents {"name":"ada","rows":[]}` → within 8 s the row shows the
reply preview; the same with a running process; `/__fixture/state` shows ≤ 1 `subagent.list` per 5 s.

---

## 11. L189 · "Not Delivered:" ahead of "Draft:"

**Web.** `S/ui-lists/row-pending.ts:15-21`: the first queued message whose delivery is unconfirmed and which is not
hidden makes the row's idle line `Not Delivered: <its text>` (the prefix in red); otherwise a draft makes it
`Draft: <text>`. `S/ui-bots/bot-row.tsx:207-213`.

**Owner.** memory `send-lost-on-leave.md`: the owner twice reported a message that never sent after leaving the chat;
the chat shows "Delivery Unconfirmed · Check" for it.

**Native today.** `LiveChatSession.markUnconfirmed` (`HermesKit/Chat/LiveChatSession.swift:994-1000`) sets
`ChatMessage.error = "Delivery unconfirmed"` on the message; the list knows nothing about it. Drafts reach the row
through `BotStore.draftWords` (`BotStore.swift:120-125`, set at `App/AppModel.swift:253`) as `bot.previewPrefix`.

> Revision 2: §0A item 3 replaces the first bullet (the store exists as `LostSends`; nothing new is persisted). The
> row rule, wording, VoiceOver label and acceptance below stand.

**Design.**
- `HermesKit/Chat/UnconfirmedSends.swift`: a small store keyed by account id + stored session id →
  `[{localId, text, at}]`, persisted beside `QueueStash` (same folder, same purge on sign-out —
  `App/AppModel.swift:202, 386`), so the line survives leaving the chat and a relaunch.
  - Added in `markUnconfirmed`. Text: the message's display text; an attachment-only send uses "Attachment"; a voice
    memo "Voice Memo".
  - Removed when: "Check" finds it delivered (`ChatDeliveryChecking`), Send Again or Delete is picked
    (`ChatActionsModel`), or the transcript loaded from the gateway contains that message (match by the same rule the
    Check uses).
- `BotStore.notDeliveredWords: (Bot) -> String?` (like `draftWords`) reads the first entry for the bot's canonical
  session. `RowStatus` idle rank: `notDelivered` → prefix "Not Delivered:" in `Color(.systemRed)`, then the text in
  secondary, one line; else draft → prefix "Draft:" as today.
- Only the Bot Chat (canonical session) drives a bot's row; a side session's unconfirmed send belongs to the Sessions
  row (L264, sessions stream — they call the same store by session id).
- VoiceOver: "Ada, Not Delivered: see you at nine".
- Tiles show no text; no change there.

**Wire.** None new.

**Fixture.** §1.2: `/__fixture/drop-send {"name":"ada"}` (socket closes after `prompt.submit` is read).

**Acceptance.** Unit: precedence (not-delivered over draft; hidden kind skipped); removal on each of the three paths;
survives encode/decode. `testL11_notDelivered`: type a draft in Ada's chat, go Back → "Draft: …"; open, arm
`drop-send`, send "see you at nine", go Back → row reads "Not Delivered: see you at nine"; kill and relaunch → still
so; open the chat, tap "Delivery Unconfirmed · Check" (fixture then reports it stored) → Back → the row shows the
normal preview.

---

## 12. L210 · Recent Activity in the empty Bot Chat

**Web.** `S/ui-bots/bot-intro.tsx:33` shows `<BotRecentActivity limit={3}>` under the intro of an empty Bot Chat.
`S/bot-recent.ts`: path (`:12-13`) `GET /api/profiles/sessions?limit=7&offset=0&min_messages=1&archived=exclude&order=recent&profile=<name>`
(limit is 5 + 2 on web); rows (`:21-32`) drop background runs — sources `tool`, `oneshot`, `subagent`, `kanban`
(`S/session-runs.ts:17-22`) — and other profiles' rows, keep cron runs, join the roster's last session, drop the Bot
Chat itself, sort newest first; a read is fresh for 30 s (`:35-40`); a failed read keeps what was shown. UI
(`S/bot-recent-activity.tsx`): heading "Recent Activity"; each row a title (`session title || preview ||
"Untitled Chat"`, a cron run's time stamp stripped) and a meta line `source · time`. Opening one makes a "side chat"
whose Back names the bot (`:54-92`).

**Native today.** `BotStore.recentChats(name:limit:)` does the read and the filtering (limit 3 → `limit=5` on the
wire); Bot Info lists them (`App/BotInfo/BotInfoSheet.swift:153-190, 445`). The empty chat
(`App/Chat/ChatPlaceholderView.swift`, mode `.empty`) shows only head, name and a line.

**Design.**
- `ChatPlaceholderView.Mode.empty` gains `recent: [SessionSummary]`; under the intro (and under the Talk / Bot Info
  capsules when the talk stream adds them, L209 — leave a stack slot above the list) it shows:
  - a section label "Recent Activity" (footnote, secondary, uppercase off, leading-aligned to the card);
  - up to **3** rows in one inset grouped card (continuous 20 pt corners, `secondarySystemGroupedBackground`; this is
    content, not a bar, so no glass): title one line (body), meta one line (footnote, secondary)
    `"<source label> · <list time>"` using the Sessions list's existing source labels and time formatter; a chevron;
    12 pt vertical padding (memory `row-padding-feedback.md`: wrapping cells 12–14 pt);
  - nothing at all (no heading) when there are no rows, while the first read is out, or when the read fails with
    nothing cached. No spinner, no error line: the intro stands alone, as on web.
- Only for a bot's Bot Chat (`menus.isBotChat`), never for a session opened from Sessions, a room, or a brand-new side
  chat.
- Loading: `LiveChatSession`'s host (`ChatViewController`) asks `services.botEditing?.recentChats(bot)` when the
  placeholder enters `.empty`; `BotStore` keeps the last answer per bot with its time and serves it if younger than
  30 s (shared with Bot Info, which then shows instantly). Request timeout 30 s. The list is dropped when the first
  message is sent (the placeholder goes away).
- Tap: pushes that session on the same stack through `BotExtras.openChat`'s session variant; its Back button reads the
  bot's name (pushed from the bot's chat, so it does by construction). The empty Bot Chat stays underneath.
- The whole placeholder scrolls if intro + list exceed the space above the composer (accessibility sizes, keyboard up).
- VoiceOver: heading trait on "Recent Activity"; each row one element: "<title>, <source>, <time>", trait button.
- **DECISION:** 3 rows (the intro's `limit={3}`), and the wire limit stays the store's `limit + 2`. Reason: web.

**Wire.** `GET /api/profiles/sessions?limit=5&offset=0&min_messages=1&archived=exclude&order=recent&profile=ada`
→ `{"sessions":[{"id":"s_1","profile":"ada","title":"Trip plan","preview":"…","source":"app","last_active":1791000000,"message_count":12}, …]}`

**Fixture.** §1.2 on 10040 (seeded table; `/__fixture/recent` to change it; `hermes` has an empty Bot Chat and six
person chats).

**Acceptance.** Unit: existing `recentRows` tests plus the 30 s cache. `testL12_recentActivity`: open a bot with an
empty Bot Chat → "Recent Activity" with exactly 3 rows, newest first, none titled like the seeded `tool`/`subagent`/
`kanban`/`oneshot` rows, the cron run present when it is among the newest three; tap row 1 → that session opens, Back
reads the bot's name; `/__fixture/recent {"name":"ada","rows":[]}` and reopen after 30 s → no heading. With the
endpoint failing (latency `fail_every: 1`) → intro only, no error.

---

## 13. L213 · Bot Info header and About

**Web.** `S/ui-bots/info-sheet.tsx:142-155`: a 96 pt head with a status badge, the name, the role, and a status line
with a tone dot — "Active now", "Active N min ago", "Active N h ago", "Active yesterday", "Active N days ago", or the
live status ("Working…", "Waiting for your approval", "Offline", "Waking up…", attention words), plus " · Watch" when it
is using its computer. About (`S/ui-bots/info-state.ts`, `info-sheet.tsx:157-166`): the description, four lines; when
longer than 180 characters or more lines than fit, a "More" / "Less" toggle; a "Handle" row `@<handle>`. The sheet
closes if the bot is deleted (`:245`); a spinner while the roster is empty (`:247`).

**Native today.** `App/BotInfo/BotInfoSheet.swift`: an 80 pt head, name, role, tiles; no status line or badge; About
shows "more" only past 160 characters, with no way back; Handle row exists.

**Design (changes only).**
- Head 96 pt with the list's status badge (working dots / orange dot / none) at its lower trailing corner.
- Status line under the role, footnote: an 8 pt dot + text from `RowStatus.infoStatus(bot)`:
  live statuses use §1.1's words and tones; idle uses `lastActive`: < 60 s "Active now"; < 60 min "Active N min ago";
  < 24 h "Active N h ago"; yesterday "Active yesterday"; else "Active N days ago"; never active: no line.
  Dot colours: tint (working/computer), orange (attention/waiting), secondary (idle/offline). Updates live (the model
  already observes `editing.bot(id:)`).
  " · Watch" is the browser stream's to add (expose a trailing slot; do not show a dead word).
- About: the description in a text cell, `lineLimit(4)` collapsed. A "More" button shows when the text is truncated —
  measured, not guessed: `ViewThatFits`/a hidden full-height measure against the 4-line height (covers both the
  180-character and the many-newlines cases at any text size). Expanded shows all of it and the button reads "Less".
  Button: tint, footnote, trailing, 44 pt hit height. VoiceOver reads the whole description on the cell whatever the
  state; the button's label is "More" / "Less", hint "Shows the whole description." No About group when the
  description is empty.
- Handle row: title "Handle", value `@<profile name>`, hold → Copy (existing).
- The role line is shown only when the title differs from the name (web intro rule).
- Bot deleted while the sheet is open → the sheet dismisses (check it does; add if not). Roster not in yet → a centred
  `ProgressView` (no words).
- Row padding 12–14 pt vertical for wrapping cells.

**Wire.** None new (roster + `profiles.describe` for the description when the roster has none, as today).

**Fixture.** §1.2 (`ada` has a 400-character, 6-line description; `basil` a 40-character one; `cleo` none).

**Acceptance.** `testL13_infoHeader`: Ada's Bot Info shows name, role, a status line "Active …"; start a turn → the
line reads "Working…" within 3 s; About shows "More"; tap → full text and "Less"; tap → four lines again. Basil: no
"More". Cleo: no About title, Handle still there. At AX5 nothing clips; the header scrolls with the page.

---

## 14. L215 · Bot Info Model group, and the instructions editor

**Web.** `S/ui-bots/info-state.ts`: rows "Model" and "Provider" (values, "Loading…" while reading, "Not Available" on
failure), and a row "Skills & Instructions" with a chevron (disabled offline). That row opens Edit Bot's advanced
part (`S/ui-bots/info-actions.ts:136`), where the desktop's editor (`V/…/edit-profile-dialog.tsx`,
`profile-config.tsx`) reads `profiles.describe {name}` and saves `profiles.configure {name, soul}` only when the text
changed (`applyAdvancedConfig`, `:546-600`). Before saving, the desktop appends a "## Messaging other agents" section
unless the gateway injects it itself (`profiles.list` → `bot_mode_protocol`) or it is already there (`soul.ts:79-92`).

**Native today.** `BotInfoModelSection` (`App/BotInfo/BotInfoSheet.swift:479`): Model, Provider, and a "Skills" row that
pushes Capabilities for the bot. No instructions editor.

**Tester batch 3 (2026-10-25): each bot's own Default Model.** ("I can't find a way to change the default model for a
profile other than default. Changing the model in Settings only changes it for default.") The group's first row is now
**Default Model** (`bot-info.default-model`, the roster's model name, "Switching…" while a pick is saved, "Not Set" when
the roster has none; dimmed offline). It pushes the Settings model chooser inside the sheet on that bot's own catalog
(`GET /api/model/options?profile=<bot>`), with the note "Applies to <bot> only. A chat can still switch its own model."
(the default bot: "Applies to <bot> only, the same as Settings › Model. …"; see the scope lines below). A pick pops
back and saves `POST /api/model/set?profile=<bot>` (scope main, the call Settings › Model › Main Model makes for the
default profile, scoped the way the desktop app scopes it). Every Hermes with `profiles.list` takes `?profile=` there
and answers 404 for an unknown profile, so the write can't land on another bot. The chooser reads that catalog after it
opens: "Loading…" until it comes, and a read that fails shows
"Couldn’t Load Models" with the reason and Try Again (`settings.load-retry`) in place of an empty Provider picker. An
expensive model asks first ("Use <model>?" · Use It); a refused or failed write says why with Try Again. On a read-only
gateway the row stays as it is (as Bot Info's pin, hide and move do) and a tap says "Couldn’t Change <bot>’s Model" with
the read-only reason before any chooser opens; Bot Profiles shows the model as a fact there. The row takes the new model
at once and a roster read sent before the write settled can't put the old one back (`BotStore.setDefaultModel`,
`keepModelWrites`). More › Bot Profiles' detail has the same row (`profiles.detail.model`). Settings › Model now names
whose models it changes ("Hermes’s Default Model", footer "Applies to Hermes only. Other bots keep their own in Bot Info
› Brain. A chat can still switch its own model."). Tests: `Tests/Settings/BotDefaultModelTests.swift`,
`testG10_BotInfoChangesThatBotsOwnDefaultModel` (a failed catalog read, Try Again, then the picks) and
`testS32_ReadOnlyRefusesEveryWrite` (scripts/e2e-settings.sh).

**Scope lines ([model-scope], owner 2026-11-03, menu review #2 "A bot's model").** Wherever a model is picked, a short
line says what the pick applies to (`SettingsWords` "Model scope", `ModelPanelModel.switchScope`, `JobWords.modelScope`):
- Bot Info › Brain's model group footer (`bot-info.model-scope`) and More › Bot Profiles' detail footer
  (`profiles.detail.model-scope`), and the bot's Default Model chooser note: "Applies to <bot> only. A chat can still
  switch its own model." For the default bot: "Applies to <bot> only, the same as Settings › Model. A chat can still
  switch its own model." (it is the very setting Main Model changes).
- A bot's own Fallback Models / Auxiliary Models pages and their choosers: the page's footer, then "Applies to <bot>
  only." Settings' own (the default bot's, also what the default bot's Brain rows open): "Applies to <default bot> only.",
  plus "Other bots keep their own in Bot Info › Brain." when the roster has more.
- Settings › Model › Main Model: footer and chooser note "Applies to <default bot> only. [Other bots keep their own in
  Bot Info › Brain.] A chat can still switch its own model."; Defaults (Reasoning Effort, Fast Mode) footer ends
  "Applies to <default bot> only. A chat can still change its own." Mixture of Agents' footer and slot choosers:
  "Applies to <default bot> only." (the default profile's `/api/model/moa`; no other bot has the page).
- Settings › Providers › a custom provider: "New chats with <default bot> use this provider’s default model." / Make
  Default's footer "Makes <model> from <provider> the default model. Applies to <default bot> only. A chat can still
  switch its own model." (`…/activate` writes the default profile).
- A bot's Capabilities › a tool's Model (image and video tools): footer "Applies to <bot> only." Vision's
  "Choose Vision Model" opens that bot's own Auxiliary Models (it opened the default bot's for every bot).
- The chat: Switch Model's menu title (none at the accessibility text sizes, where it filled the menu ahead of the
  picks), the Models sheet and the Mac's Models pop-over: "Applies to this chat only.
  Change <bot>’s default in Bot Info › Brain." (no Bot Info for the chat: the first sentence alone). A chat's switch is
  `config.set model` on its session, which Hermes keeps to that chat unless its config sets
  `model.persist_switch_by_default` (or no default model is set yet); the app never asks it to save.
- Jobs › a job's Model row: footer "Applies to this job only. Default uses <bot>’s own model."
Tests: `BotDefaultModelTests` (the words), `ModelPanelTests.aChatsSwitchSaysWhatItAppliesTo`, settings G4, G5, G10,
G11 and CP1, menus test02, jobs JE06, capabilities C14.

**Design.**
- Model group rows: **Model**, **Provider** (provider shown by its display name), then two rows, each a real
  destination:
  - **Skills** → Capabilities for this bot (existing).
  - **Instructions** → a new page inside the same sheet (memory `sheet-pages.md`: the owner wants no "a pop up on top
    of a pop up"; pages push inside Bot Info's one sheet).
  **DECISION:** two rows instead of web's one "Skills & Instructions". Reason: native has two destinations; one row
  that opens a chooser would be an extra tap, and a combined label that opens only one would mislead.
- Values: "Loading…" (secondary) until `profiles.describe` or the roster gives one; "Not Available" on failure.
  Offline: both destination rows are dimmed and not tappable, footer "Connect to change these."
- `App/BotInfo/BotInstructionsController.swift` (small title "Instructions", `PushedPageTitles`):
  - Loads `profiles.describe {name}` on appear. States: a centred `ProgressView`; failure → "Couldn’t load this bot’s
    instructions." with a "Try Again" button; loaded → a full-height `UITextView` (body, Dynamic Type, monospaced off),
    footer under it: "What this bot is told about who it is and how to work. Changes apply to its next chat."
  - Bar: leading system Back; trailing **Save** (prominent glass, disabled until the text differs from what was
    loaded; a spinner replaces it while saving).
  - Back with unsaved edits → action sheet "Discard Changes?" · "Discard Changes" (destructive) · "Keep Editing".
    Interactive pop and sheet swipe-down are blocked while dirty (`isModalInPresentation = true`).
  - Save → `profiles.configure {name, soul}`. Success (`applied.soul` truthy) → pop, haptic success. `applied.soul`
    missing or `ok: false` or an error → stay, alert "Couldn’t Save" / "Your changes are still here. Try again."
    · OK. Read-only gateway → the text view is not editable, no Save, footer "This gateway is read-only."
  - Older gateway (`profiles.describe` answers method-not-found / 4000) → the Instructions row is not shown at all
    (never a control that does nothing); probe once per account when Bot Info opens, cache the answer.
  - Never sends `soul` unless the text changed; sends nothing else in that call.
  - **DECISION:** the phone never appends the "Messaging other agents" section. When `profiles.list` says
    `bot_mode_protocol` is true (the contract's default) the gateway injects it; when it is false the phone saves the
    text exactly as typed. Reason: that block is desktop-plugin text for a relay the phone does not run; writing a
    copy from the phone could drift from the desktop's.
  - The words "SOUL.md" never appear; the row and page say "Instructions".
  - Keyboard: the text view avoids it (`keyboardLayoutGuide`); a 20 000-character text scrolls smoothly (plain
    `UITextView`, no attributed re-layout per key).

**Wire.**
```json
{"method":"profiles.describe","params":{"name":"ada"}}
→ {"name":"ada","description":"…","soul":"You are Ada…","model":{"provider":"anthropic","default":"claude-sonnet-4-5"},"skills":[…],"toolsets":[…],"toolsets_pinned":false,"mcp_servers":[…]}
{"method":"profiles.configure","params":{"name":"ada","soul":"You are Ada, and you answer briefly."}}
→ {"ok":true,"applied":{"soul":true}}
```
(`C/profiles_vault_complete_foreign_subagents.py:171-313`.) `name` and `profile` are both accepted; send `name` only.

**Fixture.** §1.2 on 10040 (`describe`/`configure` with `soul`; `/__fixture/configure-fail`; `/__fixture/no-method
{"methods":["profiles.describe"]}`; `/__fixture/latency`).

**Acceptance.** `testL14_modelGroup`: Model and Provider show the fixture's values; "Skills" opens Capabilities;
"Instructions" opens the page with the seeded text; Save is disabled; type " Be brief." → Save enabled → tap →
page pops and `/__fixture/state` has one `profiles.configure` whose params are exactly `{name, soul}`; reopen → the
new text. With `configure-fail` → the alert, text kept. Back while dirty → the discard sheet. With `no-method` → no
Instructions row. Offline → both rows dimmed.

---

## 15. L227 · Edit Bot / Add to Group / New Section when the Bots page was never built

**Web.** `S/ui-bots/pane-fallback.tsx`, `pane-actions.ts`: the Bots page is built only when first shown; a fallback
mounted beside the tab bar serves Edit Bot, Add to Group and New Section for any bot the roster knows.

**Native mapping.** The Bots tab's controller exists from launch and its view is loaded
(`MainTabController.swift:103`), but several paths still assume the *list has drawn*:
`BotsViewController.open(_:)` (`:548`) needs `botsByID[id]`, filled only by `reload`; `BotExtras` reaches the organizer
through `(host as? BotsViewController)?.organizer` (`App/Bots/BotExtras.swift:83`); a launch that restores straight
into a chat, or lands on Sessions or More, can ask for these before the first roster apply.

**Design.**
- `BotsOrganizer` is created in `BotsViewController.init` (not `viewDidLoad`) and takes its presenter per call
  (`from:`), so Edit Bot, Move to Section › New Section…, and (groups stream) Add to Group work from any tab, any
  sheet, at any time. `BotExtras` gets it from `MainTabController.botsViewController.organizer` — never nil.
- `open(_:)` looks the bot up in `BotStore` (`botEditing.bot(id:)`), not in the list's snapshot cache. If the roster
  is not in yet, the pick waits for the first roster apply (up to 10 s, then drops silently — the chat cannot open
  without a bot) instead of returning at once.
- Edit Bot opened for a bot the roster does not have yet: the page shows a centred `ProgressView` until it arrives;
  New Section's alert needs no roster.
- "Add to Group" itself is the groups stream's page; this stream only guarantees the entry (`BotMenuHooks`) fires with
  a non-nil organizer and presenter. Say so in the report.

**Wire.** As the existing actions (`profiles.configure` for edit and section moves).

**Fixture.** §1.2 on 10040 with `/__fixture/latency {"ms":2500}` (a slow first roster).

**Acceptance.** `testL15_noBotsPage`: launch with `-HQDebugStartTab sessions` (new debug argument: selects that tab
before first appearance) → open a session's chat → its header › Bot Info → Edit Bot → the page opens, rename, Save →
one write. Bot Info › Section › New Section… → the name alert → the section exists when the Bots tab is first shown.
Launch restored into a chat (kill inside a chat, relaunch) with 2.5 s latency: Bot Info › Message within the first
second → the chat opens once the roster lands. In none of these was the Bots tab selected beforehand.

---

## 16. L237 · Undo pill rules

**Web.** `S/ui-kit/undo-pill.tsx`, `feedback.ts:18`: shown 4 s, 8 s at accessibility text sizes; the clock stops while a
finger is on it or VoiceOver focus is in it; while another accessory covers its layer (the "away" pill, priority 10)
it is held — not shown and its clock not running — and appears when that one goes; label for VoiceOver
`"<label>. <way back> Undo"`, announced once `"<label>. <way back>"`; a new pill replaces the one showing.

**Native today.** `App/Kit/UndoPill.swift`: 4 s / ≥ 8 s, hold by long-press recogniser, VoiceOver focus observer,
announcement, replace-on-show. No yielding.

> Revision 2: §0A item 7 replaces the arbiter, the stand-in and the last DECISION below: the real `TalkAwayPill` is on
> the train. The pending / fade / resume rules and the unit tests stand; `testL16_undoPill` uses the real pill.

**Design.**
- `App/Kit/BottomAccessoryArbiter.swift`:
  ```swift
  @MainActor enum BottomAccessory { static var isAwayPillShowing: () -> Bool = { false }
                                    static let changed = Notification.Name("hq.bottomAccessory.changed") }
  ```
  The talk stream sets `isAwayPillShowing` and posts `changed` when its pill shows or hides (its brief says it will
  "expose a way to ask whether it is showing"; this is the hook to fill).
- `UndoPill.show`: if `isAwayPillShowing()` → keep the pill pending: not in the view tree, clock not started; on
  `changed` with the away pill gone → present and start the full duration. If the away pill appears while the Undo
  pill is up → fade it out, keep the remaining time, show again when the away pill goes. A pending pill whose host
  left the screen is dropped (its change stands; the way back named in the label still exists).
- Check and fix against the web rules: the clock pauses on touch-down (not after a long-press delay — use a
  zero-duration press recogniser), resumes with the remaining time (not a restart); pauses while VoiceOver focus is on
  the pill or its Undo button; the duration is chosen from `preferredContentSizeCategory.isAccessibilityCategory` at
  show time; the pill grows to two lines at accessibility sizes; the Undo button's label is
  `"<label>. <way back> Undo"`; the announcement posts once.
- **DECISION:** until talk merges, the closure stays `{ false }` and a debug argument `-HQDebugAwayPill YES` installs a
  plain stand-in view above the tab bar with a debug toggle, used only by the test below. Reason: planner note —
  "build the priority rule against a hook and say so in the report." The row is ticked for the rule; the real pairing
  is re-checked when talk lands.

**Wire.** None.

**Acceptance.** Unit (`Tests/UndoPillTests.swift`, injected clock): 4 s vs 8 s; pause/resume keeps the remainder;
pending while away is showing; replaced by a newer pill; dropped when the host goes. `testL16_undoPill`: hide a bot →
the pill "Hidden" is there at 3 s and gone by 5.5 s; at AX3, there at 7 s; press and hold it for 6 s → still there,
gone ~4 s after release; with `-HQDebugAwayPill YES` and the stand-in on, hide a bot → no Undo pill; turn the
stand-in off → the pill appears and lasts its full time; Undo restores the bot.

---

## 17. L240 (+ L196's Gateway part) · Bots from several gateways

**Web.** `S/ui-bots/filter-token.ts`, `roster-filters.ts`: with more than one gateway the Filter menu has Gateway › "All
Gateways" plus each gateway; the list can show every gateway's bots at once, a row from another gateway carrying that
gateway's face; the filter token joins kind · activity · gateway name; Clear Filters resets all three.

**Owner.** memory `gateway-switcher.md`: the owner picked "A + unread dots" (the title switcher, one gateway in use at
a time) and rejected B, "all at once, big"; "a switch must land on the page it was made from"; push comes only from
the gateway in use.

**Native today.** `BotsViewController.filterMenu()` (`App/Bots/BotsViewController.swift:635-663`): Gateway › lists the
gateways and picking one *switches the gateway in use*. No "All Gateways". The parity note for this row already
records that reading: "native: Filter › Gateway switches the gateway in use; the list shows one gateway's bots at a
time".

**DECISION:** keep one gateway's bots at a time, and do **not** add "All Gateways". Reasons: (1) the owner chose the
one-at-a-time design over "all at once" by name; (2) the app holds one live connection — the gateway in use — so
rows from another gateway could show no live status, unread or typing and could not be opened without a switch; a
merged list would be rows that half work; (3) a menu item "All Gateways" that changes nothing is a control that does
nothing. This row and L196's Gateway part are closed as "native equivalent", with the polish below. If the owner
later wants the merged list it is a new feature (multi-socket roster), not a leftover.

**[filters-only] Owner 2026-11-03: filter menus hold filters only.** Filter › Switch Gateway is gone: the title's
switcher (the same gateway items, plus Add Gateway… and Manage Gateways…; the folded rail's on the Mac) is the one
place to switch. Filter is on the bar always, so Sort By › Manual is there with one bot on one gateway. The Switch
Gateway lines in the design below are history; `testL17_SwitcherLabelAndGatewaySwitch` switches from the title and
`testL19_FilterIsThereWithOneBot` covers the short list.

**Design (the polish that makes the equivalent complete).**
- Filter › Switch Gateway › (shown only with more than one gateway, in a group of its own after Show Hidden Bots and
  Clear Filters: it switches, it does not filter): each gateway by its title, a checkmark on the one in
  use, **its face beside the title** (the gateway's default bot head, 24 pt, as the title switcher's menu draws it),
  and the unread count as the item's subtitle ("3 New", "9+ New") when it has news. Symbol on the submenu: `display`.
- Picking another gateway runs the same switch as the title switcher and stays on the Bots page ("a switch must land
  on the page it was made from"). While switching, the submenu's items are disabled.
- The filter token under the search field shows only kind · activity (the gateway in use is already named in the
  title's subtitle); `filtersActive` does not count the gateway; "Clear Filters" resets kind and activity only and
  never switches gateway. Activity and kind filters persist per gateway across a switch.
- "A row from another gateway takes that gateway's face": not applicable to a one-gateway list; the face appears in
  the Gateway menu items instead (above).

**Wire.** The switch's own sign-in/roster calls (spec `1x-settings.md` §4.6); nothing new.

**Fixture.** The two §1.2 start lines (10040 and 10041 `--label Beta`).

**Acceptance.** `testL17_gatewayFilter`: with A and B signed in, Filter › Gateway lists both titles, A checked, no item
named "All Gateways"; make a Beta bot unread → Beta's item subtitle "1 New"; pick Beta → still on Bots, title
subtitle names Beta, rows are Beta's (names prefixed "Beta"), the activity filter chosen before is still on. With one
gateway: no Gateway submenu. Clear Filters with a filter on → filter off, gateway unchanged.

---

## 18. Order of work, and file map

One feature per commit (memory `feedback-one-feature-at-a-time.md`). Suggested order — shared pieces first:

1. Fixture `scripts/fixtures/botslist-gateway.py` + `scripts/e2e-botslist.sh` + empty UI test file.
2. `RowStatus` (§1.1) with the existing behaviour only, tests.
3. L184 waking · L185 attention · L189 not delivered · L186 background work (each adds one rank's source).
4. L147 pinned reconcile.
5. L174/L173 one open path · L227 organizer lifetime.
6. L210 recent activity · L213 header/About · L215 Instructions.
7. L237 undo pill · L161 peek · L128 label · L240 gateway menu · L152 / L154 verification.

Revision 2: the order to follow is §0B's (closest first); the list above is kept as the dependency order when two
rows touch the same code.

New files (revision 2): `HermesKit/Model/Attention.swift`, `HermesKit/Store/BotStore+PinnedReconcile.swift`,
`App/Kit/SwipePeek.swift` (lifted from Sessions), `App/BotInfo/BotInstructionsController.swift`,
`scripts/fixtures/botslist-gateway.py`, `scripts/e2e-botslist.sh`, `UITests/botslist/`, tests named above. Not
created after all (§0A): `RowStatus.swift`, `BackgroundWork.swift`, `UnconfirmedSends.swift`,
`BottomAccessoryArbiter.swift`. Both
`project.yml` and `project-original.yml` pick sources up by folder; run `xcodegen generate` for each and build both.
Touched files other streams also touch (keep edits small, rebase often): `App/Bots/BotsViewController.swift` (groups),
`App/AppModel.swift` (everyone), `App/Chat/ChatPlaceholderView.swift` (talk), `App/Kit/UndoPill.swift` (talk),
`App/Gateways/GatewayTitleSwitcher.swift` (a11y).

Rules that apply to every row: native Liquid Glass only (system bars, `.glassEffect`, `UIButton.Configuration.glass()`);
no fake glass; tab roots keep the inline large title, pushed pages a small title; original robot heads; the word
"Dispatch" appears nowhere user-facing (the new `UserDefaults` keys start `hq.`); no private API; Swift 6, default
MainActor; a row is done only when it is built **and** seen working on `HQN-m9-botslist` against the fixture.

---

## 19. STRESS PLAN

Stress tester: simulator `HQN-m9-botslist-s`, fixtures on **10045** (A) and **10046** (B):

```sh
python3 scripts/fixtures/botslist-gateway.py --port 10045 --hermes-cookies --credentials build/fixtures/botslist-sa.json > build/fixtures/botslist-sa.log 2>&1 &
python3 scripts/fixtures/botslist-gateway.py --port 10046 --label Beta --credentials build/fixtures/botslist-sb.json > build/fixtures/botslist-sb.log 2>&1 &
HQN_BOTSLIST_PORTS="10045 10046" HQN_DD=build/dd-botslist-s scripts/e2e-botslist.sh <HQN-m9-botslist-s UDID>
```

Record for each item: pass/fail, a screenshot or a number, and the build's commit.

**Added in revision 2 (the merged features this stream now sits beside)**
- Talk running: the away pill up while hiding, deleting a section, deleting a room notice — the Undo pill waits, then
  shows for its full time; end the conversation from the pill while an Undo pill is pending; 20 quick hide / unhide
  taps with the away pill flickering (pause / resume Talk) → never two pills, never a lost Undo.
- iPad two panes (`HQN-m9-botslist-pad`, created and shut down for this run only): L173, L174, L227 picks land in the
  detail pane, the list pane keeps its scroll position; rotate and resize the window (split view, Stage Manager sizes)
  mid-pick, mid-drag and with the Instructions page dirty.
- Both peeks: fresh install, open Bots then Sessions → each list peeks once, never again; the Sessions suite's peek
  test passes after the lift.
- Photo heads: the 96 pt Bot Info head and the Gateway menu's face with a photo head, a robot head, and a photo that
  fails to load (falls back to the robot, no blank circle).
- Group chats in the list (`Show › Group Chats`): row statuses and "Not Delivered:" never leak onto a room row; a room
  pick during a bot pick → the newer one wins.
- Offline's launch screen and 3 s reconnect share: kill the fixture, relaunch into the offline screen, restart the
  fixture → "Waking up…", attention and the pinned reconcile all start clean; no reconcile write goes out while the
  link is down or read-only.
- Regression suites that must stay green on this stream's ports after each row (run before a row is called done):
  `scripts/e2e-settings.sh`, `scripts/e2e-sessions.sh`, `scripts/e2e-groups.sh`, `scripts/e2e-talk.sh`,
  `scripts/e2e-presence.sh`, `scripts/e2e-activity.sh`, `scripts/e2e-a11y.sh` (each takes its ports from its own
  environment variable — read the script's header; give it ports from 10040–10049 only, and your own simulator UDID).

**Load**
- `/__fixture/roster {"bots":500}` with 12 sections and 30 pinned: list appears < 1 s after the roster lands; scroll
  end to end with no hitch > 2 dropped frames (Instruments or `CADisplayLink` debug counter); memory steady.
- 100 bots all with background claims: `/__fixture/state` shows at most one read per bot per 5 s, and the app's main
  thread stays responsive (tap-to-push < 150 ms).
- Desktop-pin 50 bots at once (`/__fixture/meta` ×50): exactly 50 reconcile writes, none repeated; the list settles.
- 40 unconfirmed sends across 40 bots: all rows show "Not Delivered:"; relaunch < 1.5 s to first list.
- Instructions text of 200 000 characters: opens, scrolls, saves.

**Speed**
- Roster apply with `RowStatus` for 500 bots < 8 ms (unit perf test).
- "Waking up…" appears between 1.0 and 1.3 s after an open starts; clears < 100 ms after it ends.
- Preview tap → chat pushed < 400 ms; Bot Info › Message from another tab → one push animation, < 600 ms.
- Recent Activity: cached answer shows with the intro in the same frame; uncached adds no layout jump above it.

**Bad network**
- `/__fixture/latency {"ms":3000,"jitter":2000,"fail_every":3}` for the whole e2e suite: no stuck spinner, no stuck
  "Working…" or "Waking up…", no duplicate writes (compare `/__fixture/state` write counts with the no-latency run).
- Kill the fixture mid-reconcile, mid-Instructions save, mid-drag-drop, mid-switch: rows read "Offline" /
  "Reconnecting…", the save alert shows and keeps the text, the drop is undone locally; restart the fixture on the
  same port → everything recovers without relaunch, and the pinned write happens once after its minute.
- Network Link Conditioner "Very Bad Network" profile on the simulator host is **not** used (shared Mac); use the
  fixture's latency only.

**Bad data**
- Roster rows with: missing `ui_meta`, `ui_meta['hermes-bots']` a string, `pinnedFrom` a number / an object without
  `id`, `sectionId` pointing at no section, `sectionName` 2 000 characters, a bot name of emoji and RTL text, two
  bots with the same display name, 0 bots.
- `subagent.list` / `process.list` answering `{}`, `{"subagents":null}`, rows without `status`, 4001, -32601, a string.
- `profiles.describe` with no `soul`, `soul: null`, `model: null`, `model` a string; `profiles.configure` answering
  `{"ok":true}` with no `applied`.
- `/api/profiles/sessions` answering a bare array, `{"sessions":null}`, rows without `id`, 500 rows, HTML, 401.
- Error messages for attention: empty, 50 000 characters, containing both "401" and "rate limit" (transient wins).
- In every case: no crash, no blank row, no orange status from a transient error, no control that does nothing.

**Interruption**
- During each of: a drag in progress, the swipe peek, the delete-section sheet, the Instructions page dirty, the
  Undo pill showing, a switch in progress, "Waking up…" — do: background the app 10 s and return; lock/unlock; rotate;
  receive a push banner; pull Control Centre; an incoming-call banner (`simctl` status-bar override is not enough —
  use the system "Simulate" where available, else skip and say so). Expected: drag cancels cleanly; peek snaps back
  and still counts as shown; sheets stay; dirty text is kept; the Undo pill's clock keeps the remainder (does not
  restart, does not expire while backgrounded for less than its remainder); statuses are right within one poll of
  returning.
- Low Power Mode on (`-HQDebugLowPower YES` if the simulator cannot toggle it): background-work polls at 15 s.

**Relaunch**
- Kill and relaunch during each state above. Expected after relaunch: "Not Delivered:" still on its row; attention
  gone; no "Waking up…"; the peek flag honoured; an unsaved Instructions edit is gone (no draft is promised) with no
  partial write; a section delete that had been confirmed is either fully done or fully not (`/__fixture/state`); a
  pinned reconcile that was in flight is completed by the next launch with one write; the gateway in use is the one
  last picked; background claims are rebuilt from `delegation.status` / `agents.list` and a finished one clears.
- 20 cold launches in a row with a restored chat: Bot Info › Edit Bot opens every time (L227).

**Accessibility sizes**
- Every screen this stream touches at XS, L (default), AX1, AX3, AX5, in light and dark, portrait: Bots list rows with
  each status (offline, waking, attention, approval, working, Not Delivered, Draft), tiles, the section-delete sheet,
  Bot Info header + About collapsed/expanded, Model group, Instructions (empty, long, saving, failed), the empty chat
  with Recent Activity (keyboard up and down), the Undo pill (two lines), the Filter › Gateway menu. Nothing clipped,
  nothing overlapping, wrapping rows keep 12–14 pt vertical padding, every target ≥ 44 pt.
- VoiceOver pass over the same: each row reads name, status, unread; the switcher reads once (§2); the peek never
  runs; the Undo pill is reachable and does not expire while focused; "More"/"Less" announce; drag has the
  "Move to Section" menu as its non-drag path.
- Reduce Motion: no peek, pushes cross-fade, no spring on the Undo pill. Increase Contrast and Reduce Transparency:
  orange and red prefixes still meet 4.5:1 on the row background in both appearances (measure; darken the orange in
  light mode if it fails). Bold Text: no truncation of "Not Delivered:".
