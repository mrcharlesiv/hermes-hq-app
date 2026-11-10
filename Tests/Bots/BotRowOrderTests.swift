import Foundation
import Testing
@testable import HermesHQNative

/// [manualorder] Filter › Sort By › Manual: the rows' own order (`D/app/chat/sidebar/order.test.ts`), how each block
/// follows it, the store keeping it per account across launches, and Recent Activity dropping it.
@Suite(.serialized) struct BotRowOrderTests {
    private func profile(_ json: JSONValue) -> RosterProfile { RosterProfile(json: json)! }

    // MARK: Order rules (order.ts orderByIds, reconcileFreshFirst)

    @Test func ordersByTheSavedIds() {
        #expect(BotRowOrder.ordered(["a", "b", "c"], by: ["c", "a", "b"], id: { $0 }) == ["c", "a", "b"])
        #expect(BotRowOrder.ordered(["a", "b"], by: [], id: { $0 }) == ["a", "b"], "no saved order: activity order")
        #expect(BotRowOrder.ordered(["a", "b"], by: ["b", "b", "a"], id: { $0 }) == ["b", "a"], "a duplicate draws once")
    }

    /// A row the order doesn't name folds in by its activity position: newer than the first named row goes on top,
    /// older below the named ones.
    @Test func newRowsFoldInByPosition() {
        // Activity order: n1 (newest), a, n2, b. Saved: b, a.
        #expect(BotRowOrder.ordered(["n1", "a", "n2", "b"], by: ["b", "a"], id: { $0 }) == ["n1", "b", "a", "n2"])
        // Nothing named in this block: activity order as it is.
        #expect(BotRowOrder.ordered(["x", "y"], by: ["a"], id: { $0 }) == ["x", "y"])
    }

