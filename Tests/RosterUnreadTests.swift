import Foundation
import Testing
@testable import HermesHQNative

/// Bot unread dots: device-local baselines and markers (spec 02 §6.6–6.7).
@Suite struct RosterUnreadTests {
    private func bot(_ name: String = "ivy", stamp: Double, count: Int = 4, resolved: String? = "tip") -> RosterProfile {
        RosterProfile(json: BotsTest.row(name, canonical: BotsTest.session("reg", resolved: resolved, lastActive: stamp, count: count)))!
    }

    @Test func firstSightOnlyRecordsTheBaseline() {
        var state = BotUnreadState()
        state.reconcile([bot(stamp: 100)]) { _ in false }
        #expect(state.baselines["ivy"] == 100)
        #expect(!state.isUnread(bot(stamp: 100)))
    }

    @Test func newerActivityMarksUnread() {
        var state = BotUnreadState()
        state.reconcile([bot(stamp: 100)]) { _ in false }
        state.reconcile([bot(stamp: 100)]) { _ in false }
        #expect(!state.isUnread(bot(stamp: 100)))                 // unchanged poll stays read
        state.reconcile([bot(stamp: 150)]) { _ in false }
        #expect(state.isUnread(bot(stamp: 150)))
        #expect(state.markers["ivy"] == ["reg"])                    // one durable marker on the registry id
        #expect(state.baselines["ivy"] == 150)
        // A later unchanged poll keeps the dot.
        state.reconcile([bot(stamp: 150)]) { _ in false }
        #expect(state.isUnread(bot(stamp: 150)))
    }

    @Test func emptyChatNeverMarks() {
        var state = BotUnreadState()
        state.reconcile([bot(stamp: 100, count: 0)]) { _ in false }
        state.reconcile([bot(stamp: 200, count: 0)]) { _ in false }
        #expect(!state.isMarked(bot(stamp: 200, count: 0)))
        // A marker on a chat that is now empty draws no dot ("untouched").
        state.mark(bot(stamp: 200, count: 0))
        #expect(state.isMarked(bot(stamp: 200, count: 0)) && !state.isUnread(bot(stamp: 200, count: 0)))
    }

    @Test func visibleChatIsAcknowledged() {
        var state = BotUnreadState()
        state.reconcile([bot(stamp: 100)]) { _ in false }
        state.mark(bot(stamp: 100))
        state.reconcile([bot(stamp: 150)]) { $0.name == "ivy" }
        #expect(!state.isUnread(bot(stamp: 150)))
        #expect(state.baselines["ivy"] == 150)
    }

    @Test func acknowledgeClearsBothIdsAndAdvancesBaseline() {
        var state = BotUnreadState()
        state.markers["ivy"] = ["reg", "tip", "other"]
        state.baselines["ivy"] = 10
        state.acknowledge(bot(stamp: 300))
        #expect(state.markers["ivy"] == ["other"])
        #expect(state.baselines["ivy"] == 300)
        // A marker naming only the lineage tip also paints the dot.
        var tipOnly = BotUnreadState()
        tipOnly.markers["ivy"] = ["tip"]
        #expect(tipOnly.isUnread(bot(stamp: 1)))
    }

    @Test func roundTripsThroughDisk() throws {
        var state = BotUnreadState()
        state.reconcile([bot(stamp: 100)]) { _ in false }
        state.reconcile([bot(stamp: 200)]) { _ in false }
        let decoded = try JSONDecoder().decode(BotUnreadState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.isUnread(bot(stamp: 200)))
    }

    @Test func baselinesArePrunedPastTheCap() {
        var state = BotUnreadState()
        for i in 0..<BotUnreadState.maxBaselines { state.baselines["gone\(i)"] = 1 }
        state.reconcile([bot(stamp: 5)]) { _ in false }
        #expect(state.baselines.count <= BotUnreadState.maxBaselines)
        #expect(state.baselines["ivy"] == 5)
    }
}
