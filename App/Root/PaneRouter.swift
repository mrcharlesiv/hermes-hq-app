// [m9/ipad] The routing seam (docs/spec/3x-ipad.md §4.4): one place decides where a screen opened from a list goes.
// In the phone layout it is pushed on the list's own stack, exactly as before. In two panes it is shown in the right
// pane. DECISION: the seam lives in the tab stacks' navigation controller (`PaneNavigationController`), so every
// push made from a tab root is routed, including pushes other streams add later, with no change at the call site.
// `openDetail` is the same thing by name.

import UIKit

/// A screen pushed from a tab root that is itself a list (a Kanban board picker, a folder): it stays in the list pane.
@MainActor protocol ListPaneContent: UIViewController {}

/// A screen that keeps a reference to the stack it lives on (the Settings pages' router) hears when it moved panes.
@MainActor protocol PaneNavigationFollowing: UIViewController {
    func paneNavigationChanged(_ navigation: UINavigationController)
}

/// The signed-in root, whichever it is.
@MainActor enum AppRoot {
    /// The app shows its tabs (iPhone: the tab controller; iPad: the two-pane root).
    static func signedIn(_ window: UIWindow?) -> Bool {
        window?.rootViewController is MainTabController || window?.rootViewController is RootSplitController
    }

    static func tabs(_ window: UIWindow?) -> MainTabController? {
        (window?.rootViewController as? MainTabController) ?? (window?.rootViewController as? RootSplitController)?.tabs
    }

    /// [duo] This iPhone unfolds (`PaneLayout.foldable`), set when the scene connects. -HQDebugFoldable YES pretends so
    /// on a flat iPhone simulator: the two-pane root in its one-pane layout, as on the Duo's outer screen.
    static var foldable = false

    /// [duo] Set once a phone's screen has been seen open (`noteScreen`): a foldable this app does not know by model,
    /// launched folded, gets the two-pane root from its next launch.
    static let seenOpenKey = "HQFoldableSeenOpen"

    /// [duo] An iPhone with the phone root whose screen turns out to be an open foldable's. The root is not swapped
    /// under a running app (the tab controller is the window's root, and its sheets would go); the next launch takes
    /// the two-pane root.
    static func noteScreen(_ scene: UIWindowScene) {
        guard UIDevice.current.userInterfaceIdiom == .phone, !foldable,
              PaneLayout.unfolded(screen: scene.screen.bounds.size),
              !UserDefaults.standard.bool(forKey: seenOpenKey) else { return }
        UserDefaults.standard.set(true, forKey: seenOpenKey)
        AppLog.note("screen", "foldable iPhone seen open (\(deviceModel)): two-pane root from the next launch")
    }

    /// The device's model ("iPhone19,4"); the simulated one on a simulator.
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The window's root for a signed-in account: the tab controller itself on iPhone, the two-pane root on iPad.
    /// [duo] An iPhone that unfolds gets the iPad's: one pane on the outer screen and on the inner one held upright
    /// (626 pt), two held sideways (890 pt). Folding and unfolding resize the same window, as Stage Manager does.
    static func make(_ tabs: MainTabController, window: UIWindow?) -> UIViewController {
        guard UIDevice.current.userInterfaceIdiom == .pad || foldable else { return tabs }
        return RootSplitController(tabs: tabs, size: window?.bounds.size ?? .zero)
    }
}

/// A tab's navigation stack. In two panes a push of anything that is not a list goes to the right pane.
final class PaneNavigationController: UINavigationController {
    private static var passing = 0
    /// Stack changes made while moving screens between the layouts are not routed again.
    static func passThrough(_ work: () -> Void) {
        passing += 1
        defer { passing -= 1 }
        work()
    }

    /// The tabs' bar takes taps above the gateway subtitle (`TallTouchNavigationBar`).
    override init(rootViewController: UIViewController) {
        super.init(navigationBarClass: TallTouchNavigationBar.self, toolbarClass: nil)
        super.setViewControllers([rootViewController], animated: false)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    #if targetEnvironment(macCatalyst)
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        NotificationCenter.default.post(name: MacSidebar.neighbourMayChange, object: nil)   // [sidebar-light]
    }
    #endif

    private var split: RootSplitController? {
        guard Self.passing == 0, let split = (tabBarController as? MainTabController)?.split, split.isDouble else { return nil }
        return split
    }

