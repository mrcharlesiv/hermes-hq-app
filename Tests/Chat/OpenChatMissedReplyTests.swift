// "I was already in the same chat as the bot … its response is not showing. If I clicked out of it and back in, the
// response was there" (owner, 2026-10-15; the log: 14 frames set aside on the open chat). A reply that ran on a runtime
// the open chat isn't bound to shows without leaving, and a reconnect's `session.activate` that rebinds keeps the
// frames the new runtime sent before it answered.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Open chat: no reply missed", .serialized)
@MainActor
struct OpenChatMissedReplyTests {
    @Test func aReplyFinishedOnAnotherRuntimeIsReadIn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(21))
        let rows = base + [
            ["role": "user", "content": "Are you there?", "row_id": 6000, "timestamp": 1791590000],
            ["role": "assistant", "content": "Here, and done.", "row_id": 6001, "timestamp": 1791590001],
        ]
        h.setPage("24", rows: Array(rows.suffix(24)), hasMore: true)
        h.setPage("1", rows: [rows.last!], hasMore: true)
        await h.emit([h.event("message.delta", ["text": "Here, and done."], seq: 4, sid: "other-runtime"),
                      h.event("message.complete", ["text": "Here, and done.", "status": "complete"], seq: 5, sid: "other-runtime")])
        #expect(await waitUntil(timeout: .seconds(4)) { s.messages.contains { $0.plainText == "Here, and done." } })
        #expect(LeftChatProbe.of(s).foreignReads == 1)
    }

    @Test func framesTheNewRuntimeSentBeforeActivateAnsweredAreKept() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let client = h.client
        let start: JSONValue = ["jsonrpc": "2.0", "method": "event",
                                "params": ["type": "message.start", "session_id": "rebound", "seq": 1]]
        let delta: JSONValue = ["jsonrpc": "2.0", "method": "event",
                                "params": ["type": "message.delta", "session_id": "rebound", "seq": 2,
                                           "payload": ["text": "Streamed before the answer."]]]
        client.onCall { method, _ in
            switch method {
            case "session.activate":
                // The gateway rebinds, streams to the new runtime, then answers.
                client.emit(frame: start)
                client.emit(frame: delta)
                return ["session_id": "rebound", "running": true, "status": "streaming"]
            case "session.events.since":
                return ["events": [], "latest_seq": 2, "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
        client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil { s.runtimeSessionId == "rebound" && !s.parking })
        try? await Task.sleep(for: .milliseconds(80))
        s.flushChanges()
        #expect(s.messages.contains { $0.plainText.contains("Streamed before the answer.") })
    }
    /// Build 278, same bot: the reply finished while the link was paused in the background, so no frame said so, and the
    /// alert was tapped with the chat already open. The reconnect's catch-up found nothing to replay; the tail read after
    /// it shows the reply.
    @Test func aReplyThatFinishedWhileThePhoneSleptShowsAfterTheReconnect() async throws {
        let h = try ChatHarness(ready: ["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        await h.emit([h.event("session.info", ["model": "fixture"], seq: 7)])
        #expect(s.lastSeq == 7)
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(21))
        let rows = base + [
            ["role": "user", "content": "Still there?", "row_id": 7000, "timestamp": 1791590000],
            ["role": "assistant", "content": "Finished while you were away.", "row_id": 7001, "timestamp": 1791590001],
        ]
        h.setPage("24", rows: Array(rows.suffix(24)), hasMore: true)
        h.setPage("1", rows: [rows.last!], hasMore: true)
        h.client.setConnection(.reconnecting(attempt: 1))
        h.client.setConnection(.ready)
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil(timeout: .seconds(4)) { s.messages.contains { $0.plainText == "Finished while you were away." } })
    }
}
