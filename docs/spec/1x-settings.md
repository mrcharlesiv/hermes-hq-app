# 1x — Settings, gateways, bot editing, Skills and Connectors

Implementation spec for the "settings" stream of HQ Native's second milestone: the Settings screen, more than one
gateway (add, switch from the Bots/Sessions title, manage), bot organising and editing (pin, hide, sections, Edit Bot,
Edit Head, New Bot), and the Skills and Connectors pages. It maps what the web app at release-build238 does, says
exactly what goes over the wire, and decides what this round leaves out.

Read first: `ARCHITECTURE.md`, `HermesKit/Contracts.swift`, spec 01 (§2, §7.4, §17), spec 02 (§2.4, §5, §7, §10,
§12.5), spec 04 (§1.3), spec 06 (§0, §8, §9, §11, §12). Where this spec and the web app disagree, the web app wins
unless a line here is marked **DECISION** (each one says why).

---

## 0. Conventions

### 0.1 Citation key

| Prefix | Path |
| --- | --- |
| `S/` | `/Users/me/Projects/hermes-hq-native-ref238/src/` (Hermes HQ phone code, build 238) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref238/build/` (gates: exact-string patches of the vendored renderer — what the phone actually runs) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref238/vendor/hermes/apps/desktop/src/` (vendored Hermes desktop renderer) |
| `HB/` | `V/plugins/hermes-bots/` |
| `AG/` | `/Users/me/.hermes/hermes-agent/` (gateway source, HEAD `d94b70f`, read only) |
| `C/` | `AG/tui_gateway/contracts/` (the JSON-RPC contract the gateway enforces) |
| `FX/` | `/Users/me/Projects/hermes-hq-native-ref238/scripts/` (stand-in gateways) |
| `NAT/` | `/Users/me/Projects/hermes-hq-native/` |
| `MEM/` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` (owner history) |
| `SP0N` | `NAT/docs/spec/0N-*.md` |

`file:N` is a line, `file:N-M` a range. **[gate]** = behaviour that exists only because a `B/` gate rewrote vendored
code.

### 0.2 Two wire rules that bite in this area

1. **Params are strict.** Every JSON-RPC params model is `extra="forbid"` (`C/base.py:32-35`); an unknown key answers
   error **4000** "invalid params for <method>: <key>: …" (`C/registry.py:93-108`). The key lists in §10 are complete:
   send nothing else. Watch `reload.mcp` (plain `Params`, **no `profile`**, `C/tools_mcp_plugins.py:112-137`) and
   everything `ProfileParams`-based (optional `profile` = the *routing* profile, `C/common.py:231-234`; the *target* of
   a `profiles.*` call is `name`).
2. **`profiles.*` calls are long handlers** run off the socket reader (`AG/tui_gateway/server.py:181-197`). Use the 30 s
   default RPC timeout (`SP02` §0.3) for writes, 30 s for the slim read, and never block UI on them.

---

## 1. What ships this round, and what doesn't

### 1.1 In this round

| Area | Native piece | Web source |
| --- | --- | --- |
| Settings root | grouped list: gateway card, Appearance (mode), Chat (tool-call hook), Sounds, Bots & Tools, About | `S/settings-ios-list.tsx:398-442`, `S/phone-tab-bar.tsx:891-978`, `S/ui-nav/more-account.tsx` |
| Gateway page | saved gateways (check, switch, Rename, Remove, Add Gateway…), connection line, Sign Out | `S/gateway-accounts.tsx`, `B/fe-native-gates.ts:47-91`, `S/bridge/fe-native.ts:170-181` |
| Title switcher | Bots and Sessions titles open a gateway menu with "N New" and a news dot | `S/gateway-switcher.ts`, `S/gateway-title.tsx`, `MEM/gateway-switcher.md` |
| Bot organising | row menu, swipes, Pin/Unpin (with the Pinned section), Hide/Show, sections (create, rename, reorder, delete, move, drag) | `S/ui-bots/bot-menu.ts`, `bot-actions.ts`, `pinned-section-model.ts`, `HB/user-sections.ts` |
| Bot Info (organise subset) | sheet with header, About, Organize (Pinned, Show in Bots, Section), Edit | `S/ui-bots/info-state.ts:80-140`, `info-actions.ts` |
| Edit Bot | Title, Description (pages inside the Bot Info sheet) | `HB/edit-profile-dialog.tsx`, **[gate]** `B/fe-lists-gates.ts:2024-2063,3186` |
| Edit Head | Shapes editor: shape, eyes, glasses, mouth, colour (24), backdrop, blush, blob remix, ideas, Shuffle/Undo, My Style, Reset Head; CAS save + desktop mirror | `S/ui-heads/edit-head-sheet.tsx`, `sync.ts`, `mirror.ts`, `head.ts` |
| New Bot | Name, Title, Description → create, mint Bot Chat, intro turn | `HB/create-dialog.tsx:372-600`, `HB/soul.ts:160-184`, `HB/canonical-chat.ts:332-532` |
| Skills | per-bot installed list with switches, skill page (SKILL.md), "Available from Hermes" (official catalog) install/uninstall with progress | `V/api/skills.ts`, `V/store/hub-actions.ts`, `AG/hermes_cli/web_routers/skills.py` |
| Connectors | per-bot MCP server list with live status and an on/off switch | `V/app/capabilities/connectors/data/rpc.ts:148-152`, `AG/hermes_cli/web_routers/mcp.py:94-107,372-394` |

### 1.2 Left out of this round (and why)

| Left out | Why |
| --- | --- |
| Gateway-config pages (Model, Chat behaviour, Workspace, Safety, Browser, Vault, Memory & Context, Voice, Advanced, Billing, Providers, API Keys, archived Sessions) and Settings search, Export / Import / Reset to Defaults | They edit the gateway's `config.yaml` through schema-driven autosave forms with redacted credentials (`S/settings-ios-list.tsx:116-175,428-436`); a large surface that writes to the owner's real gateway. The web app keeps them. Separate round. "Model menu and favourite models" is its own parity line. |
| Themes gallery (skins), Desktop Look, High Contrast, UI Scale, Typography | Native ships the Nous palette only (`SP06` §1.1); Desktop Look and its options are web-skin features (`SP06` §11; `MEM/ui-scale-setting.md`: "UI scaling should only be for the desktop style theming"). |
| Chat Display rows other than tool calls (Text Direction, Reactions, Vibe Hearts, Inline Embeds, In-App Tips, Intro Splash) | Not built natively; a row that does nothing is exactly what the owner reported (`MEM/glitch-sweep.md`: the slider "sent its page behind Settings, and … Session List selectors do nothing"). Rule: never show a control the native app doesn't act on. |
| Notifications settings, Mute | Push is its own parity line (separate APNs topic). |
| Haptics switch | The web phone has none (`S/completion-sound-pref.ts:1-2`: "no control for that on the phone"); iOS's own System Haptics switch governs `UIFeedbackGenerator`. |
| Theme grid in Edit Head; Robot, Dots, Orb, Pixel, Emoji themes; "Describe it"; Character | The native renderer draws Shapes only (`NAT/App/Heads/HeadModel.swift:76-79`, `SP06` §13 item 7); every owner head is Shapes (`SP02` §10.4.10). A theme grid needs every theme drawn. "Describe it" is mostly vocabulary for the other themes (`S/ui-heads/describe.ts:8-104`). Character was removed by the owner ("awful", `MEM/bot-head-redraw-proposal.md`). Port later, as originals, never redrawn. |
| Hats ("Top" strip) | Owner: "hats looked off" (`MEM/new-bot-style-no-hats.md`). Not offered, not drawn; saves write `"hat":"none"` (§7.6). |
| My Style › New Bots (auto-dress new bots) | Unshipped on the web (`MEM/new-bot-style-no-hats.md`: commit 850b80e3 "unshipped"). |
| Photo pictures (Upload, Generate, Pet, Move and Scale framer) | Every owner bot wears a head; photo upload needs the framer and `profiles.set_asset` uploads. Later. |
| New Bot › Advanced (clone source, model, SOUL.md, skills/tools/MCP picks); Bot Info › Skills & Instructions | Advanced editor (`profiles.describe` + per-section `profiles.configure`) is the gateway-config round. |
| Delete Bot, Duplicate, Add to Group Chat, group chats, Watch Browser, Screen, Talk/Memo tiles, New Chat, Mute | Destructive (Delete removes memory and chats) or owned by other streams (groups, voice, browser, push). Hooks are left in the menu (§5.1). |
| Hosted (Nous) connectors, Composio "Connect Apps" | Hosted connectors are gated off for the owner (`MEM/composio-connectors.md`: "It's switched off for the owner … `managed_tools=false`"); Connect Apps writes API keys and MCP entries into every profile and reconciles automatically — "on the owner's gateway it's the owner's call". Later round. |
| Adding / editing / removing MCP servers, per-tool filters, MCP OAuth | Whole-config writes with secrets (`V/app/capabilities/mcp/use-mcp-servers.ts:229,300-330`). This round only reads servers and switches one on or off. |
| Skills: public 11 MB catalog, hub search across sources, scan view, bulk "All" switch, "Disable Unused", editing/archiving a learned skill; Tools and Plugins tabs | Large download (`B/fe-pages-gates.ts:238-242`: "~63 MB of JSON (11 MB over the wire)"), security-scan flows, and bulk writes. The gateway's own official catalog covers built-in skills. |
| Automatic writes: Pinned-section reconcile, section-name backfill, hide sweep, SOUL backfill | Same reasons as `SP02` §12.5 (not user actions; the owner's web app keeps doing them; whole-object writes from a stale copy could revert the owner's change). User actions in this round write the same patches those reconcilers would (§5.3). |
| Phone↔phone layout record (`dispatch-layout`) | Parked by the owner (`MEM/bot-layout-sync.md`: "don't merge f18f0f42 … unless the owner asks"). |

---

## 2. Shared write machinery (every bot write in this round goes through it)

One `BotMetaWriter` in `HermesKit/Store/` (owned by `BotStore`), so every action behaves the same.

### 2.1 Two kinds of writes, two conflict rules (web parity)

| `ui_meta` key | Owner | Conflict rule on the web | Native |
| --- | --- | --- | --- |
| `hermes-bots` | desktop Hermes's Bot Mode plugin (pin, hide, sections, title, …) | **No compare-and-swap.** The client sends its *whole merged* object; the gateway replaces the key (`HB/data.ts:350-372`; `AG/tui_gateway/methods_profiles.py:619-627`). Last writer wins. | Same. No `ui_meta_expected_revisions` for this key. |
| `dispatch-head` | Hermes HQ heads | **Compare-and-swap** with `ui_meta_expected_revisions:{"dispatch-head":<revision read>}` (`S/ui-heads/sync.ts:69-98`) | Same (§7.5). |

### 2.2 The `hermes-bots` write, step by step

Web: `setMeta` (`S/ui-bots/bot-actions.ts:50-58`) → `ensureBotMetadata` (`HB/canonical-chat.ts:638-668`) →
`saveBotMetaOrThrow` (`S/ui-bots/meta-save.ts:14-20`) → `saveBotMeta` (`HB/data.ts:314-447`) with the stress-a
outcome fix (**[gate]** `B/stress-a-gates.ts:11-59`).

1. **One write per bot at a time** (FIFO queue keyed by profile name). **DECISION:** the web does not serialise. Native
   does, because each write's fresh read (step 3) could otherwise return server meta *older* than a still-in-flight
   write to the same bot, and the merge `{...local, ...server}` would drop that write's change. Serialised, step 3
   always reads after the previous write settled.
2. **Patch locally at once** from the device snapshot (the row redraws in this frame, haptic per §5) and stamp
   `metaWriteAt[profile] = now` (write fence, §2.4). **DECISION:** the web applies its patch only after the fresh read
   returns (`S/ui-bots/bot-actions.ts:50-57`); native shows the change first (Telegram-like feel) and corrects it in
   step 3 in the rare case the gateway's meta differs.
3. **Fresh read.** `profiles.list {"include_sessions": false}` (30 s). Find the row whose `name` is the bot. If it carries
   an object at `ui_meta["hermes-bots"]`, merge it into the device snapshot exactly as `SP02` §5.2: `{...local,
   ...server}`, keep local `image`, delete `chat`, drop a local `group` scalar when the server has `groups` and no
   `group`. Persist the snapshot. Recompute the patch over the merged meta (pin, section and undo patches depend on it,
   §5) and re-apply it locally if it changed. **DECISION:** the web's `ensureBotMetadata` reads the *full*
   `profiles.list {}` for a source-scoped row; that call takes 18–107 s on the owner's gateway (`SP02` §2.1.1). The slim
   read carries the same `ui_meta` and `ui_meta_revisions` (`AG/tui_gateway/methods_profiles.py:282-299`:
   `_profile_ui_meta_fields` runs with or without `include_sessions`). A failed read fails the action (roll back, alert,
   Try Again) as the web's does.
4. **Send** `profiles.configure {"name": <profile>, "ui_meta": {"hermes-bots": <merged + patch, without "image" and
   "pet">}}` (+ other sections when the action has them, §6.3). JSON `null` values in the patch are sent as `null`
   (a cleared `sectionId` is `null`, a forgotten home is `pinnedFrom:false`).
5. **Outcome** (re-stamp `metaWriteAt` when it settles, `HB/data.ts:441-444`):

   | Reply | Outcome | Native |
   | --- | --- | --- |
   | result with `applied.ui_meta === true` | persisted | done; update `uiMetaRevisions["hermes-bots"]` from `applied.ui_meta_revisions` |
   | result with an `applied` object but `ui_meta !== true` | failed (`HB/data.ts:429-432`) | roll back, alert reason "Your gateway didn’t save the change." (`S/ui-bots/meta-save.ts:19`) |
   | RPC error whose message matches `/unknown\|unsupported\|invalid param\|method not found\|-3260/i` | "unsupported" (older gateway; local copy kept silently) **[gate]** `B/stress-a-gates.ts:19-28` | **DECISION: failed**, reason "This gateway can’t save bot settings yet. Update Hermes on the computer, then try again." Every gateway that passes the sign-in compatibility check (`SP01` §4.3) answers `applied`; a silent local-only pin would be reverted by the next roster. |
   | any other RPC error | failed | roll back, alert with the gateway's message |
   | result with no `applied` at all | "unsupported" | **DECISION: failed**, same reason as above |
   | transport failure: `isTimeout`, `isConnectionLost`, `isNotConnected` | failed with that error's text (`S/ui-bots/meta-save.ts:12,16-19`) | roll back, alert, Try Again |

6. **Roll back** = re-apply `undoOf(meta, patch)` locally (`S/ui-bots/pinned-section-model.ts:81-82`: each patched key
   back to its old value, `null` when absent, `false` for `pinnedFrom`), then send the undo as one more best-effort
   whole-object write, as `meta-save.ts:18` does (it matters after a timeout: the first write may have landed).
   **DECISION (review round):** the undo goes out inside the bot's queue (10 s timeout) after the caller already has
   the failure (the alert shows at once) and *before* the next queued write to that bot starts its fresh read. Queued
   behind other writes it could overwrite them (pin times out, a hide queued meanwhile lands, then the old whole object
   without `hidden` replaced it).
7. `readOnlyGateway` on (`SP02` §12.5): refuse before step 2, nothing sent, alert reason "Changes are turned off for
   this gateway in this build."

### 2.3 The failure alert (all "Couldn’t …" titles in this spec)

`failureAlert` (`S/ui-kit/native-alert.ts:103-123`): `UIAlertController(.alert)`, title e.g. "Couldn’t Pin Ivy", message
= the reason cut to two lines, actions **Show Details** (pushes a selectable text page with Copy), **Try Again**
(preferred; re-runs the whole action from step 2, without asking again), **OK** (cancel). Haptic
`notification.error` when it shows.

### 2.4 Write fence (roster reads must not undo a fresh local write)

Web: `noteBotMetaWrite` (`HB/data.ts:285-298`), checked by `mergeServerMeta` (`HB/profile-ops.ts:233-250`): a roster
snapshot *fetched before* the latest write to that bot does not overwrite its meta; stamps older than 60 s are dropped.

Native: `BotStore` records `issuedAt` when it *sends* each slim/full `profiles.list`; on apply, a bot is fenced (keeps
the device snapshot instead of the row's `ui_meta["hermes-bots"]`, and the description it wrote) while a write to it is
still out, or when `metaWriteAt[profile] > issuedAt` (stamped at the local patch and again when the write — or a failed
write's undo — settles). **DECISION (review round): order alone, no 60 s clock.** A full read on the owner's gateway
takes 18–107 s (`SP02` §2.1.1): with the web's wall-clock expiry a pin made at t=5 under a read sent at t=0 and landing
at t=80 would flip back. A stamp (and the shown description) is dropped once a read sent after it has been applied.

### 2.5 After a write: no extra roster read

**DECISION:** the web invalidates the roster after an Edit Bot save (`HB/edit-profile-dialog.tsx:126-130`), which costs a
full read on the owner's gateway. Native relies on the local patch + fence and the normal poll (`SP02` §3).

---

## 3. Settings

### 3.1 Where it opens

- The Bots bar's trailing person button (`NAT/App/Bots/BotsViewController.swift:73-76`, today "Account") becomes
  **Settings** (accessibility label "Settings", same `person.crop.circle` glyph). It presents a page sheet (`.large`
  detent, system glass sheet) holding a `UINavigationController`. `AccountViewController` is retired; its rows move to
  the Gateway page (§3.4).
- Expose `SettingsScreens.makeSettings(services:) -> UIViewController` and
  `SettingsScreens.makeCapabilities(services:profile:tab:)` so a More tab (if another stream adds one, web order:
  Capabilities first, Settings last, gateway card on top, `S/phone-tab-bar.tsx:891-897,976-984`) pushes the same pages.
- Pages are SwiftUI `List` (`.insetGrouped`) in `UIHostingController`s pushed on UIKit navigation (`ARCHITECTURE.md`
  "Navigation is UIKit"; `PLAN.md` "SwiftUI for simple screens"). Large title "Settings" on the root, inline titles on
  pages. Rows that can wrap get 12–14 pt vertical padding (`MEM/row-padding-feedback.md`: "Any cell whose text can wrap
  gets explicit vertical padding: about 12–14pt top and bottom"), trailing controls 16 pt from wrapping text.

### 3.2 Root layout (top to bottom)

| Group | Rows | Behaviour |
| --- | --- | --- |
| (card) | **Gateway card**: app mark 48 pt · gateway name (Title 3 semibold, wraps) · status line (Subheadline, secondary) · chevron | `S/ui-nav/more-account.tsx:18-63`; CSS `S/phone-ui-nav.css:265-275`: min 76 pt, 14 pt gap, padding 12/16. Taps → Gateway page (§3.4). |
| Appearance | **Light or Dark** — System / Light / Dark (inline menu picker) | §3.5 |
| Chat | **Tool Calls** › (value: the hook's summary) | Shown only when the activity stream registered its screen (§3.6). |
| Sounds | **Completion Sound** switch; footer "Plays when a bot’s reply finishes." | Shown only when the chat module calls the cue (§3.7). |
| Bots & Tools | **Skills** ›, **Connectors** › | Skills/Connectors push Capabilities on that tab (§9). Kanban Tab is on Appearance › Tabs (§3.9). |
| About | **About** › | §3.8 |

No search field this round (the list fits on one screen; search returns with the gateway-config pages).

Native wording change (UX study 2026-10-19 #63/#68/#69/#72, `SettingsSearch`): the mode row is **Light or Dark** (not
"Appearance" again under the Appearance header); the gateway-config section header is **On Your Gateway** (was
"Hermes"); its Sessions page is **Archiving & Project Folder** (UX study 2026-10-21 #117; was Chat Folder & Archiving); the Chat switches are **Greeting on Empty Chats** (was
"Intro Splash") and **Files Button in Chats** (was "File Browser"). Old names stay as search keywords.

### 3.3 Gateway card status line

`accountLine` (`S/ui-nav/more-account.tsx:18-20`): `[state words, "<n> Bot"/"<n> Bots" (n > 0), "Hermes <version>"]`
joined with " · ", each piece kept on one line (non-breaking space inside "9 Bots" and "Hermes 0.21.5").

- State words: Connected · Connecting… · Reconnecting… · Offline · Signed Out, from `ConnectionState`.
- Dot (8 pt circle before the text): green connected, orange connecting/reconnecting, red offline, gray signed out
  (`S/phone-ui-nav.css:272-275`). Colour only repeats the words.
- n = number of profiles in the last roster (hidden ones included; web counts `$profiles`).
- version = `GET /api/status` → `version` with a leading `v` and anything from the first `+` or `-` removed
  (`S/settings-ios-list.tsx:347`), read once per app run and again when Settings opens if older than 60 s and connected
  (`S/ui-nav/more-account.tsx:23-38`). Unknown → leave the piece out.
- Name = the gateway title rule (§4.2). VoiceOver: "<name>, <line>, <host>. Gateway settings".

### 3.4 Gateway page ("Gateway")

Web: Settings › Gateway › Connection, with `GatewayAccounts` on top (**[gate]** `B/fe-native-gates.ts:51-57`).

**Group "Gateways"** (header "Gateways", trailing **Edit**/**Done** when ≥ 1 row, `S/gateway-accounts.tsx:139-143`):

- One row per saved account, most recently used first: title, subtitle, checkmark on the one in use (§4.2 for words).
  While switching to a row its subtitle reads "Switching…".
- Tap another row → switch (§4.4). Tap the current row → nothing.
- Trailing swipe: **Rename** (gray) on every row; **Remove** (red) on rows that aren't in use
  (`S/gateway-accounts.tsx:127-136`). Long-press menu: Rename…, Remove… (same rules). In Edit mode each row shows
  Rename and (not current) Remove buttons, as the web does (`:154-157`).
- Last row: **Add Gateway…** with a `plus` glyph (§4.3).
- Footer: `failure` text when the last action failed, else (others saved) "Each gateway keeps its own chats, drafts and
  sign-in on this iPhone. Switching doesn’t sign you out. Alerts come only from the gateway in use." (UX study #268:
  push comes from one gateway) or (only one) "Add another gateway to switch between them
  here. Each keeps its own chats, drafts and sign-in." (`S/gateway-accounts.tsx:164-166`).

**Group "Connection"** (the one in use):

- **Address** — the base URL, selectable text, wraps (**[gate]** `B/fe-native-gates.ts:468-486`: "the gateway address …
  is fixed on iOS (Sign out to change it)").
- **Account** — "Nous account" for Sign in with Nous, else the username (`NAT/App/Bots/AccountViewController.swift:35-40`;
  `S/connection-startup.ts:74`).
- Footer: `Signed in as <user> on <host>. Your session is kept in iOS Keychain (never your password) and renews
  itself.` where user is "your Nous account" for Nous (`S/bridge/fe-native.ts:172-178`).

**Group (danger):** **Sign Out** (destructive). Confirm (`UIAlertController(.actionSheet)`): title "Sign out of <host>?"
(`S/bridge/fe-native.ts:180`), message "Your bots and chats stay on your gateway. You can sign in again any time."
(**DECISION**: the web says drafts are deleted, `B/fe-native-gates.ts:80`; the native app keeps no drafts, so the
existing truthful copy stays), action "Sign Out". **Revised (UX study #120, #129, #269):** the title names the gateway
as its row does ("Sign out of <title>?"); the message says, when others are saved, "<title> leaves this list and
Hermes HQ switches to <next>.", then what this phone deletes ("Its drafts[, N unsent messages][ and N voice
recordings] on this iPhone are deleted."), then "Your bots and chats stay on <title>. You can sign in again any time."
(`App/Settings/SignOutWords.swift`). Remove's message counts the same way. Then `AppModel.signOut()` (`NAT/App/AppModel.swift:119-128`); with
other gateways saved the next most recent becomes current and opens (`SP01` §17).

### 3.5 Appearance

- Values: **System** (default), **Light**, **Dark**. Device-wide (not per gateway). Stored in `UserDefaults`
  `hqn.appearance` = `system|light|dark`. Applied with `window.overrideUserInterfaceStyle` on every window
  (`.unspecified` for System) at launch before the first frame and on change. Haptic `selection` on change.
- Web equivalent: the mode segmented control of Appearance › Theme (`V/app/settings/appearance-settings.tsx:570-580`),
  stored `hermes-desktop-mode-v1` (`S/connection-offline.ts:61-73`). The native app cannot read the web's value; it
  starts on System.
- Native wording change (UX study 2026-10-19 #63): the row is titled **Light or Dark**.

### 3.6 Chat › Tool Calls (hook to the activity stream)

```swift
@MainActor enum SettingsHooks {
    /// Set by the activity stream at launch: its "Tool Calls" screen (Tool Call Style, After Reply).
    static var toolCallsScreen: (() -> UIViewController)?
    /// e.g. "Rows" / "Rows, hidden after reply" — shown as the row's value.
    static var toolCallsSummary: (() -> String)?
    /// Set by the chat module once it calls `CompletionCue.turnEnded(sessionKey:)` (§3.7).
    static var completionCueWired = false
}
```

Row hidden while `toolCallsScreen == nil`. Web context: the rows live in Appearance › Chat Display with ids
`dispatch-tool-call-style` / `dispatch-tool-calls` (`S/tool-calls-row.tsx:11-32`, `S/settings-ios-list.tsx:235-236`).
Native wording change (UX study 2026-10-19 #110, `SettingsWords.toolCallsSummary`): the value is "Rows", "Rows, hidden
after reply", or "In Header" alone (was "Rows · Keep").

### 3.7 Sounds › Completion Sound

- Switch, default **on**, `UserDefaults` `hqn.completionSoundOn` (web `dispatch.completionSoundOn`,
  `S/completion-sound-pref.ts:5-11`; row copy **[gate]** `B/stress-d-gates.ts:110-121`: label "Completion Sound",
  description "Plays when a bot’s reply finishes.").
- `CompletionCue.turnEnded(sessionKey:)` is called by the chat module for every live `message.complete` it receives
  while the app is active (web: `playCompletionSound(sessionId)` on every `message.complete`,
  `V/app/session/hooks/use-message-stream/gateway-event/message-stream.ts:350-351`). One cue per session key per 2 s.
  Audio session category `.ambient` (respects the silent switch, mixes with other audio).
- The sound is the web's default variant 1 "Two-note comfort" (`V/lib/completion-sound.ts:221-230`): three sine voices
  — E4 329.63 Hz at t0 (dur 0.22 s, peak 0.05, attack 0.03 s), C4 261.63 Hz at t0+0.08 (0.52 s, 0.07, 0.08 s), C3
  130.81 Hz at t0+0.08 (0.46 s, 0.02, 0.10 s); each envelope 0.0001 → peak (exponential, over attack) → 0.0001
  (exponential, at start+dur); master gain 0.48 → low-pass 3,800 Hz Q 0.32 → dry 0.88 + reverb 0.34
  (`:383-418`). Render once into a mono PCM buffer (44.1 kHz, ~1.0 s) with this math and an `AVAudioUnitReverb`
  (small room) for the wet path; cache it.
- If the chat module doesn't wire the cue this round, the row is hidden (§1.2 rule).

### 3.8 About

Plain grouped cells (`S/about-dispatch.tsx:46-88`):

| Group | Rows |
| --- | --- |
| "Hermes HQ Native" | **Version** — `"<CFBundleShortVersionString> (<CFBundleVersion>)"` e.g. "1.0 (3)" (`NAT/project.yml:15-16`); **Hermes on Your Gateway** — status `version` (§3.3) or "Unavailable". Footer: "Your personal agent, based on Hermes Agent by Nous Research (MIT)." |
| (links) | **Support** › `https://gethermeshq.com/support`; **Privacy Policy** › `https://gethermeshq.com/privacy` (`S/about-dispatch.tsx:40-41`), each in `SFSafariViewController`; **Open-Source Licenses** › a page listing swift-markdown (Apache-2.0), swift-cmark (BSD-2-Clause), Hermes Agent (MIT, credit) with each licence text |

