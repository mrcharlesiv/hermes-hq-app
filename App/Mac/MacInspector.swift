#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// [mac-layout] Owner 2026-11-03 (the Mac layout study, "I'd like to see it all built"): the inspector, a panel at the
/// chat's trailing edge that ⌘I (Chat › Inspector) and the bar's ◨ button show and hide, as Linear's details, Slack's
/// thread pane and Keynote's inspector do. Its tabs show the chat on show beside it, live: Info (what the Chat Info
/// sheet showed), Steps (the latest turn's, as the thinking row's sheet), Files (the chat's folder, when it has one)
/// and Helpers (the turn's subagents, each with its page).
/// Detail stays beside the chat instead of covering it; closed, the chat has the whole width.
final class MacInspector: UIViewController {
    enum Tab: Int, CaseIterable {
        case info, steps, files, helpers
        var title: String {
            switch self {
            case .info: "Info"
            case .steps: "Steps"
            case .files: "Files"
            case .helpers: "Helpers"
            }
        }
    }

    /// [mac-ui-issues] Owner 2026-11-09 ("awkwardly sized"): the panel was a fixed 340 pt (about 260 on screen, the app
    /// draws at 77 %), too tight for a folder's path or a file's name and kind. It opens at 380 now and its edge drags,
    /// as the list's does (`RootSplitController`'s grip): from 340 to 640, kept across launches. In a window too small
    /// for the width it was dragged to, it takes what fits (never under 340: then it waits, as before).
    static let defaultWidth: CGFloat = 380
    static let narrowest: CGFloat = 340
    static let widest: CGFloat = 640
    private static let widthKey = "HQMacInspectorWidth"
    /// The width the person left it at.
    static var chosenWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: widthKey)
            return stored > 0 ? min(max(CGFloat(stored), narrowest), widest) : defaultWidth
        }
        set { UserDefaults.standard.set(Double(min(max(newValue, narrowest), widest)), forKey: widthKey) }
    }
    /// The edge was dragged: the split lays the panes out again, at once.
    var onWidthChange: (() -> Void)?
    private let grip = UIView()
    private var dragStart: CGFloat = 0
    private var dragging = false

    private static let shownKey = "HQMacInspectorShown"
    private static let tabKey = "HQMacInspectorTab"
    /// Open or closed, kept across launches as the sidebar's fold is.
    static var isShown: Bool {
        get {
            // [tasks-first] Beside a task the pane is the bot's conversation: open unless it was closed there. Its
            // own switch, so closing the inspector beside a chat doesn't hide a task's teammate (and the other way).
            if taskMode { return UserDefaults.standard.object(forKey: taskShownKey) as? Bool ?? true }
            return UserDefaults.standard.bool(forKey: shownKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: taskMode ? taskShownKey : shownKey) }
    }

    private(set) var shownTab: Tab = Tab(rawValue: UserDefaults.standard.integer(forKey: tabKey)) ?? .info
    private weak var chat: ChatViewController?
    /// [tasks-first] Step 5 (owner 2026-11-12, mockup 6-mac: "The right pane is your teammate: the whole conversation
    /// … Today that pane shows No Helpers"): beside a task's page the pane holds the task's chat itself, under the
    /// bot's name, in place of the tabs.
    private var taskChat: ChatViewController?
    private static var taskMode = false
    private static let taskShownKey = "HQMacTaskChatShown"
    private let taskTitle = UILabel()

    /// The task on show has a bot (or none, or no task is on show): its chat fills the pane.
    func followTask(_ next: ChatViewController?, name: String) {
        guard next !== taskChat else { return }
        let was = Self.isShown
        clear()
        taskChat = next
        Self.taskMode = next != nil
        taskTitle.text = name
        if isViewLoaded {
            followLook()
            fill()
        }
        if was != Self.isShown || next != nil || was { onShownChange?() }
    }
    private var content: UIViewController?
    private let tabs = UISegmentedControl(items: Tab.allCases.map(\.title))
    /// Mac polish #62: the Desktop Look's outlined strip in the segments' place (UISegmentedControl draws iOS 26's pill
    /// whatever it is given), as Artifacts' filter and Bot Info's tabs are; `tabsRow` holds whichever the look shows.
    private let tabsRow = UIStackView()
    private var strip: UIHostingController<InspectorTabStrip>?
    private let stripChoice = InspectorTabChoice()
    private let holder = UIView()
    private let edge = UIView()
    /// [mac-ui-issues] Desktop Look: the chat bar's frosted band stopped at the panel's edge. The same band (the frost
    /// over the chat's page colour) runs across the panel's top, as tall as the chat's bar (`bandBottom`, from the split).
    private let band = UIView()
    private let bandFrost = DesktopFrostView()
    private lazy var bandHeight = band.heightAnchor.constraint(equalToConstant: 0)
    var bandBottom: CGFloat = 0 { didSet { if isViewLoaded, bandHeight.constant != bandBottom { bandHeight.constant = bandBottom } } }
    /// [mac-ten] Owner 2026-11-11 ("weird UI issues"): the tabs stood 4 pt lower than the buttons of the chat's bar
    /// beside them (12 pt under the window's toolbar height, whatever the bar's own middle was), so the window's top
    /// row had two baselines. They are centred on the middle of the bar's row of buttons (from the split, in the
    /// panel's own points); with no bar on show they keep the 12 pt.
    var barMiddle: CGFloat = 0 { didSet { if isViewLoaded, barMiddle != oldValue { alignTabs() } } }
    private lazy var tabsOnBar = tabsRow.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 0)
    private lazy var tabsUnderToolbar = tabsRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
    private func alignTabs() {
        let onBar = barMiddle > 0
        tabsOnBar.constant = barMiddle
        if !onBar { tabsOnBar.isActive = false }
        tabsUnderToolbar.isActive = !onBar
        tabsOnBar.isActive = onBar
    }
    private let empty = InspectorEmptyView(symbol: "info.circle", title: "", hint: "")

    /// The inspector beside `screen`, when the window has room for one (two panes, the chat in the right one).
    static func beside(_ screen: UIViewController) -> MacInspector? {
        var at: UIViewController? = screen
        while let next = at, !(next is RootSplitController) { at = next.parent }
        guard let split = at as? RootSplitController, split.isDouble, split.detail.viewControllers.contains(screen) else { return nil }
        return split.inspector
    }

    /// The split lays the panes out again (shown, hidden).
    var onShownChange: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        view.accessibilityIdentifier = "mac.inspector"
        edge.backgroundColor = HQPalette.paneLine
        edge.isUserInteractionEnabled = false
        tabs.selectedSegmentIndex = shownTab.rawValue
        tabs.addAction(UIAction { [weak self] _ in
            guard let self, let picked = Tab(rawValue: self.tabs.selectedSegmentIndex) else { return }
            self.show(picked)
        }, for: .valueChanged)
        tabs.accessibilityIdentifier = "mac.inspector.tabs"
        tabs.apportionsSegmentWidthsByContent = true
        tabsRow.axis = .vertical
        tabsRow.addArrangedSubview(tabs)
        taskTitle.font = {
            let base = HQFont.preferred(.subheadline)
            return UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        }()
        taskTitle.textColor = HQPalette.label
        taskTitle.textAlignment = .center
        taskTitle.isHidden = true
        taskTitle.accessibilityIdentifier = "mac.inspector.task-title"
        tabsRow.addArrangedSubview(taskTitle)
        empty.isHidden = true
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        grip.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        grip.accessibilityIdentifier = "mac.inspector.grip"
        band.isUserInteractionEnabled = false
        band.accessibilityIdentifier = "mac.inspector.band"
        bandFrost.frame = band.bounds
        bandFrost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        band.addSubview(bandFrost)
        bandHeight.constant = bandBottom
        // [inspector] Owner 2026-11-09: a rule under the tabs, so the tab's rows start under a line, not under air.
        let rule = UIView()
        rule.backgroundColor = HQPalette.paneLine
        rule.isUserInteractionEnabled = false
        for sub in [band, holder, tabsRow, rule, edge, empty, grip] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }
        let pixel = 1 / max(1, traitCollection.displayScale)
        // The Desktop Look's segments otherwise drew 10 pt tall, their titles cut (sweep 2026-11-03). Just under
        // required: hidden in the stack while the strip shows, they give way.
        let segments = tabs.heightAnchor.constraint(equalToConstant: 28)
        segments.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: view.topAnchor),
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bandHeight,
            edge.topAnchor.constraint(equalTo: view.topAnchor),
            edge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: pixel),
            // Under the window's toolbar height, where the chat's bar sits beside it (`alignTabs`: on the bar's middle).
            tabsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: InspectorLook.margin),
            tabsRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -InspectorLook.margin),
            segments,
            rule.topAnchor.constraint(equalTo: tabsRow.bottomAnchor, constant: 10),
            rule.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            rule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: pixel),
            holder.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 8),
            holder.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            holder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            empty.centerYAnchor.constraint(equalTo: holder.centerYAnchor, constant: -40),
            empty.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            // The edge's grip: 9 pt over the line, the panel's whole height.
            grip.topAnchor.constraint(equalTo: view.topAnchor),
            grip.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grip.widthAnchor.constraint(equalToConstant: 9),
        ])
        alignTabs()
        followLook()
        NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followLook() }
        }
        fill()
    }

    /// The segments in the iOS look, the outlined strip in the Desktop Look (made the first time it's wanted).
    private func followLook() {
        let desktop = Theme.isDesktop
        if desktop, strip == nil {
            stripChoice.index = shownTab.rawValue
            let host = UIHostingController(rootView: InspectorTabStrip(choice: stripChoice) { [weak self] index in
                guard let self, let picked = Tab(rawValue: index) else { return }
                self.show(picked)
            })
            host.view.backgroundColor = .clear
            host.sizingOptions = .intrinsicContentSize
            host.view.accessibilityIdentifier = "mac.inspector.tabs"
            addChild(host)
            tabsRow.addArrangedSubview(host.view)
            host.didMove(toParent: self)
            strip = host
        }
        tabs.isHidden = desktop || Self.taskMode
        taskTitle.isHidden = !Self.taskMode
        band.isHidden = !desktop
        band.backgroundColor = HQPalette.page
        bandFrost.color = HQPalette.page
        strip?.view.isHidden = !desktop || Self.taskMode
    }

    // MARK: Its width

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            dragStart = view.bounds.width
            dragging = true
        case .changed:
            let moved = pan.translation(in: view.superview).x
            let wider = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? moved : -moved
            Self.chosenWidth = dragStart + wider
            MacWindow.cursor("resizeLeftRightCursor")
            onWidthChange?()
        default:
            dragging = false
            // What the window had room for, not a wider ask it never showed.
            if view.bounds.width >= Self.narrowest { Self.chosenWidth = view.bounds.width }
        }
    }

    /// The Mac's left-right arrows over the edge, so it reads as something to drag.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        let over = hover.state == .began || hover.state == .changed
        MacWindow.cursor(over || dragging ? "resizeLeftRightCursor" : "arrowCursor")
    }

    // MARK: What it shows

    /// The chat on show changed (or none is on show now): its tabs follow it.
    func follow(_ next: ChatViewController?) {
        guard next !== chat else { return }
        let had = chat != nil
        chat = next
        if isViewLoaded, Self.isShown { fill() }
        // Beside a page that isn't a chat (Sessions' list, Jobs, a tool) the panel makes way, and comes back with a chat.
        if Self.isShown, had != (next != nil) { onShownChange?() }
    }

    /// A chat is on show beside it (the split gives the panel room only then).
    var hasChat: Bool { chat != nil || taskChat != nil }

    /// Whether the split gives the panel its room now: none in a window too narrow for it beside the panes (Mac polish
    /// #1), open or not.
    var takesRoom: (() -> Bool)?
    /// The panel was asked for where it has no room: the split folds the list away for it when the chat and the panel
    /// fit, and says whether it did. The next layout places it.
    var makeRoom: (() -> Bool)?
    /// Open and drawn beside the chat: what ⌘I hides, and what the menu's Hide Inspector names.
    var isVisible: Bool { Self.isShown && (takesRoom?() ?? true) }

    /// Shows the panel on `tab` (the title, ⋯ › Info, the thinking row).
    func show(_ tab: Tab) {
        let changed = tab != self.shownTab || content == nil
        self.shownTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey)
        if isViewLoaded, tabs.selectedSegmentIndex != tab.rawValue { tabs.selectedSegmentIndex = tab.rawValue }
        if stripChoice.index != tab.rawValue { stripChoice.index = tab.rawValue }
        if !Self.isShown {
            Self.isShown = true
            if takesRoom?() == false { _ = makeRoom?() }
            onShownChange?()
            fill()
        } else {
            // Kept open from before but with no room (a laptop-size window beside Sessions): asked for again, it makes
            // some, instead of the click doing nothing.
            if takesRoom?() == false, makeRoom?() == true { onShownChange?() }
            if changed { fill() }
        }
    }

    /// ⌘I and the bar's ◨: open on the last tab, or close. Open but with no room counts as closed, so the key shows it.
    func toggle() {
        if isVisible {
            Self.isShown = false
            onShownChange?()
            clear()
        } else {
            show(shownTab)
        }
    }

    private func clear() {
        guard let content else { return }
        // The task's chat outlives the pane's stack (the pane closes and opens again around it).
        if let stack = content as? UINavigationController, let taskChat, stack.viewControllers.contains(taskChat) { stack.viewControllers = [] }
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        self.content = nil
    }

    private func fill() {
        guard isViewLoaded else { return }
        clear()
        guard Self.isShown else { return }
        var (made, note) = make(shownTab)
        if let taskChat { made = taskChat }
        empty.set(symbol: note.symbol, title: note.title, hint: note.hint)
        empty.isHidden = made != nil
        guard let made else { return }
        // A stack of its own: Info's rows and a step's page push inside the panel.
        let stack = UINavigationController(rootViewController: made)
        rootHidesBar = (made.navigationItem.title == nil && made.title == nil) || made === taskChat
        stack.setNavigationBarHidden(rootHidesBar, animated: false)
        stack.delegate = self
        fitPage(made, root: true)
        stack.navigationBar.prefersLargeTitles = false
        addChild(stack)
        // Pinned to the holder's edges (hunt 2026-11-09): a frame that followed by autoresizing could be left a few
        // points wide after the window was dragged narrow, the page's words one letter to a line.
        stack.view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack.view)
        NSLayoutConstraint.activate([
            stack.view.topAnchor.constraint(equalTo: holder.topAnchor),
            stack.view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            stack.view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            stack.view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
        ])
        stack.didMove(toParent: self)
        content = stack
    }

    /// The tab's own page has no title (Steps, Helpers), so its bar is hidden; a page pushed from it keeps one.
    private var rootHidesBar = false
    /// The tab's pages, for ⌘[ and Escape (`KeyCommands.backStack`).
    var pageStack: UINavigationController? { content as? UINavigationController }

    /// A page in the panel: no large title, and none of a sheet's Close or Done (the panel stays open). The root has
    /// no leading items either; a pushed page keeps its Back.
    private func fitPage(_ page: UIViewController, root: Bool) {
        page.navigationItem.largeTitleDisplayMode = .never
        if root { page.navigationItem.leftBarButtonItems = nil }
        page.navigationItem.leftBarButtonItems = page.navigationItem.leftBarButtonItems?.filter { $0.accessibilityIdentifier != "sheet.close" }
        page.navigationItem.rightBarButtonItems = page.navigationItem.rightBarButtonItems?.filter { $0.accessibilityIdentifier != "sheet.close" }
    }

    private typealias Note = (symbol: String, title: String, hint: String)

    private func make(_ tab: Tab) -> (UIViewController?, Note) {
        guard let chat else { return (nil, ("bubble.left", "No Chat Open", "Open a chat to see its \(tab.title.lowercased()) here.")) }
        switch tab {
        case .info:
            return (chat.makeInfoContent?(), ("info.circle", "No Info", "This chat has nothing to show yet."))
        case .steps:
            let list = chat.activity.makeStepsList()
            list.title = nil
            list.compact = true
            return (list, ("checklist", "", ""))
        case .files:
            return (chat.menus?.makeFilesPage(), ("folder", "No Folder", "This chat isn’t working in a folder, so there are no files to show."))
        case .helpers:
            return (chat.activity.makeHelpersPanel(), ("person.2", "", ""))
        }
    }
}

/// Tester 2026-11-07: a step opened from Steps had no way back but another tab and Steps again. The tab's
/// untitled page hides the panel's bar, and a pushed page got none either, so no Back; now only that page hides it.
extension MacInspector: UINavigationControllerDelegate {
    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        let root = viewController === navigationController.viewControllers.first
        if !root { fitPage(viewController, root: false) }
        navigationController.setNavigationBarHidden(root && rootHidesBar, animated: animated)
    }
}

@Observable private final class InspectorTabChoice { var index = 0 }

/// [mac-layout] Mac polish #62: the inspector's Info / Steps / Files / Helpers in the Desktop Look's outlined strip.
private struct InspectorTabStrip: View {
    @Bindable var choice: InspectorTabChoice
    let picked: (Int) -> Void

    var body: some View {
        DesktopSegmentStrip(options: MacInspector.Tab.allCases.map { ($0.title, $0.rawValue) },
                            selection: Binding(get: { choice.index }, set: { choice.index = $0; picked($0) }),
                            wholeLabels: true)   // [mac-ui-issues] "Helpers" touched both sides of its equal quarter
            .accessibilityElement(children: .contain)
    }
}
#endif
