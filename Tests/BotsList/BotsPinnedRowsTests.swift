import Foundation
import Testing
@testable import HermesHQNative

/// [pinned-rows] Owner 2026-11-08: Filter › Pinned Bots › Rows draws every pin as a row at the top of the list, with no
/// header, in the pins' own order (the one a drag sets), instead of faces with names over the list.
@Suite struct BotsPinnedRowsTests {
    private func bot(_ id: String, at: Double? = nil, pinned: Bool = false) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: at.map { Date(timeIntervalSince1970: $0) }, isWorking: false,
            unread: false, pinned: pinned, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
    }

    /// Six tiles, two pins past them, a section and an unfiled bot.
    private var layout: RosterLayout {
        var layout = RosterLayout()
        layout.tiles = ["t1", "t2", "t3", "t4", "t5", "t6"].map { bot($0, pinned: true) }
        layout.sections = [.init(id: RosterRules.pinnedSectionId, name: RosterRules.pinnedSectionName, bots: [bot("p7", pinned: true), bot("p8", pinned: true)]),
                           .init(id: "s1", name: "Work", bots: [bot("w")])]
        layout.unassigned = [bot("u")]
        return layout
    }

    private let records = [RosterSectionRecord(id: "s1", name: "Work")]

    @Test func facesKeepTheTilesAndThePinnedSection() {
        let sections = BotListLayout.compose(layout: layout, records: records)
        #expect(sections.map(\.id) == [.tiles, .pinned, .user("s1"), .unassigned])
        #expect(sections[1].title == "Pinned")
    }

    @Test func rowsPutEveryPinInOneBlockWithNoHeader() {
        let sections = BotListLayout.compose(layout: layout, records: records, pinsAsRows: true)
        #expect(sections.map(\.id) == [.pinned, .user("s1"), .unassigned], "no tiles")
        #expect(sections[0].title == nil, "no Pinned header")
        #expect(BotListLayout.isPinnedRows(sections[0]))
        #expect(sections[0].bots.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6", "p7", "p8"], "the six faces, then the rest")
        #expect(sections[2].bots.map(\.id) == ["u"])
    }

    /// A drag past the sixth pin is kept (`PinOrder` holds 64 names): the pins' rows follow the saved order, the ones
    /// never placed after them.
    @Test func rowsFollowThePinsSavedOrder() {
        let sections = BotListLayout.compose(layout: layout, records: records, pinsAsRows: true, pinOrder: ["p8", "t3", "gone", "p7"])
        #expect(sections[0].bots.map(\.id) == ["p8", "t3", "p7", "t1", "t2", "t4", "t5", "t6"])
    }

    @Test func aRowDraggedAmongThePinsSavesTheirOrder() {
        let before = ["t1", "t2", "p7"]
        let after = PinOrder.moved(before, from: 2, to: 0)
        let saved = PinOrder.next(saved: ["t1", "t2"], before: before, after: after)
        #expect(saved == ["p7", "t1", "t2"])
        let sections = BotListLayout.compose(layout: layout, records: records, pinsAsRows: true, pinOrder: saved)
        #expect(Array(sections[0].bots.map(\.id).prefix(3)) == ["p7", "t1", "t2"])
    }

    @Test func groupByNoneKeepsThePinsOnTop() {
        let sections = BotListLayout.compose(layout: layout, records: records, pinsAsRows: true)
        let flat = BotListLayout.flat(sections, loose: [])
        #expect(flat.map(\.id) == [.pinned, .everything])
        #expect(flat[0].bots.count == 8 && flat[1].bots.map(\.id) == ["w", "u"])
    }

    @Test func noPinsNoBlock() {
        var layout = RosterLayout()
        layout.unassigned = [bot("u")]
        #expect(BotListLayout.compose(layout: layout, records: [], pinsAsRows: true).map(\.id) == [.unassigned])
    }

    @Test func theLookIsKeptOnThisDevice() {
        let saved = UserDefaults.standard.string(forKey: BotPinnedLook.key)
        defer { UserDefaults.standard.set(saved, forKey: BotPinnedLook.key) }
        UserDefaults.standard.removeObject(forKey: BotPinnedLook.key)
        #expect(BotPinnedLook.saved == .faces, "faces until chosen")
        BotPinnedLook.saved = .rows
        #expect(BotPinnedLook.saved == .rows)
    }
}
