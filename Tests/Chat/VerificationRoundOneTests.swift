// Regression tests for the protocol findings of integration verification round 1: a send whose ack was lost, Stop and
// resume when the link drops, an interrupted completion with no status, the turn-end read vs a change tick, and the
// reconnect that the connection's own replay already covered.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

private func texts(_ m: ChatMessage?) -> [String] {
    (m?.parts ?? []).compactMap { if case .text(let t) = $0 { return t } else { return nil } }
}

@Suite("Verification round 1 (protocol)", .serialized)
@MainActor
struct VerificationRoundOneTests {
    // MARK: Send whose answer never came (04 §2.5)

    /// The gateway stored the prompt, then the socket closed before the ack: "Delivery unconfirmed", no error card, the
    /// text is not handed back for a second send, and nothing is resent.
    @Test func lostAckIsUnconfirmedNotRefused() async throws {
        for failure in [RPCError.connectionLost("prompt.submit"), RPCError.timedOut("prompt.submit", after: .seconds(1800))] {
            let h = try ChatHarness()
            try h.setPage("24", "perf-page-latest-24.json")
            let s = h.make()
            #expect(await h.open())
            h.client.onCall { method, _ in
                switch method {
                case "prompt.submit": throw failure
                case "session.resume", "session.activate": return try ChatFixtures.json("perf-resume.json")["result"]!
                default: return [:]
                }
            }
            s.send("lost ack message")
            #expect(await waitUntil { h.lastUser?.error != nil })
            s.flushChanges()
            #expect(h.lastUser?.plainText == "lost ack message")
            #expect(h.lastUser?.error == LiveChatSession.unconfirmedMark)
            #expect(h.lastUser?.isPending == false)
            #expect(h.drafts.isEmpty)                                         // never offered for a resend
            #expect(!s.messages.contains { $0.role == .assistant && $0.error != nil })   // no "couldn't finish" card
            #expect(h.client.calls("prompt.submit").count == 1)               // never resent
            #expect(!s.isRunning)
        }
    }

