# 3x — Jobs editor (m9 stream `jobs`)

Implementation-ready spec for the 10 rows of `docs/parity-240.md` §15 assigned to this stream (`docs/briefs/m9/assignment.md`, section "jobs"; outcomes in `docs/briefs/m9/jobs-rows.md`). It builds on `docs/spec/1x-pages.md` (the Jobs page as shipped) and replaces its decision D-P5 ("New Job / Edit Job are not built this round, and no control for them is shown").

Worktree `/Users/me/Projects/hermes-hq-native-wt/m9-jobs`, branch `m9/jobs`. Ports 10000-10004 (builders), 10005-10009 (stress tester). Simulators `HQN-m9-jobs` (builders), `HQN-m9-jobs-s` (stress tester).

## 0. Reading key

- `V/` = `/Users/me/Projects/hermes-hq-native-ref240/vendor/hermes/apps/desktop/src/` (the vendored renderer).
- `B/` = `/Users/me/Projects/hermes-hq-native-ref240/build/` (the gates that patch the renderer for the phone).
- `S/` = `/Users/me/Projects/hermes-hq-native-ref240/src/` (phone code).
- `H/` = `/Users/me/.hermes/hermes-agent/` (the gateway, read only).
- The ref240 tree holds no built bundle, so "what the phone shows" is the vendored source with the gates applied; where a gate changes the vendored behaviour both are cited.
- **DECISION** marks a choice made here without the owner (the owner is asleep; nobody waits for a human).

## 1. The rows

| # | Parity row | Was | Plan |
|---|---|---|---|
| R1 | L621 Paged sections (40 rows) for very long lists | ❌ | Proposed **web-shell-only**; long-list checks instead (§6.1) |
| R2 | L626 Edit Job… entry from row menu | ❌ | Build (§6.2) |
| R3 | L634 Edit Job button in the failed-run banner | 🟡 | Build (§6.3) |
| R4 | L638 Run history shared/deduplicated reads | 🟡 | Finish and prove (§6.4) |
| R5 | L640 New Job editor: name, prompt, frequency presets | ❌ | Build (§6.5) |
| R6 | L641 Start from template (blueprints) with option labels | ❌ | Build (§6.6) |
| R7 | L642 Time fields and the gateway-clock note | ❌ | Build (§6.7) |
| R8 | L643 Delivery picker, home-channel note, default local | ❌ | Build (§6.8) |
| R9 | L644 Model override picker | ❌ | Build (§6.9) |
| R10 | L645 Custom cron expression field | ❌ | Build (§6.10) |

Nothing here needs a change to the push relay, a plugin, or the owner's real gateway: every call is an existing gateway REST route (§3). So there is no `docs/owner-todo/jobs.md`. The one thing only the owner's iPhone can settle is listed in §10 (risks), not as a blocker.

## 2. What the owner has said (memory notes that bind this work)

- Rows: "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt top and bottom" (row-padding-feedback). Every wrapping row in the editor (prompt, notes, delivery rows, blueprint rows) uses 12 pt, as `1x-pages.md` D-P10.
- Glass: "It isn't Liquid Glass. So much of this is wrong." (liquid-glass). The editor is a system sheet with system bars; no blur views standing in for glass. 2026-10-31, on build 538's New Job ("a sad failed first attempt"; the second template card ran off the strip's card and looked broken): "the entire pop-up should be liquid glass, and then as much that is inside of it as possible should be liquid glass too, with all of it themed so that it looks right on top of liquid glass". So the sheet stays glass at full height and its picks are glass (06 §8 rules 0 and 5).
- Sheets: the owner asked for no "a pop up on top of a pop up" (sheet-pages). So the model picker and any long choice list **push inside the sheet's navigation stack**; the editor never presents a second sheet. Alerts and the system menus are not sheets.
- One design: "edit bot and edit head are not the same design. makes no sense." (chat-visibility-alignment). New Job and Edit Job are the same page with the same order and the same bar; only the title, the trailing word and the create-only rows differ.
- Haptics (taptic-feedback-gaps): success after a confirmed write, error on a failed one, selection on a pick.
- The word "Dispatch" is never user-visible. Wording follows the web app's where it has any (§5).
- "glass sheet shake" and the liquid-glass note list "keyboard in a sheet" and "job sheets" among things never verified. They are in the stress plan (§9).
- One feature per build (feedback-one-feature-at-a-time): this stream is one feature, "make and edit jobs".

## 3. Wire

All REST, same conventions as `1x-pages.md` §2.2 (`PagesREST`, cookie session, `{"detail": …}` errors, 15 s slow-answer rule). No JSON-RPC: `cron.manage` is not used (unknown params answer 4000). The socket gives only `cron.changed` and `gateway.ready.change_events`.

`<bot>` is the profile a job belongs to ("default" for the first bot). Every route takes `?profile=`.

### 3.1 Reads the editor makes

| Call | When | Answer |
|---|---|---|
| `GET /api/cron/delivery-targets?profile=<bot>` | editor opens; again when the Bot row changes | `{"targets":[{"id":"local","name":"Local (save only)","home_target_set":true,"home_env_var":null},{"id":"telegram","name":"Telegram","home_target_set":false,"home_env_var":"TELEGRAM_HOME_CHANNEL"},{"id":"bot-chat:default","name":"Bot Chat (default)","home_target_set":true,"home_env_var":null}]}` (`H/hermes_cli/web_routers/cron.py:688-711`, `H/cron/scheduler_delivery.py:543-577`) |
| `GET /api/model/options?explicit_only=1&profile=<bot>` | editor opens, unless script-only or a blueprint is chosen (`V/app/cron/index.tsx:1108-1118`) | `{"providers":[{"slug":"anthropic","name":"Anthropic","models":["claude-sonnet-5"],"authenticated":true}]}` (`H/hermes_cli/web_routers/models.py:138-167`) |
| `GET /api/cron/blueprints?profile=<bot>` | Jobs page load and refresh; New Job opens (create only, `V/app/cron/index.tsx:1098-1106`) | `{"blueprints":[{"key":"morning-brief","title":"Morning brief","description":"…","category":"…","tags":[],"fields":[{"name":"time","type":"time","label":"What time?","default":"08:00","options":[],"optional":false,"strict":true,"help":"24h local time, e.g. 08:00"},{"name":"deliver","type":"enum","label":"Where to deliver?","default":"origin","options":["origin","local","telegram"],"optional":false,"strict":false,"help":""}],"command":"…","appUrl":"…"}]}` (`H/hermes_cli/web_routers/cron.py:858-905`, `H/cron/blueprint_catalog.py`) |
| `GET /api/cron/jobs/<id>?profile=<owner>` | Edit Job opens (fresh copy before editing) | the job record |

A read that fails never blocks the editor (§6.8, §6.9, §6.6 say what shows instead).

### 3.2 Create

`POST /api/cron/jobs?profile=<bot>` (`V/api/cron.ts`, `V/app/cron/index.tsx:559-607`, model `H/hermes_cli/web_models.py:310-330`)

```json
{"prompt":"Summarize my unread mail","schedule":"0 9 * * 1-5","name":"Morning mail","deliver":"local,telegram","model":"claude-sonnet-5","provider":"anthropic"}
```

- `name` left out when empty; `deliver` is the comma-joined list, never empty (falls back to `"local"`); `model` and `provider` left out when the model is "Default (global model)".
- 200 → the created job. 400 → `{"detail":"Invalid schedule 'x'. Use:\n  - Interval: …"}` (multi-line, `H/cron/jobs.py:787-858`).

### 3.3 Edit

`PUT /api/cron/jobs/<id>?profile=<owner>` body `{"updates":{…}}` (`V/app/cron/cron-job-model.ts:130-153`).

```json
{"updates":{"name":"Morning mail","schedule":"30 8 * * 1-5","deliver":"local","model":null,"provider":null}}
```

**DECISION D-J1 — send only what changed.** The web sends `deliver`, `name`, `schedule` always (and `prompt`, `model`, `provider` for agent jobs). The gateway recomputes the next run whenever `schedule` is in the updates (`H/cron/jobs.py:2116-2150`), and a once/interval job's stored schedule is shown as words that are not a schedule the gateway parses again. Native therefore sends a key only when its value differs from the job as loaded. `model` and `provider` always travel together; `null` for both clears the override. If nothing changed, Save is disabled (the web does the same on the phone, `B/fe-pages-gates.ts:375-380`), so an empty `updates` (a gateway error) is never sent.

- 200 → the updated job. 400 → `{"detail": …}`. 404 → `{"detail":"Job not found"}`.

### 3.4 Create from a blueprint

