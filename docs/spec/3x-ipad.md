# 3x · iPad layout and hardware keyboard (stream `ipad`, run m9)

Worktree `/Users/me/Projects/hermes-hq-native-wt/m9-ipad`, branch `m9/ipad`. Builder ports 10110-10114, stress
tester ports 10115-10119. Written 2026-10-12 while the owner was asleep: every choice the reference did not settle is
marked **DECISION**.

Paths: `R/` = `/Users/me/Projects/hermes-hq-native-ref240` (read only). `MEM/` =
`/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory`.

## 0. The row

One parity row (docs/briefs/m9/assignment.md, section `ipad`; docs/parity-240.md §21, L834):

> | ❌ | iPad full width keeps the desktop two-pane layout (docked sidebar); a narrow iPad window gets the phone layout | `src/ui-kit/phone.ts` |

The planner's note (assignment.md L47): "ipad owns one row. Both streams' real work is the whole-app pass their scope
describes, not the row count." The scope: enable the iPad device family in BOTH project files, a native split layout,
Stage Manager resizing, pointer hover, keyboard shortcuts (Command-N, Command-F, Command-Up/Down between chats, Return
to send, Escape to stop or close a transient layer), and every screen on the train working in both layouts.

The row is done only when all of §10 was seen working on an iPad simulator AND the iPhone suites still pass.

## 1. What the web app does

1. **Layout by width, capability by device.** `R/src/ui-kit/phone.ts:1-10`: the phone layout is the media query
   `(max-width:767px),(pointer:coarse) and (max-height:500px)`; "a narrow iPad window matches it too". Everything wider
   (and taller than 500 px) gets the Hermes desktop renderer's layout. `R/src/renderer-mobile.css:146`:
   `@media(min-width:768px) and (min-height:501px) {.ios-phone-header,.ios-profile-picker {display:none}}` (the phone
   chrome goes away at exactly that point).
2. **The desktop two-pane layout.** The vendored desktop renderer docks its sessions sidebar beside the chat:
   `R/vendor/hermes/apps/desktop/src/store/layout.ts:32-33` (`SIDEBAR_DEFAULT_WIDTH = 237`, `SIDEBAR_MAX_WIDTH = 360`),
   `R/vendor/hermes/apps/desktop/src/hooks/use-mobile.ts:6` (`DOCKED_SIDEBAR_MIN_PX = 768`: narrower and the sidebar
   stops being a docked column), `R/vendor/hermes/apps/desktop/src/styles.css:559-560` (`--sidebar-width: 14.8125rem`,
   `--chat-min-width: 28rem` = 448 px for the chat beside it).
3. **The device idiom** is published by the shell as a class (`R/ios/App/App/HermesViewController.swift:967-971`,
   `ios-idiom-phone` / `ios-idiom-pad`) and read by `idiom()` (`R/src/ui-kit/phone.ts:11-15`). iPad-only differences
   that matter here: the iOS System skin is phone-only (`R/src/ui-kit/ios-theme.ts:14`), the ☰ commands button is
   phone-only (MEM/commands-button.md: "1:1 chats only; rooms have their own composer, iPad excluded"), the question
   dock is "Phone layout + coarse pointer only; iPad/desktop/group rooms keep upstream's card" (MEM/phone-question-dock.md).
4. **Hardware keyboard.** The shell reports a connected keyboard (`R/ios/App/App/HermesPicker.swift:73-82`,
   `GCKeyboard.coalesced != nil`) and the page keeps `ios-hardware-keyboard` (`R/src/bridge/fe-convo.ts:32-52`).
   `R/build/fe-convo-gates.ts:52-56` (FE-037): "The on-screen keyboard's Return starts a new line, as in Messages; Send
   is the button. A hardware keyboard's Enter (no on-screen keyboard) still sends, and ⌘Enter still queues."
   The desktop renderer's shortcuts (`R/vendor/hermes/apps/desktop/src/lib/keybinds/actions.ts`): `session.new` ⌘N
   (:121), `session.next` / `session.prev` Ctrl-Tab / Ctrl-Shift-Tab (:126-127), `session.focusSearch` ⌘⇧F (:129),
   `nav.settings` ⌘, (:149), `view.toggleSidebar` ⌘B (:158), `view.findInPage` ⌘F (:212), `composer.send` Enter,
   `composer.newline` Shift-Enter, `composer.queue` ⌘Enter, `composer.cancel` Escape (:316-325). Their English names
   (`R/vendor/hermes/apps/desktop/src/i18n/en.ts:748-853`): "New session", "Next session", "Previous session",
   "Search sessions", "Open settings", "Toggle sessions sidebar", "Find in page", "Send message", "Insert newline",
   "Queue message", "Close popover · cancel run".
5. **Escape** (`R/vendor/hermes/apps/desktop/src/app/chat/composer/hooks/use-composer-esc-cancel.ts:24-60`): stops the
   running turn only when no field has focus, no overlay is open ("Esc must close that overlay, never double as
   canceling the stream behind it") and the turn is not parked on a clarify / approval prompt.
6. **What the shipped web app actually was on iPad.** `R/ios/App/App.xcodeproj/project.pbxproj:775…946`:
   `TARGETED_DEVICE_FAMILY = 1` in every configuration. The web app in the App Store record is iPhone-only: on an iPad it
   ran in the iPhone compatibility window. The two-pane layout existed in the page (and was tested on iPad simulators
   through round 6, MEM/finish-everything-push.md) but no shipped build was a real iPad app. So this stream is the first
   time the record gets an iPad build (see §12, owner note).

## 2. What the owner said

- MEM/ios-native-ux-goal.md: "Prefer iOS conventions (full-screen lists, back buttons, large titles, long-press menus,
  no hover-only controls, no touch drags) over desktop behavior on phone; **keep iPad (≥768pt) on the desktop layout.**"
- MEM/desktop-look.md: "Offered A (colours+shapes+solid chrome), B (+follow the Mac's skin), C (+iPad two-pane); owner
  picked **A to start**." Two-pane on iPad was offered and never refused; it is this row.
- MEM/finish-everything-push.md, 2026-09-27: "the owner deprioritized the iPad ('we can make that a focus later')".
  It is now on the owner's remaining list (MEM/hermes-hq-native.md: "Remaining list … iPad +"; parity-240 top-10 names
  iPad).
- MEM/app-store-checklist.md: "iPad screenshots, or ship iPhone-only." (an App Store submission question, §12).
- MEM/hermes-hq-native.md: "It's already SO MUCH smoother." The iPhone feel is what must not regress.
- Product rules (run brief): native Liquid Glass only; tab roots use the inline large title, pushed pages the small
  title on the bar row (`PushedPageTitles`); never show a control that does nothing; Telegram is the benchmark.

## 3. Decisions

- **DECISION D1 (Telegram's iPad shape, not the desktop renderer's).** Two panes: on the left the same tab controller
  the iPhone shows (Bots, Sessions, Jobs, Kanban/Artifacts, More, with its glass tab bar at the bottom of the pane), on
  the right the chat (or whatever a list row opens). The desktop renderer's own sidebar (sessions tree, 237 px, hover
  rails, title-bar clusters) is a different app's chrome; the owner's benchmark is Telegram, whose iPad app is exactly
  "the phone's list beside the chat". Everything in the left pane is the phone layout unchanged, which is what makes
  "every screen works in both layouts" true by construction.