    /// A call that never went out (no socket) is safe to refuse: the text comes back with the reason.
    @Test func notSentIsRefusedAndHandedBack() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError.notSent(.offline) }
            return try ChatFixtures.json("perf-resume.json")["result"]!
        }
        s.send("offline words")
        #expect(await waitUntil { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == "offline words")
        #expect(!s.messages.contains { $0.role == .user && $0.plainText == "offline words" })
    }

    /// The reconnect shows the gateway holds the prompt (resume's inflight user): the mark goes.
    @Test func inflightPromptClearsTheUnconfirmedMark() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": throw RPCError.connectionLost("prompt.submit")
            case "session.activate", "session.resume":
                return ["session_id": "5cc537d1", "running": true, "status": "streaming",
                        "inflight": ["user": "lost ack two", "assistant": "", "streaming": true]]
            default: return ["events": [], "truncated": false, "epoch": "fixture-epoch"]
            }
        }
        s.send("lost ack two")
        #expect(await waitUntil { h.lastUser?.error == LiveChatSession.unconfirmedMark })
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil { h.lastUser?.error == nil })
        #expect(s.isRunning)                                                  // the turn runs on the gateway
        #expect(s.messages.filter { $0.role == .user && $0.plainText == "lost ack two" }.count == 1)
    }

    // MARK: Stop over a dropped link (04 §5.6 step 4)

    @Test func stopLostOnTheLinkIsRetriedNotFailed() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let interrupts = Mutex(0)
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming", "user_row_id": 1210]
            case "session.interrupt":
                let n = interrupts.withLock { $0 += 1; return $0 }
                if n == 1 { throw RPCError.connectionLost("session.interrupt") }
                return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("long job")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        s.stop()
        #expect(await waitUntil { s.turn.stopPending })
        #expect(!h.notices.contains("Stop failed"))
        // The turn shows it is running: the second interrupt goes out.
        await h.emit([h.event("message.start")])
        #expect(await waitUntil { interrupts.withLock { $0 } == 2 })
        #expect(s.turn.interrupted)
    }

    // MARK: Resume (03 §3.1: one quiet retry)

    @Test func resumeRetriesOnceAfterADroppedLink() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let resumes = Mutex(0)
        let result = try ChatFixtures.json("perf-resume.json")["result"]!
        h.client.onCall { method, _ in
            guard method == "session.resume" else { return [:] }
            let n = resumes.withLock { $0 += 1; return $0 }
            if n == 1 { throw RPCError.connectionLost("session.resume") }
            return result
        }
        let s = h.make()
        #expect(await h.open())
        #expect(resumes.withLock { $0 } == 2)
        #expect(s.runtimeSessionId == "5cc537d1")
    }

    // MARK: Stop, then a completion without `status` (04 §4.5 step 3)

    @Test func statuslessCompleteAfterStopAddsNoBubble() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let ack = Mutex<CheckedContinuation<Void, Never>?>(nil)
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit":
                await withCheckedContinuation { c in ack.withLock { $0 = c } }
                return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("stop me before the ack")
        #expect(await waitUntil { ack.withLock { $0 != nil } })
        s.stop()
        let assistantsBefore = s.messages.filter { $0.role == .assistant }.count
        await h.emit([h.event("message.complete", ["text": "Stopped synthetic reply."])])
        ack.withLock { $0?.resume(); $0 = nil }
        try? await Task.sleep(for: .milliseconds(50))
        s.flushChanges()
        #expect(!s.messages.contains { texts($0).joined().contains("Stopped synthetic reply.") })
        #expect(s.messages.filter { $0.role == .assistant }.count == assistantsBefore)
    }

    /// A real interrupted partial still extends what was shown (extend-only).
    @Test func interruptedPartialStillExtends() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : ["status": "interrupted"] }
        s.send("write")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Once upon"])])
        s.stop()
        await h.emit([h.event("message.complete", ["text": "Once upon a time", "status": "interrupted"])])
        #expect(texts(h.assistant).joined() == "Once upon a time")
    }

    // MARK: The turn-end read owns the tick that follows the turn (03 §4.6, §7.7)

    @Test func changeTickRightAfterTurnEndWaitsForTheTurnEndRead() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        s.turnEndReadDelay = .milliseconds(300)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("short")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "ok"]),
                      h.event("message.complete", ["text": "ok", "status": "complete"])])
        let before = h.client.restLog.count
        h.client.emit(GatewayEvent(type: "sessions.changed", sessionId: "", seq: nil, payload: [:]))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.client.restLog.count == before)                             // nothing at once
        #expect(await waitUntil { h.client.restLog.count > before })          // the one turn-end read
        try? await Task.sleep(for: .milliseconds(400))
        // The turn-end read (a probe, maybe then the small page) — never a change-pass read on top of it.
        let reads = h.client.restLog.dropFirst(before).map { $0.query.first { $0.name == "limit" }?.value ?? "" }
        #expect(reads.first == "1")
        #expect(reads.count <= 2)
    }

    // MARK: Reconnect: the connection's replay already covered the gap (01 §13.3)

    @Test func reconnectSkipsItsOwnReplayWhenTheConnectionReplayed() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let replay: [JSONValue] = [h.event("message.delta", ["text": " two"], seq: 3), h.event("message.delta", ["text": " three"], seq: 4)]
        let client = h.client
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.activate":
                // The connection replays this session's missed frames while the chat re-binds.
                for frame in replay { client.emit(frame: frame) }
                try? await Task.sleep(for: .milliseconds(30))
                var snapshot = resume.object ?? [:]
                snapshot["running"] = true
                return .object(snapshot)
            case "session.events.since": return ["events": .array(replay.map { $0["params"]! }), "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
        s.send("count")
        await h.emit([h.event("message.start", seq: 1), h.event("message.delta", ["text": "one"], seq: 2)])
        #expect(s.lastSeq == 2)
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil { s.lastSeq == 4 })
        s.flushChanges()
        #expect(h.client.calls("session.events.since").isEmpty)
        #expect(texts(h.assistant).joined() == "one two three")
    }
}
