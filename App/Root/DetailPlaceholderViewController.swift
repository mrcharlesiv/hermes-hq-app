// [m9/ipad] The right pane with nothing open (docs/spec/3x-ipad.md §6, D8): a quiet placeholder. It never opens a
// chat by itself (opening one marks it read). Its words name no kind of item: the list beside it can be any tab's.
// Colours are the theme's (HQPalette), so Desktop Look, skins and High Contrast reach it. Its background follows the
// list beside it (grouped for More, the page elsewhere), so the two panes read as one window. The symbol is a neutral
// pane, not a chat's, and "Choose an item" goes while the list beside it is empty (there is nothing to choose). A list
// posts `listStateChanged` when its empty state changes (the roster loads, the store answers), so the words keep up.

import UIKit

/// UX study #89: a list whose empty state is not its `contentUnavailableConfiguration` (Sessions' list background,
/// Artifacts' state cell) says whether it is empty, and posts `listStateChanged` when that flips.
@MainActor
protocol PaneListEmptiness: AnyObject {
    var paneListIsEmpty: Bool { get }
}

final class DetailPlaceholderViewController: UIViewController {
    private let detail = UILabel()
    private let heading = UILabel()
    private let symbol = UIImageView()
    private let stack = UIStackView()
    /// The list beside it shows an empty (or can't-load) state: only "Nothing Selected" shows.
    private var listIsEmpty = false
    /// The list it last followed: its `listStateChanged` posts re-run `follow(list:)`.
    private weak var followed: UIViewController?

    /// Posted by a list (object: the list) when its `contentUnavailableConfiguration` changes.
    static let listStateChanged = Notification.Name("hq.pane.listStateChanged")

    /// Takes the background of `list` (the screen on show in the left pane) and notes whether it is empty.
    func follow(list: UIViewController?) {
        followed = list
        takeColour(of: list)
        listIsEmpty = (list as? PaneListEmptiness)?.paneListIsEmpty ?? (list?.contentUnavailableConfiguration != nil)
        if DeviceWord.isMac { return followOnMac(list) }
        detail.isHidden = listIsEmpty
        stack.accessibilityLabel = listIsEmpty ? "Nothing Selected" : "Nothing Selected. Choose an item from the list."
    }

    /// [mac] Stress test 2026-10-28 #7, #67: the words name what the list beside it holds ("No Chat Open, Choose a bot
    /// to open its chat"), not "an item". [mac] Round 2: the pane shows them beside an empty list too: a blank pane
    /// (Jobs, Artifacts) read as broken. The iPad keeps its words (its UI tests read them).
    /// [mac-audit G] Owner 2026-11-02 (Mac audit #18): beside an empty list the pane says nothing. "No Jobs" with its
    /// New Job… button and "No Job Selected" beside it were two empty states at once (Jobs, Artifacts, Kanban); the
    /// list's own state, with its button, is the one that shows, as Notes leaves the note pane blank beside an empty
    /// folder. The pane keeps the list's background, so the window still reads as one.
    /// Mac polish #4: the Bots list is folded into the sidebar on the Mac, so its own state ("Couldn’t Load Bots" with
    /// Try Again, No Bots Yet, every bot hidden) stood on a list nobody sees, beside a blank pane: the pane shows it.
    private func followOnMac(_ list: UIViewController?) {
        contentUnavailableConfiguration = (list as? BotsViewController).flatMap { Self.foldedListState($0.contentUnavailableConfiguration) }
        let words = Self.macWords(for: list)
        heading.text = words?.title
        detail.text = words?.detail
        detail.isHidden = false
        stack.isHidden = listIsEmpty || words == nil
        stack.accessibilityLabel = words.map { $0.title + ". " + $0.detail }
    }

    /// [mac] The folded Bots list's state as the pane shows it. Show Hidden Bots is left out: it opens the list's Hidden
    /// section, and the sidebar never lists hidden bots, so it would only take the words away.
    private static func foldedListState(_ state: (any UIContentConfiguration)?) -> (any UIContentConfiguration)? {
        guard var state = state as? UIContentUnavailableConfiguration else { return state }
        if state.text == BotListEmpty.allHiddenTitle {
            state.button = .plain()
            state.buttonProperties.primaryAction = nil
        }
        return state
    }

    /// [mac] The pane's title and line for the list on show in the left pane. Mac polish #57: nil, a blank pane, beside
    /// a place that isn't a list to choose from (the Tools: Files, Changes, Terminal, Status & Maintenance, Spawn Tree,
    /// Star Map), where "Choose an item from the list" named a list that isn't there. The pages whose rows open beside
    /// them (Settings, Profiles, Messaging, Webhooks …) keep "Choose an item": a blank pane there read as broken.
    static func macWords(for list: UIViewController?) -> (title: String, detail: String)? {
        switch list {
        case is BotsViewController: ("No Chat Open", "Choose a bot to open its chat.")
        case is SessionsViewController: ("No Chat Open", "Choose a chat from the list.")
        case is JobsViewController: ("No Job Selected", "Choose a job from the list.")
        case let tiles as ArtifactsViewController where tiles.pinnedOnly: ("No Tile Open", "Choose a tile to open it.")
        case is ArtifactsViewController: ("No Artifact Selected", "Choose an artifact from the list.")
        case is KanbanViewController: ("No Task Selected", "Choose a task to see its details.")
        case is TasksViewController: ("No Task Open", "Choose a task to see its steps.")   // [tasks]
        case is MoreViewController: ("Nothing Open", "Choose a page from the list.")
        // [mac-ui-issues] Owner 2026-11-09 ("really refine the app"): the Tools whose rows open beside them said
        // nothing, so half the window was blank with no hint that anything opens there. They name what does. The
        // Tools that are a page of their own (Terminal, Usage, Spawn Tree, Star Map) take the whole room instead.
        case let files as MoreWorkspaceController where files.navigationController?.viewControllers.first === files:
            files.title == "Changes" ? ("No Change Open", "Choose a changed file to see what changed.")
                                     : ("No File Open", "Choose a file to see it here.")
        case let page? where page.viewIfLoaded?.accessibilityIdentifier == "command-center.page":
            ("Nothing Open", "Recent Logs and the messaging apps open here.")
        case is MarketplaceController: ("Nothing Open", "Choose something in Marketplace to see its details.")
        case let page? where (page.navigationController?.viewControllers ?? [page]).contains(where: isTool): nil
        default: ("Nothing Selected", "Choose an item from the list.")
        }
    }