`POST /api/cron/blueprints/instantiate?profile=<bot>` body `{"blueprint":"morning-brief","values":{"time":"07:30","deliver":"local"}}` (`V/app/cron/index.tsx:614-635`).

- 200 → the created job. 404 `Unknown blueprint: <key>`. **422** a field error, e.g. `missing required value: time (What time?)`, `invalid time '25:00' — use HH:MM (24h)`. 400 anything else.

### 3.5 Run history (R4)

`GET /api/cron/jobs/<id>/runs?limit=20&profile=<owner>`, unchanged, always through `JobsStore.loadRuns` (`SharedReads`).

## 4. Native design

Fits `docs/ARCHITECTURE.md`: logic in HermesKit (no UIKit), UIKit navigation, SwiftUI form inside `UIHostingController`, one `@Observable` model per sheet.

### 4.1 New files

| File | Holds |
|---|---|
| `HermesKit/Pages/JobSchedule.swift` | `JobFrequency` (daily, weekdays, weekly, monthly, hourly, every15, custom) with the web's expressions; `frequency(for expr:)` = `scheduleOptionForExpr` (`V/app/cron/index.tsx:183-236`); `JobTimeFields {hour, minute, weekday, day}` with defaults 9, 0, 1, 1 (`S/audit-c-format.ts:243-261`); `compose` (`:263-270`); `expression(for:keeping:)` = `cronForPreset` (`:275-277`); `summary` = `scheduleSummary` (`V/…/index.tsx:238-268`). |
| `HermesKit/Pages/JobDelivery.swift` | `DeliveryTarget` (id, name, homeTargetSet, homeEnvVar); `parse` (empty → `["local"]`, de-duplicated), `toggle` (the last one cannot be unchecked) (`V/…/cron-job-model.ts:82-103`); row building: label, home-channel note, the leave-out rule, kept unknown targets, Bot Chat names (§6.8). |
| `HermesKit/Pages/JobBlueprints.swift` | `Blueprint`, `BlueprintField`; `initialValues`, `isExampleDefault`, `optionLabel`, `fieldHelp`, `cleanFieldError` (§6.6). |
| `HermesKit/Pages/JobEditor.swift` | `JobEditorModel` (`@Observable`): mode (create / edit(job)), fields, loaded targets/models/blueprints, `isComplete`, `isDirty`, `validate()`, `createBody()`, `updates()` (D-J1), `save()`; `saving`, `failure`. |
| `App/Pages/Jobs/JobEditorSheet.swift` | The sheet: `JobEditorViewController` (hosting) wrapped by `ChatSheet.wrap`, bar items, discard guard, the pushed `JobModelPickerViewController`. Pattern copied from `App/Pages/Kanban/NewTaskSheet.swift`. |
| `scripts/fixtures/jobs-gateway.py`, `scripts/e2e-jobs.sh` | §7. |
| `Tests/Pages/JobScheduleTests.swift`, `JobDeliveryTests.swift`, `JobBlueprintTests.swift`, `JobEditorModelTests.swift`, `JobsFixtureTests.swift`; `UITests/pages/JobEditorTests.swift` | §8. |

Both `project.yml` and `project-original.yml` must build after the files are added.

### 4.2 Changed files

- `HermesKit/Pages/JobsStore.swift`: `create(body:profile:)`, `update(_:updates:)`, `instantiate(blueprint:values:profile:)`, `deliveryTargets(profile:)`, `blueprints` (kept per scope, cached beside the jobs as `blueprints-<scope>.json`), `loadBlueprints()`. Each write refreshes the list on success.
- `HermesKit/Pages/PagesWire.swift`: decoding for the three new answers; lenient (unknown keys ignored, a missing `fields` is an empty list, a wrong-typed entry is dropped, not fatal).
- `HermesKit/Pages/JobWords.swift`: `humanDeliver` gains the label for local (§5).
- `App/Pages/Jobs/JobsViewController.swift`: the `+` bar button, the Blueprints section, the new empty text.
- `App/Pages/Jobs/JobActions.swift`: `edit(_:from:)`, "Edit Job…" in the menu.
- `App/Pages/Jobs/JobDetailViewController.swift`: "Edit" bar button, "Edit Job" in the error card, runs reload on `cron.changed` and on return to the foreground.

### 4.3 The sheet

`ChatSheet.wrap(editor, title:, detents: [.large()])`. **DECISION D-J2:** large only. The form has a keyboard and up to six groups; a medium detent would hide the field being typed in.

Bar (`B/fe-pages-gates.ts:375-380`: Cancel / title / Save or Create, "Saving…" while saving):

- Leading: the system close button `✕` (`sheet.close`), as every native sheet. **DECISION D-J3:** `✕`, not the word "Cancel", so the editor matches the other native sheets ("not the same design. makes no sense.").
- Title: **New Job** / **Edit Job** (`B/ui-pages-gates.ts:200-215`).
- Trailing, prominent: **Create** / **Save**. Disabled while the form is incomplete (create) or unchanged or incomplete (edit). While saving it is a spinner, the form is disabled, `isModalInPresentation = true`. **DECISION D-J4:** spinner, not the word "Saving…", as `NewTaskSheet`.

Closing with unsaved changes (✕ or swipe down): `EditingGuard.askToDiscard` (`App/BotInfo/BotInfoSheet.swift:90`), "Discard Changes" / "Keep Editing". **DECISION D-J5:** the web closes without asking; on a phone a mis-swipe would throw away a typed prompt, and the app already asks this way for a bot. A pristine form closes at once.

No field takes focus when the sheet opens (`B/audit-c-gates.ts:160-165`, no autofocus on touch). The keyboard dismisses on scroll (`.scrollDismissesKeyboard(.interactively)`).

### 4.4 Form order

As the phone's order (`S/phone-audit-c.css:158-166`): Name, Prompt, Frequency, schedule, Deliver to, Model. Native adds two create-only rows on top.

1. **Start from** — create only, only when blueprints exist (§6.6).
2. **Bot** — create only, only with two or more bots (D-J6).
3. **Name**.
4. **Prompt** (or the script-only note).
5. **Frequency**, then the time fields and summary, or the Custom Schedule field.
6. **Deliver To**.
7. **Model** — not for script-only jobs or blueprints.

When a blueprint is chosen, rows 3-7 are replaced by the blueprint's own fields (§6.6), as the web (`V/…/index.tsx:1282-1312`).

**2026-10-31 redesign (approved, merged 336271ec, build 538).** The owner asked to "really improve the job creation page". The new order is:

1. **Bot**: a strip of faces.
2. **Start From**: cards, "Write Your Own" first, with See All opening the searchable list.
3. **Prompt**, with **Name** beneath it. The name's grey placeholder is the name Hermes gives an unnamed job: the prompt's first 50 characters.
4. **Schedule**: frequency chips, Weekly's day buttons, time, summary and "First run: …" (create) or "Next run: …" (edit). The clock note shows only when the gateway's clock differs from the phone's.
5. **Send Results To**: "Run History Only" (its own choice, cleared by any other place) plus each place with its platform mark. A platform with no home channel is a footer note naming `/sethome`, not a grey row.
6. **Bot Chats**: each bot's face and name.
7. **Model**.
8. **Run Once Now** (create only, off by default).

Other changes:
- The intro line is gone.
- Weekly takes any set of days (cron `1,3,5`).
- UI tests find the first header by `job.editor.top`.

**2026-10-31 glass pass (branch `feat/job-editor-glass`).** In the iOS look:
- The sheet is glass at every height (`hqGlassPage(everyHeight: true)`); the Desktop Look's stays solid.
- The Bot, Start From and Schedule strips run edge to edge with nothing behind them. Their picks are interactive
  glass in one container: bot tiles and template cards radius 20, the chosen one tinted and ringed; chips are 36 pt
  capsules, the chosen one filled with the tint. See All is a small glass capsule (under the title at the
  accessibility sizes).