Left out: Diagnostics, performance-log switch (web-only plumbing to the Mac), the "Update Hermes" card (it updates the
owner's gateway; `MEM/onboarding-clarity.md`: "Hermes main bug #134128 breaks Nous sign-in (do not hermes update)").
Native wording change (UX study 2026-10-19 #71, `SettingsSearch.markLabel`): the app's marker row is **Mark a Slow
Moment** (the web says "Mark a Janky Moment").

### 3.9 Kanban Tab (coordination with the pages stream)

The pages stream decides whether tab 3 is Kanban or Artifacts from a probe and reserves the device-local override key
`pages.kanbanTab.override.<account>` = `auto|on|off` for this stream (`NAT/docs/spec/1x-pages.md` §4.2, D-P2; web: the
Capabilities › Plugins switch, copy "A task board your bots work from. It’s the Kanban tab." / "… Turn it on to add a
Kanban tab.", `S/fe-pages-r4.ts:48-51`).

- Row "Kanban Tab", inline menu picker: **Automatic** (`auto`, default) · **On** · **Off**; footer = the web copy above
  for the current effective state. Per gateway account (the key carries the account). Haptic `selection`.
  Native wording change (UX study 2026-10-19 #62, `SettingsWords.kanbanFooter`): on **Automatic** the footer says what
  Automatic chose — "… It’s the Kanban tab (Automatic: on), and Artifacts is in More › Workspace." or "… Automatic:
  your board has no tasks yet, so Kanban is in More. It takes Artifacts’ tab once the board has tasks. Choose On to
  give it the tab now." On and Off start with the web copy ("… It’s the Kanban tab, and Artifacts is in More ›
  Workspace." / "… Turn it on to add a Kanban tab in Artifacts’ place."). With the shared tab turned off in the list
  above: "… Its tab is turned off above, so Kanban and Artifacts open from More." (Off: "… Off: Kanban isn’t shown, and
  Artifacts opens from More."). The row is drawn with a Menu on the iPhone and iPad (a menu Picker drops its icon,
  #61), the form's pop-up on the Mac.
- **One home** ([kanban-tab-one], owner 2026-11-03: one home per page): the row is on **Settings › Appearance › Tabs**
  (`App/Settings/TabOrderPage.swift`), in a section "Kanban or Artifacts" under the Tab Bar (Mac: Sidebar) section,
  with the other tab choices. It was also a row of Settings › Bots & Tools until then; that row is gone. The footer
  says where Artifacts goes, so a tab that changes by itself on Automatic is explained where it is chosen. The Mac's
  wording says "sidebar" where the iPhone's says "tab" (`SettingsWords.kanbanFooter(mac:)`); the path is the same.
- Settings search ("kanban tab", "kanban", "artifacts tab") opens Tabs and marks the row (`tab-order:kanban`).
- The one-time tip when Automatic gives Kanban Artifacts' tab (`PagesTabs.explainKanbanTabOnce`,
  `SettingsWords.kanbanTookTab`): "Kanban Took Artifacts’ Tab" (Mac: "… Place"), "Artifacts is in More › Workspace.
  Change this in Settings › Appearance › Tabs." How Kanban Works names the same path.
- Shown only when the pages stream exposes `PagesTabs.kanbanAvailability` and it is not "absent" (no dead control).
- Writing the key is all this row does; the pages stream applies it (it never swaps tab 3 under the user's finger).
- When the pages stream adds its More tab, it lists the gateway card, Settings and Capabilities through
  `SettingsScreens` (`1x-pages.md` §1.2); the Bots bar's Settings button stays (both reach the same pages).

---

## 4. More than one gateway

Owner's choice (`MEM/gateway-switcher.md`): "Offered A (title switcher), B (all at once, big), picked **A + unread
dots**." And (build 111): "a switch must land on the page it was made from." Names (build 113): a name given on the
phone shows everywhere.

### 4.1 What exists already

`AccountStore` / `SignInService` hold every saved account with its own session and implement select / sign out /
remove / rename (`NAT/HermesKit/Net/AccountStore.swift:71-104`, `NAT/HermesKit/Net/SignInService.swift:169-217`); spec
`SP01` §17 has the wire rules (remove = that account's own logout ≤ 6 s, then Keychain delete). This round adds the UI,
`AppModel.switch(to:)`, the title switcher and the news check.

### 4.2 How a gateway is named

`gatewayRows` (`S/gateway-accounts.tsx:23-30`) with `gatewayFriendlyName` (`S/connection-offline.ts:6-12,38-55`):

```
friendly = label?.trim()  ||  friendlyName(url)
friendlyName(url):
    host = URL host without port, brackets stripped
    host empty, IPv4, contains ':' (IPv6) or "localhost"  → "Your Gateway"
    name = host minus a trailing .local/.lan/.home/.localdomain (case-insensitive)
    if name contains '.' and no spaces → first label only
    "<owner>s-(Mac|MacBook|iMac|Mac-mini|Mac-Studio|Mac-Pro)…" → "<owner>’s-<Kind>…"   (case-insensitive)
    '-' runs → one space; each word mac→Mac, macbook→MacBook, imac→iMac, studio→Studio, pro→Pro, air→Air, mini→mini
    first character upper-cased; empty → "Your Gateway"
named   = friendly != "Your Gateway"
title   = named ? friendly : host:port
subtitle = [named ? host:port : "", accountName, hasSession ? "" : "Signed Out"]  joined " · " (empties dropped)
accountName = "Nous account" for Nous accounts (username "nous:<id>"), else the username
```

Port the test vectors from `S/connection-offline.test.ts` and `S/gateway-accounts.test.ts` (e.g.
`alexs-Mac-Studio.local` → "alex’s Mac Studio"). `GatewayAccount.label` today falls back to the host
(`NAT/HermesKit/Net/SavedAccounts.swift:99-105`); keep the user's own label separately (`StoredAccount.label`) so the
rule can tell "named on this phone" from "host".

### 4.3 Add Gateway…

From the Gateway page or the title menu. Presents the existing sign-in form (`NAT/App/SignIn/`) in a full-height sheet
with **Cancel** (leading). Cancel → nothing changes. Success → the account is saved first in the list and made current
(`SavedAccounts.save`), then the app switches to it (§4.4) and the sheet closes. Web: `addGateway`
(`S/gateway-accounts.tsx:55-59`) reloads into the form with Cancel back (`SP01` §17).

### 4.4 Switch

1. Guard: one switch at a time (web `$gatewaySwitcher.switching`, `S/gateway-switcher.ts:178-191`).
2. If the target has no session (`hasSession == false`, "Signed Out"): present the sign-in form prefilled with its
   address and username, with Cancel. **DECISION:** the web switches and lands on the prefilled sign-in screen; native
   keeps the current gateway until that sign-in succeeds (Cancel leaves you where you were).
3. `AppModel.switch(to:)`: `tearDown(shutdownClient: true)` → `signIn.switchTo(account)` → `activate(account)`
   (`NAT/App/AppModel.swift:134-179`). The Bots and Sessions stores paint the target's disk caches synchronously.
4. UI: keep `MainTabController` and the selected tab, but make every per-account tab owner again
   (`MainTabController.installTabs(fresh: true)`): new Bots and Sessions screens (an open chat belonged to the old
   gateway; search and collapsed sections reset; both lists paint from the new gateway's caches) and anything else
   built for the old account in `installTabs` (the pages stream's `PagesTabs` holds the old client), then
   `.hqGatewayDidSwitch`. A Settings sheet stays open and its Gateway page moves the checkmark. (Web lands on the page
   the switch was made from: chat → its list, `MEM/gateway-switcher.md` build 111; the web reloads the page.)
5. Haptic `selection` (`S/gateway-accounts.tsx:96`). Failure → `notification.error`, footer "Couldn’t switch to
   <title>. Try again." on the Gateway page, or from the title menu an alert "Couldn’t Switch to <title>" with reason
   "The gateway in use couldn’t be closed. Try again, or switch in Settings › Gateway." and Try Again
   (`S/gateway-title.tsx:68-69`).
6. Push (later milestone): a switch must move push registration (web unregisters on switch, `SP01` §17).

### 4.5 Rename and Remove

- **Rename** (`S/gateway-accounts.tsx:43-53`): alert with a text field; title "Rename Gateway"; message "A name for
  <host:port> on this iPhone. Leave it blank to use its address."; field starts at the current label, placeholder =
  row title; actions Cancel / Save. Same text → nothing. `AccountStore.rename` (trims, ≤ 60 characters). Success haptic
  `notification.success`; failure `notification.error` + footer "Couldn’t rename <title>. Try again."
- **Remove** (`:105-118`, not the current one): confirm alert, title "Remove <title>?", message "<accountName> is signed
  out of this gateway on this iPhone, and its drafts here are deleted. You can add it again.", destructive "Remove
  Gateway". Then `SignInService.remove(account)` (its own logout ≤ 6 s, Keychain delete) and purge that account's
  device data: `TranscriptCache.shared.purge(account:)` and the four `RosterDisk` files
  (`roster|botstate|sessions|sessionstate-<accountKey>.json`, `NAT/HermesKit/Model/RosterDisk.swift:8-12`). Haptic
  success / error; failure footer "Couldn’t remove <title>. Try again." Refresh the switcher (§4.6).

### 4.6 The title switcher (Bots and Sessions)

Shown only with **two or more** saved accounts (`S/gateway-switcher.ts:87`); with one, the plain title as today.

- **Title**: "Bots" / "Sessions" with a chevron; tap opens the menu. **Subtitle** (`navigationItem.subtitle`, iOS 26):
  `"Switching to <title>…"` during a switch, else the current gateway's title; when a link problem is showing (today's
  "Offline"/"Reconnecting…" subtitle, `NAT/App/Bots/BotsViewController.swift:363-410`) it reads
  `"Reconnecting… · <title>"` / `"Offline · <title>"`. A news dot (8 pt circle, accent colour) precedes the gateway
  title when any other gateway has news (`S/gateway-title.tsx:79-86`). Use `attributedSubtitle` for the dot.
- **How (DECISION, verify on the simulator first):** use `navigationItem.titleMenuProvider` (system chevron + menu on
  the title) with the existing inline large title (`largeTitleDisplayMode = .inline`). If the system does not show a
  title menu with an inline large title on iOS 26, fall back to a `subtitleView`/`largeSubtitleView` button
  (`showsMenuAsPrimaryAction`) that shows the subtitle text and opens the same menu. Do **not** replace the title with
  a custom `titleView` and do not add height: the owner just asked for the header to sit higher ("The header (where it
  says Bots) is too far from the top of the screen").
- **Menu** (`S/gateway-title.tsx:23-36`), title "Gateways":
  - inline section: one action per saved gateway (most recent first), title = §4.2 title, checkmark on the current,
    subtitle "In Use" (current) · "Signed Out" (no session) · "N New" (other gateway's news count, "9+ New" above 9)
    · none.
  - inline section: **Add Gateway…** (`plus`), **Manage Gateways…** (`gearshape`) → present Settings and push the
    Gateway page.
  - Opening: haptic `selection`, and start a news check if the last finished more than 30 s ago
    (`gatewayCheckSoon`, `S/gateway-switcher.ts:174`). Counts that land while the menu is open update it through
    `contextMenuInteraction?.updateVisibleMenu` where available (web patches subtitles live, `:61`); else next open.
- VoiceOver label: "<Bots>, on <current title>, <N> new on other gateways" (parts present only,
  `S/gateway-title.tsx:39-43`).

### 4.7 The news check (other gateways)

Web: `checkOtherGateways` (`S/gateway-switcher.ts:126-158`), `parkedChats` (`:36-62`), `unreadCount` (`:66-74`). Push
can't do it: only the gateway in use is registered (`MEM/gateway-switcher.md`: "push does NOT keep coming from other
gateways … Hence polling").

1. For each saved account that isn't current, one at a time, one check at a time:
   - No session → count 0.
   - Read its parked data from disk: `roster-<key>.json` (`RosterCacheFile.profiles`) and `botstate-<key>.json`
     (`BotDeviceState.unread`), cached in memory per account until accounts change (`:118-123`). No roster file → 0.
   - Chats: rows with a `name`, not `hidden` (row `ui_meta["hermes-bots"].hidden == true`), canonical `message_count != 0`,
     with an id = `canonical_session.resolved_id || canonical_session.id`; profile = row name; baseline =
     `baselines[name]`; marked = `markers[name]` contains any of the canonical ids. At most **40**.
   - Read each chat with **that account's own session**: `GET /api/sessions/<id>?profile=<name>` (omit `profile` for
     `default`) — `AG/hermes_cli/web_routers/sessions.py:562-582` returns the stored row with `last_active` and
     `message_count`. A REST-only client per account (no socket), ephemeral `URLSession`, 8 s timeouts, ids matching
     `^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$` (`SP01` §7.4). Nous accounts renew through the shared single flight and write
     the rotated pair back with compare-and-swap (`SP01` §7.3 rule 4) — never replay a refresh token.
   - Count = chats where `marked`, or `live.last_active > baseline && live.message_count != 0` (no baseline → not news).
   - 401/403 → count 0 and the row reads "Signed Out" for this run (in memory; a tap signs in again first, §4.4.2). The
     Keychain session is **not** deleted for that (a 403 from a proxy or a gateway mid-restart must not sign anyone
     out); a refusal after renewal ends it in Keychain through `GatewayAuth`, as for the gateway in use. A later read
     that answers clears the mark. Unreachable/timeout → keep the previous count. Answers are keyed by the id asked
     for (the route resolves prefixes and lineage, so the row it returns may carry another id). Logs never carry the
     gateway's address as public data.
2. **When** (`S/gateway-switcher.ts:160-174`): 4 s after launch; every 3 minutes while the app is active (×3 in Low Power
   Mode / serious thermal state, as `BotStore.pollInterval`); on return to the foreground if the last check ended
   > 30 s ago; when the title menu opens (> 30 s). Nothing runs with only one account. A gateway that didn't answer
   (Can’t Reach) is skipped by the timed and return checks for 6, 12, 24, then 30 minutes (cap) after each miss in a
   row; the title menu still asks it at once, and any answer ends the backoff (owner, build 408: a saved gateway that
   was off timed out every 3 minutes, each time after a 15 s sign-in renewal).
3. Counts live in memory (`GatewaySwitcherModel`, `@Observable`); a removed account's count is dropped.
4. Note: `RosterDisk` keeps the newest **3** roster files (`NAT/HermesKit/Store/BotStore.swift:676`). With more than 3
   gateways the oldest has no parked roster and shows no news (web keeps 3 too).

---

## 5. Organising bots (Bots list)

### 5.1 Row menu (long press) and swipes

Web menu: `botRowMenu` (`S/ui-bots/bot-menu.ts:14-52`). Native `UIContextMenuConfiguration` on a bot row or tile
(replacing `NAT/App/Bots/BotsViewController.swift:525-536`), title = bot name:

```
[tiles, preferredElementSize .medium]   Talk (hook) · Memo (hook) · Pin|Unpin (pin / pin.slash)
[inline] Bot Info (info.circle) · [New Chat (hook)] · [Screen (hook)]
[inline] [Mute (hook)] · (hidden bot: "Show in Bots" eye | else "Mark as Read"/"Mark as Unread" as today)
         More ▸  [Watch Browser (hook)] · Edit Bot (pencil) · Move to Section ▸ · [Add to Group Chat… (hook)]
                 · [Duplicate (hook)] · (hidden bot: Mark as Read/Unread | else "Hide from Bots" eye.slash)
[inline, destructive] [Delete Bot (hook)]
Move to Section ▸  each user section (folder; the bot's shown section has a checkmark and is disabled)
                   [inline] New Section… (folder.badge.plus) · "Remove from Section" (tray, only when it has one)
```

`[x (hook)]` = an item another stream may register (`BotMenuHooks.items(for:)`); leave it out when nobody did. Sections
listed exclude Pinned; a pinned bot's shown section is its home (`shownSectionId`, `S/ui-bots/pinned-section-model.ts:29-35`).

Swipes (`S/ui-bots/row-swipes.ts:8-18`): leading **Read/Unread** (full swipe, blue — exists) then **Pin/Unpin**
(orange). Trailing: **Info** (gray) → Bot Info. **DECISION:** the web's trailing "More" opens the row menu; UIKit has
no API to open a context menu from a swipe, and Bot Info holds every row action (the web's own C12 rule,
`S/ui-bots/info-state.ts:1-4`). Mute (indigo, full swipe) is the push stream's.

### 5.2 Pin / Unpin

Web: `runBotAction 'pin'` (`S/ui-bots/bot-actions.ts:83`) → `setMeta(…,'pinned')` → `pinPatch` (`:50-56`). Haptic
`selection` at the tap. Patch (`S/ui-bots/pinned-section-model.ts:47-70`), with `sectionName(id)` = the name of a
section **this device** has, else null:

```
pinPatch(meta, pinned) = { pinned } + (pinnedSectionPatch({...meta, pinned}) ?? {})
pinnedSectionPatch(m):
  home    = m.pinnedFrom is {id:string≠"", name} ? {id, name:string|null} : m.pinnedFrom === null ? null : undefined
  current = m.sectionId non-empty string ? m.sectionId : null
  P = "hermes-hq-pinned"
  if m.pinned:
     current != P                         → {sectionId:P, sectionName:"Pinned", pinnedFrom: current ? {id:current, name: m.sectionName as string|null} : null}
     m.sectionName != "Pinned"            → {sectionName:"Pinned"} + (home undefined ? {pinnedFrom:null} : {})
     home undefined                       → {pinnedFrom:null}
     else                                 → null
  else:
     current != P                         → home undefined ? null : {pinnedFrom:false}
     home undefined                       → {pinned:true, sectionName:"Pinned", pinnedFrom:null}
     else back = home ? sectionName(home.id) : null
                                          → {sectionId: home && back != nil ? home.id : null, sectionName: home && back != nil ? back : null, pinnedFrom:false}
```

Example — pin Ivy (in "Work"); fresh server meta `{"sectionId":"sec-work","sectionName":"Work","created":1790000000001}`:

```json
{"jsonrpc":"2.0","id":41,"method":"profiles.configure","params":{"name":"ivy","ui_meta":{"hermes-bots":
 {"sectionId":"hermes-hq-pinned","sectionName":"Pinned","created":1790000000001,"pinned":true,
  "pinnedFrom":{"id":"sec-work","name":"Work"}}}}}
→ {"jsonrpc":"2.0","id":41,"result":{"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":4}}}}
```

Unpin then writes `{"pinned":false,"sectionId":"sec-work","sectionName":"Work","pinnedFrom":false}` merged into the
whole object. Port every vector in `S/ui-bots/pinned-section-model.test.ts` as unit tests (including "settles after one
write in every case"). Alert titles "Couldn’t Pin <Name>" / "Couldn’t Unpin <Name>".

Display (unchanged from `SP02` §7.3–7.4): the first 6 pins are tiles; extra pins are rows in the Pinned section, shown
first, only when it has a non-tile row (`MEM/pinned-section.md`: "Phone hides Pinned unless pins overflow the 6
tiles").

### 5.3 Hide / Show

`runBotAction 'hide'` (`S/ui-bots/bot-actions.ts:100-107`): patch `{"hidden":true}` (undo `{"hidden":false}`), alert
titles "Couldn’t Hide <Name>" / "Couldn’t Show <Name>". After a successful hide show the **Undo pill**: label
"Hidden", way back "Find it under Hidden, below your bots." (VoiceOver reads both), Undo → Show. Show has no pill.

Undo pill (`S/ui-kit/undo-pill.tsx:1-3`): a glass capsule (`UIGlassEffect`, interactive) floating 8 pt above the tab
bar, "Hidden · Undo", 4 s (8 s at accessibility text sizes), paused while touched or VoiceOver-focused. It shows with
the local change (the row moves in the same frame), not after the gateway answered (~3 s on the owner's gateway); a
failed write takes it away as its alert shows, and its Undo queues behind the write. **Not** the tab
bar's bottom accessory (the owner rejected that slot, `SP06` §8 "Rejected glass behaviours").

Hidden bots stay in the collapsed **Hidden · N** section at the end (exists natively, `NAT/App/Bots/BotListModel.swift:61-62`);
their menu has **Show in Bots** on the first level (`MEM/bot-unhide.md`: "Hidden bots had no way back … a hidden bot's
menu has Show in Bots on the first level").

### 5.4 Sections

Records are device-local `[{id, name}]` in display order (`BotDeviceState.sections`); membership is on the bot
(`sectionId` + `sectionName` in its meta), which is what reaches desktop Hermes (`HB/user-sections.ts:1-21`;
`MEM/bot-layout-sync.md`: "A section made on the phone reaches the desktop only once a bot is filed into it").

| Action | Where | Local | Writes |
| --- | --- | --- | --- |
| **New Section…** | Bots bar + menu (§5.6); row menu Move to Section ▸; Bot Info › Section | alert "New Section", field (placeholder "e.g. Clients"), actions Cancel / **Create**; name trimmed, ≤ 40 characters (**[gate]** `B/r21-pages-gates.ts:95-105`). Append `{id:"sec-<Date.now() base36>-<5 random base36 chars>", name}` (`HB/user-sections.ts:112-131`) | from a bot's menu: file that bot (below); from compose: none |
| **Move to Section** (unpinned bot) | menu, Bot Info, drag | — | patch `{"sectionId":id,"sectionName":name}`; Remove from Section → `{"sectionId":null,"sectionName":null}` (`HB/user-sections.ts:286-306`). Skip when already equal. Success haptic `notification.success` (`MEM/taptic-feedback-gaps.md`: "Move to Section success"). Alert "Couldn’t Move <Name>". |
| **Move to Section** (pinned bot) | same | — | `sectionMovePatch` (`S/ui-bots/pinned-section-model.ts:74-78`): target Pinned → `{}` if pinned else `pinPatch(true)`; else `{"pinnedFrom": target ? {"id":target,"name":sectionName(target)} : null}` |
| **Rename…** | section header ⋯ | alert "Rename Section", field starts at the name, Save enabled only when changed (`requireChange`) | re-stamp every member, one write per member, in order: `{"sectionId":id,"sectionName":newName}` (`HB/user-sections.ts:133-147`) |
| **Move Up / Move Down** | section header ⋯ (disabled at the ends) | reorder records | none |
| **Delete Section** | section header ⋯ | with members: confirm "Delete “<Name>”?", message "Its bot moves to Unassigned." / "Its <n> bots move to Unassigned.", destructive "Delete Section" (`S/ui-bots/section-delete.ts:4-9`); empty: no confirm. Remove the record, mark the id "pending delete" until the member writes finish (`HB/user-sections.ts:229-259`) so adoption doesn't rebuild it | each member `{"sectionId":null,"sectionName":null}`, in order. The Undo pill "Deleted “<Name>”" (8 s) shows with the local removal: Undo puts the record back at its index, skips member writes not yet sent and re-files the members already moved (queued behind their writes; one moved elsewhere meanwhile stays) (`HB/roster-pane-sections.tsx:52-64`). A failed member write puts the record back at its index (members not yet moved show under it), takes the pill away and alerts; Try Again deletes it again. The confirm counts hidden members too. |

Section header (`SP06` §6.3): the name, then at the trailing edge the caret (a folded section's count before it). No
⋯: a hold on the header (a right click on the Mac) opens its menu (**Rename…**, **Move Up**, **Move Down**, **Delete
Section** destructive — Title Case per **[gate]** `B/stress-a-gates.ts:108-117`), and VoiceOver offers its items as
actions; a tap on the name folds the section. [bots-hold-only] The ⋯ was taken away on 2026-10-27, put back in build
742 (menu review), and taken away again on 2026-11-04 (owner: "keep it very simple, where you just hold to see the
extra stuff"; the Bots page looks cleaner). Sessions' project headers and Tiles' page headers keep theirs. The Pinned
section's menu stays empty (**DECISION**: a rename or delete of Pinned would be undone by the web's reconciler on the
next roster and would unfile every pin), as do Hidden's and Group Chats'.

**List composition change (required):** `BotList.compose` groups by section *name* in first-appearance order
(`NAT/App/Bots/BotListModel.swift:35-69`). Switch the Bots list to `BotStore.layout` (id-keyed records in the device's
order, `NAT/HermesKit/Model/RosterLayout.swift`) and show **empty** user sections ("Work · 0" with a one-line hint row
"Hold a bot and drag it here, or use its menu › More › Move to Section."; [header-menus] on the Mac, whose row menu has
Move to Section at its top level, "Drag a bot here, or Control‑click it and choose Move to Section.", **[gate]**
`B/stress-a-gates.ts:113`) while
no search is active (**[gate]** `B/stress-a-gates.ts:100-105`: empty sections only "while nothing narrows the list").

### 5.5 Drag a bot onto a section

Owner asked for it (`MEM/row-drag-sections.md`: "drag and drop bots between sections … hold a row until its menu shows,
then move"). Native: `UICollectionViewDragDelegate` / `DropDelegate` on the Bots list (UIKit turns the long-press
menu into a drag when the finger moves). Rows are draggable only when at least one user section exists; tiles keep
their own reorder. Drop targets = section blocks: a user section (Move to Section), the unassigned block (Remove from
Section), the Pinned section (= Pin). Dropping where it already is does nothing. Highlight the target block while
over it (haptic `selection` on entering a new block); auto-scroll near the edges. On drop: the same write as the menu
(§5.4), haptic `impact(.light)`.

### 5.6 Bots bar + button

A trailing **+** button (`plus`), last in the bar's one glass capsule [Filter] [Search] [+] (`roster-filters.ts:33-39`,
`SP06` §6.3): **New Bot** (`plus`) → §8; [New Group Chat — groups stream]; inline **New Section…**
(`folder.badge.plus`) → §5.4 (empty section). VoiceOver: "New Bot, Group Chat or Section" ("New Bot or Section" without
group chats); the Mac rail's + (same menu) says the same. Id `bots.compose` (the capsule's third button).
[bots-plus] It was the pencil (`square.and.pencil`) until 2026-11; owner 2026-11-03 (menu review #3): the pencil only
ever means a new chat (Sessions' button), so Bots' create menu is a +. It is a plain bar item, drawn as the magnifier
is in both looks (on the Mac one weight step heavier, as Jobs' +).

### 5.7 Device-local state added (per account, in `BotDeviceState`, `botstate-<key>.json`)

`sections` (now user-edited), `pendingSectionDeletes` (memory only), `headOverlay: [profile: {head JSON|null,
revision}]` (§7.5), `metaWriteAt` (memory only). Tile order is unchanged (`pinOrder`).

---

## 6. Bot Info and Edit Bot

Owner (`MEM/sheet-pages.md`): Bot Info / Edit Bot "without 'a pop up on top of a pop up'. Chosen: pages inside one sheet
(UINavigationController-in-a-sheet)."

### 6.1 Bot Info sheet (organise subset)

Opened from the row menu / Info swipe (and by other streams from the chat header). Page sheet, `.large` detent, its own
`UINavigationController`. Bar: leading close (`UIBarButtonItem(systemItem: .close)`, glass), title "Bot Info", trailing
**Edit** (disabled while the gateway is offline). Content (`S/ui-bots/info-state.ts:80-140`, this round's rows only):

| Group | Rows |
| --- | --- |
| header | head 80 pt (live), name (Title 2 semibold), role line (secondary, wraps) |
| About | **About** — the description, up to 4 lines then "more" (omitted when empty); **Handle** — `@<handle>` value |
| Organize | **Pinned** switch; **Show in Bots** switch (= not hidden; the web says "Show in Bots List", the phone matches its row menu's Show in Bots / Hide from Bots); **Section** — value = shown section name or "Unassigned", pop-up menu: "Unassigned", each section (checkmark on current), then **New Section…**. Footer when offline: "You can change this bot again once its gateway is back." |
| footer | "Profile ID <name> · <gateway title>" |

Picks run the same actions as §5 (`S/ui-bots/info-actions.ts:87-100,125,141-142`). Other streams append groups through
`BotInfoHooks`. Writes are disabled (rows dimmed) while the gateway link isn't ready.

### 6.2 Edit Bot page (pushed inside the Bot Info sheet)

Web: `EditProfileDialog` (`HB/edit-profile-dialog.tsx:47-256`) with the phone bar **[gate]** (`B/fe-lists-gates.ts:2024-2063`,
title "Edit Bot" `:3186`).

- Bar: **Cancel** (leading) · "Edit Bot" · **Save** (trailing, prominent tinted glass; disabled until something changed —
  "Save waits for a change", `B/fe-lists-gates.ts:2024-2036`; shows "Saving…" while busy).
- Under the bar: "Appearance and role for <Name>." (secondary).
- **Picture** group: the head (64 pt) and an **Edit Head** button; note "Your other devices and desktop Hermes show the
  same picture." After a head save this round, the note reads "Head saved. It’s on every device on this gateway."
  (the web's "every phone" reads wrong on an iPad) (`S/ui-heads/renderer-hooks.tsx:59-63`; `MEM/head-save-ux.md`: Head tab says "Head saved"). **DECISION:**
  drop "Make it a robot, a character, an orb, anything." (those themes aren't in this round).
- **Title** — text field, placeholder = the current display name; value = `meta.title` (empty when none).
- **Description** — multi-line field, placeholder "What should this bot help with?"; value = the row's description.
- Leaving with changes (Cancel, swipe down, Back): action sheet "Discard Changes" (destructive) / "Keep Editing"
  (`MEM/head-save-ux.md`: "the Discard Changes guard … an idea chip or Shuffle alone closes without asking" — count
  every change). Set `isModalInPresentation` while dirty.

### 6.3 Saving Edit Bot

One `profiles.configure` through §2 with up to two sections:

- `ui_meta.hermes-bots` = whole merged meta + `{"title": <trimmed>}` — only when Title changed.
- `description` = the trimmed text — only when Description changed (`""` clears it).

```json
{"jsonrpc":"2.0","id":57,"method":"profiles.configure","params":{"name":"ivy",
 "ui_meta":{"hermes-bots":{"sectionId":"sec-work","sectionName":"Work","created":1790000000001,"title":"Ivy the Scout"}},
 "description":"Finds flights and hotels"}}
→ {"jsonrpc":"2.0","id":57,"result":{"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":5},"description":true}}}
```

- **DECISION (description):** the web runs `cli.exec {"argv":["profile","describe",<name>,"--text",<desc>]}`
  (`HB/edit-profile-dialog.tsx:132-145`), which spawns a Hermes CLI process on the gateway and cannot clear a
  description (`--text ""` prints the current one, `AG/hermes_cli/profile_cmd.py:328-352`). `profiles.configure`'s
  `description` writes the same file with the same flags (`write_profile_meta(..., description_auto=False)`,
  `AG/tui_gateway/methods_profiles.py:398-401`) and reports `applied.description`.
- **DECISION (look fields):** the web re-sends the desktop face fields (`shape`, `color`, `imageKind`, `custom:true`) on
  every save. Native doesn't edit the desktop face, so it sends only `title`; the merged object still carries whatever
  the face fields were.
- Outcomes: all applied → `notification.success`, pop back to Bot Info (title and role redraw from the local patch).
  `applied.ui_meta` not true → stay on the page with what was typed, alert "Couldn’t Save Changes" (**[gate]**
  `B/stress-a-gates.ts:56-59`). `applied.description === false` → stay, alert "Couldn’t Save the Description"
  (`:59`). A rejected part rolls back only its own field.

---

## 7. Edit Head (Shapes)

Web: `EditHeadSheet` (`S/ui-heads/edit-head-sheet.tsx:93-262`), saved through `saveHead` (`S/ui-heads/sync.ts:69-98`),
mirrored by `mirrorHead` (`S/ui-heads/mirror.ts:58-70`). Owner history: `MEM/blob-colors-theme-grid.md` (24 colours,
"Edit Head's theme strip hid Shapes off screen and scrolled up/down"), `MEM/head-save-ux.md` ("never noticed a place to
click save"; "a save with no visible result reads as 'no save'"), `MEM/default-shape-heads.md` (white eyes on light
pages, black on dark).

### 7.1 Page

Pushed from Edit Bot (§6.2) — a page in the same sheet. Bar: **Cancel** · "Edit Head" · **Save** (prominent tinted glass,
the only filled button on the page; disabled until the draft differs from the head it opened with).

- **Sticky stage** under the bar: the draft head (~120 pt, live motion), with **Shuffle** and **Undo** (plain buttons;
  `MEM/head-save-ux.md`: "Shuffle demoted so Save is the only filled button"). Undo is enabled after a whole-head change
  (an idea, Shuffle, New Blob, Use My Style) and restores the head before it.
- Scrolling content (SwiftUI `ScrollView`; heads drawn by `HeadView`, cached by `Head.cacheKey`):

| Section | Control | Options (label) |
| --- | --- | --- |
| Ideas for <Name> | horizontal strip of 10 heads | §7.3 |
| Shape | strip of heads | round Round, blob Blob, square Square, pill Pill, triangle Triangle, hex Hex, cloud Cloud, drop Drop, star Star, heart Heart |
| Eyes | strip | slits Slits, dots Dots, ovals Ovals, googly Googly, happy Happy, sleepy Sleepy, stars Stars, hearts Hearts |
| Glasses | strip | none None, shades Shades, aviators Aviators, round Round, monocle Monocle |
| Mouth | strip | none None, smile Smile, open Oh, cat Cat, grille Line |
| Color | swatch grid, 6 per row, `SHAPE_COLORS` order: red coral peach butter lime grass / mint teal sky cobalt lilac grape / rose pink magenta plum denim forest / wine cocoa caramel ink slate paper | names: Red, Coral, Peach, Butter, Lime, Grass, Mint, Teal, Sky, Cobalt, Lilac, Grape, Rose, Bubblegum (pink), Magenta, Plum, Denim, Forest, Wine, Cocoa, Caramel, Ink, Slate, Paper. Swatch fill: ink `#0A0A0A`, paper `#E7E1D3`, else `TONES[c].accent` (`S/ui-heads/robot.ts:12-37`) |
| Extras | **Backdrop** segmented: None · Dark · Light · Color; **Blush** Off · On; **Remix** "New Blob" (only when shape = blob; new seed `1 + floor(random × 1e6)`, counts for Undo) | |
| My Style | note "Keep one look for all your bots. Each bot keeps its own color."; **Set as My Style**; **Use My Style** (disabled when none) | §7.4 |
| (danger) | **Reset Head** (destructive; only when a head was saved) | §7.5 |

Each strip item shows the draft with that one part changed (compact drawing, page mode), selected item outlined, its
name under the section heading (`S/ui-heads/edit-head-sheet.tsx:53-66`). Haptic `selection` on every pick. Labels:
`S/ui-heads/labels.ts:7-35`. No "Top"/hats strip (§1.2). Segmented controls show whole labels
(`apportionsSegmentWidthsByContent = true`; `MEM/segmented-labels-whole.md`).

### 7.2 Opening

The page edits the head as it was when opened: `opened = resolve(row)`:
`head = overlay[profile] if overlay.revision > row revision else parse(row.ui_meta["dispatch-head"])`;
`revision = that revision` (row: `ui_meta_revisions["dispatch-head"]`, 0 when absent — `S/ui-heads/sync.ts:28-50`);
`saved = head != nil`. Unsaved → the draft starts at `defaultHead(profile)` (`SP02` §10.3).
A saved head in another theme (robot, dots, …): the draft starts at the same head with `theme:"shape"` and `tile:"none"`
(`themed`, `S/ui-heads/edit-head-sheet.tsx:68-69`), and a note under the stage reads "This bot wears a <Robot> head,
which this app can’t edit yet. Saving makes it a Shapes head." (**DECISION**, theme names per `labels.ts:7`).

### 7.3 Ideas, Shuffle

- **Shuffle**: `rollHead(random, "shape")` with a non-seeded random (`S/ui-heads/head.ts:207-242`, Shapes branch:
  colour from `SHAPE_COLORS`, seed `1+floor(r×1e6)`, form uniform from 10, then
  `tile` weighted none 8 / dark 1.5 / color 1 / light 0.5, `look` slits 5 / dots 1.5 / ovals 1.5 / googly 1.5 / happy 1 /
  sleepy .7 / stars .6 / hearts .6, `specs` none 6 / shades 1.5 / aviators .7 / round .9 / monocle .5, `hat` (draw the
  number, then force `"none"`), `mouth` none 5 / smile 2.5 / open .7 / cat .7 / grille .5, `blush` r < .25). Port the
  exact draw order of `rollHead` (every `random()` call in sequence, including the robot-field draws before the Shapes
  block) so seeded ideas match the web pixel for pixel.
- **Ideas for <Name>**: `ideasFor("shape", about, seededRandom(nameHash("<profile>|shape|<round>")))`
  (`S/ui-heads/labels.ts:38-45`, `edit-head-sheet.tsx:145`), `about = "<display name> <description>"`, 10 heads; the
  first 5 overlay `topicFor(about)` parts (`S/ui-heads/topics.ts:9-46`; only Shapes-relevant keys matter) keeping the
  rolled `tile`. `round` starts at 0 and +1 after each Shuffle. Picking an idea replaces the draft (Undo-able).

### 7.4 My Style

Device-local `UserDefaults` `hqn.head.style` (web `dispatch.head.style`, `S/ui-heads/edit-head-sheet.tsx:43-50`).
**Set as My Style** stores the draft (haptic `selection`); **Use My Style** applies it keeping this bot's `color` and
`seed`. Per phone; the saved head itself syncs.

### 7.5 Save (compare-and-swap) and Reset

```
profiles.configure {"name": <profile>,
                    "ui_meta": {"dispatch-head": <stored record> | null},
                    "ui_meta_expected_revisions": {"dispatch-head": <revision>}}
```

Record = `storedHead(head)` = every field of the v6 head plus `"headset": ears == "headset"`
(`S/ui-heads/head.ts:162`). The native `Head` keeps only Shapes fields (`NAT/App/Heads/HeadModel.swift:8-30`), so build
the record as: start from the opened record's fields normalised exactly as `parseHead` (`S/ui-heads/head.ts:122-160`) —
or from `ICON_HEAD` (`:97-100`) for an unsaved head — then set `v:6`, `theme:"shape"`, and the Shapes fields from the
draft. Example (Ivy, never saved, picked hex + ovals):

```json
{"jsonrpc":"2.0","id":63,"method":"profiles.configure","params":{"name":"ivy",
 "ui_meta":{"dispatch-head":{"v":6,"theme":"shape","color":"grass","seed":1562156509,"shape":"dome","face":"visor",
   "visor":"band","shell":"ink","antenna":"bulb","ears":"headset","mouth":"none","blush":false,"hair":"bob",
   "pattern":"face","tile":"none","eyes":true,"glyph":"✨","form":"hex","look":"ovals","specs":"none","hat":"none",
   "headset":true}},
 "ui_meta_expected_revisions":{"dispatch-head":0}}}
→ {"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"dispatch-head":1}}}
```

Outcomes (`S/ui-heads/sync.ts:69-91`; gateway CAS `AG/tui_gateway/methods_profiles.py:605-617`):

| Reply | Native |
| --- | --- |
| `applied.ui_meta_conflicts["dispatch-head"]` present (e.g. `{"ok":false,"applied":{"ui_meta":false,"ui_meta_conflicts":{"dispatch-head":{"expected":0,"actual":1}},"ui_meta_revisions":{"dispatch-head":1}}}`) | stay; inline notice under the bar "This bot’s head was changed on another device. Save again to replace it with yours."; set revision = `actual` (so the next Save replaces theirs); Save stays enabled |
| no `applied` object, or no `ui_meta` key in it | notice "This gateway can’t save bot heads yet. Update Hermes on the computer, then try again." |
| `applied.ui_meta !== true` | notice "The gateway didn’t save the head. Try again." |
| RPC/transport error | notice = the error's message, or "The gateway didn’t answer. Check the connection and try again." |
| success | revision = `applied.ui_meta_revisions["dispatch-head"]` if > old, else old+1; `headOverlay[profile] = {record, revision}` → every place that draws this bot (rows, tiles, chat header, Bot Info) redraws **now**; haptic `notification.success`; pop to Edit Bot (note "Head saved…"); then the mirror (below) |

- **Mirror** (desktop Hermes shows a profile's avatar picture, not heads): render the saved head non-compact, light page,
  **288 × 288 px** (scale 1), PNG → `profiles.set_asset {"name":<profile>,"asset":"avatar","data":"data:image/png;base64,…"}`.
  Not awaited, never fails the save (`S/ui-heads/mirror.ts:58-65`). 288 is the marker other clients use to ignore it
  (`SP02` §10.1).
- **Reset Head**: confirm-free (as the web); an Undo pill ("Head Reset", Undo) saves the previous head back. Same CAS call with `"dispatch-head": null`; on success
  `profiles.get_asset {"name","asset":"avatar"}`; if `found` and the data is a PNG whose IHDR is exactly 288×288, send
  `profiles.set_asset {"name","asset":"avatar","clear":true}` (`S/ui-heads/mirror.ts:66-68`; a photo someone chose is
  left alone). The overlay stores `{head:null, revision}` → the default head shows everywhere.
- Overlay rule (`S/ui-heads/sync.ts:35-50`): an overlay entry wins only while its revision is greater than the
  roster row's; a roster at the same revision or later wins again.
- `readOnlyGateway`: Save and Reset refuse (notice "Changes are turned off for this gateway in this build.").

### 7.6 Hats

`hat` is always written as `"none"` (**DECISION**, `MEM/new-bot-style-no-hats.md`: "hats removed from Shapes heads …
parseHead ignores a stored hat"). A stored hat is already ignored by the native renderer (`HeadModel.swift:27-28`).

---

## 8. New Bot

Web: `CreateBotDialog` (`HB/create-dialog.tsx`), phone bar **[gate]** (`B/fe-lists-gates.ts:1941-1975`).

### 8.1 Sheet

Page sheet with its own navigation bar: **Cancel** · "New Bot" · **Create** (prominent; disabled until valid and not
taken; "Creating…" while busy). Under the bar: "A named teammate with its own memory, skills, and chat. It can message
your other agents." (`HB/i18n.ts:504`). Fields:

- Picture: the default head for the slug (updates as you type); note "The bot gets a shape from its name. You can change
  it once the bot is created." (`S/ui-heads/renderer-hooks.tsx:56`).
- **Name** (required, autofocus, placeholder "inbox-triage"). **Title** (placeholder "Inbox Triage").
  **Description** (multi-line, placeholder "What should this bot help with?").
- Taken (a roster row with that slug exists): inline under Name, accent colour: `An agent named "<slug>" already
  exists.` (`HB/i18n.ts:548`).

Identity (`HB/labels.ts:66-114`, `create-dialog.tsx:77,216-218`):

```
slugify(v, max) = v.lowercased → runs of [^a-z0-9_-] → "-" → trim leading/trailing "-" → first max chars
slugifyProfileName(v):
   NFC; each letter/digit: NFKD minus combining marks; if ASCII alnum keep it, else "-u<hex code point>-"; "-"+ → "-"
   slug = slugify(folded, ∞); ≤ 64 → slug; else cut at 64 on the last "-" boundary (or at 64), strip trailing "-"
slug  = slugifyProfileName(name.trim());   valid = slug matches ^[a-z0-9][a-z0-9_-]{0,63}$
title = title.trim() || (name has a char outside U+0020–U+007E ? name.trim() : "")
descriptionText = [title, description.trim()].filter(nonEmpty).join(" — ")
```

Vectors: `HB/labels.profile-name.test.ts:7-33` (`小助手` → `u5c0f-u52a9-u624b`, `Café Résumé` → `cafe-resume`,
`🤖` → `""`).

### 8.2 Create, step by step

1. `profiles.create` (`HB/create-dialog.tsx:389-411`):
   ```json
   {"method":"profiles.create","params":{"name":"inbox-triage","description":"Sorts my email","clone_from":"default",
    "no_skills":false,"share_auth":true,"soul":"# Inbox Triage\n\n**Mission:** Sorts my email\n\nYou are Inbox Triage, a persistent named agent (profile `inbox-triage`) on this machine.\nYou keep your own memory, skills, and conversation history across sessions."}}
   → {"ok":true,"name":"inbox-triage","path":"…","soul_written":true,"model_set":false,"mirrored":{…}}
   ```
   `soul = composeSoul` (`HB/soul.ts:160-184`): lines `["# <D>", "", title ? "**Role:** <title>" : nil,
   description ? "**Mission:** <description>" : nil, "", "You are <D>, a persistent named agent (profile `<slug>`) on this machine.",
   "You keep your own memory, skills, and conversation history across sessions."]`, nils dropped, joined "\n";
   D = displayName({name: slug, title}) = (title || slug) with `-`/`_` runs → space, each `\b\w` upper-cased
   (`HB/labels.ts:60-62`). Append the teammate-protocol section only when the last full `profiles.list` said
   `bot_mode_protocol` is false (current gateways say true, `SP02` §12.5); then port `messagingProtocolSection`
   (`HB/soul.ts:19-66`) verbatim. Errors: 4062 (exists, bad name) → show its message inline, stay; 4061/5062 → alert
   "Couldn’t Create <Name>". **Review round:** 90 s timeout (a long handler: it copies the default profile); a timeout
   or lost connection is followed by a slim `profiles.list` — if the slug is there now, steps 2–5 carry on instead of
   failing (a Try Again would only say "already exists" and leave the bot with no meta, Bot Chat or intro).
2. Meta: §2 write of `{"shape":"blobatar","imageKind":"shape","title":<title>,"created":<now ms>}` for the new profile
   (`HB/create-dialog.tsx:482-489`; the SDK ships `blobatarSvg`, so the web's default `shape` is "blobatar",
   `HB/create-dialog.tsx:138`, `V/sdk/index.ts:2081`). Best-effort: a failure here doesn't undo the bot.
3. Add the row locally at once (name, description, meta) so it appears in Bots; then a slim read replaces it.
4. `setup.runtime_check {"profile": <slug>}` (`C/config_free_tier_control.py:137-155`). Only `ok === false` counts.
5. Mint the Bot Chat as `SP02` §8.2 (registry lookup `session.list {profile,title:"Bot Chat",limit:200,include_hidden:true}`
   → adopt if found, else `session.create {profile,title:"Bot Chat",hidden:true,follow_profile_config:true}` +
   `session.title`). Add `BotStore.mintFreshChat(profile:)` that skips the "full roster confirmed no chat" wait (the
   profile is seconds old) but keeps the registry lookup.
6. Close the sheet, open the bot's chat (push from Bots).
7. If step 4 was not `false`: 400 ms after the chat is on screen, send "Hey, tell me about yourself!" through the normal
   send path (it shows as your bubble, as on the web: `HB/canonical-chat.ts:319-334,519-532`).
   If step 4 was `false`: no intro; show a notice in the chat (system row style) `Bot "<D>" created. No model provider is
   ready for it yet, so it skipped its introduction. Pick a provider and model for it in Hermes on your computer.`
   (**DECISION**: the web says "under Advanced", `HB/i18n.ts:521-522`; native has no Advanced this round). Until the
   chat stream offers a local system-row API, it is the chat's notice capsule kept until tapped (not timed), so a
   user who looked away still learns why the bot didn't introduce itself.
8. Haptic `notification.success` when the chat opens.

`readOnlyGateway`: Create refuses before step 1.

---

## 9. Capabilities: Skills and Connectors

One page "Capabilities" (pushed from Settings › Bots & Tools, or a More tab), scoped to **one bot** (profile). Bar
title "Capabilities"; a bot picker button (head 24 pt + name + chevron; menu of visible bots, default "Hermes" =
`default`) — web: the scope selector (`V/app/capabilities/scope-selector.tsx`). Under it a `UISegmentedControl`
**Skills | Connectors** with `apportionsSegmentWidthsByContent = true` (`MEM/segmented-labels-whole.md`: "the connectors
tab cuts off the word… might require a more global change" → "a long label widens its own segment"); at accessibility
text sizes where it doesn't fit, use a pull-down button instead. Switching bot or tab keeps each list's last answer
painted while it refreshes.

All REST below carries `?profile=<bot>` (the shim's rule, `S/bridge/shim.ts:35-44`).

### 9.1 Skills

Reads (`V/api/skills.ts:14-31,102-108`; `AG/hermes_cli/web_routers/skills.py:123-145,343-376`):

```
GET /api/skills?profile=ivy
→ [{"name":"arxiv","description":"Search and read arXiv papers","category":"research","enabled":true,"usage":12,"provenance":"bundled"}, …]
GET /api/skills/hub/official?profile=ivy
→ {"skills":[{"name":"blender-mcp","description":"…","source":"official","identifier":"official/creative/blender-mcp",
              "trust_level":"builtin","repo":null,"tags":["3d"],"category":"creative","installed":false}, …]}
GET /api/skills/content?name=arxiv&profile=ivy   → {"name":"arxiv","content":"---\nname: arxiv\n…","path":"…"}
```

List (SwiftUI `List`, search field at the top filters name, description, category — `V/app/capabilities/skills/skills-data.ts:50-61`):

- **Installed** — sorted by `usage` descending, then name. Row: name (Body semibold), description (Subheadline secondary,
  2 lines), caption "<category> · used <n>×" (`V/i18n/en.ts:2500`; omit the usage part at 0); trailing switch 16 pt
  from the text. Rows wrap → 12–14 pt vertical padding.
- **Available from Hermes** — official skills with `installed == false` and no installed skill of the same name
  (`V/app/capabilities/catalog/skill-catalog.tsx:186-198`), A–Z. Row: name, description, category; trailing **Get**
  capsule (progress spinner while installing).
- Footer: "Changes apply to new chats." (`V/i18n/en.ts:2509`).
- Load failure: in place of the list, title "Skills failed to load", the reason in words (`loadErrorText`,
  `S/settings-ios-list.tsx:445-450`) and **Try again**; retried automatically when the gateway link returns.

Switch (`V/app/capabilities/skills/skills-tab.tsx:79-120`): optimistic flip, haptic `selection`, then

```
PUT /api/skills/toggle?profile=ivy   body {"name":"arxiv","enabled":false}   → {"ok":true,"name":"arxiv","enabled":false}
```

(`AG/hermes_cli/web_routers/skills.py:379-394`). One write at a time per bot (the gateway saves one disabled list);
failure → flip back, alert "Couldn’t Change <name>" with the reason. Re-read the list after each write settles.

Skill page (tap a row): title = name; the SKILL.md body rendered with the chat's `MarkdownRenderer` (front matter between
the leading `---` lines removed); a switch row "Turned On"; for `provenance == "hub"` a destructive **Uninstall** (confirm
"Uninstall <name>?" / "Uninstall"). Loading: "Loading skill…"; failure: "Couldn’t load this skill", reason, **Try again**
(**[gate]** `B/fe-pages-gates.ts:332-334`).

Install / uninstall (`V/store/hub-actions.ts:21,82-178`):

```
POST /api/skills/hub/install?profile=ivy   {"identifier":"official/creative/blender-mcp"}
→ {"ok":true,"pid":4242,"name":"skills-install-official-creative-blender-mcp-1a2b3c4d"}
GET  /api/actions/skills-install-official-creative-blender-mcp-1a2b3c4d/status?lines=200&profile=ivy
→ {"name":"…","running":true,"exit_code":null,"pid":4242,"lines":["Fetching…"]}     (poll every 1.2 s)
→ {"name":"…","running":false,"exit_code":0,"pid":4242,"lines":[…,"Installed blender-mcp"]}
POST /api/skills/hub/uninstall?profile=ivy {"name":"blender-mcp"}   (same polling)
```

(`AG/hermes_cli/web_routers/skills.py:97-112`, `AG/hermes_cli/web_routers/actions.py:366-420`). Exit 0 → the row moves
(install → Installed, on; uninstall → gone), haptic `notification.success`, re-read both lists. Non-zero → if the log
matches the scan-block patterns (`V/store/hub-actions.ts:201-222`: `/Not installed:\s+the security scan found\s+(?:(\d+)\s+)?high-risk\s+pattern/i`,
legacy `/Installation blocked:.*?\(([a-z_-]+) source \+ ([a-z_]+) verdict, (\d+) findings?\)/i`), alert "Couldn't install
<name>" with `The security scan flagged <n> item(s) to review[ and the skill comes from an unverified source]. Read the
scan before deciding whether to trust the author.` (`V/i18n/en.ts:2652-2654`); else alert "Couldn’t Install <name>"
with the last 3 log lines. A 404 on the status read while the page is gone = abandoned, no alert. Leaving the page keeps
polling in the background service until the action ends (the result updates the lists when you return).

### 9.2 Connectors

Reads (`V/app/capabilities/connectors/data/rpc.ts:148-152`; `C/tools_mcp_plugins.py:360-420`):

```json
{"method":"mcp.servers.list","params":{"profile":"ivy"}}
→ {"servers":[{"name":"github","transport":"http","url":"https://api.githubcopilot.com/mcp/","command":null,"args":[],
   "env":["GITHUB_TOKEN"],"auth":"header","oauth_tokens_present":null,"enabled":true,"tools":null,"source":"config","plugin":null}]}
{"method":"mcp.servers.status","params":{"profile":"ivy"}}
→ {"servers":[{"name":"github","transport":"http","tools":31,"connected":true,"disabled":false,"status":"connected",
   "source":"config","plugin":null}],"checked_at":1791600000}
```

List: one row per configured server, A–Z. Row: name (Body semibold), subtitle = status words — `connected` "Connected ·
<n> tools", `connecting` "Connecting…", `failed` "Couldn’t connect", `disabled` "Off", `lazy` "Starts when needed",
`configured` "Not started" — plus "From plugin <p>" for `source == "plugin"`; trailing switch (`enabled`), disabled for
plugin servers (the gateway answers 409 for them, `AG/hermes_cli/web_routers/mcp.py:380-386`). Empty: "No connectors
yet. Add them in Hermes on your computer." Footer: "Changes apply to new chats." Status refresh: on appear and every
10 s while shown (cached on the gateway, never probes, `C/tools_mcp_plugins.py:419-420`).

Switch: optimistic, haptic `selection`, then

```
PUT /api/mcp/servers/github/enabled?profile=ivy   {"enabled":false}   → {"ok":true,"name":"github","enabled":false}
{"method":"reload.mcp","params":{"confirm":true}}   → {"status":"reloaded",…}
```

**DECISION (write route):** the web rewrites the profile's whole `mcp_servers` map with `PUT /api/mcp/servers`
(`V/app/capabilities/mcp/use-mcp-servers.ts:225-235,315-320`), which can clobber a concurrent edit and must round-trip
redacted secrets. The gateway's own one-key route (`AG/hermes_cli/web_routers/mcp.py:372-394`) changes only `enabled`.
Then `reload.mcp {"confirm": true}` as the web's `silentReload` does (`use-mcp-servers.ts:148-158`) — **no `profile`
and no `session_id`** (`ReloadMcpParams` has no `profile`; 4000 otherwise). Failure (non-2xx, 409, 404) → flip back,
alert "Couldn’t Change <name>" with the gateway's `detail`.

Hosted (Nous) connectors: none this round (§1.2); do not call `connectors.*`.

---

## 10. Wire reference (complete key lists — send nothing else)

### 10.1 JSON-RPC

| Method | Params sent | Result read | Errors | Source |
| --- | --- | --- | --- | --- |
| `profiles.list` | `{"include_sessions": false}` | `profiles[].name, description, display_name, ui_meta, ui_meta_revisions, has_avatar`; top-level `bot_mode_protocol` | 5061 | `C/profiles_vault_complete_foreign_subagents.py:171-185`; `AG/…/methods_profiles.py:282-300` |
| `profiles.configure` | `{"name", "ui_meta"?, "ui_meta_expected_revisions"?, "description"?}` | `ok, applied.{ui_meta, ui_meta_revisions, ui_meta_conflicts, description}` | 4063 name required, 4064 not found, 5064 | `C/…:269-314`; `AG/…/methods_profiles.py:385-408,593-645` |
| `profiles.set_asset` | `{"name","asset":"avatar","data"}` or `{"name","asset":"avatar","clear":true}` | `ok, asset, size, removed?` | 4063, 4066, 4067, 4068, 4069 (>2 MB), 4070, 5065 | `C/…:317-334`; `AG/…:411-446` |
| `profiles.get_asset` | `{"name","asset":"avatar"}` | `found, mime?, size?, data?` | 5066 | `C/…:337-352`; `AG/…:449-463` |
| `profiles.create` | `{"name","description","clone_from","no_skills","share_auth","soul"}` | `ok, name, path, soul_written, model_set, mirrored` | 4061, 4062 (exists/invalid), 5062 | `C/…:188-225`; `AG/…:305-345` |
| `setup.runtime_check` | `{"profile"}` | `ok, error?` | — | `C/config_free_tier_control.py:137-155` |
| `session.list` / `session.create` / `session.title` | as `SP02` §2.5 | | | `SP02` §2.5 |
| `mcp.servers.list` / `mcp.servers.status` | `{"profile"}` | §9.2 | | `C/tools_mcp_plugins.py:384-420` |
| `reload.mcp` | `{"confirm": true}` | `status` | | `C/tools_mcp_plugins.py:112-137` |

### 10.2 REST (all with `?profile=<bot>` unless noted; session auth as `SP01` §8)

| Call | Body | Answer | Source |
| --- | --- | --- | --- |
| `GET /api/status` (no profile) | — | `version, release_date, …` | `SP01` §4.2 |
| `GET /api/sessions/<id>[?profile=<p>]` (other gateways, their own session) | — | session row | `AG/hermes_cli/web_routers/sessions.py:562-582` |
| `GET /api/skills` | — | `SkillInfo[]` | `AG/…/skills.py:343-376` |
| `PUT /api/skills/toggle` | `{"name","enabled"}` | `{ok,name,enabled}` | `:379-394` |
| `GET /api/skills/content?name=` | — | `{name,content,path}` (404 unknown) | `:397-415` |
| `GET /api/skills/hub/official` | — | `{skills:[OfficialSkillInfo]}` (502 on failure) | `:123-145` |
| `POST /api/skills/hub/install` | `{"identifier"}` | `{ok,pid,name}` | `:97-103` |
| `POST /api/skills/hub/uninstall` | `{"name"}` | `{ok,pid,name}` | `:106-112` |
| `GET /api/actions/<name>/status?lines=200` | — | `{name,running,exit_code,pid,lines}` (404 unknown) | `AG/…/actions.py:366-420` |
| `PUT /api/mcp/servers/<name>/enabled` | `{"enabled"}` | `{ok,name,enabled}` (404, 409, 400) | `AG/…/mcp.py:372-394` |

---

## 11. State rules summary

| State | Where | Lifetime |
| --- | --- | --- |
| Saved gateways, labels, sessions | Keychain (`SP01` §2.4.1) | until removed |
| Appearance | `UserDefaults hqn.appearance` | device |
| Completion Sound | `UserDefaults hqn.completionSoundOn` | device |
| My Style | `UserDefaults hqn.head.style` (JSON head) | device |
| Sections, meta snapshot, tile order, unread, head overlay | `botstate-<accountKey>.json` | per gateway account, purged on remove/sign-out |
| Write fence, per-bot write queue, pending section deletes, other-gateway news, skill install polls | memory | app run |
| Pins, hidden, section membership, title, description, heads, skills on/off, MCP on/off | the gateway | shared with every client |

Rules: one write per bot at a time (§2.2.1); fence 60 s (§2.4); head overlay by revision (§7.5); local patch before
the wire, rollback on failure; no automatic writes; `readOnlyGateway` refuses every write in this spec.

### 11.1 UI states checklist (every screen in this spec)

| Screen | States the builder must draw |
| --- | --- |
| Settings root | normal; gateway card Connecting… / Reconnecting… / Offline / Signed Out (dot + words, §3.3); version unknown (piece omitted); Tool Calls row absent (no hook); Completion Sound row absent (cue not wired) |
| Gateway page | one account (footer "Add another gateway…"); several; a row "Switching…"; a row "Signed Out"; Edit mode; failure footer (switch / rename / remove); Sign Out confirm |
| Title switcher | one account (plain title); ≥ 2 (chevron + gateway subtitle); news dot; "Switching to X…"; link problem ("Offline · X"); menu rows In Use / Signed Out / N New / 9+ New |
| Bots list | section with rows; empty user section + hint (only without search); Pinned section shown/hidden by the 6-tile rule; Hidden · N collapsed/expanded; drag in progress (target highlighted); Undo pill (Hidden / Deleted section) |
| Row menu | normal bot; pinned bot (Unpin, home section checked); hidden bot (Show in Bots first level); bot with no section (no "Remove from Section"); gateway offline (write items still listed; the write fails with the alert) |
| Bot Info | online; offline (Organize rows dimmed + footer, Edit disabled); no description (About row omitted) |
| Edit Bot | pristine (Save disabled); dirty; saving ("Saving…", fields disabled); title failure / description failure (alert, page stays); discard sheet; "Head saved…" note |
| Edit Head | pristine; dirty; saving (controls disabled); conflict notice; unsupported notice; generic failure notice; non-Shapes head note; unsaved head (no Reset Head); Undo enabled/disabled; My Style unset (Use disabled) |
| New Bot | empty (Create disabled); invalid name (Create disabled); taken (inline text); creating ("Creating…"); create error (inline message for 4062, alert otherwise); success → chat; no-model notice in the chat |
| Skills | first load (3 skeleton rows, `S/settings-ios-list.tsx:471`); waiting for the gateway ("Waiting for your gateway…", `:466-469`); list; no matches for the search ("No Results for “…”"); load error with Try again; switch busy; installing (spinner on Get); install blocked / failed alert; skill page loading / error |
| Connectors | first load; list; empty ("No connectors yet…"); load error with Try again; plugin row (switch disabled); switch failure alert |

---

## 12. Stand-in gateways (this stream's ports: 9738, 9739, 9740)

No committed fixture implements `profiles.configure` with real compare-and-swap, `profiles.create`, skills, actions or
MCP status (the demo gateway's `profiles.configure` is a stub that always answers revision 2 and stores nothing,
`/Users/me/Projects/hermes-ios-release178/.build/demo/demo-gateway.py:216`). The builder writes one.

### 12.1 `NAT/scripts/fixtures/settings-gateway.py` (new; stdlib only; loopback only)

- Loads `FX/action-voice-fixture-gateway.py` by absolute path with `importlib` (as `FX/build47-fixture-gateway.py:12-13`
  does; never copy or edit anything in ref238). Inherits its password sign-in, `--hermes-cookies`, `--label`,
  `--credentials` (0600), `/api/ws`. Replaces `voice.rpc` and wraps `voice.handler`; installs its own websocket loop
  (copy of `FX/action-voice-fixture-gateway.py:85-123`) that keeps a client registry so it can emit events.
- **State** (in memory, reset by `/__settings/reset`): six profiles —

  | profile | `hermes-bots` | `dispatch-head` | revisions | chat |
  | --- | --- | --- | --- | --- |
  | `default` | `{pinned:true, sectionId:"hermes-hq-pinned", sectionName:"Pinned", pinnedFrom:null}` | shape ink round ovals | hb 3, head 2 | 4 msgs |
  | `ivy` | `{sectionId:"sec-work", sectionName:"Work", created:1790000000001}` | — (default) | hb 1 | 6 msgs |
  | `research` | `{sectionId:"sec-work", sectionName:"Work", title:"Research"}` | shape lilac hex slits | hb 1, head 1 | 3 msgs |
  | `inbox` | `{pinned:true}` (not reconciled) | — | hb 1 | 2 msgs |
  | `deploys` | `{hidden:true}` | — | hb 1 | 2 msgs |
  | `notes` | none | none | `{}` | none (`message_count` 0) |

  With `--label X` every display name and the description get the prefix "X " (multi-gateway checks). Skills per
  profile: 6 installed (mixed `provenance`, two disabled), 4 official (2 installed); MCP: `github` (config, connected,
  31 tools), `files` (config, disabled), `browser` (plugin `hermes-hq-browser`, connected).
- **RPC** (each implemented method checks its params against the §10.1 key list and answers
  `{"code":4000,"message":"invalid params for <m>: <key>: Extra inputs are not permitted"}` for any other key):
  `profiles.list` (rows as Hermes: `name, path, is_default, model, provider, description, display_name, skill_count,
  previous_names, canonical_session/last_session` when `include_sessions` is not false, `ui_meta_revisions` always,
  `ui_meta` when non-empty, `has_avatar`; top level `bot_mode_protocol:true`); `profiles.configure` — a line-for-line port
  of `_configure_ui_meta` (`AG/tui_gateway/methods_profiles.py:593-645`: 64 KB cap, per-key CAS, any mismatch writes
  nothing, `null` deletes, revisions survive deletion) plus `description`; `profiles.set_asset` / `get_asset` (PNG/JPEG/WebP
  magic, ≤ 2,000,000 bytes, error codes as §10.1); `profiles.create` (4062 if the name exists or fails
  `^[a-z0-9][a-z0-9_-]{0,63}$`; new profile gets a description and no chat); `setup.runtime_check`; `session.list` title
  lookup, `session.create`, `session.title`, `session.resume`/`activate` for every profile's chat;
  `prompt.submit` → ack `{"status":"streaming"}`, then 0.5 s later `message.start`, one `message.delta`
  ("Hi! I'm <display name>."), `message.complete {"text":…, "status":"complete"}` to sockets bound to that session, and
  the two rows stored; `mcp.servers.list` / `status`; `reload.mcp` (strict: rejects `profile`).
- **REST**: `GET /api/status` → `{"version":"0.21.5","release_date":"2026.10.01","auth_required":true,"desktop_contract":8}`;
  `GET /api/sessions/<id>` (store-backed `last_active`, `message_count`); `/api/sessions/<id>/messages`; the skills and
  actions routes of §10.2 (install/uninstall: `running:true` for two polls, then exit 0 with "Installed <name>", or the
  configured outcome); `PUT /api/mcp/servers/<name>/enabled` (404 unknown, 409 plugin).
- **Controls** (loopback, no auth, never under `/api/`):

  | Control | Effect |
  | --- | --- |
  | `GET /__settings/state` | `{writes:[{method, params (asset data replaced by its byte count)}], profiles:{name:{ui_meta, revisions, description, has_avatar, avatar_size}}, prompts:[…], rest:[…]}` |
  | `POST /__settings/desktop-edit {"profile","key","value"}` | another device writes one `ui_meta` key (revision + 1) |
  | `POST /__settings/bump {"profile"}` | new activity on that bot's chat: `last_active = now`, `message_count += 2`, new preview |
  | `POST /__settings/fail {"method","mode","count"}` | next `count` calls of `method` fail: `error` (RPC 5064 "disk full"), `applied-false` (`{"ok":false,"applied":{"ui_meta":false}}`), `no-applied` (`{"ok":true}`), `slow` (answer after 35 s) |
  | `POST /__settings/install-outcome {"identifier","exit","lines"}` | the next install of `identifier` ends with that exit code and log |
  | `POST /__settings/runtime {"ok":false,"error":"No provider"}` | next `setup.runtime_check` answer |
  | `POST /__settings/reset` | back to the seed |

### 12.2 Configurations and exact commands

Check the port is free first; start in the background; keep the PID; stop only your own PIDs when done. Use a fresh
0700 scratch directory (`SCR`) for credentials and logs. Never point anything at 100.101.102.104 or `*.ts.net`.

**Config A — one gateway (every bot, Edit Head, New Bot, Capabilities check):**

```sh
SCR=$(mktemp -d "${TMPDIR:-/private/tmp}/hqn-settings.XXXXXX"); chmod 700 "$SCR"
lsof -nP -iTCP:9738 -sTCP:LISTEN && echo "9738 busy — stop" && exit 1
cd /Users/me/Projects/hermes-hq-native
python3 scripts/fixtures/settings-gateway.py --port 9738 --hermes-cookies --credentials "$SCR/a.json" >"$SCR/a.log" 2>&1 &
echo $! > "$SCR/a.pid"
# sign the simulator in (Debug builds only): SIMCTL_CHILD_HQN_SIGNIN_URL=http://127.0.0.1:9738 plus
# SIMCTL_CHILD_HQN_SIGNIN_USERNAME / _PASSWORD read from $SCR/a.json (NAT/HermesKit/Net/SignInService.swift:219-226)
curl -s http://127.0.0.1:9738/__settings/state | python3 -m json.tool | head
kill "$(cat "$SCR/a.pid")"
```

**Config B — two password gateways (switcher, news dots, rename, remove):** A as above on 9738, plus

```sh
lsof -nP -iTCP:9739 -sTCP:LISTEN && exit 1
python3 scripts/fixtures/settings-gateway.py --port 9739 --label Beta --credentials "$SCR/b.json" >"$SCR/b.log" 2>&1 &
echo $! > "$SCR/b.pid"
curl -s -X POST http://127.0.0.1:9739/__settings/bump -H 'Content-Type: application/json' -d '{"profile":"ivy"}'
```

Both fixtures use the same session ids on purpose (`FX/action-voice-fixture-gateway.py:21-23`): a cache keyed only by
session id would leak one gateway's chat into the other.

**Config C — password gateway + Sign in with Nous gateway (labels, switch to/from Nous, parked renewal):** A on 9738,
plus the Nous fixture (unchanged, from ref238; writes nothing into the repo):

```sh
lsof -nP -iTCP:9739 -sTCP:LISTEN && exit 1; lsof -nP -iTCP:9740 -sTCP:LISTEN && exit 1
cd /Users/me/Projects/hermes-hq-native-ref238
python3 scripts/nous-fixture-gateway.py --port 9739 --portal-port 9740 \
  --public-url http://127.0.0.1:9739 --access-ttl 30 >"$SCR/nous.log" 2>&1 &
echo $! > "$SCR/nous.pid"
curl -s http://127.0.0.1:9739/__fixture/nous            # counts, live tokens
curl -s -X POST http://127.0.0.1:9739/__fixture/nous/revoke   # make the parked Nous account "Signed Out"/expired
```

(Recipe and flags: `SP05` A6, `FX/nous-fixture-gateway.py:1-19,330-349`.) Config B and C both use 9739: run one at a
time.

---

## 13. Acceptance checks (builder must pass all; fixtures only — never the owner's gateway)

Unit tests (Swift Testing):

- U1 `pinPatch`, `pinnedSectionPatch`, `sectionMovePatch`, `undoOf`, `shownSectionId` — every vector in
  `S/ui-bots/pinned-section-model.test.ts`.
- U2 Write outcome mapping (§2.2 step 5 table) and rollback values.
- U3 Fence: a roster issued before a write doesn't change that bot's meta; one issued after does; stamps > 60 s ignored.
- U4 `slugifyProfileName`, `botProfileIdentity`, `descriptionText`, `composeSoul` (with/without title/description).
- U5 `friendlyName` / gateway row title+subtitle — vectors from `S/connection-offline.test.ts`, `S/gateway-accounts.test.ts`;
  Nous → "Nous account".
- U6 News count — vectors from `S/gateway-switcher.test.ts` (marked, baseline, `message_count` 0, missing baseline,
  hidden, 40 cap).
- U7 Head record: `storedHead` of a default head and of an edited one equal the JSON in §7.5; `parseHead` round trip;
  `hat` always "none"; 288×288 IHDR check (true/false cases); `rollHead`/`ideasFor` with a fixed seed match the web
  (generate expected values by running `S/ui-heads/head.ts` logic in a throwaway Node script in the scratchpad, never
  in either repo).
- U8 Install-blocked parsing — both message shapes.
- U9 Params allow-lists: encoding each call in §10.1 produces exactly those keys (`reload.mcp` has no `profile`).

Simulator end-to-end (UITests or driven by hand, with `/__settings/state` as evidence):

| # | Fixture | Do | Expect |
| --- | --- | --- | --- |
| S1 | A | Pin Ivy from its menu | Ivy becomes a tile in the same frame; one `profiles.configure` whose `hermes-bots` equals the §5.2 example (plus `created`); state shows revision +1 |
| S2 | A | Unpin Ivy | back under Work; write `pinned:false, sectionId:"sec-work", sectionName:"Work", pinnedFrom:false` |
| S3 | A + `fail applied-false` | Pin Ivy | tile appears then goes back; alert "Couldn’t Pin Ivy" / "Your gateway didn’t save the change." with Show Details, Try Again, OK; Try Again succeeds |
| S4 | A + `fail slow` | Pin Ivy | after 30 s: rollback + alert; then an undo write is sent |
| S5 | A | `desktop-edit` Ivy `hermes-bots` to add `title:"Desk"`, then pin Ivy | the slim read happens first; the write contains `title:"Desk"` (not reverted) |
| S6 | A | Pin then Hide two different bots within 1 s, and Pin+Hide the same bot within 1 s | same-bot writes are sequential (state shows two writes, the second containing both changes) |
| S7 | A | Hide Deploys' neighbour Research | Research moves to Hidden · 2; Undo pill "Hidden · Undo" for 4 s; Undo restores; Show in Bots from a hidden row's first-level menu works |
| S8 | A | + › New Section… "Clients" | empty "Clients · 0" section with the hint; no write |
| S9 | A | Drag Ivy onto Clients | write `sectionId:<sec-…>, sectionName:"Clients"`; success haptic |
| S10 | A | Rename Work → "Office" | one write per member (Ivy, Research) with `sectionName:"Office"`, in order |
| S11 | A | Delete Office (2 bots) | confirm "Delete “Office”?" / "Its 2 bots move to Unassigned."; two writes clearing; Undo pill restores record and re-files both |
| S12 | A | Move pinned Default to Clients | write only `pinnedFrom:{id:<clients>,name:"Clients"}`; Default stays a tile |
| S13 | A | Bot Info › Edit › Title "Ivy the Scout", Description "Finds flights" › Save | one call with `ui_meta` + `description` (§6.3); row name/role update at once; back on Bot Info |
| S14 | A + `fail error` on configure | Edit Bot Save | page stays with text; alert "Couldn’t Save Changes" |
| S15 | A | Edit Head for Ivy: Hex + Ovals › Save | one CAS call exactly as §7.5 (expected 0); row/tile/Bot Info heads change immediately; a `set_asset` with a 288×288 PNG follows; Edit Bot note "Head saved…" |
| S16 | A | open Edit Head for Research; `desktop-edit` its `dispatch-head`; Save | notice "This bot’s head was changed on another device…"; second Save succeeds with expected = actual |
| S17 | A | Reset Head on Research | CAS with `null`; `get_asset`; `set_asset clear:true` only when the stored avatar is the 288 mirror |
| S18 | A | Edit Head: Shuffle, Undo, idea, Set/Use My Style, swipe down with changes | Undo restores; discard sheet appears; My Style keeps colour and seed |
| S19 | A | New Bot "Inbox Triage", description "Sorts my email" | `profiles.create` params exactly §8.2; meta write; runtime check; registry lookup + `session.create` + `session.title`; chat opens; "Hey, tell me about yourself!" sent once; reply streams |
| S20 | A + `runtime ok:false` | New Bot "Notes 2" | no intro; the notice row shows |
| S21 | A | New Bot "Ivy" | Create disabled; `An agent named "ivy" already exists.` |
| S22 | A | Capabilities › Skills (Ivy): turn one off; install an official skill; `install-outcome` exit 1 with a scan-block line, install another | toggle PUT + re-read; install polls every 1.2 s, row moves; blocked alert text as §9.1 |
| S23 | A | Capabilities › Connectors (Ivy): turn `files` on; try `browser` | PUT enabled + `reload.mcp {"confirm":true}` (no other keys); plugin row's switch disabled |
| S24 | B | sign in to 9738 then Add Gateway… 9739 | 9739 becomes current; Bots title shows a chevron and "Beta…" subtitle; Gateway page lists two with a checkmark |
| S25 | B | on A, `bump ivy` on B; wait ≤ 3 min (or open the title menu) | news dot before the gateway name; menu row "1 New"; switching to Beta shows Ivy unread; the dot clears |
| S26 | B | switch from a pushed chat on the Sessions tab | lands on the Sessions list of the other gateway, no chat open, lists painted at once |
| S27 | B | Rename Beta → "Studio"; Remove it | names update in title, menu and page; Remove confirm text as §4.5; caches for that account gone (files deleted) |
| S28 | C | sign in to 9739 with Nous (Portal "Continue as owner"), then switch to 9738 | Nous row reads "Nous account"; after 30 s+ the news check renews the parked Nous token once (Nous fixture counts one refresh, no reuse revocation); switching back works without signing in |
| S29 | C | `nous/revoke`, open the title menu | Nous row subtitle "Signed Out" after the check (401 → 0); tapping it presents the prefilled Nous sign-in; Cancel stays on 9738 |
| S30 | A | Settings: Appearance Dark/Light/System; Completion Sound off then a reply finishes | whole app follows instantly and after relaunch; no cue when off, one cue when on |
| S31 | A | Settings root at every Dynamic Type size incl. AX5 | no clipped text; Capabilities segments whole or the pull-down fallback |
| S32 | A with `readOnlyGateway` on | any write action | nothing sent (`/__settings/state.writes` unchanged), alert says changes are off |
| S33 | — | VoiceOver pass over Settings, the title switcher, menus and Edit Head strips | every control labelled (§4.6 label; strip items read their option names) |
| S34 | A (+ pages stream's Kanban probe) | Settings › Appearance › Tabs › Kanban Tab → Off, then Automatic (no Kanban Tab row on the root) | `UserDefaults pages.kanbanTab.override.<account>` = `off` then `auto`; row absent when the probe says "absent"; no gateway call (UITests `testS34`, `testS41`) |

Owner-facing check before TestFlight: screenshots of Settings, Gateway page, the title menu with a dot, Bot Info,
Edit Bot, Edit Head (light and dark) — the owner inspects every sibling surface (`MEM/liquid-glass.md`: "sweep ALL
siblings of a reported element … before shipping").

---

## 14. Contract and module changes

`HermesKit/Contracts.swift` (integration owns it):

```swift
// Bot: + var sectionId: String?       // meta.sectionId as stored (may be "hermes-hq-pinned")
//      + var homeSectionId: String?   // shownSectionId(meta, sectionId)
//      + var isDefault: Bool
//      + var headRevision: Int         // ui_meta_revisions["dispatch-head"] ?? 0 (overlay applied)
// RosterProfile (RosterWire.swift): + var uiMetaRevisions: [String: Int]

protocol BotEditing: AnyObject {            // StoreBotEditing over BotStore (App/Settings/AppModel+Settings.swift)
    func setPinned(_ bot: Bot, _ pinned: Bool) async throws
    func setHidden(_ bot: Bot, _ hidden: Bool) async throws
    func move(_ bot: Bot, toSection id: String?) async throws
    func appendSection(named: String) -> RosterSectionRecord          // local; filing a bot is a separate `move`
    func renameSection(_ id: String, to name: String) async throws
    func moveSection(_ id: String, by delta: Int)
    func memberCount(ofSection id: String) -> Int                     // hidden members included
    func beginDeleteSection(_ id: String) throws -> SectionDeletion?  // local half: record gone, Undo can show
    func finishDeleteSection(_ deletion: SectionDeletion) async throws
    func undoDeleteSection(_ deletion: SectionDeletion)
    func saveEdit(_ bot: Bot, title: String?, description: String?) async throws -> EditOutcome
    func saveHead(_ bot: Bot, record: JSONValue?, revision: Int) async throws -> Int   // HeadSaveError.conflict(actual:)
    func createBot(name: String, title: String, description: String) async throws -> NewBotResult
}
protocol GatewayAccounts: AnyObject {       // AppModel + GatewaySwitcherModel
    var accounts: [GatewayAccountRow] { get }     // title, subtitle, isCurrent, hasSession, news
    var otherNews: Int { get }
    func switchTo(_ id: String) async throws; func rename(_ id: String, _ label: String?) throws
    func remove(_ id: String) async throws; func checkSoon()
    var onChange: (() -> Void)? { get set }
}
protocol CapabilitiesService: AnyObject {
    func skills(_ profile: String) async throws -> [SkillInfo]
    func officialSkills(_ profile: String) async throws -> [OfficialSkill]
    func skillContent(_ name: String, profile: String) async throws -> String
    func setSkill(_ name: String, enabled: Bool, profile: String) async throws
    func install(_ identifier: String, profile: String) -> AsyncThrowingStream<ActionStatus, Error>
    func uninstall(_ name: String, profile: String) -> AsyncThrowingStream<ActionStatus, Error>
    func mcpServers(_ profile: String) async throws -> [McpServer]
    func setMcp(_ name: String, enabled: Bool, profile: String) async throws
}
// AppServices: + var botEditing: BotEditing, var gateways: GatewayAccounts, var capabilities: CapabilitiesService
```

New/changed files (suggested): `HermesKit/Store/BotMetaWriter.swift`, `HermesKit/Store/GatewaySwitcherModel.swift`,
`HermesKit/Net/AccountProbe.swift` (REST-only other-account client), `HermesKit/Model/PinnedSection.swift`,
`HermesKit/Model/BotIdentity.swift` (slug, soul), `App/Settings/*`, `App/BotInfo/*`, `App/Heads/EditHead*.swift`,
`App/Bots/NewBotViewController.swift`, `App/Capabilities/*`, `App/Kit/UndoPill.swift`, `App/Kit/FailureAlert.swift`,
`App/Audio/CompletionCue.swift`. Changed: `BotStore` (fence, writer, layout-driven sections, overlay),
`RosterLayout` (meta merge), `BotsViewController` (menu, swipes, drag, compose, empty sections, switcher),
`SessionsViewController` (switcher), `MainTabController` (switch reset), `AppModel` (switch, add, remove, services),
`SceneDelegate` (appearance before first frame). Remove `AccountViewController`.

Coordination hooks for other streams: `SettingsHooks` (§3.6–3.7), `BotMenuHooks` (§5.1), `BotInfoHooks` (§6.1),
`SettingsScreens` (§3.1). The chat stream opens Bot Info from the chat header with `BotInfoSheet.present(bot:from:)`.

---

## 15. Owner's approved behaviour and rejections that apply here

- Gateways: title switcher + news dots (`MEM/gateway-switcher.md`, picked "A + unread dots"); land on the page you
  switched from (build 111); names given on the phone show everywhere (build 113).
- Pins file into "Pinned" so desktop matches the tiles, including desktop pins; Pinned shows only when pins overflow 6
  tiles (`MEM/pinned-section.md`). Phone→desktop sync of pins and sections works and is enough (`MEM/bot-layout-sync.md`:
  "Owner confirmed 'it all works' and decided nothing more is needed").
- Drag rows onto sections (`MEM/row-drag-sections.md`). Hidden bots have a way back (`MEM/bot-unhide.md`).
- Bot Info/Edit Bot/Edit Head as pages in one sheet (`MEM/sheet-pages.md`); a save must visibly change the picture
  (`MEM/head-save-ux.md`).
- 24 Shapes colours in a grid, 6 per row; heads default to plain Shapes with slit eyes; eyes white on light pages, black
  on dark; the desktop copy stays white-eyed (`MEM/blob-colors-theme-grid.md`, `MEM/default-shape-heads.md`).
- Rejected: CSS/fake glass (`MEM/liquid-glass.md`: "It isn't Liquid Glass"); hats (`MEM/new-bot-style-no-hats.md`);
  redrawn heads and the Character theme (`MEM/bot-head-redraw-proposal.md`: "the original robots are 100x better");
  tab-bar bottom accessory; controls that do nothing (`MEM/glitch-sweep.md`); cut-off segment labels
  (`MEM/segmented-labels-whole.md`); cramped wrapping rows (`MEM/row-padding-feedback.md`).
- Haptics map (`MEM/taptic-feedback-gaps.md`, `SP06` §9): `selection` for picks/toggles/switch menu; `notification.success`
  for Move to Section, saves, rename, remove, install done; `notification.error` for failures; drop = `impact(.light)`;
  silent for opening/closing sheets and menus.
- API keys: never typed into apps by an agent (`MEM/composio-connectors.md`: "I must not type the owner's API keys into
  apps") — another reason Connect Apps is out.

---

## 16. DECISIONs, disagreements and UNKNOWNs

**DECISIONs (each explained where it appears):** serialised per-bot writes (§2.2.1); local patch before the fresh read
(§2.2.2); slim fresh read instead of the full roster (§2.2.3); "unsupported" treated as failed (§2.2.5); no roster refetch after a save (§2.5); sign-out copy
(§3.4); no haptics switch (§1.2); signed-out target keeps you on the current gateway until sign-in (§4.4.2); title
menu via `titleMenuProvider` with a subtitle-view fallback (§4.6); trailing swipe = Info (§5.1); Pinned header without ⋯
(§5.4); description via `profiles.configure` (§6.3); Edit Bot sends only `title` (§6.3); non-Shapes heads converted on
save with a note (§7.2); `hat` written "none" (§7.6); New Bot notice wording without "Advanced" (§8.2.7); MCP switch
via the one-key route + `reload.mcp {"confirm":true}` (§9.2).

**Disagreements found (comment vs code, or web vs gateway):**

1. `HB/edit-profile-dialog.tsx:132-145` writes the description with `cli.exec … --text`; an empty text is a read, not a
   clear (`AG/hermes_cli/profile_cmd.py:328-343`). The web can't clear a description.
2. `S/ui-bots/meta-save.ts:1-4` says a request that never reached the gateway "reads like an older gateway's
   rejection" — fixed only by the stress-a gate (`B/stress-a-gates.ts:11-28`); read the gate, not the vendored file.
3. `HB/canonical-chat.ts:638-650`: `ensureBotMetadata` returns local meta for an un-scoped row and does a full
   `profiles.list {}` for a source-scoped one; on the phone rows are annotated source-scoped (`HB/data.ts:908-923`),
   so every pin pays a full roster read.
4. The demo gateway's `profiles.configure` answers revision 2 for every key and stores nothing
   (`…/demo-gateway.py:216`) — useless for CAS tests (hence §12.1).
5. `S/gateway-switcher.ts:118-123` caches a parked gateway's chats per page load; native caches per app run until the
   saved accounts change (same effect: parked data can't change while parked).

**UNKNOWNs:**

1. Whether `UINavigationItem.titleMenuProvider` shows its menu with `largeTitleDisplayMode = .inline` on iOS 26 — verify
   on the simulator before building the fallback (§4.6).
2. Whether `UIContextMenuInteraction.updateVisibleMenu` is reachable for a title menu (live "N New" while open).
3. The exact reverb impulse of the web's cue (`makeReverb` in `V/lib/completion-sound.ts`) — the native wet path is an
   approximation; the owner judges by ear.
4. Which skin and mode the owner uses on the web app (`SP06` §13 item 1); native Appearance starts at System.
5. The pages stream plans a More tab this round (`1x-pages.md` §1.2) that pushes `SettingsScreens`; if it doesn't land,
   the Bots bar's Settings button is the only way in (§3.1 covers both). Its header fix for "too far from the top" is
   owned elsewhere; the title switcher (§4.6) must use whatever title treatment that fix lands with.
