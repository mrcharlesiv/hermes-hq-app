// A turn sent before its chat's stored id came back ends under the id: the bot stops saying "Working…" (2026-11-03).

import Testing
@testable import HermesHQNative

@Suite struct TurnWorkingTests {
    @Test func aTurnThatStartedUnstoredEndsUnderItsId() {
        var w = TurnWorking()
        w.set(profile: "inbox", storedId: nil, running: true)
        #expect(w.busy("inbox") == [""])
        let moved = w.resolved(profile: "inbox", storedId: "s1")
        #expect(moved)
        #expect(w.busy("inbox") == ["s1"])
        w.set(profile: "inbox", storedId: "s1", running: false)
        #expect(w.isIdle("inbox"))
    }

    @Test func anIdWithNothingUnstoredRunningChangesNothing() {
        var w = TurnWorking()
        w.set(profile: "otto", storedId: "a", running: true)
        let movedCro = w.resolved(profile: "otto", storedId: "b")
        let movedInbox = w.resolved(profile: "inbox", storedId: "b")
        #expect(!movedCro && !movedInbox)
        #expect(w.busy("otto") == ["a"])
        #expect(w.isIdle("inbox"))
    }

    @Test func otherChatsOfTheBotKeepRunning() {
        var w = TurnWorking()
        w.set(profile: "otto", storedId: "a", running: true)
        w.set(profile: "otto", storedId: nil, running: true)
        let moved = w.resolved(profile: "otto", storedId: "b")
        #expect(moved)
        w.set(profile: "otto", storedId: "b", running: false)
        #expect(w.busy("otto") == ["a"])
    }
}