    /// [customtabs] Set while this list's tab is hidden (Settings › Tabs): what is pushed here goes on the other
    /// list's stack instead, which comes to the front, and a pop to the list pops that stack.
    weak var standIn: UINavigationController?

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        if let standIn, !viewControllers.isEmpty {
            if let tabs = standIn.tabBarController, tabs.selectedViewController !== standIn,
               (tabs as? MainTabController)?.split?.isDouble != true {
                tabs.selectedViewController = standIn
            }
            standIn.pushViewController(viewController, animated: animated)
            return
        }
        if !viewControllers.isEmpty, !(viewController is ListPaneContent), let split {
            split.show([viewController], from: self, animated: animated)
            return
        }
        super.pushViewController(viewController, animated: animated)
    }

    // A chat that only just crossed panes and is now really leaving ends as any closed chat does.
    override func popViewController(animated: Bool) -> UIViewController? {
        (topViewController as? ChatViewController)?.movingBetweenPanes = false
        return super.popViewController(animated: animated)
    }

    override func popToRootViewController(animated: Bool) -> [UIViewController]? {
        if let standIn { return standIn.popToRootViewController(animated: animated) }
        viewControllers.forEach { ($0 as? ChatViewController)?.movingBetweenPanes = false }
        return super.popToRootViewController(animated: animated)
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        if let split, let index = viewControllers.indices.dropFirst().first(where: { !(viewControllers[$0] is ListPaneContent) }) {
            // Screens already in the right pane (a caller rebuilding this stack around them) are shown there again.
            super.setViewControllers(Array(viewControllers[..<index]), animated: false)
            split.show(Array(viewControllers[index...]), from: self, animated: animated)
            return
        }
        super.setViewControllers(viewControllers, animated: animated)
    }
}

extension UIViewController {
    /// Opens `screen` from a list: pushed on this list's stack in the phone layout, shown in the right pane in two
    /// panes. A chat with nothing to paint yet is held until its first rows land (at most 0.35 s), as a push is.
    func openDetail(_ screen: UIViewController, animated: Bool = true, done: @escaping () -> Void = {}) {
        guard let navigation = (self as? UINavigationController) ?? navigationController else { return done() }
        if screen is ChatViewController, animated {
            ChatViewController.push(screen, on: navigation, done: done)
        } else {
            navigation.pushViewController(screen, animated: animated)
            done()
        }
    }
}

extension ChatViewController {
    /// The size the next chat's first screen is laid out for (the pane it is about to land in); nil: the screen's.
    static var openingSize: CGSize?

    /// The same conversation (the same bot's own chat, or the same stored chat).
    func isSameChat(as other: ChatViewController) -> Bool {
        if session === other.session { return true }
        guard let a = session as? LiveChatSession, let b = other.session as? LiveChatSession, a.profile == b.profile,
              a.menus.isBotChat == b.menus.isBotChat else { return false }
        if a.menus.isBotChat { return true }
        guard let left = a.storedSessionId ?? a.resolvedStoredId, let right = b.storedSessionId ?? b.resolvedStoredId else { return false }
        return left == right
    }
}

extension MainTabController {
    /// The two-pane root this tab controller sits in (nil on iPhone).
    var split: RootSplitController? { parent as? RootSplitController }

    /// The chat the user can see, in either layout.
    var chatOnShow: ChatViewController? { paneChatOnShow?.chat }

    /// The chat on show, the list stack it was opened from and that stack's tab ([taborder] what it is, not its place).
    var paneChatOnShow: (chat: ChatViewController, navigation: UINavigationController, tab: HQTab?)? {
        if let split, split.isDouble {
            guard let chat = split.detail.topViewController as? ChatViewController else { return nil }
            let stacks = placedTabs   // [mac-sidebar] every place: the Mac's tab controller holds five at a time
            let origin = split.origin.flatMap { origin in stacks.firstIndex { $0 === origin } }
                ?? stacks.firstIndex { $0.tabBarItem.tag == HQTab.bots.rawValue } ?? 0
            guard let navigation = stacks.indices.contains(origin) ? stacks[origin] as? UINavigationController : nil else { return nil }
            return (chat, navigation, HQTab(rawValue: navigation.tabBarItem.tag))
        }
        guard let navigation = selectedViewController as? UINavigationController,
              let chat = navigation.topViewController as? ChatViewController else { return nil }
        return (chat, navigation, shownTab)
    }

    /// Two panes: empties the right pane. Phone layout: back to the selected tab's list.
    func closeDetail(animated: Bool) {
        if let split, split.isDouble {
            split.closeDetail(animated: animated)
        } else {
            (selectedViewController as? UINavigationController)?.popToRootViewController(animated: animated)
        }
    }

