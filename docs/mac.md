# The Mac app (Oct 23)

Owner asked: "turn our app in to a mac os app".

## What it is

The same app target built with **Mac Catalyst**: the iPad layout (two panes, keyboard shortcuts, pointer hover) in a
Mac window, scaled to Mac size. No separate code base; every iPhone and iPad change reaches the Mac with the next build.

- Same bundle ID as the iPhone app (`DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: NO`), so it can go into the same
  App Store record as a Mac version of the app.
- Sandboxed, as the Mac App Store asks: `App/Identity/HermesHQ-<identity>-mac.entitlements` (network both ways for
  gateways and the Nous loopback catch, camera, microphone, files you pick, Photos, the app's Keychain group; the
  Hermes HQ identity adds push, Communication Notifications and the App Group).
- The window has no title text or toolbar row; the menu bar keeps the app's own commands (File › New Chat, View › tabs,
  Next / Previous Chat, Refresh, Settings… ⌘,) and drops the system's document, Format, toolbar and sidebar items;
  Help is "Hermes HQ Support", the website's support page (`App/Mac/MacWindow.swift`).
- The Mac draws no fade under a clear bar, so a page that leaves its bar to the system (Settings, Bot Profiles,
  Status & Maintenance…) gets a solid bar in its page's colour (`MacWindow.pageBar`, from `PushedPageTitles`' didShow); chats
  keep their clear bar, and the Desktop Look has its own. More's open-page mark is a lighter grey than the Mac's own
  (which is the page colour, so the row looked like a gap). Since stress test #54 every list's mark (sidebar, Bots,
  Sessions, Jobs, Artifacts, Kanban, More) is one rounded box inset in the row, the accent while its pane has the focus
  (the last click landed there) and grey otherwise: `MacSelection`.
