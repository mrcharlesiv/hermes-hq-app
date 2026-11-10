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
    }

    /// A row's drag (`MacSidebar`): the place it shows.
    final class DragBox: NSObject {
        let choice: TabChoice
        init(choice: TabChoice) { self.choice = choice }
    }

    // MARK: What can change

    /// What could join the sidebar now, as Settings › Tabs' add list has it: the main tabs not in it, then the More
    /// pages this gateway has, in More's order.
    static func addable() -> [Place] {
        let shown = TabOrder.tabs
        let mains = HQTab.movable.map(TabChoice.main).filter { !shown.contains($0) }
        let pages = TabOrderPage.pageChoices().filter { !shown.contains(.page($0.id)) }
        return mains.map { Place(choice: $0, title: TabOrderPage.title($0), image: image($0, symbol: nil)) }
            + pages.map { Place(choice: .page($0.id), title: $0.title, image: image(.page($0.id), symbol: $0.symbol)) }
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

    /// The places in the sidebar's order as it shows them (a page this gateway lacks is in `TabOrder.tabs` but not
    /// here: moves step over it).
    private static var shown: [TabChoice] {
        MainTabController.current?.placedTabs.compactMap { TabChoice(tag: $0.tabBarItem.tag) } ?? TabOrder.tabs
    }

    /// `choice` one row up (-1) or down (+1); false when it is already at that end.
    static func canMove(_ choice: TabChoice, by step: Int) -> Bool {
        let rows = shown
        guard let index = rows.firstIndex(of: choice) else { return false }
        return rows.indices.contains(index + step)
    }

    static func move(_ choice: TabChoice, by step: Int) {
        let rows = shown
        guard let index = rows.firstIndex(of: choice), rows.indices.contains(index + step) else { return }
        AppLog.note("mac", "sidebar: moved \(choice.key) \(step < 0 ? "up" : "down")")
        place(choice, beside: rows[index + step], after: step > 0)
    }

    /// A dragged row dropped above `target`, or below the last row (nil).
    static func move(_ choice: TabChoice, before target: TabChoice?) {
        guard target != choice else { return }
        AppLog.note("mac", "sidebar: dragged \(choice.key) above \(target?.key ?? "the end")")
        if let target { place(choice, beside: target, after: false) } else if let last = shown.last, last != choice { place(choice, beside: last, after: true) }
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
            ? UIAction(title: "Every Page Is in the Sidebar", attributes: .disabled) { _ in }
            : UIMenu(title: "Add to Sidebar", image: UIImage(systemName: "plus"), children: places.map { place in
                UIAction(title: place.title, image: place.image) { _ in add(place.choice) }
            })
        let settings = UIAction(title: "Sidebar Settings…", image: UIImage(systemName: "gearshape")) { _ in openSettings() }
        return UIMenu(children: [UIMenu(options: .displayInline, children: [add]), UIMenu(options: .displayInline, children: [settings])])
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
