import Foundation
import Testing
@testable import HermesHQNative

/// [taborder] Settings › Tabs: what is stored, how a bad or partial list reads, which tabs can be turned off, and how
/// tabs are arranged. [customtabs] Hidden tabs and More pages as tabs.
@Suite struct TabOrderTests {
    private func defaults() -> UserDefaults {
        let name = "TabOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let files = TabChoice.page("files")
    private let settings = TabChoice.page("settings")

    @Test func defaultTabsWhenNothingIsStored() {
        #expect(TabOrder.tabs(in: defaults()) == [.main(.bots), .main(.sessions), .main(.jobs), .main(.workspace)])
    }

    @Test func storesAMoveAndReadsItBack() {
        let defaults = defaults()
        #expect(TabOrder.set([.main(.sessions), .main(.bots), .main(.jobs), .main(.workspace)], in: defaults))
        #expect(TabOrder.tabs(in: defaults) == [.main(.sessions), .main(.bots), .main(.jobs), .main(.workspace)])
        #expect(defaults.stringArray(forKey: TabOrder.key) == ["sessions", "bots", "jobs", "workspace"])
        #expect(!TabOrder.set([.main(.sessions), .main(.bots), .main(.jobs), .main(.workspace)], in: defaults))   // no change
    }

    @Test func theDefaultIsStoredAsNothing() {
        let defaults = defaults()
        TabOrder.set([.main(.jobs), .main(.bots)], in: defaults)
        #expect(TabOrder.set(TabOrder.defaultTabs, in: defaults))
        #expect(defaults.object(forKey: TabOrder.key) == nil)
    }

    @Test func build448OrdersReadAsTheyWere() {
        // Build 448 stored every main tab, in the owner's order.
        let defaults = defaults()
        defaults.set(["workspace", "sessions", "bots", "jobs"], forKey: TabOrder.key)
        #expect(TabOrder.tabs(in: defaults) == [.main(.workspace), .main(.sessions), .main(.bots), .main(.jobs)])
    }

    @Test func hidesTabsAndAddsMorePages() {
        // Mark: no Bots, Sessions first, Files as a tab.
        let defaults = defaults()
        #expect(TabOrder.set([.main(.sessions), .main(.jobs), files], in: defaults))
        #expect(defaults.stringArray(forKey: TabOrder.key) == ["sessions", "jobs", "page.files"])
        #expect(TabOrder.tabs(in: defaults) == [.main(.sessions), .main(.jobs), files])
    }

    @Test func aBadListIsCleanedUp() {
        // Repeats, More, unknown names and unknown pages are dropped; the list keeps at most four tabs.
        let defaults = defaults()
        defaults.set(["sessions", "more", "nonsense", "page.nope", "sessions", 7, "page.files"], forKey: TabOrder.key)
        #expect(TabOrder.tabs(in: defaults) == [.main(.sessions), files])
        #expect(TabOrder.normalized([.main(.bots), .main(.jobs), files, settings, .main(.workspace)])
                == [.main(.bots), .main(.jobs), files, settings])
        // A launch argument (`-hqn.tabOrder "(sessions, jobs)"`) arrives as an array of strings.
        defaults.set(["sessions", "jobs"] as NSArray, forKey: TabOrder.key)
        #expect(TabOrder.tabs(in: defaults) == [.main(.sessions), .main(.jobs)])
    }