    /// [mac] Mac polish #57: the Tools' pages (and Status & Maintenance's Usage, Kanban's board list), by class or by
    /// the page's identifier. A page pushed from one (Recent Logs) is on a Tool's stack, so it is blank beside it too.
    /// Marketplace and the plugin pages under it are Tools on the Mac now (#33), so they are blank beside them too.
    private static let toolPages: Set<String> = ["command-center.page", "more-usage.page", "spawn-tree.page", "starmap.page"]
    private static func isTool(_ page: UIViewController) -> Bool {
        switch page {
        case is MoreWorkspaceController, is TerminalViewController, is KanbanBoardListController,
             is MarketplaceController, is PluginWebPageController: true
        default: page.viewIfLoaded?.accessibilityIdentifier.map(toolPages.contains) ?? false
        }
    }

    /// The list's colour, or the page's while it has none of its own yet.
    private func takeColour(of list: UIViewController?) {
        var color = list?.viewIfLoaded?.backgroundColor
        #if targetEnvironment(macCatalyst)
        if let drawn = list.flatMap(Self.drawnColour) { color = drawn }
        #endif
        let next = color == nil || color == .clear ? HQPalette.page : color
        if view.backgroundColor != next { view.backgroundColor = next }
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Mac polish #58: the colour a page shows where its view's own isn't it. The Terminal's view is the plain
    /// page (white in the iOS look light) under its grey bar and dark panel; Marketplace's hosting view keeps the
    /// system background (a neutral grey in the dark looks) under its grouped list. Both show the grouped page, as
    /// Files and Changes beside them do.
    private static func drawnColour(of list: UIViewController) -> UIColor? {
        switch list {
        case is TerminalViewController, is MarketplaceController: HQPalette.groupedPage
        default: nil
        }
    }
    #endif

    /// [mac] Mac polish #58: a list often takes its colour as it first loads or shows, after `follow` read it (Files,
    /// Changes, Terminal and Kanban the first time, in the iOS look light: a white pane beside a grey list). Its stack's
    /// layout comes after that, and says so (`MacSidebar.neighbourMayChange`).
    @objc private func listLaidOut() {
        guard let followed else { return }
        takeColour(of: followed)
    }

    @objc private func listChanged(_ note: Notification) {
        guard let list = followed, note.object as? UIViewController === list else { return }
        follow(list: list)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if let followed { follow(list: followed) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if view.backgroundColor == nil { view.backgroundColor = HQPalette.page }
        navigationItem.largeTitleDisplayMode = .never
        NotificationCenter.default.addObserver(self, selector: #selector(listChanged), name: Self.listStateChanged, object: nil)
        #if targetEnvironment(macCatalyst)
        NotificationCenter.default.addObserver(self, selector: #selector(listLaidOut), name: MacSidebar.neighbourMayChange, object: nil)
        #endif

        symbol.image = UIImage(systemName: "sidebar.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular))
        symbol.tintColor = HQPalette.label3
        symbol.contentMode = .scaleAspectFit

        if heading.text == nil { heading.text = "Nothing Selected" }   // [mac] `follow` may have named it already
        heading.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: HQFont.system(ofSize: 20, weight: .semibold))
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = HQPalette.label2
        heading.textAlignment = .center
        heading.numberOfLines = 0

        if detail.text == nil { detail.text = "Choose an item from the list." }
        detail.font = HQFont.preferred(.subheadline)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = HQPalette.label2
        detail.textAlignment = .center
        detail.numberOfLines = 0
        detail.isHidden = listIsEmpty

        [symbol, heading, detail].forEach(stack.addArrangedSubview)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.setCustomSpacing(14, after: symbol)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = listIsEmpty ? "Nothing Selected" : "Nothing Selected. Choose an item from the list."
        stack.accessibilityIdentifier = "pane.placeholder"
        view.addSubview(stack)
        if DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 #9, #52: the same symbol, title and line sizes as every other empty state.
            symbol.image = UIImage(systemName: "sidebar.right", withConfiguration: MacType.emptySymbol)
            heading.font = MacType.emptyTitle
            detail.font = MacType.emptyBody
            // [mac] Stress test 2026-10-28 round 6: the title in the label colour, as every list's empty state draws
            // its title ("No Artifacts in Recent Chats" was black beside a grey "No Artifact Selected").
            heading.textColor = HQPalette.label
        }
        // [mac] Stress test 2026-10-28 #67: the title holds the pane's middle, so a dropped or wrapped line under it
        // never moves it between tabs; the iPad centres the whole stack as before.
        // [mac] #9: lifted like the lists' own empty states (`MacInset.emptyLift`).
        let centre = DeviceWord.isMac ? heading.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor, constant: -MacInset.emptyLift)
                                      : stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            centre,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }
}
