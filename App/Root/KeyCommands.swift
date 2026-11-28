// [m9/ipad] Hardware keyboard shortcuts (docs/spec/3x-ipad.md §4.10). Every command is in the system's menu (iPadOS
// shows the menu bar and the hold-⌘ overlay from it) and its action lives on the app delegate, the end of every
// responder chain, so a shortcut works whatever has focus. A command that cannot act right now is disabled by
// `validate`, never left dead; while a sheet is up only Escape acts (it closes the sheet).
//
// Return in the message field is `ComposerTextView.pressesBegan` (the rule is `ReturnKey`), Escape's ladder is
// `EscapeAction`, Next / Previous Chat's order is `ChatWalk` (all three: HermesKit/Layout/KeyRules.swift).

import UIKit

/// A list whose search field stays folded until its magnifier opens it.
@MainActor protocol KeySearchable { func openSearchFromKeyboard() }

extension BotsViewController: KeySearchable {}
extension SessionsViewController: KeySearchable {}
extension MoreViewController: KeySearchable {}

@MainActor enum KeyCommands {
    static let newChat = #selector(AppDelegate.hqNewChat(_:))
    static let newChatWith = #selector(AppDelegate.hqNewChatWith(_:))   // [cmd-n] ⇧⌘N: the bot and project chooser
    static let newChatHere = #selector(AppDelegate.hqNewChatHere(_:))   // [cmd-n] ⌥⌘N: the open chat's bot and project
    static let closeChat = #selector(AppDelegate.hqCloseChat(_:))
    static let find = #selector(AppDelegate.hqFind(_:))
    static let searchSessions = #selector(AppDelegate.hqSearchSessions(_:))
    static let nextChat = #selector(AppDelegate.hqNextChat(_:))
    static let previousChat = #selector(AppDelegate.hqPreviousChat(_:))
    static let selectTab = #selector(AppDelegate.hqSelectTab(_:))
    static let settings = #selector(AppDelegate.hqSettings(_:))
    static let refresh = #selector(AppDelegate.hqRefresh(_:))
    static let escape = #selector(AppDelegate.hqEscape(_:))
    static let send = #selector(AppDelegate.hqSend(_:))
    static let messageActions = #selector(AppDelegate.hqMessageActions(_:))   // [transcript] L366
    static let back = #selector(AppDelegate.hqBack(_:))
    static let closeWindow = #selector(AppDelegate.hqCloseWindow(_:))   // [mac]
    // [mac] Stress test 2026-10-28: More's search (sessions, pages, actions) from anywhere, the caret into the message
    // field, and Archive as Messages' ⌘⌫.
    static let openQuickly = #selector(AppDelegate.hqOpenQuickly(_:))
    /// [quick-actions] DECISION I22: the Quick Actions page as a sheet (⇧⌘K, beside Open Quickly's ⌘K).
    static let quickActions = #selector(AppDelegate.hqQuickActions(_:))
    static let messageField = #selector(AppDelegate.hqMessageField(_:))
    static let archiveChat = #selector(AppDelegate.hqArchiveChat(_:))
    /// [mac] Tester 2026-11-09: "Cmd+Delete currently archives the conversation. On Mac this shortcut usually means
    /// delete, so I keep archiving chats by accident." On the Mac ⌘⌫ is Delete Chat… (it asks first, as Messages'
    /// does) and Archive is Mail's ⌃⌘A; an iPad's keyboard keeps ⌘⌫ for Archive.
    static let deleteChat = #selector(AppDelegate.hqDeleteChat(_:))