    @Test func staleIdsAreIgnoredAndDroppedOnReconcile() {
        #expect(BotRowOrder.ordered(["a", "b"], by: ["gone", "b", "a"], id: { $0 }) == ["b", "a"])
        let kept = BotRowOrder.reconciled(["gone", "b", "a"], blocks: [["b", "a"]], existing: ["a", "b"])
        #expect(kept == ["b", "a"])
        // A new bot goes where it folded in (newest: above the block's first named row; older: below its last); a pinned
        // tile (not shown as a row) keeps its place for when it comes back.
        #expect(BotRowOrder.reconciled(["a", "tile", "b"], blocks: [["new", "a", "b", "old"]], existing: ["a", "b", "tile", "new", "old"])
                == ["new", "a", "tile", "b", "old"])
        #expect(BotRowOrder.reconciled(["new", "a", "tile", "b", "old"], blocks: [["new", "a", "b", "old"]],
                                       existing: ["a", "b", "tile", "new", "old"]) == ["new", "a", "tile", "b", "old"],
                "settled: the same order again")
        // A row drawn in its old block while its filing write is out keeps the place its drop gave it.
        #expect(BotRowOrder.reconciled(["notes", "ivy", "research"], blocks: [["ivy", "research"], ["notes"]],
                                       existing: ["notes", "ivy", "research"]) == ["notes", "ivy", "research"])
    }

    /// A block's new sequence fills the places its rows held: other blocks' rows don't move.
    @Test func placingABlockLeavesTheOthersAlone() {
        let saved = ["w1", "w2", "h1", "w3", "h2"]
        #expect(BotRowOrder.placed(["w3", "w1", "w2"], in: saved) == ["w3", "w1", "h1", "w2", "h2"])
        // A row dropped in from another block takes the block's place it was given.
        #expect(BotRowOrder.placed(["h1", "h2", "w1"], in: ["w1", "w2", "h1", "h2"]) == ["h1", "w2", "h2", "w1"])
        // A name the order never had is added, then placed.
        #expect(BotRowOrder.placed(["x", "a"], in: ["a", "b"]) == ["x", "b", "a"])
    }

    @Test func moveUpAndDown() {
        #expect(BotRowOrder.moves(index: 0, count: 3) == [1])
        #expect(BotRowOrder.moves(index: 1, count: 3) == [-1, 1])
        #expect(BotRowOrder.moves(index: 2, count: 3) == [-1])
        #expect(BotRowOrder.moves(index: 0, count: 1).isEmpty)
        #expect(BotRowOrder.moves(index: nil, count: 3).isEmpty)
        #expect(BotRowOrder.moveTitle(-1) == "Move Up" && BotRowOrder.moveTitle(1) == "Move Down")
        // What Move Down on the first of three saves.
        let after = PinOrder.moved(["a", "b", "c"], from: 0, to: 1)
        #expect(BotRowOrder.placed(after, in: ["a", "b", "c", "z"]) == ["b", "a", "c", "z"])
    }

    /// [filters-only] Sort By no longer decides whether Filter shows: it always does (owner 2026-11-03).
    @Test func sortByWords() {
        #expect(BotSortOrder.allCases.map(\.title) == ["Recent Activity", "Manual"])
    }

    // MARK: Layout (each block follows the order; the tiles keep theirs)

    private var rows: [JSONValue] {
        let work: [String: JSONValue] = ["sectionId": "sec-work", "sectionName": "Work"]
        return [
            BotsTest.row("w1", canonical: BotsTest.session("s1", lastActive: 900), meta: work),
            BotsTest.row("w2", canonical: BotsTest.session("s2", lastActive: 800), meta: work),
            BotsTest.row("w3", canonical: BotsTest.session("s3", lastActive: 700), meta: work),
            BotsTest.row("u1", canonical: BotsTest.session("s4", lastActive: 600)),
            BotsTest.row("u2", canonical: BotsTest.session("s5", lastActive: 500)),
            BotsTest.row("h1", canonical: BotsTest.session("s6", lastActive: 400), meta: ["hidden": true]),
            BotsTest.row("h2", canonical: BotsTest.session("s7", lastActive: 300), meta: ["hidden": true]),
            BotsTest.row("pin", canonical: BotsTest.session("s8", lastActive: 100), meta: ["pinned": true]),
        ]
    }

    @Test func manualOrdersEveryBlockAndRecentActivityDoesNot() {
        let sections = [RosterSectionRecord(id: "sec-work", name: "Work")]
        var input = RosterBuilder.Input(profiles: rows.map(profile), sections: sections)
        let recent = RosterBuilder.build(input).layout
        #expect(recent.sections.first?.bots.map(\.id) == ["w1", "w2", "w3"])
        #expect(recent.unassigned.map(\.id) == ["u1", "u2"])
        #expect(recent.hidden.map(\.id) == ["h1", "h2"])
        input.rowOrder = ["h2", "u2", "w3", "w1", "h1", "u1", "w2", "pin"]
        let manual = RosterBuilder.build(input).layout
        #expect(manual.tiles.map(\.id) == ["pin"], "the tiles keep their own order")
        #expect(manual.sections.first?.bots.map(\.id) == ["w3", "w1", "w2"])
        #expect(manual.unassigned.map(\.id) == ["u2", "u1"])
        #expect(manual.hidden.map(\.id) == ["h2", "h1"])
        #expect(manual.rows.map(\.id) == ["w3", "w1", "w2", "u2", "u1", "h2", "h1"])
        // Manual with nothing saved yet: as Recent Activity.
        input.rowOrder = []
        #expect(RosterBuilder.build(input).layout == recent)
    }

    /// Past six pins, the Pinned section's rows follow the order too.
    @Test func pinnedOverflowFollowsTheOrder() {
        let pins = (1...8).map { i in
            BotsTest.row("p\(i)", canonical: BotsTest.session("s\(i)", lastActive: Double(i * 10)), meta: ["pinned": true])
        }
        var input = RosterBuilder.Input(profiles: pins.map(profile))
        #expect(RosterBuilder.build(input).layout.sections.first?.bots.map(\.id) == ["p2", "p1"])
        input.rowOrder = ["p1", "p2"]
        #expect(RosterBuilder.build(input).layout.sections.first?.bots.map(\.id) == ["p1", "p2"])
    }

    // MARK: Store (kept per account across launches)

    @Test func storeKeepsManualAcrossLaunchesAndRecentActivityDropsIt() async throws {
        let client = BotsFakeGatewayClient()
        let all = rows
        client.on("profiles.list") { _ in BotsTest.profilesResult(all) }
        let dir = BotsTest.tempDirectory()
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: dir, timing: .fast)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        #expect(!store.rowsManual)
        #expect(store.layout.unassigned.map(\.id) == ["u1", "u2"])

        // Move Down on u1: Manual from now on, the other blocks as they were.
        store.placeRows(["u2", "u1"])
        #expect(store.rowsManual)
        #expect(store.layout.unassigned.map(\.id) == ["u2", "u1"])
        #expect(store.layout.sections.first?.bots.map(\.id) == ["w1", "w2", "w3"])
        store.stop()
        RosterDiskWriter.shared.flush()

        let again = BotStore(client: BotsFakeGatewayClient(), account: .botsTestAccount, cacheDirectory: dir, timing: .fast, autoStart: false)
        #expect(again.rowsManual)
        #expect(again.layout.unassigned.map(\.id) == ["u2", "u1"], "kept across a launch")
        // Another account on this device sorts by activity.
        let other = GatewayAccount(id: "http://127.0.0.1:9716|other", baseURL: URL(string: "http://127.0.0.1:9716")!,
                                   kind: .password, username: "other", label: "127.0.0.1")
        let elsewhere = BotStore(client: BotsFakeGatewayClient(account: other), account: other, cacheDirectory: dir, timing: .fast,
                                 autoStart: false)
        #expect(!elsewhere.rowsManual)

        // Sort By › Recent Activity: the saved order goes.
        again.setRowsManual(false)
        #expect(!again.rowsManual)
        #expect(again.layout.unassigned.map(\.id) == ["u1", "u2"])
        // Sort By › Manual: every row stays where it is now.
        again.setRowsManual(true)
        #expect(again.rowsManual)
        #expect(again.layout.rows.map(\.id) == ["w1", "w2", "w3", "u1", "u2", "h1", "h2"])
    }

    /// A full roster without a bot drops its name; a new bot keeps the place it folded into.
    @Test func storeReconcilesWithTheRoster() async throws {
        let first = rows
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in BotsTest.profilesResult(first) }
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast)
        #expect(await BotsTest.waitUntil { store.phase == .full })
        store.placeRows(["u2", "u1"])
        // u1 deleted; a newer bot, n, arrives unassigned.
        let next = rows.filter { $0["name"]?.string != "u1" } + [BotsTest.row("n", canonical: BotsTest.session("s9", lastActive: 950))]
        client.on("profiles.list") { _ in BotsTest.profilesResult(next) }
        await store.refresh()
        #expect(await BotsTest.waitUntil { store.layout.unassigned.map(\.id) == ["n", "u2"] })
        #expect(store.layout.unassigned.map(\.id) == ["n", "u2"], "newer than the first known row: on top")
        store.placeRows(["u2", "n"])
        #expect(store.layout.unassigned.map(\.id) == ["u2", "n"])
        store.stop()
    }
}
