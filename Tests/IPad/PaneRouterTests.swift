// [m9/ipad] The two-pane root and the routing seam on real controllers (docs/spec/3x-ipad.md §9): a screen opened
// from a list lands in the right pane in two panes and on the list's stack in the phone layout; crossing between the
// layouts moves the same chat screen and keeps it attached to its session.

import Testing
import UIKit
@testable import HermesHQNative

@Suite("iPad panes", .serialized) @MainActor struct PaneRouterTests {
    final class Folder: UIViewController, ListPaneContent {}

    struct Rig {
        let window: UIWindow
        let split: RootSplitController
        var tabs: MainTabController { split.tabs }
        var bots: UINavigationController { tabs.botsViewController.navigationController! }
        var sessions: UINavigationController { tabs.sessionsViewController.navigationController! }

        func chat(_ title: String = "Hermes") -> (ChatViewController, FakeChatSession) {
            let session = FakeChatSession(count: 40, title: title)
            return (ChatViewController(session: session), session)
        }

        func narrow() { split.setDebugSize(width: 420, height: nil) }
        func wide() { split.setDebugSize(width: nil, height: nil) }
        func close() {
            split.setDebugSize(width: nil, height: nil)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    static func rig() throws -> Rig {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        let tabs = MainTabController(services: FakeAppServices()) { ChatViewController(session: $0) }
        let split = RootSplitController(tabs: tabs, size: window.bounds.size)
        split.setDebugSize(width: nil, height: nil)
        window.rootViewController = split
        window.isHidden = false
        window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        split.view.frame = window.bounds
        split.view.layoutIfNeeded()
        return Rig(window: window, split: split)
    }

    @Test func twoPanesPutAnOpenedScreenOnTheRight() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        #expect(rig.split.isDouble)
        #expect(rig.split.layout == .double(sidebar: 375))
        #expect(rig.split.detailIsEmpty)
        #expect(rig.tabs.chatOnShow == nil)
        #expect(rig.tabs.view.frame.width == 375)
        #expect(rig.split.detail.view.frame.minX > 375)
        #expect(rig.tabs.traitCollection.horizontalSizeClass == .compact)

        let (chat, _) = rig.chat()
        rig.tabs.botsViewController.openDetail(chat, animated: false)
        #expect(rig.bots.viewControllers.count == 1)                 // the list's stack stays at its root
        #expect(rig.split.detail.viewControllers == [chat])
        #expect(rig.tabs.chatOnShow === chat)
        #expect(rig.split.origin === rig.bots)
        #expect(rig.bots.paneChat === chat)
        #expect(rig.sessions.paneChat == nil)

        // A plain push from the list's stack is routed too (other streams' call sites need no change).
        let (second, _) = rig.chat("Ivy")
        rig.sessions.pushViewController(second, animated: false)
        #expect(rig.sessions.viewControllers.count == 1)
        #expect(rig.split.detail.viewControllers == [second])
        #expect(rig.split.origin === rig.sessions)
        #expect(rig.tabs.paneChatOnShow?.tab == .sessions)

        // A screen the right pane's own stack pushes stays there, with a way back.
        let page = UIViewController()
        second.navigationController?.pushViewController(page, animated: false)
        #expect(rig.split.detail.viewControllers == [second, page])
    }

    @Test func aListDrillDownStaysOnTheLeft() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let folder = Folder()
        rig.bots.pushViewController(folder, animated: false)
        #expect(rig.bots.viewControllers.last === folder)
        #expect(rig.split.detailIsEmpty)
        // A chat opened from the drill-down goes right; the drill-down stays.
        let (chat, _) = rig.chat()
        folder.openDetail(chat, animated: false)
        #expect(rig.bots.viewControllers.last === folder)
        #expect(rig.split.detail.viewControllers == [chat])
    }

