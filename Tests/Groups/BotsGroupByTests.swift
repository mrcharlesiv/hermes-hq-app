import Foundation
import Testing
@testable import HermesHQNative

/// [bots-groupby] Tester 2026-11-05: bots and group chats share sections, the unfiled ones sit under Unassigned, and
/// Group By › None is one list by activity.
@Suite struct BotsGroupByTests {
    private func bot(_ id: String, at: Double? = nil, pinned: Bool = false) -> Bot {
        Bot(id: id, name: id.capitalized, role: nil, preview: nil, lastActive: at.map { Date(timeIntervalSince1970: $0) }, isWorking: false,
            unread: false, pinned: pinned, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil, head: nil)
    }

    private func room(_ name: String, lastAt: Double = 0, section: String? = nil) -> GroupRowModel {
        GroupRowModel(id: "id:\(name)", name: name, image: nil, faces: [], line: "2 bots", tone: .secondary, time: nil, unread: false, pinned: false,
                      muted: false, memberCount: 2, running: false, sectionId: section, order: nil, pinnedAt: nil, lastAt: lastAt,
                      search: name.lowercased(), online: true)
    }

    @Test func aSectionDrawsItsBotsAndRoomsByActivity() {
        let section = BotListSection(id: .user("s1"), title: "Work", bots: [bot("a", at: 300), bot("b", at: 100)],
                                     rooms: [room("Standup", lastAt: 200_000), room("Old", lastAt: 50_000)])
        let ids = section.rows().map { row -> String in
            switch row { case .bot(let id): id; case .room(let id): id }
        }
        #expect(ids == ["a", "id:Standup", "b", "id:Old"])
    }

    /// Audit 05-4, 05-5: Sort By › Manual (the bots in the owner's order) keeps that order and still mixes the group
    /// chats in by time; one Move Up no longer sends every chat below the bots.
    @Test func manualKeepsTheBotsOrderAndTheRoomsAmongThem() {
        let section = BotListSection(id: .user("s1"), title: "Work", bots: [bot("b", at: 100), bot("a", at: 300)],
                                     rooms: [room("Standup", lastAt: 200_000), room("Old", lastAt: 50_000)])
        let ids = section.rows().map { row -> String in
            switch row { case .bot(let id): id; case .room(let id): id }
        }
        #expect(ids == ["id:Standup", "b", "a", "id:Old"])
        #expect(ids.filter { !$0.hasPrefix("id:") } == ["b", "a"], "the bots keep the order they were put in")
        #expect(ids.last == "id:Old" && ids.first == "id:Standup", "the rooms are not all sent to the bottom")
    }

    /// Audit 05-6: with sections, a pinned room the tiles can't take joins Pinned (made after the tiles when only rooms
    /// overflow), not Unassigned.
    @Test func pinnedRoomsPastTheTilesGoInPinned() throws {
        let sections = [BotListSection(id: .tiles, title: nil, bots: [bot("t", pinned: true)]),
                        BotListSection(id: .user("s1"), title: "Work", bots: [bot("a")]),
                        BotListSection(id: .unassigned, title: nil, bots: [bot("b")])]
        let out = try #require(BotListLayout.file(sections, loose: [room("Loose")], filed: [], pinned: [room("Extra pin")]))
        #expect(out.map(\.id) == [.tiles, .pinned, .user("s1"), .unassigned])
        #expect(out[1].title == "Pinned" && out[1].rooms.map(\.name) == ["Extra pin"] && out[1].bots.isEmpty)
        #expect(out[3].rooms.map(\.name) == ["Loose"], "Unassigned keeps only the unfiled rooms")
        let withPinned = [sections[0], BotListSection(id: .pinned, title: "Pinned", bots: [bot("p", pinned: true)])] + sections.dropFirst()
        let joined = try #require(BotListLayout.file(withPinned, loose: [], filed: [], pinned: [room("Extra pin")]))
        #expect(joined.filter { $0.id == .pinned }.count == 1)
        #expect(joined[1].bots.map(\.id) == ["p"] && joined[1].rooms.map(\.name) == ["Extra pin"])
    }

