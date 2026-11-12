// [taborder] Settings › Appearance › Tabs (a tester, Nous Research Discord 2026-10-29: "I am not much of a Bot guy
// and preferred using the sessions"): which tabs the bar shows on this device, and in what order. Bots, Sessions, Jobs
// and the Kanban or Artifacts tab can each be hidden or moved, and a More page (Files, Changes, Settings…) can be a
// tab of its own. Up to four tabs, then More, which always stays last. Bots or Sessions always stays: chats open
// there. [mac-sidebar] The Mac's sidebar has no such cap (owner 2026-10-31: "you should be able to add more options to
// the sidebar"): every main tab and every More page can have a row of its own there, as Mail's and Finder's places. Code that opens a tab asks for it by what it is (`HQTab`), never by its place in the bar.

import Foundation

/// The main tabs by what they are. The raw value is the tag on the tab's bar item, and also the place each tab had
/// before tabs could move, so a tab saved by an older build (an index then) reads as the same tab.
nonisolated enum HQTab: Int, CaseIterable, Sendable {
    case bots = 0, sessions, jobs, workspace, more

    /// The tabs Settings › Tabs moves and hides, in their default order. More is not one of them.
    static let movable: [HQTab] = [.bots, .sessions, .jobs, .workspace]

    /// How the tabs are stored (readable in a launch argument: `-hqn.tabOrder "(sessions, jobs)"`).
    var key: String {
        switch self {
        case .bots: "bots"
        case .sessions: "sessions"
        case .jobs: "jobs"
        case .workspace: "workspace"
        case .more: "more"
        }
    }

    init?(key: String) {
        guard let tab = HQTab.allCases.first(where: { $0.key == key }) else { return nil }
        self = tab
    }

    /// [customtabs] The list tab a chat opens on while this one is hidden (one of the two always shows).
    var otherList: HQTab? {
        switch self {
        case .bots: .sessions
        case .sessions: .bots
        default: nil
        }
    }
}

/// [customtabs] A tab the bar can show: a main tab, or a More page (its More row's id) as a tab of its own.
nonisolated enum TabChoice: Hashable, Sendable {
    case main(HQTab)
    case page(String)

    /// The More pages that can be tabs. A page's tag is 100 + its place here, so new pages go at the end.
    static let pageIDs = ["files", "review", "command-center", "capabilities", "profiles", "messaging", "spawn-tree",
                          "star-map", "webhooks", "connectors", "import-sessions", "settings", "artifacts", "kanban",
                          "pinned",   // [pins]
                          "terminal",   // [terminal]
                          "tasks",   // [tasks]
                          "marketplace",   // [marketplace-row]
                          "usage",
                          "passwords",   // [passwords-page]
                          "composio"]   // [composio-row]   // Usage, a page of its own since Command Center split: never a Mac Tool without it (owner 2026-11-07)
    static let firstPageTag = 100

    var key: String {
        switch self {
        case .main(let tab): tab.key
        case .page(let id): "page." + id
        }
    }

    init?(key: String) {
        if key.hasPrefix("page.") {
            let id = String(key.dropFirst(5))
            guard Self.pageIDs.contains(id) else { return nil }
            self = .page(id)
        } else {
            guard let tab = HQTab(key: key), tab != .more else { return nil }
            self = .main(tab)
        }
    }

    /// The tag on the tab's bar item.
    var tag: Int {
        switch self {
        case .main(let tab): tab.rawValue
        case .page(let id): Self.firstPageTag + (Self.pageIDs.firstIndex(of: id) ?? 0)
        }
    }

    init?(tag: Int) {
        if let tab = HQTab(rawValue: tag) {
            guard tab != .more else { return nil }
            self = .main(tab)
        } else {
            let place = tag - Self.firstPageTag
            guard Self.pageIDs.indices.contains(place) else { return nil }
            self = .page(Self.pageIDs[place])
        }
    }

    var isList: Bool { self == .main(.bots) || self == .main(.sessions) }
}

nonisolated enum TabOrder {
    static let key = "hqn.tabOrder"
    static let didChange = Notification.Name("hqn.tabOrder.changed")
    /// The tabs before More. With More that is five, all the bar holds before iOS adds a More of its own.
    static let barLimit = 4
    /// [mac-sidebar] The Mac's sidebar: every main tab and every page, More after them while it has rows left.
    static let sidebarLimit = HQTab.movable.count + TabChoice.pageIDs.count
    /// The cap on this device: the iPhone's and iPad's bar, or the Mac's sidebar.
    static var limit: Int {
        #if targetEnvironment(macCatalyst)
        sidebarLimit
        #else
        barLimit
        #endif
    }
    static let defaultTabs: [TabChoice] = HQTab.movable.map(TabChoice.main)

    /// The tabs the bar shows, in its order (More not counted).
    static var tabs: [TabChoice] {
        get { tabs(in: .standard) }
        set { if set(newValue, in: .standard) { NotificationCenter.default.post(name: didChange, object: nil) } }
    }

    static func tabs(in defaults: UserDefaults) -> [TabChoice] {
        guard let stored = defaults.array(forKey: key) else { return defaultTabs }
        return normalized(stored.compactMap { $0 as? String }.compactMap(TabChoice.init(key:)))
    }

    /// Stores `tabs` (the default is stored as nothing); answers whether what the bar shows changed.
    @discardableResult
    static func set(_ tabs: [TabChoice], in defaults: UserDefaults) -> Bool {
        let next = normalized(tabs)
        let before = self.tabs(in: defaults)
        if next == defaultTabs { defaults.removeObject(forKey: key) } else { defaults.set(next.map(\.key), forKey: key) }
        return next != before
    }

    /// Each tab once, in the given order, at most `limit`; Bots leads when neither Bots nor Sessions is left (chats open
    /// on one of them). A list stored by build 448 (all four main tabs in some order) reads as it was.
    static func normalized(_ tabs: [TabChoice], limit: Int = TabOrder.limit) -> [TabChoice] {
        var out: [TabChoice] = []
        for tab in tabs where !out.contains(tab) { out.append(tab) }
        if !out.contains(where: \.isList) { out.insert(.main(.bots), at: 0) }
        while out.count > limit, let last = out.lastIndex(where: { !$0.isList }) { out.remove(at: last) }
        return out
    }

    /// Whether `tab` can be turned off: one of Bots and Sessions stays.
    static func canHide(_ tab: TabChoice, from tabs: [TabChoice]) -> Bool {
        tabs.contains(tab) && (!tab.isList || tabs.filter(\.isList).count > 1)
    }

    /// `items` as the bar shows them, by each one's tab tag: the shown tabs in `tabs` order, then More. A tab that is
    /// built but not shown is left out.
    static func arranged<Item>(_ items: [Item], tabs: [TabChoice], tag: (Item) -> Int) -> [Item] {
        let order = tabs.map(\.tag) + [HQTab.more.rawValue]
        let ranks = items.map { order.firstIndex(of: tag($0)) }
        return items.indices.compactMap { index in ranks[index].map { (rank: $0, index: index) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map { items[$0.index] }
    }
}
