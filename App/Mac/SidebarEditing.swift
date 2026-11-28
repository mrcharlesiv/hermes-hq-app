// [mac-sidebar] Owner 2026-10-31: "you should be able to add more options to the sidebar." The Mac's sidebar is edited
// where it is, as Finder's and Mail's are, not only in Settings › Appearance › Tabs: a Control-click on a row offers
// Move Up, Move Down and Remove from Sidebar; anywhere on the sidebar (and its foot's +) Add to Sidebar ▸ lists the
// pages not in it, with their icons, and Sidebar Settings… opens Settings › Tabs; a More row offers Add to Sidebar.
// Every change goes through `TabOrder.tabs`, so Settings › Tabs, the sidebar and More follow at once.

import UIKit

#if targetEnvironment(macCatalyst)
@MainActor enum SidebarEditing {
    /// A place the sidebar could list: what it is, its name and its icon.
    struct Place {
        var choice: TabChoice
        var title: String
        var image: UIImage?
        /// [sidebar-add-tools] One of the Tools now: added, it leaves Tools for the pages under the line.
        var fromTools = false
    }

    /// A row's drag (`MacSidebar`): the place it shows.
    final class DragBox: NSObject {
        let choice: TabChoice
        init(choice: TabChoice) { self.choice = choice }
    }

    // MARK: What can change

    /// What could join the sidebar now, as Settings › Tabs' add list has it: the main tabs not in it, then the More
    /// pages this gateway has, in More's order.
    /// Owner 2026-11-17 (Mac calls Q11) had left the Tools out (a Tool is already in the sidebar, with Move to Places).
    /// [sidebar-add-tools] Owner 2026-11-22, the Add to Sidebar menu listing only setup pages: "There is a lot that I
    /// cannot add to the sidebar" (as on 2026-11-09: "I don't see tasks or tiles as options to add"). The Tools are
    /// offered again, after the rest and marked `fromTools` (the menu lists them under "From Tools"). Bots stays out:
    /// Bots in Sidebar decides where it is.
    static func addable() -> [Place] {
        let shown = TabOrder.tabs
        let mains = HQTab.movable.map(TabChoice.main).filter { !shown.contains($0) && !($0 == .main(.bots) && isTool($0)) }
        let pages = TabOrderPage.pageChoices().filter { !shown.contains(.page($0.id)) }
        let all = mains.map { Place(choice: $0, title: TabOrderPage.title($0), image: image($0, symbol: nil), fromTools: isTool($0)) }
            + pages.map { Place(choice: .page($0.id), title: $0.title, image: image(.page($0.id), symbol: $0.symbol), fromTools: isTool(.page($0.id))) }
        // The Tools in the order the sidebar lists them.
        let toolOrder = MainTabController.current?.pages?.toolIDs ?? []
        func rank(_ place: Place) -> Int { toolID(place.choice).flatMap(toolOrder.firstIndex) ?? Int.max }
        let tools = all.enumerated().filter { $0.element.fromTools }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return all.filter { !$0.fromTools } + tools
    }

    /// `choice` stands under the sidebar's Tools now (a page More's working sections give it, Marketplace, a plugin
    /// page, or Bots while it is no place).
    private static func isTool(_ choice: TabChoice) -> Bool {
        guard let pages = MainTabController.current?.pages else { return false }
        return toolID(choice).map(pages.toolIDs.contains) ?? false
    }

    /// The More row id `choice` would have among the Tools.
    private static func toolID(_ choice: TabChoice) -> String? {
        switch choice {
        case .page(let page): return page
        case .main(.jobs): return "jobs"
        case .main(.workspace): return MainTabController.current?.pages?.workspaceRowID
        case .main(.bots): return PagesTabs.botsRowID
        case .main: return nil
        }
    }