    private static func command(_ title: String, _ action: Selector, _ input: String, _ flags: UIKeyModifierFlags,
                                list: Any? = nil) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags, propertyList: list)
        command.discoverabilityTitle = title
        return command
    }

    /// The tabs' default names; `validate` puts the current ones in (Kanban or Artifacts follows the gateway).
    /// [mac-sidebar] The Mac's sidebar can list more than five places: ⌘1…⌘9 there, an item for a number with no row
    /// hidden.
    #if targetEnvironment(macCatalyst)
    static let tabTitles = ["Bots", "Sessions", "Jobs", "Artifacts", "More", "Tab 6", "Tab 7", "Tab 8", "Tab 9"]
    #else
    static let tabTitles = ["Bots", "Sessions", "Jobs", "Artifacts", "More"]
    #endif

    /// The place ⌘(n + 1) picks among the places with these tab tags (`MainTabController.placedTabs`): the nth, and
    /// with more than nine places ⌘9 picks the last, as ⌘9 picks Safari's last tab. [mac] Mac polish #18: More, which
    /// has no row in the sidebar, takes no number (`TabShortcut`).
    static func tabIndex(forShortcut index: Int, among tags: [Int]) -> Int? {
        if index >= otherPlaceBase {
            let others = TabShortcut.unnumbered(keys: tabTitles.count, tags: tags, numbersMore: !DeviceWord.isMac)
            return others.indices.contains(index - otherPlaceBase) ? others[index - otherPlaceBase] : nil
        }
        return TabShortcut.place(forShortcut: index, keys: tabTitles.count, tags: tags, numbersMore: !DeviceWord.isMac)
    }

    /// [macpass-sidebar] View's items for the places past ⌘9 (Kanban, Usage, Spawn Tree… under a long Tools group had
    /// no menu item): the same Select Tab action with no key, their `propertyList` this base plus the place's turn among
    /// the unnumbered ones. Named at validation as the numbered ones are; a slot with no place stays hidden.
    static let otherPlaceBase = 100
    #if targetEnvironment(macCatalyst)
    static let otherPlaceSlots = 32
    #else
    static let otherPlaceSlots = 0
    #endif

    /// The number whose ⌘ key picks the place at `index`, if one does (the sidebar's tooltips).
    static func shortcut(forTab index: Int, among tags: [Int]) -> Int? {
        (0..<tabTitles.count).first { tabIndex(forShortcut: $0, among: tags) == index }.map { $0 + 1 }
    }

    static func fileItems() -> [UIMenuElement] {
        #if targetEnvironment(macCatalyst)
        // [mac] Owner's call (polish sweep 2026-10-24): ⌘W closes the chat while one is open and the window when none
        // is (the item then reads Close Window); ⇧⌘W always closes the window, as in Safari.
        // [Mac AAA 2026-11-16] Three groups with a line between, as a Mac app's File menu has (New…, Close…, then what
        // acts on the chat itself): the seven items ran as one block. Same items, same order, same keys.
        [UIMenu(title: "", options: .displayInline, children: [
            command("New Chat", newChat, "n", .command), command("New Chat Here", newChatHere, "n", [.command, .alternate]),
            command("New Chat With…", newChatWith, "n", [.command, .shift])]),
         UIMenu(title: "", options: .displayInline, children: [
            command("Close Chat", closeChat, "w", .command), command("Close Window", closeWindow, "w", [.command, .shift])]),
         // [Mac AAA 2026-11-17] Owner's call Q9 ("one go-to"): Delete Chat… (⌘⌫) is the Chat menu's alone now
         // (`deleteItem`); File keeps Archive.
         UIMenu(title: "", options: .displayInline, children: [command("Archive Chat", archiveChat, "a", [.command, .control])])]
        #else
        [command("New Chat", newChat, "n", .command), command("New Chat Here", newChatHere, "n", [.command, .alternate]),
         command("New Chat With…", newChatWith, "n", [.command, .shift]),
         command("Close Chat", closeChat, "w", .command), command("Archive Chat", archiveChat, UIKeyCommand.inputDelete, .command)]
        #endif
    }

    static func editItems() -> [UIMenuElement] {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #15: every Mac app's Find Next / Find Previous step through the chat's matches
        // as the Find bar's ↓ and ↑ do.
        let steps = [command("Find Next", findNext, "g", .command), command("Find Previous", findPrevious, "g", [.command, .shift])]
        #else
        let steps: [UIKeyCommand] = []
        #endif
        #if targetEnvironment(macCatalyst)
        // [mac-audit K] Owner 2026-11-02: Send, Message Actions and Go to Message Field act on the chat; they are in the
        // Chat menu (`chatItems`), not Edit.
        // [Mac AAA 2026-11-16] "Find…" as in Safari, Mail and Notes (it opens a bar to type in), and the in-page Find
        // steps apart from the two searches of the whole app by a line.
        return [UIMenu(title: "", options: .displayInline, children: [command("Find…", find, "f", .command)] + steps),
                UIMenu(title: "", options: .displayInline, children: [
                    command("Search Sessions", searchSessions, "f", [.command, .shift]),
                    command("Open Quickly…", openQuickly, "k", .command),
                    command(IntentsText.quickActions + "…", quickActions, "k", [.command, .shift])])]
        #else
        return [command("Find", find, "f", .command)] + steps + [
         command("Search Sessions", searchSessions, "f", [.command, .shift]),
         command("Open Quickly…", openQuickly, "k", .command),
         command(IntentsText.quickActions + "…", quickActions, "k", [.command, .shift])] + chatItems()
        #endif
    }

    /// The message field's keys: in Edit on the iPad, at the top of the Chat menu on the Mac (`ChatMenuBar.menu`).
    static func chatItems() -> [UIKeyCommand] {
        var items = [command("Go to Message Field", messageField, "l", .command),
                     command("Send", send, "\r", .command),
                     // [transcript] The web's menu key: the newest message's hold menu as a list.
                     command("Message Actions", messageActions, "\r", .control)]
        #if targetEnvironment(macCatalyst)
        // [Mac AAA 2026-11-17] Owner's call Q7: Stop Reply (Escape) acts on the chat: beside Send at the top of the Chat
        // menu, no longer in View. Same key; still named for Escape's step now (`escapeTitle`).
        items.insert(stopItem(), at: 2)
        #endif
        return items
    }

    /// Escape's item: View's on the iPad, the Chat menu's on the Mac (`chatItems`).
    static func stopItem() -> UIKeyCommand {
        #if targetEnvironment(macCatalyst)
        // [mac-audit K] Owner 2026-11-02: "Stop or Close" named nothing; the item says what Escape does now (`escapeTitle`).
        let stop = command("Stop Reply", escape, UIKeyCommand.inputEscape, [])
        #else
        let stop = command("Stop or Close", escape, UIKeyCommand.inputEscape, [])
        #endif
        stop.repeatBehavior = .nonRepeatable   // a held key takes one step of the ladder, not a run of them
        return stop
    }

    #if targetEnvironment(macCatalyst)
    /// [Mac AAA 2026-11-17] Owner's call Q9: the Chat menu's Delete Chat… with File's old key, ⌘⌫ (it asks first,
    /// `hqDeleteChat`), the one place it is listed.
    static func deleteItem() -> UIKeyCommand { command("Delete Chat…", deleteChat, UIKeyCommand.inputDelete, .command) }
    #endif

    static func viewItems() -> [UIMenuElement] {
        let tabs = tabTitles.enumerated().map { index, title in command(title, selectTab, String(index + 1), .command, list: index) }
        // One chat per press: a held key (or a press a busy device reads as held) must not run through the list,
        // opening and fetching a chat on every repeat (repair after stress round 1: one press moved two rows).
        let walk: [UIKeyCommand] = [
            command("Next Chat", nextChat, UIKeyCommand.inputDownArrow, .command),
            command("Previous Chat", previousChat, UIKeyCommand.inputUpArrow, .command),
        ]
        walk.forEach { $0.repeatBehavior = .nonRepeatable }
        // ⌘[ goes back a page, as in the Finder, Safari and System Settings: Escape's last step, named in the menu.
        let back = command("Back", back, "[", .command)
        back.repeatBehavior = .nonRepeatable
        let others = (0..<otherPlaceSlots).map { slot in
            UICommand(title: "Tab \(slot + 10)", action: selectTab, propertyList: otherPlaceBase + slot)
        }
        var menus = [UIMenu(title: "", options: .displayInline, children: tabs + others),
                     UIMenu(title: "", options: .displayInline, children: walk + [back]),
                     UIMenu(title: "", options: .displayInline, children: [command("Refresh", refresh, "r", .command)])]
        #if targetEnvironment(macCatalyst)
        // [mac] Mail's Hide Sidebar: folds the tabs down the left edge to their icons (MacSidebar).
        // [Mac AAA 2026-11-17] Owner's call Q8: Show/Hide Inspector (⌘I) under it, where Mac apps keep the inspector
        // (Pages, Keynote, Xcode); it left the Chat menu. Same key, same action and naming (`validateChat`).
        menus.insert(UIMenu(title: "", options: .displayInline, children: [
            command("Hide Sidebar", toggleSidebar, "s", [.control, .command]),
            command("Hide List", toggleList, "l", [.shift, .command]),
            ChatMenuBar.inspectorItem(),
        ]), at: 0)
        // [mac] Mail's and Safari's text size items: the Desktop Look's UI Scale (MacWindow.changeTextSize).
        menus.append(UIMenu(title: "", options: .displayInline, children: [
            command("Make Text Bigger", textBigger, "+", .command),
            command("Actual Size", textNormal, "0", .command),
            command("Make Text Smaller", textSmaller, "-", .command),
        ]))
        #else
        menus[menus.count - 1] = UIMenu(title: "", options: .displayInline, children: [command("Refresh", refresh, "r", .command), stopItem()])
        // [ipad-polish] Mail's and Notes' sidebar key on the iPad: the list beside the chat goes away and comes back
        // (`RootSplitController.setListHidden`).
        menus.insert(UIMenu(title: "", options: .displayInline, children: [command("Hide List", toggleList, "s", [.control, .command])]), at: 0)
        #endif
        return menus
    }

    #if targetEnvironment(macCatalyst)
    static let findNext = #selector(AppDelegate.hqFindNext(_:))
    static let findPrevious = #selector(AppDelegate.hqFindPrevious(_:))
    static let textBigger = #selector(AppDelegate.hqTextBigger(_:))
    static let textNormal = #selector(AppDelegate.hqTextNormal(_:))
    static let textSmaller = #selector(AppDelegate.hqTextSmaller(_:))
    static let toggleSidebar = #selector(AppDelegate.hqToggleSidebar(_:))
    static let toggleList = #selector(AppDelegate.hqToggleList(_:))
    static let keyboardShortcuts = #selector(AppDelegate.hqKeyboardShortcuts(_:))
    /// Help's items. [keys] 2026-11-14 (round 3): Keyboard Shortcuts has a key of its own, ⌘/, as in Slack, Linear and
    /// Notion (⇧⌘/ stays the system's Help search).
    static func helpItems() -> [UIMenuElement] { [command("Keyboard Shortcuts", keyboardShortcuts, "/", .command)] }

    /// [Mac AAA 2026-11-17] Owner's call Q10 + [mac-session-tabs]: the Window menu's tab items.
    /// `New Tab` (⌘T) shows only while a Terminal is on screen; `Show Previous Tab` (⇧⌘[) and `Show Next Tab` (⇧⌘])
    /// walk the Terminal's tabs while it is in front, and otherwise the window's own tabs: the row at its very top
    /// (`MacWorkspaceBar`), as Safari's do. Never the bot's chats under a chat's bar (owner 2026-11-27).
    static let terminalNewTab = #selector(AppDelegate.hqTerminalNewTab(_:))
    static let terminalNextTab = #selector(AppDelegate.hqTerminalNextTab(_:))
    static let terminalPreviousTab = #selector(AppDelegate.hqTerminalPreviousTab(_:))
    static let terminalActions: Set<Selector> = [terminalNewTab, terminalNextTab, terminalPreviousTab]
    static func windowItems() -> [UIKeyCommand] {
        let previous = command("Show Previous Tab", terminalPreviousTab, "[", [.command, .shift])
        let next = command("Show Next Tab", terminalNextTab, "]", [.command, .shift])
        previous.repeatBehavior = .nonRepeatable
        next.repeatBehavior = .nonRepeatable
        return [command("New Tab", terminalNewTab, "t", .command), previous, next]
    }
    /// [mac-feel D30] Page Up, Page Down, Home and End scroll the chat on show (`ChatViewController.keyScroll`).
    static let scrollChat = #selector(AppDelegate.hqScrollChat(_:))
    private static let scrollInputs = [UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown, UIKeyCommand.inputHome, UIKeyCommand.inputEnd]
    /// With no field taking them (a text field's own use, and a focused list's, come first).
    static let scrollKeys: [UIKeyCommand] = scrollInputs.map { UIKeyCommand(action: scrollChat, input: $0, modifierFlags: []) }

    /// Which way a scroll key goes, by the key itself: the message field's way in (`ComposerTextView.pressesBegan`),
    /// since no key command matches these four while the caret is in a field on the Mac.
    static func scrollKey(pressed: UIKeyboardHIDUsage) -> ChatViewController.KeyScroll? {
        switch pressed {
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        default: return nil
        }
    }

    /// Which way a scroll key command goes, by its input.
    static func scrollKey(input: String?) -> ChatViewController.KeyScroll? {
        switch input {
        case UIKeyCommand.inputPageUp: return .pageUp
        case UIKeyCommand.inputPageDown: return .pageDown
        case UIKeyCommand.inputHome: return .home
        case UIKeyCommand.inputEnd: return .end
        default: return nil
        }
    }
    #else
    static let toggleList = #selector(AppDelegate.hqToggleList(_:))
    #endif

    /// The second key of three commands (⌃Tab, ⌃⇧Tab, ⌘period): the same actions, not listed twice in the menu or in
    /// the hold-⌘ overlay. On the app delegate, the end of every responder chain.
    static let alternates: [UIKeyCommand] = {
        let next = UIKeyCommand(action: nextChat, input: "\t", modifierFlags: .control)
        let previous = UIKeyCommand(action: previousChat, input: "\t", modifierFlags: [.control, .shift])
        // The system's own use of Tab (moving focus) must not swallow these two.
        next.wantsPriorityOverSystemBehavior = true
        previous.wantsPriorityOverSystemBehavior = true
        next.repeatBehavior = .nonRepeatable
        previous.repeatBehavior = .nonRepeatable
        let stop = UIKeyCommand(action: escape, input: ".", modifierFlags: .command)   // the Mac's other Escape
        stop.repeatBehavior = .nonRepeatable
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28: with no text field taking them, ↑ / ↓ walk the list as Mail's do (a field's
        // caret, a menu or a focused list keeps them: the system's own use comes first) and Return puts the caret in
        // the message field. Off while a sheet is up or there is nothing to walk (`validate`), so the key passes on.
        let down = UIKeyCommand(action: nextChat, input: UIKeyCommand.inputDownArrow, modifierFlags: [])
        let up = UIKeyCommand(action: previousChat, input: UIKeyCommand.inputUpArrow, modifierFlags: [])
        down.repeatBehavior = .nonRepeatable
        up.repeatBehavior = .nonRepeatable
        // [macpass] 2026-11-14: in Sessions, after a click on a row, ↓ moved the system's square focus ring down the
        // list (and past the pane's edge) instead of opening the next chat: keyboard focus takes plain arrows before a
        // key command without priority. With it they walk the chats; `validate` turns them off while a text field
        // holds the caret, or with nothing to walk, so a field, a picker or another list keeps its arrows.
        down.wantsPriorityOverSystemBehavior = true
        up.wantsPriorityOverSystemBehavior = true
        let field = UIKeyCommand(action: messageField, input: "\r", modifierFlags: [])
        // [mac] ⌘= is ⌘+ without Shift, as in every Mac app that zooms.
        return [next, previous, stop, down, up, field, UIKeyCommand(action: textBigger, input: "=", modifierFlags: .command)] + scrollKeys
        #else
        return [next, previous, stop]
        #endif
    }()

    static func settingsItem() -> UIKeyCommand {
        #if targetEnvironment(macCatalyst)
        command("Settings…", settings, ",", .command)   // [mac] a Mac menu item that opens a window or page ends in "…"
        #else
        command("Settings", settings, ",", .command)
        #endif
    }

    /// Offered by the message field while it is empty: ⌘↑ / ⌘↓ then walk the chats instead of moving a caret that
    /// has nowhere to go (D11). With text in the field the caret keeps them.
    static let walkFromEmptyField: [UIKeyCommand] = {
        let next = UIKeyCommand(action: nextChat, input: UIKeyCommand.inputDownArrow, modifierFlags: .command)
        let previous = UIKeyCommand(action: previousChat, input: UIKeyCommand.inputUpArrow, modifierFlags: .command)
        next.wantsPriorityOverSystemBehavior = true
        previous.wantsPriorityOverSystemBehavior = true
        next.repeatBehavior = .nonRepeatable
        previous.repeatBehavior = .nonRepeatable
        return [next, previous]
    }()

    static func build(_ builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        // The system's own items for these keys act on windows and documents the app does not have.
        builder.remove(menu: .close)
        builder.remove(menu: .newItem)
        builder.remove(menu: .find)
        builder.remove(menu: .document)
        #if !targetEnvironment(macCatalyst)
        // [ipad-polish] The system's own Show Sidebar (⌃⌘S) is for a split view controller the app does not use, and
        // took the key from Hide List (the key reached the window and nothing happened).
        builder.remove(menu: .sidebar)
        #endif
        #if targetEnvironment(macCatalyst)
        SheetKeys.install()   // [macpass]
        MacWindow.trimMenus(builder)   // [mac]
        MacUpdater.addMenuItem(builder)
        // [mac-audit K] Owner 2026-11-02: Help › Keyboard Shortcuts lists every key in a sheet (MacShortcutsSheet).
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: helpItems()), atStartOfMenu: .help)
        // After Minimize and Zoom, where Safari and Terminal list their tabs: Show Previous/Next Tab walk the
        // Terminal's tabs while it is in front, else the window's top row; New Tab hides unless a Terminal is on screen.
        builder.insertSibling(UIMenu(title: "", options: .displayInline, children: windowItems()), afterMenu: .minimizeAndZoom)
        TypeToChatKeys.install()   // [Mac AAA 2026-11-17] owner's call Q1
        #endif
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: fileItems()), atStartOfMenu: .file)
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: editItems()), atEndOfMenu: .edit)
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: viewItems()), atStartOfMenu: .view)
        builder.insertSibling(ChatMenuBar.menu(), afterMenu: .view)   // [mac] stress test 2026-10-28 #33
        builder.replaceChildren(ofMenu: .preferences) { _ in [settingsItem()] }
    }

    // MARK: State

    static var root: MainTabController? { MainTabController.current }
    /// The reply Escape last stopped and when (the same reply is not interrupted twice while the first Stop lands).
    static var stopAsked: (session: AnyObject?, at: TimeInterval) = (nil, 0)

    /// The screen on top of everything (a sheet over a sheet included), nil when nothing is presented.
    /// What ⌘R does over a sheet: the top page's own refresh when it has one (`KeyRefreshing`), else nothing.
    static func sheetRefresh(_ root: UIViewController) -> (() -> Void)? {
        guard let top = presented(root) else { return nil }
        let page = (top as? UINavigationController)?.topViewController ?? top
        return (page as? KeyRefreshing)?.keyRefresh
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] The top sheet's ⌘Return command (`UIKeyCommand.save`, New Job's), searched through its controllers and the
    /// views they show, and who offers it.
    static func sheetSave(_ root: UIViewController) -> (owner: UIResponder, command: UIKeyCommand)? {
        presented(root).flatMap(saveCommand)
    }

    /// The menu's name for a found ⌘Return command: its own, or Save when it has none (a SwiftUI button's
    /// `.keyboardShortcut` may come without one; Mac polish #12).
    static func saveTitle(_ save: (owner: UIResponder, command: UIKeyCommand)) -> String {
        save.command.title.isEmpty ? "Save" : save.command.title
    }

    /// The ⌘Return command offered by `top` or the pages and views it shows (a sheet, or the Settings window's page).
    static func saveCommand(in top: UIViewController) -> (owner: UIResponder, command: UIKeyCommand)? {
        func match(_ responder: UIResponder) -> UIKeyCommand? {
            responder.keyCommands?.first { $0.input == "\r" && $0.modifierFlags == .command && $0.action != nil }
        }
        var controllers: [UIViewController] = [top]
        while !controllers.isEmpty {
            let controller = controllers.removeFirst()
            if let command = match(controller) { return (controller, command) }
            if let view = controller.viewIfLoaded {
                var views: [(UIView, Int)] = [(view, 0)]
                while !views.isEmpty {
                    let (next, depth) = views.removeFirst()
                    if let command = match(next) { return (next, command) }
                    if depth < 8 { views += next.subviews.filter { !$0.isHidden }.map { ($0, depth + 1) } }
                }
            }
            controllers += controller.children.filter { $0.viewIfLoaded?.window != nil }
        }
        return nil
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// [mac-audit K] View's Escape item, named for the step of the ladder a press takes now (`hqEscape`).
    static func escapeTitle(_ root: MainTabController) -> String {
        switch EscapeAction.decide(escapeState(root)) {
        case .dismissPresented, .closeModelPanel: "Close"
        case .closeFind: "Close Find"
        case .closeDrawer: "Close Suggestions"
        case .cancelRecording: "Cancel Recording"
        case .cancelSearch: "Cancel Search"
        case .resignField: "Leave Message Field"
        case .nothing: escapePageStep(root) == .goBack ? "Go Back" : "Stop Reply"
        // Mac polish #7: out of the card's "Something else…" field first, as its Escape does.
        case .skipQuestion: questionCard(root)?.isDictating == true ? "Cancel Dictation"   // [question-dictate]
            : questionCard(root)?.isTyping == true ? "Leave Answer Field" : "Skip Question"
        // Mac polish #15: a group chat's Stop, as its ⋯ names it.
        case .stop: root.chatOnShow?.roomChrome != nil ? "Stop All" : "Stop Reply"
        case .system: "Stop Reply"
        }
    }

    /// [mac-audit] The bot's question card on show with nothing over it (Mac audit #26: it takes Escape as Skip), while
    /// no answer of its own is on its way. An approval card is not one.
    static func questionCard(_ root: MainTabController) -> QuestionDockView? {
        guard presented(root) == nil, let dock = root.chatOnShow?.promptsUI?.dockView, dock.window != nil,
              dock.sending == .none, !dock.draft.minimized else { return nil }
        return dock
    }
    #endif

    static func presented(_ root: UIViewController) -> UIViewController? {
        var top = (root.parent ?? root).presentedViewController ?? root.presentedViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    /// [mac] Stress test 2026-10-28 #18: a sheet (and every sheet over it) that New Chat, Settings or a tab may close
    /// before acting: none is an alert or guards unsaved edits, and none is already leaving. Never on the iPhone or iPad.
    static func sheetGivesWay(_ root: UIViewController) -> Bool {
        #if targetEnvironment(macCatalyst)
        var next = (root.parent ?? root).presentedViewController ?? root.presentedViewController
        guard next != nil else { return false }
        while let sheet = next {
            if sheet is UIAlertController || sheet.isModalInPresentation || sheet.isBeingDismissed { return false }
            next = sheet.presentedViewController
        }
        return true
        #else
        return false
        #endif
    }

    /// Escape's close of the sheet on top, as its own close, its ✕ or a pull down does.
    static func closePresented(_ top: UIViewController) {
        guard canDismiss(top), !top.isBeingDismissed else { return }
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #14: the ☰ Commands and Models pop-overs close their own way, which gives the message
        // field the caret back (a plain dismiss left the next keys typing into nothing).
        if let panel = top as? MacPickPanel { panel.close(); return }
        #endif
        // A sheet that asks before closing (unsaved edits) asks exactly as its ✕ or a pull down does.
        if top.isModalInPresentation, let presentation = top.presentationController {
            presentation.delegate?.presentationControllerDidAttemptToDismiss?(presentation)
        } else {
            top.dismiss(animated: true)
        }
    }

    /// [morepages] §9: Escape on an open search: one folded behind the bar's magnifier clears and folds (`PageBarCapsule`).
    static func cancelSearch(_ search: UISearchController?) {
        if let capsule = search?.searchBar.delegate as? PageBarCapsule { capsule.clearSearch() } else { search?.isActive = false }
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Mac polish #12: the Settings window's page stack while that window is in front. The keys then work it, as a
    /// Mac's settings window takes them, and not the main window behind it: Escape closes its prompt or sheet, folds
    /// its search or goes back a page; ⌘[ goes back; ⌘F opens its page's search; ⌘R refreshes its page; ⌘Return is its
    /// page's Save; ⌘W closes it. The main window's own commands (chats, lists, places) are off until it is in front.
    static var settingsInFront: UINavigationController? {
        guard MacSettingsWindow.isKey else { return nil }
        // [mac-ui-issues] Its pages are in the stack beside the categories.
        return MacSettingsWindow.root?.paneStack ?? MacSettingsWindow.scene?.windows.first?.rootViewController as? UINavigationController
    }

    /// [mac-files] A file window in front (`MacFileWindow`): ⌘W and Escape close it (Escape first closes its share menu
    /// or save panel), ⌘, opens Settings, and the main window's own commands are off until it is in front.
    static var fileInFront: UIWindowScene? { MacFileWindow.keyScene }

    /// Escape's step in the Settings window: the ladder's for what the window can hold (a prompt, a sheet, a search);
    /// `.nothing` then goes back a page when there is one.
    static func settingsEscape(_ settings: UINavigationController) -> EscapeAction {
        var state = EscapeAction.State()
        let top = presented(settings)
        state.alert = top is UIAlertController
        state.presented = top != nil
        state.searching = settings.topViewController?.navigationItem.searchController?.isActive == true
        return EscapeAction.decide(state)
    }

    /// What ⌘F opens in the Settings window: a sheet's page's search over it, else its page's own.
    static func settingsSearchPage(_ settings: UINavigationController) -> UIViewController? {
        if presented(settings) != nil { return sheetSearchPage(settings) }
        return settings.topViewController.flatMap { canSearch($0) ? $0 : nil }
    }

    /// [mac] Mac polish #21: something is presented over the window in front (a sheet holds ⌘W, as on a Mac).
    static var frontCovered: Bool {
        let front = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first { $0.isKeyWindow }
        return front?.rootViewController.flatMap(presented) != nil
    }
    #endif

    /// Escape may close this sheet: any sheet that can be pulled down, and one that guards unsaved edits when it has
    /// someone to ask (its presentation delegate), exactly as a pull down would.
    static func canDismiss(_ top: UIViewController?) -> Bool {
        guard let top else { return false }
        return !top.isModalInPresentation || top.presentationController?.delegate != nil
    }

    static func escapeState(_ root: MainTabController) -> EscapeAction.State {
        var state = EscapeAction.State()
        let top = presented(root)
        state.alert = top is UIAlertController
        state.presented = top != nil
        if let chat = root.chatOnShow {
            state.find = chat.findController?.isActive ?? false
            state.recording = MemoController.shared.isActive(for: chat.voice)
            state.question = chat.questionWaiting
            // [keys] Mac polish #15: a group chat's round counts, as its Stop square does (the room has no turn of its own).
            state.running = chat.session.isRunning || (chat.session as? ChatRoomSurface)?.roomRunning == true
            state.fieldFocused = chat.composer.textView.isFirstResponder
            state.drawer = chat.drawer?.isOpen ?? false   // [composer-drawers]
            state.modelPanel = chat.menus?.modelPanelOpen ?? false   // [keys] Mac polish #13
            #if targetEnvironment(macCatalyst)
            state.questionSkips = questionCard(root) != nil   // [mac-audit] Mac audit #26, Mac polish #7
            #endif
        }
        state.searching = activeSearch(root) != nil
        return state
    }

    // [morepages] 3x-morepages §9: once the ladder above has nothing to do, a pushed page goes Back (docs D-M7).
    static func escapeFacts(_ root: MainTabController) -> EscapeRule.Facts {
        var facts = EscapeRule.Facts()
        facts.presented = presented(root) != nil
        facts.searching = activeSearch(root) != nil
        facts.chatDraft = root.chatOnShow.map { EscapeRule.isDraft($0.composer.text) } ?? false
        facts.depth = inPlaceBack(root) != nil ? 2 : max(backStack(root)?.viewControllers.count ?? 1, botChatBack(root) != nil ? 2 : 1)
        return facts
    }

    /// The stack Escape goes back on: the left one while it has a pushed page, else (two panes) the inspector's while a
    /// step or a row is open in it, else the right pane's own stack (Settings › Theme, Files › a folder), as its Back
    /// button does.
    static func backStack(_ root: MainTabController) -> UINavigationController? {
        let left = root.selectedViewController as? UINavigationController
        if let left, left.viewControllers.count > 1 { return left }
        #if targetEnvironment(macCatalyst)
        // [mac] Tester 2026-11-07: a step opened in the inspector's Steps had no way back but another tab.
        if let split = root.split, split.isDouble, split.inspector.isVisible, let stack = split.inspector.pageStack,
           stack.viewControllers.count > 1 { return stack }
        #endif
        #if targetEnvironment(macCatalyst)
        // [mac-ui-issues] Settings in two columns: its right side has a page stack of its own.
        if let split = root.split, split.isDouble, let settings = split.detail.topViewController as? SettingsRootController,
           let stack = settings.paneStack, stack.viewControllers.count > 1 { return stack }
        #endif
        if let split = root.split, split.isDouble, split.detail.viewControllers.count > 1 { return split.detail }
        return left
    }

    /// What Escape does after the ladder: `.goBack` only when nothing else claimed the key and no question waits.
    static func escapePageStep(_ root: MainTabController) -> EscapeRule.Outcome {
        let state = escapeState(root)
        guard EscapeAction.decide(state) == .nothing, !state.question else { return .nothing }
        let outcome = EscapeRule.outcome(EscapeRule.context(escapeFacts(root)))
        return outcome == .goBack ? .goBack : .nothing
    }

    /// ⌘W has a chat or a right-pane page to close.
    static func closeChatCloses(_ root: MainTabController) -> Bool {
        root.split?.isDouble == true ? !(root.split?.detailIsEmpty ?? true) : root.chatOnShow != nil
    }

    /// ⌘[ (View › Back) has a page to go back from, as the bar's Back button does.
    static func canGoBack(_ root: MainTabController) -> Bool {
        inPlaceBack(root) != nil || botChatBack(root) != nil || backStack(root).map(canGoBack) ?? false
    }

    /// [bot-chat-back] The chat on show was opened from its bot's own chat: Back goes there.
    static func botChatBack(_ root: MainTabController) -> (() -> Void)? {
        #if targetEnvironment(macCatalyst)
        guard let chat = root.chatOnShow, chat.navigationController?.viewControllers.count == 1 else { return nil }
        return chat.backToBotChat
        #else
        return nil
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac-session-tabs] Whether the window's tab row (the one at its very top) has another tab to show.
    static func canCycleWindowTabs(_ root: MainTabController) -> Bool {
        root.split?.macWorkspaceBar.canCycleTabs == true
    }

    /// The window's next (`step` 1) or previous (-1) tab, wrapping round. False when the row has no other tab.
    @discardableResult
    static func cycleWindowTabs(_ root: MainTabController, step: Int) -> Bool {
        root.split?.macWorkspaceBar.cycleTabs(step: step) ?? false
    }
    #endif

    /// [macpass-tools] The list's page while it shows a folder it opened in place (Files' table): Back goes up one.
    static func inPlaceBack(_ root: MainTabController) -> InPlaceBack? {
        guard let page = listOnShow(root) as? InPlaceBack, page.canGoBackInPlace else { return nil }
        return page
    }

    /// `stack` has a page to go back from and isn't moving.
    static func canGoBack(_ stack: UINavigationController) -> Bool {
        stack.viewControllers.count > 1 && stack.transitionCoordinator == nil
    }

    /// Back one page on the stack Escape goes back on (`goBack`).
    static func escapeGoBack(_ root: MainTabController) {
        if let page = inPlaceBack(root) { page.goBackInPlace(); return }
        if let stack = backStack(root), canGoBack(stack) { goBack(stack); return }
        if let back = botChatBack(root) { back(); return }
        guard let stack = backStack(root) else { return }
        goBack(stack)
    }

    /// Back one page on `stack`, as its Back button goes: a page holding unsaved edits runs its own Cancel instead
    /// (`EscapeCancelling`), and [keys] (Mac polish #20) a page whose Back asks first (a connector's, an app's or a
    /// plugin's unsaved changes: its own `backAction`) asks here too, where Escape and ⌘[ threw the changes away.
    static func goBack(_ stack: UINavigationController) {
        guard stack.viewControllers.count > 1, stack.transitionCoordinator == nil, let page = stack.topViewController else { return }
        if let page = page as? EscapeCancelling, page.escapeCancel() { return }
        if let back = DesktopBack.ownBackAction(of: page.navigationItem) { back.performWithSender(nil, target: nil); return }
        stack.popViewController(animated: true)
    }

    /// The list on show in the left pane (or on the phone), and its search if one is open.
    static func listOnShow(_ root: MainTabController) -> UIViewController? {
        (root.selectedViewController as? UINavigationController)?.topViewController
    }

    /// The page on show in the right pane (two panes), the placeholder and a chat left out.
    static func pageOnShow(_ root: MainTabController) -> UIViewController? {
        guard let split = root.split, split.isDouble, let top = split.detail.topViewController,
              !(top is DetailPlaceholderViewController), !(top is ChatViewController) else { return nil }
        return top
    }

    /// What ⌘F searches with no chat on show: the right pane's page when it can be searched, else the list.
    static func findTarget(_ root: MainTabController) -> UIViewController? {
        if let page = pageOnShow(root), canSearch(page) { return page }
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #8: the Bots list folded into the sidebar is out of sight; its search took typing nobody saw.
        if root.split?.listFolded == true { return nil }
        #endif
        return listOnShow(root)
    }

    static func activeSearch(_ root: MainTabController) -> UISearchController? {
        var screens = [listOnShow(root)]
        if let split = root.split, split.isDouble { screens.append(split.detail.topViewController) }
        return screens.compactMap { $0?.navigationItem.searchController }.first { $0.isActive }
    }

    static func canSearch(_ screen: UIViewController?) -> Bool {
        screen is KeySearchable || screen?.navigationItem.searchController != nil || PageBarCapsule.on(screen) != nil
    }

    /// [mac] What ⌘F searches over a sheet: its top page's own search (the Table page's rows), nil when it has none
    /// (stress test 2026-10-31: ⌘F went nowhere over a sheet).
    static func sheetSearchPage(_ root: UIViewController) -> UIViewController? {
        guard let top = presented(root) else { return nil }
        let page = (top as? UINavigationController)?.topViewController ?? top
        return canSearch(page) ? page : nil
    }

    /// Opens the list's own search with the caret in it: the magnifier's action where the list has one.
    static func openSearch(_ screen: UIViewController?) {
        guard let screen else { return }
        #if targetEnvironment(macCatalyst)
        TypeToChatKeys.fieldWillFocus()   // [rest-hands 2026-11-17] letters typed at once wait for the field
        #endif
        if let list = screen as? KeySearchable {
            list.openSearchFromKeyboard()
        } else if let search = screen.navigationItem.searchController {
            search.isActive = true
            DispatchQueue.main.async { PageBarCapsule.focus(search.searchBar, tries: 10) }   // [rest-hands 2026-11-17] once in its window
        } else {
            PageBarCapsule.on(screen)?.openSearch()   // [keys] Mac polish #17: the bar's folded search, as its magnifier
        }
    }

    /// The list Next / Previous Chat walk: the one the chat on show was opened from, else the selected one.
    static func walkList(_ root: MainTabController) -> (order: [String], current: String?, open: (String) -> Void)? {
        #if targetEnvironment(macCatalyst)
        // [Mac AAA 2026-11-17] Owner's call Q3: Jobs and Tasks walk as Sessions does, ↑/↓ opening the next or previous
        // job or task beside the list (they kept the system's own arrows, a grey mark that opened nothing). Two panes
        // only: in one the page covers the list, as a chat does, and the keys there stay the page's.
        if root.split?.isDouble == true {
            if let jobs = listOnShow(root) as? JobsViewController {
                return (jobs.walkOrder, jobs.walkCurrent, { [weak jobs] in jobs?.walkOpen($0) })
            }
            if let tasks = listOnShow(root) as? TasksViewController {
                return (tasks.walkOrder, tasks.walkCurrent, { [weak tasks] in tasks?.walkOpen($0) })
            }
        }
        #endif
        let shown = root.paneChatOnShow
        let tab: HQTab? = if let shown { shown.tab } else { root.shownTab }   // [taborder]
        let live = shown?.chat.session as? LiveChatSession
        switch tab {
        case .bots:
            let list = root.botsViewController
            // [groups] A group chat on show walks on from its own row.
            let room = (shown?.chat.session as? ChatRoomSurface).map { BotsViewController.walkKey(room: $0.roomKey) }
            return (list.paneOrder, room ?? live.flatMap { $0.menus.isBotChat ? $0.profile : nil }, { [weak list] in list?.walkOpen($0) })
        case .sessions:
            let list = root.sessionsViewController
            let key = live.flatMap { live in (live.storedSessionId ?? live.resolvedStoredId).map { live.profile + "\u{1F}" + $0 } }
            return (list.paneOrder, key, { [weak list] in list?.open($0) })
        default:
            return nil
        }
    }

    /// [cmd-n] ⌘N set to Bot Chat: the bot's own chat, opened as a click on its rail head or Bots row opens it (Bots
    /// becomes the tab on show when it is one), then the caret in its message field, as ⌘L puts it there.
    static func openBotChat(_ id: String, root: MainTabController) {
        if let bots = root.controller(for: .bots), root.selectedViewController !== bots {
            #if targetEnvironment(macCatalyst)
            if let split = root.split { split.switchPlace(to: bots) { root.pick(bots) } } else { root.pick(bots) }
            #else
            root.pick(bots)
            #endif
        }
        root.botsViewController.open(id)
        func isBotChat(_ chat: ChatViewController?) -> Bool {
            guard let live = chat?.session as? LiveChatSession, live.menus.isBotChat else { return false }
            return (live.profile.isEmpty ? "default" : live.profile) == id
        }
        // The chat may be built and pushed over a few frames (or wait for the roster): the caret goes in once it shows.
        func focus(_ tries: Int) {
            if let chat = root.chatOnShow, isBotChat(chat), chat.viewIfLoaded?.window != nil {
                chat.focusComposer()
                return
            }
            guard tries > 0 else { AppLog.note("keys", "bot chat \(id) never showed"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { focus(tries - 1) } }
        }
        focus(30)
    }

    #if targetEnvironment(macCatalyst)
    /// [macpass] A text field or text view in the window holds the caret (the arrows are its own).
    static func typing(_ root: MainTabController) -> Bool {
        guard let first = root.view.window?.hqFirstResponder else { return false }
        return first.hqTypingInput != nil   // [search-keys] a search bar holding the keyboard counts
    }

    /// [Mac AAA 2026-11-16] The list row the keyboard's focus is on in the main window (a grey mark after ↓ or Tab).
    static func focusedRow(_ root: MainTabController) -> (UICollectionView, IndexPath)? {
        guard let window = root.view.window, let cell = UIFocusSystem.focusSystem(for: window)?.focusedItem as? UICollectionViewCell else { return nil }
        var up = cell.superview
        while let view = up, !(view is UICollectionView) { up = view.superview }
        guard let list = up as? UICollectionView, let path = list.indexPath(for: cell) else { return nil }
        return (list, path)
    }

    /// [macpass] The plain arrow walks a chat list now (see `keyCommands`).
    static func arrowsWalk(forward: Bool) -> Bool {
        guard let root, presented(root) == nil, !MacSettingsWindow.isKey, !MacFileWindow.isKey,
              root.view.window?.isKeyWindow == true, !typing(root) else { return false }
        return walkStops(root) || walkTarget(root, forward: forward) != nil
    }

    /// [Mac AAA 2026-11-17] The plain arrows at either end of a list they walk: they stay theirs and do nothing (a list's
    /// first and last row stop the walk, as before). Passed on, the press moved the system's own grey focus mark down
    /// the rows below (seen in Tasks: a second grey row five rows from the one open). Every walked list alike.
    static func walkStops(_ root: MainTabController) -> Bool {
        walkList(root)?.order.isEmpty == false
    }
    #endif

    static func walkTarget(_ root: MainTabController, forward: Bool) -> (key: String, open: (String) -> Void)? {
        guard let list = walkList(root),
              let key = ChatWalk.target(order: list.order, current: list.current, forward: forward) else { return nil }
        return (key, list.open)
    }

    /// The place a ⌘1…⌘9 item picks, its name put on the item; nil when no place has its number.
    static func namePlace(_ command: UICommand, _ root: MainTabController) -> Int? {
        let tabs = root.placedTabs
        let place = tabIndex(forShortcut: command.propertyList as? Int ?? 0, among: tabs.map { $0.tabBarItem.tag })
        if let place, let title = tabs[place].tabBarItem.title { command.title = title }
        return place
    }
}

extension AppDelegate {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        KeyCommands.build(builder)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        #if targetEnvironment(macCatalyst)
        let settings = KeyCommands.settingsInFront   // [mac] Mac polish #12: the Settings window takes the keys
        // [mac] Text size works on any screen, signed in or not; the iOS look, or an end of the range, dims its item.
        switch command.action {
        case KeyCommands.textBigger: command.attributes = MacWindow.canChangeTextSize(by: 1) ? [] : .disabled; return
        case KeyCommands.textSmaller: command.attributes = MacWindow.canChangeTextSize(by: -1) ? [] : .disabled; return
        case KeyCommands.textNormal: command.attributes = MacWindow.canChangeTextSize(by: 0) ? [] : .disabled; return
        case KeyCommands.toggleSidebar:
            command.title = MacSidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            command.attributes = settings == nil && KeyCommands.fileInFront == nil && KeyCommands.root?.split?.isViewLoaded == true ? [] : .disabled
            return
        case KeyCommands.findNext, KeyCommands.findPrevious:
            // [mac] #15: on while the chat's Find bar has matches to step through.
            let find = settings != nil || KeyCommands.fileInFront != nil ? nil : KeyCommands.root.flatMap { KeyCommands.presented($0) == nil ? $0.chatOnShow?.findController : nil }
            command.attributes = find?.canStep == true ? [] : .disabled
            return
        case KeyCommands.terminalNewTab:
            // [Mac AAA 2026-11-17] Owner's call Q10: New Tab (⌘T) stays hidden unless a Terminal is on screen.
            guard TerminalViewController.onShow else { command.attributes = .hidden; return }
            command.attributes = TerminalViewController.front?.canAddTab == true ? [] : .disabled
            return
        case KeyCommands.terminalNextTab, KeyCommands.terminalPreviousTab:
            // [Mac AAA 2026-11-17] [mac-session-tabs] Show Previous/Next Tab (⇧⌘[ / ⇧⌘]) walk the Terminal's tabs
            // while it is in front, and otherwise the window's own row of tabs at its top.
            if let terminal = TerminalViewController.front {
                command.attributes = terminal.canCycleTabs ? [] : .disabled
                return
            }
            let canWalk = settings == nil && KeyCommands.fileInFront == nil
                && KeyCommands.root.map { KeyCommands.presented($0) == nil && KeyCommands.canCycleWindowTabs($0) } == true
            command.attributes = canWalk ? [] : .disabled
            return
        case KeyCommands.keyboardShortcuts:
            // [mac] Mac polish #21: before the main page is up (the sign-in form) there is nothing to list keys for.
            command.attributes = KeyCommands.root == nil ? .disabled : []
            return
        default: break
        }
        if validateUndo(command) { return }   // [keys]
        if let settings, validateInSettings(command, settings) { return }
        if let file = KeyCommands.fileInFront, validateInFileWindow(command, file) { return }   // [mac-files]
        #endif
        if validateChat(command) { return }   // the Chat menu (ChatMenuBar)
        guard let root = KeyCommands.root else {
            if Self.ownActions.contains(command.action) { command.attributes = .disabled }
            #if targetEnvironment(macCatalyst)
            // [keys] Mac UI check 2026-11-13 (A9): before the main page is up there are no places to name, so the
            // numbers past the four lists (their default names "More", "Tab 6"…) are hidden, never shown dimmed.
            if command.action == KeyCommands.selectTab, (command.propertyList as? Int ?? 0) >= 4 { command.attributes = .hidden }
            // [mac] Mac polish #21: before the main page is up (the sign-in form, reaching the gateway) ⌘W closes the
            // window, as the red button does, and says so; a sheet over the form still holds it.
            if command.action == KeyCommands.closeChat {
                command.title = "Close Window"
                command.attributes = KeyCommands.frontCovered ? .disabled : []
            } else if command.action == KeyCommands.closeWindow {
                command.attributes = .hidden   // ⌘W reads Close Window
            }
            #endif
            return
        }
        let covered = KeyCommands.presented(root) != nil
        var enabled = !covered
        // [mac] Stress test 2026-10-28 #18: New Chat, Settings and the tabs close a sheet that can close (no unsaved
        // edits, not an alert) and then act, as a Mac window's own commands do; they no longer dim under every sheet.
        let givesWay = KeyCommands.sheetGivesWay(root)
        switch command.action {
        case KeyCommands.toggleList:
            command.title = root.split?.isListCollapsedForUser == true ? "Show List" : "Hide List"
            enabled = enabled && root.split?.canToggleList == true
        case KeyCommands.newChatHere:
            // [cmd-n] Off with no chat of one bot on show (a group chat, a page, nothing open).
            enabled = (enabled || givesWay) && root.sessionsViewController.organizer != nil && root.chatOnShow?.session is LiveChatSession
        case KeyCommands.newChat, KeyCommands.newChatWith:
            enabled = (enabled || givesWay) && root.sessionsViewController.organizer != nil
            // [cmd-n] The menu names the bot ⌘N starts with, so the item says what the key does before it is pressed.
            if command.action == KeyCommands.newChat, let organizer = root.sessionsViewController.organizer {
                let bots = organizer.services.bots
                let name = NewChatKeyBot.profile(among: bots.map(\.id)).map { id in bots.first { $0.id == id }?.name ?? (id == "default" ? "Hermes" : id) }
                if NewChatKeyBot.mode == .botChat {   // [cmd-n] a tester: the bot's own chat, not a new one
                    command.title = name.map { "Open \($0)’s Chat" } ?? "Open a Bot’s Chat…"
                    break
                }
                let projects = organizer.store?.projectEntries() ?? []
                let project = NewChatKeyBot.project(among: projects.map(\.key)).flatMap { key in projects.first { $0.key == key }?.label }
                let place = project.map { " in \($0)" } ?? ""
                command.title = name.map { "New Chat with \($0)\(place)" } ?? "New Chat\(place)…"
            }
        case KeyCommands.closeChat:
            let closes = KeyCommands.closeChatCloses(root)
            enabled = enabled && closes
            // Two panes: ⌘W empties the pane whatever it holds; it says "Close" over a page that is not a chat (§6).
            let page = root.split?.isDouble == true && !(root.split?.detailIsEmpty ?? true)
                && !(root.split?.detail.viewControllers.first is ChatViewController)
            command.title = page ? "Close" : "Close Chat"
            #if targetEnvironment(macCatalyst)
            // [mac] Nothing to close in the window: ⌘W closes the window itself (a sheet still blocks it).
            if !closes {
                enabled = !covered
                command.title = "Close Window"
            }
            #endif
        case KeyCommands.closeWindow:
            enabled = !covered
            // [mac] While ⌘W itself reads Close Window, a second Close Window under it would only repeat it.
            if !KeyCommands.closeChatCloses(root) { command.attributes = .hidden; return }
        case KeyCommands.back:
            enabled = enabled && KeyCommands.canGoBack(root)
        case KeyCommands.find:
            enabled = covered ? KeyCommands.sheetSearchPage(root) != nil
                : root.chatOnShow != nil || KeyCommands.canSearch(KeyCommands.findTarget(root))
        case KeyCommands.searchSessions:
            #if targetEnvironment(macCatalyst)
            if root.controller(for: .sessions) == nil { enabled = enabled && root.pages?.more != nil }   // K1: Open Quickly's
            #endif
            break
        case KeyCommands.nextChat, KeyCommands.previousChat:
            enabled = enabled && KeyCommands.walkTarget(root, forward: command.action == KeyCommands.nextChat) != nil
            #if targetEnvironment(macCatalyst)
            // [mac-session-tabs] ⌃Tab / ⌃⇧Tab walk the window's tabs first (as in Safari), so they stay on with one
            // row in the list and `walkTarget` nil.
            if (command as? UIKeyCommand)?.input == "\t", !covered, KeyCommands.canCycleWindowTabs(root) {
                enabled = true
            }
            // [Mac AAA 2026-11-17] The second keys (`alternates`: plain ↑ / ↓, ⌃Tab) have no title; they may reach here as
            // plain commands, so the title tells them from the menu's items. At either end of a walked list they stay
            // taken and do nothing, so the press never moves the system's grey focus mark down the rows; the menu's
            // items dim there as before.
            // (A field's caret keeps the plain arrows: `keyCommands` offers them only while no field has the keyboard.)
            if command.title.isEmpty {
                if KeyCommands.walkStops(root) { enabled = !covered }
            } else {
                // [Mac AAA 2026-11-17] Owner's call Q3: over Jobs and Tasks the items say what they open.
                let forward = command.action == KeyCommands.nextChat
                let thing = root.split?.isDouble != true ? "Chat"
                    : KeyCommands.listOnShow(root) is JobsViewController ? "Job"
                    : KeyCommands.listOnShow(root) is TasksViewController ? "Task" : "Chat"
                command.title = (forward ? "Next " : "Previous ") + thing
            }
            // [Mac AAA 2026-11-16] Nor ⌘↑ / ⌘↓ while a field holds words: they are the caret's (start / end of the text),
            // as `walkFromEmptyField` says. The menu's item went first, so ⌘↓ in a half-typed message switched the chat
            // (seen in the running app); an empty field still walks the chats.
            if KeyCommands.typing(root), root.view.window?.hqFirstResponder?.hqTypingInput?.hasText == true { enabled = false }
            #endif
        case KeyCommands.selectTab:
            let place = KeyCommands.namePlace(command, root)
            enabled = (enabled || givesWay) && place != nil
            #if targetEnvironment(macCatalyst)
            if place == nil { command.attributes = .hidden; return }   // [mac-sidebar] no row for this number
            #endif
        case KeyCommands.settings:
            #if targetEnvironment(macCatalyst)
            // [mac] Mac polish #19: Settings is a window of its own; an alert or an unsaved editor in this one doesn't
            // need to close first (`hqSettings`), so neither dims it.
            enabled = true
            #else
            enabled = (enabled || givesWay) && root.pages?.more != nil
            #endif
        case KeyCommands.refresh:
            enabled = covered ? KeyCommands.sheetRefresh(root) != nil : Self.refreshTarget(root) != nil
        case KeyCommands.send:
            enabled = enabled && (root.chatOnShow?.composer.primary == .send)
            #if targetEnvironment(macCatalyst)
            // [mac] AppKit's menu takes ⌘Return before the sheet sees it, even with Send dimmed, so over an editor sheet
            // the item is that sheet's Save (Create, Add…) and passes the key on (`hqSend`).
            if covered, let save = KeyCommands.sheetSave(root) {
                enabled = true
                command.title = KeyCommands.saveTitle(save)
            } else {
                command.title = "Send"
            }
            #endif
        case KeyCommands.messageActions:
            enabled = enabled && root.chatOnShow != nil
        case KeyCommands.openQuickly:
            #if targetEnvironment(macCatalyst)
            let openQuicklyUp = KeyCommands.presented(root) is MacOpenQuickly
            enabled = (enabled || openQuicklyUp) && root.pages?.more != nil
            #else
            enabled = enabled && root.pages?.more != nil
            #endif
        case KeyCommands.quickActions:
            break
        case KeyCommands.messageField:
            enabled = enabled && root.chatOnShow.map { !$0.composer.textView.isFirstResponder } == true
            #if targetEnvironment(macCatalyst)
            // [Mac AAA 2026-11-16] With no chat on show, Return opens the list row the keyboard has reached (↓ in Jobs or
            // Tasks marked a row, and Return then did nothing; checked in the running app). Only the untitled Return alternate, not ⌘L.
            if command.title.isEmpty, root.chatOnShow == nil, KeyCommands.focusedRow(root) != nil, !KeyCommands.typing(root) { enabled = !covered }
            #endif
        #if targetEnvironment(macCatalyst)
        case KeyCommands.scrollChat:   // [mac-feel D30]
            enabled = enabled && root.chatOnShow != nil
        #endif
        case KeyCommands.archiveChat:
            let menus = root.chatOnShow?.menus
            enabled = enabled && menus?.canArchive == true
            command.title = menus?.menuState().archived == true ? "Unarchive Chat" : "Archive Chat"
        case KeyCommands.deleteChat:
            enabled = enabled && root.chatOnShow?.menus?.canDelete == true
            #if targetEnvironment(macCatalyst)
            // [Mac AAA 2026-11-17] While a field holds words ⌘⌫ is the text's (delete to the start of the line), as ⌘↑ /
            // ⌘↓ are: the item took it and asked to delete the chat mid-message (seen in the running app).
            if KeyCommands.typing(root), root.view.window?.hqFirstResponder?.hqTypingInput?.hasText == true { enabled = false }
            #endif
        case KeyCommands.escape:
            // An alert or a menu on top: the system's own Escape closes it, so this command must not take the key.
            let action = EscapeAction.decide(KeyCommands.escapeState(root))
            enabled = action != .nothing && action != .system
            #if targetEnvironment(macCatalyst)
            // [mac] Audit 2026-11-02 #17: an alert being typed into misses the system's Escape: this one closes it.
            if action == .system, AlertCancel.typing(KeyCommands.presented(root)) != nil { enabled = true }
            #endif
            if action == .nothing, KeyCommands.escapePageStep(root) == .goBack { enabled = true }   // [morepages] §9
            if action == .dismissPresented, !KeyCommands.canDismiss(KeyCommands.presented(root)) { enabled = false }
        default:
            return
        }
        #if targetEnvironment(macCatalyst)
        if command.action == KeyCommands.escape {
            command.title = KeyCommands.escapeTitle(root)   // [mac-audit K]
            // [keys] 2026-11-14 (round 3): when Escape's step is going back, View showed "Back" (⌘[) and "Go Back" (⎋)
            // for the one action. The Escape item hides (its key still works) and Back is the one item.
            if enabled, command.title == "Go Back" { command.attributes = .hidden; return }
        }
        #endif
        command.attributes = enabled ? [] : .disabled
        #if DEBUG
        // A shortcut that did nothing leaves its reason in the log (which command, and whether a sheet covered it).
        if !enabled, command.action == KeyCommands.find || command.action == KeyCommands.newChat {
            let top = KeyCommands.presented(root).map { String(describing: type(of: $0)) } ?? "nothing"
            AppLog.note("keys", "\(command.action) is off (on top: \(top))")
        }
        #endif
    }

    private static let ownActions: Set<Selector> = {
        var actions: Set<Selector> = [
        KeyCommands.newChat, KeyCommands.newChatWith, KeyCommands.newChatHere, KeyCommands.closeChat, KeyCommands.find, KeyCommands.searchSessions, KeyCommands.nextChat,
        KeyCommands.previousChat, KeyCommands.selectTab, KeyCommands.settings, KeyCommands.refresh, KeyCommands.escape, KeyCommands.send,
        KeyCommands.messageActions, KeyCommands.back, KeyCommands.closeWindow, KeyCommands.openQuickly,
        KeyCommands.quickActions, KeyCommands.messageField, KeyCommands.archiveChat, KeyCommands.deleteChat,
        ]
        #if !targetEnvironment(macCatalyst)
        actions.insert(KeyCommands.toggleList)   // [ipad-polish]
        #else
        actions.insert(KeyCommands.scrollChat)   // [mac-feel D30]
        #endif
        return actions
    }()

    #if targetEnvironment(macCatalyst)
    /// Edit › Undo's action (the system's item).
    static let undoAction = NSSelectorFromString("undo:")

    // [keys] 2026-11-14 (Mac full pass, round 3): Edit › Undo stayed dimmed while "Archived · Undo" showed (Sessions'
    // right-click Archive), so ⌘Z took nothing back: with no field holding the keyboard the menu asks the app's end of
    // the chain, which had no undo of its own. The pill's Undo is it now ("Undo Archive"); a field's own typing undo,
    // earlier in the chain, still comes first.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // [Mac AAA 2026-11-16] Only while the pill offers it: `super` answers yes for any action this class has, so
        // Edit › Undo stayed lit (and ⌘Z did nothing) with nothing to undo.
        if action == Self.undoAction { return UndoPill.menuUndo != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func undo(_ sender: Any?) {
        guard let pill = UndoPill.menuUndo else { return }
        AppLog.note("keys", "undo: the pill's (\(pill.undoName ?? "no name"))")
        pill.undoFromMenu()
    }

    /// Edit › Undo's name while the pill's Undo is what it does.
    func validateUndo(_ command: UICommand) -> Bool {
        guard command.action == Self.undoAction, let pill = UndoPill.menuUndo else { return false }
        command.title = pill.undoName.map { "Undo \($0)" } ?? "Undo"
        command.attributes = command.attributes.subtracting(.disabled)
        return true
    }

    /// [macpass-settings2] The main window's commands that go somewhere in it (a new chat, a sidebar place, Search
    /// Sessions, Open Quickly): with the Settings window or a file window in front they stay on, as Mail's New Message
    /// works with its Settings window in front, and bring the main window forward before they act. File › New Chat was
    /// dimmed while Settings was in front. The rest (the chat on show's, the sidebar's) stay off there.
    static let bringsMainForward: Set<Selector> = [
        KeyCommands.newChat, KeyCommands.newChatWith, KeyCommands.newChatHere, KeyCommands.selectTab,
        KeyCommands.searchSessions, KeyCommands.openQuickly, KeyCommands.quickActions,
    ]

    /// The main window to the front when another of the app's windows (Settings, a file) is (`bringsMainForward`).
    func mainWindowForward() {
        guard KeyCommands.settingsInFront != nil || KeyCommands.fileInFront != nil,
              let window = KeyCommands.root?.view.window, let main = window.windowScene else { return }
        AppLog.note("keys", "main window to the front")
        // An activation request alone leaves an already-open window behind the one in front while the app is active
        // (seen: the new chat started behind Settings). AppKit's own window takes the front and the keyboard.
        UIApplication.shared.requestSceneSessionActivation(main.session, userActivity: nil, options: nil)
        window.makeKey()
        // Ordered inside the menu's action, the window the menu was chosen from took the front back after it.
        DispatchQueue.main.async { [weak window] in window?.hqMacOrderFront(activating: false) }
    }

    /// [mac] Mac polish #12: the app's commands while the Settings window is in front (`KeyCommands.settingsInFront`):
    /// the ones a window has work it; the main window's own are off, keeping their names. False for any other command
    /// (the Chat menu's dim through `ChatMenuBar.chat`).
    private func validateInSettings(_ command: UICommand, _ settings: UINavigationController) -> Bool {
        guard Self.ownActions.contains(command.action) else { return false }
        if Self.bringsMainForward.contains(command.action) { return false }   // [macpass-settings2] as the main window's
        let top = KeyCommands.presented(settings)
        var enabled = false
        switch command.action {
        case KeyCommands.closeChat:
            enabled = top == nil   // a sheet or a prompt over the window holds it, as on a Mac
            command.title = "Close Window"
        case KeyCommands.closeWindow:
            command.attributes = .hidden   // ⌘W reads Close Window
            return true
        case KeyCommands.settings:
            enabled = true
        case KeyCommands.back:
            enabled = top == nil && KeyCommands.canGoBack(settings)
        case KeyCommands.find:
            // A page with no search of its own takes ⌘F to the column's Search Settings field (`hqFind`).
            let column = top == nil && MacSettingsWindow.root?.paneStack != nil
                && !KeyCommands.canSearch(settings.topViewController)
            enabled = column || KeyCommands.settingsSearchPage(settings) != nil
        case KeyCommands.refresh:
            enabled = (top != nil ? KeyCommands.sheetRefresh(settings) : settings.topViewController.flatMap(Self.refreshAction)) != nil
        case KeyCommands.send:
            // AppKit's menu takes ⌘Return first: the item is the page's own Save (Add, Save…), or off.
            let save = KeyCommands.saveCommand(in: top ?? settings)
            enabled = save != nil
            command.title = save.map(KeyCommands.saveTitle) ?? "Send"
        case KeyCommands.escape:
            let action = KeyCommands.settingsEscape(settings)
            switch action {
            case .system: enabled = AlertCancel.typing(top) != nil   // a prompt being typed in; any other alert is the system's
            case .dismissPresented: enabled = KeyCommands.canDismiss(top)
            case .cancelSearch: enabled = true
            default: enabled = KeyCommands.canGoBack(settings)
            }
            command.title = switch action {
            case .cancelSearch: "Cancel Search"
            case .system, .dismissPresented: "Close"
            default: "Go Back"
            }
            // [keys] Round 3: going back is View › Back's (⌘[) item; the Escape item doesn't repeat it.
            if command.title == "Go Back" { command.attributes = .hidden; return true }
        case KeyCommands.selectTab:
            // The places keep their names, and a number with no place stays hidden.
            if let root = KeyCommands.root, KeyCommands.namePlace(command, root) == nil { command.attributes = .hidden; return true }
        default:
            break   // the main window's own
        }
        command.attributes = enabled ? [] : .disabled
        return true
    }

    /// [mac-files] The app's commands while a file window is in front (`KeyCommands.fileInFront`): ⌘W and Escape close
    /// it, Settings opens; the main window's own are off, keeping their names. False for any other command.
    private func validateInFileWindow(_ command: UICommand, _ scene: UIWindowScene) -> Bool {
        guard Self.ownActions.contains(command.action) else { return false }
        if Self.bringsMainForward.contains(command.action) { return false }   // [macpass-settings2] as the main window's
        let covered = scene.keyWindow?.rootViewController.flatMap(KeyCommands.presented) != nil
        var enabled = false
        switch command.action {
        case KeyCommands.closeChat:
            enabled = !covered   // a share menu or the save panel over the window holds it, as on a Mac
            command.title = "Close Window"
        case KeyCommands.closeWindow:
            command.attributes = .hidden   // ⌘W reads Close Window
            return true
        case KeyCommands.settings:
            enabled = true
        case KeyCommands.escape:
            enabled = true
            command.title = "Close"
        case KeyCommands.selectTab:
            if let root = KeyCommands.root, KeyCommands.namePlace(command, root) == nil { command.attributes = .hidden; return true }
        default:
            break   // the main window's own
        }
        command.attributes = enabled ? [] : .disabled
        return true
    }

    /// [mac-files] Escape in a file window: what is over it closes first, then the window.
    private func escapeInFileWindow(_ scene: UIWindowScene) {
        if let top = scene.keyWindow?.rootViewController.flatMap(KeyCommands.presented) {
            AppLog.note("keys", "escape (file window): close \(type(of: top))")
            KeyCommands.closePresented(top)
            return
        }
        AppLog.note("keys", "escape (file window): close the window")
        MacFileWindow.close(scene)
    }

    /// [mac] Mac polish #12: Escape in the Settings window (`KeyCommands.settingsEscape`).
    private func escapeInSettings(_ settings: UINavigationController) {
        let action = KeyCommands.settingsEscape(settings)
        AppLog.note("keys", "escape (settings window): \(action)")
        let top = KeyCommands.presented(settings)
        switch action {
        case .system:
            if let alert = AlertCancel.typing(top) { AlertCancel.close(alert) }
        case .dismissPresented:
            if let top { KeyCommands.closePresented(top) }
        case .cancelSearch:
            KeyCommands.cancelSearch(settings.topViewController?.navigationItem.searchController)
        default:
            KeyCommands.goBack(settings)
        }
    }
    #endif

    /// The root, only while nothing is presented over it: a shortcut never acts on a screen behind a sheet.
    private var uncovered: MainTabController? {
        guard let root = KeyCommands.root, KeyCommands.presented(root) == nil else { return nil }
        return root
    }

    private static func refreshControl(_ screen: UIViewController) -> UIRefreshControl? {
        func find(_ view: UIView, depth: Int) -> UIRefreshControl? {
            if let scroll = view as? UIScrollView, let control = scroll.hqKeyRefresh { return control }
            guard depth > 0 else { return nil }
            for child in view.subviews { if let found = find(child, depth: depth - 1) { return found } }
            return nil
        }
        return screen.viewIfLoaded.flatMap { find($0, depth: 3) }
    }

    /// What ⌘R does on `screen`: its list's refresh control, as a pull, or the page's own refresh (`KeyRefreshing`; a
    /// plugin page's Reload, Mac polish #22).
    private static func refreshAction(_ screen: UIViewController) -> (() -> Void)? {
        if let control = refreshControl(screen) { return { control.sendActions(for: .valueChanged) } }
        return (screen as? KeyRefreshing)?.keyRefresh
    }

    /// What ⌘R pulls: the right pane's page when one is on show, else the list on show.
    private static func refreshTarget(_ root: MainTabController) -> (() -> Void)? {
        // [keys] Mac UI check 2026-11-13 (K9): a page with no refresh of its own leaves ⌘R off; it no longer pulled the
        // list behind it, which the page hides.
        if let page = KeyCommands.pageOnShow(root) { return refreshAction(page) }
        return KeyCommands.listOnShow(root).flatMap(refreshAction)
    }

    override var keyCommands: [UIKeyCommand]? {
        #if targetEnvironment(macCatalyst)
        // [macpass] The plain ↑ / ↓ go before the system's own use of the arrows (`alternates`), so they are offered
        // only when they walk something: not while a field holds the caret, nor over a list they don't walk (Files,
        // Artifacts, Kanban, a pick panel keep their own arrows; Jobs and Tasks walk since owner's call Q3, 2026-11-17),
        // nor under a sheet or with another window in front.
        let alternates = KeyCommands.alternates.filter { command in
            guard command.modifierFlags.isEmpty, command.action == KeyCommands.nextChat || command.action == KeyCommands.previousChat else { return true }
            return KeyCommands.arrowsWalk(forward: command.action == KeyCommands.nextChat)
        }
        #else
        let alternates = KeyCommands.alternates
        #endif
        #if DEBUG
        // UI tests and the stress sweep: ⌃⌥⌘P flips the stand-in window between 420 pt wide (phone layout) and the
        // real window, ⌃⌥⌘O sweeps it 1,100 → 400 → 1,100 pt over 2 s (docs/spec/3x-ipad.md §11).
        return alternates + [
            UIKeyCommand(action: #selector(hqDebugTogglePane(_:)), input: "p", modifierFlags: [.control, .alternate, .command]),
            UIKeyCommand(action: #selector(hqDebugSweepPane(_:)), input: "o", modifierFlags: [.control, .alternate, .command])]
        #else
        return alternates
        #endif
    }

    #if DEBUG

    @objc func hqDebugTogglePane(_ sender: Any?) {
        guard let split = KeyCommands.root?.split else { return }
        split.setDebugSize(width: RootSplitController.debugWidth == nil ? 420 : nil, height: nil)
    }

    @objc func hqDebugSweepPane(_ sender: Any?) {
        guard let split = KeyCommands.root?.split else { return }
        let full = split.view.bounds.width, steps = 60
        for step in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 2.0 / Double(steps)) { [weak split] in
                let t = abs(1 - 2 * CGFloat(step) / CGFloat(steps))            // 1 → 0 → 1
                let width = 400 + (min(full, 1100) - 400) * t
                split?.setDebugSize(width: step == steps ? nil : width, height: nil)
            }
        }
    }
    #endif

    /// `act` on the root with nothing over it: now, or [mac] (#18) once a sheet that gives way has closed.
    private func whenUncovered(_ act: @escaping (MainTabController) -> Void) {
        if let root = uncovered { act(root); return }
        guard let root = KeyCommands.root, KeyCommands.sheetGivesWay(root),
              let sheet = (root.parent ?? root).presentedViewController ?? root.presentedViewController,
              let presenter = sheet.presentingViewController else { return }
        AppLog.note("keys", "closing \(type(of: sheet)) first")
        presenter.dismiss(animated: true) { act(root) }
    }

    @objc func hqNewChat(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        mainWindowForward()   // [macpass-settings2]
        #endif
        whenUncovered { root in
            guard let organizer = root.sessionsViewController.organizer else { return }
            if NewChatKeyBot.mode == .botChat {
                // [cmd-n] a tester 2026-11-02: the bot's own chat (Ask Every Time: Choose a Bot first), caret in the field.
                AppLog.note("keys", "new chat: bot chat")
                if let id = NewChatKeyBot.profile(among: organizer.services.bots.map(\.id)) {
                    KeyCommands.openBotChat(id, root: root)
                } else {
                    organizer.chooseBot { [weak root] id in if let root { KeyCommands.openBotChat(id, root: root) } }
                }
                return
            }
            AppLog.note("keys", "new chat")
            organizer.composeWithKeyBot()
        }
    }

    /// [cmd-n] ⌥⌘N: a new chat like the one on show (its bot, its project).
    @objc func hqNewChatHere(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        mainWindowForward()   // [macpass-settings2]
        #endif
        whenUncovered { root in
            guard let organizer = root.sessionsViewController.organizer,
                  let chat = root.chatOnShow?.session as? LiveChatSession else { return }
            AppLog.note("keys", "new chat here")
            organizer.newChat(like: chat)
        }
    }

    /// [cmd-n] ⇧⌘N: New Chat's chooser (a bot, and a project under All), as the Sessions Compose button opens it.
    @objc func hqNewChatWith(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        mainWindowForward()   // [macpass-settings2]
        #endif
        whenUncovered { root in
            guard let organizer = root.sessionsViewController.organizer else { return }
            AppLog.note("keys", "new chat with")
            organizer.compose()
        }
    }

    @objc func hqCloseChat(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if MacSettingsWindow.isKey { MacSettingsWindow.close(); return }   // [mac-layout] ⌘W in Settings closes it
        if let file = KeyCommands.fileInFront { MacFileWindow.close(file); return }   // [mac-files] and a file window
        if KeyCommands.root == nil { hqCloseWindow(sender); return }   // [mac] Mac polish #21: the sign-in form's window
        #endif
        guard let root = uncovered else { return }
        #if targetEnvironment(macCatalyst)
        if !KeyCommands.closeChatCloses(root) { hqCloseWindow(sender); return }   // [mac]
        #endif
        AppLog.note("keys", "close chat")
        if root.split?.isDouble == true {
            #if targetEnvironment(macCatalyst)
            if root.split?.macWorkspaceBar.closeActiveTab() == true { return }
            #endif
            root.closeDetail(animated: true)
        } else if let chat = root.chatOnShow {
            chat.navigationController?.popToRootViewController(animated: true)
        }
    }

    @objc func hqBack(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if let settings = KeyCommands.settingsInFront {   // [mac] Mac polish #12
            guard KeyCommands.presented(settings) == nil, KeyCommands.canGoBack(settings) else { return }
            AppLog.note("keys", "back (settings window)")
            KeyCommands.goBack(settings)
            return
        }
        #endif
        guard let root = uncovered, KeyCommands.canGoBack(root) else { return }
        AppLog.note("keys", "back")
        KeyCommands.escapeGoBack(root)
    }

    /// [mac] The window's red button: the scene goes, the app stays (a click on its Dock icon opens it again).
    @objc func hqCloseWindow(_ sender: Any?) {
        guard let scene = KeyCommands.root?.view.window?.windowScene
                ?? UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) else { return }
        AppLog.note("keys", "close window")
        #if targetEnvironment(macCatalyst)
        // The app has one scene (UIApplicationSupportsMultipleScenes NO), and Catalyst ignores a destruction request for
        // it: the window stayed. AppKit's own performClose: on the key window is what the red button does.
        if let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
           let window = (app.value(forKey: "keyWindow") ?? app.value(forKey: "mainWindow")) as? NSObject,
           window.responds(to: NSSelectorFromString("performClose:")) {
            window.perform(NSSelectorFromString("performClose:"), with: nil)
            return
        }
        #endif
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
    }

    @objc func hqFind(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if let settings = KeyCommands.settingsInFront {   // [mac] Mac polish #12
            AppLog.note("keys", "find (settings window)")
            // [mac-ui-issues] A page with no search of its own (and no sheet over it): the column's Search Settings field.
            if KeyCommands.presented(settings) == nil, let root = MacSettingsWindow.root, root.paneStack != nil,
               !KeyCommands.canSearch(settings.topViewController) {
                root.model.focusSearch += 1
                return
            }
            KeyCommands.openSearch(KeyCommands.settingsSearchPage(settings))
            return
        }
        #endif
        if let root = KeyCommands.root, let page = KeyCommands.sheetSearchPage(root) {
            AppLog.note("keys", "find: sheet's search")
            KeyCommands.openSearch(page)
            return
        }
        guard let root = uncovered else { AppLog.note("keys", "find: covered"); return }
        AppLog.note("keys", "find")
        if let chat = root.chatOnShow {
            #if targetEnvironment(macCatalyst)
            MacSelection.focus(on: .detail)
            #endif
            chat.showFind()
        } else {
            #if targetEnvironment(macCatalyst)
            MacSelection.focus(on: .list)
            #endif
            KeyCommands.openSearch(KeyCommands.findTarget(root))
        }
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 #15: ⌘G / ⇧⌘G, the Find bar's ↓ and ↑.
    @objc func hqFindNext(_ sender: Any?) { uncovered?.chatOnShow?.findController?.step(forward: true) }
    @objc func hqFindPrevious(_ sender: Any?) { uncovered?.chatOnShow?.findController?.step(forward: false) }
    #endif

    @objc func hqSearchSessions(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        mainWindowForward()   // [macpass-settings2]
        #endif
        guard let root = uncovered else { return }
        #if targetEnvironment(macCatalyst)
        // [keys] Mac UI check 2026-11-13 (K1): with Sessions taken out of the sidebar its search had nowhere to show (the
        // Bots list it fell back to is folded into the sidebar): Open Quickly, which finds the sessions too, opens.
        if root.controller(for: .sessions) == nil {
            AppLog.note("keys", "search sessions: no Sessions place, open quickly")
            hqOpenQuickly(sender)
            return
        }
        #endif
        AppLog.note("keys", "search sessions")
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #14: a Bots tab chat left on the right beside the Sessions search (no row of
        // its own to mark there) goes back over the Bots list, as a tab click does (`switchPlace`).
        let pick = { if root.shownTab != .sessions { root.select(.sessions) } }
        if let split = root.split { split.switchPlace(to: root.controller(for: .sessions), pick) } else { pick() }
        #else
        if root.shownTab != .sessions { root.select(.sessions) }
        root.split?.setListHidden(false)   // [ipad-polish] the search is in the list
        #endif
        root.sessionsViewController.navigationController?.popToRootViewController(animated: false)
        root.sessionsViewController.loadViewIfNeeded()
        #if targetEnvironment(macCatalyst)
        MacSelection.focus(on: .list)
        #endif
        KeyCommands.openSearch(root.sessionsViewController)
    }

    /// [quick-actions] ⇧⌘K: the Quick Actions page as a sheet, as every shortcut opens it (DECISION I22).
    @objc func hqQuickActions(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        mainWindowForward()
        #endif
        AppLog.note("keys", "quick actions")
        Task { await QuickActionsRouter.present(from: "keys") }
    }

    /// ⌘K: More's search, which finds sessions, pages and actions, opened with the caret in it.
    @objc func hqOpenQuickly(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        mainWindowForward()   // [macpass-settings2]
        if MacOpenQuickly.refocusIfShown() { return }
        #endif
        guard let root = uncovered, let more = root.pages?.more, let stack = more.navigationController,
              let index = root.slotIndex(for: stack) else { return }
        AppLog.note("keys", "open quickly")
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #61: a panel floating over the window with the latest chats, not More's field
        // over the list. A result picks More first, as below, and opens from its stack as More's search does.
        more.loadViewIfNeeded()
        if let search = more.quickSearch, let host = root.view.window?.rootViewController {
            MacOpenQuickly.present(from: host, search: search, ownTab: { kind, item in
                MacOpenQuickly.openOnOwnTab(root, kind, item)
            }) {
                if let split = root.split { split.switchPlace(to: stack) { root.selectedIndex = index } } else { root.selectedIndex = index }
                stack.popToRootViewController(animated: false)
            }
            return
        }
        #endif
        #if targetEnvironment(macCatalyst)
        // [mac] stress test #14 / #62: as a tab click
        if let split = root.split { split.switchPlace(to: stack) { root.selectedIndex = index } } else { root.selectedIndex = index }
        #else
        root.selectedIndex = index
        #endif
        stack.popToRootViewController(animated: false)
        more.loadViewIfNeeded()
        more.openSearchFromKeyboard()
    }

    #if targetEnvironment(macCatalyst)
    /// [Mac AAA 2026-11-17] Owner's call Q10: Window › New Tab, Show Previous Tab, Show Next Tab (the Terminal in front).
    @objc func hqTerminalNewTab(_ sender: Any?) {
        guard let terminal = TerminalViewController.front else { return }
        AppLog.note("keys", "terminal: new tab")
        terminal.menuNewTab()
    }

    @objc func hqTerminalNextTab(_ sender: Any?) {
        if let terminal = TerminalViewController.front {
            AppLog.note("keys", "terminal: next tab")
            terminal.menuCycle(1)
            return
        }
        if let root = uncovered, KeyCommands.cycleWindowTabs(root, step: 1) {
            AppLog.note("keys", "window tabs: next tab")
        }
    }

    @objc func hqTerminalPreviousTab(_ sender: Any?) {
        if let terminal = TerminalViewController.front {
            AppLog.note("keys", "terminal: previous tab")
            terminal.menuCycle(-1)
            return
        }
        if let root = uncovered, KeyCommands.cycleWindowTabs(root, step: -1) {
            AppLog.note("keys", "window tabs: previous tab")
        }
    }

    /// [mac-feel D30] Page Up, Page Down, Home, End: the chat on show scrolls (which key: `KeyCommands.scrollKey`).
    @objc func hqScrollChat(_ sender: Any?) {
        guard let key = KeyCommands.scrollKey(input: (sender as? UIKeyCommand)?.input) else { return }
        scrollChat(key)
    }

    /// True when a chat is on show to scroll (false: under a sheet, or no chat open, and the key passes on).
    @discardableResult
    func scrollChat(_ key: ChatViewController.KeyScroll) -> Bool {
        guard let chat = uncovered?.chatOnShow else { return false }
        chat.keyScroll(key)
        return true
    }
    #endif

    @objc func hqMessageField(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if let root = uncovered, root.chatOnShow == nil, let (list, path) = KeyCommands.focusedRow(root) {
            AppLog.note("keys", "return: open the focused row")
            list.selectItem(at: path, animated: false, scrollPosition: [])
            list.delegate?.collectionView?(list, didSelectItemAt: path)
            return
        }
        #endif
        guard let chat = uncovered?.chatOnShow else { return }
        AppLog.note("keys", "message field")
        #if targetEnvironment(macCatalyst)
        MacSelection.focus(on: .detail)
        #endif
        chat.focusComposer()
    }

    /// [mac] ⌘⌫ on the Mac: the chat's own ⋯ › Delete, which asks first.
    @objc func hqDeleteChat(_ sender: Any?) {
        guard let menus = uncovered?.chatOnShow?.menus, menus.canDelete else { return }
        AppLog.note("keys", "delete chat (asks)")
        menus.performListAction(.delete)
    }

    /// ⌘⌫ (⌃⌘A on the Mac): the chat's own ⋯ › Archive (or Unarchive), with its "Archived · Undo" note.
    @objc func hqArchiveChat(_ sender: Any?) {
        guard let menus = uncovered?.chatOnShow?.menus, menus.canArchive else { return }
        AppLog.note("keys", "archive chat")
        menus.performListAction(.archive)
    }

    @objc func hqNextChat(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if (sender as? UIKeyCommand)?.input == "\t", let root = uncovered, KeyCommands.cycleWindowTabs(root, step: 1) {
            AppLog.note("keys", "window tabs: next tab (⌃Tab)")
            return
        }
        #endif
        walk(forward: true)
    }

    @objc func hqPreviousChat(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if (sender as? UIKeyCommand)?.input == "\t", let root = uncovered, KeyCommands.cycleWindowTabs(root, step: -1) {
            AppLog.note("keys", "window tabs: previous tab (⌃⇧Tab)")
            return
        }
        #endif
        walk(forward: false)
    }

    private func walk(forward: Bool) {
        guard let root = uncovered, let target = KeyCommands.walkTarget(root, forward: forward) else {
            AppLog.note("keys", forward ? "next chat: at the end" : "previous chat: at the start")
            return
        }
        AppLog.note("keys", forward ? "next chat" : "previous chat")
        // Phone layout: the chat on show gives way to the next one over the same list, in one step (the list between
        // them is never shown).
        ChatViewController.replacesTopOnNextPush = root.split?.isDouble != true && root.paneChatOnShow != nil
        #if targetEnvironment(macCatalyst)
        if root.split?.isDouble == true, root.split?.tabs.view.isHidden == false { MacSelection.focus(on: .list) }
        #endif
        target.open(target.key)
        ChatViewController.replacesTopOnNextPush = false
    }

    @objc func hqSelectTab(_ sender: Any?) {
        guard let index = (sender as? UICommand)?.propertyList as? Int else { return }
        #if targetEnvironment(macCatalyst)
        mainWindowForward()   // [macpass-settings2]
        #endif
        whenUncovered { root in
            let places = root.placedTabs   // [mac-sidebar] every sidebar place, ⌘9 the last of more than nine
            guard let place = KeyCommands.tabIndex(forShortcut: index, among: places.map { $0.tabBarItem.tag }) else { return }
            #if targetEnvironment(macCatalyst)
            // [mac] stress test #62: the right pane follows the tab, as a click does (`switchPlace`)
            if let split = root.split { split.switchPlace(to: places[place]) { root.show(places[place]) } } else { root.show(places[place]) }
            MacSelection.focus(on: .sidebar)   // [mac] Stress test 2026-10-28 #54: its mark is the accent, as after a click
            #else
            root.show(places[place])
            root.split?.setListHidden(false)   // [ipad-polish] a tab picked by key is its list: put away, it comes back
            #endif
        }
    }

    @objc func hqSettings(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if MacSettingsWindow.open() { return }   // [mac-layout] Settings is a window of its own
        #endif
        whenUncovered { root in
            guard root.pages?.more != nil else { return }
            AppLog.note("keys", "settings")
            if root.split?.isDouble == true, root.split?.detail.viewControllers.first is SettingsRootController { return }
            root.showSettings()   // its own tab when it has one: More then has no Settings row
        }
    }

    @objc func hqToggleList(_ sender: Any?) {
        AppLog.note("keys", "hide or show the list")
        KeyCommands.root?.split?.toggleList()
    }

    @objc func hqRefresh(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if let settings = KeyCommands.settingsInFront {   // [mac] Mac polish #12
            let refresh = KeyCommands.presented(settings) != nil ? KeyCommands.sheetRefresh(settings)
                : settings.topViewController.flatMap(Self.refreshAction)
            AppLog.note("keys", "refresh (settings window)")
            refresh?()
            return
        }
        #endif
        if let root = KeyCommands.root, let refresh = KeyCommands.sheetRefresh(root) {
            AppLog.note("keys", "refresh (sheet)")
            refresh()
            return
        }
        guard let root = uncovered, let refresh = Self.refreshTarget(root) else { return }
        AppLog.note("keys", "refresh")
        refresh()
    }

    @objc func hqSend(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if let settings = KeyCommands.settingsInFront {   // [mac] Mac polish #12: the Settings page's own Save
            if let save = KeyCommands.saveCommand(in: KeyCommands.presented(settings) ?? settings), let action = save.command.action {
                UIApplication.shared.sendAction(action, to: save.owner, from: save.command, for: nil)
            }
            return
        }
        if let root = KeyCommands.root, KeyCommands.presented(root) != nil {
            // [mac] ⌘Return over a sheet: the sheet's own ⌘Return command (see `validate`).
            if let save = KeyCommands.sheetSave(root), let action = save.command.action {
                UIApplication.shared.sendAction(action, to: save.owner, from: save.command, for: nil)
            }
            return
        }
        #endif
        guard let composer = uncovered?.chatOnShow?.composer, composer.primary == .send else { return }
        composer.hardwareSend()
    }

    @objc func hqMessageActions(_ sender: Any?) {
        guard let chat = uncovered?.chatOnShow else { return }
        AppLog.note("keys", "message actions")
        chat.openMessageActionsForNewest()
    }

    @objc func hqEscape(_ sender: Any?) {
        #if targetEnvironment(macCatalyst)
        if let settings = KeyCommands.settingsInFront { escapeInSettings(settings); return }   // [mac] Mac polish #12
        if let file = KeyCommands.fileInFront { escapeInFileWindow(file); return }   // [mac-files]
        #endif
        guard let root = KeyCommands.root else { return }
        // Each press takes one step of the ladder (the commands do not repeat while held), so Escape, Escape closes
        // Find and then stops the reply however quickly they come.
        let action = EscapeAction.decide(KeyCommands.escapeState(root))
        AppLog.note("keys", "escape: \(action)")
        switch action {
        case .system:
            #if targetEnvironment(macCatalyst)
            if let alert = AlertCancel.typing(KeyCommands.presented(root)) { AlertCancel.close(alert) }   // [mac] #17
            #endif
            break
        case .nothing:
            if KeyCommands.escapePageStep(root) == .goBack { KeyCommands.escapeGoBack(root) }   // [morepages] §9
        case .skipQuestion:
            #if targetEnvironment(macCatalyst)
            // [mac-audit] Owner 2026-11-02 (Mac audit #26): a bot's question card on the Mac takes Escape as Skip (out
            // of its "Something else…" field first). Skip asks before throwing answers away, and it answers the
            // question rather than cancelling the turn, so the ladder's "never cancel a parked turn" still holds.
            // An approval card still takes nothing. Mac polish #7: the step is the ladder's own now, so `validate`
            // lights the menu item (it was dimmed, so the key never reached here).
            KeyCommands.questionCard(root)?.escapePressed()
            #else
            break   // never decided off the Mac (`questionSkips` stays off there)
            #endif
        case .closeModelPanel:
            root.chatOnShow?.menus?.closeModelPanel()   // [keys] Mac polish #13: the panel, not the reply behind it
        case .dismissPresented:
            if let top = KeyCommands.presented(root) { KeyCommands.closePresented(top) }
        case .closeFind:
            root.chatOnShow?.findController?.close()
        case .closeDrawer:
            root.chatOnShow?.drawer?.close()   // [composer-drawers] the words stay; the next keystroke may open it again
        case .cancelRecording:
            // The recorder's own delete: it asks first when the take is long enough to matter.
            MemoController.shared.input(.delete)
        case .cancelSearch:
            KeyCommands.cancelSearch(KeyCommands.activeSearch(root))
        case .stop:
            guard let chat = root.chatOnShow else { return }
            // A second press while the first Stop is still on its way to the gateway does not interrupt again.
            let now = ProcessInfo.processInfo.systemUptime
            if KeyCommands.stopAsked.session === (chat.session as AnyObject), now - KeyCommands.stopAsked.at < 2 { return }
            KeyCommands.stopAsked = (chat.session as AnyObject, now)
            Haptics.play(.rigid)
            chat.composer.onStop?()
        case .resignField:
            root.chatOnShow?.composer.textView.resignFirstResponder()
        }
    }
}

extension ComposerView {
    /// ⌘Return: what the Send button does right now, except that while a reply runs it does what Return doesn't: the
    /// message waits in the queue, or goes into the reply when Settings › Chat › Send While Replying is Queue.
    func hardwareSend() { (textView as? ComposerTextView)?.onHardwareReturn?(true) }
}

extension UINavigationController {
    /// The chat opened from this list stack: on top of it in the phone layout, in the right pane in two panes.
    var paneChat: ChatViewController? {
        if let standIn = (self as? PaneNavigationController)?.standIn { return standIn.paneChat }   // [customtabs]
        if let chat = topViewController as? ChatViewController { return chat }
        guard let root = tabBarController as? MainTabController, let split = root.split, split.isDouble, split.origin === self else { return nil }
        return split.detail.topViewController as? ChatViewController
    }
}

extension KanbanBoardListController: ListPaneContent {}

#if targetEnvironment(macCatalyst)
/// [macpass] 2026-11-14 (Mac full pass, round 2): Escape and ⌘. never closed a sheet (New Job, Edit Job, Bot Info, a
/// step's sheet, Star Map's skill, Select Text…), changed or not; only Cancel and Done did. The Mac shows a sheet in a
/// window of its own (`_UIBridgedPresentationWindow`), and there a key command never matches, the menu bar's included
/// (View's Close, the app's ⌘.): with nothing focused the press met no responder, and a focused field's keys go the
/// AppKit way and never reach UIKit at all. So the app watches its own key presses (an AppKit local monitor, which
/// sees them before any window does): Escape or ⌘. while a sheet's window is key goes to the nearest `hqEscape` in the
/// first responder's chain below the app's (New Chat's Back), as the menu item's action would, else closes the sheet
/// the Mac way (`closeSheet`), or takes the Cancel of an alert over it. An input method's composition keeps its Escape.
@MainActor enum SheetKeys {
    private static var monitor: AnyObject?
    /// The key code of the Escape press taken when it went down, so its release is taken too.
    private static var taken: UInt16?

    static func install() {
        guard monitor == nil, let events = NSClassFromString("NSEvent"),
              let method = class_getClassMethod(events, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")) else { return }
        typealias Handler = @convention(block) (NSObject) -> NSObject?
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping Handler) -> AnyObject?
        let add = unsafeBitCast(method_getImplementation(method), to: Add.self)
        let keyDown: UInt64 = 1 << 10, keyUp: UInt64 = 1 << 11
        monitor = add(events, NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:"), keyDown | keyUp) { event in
            let taken = MainActor.assumeIsolated { take(event) }
            return taken ? nil : event
        }
    }

    /// True when the AppKit key event is Escape's (or ⌘.'s) in a sheet's window and was handled here.
    private static func take(_ event: NSObject) -> Bool {
        guard let code = (event.value(forKey: "keyCode") as? NSNumber)?.uint16Value,
              let type = (event.value(forKey: "type") as? NSNumber)?.uintValue else { return false }
        if type == 11 {   // key up
            guard taken == code else { return false }
            taken = nil
            return true
        }
        let flags = (event.value(forKey: "modifierFlags") as? NSNumber)?.uintValue ?? 0
        let mods = flags & (1 << 17 | 1 << 18 | 1 << 19 | 1 << 20)   // shift, control, option, command
        // [mac-session-tabs] AppKit swallows ⌃Tab / ⌃⇧Tab before UIKit sees them; with no Terminal, sheet or other
        // window in front they walk the window's tabs (the row at its very top) here, as Safari's do.
        let controlTab = code == 48 && (mods == 1 << 18 || mods == ((1 << 18) | (1 << 17)))
        if controlTab, (event.value(forKey: "isARepeat") as? Bool) != true,
           !composing(), sheetWindow() == nil, appWindowIsKey(),
           KeyCommands.settingsInFront == nil, KeyCommands.fileInFront == nil,
           TerminalViewController.front == nil,
           let root = KeyCommands.root, KeyCommands.presented(root) == nil {
            let step = (mods & (1 << 17)) != 0 ? -1 : 1
            if KeyCommands.cycleWindowTabs(root, step: step) {
                AppLog.note("keys", step > 0 ? "window tabs: next tab (⌃Tab)" : "window tabs: previous tab (⌃⇧Tab)")
                taken = code
                return true
            }
        }
        let characters = event.value(forKey: "charactersIgnoringModifiers") as? String
        let commandPeriod = characters == "." && mods == 1 << 20
        guard (code == 53 && mods == 0) || commandPeriod, (event.value(forKey: "isARepeat") as? Bool) != true else { return false }
        guard let window = sheetWindow(), sheetPage(in: window) != nil else {
            // [keys] Round 3: ⌘. never reached UIKit in the app's own windows either (AppKit keeps it as its Cancel):
            // the photo viewer, a reply running, a search, all ignored it while Escape worked. It goes where the menu's
            // Escape item would.
            guard commandPeriod, !composing(), appWindowIsKey() else { return false }
            AppLog.note("keys", "⌘. in the window: as Escape")
            guard UIApplication.shared.sendAction(KeyCommands.escape, to: nil, from: nil, for: nil) else { return false }
            taken = code
            return true
        }
        if composing() { return false }
        if escapeInChain(from: window.hqFirstResponder, in: window) || closeSheet(in: window) {
            taken = code
            return true
        }
        return false
    }

    /// The window of a sheet on show, when it is key (the app's scenes don't list it: found through what is presented).
    private static func sheetWindow() -> UIWindow? {
        guard let type = NSClassFromString("_UIBridgedPresentationWindow") else { return nil }
        var found: [UIWindow] = []
        for root in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).compactMap(\.rootViewController) {
            var next = root.presentedViewController
            while let page = next {
                if let window = page.viewIfLoaded?.window, window.isKind(of: type), !found.contains(window) { found.append(window) }
                next = page.presentedViewController
            }
        }
        return found.first { $0.isKeyWindow }
    }

    /// One of the app's own windows (the main window, Settings, a Files window) has the keyboard: not a panel, the
    /// Open Quickly field or a menu.
    private static func appWindowIsKey() -> Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController != nil }
    }

    /// An input method is composing (marked text) in the key window's field, UIKit's or AppKit's.
    private static func composing() -> Bool {
        if (sheetWindow()?.hqFirstResponder?.hqTypingInput as? UITextInput)?.markedTextRange != nil { return true }
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let first = (app.value(forKey: "keyWindow") as? NSObject)?.value(forKey: "firstResponder") as? NSObject,
              first.responds(to: NSSelectorFromString("hasMarkedText")) else { return false }
        return first.value(forKey: "hasMarkedText") as? Bool == true
    }

    /// The nearest `hqEscape` in the first responder's chain inside the sheet (past it are the pages it covers, and
    /// the app's own Escape, which acts on the main window).
    private static func escapeInChain(from first: UIResponder?, in window: UIWindow) -> Bool {
        func inSheet(_ responder: UIResponder) -> Bool {
            if let view = responder as? UIView { return view.window === window && view !== window }
            return (responder as? UIViewController)?.viewIfLoaded?.window === window
        }
        var next = first
        while let responder = next, inSheet(responder) {
            if responder.responds(to: KeyCommands.escape), responder.canPerformAction(KeyCommands.escape, withSender: nil) {
                AppLog.note("keys", "escape (sheet window): \(type(of: responder))'s own")
                _ = responder.perform(KeyCommands.escape, with: nil)
                return true
            }
            next = responder.next
        }
        return false
    }

    /// The deepest presented page (not an alert) whose view is in `window`.
    static func sheetPage(in window: UIWindow) -> UIViewController? {
        let roots = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).compactMap(\.rootViewController)
        var found: UIViewController?
        for root in roots {
            var next = root.presentedViewController
            while let page = next {
                if page.viewIfLoaded?.window === window, !(page is UIAlertController), !page.isBeingDismissed { found = page }
                next = page.presentedViewController
            }
        }
        return found
    }

    /// Escape or ⌘. in a sheet's window: the top of what is over the sheet closes as its Cancel, ✕ or a pull down
    /// would (asking first over unsaved changes, `KeyCommands.closePresented`). An alert there (Discard Changes' own
    /// question, a prompt) takes its Cancel button, as the system's Escape does for an alert in the main window.
    private static func closeSheet(in window: UIWindow) -> Bool {
        guard var top = sheetPage(in: window) else { return false }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if let alert = top as? UIAlertController {
            if let typing = AlertCancel.typing(alert) { AlertCancel.close(typing); return true }
            return cancel(alert)
        }
        guard KeyCommands.canDismiss(top) else { return false }
        AppLog.note("keys", "escape (sheet window): close \(type(of: top))")
        KeyCommands.closePresented(top)
        return true
    }

    /// Taps `alert`'s Cancel (its handler runs, as a click's would). False when it has none: the key does nothing.
    private static func cancel(_ alert: UIAlertController) -> Bool {
        let selector = NSSelectorFromString("_dismissAnimated:triggeringAction:")
        guard let action = alert.actions.first(where: { $0.style == .cancel && $0.isEnabled }),
              let method = class_getInstanceMethod(object_getClass(alert), selector) else { return false }
        typealias Dismiss = @convention(c) (AnyObject, Selector, Bool, UIAlertAction) -> Void
        AppLog.note("keys", "escape (sheet window): alert's \(action.title ?? "Cancel")")
        unsafeBitCast(method_getImplementation(method), to: Dismiss.self)(alert, selector, true, action)
        return true
    }
}
#endif