    @Test func botsOrSessionsAlwaysStays() {
        // Neither left: Bots comes back first. Over the limit: the last page goes, never a list.
        #expect(TabOrder.normalized([.main(.jobs), files]) == [.main(.bots), .main(.jobs), files])
        #expect(TabOrder.normalized([]) == [.main(.bots)])
        #expect(TabOrder.normalized([.main(.jobs), files, settings, .main(.workspace), .main(.sessions)])
                == [.main(.jobs), files, settings, .main(.sessions)])
        let tabs: [TabChoice] = [.main(.sessions), .main(.jobs)]
        #expect(!TabOrder.canHide(.main(.sessions), from: tabs))
        #expect(TabOrder.canHide(.main(.jobs), from: tabs))
        #expect(TabOrder.canHide(.main(.bots), from: [.main(.bots), .main(.sessions)]))
        #expect(!TabOrder.canHide(.main(.bots), from: tabs))   // not shown
    }

    @Test func theMacSidebarHoldsEveryPlace() {
        // [mac-sidebar] Owner 2026-10-31: no cap of four in the Mac's sidebar. The iPhone's and iPad's bar keep it.
        #expect(TabOrder.barLimit == 4)
        #expect(TabOrder.sidebarLimit == HQTab.movable.count + TabChoice.pageIDs.count)
        let every = HQTab.movable.map(TabChoice.main) + TabChoice.pageIDs.map(TabChoice.page)
        #expect(TabOrder.normalized(every, limit: TabOrder.sidebarLimit) == every)
        #expect(TabOrder.normalized(every, limit: TabOrder.barLimit) == Array(every.prefix(4)))
        // Repeats still go, and with neither list Bots still leads, with every page kept.
        let pages = TabChoice.pageIDs.map(TabChoice.page)
        #expect(TabOrder.normalized(pages + pages, limit: TabOrder.sidebarLimit) == [.main(.bots)] + pages)
        #if targetEnvironment(macCatalyst)
        #expect(TabOrder.limit == TabOrder.sidebarLimit)
        #else
        #expect(TabOrder.limit == TabOrder.barLimit)
        #endif
        // Stored and read back whole (the default argument is this device's limit).
        let defaults = defaults()
        TabOrder.set(every, in: defaults)
        #expect(TabOrder.tabs(in: defaults).count == min(every.count, TabOrder.limit))
    }

    @MainActor @Test func numberKeysPickPlaces() {
        // ⌘1… pick the places in order; on the Mac ⌘9 picks the ninth, or with more than nine the last, and More (no
        // sidebar row there) takes no number (Mac polish #18).
        let five = [100, 101, 102, 103, 104]   // five places, More not among them
        #expect(KeyCommands.tabIndex(forShortcut: 0, among: five) == 0)
        #expect(KeyCommands.tabIndex(forShortcut: 4, among: five) == 4)
        #expect(KeyCommands.tabIndex(forShortcut: 4, among: Array(five.prefix(3))) == nil)
        #expect(KeyCommands.shortcut(forTab: 1, among: five) == 2)
        #if targetEnvironment(macCatalyst)
        let places = Array(100..<113) + [HQTab.more.rawValue]   // thirteen places, then More
        #expect(KeyCommands.tabIndex(forShortcut: 7, among: places) == 7)
        #expect(KeyCommands.tabIndex(forShortcut: 8, among: Array(100..<109) + [HQTab.more.rawValue]) == 8)
        #expect(KeyCommands.tabIndex(forShortcut: 8, among: places) == 12)
        #expect(KeyCommands.tabIndex(forShortcut: 8, among: Array(100..<106)) == nil)
        #expect(KeyCommands.shortcut(forTab: 12, among: places) == 9)
        #expect(KeyCommands.shortcut(forTab: 13, among: places) == nil)   // More
        #expect(KeyCommands.shortcut(forTab: 8, among: places) == nil)
        #expect(KeyCommands.shortcut(forTab: 8, among: Array(100..<109)) == 9)
        #else
        #expect(KeyCommands.tabIndex(forShortcut: 4, among: HQTab.allCases.map(\.rawValue)) == 4)   // More is ⌘5 there
        #expect(KeyCommands.shortcut(forTab: 5, among: Array(100..<106)) == nil)
        #endif
    }

    @Test func arrangesTabsByTagWithMoreLast() {
        let built = [0, 1, 2, 3, 4]   // as MainTabController builds them
        #expect(TabOrder.arranged(built, tabs: [.main(.sessions), .main(.bots), .main(.jobs), .main(.workspace)]) { $0 } == [1, 0, 2, 3, 4])
        #expect(TabOrder.arranged(built, tabs: [.main(.workspace), .main(.jobs), .main(.sessions), .main(.bots)]) { $0 } == [3, 2, 1, 0, 4])
        // No More tab (no More rows), and an already arranged list arranged again.
        #expect(TabOrder.arranged([0, 1, 2, 3], tabs: [.main(.jobs), .main(.sessions), .main(.bots), .main(.workspace)]) { $0 } == [2, 1, 0, 3])
        #expect(TabOrder.arranged([2, 1, 0, 3, 4], tabs: [.main(.jobs), .main(.sessions), .main(.bots), .main(.workspace)]) { $0 } == [2, 1, 0, 3, 4])
        // Only Bots and Sessions (no gateway: previews and tests).
        #expect(TabOrder.arranged([0, 1], tabs: [.main(.sessions), .main(.bots), .main(.jobs), .main(.workspace)]) { $0 } == [1, 0])
    }

    @Test func leavesHiddenTabsOutAndPlacesPageTabs() {
        let built = [0, 1, 2, 3, files.tag, 4]
        #expect(TabOrder.arranged(built, tabs: [.main(.sessions), files, .main(.jobs)]) { $0 } == [1, files.tag, 2, 4])
        // A chosen page this gateway lacks was never built: the others keep their order.
        #expect(TabOrder.arranged([0, 1, 2, 3, 4], tabs: [.main(.sessions), files, .main(.jobs)]) { $0 } == [1, 2, 4])
    }

    @Test func tagsMatchTheOldPlacesAndPagesSitAbove() {
        // A tab saved by an older build was its place in the default order; it must read as the same tab.
        #expect(HQTab.allCases.map(\.rawValue) == [0, 1, 2, 3, 4])
        #expect(HQTab.allCases.allSatisfy { HQTab(key: $0.key) == $0 })
        #expect(files.tag == 100 && settings.tag == 111)
        for id in TabChoice.pageIDs {
            let page = TabChoice.page(id)
            #expect(TabChoice(tag: page.tag) == page && TabChoice(key: page.key) == page)
        }
        #expect(TabChoice(tag: HQTab.more.rawValue) == nil && TabChoice(key: "more") == nil)
        #expect(HQTab.bots.otherList == .sessions && HQTab.sessions.otherList == .bots && HQTab.jobs.otherList == nil)
    }
}