    /// The place a More row opens, when it can be in the sidebar: a hidden Jobs or Kanban/Artifacts tab, or a page.
    static func choice(forMoreRow id: String) -> TabChoice? {
        let shown = TabOrder.tabs
        if id == "jobs" { return shown.contains(.main(.jobs)) ? nil : .main(.jobs) }
        if let pages = MainTabController.current?.pages, id == pages.workspaceRowID, !shown.contains(.main(.workspace)) {
            return .main(.workspace)
        }
        guard addable().contains(where: { $0.choice == .page(id) }) else { return nil }
        return .page(id)
    }

    static func add(_ choice: TabChoice) {
        guard !TabOrder.tabs.contains(choice) else { return }
        AppLog.note("mac", "sidebar: added \(choice.key)")
        TabOrder.tabs = TabOrder.tabs + [choice]
    }

    static func remove(_ choice: TabChoice) {
        let tabs = TabOrder.tabs
        guard TabOrder.canHide(choice, from: tabs) else { return }
        AppLog.note("mac", "sidebar: removed \(choice.key)")
        TabOrder.tabs = tabs.filter { $0 != choice }
    }

    /// [sidebar-divider] A page added to the sidebar (More's, from Add to Sidebar or Settings › Tabs), not one of the
    /// main places (Bots, Sessions, Jobs, Kanban or Artifacts): those added sit under a line after the main ones.
    static func isAddedPage(_ tag: Int) -> Bool {
        if case .page? = TabChoice(tag: tag) { return true }
        return false
    }

    /// Moves stay on their own side of the line: a page among the pages, a main place among the main places.
    private static func sameSide(_ a: TabChoice, _ b: TabChoice) -> Bool { isAddedPage(a.tag) == isAddedPage(b.tag) }

    /// The places in the sidebar's order as it shows them (a page this gateway lacks is in `TabOrder.tabs` but not
    /// here: moves step over it).
    /// Only rows a move can land beside: Bots has no row here (the bots themselves stand for it) and the Tools sit
    /// under the places in an order of their own, outside `TabOrder.tabs`. With them counted, Move Down on the last
    /// place and a drop at the end did nothing, and Move Up on the first place swapped it with the unseen Bots.
    private static var shown: [TabChoice] {
        let order = TabOrder.tabs
        let placed = MainTabController.current?.placedTabs.compactMap { TabChoice(tag: $0.tabBarItem.tag) } ?? order
        return placed.filter { (!MacSidebar.botsInSidebar || $0 != .main(.bots)) && order.contains($0) }
    }

    /// `choice` one row up (-1) or down (+1); false when it is already at that end.
    static func canMove(_ choice: TabChoice, by step: Int) -> Bool {
        let rows = shown.filter { sameSide($0, choice) }   // [sidebar-divider] not across the line
        guard let index = rows.firstIndex(of: choice) else { return false }
        return rows.indices.contains(index + step)
    }

    static func move(_ choice: TabChoice, by step: Int) {
        let rows = shown.filter { sameSide($0, choice) }
        guard let index = rows.firstIndex(of: choice), rows.indices.contains(index + step) else { return }
        AppLog.note("mac", "sidebar: moved \(choice.key) \(step < 0 ? "up" : "down")")
        place(choice, beside: rows[index + step], after: step > 0)
    }

    /// A dragged row dropped above `target`, or below the last row (nil).
    /// [sidebar-divider] Dropped on the other side of the line, it lands at the end of its own side nearest the drop:
    /// a page let go among the main places is the first page, a main place let go among the pages the last main place.
    static func move(_ choice: TabChoice, before target: TabChoice?) {
        guard target != choice else { return }
        AppLog.note("mac", "sidebar: dragged \(choice.key) above \(target?.key ?? "the end")")
        let side = shown.filter { sameSide($0, choice) }
        if let target, sameSide(target, choice) {
            place(choice, beside: target, after: false)
        } else if isAddedPage(choice.tag), target != nil {
            if let first = side.first, first != choice { place(choice, beside: first, after: false) }
        } else if let last = side.last, last != choice {
            place(choice, beside: last, after: true)
        }
    }