    @Test func thePhoneLayoutPushesOnTheListsStack() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        rig.narrow()
        #expect(!rig.split.isDouble)
        #expect(rig.split.detail.view.isHidden)
        #expect(rig.tabs.view.frame.width == 420)
        let (chat, _) = rig.chat()
        rig.tabs.botsViewController.openDetail(chat, animated: false)
        #expect(rig.bots.viewControllers.last === chat)
        #expect(rig.split.detailIsEmpty)
        #expect(rig.tabs.chatOnShow === chat)
        rig.tabs.closeDetail(animated: false)
        #expect(rig.bots.viewControllers.count == 1)
        #expect(rig.tabs.chatOnShow == nil)
    }

    @Test func crossingTheThresholdMovesTheSameChatAndKeepsItAttached() async throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        rig.tabs.selectedIndex = 1
        let (chat, session) = rig.chat()
        rig.tabs.sessionsViewController.openDetail(chat, animated: false)
        rig.split.view.layoutIfNeeded()
        chat.loadViewIfNeeded()
        chat.view.layoutIfNeeded()
        #expect(session.onChange != nil)                              // attached
        chat.composer.text = "a draft"
        rig.tabs.selectedIndex = 0                                    // another tab on the left

        for _ in 0..<5 {
            rig.narrow()
            #expect(!rig.split.isDouble)
            #expect(rig.split.detailIsEmpty)
            #expect(rig.tabs.selectedIndex == 1)                      // the phone layout lands on the chat's own list (D14)
            #expect(rig.sessions.viewControllers.last === chat)
            #expect(rig.sessions.viewControllers.count == 2)
            #expect(chat.hidesBottomBarWhenPushed)
            #expect(session.onChange != nil)                          // still attached: the stream keeps arriving
            #expect(chat.composer.text == "a draft")
            #expect(rig.tabs.chatOnShow === chat)

            rig.wide()
            #expect(rig.split.isDouble)
            #expect(rig.split.detail.viewControllers == [chat])
            #expect(rig.sessions.viewControllers.count == 1)
            #expect(rig.split.origin === rig.sessions)
            #expect(session.onChange != nil)
            #expect(chat.composer.text == "a draft")
            #expect(rig.tabs.chatOnShow === chat)
        }

        // Closing the chat for real does detach it.
        rig.tabs.closeDetail(animated: false)
        #expect(rig.split.detailIsEmpty)
        // UIKit reports the removal once the swap settles.
        for _ in 0..<40 where session.onChange != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.onChange == nil)
    }

    @Test func expandingKeepsOnlyTheSelectedTabsChat() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        rig.narrow()
        let (first, firstSession) = rig.chat()
        let (second, _) = rig.chat("Ivy")
        rig.tabs.selectedIndex = 0
        rig.bots.pushViewController(first, animated: false)
        rig.tabs.selectedIndex = 1
        rig.sessions.pushViewController(second, animated: false)
        first.loadViewIfNeeded()
        rig.wide()
        #expect(rig.split.detail.viewControllers == [second])          // the tab on show wins the one right pane
        #expect(rig.bots.viewControllers.count == 1)                   // the other goes back to its list
        #expect(rig.sessions.viewControllers.count == 1)
        _ = firstSession
    }

    @Test func leavingAChatEmptiesTheRightPane() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let (chat, _) = rig.chat()
        rig.tabs.botsViewController.openDetail(chat, animated: false)
        rig.tabs.leave(chat, animated: false)
        #expect(rig.split.detailIsEmpty)
        #expect(rig.split.detail.viewControllers.first is DetailPlaceholderViewController)
        #expect(rig.tabs.nothingOpen)
    }

    /// Escape goes back on the right pane's own stack (a sub-page of a page open there) once the list is at its root,
    /// and ⌘F / ⌘R aim at the page on show there.
    @Test func escapeGoesBackOnTheRightPane() async throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let page = UIViewController()
        rig.tabs.botsViewController.openDetail(page, animated: false)
        #expect(KeyCommands.pageOnShow(rig.tabs) === page)
        #expect(EscapeRule.context(KeyCommands.escapeFacts(rig.tabs)) == .tabRoot)
        rig.split.detail.pushViewController(UIViewController(), animated: false)
        #expect(KeyCommands.backStack(rig.tabs) === rig.split.detail)
        #expect(EscapeRule.context(KeyCommands.escapeFacts(rig.tabs)) == .pushedPage)
        KeyCommands.escapeGoBack(rig.tabs)
        // The pop is animated, as the Back button's is.
        for _ in 0..<40 where rig.split.detail.topViewController !== page { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.split.detail.topViewController === page)
        #expect(rig.bots.viewControllers.count == 1)
    }

    @Test func aGatewaySwitchEmptiesTheRightPane() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let (chat, _) = rig.chat()
        rig.tabs.botsViewController.openDetail(chat, animated: false)
        rig.tabs.installTabs(fresh: true)
        #expect(rig.split.detailIsEmpty)
        // The new stacks route as the old ones did.
        let (next, _) = rig.chat()
        rig.tabs.botsViewController.openDetail(next, animated: false)
        #expect(rig.split.detail.viewControllers == [next])
    }

    /// A rotation that keeps two panes still changes the width the next chat opens at (§4.6).
    @Test func theOpeningSizeFollowsEverySizeChange() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let pixel = 1 / max(1, UITraitCollection.current.displayScale)
        rig.window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        rig.split.view.frame = rig.window.bounds
        rig.split.view.layoutIfNeeded()
        #expect(rig.split.layout == .double(sidebar: 375))
        #expect(abs((ChatViewController.openingSize?.width ?? 0) - (1024 - 375 - pixel)) < 0.01)
        rig.window.frame = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        rig.split.view.frame = rig.window.bounds
        rig.split.view.layoutIfNeeded()
        #expect(rig.split.layout == .double(sidebar: 375))
        #expect(abs((ChatViewController.openingSize?.width ?? 0) - (1366 - 375 - pixel)) < 0.01)
        #expect(ChatViewController.openingSize?.height == 1024)
        rig.narrow()
        #expect(ChatViewController.openingSize?.width == 420)
    }

    /// The row of the chat already on show builds nothing; a screen rejected by the right pane is torn down.
    @Test func theChatOnShowIsNotBuiltAgain() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let (chat, session) = rig.chat()
        rig.tabs.botsViewController.openDetail(chat, animated: false)
        chat.loadViewIfNeeded()
        #expect(session.onChange != nil)
        // The same session again (what `isSameChat` matches in a fake): the pane keeps the screen it has, attached.
        let again = ChatViewController(session: session)
        again.loadViewIfNeeded()
        rig.split.show([again], from: rig.bots, animated: false)
        #expect(rig.split.detail.viewControllers.first === chat)
        #expect(session.onChange != nil)
    }

    @Test func aShortWindowIsThePhoneLayout() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        rig.split.setDebugSize(width: nil, height: 480)
        #expect(!rig.split.isDouble)
        rig.split.setDebugSize(width: 900, height: nil)
        #expect(rig.split.layout == .double(sidebar: 375))
        #expect(ChatViewController.openingSize?.width ?? 0 < 900 - 375)
    }

    /// A tester's iPad (build 337, 2026-10-24): as the app leaves, iPadOS lays it out narrower for its app-switcher
    /// snapshots and widens it back, and moving the open chat onto its list for that ended the app. Away, the panes hold;
    /// the return applies the size the window has then.
    @Test func theSnapshotsAsTheAppLeavesMoveNothingBetweenThePanes() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let (chat, session) = rig.chat()
        rig.tabs.botsViewController.openDetail(chat, animated: false)
        chat.loadViewIfNeeded()
        rig.split.view.layoutIfNeeded()
        let detailFrame = rig.split.detail.view.frame
        let center = NotificationCenter.default
        center.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        for _ in 0..<3 {
            rig.narrow()                                              // a snapshot's size
            #expect(rig.split.isDouble)
            #expect(rig.split.detail.viewControllers == [chat])
            #expect(rig.bots.viewControllers.count == 1)
            #expect(rig.split.detail.view.frame == detailFrame)       // the chat isn't laid out again for it
            rig.wide()                                                // and back
            #expect(rig.split.isDouble)
            #expect(rig.split.detail.viewControllers == [chat])
        }
        // Still narrow as the app comes back: the phone layout then, with the same chat, still attached.
        rig.narrow()
        center.post(name: UIScene.willEnterForegroundNotification, object: nil)
        rig.split.view.layoutIfNeeded()
        #expect(!rig.split.isDouble)
        #expect(rig.split.detailIsEmpty)
        #expect(rig.bots.viewControllers.last === chat)
        #expect(session.onChange != nil)
        rig.wide()
        #expect(rig.split.detail.viewControllers == [chat])
    }

    @Test func theAppRootIsTheTabsOnAPhoneAndTheSplitOnAPad() throws {
        let tabs = MainTabController(services: FakeAppServices()) { ChatViewController(session: $0) }
        let root = AppRoot.make(tabs, window: nil)
        if UIDevice.current.userInterfaceIdiom == .pad {
            #expect(root is RootSplitController)
        } else {
            #expect(root === tabs)
            #expect(tabs.split == nil)
        }
    }
}

