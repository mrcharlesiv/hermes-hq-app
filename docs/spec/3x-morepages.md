# 3x — More tab pages and navigation chrome (m9 stream `morepages`)

Written 2026-10-12 by the spec writer for stream `morepages` (worktree
`/Users/me/Projects/hermes-hq-native-wt/m9-morepages`, branch `m9/morepages`, cut from `m9/train` at `beee9f7`).
The owner was asleep; every call made without them is marked **DECISION**.

Path shorthands (as the earlier specs use them):

| Short | Means |
|---|---|
| `S/` | `/Users/me/Projects/hermes-hq-native-ref240/src/` (the web phone app, build 240) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref240/build/` (the gates that patch the vendored renderer) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref240/vendor/hermes/apps/desktop/src/` (vendored desktop renderer) |
| `AG/` | `/Users/me/.hermes/hermes-agent/` (the real gateway source, READ ONLY) |
| `NAT/` | this worktree |
| `MEM/` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` |

The 12 rows this stream owns are in `docs/briefs/m9/assignment.md` § morepages and, verbatim with outcomes, in
`docs/briefs/m9/morepages-rows.md`.

---

## 0. Summary, build order and decisions

### 0.1 What ships, in what order (one feature per build)

Small, certain things first, so each build is easy to feel on the phone. Every unit is one TestFlight build.

| # | Unit | Rows | Size |
|---|---|---|---|
| U1 | Artifacts: a repeated file shows "×N" | L688 | S |
| U2 | Artifacts text viewer: linked notes open in place, Back steps through them | L699 | M |
| U3 | Kanban task: Add Attachment | L673 | M |
| U4 | Search behind the magnifier on Jobs, Kanban, Artifacts and Capabilities; the typed search stays across tabs | L858 | M |
| U5 | Bots: "All Bots Are Hidden" | L878 (and that state of groups' L207) | S |
| U6 | Open-Source Licenses lists everything the native app ships | L879 | S |
| U7 | Quick-action tiles (kit) and Bot Info's tiles on it | L865 | S |
| U8 | Hardware-keyboard Escape rule | L864 | S |
| U9 | More › Bot Profiles, with the SOUL.md editor and its Cancel/Save bar | L872 (part), L862 | L |
| U10 | More › Files and Review | L872 (part) | M |
| U11 | More › Messaging | L872 (part) | L |
| U12 | More › Webhooks | L872 (part) | M |
| U13 | More › Import Sessions | L872 (part) | M |
| U14 | More › Status & Maintenance (was Command Center) and More › Usage | L872 (part) | M |
| U15 | More › Spawn Tree | L872 (part) | M |
| U16 | More › Star Map | L872 (part) | L |
| U17 | More search (the command palette) | L874 | M |
| — | Bottom accessory over the tab bar | L852 | not built: the owner rejected it (§1) |

L872 counts as done only when U9–U16 are all on the train and each was seen working.

### 0.2 Decisions

| # | DECISION | Why |
|---|---|---|
| D-M1 | **The bottom accessory over the tab bar (L852) is not built.** The row is recorded "not built: rejected by the owner"; one plain question goes to `docs/owner-todo/morepages.md`. | `MEM/liquid-glass-more.md`: "tab-bar accessory bubble ("Inbox · Working…") REJECTED: covered the list and its tap didn't open the chat on the real phone … Removed … **Don't re-add an accessory without asking.**" The web app itself has had none since build 196; `S/phone-tab-bar.tsx:916` only keeps the empty stack host. `NAT/App/Pages/PageKit.swift:1-3` already says HUD and Undo are "never a tab-bar accessory". |
| D-M2 | Artifact rows show "×N" when a file or link was named more than once in the same chat. This replaces 1x-pages D-P12 ("no ×N badge"). | The owner asked for every open row to be finished. The web designed and styled the badge (`S/ui-pages/artifact-list.tsx:32-43,97`) and a later change (`S/ui-pages/artifacts-model.ts:4-11`, same key) made every count 1 by accident. The count is cheap and true natively: the collector already drops the repeats (`NAT/HermesKit/Pages/ArtifactCollector.swift` `found[key]`). |
| D-M3 | Linked notes are **pushed pages** on the tab's navigation stack, not a private stack inside one sheet. | The native text viewer is already a pushed page (`NAT/App/Pages/Artifacts/ArtifactTextViewController.swift:1-3`). UIKit then gives the back stack, the "‹ <previous note>" label and hold-Back-to-list for free, which is exactly what `S/artifact-text-sheet.tsx:125-127` builds by hand. |
| D-M4 | Linked notes are read-only and are always read "scoped" (`/api/fs/download` with the artifact's `session_id` and `profile`). | The native viewer never edits (1x-pages §8). The web's unscoped branch exists only to allow editing through the active profile's plain route (`S/artifact-text-sheet.tsx:54-56`). So the Discard question (`:57-60,160`) has nothing to guard and is not ported. |
| D-M5 | Kanban Add Attachment offers **Photo Library** and **Choose File** (a menu on the row); the web has one file input. One file per pick. The limit is checked on the phone before upload (25 MB) and the gateway's 413 is still handled. | The web's `<input type=file>` on iOS shows the system's own Photo Library / Take Photo / Choose Files menu; the native equivalent is `PHPickerViewController` and `UIDocumentPickerViewController`, which the composer already wraps (`NAT/App/Chat/Attachments/AttachmentPickerCoordinator.swift`). Camera is left out: it needs the camera usage string, which the photoheads/talk streams own. Builder: read `KANBAN_ATTACHMENT_MAX_BYTES` in `AG/` (`grep -rn KANBAN_ATTACHMENT_MAX_BYTES AG/hermes_cli AG/plugins`) and use that number instead of 25 MB if it differs. |
| D-M6 | Search mode: every list page folds its search behind the bar magnifier through `PageBarCapsule`. Kanban too (the web left Kanban's field in its board row). | `MEM/search-magnifier.md`: owner, "takes up so much space"; 1x-pages D-P11 already chose the magnifier for Kanban. |
| D-M7 | Escape: on a tab root it only ends that page's search; with a sheet, alert, menu or the media viewer up it closes that; on a pushed page it goes Back; in a chat with text being typed it does nothing. Never closes a tab root, never leaves the tab. | `S/ui-nav/root-escape.ts:1-16`. The web's rule covers only Jobs and Artifacts because the desktop renderer's Escape closed those pages; natively the same rule is stated for every tab root. |
| D-M8 | "Open-Source Licenses, complete" means everything the **native** app ships, not the web app's 342 npm packages. | The web list is "every package whose code or assets are in the bundle" (`B/license-notices.ts:6-10`). None of those are in the native binary. Listing them would be false. |
| D-M9 | Profiles is titled **Bot Profiles** in More and on its page; rows show the bot's display name with the profile id under it. New Profile is not offered here: Bots › New Bot is the one way to make a bot. | `S/ui-nav/more-model.ts:32` (`profiles:'Bot Profiles'`). A profile made here would have no Bot title, head or messaging section; New Bot writes all three (`NAT/HermesKit/Store/BotStore+Editing.swift:675-681`). No dead or half-working control (`MEM/glitch-sweep.md`). |
| D-M10 | Files and Review reuse the chat's workspace pages (`WorkspacePage`), read-only: browse, view text, see a diff, Share. No editing, staging, commit, push or pull-request from the phone in this round. | The owner's rule is one feature per build; the read-only pages already exist and are tested (`NAT/App/Chat/Menus/WorkspacePages.swift`). Git writes from a phone are destructive and need their own build with their own stress round. Listed as a known gap in the report, not hidden. |
| D-M11 | Messaging covers: the platform list with status, a platform's settings (its keys, on/off, Test), who may message the bot (approve / remove), and Telegram's "Set Up with Telegram" link flow. WhatsApp's QR flow is not built (the web has none either: only `V/app/messaging/telegram-qr-setup.tsx` exists). | Parity with what build 240 can do. |
| D-M12 | The web's Command Center is one page, **Status & Maintenance**: the System part first, then Maintenance, as sections with headers, no tabs. Its Usage part is a More row of its own, **Usage**. The web's fourth part, Sessions, is not ported. | It was three segments (System · Usage · Maintenance) until owner 2026-11-03: one home per page, and tabs only flip between lists of one kind, never hold different jobs. Usage is not another usage page: it is the gateway's whole history (7 / 30 / 90 days, every bot), which neither the chat's Usage & Limits (this chat's plan allowances) nor its Full Usage Report (this chat's /usage) shows. Sessions is a second copy of the Sessions tab (search, pin, manage: `V/i18n/en.ts` commandCenter.panels.sessions), which the phone already has as a tab. |
| D-M13 | Spawn Tree reads the gateway's own list of running subagents (`delegation.status`), per bot, refreshed every 3 s while on screen. Read-only (tap a row to open its chat); no Steer, no Stop, no pause switch here. | The web's page shows only subagents of turns this client happened to be streaming (`V/app/agents/index.tsx:85` `$subagentsBySession`), which on a phone is usually nothing. The gateway call shows what is really running. Steer/Stop live in the chat's subagent card (activity stream). |
| D-M14 | Star Map is a native drawn map (SwiftUI `Canvas`, pan and pinch) with a **List** switch beside it and a node sheet. Map codes (share/import), the timeline scrubber and editing or deleting a memory are not built. | The web page is a 3,900-line canvas simulation (`V/app/starmap/*`). The map and what a star says are the feature; the rest are desktop extras. Deleting a memory from a phone by a slip of the thumb is not worth the risk in a first build. Known gap, recorded. |
| D-M15 | More search lists, in this order: **Go To** (every More page and tab), **Bots**, **Sessions**, **Settings**, **Actions**. Desktop-only rows are left out. | `S/settings-ios-list.tsx:321-359` (`PHONE_HIDDEN`, `phoneGoTo`, `phonePaletteGroups`). |
| D-M16 | Connect Apps stays where capabilities puts it; this stream adds no row for it. Insights' and Integrations' rows appear only when the gateway answers their first read (a 404 hides the row; any other failure keeps the row and the page shows the error). | Connect Apps is owned by `capabilities` (assignment). "Never show a control that does nothing": an older gateway without `/api/webhooks` must not get a dead row. |

### 0.3 Nothing here needs the relay, a plugin or a gateway change

Every call below exists in the gateway as it is installed (`AG/hermes_cli/web_routers/*.py`, `AG/tui_gateway/contracts/*.py`,
`AG/plugins/kanban/dashboard/plugin_api.py`). `docs/owner-todo/morepages.md` holds only the one question of D-M1.

### 0.4 Shared rules for every unit

- Tab roots keep the inline large title; every page pushed from More gets the small title on the bar row. Use
  `PageChrome.applyListHeader` only on roots; pushed pages go through `PushedPageTitles` (`NAT/App/Pages/PageKit.swift:38-51`).
- Rows whose text can wrap: 12–14 pt vertical padding (`MEM/row-padding-feedback.md`: "Any cell whose text can wrap gets
  explicit vertical padding: about 12–14pt top and bottom").
- Glass: only `UIGlassEffect`, `.glassEffect`, `.buttonStyle(.glass)`, system bars and sheets
  (`MEM/liquid-glass.md`: "never ship CSS imitation glass").
- The word "Dispatch" never reaches the screen or VoiceOver. Several web strings carry it in code names only; none of
  the wording copied below contains it.
- Page states come from `NAT/App/Pages/PageKit.swift` (skeleton, error with Try Again / Copy Details, empty, search
  miss) and results from `PagesHUD`. Haptics from `PagesHaptics`.
- REST goes through `PagesREST` (`NAT/HermesKit/Pages/PagesWire.swift`) on `GatewayClient.rest`; JSON-RPC through
  `GatewayClient.call`. **Hermes answers error 4000 for any param key it does not know**: send exactly the keys
  listed here, nothing more. Profile scope on REST is the query item `profile=<id>` (`V/api/client.ts:49-80`); leave it
  out for the default bot.
- A read-only gateway (`PagesServices.readOnlyGateway`, or `-HQPagesReadOnly YES` in DEBUG) hides every write control
  in this spec; pages still read.
- Offline: a page that has shown data keeps showing it with the link subtitle ("Offline" / "Reconnecting…"); writes
  are disabled while offline and say why in a footer ("You can change this once your gateway is back.").
- New Swift files go in `App/Pages/More/<Page>/…` (UI) and `HermesKit/Pages/More/…` (stores, wire), tests in
  `Tests/Pages/More…` and `UITests/pages/MorePagesTests.swift`. Both `project.yml` and `project-original.yml` pick up
  sources by folder; **build both identities** before calling a unit done:
  `scripts/build.sh build <udid>` and `HQ_IDENTITY=original scripts/build.sh build <udid>`.

---

## 1. L852 — Bottom accessory over the tab bar (not built)

**Web.** `ios/App/App/HermesUINav.swift` carries a `DispatchTabAccessoryView` host; `S/phone-tab-bar.tsx:916` says
"The bottom accessory stack … nothing renders until one registers", and nothing registers: `S/tab-accessory.ts` was
deleted in build 196.

**Owner.** `MEM/liquid-glass-more.md`: "tab-bar accessory bubble ("Inbox · Working…") REJECTED: covered the list and
its tap didn't open the chat on the real phone (worked in sim). Removed … Don't re-add an accessory without asking."

**Native (D-M1).** Nothing is added. No `UITabBarController.bottomAccessory`, no view over the tab bar. Running and
waiting chats are already told by the Bots rows' status line, the tab badges and Reply Peek.

**Outcome.** "not built: owner rejected it; waiting on the owner's word" in the rows file. The question in
`docs/owner-todo/morepages.md` offers the one design that avoids both complaints (iOS 26's own
`UITabBarController.bottomAccessory`, shown only while a chat is waiting on the owner, tap opens that chat), to be
built only on a yes.

**Acceptance.** A unit test asserts `MainTabController().bottomAccessory == nil` after sign-in with a running and a
waiting chat in the fixture, so nobody adds one by accident.

---

## 2. U1 · L688 — Artifacts: repeats collapsed into one row with a count

**Web.** `S/ui-pages/artifact-list.tsx:32-43` `collapseRepeats`: "One row per file or link from one source (the
newest), with how many times it appeared there", keyed `[profile, sessionId, kind, value, href]`; the row draws
`×{n}` with the hidden text ", {n} times" (`:97`) when n > 1. Images are not collapsed this way (the grid is its own
list).

**Native today.** `ArtifactCollector.unique` (`NAT/HermesKit/Pages/ArtifactCollector.swift:425-431`) and the
per-session `found[key]` guard (`:408-418`) already keep one record per key. The count is thrown away.

**Design.**
- `ArtifactRecord` (`NAT/HermesKit/Pages/PagesWire.swift:540`) gains `var repeats: Int = 1` (Codable with a default:
  decode with `decodeIfPresent ?? 1`, so the kept index from older builds still loads).
- In the collector, when `found[key]` already exists for the session, do `out[index].repeats += 1` instead of
  skipping silently. In `unique`, when a duplicate key is dropped across pages of the same session, add its count to
  the kept (newest) record.
- Row (`ArtifactsViewController` file/link rows, kinds `.file` and `.link` only): a trailing secondary label
  `×N` (footnote, `HQPalette.label2`, monospaced digits), left of the ⋯ button, only when `repeats > 1`. It never
  truncates the name: name wraps to two lines first.
- VoiceOver: the row's label ends ", N times".
- No wire change: the data comes from the same `GET /api/sessions/<id>/messages` pages the index already reads.

**Wording.** `×2`, `×14`. VoiceOver: "report.md, Hermes Projects · 6:02 AM, 14 times".

**Fixture.** `scripts/fixtures/morepages-gateway.py` (§15) seeds one chat that names `notes/plan.md` three times and
`https://example.com/a` twice, and a second chat that names `notes/plan.md` once.

```
python3 scripts/fixtures/morepages-gateway.py --port 10050 --credentials build/fixtures/morepages.json \
  --files build/fixtures/morepages-files --tick-seconds 0
```

**Acceptance.**
1. Unit (`Tests/Pages/ArtifactRepeatsTests.swift`): three mentions in one session → one record, `repeats == 3`; the
   same path from a second session → its own record with `repeats == 1`; a record decoded from JSON without
   `repeats` → 1; images never carry a badge.
2. UI (`MorePagesTests.testU1_RepeatBadge`): Artifacts › Files shows `plan.md` twice (two chats), one with "×3";
   Links shows "×2". Screenshot looked at, light and dark.
3. AX5: the badge stays on the first line's trailing edge and the name wraps.

---

## 3. U2 · L699 — Linked notes open in the text viewer with a back stack

**Web.** `S/artifact-text-sheet.tsx:50-52,102-127`: a link in a Markdown note that points at another file opens that
note **inside the same sheet**; `linked` is the stack; Back goes to the note before it ("Back to <name>", or plain
"Back" when the name is longer than 12 characters, `:137`); the title is the note's file name (`:35,125`). Path rule
`S/fe-pages-r5.ts:27-35` `linkedNotePath(from, target)`: strip `file://`; an absolute or `~/` target is itself; a
relative target is resolved in the linking note's folder with `.`/`..` collapsed; the read carries the base
artifact's `profile` and `sessionId` (`:44-49`). States: "Loading <name>…" (`:149,156`), "Couldn’t open <name> here."
plus the reason (`:146-147`). Share shares the note on screen (`:128-132`). Link kinds
(`V/lib/preview-markdown-links.ts:13-17`): `external` (web link → the browser), `file` (a note), `hash` (scroll to
that heading in this note), `inert`.

**Native today.** `ArtifactTextViewController` sets `dataDetectorTypes = [.link]`; a relative Markdown link is drawn
but does nothing useful.

**Design (D-M3, D-M4).**
- `HermesKit/Pages/ArtifactLinks.swift` (pure): `linkedNotePath(from:target:) -> String` ported line for line with the
  web's test cases (`S/fe-pages-r5.test.ts`), and `classify(href:) -> .external(URL) | .file(String) | .hash(String) | .inert`
  (a scheme other than `file:` is external; `#…` is hash; empty or `javascript:`-like is inert).
- `ArtifactTextViewController` becomes the `UITextViewDelegate` and answers
  `textView(_:primaryActionFor:defaultAction:)` for link items: external → the default action (system opens it);
  hash → scroll to the heading whose slug matches (`previewHeadingSlug`, `V/lib/preview-markdown-links.ts:24-34`: NFC,
  trim, lower-case, drop everything but letters, digits, marks, `-`, `_`, space; spaces → `-`); file → push another
  `ArtifactTextViewController` (or Quick Look for a non-text file by the same `ArtifactFiles.opening` rule) built by a
  `linkOpener` closure the Artifacts page injects. The new page's title is the target's last path component; its
  `load` is `ArtifactFiles.download` with `path = linkedNotePath(from: thisNotePath, target:)`, the base record's
  `session_id` and `profile`.
- Back: the pushed page's back button title is the previous note's name; when that name is longer than 12 characters
  set `navigationItem.backButtonDisplayMode = .generic` on the page under it ("Back"), as the web does. Depth is not
  capped; UIKit's hold-Back menu lists the notes under this one.
- A cycle (A → B → A) just pushes again, as the web does. A link to the note already on screen with only a
  `#fragment` scrolls and does not push.
- Share on a linked note shares that note (downloaded the same scoped way).
- Missing file: `ArtifactFiles.isMissing(error)` → the page shows the error state without "Open in Quick Look" and
  without Share; other errors offer "Open in Quick Look".

**Wire.** `GET /api/fs/download?path=<resolved>&session_id=<id>[&profile=<id>]` (already used:
`NAT/HermesKit/Pages/ArtifactFiles.swift:69-73,110-113`). A relative path stays relative so the gateway resolves it
against the session's folder, exactly as it resolved the first note.

**UI states and wording.** Loading: spinner and "Loading <name>…". Failed: "Couldn’t open <name> here." and under it
the reason from `ArtifactFiles.failureText`. Button (not for a missing file): "Open in Quick Look".

**Fixture.** The morepages fixture serves `notes/index.md` → links to `plan.md` (same folder), `../README.md`,
`/home/hermes/abs.md`, `#usage` (a heading in itself), `missing.md` (404), `https://example.com`, and
`plan.md` → links back to `index.md`.

**Acceptance.**
1. Unit: `linkedNotePath` table (relative, `..` above the root of a relative path keeps `..`, absolute, `~/`,
   `file://`), `classify`, the slug rule (composed and decomposed accents slug alike).
2. UI (`testU2_LinkedNotes`): open `index.md` → tap "plan" → title "plan.md", Back reads "index.md" → tap its link
   back → Back twice returns to Artifacts. `missing.md` shows "Couldn’t open missing.md here." with no Quick Look
   button. `#usage` scrolls without pushing (navigation depth unchanged). The fixture log shows every read carried
   `session_id`.
3. The external link does not push a page (the test asserts depth unchanged and stops there; it does not follow it).

---

## 4. U3 · L673 — Kanban task: Add Attachment

**Web.** `S/ui-kanban/task-sheet.tsx:291-300`: under Attachments, after the existing files, a row "Add Attachment"
(green plus) that reads "Adding…" and is disabled while it uploads; the footer "Files you add here go to the bot with
the task." shows while the list is empty; a failure is reported as an error notice with the gateway's words; on
success the task is read again. Upload call `V/plugins/kanban/api.ts:467-468`.

**Gateway.** `AG/plugins/kanban/dashboard/plugin_api.py:471-501`:
`POST /api/plugins/kanban/tasks/{task_id}/attachments[?board=<slug>]`, `multipart/form-data` with the part **`file`**
(required) and the optional form field `uploaded_by`. Answers `{"attachment": {id, filename, stored_path, size, …}}`;
400 for an unsafe name (`_safe_attachment_name`), **413** `{"detail":"attachment exceeds N MB limit"}`, 404 for an
unknown task, 500 `failed to store attachment: …`. A name that exists is stored as `foo (1).pdf`.

**Design.**
- `KanbanAPI.addAttachment(_ id: String, file: URL, filename: String, board: String, progress:)`
  (`NAT/HermesKit/Pages/KanbanAPI.swift`): builds the body **on disk** (never in memory) with a new
  `MultipartBody.buildFileOnly(source:filename:contentType:boundary:in:limit:)` that writes only the `file` part and
  `uploaded_by=phone`… **no**: send only `file` (the web sends only `file`; the gateway then records "dashboard").
  Upload through `LiveGatewayClient.upload(_:query:contentType:bodyFile:timeout:priority:progress:)`
  (`NAT/HermesKit/Net/LiveGatewayClient.swift:242`), timeout 300 s. The fake clients in tests get the same method
  through a small `GatewayUploading` protocol the Live client already satisfies. Remove the body file afterwards,
  success or not.
- `KanbanTaskModel.addAttachment(from:)` (`NAT/App/Pages/Kanban/KanbanTaskSheet.swift`): sets `busy.insert("upload")`,
  copies the picked item into the app's temporary folder (security-scoped access for document picks; photos through
  `AttachmentImporter` so HEIC and Live Photos are normalised as the composer does), uploads, reads the task again,
  `PagesHaptics.success()`, HUD "Attachment Added". On failure: `PagesHaptics.error()` and `FailureAlert` titled
  "Couldn’t Add Attachment" with the reason.
- Row: in the Attachments section, after the files, a row with a green `plus.circle.fill` and "Add Attachment"; it is
  a `Menu` with "Photo Library" (`photo.on.rectangle`) and "Choose File" (`folder`) (D-M5). While uploading the row
  reads "Adding…" with a `ProgressView(value:)` for files over 1 MB, and is disabled. Hidden on a read-only gateway
  and while offline.
- The section shows even when the task has no attachments yet (the web shows it whenever `detail.attachments` is
  present, empty included).

**Wire example.**

```
POST /api/plugins/kanban/tasks/t_8f2c/attachments?board=website
Content-Type: multipart/form-data; boundary=hermes-…

--hermes-…
Content-Disposition: form-data; name="file"; filename="brief.pdf"
Content-Type: application/pdf

<bytes>
--hermes-…--

200 {"attachment":{"id":7,"filename":"brief.pdf","stored_path":"/…/attachments/t_8f2c/brief.pdf","size":48211}}
```

File names with `"`, `\`, CR or LF are refused before any byte is sent (`MultipartBody.Failure.unsafeName`).

**Wording.**

| State | Text |
|---|---|
| Row | "Add Attachment" |
| Uploading | "Adding…" |
| Empty footer | "Files you add here go to the bot with the task." |
| Done | HUD "Attachment Added" |
| Too large (before upload, or 413) | Alert "Couldn’t Add Attachment" · "This file is larger than 25 MB, the most a task can hold." (use the gateway's number) |
| Unsafe name / 400 | "Couldn’t Add Attachment" · the gateway's `detail`, else "The gateway couldn’t use this file’s name." |
| Task gone / 404 | "Couldn’t Add Attachment" · "This task is no longer on the board." then the sheet's own gone state |
| Offline / transport | "Couldn’t Add Attachment" · `GatewayFailure`'s plain words |
| Photo access limited | nothing asked: `PHPickerViewController` needs no permission |

**Fixture.** The pages fixture already serves the Kanban API (`NAT/scripts/pages-fixture-gateway.py:314-345`); the
morepages fixture adds `POST …/tasks/<id>/attachments` (parses the multipart, stores under `--files`, enforces a
limit set by `--attachment-max-mb`, default 25, collision names `name (1).ext`), so the new file opens again through
the existing `GET /attachments/<id>`. `POST /__fixture/fail {"method":"POST","path":"/api/plugins/kanban/tasks/…/attachments","status":413,"detail":"attachment exceeds 25 MB limit"}` and `{"delay":20}` are the knobs.

**Acceptance.**
1. Unit: the multipart body is byte-exact (golden file); unsafe names are refused; a 26 MB file is refused before
   upload; 413/400/404 map to the texts above; the body file is always removed.
2. UI (`testU3_AddAttachment`): task sheet → Add Attachment → Choose File (the test seeds a file in the app's
   Documents through `-HQPagesSeedFile`) → row reads "Adding…" → the file appears in the list → tapping it opens
   Quick Look. The fixture's state shows exactly one POST with a `file` part and no other field.
3. Uploading the same name twice lists `brief.pdf` and `brief (1).pdf`.
4. Read-only gateway: no Add Attachment row.

---

## 5. U4 · L858 — Search mode on every page

**Web.** `S/ui-nav/page-search.ts:1-6`: "A page's search behind a magnifier in its bar … fold away while nothing is
typed in them and they don't have focus … The bar's Search item unfolds the visible page's row and focuses its field,
so the keyboard comes up from the same tap; Cancel, or leaving the field empty, folds it again. A typed search keeps
its row open, also across tab changes." `S/ui-nav/search-mode.ts:1-3,16-21`: the search "belongs to the screen it
started on and retains its query across tab changes"; while its screen is not on show the mode is "aside", and it
ends when the field is gone or left empty.

**Owner.** `MEM/search-magnifier.md`: "Owner asked 2026-10-03 to move the search box at the top of pages to an icon by
the filter button; picked the icon version." ("takes up so much space".)

**Native today.** Bots and Sessions use `PageBarCapsule` (`NAT/App/Kit/PageBarCapsule.swift`). Jobs, Kanban and
Artifacts call `PageChrome.installSearch` (`.integratedButton` placement, `NAT/App/Pages/PageKit.swift:20-31`) and
Capabilities sets its own `navigationItem.searchController` (`NAT/App/Capabilities/CapabilitiesViewController.swift:18-22`):
the field is always there.

**Design.**
- Jobs, Kanban, Artifacts, Capabilities (each tab of it) and every new list page in this spec use `PageBarCapsule`
  for search. `PageChrome.installSearch` is removed once nothing calls it. The capsule order stays
  Filter · Search · Compose; pages with a "+" (Jobs' New Job when the jobs stream adds it, Kanban's New Task) pass it
  as `compose` with their own symbol and label.
- Behaviour, identical on every page (already what the capsule does): no field at rest; tap the magnifier → field
  under the title with the keyboard up in the same tap; Cancel, or leaving it empty, folds it; a typed query keeps the
  field shown and the magnifier `isSelected`.
- Across tabs: the page keeps its `UISearchController` and its text when another tab is selected
  (`definesPresentationContext = true`, already set by `install()`); coming back shows the field with the same query
  and the same filtered rows, keyboard down. Add a `PageBarCapsule.restoreIfTyped()` called from each page's
  `viewWillAppear` that re-attaches the controller when a query is held but UIKit dropped the bar.
- Across a push and pop (opening a result and coming back): the query and the filtered list are still there.
- Not kept across a cold launch (the web keeps it only in memory too).
- More's root: its magnifier opens More search (U17), not a page filter.
- Capabilities shares one capsule; switching its tab keeps the query and re-filters the new tab (as the web's
  per-tab rows do when one field is typed in).

**Identifiers.** `jobs.search`, `kanban.search`, `artifacts.search`, `capabilities.search`, and
`<page>.search.field` on the field.

**Wording.** Placeholders stay as they are: "Search Jobs", "Search Tasks", "Search Artifacts", "Search" (Capabilities
uses its tab's: "Search Skills", "Search Connectors", …, as the capabilities stream names them). VoiceOver for the
magnifier: "Search", value = the typed query while one is held.

**Fixture.** The morepages fixture (it carries everything the pages fixture has).

**Acceptance.**
1. UI (`testU4_SearchFoldsOnEveryPage`), for each of Jobs, Kanban, Artifacts, Capabilities: at rest no search field
   exists; tap `<page>.search` → field exists and has keyboard focus; type "zzz" → the page's no-results state; Cancel
   → field gone, full list back.
2. `testU4_QueryKeptAcrossTabs`: type "inbox" on Jobs, select Bots, select Jobs → the field shows "inbox" and the
   list is still filtered; select More and back the same.
3. `testU4_QueryKeptAcrossPush`: filter Artifacts, open a file, Back → still filtered.
4. Screenshot of each page at rest, looked at: the first row starts where it starts on Bots (no gap where the field
   was).

---

## 6. U5 · L878 — "All Bots Are Hidden"

**Web.** `S/ui-bots/roster-filters.ts:27`: Filter › "Show Hidden Bots (N)" with a check while on.
`S/ui-bots/roster-empty.tsx:18-19`: when every bot is hidden and hidden bots are not shown: symbol `eye.slash`, title
**"All Bots Are Hidden"**, description **"Hidden bots keep working; they just aren’t listed."**, button
**"Show Hidden Bots"**.

**Owner.** `MEM/bot-unhide.md`: "Owner reported "no way to un-hide a bot"." The fix made Filter show whenever a bot is
hidden and ended the list with a foldable Hidden section.

**Native today.** Filter › Show Hidden Bots (N) opens the collapsible Hidden section; with every bot hidden the list
is just one collapsed "Hidden" header on an otherwise blank page.

**Design.** In `BotsViewController.updateEmptyState` (`NAT/App/Bots/BotsViewController.swift:442-469`), before the
"No Bots Yet" branch: when `query.isEmpty`, no filter is on, `!bots.isEmpty`, every bot (and group chat, when groups
land) is hidden and the Hidden section is collapsed → a `UIContentUnavailableConfiguration.empty()` with image
`eye.slash`, the text and secondary text above and a `.glass()` button "Show Hidden Bots" that expands the Hidden
section (the same action as Filter › Show Hidden Bots). While this state shows, the collapsed "Hidden" header row is
left out of the snapshot (the empty state replaces it); once expanded, the list shows the Hidden section and the
empty state goes.
- The rule lives in a pure `BotList.emptyState(bots:query:activity:hiddenShown:) -> BotListEmpty` so groups' L207 can
  add its other states to the same function. Leave the hook: `enum BotListEmpty { case none, noBots, offline(String), search, filtered, allHidden }`.
- Unhiding the last hidden bot from the expanded section returns to the normal list; hiding the last visible bot
  (with the Undo pill) lands on this state once the pill's row is gone.

**Wire.** None (hide is the roster layout the app already syncs).

**Fixture.** `scripts/fixtures/settings-gateway.py` (it has the roster layout writes):

```
python3 scripts/fixtures/settings-gateway.py --port 10051 --hermes-cookies --credentials build/fixtures/morepages-settings.json
```

**Acceptance.**
1. Unit: `emptyState` table (no bots → noBots; all hidden + collapsed → allHidden; all hidden + expanded → none; all
   hidden + query → search rules win).
2. UI (`testU5_AllBotsHidden`): hide both fixture bots → "All Bots Are Hidden" and the button; tap it → both rows
   under Hidden; Show in Bots on one → normal list. Screenshot looked at, light, dark and AX3.
3. VoiceOver reads title, description, button in that order.

---

## 7. U6 · L879 — Open-Source Licenses, complete

**Web.** `S/licenses-sheet.tsx:40-49`: intro "This app is built on Hermes Agent by Nous Research and the open-source
software below. Tap one to read its license."; one disclosure per package with "version · license" under the name;
"Loading…" / "The licenses couldn’t load.". `B/license-notices.ts:6-10,49-65`: built from what is really in the
bundle, Hermes first, then by name.

**Native today.** `LicensesView` (`NAT/App/Settings/AboutView.swift:120-180`) hard-codes three entries.

**Design (D-M8).**
- The list is **generated**, so it cannot fall behind: `scripts/licenses.py` reads
  `HermesHQNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (every resolved Swift package,
  direct and transitive: today swift-markdown and swift-cmark) plus `App/Resources/Licenses/extra.json` (things that
  ship another way) and writes `App/Resources/Licenses/licenses.json`:
  `[{"name","version","license","text"}]`, Hermes first, then by name, `text` = the package's own LICENSE / COPYING /
  NOTICE files joined (the rule of `B/license-notices.ts:32-37`). The JSON is committed; a unit test fails when
  `Package.resolved` names a package the JSON lacks, or a version differs.
- `extra.json`, audited by the builder and listed in the report with how each was checked:
  1. **Hermes Agent (Nous Research)**, MIT, `AG/LICENSE`: the app ports its wire contracts, the slash catalog and
     the messaging protocol section (`NAT/HermesKit/Model/BotIdentity.swift:110`).
  2. **Lucide** (ISC): the Kanban tab icon is Lucide's `square-kanban` path (1x-pages §1, row 3) and any other glyph
     the code draws from Lucide path data (`grep -rn -i lucide App`).
  3. Any syntax-highlighting grammar or theme the native highlighter was ported from
     (`NAT/App/Chat/Render/SyntaxHighlighter.swift` header names its source; if it names one, add its notice).
  4. Any bundled sound, font or image that is not the owner's own (`NAT/App/Audio/CompletionSounds.swift`,
     `App/Resources/Assets.xcassets`): add its notice, or state in the report that it was made for this app.
  5. The bot heads' SVG shapes are the owner's own artwork: no notice.
  Builder: `grep -rn -i -E "ported from|adapted from|based on|copyright|licen[cs]e" App HermesKit Shared NotificationService`
  and account for every hit in the report.
- Page: Settings › About › Open-Source Licenses (unchanged place). Intro paragraph, then one row per entry: name,
  and under it "version · license" (`noticeMeta`, `S/licenses-sheet.tsx:19-20`; no leading dot when there is no
  version). Tapping pushes the text page that exists today (re-flowed paragraphs). Loaded when the page opens, off
  the main thread.

**Wording.** Title "Open-Source Licenses". Intro as the web's sentence above. Failure: "The licenses couldn’t load."

**Acceptance.**
1. Unit: `licenses.json` decodes; first entry is "Hermes Agent (Nous Research)"; every `Package.resolved` pin is
   present with its version; no entry has empty text.
2. UI (`testU6_Licenses`): About › Open-Source Licenses lists at least the audited entries; opening swift-cmark
   shows its text; screenshot looked at.
3. The report holds the audit table (what ships, where its notice came from).

---

## 8. U7 · L865 — Quick-action tiles

**Web.** `S/ui-kit/quick-actions.tsx:1-13`: "3–4 equal tiles (Info's Talk · Memo · Screen · New Chat); two columns at
AX1 and larger, full-width rows at AX3 and larger". CSS `S/ui-kit/components.css:84-89`: equal columns, 8 pt gap,
min height 60, glyph 20 over a caption-1 medium label, pressed state, disabled at 40 %. Bot Info's tiles
(`S/ui-bots/info-state.ts:130-135`): Talk (`waveform`), Memo (`mic`), Screen (`display`, or `photo.on.rectangle`),
Mute/Unmute (`bell.slash` / `bell`); group chats: Add Bots, Activity, Mute (`:176-180`).

**Native today.** `BotInfoTiles` (`NAT/App/BotInfo/BotInfoSheet.swift:449-475`): an `HStack` capped at 260 pt with
Memo and Mute, no reflow.

**Design.**
- `App/Kit/QuickActionTiles.swift` (SwiftUI): `struct QuickAction: Identifiable { id, label, symbol, disabled, run }`
  and `QuickActionTiles(actions:)`. Layout by `@Environment(\.dynamicTypeSize)`:
  below `.accessibility1` one row of equal-width tiles; `.accessibility1`–`.accessibility2` a two-column grid;
  `.accessibility3` and larger one tile per row with the glyph beside the label. 8 pt gaps, min height 60 pt,
  `.buttonStyle(.glass)`, label `.caption.weight(.medium)` on one line (`minimumScaleFactor(0.85)`, never
  truncated: at sizes where it would truncate the layout has already reflowed), disabled tiles at 40 %.
  Fills the sheet's content width (no 260 pt cap). Each tile's identifier is `quick-action.<id>`; keep
  `bot-info.tile.<id>` as a second identifier on Bot Info so existing tests pass.
- `BotInfoTiles` renders through it. Tiles come from a small registry so the talk and screen streams add theirs
  without editing this file: `BotInfoTileHooks.providers[.talk | .screen]` in the style of
  `BotMenuHooks.providers` (`NAT/App/BotInfo/BotInfoSheet.swift:204-209`). Order is fixed: Talk · Memo · Screen ·
  Mute. A tile whose provider is absent is not shown (never a tile that does nothing), so today the row has Memo and
  Mute, and it grows to four as those streams land.
- Leave the group-chat set (Add Bots · Activity · Mute) to the groups stream; it uses the same view.

**Acceptance.**
1. Snapshot/layout unit test: 2, 3 and 4 tiles have equal widths at default size; two columns at AX1; full-width
   rows at AX3; no label truncated at any size from xSmall to AX5.
2. UI (`testU7_QuickActionTiles`): Bot Info shows Memo and Mute as equal tiles filling the row; Mute toggles to
   Unmute; screenshots at default, AX1 and AX5 looked at.

---

## 9. U8 · L864 — Escape belongs to transient layers

**Web.** `S/ui-nav/root-escape.ts:1-16`: "A tab root is persistent. Escape belongs to a transient layer or its
search, never desktop page close." On a tab root with no layer up, Escape is swallowed; if that page is searching, it
presses the search's Cancel.

**Native design (D-M7).** One `UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [])` on
`MainTabController` (`wantsPriorityOverSystemBehavior = false`), handled by a pure rule so it is testable:

```swift
enum EscapeRule {
    enum Context { case layer, searching, pushedPage, tabRoot, chatTyping }
    enum Outcome { case dismissLayer, cancelSearch, goBack, nothing }
    static func outcome(_ c: Context) -> Outcome   // layer→dismissLayer, searching→cancelSearch,
                                                   // pushedPage→goBack, tabRoot→nothing, chatTyping→nothing
}
```

Context is read top-down: a presented controller (sheet, alert, action sheet, menu, media viewer, Quick Look) →
`layer` (dismiss the top-most one only); else an active `UISearchController` on the visible page → `searching`
(`isActive = false`, which clears and folds it through `PageBarCapsule`); else a navigation stack deeper than its
root → `pushedPage` (pop one; a page with unsaved edits, i.e. the SOUL.md editor, runs its Cancel path with the
Discard question instead); else `tabRoot` → nothing. A focused chat composer holding text → nothing (Escape must not
throw a draft away or leave the chat). Controllers that already take Escape themselves (the browser viewer's key
field, `NAT/App/Browser/BrowserKeyField.swift:96-110`) keep it: first responder wins.

Escape never selects another tab, never signs out, never closes the app's root.

**Acceptance.**
1. Unit: the rule table; context detection against stub controller trees.
2. UI (`testU8_Escape`, hardware key through `XCUIApplication().typeKey(.escape, modifierFlags: [])`): on Jobs root
   nothing changes (same tab, same title); with Jobs search typed → field folds, full list; on a pushed job → back to
   Jobs; with a sheet over Kanban → sheet closes, Kanban stays; in a chat with text typed → text still there.

---

## 10. U9 · L872 (Profiles) and L862 (nav edit bar)

**Web.** `V/app/profiles/index.tsx`: a list of profiles ("N profiles"), each with model, skills count and its folder;
a detail with facts and the **SOUL.md** editor; Rename (dialog with the hint "Lowercase letters, digits, hyphens, and
underscores. Must start with a letter or digit."), Delete (never the default). `S/phone-nav-edit-bar.tsx:6-17`: "an
editor in a page's detail (SOUL.md) puts Cancel and Save in the phone's bar while it edits … Cancel over the back
(which hides), Save at the trailing edge, grey until something changed"; while saving, Save reads "Saving…" and both
are disabled. A failed save shows a notice with Retry above the editor (`B/stress-d-gates.ts:104-107`). Success:
"SOUL saved" notice (`V/app/profiles/index.tsx:321`).

**Wire (all verified in `AG/hermes_cli/web_routers/profiles.py`; shapes `V/api/profiles.ts`, `V/types/hermes.ts:1084-1169`).**

| Call | Body → answer |
|---|---|
| `GET /api/profiles` | → `{"profiles":[{"name","path","is_default","model","provider","has_env","skill_count","display_name?","bot_title?","role?"}]}` |
| `GET /api/profiles/<name>/soul` | → `{"content":"…","exists":true}` |
| `PUT /api/profiles/<name>/soul` | `{"content":"…"}` → `{"ok":true}` |
| `PATCH /api/profiles/<name>` | `{"new_name":"…"}` → `{"ok":true,"name":"…","path":"…"}` |
| `DELETE /api/profiles/<name>` | → `{"ok":true,"path":"…"}` (never `default`; refuse on the phone first) |

`<name>` is percent-encoded as one path segment (`PagesREST.segment`).

**Design.**
- More › Bots › **Bot Profiles** (tile `person.crop.circle`, colour `#5e5ce6`), first in the Bots group
  (`S/ui-nav/more-model.ts:14`: profiles, capabilities, messaging).
- `ProfilesViewController` (list, `PageBarCapsule` search "Search Profiles"): one row per profile: the bot's head
  (from the roster), its display name (`PagesNames.botName`), and under it "`<profile id>` · `<model>` · `N skills`"
  (wraps; 12 pt vertical padding). The default profile is first. Pull to refresh. Footer: "N profiles" (the web's
  count, `V/i18n/en.ts` profiles.count: "1 profile" / "N profiles").
- `ProfileDetailViewController` (pushed): a facts group (Profile ID, Model, Provider, Skills, Folder: the path, middle
  truncated, long-press Copy), a row **SOUL.md** → the editor, and at the bottom **Rename Bot…** and
  **Delete Bot…** (destructive; both absent for `default`, on a read-only gateway and offline). The row
  ⋯/hold menu on the list offers the same Rename and Delete.
  - Rename: `TextPrompt` (`NAT/App/Kit/TextPrompt.swift`) titled "Rename Bot", message = the hint above, field
    pre-filled, validated on the phone with `^[a-z0-9][a-z0-9_-]*$` before sending; on success the roster is
    refreshed (`services.refreshBots()`) because the bot's id changed.
  - Delete: reuse the Bots list's delete confirmation and store call (`NAT/HermesKit/Store/BotStore+Extras.swift:86`,
    `Contracts+settings.swift:111`), so wording and behaviour are the ones the owner already has in build 244.
- **`NavEditBar` (L862), `App/Kit/NavEditBar.swift`**: a small helper any detail editor can use:

  ```swift
  @MainActor final class NavEditBar {
      init(host: UIViewController, onCancel: @escaping () -> Void, onSave: @escaping () -> Void)
      func begin()                       // Back hides; leading "Cancel", trailing prominent "Save" (disabled)
      func update(dirty: Bool, saving: Bool, savingLabel: String = "Saving…")
      func end()                         // Back and the page's own items return
  }
  ```

  `begin()` sets `navigationItem.hidesBackButton = true`, `leftBarButtonItem = Cancel` (`.cancel` system item, id
  `nav-edit.cancel`), `rightBarButtonItem = Save` (`style: .prominent`, id `nav-edit.save`), and turns the
  interactive pop gesture off for this page (`isModalInPresentation`-style guard: a swipe back must not drop edits).
  Save is disabled until `dirty`, and reads "Saving…" (disabled, with Cancel disabled) while `saving`. `end()`
  restores what was there.
- `SoulEditorViewController` (pushed from the detail; title "SOUL.md"): loads the text ("Loading SOUL.md…"), shows it
  in a `UITextView` (monospaced body, Dynamic Type, `keyboardLayoutGuide` insets, autocorrect and smart punctuation
  **off**: this is a prompt file). Read-only at first with an **Edit** bar button; Edit → `NavEditBar.begin()` and
  the keyboard. Save → `PUT …/soul`, then HUD "SOUL Saved", `end()`, text stays. Cancel with changes → an action
  sheet "Discard Changes?" · "Your changes to SOUL.md haven’t been saved." · **Discard Changes** (destructive) /
  **Keep Editing** (the web's Discard copy, `S/phone-file-preview.tsx` `DISCARD_COPY`; builder: copy its exact
  title and labels). Cancel without changes just ends editing.
  - Save failure: an inline notice pinned above the text: "Couldn’t Save SOUL.md" + the reason + **Try Again**
    (`SettingsSaveFailure`'s behaviour); the edit bar stays up, nothing typed is lost.
  - A SOUL that does not exist yet (`exists:false`): empty editor with the placeholder "This bot has no SOUL.md yet.
    What you write here tells the bot who it is."
  - The app going to the background mid-edit keeps the draft in memory; the draft is also written to
    `Caches/pages/soul-draft-<account>-<profile>.txt` on every pause in typing (1 s debounce) and offered back
    ("Restore Unsaved Changes?" Restore / Discard) when the editor opens and the server text differs from the draft's
    base. Removed on Save and on Discard.
  - If the server text changed since it was loaded (compare on Save by re-reading first), ask: "SOUL.md Changed on
    Your Gateway" · "Someone else changed this file since you opened it." · **Replace It** / **Cancel**.

**Wording table.**

| Where | Text |
|---|---|
| More row / page title | "Bot Profiles" |
| List footer | "1 profile" / "N profiles" |
| Search placeholder | "Search Profiles" |
| Editor row | "SOUL.md" |
| Loading editor | "Loading SOUL.md…" |
| Bar while editing | "Cancel" · "Save" · "Saving…" |
| Saved | HUD "SOUL Saved" |
| Rename prompt | "Rename Bot" · "Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit." |
| Invalid name | the hint turns red; Rename stays disabled |
| Name taken (409) | "Couldn’t Rename" · the gateway's detail, else "A profile with that name already exists." |
| Default profile | no Rename, no Delete; footer "The default profile can’t be renamed or deleted." |
| Load failed | page error state "Can’t Load Profiles" with Try Again / Copy Details |

**Fixture.** morepages fixture: `GET/PATCH/DELETE /api/profiles…`, `GET/PUT …/soul` (kept per profile, with a
revision counter), `POST /__fixture/soul-edit {"profile","content"}` (another device edits it),
`/__fixture/fail` for a 500 on PUT and a `delay`.

**Acceptance.**
1. Unit: name validation; `NavEditBar` state machine (begin/update/end restore the exact previous items); draft
   file lifecycle; conflict detection.
2. UI (`testU9_Profiles`): More › Bot Profiles lists the fixture's bots, default first; open one → facts; SOUL.md →
   text loads; Edit → Back is gone, Cancel and a disabled Save show; type → Save enabled; Save → "Saving…" then
   the HUD and Back returns; the fixture holds the new text. Cancel with changes → the Discard question, Keep Editing
   keeps the text. PUT failing → the notice with Try Again, which then saves. Swipe-back during editing does not pop.
3. Rename: an invalid name cannot be sent; a valid one renames and the Bots list shows the bot still (same title).
4. Screenshots: list, detail, editor at rest, editor editing (keyboard up, last line visible above it), light/dark.

---

## 11. U10 · L872 — Files and Review

**Web.** `S/phone-tab-bar.tsx:925,981-989`: More › Workspace › **Files** and **Review** reveal the desktop's file and
review panes over More with Back to More. `S/phone-files-root.tsx:21-23`: "Files shows the folder of the chat last on
screen … A folder chosen here (through the gateway folder picker) is kept per gateway and profile until "Use chat's
folder"."

**Native today.** `WorkspacePage(kind: .files | .changes, workspace:, directory:)`
(`NAT/App/Chat/Menus/WorkspacePages.swift:6-36`) and `ChatWorkspace` (`NAT/HermesKit/Chat/ChatWorkspace.swift`) serve
the chat ⋯ menu's Files and Changes.

**Wire (already used natively; `AG/hermes_cli/web_routers/files.py`).**

| Call | Answer |
|---|---|
| `GET /api/fs/default-cwd[?profile=]` | `{"cwd":"/…","branch":"main"}` (`files.py:981`) |
| `GET /api/fs/list?path=<dir>[&profile=]` | `{"entries":[{"name","path","isDirectory"}],"error?"}` |
| `GET /api/fs/read-text?path=<file>` | `{"path","text","binary?","truncated?","byteSize?"}` |
| `GET /api/git/review/list?path=<cwd>&scope=uncommitted` | `{"files":[{"path","added","removed","status","staged"}]}` |
| `GET /api/git/review/diff?path=<cwd>&file=<f>&scope=uncommitted&staged=<bool>` | `{"diff":"…"}` |

**Design (D-M10).**
- More › Workspace › **Files** (`folder`, `#0a84ff`) and **Review** (`arrow.triangle.branch`, `#30b94d`), before the
  Kanban/Artifacts row (`S/ui-nav/more-model.ts:15`).
- Both push `WorkspacePage` (not its modal `make` wrapper) on More's stack, with a root chosen by
  `MoreWorkspaceRoot` (pure, `HermesKit/Pages/More/MoreWorkspaceRoot.swift`): 1) the folder chosen here for this
  gateway and scope bot (UserDefaults `pages.filesRoot.<account>.<profile>`); else 2) the working folder of the chat
  last on screen (`LaunchChatMemory` / the session's `cwd`); else 3) `GET /api/fs/default-cwd`.
- A header row shows the root (home shortened to `~`, middle truncated) with a menu: **Choose Folder…** (pushes a
  folder-only browser starting at the root's parent; "Use This Folder" in its bar) and, while a chosen folder is
  set, **Use Chat’s Folder** (the web's wording). The scope pill (All Bots is not meaningful here) is replaced by a
  bot picker only when the gateway has more than one bot: Files and Review are per bot; default = the default bot.
- Files: folders first, then files, as `ChatWorkspace.sorted`; a text file opens `WorkspaceTextPage`; other files
  open through the Artifacts opener (download with progress → Quick Look; past the limit: "This file is too large to
  open on your phone."). Mac polish 2026-11-06 #47, Mac only: Quick Look, Share, Save As… and a drag out stream the
  file to disk, so the Mac's limit is a chat file card's 512 MiB, not the REST answers' 32 MiB; the iPhone and iPad keep
  32 MiB (D-P9). Truncated text shows the notice
  "Showing the first 512 KB of 2.5 MB."
  (`S/fe-pages-r5.ts:57-63`). Share in the bar.
- Review: the changed files with `+N −M` and a status letter; a file opens its diff in `WorkspaceTextPage(diff: true)`.
  Empty: "No Changes" · "Nothing has changed in this folder since the last commit." Not a git folder (the list
  errors): "Not a Git Folder" · "Review shows changes in a project that uses Git." with **Choose Folder…**.
- Folder errors use the web's words (`S/fe-pages-r4.ts` `folderErrorText`; builder: port that function with its
  tests rather than inventing text).

**Fixture.** morepages fixture: a small invented tree under `/home/hermes/projects/site` (nested folders, a 3 MB text
file, a binary, an unreadable folder → `error`), `default-cwd`, two changed files with diffs, one folder that is not
a git folder.

**Acceptance.**
1. Unit: `MoreWorkspaceRoot` precedence; root persistence per account and profile.
2. UI (`testU10_FilesAndReview`): More › Files shows the root's entries; into a folder and back; open a text file;
   the 3 MB file shows the truncation notice; Choose Folder… → Use This Folder → the header changes and survives a
   relaunch; Use Chat’s Folder returns. More › Review lists two files; a diff opens with added lines tinted; the
   non-git folder shows "Not a Git Folder".
3. Nothing on either page can write (the fixture's state shows GETs only).

---

## 12. U11 · L872 — Messaging

**Web.** `V/app/messaging/index.tsx` (list of platforms with a status dot; a platform's detail: on/off, its keys as
fields, docs link, home channel, Test, pairing: pending and approved people), `V/app/messaging/telegram-qr-setup.tsx`
(QR/deep-link onboarding), strings `V/i18n/en.ts:2930-3126` (builder: take every label from that block and from the
gates that rewrite it in `B/fe-pages-gates.ts`; where a gate replaces a string, the gate wins).

**Wire (`AG/hermes_cli/web_routers/messaging.py`; shapes `V/api/messaging.ts`, `V/types/hermes.ts:320-470`).**

| Call | Body → answer |
|---|---|
| `GET /api/messaging/platforms[?profile=]` | → `{"platforms":[{"id","name","description","docs_url","configured","enabled","gateway_running","state?","error_code?","error_message?","updated_at?","home_channel?","ingress_url?","env_vars":[{"key","prompt","description","is_password","is_set","redacted_value","required","advanced","url"}]}]}` |
| `PUT /api/messaging/platforms/<id>[?profile=]` | `{"enabled"?:bool,"env"?:{KEY:"value"},"clear_env"?:["KEY"]}` → `{"ok":true,"platform":"…","hot_served"?:bool}` |
| `POST /api/messaging/platforms/<id>/test[?profile=]` | → `{"ok":bool,"message":"…","state"?}` |
| `GET /api/pairing[?profile=]` | → `{"pending":[{"platform","user_id","user_name?","request_id","age_minutes?"}],"approved":[{"platform","user_id","user_name?"}]}` |
| `POST /api/pairing/approve` | `{"platform","request_id","profile"?}` → `{"ok":true,"user":{…}}` (**profile goes in the body**, `V/api/messaging.ts:128-131`) |
| `POST /api/pairing/revoke` | `{"platform","user_id","profile"?}` → `{"ok":true}` |
| `POST /api/messaging/telegram/onboarding/start` | `{}` or `{"bot_name":"…"}` → `{"pairing_id","deep_link","qr_payload","suggested_username","expires_at"}` |
| `GET /api/messaging/telegram/onboarding/<pairing_id>` | → `{"status":"waiting","expires_at"}` or `{"status":"ready","bot_username","owner_user_id?","expires_at"}` |
| `POST /api/messaging/telegram/onboarding/<pairing_id>/apply` | `{"allowed_user_ids":["…"],"profile"?}` → `{"ok","platform":"telegram","needs_restart","bot_username?","restart_started?","restart_error?"}` |
| `DELETE /api/messaging/telegram/onboarding/<pairing_id>` | → `{"ok":true}` |
| `POST /api/gateway/restart[?profile=]` | → an action record; then `GET /api/actions/gateway-restart/status?lines=200` → `{"name","running","exit_code","pid","lines":[…]}` (the action name: builder confirms in `AG/hermes_cli/web_routers/actions.py`) |

Every call of one Telegram flow carries the same profile scope (`V/api/messaging.ts:60-63`).

**Design (D-M11).**
- More › Bots › **Messaging** (`message.fill`, `#30b94d`), after Capabilities.
- `MessagingViewController`: the bot picker (as Files') on top when there is more than one bot; one row per platform:
  its mark (SF symbol per id, generic `bubble.left.and.bubble.right` otherwise), name, and a status line:
  "Connected" (green dot) when `enabled && configured && gateway_running && state` is healthy; "Needs Setup" when not
  `configured`; "Off" when configured and not `enabled`; "Not Running" when the messaging gateway is down; the
  platform's `error_message` in red when it has one. Search behind the magnifier. Pull to refresh; re-read on
  `gateway.ready`.
- `MessagingPlatformViewController` (pushed):
  1. A switch **On** (`enabled`) — written at once (`PUT {"enabled":…}`), rolled back with an alert on failure.
  2. **Keys**: one row per non-advanced `env_vars` entry: `prompt` as the label, `description` as its footnote;
     value shows "Set" (with `redacted_value` when present) or "Not Set"; tapping opens the app's existing key field
     page (`NAT/App/Settings/Config/KeysPages.swift`: secure entry for `is_password`, paste button, "Get a Key"
     opening `url`). Save → `PUT {"env":{KEY:value}}`; Remove → `PUT {"clear_env":[KEY]}`. Advanced keys under a
     disclosure "Advanced". A value is never shown again after saving, never logged, never put in a URL.
  3. **Test Connection** → `POST …/test`; the row shows a spinner, then the `message` in green (ok) or red.
  4. **Who Can Message This Bot** (pairing, filtered to this platform): "Waiting" rows with **Approve** (and the age,
     "12 min ago") and "Approved" rows with swipe **Remove** (confirmation: "Remove <name>?" · "They won’t be able
     to message this bot until you approve them again.").
  5. **Setup Guide** → `docs_url` in the in-app Safari page.
  6. After a change that is not `hot_served`: a notice "Restart your gateway to use this change." with
     **Restart Gateway** (confirmation "Restart Your Gateway?" · "Bots stop for a moment and running replies are
     interrupted." · Restart / Cancel) → `POST /api/gateway/restart`, then poll the action status every 2 s (max 90 s)
     showing "Restarting…", then "Gateway Restarted" or the failure's last line.
- Telegram: when Telegram is not configured, its page leads with **Set Up with Telegram** → a sheet: start the
  onboarding, show the QR (`qr_payload` drawn with CoreImage `CIQRCodeGenerator`, for a second device) and a prominent
  **Open Telegram** (`deep_link` through `UIApplication.open`: on the phone this is the normal path), "Waiting for
  Telegram…" while polling the status every 2 s until `expires_at` ("This link expired. Start again." + Start Again);
  on `ready`: "Connected to @<bot_username>" and **Finish** → apply with `allowed_user_ids = [owner_user_id]` when
  given; then the restart notice of (6) when `needs_restart`. Closing the sheet before Finish sends the DELETE.

**States.** List: skeleton; "Can’t Load Messaging" + Try Again / Copy Details; empty "No Messaging Apps" · "This
gateway has no messaging apps to set up." 404 on the first read hides the More row (D-M16).

**Fixture.** morepages fixture: four invented platforms (one connected, one unconfigured Telegram, one off, one with
an error), env writes kept, `test` answers by knob, pairing with two pending and one approved, the Telegram flow
(`POST /__fixture/telegram {"status":"ready","bot_username":"demo_bot","owner_user_id":"42"}` flips it), a fake
restart action that runs 3 s.

**Acceptance.**
1. Unit: the status rule table; body builders (exact keys); profile-in-body for approve/revoke/apply; onboarding
   state machine (waiting → ready → applied; expiry; cancel sends DELETE).
2. UI (`testU11_Messaging`): list shows four rows with the right status lines; toggling On writes
   `{"enabled":false}` only; saving a key writes `{"env":{…}}` and the row reads "Set" (the value appears nowhere on
   screen afterwards, asserted); Test shows the message; Approve moves a person to Approved; Remove asks first; the
   Telegram sheet reaches "Connected to @demo_bot" after the knob flips, Finish applies, the restart notice shows and
   Restart Gateway ends in "Gateway Restarted".
3. `/__fixture/state` shows no write on a read-only gateway.

---

## 13. U12 · L872 — Webhooks

**Web.** `V/app/webhooks/index.tsx`; strings `V/i18n/en.ts:3127-3190`.

**Wire (`AG/hermes_cli/web_routers/messaging.py`; `V/api/messaging.ts:150-195`, `V/types/hermes.ts:424-470`).**

| Call | Body → answer |
|---|---|
| `GET /api/webhooks` | → `{"enabled":bool,"base_url":"…","subscriptions":[{"name","description","events":[…],"skills":[…],"deliver","deliver_only","prompt","enabled","secret_set","url","created_at"}]}` |
| `POST /api/webhooks/enable` | → `{"ok":true,"enabled":true,"platform":"webhook","needs_restart":bool,"restart_started?":bool,"restart_error?":"…"}` |
| `POST /api/webhooks` | `{"name", "description"?, "events"?:[…], "skills"?:[…], "deliver"?, "deliver_chat_id"?, "deliver_only"?, "prompt"?}` → the route plus **`"secret"`** (shown once) |
| `PUT /api/webhooks/<name>/enabled` | `{"enabled":bool}` → `{"ok":true,"name","enabled"}` |
| `DELETE /api/webhooks/<name>` | → `{"ok":true}` |

**Design.**
- More › Integrations › **Webhooks** (`arrow.triangle.turn.up.right.diamond.fill`, `#e5446d`).
- Receiver off (`enabled:false`): a card "Webhook Receiver Is Off" · "Turn it on to let other services send events
  to your bots." · **Turn On Webhooks** (→ "Turning On…"); then, when `needs_restart` and no restart started, the
  restart notice of §12 (6) with the web's sentence "Webhooks are enabled, but the gateway still needs a restart
  before the receiver can come online."
- List: header "Subscriptions (N)"; each row: name, then "`<events or “All Events”>` → `<deliver label>`" and the
  description on a third line when present (12 pt padding), a trailing switch (enable/disable, optimistic, rolled
  back with "Couldn’t turn "<name>" on/off"). Swipe / hold menu: **Copy URL**, **Delete** (confirmation "Delete
  Webhook?" · "This will permanently remove <name>. This cannot be undone." · Delete). Empty: "No Webhooks Yet" ·
  "A webhook lets another service start a bot." with **New Webhook**. Footer hint: "Changes take effect right away
  once the receiver is running. A webhook that is off rejects incoming events."
- "+" in the bar → **New Webhook** sheet (form): Name (required, placeholder "e.g. github-push"), Description
  ("What this webhook does (optional)"), Events ("comma-separated, leave empty for all"), Skills ("comma-separated
  skill names (optional)"), Deliver To (picker: Log · Telegram · Discord · Slack · Email · GitHub Comment;
  `deliver_chat_id` field appears for a chat platform), Deliver Payload Only (switch), Prompt (multi-line,
  "Instructions for the agent when this webhook fires (optional)"). Create → "Creating…".
- Created: a sheet that cannot be swiped away by accident (`isModalInPresentation`): "Webhook Created" · "Copy the
  secret now. It is only shown once." · **Webhook URL** (value + Copy) · **Secret** (monospaced, + Copy) · **Done**.
  The secret is held only by that sheet, never written to disk or the log.
- Detail (tap a row): the route's facts, Copy URL, the switch, Delete.

**Fixture.** morepages fixture: receiver off at seed with `--webhooks-off`, else on with three subscriptions; create
returns a random secret; knobs for 409 (name taken → "A webhook with that name already exists.") and 500.

**Acceptance.**
1. Unit: form → payload (events and skills split on commas, trimmed, empties dropped; absent keys not sent);
   the deliver labels.
2. UI (`testU12_Webhooks`): list of three; switch writes `{"enabled":false}`; New Webhook with only a name creates
   it, the secret sheet shows and Copy puts it on the pasteboard; after Done the secret is nowhere on screen; Delete
   asks, then the row goes. With `--webhooks-off`: the card, Turn On Webhooks, the restart notice.

---

## 14. U13 · L872 — Import Sessions

**Web.** `V/app/session-import/index.tsx`, `api.ts`; strings `V/i18n/en.ts:388-420`; `S/import-scan-help.ts`
(builder: port its help text for a scan that finds nothing).

**Wire (JSON-RPC; `AG/tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py:531-602`; params are
`ProfileParams` plus the listed keys only).**

| Method | Params → result |
|---|---|
| `session.foreign.list` | `{"profile"?, "source"?: "claude"\|"codex", "offset"?: int, "limit"?: int}` → `{"sessions":[{"id","source","label","title","cwd","mtime","turn_count","excerpt"}],"next_offset":int\|null,"host":"…","unreadable":int}` |
| `session.foreign.preview` | `{"profile"?, "id"}` → `{"messages":[{"role","content"}],"total","truncated","already_imported":id\|null,"cwd"}` |
| `session.foreign.import` | `{"profile"?, "id"}` → `{"session_id","already_imported":bool}` |

Timeout 60 s each (`V/app/session-import/api.ts:46`). `id` is an opaque handle, never a path.

**Design.**
- More › Integrations › **Import Sessions** (`square.and.arrow.down.on.square`, `#a2845e`).
- Page: header text "Bring a conversation into Hermes and pick up where you left off." and "Reading from <host>";
  a segmented All · Claude Code · Codex (sends `source`); "Import Into" bot picker (default bot first); the list:
  title (or label), "`<folder>` · N messages · `<relative time>`", two lines of `excerpt` (12 pt padding). Search
  filters the loaded rows ("Search Loaded Sessions"). Bottom row "Load More Sessions" while `next_offset != nil`
  (limit 50). When `unreadable > 0`: footer "Some logs were empty, unreadable, or too large to preview."
- States: "Finding Conversations…" skeleton; "No Conversations Found" · "Claude Code and Codex sessions on your
  gateway computer will appear here."; "Couldn’t Find Sessions" · "Check your connection to your gateway, then try
  again. An older Hermes may need an update." + Try Again; search miss "No Matching Conversations" · "Try another
  title or folder, or load more sessions." An RPC error -32601 (method unknown) hides the More row next time and
  shows the "older Hermes" text now.
- Tap a row → preview page: the turns as plain bubbles (You / the assistant), a notice when `truncated`: "Preview
  shortened for readability. The complete conversation is imported."; a footnote "Copies conversation text. Source
  files stay unchanged. Tool output and reasoning are not carried over."; the bar's prominent **Import** ("Importing…").
  When `already_imported`: the note "This conversation is already in Hermes. Open your existing copy to continue."
  and the button reads **Open in Hermes**.
- After import: open the new session's chat (`services.chat(for:)` after `refreshSessions()`), pushed over More, as a
  notification opens a chat. Failure: alert "Couldn’t Import This Conversation" + the reason.

**Fixture.** morepages fixture: 120 invented foreign sessions (both sources, some with empty titles, emoji and RTL
titles, a 0-turn one), paging, `unreadable: 3`, one already imported, import creates a session the sessions list then
returns; every method refuses unknown keys with 4000; knobs for a 30 s delay and an error.

**Acceptance.**
1. Unit: param builders send only the allowed keys; paging merges without duplicates; row text.
2. UI (`testU13_ImportSessions`): list loads 50, Load More reaches 120; Codex segment sends `source:"codex"`;
   preview shows turns and the footnote; Import lands in the chat titled as the session; importing the
   already-imported one opens the existing chat without a second import call.

---

## 15. U14 · L872 — Status & Maintenance (was Command Center) and Usage

**Web.** `V/app/command-center/index.tsx`, `maintenance.tsx`; strings `V/i18n/en.ts:2741-2930` (sections
"Sessions · System · Usage · Maintenance"; "Messaging gateway running/stopped", "Restart gateway", "Update Hermes",
"Recent logs", "No logs loaded yet.", "Est. cost", "Daily tokens", "Run doctor" · "Health-check the install, config,
and providers").

**Wire (`AG/hermes_cli/web_routers/status.py`, `analytics.py`, `actions.py`, `ops.py`; shapes
`V/types/hermes.ts:955-985,1372-1400,1533-1545`).**

| Call | Answer |
|---|---|
| `GET /api/status` | `{"version","release_date","gateway_running","gateway_state","gateway_pid","gateway_updated_at","gateway_platforms":{id:{"state","updated_at","error_message?"}},"active_sessions","hermes_home","config_version","latest_config_version",…}` |
| `GET /api/logs?file=&lines=200[&level=][&component=][&search=]` | `{"file","lines":[…]}` (omit `level` for all; omit `component` for all) |
| `GET /api/analytics/usage?days=<1…>` | `{"period_days","totals":{…},"daily":[…],"by_model":[…],"skills":{"summary","top_skills"},"tools?":[…]}` |
| `POST /api/gateway/restart` | action record; then `GET /api/actions/<name>/status?lines=200` |
| `POST /api/hermes/update` | action record; status as above (`name` from the answer) |
| `GET /api/hermes/update/check[?force=true]` | the update state (behind count, notes) |
| `POST /api/ops/doctor` | `{}` → action record |

Builder: read the exact field names of `totals`, `daily` and the action record in `V/types/hermes.ts` and
`AG/hermes_cli/web_routers/analytics.py` before decoding; decode leniently (missing fields → "—").

**Design (D-M12).**
- More › Insights › **Status & Maintenance** (`gauge.with.dots.needle.67percent`, `#636366`; row id `command-center`, kept
  for saved tabs and row availability) and, under it, **Usage** (`chart.bar.fill`, `#0A84FF`; row id `usage`).
- Status & Maintenance is one page (D-M12, owner 2026-11-03): the System sections first, then a **Maintenance**
  section. No segmented control. Every way in says "Status & Maintenance": More's row, Settings › Gateway's row, More
  search, a tab or the Mac's sidebar.
- **System**: a status group (Hermes version "Hermes 0.21.5" as About formats it; "Messaging Gateway" Running /
  Stopped with a dot; Active Sessions; one row per platform with its state); **Restart Gateway** (the confirmation
  and progress of §12 (6)); **Update Hermes** (`OutdatedCopy.title`; the palette says "on Your Gateway Computer",
  `S/settings-ios-list.tsx:353`, which names the Telegram bridge here) showing "Up to Date" or "N updates available" from the check, confirmation "Update
  Hermes?" · "Hermes restarts when the update finishes. Bots stop for a moment." → progress lines from the
  action status, ending "Hermes Updated" or the failure's last lines with Copy Details; **Recent Logs** → a pushed
  monospaced log page (200 lines, a level menu All / Errors / Warnings, pull to refresh, Share, "No logs loaded yet."
  when empty).
- **Usage** (its own page): a period menu (7 / 30 / 90 days); tiles Tokens, Sessions, "Est. Cost"; "Daily Tokens" as a Swift Charts
  bar chart (VoiceOver: audio graph plus a "Daily tokens, N days" summary); "By Model" and "Top Skills" lists.
  Empty: "No Usage Yet" · "Usage shows up after your bots have worked."
- **Maintenance** (a section under System, headed "Maintenance"): **Run Doctor** · "Health-check the install, config, and providers" → runs and shows the action's
  output page; other maintenance actions of `V/app/command-center/maintenance.tsx` are added only where the gateway
  route exists and the action is safe from a phone (builder lists each in the report with keep/skip and why; the
  debug-share upload is **skipped**: it sends logs off the gateway).
- All actions hidden on a read-only gateway (the Maintenance section too: every row in it is an action). While the gateway restarts, the app's own link drops: the page keeps its
  "Restarting…" state through the reconnect and resolves from the action status afterwards (or, after 90 s, "Still
  restarting. This page updates when your gateway is back.").

**Fixture.** morepages fixture: status, 500 log lines with levels, 90 days of usage, fake actions (restart 3 s and
the socket really drops and returns; update 6 s with progress lines; doctor with a failing check), knobs for failure.

**Acceptance.**
1. Unit: lenient decoders (golden JSON from the fixture and a trimmed "old gateway" variant); action polling state
   machine incl. the socket drop.
2. UI (`testU14_CommandCenter`): the page is titled Status & Maintenance and has no segmented control; System shows
   version and gateway state; Restart Gateway asks, shows "Restarting…", ends "Gateway Restarted" while the app
   reconnects by itself; Recent Logs lists lines and the Errors filter sends `level=ERROR`; the Maintenance section is
   on the same page and Run Doctor shows its output; More › Usage draws the chart for 30 days and switching to 7
   re-reads with `days=7`.

---

## 16. U15 · L872 — Spawn Tree

**Web.** `V/app/agents/index.tsx`; strings `V/i18n/en.ts:2698-2740`: title "Spawn tree", subtitle "Live subagent
activity for the current turn.", empty "No live subagents" · "When a turn delegates work, child agents stream their
progress here.", statuses Running / Failed / Done / Queued, "N agents", "N active", "N tools".

**Wire (D-M13).** JSON-RPC `delegation.status` with `{"profile"?: "<id>"}` only
(`AG/tui_gateway/contracts/billing_delegation_pets.py:362-385`) →
`{"active":[{"subagent_id","parent_id","depth","goal","delegation_id","model","started_at","status","tool_count","owner_agent_session_id", …}],"paused":bool,"max_spawn_depth":int,"max_concurrent_children":int}`.
The record is open (extra keys are ignored). One call per bot in scope.

**Design.**
- More › Insights › **Spawn Tree** (`point.3.connected.trianglepath.dotted`, `#00a2b8`).
- A list grouped by bot (head + name header), then by owning chat (the session's title, from `SessionStore` by
  `owner_agent_session_id`, else "Chat"), children indented by `depth` (16 pt per level, capped at 4 levels of
  indent). A row: the goal (two lines), then "`<model>` · N tools · running 2m 10s" with the app's running spinner
  glyph; status words as the web's. Tap a row → opens that chat (pushed over More).
- Header line: "N agents · N active"; when `paused`: a notice "New subagents are paused on this gateway."
- Refresh: on appear, every 3 s while on screen and the app is active (stopped off screen, backed off to 10 s after
  an error), and on `subagent.*` events for an open chat.
- Empty: "No Live Subagents" · "When a bot hands work to helpers, they show up here while they run."
  (plain words for the web's sentence). Error -32601: the "older Hermes" state and the row is hidden next time.

**Fixture.** morepages fixture: `delegation.status` returns a seeded tree (2 bots, depth 3, 14 children) and changes
on a knob (`POST /__fixture/delegation {...}`); refuses unknown params with 4000.

**Acceptance.**
1. Unit: tree building from flat records (orphans attach to the root; cycles broken), duration words, grouping.
2. UI (`testU15_SpawnTree`): the tree shows with indents; after the knob removes all children the empty state
   appears within 4 s; tapping a row opens the chat; the fixture saw only `{"profile":…}` params.

---

## 17. U16 · L872 — Star Map

**Web.** `V/app/starmap/*` (canvas simulation), `S/starmap-touch.ts` (touch pan/zoom on the phone); strings
`V/i18n/en.ts:2670-2696`: title "Memory Graph", subtitle "N skills across M categories", filters All / Used /
Learned, "Memory", "Refresh", "Could not load memory graph", empty "Nothing learned yet" · "As Hermes builds skills
and memories for your work, they appear here." More's row is "Star Map" (`S/ui-nav/more-model.ts:32`).

**Wire (`AG/hermes_cli/web_routers/status.py:~700`; `V/api/skills.ts:49-66`, `V/types/hermes.ts:863-905`).**

| Call | Answer |
|---|---|
| `GET /api/learning/graph[?profile=]` | `{"nodes":[{"id","label","kind":"memory"\|"skill","category","useCount","state","createdBy","pinned","timestamp?","memorySource?"}],"edges":[{"source","target"}],"clusters":[{"category","count"}],"memory":[{"source","title","body","timestamp?","fingerprint?"}],"stats":{…}}` |
| `GET /api/learning/node?id=<id>[&profile=]` | the node's detail (404 "not found"); builder reads `node_detail` in `AG/` for its fields and decodes leniently |

**Design (D-M14).**
- More › Insights › **Star Map** (`sparkles`, `#8e5cd9`); page title "Star Map"; subtitle line "N skills across M
  categories".
- A bot picker (per bot), a filter menu All · Used (`useCount > 0`) · Learned (builder: the web's rule in
  `V/app/starmap/star-map.tsx` for "Learned" — `createdBy`/`state`; port it with a test), and a **Map | List**
  segmented control (the choice is remembered).
- **Map** (`StarMapCanvas`, SwiftUI `Canvas` inside a `UIHostingController`): a deterministic layout computed off the
  main thread once per graph (`HermesKit/Pages/More/StarMapLayout.swift`, pure): categories on a ring ordered by
  size; inside each, nodes on a golden-angle spiral, radius by rank of `useCount`; star size by `useCount` (4–14 pt),
  colour by category from the app's palette (stable hash), pinned stars ringed; edges as hairlines at 25 % opacity;
  category names as labels at each cluster's centre. One-finger pan, pinch zoom (0.5×–4×), double-tap zoom to a
  cluster; labels of stars appear above 1.6×. Tapping a star (44 pt hit target at any zoom, nearest wins) opens its
  sheet. Reduce Motion: no fly-in. The canvas draws only what is in view; target 60 fps with 2,000 nodes on the
  simulator's iPhone 17 Pro (`-HQStarMapProbe` prints frame times, as `ChatPerfProbe` does).
- **List**: sections by category ("Category · N"), rows "label" with "Used N times" / "Not used yet" and a pin mark;
  then a **Memory** section with the `memory` cards (title, body folded at 4 lines with Show More). This is also the
  VoiceOver path: with VoiceOver on, the page opens on List, and the Map exposes one element per cluster ("Coding,
  42 skills") rather than 2,000 stars.
- Node sheet (medium detent, glass): label, kind, category, "Used N times", state, created by, and the node's text
  from `/api/learning/node` ("Loading…", "Couldn’t load this.", missing → "This is no longer in the map."). Read-only.
- States: skeleton "Loading…"; error "Can’t Load Star Map" + Try Again / Copy Details; empty as the web's two lines.

**Fixture.** morepages fixture: graphs of 0, 60 and 2,000 nodes by knob (`POST /__fixture/graph {"nodes":2000}`),
12 categories, 3,000 edges, 40 memory cards (one 20,000 characters), a node that 404s.

**Acceptance.**
1. Unit: layout is deterministic (same graph → same points), no two stars of a cluster overlap at 1×, filters, list
   sections.
2. UI (`testU16_StarMap`): the map draws (screenshot looked at: clusters labelled, nothing clipped under the bars);
   pinch changes the scale; tapping a star opens its sheet with text; List shows the same count as the subtitle; the
   empty graph shows "Nothing learned yet".
3. Probe: 2,000 nodes, a 5 s pan/zoom script, no frame over 25 ms after the first second (recorded in the report).

---

## 18. U17 · L874 — More search (the command palette)

**Web.** `S/phone-header.tsx:200`: More's bar magnifier, labelled "Search Sessions, Pages and Actions", opens the
command palette. `S/settings-ios-list.tsx:316-359`: on the phone the palette drops desktop-only rows, its Go To gains
More's pages (Files, Review, Command Center, Webhooks, Import Sessions, plugin pages), "Update Hermes on your gateway
computer" names the loaded version, "YOLO mode" shows On/Off. Placeholder (desktop): "Search sessions, views, and
actions". `MEM/search-magnifier.md`: "More's fake search row removed; More root bar magnifier opens the command
palette."

**Design (D-M15).**
- More's root gets a trailing magnifier (`more.search`, VoiceOver "Search Sessions, Pages and Actions") through
  `PageBarCapsule` with a `UISearchController` whose results show in More's own list (the grouped rows are replaced
  by results while a query is typed; emptying it brings More back). Placeholder "Search Sessions, Pages and Actions".
- `HermesKit/Pages/More/MoreSearch.swift` (pure, unit-tested): `results(query:, pages:, bots:, sessions:, settings:, actions:) -> [Group]`.
  Matching: case- and diacritic-insensitive, every typed word must match the title or a keyword; title-prefix
  matches first, then word-prefix, then substring; at most 6 rows per group, with "Show All N" for Sessions.
  - **Go To**: the five tabs and every More row currently shown (from `PagesTabs` sections, so hidden pages are never
    offered), with the web's keywords (`S/settings-ios-list.tsx:327-331`: files/browse/folder/documents;
    review/changes/diff/git; command center/system/status/maintenance (Status & Maintenance); usage/tokens/cost
    (Usage); webhooks/hooks/triggers;
    import/claude/codex/conversation/sessions).
  - **Bots**: display name, profile id, role (the Bots search rule, `BotList` search) → opens the bot's chat.
  - **Sessions**: `SessionSearch` (`NAT/HermesKit/Model/SessionSearch.swift`) over the loaded sessions → opens the chat.
  - **Settings**: `SettingsSearch` (`NAT/HermesKit/Settings/SettingsSearch.swift`) → opens that settings page on
    More's stack and flashes the row, as Settings search does.
  - **Actions**: New Chat (with the default bot), New Bot, New Task (when Kanban is on), Restart Gateway and Update
    Hermes (detail "Hermes x.y.z"; both open Status & Maintenance, where the
    confirmation lives), Send Performance Logs (the About action). Each action shows only where its feature exists
    and the gateway is writable.
- Rows: tile icon, title, a secondary context ("Settings › Chat", "Bot", the session's bot and time). Return on the
  keyboard opens the first result. Empty query → More as usual. No results → the system search-miss state
  ("No Results for “x”").
- Selecting a result leaves the query in place (U4's rule), so Back returns to the same results.

**Fixture.** morepages fixture (bots, sessions, pages all present).

**Acceptance.**
1. Unit: ranking and grouping table; hidden pages never appear; keywords ("git" finds Review, "codex" finds Import
   Sessions).
2. UI (`testU17_MoreSearch`): magnifier → type "web" → Go To › Webhooks first → opens Webhooks → Back shows the
   results again; "rest" offers Restart Gateway, which opens Status & Maintenance; a bot's name opens its chat; a setting's
   name opens its page; Cancel returns More.

---

## 19. The More list after this stream

`PagesTabs.sectionOrder` stays `account, settings, bots, workspace, insights, integrations`
(`NAT/App/Pages/PagesTabs.swift:32`). This stream registers, through `PagesTabs.registerMoreSection` (merging with
rows other streams already register in the same section: change the registry to **append rows by section id**
rather than replace, with a stable per-row order key):

| Section | Rows, in order (`S/ui-nav/more-model.ts:13-17`, titles `:32`) |
|---|---|
| Bots | **Bot Profiles**, Capabilities (existing), **Messaging** |
| Workspace | **Files**, **Review**, Kanban or Artifacts (existing) |
| Insights | **Status & Maintenance**, **Usage**, **Spawn Tree**, **Star Map** |
| Integrations | Connect Apps (capabilities stream, when it lands), **Webhooks**, **Import Sessions** |

Tile colours are the web's (`S/phone-tab-bar.tsx:924-927`). Row availability (D-M16) is remembered per account in
UserDefaults (`pages.more.unavailable.<account>`: a set of row ids the gateway answered 404 / -32601 for), re-probed
on each `gateway.ready`. Cold-launch restore of a page left open under More keeps working
(`MEM/more-tab-restore-fix.md`: More must reopen with the tab bar showing and Back leading to More's root; the test
`testMoreRestore` in the restore suite must still pass, and a new case restores each new page).

---

## 20. Stand-in gateway

One new script, `scripts/fixtures/morepages-gateway.py`, stdlib only, 127.0.0.1 only, invented data only. It loads
`scripts/pages-fixture-gateway.py` by path (as that one loads the reference fixture) so Jobs, Kanban, Artifacts,
sign-in, `/api/ws` and the `/__fixture/*` controls keep working, and adds everything in §§2–18. Every JSON-RPC method
it adds checks its params against the keys listed in this spec and answers error 4000 for any other key, as Hermes
does. Every write is recorded in `GET /__fixture/state`.

```
# builders (ports 10050–10054)
python3 scripts/fixtures/morepages-gateway.py --port 10050 --credentials build/fixtures/morepages.json \
  --files build/fixtures/morepages-files --tick-seconds 0
python3 scripts/fixtures/morepages-gateway.py --port 10052 --credentials build/fixtures/morepages-old.json \
  --files build/fixtures/morepages-files-old --tick-seconds 0 --old-gateway      # 404 / -32601 for every new route
python3 scripts/fixtures/morepages-gateway.py --port 10053 --credentials build/fixtures/morepages-wh.json \
  --files build/fixtures/morepages-files-wh --tick-seconds 0 --webhooks-off
python3 scripts/fixtures/settings-gateway.py --port 10051 --hermes-cookies --credentials build/fixtures/morepages-settings.json   # U5

# stress tester: the same scripts on 10055–10059
```

`scripts/e2e-morepages.sh <UDID>` (a copy of `scripts/e2e-pages.sh` with these ports; it refuses a busy port, never
prints credentials, stops every fixture it started) runs `-only-testing:HermesHQNativeUITests/MorePagesTests`
(`HQN_MOREPAGES_ONLY="testU3_AddAttachment,…"` narrows it). Simulators: `HQN-m9-morepages` for builders,
`HQN-m9-morepages-s` for the stress tester, created with
`xcrun simctl create "HQN-m9-morepages" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`; never the
default simulator in the scripts. Unit tests: `scripts/build.sh test <udid>`.

Never point any of this at a real gateway, and never connect to a local port this stream did not start.

---

## 21. STRESS PLAN

For the stress tester (ports 10055–10059, simulator `HQN-m9-morepages-s`). Each line is a thing to try and what must
hold. A unit may go to TestFlight only after its lines pass and the screenshots were looked at.

**Load**
- Artifacts with 5,000 records where 200 files repeat 2–500 times: one row each, correct ×N, scrolling stays smooth,
  the kept index reloads from disk with counts intact.
- Linked notes: a chain 60 deep, then hold Back and jump to the first; a 2 MiB note; a note with 3,000 links.
- Kanban: upload 20 files one after another to one task; a 24.9 MB file and a 25.1 MB file; a 0-byte file; names with
  emoji, spaces, 200 characters, a leading dot, `"` and a newline (refused before upload).
- Profiles with 60 bots; a 400 KB SOUL.md (typing stays responsive, Save sends it whole).
- Messaging with 40 platforms and 500 pending people; Webhooks with 300 subscriptions; Import Sessions paged to
  2,000 rows; Spawn Tree with 400 children at depth 6; Star Map with 5,000 nodes and 10,000 edges; logs of 5,000
  lines with 4,000-character lines.
- More search with 2,000 sessions loaded: results appear within one frame of a keystroke after the first.

**Speed**
- Every page pushed from More shows its skeleton in the same frame as the push; nothing blocks the main thread on
  JSON (decode `@concurrent`). Time from tap to first rows against the fixture, per page, in the report.
- Star Map probe (§17.3). Typing in the SOUL editor with the 400 KB file: no keystroke over 16 ms.
- Search fold/unfold on each page 30 times quickly: no stuck field, no doubled bar, no jump of the first row.

**Bad network** (fixture `/__fixture/fail` with `delay`, and the simulator's link turned off)
- Each first read delayed 20 s then failing: skeleton, then the error state with Try Again that works.
- Upload: connection dropped at 50 %; 413; 500; a 10-minute stall (the row stays "Adding…", Cancel by closing the
  sheet stops the upload and removes the body file).
- SOUL Save with the link off: the notice with Try Again; turn the link on, Try Again saves; nothing typed lost.
- Gateway restart from Status & Maintenance and from Messaging: the socket drops, the page keeps its state and resolves.
- Offline on every page that has data: data stays, writes disabled with the reason; offline with no data: the page's
  "Can’t Load …" state, never a blank page.
- Old gateway (`--old-gateway`): rows for missing routes are not in More; More search never offers them.

**Bad data**
- Every decoder gets: missing fields, nulls, numbers as strings, an empty object, an array where an object was
  expected, 5 MB of JSON, non-UTF-8 bytes. Nothing crashes; the page shows its error state or skips the bad row.
- Names and titles with RTL text, emoji, zero-width characters, 1,000 characters, HTML, Markdown and newlines in
  every list (rows wrap or truncate cleanly, VoiceOver reads them).
- Linked notes: links to `../../../../etc/passwd`, `file:///…`, `javascript:…`, a data URL, a path with `%00`, a
  link to a 40 MB binary, a link to itself. None crashes; paths are only ever sent to the gateway's own download
  route with the session scope; nothing but a real `http(s)` link leaves the app.
- A webhook secret, a messaging key and a SOUL draft never appear in the diagnostic log (`scripts/hqn-logs.py`),
  in a screenshot after the sheet closes, or in `UserDefaults`.
- Duplicate ids in lists (profiles, webhooks, subagents): the diffable snapshot never traps.

**Interruption**
- Background the app, lock the phone and take a call during: an upload, a SOUL edit, a Telegram setup, an import, an
  update, a pinch on the Star Map. Coming back: the upload finished or failed cleanly; the SOUL draft is there; the
  Telegram sheet either continues or says it expired.
- Rotate (where the app rotates), Split keyboard / hardware keyboard attach during the SOUL edit.
- Switch gateways (the title switcher) with each page open: the page pops to More's root for the new gateway; no
  data of the old gateway shows.
- Sign out with each page open and with an upload running.
- A push notification tapped while the SOUL editor has unsaved text: the Discard question comes first.
- Memory warning with the Star Map and a 2 MiB note open.

**Relaunch**
- Kill the app on each new page and relaunch: More is selected with the tab bar showing, the page is restored or
  More's root shows (never a page over a chat with no tab bar, `MEM/more-tab-restore-fix.md`), Back leads to More.
- Kill during a SOUL edit: the draft is offered on reopening the editor. Kill during an upload: no half file listed,
  no leftover body file in the temporary folder.
- The chosen Files root, the Star Map's Map/List choice and the hidden-row memory survive; a typed search does not.

**Accessibility sizes and VoiceOver**
- Every new screen at xSmall, default, AX1, AX3 and AX5, light and dark, Increase Contrast and Reduce Transparency:
  no truncated button label, no clipped row, tiles reflow (U7), segmented controls keep whole words, the SOUL
  editor's last line stays above the keyboard.
- VoiceOver walk of each page: order is top to bottom, every control has a label and a trait, switches read their
  state, the Star Map is usable through List, the edit bar reads "Cancel" and "Save, dimmed" before changes.
- Escape, Return and Tab on a hardware keyboard on every page (U8); Full Keyboard Access can reach every control.
- Reduce Motion: no fly-ins on the Star Map, searches fold without a slide.

**Never**
- "Dispatch" in any label, alert, VoiceOver string or log line the user can read (`grep -rn -i dispatch` over the new
  Swift files must hit only bundle ids and storage keys).
- A control that does nothing; a tab-bar accessory; fake glass.

---

## 22. Files to add or change (map for builders)

| Unit | New | Changed |
|---|---|---|
| U1 | `Tests/Pages/ArtifactRepeatsTests.swift` | `HermesKit/Pages/PagesWire.swift`, `ArtifactCollector.swift`, `App/Pages/Artifacts/ArtifactsViewController.swift` |
| U2 | `HermesKit/Pages/ArtifactLinks.swift`, tests | `App/Pages/Artifacts/ArtifactTextViewController.swift`, `ArtifactsViewController.swift` |
| U3 | tests | `HermesKit/Pages/KanbanAPI.swift`, `HermesKit/Attachments/MultipartBody.swift`, `App/Pages/Kanban/KanbanTaskSheet.swift` |
| U4 | — | `App/Kit/PageBarCapsule.swift`, `App/Pages/PageKit.swift`, Jobs/Kanban/Artifacts/Capabilities view controllers |
| U5 | tests | `App/Bots/BotListModel.swift`, `BotsViewController.swift` |
| U6 | `scripts/licenses.py`, `App/Resources/Licenses/licenses.json`, `extra.json`, tests | `App/Settings/AboutView.swift` |
| U7 | `App/Kit/QuickActionTiles.swift`, tests | `App/BotInfo/BotInfoSheet.swift` |
| U8 | `App/Root/EscapeRule.swift`, tests | `App/Root/MainTabController.swift` |
| U9 | `App/Kit/NavEditBar.swift`, `App/Pages/More/Profiles/*`, `HermesKit/Pages/More/ProfilesAPI.swift` | `App/Pages/PagesTabs.swift` (registry append) |
| U10 | `App/Pages/More/Workspace/*`, `HermesKit/Pages/More/MoreWorkspaceRoot.swift` | `App/Chat/Menus/WorkspacePages.swift` (pushable, root header) |
| U11–U16 | `App/Pages/More/<Page>/*`, `HermesKit/Pages/More/<Page>API.swift` + stores | — |
| U17 | `HermesKit/Pages/More/MoreSearch.swift`, tests | `App/Pages/MoreViewController.swift` |
| all | `scripts/fixtures/morepages-gateway.py`, `scripts/e2e-morepages.sh`, `UITests/pages/MorePagesTests.swift` | `docs/briefs/m9/morepages-rows.md`, `morepages-report.md` |

Other streams' hooks left in place: `BotList.emptyState` (groups, L207), `BotInfoTileHooks` (talk, screen),
`PagesTabs` row registry (capabilities' Connect Apps and issue counts L853/L875 draw on More's rows: the row model
gains an optional trailing `value` string and `valueIsIssue` flag, unused by this stream).

## 23. Known gaps this spec chooses (to be repeated in the report)

- No tab-bar accessory (owner decision pending, D-M1).
- Files and Review are read-only (D-M10): no edit, stage, commit, push, pull request.
- Messaging: no WhatsApp QR flow (D-M11).
- Status & Maintenance: no Sessions part (D-M12); no debug-share upload.
- Spawn Tree: read-only (D-M13). Star Map: no map codes, timeline, edit or delete (D-M14).
- Profiles: no New Profile, no import/export archive, no remote-host override (desktop-only flows; D-M9).
- Wording for Messaging, Status & Maintenance and Import Sessions was taken from the vendored English strings
  (`V/i18n/en.ts`) and turned into the app's Title Case plain language; a builder must check each page's block in
  `B/fe-pages-gates.ts` for a phone rewrite of the same string and prefer it.