    private static func place(_ choice: TabChoice, beside neighbour: TabChoice, after: Bool) {
        var tabs = TabOrder.tabs
        guard let from = tabs.firstIndex(of: choice) else { return }
        tabs.remove(at: from)
        guard let at = tabs.firstIndex(of: neighbour) else { return }
        tabs.insert(choice, at: after ? at + 1 : at)
        TabOrder.tabs = tabs
    }

    // MARK: Menus

    /// A row's Control-click: Move Up, Move Down, Remove from Sidebar (not for the only list left: chats open there),
    /// then what the sidebar's own menu offers. More (`choice` nil) has only the latter.
    static func rowMenu(for choice: TabChoice?) -> UIMenu {
        guard let choice, TabOrder.tabs.contains(choice) else { return spaceMenu() }
        let up = UIAction(title: "Move Up", image: UIImage(systemName: "arrow.up"),
                          attributes: canMove(choice, by: -1) ? [] : .disabled) { _ in move(choice, by: -1) }
        let down = UIAction(title: "Move Down", image: UIImage(systemName: "arrow.down"),
                            attributes: canMove(choice, by: 1) ? [] : .disabled) { _ in move(choice, by: 1) }
        var groups: [UIMenuElement] = [UIMenu(options: .displayInline, children: [up, down])]
        if TabOrder.canHide(choice, from: TabOrder.tabs) {
            groups.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Remove from Sidebar", image: UIImage(systemName: "minus.circle")) { _ in remove(choice) },
            ]))
        }
        return UIMenu(children: groups + spaceMenu().children)
    }

    /// The sidebar's own menu (a Control-click between rows, the foot's +): Add to Sidebar ▸, Sidebar Settings….
    static func spaceMenu() -> UIMenu {
        let places = addable()
        let add: UIMenuElement = places.isEmpty
            // Owner 2026-11-17 (Mac calls Q11): Nothing left to add: the item itself, dimmed, not an empty submenu.
            ? UIAction(title: "Add to Sidebar", image: UIImage(systemName: "plus"), attributes: .disabled) { _ in }
            : UIMenu(title: "Add to Sidebar", image: UIImage(systemName: "plus"), children: addGroups(places))
        let settings = UIAction(title: "Sidebar Settings…", image: UIImage(systemName: "gearshape")) { _ in openSettings() }
        // [bots-place] The bots in the sidebar, or a Bots row whose list opens beside it (while Bots is a place).
        var view: [UIMenuElement] = []
        if TabOrder.tabs.contains(.main(.bots)) {
            view.append(UIAction(title: "Bots in Sidebar", state: MacSidebar.botsInSidebar ? .on : .off) { _ in
                MacSidebar.botsInSidebar.toggle()
            })
            // [pinned-only] Only the pinned bots (and one that wants you), while the bots are in the sidebar.
            if MacSidebar.botsInSidebar {
                view.append(UIAction(title: "Pinned Bots Only", state: MacSidebar.pinnedOnly ? .on : .off) { _ in
                    MacSidebar.pinnedOnly.toggle()
                })
            }
        }
        // [sidebar-usage] What is left on each plan, at the sidebar's foot.
        view.append(UIAction(title: "Plan Usage", state: SidebarUsageStore.shown ? .on : .off) { _ in
            SidebarUsageStore.shown.toggle()
        })
        return UIMenu(children: [UIMenu(options: .displayInline, children: [add]), UIMenu(options: .displayInline, children: view),
                                 UIMenu(options: .displayInline, children: [settings])])
    }

    /// [sidebar-add-tools] Add to Sidebar's items: the pages in neither list first, then "From Tools" (each leaves
    /// Tools for the pages under the line), each group only when it has items.
    private static func addGroups(_ places: [Place]) -> [UIMenuElement] {
        func item(_ place: Place) -> UIAction { UIAction(title: place.title, image: place.image) { _ in add(place.choice) } }
        let others = places.filter { !$0.fromTools }.map(item)
        let tools = places.filter(\.fromTools).map(item)
        var groups: [UIMenuElement] = []
        if !others.isEmpty { groups.append(UIMenu(options: .displayInline, children: others)) }
        if !tools.isEmpty { groups.append(UIMenu(title: "From Tools", options: .displayInline, children: tools)) }
        return groups
    }

    /// A More row's Control-click: Add to Sidebar, when its page can be there.
    static func moreRowMenu(rowID: String) -> UIMenu? {
        guard let choice = choice(forMoreRow: rowID) else { return nil }
        return UIMenu(children: [
            UIAction(title: "Add to Sidebar", image: UIImage(systemName: "plus")) { _ in add(choice) },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Sidebar Settings…", image: UIImage(systemName: "gearshape")) { _ in openSettings() },
            ]),
        ])
    }

    /// [tools-menu-icon] A sidebar row's icon at a menu's size (the folded sidebar's Tools menu). Owner 2026-11-22: "the
    /// kanban icon here is too big": a drawn glyph (Kanban, Bots) is made at the bar's size and a menu draws an image
    /// at the size it is, where a symbol takes the menu's own size. Those are drawn again as Add to Sidebar draws them.
    static func menuImage(_ item: UITabBarItem) -> UIImage? {
        if let image = item.image, image.isSymbolImage { return image }
        if item.accessibilityIdentifier == "tab-page-\(PagesTabs.botsRowID)" { return image(.main(.bots), symbol: nil) }
        if let choice = TabChoice(tag: item.tag), choice == .page("kanban") || choice == .main(.workspace) {
            return image(choice, symbol: nil)
        }
        return item.image
    }

    /// The place's icon as the sidebar draws it, at a menu's size.
    private static func image(_ choice: TabChoice, symbol: String?) -> UIImage? {
        let size: CGFloat = 15
        switch choice {
        case .main(.bots): return TabIcons.bot(pointSize: size).withRenderingMode(.alwaysTemplate)
        case .main(.sessions): return UIImage(systemName: "bubble.left.and.bubble.right")
        case .main(.jobs): return UIImage(systemName: "calendar.badge.clock")
        case .main(.workspace):
            return TabOrderPage.workspaceTitle == "Kanban" ? TabIcons.kanban(pointSize: size).withRenderingMode(.alwaysTemplate)
                : UIImage(systemName: "photo.on.rectangle")
        case .main(.more): return UIImage(systemName: "ellipsis")
        case .page("kanban"): return TabIcons.kanban(pointSize: size).withRenderingMode(.alwaysTemplate)
        case .page: return UIImage(systemName: symbol ?? "square.dashed")
        }
    }

    // MARK: Settings › Tabs

    /// Sidebar Settings…: Settings › Tabs in the Settings window, as ⌘, opens it (Mac polish #29: it opened the window at
    /// its first page and turned the main window to the hidden More list). The main window stays on what it shows. Only
    /// with no window to open (signed out) does it go the old way, in the right pane.
    static func openSettings() {
        AppLog.note("mac", "sidebar: settings")
        if MacSettingsWindow.open(category: .appearance, then: { SettingsNavigator.openRoot("tab-order", router: $0) }) { return }
        guard let root = MainTabController.current else { return }
        root.showSettings()
        openTabsPage(tries: 20)
    }

    /// Settings' first page is made on its stack a moment after the push: Tabs goes over it once its router has one.
    private static func openTabsPage(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let root = MainTabController.current else { return }
            let stacks = [root.split?.detail, root.selectedViewController as? UINavigationController].compactMap { $0 }
            let settings = stacks.flatMap(\.viewControllers).compactMap { $0 as? SettingsRootController }.last
            if let settings, settings.router.navigation != nil {
                SettingsNavigator.openRoot("tab-order", router: settings.router)
            } else if tries > 0 {
                openTabsPage(tries: tries - 1)
            }
        }
    }
}
#endif
