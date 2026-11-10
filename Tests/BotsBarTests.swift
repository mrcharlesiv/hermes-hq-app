import Foundation
import Testing
@testable import HermesHQNative

/// Pinned-tile order (`S/ui-bots/pinned-model.test.ts`), its persistence per account, and the Bots bar's filter rules.
@Suite(.serialized) struct BotsBarTests {
    // MARK: PinOrder (pinned-model.test.ts)

    @Test func movesOneKey() {
        #expect(PinOrder.moved(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"])
        #expect(PinOrder.moved(["a", "b", "c", "d"], from: 3, to: 1) == ["a", "d", "b", "c"])
        #expect(PinOrder.moved(["a", "b"], from: 1, to: 1) == ["a", "b"])
        #expect(PinOrder.moved(["a", "b"], from: 5, to: 0) == ["a", "b"])
    }

    @Test func savesADropIntoThePlacesTheTilesHeld() {
        #expect(PinOrder.next(saved: [], before: ["a", "b", "c"], after: ["c", "a", "b"]) == ["c", "a", "b"])
        // A pin out of view keeps its place.
        #expect(PinOrder.next(saved: ["a", "b", "x", "c"], before: ["a", "b", "c"], after: ["c", "a", "b"]) == ["c", "a", "x", "b"])
        // Tiles never placed before go after the saved ones.
        #expect(PinOrder.next(saved: ["a"], before: ["a", "b", "c"], after: ["b", "a", "c"]) == ["b", "a", "c"])
        // Past the limit, the oldest names not on screen go first.
        #expect(PinOrder.next(saved: ["x", "y", "a", "z"], before: ["a", "b"], after: ["b", "a"], limit: 4) == ["y", "b", "z", "a"])
    }

    // MARK: Tiles in the roster (RosterBuilder)

    private func pinnedRows(_ names: [String], unpinned: [String] = []) -> [RosterProfile] {
        // Newest first by name order: a 100, b 90, …
        (names + unpinned).enumerated().map { index, name in
            RosterProfile(json: BotsTest.row(name, canonical: BotsTest.session("c-\(name)", lastActive: Double(100 - index * 10)),
                                             meta: names.contains(name) ? ["pinned": true] : [:]))!
        }
    }

    @Test func draggedPinsLeadAndNeverPlacedPinsKeepTheirRosterPlace() {
        let profiles = pinnedRows(["a", "b", "c", "d"], unpinned: ["e"])
        let tiles = { (order: [String]) in RosterBuilder.build(.init(profiles: profiles, pinOrder: order)).layout.tiles.map(\.id) }
        #expect(tiles([]) == ["a", "b", "c", "d"])
        #expect(tiles(["c", "a"]) == ["c", "a", "b", "d"])
        // An unpinned bot keeps its saved place for when it's pinned again, but never shows as a tile.
        #expect(tiles(["e", "d"]) == ["d", "a", "b", "c"])
        let layout = RosterBuilder.build(.init(profiles: profiles, pinOrder: ["d", "c"])).layout
        #expect(layout.tiles.map(\.pinOrder) == [0, 1, 2, 3])
    }

    @Test func sixTilesAtMostAndTheRestInPinned() {
        let names = (0..<8).map { "p\($0)" }
        let out = RosterBuilder.build(.init(profiles: pinnedRows(names), pinOrder: ["p7", "p6"]))
        #expect(out.layout.tiles.map(\.id) == ["p7", "p6", "p0", "p1", "p2", "p3"])
        #expect(out.layout.sections.first?.isPinned == true)
        #expect(out.layout.sections.first?.bots.map(\.id) == ["p4", "p5"])
    }

    /// A drop is kept on this device for the account, and comes back with the next launch's cached paint.
    @Test func storeKeepsADropAcrossLaunches() async throws {
        let rows = ["default", "inbox", "ivy"].enumerated().map { index, name in
            BotsTest.row(name, canonical: BotsTest.session("c-\(name)", lastActive: Double(100 - index * 10)), meta: ["pinned": true])
        }
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult(rows) }
        let dir = BotsTest.tempDirectory()
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        #expect(store.layout.tiles.map(\.id) == ["default", "inbox", "ivy"])
        var changes = 0
        store.onChange = { changes += 1 }
        store.placeTiles(before: ["default", "inbox", "ivy"], after: ["ivy", "default", "inbox"])
        #expect(store.layout.tiles.map(\.id) == ["ivy", "default", "inbox"])
        #expect(changes == 1)
        // The same order again writes nothing new.
        store.placeTiles(before: ["ivy", "default", "inbox"], after: ["ivy", "default", "inbox"])
        #expect(changes == 1)
        store.stop()
        RosterDiskWriter.shared.flush()

        let again = BotStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        #expect(again.layout.tiles.map(\.id) == ["ivy", "default", "inbox"])
        // Another account on this device has its own order.
        let other = GatewayAccount(id: "http://127.0.0.1:9716|other", baseURL: URL(string: "http://127.0.0.1:9716")!,
                                   kind: .password, username: "other", label: "127.0.0.1")
        let elsewhere = BotStore(client: BotsFakeGatewayClient(account: other), account: other, cacheDirectory: dir, timing: .fast,
                                 autoStart: false)
        #expect(elsewhere.layout.tiles.isEmpty)
    }

    // MARK: Bar filters (filter-token.ts, roster-pane-derivation.ts)

    private func bot(_ id: String, minutesAgo: Double?, working: Bool = false, hidden: Bool = false) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil,
            lastActive: minutesAgo.map { Date(timeIntervalSince1970: 1_000_000_000 - $0 * 60) }, isWorking: working,
            unread: false, pinned: false, pinOrder: nil, sectionName: nil, hidden: hidden, canonicalSessionId: nil, head: nil)
    }

    // [filters-only] Filter is always on the bar now (owner 2026-11-03): only its token is worked out here.
    @Test func filterTokenNamesTheActivity() {
        #expect(BotsBar.token(activity: .all) == nil)
        #expect(BotsBar.token(activity: .active) == "Active Now")
    }

    @Test func activityFilterMatchesTheWeb() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let bots = [bot("busy", minutesAgo: 5, working: true), bot("week", minutesAgo: 60 * 24 * 6),
                    bot("old", minutesAgo: 60 * 24 * 8), bot("never", minutesAgo: nil), bot("gone", minutesAgo: 1, hidden: true)]
        let ids = { (activity: BotActivityFilter, hidden: Bool) in
            Set(BotsBar.results(bots, query: "", activity: activity, showHidden: hidden, now: now).map(\.id))
        }
        #expect(ids(.active, false) == ["busy"])
        #expect(ids(.recent, false) == ["busy", "week"])
        #expect(ids(.older, false) == ["old", "never"])
        #expect(ids(.recent, true) == ["busy", "week", "gone"])
        // A search finds hidden bots too.
        #expect(BotsBar.results(bots, query: "gone", activity: .all, showHidden: false, now: now).map(\.id) == ["gone"])
    }
}
