# 3x · Onboarding: welcome, connection guide and sign-in extras (m9 `onboarding`)

Stream `onboarding`, worktree `/Users/me/Projects/hermes-hq-native-wt/m9-onboarding`, branch `m9/onboarding`.
Rows: the 17 rows of `docs/parity-240.md` §1 listed in `docs/briefs/m9/assignment.md` (section "onboarding") and
copied verbatim into `docs/briefs/m9/onboarding-rows.md`. Written 2026-10-13 against train commit `801998d`.

**Revised 2026-10-13 after the train moved to `c5a3508`** (86 commits: `offline`, `ipad`, `a11y`, `desktoplook`,
`groups`, `sessions` and others joined it). The train was merged into this branch; what that changed for this stream,
what is still to build and what must be proved again is **§14**, which wins wherever it differs from an earlier
section. Sections changed by the revision carry a line starting **After the merge**.

The owner was asleep when this was written. Every choice the web app does not settle is marked **DECISION** and
collected in §11.

## 0. Sources and notation

| Mark | Meaning |
|---|---|
| `W:` | `/Users/me/Projects/hermes-hq-native-ref240/` (web app, build 240, read only) |
| `HA:` | `/Users/me/.hermes/hermes-agent/` (real Hermes, read only) |
| `MEM:` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` |
| `NAT:` | this worktree |
| R1…R17 | this spec's name for each assigned row (table in §1) |

Web files read in full: `W:src/connection-onboarding.ts` (161 lines), `W:src/connection-guide.ts` (220),
`W:src/gateway-compat.ts` (52), `W:src/connection-ways.ts`, `W:src/connection-startup.ts:25-70,236-433`,
`W:src/main.ts:183-284` (form), `:330-412` (offline and outdated screens), `W:src/connection-storage.ts:166-169,238-252`,
`W:ios/App/App/HermesPlatform.swift:1259-1271` (openExternal), `W:ios/App/App/HermesMenus.swift:40-52` (shareText),
`W:ios/App/App/HermesNative.swift:2011-2023` (label on login).

Memory notes read: `onboarding-clarity.md`, `hermes-setup-prompt.md`, `gateway-version-check.md`,
`new-user-setup-flow.md`, `row-padding-feedback.md`, `liquid-glass.md`, `taptic-feedback-gaps.md`,
`feedback-one-feature-at-a-time.md`.

Device word: every `${DEVICE}` in web copy is `iPhone` on a phone and `iPad` on an iPad
(`W:src/connection-startup.ts:28-33`). Native has `SignInCopy.device = "iPhone"` (`NAT:App/SignIn/SignInDriving.swift:48`)
and ships iPhone only (`TARGETED_DEVICE_FAMILY: "1"`). This stream moves the word to one place,
`OnboardingCopy.device` (computed from `UIDevice.current.userInterfaceIdiom`), and `SignInCopy.device` reads it, so the
`ipad` stream gets the right word with no further change. In this spec `iPhone` stands for that word.

**After the merge:** the train has its own single source, `DeviceWord.name` (`ipad` stream), and
`SignInCopy.device` already reads it. `OnboardingCopy.device` must go the same way (§14.3 I4); the train's
`scripts/check-ipad.py` fails on the literal it holds.

Punctuation in copy is the web's: curly apostrophes (’), curly quotes (“ ”), the ellipsis character (…). Copy strings
below are exact; tests compare them character for character.

## 1. Rows and what this spec proposes for each

| # | Parity line | Row (short) | Proposal |
|---|---|---|---|
| R1 | L75 | Welcome screen | build natively |
| R2 | L76 | Onboarding back stack | build natively (a `UINavigationController` stack with pop-to-existing) |
| R3 | L77 | "Where does Hermes run?" chooser + "Install Hermes first" | build natively |
| R4 | L78 | "Let Hermes set it up" | build natively |
| R5 | L79 | Mac guide, 3 steps | build natively |
| R6 | L80 | Linux/server guide, 3 steps | build natively |
| R7 | L81 | "If the terminal shows a problem" list | build natively |
| R8 | L82 | Windows path | build natively |
| R9 | L83 | "Set it up yourself" manual page | build natively |
| R10 | L84 | Copy and share feedback lines | build natively |
| R11 | L85 | Guide loads lazily, prefetched after 400 ms | **web-shell-only mechanism**; the behaviour ("the guide opens with no wait") is met and measured (§5.11) |
| R12 | L86 | "Need help connecting?" link | build natively |
| R13 | L92 | Optional "Name" field | build natively |
| R14 | L100 | Gateway version check after a typed sign-in | finish: checked before the app shows, 4 s cap, never blocks |
| R15 | L101 | "Update Hermes" screen | finish: a full screen with Check Again and Continue Anyway |
| R16 | L103 | Keychain unreadable → "Sign in again?" | finish: Sign In Again button, confirm, clear, form (shared with `offline`, §12.1). **After the merge:** the button, the confirm and the form are the `offline` stream's, already on the train; this stream proves the row there and removes its own copy (§14.2 D27, §14.3 I3) |
| R17 | L105 | Tailscale explanation copy throughout | build natively (a checklist of sentences, §5.17) |

Nothing in this stream needs the push relay, a plugin or a change on a real gateway, so there is no
`docs/owner-todo/onboarding.md`. If a builder finds otherwise, that file is where it goes.

## 2. Native today (train `801998d`)

* **First run.** `SceneDelegate.restore()` (`NAT:App/AppDelegate.swift:162-194`) reads the saved sign-in. Signed out →
  `showSignIn(prefill:)` (`:216-236`) makes `SignInScreen.make(…)` the window root. There is no welcome, no guide, no
  Back, no help link.
* **Form.** `NAT:App/SignIn/SignInView.swift`: icon, "Hermes HQ", subtitle, "Hermes address" field, then (once the
  address has been asked about) Sign in with Nous and/or Username, Password, Sign In, an error line, a footnote.
  No Name field. Copy in `SignInCopy` (`NAT:App/SignIn/SignInDriving.swift:47-136`) was trimmed where the web pointed at
  the guide (`:45-46`: "adapted where the web pointed at screens M1 doesn't have").
* **Add Gateway.** `AddGatewayFlow.present` (`NAT:App/Gateways/AddGatewayFlow.swift:10-45`): the same form as the root
  of a `UINavigationController` in a large sheet with Cancel.
* **Version check.** After a typed sign-in the app shows, then `checkCompatibility` (`NAT:App/AppDelegate.swift:239-249`,
  and `GatewayCompatibilityCheck.run` for the sheet, `AddGatewayFlow.swift:75-91`) reads `/api/status` (4 s,
  `LiveGatewayClient.compatibility()`, `NAT:HermesKit/Net/LiveGatewayClient.swift:207-211`) and, when outdated, shows a
  system alert "Update Hermes" with Check Again and Continue Anyway. `GatewayCompatibility.outdated`
  carries only the release date (`:271-293`).
* **Keychain.** `RestoreState.unavailable(failure)` → `LaunchViewController.showProblem(message)` ("Can’t Open Your
  Sign-In", Try Again) for locked, unavailable and unreadable alike (`NAT:App/Root/LaunchViewController.swift:36-52`).
  The vault already knows how to discard an unreadable item (`Keychain.swift:175-179`, `clearCurrentLocked`) and a save
  replaces one (`:198-205`, `editable()`).
* **Label.** `StoredAccount.label` exists, `AccountStore.rename` caps it at 60 characters
  (`NAT:HermesKit/Net/AccountStore.swift:91-98`), `SavedAccounts.save` keeps an old label when the new record names none
  (`SavedAccounts.swift:125-129`), and `GatewayNaming.row/title` show it. Sign-in never sets it.
* **Connect link.** `hermes://connect?url=…` already fills the form (`AppDelegate.swift:127-141`,
  `AppModel.handleLink`, `NAT:App/Notifications/AppModel+Notifications.swift:292-303`).
* **Drafts.** Every draft is stored under `"<account id>|<profile>|<stored session id>"`
  (`NAT:HermesKit/Contracts+attachments.swift:36-37`); there is no account-less draft storage.

## 3. Design overview

### 3.1 One flow object, used in two places

`OnboardingFlow` (new, `App/Onboarding/OnboardingFlow.swift`) owns a `UINavigationController` and maps the web's `Step`
(`W:src/connection-onboarding.ts:6`) to screens:

```swift
enum OnboardingStep: String, CaseIterable {
    case welcome, hermes, `where`, mac1, mac2, mac3, linux1, linux2, linux3, other1, other2, manual, connect
}
```