- **DECISION D2 (thresholds = the web's).** Two panes when the window is at least 768 pt wide AND more than 500 pt
  tall; otherwise the phone layout. This is the web's `PHONE_QUERY` (§1.1) applied to the window's own size, so Split
  View, Slide Over and Stage Manager windows follow it. It is NOT the size class: a 700 pt Stage Manager window has a
  regular size class on some iPads and must still be the phone layout.
- **DECISION D3 (sidebar width).** 375 pt (a phone's width) whenever the chat beside it keeps 448 pt, narrowing to
  320 pt at the 768 pt edge: `min(375, max(320, window − 448))`, so an 820 pt portrait iPad gets 372 pt. (Until the UX
  study of 2026-10-19 it was a flat 320 pt below 1000 pt, narrower than any iPhone, and rows cut harder at Extra Large
  text than on a phone.) The web's 237 px
  fits the desktop renderer's dense one-line rows; the native lists are phone rows (56 pt heads, two lines) laid out for
  320-440 pt. 768 − 320 = 448 pt, exactly the web's `--chat-min-width: 28rem`. No drag-to-resize in this row (the web
  sidebar's resize handle is desktop chrome; nothing is shown that does nothing).
- **DECISION D4 (own container, not `UISplitViewController`).** A plain container view controller owns the two panes.
  `UISplitViewController`'s column style wraps a column that is not a navigation controller in one (a tab bar
  controller inside a navigation controller), collapses by size class rather than at 768 pt (D2), and moves view
  controllers between columns on its own schedule, which fights the chat screen's "built before the push" rule. The
  container uses only system pieces (the system tab bar, the system navigation bars, a hairline in the theme's separator colour),
  so all glass on screen is still system glass. No private API.
- **DECISION D5 (the iPhone is untouched).** On the phone idiom the window's root stays `MainTabController` exactly as
  today; the container exists only on the pad idiom. Shared code changes are limited to the routing seam (§4.4), the
  key commands (§4.10) and pointer effects (§4.9), all of which are inert without a pointer or hardware keyboard.
- **DECISION D6 (what goes right).** In two panes, anything a tab root pushes that is not itself a list goes to the
  right pane: chats (every source), a job's page, an artifact viewer, and every page More opens (Settings, Capabilities,
  Gateway and their sub-pages, as the Settings app does). List drill-downs stay left (a Sessions folder / Archived
  list, a Kanban column list): they adopt the marker protocol `ListPaneContent`. DECISION (UX study 2026-10-19): a
  Kanban task stays a sheet in both layouts (the system's centred form sheet in two panes). It is an editing form with
  its own Done, not a page you read beside the list, and the owner tidied it as a sheet (build 287). The lists mark
  the row of whatever the right pane shows: Bots, Sessions, Jobs (the job's page) and More (the page it opened).
- **DECISION D7 (the right pane is one place).** There is one right pane, shared by all tabs. Switching tabs on the
  left never changes it (Telegram). Opening something replaces what was there (its navigation stack is dropped).
- **DECISION D8 (no auto-open).** With nothing open the right pane shows a quiet placeholder (§6). It does not open the
  top chat by itself: opening a chat marks it read, and the owner did not look at it. Launch still reopens the last
  chat (the existing restore), now into the right pane.
- **DECISION D9 (one window).** `UIApplicationSupportsMultipleScenes` stays `false`. The app has one socket and one
  set of stores per account; a second window is its own feature (the web's `session.newWindow` is desktop-only).
- **DECISION D10 (Return).** A hardware keyboard's Return sends (what the Send button would do right now, including
  queueing while a turn runs); Shift-Return and Option-Return add a line; the on-screen keyboard's Return adds a line
  as today (web FE-037, §1.4). ⌘Return also sends (the web's "Queue message" is the same action natively: a send while
  a turn runs queues). Return during marked text (Japanese, Chinese, Korean input) confirms the composition and never
  sends. This applies on iPhone with a paired keyboard too, as on the web.
- **DECISION D11 (⌘↑ / ⌘↓).** The scope names Command-Up/Down for moving between chats; the web's defaults are
  Ctrl-Tab / Ctrl-Shift-Tab. Both are bound. Inside a focused text field ⌘↑/⌘↓ keep their text meaning (start / end of
  the text), as the system and Messages do; they switch chats when the message field is empty or not focused.
- **DECISION D12 (☰ on iPad).** The commands button shows on iPad too (`App/Chat/Menus/ChatMenus.swift:51` hides it
  off-phone today). The web hid it because the iPad had the desktop composer with its own slash popover; the native
  iPad has the one native composer, and without ☰ the commands would be unreachable by touch.
- **DECISION D13 (orientations).** iPad: all four (required for Split View and Stage Manager). iPhone: portrait only,
  as shipped.
- **DECISION D14 (collapse lands on the chat).** When a two-pane window becomes narrow with a chat open, the phone
  layout shows that chat, pushed over the list it was opened from, whatever tab was selected on the left.

## 4. Native design

### 4.1 Project files (both identities)

`project.yml`:
- target `HermesHQNative`: `TARGETED_DEVICE_FAMILY: "1,2"`.
- target `HermesHQNotifications`: `TARGETED_DEVICE_FAMILY: "1,2"` (an iPhone-only extension inside an iPad app is
  rejected at upload).
- `project-original.yml` only sets `HQ_IDENTITY_CHOICE` and the extension dependency, so the family comes from
  `project.yml` for both identities. The builder must still build BOTH (`scripts/build.sh build <udid>` and
  `HQ_IDENTITY=original scripts/build.sh build <udid>`) on the iPad simulator and the iPhone simulator, and read
  `TARGETED_DEVICE_FAMILY` back from each built app's `Info.plist` (`UIDeviceFamily` = `[1, 2]`).
- Integration note for Ship: any target another m9 stream adds (the Share extension, widgets, intents) must also be
  `"1,2"`. `scripts/check-ipad.py` (§7.3) fails when any target in either generated project is not.

`App/Info.plist`:
- add `UISupportedInterfaceOrientations~ipad` = Portrait, PortraitUpsideDown, LandscapeLeft, LandscapeRight (the
  web shell's list, `R/ios/App/App/Info.plist:85-91`); keep `UISupportedInterfaceOrientations` = Portrait.
- do NOT add `UIRequiresFullScreen`. Keep `LSRequiresIPhoneOS` (it means "iOS", and the web shell has it too).
- `UIApplicationSceneManifest` unchanged (D9).
- add `UISceneSizeRestrictions`-equivalent in code: `windowScene.sizeRestrictions?.minimumSize = CGSize(width: 320,
  height: 480)` in `SceneDelegate.scene(_:willConnectTo:)` on the pad idiom (the phone layout's floor).
- The app icon set is already single-size universal (1024). The launch screen is a colour. Nothing else.

### 4.2 `PaneLayout` (HermesKit/Layout/PaneLayout.swift, pure, unit tested)

```swift
nonisolated enum PaneLayout: Equatable, Sendable {
    case single                       // the phone layout
    case double(sidebar: CGFloat)     // two panes, the left one this wide
    static func decide(size: CGSize, pad: Bool) -> PaneLayout   // D2, D3; `pad == false` is always .single
    static let minWidth: CGFloat = 768, minHeight: CGFloat = 500   // two panes need width >= 768 and height > 500
}
```

Sizes are the container view's bounds (the window's), not the screen's. Half-point widths round down before comparing.

### 4.3 `RootSplitController` (App/Root/RootSplitController.swift)

The window's root on the pad idiom (`AppDelegate.swift:181-184`, where `MainTabController` is made).

- Children: `tabs: MainTabController` (left) and `detail: UINavigationController` (right; `navigationBar.prefersLargeTitles
  = false`, `delegate = PushedPageTitles.shared`). Between them a 1-pixel hairline in the theme's separator colour (`HQPalette.separator`).
- `viewDidLayoutSubviews` computes `PaneLayout.decide(size: view.bounds.size, pad: true)`. Frames are set directly
  (the sidebar is on the leading side: left in left-to-right languages, right in right-to-left ones, read from
  `effectiveUserInterfaceLayoutDirection`). `.single`: `tabs.view` fills, `detail.view` is hidden and holds no screens.
  `.double`: `tabs.view` = sidebar width, `detail.view` = the rest.
- **The left pane is a phone.** In `.double` the container sets `tabs.traitOverrides.horizontalSizeClass = .compact`
  (so the system shows the bottom tab bar rather than iPadOS's floating top bar, and every list lays out as on the
  phone); in `.single` it removes the override ONLY if the window itself is compact, otherwise keeps it (a 700 pt
  regular-class window still gets the bottom bar). The builder must look at a screenshot of both: bottom glass tab bar
  in the left pane, no top tab bar anywhere. If the system still draws a top bar, set `tabs.mode = .tabBar` and
  record what was needed in the report. Overriding `userInterfaceIdiom` is NOT allowed (it changes how sheets present).
- Safe areas: each pane gets the window's top and bottom insets; the left pane the leading inset, the right pane the
  trailing inset (`additionalSafeAreaInsets` are not needed when the children's views touch the window's edges; verify
  in landscape on an iPad with a home indicator and under Stage Manager's window controls, whose top-leading corner
  inset arrives through the safe area / `UIWindowScene` layout guide: the left pane's navigation bar must not sit under
  the window controls).
- Status bar, home indicator and rotation: `childForStatusBarStyle` = `tabs`; `supportedInterfaceOrientations` = all.
- The switch between `.single` and `.double` happens inside `viewDidLayoutSubviews` of the same pass as the size
  change, with `UIView.performWithoutAnimation`, after moving screens (§4.5): no frame shows a half state.
- `MainTabController.current` (App/Gateways/MainTabController+Gateways.swift:17) also finds the tab controller inside
  a `RootSplitController`. Every `window.rootViewController is MainTabController` check
  (`AppDelegate.swift:109, 184` and friends) becomes `AppRoot.signedIn(window)` (true for either root). `FailureAlert.topmost`,
  `JobActions.resultHost` and `PagesHUD.show` keep working because they walk from the window root or the tab controller
  (the HUD and the Undo pill stay in the left pane, above its tab bar, where the list they talk about is).

### 4.4 The routing seam: `PaneRouter`

One place decides where a screen goes. Extension on `UIViewController`:

```swift
extension UIViewController {
    /// Opens `screen` from a list: pushed on this list's stack in the phone layout, shown in the right pane in two panes.
    func openDetail(_ screen: UIViewController, animated: Bool = true, done: @escaping () -> Void = {})
}
extension MainTabController {
    var split: RootSplitController? { get }              // nil on iPhone
    var chatOnShow: ChatViewController? { get }          // the chat the user can see, in either layout
    func closeDetail(animated: Bool)                     // two panes: empty the right pane; phone: pop to the list
}
```

`openDetail`:
- phone layout: exactly today's code path (`ChatViewController.push(_:on:limit:done:)` for a chat, `pushViewController`
  otherwise, `hidesBottomBarWhenPushed` as the caller set it).
- two panes: remember the origin (`weak originNavigation`, the calling list's navigation controller), then
  `detail.setViewControllers([screen], animated: false)`. A chat with nothing to paint yet keeps the "never slide in
  blank" hold (`ChatViewController.readyWaiter`, at most 0.35 s) before it replaces the old screen; the old screen stays
  until then. The swap is a 0.12 s cross-fade of the right pane's content (Reduce Motion: none). No slide: nothing is
  being pushed over anything.
- A screen already in the right pane that is opened again (same chat: same profile and stored id) is not rebuilt: the
  call returns after `done()`.
- Pushes made BY a right-pane screen (`navigationController?.pushViewController`, e.g. `StepSheets.swift:582`,
  `WorkspacePages.swift:165-177`, `SettingsScreens.swift:66`, `AppModel+ChatMenus.swift:84`) need no change: their
  navigation controller is `detail`. Its first screen has no back button; deeper ones get the system back button.

Call sites to move to the seam (each one checked on both layouts):

| File:line (m9/train at beee9f7) | Today | After |
|---|---|---|
| `App/Bots/BotsViewController.swift:548-577` (`open`, `push`) | `ChatViewController.push(chat, on: navigation)` | `openDetail(chat)` |
| `App/Sessions/SessionsViewController.swift:365-373` (`openChat`) | same | `openDetail(chat)` |
| `App/Pages/Artifacts/ArtifactsViewController.swift:538, 599, 616` | push chat / viewer | `openDetail` |
| `App/Pages/Jobs/JobsViewController.swift:398` | push job page | `openDetail` |
| `App/Pages/Jobs/JobDetailViewController.swift:92` | push viewer (already right) | unchanged |
| `App/Pages/MoreViewController.swift:109, 117` | push page | `openDetail` |
| `App/Pages/Kanban/KanbanViewController.swift:324` | push a column list | unchanged; the list adopts `ListPaneContent` |
| `App/Root/MainTabController+LaunchChat.swift:113-118` (`placeLaunchChat`) | `setViewControllers([root, screen])` | two panes: select the tab, then `split.show(screen, origin:)` without animation, before the first frame |
| `App/Root/MainTabController+LaunchChat.swift:69-80` (`chatOnShow`) | top of the selected tab | `chatOnShow` from the seam; origin = the remembered origin navigation's tab |
| `App/Root/MainTabController+LaunchChat.swift:160` (chat gone) | `popToRootViewController` | `closeDetail(animated: true)` when it is that chat |
| `App/Notifications/AppModel+Notifications.swift:262-275` | select tab, pop to root, push | select tab, `openDetail` from that tab's root |
| `App/Bots/NewBotViewController.swift:19-33`, `App/Bots/BotExtras.swift:153-156`, `App/Browser/AppModel+Browser.swift:72-79`, `App/Debug/DebugHooks.swift:93` | `botsViewController.navigationController?.topViewController as? ChatViewController` | `root.chatOnShow` |
| `App/Gateways/MainTabController+Gateways.swift:39` (`topChatScreen`) | top of selected tab | `chatOnShow` |
| `App/Chat/Menus/ChatMenus+Actions.swift:176` (delete / archive pops the chat) | `navigation.popViewController` | first screen of `detail`: `closeDetail`; otherwise pop |
| `App/Pages/PagesTabs.swift:205-222, 281-284, 331` (tab rebuilds, `adoptMoreStack`) | `setViewControllers` on tab stacks | after any of these in two panes, run the sweep in §4.5 |
| `App/Root/MainTabController.swift:36-72` (`installTabs(fresh:)`, a gateway switch) | rebuilds tabs | also `closeDetail(animated: false)` unless the right pane shows a More page being carried (`carriedMoreStack`): that stack is re-shown in the right pane |

Any other stream on the train that pushes from a tab root must use `openDetail` (§7).

### 4.5 Moving between layouts

`RootSplitController.apply(_ next: PaneLayout)` runs when the decision changes.

- **`.double` → `.single` (collapse).** If `detail` holds screens: take them all out (`detail.setViewControllers([],
  animated: false)`), find the origin navigation (the remembered one; if it is gone, the Bots tab's), select its tab,
  set `hidesBottomBarWhenPushed = true` on the first moved screen, and `origin.setViewControllers(origin.viewControllers
  + moved, animated: false)` (D14). The chat screen is the same object: scroll position, draft, a recording, a running
  stream, an open Find bar and the keyboard's first responder survive (re-make first responder after the move if it
  was inside the moved screen and the keyboard dropped).
- **`.single` → `.double` (expand).** The sweep: for the selected tab's navigation, find the first screen above the root
  that does not adopt `ListPaneContent`; move it and everything above it into `detail` (remembering that navigation as
  the origin). Other tabs' stacks are swept lazily when their tab is selected (their deeper screens then replace the
  right pane only if the right pane is empty; otherwise they are dropped back to their list, since one right pane cannot
  show two). With nothing to move, `detail` shows the placeholder (§6).
- Both moves happen without animation in the layout pass of the size change. A presented sheet stays presented (it
  belongs to the window, not to a pane).
- **Not while away.** As the app goes to the background, a real iPad lays it out at a narrower size for its app-switcher
  snapshots and widens it back a moment later (the simulator doesn't). With the scene in the background a change
  between one pane and two is held: nothing moves, the panes keep their frames, and `layout: one pane held while away`
  is logged once. Coming back (`UIScene.willEnterForegroundNotification`) lays out again, so a window that really is
  narrower then gets the phone layout as usual. Build 337 moved the chat for those snapshots, and a tester's iPad
  (iPadOS 26.5.2, 2026-10-24) ended the app on 46 of the 46 trips home that had a chat in the right pane. The UI test
  `IPadBackgroundTests` replays the snapshots with `-HQDebugSnapshotResize`.
- `ChatViewController` must not `detach()` during a move: `didMove(toParent: nil)` → `detach()` today
  (`ChatViewController.swift:706-711`). The container sets `chat.movingBetweenPanes = true` around the move and the chat
  skips `detach`/`attach` and `voice.screenLeft()` while it is set. Unit test: a stream that is running across a
  collapse keeps receiving deltas and `session.onChange` stays set.

### 4.6 The chat in a pane

- **Width before the push.** `ChatViewController.init` lays out at the SCREEN's width (`ChatViewController.swift:163-166`).
  On iPad that is wrong twice (pane, window). Add `static var openingWidth: CGFloat?` set by the seam from the pane the
  chat is about to land in (the right pane's width, or the window's width in the phone layout); `init` uses it and falls
  back to the screen. `TextLayout.screenHeight` likewise takes the window's height. `ChatChrome.swift:182` and
  `ToolCallsSettingsView.swift:92` read the screen width: both take their own view's / window's width instead.
- **Resize.** `viewDidLayoutSubviews` already relays out when the table's width changes
  (`ChatViewController.swift:653-656`, `relayoutEverything()`). A Stage Manager drag fires this for every intermediate
  width. Requirement: during a live resize the chat stays readable and never jumps: keep the reading position anchored
  (the row at the visual bottom stays at the visual bottom); coalesce to one relayout per display frame; layouts for
  off-screen rows refill progressively as at open. Measure on the 2,000-message fixture chat: no frame over 33 ms on
  the simulator host while dragging (signpost `chat.resize`), and no blank table at any point.
- **Readable column.** A reply spanning 1,000 pt is unreadable. The transcript and the composer are centred in a column
  of at most **760 pt** (`ChatMetrics.readableMax`), with `ChatMetrics.sideInset` inside it. Implementation: the layout
  width passed to `TextLayout` is `min(pane width, 760)` and the rows' content is offset by `(pane − column) / 2`; the
  table itself still spans the pane so scrolling works from the margins. The user's bubble cap stays
  `min(column × 0.8, 320)` (`TextLayout.swift:518-522`): bubbles do not grow on iPad. The composer, queue card,
  activity shelf, question dock, jump button and voice rows follow the same column (`followDockSide()`,
  `activity.setSideInset`).
- **Bars.** In the right pane the chat's navigation bar is the same small-title bar with the same title view, ⋯ menu and
  status line. No back button on the first screen. `hidesBottomBarWhenPushed` has no effect there (the tab bar belongs
  to the left pane and stays).
- **Keyboard.** The composer stays pinned to `view.keyboardLayoutGuide.topAnchor` (ARCHITECTURE "Feel rules"). On iPad
  check: the docked keyboard (spans the window, the left pane's tab bar goes under it), the floating keyboard and split
  keyboard (`followsUndockedKeyboard` stays `false`: the composer rests at the bottom), the hardware-keyboard shortcut
  strip, and Stage Manager windows that do not touch the screen's bottom (the guide accounts for the overlap only).
  Interactive dismissal still tracks the finger.
- **Left-pane selection.** The row of the chat on show is highlighted in Bots (row or tile) and Sessions with the
  system's selected list background (`UIBackgroundConfiguration.listCell()` selected state), updated when the right
  pane changes, cleared in the phone layout. The row keeps its unread dot rules (a chat on show is read once fresh
  history applied, as today).
- **Back count** (`MainTabController.setBackCount`): only meaningful in the phone layout; in two panes nothing shows it.

### 4.7 Sidebar toggle

- **Not built.** The web's ⌘B "Toggle sessions sidebar" hides the desktop sidebar. In the native two-pane layout the
  left pane holds the tab bar, which is the only way to the other tabs; hiding it needs a second control to bring it
  back and a full-width chat mode. DECISION: out of this row; ⌘B is not bound (never a shortcut that does nothing).
  Recorded in the report as a possible follow-up, not as a gap in L834.

### 4.8 Sheets, popovers, viewers

- Sheets (`ChatSheet.wrap`, Settings, Bot Info, New Bot, pickers) present from whichever pane asked; UIKit presents
  them over the window. In a regular-width window they are the system's centred form sheet; in a compact window the
  edge-attached sheet with their detents, as on the phone. Each sheet must be opened once in each layout (§7.2).
- `.actionSheet` alerts and `UIActivityViewController` crash on iPad without a popover anchor. Every site on the train
  today sets one (audited at beee9f7: `BotExtras.swift:165-203`, `GatewayPageView.swift:145-158`,
  `SessionsOrganizer.swift:189-210, 469-471`, `ChatMenus+Actions.swift:96-97, 141-144`, `KanbanViewController.swift:547-634`,
  `BotInfoSheet.swift:67-75`, `ArtifactImageViewer.swift:113-120`, `KanbanTaskSheet.swift:202-210`,
  `JobActions.swift:112-137`, `AboutView.swift:204-205`, `ActivityCells.swift:591`, `ChatMenus.swift:294-296, 453-454`,
  `ChatViewController.swift:757-758`, `QuickLookPresenter.swift:60-61`, `FilePreviewPresenter.swift:104-105`,
  `ArtifactsViewController.swift:546-547, 637-638`, `MediaActions.swift:53-55`, `SettingsNavigator.swift:84-86`,
  `ArtifactTextViewController.swift:273-274`). Two need a real look: `ActivityCells.swift:591` (no anchor visible on the
  next lines) and every `if let source { … }` form whose `source` can be nil (`ChatMenus.swift:454`,
  `TextPrompt.swift:54-56`, `KanbanViewController.swift` `source ?? view`). Rule: an anchor is never optional; fall back
  to the presenting view with `sourceRect` = its centre and `permittedArrowDirections = []`. `scripts/check-ipad.py`
  (§7.3) greps for new sites.
- SwiftUI `.confirmationDialog` (`AccountViewController.swift:77`) anchors itself.
- Full-screen viewers (media viewer, browser viewer, Quick Look) cover the whole window in both layouts.
- Context menus and `UIMenu` buttons need nothing.
- The camera on iPad: `UIImagePickerController` with `.camera` must be presented full screen; Photos and Files pickers
  are form sheets. Check the + menu's three sources on the iPad simulator (the simulator has no camera: the row must be
  absent or say so exactly as on the iPhone simulator).

### 4.9 Pointer hover

System behaviours only (no hover-only controls, MEM/ios-native-ux-goal.md).

- List rows (Bots rows and tiles, Sessions rows, Jobs, Artifacts, More, Settings rows): `UICollectionViewListCell` and
  `UIBackgroundConfiguration` do not show a hover state by default. Add a `UIPointerInteraction` with `UIPointerStyle(effect: .hover(preview))`
  to each tappable row's content view through one helper, `PointerEffects.row(_:)`, and
  `PointerEffects.button(_:)` = `.highlight` for round glass buttons (composer +, ☰, mic, Send / Stop, jump button,
  the Find bar's arrows, tile actions) and `.lift` for the Bots tiles. `UIButton`s made with `UIButton.Configuration`
  set `isPointerInteractionEnabled = true` instead.
- Bar button items and tab bar items get the system effect for free.
- Text: the composer and Select Text show the I-beam for free. Links in a bubble: `.hover` effect on the link's rect is
  not required; the pointer stays an arrow.
- Secondary click (two-finger tap / right click) opens every context menu a long press opens (free with
  `UIContextMenuInteraction`; verify on a Bots row, a Sessions row and a message bubble).
- Scroll: trackpad scrolling, and the transcript's inverted table scrolling in the natural direction (verify: an
  inverted table has inverted the wheel direction in past UIKit versions; if it has, flip with
  `panGestureRecognizer.allowedScrollTypesMask = .all` plus a sign fix in a `UIScrollViewDelegate` shim, and record it).
- Nothing appears only on hover.

### 4.10 Keyboard shortcuts

Built with `UIKeyCommand` on the responder chain plus `pressesBegan` for Return / Escape in the message field. All
titles show in the system's hold-⌘ overlay (`discoverabilityTitle` = `title`), grouped by `UIMenuBuilder` in
`AppDelegate.buildMenu(with:)` under the system's File / Edit / View menus (iPadOS 26 shows a real menu bar: every item
must work or be disabled with a reason-free grey state by `validate(_:)`, never a dead item).

| Keys | Title (exact) | Where it lives | What it does |
|---|---|---|---|
| ⌘N | New Chat | root (`MainTabController`) | [cmd-n] Since 2026-11-02 (tester: the chooser on every ⌘N was irritating): a new chat with one bot at once, no chooser — Hermes, or the bot Settings › Chat › New Chat (⌘N) names on the Mac (`NewChatKeyBot`; Ask Every Time brings the chooser back), via `SessionsOrganizer.composeWithKeyBot()`; the menu item reads "New Chat with <bot>". ⇧⌘N (New Chat With…) is the chooser below. Owner 2026-11-02 ("any others we should have?"): Settings › Chat › New Chat Project (Mac) starts ⌘N's chat in a project (it wins over Filter › Project; a project no bot has any more is dropped); ⌥⌘N (New Chat Here) starts one with the open chat's bot in the project holding its folder (`SessionsOrganizer.newChat(like:)`, off with no one-bot chat on show); the Dock menu has New Chat. A tester 2026-11-02 ("bot chats are intended to be persistent and compact rather than reset"): Settings › Chat › ⌘N Opens › Bot Chat makes ⌘N open the ⌘N bot's own chat as its rail head or Bots row does (Bots becomes the tab on show), with the caret in the message field (`KeyCommands.openBotChat`); Ask Every Time asks which bot first; the item reads "Open <bot>’s Chat". ⇧⌘N and ⌥⌘N still start new chats. Before: Sessions' compose (`SessionsOrganizer.compose()`: with more than one bot the bot picker, else a new chat with the only bot). Runs from any tab; the new chat opens through the seam: in two panes on the right with the left pane's tab unchanged, in the phone layout Sessions comes to the front at its list and the chat is pushed there, so one Back lands on Sessions (repair after stress round 1: it used to be pushed on the hidden Sessions stack and never seen). The same holds with Sessions already on show and a chat open on it: the new chat goes over the list, not over that chat, so repeated Command-N never grows the stack (repair after stress round 2; DECISION: the list comes back without animation and the new chat is pushed over it, the same way as from another tab). DECISION (repair, stress round 1): Command-N does exactly what the Sessions Compose button does, offline too. That button is not disabled offline on the train (it opens Choose a Bot and a failed `session.create` shows "Couldn’t Start a New Chat" with Try Again), so the key is not disabled offline either: a key that is dead while the button beside it works would be the worse surprise. The earlier wording here ("Disabled offline / read-only, as the compose button is") described a button state that does not exist. If the sessions stream later disables Compose offline, `validate` must follow it. |
| ⌘F | Find | chat on show: `showFind()` (the ⋯ menu's Find); otherwise, in two panes, the right pane's page when it has a search (Files, Webhooks, Settings); otherwise the selected list's search field becomes first responder (Bots, Sessions, any page with a search controller). Disabled where none exists. |
| ⌘⇧F | Search Sessions | root | Selects the Sessions tab and focuses its search field (web `session.focusSearch`). |
| ⌘↓ / ⌃Tab | Next Chat | root | The row after the chat on show in the list it was opened from (the list's current order, filters and collapsed sections respected; hidden rows skipped), opened through the seam. With no chat open: the first row of the selected list. At the end: nothing (no wrap; the system's "bonk" is not played). |
| ⌘↑ / ⌃⇧Tab | Previous Chat | root | The row before. |
| ⌘1 … ⌘5 | Bots, Sessions, and the three page tabs by their current titles | root | Selects that tab (titles follow `PagesTabs`: "Jobs", "Kanban" or "Artifacts", "More"). |
| ⌘, | Settings | root | More › Settings through the seam (web `nav.settings`). |
| Return | (no menu item) | message field | D10. Hardware only: `pressesBegan` sees `UIKeyboardHIDUsage.keyboardReturnOrEnter` / `.keypadEnter`; the on-screen keyboard never produces presses with a `key`. With `markedTextRange != nil`: pass to `super`. Empty field with no attachments: nothing. |
| ⇧Return / ⌥Return | (none) | message field | Inserts a line break. |
| ⌘Return | Send | message field | Same as Return (D10). |
| Escape | Stop / Close (see below) | chat, sheets | First match wins. |
| ⌘W | Close Chat (Close) | root, two panes only | `closeDetail` (the right pane shows the placeholder). Titled "Close" while the right pane holds a page that is not a chat (Settings, a job), so the menu says what goes. In the phone layout: back to the list. |
| ⌘R | Refresh | page or list on show | In two panes, the right pane's page when it has pull-to-refresh; otherwise the list's pull-to-refresh action. |

**Escape, first match wins** (web §1.5; "a transient layer" in the scope):
1. A context menu or `UIMenu` is open: the system closes it.
2. A sheet, alert, popover or full-screen viewer is presented: it is dismissed the way its ✕ / Cancel does (a sheet
   with unsaved edits asks exactly as its ✕ does; an alert takes its cancel action). `ChatSheet.wrap` and the viewers
   implement `accessibilityPerformEscape` AND a `UIKeyCommand(input: UIKeyCommand.inputEscape)` calling the same close.
3. The chat's Find bar is open: `ChatFindController.close()`.
4. A voice memo is being recorded or reviewed: cancel it exactly as its ✕ does (to a draft chip where ✕ does that).
5. A list's search is active: cancel the search.
6. A question dock (clarify / approval) is waiting: nothing. Escape never answers or dismisses a question (web:
   "the turn is parked on a clarify / approval … never cancel the stream out from under it").
   [mac-audit] 2026-11-02: on the Mac a clarify question's card takes Escape as its Skip (leaving its "Something
   else…" field first); Skip answers the question, it never cancels the turn. An approval still takes nothing.
7. A turn is running in the chat on show: Stop (`composer.onStop`, the same path as the Stop button, haptic included).
   This holds whether or not the message field has focus (native has no "focus is in the transcript" state; the web's
   field-focused case is covered by its composer handler, which also cancels).
8. The message field has focus and nothing else applies: it resigns first responder (the keyboard, if any, goes down).
9. Otherwise nothing.

Rules:
- Key commands that take plain or ⌘ keys a text field uses set `wantsPriorityOverSystemBehavior` only where stated
  (none do: ⌘↑/⌘↓ deliberately lose to a non-empty focused field, D11; implement by not offering the command from
  `ComposerView`'s text view when `text.isEmpty == false`, via `canPerformAction`).
- Commands are offered only when signed in (`RootSplitController` / `MainTabController` are in the chain). The sign-in
  form keeps the system's own Return / Tab behaviour.
- While a sheet is presented, root commands do not fire (UIKit: the presented controller's chain). Verify ⌘N under an
  open Settings sheet does nothing rather than opening a chat behind it.
- Arrow keys / Tab focus movement: the system's focus engine is left at its default (`focusGroupIdentifier` untouched).
  Space / Page Up / Page Down scroll the transcript when the field is not focused (free with `UIScrollView`; verify the
  inverted table goes the right way, else bind `UIKeyCommand.inputPageUp/Down` to an explicit scroll).

### 4.11 Launch, alerts, links in two panes

- **Launch restore** (`MainTabController+LaunchChat.swift`): the remembered chat is placed in the right pane before the
  first frame when the window opens in two panes; the remembered origin still selects the left tab. A chat that turns
  out to be gone goes back to the placeholder quietly (today: back to its list).
- **A tapped notification / a `hermes://` link** (`AppModel+Notifications.swift:239-290`): opens the chat through the
  seam; in two panes the left list does not pop or scroll, the tab selects as today.
- **Reply peek / in-app banners** (if on the train): shown over the window as today; tapping opens through the seam.
- **`LaunchChatMemory.remember`**: `chatOnShow` from the seam, so a chat in the right pane is remembered with its
  origin tab.

### 4.12 Rotation, Split View, Slide Over, Stage Manager

All are just size changes to the container (§4.3, §4.5). Specifics to check:
- Slide Over and the narrowest Split View third (320-375 pt): phone layout.
- Half Split View on a 13-inch iPad (~678-683 pt): phone layout (below 768). On an 11-inch in landscape half = ~590:
  phone layout.
- Full screen portrait on any current iPad (≥ 744 pt: iPad mini is 744 pt wide): **iPad mini portrait is 744 pt, so it
  gets the phone layout in portrait and two panes in landscape (1133 pt)**. This follows D2 and the web exactly;
  the report must show a screenshot of both and say so.
- Stage Manager / iPadOS 26 windowing: continuous resize crosses 768 pt repeatedly; hysteresis is NOT added (the web has
  none); what must hold is that crossing is glitch-free and loses nothing (§4.5).
- An external display: same rules on that scene's size.
- Window height ≤ 500 pt with width ≥ 768: phone layout (D2). Lists and chat must still be usable at 480 pt tall.

### 4.13 What does not change

Transport, stores, caches, the chat session, every wire call. `ChatWarmer`, unread rules, badges (the left tab bar's
badges count the same things). Debug hooks: `-HQDebugOpenBot`, `-HQDebugSessionsTab`, `-HQPages…` keep working in both
layouts through the seam. New DEBUG launch argument: **`-HQDebugPaneWidth <points>`**: the container insets its own
content to that width (centred, black around), so UI tests can drive a "window" of any width on an iPad simulator
without Stage Manager; `-HQDebugPaneHeight <points>` likewise.

## 5. Wire calls

**None are new.** The stream moves screens; it sends nothing the phone layout does not send. For the tester, what the
shortcuts cause on the wire (all existing code paths; Hermes rejects unknown params with error 4000, so nothing is added):

| Action | Call (existing) |
|---|---|
| ⌘N New Chat | JSON-RPC `session.create` `{"profile":"<bot id>","follow_profile_config":true}` → `{"session_id":…,"stored_session_id":…}` (`HermesKit/Store/SessionStore+Actions.swift:354-362`; contract `tui_gateway/contracts/sessions.py`) |
| Return / ⌘Return | JSON-RPC `prompt.submit` `{"session_id":…,"text":…}` exactly as the Send button builds it (spec 04) |
| Escape while running | JSON-RPC `session.interrupt` `{"session_id":…}` exactly as the Stop button (spec 04) |
| ⌘↑ / ⌘↓, opening a row | the open path of spec 03: `GET /api/sessions/{id}/messages…` + `session.resume` |
| ⌘R | the list's refresh: `profiles.list` / `GET /api/profiles/sessions/sidebar` (spec 02) |

Check: the fixture's request log (`/__fixture/state` or the perf fixture's log) shows the SAME calls with the SAME
params for a shortcut as for the tap it stands for, and no call at all for a layout change, a rotation or a resize.

## 6. UI states and wording

| State | What shows |
|---|---|
| Two panes, nothing open | Right pane: the background of the list beside it (`HQPalette.groupedPage` beside More, `HQPalette.page` elsewhere; UX study 2026-10-21: two shades read as two slabs), centred, the theme's secondary label colour (`HQPalette.label2`), the neutral `sidebar.right` symbol (44 pt, `HQPalette.label3`; not a chat's bubbles, since the list can be Jobs or More) over **"Nothing Selected"** (title 3, semibold) and **"Choose an item from the list."** (subheadline). The second line is left out while the list beside it shows its empty state (its `contentUnavailableConfiguration`; Sessions' list background and Artifacts' state cell through `PaneListEmptiness`, UX study #89), and comes back or goes as soon as the list fills or empties. The words name no kind of item, since the list beside it can be Jobs, Kanban or More (UX study 2026-10-19). No bar buttons. VoiceOver reads the lines as one element. DECISION: wording is new (the web's desktop layout always has a chat open); plain, no product names. |
| Two panes, chat open | §4.6. The left row is selected. |
| Two panes, signed in but offline with no cache | Left: the lists' own offline / skeleton states unchanged. Right: the placeholder. |
| Two panes, a More page open | Right pane shows the page with its small title on the bar row; the More row stays selected. |
| Phone layout on iPad | Identical to iPhone, including the back count on Back. |
| Chat removed while on show (deleted / archived here or elsewhere) | Two panes: the right pane returns to the placeholder; the existing notice wording (if any) is unchanged. |
| Gateway switch | Right pane empties (or re-shows the carried More page); left rebuilds as today. |
| Sign-in form, launch screen, "problem" screen | Full window in both layouts, content in a centred column of at most 480 pt on a wide window (the form is SwiftUI: `.frame(maxWidth: 480)`); wording unchanged. |
| Shortcut titles | Exactly as in §4.10: "New Chat", "Find", "Search Sessions", "Next Chat", "Previous Chat", "Settings", "Send", "Close Chat" ("Close" while the right pane holds a page that is not a chat), "Refresh", and the tab names. DECISION: "Chat" not the web's "session" in "New Chat" / "Next Chat" (the native app's own buttons say "New Chat"); "Search Sessions" keeps "Sessions" because it names the tab. |

No wording anywhere contains the word the owner banned from the UI. No new alert text.

## 7. Every screen on the train, in both layouts

### 7.1 The contract for other streams (goes into the report's integration notes for Ship)

1. Open a screen from a tab root with `openDetail(_:)`, never `navigationController?.pushViewController` or
   `ChatViewController.push` directly. List drill-downs adopt `ListPaneContent`.
2. Find the chat on screen with `MainTabController.current?.chatOnShow`, never `botsViewController.navigationController?.topViewController`.
3. Never read `UIScreen` / `windowScene.screen.bounds` for layout: use the view's own bounds.
4. Every `.actionSheet` and share sheet has a non-optional anchor (§4.8).
5. New targets: `TARGETED_DEVICE_FAMILY: "1,2"`.
6. Nothing may assume `window.rootViewController is MainTabController`: use `MainTabController.current` / `AppRoot.signedIn`.

### 7.2 The screen audit (builder fills `docs/briefs/m9/ipad-report.md` with one line per screen: layout × result × screenshot file)

Each of these is opened on the iPad simulator in two panes (landscape, 13-inch) AND in the phone layout
(`-HQDebugPaneWidth 420`), and a screenshot is looked at:
Bots (rows, tiles, sections, search, filter menu, empty, offline, skeleton) · Sessions (list, folders, Archived, search,
filter) · chat (cached open, cold open skeleton, failure with Retry, streaming, queue card, activity shelf, question
dock, tucked prompt, jump button, Find, voice recorder rows and draft chip, attachment tray, media viewer, file
preview, step sheet, hold menu on a bubble, ⋯ menu, commands sheet) · Bot Info and Edit Bot / Edit Head · New Bot ·
Account sheet · gateway switcher · Jobs list, job page, new/edit job · Kanban board, column list, task sheet · Artifacts
list and each viewer · More · Settings root and one page of each kind (list, form, model picker, About, Tool Calls) ·
Capabilities · Browser viewer and browser choice · sign-in form (address, Nous, password) · launch problem screen.
Plus every screen that other m9 streams have landed on `m9/train` by the time the builder merges it (merge `m9/train`
into `m9/ipad` before the audit and again before handing to the stress tester; list what was added).

A screen "works" when: nothing is clipped or overlapping, text is not stretched past the readable column where it is
prose, every control is reachable, its sheet / popover opens anchored, and closing it returns to the same place.

### 7.3 `scripts/check-ipad.py` (new, run by the builder and by Ship)

Static checks, exit 1 on a finding: (a) every target in `project.yml` has family `"1,2"`; (b) `App/Info.plist` has the
`~ipad` orientations and no `UIRequiresFullScreen`; (c) no `UIScreen.main` and no `.screen.bounds` under `App/` outside
an allow-list (`ChatPerfProbe.swift`); (d) every line with `.actionSheet` or `UIActivityViewController(` has
`popoverPresentationController` or `sourceView:` / `sourceItem` within the next 12 lines; (e) no
`topViewController as? ChatViewController` outside `App/Root/`; (f) no user-facing string literal in the new files
contains the banned word.

## 8. Stand-in gateways and commands

Simulators (create once, reuse; never the default one):

```sh
xcrun simctl create "HQN-m9-ipad" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0          # phone regressions
xcrun simctl create "HQN-m9-ipad-pad" "iPad Pro 13-inch (M5)" com.apple.CoreSimulator.SimRuntime.iOS-27-0
xcrun simctl create "HQN-m9-ipad-mini" "iPad mini (A17 Pro)" com.apple.CoreSimulator.SimRuntime.iOS-27-0  # the 744 pt case
# stress tester: "HQN-m9-ipad-s" (iPhone 17 Pro), "HQN-m9-ipad-s-pad" (iPad Pro 13-inch (M5)), "HQN-m9-ipad-s-mini"
```

Fixtures (all bind 127.0.0.1 only; refuse a busy port; credentials files are 0600 and never printed):

| Need | Fixture | Start command (builder port) |
|---|---|---|
| Bots, sessions, a 2,000-message chat, send / stream / Stop, a queued send | the performance fixture | `python3 /Users/me/Projects/hermes-hq-native-ref238/scripts/performance-fixture-gateway.py --port 10110 --credentials build/fixtures/ipad-perf.json` |
| Sessions list actions, search, New Chat (`session.create`), request log at `/__fixture/state` | `scripts/fixtures/sessions-gateway.py` | `python3 scripts/fixtures/sessions-gateway.py --port 10111 --credentials build/fixtures/ipad-sessions.json` |
| Jobs / Kanban / Artifacts / More pages | `scripts/pages-fixture-gateway.py` | as `scripts/e2e-pages.sh` starts it, with port 10112 |
| ⋯ menu, Find, commands, model switcher | `scripts/fixtures/menus-gateway.py` | as `scripts/e2e-menus.sh` starts it, with port 10113 |
| Questions dock (Escape must not answer) | `scripts/fixtures/questions-gateway.py` | `python3 scripts/fixtures/questions-gateway.py --port 10114 --credentials build/fixtures/ipad-questions.json` |

No new fixture script is needed: the feature adds no wire traffic (§5). If the performance fixture cannot hold a turn
running long enough to press Escape reliably, the builder adds `--reply-seconds` handling in a thin wrapper
`scripts/fixtures/ipad-gateway.py` that loads it the way `sessions-gateway.py` loads the action-voice fixture, and
documents the command here.

New script **`scripts/e2e-ipad.sh <PAD_UDID> [PHONE_UDID]`** (modelled on `scripts/e2e.sh`): starts the performance
fixture on `${HQN_IPAD_PORT:-10110}`, passes `TEST_RUNNER_HQN_UI_CREDENTIALS` and `TEST_RUNNER_HQN_SHOTS_DIR`, runs
`-only-testing:HermesHQNativeUITests/IPadLayoutTests` and `…/KeyboardShortcutTests` on the iPad simulator with derived
data `${HQN_DD:-build/dd}`, then (when a phone UDID is given) `KeyboardShortcutTests` on the phone, and stops the
fixture it started. The stress tester runs it with `HQN_IPAD_PORT=10115`.

Builds and unit tests:

```sh
scripts/build.sh build <pad-udid> && HQ_IDENTITY=original scripts/build.sh build <pad-udid>
scripts/build.sh test <phone-udid>          # the whole unit suite must stay green on the phone
scripts/build.sh test <pad-udid>            # and on the iPad
python3 scripts/check-ipad.py
```

## 9. Tests to write

Unit (`Tests/IPad/`):
- `PaneLayoutTests`: 767.5 → single; 768 × 501 → double(320); 768 × 500 → single; 999 → 320; 1000 → 375; 1366 → 375;
  744 × 1133 → single; 1133 × 744 → double(375); `pad: false` always single.
- `PaneRouterTests` (a `RootSplitController` built with the demo services, `ListsDemo`): open in double puts the screen
  in `detail` and leaves the list stack at its root; open in single pushes; collapse moves the same chat instance onto
  its origin's stack and selects that tab; expand moves it back; a `ListPaneContent` drill-down stays left; opening the
  chat already shown builds nothing; `chatOnShow` is right in all four states; a gateway switch empties `detail`.
- `PaneMoveKeepsChatAliveTests`: across collapse and expand `session.onChange` stays set, `detach` is not called, the
  draft text and the content offset are unchanged.
- `KeyCommandTests`: the Escape ladder as a pure function `EscapeAction.decide(state)` over (menu, presented, find,
  recording, searching, question, running, fieldFocused) → the nine outcomes of §4.10; Return decision
  `ReturnKey.decide(hardware:shift:option:marked:empty:)`; next / previous chat over a list order with hidden rows and
  collapsed sections; ⌘↑/⌘↓ not offered from a non-empty field.
- `ReadableColumnTests`: layout width = min(pane, 760); bubble cap unchanged at 320.

UI (`UITests/ipad/`, on the iPad simulator; hardware keys via `XCUIElement.typeKey(_:modifierFlags:)`):
- `IPadLayoutTests`: (1) sign in, two panes visible (`bots.list` and the placeholder both hittable), tap a bot, the chat
  appears on the right while `bots.list` is still hittable, the row is selected; (2) switch to Sessions, open one, the
  right pane changes, switch tabs, the chat stays; (3) rotate to portrait and back: same chat, same scroll position
  (compare the top visible row's identifier), draft kept; (4) relaunch with `-HQDebugPaneWidth 420`: phone layout, the
  restored chat is pushed over its list, Back returns to the list; (5) More › Settings opens on the right, a sub-page
  pushes there with a back button; (6) a share sheet and an action sheet open anchored (no crash) from a Sessions row
  and from the chat's ⋯; (7) iPad mini portrait = phone layout, landscape = two panes; (8) screenshots of every state
  into the shots folder for the report.
- `KeyboardShortcutTests` (iPad and iPhone simulators): ⌘N opens a new chat (and the fixture logged one
  `session.create`); typing then Return sends (bubble appears), Shift-Return adds a line and does not send; Escape
  during a stream stops it (`composer.stop` turns back into send; one `session.interrupt` logged); ⌘F opens Find and
  Escape closes it without stopping the stream that is running; Escape with a sheet open closes only the sheet; ⌘↓ / ⌘↑
  walk three chats in list order and stop at the ends; ⌘1/⌘2 switch tabs; ⌘, opens Settings; ⌘W empties the right pane.

Never loosen an assertion to pass under load: rerun, and report a flake as a flake with its rate.

## 10. Acceptance checks (the row is ✅ only with all of these seen)

1. Both identities build for an iPad simulator and an iPhone simulator; the built apps' `UIDeviceFamily` is `[1, 2]`;
   `scripts/check-ipad.py` passes.
2. iPad Pro 13-inch, landscape and portrait: two panes; the left is the phone's tab controller with its bottom glass
   tab bar; the right is the chat or the placeholder with the exact §6 wording. Screenshot looked at, light and dark.
3. A window narrower than 768 pt (Split View half, Slide Over, `-HQDebugPaneWidth 420`, iPad mini portrait) is the
   phone layout, indistinguishable from the iPhone's.
4. Crossing 768 pt with a chat open, in both directions, keeps the same chat, scroll position, draft, running stream
   and Find bar; no blank frame (screen recording stepped through).
5. Every screen in §7.2 has a line in the report for both layouts with a screenshot that was looked at.
6. Every shortcut in §4.10 does what its row says and its title shows in the hold-⌘ overlay; the Escape ladder holds
   (in particular: never answers a question, never stops a stream while a sheet is open).
7. Return rule D10 holds with a hardware keyboard on iPad and iPhone; the on-screen keyboard's Return still adds a line.
8. Pointer: rows and round buttons show the system hover effect; secondary click opens the context menus; trackpad
   scroll direction is natural in the transcript.
9. The fixture's request log shows no extra call for any layout change, and identical calls for shortcut vs tap.
10. iPhone: the full existing suites (`scripts/build.sh test`, `scripts/e2e.sh`, and each `scripts/e2e-*.sh` the train
    has) pass on the phone simulator with the same first-content numbers as before the change (within noise; report
    the numbers).
11. Chat open time on iPad two-pane from cache: first content in the same frame as the swap (the DEBUG
    `first-content-ms` value on `chat.table`), `rows-at-init > 0`.

## 11. STRESS PLAN

Run by the stress tester on its own simulators (`HQN-m9-ipad-s*`) and ports 10115-10119.

**Resizing and rotation**
- With the 2,000-message chat open and a reply streaming, rotate 20 times in a row (`simctl` / XCUIDevice orientation),
  then check: one chat screen exists (no leaked duplicates: count `ChatViewController` instances through a DEBUG
  counter), scroll position at the newest end, stream still growing, memory back within 10% of the start.
- Drive `-HQDebugPaneWidth` through a live sweep (a DEBUG slider or a timer hook stepping 1,100 → 400 → 1,100 pt over
  2 s, 50 times), which crosses 768 and 1000 repeatedly: no crash, no blank pane, no lost draft, hitch signposts under
  the §4.6 limit. Repeat with the keyboard up, with Find open, with a voice memo recording, with a sheet presented, with
  a context menu open, and with the media viewer open.
- In the simulator's real windowing (Stage Manager / iPadOS 26 windows): drag the window's corner across the threshold
  by hand ten times; Split View with another app at each ratio; Slide Over; pull the app to half height (≤ 500 pt).
- iPad mini: portrait ↔ landscape flips layouts every time; do it 20 times with a chat open.

**Speed and load**
- ⌘↓ held with key repeat through 100 sessions: the right pane must keep up without queueing a backlog of opens (the
  seam drops intermediate opens: only the last requested chat is built once the key is released or the previous open
  painted), no stale chat left attached (each skipped session gets no `session.resume`), memory flat.
- Tap ten different rows in one second: the last one wins, exactly one chat attached.
- Open the 2,000-message chat in two panes: first content same frame; scroll a fling with the trackpad and with touch.
- Type fast with the hardware keyboard while a reply streams: no dropped characters, no hitch over 33 ms.
- Return pressed 30 times quickly with text typed between: 30 sends or queues in order, none doubled, none lost.

**Bad network**
- Kill the fixture while two panes show a streaming chat: the left shows "Offline" / "Reconnecting…" as today, the
  right keeps its rows, Escape does not crash with no socket (Stop while offline behaves exactly as the Stop button),
  ⌘N is disabled, ⌘↓ still opens cached chats. Restart the fixture: both panes recover without a duplicate turn.
- 5 s response delay (`/__fixture/fail` with `delay`) on the session open: ⌘↓ ⌘↓ ⌘↓ quickly, then the delayed answers
  arrive out of order: the pane shows the last chosen chat, never an earlier one.
- Resize across the threshold while an open is in flight (skeleton showing) and while the first-page retry ladder
  (2/5/10 s) is counting.

**Bad data**
- A session row that 404s on open (deleted elsewhere): the right pane shows the existing failure state with Retry, and
  ⌘↑/⌘↓ still move off it.
- A bot or session with a 300-character name and emoji / right-to-left text in the left pane at 320 pt and the title of
  the right pane; a chat whose only content is a 4,000-pt-wide code block or table (the readable column must scroll it,
  not stretch the pane).
- Right-to-left system language (Arabic pseudo-language): panes mirror, selection and shortcuts still work.
- A roster of 0 bots and 0 sessions: left shows its empty states, right the placeholder; ⌘N / ⌘↓ disabled or inert.
- 200 bots and 1,000 sessions: ⌘↓ order matches the visible order exactly, including after a refresh reorders rows
  mid-walk (the walk continues from the chat on show's new position).

**Interruption**
- Background the app (home, app switcher, another app in Split View taking focus) mid-stream, mid-recording, with a
  sheet up, in each layout; foreground: same screen, same layout, socket reconnects once.
- Lock / unlock; an incoming call banner; the system keyboard switching between docked, floating and split; connecting
  and disconnecting the hardware keyboard while the composer has focus (the on-screen keyboard comes back, Return goes
  back to adding a line).
- A notification tapped while in two panes with a sheet presented: the sheet closes (or stays, as on the phone today)
  and the right pane shows the notified chat.
- A gateway switch from More › Settings › Gateway in two panes; sign out in two panes; a 401 that forces the sign-in
  form while two panes show.
- Low-memory warning (`simctl spawn … notifyutil` / the simulator's Debug menu) with both panes populated.

**Relaunch**
- Kill and relaunch in two panes with a chat open: the same chat in the right pane before the first frame, its origin
  tab selected. Relaunch at a different size (was two panes, now `-HQDebugPaneWidth 420`, and the reverse): the chat is
  restored in the new layout. Relaunch in the other orientation. Relaunch offline. Relaunch after the chat was deleted
  on the gateway (returns to the placeholder quietly). Relaunch after a crash marker (the restore is skipped as today).
- Upgrade path: install the phone-only build 250 on the iPad simulator (it runs in the compatibility window), sign in
  against the fixture, then install this build over it: signed in still, lists from cache, two panes.

**Accessibility**
- Dynamic Type at XS, default, XXXL and AX5 in both layouts: the 320 pt left pane at AX5 must still show its rows
  (wrapping rows keep 12-14 pt vertical padding) and the tab bar; the placeholder wraps; the composer and the readable
  column hold.
- VoiceOver: the two panes are reachable in order (left then right), the placeholder is one element, the selected row
  says "selected", Escape gesture (two-finger scrub) follows the same ladder as the Escape key; Full Keyboard Access
  on: Tab moves between panes, Space activates rows, nothing is trapped; Switch Control scan reaches both panes.
- Bold Text, Increase Contrast (the hairline stays visible), Reduce Transparency (system bars go solid, nothing of ours
  fakes glass), Reduce Motion (the right-pane swap has no fade), Button Shapes, Smart Invert, dark and light.
- Pointer at the largest pointer size and with "Pointer Animations" off.

**Keyboard abuse**
- Every shortcut pressed on every screen in §7.2 (a scripted matrix): none crashes, none acts on a screen behind a
  sheet, none shows in the ⌘ overlay without working.
- Shortcuts during a transition (mid cross-fade, mid sheet presentation, mid rotation).
- International layouts (German, French AZERTY, Japanese with a marked-text composition: Return confirms, never sends).
- Escape hammered 50 times during a stream: exactly one `session.interrupt`.

## 12. Owner to-do

Nothing in this stream needs the relay, a plugin or the real gateway. One App Store fact the owner should know is
written in `docs/owner-todo/ipad.md`: the shipped Hermes HQ app has always been iPhone-only; this build makes it a real
iPad app. That is free for TestFlight. For an App Store release it needs iPad screenshots, and once an iPad version is
released on the App Store, Apple does not let a later version drop the iPad. The app does not depend on the answer.

## 13. Build order (one feature per build, each stress tested before TestFlight)

1. **iPad family + phone layout on iPad** (project files, Info.plist, `RootSplitController` always `.single`, the seam
   with the phone path only, `check-ipad.py`, the popover audit, D12). Ships as: "runs properly on iPad, full screen,
   phone layout". Lowest risk; proves both identities and the upload accept the family.
2. **Two panes** (`PaneLayout`, `.double`, the seam's right-pane path, collapse / expand, readable column, launch
   restore, notifications, selection highlight, placeholder).
3. **Hardware keyboard** (Return rule, Escape ladder, the command table, menu bar). Also reaches iPhone.
4. **Pointer** (hover effects, secondary click, scroll direction).

Each step leaves the tree shippable; the row turns ✅ only after step 4, and stays 🟡 with the reason before that.

New files: `HermesKit/Layout/PaneLayout.swift`, `App/Root/RootSplitController.swift`, `App/Root/PaneRouter.swift`,
`App/Root/DetailPlaceholderViewController.swift`, `App/Root/KeyCommands.swift`, `App/Kit/PointerEffects.swift`,
`Tests/IPad/*`, `UITests/ipad/*`, `scripts/e2e-ipad.sh`, `scripts/check-ipad.py`. Per-stream files:
`docs/briefs/m9/ipad-rows.md`, `docs/briefs/m9/ipad-report.md`, `docs/owner-todo/ipad.md`.

## 14. Risks

1. **The tab bar inside a narrow left pane on iPadOS 26/27.** The system may draw its floating top tab bar or a sidebar
   affordance despite the compact override (§4.3). If neither the trait override nor `mode = .tabBar` gives the bottom
   bar, stop and record it: do not draw a look-alike bar (no fake glass).
2. **Chat relayout cost during live resize** (§4.6): 2,000 rows of exact heights were designed for one width per open.
3. **Merge surface.** The seam touches files every other m9 stream edits (`BotsViewController`, `SessionsViewController`,
   `ChatViewController`, `MainTabController`, `AppModel+Notifications`). Keep the edits to single-line call swaps and
   merge `m9/train` often; `check-ipad.py` catches call sites other streams add later.
4. **Other streams' screens were never run on iPad.** The audit (§7.2) will find breakage that belongs to them; fix
   what is layout, report what is behaviour.
5. **Simulator limits.** Stage Manager dragging and real pointer hover are hard to automate; those checks are by
   screenshot / recording and are named as such in the report. A real iPad was never used: say so in the build notes.
6. **App Store consequence of the iPad family** (§12): fine for the internal TestFlight group, a decision before any
   public release.

## 15. Builder decisions (run m9, written while building)

- DECISION (seam): the routing seam of §4.4 lives in `PaneNavigationController` (the class of every tab stack), which
  overrides `pushViewController` / `setViewControllers`. Every existing push from a tab root lands in the right pane
  in two panes with no call-site change; `openDetail(_:)` exists and is the same thing by name. `ListPaneContent`
  marks drill-downs that stay on the left.
- DECISION (left pane): the left pane is always given the compact width class, so it is the phone's tab controller
  with the bottom glass tab bar at every size.
- DECISION (expand): when a window grows into two panes, only the selected tab's open chat moves to the right pane;
  chats left open on other tabs' stacks are popped at once.
- DECISION (keys): every shortcut is an item in the system menu with its action on the app delegate, so it works
  whatever has focus and shows in the hold-Command overlay. A command that cannot act is disabled.
- DECISION (Escape): the menu item reads "Stop or Close". Command-period does the same (the Mac's other Escape).
  During a recording Escape is the recorder's own Delete (it asks first for a long take).
- DECISION (search keys): Command-F on Bots and Sessions opens the list's folded search through the magnifier's own
  code path (`KeySearchable`).
- DECISION (close after a move): a chat that crossed panes less than a second ago and is then really closed is
  detached at once (`RootSplitController.settleMoves`, `PaneNavigationController.pop…`).
- DECISION (finish pass, device word): text that names the device says "iPad" on an iPad. One value,
  `Shared/DeviceWord.swift` (`DeviceWord.name`, set once at launch), is used by every such sentence; rule (h) of
  `scripts/check-ipad.py` fails the build check on a new literal "iPhone" in app text.
- DECISION (finish pass, menu): one menu item per command. The second key of a command (Control-Tab,
  Control-Shift-Tab, Command-period) is a key command on the app delegate that is not in the menu, so nothing is
  listed twice.
- DECISION (finish pass, Escape repeat): the half-second Escape throttle is gone (it could swallow a real second
  press). Escape and Command-period do not auto-repeat (`repeatBehavior = .nonRepeatable`), and a second "stop" for
  the same chat within 2 seconds is not sent again.
- DECISION (finish pass, keyboard guide): after a chat moves between panes its `keyboardLayoutGuide` can be dead
  (zero size, never updated again; seen on iOS 27 going from two panes to the phone layout with the keyboard up). The
  split controller lowers the keyboard before the move, and after it takes any moved view with a dead guide out of
  its parent and puts it straight back (`RootSplitController.reviveKeyboardGuide`), then gives the field its focus
  back. Public API only.
- DECISION (finish pass, same chat): choosing the row of the chat that is already on show does nothing (no second
  screen is built, nothing is fetched); a screen built and then not shown is detached at once.
- DECISION (finish pass, deleting the open chat): deleting or archiving the chat, bot or job that is on show in the
  right pane empties the pane (the placeholder shows) instead of leaving a dead screen.
- DECISION (finish pass, walking chats on iPhone): Command-Down / Up replace the open chat in place, so one Back
  returns to the list.
- DECISION (finish pass, tests): XCUITest on the iOS 27 simulator delivers a real Return key only for
  `typeKey("\n")` (with Shift, Option and Command too); `XCUIKeyboardKey.return`, `.escape` and `.enter` are not
  delivered as those keys. The UI tests therefore press "\n" for Return and Command-period for Escape, and the plain
  Escape test skips itself when the key does not arrive. "Critical process crashed" issues from XCTest are dropped
  only when this test's own app is still running with the same process id (other agents' apps on the shared Mac
  crash under the same name).