    /// Audit 05-2: Delete Section's question counts the group chats filed there too.
    @Test func deleteSectionNamesItsBotsAndGroupChats() {
        #expect(BotListLayout.deleteMessage(bots: 0, rooms: 0) == nil, "an empty section goes at once")
        #expect(BotListLayout.deleteMessage(bots: 1, rooms: 0) == "Its bot moves to Unassigned.")
        #expect(BotListLayout.deleteMessage(bots: 3, rooms: 0) == "Its 3 bots move to Unassigned.")
        #expect(BotListLayout.deleteMessage(bots: 0, rooms: 1) == "Its group chat moves to Unassigned.")
        #expect(BotListLayout.deleteMessage(bots: 0, rooms: 2) == "Its 2 group chats move to Unassigned.")
        #expect(BotListLayout.deleteMessage(bots: 2, rooms: 1) == "Its 2 bots and 1 group chat move to Unassigned.")
        #expect(BotListLayout.deleteMessage(bots: 1, rooms: 3) == "Its 1 bot and 3 group chats move to Unassigned.")
    }

    /// Audit 05-14: a section can't take the list's own headings or another section's name.
    @Test func sectionNamesAreChecked() {
        #expect(BotListLayout.sectionNameProblem("Clients", others: ["Work"]) == nil)
        #expect(BotListLayout.sectionNameProblem("  ", others: ["Work"]) == nil, "blank is the prompt's own rule")
        #expect(BotListLayout.sectionNameProblem("work ", others: ["Work"]) == "There’s already a section named “Work”.")
        for reserved in ["unassigned", "Hidden", "PINNED", "Group Chats"] {
            #expect(BotListLayout.sectionNameProblem(reserved, others: []) != nil, "\(reserved)")
        }
        #expect(BotListLayout.sectionNameProblem("Work", others: []) == nil, "a rename leaves its own name out")
    }

    @Test func withSectionsUnfiledChatsGoUnderUnassigned() throws {
        let sections = [BotListSection(id: .user("s1"), title: "Work", bots: [bot("a")]),
                        BotListSection(id: .unassigned, title: nil, bots: [bot("b")]),
                        BotListSection(id: .hidden, title: "Hidden", bots: [bot("h")])]
        let out = try #require(BotListLayout.file(sections, loose: [room("Loose")], filed: [(id: "s1", rooms: [room("Filed", section: "s1")])]))
        #expect(out.map(\.id) == [.user("s1"), .unassigned, .hidden])
        #expect(out[0].rooms.map(\.name) == ["Filed"])
        #expect(out[1].title == "Unassigned" && out[1].rooms.map(\.name) == ["Loose"] && out[1].bots.map(\.id) == ["b"])
    }

    @Test func anUnassignedBlockIsMadeForLooseRoomsAboveHidden() throws {
        let sections = [BotListSection(id: .user("s1"), title: "Work", bots: [bot("a")]),
                        BotListSection(id: .hidden, title: "Hidden", bots: [bot("h")])]
        let out = try #require(BotListLayout.file(sections, loose: [room("Loose")], filed: []))
        #expect(out.map(\.id) == [.user("s1"), .unassigned, .hidden])
        let none = try #require(BotListLayout.file(Array(sections.prefix(1)), loose: [], filed: []))
        #expect(none.map(\.id) == [.user("s1")], "nothing loose: no empty Unassigned")
    }

    @Test func withoutSectionsTheListStaysAsItWas() {
        let sections = [BotListSection(id: .unassigned, title: nil, bots: [bot("a")])]
        #expect(BotListLayout.file(sections, loose: [room("Loose")], filed: []) == nil)
    }

    @Test func groupByNoneIsOneBlockByActivityBetweenTilesAndHidden() throws {
        let sections = [BotListSection(id: .tiles, title: nil, bots: [bot("t", pinned: true)]),
                        BotListSection(id: .pinned, title: "Pinned", bots: [bot("p", at: 10, pinned: true)]),
                        BotListSection(id: .user("s1"), title: "Work", bots: [bot("w", at: 30)], rooms: [room("Filed", lastAt: 20_000)]),
                        BotListSection(id: .unassigned, title: nil, bots: [bot("u", at: 40)]),
                        BotListSection(id: .hidden, title: "Hidden", bots: [bot("h")])]
        let out = BotListLayout.flat(sections, loose: [room("Loose", lastAt: 35_000)])
        #expect(out.map(\.id) == [.tiles, .everything, .hidden])
        let everything = try #require(out.first { $0.id == .everything })
        #expect(everything.title == nil)
        let ids = everything.rows().map { row -> String in
            switch row { case .bot(let id): id; case .room(let id): id }
        }
        #expect(ids == ["u", "id:Loose", "w", "id:Filed", "p"], "a pin past the tiles takes its place by activity")
    }

    @Test func groupByIsSavedByName() {
        #expect(BotGroupBy.allCases.map(\.title) == ["Sections", "None"])
        #expect(BotGroupBy(rawValue: "none") == BotGroupBy.none)
    }
}