* **Root use** (signed out): `SceneDelegate.showSignIn` makes `flow.navigationController` the window root. The stack is
  always rooted at `welcome`. A first run shows `[welcome]`; a returning start shows `[welcome, connect]` built without
  animation, so the form is on screen and Back leads to the welcome, exactly as the web's Back on the form does
  (`W:src/connection-onboarding.ts:20`: `history.pop() ?? 'welcome'`, and the form's Back at `:99-103`).
* **Sheet use** (Add Gateway…, or signing a saved gateway back in): `AddGatewayFlow` asks the flow for its navigation
  controller with `mode: .sheet(cancel:)`. The stack is `[connect]` with Cancel on the left; there is no welcome
  (`W:src/connection-onboarding.ts:76-78`: "the first-run welcome (no way back from there) isn't offered"). The help
  link pushes guide screens inside the sheet.

`flow.go(_ step:)` is the web's `go` (`W:src/connection-onboarding.ts:18-25`), on the navigation stack (R2, §5.2).

Each screen is a `UIHostingController` over a SwiftUI view, built like `SignInView` (icon, type and buttons match).
The sign-in form stays `SignInView`/`SignInModel`, extended (R12, R13, R14).

### 3.2 Which screen a signed-out launch starts on

Web: `returning: !!linked || !!prefill?.url || !!message || startup.adding()` (`W:src/main.ts:206`), where `prefill` is
the saved identity of an ended session **or the gateway last signed out of** (`W:src/main.ts:193`,
`W:src/connection-storage.ts:238-252`).

Native, one pure function (unit tested):

```swift
enum OnboardingEntry { case welcome, form }
nonisolated enum OnboardingGate {
    static func entry(linkAddress: String?, prefillAddress: String?, notice: String?,
                      signedInBefore: Bool, startAtForm: Bool) -> OnboardingEntry
    // .form when any of: a non-empty linkAddress, a non-empty prefillAddress, a non-empty notice,
    // signedInBefore, startAtForm. Otherwise .welcome.
}
```

* `signedInBefore`: `UserDefaults` Bool `hq.onboarding.signedInBefore`, set to true in `SceneDelegate.showApp` (so an
  existing install is marked on its first launch of this build) and never cleared by Sign Out.
  **DECISION D1:** this flag stands in for the web's "gateway last signed out of" prefill. Native does not prefill the
  address after Sign Out (not an open parity row), but a phone that has been signed in before must still open on the
  form, as the web does, not on the welcome. `-HQDebugResetAccounts YES` clears the flag.
* `startAtForm`: `false` in Release. In DEBUG it is `!UserDefaults.standard.bool(forKey: "HQDebugWelcome")`.
  **DECISION D2:** about twenty UI test suites on the train (and those of ten parallel streams) launch a clean
  simulator with plain `app.launch()` and wait for `sign-in-address`. In DEBUG builds only, a clean first run therefore
  starts as a returning one (`[welcome, connect]`, the welcome one Back away) unless `-HQDebugWelcome YES` is passed.
  Release builds (everything that reaches TestFlight) have no such switch. The onboarding suite passes
  `-HQDebugWelcome YES`; the gate's Release rule is pinned by a unit test; the stress tester also checks one clean
  launch of a Release-configuration simulator build with no arguments (§10 item 1).

### 3.3 Files

| File (new unless noted) | What |
|---|---|
| `App/Onboarding/OnboardingFlow.swift` | The flow: steps, `go`, `back`, busy, `showForm(address:)`, root and sheet modes |
| `App/Onboarding/OnboardingGate.swift` | `OnboardingGate.entry` and the `signedInBefore` flag |
| `App/Onboarding/OnboardingCopy.swift` | Every string, command and link of §5 (`nonisolated enum`, pure; the tests' source of truth) |
| `App/Onboarding/OnboardingKit.swift` | Shared SwiftUI pieces: page scaffold, numbered steps, note card, command card, disclosure, key caps, status line, choice row |
| `App/Onboarding/WelcomeView.swift` | R1 |
| `App/Onboarding/WhereView.swift` | R3 |
| `App/Onboarding/LetHermesView.swift` | R4 |
| `App/Onboarding/QuickSetupViews.swift` | R5, R6, R7 (one set of three views parameterised by `mac` / `linux`) |
| `App/Onboarding/WindowsViews.swift` | R8 (`other1`, `other2`) |
| `App/Onboarding/ManualSetupView.swift` | R9 |
| `App/Onboarding/GuideActions.swift` | R10: `GuideClipboard`, `GuideSharing`, `GuideLinks` protocols, live implementations, the feedback model |
| `App/Onboarding/UpdateHermesView.swift` | R15: the screen and its `UpdateHermesModel` |
| `App/SignIn/UnreadableSignIn.swift` | R16: the confirm and the start-over (shared with `offline`, §12.1) |
| `HermesKit/Net/GatewayCompatibility.swift` | R14: `GatewayCompatibility` moved out of `LiveGatewayClient.swift`, with `OutdatedGateway` and `OutdatedCopy` |
| `App/SignIn/SignInView.swift`, `SignInDriving.swift`, `SignInServiceDriver.swift` (edit) | R12, R13, R14: help link, Name field, restored copy, the check before entering |
| `HermesKit/Net/SignInService.swift` (edit) | R13: `label:` on both sign-ins; R16: `discardUnreadableSignIn()` |
| `App/AppDelegate.swift` (edit, kept small) | Root wiring: flow instead of the bare form; Update screen; R16 hook |
| `App/Gateways/AddGatewayFlow.swift` (edit) | Sheet wiring: flow in sheet mode; Update screen pushed in the sheet |
| `App/Debug/DebugHooks.swift` (edit) | `-HQDebugWelcome`, `-HQDebugCorruptSignIn`, `-HQDebugGuideOut`, `-HQDebugGuideFail` (§9.3) |
| `scripts/fixtures/onboarding-gateway.py`, `scripts/e2e-onboarding.sh` | §8 |
| `Tests/Onboarding/*.swift`, `UITests/onboarding/OnboardingEndToEndTests.swift` | §9 |

Both `project.yml` and `project-original.yml` pick sources up by folder; a new folder under `App/`, `Tests/` or
`UITests/` needs no edit, but the builder builds **both** identities (`scripts/build.sh` and
`HQ_IDENTITY=original scripts/build.sh`) before calling anything done.

### 3.4 Look (owner rules applied)

* **Navigation bar.** System bar, system Back (the glass chevron). **DECISION D3:** the web draws a text "‹ Back"; the
  native bar's own back control is used instead. The interactive swipe back works.
* **Titles.** The welcome hides the bar. Every other screen has `largeTitleDisplayMode = .never` and shows the web's
  eyebrow as the small title on the bar row ("Step 1 of 3", "Set it up yourself", "Without Hermes’s help"); screens
  with no eyebrow ("Let Hermes set it up.", the form) have an empty bar title. The heading itself ("Where does Hermes
  run?") is content: `.title.bold()`, wraps, first in VoiceOver order with the header trait. **DECISION D4:** this is
  how "pushed pages use the small title on the bar row" maps to headings that are whole sentences; a sentence in the bar
  would truncate. The form in sheet mode keeps its existing bar title ("Add Gateway" / "Sign In").
* **Glass.** Primary buttons `.buttonStyle(.glassProminent).tint(Color.hqTint)`, secondary `.buttonStyle(.glass)`,
  both `.controlSize(.large)`, as on the form. "Tinted" buttons inside cards (Copy, Send…, Get Tailscale, Copy All
  Steps) are `.buttonStyle(.glass)` at regular size. Cards are plain filled shapes
  (`HQPalette.groupedCard`, 14 pt continuous corners), not glass. Nothing is drawn with blur plus tint
  (`MEM:liquid-glass.md:26`: "It isn't Liquid Glass. So much of this is wrong.").
* **Padding.** Every card or row whose text can wrap has 14 pt top and bottom and 16 pt sides
  (`MEM:row-padding-feedback.md:16`: "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt top
  and bottom, with line-height set."). Choice rows have a 76 pt minimum height (`W:src/connection.css:109`).
* **Width and scrolling.** Content is a `ScrollView`, 24 pt side margins, `maxWidth: 440` centred (as the form). The
  action buttons sit at the end of the content, not pinned, so at accessibility sizes they are reached by scrolling.
* **Words.** "gateway" is not used on the welcome or the guide (`MEM:onboarding-clarity.md`: "“gateway” is avoided in
  onboarding because in Hermes it means the Telegram bridge."). The form, the Update screen and the Keychain messages
  keep the web's own wording, which does say "gateway". The word "Dispatch" appears nowhere.
* **Icons.** The web's line icons become SF Symbols: `desktopcomputer`, `iphone` (`ipad` on iPad), `lock`,
  `laptopcomputer`, `server.rack`, `link`, and `chevron.right` on choice rows. The welcome's icon is the `LaunchIcon`
  asset at 72 pt with the app-icon corner, as on the form. No robot heads are involved.

## 4. Shared pieces (`OnboardingKit.swift`, `GuideActions.swift`)

* **Page scaffold** `GuidePage(heading:content:)`: scroll view, heading, content, an error line at the bottom
  (`role="alert"` on the web, `W:src/connection-guide.ts:96`): red `.callout` text with
  `exclamationmark.circle.fill`, hidden while empty, announced to VoiceOver when it appears.
* **Numbered steps** `GuideSteps`: a filled 28 pt circle with the number (`Color.hqTint`, white bold digit) and the
  step's text beside it, 18 pt between steps (`W:src/connection.css:116-118`). VoiceOver reads "1. Open Terminal…".
* **Key caps.** The web's `<kbd>` (`W:src/connection-guide.ts:98`). **DECISION D5:** drawn inline as semibold text on a
  `HQPalette.searchFill` background through `AttributedString` (`backgroundColor`), with a hair space each side; no
  border. VoiceOver reads the names: `⌘ Space` → "Command Space", `⌘ V` → "Command V", `⌘ N` → "Command N",
  `Control C` → "Control C", `Return`, `Enter`.
* **Note card** `GuideNote`: a filled card with one paragraph (`.ios-setup-note`).
* **Command card** `CommandCard`: optional monospaced block (14 pt scaled, wraps anywhere, `.textSelection(.enabled)`),
  a row of one or two glass buttons of equal width (they stack at accessibility sizes), a status line under them, and
  an optional disclosure. The status line is `role="status"` on the web: `.footnote`, secondary colour, announced with
  `AccessibilityNotification.Announcement` when its text changes to something non-empty.
* **Disclosure** `GuideDisclosure(title:)`: a `DisclosureGroup` whose label is the web's `<summary>` text. Closed at
  first; its state is kept while the screen stays on the stack.
* **Actions** (`GuideActions.swift`), injected so tests can force each failure:

```swift
protocol GuideClipboard { func copy(_ text: String) -> Bool }            // live: UIPasteboard.general.string = text;
                                                                         //       returns UIPasteboard.general.hasStrings
protocol GuideSharing  { func share(_ text: String, from: UIView) -> Bool } // live: UIActivityViewController(activityItems: [text]);
                                                                         //       false when nothing can present it
protocol GuideLinks    { func open(_ url: URL) async -> Bool }           // live: see below
```

  Links: `https://apps.apple.com/…` opens with `UIApplication.shared.open` (the App Store app); every other `https`
  link opens in an `SFSafariViewController` over the flow, as the web does (`W:ios/App/App/HermesPlatform.swift:1267-1269`).
  **DECISION D6:** the App Store link leaves the app instead of loading the store page inside a Safari sheet.
  `open` returns false when the URL is not `https`, has user info, or nothing can present. A share sheet on iPad is
  anchored to the button that opened it.
* **Haptics.** A successful copy plays `UINotificationFeedbackGenerator().notificationOccurred(.success)`
  (`MEM:taptic-feedback-gaps.md:12-13`: copies were among the "15 silent spots wired"). A failed copy plays nothing.
  Navigation taps play nothing.

## 5. Row by row

### 5.1 R1 (L75) — Welcome screen

**Web.** `W:src/connection-onboarding.ts:47-57`. Shown when the launch is not a returning one (§3.2).

**Native.** `WelcomeView`, the flow's root, navigation bar hidden. Top to bottom:

| Element | Text |
|---|---|
| Icon | `LaunchIcon`, 72 pt, decorative |
| Heading (two lines, `.largeTitle.bold()`) | `Your Hermes,` / `wherever you are.` |
| Lead (`.body`, secondary) | `Chat with your agents, see what they’re working on, and get a ping when they’re done, right from your iPhone.` |
| Row 1 (`desktopcomputer`) | **`Hermes stays on your computer.`** `Your agents, chats and files stay there.` |
| Row 2 (`iphone`) | **`Hermes HQ connects your iPhone to it.`** `Set it up once; it takes a few minutes.` |
| Row 3 (`lock`) | **`Only you can get in.`** `Hermes HQ never stores your password.` |
| Primary button | `Get Started` → `go(.hermes)` |
| Secondary button | `I already have an address` → `go(.connect)` |

Each row: a 30 pt tinted symbol, a bold first line (label colour) and the second line under it (secondary), 18 pt
between rows (`W:src/connection.css:102-106`). VoiceOver reads a row as one element: "Hermes stays on your computer.
Your agents, chats and files stay there."

Identifiers: `onboarding.welcome`, `onboarding.welcome.start`, `onboarding.welcome.address`.

**Wire.** None.

**Owner.** `MEM:onboarding-clarity.md`: "make the onboarding process clearer, dumb it down so that EVERYONE will get it
right." and "Get Started → `hermes` screen: Copy Message / Send… (share sheet into Telegram/Discord), then I Have the
Address → form."

**Fixture.** None needed to see it: a clean simulator with `-HQDebugResetAccounts YES -HQDebugWelcome YES`.

**Acceptance.**
1. A clean first run (no saved sign-in, never signed in) shows the welcome with every string above; a Release build
   does so with no launch arguments.
2. Get Started shows "Let Hermes set it up."; I already have an address shows the form with an empty address and
   a Back that returns to the welcome.
3. A phone that has signed in before (flag set), signed out and relaunched shows the form, not the welcome; Back from
   that form shows the welcome.
4. Largest accessibility text size: nothing is cut off, both buttons are reachable by scrolling. Dark and light
   screenshots looked at.

### 5.2 R2 (L76) — Back stack

**Web.** `W:src/connection-onboarding.ts:10-27`:
`go(next)`: ignored while busy or when `next` is the current step; `'back'` pops (to `welcome` when the history is
empty); a step already on the history truncates the history to it; any other step pushes the current one.

**Native.** `OnboardingFlow`:

```swift
func go(_ step: OnboardingStep)   // no-op when busy or when step is on top
                                   // if a controller for `step` is on the stack → popToViewController(it, animated: true)
                                   // else → pushViewController(make(step), animated: true)
func back()                        // no-op when busy; popViewController(animated: true)
var isBusy: Bool                   // set by the form while a sign-in or the version check runs
```

While busy: the top controller's `navigationItem.hidesBackButton = true`, the interactive pop gesture is off, Cancel
(sheet mode) is disabled, `isModalInPresentation = true` in the sheet, and every `go` is ignored
(`W:src/connection-onboarding.ts:157`, `setBusy`). A step's controller is found by an `OnboardingStep` it carries, not
by class, because the Mac and Linux screens share classes.

Loops that must work (the web's own comment names the first two):

| Start stack | Action | Result |
|---|---|---|
| `[welcome, hermes, connect]` | form's "Need help connecting?" (`go(.hermes)`) | pops to `[welcome, hermes]` |
| `[welcome, connect]` (returning) | "Need help connecting?" | pushes: `[welcome, connect, hermes]` |
| `[welcome, connect, hermes]` | "I Have the Address" (`go(.connect)`) | pops to `[welcome, connect]` |
| `[welcome, hermes, where, mac1, mac2, mac3]` | "Type the Address Instead" | pushes `connect` |
| `[…, mac3, connect]` | "Need help connecting?" | pops to `[welcome, hermes]` |
| `[connect]` (sheet) | "Need help connecting?" then "Set It Up Myself" | `[connect, hermes, where]`; Back, Back returns to the form; Cancel closes the sheet from any depth |

`showForm(address:)` (the web's `showConnect`, `W:src/connection-onboarding.ts:158-159`): `go(.connect)` from wherever
the flow is, then the address is put in the field (which asks about it). `SceneDelegate` calls it when a
`hermes://connect` link arrives while the flow is the root, instead of rebuilding the root; the sheet's flow gets the
same call from `AddGatewayFlow`. It is ignored while busy.

The form's model (address, username, Name as typed; never the password after a success) lives as long as its
controller is on the stack, so going to the guide by a push and coming back keeps what was typed. When the form is
popped off (help from `[…, hermes, connect]`), what was typed is gone, as on the web where the fields are reset only
by a new mount. **DECISION D7:** the flow keeps the address text when the form is popped by `go(.hermes)` and puts it
back when the form is next shown, so asking for help never costs the address. The password is never kept.

**Acceptance.** Unit tests on `OnboardingFlow` with a navigation controller (animations off) for every row of the
table, for busy (no step changes), and for `go` to the current step. UI test: the first and third loops by tapping,
plus an interactive swipe back from `where` to `hermes`.

### 5.3 R3 (L77) — "Where does Hermes run?"

**Web.** `W:src/connection-onboarding.ts:58-71,146-152`.

**Native.** `WhereView`. Bar title `Set it up yourself`. Heading `Where does Hermes run?`. Under it
`Pick the computer Hermes is installed on.` Then four choice rows (symbol, bold title, secondary text, chevron):

| Symbol | Title | Text | Goes to |
|---|---|---|---|
| `laptopcomputer` | `On a Mac` | `One command sets it up. Then you sign in with your Nous account.` | `mac1` |
| `server.rack` | `On Linux or a server` | `The same one command, run there or over SSH. Then you sign in with Nous.` | `linux1` |
| `desktopcomputer` | `On Windows` | `Uses Tailscale, a free app, on that computer and this iPhone, with a password.` | `other1` |
| `link` | `Someone gave me an address` | `Sign in with the address and details they sent you.` | `connect` |

Footnote: `No Hermes yet? It runs on a computer, not on your phone. ` + link `Install Hermes first` + `, then come back.`
(the web says "your phone" here on every device; kept). The link opens
`https://hermes-agent.nousresearch.com/docs/` through `GuideLinks`. When it cannot open, the error line reads
`Couldn’t open the guide. Open this address in Safari: https://hermes-agent.nousresearch.com/docs/`; it is cleared when
the link is tapped again.

Identifiers: `onboarding.where`, `onboarding.where.mac`, `.linux`, `.windows`, `.address`, `.install-link`.

**Acceptance.** Each row lands on its screen; the link opens the docs in the in-app Safari sheet (UI test asserts the
Safari sheet's Done button, or with `-HQDebugGuideOut` the recorded URL); with `-HQDebugGuideFail open` the error line
shows the exact sentence. Rows keep 14 pt vertical padding at every text size (screenshot at the largest size looked at).

### 5.4 R4 (L78) — "Let Hermes set it up"

**Web.** `W:src/connection-guide.ts:19-30` (the message), `:146-155` (the screen), `:183` (feedback).

**Native.** `LetHermesView`. Empty bar title. Heading `Let Hermes set it up.` Then:

1. Paragraph: `Send this message to your Hermes, wherever you chat with it: Telegram, Discord, the Hermes app or its terminal. Hermes sets up its own computer for you.`
2. Command card with no visible block, two buttons `Copy Message` and `Send…`, a status line, and a disclosure
   `Show the message` holding the message in monospaced, selectable text.
3. Numbered steps:
   1. `Hermes runs the setup on its computer.`
   2. `It may send you a link or two to sign in to, both free: ` **`Nous`** `, so only you can get in, and ` **`Tailscale`** `, which gives that computer an address your iPhone can reach from anywhere.`
   3. `When it’s done, Hermes sends you the address. Paste it on the next screen and tap ` **`Sign in with Nous`** `.`
4. Footnote: `Tailscale runs only on that computer: nothing to install on this iPhone. Works when Hermes runs on a Mac or Linux, servers included.`
5. Primary `I Have the Address` → `go(.connect)`; secondary `Set It Up Myself` → `go(.where)`.

The message (`OnboardingCopy.hermesConnectPrompt`), exact, with `connectCommand` =
`curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh`:

```text
Please connect this computer to Hermes HQ, the iPhone app for Hermes, so I can reach you from anywhere and sign in with my Nous account.

Run this in your terminal, on this computer itself (if your terminal runs in a container, sandbox or another machine, stop and tell me):
curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh -s -- --agent

It's safe to run again and again. Each time it either finishes or prints a NEXT STEP. If the next step is for you, do it. If it's for me (a link to open, a code, or a command that needs my password), send it to me word for word and wait until I say I've done it. Then run the command again, until it says DONE.

It uses Tailscale on this computer (free) to give it an address my phone can reach; my phone doesn't need Tailscale. Never send me files from this computer, and put any file path you mention in backticks.

When it says DONE, send me the address it prints and tell me to paste it into Hermes HQ and tap Sign in with Nous. If it says it can't run on this computer, tell me why.
```

The message uses straight apostrophes and says "the iPhone app" on every device, as the web's does (it is text for an
agent). It is copied and shared byte for byte; a unit test compares it with a copy of the web string kept in the test.

Feedback (R10): Copy Message → `Copied. Paste it into your chat with Hermes.` or
`Couldn’t copy. Tap Send… or Show the message instead.`; Send… failing → `Couldn’t open sharing. Tap Copy instead.`

Identifiers: `onboarding.hermes`, `onboarding.hermes.copy`, `.share`, `.show-message`, `.message`, `.status`,
`.have-address`, `.myself`.

**Wire.** None. The app never fetches `connect.sh`; it only hands the text over.

**Owner.** `MEM:onboarding-clarity.md`: "This needs to be something you can have your agent do for you. This isn't easy
enough." and, after the first real run leaked a file path into Telegram, the follow-up now in the message: "Never send
me files from this computer, and put any file path you mention in backticks." `MEM:hermes-setup-prompt.md`: "keep the
prompt and `SETUP_COMMANDS` in sync (test checks order)."

**Acceptance.**
1. Copy Message puts exactly the message on the pasteboard (UI test reads `copy.txt` written by `-HQDebugGuideOut`;
   unit test with a fake clipboard) and shows the Copied line; VoiceOver hears it.
2. Send… opens the system share sheet with the message as its one text item (UI test: the sheet appears and offers
   Copy; `share.txt` equals the message).
3. Show the message opens and closes; the text can be selected.
4. Both buttons at the end go where the table says.

### 5.5 R5 (L79) — Mac guide, 3 steps

**Web.** `W:src/connection-guide.ts:103-142` with `kind = 'mac'`; feedback `:184`.

**Native.** `QuickSetupViews.swift`, `kind: .mac`.

**`mac1`** — bar title `Step 1 of 3`, heading `Get the setup command onto your Mac.`
* Paragraph: `You’ll paste one line into Terminal on your Mac. It sets up everything else for you.`
* Command card: block `curl -fsSL https://raw.githubusercontent.com/mrcharlesiv/hermes-hq/main/connect.sh | sh`;
  buttons `Copy` and `Send to Your Mac…`; status line.
  Copy → `Copied. If this iPhone and your Mac use the same Apple Account, press ⌘V in Terminal on your Mac to paste it.`
  or `Couldn’t copy. Tap Send to Your Mac… instead.` Send failing → `Couldn’t open sharing. Tap Copy instead.`
* Footnote: `Or on your Mac, open ` **`github.com/mrcharlesiv/hermes-hq`** ` in a web browser and copy the command from there.`
  (bold text, not a link: it is something to type on the Mac).
* Primary `Next` → `mac2`.

**`mac2`** — bar title `Step 2 of 3`, heading `Run it in Terminal on your Mac.`
* Numbered steps:
  1. `Open ` **`Terminal`** `: press ` ⌘ Space `, type ` **`Terminal`** `, then press ` Return `.`
  2. `Paste the command with ` ⌘ V `, then press ` Return `.`
  3. `Do what it asks. It signs this Mac in to ` **`Nous`** `, so only you can get in, and to ` **`Tailscale`** `, which gives your Mac an address this iPhone can reach from anywhere (both free). It may open your browser for you to sign in, or ask you to click ` **`Allow`** `.`
* Note card: `It takes about five minutes. Tailscale runs only on your Mac: your iPhone doesn’t need it. If you stop partway, run the command again: it picks up where it left off.`
* Disclosure `If Terminal shows a problem` (R7, §5.7).
* Primary `Next` → `mac3`.

**`mac3`** — bar title `Step 3 of 3`, heading `Scan the QR code with this iPhone.`
* Paragraph: `When the setup is done, Terminal shows a QR code. It holds your Mac’s address, so you don’t have to type it.`
* Numbered steps:
  1. `Open the ` **`Camera`** ` app and point it at the QR code on the screen.`
  2. `Tap ` **`Open in Hermes HQ`** `.`
  3. `Tap ` **`Sign in with Nous`** `, with the same Nous account you used on your Mac.`
* Note card: `Keep your Mac on and awake: Hermes HQ can reach Hermes only while it is.`
* Secondary button `Type the Address Instead` → `go(.connect)`.

Scanning works today in the shipped identity: the QR holds `hermes://connect?url=…`, which the app already handles;
with the flow on screen it calls `showForm(address:)` (§5.2). In the `native` identity the scheme is
`hermeshq-native`, which no tool prints; step 2's sentence stays as written there (the identity is not shipped).

Identifiers: `onboarding.mac-1` (`.copy`, `.share`, `.status`, `.next`), `onboarding.mac-2` (`.trouble`, `.next`),
`onboarding.mac-3` (`.type-address`).

**Owner.** `MEM:onboarding-clarity.md`: "Mac: 3 screens (Copy or Send to Your Mac… share sheet; Terminal keys +
troubleshooting; scan the QR code)." and "Keep the in-app guide in sync with what dispatch-connect prints."

**Acceptance.** The three screens show every string; Copy leaves exactly the command on the pasteboard; Send to Your
Mac… opens the share sheet with the command; a `hermes://connect?url=https%3A%2F%2Fexample-mac.tail1234.ts.net` link
opened while `mac3` is on screen lands on the form with `https://example-mac.tail1234.ts.net` in the address field
and nothing signed in (the link is only handed to the app with `simctl openurl` on the test's own simulator; no
network host is contacted beyond the form's probe of that invented name, which fails quietly). Key caps are read by
VoiceOver as words.

### 5.6 R6 (L80) — Linux or server guide, 3 steps

**Web.** The same function with `kind = 'linux'` (`W:src/connection-guide.ts:103-142`), feedback `:185`.

**`linux1`** — `Step 1 of 3`, heading `Get the setup command onto that computer.`
* Paragraph: `You’ll paste one line into a terminal on the computer running Hermes, or into an SSH session to it. It sets up everything else for you.`
* Command card: the same command; buttons `Copy` and `Send…`.
  Copy → `Copied. Paste it into the terminal on that computer, or your SSH session to it.` or
  `Couldn’t copy. Tap Send… instead.` Send failing → `Couldn’t open sharing. Tap Copy instead.`
* Footnote: `Or on the computer you’ll type it on, open ` **`github.com/mrcharlesiv/hermes-hq`** ` in a web browser and copy the command from there.`
* `Next` → `linux2`.

**`linux2`** — `Step 2 of 3`, heading `Run it in a terminal there.`
* Steps:
  1. `Open a terminal on the computer running Hermes, or connect to it with ` **`SSH`** `.`
  2. `Paste the command and press ` Enter `.`
  3. `Do what it asks. It signs that computer in to ` **`Nous`** `, so only you can get in, and to ` **`Tailscale`** `, which gives it an address this iPhone can reach from anywhere (both free). It may show a link to open in any browser (this iPhone’s is fine), or ask for your password once.`
* Note card: `It takes about five minutes. Tailscale runs only on that computer: your iPhone doesn’t need it. If you stop partway, run the command again: it picks up where it left off.`
* Disclosure `If the terminal shows a problem` (R7).
* `Next` → `linux3`.

**`linux3`** — `Step 3 of 3`, heading `Scan the QR code with this iPhone.`
* Paragraph: `When the setup is done, the terminal shows a QR code. It holds that computer’s address, so you don’t have to type it.`
* Steps: 1 and 2 as on `mac3`; 3. `Tap ` **`Sign in with Nous`** `, with the same Nous account you used there.`
* Note card: `Keep that computer on: Hermes HQ can reach Hermes only while it is.`
* Secondary `Type the Address Instead` → `go(.connect)`.

Identifiers: `onboarding.linux-1/2/3` with the same suffixes as the Mac screens.

**Owner.** `MEM:onboarding-clarity.md`: "The app question is now Mac / Linux or a server / Windows / given an address."
and (rejecting Tailscale on the phone for this path) "the whole purpose of sign in with nous is so that you don't have
to use tailscale".

**Acceptance.** As R5, with the Linux strings; the Mac and Linux screens are compared string by string in a unit test
against a table copied from the web source, so a Mac sentence can never show on the Linux path.

### 5.7 R7 (L81) — "If the terminal shows a problem"

**Web.** `W:src/connection-guide.ts:121-130`, a `<details>` on step 2 of each quick guide.

**Native.** A `GuideDisclosure` on `mac2` titled `If Terminal shows a problem` and on `linux2` titled
`If the terminal shows a problem`. Inside, a list of problem (bold, label colour) and what to do (secondary), 14 pt
between items:

| Shown on | Problem | What to do |
|---|---|---|
| Mac | `“Hermes isn’t installed”` | `Install Hermes on this Mac first (` link `Hermes setup guide` `), then run the command again.` |
| Linux | `“Hermes isn’t installed”` | `Install Hermes on that computer first (` link `Hermes setup guide` `), then run the command again.` |
| Mac | `“Hermes didn’t start in the background”` | `Open a new Terminal window with ` ⌘ N `, type ` `hermes serve` ` and press ` Return `. Leave it running, then run the command again in the first one.` |
| Linux | `“Hermes didn’t start in the background”` | `In a second terminal, type ` `hermes serve` ` and press ` Enter `. Leave it running, then run the command again in the first one.` |
| Mac only | `“Needs Node.js 20 or newer”` | `Update Hermes: type ` `hermes update` ` and press ` Return `, then run the command again.` |
| Linux only | `“Tailscale is installed but not signed in”` | `Type ` `sudo tailscale up` `, open the link it shows and sign in, then run the command again.` |
| Linux only | `“systemd user services … can’t reach”` | `Log in to that computer directly or over SSH as yourself, not with su or sudo, then run the command again.` |
| both | `“Turn on MagicDNS and HTTPS Certificates”` | `Open the link it shows, switch both on, then run the command again.` |
| both | `“Restart Hermes now”` | `Stop Hermes where you started it (` Control C ` in its window) and start it again the same way. The setup carries on by itself.` |
| both | `Anything else` | `Run the command again; that’s always safe. Still stuck? Paste what the terminal says into a chat with Hermes and ask it for help.` |

Order on Mac: installed, background, Node, MagicDNS, Restart, Anything else. Order on Linux: installed, background,
Tailscale not signed in, systemd, MagicDNS, Restart, Anything else (the web's order). Commands (`hermes serve`,
`hermes update`, `sudo tailscale up`) are monospaced inline text. The `Hermes setup guide` link opens
`https://hermes-agent.nousresearch.com/docs/`; failing, the screen's error line reads
`Couldn’t open it. Open this address in Safari: https://hermes-agent.nousresearch.com/docs/`.

These commands are text for the person to type on their own computer. The app never runs anything.

**Acceptance.** Closed at first; opening shows six items on Mac and seven on Linux in the order above; the link opens;
at the largest text size the open list scrolls and `Next` is still reachable.

### 5.8 R8 (L82) — Windows path

**Web.** `W:src/connection-guide.ts:158-170`; the message `:70-90`; feedback `:186`.

**`other1`** — bar title `Step 1 of 2`, heading `Install Tailscale on both.`
* Paragraph: `Tailscale is a free app that privately links this iPhone and the computer running Hermes, wherever you are.`
* Steps:
  1. **`On this iPhone:`** ` install Tailscale and sign in.` with a glass button under it `Get Tailscale` →
     `https://apps.apple.com/app/tailscale/id1470499037` (opens the App Store; failing →
     `Couldn’t open it. Open this address in Safari: https://apps.apple.com/app/tailscale/id1470499037`).
  2. **`On the computer running Hermes:`** ` install Tailscale from ` **`tailscale.com/download`** ` and sign in with the same account.`
* `Next` → `other2`.

**`other2`** — bar title `Step 2 of 2`, heading `Let Hermes do the setup.`
* Paragraph: `Copy this message and send it to Hermes on that computer, wherever you chat with it: in its terminal, Telegram, Discord or the Hermes app.`
* Command card: one button `Copy Message for Hermes`, status line, disclosure `Show the message` with
  `OnboardingCopy.hermesSetupPrompt` (below). There is no Send… button here on the web; none is added.
  Copy → `Copied. Paste it into a chat with Hermes on that computer.` or
  `Couldn’t copy. Tap Show the message to select it.`
* Paragraph: `Hermes does the setup, has you choose a password, then tells you the ` **`address`** ` and ` **`username`** ` to sign in with.`
* Plain link-style button `I’d rather do it myself` → `go(.manual)`.
* Primary `Next: Sign In` → `go(.connect)`.

`hermesSetupPrompt`, exact (`W:src/connection-guide.ts:73-90`), built from the same constants as the manual page
(`serve` = `tailscale serve --bg 9119`, `secret` = `openssl rand -base64 32`, `env` = the four lines of §5.9,
`start` = `hermes dashboard --no-open`):

```text
Please set up this computer so I can use Hermes from Hermes HQ, the iPhone app for Hermes. Use your terminal tools and do each step yourself; stop and ask me only for what you can't do. If your terminal runs somewhere other than this computer (a container, sandbox or remote machine), stop and tell me.

1. Check that Tailscale is installed, running and signed in (tailscale status). If it isn't, tell me how to install it and sign in, and wait for me. Remind me to install Tailscale on my phone with the same account, and to turn on MagicDNS and HTTPS certificates in the Tailscale admin console (https://login.tailscale.com/admin/dns).

2. Run tailscale serve status. If nothing is being served, run: tailscale serve --bg 9119
If something is already served, don't replace it; run tailscale serve --bg --https=8443 9119 instead and use :8443 in the address. The address is https:// plus this computer's MagicDNS name (Self.DNSName in tailscale status --json, without the trailing dot), e.g. https://your-computer.your-tailnet.ts.net

3. Ask me for the username and password I want to type into Hermes HQ, or offer to generate a strong password. These are sign-in details for this computer's Hermes, not an AI provider login. Generate a secret with: openssl rand -base64 32

4. Back up ~/.hermes/.env, then set these four lines in it (replace any existing values for the same keys, don't duplicate them):
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=your-username
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=your-long-password
HERMES_DASHBOARD_BASIC_AUTH_SECRET=the-secret-you-generated
HERMES_DASHBOARD_PUBLIC_URL=https://your-computer.your-tailnet.ts.net
using my username and password, the secret from step 3 and the address from step 2 (with :8443 if you used it).

5. Start the dashboard so it keeps running after this chat ends: hermes dashboard --no-open (in the background, e.g. with nohup, or as a login service). If a dashboard is already running, restart it so it reads the new settings.

6. Check it: curl -sI on the address should answer, not "400 Invalid Host header". If it fails, fix it and check again.

When you're done, tell me in plain words the address and username to type into Hermes HQ, and anything I still have to do myself. Don't repeat the password back in the chat.
```

Identifiers: `onboarding.other-1` (`.get-tailscale`, `.next`), `onboarding.other-2` (`.copy`, `.show-message`,
`.status`, `.myself`, `.next`).

**Owner.** `MEM:hermes-setup-prompt.md`: the owner "asked for the gateway help steps to include a prompt you give your
Hermes so it does the setup"; "manual steps stay below as 'Or do it yourself'". `MEM:new-user-setup-flow.md` is why the
fourth `.env` line exists: "Hermes rejects any Host header that isn't its bound host unless
`HERMES_DASHBOARD_PUBLIC_URL` declares it".

**Acceptance.** Get Tailscale asks iOS to open the App Store link (recorded with `-HQDebugGuideOut`; on a simulator
without the App Store the system may show Safari, which is not checked); Copy Message for Hermes copies the prompt
exactly; I’d rather do it myself shows the manual page; Next: Sign In shows the form.

### 5.9 R9 (L83) — "Set it up yourself" manual page

**Web.** `W:src/connection-guide.ts:32-68` (commands and the copied text), `:171-179` (the page), `:187` (feedback).

**Native.** `ManualSetupView`. Bar title `Without Hermes’s help`. Heading `Set it up yourself.`
* Paragraph: `Type these on the computer running Hermes, not on this iPhone. Tailscale should already be on both, signed in to the same account, with MagicDNS and HTTPS Certificates turned on in its ` link `admin console` `.`
  → `https://login.tailscale.com/admin/dns`.
* Glass button `Copy All Steps`, status line. Copy →
  `Copied. Paste them on your computer, or into a note or message to yourself.` or
  `Couldn’t copy. The steps are listed below.`
* Three numbered sections, each with a bold title (`.headline`), monospaced selectable blocks and text:
  1. **`Share Hermes on your Tailscale network`** · block `tailscale serve --bg 9119` ·
     `It prints your address, like https://your-computer.your-tailnet.ts.net. If this computer already shares something with Tailscale Serve, this replaces it: use --https=8443 instead and add :8443 to the address.` ·
     link `Tailscale Serve guide` → `https://tailscale.com/docs/features/tailscale-serve`
  2. **`Turn on sign-in`** · `Make a secret:` · block `openssl rand -base64 32` ·
     `Add four lines to the file ~/.hermes/.env, with your own username, password, that secret and the address from step 1:` ·
     block (four lines):
     ```text
     HERMES_DASHBOARD_BASIC_AUTH_USERNAME=your-username
     HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=your-long-password
     HERMES_DASHBOARD_BASIC_AUTH_SECRET=the-secret-you-generated
     HERMES_DASHBOARD_PUBLIC_URL=https://your-computer.your-tailnet.ts.net
     ```
     · `You choose this username and password here; they aren’t your AI provider’s login. Without the last line, Hermes turns your phone away.` ·
     link `Sign-in guide` → `https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard`
  3. **`Start Hermes`** · `Run this and leave it running. Restart it whenever you change those lines.` ·
     block `hermes dashboard --no-open`
* Primary `Next: Sign In` → `go(.connect)`.

Copy All Steps copies `OnboardingCopy.setupStepsText`, exact (`W:src/connection-guide.ts:47-68`; note the trailing
newline):

```text
Hermes HQ setup (type these on the computer where Hermes is installed)

Before you start: Tailscale is installed and signed in on this computer and on your iPhone, with the same account. In the Tailscale admin console (https://login.tailscale.com/admin/dns), MagicDNS and HTTPS Certificates are on.

1. Share Hermes on your Tailscale network:
tailscale serve --bg 9119
It prints your address, like https://your-computer.your-tailnet.ts.net
(If this computer already shares something with Tailscale Serve, that command replaces it. Use: tailscale serve --bg --https=8443 9119, and add :8443 to the address.)

2. Turn on sign-in. Make a secret:
openssl rand -base64 32
Then add these four lines to the file ~/.hermes/.env, with your own username, password, that secret and the address from step 1:
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=your-username
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=your-long-password
HERMES_DASHBOARD_BASIC_AUTH_SECRET=the-secret-you-generated
HERMES_DASHBOARD_PUBLIC_URL=https://your-computer.your-tailnet.ts.net

3. Start Hermes and leave it running:
hermes dashboard --no-open
(Restart it whenever you change those lines.)

4. In Hermes HQ, enter the address from step 1 and the username and password from step 2.

More on sign-in, including a hashed password: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
```

("your iPhone" in the second paragraph is the device word.) A link that cannot open shows
`Couldn’t open it. Open this address in Safari: <that link’s address>` in the screen's error line.

Identifiers: `onboarding.manual` (`.copy-all`, `.status`, `.admin-link`, `.serve-link`, `.signin-link`, `.next`).

**Owner.** `MEM:new-user-setup-flow.md`: "setup page with exact commands + 'Copy steps' button". The values are
placeholders ("your-username"); the app never writes a real secret anywhere.

**Acceptance.** The page shows the three sections in order with the exact commands; Copy All Steps copies the text
above byte for byte; each of the three links opens its address; the blocks can be selected; at the largest size the
four `.env` lines wrap inside their block without clipping.

### 5.10 R10 (L84) — Copy and share feedback

**Web.** `W:src/connection-guide.ts:182-208`.

**Native.** One model per command card or section, `GuideFeedback` (`@Observable`): `status: String`.

| Kind | Copies / shares | Copied line | Couldn’t copy line |
|---|---|---|---|
| `agent` | `hermesConnectPrompt` | `Copied. Paste it into your chat with Hermes.` | `Couldn’t copy. Tap Send… or Show the message instead.` |
| `connect` | `connectCommand` | `Copied. If this iPhone and your Mac use the same Apple Account, press ⌘V in Terminal on your Mac to paste it.` | `Couldn’t copy. Tap Send to Your Mac… instead.` |
| `connectLinux` | `connectCommand` | `Copied. Paste it into the terminal on that computer, or your SSH session to it.` | `Couldn’t copy. Tap Send… instead.` |
| `prompt` | `hermesSetupPrompt` | `Copied. Paste it into a chat with Hermes on that computer.` | `Couldn’t copy. Tap Show the message to select it.` |
| `steps` | `setupStepsText` | `Copied. Paste them on your computer, or into a note or message to yourself.` | `Couldn’t copy. The steps are listed below.` |

Rules, as the web's:
* Tapping Copy clears the line, copies, then sets the Copied or the Couldn’t copy line (`:199-202`).
* Tapping a Send button clears the line and opens the share sheet; if it cannot open the line reads
  `Couldn’t open sharing. Tap Copy instead.` (`:207`). A share that opens and is cancelled, or completes, leaves the
  line empty.
* The line belongs to its card: copying on one screen never changes another screen's line (`:193`).
* The line stays until the next tap on that card or until the screen leaves the stack.
* The fallbacks the lines name always exist: the message is selectable under Show the message, the command and the
  steps are selectable on the page, and Send… is next to Copy.
* **DECISION D8:** the web hides Copy or Send when the host offers no clipboard or share function (`:198,206`). On
  iOS both always exist, so the buttons are always shown.

On iOS a pasteboard write practically always succeeds; the Couldn’t copy lines are reached through the injected
`GuideClipboard` (unit tests) and `-HQDebugGuideFail copy` (UI tests).

**Acceptance.** Unit tests of `GuideFeedback` for all five kinds × {copied, failed}, share failure, clear-on-tap, and
card isolation. UI tests: one Copied line seen and screenshotted, one Couldn’t copy line and the sharing line with
`-HQDebugGuideFail copy,share`. VoiceOver: the line is posted as an announcement (unit test on the announcer seam).

### 5.11 R11 (L85) — Lazy load and 400 ms prefetch

**Web.** `W:src/connection-onboarding.ts:116-123,134-136,154-155`: the guide is a separate JavaScript chunk, fetched on
first use and prefetched 400 ms after the welcome shows, "so Get Started never waits" (`:154`).

**Native.** The screens are compiled into the app; there is nothing to fetch. **Proposed as web-shell-only for the
mechanism** (the row exists because the old app's startup JavaScript budget kept the guide out of the first load; a
native binary has no such split). The behaviour the mechanism buys is kept and checked:

* No guide screen is built before it is needed (the welcome costs nothing extra at launch), and building one does no
  I/O.
* Get Started shows "Let Hermes set it up." inside the normal push; nothing waits.

**Acceptance (what the row's planner note asks to be recorded).**
1. Unit test: constructing and laying out each of the ten guide screens at 402 × 874 pt takes under 50 ms each on the
   simulator (median of 5), with no file or network access (a `URLProtocol` trap sees no request).
2. UI test: from the tap on Get Started to the heading `Let Hermes set it up.` existing is under 1 s on a loaded
   simulator; the measured value is written to the report.
3. Launch: first frame time of a clean first run with and without the onboarding code is compared once
   (`-HQLaunchTime`); the difference is written to the report.

The row's outcome is recorded as "web-shell-only mechanism; behaviour seen working" with those three numbers.

### 5.12 R12 (L86) — "Need help connecting?"

**Web.** `W:src/connection-onboarding.ts:104-106`: a secondary button appended after the form, `go('hermes')`. Two
strings on the form point at it (`W:src/connection-ways.ts:8,26`).

**Native.** In `SignInView`, a plain tinted text button `Need help connecting?` under the footnote, 44 pt tall,
centred, `accessibilityIdentifier("sign-in-help")`, always visible (also before the address has been asked about, and
in sheet mode). Tap → `flow.go(.hermes)`. Disabled while busy.

Two strings go back to the web's full wording now that the screen they name exists
(`NAT:App/SignIn/SignInDriving.swift:71,125`):

| Key | Now (trimmed) | Becomes (web) |
|---|---|---|
| `SignInCopy.subtitle(.password)` | `This Hermes uses a username and password.` | `This Hermes uses a username and password. To sign in with your Nous account instead, it needs a one-time setup on its computer: tap Need help connecting? below.` |
| `messages["nous-unavailable"]` | `This Hermes doesn’t offer Sign in with Nous yet. Sign in with its username and password.` | `This Hermes doesn’t offer Sign in with Nous yet. Sign in with its username and password, or finish the Mac setup: tap Need help connecting? below.` |

`GatewayFailure.nousUnavailable.message` (the Net module's copy of the same sentence) is brought in line, and the unit
tests that pin the short strings are updated to the web's strings (a wording change the row requires, not a loosened
assertion).

**(Superseded by D36, §16: inside this stream's flow the form now carries the web's heading and first lead.)**
**DECISION D9:** the form's own heading and first subtitle stay as they are today ("Hermes HQ" and the ways subtitle);
those rows are already ✅ in the parity doc and belong to no m9 stream. The web's "Sign in to Hermes." /
"Add a gateway." headings are not introduced here.

**Acceptance.** The link shows on the root form and in the Add Gateway sheet; tapping it lands on "Let Hermes set it
up." by push or by pop as §5.2's table says; with a password-only fixture address the subtitle reads the long
sentence; a Nous attempt against a password-only gateway shows the long `nous-unavailable` sentence.

### 5.13 R13 (L92) — Optional Name field

**Web.** `W:src/main.ts:187` (`<label>Name<input name="label" … maxlength="60" placeholder="Optional, like Home Mac">`,
after Password and before Connect), `:243-244,270-271` (sent with both kinds of sign-in when not blank),
`W:ios/App/App/HermesNative.swift:2011,2023` (trimmed, first 60 characters, stored as the account's label).

**Native.**
* `SignInModel.name: String` (bound), shown once `ways != nil`, on every form (root, Add Gateway, sign back in):
  for `password` and `both` under the Password field and above the Sign In button; for `nous` under the address field
  and above Sign in with Nous. Field label `Name`, placeholder `Optional, like Home Mac`, style as the other fields,
  `accessibilityIdentifier("sign-in-name")`, `.textInputAutocapitalization(.words)`, autocorrection off,
  `.submitLabel(.go)`. Return in it signs in the way the form offers (Nous-only → Sign in with Nous; otherwise the
  password sign-in), as the web's `enterkeyhint="go"` submit does (`W:src/main.ts:254-258`).
* Typing is capped at 60 characters (extra characters are dropped as typed, counted in `Character`s so an emoji is
  never cut in half).
* `SignInDriving` gains the label on both attempts:

```swift
func signInWithPassword(address: String, username: String, password: String, label: String?) async throws
func signInWithNous(address: String, label: String?) async throws
```

  Conformers to update: `SignInServiceDriver`, `SheetSignInDriver`, `FakeSignInDriver`
  (`NAT:App/Debug/ListsDemo.swift:296`), `Tests/BotListTests.swift:127`. `SignInService.signInWithPassword(…, label:
  String? = nil)` and `signInWithNous(…, label: String? = nil)` pass it into `StoredAccount(…, label:)`; a trimmed
  empty name is `nil`, which keeps a label the gateway already has on this phone (`SavedAccounts.save`, existing
  rule). The cap is applied once more in the service (`String(name.prefix(60))`).
* The name is used wherever the label already is: the Bots/Sessions title switcher, Settings › Gateway, Manage
  Gateways, the Update screen's card (§5.15). The field is not prefilled with an existing label (the web's is empty).
* Busy: the field is disabled while a sign-in runs. After a failed attempt the typed name stays.

**Wire.** Nothing new. The name never leaves the phone: `POST /api/auth/password-login` keeps its body
`{"provider":"…","username":"…","password":"…"}` (a unit test asserts the body has exactly those three keys when a
name is given; Hermes answers 4000-style refusals for unknown parameters on the socket and must not be sent strays
anywhere).

**Owner.** `MEM:onboarding-clarity.md`: "The form is 'Sign in to Hermes' / Address / Name."

**Fixture.** `onboarding-gateway.py` on 9990 (§8) for the password path; the reference Nous fixture on 9992/9993 for
the Nous path.

**Acceptance.**
1. Sign in with the name `Home Mac` → the Bots title switcher and Settings › Gateway show `Home Mac`; relaunch: still
   `Home Mac`.
2. Sign in with the field empty → the computer's friendly name shows, as today.
3. Sign out, sign in again to the same gateway and account with the field empty → the earlier name is kept only if
   the account was still saved (sign-back-in sheet); after a real Sign Out the account is gone and the name with it
   (the web behaves the same: the label lives in the vault record).
4. 61 typed characters keep 60; a name of 60 emoji is stored whole; a name of only spaces is treated as empty.
5. Nous sign-in with a name (reference Nous fixture) stores it.
6. The fixture's ledger shows no `label` in any request.

### 5.14 R14 (L100) — Version check after a typed sign-in

**Web.** `W:src/connection-startup.ts:25` (`STATUS_CHECK_MS = 4000`), `:269-277` (`compat()`: no status reader or no
update screen → not outdated; a 4 s race; any error → not outdated), `:393-413` (`login`: after a good sign-in,
`compat()`; outdated → phase `outdated`, the screen, result `outdated`; else boot),
`W:src/gateway-compat.ts:11-42` (the rule). Launch restore is never checked (`MEM:gateway-version-check.md`: "Launch/restore
is deliberately unchecked (status body is heavy; load-times work)").

**Rule (unchanged, tightened to the web's parser).** Outdated iff `release_date`, trimmed, matches
`^(\d{4})\.(\d{1,2})\.(\d{1,2})$` with month 1…12 and day 1…31, and orders before `2026.9.21`
(`CONTRACT_RELEASES[8]`). Anything else (missing, wrong shape, later, equal) is not outdated. `version` is never
compared (`MEM:gateway-version-check.md`: "Hermes `version` is not monotonic (0.22.2, 1.0.0, 0.21.4 stamped the same
day); only `release_date` orders.").

`NAT:HermesKit/Net/LiveGatewayClient.swift:287-292` differs from the web in three small ways the builder fixes with
tests: it does not trim, it accepts signs (`Int("+9")`), and it accepts three-digit months or days. The parser becomes
the regular expression above.

**Native types** (`HermesKit/Net/GatewayCompatibility.swift`):

```swift
nonisolated struct OutdatedGateway: Sendable, Equatable {
    var version: String        // status.version trimmed, first 24 characters; "" when absent or not a string
    var releaseDate: String    // status.release_date trimmed, as reported
    var canUpdate: Bool        // status.can_update_hermes != false
}
nonisolated enum GatewayCompatibility: Sendable, Equatable {
    case compatible
    case outdated(OutdatedGateway)
    case unknown               // unreadable, slow, or not a release date: never blocks
    var outdated: OutdatedGateway? { get }
}
```

The two call sites and the unit test that match `.outdated(releaseDate:)` are updated
(`AppDelegate.swift:242`, `AddGatewayFlow.swift:80`, `Tests/NetUnitTests.swift:397`).

**Flow.** The check moves from "after the app shows" to "before it shows", as on the web:

1. The sign-in succeeds (the account is saved and current; this does not change).
2. The form stays busy (button still `Signing In…`, the flow busy) while
   `SignInDriving.compatibility() async -> GatewayCompatibility` runs: `SignInServiceDriver` calls
   `service.compatibility(for: signedIn)`, raced against a 4 s sleep in the driver so the cap holds whatever the
   transport does (`.unknown` on the sleep winning). A protocol extension gives fakes a default `.compatible`.
3. `.compatible` or `.unknown` → the success haptic, the password field is cleared, `onSignedIn(.enter)` → the app
   shows, as today.
4. `.outdated(info)` → no haptic (the web taps success only for `started`, `W:src/main.ts:232`), the password field is
   cleared, `onSignedIn(.update(info))` → the Update screen (§5.15).

`SignInModel.onSignedIn` becomes `(SignInOutcome) -> Void` with `enum SignInOutcome { case enter, update(OutdatedGateway) }`.
The old `checkCompatibility` alert code in `SceneDelegate` and `GatewayCompatibilityCheck` is deleted.

**DECISION D10:** holding the form for the check costs one `/api/status` round trip on every typed sign-in (never on
launch). The web does the same, sign-ins are rare, and showing the app and then covering it with a full screen would
look like a glitch. The cap is a hard 4 s.

**Wire.**

```http
GET /api/status            (authenticated like any REST read: the session cookies, or Authorization: Bearer for Nous)
Accept: application/json
→ 200 {"version":"0.21.4","release_date":"2026.9.10","can_update_hermes":true,"auth_required":true,…}
```

Real Hermes: `HA:hermes_cli/web_routers/status.py:509-511` (`"version"`, `"release_date": __release_date__`,
`"can_update_hermes": not _dashboard_local_update_managed_externally()`). No query, no body, no JSON-RPC.

**Owner.** `MEM:gateway-version-check.md`: "older than the release the required contract landed under (contract 8 →
2026.9.21) shows an Update Hermes screen (Check Again / Continue Anyway). Fails open."

**Fixture.** `onboarding-gateway.py` (§8): `POST /__onboarding/status` sets what `/api/status` answers and how.

**Acceptance.**
1. `release_date` `2026.10.01` → straight into the app; the ledger shows exactly one authenticated `/api/status` read
   after the login.
2. `2026.9.20` → the Update screen; `2026.9.21` → the app; `2026.09.20` → the Update screen; `" 2026.9.20 "` → the
   Update screen; `2026.9`, `26.9.20`, `2026.13.1`, `+2026.9.20`, `""`, a number, no key → the app (unit tests on the
   parser; three of them end to end).
3. Status slower than 4 s (`mode: slow`, 6 s) → the app shows 4.0–4.6 s after the login answered, with no Update
   screen and no error.
4. Status 500, not JSON, or the connection dropped → the app shows at once.
5. A cold launch with a saved sign-in against an outdated fixture goes straight in and reads no `/api/status` for
   this check (the ledger's authenticated status count stays 0 for 5 s).
6. A failed sign-in (wrong password) reads no authenticated `/api/status`.

**After the merge.** Entering the app after the check goes through the `offline` stream's launch coordinator:
`.enter` → `LaunchCoordinator.signedIn(account, typed: true)` (the storage check of its §3.4, then the launch screen
until a first list has content, then the app). The train's own after-the-fact alert (`SceneDelegate.checkCompatibility`)
is gone: the form has already read the status once, and a second read would be a second question. Acceptance adds:
with the fixture healthy, exactly **one** authed `GET /api/status` between the login and the first list
(`/__onboarding/state`), on the root form, in the Add Gateway sheet and in the offline screen's sheet alike.

### 5.15 R15 (L101) — "Update Hermes" screen

**Web.** `W:src/main.ts:389-413` (`showOutdated`), `W:src/gateway-compat.ts:44-52` (`outdatedCopy`),
`W:src/connection-startup.ts:415-431` (`recheckOutdated`, `continueOutdated`).

**Native.** `UpdateHermesView` over `UpdateHermesModel`. It is laid out like the web's (which reuses the offline
screen's layout): centred when it fits, scrolling from the top otherwise.

| Element | Text |
|---|---|
| Icon | `LaunchIcon`, 72 pt, decorative |
| Title (`.title2.bold()`, centred, header trait) | `Update Hermes` |
| Recovery, when `canUpdate` | `Hermes HQ needs a newer version of Hermes than the computer running Hermes has, and parts of the app won’t work until it’s updated. On the computer running Hermes, run “hermes update”, then check again.` |
| Recovery, when not | `Hermes HQ needs a newer version of Hermes than the computer running Hermes has, and parts of the app won’t work until it’s updated. Update Hermes on the computer running Hermes the way it was installed, then check again.` |
| Card line 1 (`.headline`) | the gateway's name: `GatewayNaming.title(url:label:)` (the Name just typed wins; else the computer's friendly name; else `Your Gateway`) |
| Card line 2 (`.subheadline`, secondary) | `Hermes 0.21.4 · released 2026.9.10` (with a version) or `Hermes · released 2026.9.10` (without) |
| Primary button | `Check Again` |
| Secondary button | `Continue Anyway` |
| Status line | empty; `Checking…` with a small spinner while a check runs; `Still the older version. An update can take a few minutes.` after a check that is still outdated |

States:

| State | Buttons | Status line |
|---|---|---|
| idle | both enabled | empty |
| checking | both disabled | spinner + `Checking…` |
| still outdated | both enabled | `Still the older version. An update can take a few minutes.` (title, recovery and card re-rendered from the new answer: the version, date or `canUpdate` may have changed) |
| now compatible, or the answer is unknown (slow, unreadable, gateway restarting) | — | the screen is left: the app shows, with the success haptic |

A second tap on Check Again while one runs is ignored (`rechecking`, `W:src/connection-startup.ts:417-418`). Each
check is the same capped read as §5.14 (4 s). Continue Anyway enters the app at once with no further read and no
haptic. The status line is announced to VoiceOver when it changes to non-empty text. The card has 14 pt vertical
padding; both lines wrap.

**DECISION D11:** an unknown answer on Check Again enters the app, as the web's does (its `compat()` reports "not
outdated" for any failure). The app's own reconnect behaviour takes over if the gateway is mid-restart.

**Where it shows.**
* **Root flow.** `SceneDelegate` makes the Update screen the window root (cross-dissolve, as other root swaps).
  Entering calls `showApp(account)`. The sign-in is already saved: if the app is closed on this screen the next launch
  goes straight in (web comment at `W:src/main.ts:386-388`: "the sign-in is saved either way, so the next launch goes
  straight in"). There is no Back: the only ways on are the two buttons.
* **Add Gateway sheet.** The app underneath has already switched to the new gateway
  (`settings.adoptSignedInAccount(account)` runs at sign-in success, as today, because `SignInService` has already
  ended the previous client). When the outcome is `.update`, the Update screen is pushed in the sheet's navigation
  controller with the back button hidden, Cancel removed and `isModalInPresentation = true`; entering dismisses the
  sheet. When the outcome is `.enter` the sheet dismisses as today.
  **DECISION D12:** in the sheet the screen sits over an app that is already on the new gateway. Holding the switch
  back until Continue Anyway would leave the app with an ended client for as long as the person reads the screen.

Identifiers: `update-hermes`, `update-hermes.title`, `.recovery`, `.name`, `.release`, `.check`, `.continue`, `.status`.

**Wire.** `GET /api/status` per Check Again, as §5.14. Nothing else.

**Fixture.** `onboarding-gateway.py`: sign in while it reports `2026.9.10`, tap Check Again (still old), then
`POST /__onboarding/status {"release_date":"2026.10.01"}` and tap again.

**Acceptance.**
1. Outdated sign-in → the screen with the exact title, the `canUpdate` recovery, the name and
   `Hermes 0.21.4 · released 2026.9.10`. With `can_update_hermes: false` the other recovery. With no `version` the
   card reads `Hermes · released 2026.9.10`. A 40-character version shows its first 24 characters.
2. Check Again while still old → `Checking…` with both buttons disabled, then the "Still the older version…" line.
3. After the fixture is "updated", Check Again → the app (Bots list) shows.
4. Continue Anyway → the app shows; the ledger shows no further status read for the check.
5. Kill the app on the Update screen, relaunch → the app shows (signed in), no Update screen.
6. Add Gateway against an outdated second fixture (9991) → the screen inside the sheet; the sheet cannot be swiped
   away; Continue Anyway closes it and the app is on the new gateway.
7. A Name typed at sign-in is the card's first line.
8. Largest text size, light and dark: screenshots looked at; both buttons reachable.

**After the merge.** Continue Anyway and a Check Again that finds the gateway updated call
`LaunchCoordinator.signedIn(account, typed: true)` instead of showing the app directly, so the launch screen may
cover for a moment while the first list loads; the success tap still plays when the app shows. A third place can now
sign in: the offline screen's sheet (`DifferentGatewayFlow`, used by Sign In to a Different Hermes and Sign In
Again). It gets the same screen inside the sheet, locked, exactly as Add Gateway's does (I1). Until I1 is built the
merged branch shows the screen full-screen over the app once the app has appeared
(`GatewayCompatibilityCheck.run`, `NAT:App/Gateways/AddGatewayFlow.swift`), which is a stop-gap that compiles and has
not been seen running.

### 5.16 R16 (L103) — Keychain unreadable → "Sign in again?"

**Web.** `W:src/main.ts:342` (the offline screen's copy for `keychain-unreadable`), `:361-365` (the Sign In Again
button: `confirm(…)`, then `quarantineConnectionStorage`, then `startup.signInAfresh()`), `:383` (the button shows
only for this reason), `W:src/connection-startup.ts:303-308,354-361`, `W:src/connection-storage.ts:166-169`
(quarantine: the unowned local data is parked under a dated key so the next account does not inherit it).

**What "unreadable" is natively.** The Keychain item exists and was returned, but its bytes do not decode
(`Keychain.swift:193` → `.keychainUnreadable`). Locked (`errSecInteractionNotAllowed`) and unavailable (any other
status) are different reasons and never offer Sign In Again: for those, retrying is right and discarding would throw
a good sign-in away.

**Native.**
* `SignInService.discardUnreadableSignIn() throws(GatewayFailure)`: allowed only when the last restore failed with
  `.keychainUnreadable` (otherwise it does nothing and returns); calls the vault's existing clear
  (`AccountVault.clearCurrent()`, which deletes an undecodable item whole, `Keychain.swift:167-181`), then reloads.
* `UnreadableSignIn.confirm(from:onConfirmed:)` (`App/SignIn/UnreadableSignIn.swift`): a system alert

  | | |
  |---|---|
  | Title | `Sign in again?` |
  | Message | `Hermes HQ couldn’t read your saved sign-in. Drafts on this iPhone are kept aside and won’t move to the account you sign in with.` |
  | Buttons | `Sign In Again` (default) · `Cancel` (cancel) |

  The web's `confirm()` is one sentence ("Sign in again? Hermes HQ couldn’t read…") with OK and Cancel; the alert
  splits it at the question mark and names the action on the button.
* On Sign In Again: `discardUnreadableSignIn()`. If it throws, nothing else happens and the launch problem's message
  becomes `Hermes HQ couldn’t switch this iPhone’s saved app data to this account. Your drafts are kept. If iPhone storage is almost full, free up some space, then try again.`
  (the web's `STORAGE_FAILURE`, `W:src/main.ts:44`). If it succeeds: the sign-in form shows as a returning start
  (`[welcome, connect]`), with the address filled in when the train has the `offline` stream's `LastGatewayHint`
  (§12.1) and empty otherwise.
* **Where the button is.** On whatever screen the train shows for `RestoreState.unavailable(.keychainUnreadable)`:
  today `LaunchViewController.showProblem` gains a second glass button `Sign In Again` under Try Again for this
  reason only, and its title and text become the web's for this reason
  (`Can’t Read Your Saved Sign-In` / `Sign in again to continue. Drafts on this iPhone are kept aside, not moved to the account you sign in with.`).
  The other two reasons keep today's screen. See §12.1 for how this meets the `offline` stream's offline screen.
* **Drafts.** **DECISION D13:** nothing is moved. The web parks local data because its drafts were stored without an
  owner. Native drafts, queued messages, phone copies and caches are all filed under an account id
  (`"<account id>|<profile>|<stored session id>"`), so data whose owner cannot be read is already aside: signing in to
  the same address and account finds it again, any other account never sees it. A unit test pins this (a draft saved
  for account A is invisible to account B and visible again to A after an unreadable-Keychain start-over).

**Wire.** None. Try Again is the Keychain read again; no network.

**After the merge (this replaces "Where the button is" and acceptance checks 1–4 above).** The train shows
`OfflineViewController` for every `RestoreState.unavailable` (`NAT:App/Offline/LaunchCoordinator.swift:268-282`);
`LaunchViewController.showProblem` no longer exists. For `keychain-unreadable` that screen already has the web's
title and text, **Try Again**, **Sign In to a Different Hermes** (when an address is known) and **Sign In Again**
(`offline.sign-in-again`), and Sign In Again already asks with the same alert, word for word
(`OfflineCopy.signInAgainTitle/Message`, `NAT:HermesKit/Offline/OfflineCopy.swift:21-29`;
`OfflineViewController.confirmSignInAgain`). On yes it opens the sign-in form in a sheet with the last gateway's
address and username filled in (`DifferentGatewayFlow`); a successful sign-in saves over the unreadable item (the
vault's `editable()` replaces an item it cannot decode) and the app shows. Cancel on the sheet returns to the offline
screen, still retrying. See D27 for why the sheet is kept. Acceptance on the train:

1. Signed in, then relaunched with `-HQDebugCorruptSignIn YES` → the offline screen: `offline.title` is
   `Can’t Read Your Saved Sign-In`, `offline.recovery` is the web's sentence with the device word, Try Again and
   Sign In Again both there.
2. Try Again → the same screen, still unreadable, no crash, no loop; the status line counts down and retries on its
   own without ever discarding anything.
3. Sign In Again → the alert with the exact title, message and buttons. Cancel → nothing changed (a relaunch without
   the hook still shows the screen).
4. Sign In Again → Sign In Again → the sheet with the form (address filled in from `LastGatewayHint`). Signing in to
   the same fixture account brings back a draft typed before; another account (9991) shows no draft in the same bot.
   Cancel on the sheet instead → back on the offline screen, item still unreadable.
5. and 6. as above, unchanged.
7. Exactly one alert in the binary for this: no `UnreadableSignIn.confirm`, no `OnboardingCopy.Unreadable` (I3).

**Owner.** No note names this screen. The copy is the web's.

**Fixture.** No gateway is needed to reach the screen. DEBUG hook `-HQDebugCorruptSignIn YES`
(`#if DEBUG && targetEnvironment(simulator)`): before the first restore, the app's Keychain item is overwritten with
bytes that are not a saved-accounts record. To sign in afterwards: `onboarding-gateway.py` on 9990.

**Acceptance.**
1. Signed in, then relaunched with `-HQDebugCorruptSignIn YES` → the launch problem with the unreadable title and
   text, Try Again and Sign In Again.
2. Try Again → the same screen (still unreadable), no crash, no loop.
3. Sign In Again → the alert with the exact title, message and buttons. Cancel → nothing changed (a relaunch without
   the hook argument still shows the problem, because the item is still unreadable).
4. Sign In Again → Sign In Again → the form shows. Signing in to the same fixture account brings back a draft typed
   before; signing in to another account (second fixture, 9991) shows no draft in the same bot.
5. A locked or unavailable Keychain (unit test with a vault stub) never shows Sign In Again and
   `discardUnreadableSignIn()` leaves the item alone.
6. Relaunch after a completed start-over → the app, signed in, no problem screen.

### 5.17 R17 (L105) — Tailscale explanation copy throughout

**Web.** The sentences that say what Tailscale is for and where it runs, added after the owner said of the setup
(`MEM:onboarding-clarity.md`): "you just don't explain that in the set up at all" — "the app screens, support page,
message for Hermes and every tool step say why. Nous = only you get in; Tailscale = an address your phone can reach,
on the computer only." `W:docs/remote-access.md:125` adds: "Install Tailscale on the computer and sign in. Not on the
phone." The public address the setup creates is a Tailscale Funnel address (`W:docs/remote-access.md:3`); the app's
own copy never says "Funnel", it says "an address this iPhone can reach from anywhere".

**Native.** No screen of its own: the row is done when every sentence below is on screen, word for word, where the
web has it. One unit test (`TailscaleCopyTests`) holds this table and checks each against `OnboardingCopy` /
`SignInCopy`; the UI suite sees T1–T9 on screen.

| # | Where | Sentence |
|---|---|---|
| T1 | `where`, Windows row | `Uses Tailscale, a free app, on that computer and this iPhone, with a password.` |
| T2 | `hermes`, step 2 | `…both free: Nous, so only you can get in, and Tailscale, which gives that computer an address your iPhone can reach from anywhere.` |
| T3 | `hermes`, footnote | `Tailscale runs only on that computer: nothing to install on this iPhone. Works when Hermes runs on a Mac or Linux, servers included.` |
| T4 | `mac2`, step 3 | `…It signs this Mac in to Nous, so only you can get in, and to Tailscale, which gives your Mac an address this iPhone can reach from anywhere (both free)…` |
| T5 | `mac2`, note | `…Tailscale runs only on your Mac: your iPhone doesn’t need it…` |
| T6 | `linux2`, step 3 | `…It signs that computer in to Nous, so only you can get in, and to Tailscale, which gives it an address this iPhone can reach from anywhere (both free)…` |
| T7 | `linux2`, note | `…Tailscale runs only on that computer: your iPhone doesn’t need it…` |
| T8 | `other1` | `Tailscale is a free app that privately links this iPhone and the computer running Hermes, wherever you are.` |
| T9 | `manual` | `…Tailscale should already be on both, signed in to the same account, with MagicDNS and HTTPS Certificates turned on in its admin console.` |
| T10 | message for Hermes (`hermesConnectPrompt`) | `It uses Tailscale on this computer (free) to give it an address my phone can reach; my phone doesn't need Tailscale.` |
| T11 | Linux trouble list | `“Tailscale is installed but not signed in”` · `Type sudo tailscale up, open the link it shows and sign in, then run the command again.` |
| T12 | form, `unreachable` (already native) | `…If you use Tailscale, check that it’s on here too.` |
| T13 | form, `timeout` (already native) | `…and that Tailscale is on if you use it.` |
| T14 | form, `tailscale-off` (already native) | `Turn on Tailscale to reach the computer running Hermes, then try again.` |
| T15 | form, `tailscale-ip` (already native) | `iPhone allows plain http:// to a Tailscale machine only by its name. Use the gateway’s Tailscale name (in the Tailscale app, like mac-mini.tailnet-name.ts.net) instead of its 100.x address, or use https://.` |

The rule the sentences carry, which no new copy may contradict: on the Mac, Linux and "Let Hermes set it up" paths
Tailscale is on the computer only; on the Windows and manual paths it is on both.

**Acceptance.** The unit test passes; the UI suite's walk through every guide screen asserts T1–T9 as static texts;
the copied message contains T10.

## 6. Wire summary

| Call | When | Request | Answer used |
|---|---|---|---|
| `GET /api/status` (no credentials) | the form's existing address probe (unchanged) | `Accept: application/json` | `auth_providers`, `auth_flows` |
| `GET /api/status` (authenticated) | once after a typed sign-in; once per Check Again | `Accept: application/json` | `release_date`, `version`, `can_update_hermes` |
| `POST /api/auth/password-login` etc. | sign-in (unchanged) | unchanged; **no `label`** | unchanged |

No JSON-RPC method is added or changed, so no contract in `HA:tui_gateway/contracts` is touched. The guide, the
welcome, the Name field and the Keychain start-over make no request at all. Links open in the system's browser sheet
or the App Store, outside the app's transport.

## 7. Screen states at a glance

| Screen | States |
|---|---|
| Welcome | one |
| Where | normal · link error line |
| Let Hermes set it up | status: empty / Copied / Couldn’t copy / Couldn’t open sharing · disclosure closed / open |
| Mac 1, Linux 1 | status: empty / Copied / Couldn’t copy / Couldn’t open sharing |
| Mac 2, Linux 2 | trouble list closed / open · link error line |
| Mac 3, Linux 3 | one |
| Windows 1 | normal · link error line |
| Windows 2 | status: empty / Copied / Couldn’t copy · disclosure closed / open |
| Manual | status: empty / Copied / Couldn’t copy · link error line |
| Form | existing states + Name field (hidden until the address is asked about) + help link + busy through the version check |
| Update Hermes | idle · checking · still outdated |
| Launch problem (unreadable) | problem · alert · storage sentence |

## 8. Stand-in gateways

**New: `scripts/fixtures/onboarding-gateway.py`.** Loads `scripts/fixtures/settings-gateway.py` by path (as
`restore-gateway.py` loads the pages fixture; nothing there is edited) for its password sign-in, sessions, roster and
socket, and replaces only `GET /api/status`. Loopback only, invented data.

```
python3 scripts/fixtures/onboarding-gateway.py --port 9990 --credentials build/fixtures/onboarding-a.json
python3 scripts/fixtures/onboarding-gateway.py --port 9991 --label Beta --credentials build/fixtures/onboarding-b.json \
        --release-date 2026.9.10
```

Default status: `{"version":"0.21.5","release_date":"2026.10.01","can_update_hermes":true,"auth_required":true,
"auth_providers":["basic"],"auth_flows":["cookie"],"desktop_contract":8}` (`auth_providers` is what the form's probe
reads, so the password fields show).

Controls (no auth, never under `/api/`):

| | |
|---|---|
| `POST /__onboarding/status {…}` | any of `release_date`, `version`, `can_update_hermes` (a JSON `null` removes the key), `mode`: `ok` · `slow` (with `delay_ms`) · `500` · `garbage` (200 with a non-JSON body) · `drop` (close without answering), `count` (how many reads the mode lasts; default until changed) |
| `GET /__onboarding/state` | `{"status_reads":{"public":n,"authed":n},"logins":n,"login_bodies":[["provider","username","password"],…],"status":{…}}`: key names of each login body only, never values |
| `POST /__onboarding/reset` | back to the defaults, counters zeroed |

A read counts as `authed` when it carries the fixture's session cookie.

**Reference Nous fixture** (Name with Nous, R13 check 5):
`python3 /Users/me/Projects/hermes-hq-native-ref240/scripts/nous-fixture-gateway.py --port 9992 --portal-port 9993 --public-url http://127.0.0.1:9992 --access-ttl 30`

**Ports.** Builders: 9990 (A), 9991 (B), 9992/9993 (Nous gateway and portal), 9994 spare. Stress tester: 9995 (A),
9996 (B), 9997/9998 (Nous), 9999 spare. Every script refuses a busy port and stops only what it started.

**Simulators.** Builders `HQN-m9-onboarding`, stress tester `HQN-m9-onboarding-s`
(`xcrun simctl create "HQN-m9-onboarding" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`; reuse when it
exists). Never the scripts' default simulator; always pass the UDID.

**`scripts/e2e-onboarding.sh <SIM_UDID>`**, modelled on `scripts/e2e-settings.sh`: starts A and B (and the Nous
fixture when `HQN_ONBOARDING_NOUS=1`), passes `TEST_RUNNER_HQN_ONBOARDING_A/_B`, `TEST_RUNNER_HQN_SHOTS`, runs
`-only-testing:HermesHQNativeUITests/OnboardingEndToEndTests`, prints `scripts/e2e-summary.py`, stops its fixtures.
`HQN_ONBOARDING_PORTS="9995 9996 9997 9998"` moves it for the stress tester.

## 9. Tests

### 9.1 Unit (`Tests/Onboarding/`, Swift Testing)

* `OnboardingGateTests`: every combination of the five inputs; the Release rule (all false → welcome).
* `OnboardingFlowTests`: §5.2's table, busy, `showForm(address:)`, the kept address (D7), sheet mode has no welcome.
* `OnboardingCopyTests`: every string of §5 against a table typed from the web source (the test file carries the
  web's strings, including the three long texts, so a drift in either direction fails); the Mac/Linux variants; the
  `.env` lines appear in the same order in the manual page, the copied steps and the prompt
  (`MEM:hermes-setup-prompt.md`: "test checks order"); no string contains "Dispatch"; no welcome or guide string
  contains "gateway".
* `TailscaleCopyTests`: §5.17's table.
* `GuideFeedbackTests`: §5.10.
* `GuideBuildTests`: R11 check 1.
* `GatewayCompatibilityTests`: the parser cases of §5.14 check 2; `OutdatedGateway` fields (version cap 24,
  `can_update_hermes` absent / true / false / a string); `OutdatedCopy` (both recoveries, both release lines).
* `SignInNameTests`: the cap, trimming, emoji, blank → nil, label kept on a save that names none, the login body's key
  set, Return in the Name field picks the right way.
* `SignInModelCompatTests`: the form stays busy through the check; `.enter` / `.update` outcomes; the 4 s cap with a
  driver that never answers (clock injected); no check after a failed sign-in.
* `UpdateHermesModelTests`: the state table of §5.15; a double tap is one check; unknown enters.
* `UnreadableSignInTests`: discard only for unreadable; locked and unavailable untouched; D13's draft test.
* `OnboardingFixtureTests` (live, skipped unless the fixture runs, as the other fixture suites): the service against
  `onboarding-gateway.py` on 9990 for §5.14 checks 1–6.

### 9.2 UI (`UITests/onboarding/OnboardingEndToEndTests.swift`)

Launch arguments for every test: `-HQDebugResetAccounts YES -HQDebugWelcome YES` unless stated.

| Test | Covers |
|---|---|
| `testO01_WelcomeAndFirstSteps` | R1, R2: strings, both buttons, Back |
| `testO02_BackStackLoops` | R2: the loops, swipe back |
| `testO03_WhereAndInstallLink` | R3 |
| `testO04_LetHermesCopyAndShare` | R4, R10: `copy.txt`, `share.txt`, the lines |
| `testO05_MacGuide` | R5, R7 |
| `testO06_LinuxGuide` | R6, R7 |
| `testO07_WindowsAndManual` | R8, R9 |
| `testO08_FailureLines` | R10 with `-HQDebugGuideFail copy,share,open` |
| `testO09_HelpLinkFromForm` | R12, root and Add Gateway sheet |
| `testO10_NameAtSignIn` | R13 checks 1, 2, 4, 6 |
| `testO11_OutdatedScreen` | R14, R15 checks 1–4, 7 |
| `testO12_OutdatedRelaunchAndSheet` | R15 checks 5, 6 |
| `testO13_SlowAndBrokenStatus` | R14 checks 3, 4 |
| `testO14_UnreadableSignIn` | R16 checks 1–4, 6 |
| `testO15_ConnectLinkDuringGuide` | R5: the QR link moves to the form |
| `testO16_LargestTypeWalk` | every screen at the largest accessibility size, light and dark, screenshots |
| `testO17_ReturningStartsOnForm` | R1 check 3 and D2 (no `-HQDebugWelcome`: the form shows, Back shows the welcome) |
| `testO18_GuideOpensAtOnce` | R11 check 2 |
| **After the merge:** `testO14_UnreadableSignIn` rewritten | R16 on the offline screen (§5.16 acceptance 1–4, 6), by the `offline.*` identifiers |
| `testO19_DifferentGatewaySheet` (new) | I1: from the offline screen (`-HQDebugRestoreFailure keychain-unavailable`), Sign In to a Different Hermes → the help link opens the guide inside the sheet with the sheet's Cancel; an outdated fixture ends on the locked Update screen in the sheet; Continue Anyway → the app; one authed status read |
| `testO20_EntersThroughLaunch` (new) | §5.14/§5.15 after the merge: with `-HQDebugResetCaches YES` semantics (nothing saved to show) a typed sign-in shows the launch screen, then the app; with the fixture's lists held back 3 s the launch caption shows and no second form or welcome flashes; the same from Continue Anyway |
| `testO21_PadWalk` (new, iPad simulator, optional pass `HQN_ONBOARDING_PAD=<udid>`) | welcome, chooser, Mac step 1, form and Update screen on an iPad: the word "iPad" in every device sentence, the share sheet opens anchored, content capped at 440 pt and centred |

Screenshots go to `TEST_RUNNER_HQN_SHOTS` as `onboarding-<nn>-<name>-{light,dark}.png`; a row is "done" only after its
screenshots were looked at.

Every other suite on the train must still pass untouched: D2 exists for that. Before handing over, the builder runs
`scripts/e2e.sh` and `scripts/e2e-settings.sh` on its own simulator and ports (`HQN_E2E_PORT`, `HQN_SETTINGS_PORTS`
inside 9990–9994) to prove the form is still reached by plain `app.launch()`.

### 9.3 DEBUG hooks (compiled out of Release)

| Argument | Effect |
|---|---|
| `-HQDebugWelcome YES` | a clean first run starts on the welcome (D2) |
| `-HQDebugCorruptSignIn YES` | simulator only: the saved sign-in is made unreadable before the first restore (R16) |
| `-HQDebugGuideOut <folder>` | writes what Copy put on the pasteboard (`copy.txt`), what Send handed the share sheet (`share.txt`) and the last link asked to open (`open.txt`) |
| `-HQDebugGuideFail copy,share,open` | the named guide actions report failure (R10's and the links' error lines) |

## 10. STRESS PLAN

The stress tester uses simulator `HQN-m9-onboarding-s` and ports 9995–9999 only, starts its own fixtures, and stops
them and shuts its simulator down at the end.

**Load and speed**
1. Release-configuration simulator build, clean install, no arguments: the welcome shows. Then the same with the
   `original` identity.
2. Walk welcome → hermes → where → mac1 → mac2 → mac3 → form → help → … 50 times in one run by script (fast taps, no
   waits beyond existence): no crash, the stack depth never exceeds the longest path (no leaked duplicates: a step is
   on the stack at most once), memory after the 50th loop within 5 MB of after the 5th.
3. Tap Copy 100 times fast on mac1, alternating with Send…: one share sheet at a time, the line always matches the
   last finished action, the pasteboard always holds exactly the command.
4. Double-tap every navigation button (two taps inside 80 ms): one push, never two of the same screen.
5. Tap Check Again 30 times as fast as possible while the fixture answers in 800 ms: at most one read in flight
   (the ledger's authed count rises by the number of completed checks, not taps), the screen ends in a steady state.
6. Time from the login's answer to the app's first frame with a 5 ms status: the added delay of the check is reported
   (median of 10) and must stay under 150 ms on the loaded Mac.

**Bad network**
7. Status `slow` 3.9 s, 4.1 s, 10 s, 60 s: in at 3.9 s after the answer, at 4.0–4.6 s for the others, never an Update
   screen from a late answer arriving after the app showed.
8. Status `drop`, `500`, `garbage`, a 2 MB JSON body, a body that is `[]`, `null`, `"text"`: straight in, no crash.
9. Fixture stopped between the login and the status read: straight in; the app then shows its own reconnecting state.
10. Fixture stopped while the Update screen is up, then Check Again: enters (D11), and the app reconnects when the
    fixture returns. Then the reverse: the fixture comes back outdated → next typed sign-in shows the screen again.
11. Airplane-like: the simulator's network cut by stopping every fixture, then Get Tailscale, the docs links and
    Send…: the guide stays responsive, a link that cannot load shows Safari's own error inside the Safari sheet, the
    guide never hangs.

**Bad data**
12. `release_date` values: `2026.9.20`, `2026.09.20`, `2026.9.21`, `2026.9.022`, `2026.0.5`, `2026.13.1`, `2026.9.32`,
    `9999.12.31`, `0001.1.1`, `٢٠٢٦.٩.٢٠` (Arabic-Indic digits), `2026.9.20\n`, `2026-9-20`, `20260920`, `""`, `null`,
    a number, an object, 10 000 characters. Outdated only for the well-formed dates before 2026.9.21; no crash.
13. `version`: missing, `""`, 500 characters, emoji, a newline, right-to-left text, a number. The card shows at most
    24 characters on one or two lines and never overflows.
14. Name field: 60 emoji, 60 combining-mark clusters, a pasted 10 000-character string, right-to-left text, only
    spaces, a newline pasted in, `"; DROP TABLE`, a name equal to another saved gateway's. Stored trimmed and capped,
    shown without breaking the title switcher, Settings › Gateway or the Update card.
15. Address pasted from the agent's reply with surrounding text (`Here it is: https://x.ts.net.`), with a trailing
    slash, in capitals, with a zero-width space: the form's existing validation answers; nothing crashes; the help
    link still works after an error.
16. A `hermes://connect` link with a bad inner URL (http, with a query, 400 characters) while the guide is up: ignored,
    the guide stays where it was. A good link 20 times in a row: the form shows once, the address is the last link's.

**Interruption**
17. Background the app on every screen for 30 s and return: same screen, same scroll position, disclosure state and
    status line kept.
18. Background during `Signing In…` and during `Checking…`; return after 1 s and after 40 s: the attempt finishes or
    fails with its normal message; the form is never left busy forever; Back works again.
19. A phone call banner / Control Center pull / notification banner over the share sheet and over the alert of R16.
20. Rotate (if the build allows), split the keyboard on and off, connect a hardware keyboard: Return in Name signs
    in, Escape does nothing harmful, Command-[ goes back.
21. A connect link, a tapped notification and a Home Screen quick action arriving while the welcome, the guide, the
    Update screen and the R16 alert are up: no crash, no second root, the link's address reaches the form when the
    flow is the root, and is kept for after sign-in on the Update screen.
22. Add Gateway sheet: open help, go three screens deep, swipe the sheet down (allowed when not busy) and reopen;
    start a sign-in and try to swipe (refused); reach the Update screen in the sheet and try to swipe (refused).

**Relaunch**
23. Kill on every guide screen and relaunch: a first-run phone is back on the welcome (the web also starts over), a
    returning one on the form. Nothing typed in the password field survives.
24. Kill during `Signing In…`: relaunch is either signed in (the save landed) or on the form; never a half state.
25. Kill on the Update screen: relaunch goes straight in. Kill during `Checking…`: the same.
26. R16: kill with the alert up; kill between the discard and the form: relaunch shows the form (item gone), never
    the problem screen with a half-deleted item, never the welcome if the phone had signed in before.
27. Upgrade path: install the train build without this stream, sign in, install this build over it: the app opens
    signed in, the flag is set, Sign Out then shows the form (not the welcome).
28. Corrupt the item (hook) 10 times in a row with a start-over each time: every round ends signed in; drafts of the
    account survive every round.

**Accessibility sizes and modes**
29. All seven accessibility text sizes on every screen, light and dark, Increase Contrast, Bold Text, Reduce
    Transparency (glass buttons stay legible), Reduce Motion (pushes cross-fade, nothing breaks): no clipped text, no
    overlapping buttons, every button reachable, wrapping rows keep their padding. Smallest size too.
30. VoiceOver walk of every screen: the heading is first, steps read with their numbers, key caps as words, the
    status line announced once per change, the disclosure announces expanded/collapsed, the Update card reads as
    "name, Hermes 0.21.4, released 2026.9.10".
31. Voice Control ("Tap Get Started", "Tap Copy"), Switch Control order, Full Keyboard Access (Tab reaches every
    control; Space activates).
32. Smallest supported phone width (iPhone SE-class simulator if the runtime has one) and the largest: the two card
    buttons do not truncate ("Send to Your Mac…" is the longest); they stack when they do not fit.

**Words**
33. A scan of the built app's strings and of every screenshot's recognised text for "Dispatch" (must be none
    user-visible) and, on welcome and guide screens, "gateway" (none).

**After the merge (new items)**
34. Launch hand-over: sign in on a fixture whose first list takes 0 s, 2 s, 13 s (past the launch screen's 12 s) and
    never: the app, the launch caption, "Still connecting…" with Try Again, and the offline screen respectively; at
    no point the welcome, a second form, or a blank window. Same four from Continue Anyway on the Update screen.
35. Kill the app on the launch screen that follows a typed sign-in (before the first list): the next launch is
    signed in (the account was saved before the wait began).
36. Storage check failing after a typed sign-in (`-HQDebugStorageFailure YES`): the launch screen's "couldn't start"
    words show, not the Update screen and not the app; from the Update screen's Continue Anyway the same.
37. Offline screen → Sign In to a Different Hermes → sheet → help link → walk the whole guide and back 20 times,
    then sign in: one sheet, Cancel always the sheet's, the offline screen's retry countdown keeps running underneath
    and a connection that opens meanwhile closes the sheet (its §3.7) without a crash while a guide page is on top.
38. Unreadable item, Sign In Again, then background the app on the confirm alert, on the sheet, and mid sign-in;
    return each time: the alert or sheet is still there, nothing was discarded by the return's forced Keychain read,
    never two alerts stacked.
39. A connect link (`hermes://connect?url=…` in the shipped identity, `hermeshq-native://…` in the native one) arriving on the launch screen after a typed sign-in, on the offline
    screen, and on the offline screen's sheet: lands in Add Gateway after the app shows, in the form, and in the
    sheet's form respectively; never a second sheet, never a rebuilt root under the launch screen.
40. The train's scans: `A11yLintTests` and `scripts/check-ipad.py` clean with this stream's files in the tree;
    Reduce Motion on: the disclosure, the status lines and the Update screen's phase change do not move (cross-fade
    or cut), checked by eye in a screen recording.
41. iPad: every screen in both orientations, in a 320-point-wide Stage Manager window and in Slide Over; the share
    sheet and the Safari sheet from each; rotate with the troubleshooting list open and with the keyboard up on the
    form; the Update screen inside the Add Gateway sheet (a form sheet on iPad, not full height).
42. Increase Contrast and Bold Text through `HQAccessibility` overrides the a11y stream's UI tests use
    (`-HQA11yContrast`, `-HQA11yBoldText`, `-HQA11yReduceMotion`, `-HQA11yReduceTransparency`; see `App/Kit/Accessibility/`): step numbers, key caps, glass buttons and the status lines stay legible; the themed colours
    (`HQPalette`, Desktop Look skins) apply to the welcome and guide as they do to the form.
43. The whole train's sign-in users after the merge: `scripts/e2e.sh`, `e2e-settings.sh`, `e2e-offline.sh`,
    `e2e-a11y.sh` and `e2e-ipad.sh` each run once on the tester's simulator and ports; any test that fails only with
    this stream merged is this stream's bug until shown otherwise.

## 11. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | A `signedInBefore` flag stands in for the web's "gateway last signed out of" when choosing welcome or form | native does not prefill after Sign Out; a returning phone must still open on the form |
| D2 | DEBUG builds start a clean run on the form (welcome one Back away) unless `-HQDebugWelcome YES` | keeps every existing and parallel UI suite working; Release is unaffected and separately checked |
| D3 | System Back control instead of the web's "‹ Back" text | native bar |
| D4 | Eyebrow → small bar title; heading stays in the content | whole-sentence headings would truncate in the bar |
| D5 | Key caps as inline tinted text, read by VoiceOver as words | SwiftUI text cannot border a run |
| D6 | The App Store link opens the App Store app | better than a store page inside a Safari sheet |
| D7 | The typed address survives a trip to the guide | asking for help should not cost the address |
| D8 | Copy and Send are always shown | iOS always has a pasteboard and a share sheet |
| D9 | The form's heading stays "Hermes HQ" (superseded by D36, §16) | that row is already ✅ and not this stream's |
| D10 | The version check runs before the app shows, capped at 4 s | web behaviour; avoids the app flashing under a full screen |
| D11 | Check Again with an unknown answer enters the app | web behaviour (fails open) |
| D12 | In the Add Gateway sheet the Update screen sits over an app already switched | the previous client has already ended at sign-in success |
| D13 | No drafts are moved on an unreadable Keychain | native drafts are already filed per account |
| D14 | Guide screens are not restored after a kill | the web starts over too; nothing is lost but the place |
| D15 | R11's lazy loading is web-shell-only; "no wait" is measured instead | a native binary has no chunks |

### Decisions made while building (13 October)

* **D16:** `SignInDriving` grew additively: `signInWithPassword(…label:)`, `signInWithNous(address:label:)` and
  `compatibility()` have default implementations, and `SignInModel` keeps an `init(driver:address:onSignedIn:)`, so
  the other streams' drivers and tests compile unchanged.
* **D17:** `GuideActions` is one struct of four closures (copy, share, open, announce) rather than three protocols:
  tests pass their own closures, the app passes `GuideActions.live`.
* **D7a:** the flow keeps one form and one `SignInModel` for its whole life. Popped off for the guide, the form keeps
  the address, username and Name; the password is cleared (`leftForGuide()`).
* **D18:** the welcome keeps its (empty) navigation bar instead of hiding it, so the push to the next screen has no bar
  jump. In sheet mode every pushed guide page has the sheet's Cancel on the trailing side.
* **D19:** a locked screen pushed on the sheet's stack (the Update screen) hides the whole navigation bar: a hosting
  controller on a stack brought its Back button back when only the item said hidden.
* **D20:** the share sheet's popover is anchored to the presenting view, not the button (SwiftUI buttons have no
  stable UIKit anchor); it matters on iPad only.
* **D21:** the Update card names the gateway by the Name typed on this phone, else its computer's name, else "Your
  Gateway" (an IP address or localhost is never shown as a name).
* **D22:** the Name field holds its own text and hands the model the capped text: a binding that shortens what was
  just typed left the extra characters on show.


* **D23 (after review):** a connect link that changes the address in the form clears a typed password (the same
  address, however it is written, keeps it). The web keeps the password; native does not, so a link from another app
  can never point a typed password at another host. The username and Name stay.
* **D24 (after review):** a locked screen (the Update screen in the Add Gateway sheet) and a busy form turn off both
  swipes back: the edge swipe and iOS 26's swipe from anywhere in the content. The end of a sign-in never turns them
  back on under a locked screen. A connect link that arrives under the locked screen is dropped (the form is hidden
  and already signed in); nothing is rewritten unseen.
* **D25 (after review):** a connect link while the Add Gateway sheet is under its own share sheet or browser goes
  into that sheet's form (what was over it is closed); no second sheet. A second tap on a guide link while the
  browser is up or rising is not an error.

## 12. Other streams

**After the merge:** `offline`, `ipad` and `a11y` are on the train and merged here; §12.1 and §12.2 below are the
plan as written before that, kept for the record. What actually happened and what is left is §14.

### 12.1 `offline` (owns L107–L110 and §26; its spec: `m9-offline/docs/spec/3x-offline.md` §3.5)

The `offline` stream replaces `LaunchViewController.showProblem` with a full offline screen that already plans a
**Sign In Again** button and the same alert for `keychain-unreadable`. Row L103 is this stream's, so:

* This stream ships `SignInService.discardUnreadableSignIn()` and `UnreadableSignIn.confirm` as the single
  implementation of the confirm and the discard, wired to whichever screen the train has.
* If `offline` is on the train first, the builder wires its offline screen's Sign In Again button to
  `UnreadableSignIn.confirm` (or, if `offline` already built an equivalent, keeps one and deletes the other), and R16's
  acceptance checks run against that screen. The address prefill then comes from its `LastGatewayHint`.
* If this stream lands first, the button lives on today's launch problem view, and `offline` moves the call when it
  rebuilds that screen. Never two alerts, never two discards.
* Both streams edit `SceneDelegate`. This stream's edits are confined to `showSignIn`, the `.unavailable` branch of
  `restore()`, `open(_:)`'s connect branch and the removal of `checkCompatibility`; everything else goes in new files.
* `offline` lists a `gateway-outdated` offline reason ("…Hermes HQ keeps trying."). That is the launch-time refusal by
  a Hermes with no sign-in endpoints, a different situation from R15's screen, which follows a successful sign-in.

### 12.2 Others

* `ipad`: the device word (`OnboardingCopy.device`) and the share sheet's popover anchor are ready for it; layouts are
  width-capped at 440 pt and centred.
* `a11y`: this stream's screens carry identifiers, header traits, announcements and the VoiceOver key names; the
  whole-app pass should need no changes here.
* `settings`: Add Gateway… and "sign back in" are entered through `AddGatewayFlow.present`, whose signature does not
  change.
* `share`, `intents`: a sign-in ending on the Update screen has already saved the account, so the share sheet and
  shortcuts see it at once; nothing to do.

## 13. Risks and open points

1. **D2 is a test convenience with a real cost**: a developer running a DEBUG build never sees the welcome first
   unless they pass the argument. The Release check in the stress plan (item 1) is the guard; it must not be skipped.
2. **`SceneDelegate` is shared ground** with `offline` and `ipad`; merges there need a careful read, not a blind
   resolve.
3. **The check before entering** changes the moment the success haptic plays and adds a wait. If the stress tester's
   item 6 shows more than 150 ms on a healthy fixture, the read should start in parallel with the Keychain save
   rather than after it, never be dropped.
4. **The public repository path** in the command (`mrcharlesiv/hermes-hq`) is the owner's and must stay in step with
   it (`MEM:onboarding-clarity.md`: "The repo is now named `mrcharlesiv/hermes-hq`."). The app only prints it.
5. **The App Store link and Safari sheet cannot be fully exercised on a simulator**; the tests check what the app
   asks iOS to open. One tap of Get Tailscale on a real phone is worth doing at the TestFlight stage.
6. **The QR step in the `native` identity** names a link no tool prints for that scheme; only the `original` identity
   ships, where it works.
7. **Name field and Return**: adding a field after Password changes which field shows "Go". Existing UI suites type
   the password and tap the button, so they are unaffected; the builder confirms with one run of `scripts/e2e.sh`.
8. **Real unreadable Keychain items are rare** and cannot be produced on a phone on purpose; R16 rests on the
   simulator hook and the vault unit tests.

## 14. After the train merge (revision of 13 October)

### 14.1 What was done in this revision

* The worktree held uncommitted review fixes (D23–D25 and their tests, last touched about 07:24). They were committed
  as found (`m9 onboarding: review fixes left uncommitted…`) so the train could be merged. Nobody had rebuilt or
  rerun them at that commit.
* `m9/train` (`c5a3508`) was merged into `m9/onboarding`. Five files conflicted. How each was settled:

  | File | Settled as |
  |---|---|
  | `App/Root/LaunchViewController.swift` | deleted, as on the train (`offline` rebuilt it in `App/Offline/`). This stream's `showProblem(secondary:)` went with it |
  | `App/AppDelegate.swift` | the train's `restore()` (`launch.unavailable(failure)` for every Keychain failure); the train's `showApp` with this stream's two lines (`OnboardingGate.signedInBefore = true`, flow released); `showSignIn` builds this stream's `OnboardingFlow` after the train's `launch?.signInShown()`, and its outcome goes `.enter` → `launch.signedIn(account, typed: true)`, `.update` → `showUpdate`; the Update screen's way in is `launch.signedIn(account, typed: true)`; `signInAgain()`, `startOverPending` and the train's `checkCompatibility` alert are gone |
  | `App/SignIn/SignInDriving.swift` | `SignInCopy.device` is the train's `DeviceWord.name` |
  | `App/SignIn/SignInView.swift` | both sides: this stream's `nameText` and the `a11y` stream's two `@AccessibilityFocusState`s |
  | `HermesKit/Net/GatewayFailure.swift` | the train's `DeviceWord` sentences, this stream's longer `nous-unavailable` sentence (the web's) |

* Two things the train needed that this stream had removed were put back so it compiles:
  `SheetSignInDriver.onBusy` (the offline screen's sheet locks itself with it) and
  `GatewayCompatibilityCheck.run(_:services:)` (called by `LaunchCoordinator.differentGateway`), now showing the
  Update screen full-screen over the app instead of the old alert. Both are stop-gaps for I1.

**Seen in this revision** (simulator `HQN-m9-onboarding`, `603C17FA-…`): `scripts/build.sh build` exit 0 for the
native identity and for `HQ_IDENTITY=original`; `scripts/build.sh build-for-testing` exit 0 (unit and UI test
targets compile). First unit run on the merged tree: two failures, both source scans the train added
(`A11yLintTests.noUnguardedAnimations`, `ThemeLintTests.noRawFontCallsOutsideTheThemeFolder`), both caused by this
stream's files, both fixed here (I5, I6) and seen passing. The final unit result is recorded in
`docs/briefs/m9/onboarding-rows.md` (header). **Not seen:** any UI test, any screen, either identity running. Nothing in §5's "done" claims has been
re-proved on the merged tree; `docs/briefs/m9/onboarding-rows.md` says so row by row.

### 14.2 Decisions made in this revision

* **DECISION D26: enter through the launch coordinator.** After a typed sign-in the root form and the Update screen
  hand the account to `LaunchCoordinator.signedIn(_:typed:)`; they never call `showApp` themselves. That keeps the
  train's storage check and "launch screen until a first list has content" (rows L107, L108) true for a first
  sign-in, which is exactly when there is nothing saved to show. Cost: the moment between Sign In and the app can now
  be the launch screen for a few seconds on a slow gateway; that is the web's behaviour too
  (`W:src/launch-screen.ts`).
* **DECISION D27: one Sign In Again, the train's.** §12.1 said "keeps one and deletes the other". The `offline`
  screen, alert and sheet are merged, reviewed and stress tested on the train (`docs/briefs/m9/offline-report.md`, its review table), and the alert's words equal this stream's character for character, so the train's stays and this
  stream's `UnreadableSignIn.confirm/startOver`, `OnboardingCopy.Unreadable` and the launch-problem wiring go (I3).
  The form appears in a sheet over the offline screen rather than as the root (the web makes it the root): Cancel
  then returns to a screen that keeps retrying, which is the web's "Cancel returns to retrying"
  (parity L939), and no explicit discard is needed because a successful sign-in saves over the unreadable item.
  `SignInService.discardUnreadableSignIn()` therefore has no caller left; I3 removes it with its tests unless the
  builder finds the save does **not** replace a really undecodable item, in which case it is called from
  `LaunchCoordinator` on confirm, before the sheet (one line), and its tests stay.
* **DECISION D28: one check, before the app, everywhere.** Three places sign in by typing (root form, Add Gateway
  sheet, offline screen's sheet). All three use `OnboardingFlow` and its `SignInOutcome`; no place reads the status
  again after the app shows. `GatewayCompatibilityCheck` and `SheetSignInDriver.onBusy` are deleted by I1.
* **DECISION D29: the offline sheet gets the guide.** The form's error sentences say "tap Need help connecting?
  below" (`SignInCopy`, the web's words). In the offline screen's sheet the link is not there today (a plain
  `SignInScreen.make` has no guide to open), so the sentence points at nothing. Using `OnboardingFlow` in sheet mode
  there (I1) puts the link under the form as everywhere else. Never a sentence that names a control that is not on
  screen.
* **DECISION D30: `-HQDebugCorruptSignIn` stays** beside the train's `-HQDebugRestoreFailure keychain-unreadable`.
  The train's hook fakes the read's answer; this one really damages the item, which is the only way to see the sheet's
  sign-in save over it and the next launch come up clean (§5.16 acceptance 4 and 6).
* **DECISION D31: rows are not reset to "todo".** This stream was built and reviewed before the revision; its rows
  file keeps each outcome, and the revision downgrades to `partial` exactly the rows whose proof the merge
  invalidated (L101, L103), with the reason. Every other row is marked "proof predates the merge": the builder's
  first job is the full rerun of §9 on the merged tree.

### 14.3 Still to build (in this order)

**I1. `DifferentGatewayFlow` on `OnboardingFlow`** (`NAT:App/Offline/OfflineViewController.swift:60-95`, an
`offline` file: edit it with an `[onboarding]` mark). `present` builds
`OnboardingFlow(mode: .sheet(title: "Sign In", cancelIdentifier: "offline.sign-in.cancel"), driver:, address:, username:)`
exactly as `AddGatewayFlow.present` does, keeps `nav.view.accessibilityIdentifier = "offline.sign-in"` (the train's
UI tests find the sheet by it), and on the outcome: `.enter` → dismiss, then `onSignedIn(account)`; `.update(info)` →
`driver.flow?.push(locked: UpdateHermesScreen.make(…))` whose way in dismisses and then calls `onSignedIn(account)`.
`LaunchCoordinator.differentGateway` then passes no `then:` closure. Delete `GatewayCompatibilityCheck` and
`SheetSignInDriver.onBusy` (the flow holds the sheet closed while busy, D24). The coordinator's §3.7 rule ("a
connection that opens while the form is up dismisses the form") must still work with a guide page or the locked
Update screen on top: it skips a sheet whose `isModalInPresentation` is true, so the locked screen stays; a guide
page is dismissed with the sheet. Wire: unchanged (`POST /api/auth/login`, one authed `GET /api/status`).

**I2. One status read.** With I1 done, assert it (§5.14 "After the merge"): `status_reads.authed == 1` per sign-in
in O11, O12 and O19.

**I3. Remove this stream's unreadable-sign-in copy** (D27): `App/SignIn/UnreadableSignIn.swift`,
`OnboardingCopy.Unreadable`, `UnreadableSignInTests`' alert-side cases, the `[onboarding]` paragraph about
`LaunchViewController` in `App/Debug/DebugHooks.swift`; keep the `-HQDebugCorruptSignIn` hook (D30). Rewrite
`testO14_UnreadableSignIn` against the offline screen (§5.16 acceptance on the train).

**I4. Device word.** `OnboardingCopy.device` becomes `DeviceWord.name` (delete the `sysctlbyname` reader);
`python3 scripts/check-ipad.py` must print no finding (today: `(h) App/Onboarding/OnboardingCopy.swift:22: a string
says "iPhone"`). `OnboardingCopyTests` compare against the web's strings with `DeviceWord.name` substituted.

**I5. Reduce Motion: done in this revision, to be looked at.** The train's `A11yLintTests.noUnguardedAnimations`
has teeth (the soft marker is gone) and failed on five calls in this stream's files. They now go through the train's
helper as the form does (`NAT:App/SignIn/SignInView.swift:282-284`):

| Line | Now |
|---|---|
| `App/Onboarding/ManualSetupView.swift:27`, `OnboardingKit.swift:167`, `:319`, `UpdateHermesView.swift:155` (status lines, the Update screen's phase) | `.animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: …)`: a 0.2 s cross-fade under Reduce Motion |
| `App/Onboarding/OnboardingKit.swift:277` (the troubleshooting and "Show the message" disclosures) | `HQMotion.withAnimation(.smooth(duration: 0.25)) { open.toggle() }`: opens at once under Reduce Motion (it resizes) |

The scan passes. Nobody has watched these with Reduce Motion on; the builder does (stress 40), and checks that the
disclosure's chevron and content do not slide.

**I6. Fonts: done in this revision, to be looked at.** `ThemeLintTests.noRawFontCallsOutsideTheThemeFolder` failed
on seven files (`SignInView`, `ManualSetupView`, `QuickSetupViews`, `OnboardingKit`, `WelcomeView`,
`UpdateHermesView`, `WindowsViews`: 30 raw text-style calls). The train's own tool was run as its header says to
after a merge (`python3 scripts/desktoplook-migrate.py`; it rewrote exactly those seven: `.font(.body)` →
`.font(Font.hq(.body))` and so on). With the Desktop Look off each returns the font it replaced
(`App/Theme/ThemeFonts.swift`), so the standard look is unchanged; with a skin on, the welcome, guide and Update
screen now take its typeface like the rest of the app. The scan passes. To look at: one screenshot of the welcome
and of Mac step 2 with a Desktop Look skin on (the launch arguments in `App/Debug/ThemeDebugHooks.swift`), and the largest-type
walk (`testO16`) again, since the font source changed under every screen. The scan for fixed sizes and direct
`UIAccessibility.is…` reads found nothing in this stream's files; the one `.font(.system…)` is
`.system(.footnote, design: .monospaced)` (`OnboardingKit.swift:237`), a text style.

**I7. iPad.** The train now ships `TARGETED_DEVICE_FAMILY "1,2"`. Every screen: content column capped at 440 pt and
centred (§3.4 already), the share sheet anchored (D20; `check-ipad.py` rule (d) passes today), the Add Gateway and
offline sheets are form sheets on iPad so the locked Update screen and guide pages must lay out at about 540 pt
wide and scroll. The root flow under the two-pane root is not a concern: the flow is the window root only while
signed out.

**I8. Rerun and re-prove everything.** `scripts/build.sh test <SIM>` (all suites, both identities),
`scripts/e2e-onboarding.sh <SIM>` light then dark, then the train's sign-in users on this stream's ports:
`HQN_E2E_PORT=9992 scripts/e2e.sh`, `scripts/e2e-settings.sh`, `scripts/e2e-offline.sh`, `scripts/e2e-a11y.sh`
(read each script's header for its port variable; stay inside 9990–9994). Then update
`docs/briefs/m9/onboarding-rows.md` and `-report.md` from what was seen, screenshots looked at again (the form, the
launch hand-over, the offline screen for the unreadable item and its sheet, the Update screen in all three places).

### 14.4 Stand-ins for the new checks

* The offline screen and its sheet need no gateway to appear:
  `xcrun simctl launch <SIM> <bundle id> -HQDebugRestoreFailure keychain-unavailable` (or `keychain-unreadable`,
  or `-HQDebugCorruptSignIn YES` after a real sign-in). To sign in from the sheet:
  `python3 scripts/fixtures/onboarding-gateway.py --port 9990 --credentials build/fixtures/onboarding-a.json`
  and, for the outdated path,
  `python3 scripts/fixtures/onboarding-gateway.py --port 9991 --label Beta --credentials build/fixtures/onboarding-b.json --release-date 2026.9.10`.
* The launch hand-over (stress 34) needs a first list that can be held back. `onboarding-gateway.py` gains one
  control, in the fixture's own style: `POST /__onboarding/lists {"delay_ms": n}` (n = -1: never answer) delays the
  socket's first `session.list`/roster reply; reset by `/__onboarding/reset`. No other fixture is edited.
* Stress tester: the same commands on 9995 and 9996 (`HQN_ONBOARDING_PORTS="9995 9996 9997 9998"`), simulator
  `HQN-m9-onboarding-s`; for stress 41 its own iPad simulator
  (`xcrun simctl create "HQN-m9-onboarding-s-pad" "iPad Pro 13-inch (M5)" com.apple.CoreSimulator.SimRuntime.iOS-27-0`;
  check `xcrun simctl list devicetypes` for the exact iPad name), shut down and deleted by the tester at the end.

### 14.5 Risks added by the merge

1. **Two streams' state machines meet in `SceneDelegate`.** `LaunchCoordinator.stage` is `.signIn` from
   `signInShown()` until `signedIn(...)`; the Update screen as root sits inside that span. A restore triggered there
   (sign-out from elsewhere cannot happen, but `protectedDataDidBecomeAvailable` and `appBecameActive` can fire) must
   not replace the Update screen. The coordinator's handlers act only in `.offline`, so this should hold; stress 38
   checks it.
2. **`showApp` runs for every hand-over**, restores included, so `OnboardingGate.signedInBefore` is written on every
   launch (a `UserDefaults` set of the same value: cheap, but keep it out of the first-frame path if a launch
   measurement moves).
3. **The stop-gap `GatewayCompatibilityCheck`** presents over `MainTabController.current`; on iPad the root is the
   two-pane controller. I1 removes the question; until then it is unproved on iPad.
4. **`python3 scripts/check-ipad.py` still fails** on this branch (one finding, I4). It is a train gate.
5. **`testO14` fails on the merged tree as written** (it looks for the old launch problem screen). That is a known,
   stated failure until I3, not a flake to rerun away.


## 15. Builder's pass after the merge (13 October)

What §14.3 asked for, as built. Results are in `docs/briefs/m9/onboarding-report.md`.

* **I1 done.** `DifferentGatewayFlow.present` (`App/Offline/OfflineViewController.swift`, marked `[onboarding]`) builds
  `OnboardingFlow` in sheet mode. `GatewayCompatibilityCheck` and `SheetSignInDriver.onBusy` are deleted.
  `LaunchCoordinator.differentGateway` passes no `then:` closure.
* **DECISION D32: the offline screen stands down under the locked Update screen.** When the sheet's sign-in ends on
  "Update Hermes", the sign-in is already saved, so the offline screen underneath would find it on its
  next retry and put the app up under the locked sheet. `present` gained `onLocked`, and the coordinator answers it
  with `signInShown()` (retries and Keychain reads stop; only while it is still `.offline`). Continue Anyway then
  dismisses the sheet and enters through `signedIn(_:typed:adopting:)`. If a retry did win the race during the busy
  moment before the outcome, the coordinator is already in `.app` on that account and the second hand-over is skipped.
* **I2, as far as the wire can show it.** "One authed status read" is asserted where only the version check can have
  read it: on the Update screen before the app shows (O11, O19, O20). After the app shows, Settings reads the same
  endpoint once per run for its version line (`App/Settings/AppModel+Settings.swift`), so a count taken later is 2 and
  proves nothing about the check. That the form reads once is also `SignInModelCompatTests`.
* **I3 done.** `App/SignIn/UnreadableSignIn.swift`, `OnboardingCopy.Unreadable` and
  `SignInService.discardUnreadableSignIn()` are gone (a sign-in's save replaces an unreadable item:
  `Keychain.editable()`, and `UnreadableSignInTests.aSignInSavesOverAnUnreadableItem`). `-HQDebugCorruptSignIn` stays.
* **I4 done.** `OnboardingCopy.device` is `DeviceWord.name`; `python3 scripts/check-ipad.py` prints `check-ipad: ok`.
* **DECISION D33: a connect link while the offline screen's sheet is up goes into that sheet's form**
  (`App/AppDelegate.swift`, marked). Before, it rebuilt the root as a sign-in form under the sheet. On the sheet's
  locked Update screen the link waits and opens Add Gateway once the app shows. With the offline screen alone (no
  sheet) the train's behaviour is unchanged: the root becomes the form with the address.
* **Fixture.** `POST /__onboarding/lists {"delay_ms": n}` holds back every signed-in read but the status (the lists
  and the socket), not only the first list: simpler, and the launch screen is what it is for.
* **Tests added:** O19 (offline sheet: guide, twenty trips, link into the sheet, locked Update screen), O20 (enters
  through the launch screen; killed on it), O21 (iPad), O22 (storage failure after a typed sign-in), O23 (Reduce
  Motion, Increase Contrast, Bold Text; a Desktop Look skin). O14 rewritten against the offline screen. O15's last
  part used an `http://127.0.0.1` connect link, which the app refuses by design (links are https only); it now uses an
  invented https host and signs in to nothing.

## 16. After review (13 October, finishing pass)

The reviewer's findings and what was done about each. Results are in `docs/briefs/m9/onboarding-report.md`.

* **DECISION D34: the offline screen stands down when the sheet's sign-in is saved, not when the Update screen
  locks (replaces D32's timing).** `SignInService` saves the new sign-in first; the form then stays busy for the
  version read (up to 4 s). In that window the offline screen's own Keychain timer, or a return to the app, could read
  the new sign-in and put the app up under the busy sheet, so an older gateway never showed "Update Hermes on Your
  Gateway". `SheetSignInDriver` gained `onSaved`, called right after the password or Nous sign-in returns;
  `DifferentGatewayFlow.present(…onSaved:…)` hands it the coordinator's stand-down (`signInShown()`, only while the
  stage is still `.offline`). The `.update` branch no longer stands down itself. The Add Gateway sheet sets no
  `onSaved` (the app underneath is live there). Proof: `testO25_SlowVersionReadInOfflineSheet` (a real unreadable
  item, the status held 3.5 s, the app sent away and brought back inside the busy window). The same test was run once
  against the old timing and failed with "the app showed before the Update screen", so it does reach the window.
  `testO24_OfflineStandsDownUnderUpdate` holds the locked screen for 35 s and two returns with the new sign-in
  readable underneath (D32's claim, which O19 could not prove: its debug Keychain failure never clears).
* **DECISION D35: reading a gateway's version never makes or ends a client.**
  `SignInService.compatibility(for:)` asks the active client only when it is that account's and alive; otherwise the
  answer is `.unknown`, which enters (D11). Before, Check Again under a locked Add Gateway sheet could end another
  gateway's live client if the app underneath had moved on. Unit test
  `aVersionReadForAnotherAccountLeavesTheActiveClientAlone`.
* **DECISION D36: the form inside this flow carries the web's heading and first lead (supersedes D9).** "Sign in to
  Hermes." (`W:src/connection-onboarding.ts:97`), "Add another Hermes." (UX study #24; the web's "Add a gateway.") in the Add Gateway sheet when adding one
  (`W:src/main.ts:206`), and, until the address has been asked about, "Enter the address of your Hermes, then sign
  in." (`:98`). Once the address is asked about the per-way subtitles show, as the web's `applySignInWays` does. The
  owner's note `onboarding-clarity.md` records the same heading. A sheet that signs a saved gateway back in, and the
  offline screen's sheet, say "Sign in to Hermes." (the web has one form for both). A form not hosted by the flow (none
  in the app today) would still say the app's name.
* **The capped version read is cancelled when the cap wins** (`CompatibilityCap.run`), so no read runs on beside the
  next Check Again. Unit test in `theCapAnswersUnknownAndDropsALateAnswer`.
* **`SignInService.lastRestoreFailure` is deleted** (nothing read it).
* **An iPad's share popover points at the Send… button that was tapped.** `GuideActions.share` takes the button's
  frame in window coordinates (`CommandCard` records it with `onGeometryChange`); with no frame it falls back to the
  old fixed point.
* **Tests.** `dismissSavePassword` waits for the system sheet to settle before tapping "Not Now" and for it to go
  afterwards. On this loaded Mac the sheet arrives 5 s and more after the sign-in, so O11 waits up to 15 s for it
  before its first screenshot and tap, and taps Check Again again if the sheet still took the tap (a tap that never
  landed reads nothing). O19's last check is a Beta-only element ("Beta Ivy"). New: O24, O25.


## 17. Spec writer's rerun (13 October, 14:55): where the stream stands and what is left

This run found the stream already built. Nothing was restarted. The train (`c5a3508`) is already merged into
`m9/onboarding`; there was nothing new to merge. All 17 rows keep their spec sections (R1–R17, §5.1–§5.17), which were
checked again against the web sources for this pass (`W:src/connection-onboarding.ts:61,69,97,98,105`,
`W:src/main.ts:206,336,395,400`, `W:src/connection-startup.ts:61`, `W:src/gateway-compat.ts:15,32-39`,
`NAT:HermesKit/Net/GatewayCompatibility.swift:29,66`). No wire call changed: still only `GET /api/status` (public for
the form's probe, authenticated once after a typed sign-in and once per Check Again) and the existing sign-in posts;
no JSON-RPC method, so nothing in `HA:tui_gateway/contracts` is touched and error 4000 cannot arise from this stream.

**DECISION D37: `docs/briefs/m9/onboarding-rows.md` is not reset to "todo".** The task text for a spec writer says to
create it with every outcome "todo". The file already holds 17 rows copied verbatim with outcomes and proofs from the
builders' passes (16 done, 1 web-shell-only). The run's own rule is that earlier work is kept and continued, so the
file stands as it is; resetting it would throw away recorded proof.

### 17.1 What was found uncommitted, and what was done with it

The finishing pass of §16 (D34, D35, D36, the cancelled capped read, `lastRestoreFailure` deleted, the iPad share
anchor, tests O24 and O25) was sitting in the worktree, last edited 14:08, with no process of this stream running and
both simulators shut down. It is committed as it was found, in its own commit, so the next stage starts from a clean
tree. What was seen for it, from the logs that pass left in `build/` (not rerun by the spec writer):

| Check | Result seen | Source |
|---|---|---|
| Onboarding UI suite, light, native identity, on the uncommitted tree | 24 passed, O21 skipped (iPad-only, phone simulator), `xcodebuild exit 0`, ended 14:50 | `build/full-e2e-onboarding.out` |
| Onboarding UI suite, dark | **did not run**: the test runner failed to launch ("Mach error -308, server died") 4 s in; no test executed | `build/last-e2e-onboarding-dark.log` |
| Unit suite on the uncommitted tree | **not known**: `build/last-test.log` (14:15) holds no pass or fail line | `build/last-test.log` |
| `project-original.yml` build on the uncommitted tree | **not rerun** after §16 | none |
| iPad walk (O21) on the uncommitted tree | **not rerun** after §16 (the share popover anchor changed) | none |

So §16's code compiles in the native identity and passes its light UI suite; the rest of the table is owed.

### 17.2 What the next stage must do, in order

1. `xcodegen generate` and build both identities (`scripts/build.sh` with this worktree's derived data; `HQ_IDENTITY=original`
   for the shipped one). Both must build.
2. Unit suite, native identity, on simulator `HQN-m9-onboarding` (`603C17FA-14F9-453A-A47B-B2754167C309`); it must
   include `aVersionReadForAnotherAccountLeavesTheActiveClientAlone` and `theCapAnswersUnknownAndDropsALateAnswer`.
3. `HQN_ONBOARDING_PASSES=dark scripts/e2e-onboarding.sh 603C17FA-14F9-453A-A47B-B2754167C309` (fixtures on 9990 and
   9991). A runner that dies at launch is the simulator, not the app: boot the simulator again and rerun before
   calling anything a failure.
4. O21 on `HQN-m9-onboarding-pad` (`5982AFE6-0691-45D4-B8DF-60B245FB8DE9`), and look at a screenshot of the share
   popover pointing at the Send… button (the §16 change; no test looks at where the arrow points).
5. Look at the form's new heading in the three places D36 names (first run: "Sign in to Hermes."; Add Gateway:
   "Add another Hermes."; offline sheet: "Sign in to Hermes.") at the default size and at the largest accessibility size.
   The heading is a large title and now wraps; it must not push Sign In off a small screen without scrolling to it.
6. Bring `docs/briefs/m9/onboarding-report.md` and `docs/briefs/m9/onboarding-rows.md` up to §16 (D34–D36, O24, O25,
   the results of steps 1–5). They still describe the pass before the review.
7. Stress tester: the STRESS PLAN of §10 on `HQN-m9-onboarding-s`, ports 9995–9999, plus §17.3.

### 17.3 STRESS PLAN additions for §16

These join §10; each is a way the finishing pass's changes could break.

* **S-A (D34, the window).** In the offline screen's sheet, sign in against a status held 0.5, 2, 3.5 and 3.9 s with
  an older `release_date`; inside each hold send the app to the Home Screen and back, lock and unlock, and pull
  Control Center. The app must never show before "Update Hermes". Repeat 20 times at 3.5 s.
  `POST /__onboarding/status {"mode":"slow","delay_ms":3500,"release_date":"2026.9.10"}` on port 9995.
* **S-B (D34, a failed sign-in).** Wrong password in the offline sheet, then a dropped connection at the login post:
  `onSaved` must not run, the offline screen keeps retrying underneath, and a later good sign-in still enters.
* **S-C (D35).** Two gateways (9995 and 9996 `--label Beta`). Lock the Add Gateway sheet on Update for Beta, leave the
  app 60 s, come back and tap Check Again ten times quickly: one read per tap at most, the first gateway's chat
  underneath keeps streaming, and nothing signs out. Then kill Beta's fixture and tap Check Again: the answer is
  unknown and the app enters (D11), with no crash and no spinner left on.
* **S-D (cancelled read).** Status held 10 s; tap Check Again, wait for the 4 s cap, tap again at once, five times.
  `GET /__onboarding/state` must show the reads ending (no pile of open requests), and memory must not climb.
* **S-E (D36, the heading).** Largest accessibility size, Bold Text on, iPhone SE-size simulator if one can be made
  under this stream's name, portrait and (iPad) every rotation: heading wraps, nothing is clipped, Sign In reachable.
  VoiceOver order: heading, lead, address.
* **S-F (share anchor).** iPad, both orientations and Split View at one third: Send… on each of the four command
  cards; rotate with the popover open; the popover stays on screen and the app does not crash when the button has
  scrolled off (the frame is stale then; the fallback point is the floor).
* **S-G (relaunch).** Kill the app inside the 3.5 s hold of S-A and relaunch: the saved sign-in enters through the
  launch screen with no Update screen (the web checks after a typed sign-in only, D10), and no second sign-in is asked.

### 17.4 How close this stream is

Seventeen rows: sixteen recorded done with proof on the merged tree, one (L85, lazy load and prefetch) proposed
web-shell-only with the "opens with no wait" behaviour measured. Nothing waits on the owner; there is no
`docs/owner-todo/onboarding.md` because nothing here needs the relay, a plugin or a real gateway. What stands between
this stream and a build is §17.2 steps 1–6 (about an hour of machine time on this loaded Mac) and the stress pass.
The gaps the report already admits still hold and cannot be closed on a simulator: the Camera scan of the QR code, Get
Tailscale really opening the App Store, a truly damaged Keychain item on a phone, and VoiceOver listened to by a person.

## 18. Already on Tailscale: a private address (18 October, native only)

A tester asked for a way to set up without putting the computer on the internet: their phone runs Tailscale all the
time (an exit node into the home network), and they had turned Funnel off by hand. The Windows and manual paths were
already tailnet-only, but the Mac and Linux one command always opened Funnel and the app offered no other way.

* **DECISION D38: one switch, "This iPhone already uses Tailscale", on the first screen of each path that gives the
  one command** (Let Hermes set it up, and step 1 of the Mac and Linux guides). On, the command becomes
  `connect.sh | sh -s -- --private` and the message for Hermes runs it with `--agent --private`. The words that say
  the phone doesn't need Tailscale give way to ones asking for the same Tailscale account and for Tailscale left
  connected on the phone. The choice lives on the flow (`SetupReach`), so it carries from one screen to the next, and
  it starts off each time the guide opens. Copy and Send hand over what the card shows (`GuideFeedback.text`).
* **The setup side** (hermes-ios `gateway-edge/`, published to github.com/mrcharlesiv/hermes-hq): `--private` runs the
  same steps (Nous sign-in, gatekeeper, QR code) but shares the address with `tailscale serve` instead of
  `tailscale funnel`. It's saved as `"reach": "private"` in the gatekeeper's config, so a plain re-run keeps it;
  `--public` switches back. `status` and `off` know both kinds. Nous sign-in is unchanged because it all happens in
  the phone's browser, which is on the tailnet; `hermes dashboard register` only records the address with Nous.
* This differs from the web's build 240 on purpose: the web guide has no such switch. The strings are in
  `OnboardingCopy.Tailnet` and `quick(_:tailnetOnly:)`; the web-parity tests still pin the default words.
* Proof: `GuideFeedbackTests.tailnetOnlyHandsOverThePrivateCommandAndMessage`, `TailscaleCopyTests.tailnetOnlyCopy`,
  UI tests O26 and O26b (the switch at the largest size), and the connect tests for `--private`.