@MainActor struct KeyCommandTests {
    /// [cmd-n] Tester 2026-11-02: ⌘N starts with one bot, no chooser; ⇧⌘N is the chooser.
    @Test func newChatKeyStartsWithOneBotAndShiftAsks() {
        let items = KeyCommands.fileItems().compactMap { $0 as? UIKeyCommand }
        let plain = items.first { $0.action == KeyCommands.newChat }, with = items.first { $0.action == KeyCommands.newChatWith }
        #expect(plain?.input == "n" && plain?.modifierFlags == .command)
        #expect(with?.input == "n" && with?.modifierFlags == [.command, .shift] && with?.title == "New Chat With…")
        let bots = ["default", "research", "deploys"]
        #expect(NewChatKeyBot.profile(chosen: "default", among: bots) == "default")
        #expect(NewChatKeyBot.profile(chosen: "research", among: bots) == "research")
        #expect(NewChatKeyBot.profile(chosen: "gone", among: bots) == "default", "a bot the gateway no longer has: Hermes")
        #expect(NewChatKeyBot.profile(chosen: "gone", among: ["research"]) == "research", "no Hermes: the first bot")
        #expect(NewChatKeyBot.profile(chosen: "research", among: []) == "research", "roster not read yet: tried as chosen")
        #expect(NewChatKeyBot.profile(chosen: NewChatKeyBot.ask, among: bots) == nil, "Ask Every Time: the chooser")
        // ⌥⌘N: the open chat's bot and project. The project: the chosen one while a bot still has it.
        let here = items.first { $0.action == KeyCommands.newChatHere }
        #expect(here?.input == "n" && here?.modifierFlags == [.command, .alternate] && here?.title == "New Chat Here")
        #expect(NewChatKeyBot.project(chosen: "/srv/q4", among: ["/srv/q4", "/srv/site"]) == "/srv/q4")
        #expect(NewChatKeyBot.project(chosen: "/srv/gone", among: ["/srv/q4"]) == nil, "a project no bot has: none")
        #expect(NewChatKeyBot.project(chosen: nil, among: ["/srv/q4"]) == nil)
        #expect(NewChatKeyBot.Mode.allCases.map(\.title) == ["New Chat", "Bot Chat"], "Jack: ⌘N may open the bot's own chat")
    }

