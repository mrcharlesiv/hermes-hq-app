import Foundation
import Testing
@testable import HermesHQNative

@Suite("Workspace tabs")
struct WorkspaceTabsTests {
    private func session(_ id: String, profile: String = "otto", title: String? = nil) -> WorkspaceTabRecord {
        WorkspaceTabRecord(kind: .session, profile: profile, id: id, title: title ?? "Session \(id)")
    }

    private func bot(_ id: String, title: String? = nil) -> WorkspaceTabRecord {
        WorkspaceTabRecord(kind: .bot, profile: id, id: id, title: title ?? id.capitalized)
    }

    @Test func openedSessionsAppendWithoutEvictionCap() {
        var list = WorkspaceTabList()
        for i in 1...12 {
            let added = list.open(session("s\(i)"))
            #expect(added)
        }
        #expect(list.tabs.count == 12)
        #expect(list.tabs.map(\.id) == (1...12).map { "s\($0)" })
    }

    @Test func reopeningExistingTabKeepsItsPositionAndUpdatesTitle() {
        var list = WorkspaceTabList(tabs: [session("s1", title: "Old"), session("s2"), bot("ivy")])
        let changed = list.open(session("s1", title: "Renamed"))
        #expect(changed)
        #expect(list.tabs.map(\.id) == ["s1", "s2", "ivy"])
        #expect(list.tabs[0].title == "Renamed")
        // Opening again with identical title is a no-op
        let repeated = list.open(session("s1", title: "Renamed"))
        #expect(!repeated)
    }

    @Test func closingActiveTabSelectsNeighborRightThenLeft() {
        var list = WorkspaceTabList(tabs: [session("s1"), session("s2"), session("s3")])
        let active2 = list.tabs[1].tabId
        let firstClose = list.close(tabId: active2, activeTabId: active2)
        #expect(firstClose.removed)
        #expect(firstClose.nextActive?.id == "s3")
        #expect(list.tabs.map(\.id) == ["s1", "s3"])

        // Closing rightmost active tab falls back to the tab on its left
        let active3 = list.tabs[1].tabId
        let secondClose = list.close(tabId: active3, activeTabId: active3)
        #expect(secondClose.removed)
        #expect(secondClose.nextActive?.id == "s1")
        #expect(list.tabs.map(\.id) == ["s1"])

        // Closing the final active tab returns nil
        let active1 = list.tabs[0].tabId
        let lastClose = list.close(tabId: active1, activeTabId: active1)
        #expect(lastClose.removed)
        #expect(lastClose.nextActive == nil)
        #expect(list.tabs.isEmpty)
    }

    @Test func closingInactiveTabLeavesActiveAlone() {
        var list = WorkspaceTabList(tabs: [session("s1"), session("s2"), session("s3")])
        let result = list.close(tabId: list.tabs[0].tabId, activeTabId: list.tabs[2].tabId)
        #expect(result.removed)
        #expect(result.nextActive == nil)
        #expect(list.tabs.map(\.id) == ["s2", "s3"])
    }

    @Test func closeOthersAndCloseToRight() {
        var list = WorkspaceTabList(tabs: [session("s1"), session("s2"), session("s3"), session("s4")])
        let keep2 = list.tabs[1].tabId
        let closedRight = list.closeToRight(of: keep2)
        #expect(closedRight)
        #expect(list.tabs.map(\.id) == ["s1", "s2"])
        let closedRightAgain = list.closeToRight(of: keep2)
        #expect(!closedRightAgain)

        let closedOthers = list.closeOthers(keeping: keep2)
        #expect(closedOthers)
        #expect(list.tabs.map(\.id) == ["s2"])
        let closedAll = list.closeAll()
        #expect(closedAll)
        #expect(list.tabs.isEmpty)
    }

    @Test func persistsPerGatewayAcrossRelaunches() {
        let suiteName = "hq.tests.workspace-tabs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var gwA = WorkspaceTabList()
        gwA.open(session("a1", title: "Plan week"))
        gwA.open(bot("otto", title: "Otto"))
        gwA.save(gatewayId: "gw-a", defaults: defaults)

        var gwB = WorkspaceTabList()
        gwB.open(session("b1", title: "Release notes"))
        gwB.save(gatewayId: "gw-b", defaults: defaults)

        let loadedA = WorkspaceTabList.load(gatewayId: "gw-a", defaults: defaults)
        let loadedB = WorkspaceTabList.load(gatewayId: "gw-b", defaults: defaults)
        #expect(loadedA == gwA)
        #expect(loadedB == gwB)

        // Closing all tabs clears persisted state
        gwA.closeAll()
        gwA.save(gatewayId: "gw-a", defaults: defaults)
        #expect(WorkspaceTabList.load(gatewayId: "gw-a", defaults: defaults).tabs.isEmpty)
    }

    @Test("Show Next Tab and Show Previous Tab step to the neighbour and wrap round at either end, as Safari's ⌃Tab does")
    func cyclingWrapsRound() {
        #expect(WorkspaceTabList.cycledIndex(count: 4, active: 0, step: 1) == 1)
        #expect(WorkspaceTabList.cycledIndex(count: 4, active: 2, step: -1) == 1)
        #expect(WorkspaceTabList.cycledIndex(count: 4, active: 3, step: 1) == 0)
        #expect(WorkspaceTabList.cycledIndex(count: 4, active: 0, step: -1) == 3)
    }

    @Test("With one tab, none, or no step there is nowhere to go; from a page with no tab the walk starts at an end")
    func cyclingEdges() {
        #expect(WorkspaceTabList.cycledIndex(count: 1, active: 0, step: 1) == nil)
        #expect(WorkspaceTabList.cycledIndex(count: 1, active: 0, step: -1) == nil)
        #expect(WorkspaceTabList.cycledIndex(count: 0, active: nil, step: 1) == nil)
        #expect(WorkspaceTabList.cycledIndex(count: 3, active: 1, step: 0) == nil)
        #expect(WorkspaceTabList.cycledIndex(count: 3, active: nil, step: 1) == 0)
        #expect(WorkspaceTabList.cycledIndex(count: 3, active: nil, step: -1) == 2)
        #expect(WorkspaceTabList.cycledIndex(count: 1, active: nil, step: 1) == 0)
        #expect(WorkspaceTabList.cycledIndex(count: 3, active: 7, step: 1) == 0)
    }
}
