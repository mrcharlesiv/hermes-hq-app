import Foundation
import Testing
@testable import HermesHQNative

/// [perf] The Sessions header's chips hold only what a chip draws, so a roster tick that changes a preview, a time or
/// an unread dot leaves the rail's array equal and the header is not drawn and measured again.
@MainActor @Suite struct SessionChipBotTests {
    private func bot(_ id: String, name: String? = nil, preview: String? = nil, minutes: Double? = nil, unread: Bool = false,
                     working: Bool = false, form: String = "round") -> Bot {
        Bot(id: id, name: name ?? id.capitalized, role: nil, preview: preview,
            lastActive: minutes.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * 60) }, isWorking: working,
            unread: unread, pinned: false, pinOrder: nil, sectionName: nil, hidden: false, canonicalSessionId: nil,
            head: .object(["theme": .string("shape"), "form": .string(form), "tile": .string("none"), "seed": .number(7),
                           "color": .string("sky"), "v": .number(6)]))
    }

    @Test func fewerThanTwoBotsHaveNoRail() {
        #expect(SessionChipBot.chips(from: []).isEmpty)
        #expect(SessionChipBot.chips(from: [bot("default")]).isEmpty)
        #expect(SessionChipBot.chips(from: [bot("default"), bot("ada")]).map(\.id) == ["default", "ada"])
    }

    @Test func previewTimeAndUnreadLeaveTheChipsEqual() {
        let before = SessionChipBot.chips(from: [bot("default"), bot("ada")])
        let after = SessionChipBot.chips(from: [bot("default", preview: "Done.", minutes: 1, unread: true), bot("ada", minutes: 3)])
        #expect(before == after)
    }

    @Test func nameHeadAndWorkingChangeTheChips() {
        let base = SessionChipBot.chips(from: [bot("default"), bot("ada")])
        #expect(SessionChipBot.chips(from: [bot("default"), bot("ada", name: "Ada L")]) != base)
        #expect(SessionChipBot.chips(from: [bot("default"), bot("ada", form: "blob")]) != base)
        #expect(SessionChipBot.chips(from: [bot("default"), bot("ada", working: true)]) != base)
    }
}