- The cards (Prompt and Name, Time, places, Model, Run Once Now, a blueprint's fields) are solid, 16 pt in from the
  sheet's edges on a 402 pt phone and 20 pt on wider ones and in the Desktop Look, as iOS's own gutter.
- Headers are full ink and semibold, footers full ink, placeholders `cardNote`: every line passes 4.5:1 in light and
  dark in both looks, except the system's dimmed Create.
- Every header sits the same distance above its strip or card. The chips sit 10 pt above the Time card, so Schedule
  reads as one group.

**DECISION D-J6 — the Bot row.** Under "All bots" the web creates the job for `default` without saying so (`V/…/index.tsx:614-635`, All → 'default'). Native shows a row **Bot** with a menu of the bots (original robot head, name), preselected to the page's bot, or the first bot under All. Changing it re-reads delivery targets, models and blueprints. With one bot the row is absent. Edit shows no Bot row: a job cannot move between bots.

### 4.5 Entry points

| Where | Control | Opens |
|---|---|---|
| Jobs page bar, trailing | `+` (`UIBarButtonItem(systemItem: .add)`, accessibility label "New Job", id `jobs.new`) | New Job (`V/…/index.tsx:685`) |
| Jobs list, section "Blueprints" | a row per blueprint | New Job with that blueprint chosen (`:686-700`) |
| Row menu (`…` and long press) | "Edit Job…" | Edit Job (R2) |
| Job page bar, trailing | "Edit" (id `job.edit`) | Edit Job (`B/audit-c-gates.ts:152`) |
| Job page, failed-run card | "Edit Job" | Edit Job (R3) |

Read-only gateway (`store.readOnlyGateway`): every entry stays visible and answers with the notice "Changes are off for this gateway." (`1x-pages.md` §2.7); the `+` and "Edit" bar buttons are disabled. A control is never shown that silently does nothing.

### 4.6 After a save

- Create: sheet closes, HUD **Job Created** (`B/r21-pages-gates.ts:47-54`), success haptic, list refreshed, the new row is scrolled into view. **DECISION D-J7:** the job page is not opened by itself (the web does not either).
- Edit: sheet closes, HUD **Job Saved**, success haptic, list and the open job page refreshed (name, schedule, delivery, model lines, next run).
- Failure: the sheet stays, error haptic, the reason shows in a red-tinted note at the top of the form, scrolled into view (`B/stress-c-gates.ts:39-42`); everything typed is kept; the trailing button is live again.

## 5. Wording (exact)

From `V/i18n/en.ts:3356-3491` unless a gate is cited.

| Where | Text |
|---|---|
| Sheet titles | New Job · Edit Job |
| Trailing | Create · Save |
| Create footer under the first group | Schedule a prompt to run automatically. Choose how often it runs. (`B/fe-pages-gates.ts:143-145`) |
| Edit footer | Update the schedule, prompt, or delivery target. Changes apply on next run. |
| Name | label "Name", placeholder "Morning briefing", trailing hint "Optional" |
| Prompt | label "Prompt", placeholder "Summarize my unread Slack threads and email me the top 5..." |
| Script-only note | This job runs a script on the computer running Hermes. It has no AI prompt. (`B/audit-c-gates.ts:160-165`) |
| Frequency | label "Frequency"; Daily · Weekdays · Weekly · Monthly · Hourly · Every 15 minutes · Custom |
| Summaries | Every day at {t} · Weekdays at {t} · Every {Day} at {t} · Monthly on day {d} at {t} · At the top of every hour · Every hour at :{mm} · Every 15 minutes |
| Time fields | Time · Day · Day of the Month · Minutes Past the Hour (`S/cron-time-fields.tsx:1-39`) |
| Notes | Months without day {N} skip this run. · Times follow the clock on the computer running Hermes. |
| Custom | label "Custom Schedule", placeholder "0 9 * * * or weekdays at 9am", footer: Cron expression, or phrases like "every hour" or "weekdays at 9am". |
| Deliver To | label "Deliver To"; local row **Saved in Run History** (the web's "Saved in Hermes", `B/chat-gates.ts:107-114`; D-J8); "{Platform} — set a home channel first" (`V/…/index.tsx:1006-1010`) |
| Model | label "Model", "Optional"; first choice **Default (global model)** |
| Blueprints | section "Blueprints"; row "Start from"; first choice "Custom" |
| Validation | Prompt is required. · Schedule is required. · Prompt and schedule are required. |
| Failures (alert-free, in the form) | title line "Could not save the job" then the gateway's reason (`B/fe-pages-gates.ts:143-145`) |
| HUD | Job Created · Job Saved |
| Menu | Edit Job… |
| Failed-run card | Edit Job · Run Again |
| Discard | Discard Changes · Keep Editing |
| Empty Jobs page | title "No Jobs"; "Jobs run a prompt[ for {Bot}] on a schedule. Tap + to make one[, or start from a blueprint below]." (`B/r21-pages-gates.ts:40`) |
| Read-only | Changes are off for this gateway. |
| Slow answer (15 s) | "The gateway is taking a while. Check the list before trying again." (as `1x-pages.md` §2.2 for writes; a create that may have landed is not retried by itself) |

**DECISION D-J8 — "Saved in Run History" everywhere.** The job page's "Delivers To" line today says "Keep in Hermes (no message)" (the unlabelled fallback of `S/audit-c-format.ts:218-239`); the web phone passes the label "Saved in Hermes". Native passes its own label, so the page and the editor say the same thing: **"Saved in Run History"** (UX study #90, owner's "your judgement" call, 2026-10-22: "Hermes" read as the bot named Hermes; the results of a `local` job are kept in the job page's Run History, so the words say where to find them). Builders update any UI test asserting the old words.

**2026-10-31 update.** The redesign's editor calls `local` "Run History Only", and the owner asked whether the job page should match ("Yeah I think they should match, right?"). It now does:
- `localLabel` is **"Run History Only"** everywhere.
- `local` beside another place is left out of the "Delivers To" line ("local,telegram" → "Telegram"), because every result is kept in Run History anyway.
- Run Now says "Its result is kept in its Run History."

Gateway reasons are shown as sent, first line only when multi-line (the invalid-schedule detail is a paragraph of usage), trimmed to 200 characters. Empty or non-text reasons fall back to "The gateway did not say why."

## 6. Row by row

### 6.1 R1 — Paged sections (40 rows) for very long lists

**Web.** `S/ui-pages/job-sections.tsx:13-43`: when there are more than 100 jobs and a section has more than 40 rows, the section is cut into pages of 40 with "Previous" / "{label} a–b of N" / "Next" (`S/bounded-list.ts:4-23`). The list cache is capped at 300 000 characters (`S/jobs-list-cache.ts`).

**Why it exists.** Only to bound the WebView's DOM: a thousand job rows are a thousand live elements with menus. It is not a product feature (nothing is shown that an unpaged list would not show; the pager is absent below 100 jobs).

**DECISION D-J9 — proposed web-shell-only.** `JobsViewController` is a `UICollectionView` with a diffable data source: cells are recycled, so only what is on screen exists. Paging would make a native list worse (two taps to reach row 41, no scroll position to restore, VoiceOver stops at the pager). Native keeps one continuous list per section, with the existing "Show N Completed" fold.

**What must hold instead (acceptance).** Against `jobs-gateway.py --jobs 1000`:
1. The list appears within 1 s of the answer; scrolling top to bottom drops no more than 2 frames in any second on the simulator (Instruments or `XCTOSSignpostMetric.scrollDecelerationMetric`).
2. Applying a refresh of 1 000 jobs takes under 100 ms on the main thread (snapshot built off the main actor or diffed by id only).
3. Relaunch paints the list from the cache before the network answers; the cache file stays under 2 MB (**DECISION D-J10:** cap the cached list at 500 jobs per scope, the rest arrive with the network; the web's cap is 300 000 characters, about the same).
4. Search over 1 000 jobs filters within one frame of a keystroke at normal typing speed.
5. Memory after scrolling the whole list returns within 10 MB of its starting value.

Outcome once these are seen passing: `web-shell-only`, with the measurements as proof.

**Fixture:** `python3 scripts/fixtures/jobs-gateway.py --port 10000 --credentials build/fixtures/jobs.json --files build/fixtures/jobs-files --jobs 1000 --tick-seconds 0`.

### 6.2 R2 — "Edit Job…" in the row menu

**Web.** `S/ui-pages/jobs.ts:25-33`: Run Now, Pause/Resume, **Edit Job…**, Delete Job (destructive, last).

**Native.** `JobActions.menu`: add `UIAction(title: "Edit Job…", image: UIImage(systemName: "pencil"))` after Pause/Resume, before the inline Delete Job group. It calls `JobActions.edit(job, from:)`, which presents the sheet from `topmost`. The same menu serves the `…` button and the long-press, so both gain it.

**States.**
- Busy job (a run, pause or delete in flight): the entry is disabled, as the others.
- Read-only gateway: the notice, no sheet.
- Job deleted elsewhere while the sheet is open: Save answers 404 → in-form reason "This job no longer exists." (**DECISION D-J11**, plain words for `Job not found`), the list refreshes behind the sheet.
- The fresh `GET /api/cron/jobs/<id>` on open fails: the sheet opens with the list's copy (never a blocking spinner).
- `cron.changed` for this job while the sheet is open and pristine: the fields take the new values. While dirty: the fields are left alone (**DECISION D-J12:** the person's typing wins; D-J1 means only their own changes are sent, so a change made elsewhere to another field is not overwritten).

**Acceptance.** Menu shows the four entries in order with "Edit Job…" third; tapping opens "Edit Job" with the job's values; VoiceOver reads "Edit Job…"; long-press menu identical.

**Fixture:** base command (§7).

### 6.3 R3 — "Edit Job" in the failed-run banner

**Web.** `V/app/cron/index.tsx:843-860`: the banner "Last run failed: …" has **Edit job** and **Run again**; Title Case on the phone (`B/ui-pages-gates.ts:200-215`).

**Native.** `JobDetailView.errorCard`: two buttons side by side, **Edit Job** (bordered) then **Run Again** (bordered prominent, as now). At accessibility sizes they stack, each full width. Ids `job.error.edit`, `job.error.run`. "Edit Job" opens the same sheet as R2. The job page also gains the bar button "Edit" (`B/audit-c-gates.ts:152`).

**States.** Read-only: notice. While the job is busy: both disabled. After a save the card stays until a run succeeds (the gateway clears `last_error`, not the app).

**Acceptance.** On `j-fail`: the card shows both buttons; Edit Job opens the editor with j-fail's values; saving a new prompt shows "Job Saved" and the page's prompt changes; Run Again still works.

**Fixture:** base command; job `j-fail`.

### 6.4 R4 — Run history shared/deduplicated reads

**Web.** `S/cron-run-once.ts:59-79` `sharedRead(key, load, joinMs = 250)`: callers within 250 ms of a read's start share it; a later caller while it is in flight gets one trailing read; a finished read is never reused. Wired to `getCronJobRuns` by `B/fe-pages-gates.ts:140-141`. The job page re-reads runs every 8 s while a run is expected, else every 60 s, on `cron.changed`, when `lastRunAt` changes, and when the page becomes visible again; it stops when parked (`V/…/index.tsx:896-897`, `B/fix160-pages-gates.ts:203-205`).

**Native today (why 🟡).** `SharedReads<[CronRun]>` in `HermesKit/Pages/JobRuns.swift` is already a faithful port with unit tests. Missing: the page does not re-read on `cron.changed` or on return to the foreground, and nothing proves end to end that simultaneous triggers make one request.

**Build.**
1. `JobDetailViewController`: subscribe to the store's `cron.changed` for this job and to `UIScene.willEnterForegroundNotification`; both call `store.loadRuns(job)`. Stop the timer and the subscriptions in `viewDidDisappear`, restart in `viewWillAppear`; nothing runs while the app is in the background.
2. Every runs read in the app goes through `store.loadRuns` (grep for the path: one call site).
3. The key stays `job.key` (owner + id); one store per signed-in account, so the web's connection part of the key is implied.

**States.** Unchanged: "Couldn’t load the run history." with "Try Again" (web: "Couldn’t load run history" / "Try again", `B/fe-pages-gates.ts:446-449`), "No saved runs yet", the list. A failed shared read fails every joined caller once, with one message.

**Acceptance.**
1. Fixture test: the fixture logs requests (`GET /__fixture/state` → `requests`). Broadcast `cron.changed` and change `last_run_at` in the same tick while the page is open → exactly **one** `/runs` request. Trigger again while that read is held open (`/__fixture/fail` with a delay) → exactly **one** more, starting after the first ends.
2. Background the app for 70 s → zero `/runs` requests meanwhile; one on return.
3. Leave the job page → zero further `/runs` requests.
4. Unit: the three `SharedReadsTests` still pass; add "a failed read fails all joined callers and is not cached".

**Fixture:** `… jobs-gateway.py --port 10000 … --tick-seconds 2` (ticks drive `cron.changed`).

### 6.5 R5 — New Job editor: name, prompt, frequency presets

**Web.** `CronEditorDialog` (`V/app/cron/index.tsx:1065-1457`). Presets (`:105-113`): Daily `0 9 * * *`, Weekdays `0 9 * * 1-5`, Weekly `0 9 * * 1`, Monthly `0 9 1 * *`, Hourly `0 * * * *`, Every 15 minutes `*/15 * * * *`, Custom. Initial values (`:1139-1148`): empty name and prompt, Daily, deliver `local`, model default. Changing the preset keeps the chosen time and day (`cronForPreset`, `B/fe-pages-gates.ts:132-138`). Validation (`V/…/cron-job-model.ts:23-40`). On the phone Create is disabled until the form is complete (`B/fe-pages-gates.ts:375-380`).

**Native.**
- **Name**: single-line `TextField`, words capitalised, placeholder "Morning briefing".
- **Prompt**: `TextField(axis: .vertical)`, 3 to 10 lines then scrolls inside, sentences capitalised, 12 pt vertical padding.
- **Frequency**: a row with a `Menu` picker of the seven names (selection haptic on change). Under it the schedule group (§6.7 or §6.10).
- Complete = prompt not blank (unless script-only) and schedule not blank. Create is disabled otherwise. If Create is somehow fired incomplete, the validation sentence shows in the form.
- Create body per §3.2.

**Edit.** The preset is found with `frequency(for:)` from the job's expression; anything it cannot classify (intervals, once, phrases, odd cron) opens as **Custom** with the stored expression (or, for non-cron schedules, the stored display text) in the field. Script-only jobs (`jobIsScriptOnly`) show the note instead of the prompt; the prompt is not sent.

**States.** Opening (targets and models still loading: the form is usable at once, those two groups show a small spinner row) · ready · incomplete (Create disabled) · saving · failed (reason on top, form kept) · slow answer · read-only (never reached: entries refuse first) · keyboard up (the focused field stays above the keyboard) · offline (Create answers with the connection reason; form kept).

**Acceptance.**
1. `+` opens "New Job"; Create is disabled; typing a prompt enables it.
2. Create with defaults posts exactly `{"prompt":"…","schedule":"0 9 * * *","deliver":"local"}` to `?profile=default` (fixture request log), HUD "Job Created", the row appears.
3. Each of the seven presets posts its expression.
4. A 400 keeps the sheet with the reason on top and all fields intact.
5. No 4000 "malformed" answer in any test (fixture log checked in tearDown).

**Fixture:** base command.

### 6.6 R6 — Start from template (blueprints) with option labels

**Web.** A "Blueprints" section in the Jobs list whose rows open New Job with that blueprint (`V/…/index.tsx:686-700`); in the editor a "Start from" select with "Custom" first and the chosen blueprint's description as a hint (`:1263-1280`); the blueprint's fields replace the normal ones (`:1282-1312`, `V/app/cron/blueprints.tsx:50-91`): `enum` and `weekdays` → a choice list, `time` → a time input, otherwise text with placeholder = help or label. Initial values (`blueprints.tsx:22-31`): the field default, except `deliver` '' or 'origin' → 'local'. Text defaults that are examples start empty (`S/stress-c.tsx:16-21`, `/^(?:an?|two or three|one or two|some)\s.*(?:\sor\s|,)/i`). Option labels (`S/audit-c-format.ts:350-363`): everyday → "Every day", weekdays → "Weekdays", weekends → "Weekends", day names capitalised, `*_hour` values up to 23 → "7 AM", `interval_min|minutes` → "Every N minutes" ("Every hour" at 60), `interval_h|hours` → "Every hour" / "Once a day" at 24 / "Every N hours", else capitalised. Help (`:367-371`): a time field → "Times follow the clock on the computer running Hermes."; "(24h)" stripped; capitalised. The deliver slot uses the delivery rows of §6.8. Field errors lose a leading `\d+:\s*` (`blueprints.tsx:35-37`). A 422 shows inline (`V/…/index.tsx:1245-1250`). The model picker is not shown for a blueprint.

**Native.**
- Jobs list: a last section **Blueprints** (header as the other sections), one row per blueprint: title, description on up to two lines, 12 pt padding, chevron. Filtered by the search text (title and description). Absent when the gateway has none or the read failed. The empty Jobs page adds ", or start from a blueprint below" only when the section is there.
- Editor row **Start from**: a `Menu` picker, "Custom" then the titles. Under it the description as a footer. With more than 12 blueprints the row pushes a searchable list instead (**DECISION D-J13**; the built-in catalog has 16).
- Blueprint fields, each a row labelled with the field's label (trailing "Optional" when optional), help as footer:
  - `time` → compact `DatePicker(.hourAndMinute)`; the value sent is "HH:mm", 24 h, built from the components (never a locale-formatted string).
  - `enum`, `weekdays` → `Menu` picker with `optionLabel`; the value sent is the raw option.
  - `deliver` slot → the Deliver to rows (single choice here: the slot takes one value), with "Where it was created" not offered (the phone is not a chat origin; `origin` → `local`).
  - else → `TextField`, placeholder help or label.
- Create is disabled while a non-optional field is blank.
- Posts §3.4. 422 → the reason (cleaned) on top; if it names a field (`… : <name> (`), that row gets a red footer.
- Switching "Start from" back to Custom restores what was typed in the normal form (kept in the model); switching between blueprints resets to that blueprint's initial values.

**States.** No blueprints (row and section absent) · blueprints loading (row absent until they arrive; the editor never waits) · chosen · field error · unknown field type (shown as text) · unknown blueprint 404 → "This blueprint is no longer available." and the list of blueprints is re-read.

**Acceptance.**
1. The Blueprints section lists the fixture's blueprints; tapping "Morning brief" opens New Job with "Start from: Morning brief", a time wheel at 08:00 and "Where to deliver?" on "Saved in Run History".
2. Create posts `{"blueprint":"morning-brief","values":{"time":"08:00","deliver":"local"}}` to `/api/cron/blueprints/instantiate?profile=default`.
3. Option labels: the fixture's `habit-checkin` shows "Every day / Weekdays / Weekends", `hydration-move` shows "Every 30 minutes / Every hour".
4. An example default ("a book or a course, …") starts empty with the help as placeholder.
5. Fixture `--blueprint-422` → the reason shows inline, sheet stays.
6. `--no-blueprints` → no section, no "Start from" row, empty text without the blueprint clause.
7. Unit: `optionLabel`, `fieldHelp`, `isExampleDefault`, `initialValues`, `cleanFieldError` against the web's cases.

**Fixture:** base command; variants `--no-blueprints`, `--blueprint-422`.

### 6.7 R7 — Time fields

**Web.** `S/cron-time-fields.tsx:1-39`, shown for daily, weekdays, weekly, monthly, hourly (`TIMED_PRESETS`); nothing for every-15 and custom.

| Preset | Fields | Note |
|---|---|---|
| Daily, Weekdays | Time | Times follow the clock on the computer running Hermes. |
| Weekly | Day (Sunday…Saturday, 0-6), Time | same |
| Monthly | Day of the month (1-31), Time | "Months without day {N} skip this run." when N > 28, then the clock note |
| Hourly | Minutes Past the Hour (:00, :05 … :55, plus the current minute if it is off the grid) | clock note |
| Every 15 minutes | none | summary only |

**Native.** One group under Frequency:
- **Time**: `DatePicker("Time", selection:, displayedComponents: .hourAndMinute)` in the compact style, which opens the system time wheel. The model holds hour and minute as integers; the picker's `Date` is built from them in a fixed calendar so the device's time zone and daylight saving never move the stored hour.
- **Day**: `Menu` picker, Sunday to Saturday (always the cron order, values 0-6; names from `Calendar.weekdaySymbols` of the app's language).
- **Day of the Month**: `Menu` picker 1-31.
- **Minutes past the hour**: `Menu` picker `:00 … :55` (+ the off-grid current value when editing).
- Footer: the summary sentence (§5) on the first line, then the notes. The time inside the summary is formatted in the device's 12/24 h style.
- The composed expression is `compose(frequency, fields)` (`S/audit-c-format.ts:263-270`): e.g. Weekly, Wednesday, 18:30 → `30 18 * * 3`.

**DECISION D-J14:** the raw cron line is not shown under a preset (the web shows it in the summary box on desktop; the phone's box holds the time fields and the sentence). Plain language first; the expression is visible by choosing Custom, which starts from the current expression.

**States.** Editing a job whose expression has an off-grid minute, a weekday list or a step (`0 9 * * 1,3`) → Custom (per `frequency(for:)`), never a preset that would silently simplify it.

**Acceptance.**
1. Weekly + Wednesday + 6:30 PM → posts `30 18 * * 3`; summary "Every Wednesday at 6:30 PM".
2. Monthly + 31 → the skip note with 31; + 28 → no skip note.
3. Hourly + :25 → `25 * * * *`, "Every hour at :25"; :00 → "At the top of every hour".
4. Switching Daily 07:15 → Weekly keeps 07:15 (`15 7 * * 1`).
5. With the simulator's time zone set to Asia/Tokyo and again to America/Los_Angeles, the posted expression for "9:00 AM" is `0 9 * * *` both times.
6. Unit: `frequency(for:)` round-trips every preset and rejects the odd forms; `compose` cases from the web's tests.

**Fixture:** base command.

### 6.8 R8 — Delivery picker

**Web.** `DeliverCheckboxes` (`V/…/index.tsx:1016-1063`): one check row per target; selected targets the gateway no longer lists are kept as rows; a platform without a home channel reads "{name} — set a home channel first" and cannot be chosen (`:1006-1010`); the value is the comma-joined ids; empty means `local` (`DEFAULT_DELIVER`, `:91`); the last checked row cannot be unchecked (`cron-job-model.ts:91-103`). Phone: iOS rows with a trailing checkmark, 44 pt (`S/phone-fe-pages-routed.css:271-279`); local reads "Saved in Hermes" (native: "Saved in Run History", D-J8); a platform without a home channel is left out when one of its chats (or the origin chat on that platform) is already selected (`B/stress-c-gates.ts:47-48`); names via `humanDeliverTarget`, `knownChatNames`, `readableTargetName` ("Bot Chat (maple-revenue-operator)" → "Bot Chat (Maple Revenue Operator)", default → "Hermes"), `botChatNames` (`S/stress-c.tsx:118-122`: `bot-chat:<profile>` → the bot's display name).

**Native.** Group **Deliver to**: one row per target, label leading, a checkmark trailing when chosen; the whole row is the button; selection haptic.
- Order: as the gateway sends, local first.
- `local` → "Saved in Run History".
- `bot-chat:<profile>` → "Bot Chat ({bot's name})" using `PagesNames.botName`; the default bot's name, not "default".
- A platform with `home_target_set == false` → "{Name}", secondary line "Set a home channel first" (**DECISION D-J15:** two lines instead of the dash, so the reason wraps cleanly at large type; same words), dimmed, not selectable, VoiceOver "dimmed" with the hint read.
- A selected value not in the list (e.g. `telegram:-100123:7`, `origin`) → a kept row named by `humanDeliverTarget` ("Telegram · Family (topic 7)", "Where it was created · Telegram · Family"), checked, can be unchecked (then it disappears on the next open).
- Unchecking the last checked row does nothing (light warning haptic; **DECISION D-J16:** no alert, the row simply stays checked, as the web).
- New Job starts with only `local` checked.

**States.** Loading (spinner row; `local` already offered and checked so the form is complete without the read) · loaded · read failed (only "Saved in Run History" plus kept rows, footer "Couldn’t load the other places. Pull down to try again." with the form's pull-to-refresh; **DECISION D-J17**) · no platforms connected (just "Saved in Run History" and the Bot Chats).

**Acceptance.**
1. New Job: "Saved in Run History" checked; checking "Telegram" too posts `"deliver":"local,telegram"`.
2. The fixture's Discord (no home channel) is dimmed with "Set a home channel first" and a tap changes nothing.
3. Editing `j-zone`-like job with `deliver: "telegram:-100123:7"` shows the kept row checked; saving without touching it sends no `deliver` key (D-J1).
4. The last checked row cannot be unchecked.
5. `bot-chat:research` reads "Bot Chat (Research)".
6. Unit: `parse`, `toggle`, the leave-out rule, kept rows.

**Fixture:** base command; variant `--no-platforms`.

### 6.9 R9 — Model override picker

**Web.** `MODEL_DEFAULT_VALUE = '__default__'` (`V/…/index.tsx:95`) = no override, shown as "Default (global model)". Choices: providers with `authenticated !== false` and at least one model (`:1180-1182`), value = JSON `[provider, model]` (`cron-job-model.ts:59-80`). A pinned model the list no longer has is kept as an extra choice (`:1187-1191`, `:1393-1397`). Not shown for script-only jobs or blueprints. Model names in words on the phone (`B/fe-pages-gates.ts:714-716`). Create sends `model` and `provider` only when chosen; edit sends `null` for both to clear.

**Native.** Row **Model** with the current choice trailing and a chevron; tapping **pushes** `JobModelPickerViewController` inside the sheet (no second sheet):
- First row "Default (global model)", checkmark when chosen. **DECISION D-J18:** the web's words are kept, with the footer "Uses whatever model this bot is set to." so "global" is not left unexplained.
- Then one section per provider (header = `ModelNames.plainProviderName`), rows = `ModelNames.displayModelName(model)` with the raw id as the secondary line when two models share a display name.
- A pinned model that is not listed: a section "Current" with that one row, so opening and saving never changes it.
- Search field when there are more than 20 models.
- Picking a row: selection haptic, pops back.

**States.** Loading (row shows the stored choice; the picker shows a spinner) · loaded · read failed (picker shows "Default (global model)", the pinned model if any, and "Couldn’t load the models." with "Try Again") · no provider signed in (only the default row and the footer).

**Acceptance.**
1. New Job without touching Model posts no `model` and no `provider` key.
2. Choosing a model posts both keys.
3. Edit a job with a model → choose Default → `{"updates":{"model":null,"provider":null}}`.
4. A job pinned to a model the fixture does not list opens with that model shown and saves another field without sending `model`.
5. `j-script` (script-only): no Model row, no Prompt row, the note shows.
6. The picker is a pushed page with a back button; the sheet's ✕ is not shown on it (the system back button takes its place).

**Fixture:** base command; variant `--no-models`.

### 6.10 R10 — Custom cron expression field

**Web.** Choosing Custom shows a text field in place of the summary (`V/…/index.tsx:1417-1435`): label "Custom schedule", placeholder "0 9 * * * or weekdays at 9am", hint 'Cron expression, or phrases like "every hour" or "weekdays at 9am".' `handleSchedulePresetChange` (`:1163-1174`): going to Custom keeps the current expression; going from Custom to a preset takes the preset's. The gateway parses cron, "every 30m", "in 2h", ISO times and phrases, and answers 400 with usage text otherwise.

**Native.** Under Frequency = Custom: one `TextField`, monospaced, `.autocorrectionDisabled()`, `.textInputAutocapitalization(.never)`, `.keyboardType(.asciiCapable)`, smart quotes and dashes off (a "smart" dash or quote would break an expression). Footer: the hint. No client-side cron validation beyond "not blank" (**DECISION D-J19:** the gateway accepts more forms than a client parser would; a wrong value comes back as its 400, first line shown in the form). When the field holds a five-field cron the app can describe (`describeCron`), the footer's first line is that description, as a preview.

**States.** Blank (Create/Save disabled) · typed · rejected (reason on top and a red footer under the field; field keeps the text and focus) · pasted text with line breaks (collapsed to spaces, trimmed).

**Acceptance.**
1. Daily 07:15 → Custom shows `15 7 * * *`.
2. `*/10 * * * *` posts as typed; "every 2h" posts as typed.
3. `banana` → the fixture's 400; the form shows "Could not save the job" and "Invalid schedule 'banana'. Use:" (first line), nothing lost.
4. Typing `0 9 * * 1-5` keeps a plain hyphen and plain spaces (no smart punctuation) — asserted on the posted body.
5. Editing a job with `every 30m` opens on Custom with that text and saving another field sends no `schedule` key.

**Fixture:** base command.

## 7. Stand-in gateway

New `scripts/fixtures/jobs-gateway.py`, built the way `scripts/fixtures/intents-pages-gateway.py` is: it loads `scripts/pages-fixture-gateway.py` by path with importlib, wraps its handler, refuses a port outside 10000-10009, and refuses a busy port (printing the `lsof` line) instead of taking it. It keeps every inherited route and hook (`/__fixture/state|fail|reset|broadcast|append`) and adds:

| Route | Behaviour |
|---|---|
| `POST /api/cron/jobs` | validates as the gateway: schedule required; 5-field cron, `every Nm/h/d`, `in Nh`, ISO time and the phrases "every hour", "weekdays at 9am" accepted; else 400 with the real multi-line detail. Stores the job under `?profile`, broadcasts `cron.changed`. |
| `PUT /api/cron/jobs/<id>` | body `{"updates":{…}}`; empty updates → 400; unknown id → 404 "Job not found"; `model`/`provider` null clear; `schedule` recomputes `next_run_at`; broadcasts. |
| `GET /api/cron/delivery-targets` | local, Telegram (home set), Discord (home **not** set), one `bot-chat:<profile>` per bot. |
| `GET /api/cron/blueprints` | six of the real catalog's entries copied field for field (morning-brief, custom-reminder, habit-checkin, hydration-move, learn-daily, weekly-review) so time, enum, weekdays, text and example-default slots all occur. |
| `POST /api/cron/blueprints/instantiate` | real 404 / 422 texts; creates the job. |
| `GET /api/model/options` | two signed-in providers, one not signed in, one with no models. |
| `GET /__fixture/state` | adds `requests`: method, path, query, body, time for every request since the last reset. |

Flags added: `--jobs N` (N generated jobs across all sections and bots), `--no-blueprints`, `--no-platforms`, `--no-models`, `--blueprint-422`, `--write-delay S` (hold every POST/PUT S seconds), `--read-only` (writes answer 403 as the real read-only gateway does). `/__fixture/fail` already fails or delays the next matching request.

Start commands (run from the worktree root):

```sh
# builders
python3 scripts/fixtures/jobs-gateway.py --port 10000 --credentials build/fixtures/jobs.json --files build/fixtures/jobs-files --tick-seconds 0
# long list (R1)
python3 scripts/fixtures/jobs-gateway.py --port 10001 --credentials build/fixtures/jobs-long.json --files build/fixtures/jobs-files --jobs 1000 --tick-seconds 0
# shared reads (R4)
python3 scripts/fixtures/jobs-gateway.py --port 10002 --credentials build/fixtures/jobs-ticks.json --files build/fixtures/jobs-files --tick-seconds 2
# stress tester
python3 scripts/fixtures/jobs-gateway.py --port 10005 --credentials build/fixtures/jobs-s.json --files build/fixtures/jobs-s-files --write-delay 4
```

`scripts/e2e-jobs.sh <udid>` (modelled on `scripts/e2e-pages.sh`): starts the fixture on its port, passes `TEST_RUNNER_HQN_UI_CREDENTIALS`, runs `xcodebuild -scheme HermesHQNativeUI -only-testing:HermesHQNativeUITests/JobEditorTests` with its own `HQN_DD` derived-data folder and shots folder `build/shots/jobs-*`, then stops **only the process it started** (by pid). Simulator: `xcrun simctl create "HQN-m9-jobs" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`.

The app never talks to the owner's gateway in any test; the fixture is the only host.

## 8. Tests

Unit (`scripts/build.sh test <udid>`):
- `JobScheduleTests`: every preset ↔ expression, classification of odd forms as Custom, `compose`, `expression(for:keeping:)`, summaries (12 h and 24 h).
- `JobDeliveryTests`: parse, toggle, last-one rule, home-channel rows, leave-out rule, kept unknown targets, Bot Chat names.
- `JobBlueprintTests`: initial values, example defaults, option labels, help, error cleaning, lenient decoding of a malformed catalog.
- `JobEditorModelTests`: `createBody` key sets (no empty name, no model keys by default), `updates` sends only changed keys and pairs model/provider, pristine → not dirty, script-only never sends prompt, completeness rules.
- `JobsFixtureTests` (against the fixture on port 10003): create, edit, instantiate, each error text, the request log; the R4 one-request proofs.

UI (`UITests/pages/JobEditorTests.swift`), each with a screenshot looked at in light and dark:
`testJE01_NewJobDefaults`, `JE02_EveryPreset`, `JE03_TimeFields`, `JE04_CustomSchedule`, `JE05_Delivery`, `JE06_ModelPicker`, `JE07_BlueprintFromList`, `JE08_BlueprintFieldError`, `JE09_EditFromMenu`, `JE10_EditFromFailedRun`, `JE11_ScriptOnlyJob`, `JE12_SaveFailsKeepsForm`, `JE13_DiscardGuard`, `JE14_ReadOnlyGateway`, `JE15_LargestType`, `JE16_ThousandJobs`, `JE17_RunsReadOnce`.

A row is `done` only when its tests pass **and** its screenshots have been looked at.

## 9. STRESS PLAN

The stress tester uses simulator `HQN-m9-jobs-s`, ports 10005-10009, its own derived data. It never touches the builders' simulator or processes.

**Load**
- `--jobs 1000` and `--jobs 5000`: first paint, scroll, search, refresh (§6.1 numbers). Open and close the editor 50 times over the long list: no growth in memory beyond 10 MB, no leaked `JobEditorModel` (deinit counter in a debug build).
- 200 blueprints, 60 delivery targets, 300 models (fixture `/__fixture/append`): the pickers scroll, search appears, the form does not lay out every row up front.
- A 20 000-character prompt pasted: typing stays responsive, Save posts all of it, the job page shows it.
- 30 `cron.changed` broadcasts in one second with the job page open: at most 2 `/runs` requests (one shared, one trailing).

**Speed**
- Double-tap and triple-tap Create: exactly one POST (request log).
- Tap Create, then ✕ during the spinner: the sheet does not close mid-write; one POST; the result is shown.
- Switch Frequency 40 times fast, then Create: the posted expression matches what is on screen.
- Open Edit from the menu while the list is refreshing; open the editor twice quickly (menu then detail): one sheet only.
- Tap "Edit Job…" on a row, and Delete the same job from another client (fixture) before Save: the 404 words, no crash, row gone.

**Bad network**
- `--write-delay 4`: spinner, form locked, no second request.
- A write that never answers (fixture hold 20 s): the slow-answer words at 15 s, the sheet stays, the list is re-read; if the job did land it shows and a second Create is the person's choice, never automatic.
- Connection dropped mid-POST (`/__fixture/fail` reset): the connection reason in the form, everything kept.
- Each editor read failing alone (targets, models, blueprints, the fresh job): the form still saves a local, default-model job.
- 401 on save (session lapsed): one silent renewal as the rest of the app, then the write once; never a sign-in loop.
- 500 with HTML, 502 with an empty body, 200 with `null`: plain words, no raw HTML or JSON on screen.

**Bad data**
- Targets: missing `name`, duplicate ids, `home_target_set` as a string, an id with emoji, a 300-character name (wraps, 12 pt padding).
- Blueprints: no `fields`, a field with no `options` but type enum (shown as text), an unknown type, a default not in the options, a key with a slash, right-to-left titles.
- Model options: a provider with `models: null`, the same model under two providers (both rows distinct by provider), 0 providers.
- Jobs to edit: `schedule` null, `deliver` an empty string, `deliver: "local,local,,telegram"`, a 6-field cron, `model` set with `provider` null, a name of 500 characters, a prompt of only whitespace, a job with both `script` and `prompt`.
- Gateway detail as an object or a list instead of text: the fallback sentence.
- Schedule input: leading/trailing spaces, tabs, a newline, non-breaking spaces, full-width digits, smart quotes pasted from Notes.

**Interruption**
- Background the app mid-save, return after 5 s and after 60 s: the result is shown once; no duplicate job.
- Incoming call banner, Control Center, notification pull-down over the open time wheel and over the keyboard.
- Rotate with the keyboard up and with the model picker pushed; split keyboard not applicable (phone only).
- Lock the phone on the dirty form; unlock: the text is still there.
- A push opens a chat while the dirty editor is up: the editor is not thrown away silently (the discard question, or the push waits behind the sheet, whichever the app does for the bot editor; it must match).
- Sign-out or account switch from another device while the editor is open: the sheet closes with the app's signed-out state, no write is sent to the new account.
- The socket reconnects while the editor is open: nothing in the form changes; a dirty form is never overwritten (D-J12).

**Relaunch**
- Kill the app on the dirty form and relaunch: the Jobs page comes back from the cache; the draft is gone (**DECISION D-J20:** drafts are not kept across a kill; the web does not keep them either). Nothing half-created on the gateway.
- Kill during the POST and relaunch: zero or one job exists, never two; the list shows the truth after its first refresh.
- Relaunch with 1 000 cached jobs offline: the list paints, `+` opens the editor, Create fails with the connection words.
- Relaunch after an edit: the job page shows the saved values from the cache before the network.

**Accessibility sizes**
- Largest accessibility type (AX5), light and dark: no clipped label, the bar keeps ✕ and Create/Save, the Frequency and Day menus are reachable, the failed-run card's two buttons stack, delivery rows wrap with 12 pt padding, the time wheel opens and is usable.
- Smallest type: nothing overlaps.
- VoiceOver: every row has a label and a value ("Frequency, Weekly", "Telegram, selected", "Discord, dimmed, Set a home channel first"); the error note is announced when it appears; focus returns to the form after the model picker pops; the HUD is announced.
- Bold Text, Increase Contrast, Reduce Transparency (the sheet stays legible; this is where fake glass would show), Reduce Motion, Button Shapes.
- Switch Control / Full Keyboard Access: Tab order follows the form order; Return in Name moves to Prompt; Cmd-Return saves when enabled.
- Right-to-left (Arabic pseudo-language): checkmarks and chevrons flip, cron text stays left-to-right.

**Never-verified sheet behaviour (owner notes)**
- Keyboard in the sheet: open the keyboard in Prompt, drag the sheet down a little and let go 30 times: the sheet does not shake or jump, the bar stays glass, the field stays above the keyboard.
- Open the time wheel popover with the keyboard up; dismiss each in both orders.
- Compare the sheet's bar against the bot editor's bar in a screenshot pair: same glass, same button shapes.

## 10. Risks and open points

1. **D-J1 differs from the web** (changed keys only). If a real gateway version needs `schedule` on every update, edits of other fields still work, because the gateway's update merges; verified against `H/cron/jobs.py` but not against the owner's running gateway (which no test may contact).
2. **Time zone.** Times are the gateway computer's, not the phone's; the note says so, but a phone abroad shows "9:00 AM" meaning the gateway's 9. That is the web's behaviour too.
3. **`DatePicker` compact wheel inside a sheet with the keyboard** is one of the owner's never-verified areas; if it misbehaves on iOS 27, the fallback is an inline wheel row that expands in the form (no popover).
4. **R1 as web-shell-only** is a proposal; if the reviewer wants the pager, it is a small addition to the snapshot builder, but the spec argues it would be worse.
5. **The fixture's schedule parser** is a stand-in for the gateway's; phrases the real gateway accepts may be refused by the fixture or the reverse. The app does no parsing of its own (D-J19), so only the fixture's test expectations depend on it.
6. **Blueprint catalog drift.** Plugins can add blueprints with field types not seen here; unknown types fall back to text.
7. **`testJob11` flakes under load** on the shared Mac (known before this stream); new UI tests must wait on elements, never on fixed sleeps.
8. **Only the owner's iPhone can show** how the real gateway words its errors for his setup and whether his platforms list home channels as expected; nothing is blocked on it.

## 11. State on 2026-10-13 after merging the train (second spec pass)

This spec was written at 03:59 and a builder then built all of it. The second spec pass (10:00) found that work **uncommitted** in the worktree, with `docs/briefs/m9/jobs-report.md` still saying `RESULTS_PLACEHOLDER` under Results. Nothing above this section was changed by the second pass: §1-§10 stand as written, and the builder's own DECISIONs (in the report) stand.

## 12. Lock Screen progress for Run Now (Live Activity)

Built on branch `feat/revisit-lock-screen`, reviving n20 item F13 (TestFlight build 400, `integrate/n20-r2`), with
the long-turn side in `docs/spec/3x-presence.md` §17 (rules, switch, ending, limits, builds are shared — including
D41a, which replaces n20's own-target design with reuse of `HermesHQTalkActivity`, needing no App ID of its own).

- **DECISION D-J23 — Running from the tap.** Confirming Run Now (`JobActions.performRun`) starts the activity at
  once: the bot's name, "Running" with the job's title as its detail, a timer. Starting at the tap (not when the
  app is left) means locking the phone straight after works, and the app is in front, which iOS requires.
- **DECISION D-J24 — the answer.** `JobsStore.runNow`'s result: `.started` / `.stillRunning` / `.restorePauseFailed`
  wait for the next Jobs read (a Bot Chat job's bot may still be on the output); `.refused` / `.alreadyRunning` take
  the activity away at once (it never began, so no "Failed"); `.failed` ends it "Failed".
- **DECISION D-J25 — the Jobs read decides.** After each list read (`JobsStore.onListRead`, called right after
  `settleStillRunning`) every followed job is checked: still out (`showsRunning` or `JobWords.isRunning`) stays;
  otherwise "Done", or "Failed" when `JobWords.lastRunFailed`; a job gone from the list is taken away. The list
  reads pause while the app is inactive, so a run that ends then ends its activity when the app is next opened (and
  the activity says "· Open to check" after 30 min, presence D45) — a job's run has no push to shorten that wait;
  only a bot's turn does (presence §17.4).
- **DECISION D-J26 — its link.** Tapping it opens `<scheme>://job/<owner|id>` (the `|` sent as `%7C`): Jobs tab,
  that job's page, from any tab (`MainTabController.openJob`).
- Tests: `Tests/Live/LiveActivityTests.swift` (`LiveActivityJobRulesTests`, `LiveActivityCenterTests`),
  `UITests/pages/PagesTests+Live.swift` (`testJob13_RunNowShowsOnTheLockScreen`,
  `testJob13b_ARunThatNeverBeganGoesAtOnce`, `testJob14_JobLinkOpensItsPage`).

### 11.1 What the second pass did

1. Committed the builder's work as found, as a checkpoint (so nothing could be lost and the train could be merged). It was not rebuilt or re-run at that commit.
2. Merged `m9/train` (c5a3508: offline, sessions, groups, talk, desktoplook, ipad, a11y and the rest) into `m9/jobs`. Two files conflicted; both were resolved by keeping both sides:
   - `App/Pages/Jobs/JobDetailViewController.swift`: the "Delivers To" line keeps this stream's words and id (`job.delivers`, D-J8) in the train's font (`Font.hq(.subheadline)`); the failed-run card keeps this stream's two buttons (§6.3) in the train's font, and the train's `HQMotion.withAnimation` on the fold.
   - `HermesKit/Pages/JobsStore.swift`: this stream's `blueprintsByProfile`, `changeTick`, `cachedJobsLimit` beside offline's `flight` (`ReadFlight`) and `cacheLimit`; `performRefresh` keeps the blueprint read beside the list; the cache write is now **the first 500 jobs, written only when their JSON is at most 300 000 bytes** (see D-J21).
3. Converted the two lines the train's source scans would refuse (the scans have teeth on the train now, `Tests/Accessibility/A11yLintTests.swift`): `withAnimation(.snappy)` in `JobEditorView.swift` → `HQMotion.withAnimation(.snappy)`; `.font(.system(size: 40))` in `JobsEmptyNoteView` → `.hqSymbolFont(40, cap: 56)`.
4. Built the native identity on `HQN-m9-jobs` after the merge: `scripts/build.sh build 5FFE18B7-F7FE-4A77-AE5E-19990BECE31E` → exit 0.

**Not done by the second pass, so not known:** the original identity build (`HQ_IDENTITY=original`), the unit suite, and every UI test, after the merge. Every proof in `jobs-rows.md` was seen **before** the merge. Until they are seen again on the merged tree the rows are honestly "done before the merge, to be re-seen", and the next stage must treat them so.

### 11.2 What the train changed under this feature (read before touching the code)

| Train change | Where | What it means here |
|---|---|---|
| List reads go through `ReadFlight`: one at a time, none while the app is away, one catch-up on return (`3x-offline.md` §6.7) | `JobsStore.refresh(background:)` → `performRefresh()` | After a create or an edit the store's refresh may be **joined to a read already in flight** that started before the write. Check that the new or changed row still appears (JE01 "row scrolled into view", JE09, JE10): if the joined read predates the write, `replace(_:)` with the write's own answer must already have put the row there. Do not bypass `ReadFlight` to fix it. |
| The Jobs cache is not written over 300 000 bytes, and the older copy is removed (`3x-offline.md` §6.10; `WarmOrderTests.aJobsListOverTheLimitIsNotSaved`) | `JobsStore.cacheLimit`, `PagesCache.write(_:to:maxBytes:)` | D-J21 below. |
| One font factory, `HQFont` / `Font.hq(…)`; Bold Text and Increase Contrast inside the theme (`3x-a11y.md`) | all of `App/` | The new editor files still use plain SwiftUI text styles (`.font(.subheadline)` and so on: 16 lines in `JobEditorView.swift`, `JobEditorSheet.swift`, `JobRowView.swift`). The scans allow a SwiftUI text style, so they pass, but under a Desktop Look theme with its own typeface these lines will not follow the theme. Builder: change them to `Font.hq(…)` as the rest of `App/Pages/Jobs` now is, and look at the editor under one non-default theme. |
| Motion is checked per call (`HQMotion`) | `A11yLintTests` | Any new animation in the editor needs `HQMotion` on its line or within six lines above. |
| iPad: a two-pane root; sheets are form sheets on iPad (`3x-ipad.md`) | `ChatSheet`, the tab root | The editor has only been seen on iPhone. See §11.4. |
| Offline header and launch screen (`3x-offline.md`) | Jobs tab header says "Offline" | With the gateway down the `+` and Edit entries must still open the editor (the form is local) and Create must answer with the connection words (§9 Relaunch, third point). Re-see it against the merged tree. |

**DECISION D-J21 — the cache cap after the merge (replaces the numbers in D-J10).** Two rules now meet: this stream's "keep at most 500 jobs" and offline's "never write more than 300 000 bytes; over that, remove the old copy". As merged, a list whose first 500 jobs are over 300 000 bytes (about 600 bytes a job: long prompts do it) leaves **no** cache, so a relaunch shows a spinner rather than rows. That is offline's stated behaviour and is safe, but it wastes D-J10. Builder: make the kept prefix fit, by halving: try 500, then 250, 125, 62, 31 jobs and write the first that encodes to at most `cacheLimit`; only when even 31 do not fit, remove the file. The encoding stays on `PagesCache`'s own queue (nothing is encoded on the main thread). `JobsLongListTests.theCacheKeepsAtMost500JobsAndStaysUnder2MB` changes its bound from 2 MB to `JobsStore.cacheLimit` and gains a case with 1 000 jobs of 1 000-character prompts (expect 250 kept, not zero). `WarmOrderTests.aJobsListOverTheLimitIsNotSaved` must still pass unchanged (one job of 310 000 characters fits no prefix, so nothing is saved).

### 11.3 What the next stage does first (in this order)

1. `HQ_IDENTITY=original scripts/build.sh build <udid>` then `xcodegen generate -q` (both identities must build; only native was seen).
2. `scripts/build.sh test <udid>`: the whole unit suite, including `A11yLintTests`, `WarmOrderTests`, `JobsLongListTests`, `JobRunsSharedReadTests`, `JobEditorModelTests`. Report any failure as a failure.
3. D-J21 and the `Font.hq` change (§11.2), with their tests.
4. `scripts/e2e-jobs.sh 5FFE18B7-F7FE-4A77-AE5E-19990BECE31E 10000` in full (about 45 minutes), and the 15 Jobs tests of `PagesTests` on ports 10002/10003 (the command is in the report). Look at the screenshots again, light and dark: the train changed fonts and colours under every one of them.
5. Fill in the report's Results section with what was actually seen (replace `RESULTS_PLACEHOLDER`), and correct `jobs-rows.md` wherever a proof no longer holds.

Fixture commands are unchanged (§7). The fixture refuses any port outside 10000-10009 and any busy port.

### 11.4 Additions to the STRESS PLAN (after the merge)

Same simulator and ports as §9 (`HQN-m9-jobs-s`, 10005-10009).

- **Write meets a read in flight.** Hold the list read 5 s (`POST /__fixture/fail {"method":"GET","path":"/api/cron/jobs","delay":5,"count":1}`), pull to refresh, and Create a job during the hold: the row appears once, is scrolled into view, and is not removed when the older read lands. The same for an edit (the old name must not come back) and for a delete made from the row menu during the hold.
- **Away and back.** Create, then background the app before the answer (`--write-delay 4`): on return exactly one job exists and the list shows it; `ReadFlight` makes one catch-up read, not one per missed `cron.changed`.
- **Cache at the limit.** 1 000 jobs with 1 000-character prompts, then kill and relaunch with the fixture refusing connections: rows are painted from the cache (D-J21), the header says "Offline", `+` opens the editor, Create answers with the connection words and keeps the form.
- **Themes.** The editor, the model picker, a blueprint form and the failed-run card under each Desktop Look theme the train ships and under High Contrast, light and dark: text follows the theme's typeface, the red failure note stays readable, checkmarks and the prominent Create button keep enough contrast.
- **iPad.** On an iPad simulator of the tester's own (`xcrun simctl create "HQN-m9-jobs-s-ipad" "iPad Pro 13-inch (M5)" com.apple.CoreSimulator.SimRuntime.iOS-27-0`, or the nearest type listed): the editor as a form sheet over the two-pane root; the time wheel and the Frequency menu open from their rows (popovers need a source, a crash here is the classic iPad failure); rotate with the editor open and dirty; a hardware keyboard: Tab order, Return in Name moves to Prompt, Cmd-Return saves, Escape asks to discard when dirty.
- **Bold Text and Increase Contrast together at AX5** in the editor (the train moved both into the theme): no clipped row, the two failed-run buttons stay stacked and whole.
- **The scans.** Run `A11yLintTests` alone after any stress fix: a quick fix that adds a literal font size or a bare `withAnimation` fails the train's unit run.

### 11.5 Risks added by the merge

1. Every "done" in `jobs-rows.md` rests on runs made before the merge. Only the native build has been seen since.
2. The merged cache write can leave no cache for a long list with long prompts until D-J21 is built.
3. A write joined to an older in-flight list read (§11.2, first row) is untested.
4. The editor has never been seen on iPad or under a non-default theme.