#if DEBUG
/// The app's window in DEBUG builds. It notes, in the app's log, each key press that arrives with Command held (the
/// key's keyboard usage number, never text, and never a press without Command) and each time the window gains or
/// loses the keyboard. With these a shortcut that did nothing can be told apart: the press never reached the app, the
/// window was not the one with the keyboard, or the app ignored it (stress rounds 1 and 2: Command-F once in a run
/// did nothing and the log could not say which).
final class KeyLogWindow: MeteredWindow {
    /// How many such presses arrived, also written to the file a UI test names (`HQN_KEY_COUNT_FILE`), so the test
    /// can tell a press the simulator never delivered from one the app did nothing with.
    private static var arrived = 0
    private static let countFile = ProcessInfo.processInfo.environment["HQN_KEY_COUNT_FILE"].flatMap { $0.isEmpty ? nil : $0 }

    override func sendEvent(_ event: UIEvent) {
        if let presses = (event as? UIPressesEvent)?.allPresses {
            for press in presses where press.phase == .began {
                guard let key = press.key, key.modifierFlags.contains(.command) else { continue }
                Self.arrived += 1
                if let file = Self.countFile { try? "\(Self.arrived)".write(toFile: file, atomically: true, encoding: .utf8) }
                AppLog.note("keys", "command press \(key.keyCode.rawValue) (key window: \(isKeyWindow), first responder: \(firstResponderForLog ?? "none"))")
            }
        }
        super.sendEvent(event)
    }

    override func becomeKey() {
        super.becomeKey()
        AppLog.note("keys", "window has the keyboard")
    }

    override func resignKey() {
        super.resignKey()
        AppLog.note("keys", "window lost the keyboard")
    }
}

extension UIView {
    /// The type of the first responder under this view, for the DEBUG key log.
    var firstResponderForLog: String? {
        if isFirstResponder { return String(describing: type(of: self)) }
        for child in subviews { if let found = child.firstResponderForLog { return found } }
        return nil
    }
}
#endif