- **Sizes** (owner: "Keep the current layout and fix the sizes: no text under about 10 pt, bigger tab labels, a wider
  left column, Kanban using the right side, taller sheets"). The Mac draws the iPad layout at 77 %, so 13 iPad pt is
  10 pt on the Mac's screen:
  - **no text under 10 pt**: caption 1 and 2 are the footnote style on the Mac, and any smaller fixed size is 13
    (`HQFont.legibleStyle` / `HQFont.legible` in `ThemeFonts.swift`, applied in `HQFont.preferred`, `scaled`, `mono`,
    `digits`, `style`, SwiftUI's `Font.hq` / `hqSystem`, the retry capsule and the chat's timer). Sizes that only draw
    a shape (avatar initials, decorations) are left alone;
  - **tab labels** 13 pt (`HQFont.macTabLabel`, set by `MacWindow.tabLabels` on the tab bar's own appearance: the
    item appearance proxy does nothing on the iOS 26 bar);
  - **the tabs are a sidebar** (Oct 25, owner: the bottom capsule was "a crowded row of overlapping touch-style
    pills"; Oct 24 they had turned down the system bar at the top, and after build 195 a bar floating over the list):
    `MacSidebar` runs down the window's leading edge, beside the list and chat panes, in both looks and in one pane or
    two (`RootSplitController.split` takes its strip off first). One row per tab: icon, name, count, a grey fill on
    the open tab and a fainter one under the pointer, a tooltip naming its ⌘ key; a second click on the open tab goes
    back to its root (`DesktopTabBar.select`, shared with the docked bar). It is 160 + 68 × UI Scale wide (228 pt at 100 %, the same in both looks; 2026-10-28 stress
    test #64), its rows 60 pt down; in the iOS look its glass panel starts 40 pt down, 10 under the traffic lights
    (12–30 pt), not round them (owner 2026-11-03: they sat "almost inside that little bubble"), 40 pt rows (about 31 on the screen, Mail's) with 17 pt names, and grows
    with UI Scale. It folds to an icon rail by itself in a window too narrow for it plus a list and chat (#13). `DesktopTabBar.style` is
    `.sidebar` on the Mac: no bar of the app's own, the system bar hidden, no room kept at the list's foot. The
    glass capsule (`.glass`) is still in the code but unused. The window's minimum is the sidebar plus a 375 pt list
    by 600 (`MacWindow.minimumSize`);
  - **text size** (Oct 25, owner: "Everything also feels like it's too small"): an iPad app on the Mac has no text
    size of its own. Every Dynamic Type size draws body at 17 (measured with `-HQDebugMacShots`: the app's, the
    window's and a forced XXL trait collection's body fonts, and `UIFontMetrics`, all 17; a scene trait override and
    a swapped `UIApplication.preferredContentSizeCategory` changed nothing on screen). So on the Mac **UI Scale applies
    in both looks** (`ThemeState.scalesEverywhere`; the iOS look's fonts in `HQFont.preferred`, `HQFont.system`,
    `Font.hq`, `hqSystem` take it). View › Make Text Bigger ⌘+ (and ⌘=), Make Text Smaller ⌘−, Actual Size ⌘0 step
    the presets (90, 100, 110, 125, 150; `MacWindow.changeTextSize`), and Settings › Theme shows the UI Scale picker in
    the iOS look too. Since 2026-11-09 ([density]) the iPhone and iPad do the same, on top of iOS's text size and
    capped at its largest (`HQFont.iosFactor`), beside Theme › Density (Standard or Compact);
  - **Grok Bot's sizes** (Oct 27, owner: "mimic that closely while sticking to our brand", then "Apply Grok's sizes
    on the Mac in both the Desktop Look and the iOS look"): UI Scale starts at **100 %**, and on the Mac 100 % is
    `ThemeState.macBase` × the look's own sizes: × 1.3 in the Desktop Look (its 15 pt body was 11.5 on the screen),
    × 1.15 in the iOS look (17 was 13). Both now draw chat text at 15 pt on the screen like Grok Bot (Electron,
    `/Applications/Grok Bot.app`); faces, list rows and icons grow with it. Mac-only geometry that does not follow
    the text: the chat column is 1280 (`ReadableColumn.maxWidth`, 960 on the screen), replies and their tool rows,
    cards and error cards stop at 728 (560 on the screen, `ChatMetrics.replyMaxWidth`, `TextLayout.replyWidth`) at the
    column's left, your messages reach its right edge (up to 728); body lines are 1.45 × the size (22 pt on the
    screen, `ChatStyle.bodyLineHeight`); bubbles pad 9 / 16; the composer is 44 pt tall on the screen
    (`ChatMetrics.control` 51 Desktop Look / 54 iOS look), 16 pt above the window's foot (`composerBottomDown` 21),
    radius 25. Kept as brand: HQ colours and faces, unboxed Desktop Look replies, timestamps and ⋯ on rows, caps
    section labels, 4 pt Desktop Look radii, iOS bubble tails. Measured on a 1x screen at 1920 × 970 (Grok: 22 pt
    lines, 960 × 44 composer, 58 pt rows, 34 pt faces; HQ Desktop Look: 22, 962 × 45, 60, ~32; iOS look: ~21,
    44 tall). At 100 % the iOS look's list previews wrap to two lines in the 440 pt list pane. Someone who had picked
    another UI Scale keeps that percent, now on the larger base;
  - **the list pane** starts 440 pt wide (375 on the iPad; 320 in a window under 1400 pt, about a laptop's 1000 on the
    screen, with its own remembered width there: stress test #63) and is dragged wider or narrower by the line between the
    panes (it sets the left-right cursor over the line; not checked by eye), from 320 to 640 pt, always leaving the chat 448; the width is kept
    (`HQListPaneWidth`; `RootSplitController`, `PaneLayout.decide(preferred:)`);
  - **a Kanban task opens in the right pane** (`KanbanTaskSheet.page`) with its row marked, as a job does, instead of a
    sheet over the board; Archive or Delete closes the pane (the Undo pill shows over the board), and in one pane it is
    a pushed page;
  - **sheets** (`SheetStyle`) keep the iPad's 620 pt width but are as tall as the window allows (window − 120, up to
    1100), not a fixed 700.
- **Bots rail** (owner 2026-11-02, a mockup of bot heads down the window's edge): with the sidebar folded (its button
  or ⌃⌘S), the Bots list folds into it. The sidebar's top is the bots as heads in the list's order (pinned, each
  section, the rest, a faint line between groups; hidden bots left out; + for New Bot), its foot the other places as
  icons and the fold button, and the chat takes the rest of the window. A head opens its bot's chat as its row does,
  with the same unread dot, working arc, badges and right-click menu; its name shows under the pointer. Picking
  Sessions, Kanban, Jobs or More brings that list back beside the rail; a head folds it away again. The layout is
  `PaneLayout.double(sidebar: 0)` (`RootSplitController.listFolded`): the tab controller stays alive, hidden just
  off the window, so routing, notifications and launch-reopen are unchanged (`App/Mac/MacBotsRail.swift`,
  `MacSidebar.botsChanged`). `-HQDebugMacShots <name> -HQDebugMacShotsRail YES` photographs it.
- **Rail extras** (Mac audit #25, 2026-11-02): the heads are the list's own blocks (`BotsViewController.railSections`:
  tiles and Pinned as one group, each section, the rest, Group Chats and its sub-blocks; Hidden left out), so the
  manual order shows. A bot's head drags to a new place with the open sidebar's drop line: within its block it is
  the tiles' or rows' order (`placeTiles` / `placeRows`, Sort By turns Manual, as in the list); into another block it
  is pinned or filed first (`BotsOrganizer.drop`), by the list's rules (`MacSidebar.railLanding`/`railDrop`). Group
  chats are heads with the group tile's face (`GroupAvatar`), unread dot or running dots on its corner, the room's
  menu on a right click; a click opens the room beside the rail. With more than one gateway the Bots title's switcher
  sits at the rail's top (`MacRailGateway`: the network symbol with a news dot, or the gateway's name and a chevron
  with the names on), and a right click on the rail's empty space offers Gateways ▸ too.
  `-HQDebugMacShotsRailMore YES` (with a second gateway from `HQN_ADD_*`, removed again) photographs both widths.
- **Rail names** (owner 2026-11-02: "some more room on the side ... to fit in the name of each bot underneath"): the
  folded rail's outer edge drags (left-right cursor). Pushed in it is the faces alone (`MacSidebar.compactRailWidth`);
  pulled past halfway the names come at once and, let go, it settles at `namedRailWidth` with each name under its face
  and the foot's places two across with their names. No third width (the sidebar button still opens everything). Kept
  in `HQMacRailNamed`. `-HQDebugMacShotsRailNames YES` photographs faces, mid-drag, names and Sessions beside it.
- It is called **Hermes HQ** on the Mac whichever identity it is built as (owner: "Make sure it's called Hermes HQ"):
  `HQ_DISPLAY_NAME[sdk=macosx*]` names the menu bar (About / Hide / Quit Hermes HQ) and the in-app text, and
  `PRODUCT_NAME[sdk=macosx*]` makes the file `Hermes HQ.app` (Finder, Dock, Activity Monitor). The iPhone names are
  unchanged ("HQ Native" for the native identity). The Swift module stays `HermesHQNative` on both.
- Mac-only code is behind `#if targetEnvironment(macCatalyst)` and marked `[mac]`:
  - the sheets' colour effect (`hqOpaqueGroupedPage`, the API is iOS only) and Quick Look's `canPreview` (iOS only;
    the Mac previews any file);
  - the Mac window and menus;
  - **Return sends** (`ComposerTextView`): the Mac's text system takes Return before `pressesBegan`, so the composer
    also registers Return, Shift-Return and Option-Return as key commands. Return sends; Shift- or Option-Return adds
    a line; Return still ends an input method's composition;
  - **Mac words** (`Shared/DeviceWord.swift`): `name` is "Mac", `system` "macOS", `settingsApp` "System Settings",
    `tap`/`Tap` "click"/"Click", `hold` "Control-click", `reorder` "drag". Every user-facing "iPhone", "iOS", "iOS
    Settings" and "tap" goes through them (accessibility hints and labels keep the system's own words);
  - no **Haptics** switch in Settings (`SettingsSearch.hasHaptics`; the section is "Sounds"): a Mac has nothing that
    taps back;
  - **typing on a bot's screen** (`ScreenKeyField`): a text field there lost Control and Option chords and Escape to
    the Mac's text system (Option-A typed "å", Control-C did nothing) and never matched the named keys' commands, so on
    the Mac the screen's keyboard is a plain view that reads each press, as a VNC client does: a named key by its key
    code, a key with Control, Option or Command as a chord, any other key as its text. A held key repeats at the Mac's
    own delay and rate. The menu bar's shortcuts (⌘Q, ⌘W, ⌘,) still come first;
  - **typing in a bot's browser** (`BrowserKeyField`, still a text field for password AutoFill): Tab and the arrows are
    read in `pressesBegan` (Tab moved focus to the address bar), and the menu's Stop or Close is the page's Escape
    while the field has the keyboard;
  - **scrolling** in Watch Screen and Watch Browser (`ScreenStageView` / `BrowserStageView`): a trackpad or mouse
    wheel brings no touches, so a scroll recognizer turns the bot's wheel (a trackpad by travel, as two fingers; a
    mouse one step per line) or scrolls the page (a zoomed view pans first);
  - the viewers' **gesture hints** say click and hold the button (`ControlWords`).
  - **mouse-only paths** (polish sweep, Oct 24): help text names click, Control-click and Command-R, never hold,
    swipe, pinch or pull down (`DeviceWord.isMac` / `refresh`); every row a swipe deletes also has a right-click
    Delete or, for text-field rows, a red minus (`MacRemoveButton`);
  - **drag and drop** of files and pictures from the Finder onto a chat, and ⌘V of a file copied in the Finder,
    attach it (`AttachmentDrop`; the iPad too). While files are over the chat it dims inside a dashed outline with a
    "Drop to Attach" card and the number of files ("No Room for More Files" with the tray full; a tester
    2026-11-07 asked for drag and drop, not knowing it was there). A file from the Finder reaches the app as its own
    type, not a file URL, so a text type (.txt, .md, .csv, code) counts as a file unless the drag carries a UTF-8 or
    UTF-16 plain-text flavour (a text snippet, `AttachmentDrop.isSnippet`). Dropped on the message field, files and
    pictures attach too (`ComposerTextView`'s text drop delegate; the field used to type a text file's contents in).
    `-HQDebugMacShotsDrop YES` photographs the card; real drags were checked with the tools in
    `hermes-hq-share/2026-11-07-mac-drag-drop/`;
  - **keys**: View › Back ⌘[; ⌘Return saves every editor sheet; ⌘W closes the chat while one is open and the window
    when none is, File › Close Window ⇧⌘W always (owner's call);
  - **selecting part of a message** (Mac audit #11, Nov 2): see "Selecting part of a message" below;
  - **hover**: the Mac draws no pointer effect, so rows get a faint fill of their own under the pointer and small
    round controls a faint round one (`MacHover` in `PointerEffects.swift`);
  - **stall log**: HangWatch pauses while the app's windows are hidden and drops a wait the watch's own timer was
    held back through (App Nap); a resize is a `window.resize` span.
- **Add-ons**: the Hermes HQ identity embeds its notification extension (sealed alerts, bot faces) and its Share
  extension on the Mac too, each with a sandboxed `-mac.entitlements`. Push needs no server change: the
  hermes-hq-push plugin and the relay take any APNs token for the `com.charlesmcdowell.dispatch` topic, and a Mac
  Catalyst token is one of those (Debug builds register as `sandbox`, Release as `production`, as on the iPhone).

## Selecting part of a message

A chat bubble's text is drawn by the app (`TextKitLayout` pieces in `BlockView`s), not a text view, so the selection
is the app's own. F18 built it first (fix/n20-macselect, Mac build 400, never merged); the stress test's simpler drag
(2026-10-28 #3) replaced it on main and lost the selection when a piece redrew, copied the drawing's own marks and
fought the chat's scroll. Mac audit #11 (2026-11-02) rebuilt F18 on today's renderer.

- **Press and drag** across a message's text: the press picks the message and the caret spot under it, the drag moves
  the other end. It runs across the message's blocks (prose, quote, code card, list); a drag past the message runs to
  its start or end. One message at a time (not across messages).
- **Folded replies** (an exchange's or update group's member, `UpdateMemberCell`): its opened words select the same
  way; a click still folds it (or, with a selection, puts it away).
- **The highlight** is the theme's tint under a reply (as iOS's own selection), white at 35 % under your own bubble.
  It is kept per piece, so it survives a piece being redrawn or scrolled off and back (not the row being reused).
- **⌘C** (Edit › Copy) and **right-click › Copy** copy plain words: a link as its words, a code span or formula selected
  whole as what a click on it copies (the code, the TeX source), a part of one as drawn without the word joiners and
  narrow spaces the drawing adds; a table's cells with tabs, its rows with line breaks, blocks with a blank line.
  Right-click elsewhere in the message keeps its own menu under Copy. A press on the selection drags it out.
- **⌘A** selects the whole message once it has a selection or was clicked (a click on its text makes it the one).
- **A click anywhere else** in the window puts it away (on a message, that click does nothing else).
- **Left alone**: a trackpad or wheel scroll (no touches: the chat scrolls), a drag that starts off the text (scrolls),
  a drag in a code card or table that scrolls sideways (scrolls it; those can't be drag-selected), a click (links,
  one-click copy of code, a table's page), hover.
- **The keyboard rule**: the selection never takes the keyboard from a text field. With the composer focused it stays
  there and ⌘C comes up its responder chain to `ChatViewController.copy`; with nothing focused the message's cell takes
  it, so ⌘C and ⌘A reach it.
- **Not done**: double- and triple-click (word, paragraph), Shift-click to extend, auto-scroll past the window's edge,
  selecting across messages.
- **DECISION (F18, kept): the Mac only.** iPhone and iPad are unchanged: on the iPad a pointer's press reaches the app
  as a finger's (no `UIApplicationSupportsIndirectInputEvents`), so a drag on a bubble can't be told from a scroll.
- Code: `App/Chat/Render/MessageSelection.swift` (the pure rules), `App/Chat/Cells/ChatTextSelection.swift` (the drag,
  Copy, Select All, the click away, the chat scroll's guard), hooks in `BlockView` (`ChatTextViews.swift`),
  `ChatBubbleCell`, `UpdateMemberCell` and `ChatTableView`.
- Check: `-HQDebugMacShots <name> -HQDebugMacShotsSelect YES` (signed in to the stand-in) selects part of the first
  bot's biggest reply through the drag's own code, then ⌘C, ⌘A, a click away, the composer case, your own bubble and an
  opened folded reply, and writes each picture and `<name>-select.txt` (selected words, first responder, pasteboard).

## Sidebar light pass (Nov 3)

Owner: "I do not like the circle over the bots… a box shadow behind the bots… how Slack does it"; the sidebar icons
"don't feel like they're sized properly"; in light mode "it's all white behind" the sidebar.

- **Open bot = a tile** (`MacRailHead.tile`): a rounded square (radius 10) 8 pt wider than the face, black 9 % in light,
  white 14 % in dark; hover is a fainter one. Replaces the ring of build 708.
- **Icon study** (`-HQDebugIconInk` writes each place's ink box to `<name>-icons.txt`): at one point size Sessions
  drew 31×25 pt of ink and Kanban's frame 25.6 pt with a heavier line, beside Jobs at 26×23. `MacSidebar.rowIcon`
  now draws Sessions at 0.88, Tiles at 0.9, Kanban at 0.9 size with the bot icon's 0.07 line, so every icon's ink is
  about 22–23 pt tall folded.
- **Strip behind the panel**: it was always the list colour (white), so beside a grey page (Settings) the panel sat on
  a white band. Outside the Desktop Look the strip now takes the colour of the page beside it (one pixel sampled past
  its edge, redone when a pane lays out: `MacSidebar.neighbourMayChange`), and the glass gets a tint a few percent
  toward the text colour plus a hairline edge so it reads as a floating panel in light and dark.

## Layout pass (Nov 3, branch feat/mac-layout)

Owner, after the layout study (docs/studies/2026-11-03-mac-layout.md): "Yes I like the bots in the sidebar" / no
Activity place / "I'd like to see it all built". Mac only; the iPhone and iPad keep their layout.

- **Sidebar**: Search (⌘K) and New Chat at the top, then the places, then **Tools** (`MacSidebar.addTools`), then the
  bots in their folding groups (`MacSidebarHeading`, folds kept in `HQMacSidebarFoldedGroups`). No Bots list column:
  `RootSplitController.listFolded` is true while Bots is on show, open or folded.
- **Tools** = More's Workspace and Insights pages (`PagesTabs.toolSections`, `toolIDs`, `isTool`). Each is a page tab
  as one added from More is; `MainTabController.setViewControllers` places them after the Settings › Tabs places.
  A tool's menu has Move to Places. Folded, Tools is one button whose menu clicks the hidden rows.
- **More** has no sidebar row. It stays placed out of sight: ⌘K (Open Quickly) opens its results from More's stack.
  Its setup pages (Bot Profiles, Messaging, Webhooks, Import Sessions) are rows in the Settings window
  (`SettingsRootView.movedFromMore`, only with `model.ownWindow`).
- **Chat toolbar**: the face and name (and a status line: the owner subtitle, Working… or the model) sit in a leading
  bar item (`ChatViewController.putTitleInBar`); ⋯ and ◨ (inspector) on the right.
- **Inspector** (`MacInspector`, ⌘I, ◨): 340 pt at the trailing edge, carved off in `RootSplitController.split()`.
  Tabs Info, Steps (the thinking row and ⋯ › Steps open it), Files (the chat's folder), Helpers
  (`HelpersPanelController`, fed by `ChatActivityController.updateHelpersPanel`; the open helper's tail is polled
  while the tab shows).
- **Settings window** (`MacSettingsWindow`, ⌘, and ⌘W): a scene of its own (configuration "Settings"), about
  600×640 on the screen (Polish pass), themed. Info.plist is preprocessed so only the Mac build supports multiple scenes (`HQ_MAC_WINDOWS`). Its list's
  soft top edge shows only once rows scroll under the bar: SwiftUI re-shows a list's edge on every update, so the
  list hides it itself (`SoftEdgeOnlyScrolled`: `onScrollGeometryChange` + `scrollEdgeEffectHidden`).
- **No pull-to-refresh** on the Mac (`hqInstallRefresh` keeps the control for ⌘R only). Swipe rows kept (Mail has them).
- Checks: `-HQDemoRealChat YES` (a real chat in the lists demo), `-HQDemoHelpers YES` (three pretend helpers),
  `-HQDemoHelperOpen <id>`, `-HQMacInspectorShown YES -HQMacInspectorTab 0…3`, `-HQDebugSettingsWindow <name>`.
  Theme for shots with argument-domain keys only (`-hqn.theme.skin`, `-hqn.appearance`); the `-HQDebug*` theme hooks
  save to the stored theme.

## Polish pass (Nov 7, branch fix/mac-polish)

A 145-item audit of the Mac app (report and pictures: `~/Projects/hermes-hq-share/2026-11-06-mac-polish/`), all
fixed on the owner's "yes to all, go". Commits end "(Mac polish #N)". What changed for someone using the Mac:

- **Keys**: Escape skips a bot's question card (View › Skip Question), closes the open model panel before it stops a
  reply, and stops a group chat's bots. ⌘1 to ⌘9 skip More, so ⌘9 is the last Tool. ⌘F opens the search on Tasks,
  Artifacts, Tiles, Jobs, Kanban and Settings, and is dimmed where a page has no search. ⌘R reloads a plugin page.
  Escape and ⌘[ on a page with unsaved changes ask "Discard Changes?" as Back does. The @ list in a group chat takes
  ↑/↓, Tab, Return and Escape. After Escape closes the ☰ Commands or Models pop-over the caret is back in the message
  field. Typing in ☰ Commands puts names that start with what you typed first. ⌘Return sets a date in Choose Date.
- **Settings window**: opens at about 600 × 640 points on the screen (the old 780 × 830 was in the app's points, so
  it opened too big) and always inside the visible screen, never under the Dock (`WindowFit`,
  `MacSettingsWindow.visibleScreen`). With it in front the keys work it, not the main window: Escape, ⌘[, ⌘F, ⌘R and
  ⌘Return act on its page, ⌘W reads Close Window, and the main window's commands are dimmed. Its pages have the
  main window's solid bar. Questions and sheets started there (Remove Key, an add-on update, the Nous sign-in) open
  over it, and Voice Settings…, Fix… and Manage Gateways… open their page in it. ⌘, stays lit over an alert. The
  sidebar's Settings… opens it at Sidebar (Settings › Tabs is called Sidebar on the Mac).
- **Closing and reopening the window**: after the main window is closed and opened again from the Dock, @ mentions,
  group chats, More's rows and the Voice shortcut keep working, and the Dock's New Chat brings a window back while
  only Settings is open.
- **Sidebar**: **Marketplace is listed under Tools**, with a row under it for each page the bots' plugins add (shown
  only when there are such pages; ⌘K still finds them). In a short window Search and the bots keep their room and
  the places scroll below them; both lists fade at the top as at the foot. Names line up and never shrink under the
  Mac's smallest text. A right click on empty sidebar offers the bots' Sort By and Group By; Group By › None has no
  Bots heading. A group chat has Move to Section and drags into a section. Add to Sidebar no longer offers Settings
  or the Tools. Changes uses the +/− icon everywhere and Star Map a star, each with its own tap motion.
- **Page titles**: Tasks and Tiles have the same small centred title as the other Tools; Sessions, Jobs and
  Artifacts keep the big heading.
- **Right pane**: when the bots can't load (or there are none) it says why, with Try Again. Beside the Tools it stays
  blank; beside Settings' list pages it says Nothing Selected; beside Tiles, No Tile Open. The open task stays marked
  in the Tasks list. The inspector no longer flips the window between one and two panes in a laptop-size window.
- **Inspector**: the Info tab's labels and the gateway address stay on one line; the Desktop Look's tabs are its
  squared strip. The Chat menu's ⌘I item reads Show Inspector or Hide Inspector. Where the inspector has no room beside two panes
  (a laptop-size window beside Sessions), ⌘I folds the list away for it and ⌘I again brings the list back (owner,
  Nov 7).
- **Notices** under a chat's bar (the voice banner, "Switching to …") sit on a page-coloured backing that fades out
  below them, so no half-covered line shows beside them. **Mixture of Agents** adds and removes models with + and −
  under the list, as Fallback Models does. **Marketplace's** featured picture shows whole (owner, Nov 7).
- **Settings from the window** (owner, Nov 7 evening: "I don't see where I can access More or Settings"): a gear at
  the sidebar's foot (beside the +; above the toggle when folded) opens the Settings window, where More's setup pages
  are (Bots & Tools). **Usage** is one of the Tools again. The Update Add-on and Update Hermes sheets are the other
  sheets' size on the Mac, so their steps fit.
- **Owner, Nov 8:** the sidebar's New Chat and Search send to the app (after a click in the sidebar nothing held the keys
  and they did nothing); **Settings opens in the main window** again (More's list left, Settings right) from the gear,
  ⌘, and every link, not a window of its own; **a table opens in the chat's pane** as an outlined card at its own widths,
  with Back (the sheet sized to the table moved a laptop's window); **the message bar is one rounded, bordered box** in
  the iOS look too (plain ☰ + mic, an accent send/talk circle; no glass), the Desktop Look's shape in the look's colours.
- **Controls drawn the Mac way**: bar buttons are plain from the start (no glass pill); sheets close with a word
  (Done, Not Now, Hide) instead of an ✕ in a circle; Edit… and Choose… stand in one column; times and dates sit in a
  bordered box; empty-state buttons are push buttons; file rows have no ›, only folders do; Kanban's Board pop-up is a
  short filled box; hover lights only rows you can click.
- **Words**: click, Control-click, System Settings, macOS and "this Mac" instead of tap, swipe, Settings, iOS and
  "your phone"; Open Settings for a refused permission opens that page of System Settings. Menu items that ask
  something end in "…". Files names .env, .key, .log and .sh files in words.
- **Other**: spinners, Spawn Tree and a connector's log keep going while another app is in front; Open Quickly shows
  each chat's and bot's face; Files and Changes drag, save and open files up to 512 MB (iPhone and iPad keep 32 MB);
  a bot can ask where you are while the window is behind another app; the Terminal has no blue focus ring.

## Build and run

```
scripts/build-mac.sh run            # Debug, opens the app
scripts/build-mac.sh build Release
HQ_IDENTITY=original scripts/build-mac.sh run    # the Hermes HQ record's app, with push and Share
```

The app lands in `build/dd-mac/Build/Products/<config>-maccatalyst/Hermes HQ.app` (`build/dd-mac-original/…` for the
Hermes HQ identity). Signing uses the team's development certificate and Mac Catalyst development profiles (one per
bundle: app, `.notifications`, `.share`), which the Keychain and push need (without one, every saved sign-in fails).
The script passes the App Store Connect key from `~/.appstoreconnect/dispatch.env` so Xcode can make the profiles.
This Mac Studio was registered as a development device on Oct 23 for that.

In Debug, `HQN_SIGNIN_URL` / `HQN_SIGNIN_USERNAME` / `HQN_SIGNIN_PASSWORD` in the shell sign a signed-out app in by
itself, as on the simulator (the script hands them over with `open --env`).

## Shipping

`HQ_PLATFORM=mac` in `scripts/ship.py` makes the Mac build:

```
HQ_IDENTITY=original HQ_PLATFORM=mac BUILD=N scripts/ship.py archive   # .build/HQOriginal-mac-N.xcarchive
HQ_IDENTITY=original HQ_PLATFORM=mac BUILD=N scripts/ship.py export    # a Mac App Store .pkg in .build/Export-mac-N
```

The archive checks every bundle is the iPad family (the only one a Mac Catalyst bundle has). Export signs
automatically: Xcode makes the Mac App Store profiles for the three bundles and picks the installer certificate the
.pkg needs, with the App Store Connect key (the iPhone's manual profiles are iOS only). `upload` sends it the same way
as the iPhone build, but the App Store record needs its **macOS platform added** first, and that, like every upload,
waits for the owner.

### The website's download

Owner, Oct 23: "i need people to be able to download and use this. then i need it on our website." They chose a
download button over TestFlight for the Mac, so the Mac app is a signed, notarized disk image on gethermeshq.com:

```
HQ_IDENTITY=original HQ_PLATFORM=mac BUILD=N scripts/ship.py archive
HQ_IDENTITY=original HQ_PLATFORM=mac BUILD=N scripts/ship.py dmg       # .build/Hermes-HQ-N.dmg
```

`dmg` exports the archive for Developer ID with manual signing (Xcode's automatic signing wants cloud-managed
certificates, which the App Store Connect key may not use): `scripts/prepare-mac-direct.mjs` makes the three bundles'
Mac Catalyst Developer ID profiles through the App Store Connect API for the Developer ID Application certificate in
the login keychain. Those profiles end with the certificate (Feb 1, 2027); make a new download with a renewed
certificate before then. It then puts the app in a disk image next to an Applications link, signs the image,
notarizes it with the same key, staples the ticket and checks it with Gatekeeper. The Mac builds turn on the hardened runtime (`ENABLE_HARDENED_RUNTIME[sdk=macosx*]`), which notarization
needs. Push works as in the App Store build (production APNs).

The site is the web app's repository (`~/Projects/hermes-ios`, `site/`, see its `site/README.md`). Since build 411 the
image (33 MB with GPT-Live's WebRTC) is over the 25 MiB Cloudflare allows a static file, so it lives in the R2 bucket
`hermes-hq-downloads` and the site's Worker (`site/src/worker.js`) serves it at the same
`gethermeshq.com/download/Hermes-HQ.dmg`. Upload it with `npx wrangler@latest r2 object put
hermes-hq-downloads/Hermes-HQ.dmg --file .build/Hermes-HQ-N.dmg --content-type application/x-apple-diskimage --remote`
(from `site/`), copy `.build/appcast-N.xml` to `site/public/download/appcast.xml`, update the size in `index.html`'s Mac
section, then deploy from `site/` with `npx wrangler@latest deploy` right after the upload. Write the build's notes
(`docs/releases/build-N-mac.txt`) before `dmg`: their first part is what the update window shows.

### Updates

Owner, Oct 23: "automatic updates need to be built in - the user needs to be prompted to update." The download keeps
itself up to date with [Sparkle](https://sparkle-project.org) 2.10.0 (`App/Mac/MacUpdater.swift`):

- It checks `gethermeshq.com/download/appcast.xml` when it starts and once a day while it runs, and on Hermes HQ ›
  Check for Updates… (an item only the download has; Show Update… while one is under way). A newer build brings up the
  app's own update sheet (`App/Mac/MacAppUpdate.swift`, [mac-update], owner 2026-11-10: Sparkle's stock windows let the
  update "fall off" out of sight): the versions, the size, What's New as a list, and Skip This Version / Later /
  Update Now. Update Now shows each step as it happens: Download (MB, speed, time left, one bar for the whole update),
  Check and Unpack, Install, Reopen Hermes HQ. The sheet can be hidden meanwhile (the Dock icon shows the percent) and
  comes back for a 5-second "Restarting in…" countdown with Restart Now and Later (installs when you quit). Before it
  quits the app leaves a note (`MacAppUpdateRecord`), so the copy that opens says "Updated to 1.0.2 (925)" with what's
  new, or "The Update Didn't Finish" with Try Again. Failures say what happened in plain words, with Try Again, Copy
  Details and, where it helps, Open Website. A daily check's find waits until the app is in front with no other sheet
  up. Pictures of each state: `-HQDebugMacUpdateShot <state>` (`MacUpdater.start`).
- Only the download has Sparkle; the Mac App Store refuses apps that update themselves. `ship.py dmg` adds it to the
  exported app (Contents/Frameworks/Sparkle.framework; `SUFeedURL`, `SUPublicEDKey`,
  `SUEnableInstallerLauncherService` and `SUEnableAutomaticChecks` in Info.plist; the sandbox's lookups of Sparkle's
  installer, `<bundle id>-spks` and `-spki`) and signs it again, inside out. In the App Store build `MacUpdater` finds
  no feed and does nothing.
- Sparkle is an AppKit framework, which a Mac Catalyst target can't link, so the app loads it when it starts and
  drives `SPUUpdater` through the Objective-C runtime, with the app's own user driver (`MacUpdateDriver`, which
  answers SPUUserDriver's calls) in place of Sparkle's AppKit windows. The feed's notes are plain text: the part of
  `docs/releases/build-N-mac.txt` above a line of `---`, each "- " line kept a line of its own (the sheet also splits
  the older run-in feeds). A copy before this change still shows Sparkle's stock window for its next update.
- Every update is signed with an Ed25519 key, `~/.appstoreconnect/hermes-hq-sparkle.key` (made Oct 23; the public half
  is `UPDATE_PUBLIC_KEY` in `ship.py` and is in every download). Sparkle takes an update only when the image's
  signature checks out against that key and the new app carries the same key. **Keep a copy of the key file somewhere
  safe**: without it, no copy in use can take another update, and everyone would have to download again by hand.
- Build 351 came before the updater: a copy of 351 needs downloading again once.

## Checked (Oct 23)

Against the desktoplook fixture: signed in, Bots list and chat in two panes, sent a message and got the reply,
Sessions, More › Settings from the menu, Release build (Apple silicon and Intel), both identities' iPhone builds.
Return / Shift-Return / Option-Return with a real key press. The Hermes HQ identity signed with both add-ons embedded
and registered with macOS (`pluginkit`). `HQ_PLATFORM=mac ship.py archive` (build 349, local only): Apple silicon and
Intel, both add-ons, every bundle the iPad family. Settings › Notifications › Open Settings opens System Settings.

**Push, end to end** (Hermes HQ identity, Debug): the app registered its token (sandbox, sealed) with a push gateway
fixture; one sealed `turnDone` alert sent through APNs with the push plugin's own sender was accepted, delivered to
the Mac, unsealed by the notification extension inside its sandbox (a message notification with the bot's face) and
presented by Notification Center. While the screen is shared, macOS mutes the banner and files the alert in
Notification Center only.

**Watch Screen** (screen fixture, real key presses, inputs read back from the fixture): letters, capitals, "!", space,
Control-C / Control-A, Option-A, Command-A, Left, Command-Shift-Left, Escape, Tab, Return, Backspace,
Option-Backspace; a held Left repeats (19 in 2 s); the key bar's Ctrl then Tab (either key) sends Control-Tab and ⌥ then
A sends Option-A; mouse-wheel scrolls turn the bot's wheel both ways. **Watch Browser** (browser fixture): typing, Return, Backspace, Tab (focus stays), the
arrows, View › Stop or Close as Escape, and wheel scrolls reach the page. Escape in the composer leaves the field.

**The download** (build 351, Oct 23): notarized and stapled; downloaded back from gethermeshq.com with the quarantine
flag set, Gatekeeper accepts the image and the app as "Notarized Developer ID". Universal (Apple silicon and Intel),
macOS 26 or later, 21 MB. Launched from the image, it found the saved sign-in, sent a message and got the reply, and
got a production APNs token (registering it with a real gateway's push add-on wasn't tried; the demo gateway has none).
A fresh sign-in on another Mac wasn't tried.

**Updates** (build 352, Oct 23): Sparkle loads in the Mac Catalyst app (checked in its memory map) and checked the feed
by itself about two seconds after its first launch. A copy of the shipped 352 labeled 351 (Developer ID, sandboxed)
showed the update window with the notes from Hermes HQ › Check for Updates…. Install downloaded the notarized 352
image, checked its signature, quit the app, replaced it and reopened it in about 25 s, once from a local feed and once
from gethermeshq.com itself. The result was the shipped 352 binary, accepted by Gatekeeper as "Notarized Developer ID",
and on it Check for Updates… says "You're up to date!". An update whose app lacks the update key (the 351 image
offered to a Debug build) is refused with "The update is improperly signed". Not tried: the daily check on a copy
left open for a day, and "Automatically download and install updates in the future".

**Sizes** (Debug, demo gateway, 1280 × 800 window, Oct 23): tab labels measured 26 % wider ("Sessions" 34 → 43 px,
about 10 pt); the list pane 340 px (440 pt) at first, dragged to 412 px, saved as 535 pt and back at that width after
a relaunch; a Kanban task opened in the right pane with its row marked, a second task replaced it, Archive closed the
pane with the Undo pill on one line over the board ("Archived tasks are on the desktop board." had folded into four
short lines: the row's own text rule held the words to half its width, which would fold it on the iPhone too; seen
on the Mac only; `UndoPill.wrapLines`), and
shrinking the window to one pane made the open task a pushed page and widening it put the task back on the right.
Delete's confirmation showed in the pane (the demo gateway refuses deletes, so only its error alert was seen). New Task
filled the window's height (750 of 800 px; 539 before). Bots, Sessions, Jobs, More and Kanban rows: nothing clipped.
Unit tests on an iPhone simulator: all pass (3438; on an iPad simulator ten wording tests expect "iPhone" and fail
there, as before). `scripts/build-mac.sh` runs xcodegen, so `HQ_IDENTITY=original` rewrites the project for that
identity: a test run built at the same time names the app "Hermes HQ" and the slash test that expects "HQ Native"
fails. Run `xcodegen generate` (no identity) before testing again. Shipped as Mac download 354 (Oct 23): a copy of 353 was
offered it by Check for Updates… and updated itself in about 27 s.

## Not done yet

- **Share menu**: macOS keeps a newly installed app's Share extension off until it is turned on in System Settings ›
  General › Login Items & Extensions › Sharing, so "Hermes HQ" isn't in Share menus at first. Not tried once on.
- **Notification prompt**: macOS asks with a banner that goes away after about 8 minutes. One left unanswered that
  long counted as a refusal here (Settings › Notifications then shows "Notifications are off" and Open Settings).
  Switching Hermes HQ on in System Settings › Notifications then works: the app registers for push the next time it
  comes to the front or Settings › Notifications opens.

- **Look**: it is the iPad layout scaled (77%), with the size fixes above. "Optimize for Mac" (native Mac controls and
  text at 100%) was tried on Oct 23 and set aside by the owner: it would need every fixed size and iPad check revisited.
  Oct 25 decision (brief mac-native-proper): stay on the iPad idiom at 77 % and make the Mac larger with UI Scale at
  110 % instead (Oct 27: a per-look Mac base under a 100 % UI Scale, Grok Bot's sizes, see Sizes). That is one number that reaches every screen through the font factory and the scaled lengths, with the
  same rows and checks as the iPhone's larger text sizes, while "Optimize for Mac" would redraw every control (switches,
  steppers, segmented controls, bars) and drop the iPad's sheet and popover sizes the screens are laid out for.
- **Debug builds keep their own sign-in** (Oct 25, owner: "the desktop app logs me out every time I update it"): a
  Mac app's Keychain group and data folder belong to its bundle ID, so a Debug build of the Hermes HQ identity used
  the download's own sign-in. A fixture sign-in replaced the owner's account and `-HQDebugResetAccounts` deleted it.
  Mac Debug builds now save under `<service>.debug` / `<signed-out key>.debug` (`project.yml`), and the reset hook
  refuses on a Mac build that shares the download's bundle ID (`DebugHooks`). The data folder is still shared (a
  separate Debug bundle ID needs a new App ID and profile: `docs/owner-todo/mac-signin.md`).
- **Keys the Mac keeps**: Control-Tab and Control-Shift-Tab never reach the window, so Watch Screen can't send them
  from the keyboard (the key bar's Ctrl, then Tab, does). In Watch Browser, Escape and ⌘. while typing go to the Mac's
  text system, which asks the field nothing; View › Stop or Close sends Escape. A held arrow there sends one press.
- **Pinch** brings no touches on the Mac, so neither viewer zooms with a trackpad pinch (the window can be made larger).
  Trackpad scrolling goes through the same recognizer as the mouse wheel but was only tried with a wheel.