    @Test func everyShortcutHasATitleAndAnAction() {
        let items = KeyCommands.fileItems() + KeyCommands.editItems() + [KeyCommands.settingsItem()]
        let titles = items.compactMap { ($0 as? UIKeyCommand)?.title }
        #expect(titles == ["New Chat", "New Chat Here", "New Chat With…", "Close Chat", "Archive Chat", "Find", "Search Sessions", "Open Quickly…", "Go to Message Field",
                           "Send", "Message Actions", "Settings"])
        for case let command as UIKeyCommand in items {
            #expect(AppDelegate.instancesRespond(to: command.action))
            #expect(command.discoverabilityTitle == command.title)
        }
        let view = KeyCommands.viewItems().compactMap { $0 as? UIMenu }.flatMap(\.children).compactMap { $0 as? UIKeyCommand }
        // One menu item per command (nothing is listed twice in the menu or the hold-⌘ overlay).
        #expect(view.map(\.title) == ["Bots", "Sessions", "Jobs", "Artifacts", "More", "Next Chat", "Previous Chat", "Back", "Refresh", "Stop or Close"])
        for command in view { #expect(AppDelegate.instancesRespond(to: command.action)) }
        // Escape itself is "Stop or Close": the plain key, no modifier, and it does not repeat while held.
        let stop = try! #require(view.last)
        #expect(stop.input == UIKeyCommand.inputEscape && stop.modifierFlags.isEmpty && stop.action == KeyCommands.escape)
        #expect(stop.repeatBehavior == .nonRepeatable)
        // The second keys run the same actions from the app delegate: ⌃Tab, ⌃⇧Tab, ⌘period.
        let alternates = KeyCommands.alternates
        #expect(alternates.map(\.action) == [KeyCommands.nextChat, KeyCommands.previousChat, KeyCommands.escape])
        #expect(alternates.map(\.input) == ["\t", "\t", "."])
        #expect(alternates.map(\.modifierFlags) == [.control, [.control, .shift], .command])
        #expect(alternates.allSatisfy { $0.title.isEmpty })
        // Next / Previous Chat take one step per press on every key they have (a held key does not run the list).
        let walks = view.filter { $0.action == KeyCommands.nextChat || $0.action == KeyCommands.previousChat }
            + alternates.prefix(2) + KeyCommands.walkFromEmptyField
        #expect(walks.count == 6 && walks.allSatisfy { $0.repeatBehavior == .nonRepeatable })
        for title in titles + view.map(\.title) { #expect(!title.lowercased().contains("dispatch")) }
    }

    /// Stress round 1: on the phone layout Command-N from the Bots tab created the session and pushed the chat on
    /// the hidden Sessions stack, so it was never seen. Sessions comes to the front, at its list, with the chat.
    @Test func aChatOpenedWhileAnotherTabShowsBringsSessionsToTheFrontInThePhoneLayout() async throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        rig.narrow()
        #expect(!rig.split.isDouble)
        rig.tabs.selectedIndex = 0
        let stale = UIViewController()
        rig.sessions.pushViewController(stale, animated: false)      // something left open on the hidden tab
        let summary = SessionSummary(id: "s-new", profile: "default", title: "New Chat", preview: nil, lastActive: Date(),
                                     source: nil, unread: false, isRunning: false)
        rig.tabs.sessionsViewController.openChat(summary)
        #expect(rig.tabs.selectedViewController === rig.sessions)
        for _ in 0..<40 where !(rig.sessions.topViewController is ChatViewController) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.sessions.topViewController is ChatViewController)
        #expect(rig.sessions.viewControllers.count == 2)             // list, chat: one Back returns to Sessions
        #expect(!rig.sessions.viewControllers.contains(stale))
        #expect(rig.tabs.chatOnShow != nil)
    }

    /// Two panes: the same call leaves the left pane's tab alone and shows the chat on the right.
    @Test func aChatOpenedWhileAnotherTabShowsStaysOnTheRightInTwoPanes() async throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        #expect(rig.split.isDouble)
        rig.tabs.selectedIndex = 0
        let summary = SessionSummary(id: "s-new", profile: "default", title: "New Chat", preview: nil, lastActive: Date(),
                                     source: nil, unread: false, isRunning: false)
        rig.tabs.sessionsViewController.openChat(summary)
        for _ in 0..<40 where !(rig.split.detail.topViewController is ChatViewController) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.split.detail.topViewController is ChatViewController)
        #expect(rig.tabs.selectedIndex == 0)
        #expect(rig.sessions.viewControllers.count == 1)
    }

    /// Stress round 2: Command-N with a new chat already open on Sessions (phone layout) stacked the next chat on
    /// top of it. A chat just started always sits directly on the list; a chat opened any other way still pushes.
    @Test func aNewChatStartedOverAnOpenChatTakesItsPlaceInThePhoneLayout() async throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        rig.narrow()
        rig.tabs.selectedIndex = 1
        let list = rig.tabs.sessionsViewController
        func summary(_ id: String) -> SessionSummary {
            SessionSummary(id: id, profile: "default", title: "New Chat", preview: nil, lastActive: Date(), source: nil, unread: false, isRunning: false)
        }
        var shown: [ChatViewController] = []
        for id in ["s-1", "s-2", "s-3"] {
            list.openChat(summary(id), fresh: true)
            for _ in 0..<60 where (rig.sessions.topViewController as? ChatViewController).map({ chat in shown.contains { $0 === chat } }) ?? true {
                try await Task.sleep(for: .milliseconds(50))
            }
            let chat = try #require(rig.sessions.topViewController as? ChatViewController)
            #expect(!shown.contains { $0 === chat })                 // the new one is on show
            shown.append(chat)
            #expect(rig.sessions.viewControllers.count == 2)         // list, chat: one Back returns to Sessions
            #expect(rig.sessions.viewControllers.first === list)
        }
        // Not a new chat (a branch made from the open one): it goes on top, and Back returns to where it came from.
        list.openChat(summary("s-4"))
        for _ in 0..<60 where rig.sessions.viewControllers.count < 3 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.sessions.viewControllers.count == 3)
    }

    /// Two panes: a new chat goes to the right pane and the list's stack stays at its root.
    @Test func aNewChatInTwoPanesGoesToTheRightPane() async throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        rig.tabs.selectedIndex = 1
        let summary = SessionSummary(id: "s-new", profile: "default", title: "New Chat", preview: nil, lastActive: Date(),
                                     source: nil, unread: false, isRunning: false)
        rig.tabs.sessionsViewController.openChat(summary, fresh: true)
        for _ in 0..<40 where !(rig.split.detail.topViewController is ChatViewController) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.split.detail.topViewController is ChatViewController)
        #expect(rig.sessions.viewControllers.count == 1)
    }

    /// Stress round 2 (blocker): at an accessibility text size the chat took its title off the bar from inside the
    /// bar's own text-size change, and the app died opening any chat in the right pane. The title is never taken
    /// off the bar inside the change; it is re-seated on the next turn, at the new size.
    @Test func aTextSizeChangeNeverTakesTheChatTitleOffTheBarInsideTheChange() async throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        let (chat, _) = rig.chat("A fairly long chat title for the bar")
        rig.tabs.botsViewController.openDetail(chat, animated: false)
        rig.window.layoutIfNeeded()
        let title = try #require(chat.navigationItem.titleView)
        #expect(title.superview != nil)
        nonisolated final class Count: @unchecked Sendable { var value = 0 }
        let seats = Count()
        let watch = chat.navigationItem.observe(\.titleView, options: [.new]) { _, _ in seats.value += 1 }
        defer { watch.invalidate() }
        for size in [UIContentSizeCategory.accessibilityExtraExtraExtraLarge, .extraSmall, .accessibilityMedium] {
            seats.value = 0
            rig.window.traitOverrides.preferredContentSizeCategory = size
            rig.window.updateTraitsIfNeeded()
            rig.window.layoutIfNeeded()
            #expect(seats.value == 0)                                // nothing re-seated inside the change
            #expect(chat.navigationItem.titleView === title)
            try await Task.sleep(for: .milliseconds(150))
            rig.window.layoutIfNeeded()
            #expect(chat.navigationItem.titleView === title)
            #expect(title.superview != nil)
            #expect(title.frame.size == title.intrinsicContentSize)  // and the bar has the new size
        }
    }

    @Test func theEmptyFieldOffersTheWalkAndAFieldWithTextDoesNot() {
        let field = ComposerTextView()
        #expect(field.keyCommands?.count == 2)
        field.text = "words"
        #expect(field.keyCommands == nil)
    }
}
