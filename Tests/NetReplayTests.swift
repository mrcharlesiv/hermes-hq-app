import Foundation
import Testing
@testable import HermesHQNative

/// The replay bookkeeping behind lossless reconnects (spec 01 §13.3).
@Suite struct ReplayBookTests {
    func event(_ session: String, _ seq: Int?, _ type: String = "message.delta") -> GatewayEvent {
        GatewayEvent(type: type, sessionId: session, seq: seq, payload: ["n": .number(Double(seq ?? -1))])
    }

    @Test func liveEventsPassOnceInOrder() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e1")
        #expect(book.live(event("s1", 1), size: 10).deliver?.seq == 1)
        #expect(book.live(event("s1", 2), size: 10).deliver?.seq == 2)
        #expect(book.live(event("s1", 2), size: 10).deliver == nil) // a duplicate (another socket, a replay overlap)
        #expect(book.live(event("s1", 1), size: 10).deliver == nil)
        #expect(book.live(event("", nil, "sessions.changed"), size: 10).deliver != nil) // session-less broadcasts pass
        #expect(book.live(event("s2", nil), size: 10).deliver != nil) // no seq (fixtures): pass, no cursor
        #expect(book.cursors == ["s1": 2])
    }

    @Test func reconnectReplaysThenReleasesParkedFrames() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e1")
        _ = book.live(event("s1", 5), size: 10)
        _ = book.live(event("s2", 9), size: 10)
        // Same epoch: both sessions are replayed, most recently active first, and their live frames wait.
        #expect(book.ready(epoch: "e1") == ["s2", "s1"])
        #expect(book.live(event("s1", 8), size: 10).deliver == nil)
        #expect(book.live(event("s1", 9), size: 10).deliver == nil)
        #expect(book.live(event("s3", 1), size: 10).deliver?.seq == 1) // not parked
        // The replay brings 6…8; the parked 8 is then a duplicate, 9 is new.
        #expect(book.accept(event("s1", 6))?.seq == 6)
        #expect(book.accept(event("s1", 7))?.seq == 7)
        #expect(book.accept(event("s1", 8))?.seq == 8)
        #expect(book.release("s1").map(\.seq) == [9])
        #expect(book.release("s2").isEmpty)
        #expect(!book.isParking && book.parkedCount == 0)
        #expect(book.cursors["s1"] == 9)
    }

    /// [presence] Catch-up frames (the `session.events.since` answer and the frames held meanwhile) carry `replayed`;
    /// a frame delivered as it happened does not (docs/spec/3x-presence.md §3.4): a replayed tool start is old news.
    @Test func replayedFramesAreMarkedAndLiveOnesAreNot() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e1")
        let live = book.live(event("s1", 5, "tool.start"), size: 10).deliver
        #expect(live?.replayed == false)
        #expect(book.live(event("", nil, "sessions.changed"), size: 10).deliver?.replayed == false)
        #expect(book.ready(epoch: "e1") == ["s1"])
        #expect(book.live(event("s1", 8, "tool.start"), size: 10).deliver == nil)       // held while the replay runs
        let caughtUp = book.acceptReplayed(event("s1", 6, "tool.start"))
        #expect(caughtUp?.replayed == true && caughtUp?.seq == 6 && caughtUp?.type == "tool.start")
        #expect(book.acceptReplayed(event("s1", 6, "tool.start")) == nil)               // still delivered once only
        let released = book.release("s1")
        #expect(released.map(\.seq) == [8] && released.allSatisfy(\.replayed))
        // After the catch-up the session is live again.
        #expect(book.live(event("s1", 9, "tool.start"), size: 10).deliver?.replayed == false)
        // A gap repair is a catch-up too.
        #expect(book.hasGap(event("s1", 12)))
        book.park("s1")
        #expect(book.live(event("s1", 12), size: 10).deliver == nil)
        #expect(book.acceptReplayed(event("s1", 10))?.replayed == true)
        #expect(book.releaseAll().map(\.replayed) == [true])
        // The default is "as it happened".
        #expect(GatewayEvent(type: "tool.start", sessionId: "s", seq: 1, payload: .null).replayed == false)
    }

    @Test func aRestartedGatewayDropsTheCursors() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e1")
        _ = book.live(event("s1", 40), size: 10)
        #expect(book.ready(epoch: "e2").isEmpty)
        #expect(book.cursors.isEmpty)
        // After the restart seq starts again; nothing is mistaken for a duplicate.
        #expect(book.live(event("s1", 1), size: 10).deliver?.seq == 1)
    }

    @Test func noEpochMeansNoContinuity() {
        var book = ReplayBook()
        _ = book.ready(epoch: nil)
        _ = book.live(event("s1", 40), size: 10)
        #expect(book.ready(epoch: nil).isEmpty)
        #expect(book.live(event("s1", 1), size: 10).deliver?.seq == 1)
    }

    @Test func answersFromAnotherEpochAndTruncation() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e1")
        _ = book.live(event("s1", 3), size: 10)
        _ = book.live(event("s2", 3), size: 10)
        _ = book.ready(epoch: "e1")
        book.truncated("s1")
        #expect(book.cursors["s1"] == nil && book.cursors["s2"] == 3)
        book.epochChanged(to: "e9")
        #expect(book.cursors.isEmpty && book.epoch == "e9")
    }

    @Test func atMostEightCursorsLeastRecentDropped() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e")
        for n in 0..<10 { _ = book.live(event("s\(n)", 1), size: 1) }
        #expect(book.cursors.count == 8)
        #expect(book.cursors["s0"] == nil && book.cursors["s1"] == nil && book.cursors["s9"] == 1)
        _ = book.live(event("s2", 2), size: 1) // s2 becomes the most recent
        #expect(book.ready(epoch: "e").first == "s2")
    }

    @Test func holdBudget() {
        var book = ReplayBook()
        _ = book.ready(epoch: "e")
        _ = book.live(event("s", 1), size: 1)
        _ = book.ready(epoch: "e")
        var over = false
        for n in 2...(ReplayBook.parkedFrameBudget + 2) where !over { over = book.live(event("s", n), size: 1).overBudget }
        #expect(over)
        book.socketClosed()
        #expect(!book.isParking && book.cursors["s"] == 1) // the cursor is untouched: the next replay starts there
        _ = book.ready(epoch: "e")
        #expect(book.live(event("s", 2), size: 5 << 20).overBudget)
    }
}