    /// Leaves `screen` (a chat that was deleted, archived, or is gone): the right pane empties, or its stack pops.
    func leave(_ screen: UIViewController, animated: Bool) {
        if let split, split.isDouble, split.detail.viewControllers.first === screen {
            split.closeDetail(animated: animated)
        } else if let navigation = screen.navigationController {
            if navigation.viewControllers.first === screen { return }
            if navigation.topViewController === screen {
                navigation.popViewController(animated: animated)
            } else {
                navigation.viewControllers.removeAll { $0 === screen }
            }
        }
    }

    /// Two panes: a chat deleted or archived from its list row (or its bot deleted) while it shows on the right gives
    /// the pane back to the placeholder (§6). `sessionId` nil: any chat of that bot.
    func leaveDetailChat(profile: String, sessionId: String?) {
        guard let split, split.isDouble, let chat = split.detail.viewControllers.first as? ChatViewController,
              let live = chat.session as? LiveChatSession, live.profile == profile else { return }
        if let sessionId, (live.storedSessionId ?? live.resolvedStoredId) != sessionId { return }
        AppLog.trace("nav", "right pane's chat \(AppLog.tag(sessionId)) gone from its list, closing the pane")
        leave(chat, animated: true)
    }

    /// Nothing is open beside (or over) the selected tab's list.
    var nothingOpen: Bool {
        guard let navigation = selectedViewController as? UINavigationController, navigation.viewControllers.count == 1 else { return false }
        return split.map { !$0.isDouble || $0.detailIsEmpty } ?? true
    }

    /// The lists mark the row of the chat, job or More page on show in the right pane (cleared in the phone layout).
    func paneSelectionChanged() {
        var bot: String?, session: String?, room: String?
        let root = split.flatMap { $0.isDouble ? $0.detail.viewControllers.first : nil }
        if let chat = root as? ChatViewController, let live = chat.session as? LiveChatSession {
            if live.menus.isBotChat {
                bot = live.profile
            } else if let id = live.storedSessionId ?? live.resolvedStoredId {
                session = live.profile + "\u{1F}" + id
            }
        } else if let chat = root as? ChatViewController, let group = chat.session as? ChatRoomSurface {
            room = group.roomKey   // [groups] a group chat marks its row in the Bots list too
        } else if root is OtherAppsViewController {
            session = SessionsViewController.otherAppsKey   // the page beside the list marks the row that opened it
        }
        let double = split?.isDouble ?? false
        services.setListsBesideChat(double)   // the list beside a chat keeps its on-screen refresh
        botsViewController.markOnShow(bot, room: room, keepsSelection: double)
        sessionsViewController.markOnShow(session, keepsSelection: double)
        pages?.jobs?.markOnShow((root as? JobDetailViewController)?.jobKey, keepsSelection: double)
        pages?.more?.markOnShow(root, keepsSelection: double)
        MoreWorkspaceController.markOnShow(root, keepsSelection: double)   // [mac-tools] Files' and Changes' tables
        ArtifactsViewController.markOnShow(root, keepsSelection: double)   // [mac-tools] Artifacts' grid
        KanbanViewController.markOnShow((root as? KanbanTaskHostController)?.model.taskId, keepsSelection: double)   // [mac] every live board
        TasksViewController.markOnShow(root: root, keepsSelection: double)   // [mac] Mac polish #41: Tasks marks the open task's row
        #if targetEnvironment(macCatalyst)
        // [bots-rail] the rail's head [rail-more] or room [chats-under] or a chat listed under its bot
        if split?.isViewLoaded == true { split?.macSidebar.markOpen(bot: double ? bot : nil, room: double ? room : nil, chat: double ? session : nil) }
        split?.inspector.follow(double ? root as? ChatViewController : nil)   // [mac-layout] the inspector shows the chat beside it
        // [tasks-first] Step 5: beside a task's page the pane is the bot's conversation.
        let taskModel = double ? (root as? TodoSheetHost)?.model : nil
        split?.inspector.followTask(taskModel?.split == true ? taskModel?.keptChat : nil,
                                    name: taskModel?.task.map { taskModel?.botName(taskModel?.chatBot($0)) ?? "" } ?? "")
        #endif
        // The placeholder takes the background of the list beside it, and drops "Choose an item" beside an empty one.
        (root as? DetailPlaceholderViewController)?.follow(list: (selectedViewController as? UINavigationController)?.topViewController)
    }
}

// MARK: - The Settings pages follow the stack they are on

extension SettingsRootController: PaneNavigationFollowing {
    func paneNavigationChanged(_ navigation: UINavigationController) { router.navigation = navigation }
}

extension GatewayPageController: PaneNavigationFollowing {
    func paneNavigationChanged(_ navigation: UINavigationController) { model.router.navigation = navigation }
}
